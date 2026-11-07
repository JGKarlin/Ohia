import Foundation

/// Pure helper that picks the "active" chapter given a sorted chapter list
/// and the current playhead. Video-chapter semantics: the largest `start ≤
/// playhead` wins. `end` is intentionally not consulted — once the playhead
/// passes a chapter marker, that chapter stays active until the next one
/// begins, even if the chapter's last message is days in the past.
///
/// Used by `TimelineWorkspaceState.activeChapter` (which then drives both
/// the multitrack expansion and the playhead resolver scope) and by the
/// chapter strip's "active label" highlight.
public enum TimelineActiveChapterResolver {

    /// Returns the active chapter via binary search on `chapters` (assumed
    /// sorted by `start` ascending). O(log n).
    /// Returns nil when `chapters` is empty OR when `playhead` is strictly
    /// before every chapter's `start` (the user is scrubbing into a region
    /// no chapter has started yet).
    public static func activeChapter(
        chapters: [TimelineChapter],
        playhead: Date
    ) -> TimelineChapter? {
        guard chapters.isEmpty == false else { return nil }
        // Binary-search for the rightmost chapter whose start <= playhead.
        var lo = 0
        var hi = chapters.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if chapters[mid].start <= playhead {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let index = lo - 1
        return index >= 0 ? chapters[index] : nil
    }

    /// Returns the chapter immediately after `current` (or the first
    /// chapter if `current` is nil). Used by `cmd-→` skip-next and the
    /// chapter strip's ⏭ button.
    public static func nextChapter(
        after current: TimelineChapter?,
        in chapters: [TimelineChapter]
    ) -> TimelineChapter? {
        guard chapters.isEmpty == false else { return nil }
        guard let current else { return chapters.first }
        guard let index = chapters.firstIndex(where: { $0.id == current.id }) else {
            return chapters.first
        }
        let next = index + 1
        return next < chapters.count ? chapters[next] : nil
    }

    /// Returns the chapter immediately before `current` (or nil if
    /// `current` is the first). Used by `cmd-←` skip-prev and the
    /// chapter strip's ⏮ button.
    public static func previousChapter(
        before current: TimelineChapter?,
        in chapters: [TimelineChapter]
    ) -> TimelineChapter? {
        guard let current else { return nil }
        guard let index = chapters.firstIndex(where: { $0.id == current.id }) else { return nil }
        let prev = index - 1
        return prev >= 0 ? chapters[prev] : nil
    }

    /// Step within the active chapter's message list; on overflow advance
    /// (or retreat) to the adjacent chapter's first (or last) message.
    /// Returns nil when there's no next message in any direction.
    public static func step(
        from currentMessageID: UUID?,
        direction: StepDirection,
        active: TimelineChapter?,
        chapters: [TimelineChapter]
    ) -> StepResult? {
        guard let active else { return nil }
        let messages = active.messageIDs
        guard let currentMessageID,
              let currentIndex = messages.firstIndex(of: currentMessageID) else {
            // No current — land on the first / last of the active chapter.
            switch direction {
            case .forward:
                return messages.first.map { StepResult(chapter: active, messageID: $0) }
            case .backward:
                return messages.last.map { StepResult(chapter: active, messageID: $0) }
            }
        }

        switch direction {
        case .forward:
            let nextIndex = currentIndex + 1
            if nextIndex < messages.count {
                return StepResult(chapter: active, messageID: messages[nextIndex])
            }
            guard let next = nextChapter(after: active, in: chapters),
                  let firstID = next.messageIDs.first else { return nil }
            return StepResult(chapter: next, messageID: firstID)
        case .backward:
            let prevIndex = currentIndex - 1
            if prevIndex >= 0 {
                return StepResult(chapter: active, messageID: messages[prevIndex])
            }
            guard let prev = previousChapter(before: active, in: chapters),
                  let lastID = prev.messageIDs.last else { return nil }
            return StepResult(chapter: prev, messageID: lastID)
        }
    }

    public enum StepDirection: Sendable { case forward, backward }

    public struct StepResult: Sendable, Equatable {
        public let chapter: TimelineChapter
        public let messageID: UUID
    }
}
