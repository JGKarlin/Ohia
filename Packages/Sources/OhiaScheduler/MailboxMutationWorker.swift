import Foundation
import SwiftData
import OhiaCore
import OhiaMail

/// Sendable snapshot of the IMAP coordinates needed to run a mutation.
/// `MailboxMutation` itself is a `@Model`, which is non-Sendable; we
/// capture the fields we'll send across the actor boundary into this
/// immutable struct before each `IMAPSession` call.
private struct MailboxMutationSnapshot: Sendable {
    let accountID: UUID
    let kind: MailboxMutationKind
    let folder: String
    let uid: UInt32
    let rfcMessageIDHeader: String?
    let expectedUIDValidity: UInt32?
    let destinationFolder: String?
    let isRetry: Bool
}

/// Drains queued `MailboxMutation` rows by routing each one through the
/// per-account `IMAPSession`. Mirrors `OutboxWorker`'s lifecycle: claim a
/// small batch, run optimistically, classify failures into permanent
/// (give up) vs transient (exponential backoff up to `maxAttempts`).
///
/// Most local SwiftData state has already been updated optimistically at
/// enqueue time. Move-to-Junk is deliberately different: the local message is
/// retained until the provider move succeeds, then this worker removes its
/// artifacts and row. A failed Junk move therefore leaves the message intact.
public final class MailboxMutationWorker: @unchecked Sendable {
    private let sessionProvider: @MainActor (UUID) -> IMAPSession?
    private let maxPerTick: Int
    private let maxAttempts: Int
    private let reachability: NetworkReachability
    private let localDeletionCascade: (any MessageLocalDeletionArtifactCleaning)?
    private let jobQueue: JobQueue
    private let activityReporter: (any IMAPActivityReporting)?

    public convenience init(
        sessionManager: IMAPSessionManager,
        reachability: NetworkReachability = AlwaysOnlineReachability(),
        maxPerTick: Int = 10,
        maxAttempts: Int = 5,
        localDeletionCascade: (any MessageLocalDeletionArtifactCleaning)? = nil,
        jobQueue: JobQueue = JobQueue()
    ) {
        self.init(
            sessionProvider: { accountID in
                sessionManager.sessionForWork(accountID: accountID)
            },
            reachability: reachability,
            maxPerTick: maxPerTick,
            maxAttempts: maxAttempts,
            localDeletionCascade: localDeletionCascade,
            jobQueue: jobQueue,
            activityReporter: sessionManager
        )
    }

    init(
        sessionProvider: @escaping @MainActor (UUID) -> IMAPSession?,
        reachability: NetworkReachability = AlwaysOnlineReachability(),
        maxPerTick: Int = 10,
        maxAttempts: Int = 5,
        localDeletionCascade: (any MessageLocalDeletionArtifactCleaning)? = nil,
        jobQueue: JobQueue = JobQueue(),
        activityReporter: (any IMAPActivityReporting)? = nil
    ) {
        self.sessionProvider = sessionProvider
        self.reachability = reachability
        self.maxPerTick = maxPerTick
        self.maxAttempts = maxAttempts
        self.localDeletionCascade = localDeletionCascade
        self.jobQueue = jobQueue
        self.activityReporter = activityReporter
    }

    @MainActor
    @discardableResult
    public func drain(
        context: ModelContext,
        now: Date = Date()
    ) async throws -> [PipelineMessageMutation] {
        if !reachability.isOnline { return [] }
        let all = try context.fetch(FetchDescriptor<MailboxMutation>())
        var finalizedMessageIDs = finalizeSucceededLocalDeletions(
            in: all,
            context: context
        )
        let eligible = all
            .filter { $0.status == .queued }
            .filter { $0.nextAttemptAfter == nil || $0.nextAttemptAfter! <= now }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(maxPerTick)

        // Suspended accounts: an auth-class failure on one mutation marks
        // the account `needsReauth`; subsequent mutations for that same
        // account in the same drain pass should not retry until the user
        // re-auths.
        var suspendedAccounts = Set<UUID>()

        for row in eligible {
            // The eligible array was captured before the previous row's await.
            // Undo may have cancelled this row while that provider operation
            // was in flight, so claim only rows that are still queued now.
            guard row.status == .queued else { continue }
            if suspendedAccounts.contains(row.accountID) { continue }
            guard let session = sessionProvider(row.accountID) else {
                handleTransient(
                    error: "no IMAP session available for account",
                    row: row,
                    now: now
                )
                synchronizeIgnoredMessageHistory(for: row, context: context)
                try context.save()
                activityReporter?.failIMAPActivity(
                    accountID: row.accountID,
                    folder: row.imapFolderPath,
                    requiresAttention: row.status == .failed,
                    cause: .mailboxOperation,
                    operationID: row.id
                )
                continue
            }

            let isRetry = row.lastAttemptAt != nil
            row.status = .running
            row.lastAttemptAt = now
            try context.save()

            // Snapshot the row's IMAP coordinates before suspending across
            // the actor boundary — `MailboxMutation` is a SwiftData @Model
            // and therefore non-Sendable. After the await, the row may
            // also have been mutated by another scheduler tick, so we
            // continue to use this immutable snapshot for execute().
            let snapshot = MailboxMutationSnapshot(
                accountID: row.accountID,
                kind: row.kind,
                folder: row.imapFolderPath,
                uid: row.imapUID,
                rfcMessageIDHeader: row.rfcMessageIDHeader,
                expectedUIDValidity: row.expectedUIDValidity,
                destinationFolder: row.destinationFolderPath,
                isRetry: isRetry
            )

            activityReporter?.reportIMAPActivity(
                WorkerIMAPActivityKind(mailboxMutation: snapshot.kind),
                accountID: snapshot.accountID,
                folder: snapshot.folder
            )
            var operationFailed = false
            var failureCause = WorkerIMAPAttentionCause.mailboxOperation
            do {
                try await execute(snapshot, against: session)
                row.status = .succeeded
                row.lastError = nil
            } catch let imap as IMAPError {
                operationFailed = true
                failureCause = IMAPSessionManager.attentionCause(for: imap)
                handleIMAPError(
                    imap,
                    row: row,
                    now: now,
                    suspended: &suspendedAccounts,
                    context: context
                )
            } catch {
                operationFailed = true
                handleTransient(
                    error: error.localizedDescription,
                    row: row,
                    now: now
                )
            }
            if operationFailed {
                activityReporter?.failIMAPActivity(
                    accountID: snapshot.accountID,
                    folder: snapshot.folder,
                    requiresAttention: row.status == .failed,
                    cause: failureCause,
                    operationID: row.id
                )
            } else {
                activityReporter?.completeIMAPActivity(
                    accountID: snapshot.accountID,
                    folder: snapshot.folder,
                    operationID: row.id
                )
            }
            synchronizeIgnoredMessageHistory(for: row, context: context)
            try context.save()
            if Self.requiresLocalDeletionFinalization(row), row.status == .succeeded {
                do {
                    if try finalizeLocalDeletionIfNeeded(for: row, context: context) {
                        finalizedMessageIDs.insert(row.messageID)
                    }
                } catch {
                    recordLocalFinalizationFailure(error, for: row, context: context)
                }
            }
        }
        guard finalizedMessageIDs.isEmpty == false else { return [] }
        return [PipelineMessageMutation(
            messageIDs: finalizedMessageIDs.sorted { $0.uuidString < $1.uuidString },
            facets: [.visibility]
        )]
    }

    @MainActor
    private func finalizeSucceededLocalDeletions(
        in mutations: [MailboxMutation],
        context: ModelContext
    ) -> Set<UUID> {
        var finalizedMessageIDs = Set<UUID>()
        for mutation in mutations where Self.requiresLocalDeletionFinalization(mutation)
            && mutation.status == .succeeded {
            do {
                if try finalizeLocalDeletionIfNeeded(for: mutation, context: context) {
                    finalizedMessageIDs.insert(mutation.messageID)
                }
            } catch {
                recordLocalFinalizationFailure(error, for: mutation, context: context)
            }
        }
        return finalizedMessageIDs
    }

    @MainActor
    private func recordLocalFinalizationFailure(
        _ error: Error,
        for mutation: MailboxMutation,
        context: ModelContext
    ) {
        mutation.lastError = "Provider mutation succeeded; local cleanup pending: \(error.localizedDescription)"
        try? context.save()
    }

    /// The remote mutation is committed before this method is reached. If local
    /// cleanup fails, the mutation remains `.succeeded`, so the next drain
    /// retries only this idempotent local finalization and never resends the
    /// provider command.
    @MainActor
    private func finalizeLocalDeletionIfNeeded(
        for mutation: MailboxMutation,
        context: ModelContext
    ) throws -> Bool {
        let messageID = mutation.messageID
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        guard let message = try context.fetch(descriptor).first else {
            try markLocalFinalizationComplete(mutation, context: context)
            return mutation.kind == .moveToJunk
        }
        if mutation.kind == .delete, message.isTrashed == false {
            try markLocalFinalizationComplete(mutation, context: context)
            return false
        }
        if mutation.kind == .moveToJunk {
            guard try hasNewerInboxPromotion(for: mutation, context: context) == false,
                  messageStillMatchesJunkMutation(message, mutation: mutation) else {
                try markLocalFinalizationComplete(mutation, context: context)
                return false
            }
        }
        guard let localDeletionCascade else { return false }

        let frames = try localDeletionCascade.removeLocalArtifacts(messageID: messageID)
        if !frames.isEmpty {
            // Persist recomputation work while the retained Message still
            // exists. If staging fails, the next drain can refetch the row and
            // retry the idempotent artifact cleanup plus enqueue.
            try localDeletionCascade.enqueueClusterRecomputeIfNeeded(
                frames: frames,
                context: context,
                jobQueue: jobQueue
            )
        }

        mutation.lastError = nil
        mutation.localFinalizedAt = Date()
        context.delete(message)
        do {
            try context.save()
        } catch {
            // Do not let a later error-recording save accidentally commit a
            // pending Message deletion whose final save failed.
            context.rollback()
            throw error
        }
        return true
    }

    private static func requiresLocalDeletionFinalization(
        _ mutation: MailboxMutation
    ) -> Bool {
        mutation.localFinalizedAt == nil
            && (mutation.kind == .delete || mutation.kind == .moveToJunk)
    }

    @MainActor
    private func markLocalFinalizationComplete(
        _ mutation: MailboxMutation,
        context: ModelContext
    ) throws {
        mutation.lastError = nil
        mutation.localFinalizedAt = Date()
        try context.save()
    }

    @MainActor
    private func hasNewerInboxPromotion(
        for mutation: MailboxMutation,
        context: ModelContext
    ) throws -> Bool {
        let mutations = try context.fetch(FetchDescriptor<MailboxMutation>())
        return mutations.contains { candidate in
            candidate.messageID == mutation.messageID
                && candidate.kind == .moveToInbox
                && candidate.status != .cancelled
                && candidate.createdAt > mutation.createdAt
        }
    }

    private func messageStillMatchesJunkMutation(
        _ message: Message,
        mutation: MailboxMutation
    ) -> Bool {
        guard let folder = message.imapFolderPath,
              folder.caseInsensitiveCompare(mutation.imapFolderPath) == .orderedSame,
              message.imapUID > 0 else {
            return false
        }
        if let mutationHeader = canonicalProviderMessageID(mutation.rfcMessageIDHeader) {
            return canonicalProviderMessageID(message.messageIdHeader) == mutationHeader
        }
        return message.imapUID == mutation.imapUID
    }

    private func execute(_ snapshot: MailboxMutationSnapshot, against session: IMAPSession) async throws {
        switch snapshot.kind {
        case .setSeen:
            try await session.markSeen(folder: snapshot.folder, uid: snapshot.uid, expectedUIDValidity: snapshot.expectedUIDValidity, value: true)
        case .clearSeen:
            try await session.markSeen(folder: snapshot.folder, uid: snapshot.uid, expectedUIDValidity: snapshot.expectedUIDValidity, value: false)
        case .setFlagged:
            try await session.markFlagged(folder: snapshot.folder, uid: snapshot.uid, expectedUIDValidity: snapshot.expectedUIDValidity, value: true)
        case .clearFlagged:
            try await session.markFlagged(folder: snapshot.folder, uid: snapshot.uid, expectedUIDValidity: snapshot.expectedUIDValidity, value: false)
        case .delete:
            try await session.deleteMessage(
                folder: snapshot.folder,
                uid: snapshot.uid,
                expectedUIDValidity: snapshot.expectedUIDValidity,
                messageIDHeader: snapshot.rfcMessageIDHeader
            )
        case .moveToTrash:
            try await session.moveMessageToTrash(
                folder: snapshot.folder,
                uid: snapshot.uid,
                expectedUIDValidity: snapshot.expectedUIDValidity,
                trashFolder: snapshot.destinationFolder,
                messageIDHeader: snapshot.rfcMessageIDHeader
            )
        case .moveToJunk:
            try await session.moveMessageToJunk(
                folder: snapshot.folder,
                uid: snapshot.uid,
                expectedUIDValidity: snapshot.expectedUIDValidity,
                junkFolder: snapshot.destinationFolder,
                messageIDHeader: snapshot.rfcMessageIDHeader,
                acceptAlreadyAbsentSourceUID: snapshot.isRetry
            )
        case .moveToInbox:
            guard let destination = snapshot.destinationFolder, !destination.isEmpty else {
                throw IMAPError.protocolViolation("moveToInbox mutation missing destination folder")
            }
            try await session.moveMessage(
                folder: snapshot.folder,
                uid: snapshot.uid,
                expectedUIDValidity: snapshot.expectedUIDValidity,
                to: destination
            )
        }
    }

    @MainActor
    private func handleIMAPError(
        _ err: IMAPError,
        row: MailboxMutation,
        now: Date,
        suspended: inout Set<UUID>,
        context: ModelContext
    ) {
        if JobErrorClassifier.isPermanent(err) {
            row.status = .failed
            row.lastError = "\(err)"
            // Auth-class permanent failures mark the account so the user
            // is prompted to re-auth and other mutations for the same
            // account in this drain pass don't retry against a known-bad
            // session.
            switch err {
            case .authFailed, .reauthRequired:
                if let account = fetchAccount(id: row.accountID, context: context) {
                    account.needsReauth = true
                }
                suspended.insert(row.accountID)
            default:
                break
            }
            return
        }
        handleTransient(error: "\(err)", row: row, now: now)
    }

    @MainActor
    private func handleTransient(error: String, row: MailboxMutation, now: Date) {
        row.attempts += 1
        row.lastError = error
        if row.attempts >= maxAttempts {
            row.status = .failed
        } else {
            // Same backoff curve as OutboxWorker: 30s, 60s, 120s, 240s,
            // capped at 1h. Mailbox mutations are idempotent (setting
            // \Seen twice is a no-op; expunging an already-gone UID is
            // a server-side NO that lands in `protocolViolation` and
            // gets reclassified to `.failed` on the next attempt).
            let delay = min(pow(2.0, Double(row.attempts)) * 30.0, 3600.0)
            row.nextAttemptAfter = now.addingTimeInterval(delay)
            row.status = .queued
        }
    }

    @MainActor
    private func fetchAccount(id: UUID, context: ModelContext) -> Account? {
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    @MainActor
    private func synchronizeIgnoredMessageHistory(
        for mutation: MailboxMutation,
        context: ModelContext
    ) {
        guard mutation.kind == .moveToTrash else { return }
        let messageID = mutation.messageID
        var descriptor = FetchDescriptor<MailingListIgnoredMessage>(
            predicate: #Predicate<MailingListIgnoredMessage> {
                $0.originalMessageID == messageID
            }
        )
        descriptor.fetchLimit = 1
        guard let history = try? context.fetch(descriptor).first else { return }

        switch mutation.status {
        case .succeeded:
            history.trashDispositionRaw = MailingListIgnoredTrashDisposition.serverTrash
            history.remoteStatusRaw = MailingListIgnoredRemoteStatus.completed
            history.lastRemoteError = nil
        case .failed:
            history.trashDispositionRaw = MailingListIgnoredTrashDisposition.serverTrash
            history.remoteStatusRaw = MailingListIgnoredRemoteStatus.failed
            history.lastRemoteError = mutation.lastError
        default:
            history.trashDispositionRaw = MailingListIgnoredTrashDisposition.serverTrash
            history.remoteStatusRaw = MailingListIgnoredRemoteStatus.queued
            history.lastRemoteError = mutation.lastError
        }
    }
}
