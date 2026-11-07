import Foundation
import SwiftUI
import Observation
import OhiaCore

private struct PlayheadNavigationAnchor {
    let chapterID: UUID?
    let messageID: UUID
}

/// `@MainActor @Observable` state owned by `TimelineWorkspaceView`. Holds
/// viewport / playhead / overlay state that is local to Timeline. The
/// shared top-bar bindings (`state.activeFrame`, `state.selectedTimeRange`,
/// `state.filter` from `ConstellationState`) remain authoritative — this
/// view-model only exposes Timeline-internal overlays.
///
/// Persisted preferences (per CLAUDE.md §19 display-vs-toggle convention)
/// are surfaced through `@AppStorage` bindings that the view writes to
/// directly; the corresponding `@Published`-style fields here mirror the
/// AppStorage values on read for off-main consumers.
@Observable @MainActor
final class TimelineWorkspaceState {

    // Viewport / zoom
    //
    // Two ranges in tandem (NLE convention):
    //
    // - `outerRange` is the "project duration" — the Moments preset's
    //   range (e.g. "Last 30 days"). The minimap renders this and zoom /
    //   pan operations stay clamped within it.
    // - `viewportRange` is the "camera window" — the sub-range the
    //   ruler and multitrack are currently rendering. Always a subset
    //   of `outerRange`. Equal to `outerRange` at zoom = fit.
    var outerRange: ClosedRange<Date>
    var viewportRange: ClosedRange<Date>
    var viewportPixelsPerDay: Double

    // Playhead
    var playhead: Date
    /// Exact identity selected by discrete navigation. Timeline chapters can
    /// overlap in time, so a date alone cannot preserve which thread/message
    /// the user stepped to. Scrubbing clears this anchor and returns to the
    /// date-based resolver.
    private var playheadNavigationAnchor: PlayheadNavigationAnchor?
    /// Search-result evidence to mark inside the top email pane. Cleared by
    /// ordinary playhead movement so manual Timeline navigation never carries
    /// stale result text forward.
    var searchMatchHighlight: SearchMatchHighlight?

    /// Transient per-message status gestures, so the reader pane can play the
    /// same delete / resolve / send-to-Composer exit animations the Front Page
    /// uses (via `DepartingGestureOverlay`). Its own coordinator — a lens is only
    /// ever mounted one at a time, and the shared `beginningStatusGestures`
    /// wrapper + `beginComposerDispatch` route the fires to the active lens.
    let statusGestureCoordinator = MessageStatusGestureCoordinator()

    // Multitrack-only affordances
    var expandedThreadIDs: Set<UUID> = []
    var attachmentSubtracksVisible: Bool = true
    /// Solo/mute now applies to NLE-style multitrack rows
    /// (sender, receiver, attachments, category, thread, account, status),
    /// not classification groups. Purpose appears as a chip inside the .purpose
    /// row's focused-email surface.
    var soloedRows: Set<TimelineMultitrackRow> = []
    var mutedRows: Set<TimelineMultitrackRow> = []
    var isolatedCorrespondentEmail: String?
    var isolatedAttachmentKind: TimelineAttachmentKind?
    var bracketedRange: ClosedRange<Date>?

    // Conversation mode
    /// Toggle for chapter-playback semantics. Mirrors the
    /// `@AppStorage("timelineConversationModeEnabled")` UserDefaults key —
    /// the view binds the AppStorage value into this property on
    /// appearance, and writes back on toggle.
    var conversationModeEnabled: Bool = false

    // AI annotation layers
    var aiLayers: Set<TimelineLayoutSnapshot.AIAnnotation.Kind> = []

    // Hover state
    var hoveredEntity: TimelineHoverTarget?

    // The latest layout snapshot (when one is available). Drives every
    // derived computation; written by `TimelineDataController` and read by
    // every view + resolver.
    var currentSnapshot: TimelineLayoutSnapshot? {
        didSet {
            guard let anchor = playheadNavigationAnchor else { return }
            if navigationAnchor(anchor, isValidIn: currentSnapshot) == false {
                playheadNavigationAnchor = nil
            }
        }
    }

    public init(
        viewportRange: ClosedRange<Date>,
        viewportPixelsPerDay: Double = 12.0
    ) {
        // Outer and inner start equal — fit to outer until the user zooms in.
        self.outerRange = viewportRange
        self.viewportRange = viewportRange
        self.viewportPixelsPerDay = viewportPixelsPerDay
        // Land the playhead at the viewport midpoint so the bright-yellow
        // cursor is plainly visible on first mount. The historical default
        // (`upperBound`) parked it on the rightmost pixel where the handle
        // was clipped and easy to miss.
        let span = viewportRange.upperBound.timeIntervalSince(viewportRange.lowerBound)
        self.playhead = viewportRange.lowerBound.addingTimeInterval(span * 0.5)
    }

    /// Minimum zoomed-in span (1 hour). Stops zoom-in from collapsing the
    /// viewport to a degenerate range that the projector can't divide.
    /// `nonisolated` — a plain constant, read from the `nonisolated`
    /// `TimelineDataController.fittedOuterRange` as well as from the main actor.
    nonisolated static let minimumViewportSpan: TimeInterval = 3600

    /// 0…1 zoom fraction for the ruler's slider. 0 = fit (viewport == outer),
    /// 1 = maximum zoom in (viewport span == `minimumViewportSpan`).
    /// Logarithmic mapping so the slider feels uniform across decades:
    /// pulling from "year" to "month" covers the same slider distance
    /// as "day" to "hour".
    var zoomFraction: Double {
        let outerSpan = outerRange.upperBound.timeIntervalSince(outerRange.lowerBound)
        let viewSpan = viewportRange.upperBound.timeIntervalSince(viewportRange.lowerBound)
        let minSpan = Self.minimumViewportSpan
        guard outerSpan > minSpan, viewSpan > 0 else { return 0 }
        let denom = log(outerSpan / minSpan)
        guard denom > 0 else { return 0 }
        return min(1, max(0, log(outerSpan / viewSpan) / denom))
    }

    /// Apply a 0…1 zoom fraction. The viewport span shrinks logarithmically
    /// from `outerSpan` (fraction = 0) toward `minimumViewportSpan`
    /// (fraction = 1), centered on `anchor`. Clamped to the outer range
    /// via `setViewportRange`.
    func applyZoomFraction(_ fraction: Double, centeredOn anchor: Date) {
        let outerSpan = outerRange.upperBound.timeIntervalSince(outerRange.lowerBound)
        let minSpan = Self.minimumViewportSpan
        guard outerSpan > minSpan else { return }
        let clamped = min(1, max(0, fraction))
        let ratio = minSpan / outerSpan
        let viewportSpan = outerSpan * pow(ratio, clamped)
        // Fraction 0 (or any zoom that would request a span ≥ the outer
        // range) is the "fit zoom" state. Route through `resetZoom()` so
        // the viewport snaps to `outerRange` regardless of where the
        // anchor sits — without this, an off-center playhead leaves a
        // sliver of outerRange uncovered because `setViewportRange`
        // only clamps inward.
        if viewportSpan >= outerSpan - 0.5 {
            resetZoom()
            return
        }
        let halfSpan = viewportSpan / 2
        let newLower = anchor.addingTimeInterval(-halfSpan)
        let newUpper = anchor.addingTimeInterval(halfSpan)
        setViewportRange(newLower...newUpper)
        // Keep persisted ppd in step with the new span.
        let days = max(0.001, viewportSpan / 86_400)
        viewportPixelsPerDay = max(0.005, 1024.0 / days)
    }

    // MARK: - Derived

    /// Chapter whose `start` is the largest value `≤ playhead`. Drives
    /// multitrack active-chapter expansion and the playhead resolver scope
    /// when `conversationModeEnabled`.
    var activeChapter: TimelineChapter? {
        guard let snapshot = currentSnapshot else { return nil }
        if let anchor = validPlayheadNavigationAnchor,
           let chapterID = anchor.chapterID,
           let chapter = snapshot.chapters.first(where: { $0.id == chapterID }) {
            return chapter
        }
        return TimelineActiveChapterResolver.activeChapter(
            chapters: snapshot.chapters,
            playhead: playhead
        )
    }

    /// The single message ID surfaced in the top pane's email viewer.
    /// In chronological mode, nearest message in the global eligible set.
    /// In conversation mode, nearest within the active chapter.
    var playheadMessageID: UUID? {
        guard let snapshot = currentSnapshot else { return nil }
        if let anchor = validPlayheadNavigationAnchor {
            if conversationModeEnabled == false
                || activeChapter?.messageIDs.contains(anchor.messageID) == true {
                return anchor.messageID
            }
        }
        if conversationModeEnabled {
            guard let chapter = activeChapter else { return nil }
            return TimelinePlayheadResolver.nearestMessage(
                playhead: playhead,
                scope: .chapter(chapter, dateLookup: snapshot.messageDateLookup)
            )
        }
        return TimelinePlayheadResolver.nearestMessage(
            playhead: playhead,
            scope: .global(eligible: snapshot.sortedEligibleEntries)
        )
    }

    /// The full metadata for the playhead message (subject, sent flag,
    /// chapter ID, etc.) — driven via `messageMetadata` so consumers don't
    /// need to re-search.
    var playheadMessage: TimelineLayoutSnapshot.MessageMeta? {
        guard let id = playheadMessageID,
              let snapshot = currentSnapshot else { return nil }
        return snapshot.messageMetadata[id]
    }

    /// 1-indexed position represented by the Timeline transport: the active
    /// thread among all chapters when conversation mode is on, or the current
    /// message among the chronological eligible set otherwise. `nil` when the
    /// snapshot is empty or no position can be resolved at the playhead.
    var playheadScopePosition: (index: Int, total: Int)? {
        guard let snapshot = currentSnapshot,
              let id = playheadMessageID else { return nil }
        if conversationModeEnabled {
            guard let chapter = playheadChapterPosition else { return nil }
            return (chapter.index + 1, chapter.total)
        }
        let entries = snapshot.sortedEligibleEntries
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return (idx + 1, entries.count)
    }

    /// 1-indexed message position inside the active thread. Kept separate
    /// from `playheadScopePosition` so the HUD can report thread position
    /// while still enabling previous/next-email navigation within a thread.
    var playheadMessagePositionInActiveThread: (index: Int, total: Int)? {
        guard conversationModeEnabled,
              let id = playheadMessageID,
              let chapter = activeChapter,
              let idx = chapter.messageIDs.firstIndex(of: id) else {
            return nil
        }
        return (idx + 1, chapter.messageIDs.count)
    }

    /// 0-indexed position of the active chapter within the snapshot's
    /// chapter list. Used to gate the ⏮/⏭ chapter-skip buttons.
    var playheadChapterPosition: (index: Int, total: Int)? {
        guard let snapshot = currentSnapshot,
              let active = activeChapter,
              let idx = snapshot.chapters.firstIndex(where: { $0.id == active.id }) else {
            return nil
        }
        return (idx, snapshot.chapters.count)
    }

    // MARK: - Mutations

    /// Set the playhead to a specific date, clamped into the viewport.
    func setPlayhead(_ date: Date) {
        let clamped = max(viewportRange.lowerBound, min(viewportRange.upperBound, date))
        playhead = clamped
        playheadNavigationAnchor = nil
        searchMatchHighlight = nil
    }

    /// Snap the playhead to a message ID by looking up its date in the
    /// current snapshot.
    func setPlayhead(toMessageID id: UUID) {
        setPlayhead(toMessageID: id, anchoredInChapterID: nil)
    }

    /// Center the timeline viewport on a message and move the playhead to it.
    /// Search warp uses this instead of `setPlayhead(toMessageID:)` so a hit
    /// outside the current camera window becomes visible before the playhead is
    /// clamped.
    @discardableResult
    func focusMessage(
        _ id: UUID,
        date fallbackDate: Date? = nil,
        maximumViewportSpan: TimeInterval? = nil,
        searchHighlight: SearchMatchHighlight? = nil
    ) -> Bool {
        guard let date = currentSnapshot?.messageDateLookup[id] ?? fallbackDate else { return false }
        centerViewport(on: date, maximumViewportSpan: maximumViewportSpan)
        if currentSnapshot?.messageDateLookup[id] != nil {
            setPlayhead(toMessageID: id, anchoredInChapterID: nil)
        } else {
            setPlayhead(date)
        }
        searchMatchHighlight = searchHighlight?.scoped(to: id)
        return true
    }

    /// Snap the playhead to the newest message in the current eligible
    /// snapshot. Returns false when no snapshot entry exists yet so callers
    /// can keep a pending default/recenter request alive until refresh lands.
    @discardableResult
    func setPlayheadToLatestEligibleMessage() -> Bool {
        guard let latest = currentSnapshot?.sortedEligibleEntries.last else { return false }
        setPlayhead(toMessageID: latest.id, anchoredInChapterID: nil)
        return true
    }

    /// Toggle a row's solo state. Solo'd rows override mute.
    func toggleSolo(_ row: TimelineMultitrackRow) {
        if soloedRows.contains(row) {
            soloedRows.remove(row)
        } else {
            soloedRows.insert(row)
            mutedRows.remove(row)
        }
    }

    /// Toggle a row's mute state. Solo'd rows cannot be muted.
    func toggleMute(_ row: TimelineMultitrackRow) {
        guard soloedRows.contains(row) == false else { return }
        if mutedRows.contains(row) {
            mutedRows.remove(row)
        } else {
            mutedRows.insert(row)
        }
    }

    /// Isolate a single correspondent (clears any prior isolation).
    func isolateCorrespondent(_ email: String?) {
        isolatedCorrespondentEmail = email?.lowercased()
    }

    /// Isolate a single attachment kind (clears any prior isolation).
    func isolateAttachmentKind(_ kind: TimelineAttachmentKind?) {
        isolatedAttachmentKind = kind
    }

    /// Toggle a thread's expanded state in the multitrack. Expanded threads
    /// render at increased height so the user can see the per-message
    /// internal ticks even outside the active chapter.
    func toggleThreadExpansion(_ threadID: UUID) {
        if expandedThreadIDs.contains(threadID) {
            expandedThreadIDs.remove(threadID)
        } else {
            expandedThreadIDs.insert(threadID)
        }
    }

    /// Apply a shift-drag bracket on the ruler.
    func applyBracket(_ range: ClosedRange<Date>?) {
        bracketedRange = range
    }

    /// Anchor the bracket's start at the current playhead. The end is
    /// either the existing bracket's upper bound or the viewport's upper
    /// bound (whichever sits after the playhead). A minimum 60s width is
    /// guaranteed so the resulting range is never degenerate (e.g., when
    /// the playhead is sitting at `viewportRange.upperBound`).
    func setBracketStartAtPlayhead() {
        let upper: Date
        if let existing = bracketedRange, existing.upperBound > playhead {
            upper = existing.upperBound
        } else {
            upper = viewportRange.upperBound
        }
        let candidateLower = min(playhead, upper)
        let lower = (upper.timeIntervalSince(candidateLower) >= Self.bracketMinimumWidth)
            ? candidateLower
            : upper.addingTimeInterval(-Self.bracketMinimumWidth)
        bracketedRange = lower...upper
    }

    /// Anchor the bracket's end at the current playhead. Symmetric to
    /// `setBracketStartAtPlayhead` — guarantees a minimum width.
    func setBracketEndAtPlayhead() {
        let lower: Date
        if let existing = bracketedRange, existing.lowerBound < playhead {
            lower = existing.lowerBound
        } else {
            lower = viewportRange.lowerBound
        }
        let candidateUpper = max(playhead, lower)
        let upper = (candidateUpper.timeIntervalSince(lower) >= Self.bracketMinimumWidth)
            ? candidateUpper
            : lower.addingTimeInterval(Self.bracketMinimumWidth)
        bracketedRange = lower...upper
    }

    private static let bracketMinimumWidth: TimeInterval = 60

    /// Fit zoom: restore the viewport to the entire outer (Moments) range.
    /// This is the NLE "zoom to fit sequence" — bound to the `0` key and
    /// the minimap / zoom slider's "fit" affordance. The canvas
    /// re-derives its effective ppd from `viewportRange ÷ width` on the
    /// next draw, so the visible window matches the new range immediately.
    func resetZoom() {
        viewportRange = outerRange
        let span = outerRange.upperBound.timeIntervalSince(outerRange.lowerBound)
        let days = max(0.001, span / 86_400)
        // Best-effort ppd hint so persisted state matches the fit zoom on
        // next launch. The renderer doesn't need this — it derives ppd
        // from `viewport ÷ width` per frame — but the persistence layer
        // round-trips this value through @AppStorage.
        viewportPixelsPerDay = max(0.005, 1024.0 / days)
    }

    /// Replace the outer range (e.g., initial bind to the database
    /// span). Resets the viewport to fit, clamps the playhead into
    /// the new range, and updates `viewportPixelsPerDay` to match.
    /// **Destructive** — use `extendOuterRange` for any subsequent
    /// outer-range updates that should preserve the user's current
    /// zoom / viewport position.
    func setOuterRange(_ range: ClosedRange<Date>) {
        outerRange = range
        viewportRange = range
        if playhead < range.lowerBound || playhead > range.upperBound {
            let span = range.upperBound.timeIntervalSince(range.lowerBound)
            playhead = range.lowerBound.addingTimeInterval(span * 0.5)
            playheadNavigationAnchor = nil
        }
        let days = max(0.001, range.upperBound.timeIntervalSince(range.lowerBound) / 86_400)
        viewportPixelsPerDay = max(0.005, 1024.0 / days)
    }

    /// Non-destructive outer-range update: shifts the outer bounds
    /// without resetting the user's viewport / zoom. The data
    /// controller calls this when live-refresh events (new mail
    /// arrived, message deleted) change the database span — the user
    /// is presumably mid-task and the slider position should stay put.
    /// The viewport is re-clamped through `setViewportRange` only if
    /// the new outer would otherwise crop it; same for the playhead.
    func extendOuterRange(_ range: ClosedRange<Date>) {
        outerRange = range
        // Clamp playhead into the new outer bounds. Only kicks in when
        // outer contracts past the playhead (e.g., the message the
        // playhead was on got deleted and it was the oldest / newest);
        // when outer grows this branch is inert.
        if playhead < range.lowerBound || playhead > range.upperBound {
            playhead = min(max(playhead, range.lowerBound), range.upperBound)
            playheadNavigationAnchor = nil
        }
        // Re-clamp viewport only if it sticks out past the new outer —
        // `setViewportRange` is a no-op when the input is already inside.
        let needsClamp = viewportRange.lowerBound < range.lowerBound
            || viewportRange.upperBound > range.upperBound
        if needsClamp {
            setViewportRange(viewportRange)
        }
    }

    /// Replace the inner viewport range, clamped into the outer range and
    /// no narrower than `minimumViewportSpan`. The single mutator for
    /// pan, zoom, and minimap-window drags so the clamp logic stays in
    /// one place.
    func setViewportRange(_ range: ClosedRange<Date>) {
        let minSpan = Self.minimumViewportSpan
        let outerLower = outerRange.lowerBound
        let outerUpper = outerRange.upperBound
        var lower = max(outerLower, range.lowerBound)
        var upper = min(outerUpper, range.upperBound)
        if upper.timeIntervalSince(lower) < minSpan {
            // Maintain the minimum span by expanding upward first.
            upper = lower.addingTimeInterval(minSpan)
            if upper > outerUpper {
                upper = outerUpper
                lower = max(outerLower, upper.addingTimeInterval(-minSpan))
            }
        }
        // Pure pan (no zoom change) — preserve the span exactly so the
        // user doesn't lose pixels as they drag along the minimap body
        // or scroll the playhead past the outer edge. Compare the
        // **requested** span (caller's intent) against the previous
        // viewport span, NOT the post-clamp span — when the requested
        // range overhangs outer, the initial `max/min` clamp shrinks
        // the post-clamp span and would otherwise fool this check into
        // thinking the caller asked for a zoom. The scroll scrubber
        // hitting outerUpper / outerLower is the canonical case: span
        // should stay constant; the viewport pegs against the edge.
        let oldSpan = viewportRange.upperBound.timeIntervalSince(viewportRange.lowerBound)
        let requestedSpan = range.upperBound.timeIntervalSince(range.lowerBound)
        if abs(requestedSpan - oldSpan) < 0.5 {
            let span = oldSpan
            if lower.addingTimeInterval(span) > outerUpper {
                lower = max(outerLower, outerUpper.addingTimeInterval(-span))
                upper = lower.addingTimeInterval(span)
            } else {
                upper = lower.addingTimeInterval(span)
            }
        }
        viewportRange = lower...upper
    }

    private func centerViewport(on date: Date, maximumViewportSpan: TimeInterval?) {
        let outerSpan = outerRange.upperBound.timeIntervalSince(outerRange.lowerBound)
        guard outerSpan > 0 else { return }
        let currentSpan = max(
            Self.minimumViewportSpan,
            viewportRange.upperBound.timeIntervalSince(viewportRange.lowerBound)
        )
        let requestedSpan: TimeInterval
        if let maximumViewportSpan, maximumViewportSpan > 0 {
            requestedSpan = min(currentSpan, maximumViewportSpan)
        } else {
            requestedSpan = currentSpan
        }
        let span = min(max(Self.minimumViewportSpan, requestedSpan), outerSpan)
        let halfSpan = span / 2
        setViewportRange(
            date.addingTimeInterval(-halfSpan)
            ... date.addingTimeInterval(halfSpan)
        )
        let days = max(0.001, span / 86_400)
        viewportPixelsPerDay = max(0.005, 1024.0 / days)
    }

    /// Skip to the next chapter (cmd-→ / ⏭).
    func skipToNextChapter() {
        guard let snapshot = currentSnapshot,
              let next = TimelineActiveChapterResolver.nextChapter(
                after: activeChapter,
                in: snapshot.chapters
              ),
              let firstID = next.messageIDs.first,
              snapshot.messageDateLookup[firstID] != nil else {
            return
        }
        setPlayhead(toMessageID: firstID, anchoredInChapterID: next.id)
    }

    /// Skip to the previous chapter (cmd-← / ⏮).
    func skipToPreviousChapter() {
        guard let snapshot = currentSnapshot,
              let prev = TimelineActiveChapterResolver.previousChapter(
                before: activeChapter,
                in: snapshot.chapters
              ),
              let firstID = prev.messageIDs.first,
              snapshot.messageDateLookup[firstID] != nil else {
            return
        }
        setPlayhead(toMessageID: firstID, anchoredInChapterID: prev.id)
    }

    /// Step the playhead by one message (←/→). In conversation mode, steps
    /// within the active chapter with chapter-overflow on the ends. In
    /// chronological mode, steps through the global eligible set.
    func stepPlayhead(direction: TimelineActiveChapterResolver.StepDirection) {
        guard let snapshot = currentSnapshot else { return }
        if conversationModeEnabled {
            guard let chapter = activeChapter else { return }
            let currentID = playheadMessageID
            guard let result = TimelineActiveChapterResolver.step(
                from: currentID,
                direction: direction,
                active: chapter,
                chapters: snapshot.chapters
            ),
            snapshot.messageDateLookup[result.messageID] != nil else { return }
            setPlayhead(
                toMessageID: result.messageID,
                anchoredInChapterID: result.chapter.id
            )
        } else {
            let entries = snapshot.sortedEligibleEntries
            guard entries.isEmpty == false else { return }
            let currentID = playheadMessageID
            guard let currentIndex = entries.firstIndex(where: { $0.id == currentID }) else {
                // No anchor — land on first or last.
                switch direction {
                case .forward:
                    setPlayhead(toMessageID: entries[0].id, anchoredInChapterID: nil)
                case .backward:
                    setPlayhead(toMessageID: entries[entries.count - 1].id, anchoredInChapterID: nil)
                }
                return
            }
            switch direction {
            case .forward:
                let next = currentIndex + 1
                if next < entries.count {
                    setPlayhead(toMessageID: entries[next].id, anchoredInChapterID: nil)
                }
            case .backward:
                let prev = currentIndex - 1
                if prev >= 0 {
                    setPlayhead(toMessageID: entries[prev].id, anchoredInChapterID: nil)
                }
            }
        }
    }

    /// Move the playhead off a just-deleted message so the email pane
    /// doesn't keep displaying it. Prefers the next message forward
    /// in time; falls back to the previous message if the deletion
    /// was the latest one. Handles two snapshot states:
    ///
    /// - Snapshot still contains the deleted message (the
    ///   `.ohiaDeletionApplied` notification hasn't propagated a
    ///   rebuild yet) — index off the deleted message's position.
    /// - Snapshot already refreshed (deletion landed synchronously
    ///   before this method runs) — find the next entry relative to
    ///   the current playhead date.
    func advancePlayheadAfterDeletion(of deletedID: UUID) {
        guard let snapshot = currentSnapshot else { return }
        let entries = snapshot.sortedEligibleEntries
        guard entries.isEmpty == false else { return }

        if let idx = entries.firstIndex(where: { $0.id == deletedID }) {
            // Snapshot still has the deleted message — step to its
            // chronological neighbor.
            if idx + 1 < entries.count {
                setPlayhead(toMessageID: entries[idx + 1].id, anchoredInChapterID: nil)
            } else if idx > 0 {
                setPlayhead(toMessageID: entries[idx - 1].id, anchoredInChapterID: nil)
            }
            return
        }

        // Snapshot already excludes the deleted message — find the
        // nearest entry by playhead date so the email pane lands on
        // a real neighbor instead of hanging on the deleted one.
        let currentPlayhead = playhead
        if let nextForward = entries.first(where: { $0.date > currentPlayhead }) {
            setPlayhead(toMessageID: nextForward.id, anchoredInChapterID: nil)
        } else if let nextBackward = entries.last(where: { $0.date < currentPlayhead }) {
            setPlayhead(toMessageID: nextBackward.id, anchoredInChapterID: nil)
        } else {
            // Playhead is exactly at an entry's date — pick any remaining
            // entry (the closest by linear scan) so the pane refreshes.
            setPlayhead(toMessageID: entries[entries.count - 1].id, anchoredInChapterID: nil)
        }
    }

    private var validPlayheadNavigationAnchor: PlayheadNavigationAnchor? {
        guard let anchor = playheadNavigationAnchor,
              navigationAnchor(anchor, isValidIn: currentSnapshot) else {
            return nil
        }
        return anchor
    }

    private func navigationAnchor(
        _ anchor: PlayheadNavigationAnchor,
        isValidIn snapshot: TimelineLayoutSnapshot?
    ) -> Bool {
        guard let snapshot,
              snapshot.messageDateLookup[anchor.messageID] == playhead else {
            return false
        }
        if let chapterID = anchor.chapterID {
            guard snapshot.chapters.first(where: { $0.id == chapterID })?
                .messageIDs.contains(anchor.messageID) == true else {
                return false
            }
        }
        return true
    }

    private func setPlayhead(
        toMessageID messageID: UUID,
        anchoredInChapterID chapterID: UUID?
    ) {
        guard let snapshot = currentSnapshot,
              let date = snapshot.messageDateLookup[messageID] else {
            return
        }
        setPlayhead(date)
        guard playhead == date else { return }
        let resolvedChapterID = chapterID ?? snapshot.chapters.first(where: {
            $0.messageIDs.contains(messageID)
        })?.id
        playheadNavigationAnchor = PlayheadNavigationAnchor(
            chapterID: resolvedChapterID,
            messageID: messageID
        )
    }

    // MARK: - Multitrack chip activation

    /// Per-row set of "active chip values" — strings whose meaning is
    /// row-specific (sender email, recipient email, attachment ID,
    /// Purpose rawValue, thread UUID, account UUID, "sent" / "read" /
    /// "unread" for the status row). When a row has any active value,
    /// the canvas:
    /// - Renders ticks for events whose value matches one of the
    ///   active set (instead of "events matching the focused email"),
    ///   in `ohiaYellow` rather than the event's AccountColor.
    /// - Decorates the matching chip(s) with a yellow fill so the
    ///   active state reads at a glance.
    ///
    /// Multi-select union per row (clicking two senders → both
    /// highlighted); rows are independent of each other.
    var activeRowChips: [TimelineMultitrackRow: Set<String>] = [:]

    /// Toggle a chip's active state on a row. Empty sets are pruned
    /// so `activeRowChips[row]` is either nil or non-empty — the
    /// canvas code uses presence as the "any chip active here" signal.
    func toggleRowChip(_ row: TimelineMultitrackRow, value: String) {
        var set = activeRowChips[row] ?? []
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
        activeRowChips[row] = set.isEmpty ? nil : set
    }

    /// True when `value` is in `row`'s active set.
    func isRowChipActive(_ row: TimelineMultitrackRow, value: String) -> Bool {
        activeRowChips[row]?.contains(value) ?? false
    }

    /// Step the playhead by ±1 day in clock time (shift-←/→).
    func stepPlayheadByDays(_ days: Int) {
        let delta = TimeInterval(days) * 86_400
        setPlayhead(playhead.addingTimeInterval(delta))
    }

    // MARK: - Scroll wheel

    /// Dispatches scroll wheel events from any timeline strip that wires
    /// itself to a `TimelineScrollCatcher`. Plain scroll scrubs the
    /// playhead through time (auto-panning the viewport when the
    /// playhead would otherwise leave the visible window). Shift- or
    /// option-scroll zooms the viewport around the playhead, matching
    /// the NLE convention. Lives on the workspace (not on the multitrack
    /// view) so the ruler band can route to the same behavior without
    /// duplicating logic.
    func handleScroll(deltaY: CGFloat, modifiers: NSEvent.ModifierFlags) {
        guard deltaY != 0 else { return }
        let isZoomGesture = modifiers.contains(.shift) || modifiers.contains(.option)
        if isZoomGesture {
            applyScrollZoom(deltaY: deltaY)
        } else {
            applyScrollScrub(deltaY: deltaY)
        }
    }

    private func applyScrollScrub(deltaY: CGFloat) {
        let viewport = viewportRange
        let span = viewport.upperBound.timeIntervalSince(viewport.lowerBound)
        guard span > 0 else { return }
        // ~one viewport-width of travel per 2000 cumulative scroll units.
        // Visible playhead stride per scroll tick stays under ~0.05% of
        // the viewport, so even at a Canvas redraw budget of ~20 ms the
        // motion reads as continuous rather than stepped.
        let timeDelta = Double(deltaY) * span / 2000
        let targetPlayhead = playhead.addingTimeInterval(timeDelta)
        // If the new playhead would leave the viewport, pan the viewport
        // so the playhead stays visible — otherwise the user would need
        // to stop scrolling, drag the minimap, then resume.
        if targetPlayhead < viewport.lowerBound {
            let shift = targetPlayhead.timeIntervalSince(viewport.lowerBound)
            setViewportRange(
                viewport.lowerBound.addingTimeInterval(shift)
                ... viewport.upperBound.addingTimeInterval(shift)
            )
        } else if targetPlayhead > viewport.upperBound {
            let shift = targetPlayhead.timeIntervalSince(viewport.upperBound)
            setViewportRange(
                viewport.lowerBound.addingTimeInterval(shift)
                ... viewport.upperBound.addingTimeInterval(shift)
            )
        }
        setPlayhead(targetPlayhead)
    }

    private func applyScrollZoom(deltaY: CGFloat) {
        let outerSpan = outerRange.upperBound
            .timeIntervalSince(outerRange.lowerBound)
        let minSpan = TimelineWorkspaceState.minimumViewportSpan
        guard outerSpan > minSpan else { return }
        let currentSpan = viewportRange.upperBound
            .timeIntervalSince(viewportRange.lowerBound)
        guard currentSpan > 0 else { return }
        let logRatio = log(minSpan / outerSpan)
        guard logRatio != 0 else { return }
        let currentFraction = log(currentSpan / outerSpan) / logRatio
        // Scroll up (positive deltaY) zooms in; scroll down zooms out.
        let newFraction = max(0, min(1, currentFraction + Double(deltaY) * 0.002))
        applyZoomFraction(newFraction, centeredOn: playhead)
    }
}
