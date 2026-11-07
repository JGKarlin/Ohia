import AppKit
import Foundation
import Observation
import OhiaCore
import OhiaML
import SwiftUI

// Front Page is a SwiftUI reading workspace. The Metal scene does not mount
// for `.frontPage` (`usesMetalScene` returns false), mirroring Projects.

/// Observable UI state for the Front Page lens. Holds the current snapshot,
/// the in-place reader takeover target, the set of expanded Purpose
/// sections, the hovered article, and the unread-only display toggle.
@Observable @MainActor
final class FrontPageWorkspaceState {
    private struct FocusedArticleReadOverride {
        let isRead: Bool
        let readAt: Date?
    }

    /// Reader-scoped optimistic reply / confirmation state for the focused
    /// article. Replied and confirmed messages leave the Front Page feed, so the
    /// post-action snapshot rebuild drops the article and the open reader resolves
    /// only its stale focus-time copy; this override is applied on top of whatever
    /// base `focusedArticle` resolves so the reader's status chip updates
    /// immediately and stays correct across the rebuild. It never touches
    /// `currentSnapshot` or the card gestures.
    private struct FocusedArticleAttentionOverride {
        let isActionable: Bool
        let requiresConfirmation: Bool
        let isReplied: Bool
        let isConfirmed: Bool
    }

    /// Reader-scoped optimistic classification assignment for the focused article.
    /// The reader's classification pulldown persists asynchronously (the snapshot
    /// rebuilds off a notification), so without this the masthead chips and the
    /// popover checkmarks would lag a toggle by a full rebuild. Applied on top
    /// of whatever base `focusedArticle` resolves; the authoritative rebuild
    /// supersedes it. Never touches `currentSnapshot` or the card gestures.
    private struct FocusedArticleClassificationOverride {
        let classification: MailClassification?
        let customCategoryKeys: Set<String>
    }

    var currentSnapshot: FrontPageSnapshot? {
        didSet { reconcileRetiredDeparturesWithCurrentSnapshot() }
    }
    /// When non-nil, the page region swaps to the focused reader for this
    /// article (an in-place takeover — **not** the global lock session).
    var focusedArticleID: UUID?
    private var focusedArticleSnapshot: FrontPageArticle?
    private var focusedArticleReadOverride: FocusedArticleReadOverride?
    private var focusedArticleAttentionOverride: FocusedArticleAttentionOverride?
    private var focusedArticleClassificationOverride: FocusedArticleClassificationOverride?
    /// Search-result evidence to mark inside the focused reader. The host ID
    /// is the article that owns the reader; the highlight's own message ID may
    /// be a sent reply rendered in that article's reply tree.
    var focusedArticleSearchHighlight: SearchMatchHighlight?
    private var focusedArticleSearchHighlightHostID: UUID?
    /// Purpose/non-Purpose sections the user has expanded to reveal overflow.
    var expandedPurposePresentations: Set<FrontPagePurposePresentation> = []
    /// The thread package currently opened in place, keyed by its representative
    /// article id. When set, that package's slot expands into its member cards
    /// (newest → oldest) and every other card on the page dims. `nil` when no
    /// package is open. At most one is open at a time — opening is a focused,
    /// in-place expansion, not a reader takeover.
    var openThreadID: UUID?
    var hoveredArticleID: UUID?
    /// Selected article cards. Mirrors `ProjectsWorkspaceState.selectedProjectKeys`:
    /// a single-element set is the canonical "one card selected" case; a
    /// multi-element set unlocks the bulk right-click menu and the right
    /// column's bulk action toggles. A plain click selects (replacing), ⌘-click
    /// toggles, ⇧-click extends a range — double-click opens the reader.
    var selectedArticleIDs: Set<UUID> = []
    /// Anchor for ⇧-click range extension. Set on every replace / toggle that
    /// leaves the clicked card selected, cleared with the selection.
    var selectionAnchorID: UUID?
    /// Display toggle: when on, only unread mail is admitted to the page.
    /// Folded into the snapshot signature so flipping it triggers a recompute.
    var unreadOnly: Bool = false

    /// Monotonic counter bumped whenever a display toggle (currently
    /// `unreadOnly`) changes, so the view's fingerprint observer fires a
    /// refresh. Mirrors `ProjectsWorkspaceState.actionRevision`.
    var displayRevision: Int = 0

    /// Transient per-message action-response gestures (the masking animations).
    /// Begun when an action is dispatched and cleared once the rebuilt snapshot
    /// reflects the change. Owned here so both the card cluster and the right
    /// control column drive — and the cards render — the same gestures.
    let statusGestureCoordinator = MessageStatusGestureCoordinator()
    @ObservationIgnored
    private let removeArrivalBadgesForDeletedMessages: @MainActor (Set<String>) -> Void
    @ObservationIgnored
    private let sleepForDepartureRetirement: @MainActor (Duration) async throws -> Void

    /// Messages whose successful departing action has finished its visible exit
    /// motion but whose stale snapshot row has not disappeared yet. The layout
    /// excludes these ids so the original card can never be exposed again when
    /// the gesture coordinator reaches its safety expiry before a slow refresh.
    private(set) var retiredDepartingArticleIDs: Set<UUID> = []
    @ObservationIgnored
    private var departureRetirementTasks: [UUID: Task<Void, Never>] = [:]

    /// The focused article currently playing its reader-departure Collapse. While
    /// set, the reader stays mounted — content hidden, chrome faded — so the
    /// email sheet crumples in place instead of the reader blinking away, and the
    /// scheduled task returns to the grid once the animation lands. A grid-card
    /// crumple needs none of this reader ownership; its local retirement or the
    /// snapshot rebuild tears the card down. Drives `FrontPageWorkspaceView`'s
    /// departing fade / overlay swap.
    private(set) var departingFocusedArticleID: UUID?
    @ObservationIgnored
    private var focusedReaderDepartureTask: Task<Void, Never>?
    /// When the in-flight `focusedReaderDepartureTask` is scheduled to dismiss
    /// the reader. Lets a second departing action on the same still-open id
    /// (e.g. delete arriving on a message already mid-resolve) extend the wait
    /// when its own hold runs later than what's already scheduled, instead of
    /// the idempotency guard silently stranding the shorter one in place.
    @ObservationIgnored
    private var focusedReaderDepartureDeadline: Date?

    /// Short tail added past a departing gesture's own `floor` (read from the
    /// live gesture at the call site, since delete's Black hole floor and
    /// resolve's Protostar floor — `blackHoleFloor` / `protostarFloor` — now
    /// each run longer than ignore / send-to-Composer's shared
    /// `departingFloor`) so the core-bounce flash and shockwave ring read
    /// before the grid returns, instead of cutting the reader away the
    /// instant the motion technically completes.
    private static let focusedReaderDepartureTail: Double = 0.25

    init(
        removeArrivalBadgesForDeletedMessages: @escaping @MainActor (Set<String>) -> Void = {
            NewMailArrivalLedger.shared.removeArrivals(messageIds: $0)
        },
        sleepForDepartureRetirement: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.removeArrivalBadgesForDeletedMessages = removeArrivalBadgesForDeletedMessages
        self.sleepForDepartureRetirement = sleepForDepartureRetirement
    }

    func focusArticle(_ article: FrontPageArticle, searchHighlight: SearchMatchHighlight? = nil) {
        cancelFocusedReaderDeparture()
        focusedArticleID = article.id
        focusedArticleSnapshot = article
        focusedArticleReadOverride = nil
        focusedArticleAttentionOverride = nil
        focusedArticleClassificationOverride = nil
        focusedArticleSearchHighlight = searchHighlight
        focusedArticleSearchHighlightHostID = searchHighlight == nil ? nil : article.id
        // Commit the focused surface before retiring its badge. Badge
        // observers must never be able to delay the navigation state change.
        NewMailArrivalLedger.shared.markVisited(messageId: article.messageIdString)
    }

    func focusArticle(_ id: UUID, searchHighlight: SearchMatchHighlight? = nil) {
        guard let article = currentSnapshot?.article(id: id) else {
            cancelFocusedReaderDeparture()
            focusedArticleID = id
            focusedArticleSnapshot = nil
            focusedArticleReadOverride = nil
            focusedArticleAttentionOverride = nil
            focusedArticleClassificationOverride = nil
            focusedArticleSearchHighlight = searchHighlight
            focusedArticleSearchHighlightHostID = searchHighlight == nil ? nil : id
            return
        }
        focusArticle(article, searchHighlight: searchHighlight)
    }

    @discardableResult
    func focusArticleMatchingMessage(_ id: UUID, searchHighlight: SearchMatchHighlight? = nil) -> Bool {
        guard currentSnapshot?.article(id: id) != nil else { return false }
        focusArticle(id, searchHighlight: searchHighlight)
        return true
    }

    /// Route a message-level navigation request into the Front Page reader.
    /// This keeps lens-scoped actions, including the new-star badge, inside the
    /// reading workspace instead of falling through to the global Metal lock.
    @discardableResult
    func openArticleForMessage(_ messageID: UUID, in snapshot: FrontPageSnapshot) -> Bool {
        guard let article = snapshot.article(id: messageID) else { return false }
        focusArticle(article)
        return true
    }

    /// Opens the first rendered article from a queue of message-level
    /// candidates. Hidden or filtered candidates are skipped so one
    /// non-renderable new-star item cannot block later visible mail.
    @discardableResult
    func openFirstArticleForMessage(
        _ messageIDs: [UUID],
        in snapshot: FrontPageSnapshot
    ) -> (opened: UUID, skipped: [UUID])? {
        var skipped: [UUID] = []
        for messageID in messageIDs {
            guard let article = snapshot.article(id: messageID) else {
                skipped.append(messageID)
                continue
            }
            focusArticle(article)
            return (opened: messageID, skipped: skipped)
        }
        return nil
    }

    @discardableResult
    func focusArticleDisplayingSearchMatch(
        _ articleID: UUID,
        searchHighlight: SearchMatchHighlight? = nil
    ) -> Bool {
        guard currentSnapshot?.article(id: articleID) != nil else { return false }
        focusArticle(articleID, searchHighlight: searchHighlight)
        return true
    }

    func dismissReader() {
        cancelFocusedReaderDeparture()
        focusedArticleID = nil
        focusedArticleSnapshot = nil
        focusedArticleReadOverride = nil
        focusedArticleAttentionOverride = nil
        focusedArticleClassificationOverride = nil
        focusedArticleSearchHighlight = nil
        focusedArticleSearchHighlightHostID = nil
    }

    /// Clears a transient loading reader only when it still belongs to the
    /// failed hydration request. A newer focus or an article that resolved
    /// through a snapshot/transient value remains untouched.
    @discardableResult
    func dismissUnresolvedArticleFocus(ifMatching articleID: UUID) -> Bool {
        guard focusedArticleID == articleID, focusedArticle == nil else {
            return false
        }
        dismissReader()
        return true
    }

    func applyReadStateToFocusedArticle(messageID: UUID, isRead: Bool) {
        guard focusedArticleID == messageID else { return }
        let article = currentSnapshot?.article(id: messageID) ?? focusedArticleSnapshot
        let overrideReadAt: Date?
        if isRead {
            if let focusedArticleReadOverride {
                overrideReadAt = focusedArticleReadOverride.isRead
                    ? (focusedArticleReadOverride.readAt ?? Date())
                    : Date()
            } else {
                overrideReadAt = article?.readAt ?? Date()
            }
        } else {
            overrideReadAt = nil
        }
        let override = FocusedArticleReadOverride(
            isRead: isRead,
            readAt: overrideReadAt
        )
        focusedArticleReadOverride = override
        focusedArticleSnapshot = article?.withReadState(isRead: isRead, readAt: override.readAt)
    }

    /// Optimistically reflect a reply / confirmation action on the focused reader
    /// article. The reader stays open on a message the rebuilt snapshot will drop
    /// from the feed (replied / confirmed mail leaves the page), so without this
    /// the reader's status chip is pinned to the pre-action obligation from its
    /// stale focus-time copy. The `true` direction sets the resolved post-action
    /// state — mirroring `ProjectLensActionRepository`'s revoke rules so it equals
    /// what the rebuild computes — while un-marking clears the override and lets
    /// the re-admitted snapshot copy show through. Reader-scoped: never touches
    /// `currentSnapshot` or the card gestures.
    func applyAttentionAction(_ action: FrontPageReaderAttentionAction, messageID: UUID) {
        guard focusedArticleID == messageID, let current = focusedArticle else { return }
        switch action {
        case .replied(true):
            focusedArticleAttentionOverride = FocusedArticleAttentionOverride(
                isActionable: false,
                requiresConfirmation: false,
                isReplied: true,
                isConfirmed: current.isConfirmed
            )
        case .confirmed(true):
            focusedArticleAttentionOverride = FocusedArticleAttentionOverride(
                isActionable: current.isActionable,
                requiresConfirmation: false,
                isReplied: current.isReplied,
                isConfirmed: true
            )
        case .replyNeeded(true):
            focusedArticleAttentionOverride = FocusedArticleAttentionOverride(
                isActionable: true,
                requiresConfirmation: false,
                isReplied: false,
                isConfirmed: current.isConfirmed
            )
        case .confirmationNeeded(true):
            focusedArticleAttentionOverride = FocusedArticleAttentionOverride(
                isActionable: false,
                requiresConfirmation: true,
                isReplied: false,
                isConfirmed: false
            )
        case .replied(false), .confirmed(false), .replyNeeded(false), .confirmationNeeded(false):
            // Un-marking re-admits the article to the feed; defer to the
            // authoritative rebuild rather than pin a stale optimistic state.
            // The classification override is an independent channel and must
            // not be touched here; clearing it would wipe a pending manual edit.
            focusedArticleAttentionOverride = nil
        }
    }

    /// Optimistically reflect a flag toggle in the rendered snapshot so the card
    /// cluster and the focused reader show the new `\Flagged` state immediately,
    /// without waiting on the async snapshot rebuild. Mirrors the read-state
    /// optimism in `applyReadStateToFocusedArticle`; the authoritative rebuild
    /// overwrites this shortly with the persisted value.
    ///
    /// Bumping `builtAt` is deliberate: it is the workspace's reconcile trigger
    /// (`FrontPageWorkspaceView.onChange(currentSnapshot?.builtAt)`), so the
    /// in-flight flag gesture resolves against the now-confirmed state on the
    /// next pass instead of looping until the gesture coordinator's safety
    /// expiry. The flag mutation persists synchronously, so this optimistic copy
    /// never disagrees with the store for more than one rebuild.
    func applyFlagState(messageIDs: Set<UUID>, isFlagged: Bool) {
        guard !messageIDs.isEmpty else { return }
        if let snapshot = currentSnapshot {
            var articles = snapshot.articlesByID
            var changed = false
            for id in messageIDs {
                guard let article = articles[id], article.isFlagged != isFlagged else { continue }
                articles[id] = article.withFlagState(isFlagged)
                changed = true
            }
            if changed {
                currentSnapshot = FrontPageSnapshot(
                    signature: snapshot.signature,
                    builtAt: Date(),
                    composition: snapshot.composition,
                    articlesByID: articles,
                    messageFilterRows: snapshot.messageFilterRows
                )
            }
        }
        // Keep the reader's cached fallback in sync for a focused article that is
        // not present in the current snapshot (e.g. filtered out of the page).
        if let focusedArticleID,
           messageIDs.contains(focusedArticleID),
           let focused = focusedArticleSnapshot,
           focused.isFlagged != isFlagged {
            focusedArticleSnapshot = focused.withFlagState(isFlagged)
        }
    }

    /// Optimistically reflect a classification-pulldown edit on the focused reader
    /// article and its top-level card so both surfaces update the instant the user
    /// toggles a row, without waiting on the async snapshot rebuild that the
    /// persisted edit triggers. Mirrors `applyFlagState`; the authoritative
    /// rebuild overwrites this shortly with the persisted value.
    func applyClassificationState(
        messageID: UUID,
        classification: MailClassification?,
        customCategoryKeys: Set<String>
    ) {
        guard focusedArticleID == messageID else { return }
        focusedArticleClassificationOverride = FocusedArticleClassificationOverride(
            classification: classification,
            customCategoryKeys: customCategoryKeys
        )
        if let snapshot = currentSnapshot,
           let article = snapshot.articlesByID[messageID] {
            var articles = snapshot.articlesByID
            articles[messageID] = article.withClassificationState(
                classification: classification,
                customCategoryKeys: customCategoryKeys
            )
            currentSnapshot = FrontPageSnapshot(
                signature: snapshot.signature,
                builtAt: Date(),
                composition: snapshot.composition,
                articlesByID: articles,
                messageFilterRows: snapshot.messageFilterRows
            )
        }
        // Keep the reader's cached fallback in sync when the focused article is
        // absent from the current snapshot (e.g. filtered out of the page).
        if let focused = focusedArticleSnapshot {
            focusedArticleSnapshot = focused.withClassificationState(
                classification: classification,
                customCategoryKeys: customCategoryKeys
            )
        }
    }

    func toggleExpanded(_ presentation: FrontPagePurposePresentation) {
        if expandedPurposePresentations.contains(presentation) {
            expandedPurposePresentations.remove(presentation)
        } else {
            expandedPurposePresentations.insert(presentation)
        }
    }

    func isExpanded(_ presentation: FrontPagePurposePresentation) -> Bool {
        expandedPurposePresentations.contains(presentation)
    }

    // MARK: - Thread packages

    /// Open a thread package in place. Clears the card selection — the open
    /// package is the focus now.
    func openThread(_ representativeID: UUID) {
        clearSelection()
        openThreadID = representativeID
    }

    func closeThread() {
        openThreadID = nil
    }

    func isThreadOpen(_ representativeID: UUID) -> Bool {
        openThreadID == representativeID
    }

    func setUnreadOnly(_ value: Bool) {
        guard value != unreadOnly else { return }
        unreadOnly = value
        displayRevision &+= 1
    }

    // MARK: - Multi-selection

    func isSelected(_ id: UUID) -> Bool {
        selectedArticleIDs.contains(id)
    }

    /// Replace the selection with a single card (or clear it when `nil`).
    func selectOnly(_ id: UUID?) {
        if let id {
            selectedArticleIDs = [id]
            selectionAnchorID = id
        } else {
            clearSelection()
        }
    }

    /// ⌘-click: toggle a card's membership. The anchor follows the clicked
    /// card whenever the toggle leaves it selected so a subsequent ⇧-click
    /// extends from the last-touched card.
    func toggleSelection(_ id: UUID) {
        if selectedArticleIDs.contains(id) {
            selectedArticleIDs.remove(id)
            if selectionAnchorID == id {
                selectionAnchorID = selectedArticleIDs.first
            }
        } else {
            selectedArticleIDs.insert(id)
            selectionAnchorID = id
        }
    }

    /// ⇧-click: replace the selection with the inclusive range from the anchor
    /// to `id`, ordered by `orderedIDs` (the page's visible card order). A
    /// missing / stale anchor collapses to a plain selection of `id`.
    func extendSelection(to id: UUID, in orderedIDs: [UUID]) {
        guard let anchor = selectionAnchorID,
              let anchorIndex = orderedIDs.firstIndex(of: anchor),
              let targetIndex = orderedIDs.firstIndex(of: id) else {
            selectOnly(id)
            return
        }
        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        selectedArticleIDs = Set(orderedIDs[lower...upper])
    }

    func clearSelection() {
        selectedArticleIDs = []
        selectionAnchorID = nil
    }

    /// A deleted message must stop owning any Front Page transient UI. The
    /// focused reader keeps a cached article snapshot so unread-only refreshes
    /// do not eject the user mid-read; explicit deletion is different and must
    /// clear that cache immediately.
    func removeDeletedArticles(_ deletedIDs: Set<UUID>) {
        guard !deletedIDs.isEmpty else { return }
        removeArrivalBadgesForDeletedMessages(Set(deletedIDs.map(\.uuidString)))
        removeArticlesFromTransientState(deletedIDs)
    }

    /// A resolved article leaves the Front Page feed just like a deleted one,
    /// but without implying any mailbox mutation. Clear local reader/selection
    /// ownership immediately while the saved action rebuilds the snapshot.
    func removeResolvedArticles(_ resolvedIDs: Set<UUID>) {
        guard !resolvedIDs.isEmpty else { return }
        removeArticlesFromTransientState(resolvedIDs)
    }

    /// A message sent to the Composer leaves the feed like a resolved one (no
    /// mailbox mutation). When the reader is open on it, this lets the open sheet
    /// play the launch Comet in place — the same deferred-dismissal path the
    /// grid card's comet rides — and return to the grid once it lands. A no-op
    /// for grid sends (the reader isn't focused on the id), whose card retires
    /// locally as soon as the exit motion lands. The `.sentToComposer` gesture must
    /// already be begun on the coordinator before this runs, so the focused-reader
    /// departure gate (`usesDepartingOverlay`) sees it.
    func removeSentToComposerArticles(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        removeArticlesFromTransientState(ids)
    }

    /// True once the card's departing animation has become the final visible
    /// representation of the message. A collapsed thread package retires with
    /// any member that drove its package-wide exit animation.
    func hidesCardAfterDeparture(messageID: UUID, threadMemberIDs: [UUID] = []) -> Bool {
        retiredDepartingArticleIDs.contains(messageID)
            || threadMemberIDs.contains(where: retiredDepartingArticleIDs.contains)
    }

    /// Test/coordination seam that awaits the actual scheduled retirement task
    /// instead of requiring callers to guess how long the animation takes.
    func waitForDepartureRetirement(of messageID: UUID) async {
        await departureRetirementTasks[messageID]?.value
    }

    private func removeArticlesFromTransientState(_ ids: Set<UUID>) {
        scheduleDepartureRetirement(for: ids)
        if let focusedArticleID, ids.contains(focusedArticleID) {
            if let gesture = statusGestureCoordinator.gesture(for: focusedArticleID), gesture.action.usesDepartingOverlay {
                // A resolve / delete on the open reader plays the Collapse in
                // place — the email sheet crumples while the chrome fades — and
                // returns to the grid once it lands, instead of blinking away.
                // The hold is derived from this gesture's own floor (not a
                // fixed constant) since delete's Black hole plays longer than
                // resolve / ignore / send-to-Composer.
                beginFocusedReaderDeparture(focusedArticleID, hold: gesture.floor + Self.focusedReaderDepartureTail)
            } else {
                dismissReader()
            }
        }
        selectedArticleIDs.subtract(ids)
        if let selectionAnchorID, ids.contains(selectionAnchorID) {
            self.selectionAnchorID = nil
        }
        if selectedArticleIDs.isEmpty {
            selectionAnchorID = nil
        }
    }

    /// Retire a successfully departed card when its overlay reaches the end of
    /// the motion floor. Until then the stale snapshot card remains mounted so
    /// the Collapse/Cinder/Comet itself can play; afterwards local retirement
    /// owns the gap until the authoritative snapshot drops the message.
    private func scheduleDepartureRetirement(for ids: Set<UUID>, now: Date = .now) {
        for id in ids {
            guard let gesture = statusGestureCoordinator.gesture(for: id),
                  gesture.action.usesDepartingOverlay else {
                continue
            }
            departureRetirementTasks[id]?.cancel()
            let startedAt = gesture.start
            let remainingFloor = max(0, gesture.floor - now.timeIntervalSince(startedAt))
            if remainingFloor == 0, gesture.composerDeparture == nil {
                // Ignore performs its rule creation and evidence move
                // synchronously before reporting success. If that work outlasts
                // the gesture safety window, retire now while the successful
                // gesture is still known rather than racing its queued expiry.
                if currentSnapshot?.article(id: id) != nil {
                    retiredDepartingArticleIDs.insert(id)
                }
                departureRetirementTasks[id] = nil
                continue
            }
            let departure = gesture.composerDeparture
            let presentationLease = departure?.retainPresentation()
            departureRetirementTasks[id] = Task { @MainActor [weak self] in
                var completesWithTransition = false
                defer {
                    if !completesWithTransition, let presentationLease {
                        departure?.releasePresentation(presentationLease)
                    }
                }
                guard let self else { return }
                do {
                    if let departure {
                        try await departure.waitForMotion()
                    } else {
                        try await self.sleepForDepartureRetirement(.seconds(remainingFloor))
                    }
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.statusGestureCoordinator.gesture(for: id)?.start == startedAt,
                      self.currentSnapshot?.article(id: id) != nil else {
                    self.departureRetirementTasks[id] = nil
                    return
                }
                if let departure, let presentationLease {
                    completesWithTransition = true
                    withAnimation(.easeOut(duration: 0.28), completionCriteria: .removed) {
                        _ = self.retiredDepartingArticleIDs.insert(id)
                    } completion: {
                        departure.releasePresentation(presentationLease)
                    }
                } else {
                    self.retiredDepartingArticleIDs.insert(id)
                }
                self.departureRetirementTasks[id] = nil
            }
        }
    }

    /// Once a refreshed snapshot no longer carries a retired message, its local
    /// tombstone has done its job and can be released. A snapshot that wins the
    /// race before the animation completes also cancels the pending retirement.
    private func reconcileRetiredDeparturesWithCurrentSnapshot() {
        guard let currentSnapshot else { return }
        let liveArticleIDs = Set(currentSnapshot.articlesByID.keys)
        retiredDepartingArticleIDs.formIntersection(liveArticleIDs)
        let completedBeforeRetirement = departureRetirementTasks.keys.filter {
            liveArticleIDs.contains($0) == false
        }
        for id in completedBeforeRetirement {
            departureRetirementTasks[id]?.cancel()
            departureRetirementTasks[id] = nil
        }
    }

    private func clearDepartureRetirements() {
        for task in departureRetirementTasks.values {
            task.cancel()
        }
        departureRetirementTasks.removeAll()
        retiredDepartingArticleIDs.removeAll()
    }

    /// Hold the focused reader open through a departing (resolve / delete)
    /// Collapse, then dismiss back to the grid once the animation lands.
    /// `hold` is the acting gesture's own floor plus `focusedReaderDepartureTail`
    /// (computed at the call site from the live gesture), since delete's Black
    /// hole floor and resolve's Protostar floor each run longer than ignore /
    /// send-to-Composer's shared `departingFloor`. Idempotent for a given id — a re-entrant transient
    /// sweep with the SAME hold never restarts the timer mid-crumple — but a
    /// second departing action on the same still-open id whose own `hold` runs
    /// LATER than what's already scheduled (e.g. delete's longer collapse
    /// landing on a message already mid-resolve) reschedules to the later
    /// deadline, so the shorter hold can never strand the longer animation.
    private func beginFocusedReaderDeparture(_ id: UUID, hold: Double) {
        guard focusedArticleID == id else { return }
        let deadline = Date().addingTimeInterval(hold)
        if departingFocusedArticleID == id,
           let focusedReaderDepartureDeadline,
           deadline <= focusedReaderDepartureDeadline {
            return
        }
        departingFocusedArticleID = id
        focusedReaderDepartureDeadline = deadline
        focusedReaderDepartureTask?.cancel()
        let departure = statusGestureCoordinator.gesture(for: id)?.composerDeparture
        let presentationLease = departure?.retainPresentation()
        focusedReaderDepartureTask = Task { @MainActor [weak self] in
            var completesWithTransition = false
            defer {
                if !completesWithTransition, let presentationLease {
                    departure?.releasePresentation(presentationLease)
                }
            }
            do {
                if let departure {
                    try await departure.waitForMotion()
                    try await Task.sleep(for: .seconds(max(0, hold - departure.floor)))
                } else {
                    try await Task.sleep(for: .seconds(hold))
                }
            } catch { return }
            guard let self, !Task.isCancelled, self.departingFocusedArticleID == id else { return }
            // Cross-fade back to the grid rather than cutting: by the hold's end
            // the crumple has played to its bounce and only the humming core
            // remains, so an instant unmount would pop that core off-screen.
            completesWithTransition = true
            withAnimation(.easeOut(duration: 0.25), completionCriteria: .removed) {
                self.dismissReader()
            } completion: {
                if let presentationLease { departure?.releasePresentation(presentationLease) }
            }
        }
    }

    /// Cancel any in-flight reader-departure animation and clear its marker.
    /// Called by every reader-teardown path so the deferred dismissal can never
    /// fire against a freshly-opened or already-closed reader.
    private func cancelFocusedReaderDeparture() {
        focusedReaderDepartureTask?.cancel()
        focusedReaderDepartureTask = nil
        departingFocusedArticleID = nil
        focusedReaderDepartureDeadline = nil
    }

    /// Modifier-aware click selection mirroring the Projects time view: ⇧
    /// extends, ⌘ toggles, a plain click on the sole selected card clears, and
    /// any other plain click replaces the selection.
    func handleSelectionClick(
        id: UUID,
        modifiers: NSEvent.ModifierFlags,
        orderedIDs: [UUID]
    ) {
        if modifiers.contains(.shift) {
            extendSelection(to: id, in: orderedIDs)
        } else if modifiers.contains(.command) {
            toggleSelection(id)
            // `toggleSelection`'s removal path falls back to `Set.first` for the
            // anchor, which is unordered. When the click *removed* a card,
            // re-pin the anchor deterministically to the still-selected card
            // latest in visible order so a following ⇧-click extends sensibly
            // (an add leaves the just-clicked card as the anchor, which is
            // already correct).
            if !selectedArticleIDs.contains(id) {
                selectionAnchorID = orderedIDs.last(where: { selectedArticleIDs.contains($0) })
            }
        } else if selectedArticleIDs == [id] {
            clearSelection()
        } else {
            selectOnly(id)
        }
    }

    /// The currently selected articles, resolved against the live snapshot.
    /// Drives the right column's bulk toggles and the bulk right-click menu.
    var selectedArticles: [FrontPageArticle] {
        guard let currentSnapshot, !selectedArticleIDs.isEmpty else { return [] }
        return selectedArticleIDs.compactMap { currentSnapshot.article(id: $0) }
    }

    /// Reset transient UI when the filter scope changes (the snapshot is about
    /// to be rebuilt against a different scope).
    func clearForFilterChange() {
        cancelFocusedReaderDeparture()
        clearDepartureRetirements()
        focusedArticleID = nil
        focusedArticleSnapshot = nil
        focusedArticleReadOverride = nil
        focusedArticleAttentionOverride = nil
        focusedArticleClassificationOverride = nil
        focusedArticleSearchHighlight = nil
        focusedArticleSearchHighlightHostID = nil
        expandedPurposePresentations = []
        openThreadID = nil
        hoveredArticleID = nil
        clearSelection()
        statusGestureCoordinator.clearAll()
    }

    /// ESC ladder, most-transient first:
    ///   1. dismiss the focused reader,
    ///   2. close an open thread package,
    ///   3. clear the card selection,
    ///   4. collapse any expanded Purpose sections,
    ///   5. otherwise ignored.
    /// Returns true when the key was consumed.
    func handleEscape() -> Bool {
        if focusedArticleID != nil {
            cancelFocusedReaderDeparture()
            focusedArticleID = nil
            focusedArticleSnapshot = nil
            focusedArticleReadOverride = nil
            focusedArticleAttentionOverride = nil
            focusedArticleClassificationOverride = nil
            focusedArticleSearchHighlight = nil
            focusedArticleSearchHighlightHostID = nil
            return true
        }
        if openThreadID != nil {
            openThreadID = nil
            return true
        }
        if selectedArticleIDs.isEmpty == false {
            clearSelection()
            return true
        }
        if expandedPurposePresentations.isEmpty == false {
            expandedPurposePresentations = []
            return true
        }
        return false
    }

    var focusedArticle: FrontPageArticle? {
        guard let focusedArticleID else { return nil }
        let base = currentSnapshot?.article(id: focusedArticleID) ?? focusedArticleSnapshot
        guard var article = base else { return nil }
        if let focusedArticleReadOverride {
            article = article.withReadState(
                isRead: focusedArticleReadOverride.isRead,
                readAt: focusedArticleReadOverride.readAt
            )
        }
        if let focusedArticleAttentionOverride {
            article = article.withAttentionState(
                isActionable: focusedArticleAttentionOverride.isActionable,
                requiresConfirmation: focusedArticleAttentionOverride.requiresConfirmation,
                isReplied: focusedArticleAttentionOverride.isReplied,
                isConfirmed: focusedArticleAttentionOverride.isConfirmed
            )
        }
        if let focusedArticleClassificationOverride {
            article = article.withClassificationState(
                classification: focusedArticleClassificationOverride.classification,
                customCategoryKeys: focusedArticleClassificationOverride.customCategoryKeys
            )
        }
        return article
    }

    var focusedReaderSearchHighlight: SearchMatchHighlight? {
        guard let focusedArticleID else { return nil }
        guard focusedArticleSearchHighlightHostID == focusedArticleID else { return nil }
        return focusedArticleSearchHighlight
    }
}

/// Reader-scoped reply / confirmation intents that drive the focused article's
/// optimistic attention override (`FrontPageWorkspaceState.applyAttentionAction`).
/// Each case carries the action's boolean value: the `true` direction pins the
/// resolved post-action state and the `false` direction drops the override so the
/// rebuilt snapshot reconciles.
enum FrontPageReaderAttentionAction: Equatable, Sendable {
    case replied(Bool)
    case confirmed(Bool)
    case replyNeeded(Bool)
    case confirmationNeeded(Bool)
}
