import Foundation
import CoreGraphics

// Projects is a SwiftUI/Canvas workspace. The normal Metal scene should not mount for `.projects`.

@MainActor
final class ProjectsHitTester {
    struct MessageHit {
        let rect: CGRect
        let messageID: UUID
        let projectKey: String
    }

    struct RowHit {
        let rect: CGRect
        let projectKey: String
    }

    struct LinkHit {
        let rect: CGRect
        let linkID: String
    }

    private var messageHits: [MessageHit] = []
    private var rowHits: [RowHit] = []
    private var linkHits: [LinkHit] = []

    func reset() {
        messageHits.removeAll(keepingCapacity: true)
        rowHits.removeAll(keepingCapacity: true)
        linkHits.removeAll(keepingCapacity: true)
    }

    func addMessage(rect: CGRect, messageID: UUID, projectKey: String) {
        messageHits.append(MessageHit(rect: rect.insetBy(dx: -4, dy: -4), messageID: messageID, projectKey: projectKey))
    }

    /// Replace a message's recorded rect in place. Canvas surfaces `reset()`
    /// and re-add every draw pass; SwiftUI card surfaces (the workroom feed)
    /// instead report per-card geometry changes, so the store must not grow
    /// an entry per layout pass.
    func updateMessage(rect: CGRect, messageID: UUID, projectKey: String) {
        messageHits.removeAll { $0.messageID == messageID }
        messageHits.append(MessageHit(rect: rect.insetBy(dx: -4, dy: -4), messageID: messageID, projectKey: projectKey))
    }

    /// Drop every message rect whose id is not in `ids`. Card surfaces call
    /// this on snapshot refresh so a deleted or re-homed message's vacated
    /// region can't keep hit-testing (a stale rect would right-click-menu a
    /// message that is no longer there, or anchor a comet to empty space).
    func retainMessages(_ ids: Set<UUID>) {
        messageHits.removeAll { !ids.contains($0.messageID) }
    }

    func addRow(rect: CGRect, projectKey: String) {
        rowHits.append(RowHit(rect: rect, projectKey: projectKey))
    }

    func addLink(rect: CGRect, linkID: String) {
        linkHits.append(LinkHit(rect: rect.insetBy(dx: -5, dy: -5), linkID: linkID))
    }

    func message(at point: CGPoint) -> MessageHit? {
        messageHits.last { $0.rect.contains(point) }
    }

    /// The most recent rect recorded for a message, in the owning surface's
    /// content coordinate space — a Canvas draw pass (Time view) or a
    /// per-card geometry report (workroom feed). `nil` only when the message
    /// is not in the current surface; scrolled-off content keeps its rect
    /// since both surfaces span the full content extent. Used by the
    /// send-to-Composer comet overlay to launch from the message's dot/card.
    func rect(forMessageID messageID: UUID) -> CGRect? {
        messageHits.last { $0.messageID == messageID }?.rect
    }

    func row(at point: CGPoint) -> RowHit? {
        rowHits.last { $0.rect.contains(point) }
    }

    func link(at point: CGPoint) -> LinkHit? {
        linkHits.last { $0.rect.contains(point) }
    }
}
