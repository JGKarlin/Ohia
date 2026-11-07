import Foundation

/// A discrete "chapter" in conversation mode: either a real `MessageThread`
/// (sequence of related messages) or a synthetic one-message chapter for an
/// orphan message (`message.thread == nil`).
///
/// Chapters are constructed during `TimelineLayoutEngine.snapshot(...)` step
/// 4 and stored on the snapshot. Filter intersection has already been
/// applied at construction time — `messageIDs` is the post-filter set, and
/// chapters with empty `messageIDs` are dropped from the list.
///
/// Active-chapter resolution is documented in `TimelineActiveChapterResolver`:
/// the largest `start ≤ playhead` wins (video-chapter semantics — once the
/// playhead passes a chapter marker, that chapter stays active until the
/// next marker). `end` is intentionally not consulted for the active rule.
public struct TimelineChapter: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case thread(threadID: UUID)
        case orphan(messageID: UUID)
    }

    public let id: UUID
    public let kind: Kind
    public let start: Date
    public let end: Date
    public let title: String
    public let messageIDs: [UUID]
    public let participantCount: Int
    public let primaryPurpose: TimelinePurposeState

    public nonisolated init(
        id: UUID,
        kind: Kind,
        start: Date,
        end: Date,
        title: String,
        messageIDs: [UUID],
        participantCount: Int,
        primaryPurpose: TimelinePurposeState
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.title = title
        self.messageIDs = messageIDs
        self.participantCount = participantCount
        self.primaryPurpose = primaryPurpose
    }

    public var isOrphan: Bool {
        if case .orphan = kind { return true }
        return false
    }
}
