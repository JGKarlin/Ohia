import Foundation
import Synchronization

/// Live drafting actions keyed by the draft and message they serve, so a
/// cancellation aimed at one Composer job cancels that job's model calls and
/// nothing else running on the shared engine.
public final class ComposerGenerationActions: Sendable {
    public static let shared = ComposerGenerationActions()

    private struct Entry: Sendable {
        let action: ComposerGenerationAction
        let draftID: UUID?
        let messageID: UUID?
    }
    private let entries = Mutex<[UUID: Entry]>([:])

    public init() {}

    public func register(_ action: ComposerGenerationAction, draftID: UUID?, messageID: UUID?) {
        entries.withLock { $0[action.id] = Entry(action: action, draftID: draftID, messageID: messageID) }
    }

    public func unregister(_ action: ComposerGenerationAction) {
        entries.withLock { $0.removeValue(forKey: action.id) }
    }

    /// Cancels every registered action serving one of the given drafts or
    /// messages. Returns false when nothing matched, so the caller can fall
    /// back to whatever coarser cancellation it has.
    @discardableResult
    public func cancel(draftIDs: Set<UUID>, messageIDs: Set<UUID>) -> Bool {
        let matched = entries.withLock { table in
            table.values.filter { entry in
                entry.draftID.map(draftIDs.contains) == true || entry.messageID.map(messageIDs.contains) == true
            }
        }
        for entry in matched { entry.action.cancel() }
        return !matched.isEmpty
    }

    public var activeCount: Int { entries.withLock { $0.count } }
}
