import Foundation
import SwiftData
import OhiaCore
import OhiaMail

/// Restores a message recorded by a mailing-list ignore rule from the server's
/// Trash folder into Inbox. The restore exemption is committed before any
/// network work so the ingest-first promotion path cannot be caught by the
/// still-active rule.
@MainActor
public final class MailingListIgnoredMessageRestoreService {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case historyNotFound
        case localOnlyMessage
        case remoteTrashNotCompleted
        case missingMessageIDHeader
        case messageNotFoundInTrash
        case trashFolderUnavailable
        case accountMismatch

        public var errorDescription: String? {
            switch self {
            case .historyNotFound:
                "The ignored-message history is no longer available."
            case .localOnlyMessage:
                "This message was hidden locally and has no server Trash copy to restore."
            case .remoteTrashNotCompleted:
                "The server Trash move has not completed, so this message cannot be restored yet."
            case .missingMessageIDHeader:
                "This message has no Message-ID header, so its Trash copy cannot be identified safely."
            case .messageNotFoundInTrash:
                "The message could not be found in the account's Trash folder."
            case .trashFolderUnavailable:
                "The account's Trash folder could not be resolved."
            case .accountMismatch:
                "The restore connection does not belong to this message's account."
            }
        }
    }

    private let context: ModelContext
    private let bodySource: any WithheldPromotionBodySource
    private let coordinator: WithheldPromotionCoordinator

    public init(
        context: ModelContext,
        bodySource: any WithheldPromotionBodySource,
        ingester: any WithheldPromotionIngesting,
        moveQueue: any WithheldPromotionMoveQueueing
    ) {
        self.context = context
        self.bodySource = bodySource
        self.coordinator = WithheldPromotionCoordinator(
            bodySource: bodySource,
            ingester: ingester,
            moveQueue: moveQueue
        )
    }

    @discardableResult
    public func restore(
        historyID: UUID,
        config: WithheldFetchConfig
    ) async throws -> PromotionOutcome {
        guard let history = try fetchHistory(id: historyID) else {
            throw Error.historyNotFound
        }
        guard history.wasMovedToServerTrash else {
            throw Error.localOnlyMessage
        }
        guard history.isRemoteTrashCompleted else {
            throw Error.remoteTrashNotCompleted
        }
        guard config.accountID == history.accountID else {
            throw Error.accountMismatch
        }
        guard let messageID = history.messageIdHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
              !messageID.isEmpty else {
            throw Error.missingMessageIDHeader
        }

        history.restoreRequestedAt = .now
        history.restoredAt = nil
        history.lastRestoreError = nil
        try context.save()

        do {
            guard let resolved = try await bodySource.resolveUID(
                messageID: messageID,
                role: .trash,
                config: config
            ) else {
                throw Error.messageNotFoundInTrash
            }
            guard let folderPath = resolved.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !folderPath.isEmpty else {
                throw Error.trashFolderUnavailable
            }

            let outcome = try await coordinator.promote(
                WithheldPromotionRequest(
                    accountID: history.accountID,
                    role: .trash,
                    folderPath: folderPath,
                    uid: resolved.uid,
                    uidValidity: resolved.uidValidity,
                    messageID: messageID
                ),
                config: config
            )
            history.restoredAt = .now
            history.lastRestoreError = nil
            try context.save()
            return outcome
        } catch {
            history.lastRestoreError = error.localizedDescription
            try? context.save()
            throw error
        }
    }

    private func fetchHistory(id: UUID) throws -> MailingListIgnoredMessage? {
        var descriptor = FetchDescriptor<MailingListIgnoredMessage>(
            predicate: #Predicate<MailingListIgnoredMessage> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
