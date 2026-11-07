import Foundation
import OhiaCore

struct TrashRestoreReference: Sendable {
    let messageID: UUID
    let accountID: UUID
    let rfcMessageIDHeader: String?
    let senderAddress: String
    let subject: String
    let date: Date?

    @MainActor
    init?(message: Message) {
        guard let accountID = message.accountID ?? message.account?.id else { return nil }
        self.messageID = message.id
        self.accountID = accountID
        self.rfcMessageIDHeader = normalizeMessageIDHeader(message.messageIdHeader)
        self.senderAddress = message.fromAddress
        self.subject = message.subject
        self.date = message.receivedAt ?? message.sentAt
    }
}

/// Stable per-window reference target for native message-action Undo/Redo.
/// `UndoManager` does not retain its target, so the owning SwiftUI scene keeps
/// this instance in `@State` for the full lifetime of the window.
@MainActor
final class OhiaMessageUndoTarget {
    typealias Operation = @MainActor () -> Bool
    typealias AsyncMessageOperation = @MainActor (Set<UUID>) async -> Set<UUID>

    func registerSuccessfulAction(
        on undoManager: UndoManager?,
        actionName: String,
        undo: @escaping Operation,
        redo: @escaping Operation
    ) {
        guard let undoManager else { return }
        register(
            on: undoManager,
            actionName: actionName,
            operation: undo,
            inverse: redo
        )
    }

    func registerSuccessfulAsyncAction(
        on undoManager: UndoManager?,
        actionName: String,
        messageIDs: Set<UUID>,
        undo: @escaping AsyncMessageOperation,
        redo: @escaping AsyncMessageOperation
    ) {
        guard let undoManager, !messageIDs.isEmpty else { return }
        registerAsync(
            on: undoManager,
            actionName: actionName,
            operation: undo,
            inverse: redo,
            sequence: AsyncUndoSequence(messageIDs: messageIDs)
        )
    }

    private func register(
        on undoManager: UndoManager,
        actionName: String,
        operation: @escaping Operation,
        inverse: @escaping Operation
    ) {
        undoManager.registerUndo(withTarget: self) { [weak undoManager] target in
            guard let undoManager, operation() else { return }
            target.register(
                on: undoManager,
                actionName: actionName,
                operation: inverse,
                inverse: operation
            )
        }
        undoManager.setActionName(actionName)
    }

    private func registerAsync(
        on undoManager: UndoManager,
        actionName: String,
        operation: @escaping AsyncMessageOperation,
        inverse: @escaping AsyncMessageOperation,
        sequence: AsyncUndoSequence
    ) {
        undoManager.registerUndo(withTarget: self) { [weak undoManager] target in
            guard let undoManager else { return }
            target.registerAsync(
                on: undoManager,
                actionName: actionName,
                operation: inverse,
                inverse: operation,
                sequence: sequence
            )
            sequence.enqueue(operation)
        }
        undoManager.setActionName(actionName)
    }
}

@MainActor
private final class AsyncUndoSequence {
    private var tail: Task<Set<UUID>, Never>

    init(messageIDs: Set<UUID>) {
        tail = Task { @MainActor in messageIDs }
    }

    func enqueue(_ operation: @escaping OhiaMessageUndoTarget.AsyncMessageOperation) {
        let predecessor = tail
        tail = Task { @MainActor in
            let messageIDs = await predecessor.value
            guard !messageIDs.isEmpty else { return [] }
            return await operation(messageIDs)
        }
    }
}
