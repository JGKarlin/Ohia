import Foundation
import SwiftData
import OhiaCore
import OhiaMail

/// Drains a `.imapDeletionWatch` job by issuing a SELECT-only tick against
/// the named folder via the live `IMAPSession`. The session emits an
/// `IMAPDeletionEvent` if anything interesting changed; the existing
/// `DeletionSyncCoordinator` cascade applies the deletion (which posts
/// `.ohiaDeletionApplied` so the constellation's black-hole animation
/// fires) just like the regular live-poll path.
///
/// The worker runs in both `.full` and `.deletionWatchOnly` modes. In full
/// mode it uses the same auxiliary-client SELECT path without fetching
/// message bodies, so Gmail's All Mail delete state does not have to wait for
/// the slower non-INBOX poll cadence.
@MainActor
public final class IMAPDeletionWatchWorker {
    struct Payload: Codable {
        let accountID: UUID
        let folderName: String
    }

    private let sessionManager: IMAPSessionManager

    public init(sessionManager: IMAPSessionManager) {
        self.sessionManager = sessionManager
    }

    public func run(job: Job, context: ModelContext) async throws {
        guard let payloadStr = job.payload,
              let data = payloadStr.data(using: .utf8) else {
            throw IMAPError.protocolViolation("imapDeletionWatch job missing payload")
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        sessionManager.reportIMAPActivity(
            .verifyingDeletions,
            accountID: payload.accountID,
            folder: payload.folderName
        )
        do {
            guard let session = sessionManager.session(for: payload.accountID) else {
                // Session-missing -> transient. The job retries on the next tick
                // once the manager has had a chance to spin up the session
                // (post-cold-boot, post-network-restored, post-unpause).
                throw IMAPError.transient(underlying: IMAPError.notConnected)
            }
            try await session.runDeletionWatchTick(folder: payload.folderName)
            stampLastDeletionWatchAt(
                accountID: payload.accountID,
                folderName: payload.folderName,
                context: context
            )
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
            stampLastDeletionWatchFailureAt(
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

    private func stampLastDeletionWatchAt(
        accountID: UUID,
        folderName: String,
        context: ModelContext
    ) {
        let descriptor = FetchDescriptor<IMAPFolderState>(
            predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID && state.folderName == folderName
            }
        )
        guard let state = try? context.fetch(descriptor).first else { return }
        state.lastDeletionWatchAt = Date()
        state.lastDeletionWatchFailureAt = nil
        state.updatedAt = Date()
        try? context.save()
    }

    private func stampLastDeletionWatchFailureAt(
        accountID: UUID,
        folderName: String,
        context: ModelContext
    ) {
        let descriptor = FetchDescriptor<IMAPFolderState>(
            predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID && state.folderName == folderName
            }
        )
        guard let state = try? context.fetch(descriptor).first else { return }
        state.lastDeletionWatchFailureAt = Date()
        state.updatedAt = Date()
        try? context.save()
    }
}
