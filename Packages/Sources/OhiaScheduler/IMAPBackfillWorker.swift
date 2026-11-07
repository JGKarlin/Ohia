import Foundation
import SwiftData
import OhiaCore
import OhiaMail

@MainActor
public final class IMAPBackfillWorker {
    static let defaultBatchSize = 128

    struct Payload: Codable {
        let accountID: UUID
        let folderName: String
        let batchSize: Int
    }

    private let sessionManager: IMAPSessionManager

    public init(sessionManager: IMAPSessionManager) {
        self.sessionManager = sessionManager
    }

    public func run(job: Job, context: ModelContext) async throws {
        guard let payloadStr = job.payload,
              let data = payloadStr.data(using: .utf8) else {
            throw IMAPError.protocolViolation("imapBackfill job missing payload")
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        sessionManager.reportIMAPActivity(
            .backfilling,
            accountID: payload.accountID,
            folder: payload.folderName
        )
        do {
            guard let session = sessionManager.sessionForWork(accountID: payload.accountID) else {
                throw IMAPError.transient(underlying: IMAPError.notConnected)
            }
            let batchSize = try Self.effectiveBatchSize(
                requested: payload.batchSize,
                context: context
            )
            let result = try await session.backfillTick(
                folder: payload.folderName,
                batchSize: batchSize
            )
            if result.backfillComplete {
                sessionManager.markBackfillComplete(account: payload.accountID, folder: payload.folderName)
                try await sessionManager.reconcileOrphanThreadsBySubject()
            }
            sessionManager.completeIMAPActivity(
                accountID: payload.accountID,
                folder: payload.folderName
            )
        } catch {
            sessionManager.failIMAPActivity(
                accountID: payload.accountID,
                folder: payload.folderName,
                requiresAttention: Self.requiresAttention(for: error),
                cause: IMAPSessionManager.attentionCause(for: error)
            )
            throw error
        }
    }

    private static func requiresAttention(for error: Error) -> Bool {
        guard let imap = error as? IMAPError else { return false }
        switch imap {
        case .authFailed, .reauthRequired:
            return true
        default:
            return false
        }
    }

    static func effectiveBatchSize(requested: Int, context: ModelContext) throws -> Int {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.placedAt != nil
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).isEmpty ? 1 : requested
    }
}
