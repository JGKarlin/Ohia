import Foundation
import SwiftData
import OhiaCore
import OhiaMail

@MainActor
public final class IMAPPollFolderWorker {
    static let defaultBatchSize = 50

    struct Payload: Codable {
        let accountID: UUID
        let folderName: String
        var batchSize: Int? = nil
        // Decode compatibility for existing one-shot gap-check rows. New work
        // is scheduled from ordinary IMAP folder state.
        var gapCheck: Bool? = nil
    }

    private let sessionManager: IMAPSessionManager

    public init(sessionManager: IMAPSessionManager) {
        self.sessionManager = sessionManager
    }

    public func run(job: Job, context: ModelContext) async throws {
        guard let payloadStr = job.payload,
              let data = payloadStr.data(using: .utf8) else {
            throw IMAPError.protocolViolation("imapPollFolder job missing payload")
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        sessionManager.reportIMAPActivity(
            payload.gapCheck == true ? .gapChecking : .polling,
            accountID: payload.accountID,
            folder: payload.folderName
        )
        do {
            guard let session = sessionManager.sessionForWork(accountID: payload.accountID) else {
                throw IMAPError.transient(underlying: IMAPError.notConnected)
            }
            let reportsNewInboundMessages = payload.gapCheck != true
            let result = try await session.pollFolder(
                folder: payload.folderName,
                batchSize: payload.batchSize ?? Self.defaultBatchSize,
                reportsNewInboundMessages: reportsNewInboundMessages
            )
            if result.hasMore {
                clearLastPollAt(accountID: payload.accountID, folderName: payload.folderName, context: context)
            } else {
                stampLastPollAt(accountID: payload.accountID, folderName: payload.folderName, context: context)
            }

            if payload.gapCheck == true {
                runGapCheck(
                    accountID: payload.accountID,
                    folderName: payload.folderName,
                    context: context
                )
            }
            sessionManager.completeIMAPActivity(
                accountID: payload.accountID,
                folder: payload.folderName
            )
        } catch {
            markAccountForIMAPReauthIfNeeded(
                error,
                accountID: payload.accountID,
                context: context
            )
            stampLastPollFailureAt(
                accountID: payload.accountID,
                folderName: payload.folderName,
                context: context
            )
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

    private func markAccountForIMAPReauthIfNeeded(
        _ error: Error,
        accountID: UUID,
        context: ModelContext
    ) {
        guard let imap = error as? IMAPError else { return }
        switch imap {
        case .authFailed, .reauthRequired:
            let descriptor = FetchDescriptor<Account>(
                predicate: #Predicate<Account> { $0.id == accountID }
            )
            guard let account = try? context.fetch(descriptor).first else { return }
            guard IMAPReauthGate.shouldMarkNeedsImapReauth(
                account: account,
                error: imap
            ) else {
                return
            }
            account.needsImapReauth = true
            try? context.save()
        default:
            break
        }
    }

    private func stampLastPollAt(accountID: UUID, folderName: String, context: ModelContext) {
        let descriptor = FetchDescriptor<IMAPFolderState>(
            predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID && state.folderName == folderName
            }
        )
        guard let state = try? context.fetch(descriptor).first else { return }
        state.lastPollAt = Date()
        state.lastPollFailureAt = nil
        state.updatedAt = Date()
        try? context.save()
    }

    private func clearLastPollAt(accountID: UUID, folderName: String, context: ModelContext) {
        let descriptor = FetchDescriptor<IMAPFolderState>(
            predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID && state.folderName == folderName
            }
        )
        guard let state = try? context.fetch(descriptor).first else { return }
        state.lastPollAt = nil
        state.lastPollFailureAt = nil
        state.updatedAt = Date()
        try? context.save()
    }

    private func stampLastPollFailureAt(accountID: UUID, folderName: String, context: ModelContext) {
        let descriptor = FetchDescriptor<IMAPFolderState>(
            predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID && state.folderName == folderName
            }
        )
        guard let state = try? context.fetch(descriptor).first else { return }
        state.lastPollFailureAt = Date()
        state.updatedAt = Date()
        try? context.save()
    }

    /// Post-poll gap check: compare server EXISTS against local Message count
    /// for this account+folder. If the threshold fires, enqueue a priority-9
    /// .imapBackfill job.
    private func runGapCheck(
        accountID: UUID,
        folderName: String,
        context: ModelContext
    ) {
        let accountDescriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == accountID }
        )
        let account = try? context.fetch(accountDescriptor).first

        let localCountDescriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { msg in
                (msg.accountID == accountID || msg.account?.id == accountID)
                    && msg.imapFolderPath == folderName
            }
        )
        let localMessages = (try? context.fetch(localCountDescriptor)) ?? []
        let localCount = localMessages.filter { message in
            account?.acceptsExistingMessageIngestionWindow(
                receivedAt: message.receivedAt,
                sentAt: message.sentAt
            ) ?? true
        }.count

        let stateDescriptor = FetchDescriptor<IMAPFolderState>(
            predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID
                    && state.folderName == folderName
            }
        )
        let state = try? context.fetch(stateDescriptor).first
        let uidNextAtLastSelect = state?.uidNextAtLastSelect ?? 0
        let serverEst: Int?
        if account?.ingestionLowerBoundAt != nil {
            serverEst = state?.inScopeMessageCountAtLastSelect
        } else {
            serverEst = state?.existsAtLastSelect
                ?? (uidNextAtLastSelect == 0 ? 0 : Int(uidNextAtLastSelect - 1))
        }

        if let serverEst,
           GapCheckThreshold.shouldRunBackfill(
               serverExistsCount: serverEst,
               localMessageCount: localCount
           ) {
            let backfillPayload = IMAPBackfillWorker.Payload(
                accountID: accountID,
                folderName: folderName,
                batchSize: IMAPBackfillWorker.defaultBatchSize
            )
            if let jsonData = try? JSONEncoder().encode(backfillPayload),
               let json = String(data: jsonData, encoding: .utf8) {
                let backfillJob = Job(type: .imapBackfill, priority: 9)
                backfillJob.payload = json
                context.insert(backfillJob)
                try? context.save()
            }
        }

    }
}
