import Foundation
import SwiftData
import OhiaCore

/// Translates a user-initiated context-menu action into the local SwiftData
/// state change plus a queued `MailboxMutation` for server-side
/// propagation. Mirrors `SendDispatcher` for the read/delete surface.
///
/// All entry points run on the main actor: the UI is the only caller, the
/// `ModelContext` is the main-actor context, and the @Model rows are
/// non-Sendable so we never hand them across actor boundaries.
@MainActor
public final class MailboxMutationDispatcher {
    private let context: ModelContext
    private let jobQueue: JobQueue
    private let localDeletionCascade: (any MessageLocalDeletionArtifactCleaning)?
    private let providerTrashRestorer: (@MainActor @Sendable (UUID, String) async throws -> Void)?

    public init(
        context: ModelContext,
        jobQueue: JobQueue,
        localDeletionCascade: (any MessageLocalDeletionArtifactCleaning)? = nil,
        providerTrashRestorer: (@MainActor @Sendable (UUID, String) async throws -> Void)? = nil
    ) {
        self.context = context
        self.jobQueue = jobQueue
        self.localDeletionCascade = localDeletionCascade
        self.providerTrashRestorer = providerTrashRestorer
    }

    public enum Error: Swift.Error, Equatable {
        case messageNotFound
        case missingIMAPCoordinates
        case junkDestinationUnavailable
        case trashDestinationUnavailable
        case permanentDeleteRequiresTrash
    }

    /// Outcome of a successfully dispatched mutation. When an outcome is
    /// returned, the local state has already changed.
    /// `propagatedToServer` is false when Ohia lacks the server coordinates
    /// needed to mirror a local-only change remotely. In that case the UI
    /// should surface a quiet "couldn't propagate to server" notice.
    public struct Outcome: Sendable, Equatable {
        public let propagatedToServer: Bool
    }

    public enum TrashRestoreDisposition: Sendable, Equatable {
        case restoredLocally
        case requiresRemotePromotion
    }

    /// Toggle the read flag on a message and (when the message has an
    /// IMAP origin) queue a `\Seen` STORE for the server. Idempotent —
    /// setting read=true on an already-read message is a no-op locally
    /// and produces a no-op IMAP STORE.
    public func setRead(messageID: UUID, value: Bool) throws -> Outcome {
        let message = try fetchMessage(id: messageID)
        message.applyReadState(value)

        let queued = try enqueueIfPossible(
            message: message,
            kind: value ? .setSeen : .clearSeen
        )
        try context.save()
        if let mutation = queued.mutation {
            publishQueuedActivity(mutation)
        }
        return queued.outcome
    }

    /// Queue a read/unread mutation for a transient withheld row. Withheld mail
    /// is not represented by a local `Message` until promotion, so the caller
    /// passes the IMAP coordinates directly and updates the drawer state
    /// optimistically.
    public func setRead(
        accountID: UUID,
        sourceFolder: String,
        uid: UInt32,
        uidValidity: UInt32,
        value: Bool
    ) throws -> Outcome {
        return try enqueueRemoteOnly(
            accountID: accountID,
            sourceFolder: sourceFolder,
            uid: uid,
            uidValidity: uidValidity,
            kind: value ? .setSeen : .clearSeen
        )
    }

    /// Toggle the user-flagged ("starred") flag on a message and queue
    /// a `\Flagged` STORE for the server when the message has an IMAP
    /// origin. Idempotent in the same way as `setRead`.
    public func setFlagged(messageID: UUID, value: Bool) throws -> Outcome {
        let message = try fetchMessage(id: messageID)
        message.flagged = value

        let queued = try enqueueIfPossible(
            message: message,
            kind: value ? .setFlagged : .clearFlagged
        )
        try context.save()
        if let mutation = queued.mutation {
            publishQueuedActivity(mutation)
        }
        return queued.outcome
    }

    /// Normal user delete for an ingested message.
    ///
    /// Product contract: "delete" means move the server copy to Trash, not
    /// expunge it. Keep this as an alias for `moveToTrash(messageID:)` so
    /// delete buttons and context-menu actions share one meaning across lenses.
    public func delete(messageID: UUID) throws -> Outcome {
        try moveToTrash(messageID: messageID)
    }

    /// Explicit permanent delete for an ingested message.
    ///
    /// Unlike normal `delete(messageID:)`, this is irreversible. IMAP-backed
    /// messages remain retained until the queued server delete/expunge succeeds;
    /// genuinely local-only messages are deleted immediately with their local
    /// artifacts. An IMAP-backed message missing its coordinates is left intact.
    public func deletePermanently(messageID: UUID) throws -> Outcome {
        let message = try fetchMessage(id: messageID)
        guard message.isTrashed else {
            throw Error.permanentDeleteRequiresTrash
        }
        guard let mutation = makeMutationIfPossible(for: message, kind: .delete) else {
            if !hasIMAPOrigin(message) {
                let deletedMessageID = message.id
                deleteMessageLocally(message)
                try context.save()
                try cleanupDeletedMessageArtifacts(messageID: deletedMessageID)
                return Outcome(propagatedToServer: false)
            }
            throw Error.missingIMAPCoordinates
        }
        context.insert(mutation)
        jobQueue.stage(type: .mailboxMutation, priority: 1, context: context)
        try context.save()
        publishQueuedActivity(mutation)
        return Outcome(propagatedToServer: true)
    }

    /// Queue a permanent server-side delete for a transient withheld row.
    /// There is no local corpus row to delete; successful enqueue lets the UI
    /// remove the transient row from the drawer.
    public func delete(
        accountID: UUID,
        sourceFolder: String,
        uid: UInt32,
        uidValidity: UInt32,
        rfcMessageIDHeader: String? = nil,
        retainedMessageID: UUID? = nil
    ) throws -> Outcome {
        let retainedMessageID = retainedTrashedMessageID(
            accountID: accountID,
            explicitMessageID: retainedMessageID,
            rfcMessageIDHeader: rfcMessageIDHeader
        )
        return try enqueueRemoteOnly(
            accountID: accountID,
            sourceFolder: sourceFolder,
            uid: uid,
            uidValidity: uidValidity,
            kind: .delete,
            messageID: retainedMessageID,
            rfcMessageIDHeader: rfcMessageIDHeader
        )
    }

    /// Queue a server-side move of a withheld (Junk/Trash) message into the
    /// account inbox. Unlike `moveToTrash`, this does NOT touch the local store:
    /// the promoted message has already been ingested into the corpus by the
    /// WithheldPromotionCoordinator (ingest-first). Source coordinates come from
    /// the withheld folder (the source message was never ingested), so the caller
    /// passes them explicitly rather than via a Message row.
    public func moveToInbox(
        accountID: UUID,
        messageID: UUID,
        sourceFolder: String,
        uid: UInt32,
        uidValidity: UInt32? = nil,
        destination: String = "INBOX",
        feedbackEvidence: MailboxSpamFeedbackEvidence? = nil,
        feedbackSourceRoleRaw: String? = nil,
        feedbackProviderSpamScore: Double? = nil
    ) throws -> Outcome {
        guard !sourceFolder.isEmpty,
              uid > 0,
              uidValidity != 0,
              !destination.isEmpty,
              sourceFolder.caseInsensitiveCompare(destination) != .orderedSame else {
            return Outcome(propagatedToServer: false)
        }
        let mutation = MailboxMutation(
            accountID: accountID,
            messageID: messageID,
            imapFolderPath: sourceFolder,
            imapUID: uid,
            expectedUIDValidity: uidValidity,
            kind: .moveToInbox,
            destinationFolderPath: destination
        )
        mutation.applySpamFeedbackEvidence(
            feedbackEvidence,
            sourceRoleRaw: feedbackSourceRoleRaw,
            providerSpamScore: feedbackProviderSpamScore
        )
        context.insert(mutation)
        try jobQueue.enqueue(type: .mailboxMutation, priority: 1, context: context)
        try context.save()
        publishQueuedActivity(mutation)
        return Outcome(propagatedToServer: true)
    }

    /// Remove a message from Ohia's active store and queue a server-side move
    /// into the account's Trash mailbox. Cached folder state is a hint, not a
    /// prerequisite: if no cached Trash path is available, the async IMAP
    /// worker resolves Trash from live LIST and creates a conventional `Trash`
    /// mailbox if the server truly advertises none.
    /// Local-only rows may still be hidden locally because there is no server
    /// mailbox to move.
    public func moveToTrash(messageID: UUID) throws -> Outcome {
        let message = try fetchMessage(id: messageID)
        guard let mutation = makeMoveToTrashMutationIfPossible(for: message) else {
            if hasIMAPOrigin(message) {
                throw Error.trashDestinationUnavailable
            }
            try retainMessageInTrash(message)
            return Outcome(propagatedToServer: false)
        }
        try localDeletionCascade?.setMessageActive(messageID: message.id, isActive: false)
        message.trashedAt = Date()
        context.insert(mutation)
        jobQueue.stage(type: .mailboxMutation, priority: 1, context: context)
        do {
            try context.save()
        } catch {
            try? localDeletionCascade?.setMessageActive(messageID: message.id, isActive: true)
            throw error
        }
        publishQueuedActivity(mutation)
        return Outcome(propagatedToServer: true)
    }

    /// Undo/Restore for retained Trash. A queued provider move can be cancelled
    /// synchronously on the main actor. Once a move has completed, restore the
    /// provider copy by stable Message-ID and reactivate the retained row only
    /// after that provider operation confirms success.
    public func restoreFromTrash(messageID: UUID) async throws -> TrashRestoreDisposition {
        var message = try fetchMessage(id: messageID)
        guard message.isTrashed else { return .restoredLocally }

        let latestMutation = try context.fetch(FetchDescriptor<MailboxMutation>())
            .filter { $0.messageID == messageID && $0.kind == .moveToTrash }
            .sorted { $0.createdAt > $1.createdAt }
            .first
        var restoredAtProvider = false
        if let latestMutation {
            switch latestMutation.status {
            case .running:
                return .requiresRemotePromotion
            case .succeeded:
                guard let providerMessageID = canonicalProviderMessageID(message.messageIdHeader)
                        ?? canonicalProviderMessageID(latestMutation.rfcMessageIDHeader),
                      let providerTrashRestorer else {
                    return .requiresRemotePromotion
                }
                let accountID = latestMutation.accountID
                try await providerTrashRestorer(
                    accountID,
                    providerMessageID
                )
                restoredAtProvider = true
                message = try fetchMessage(id: messageID)
                guard message.isTrashed else { return .restoredLocally }
            case .queued, .failed:
                latestMutation.status = .cancelled
                latestMutation.nextAttemptAfter = nil
            case .cancelled:
                break
            }
        }
        try localDeletionCascade?.setMessageActive(messageID: messageID, isActive: true)
        message.trashedAt = nil
        if restoredAtProvider {
            // The pre-Trash UID belongs to the old source folder. Leave a zero
            // coordinate until the next Inbox poll reconciles the provider's
            // new UID by Message-ID, preventing stale UID STORE operations.
            message.imapFolderPath = "INBOX"
            message.imapUID = 0
        }
        do {
            try context.save()
        } catch {
            try? localDeletionCascade?.setMessageActive(messageID: messageID, isActive: false)
            context.rollback()
            throw error
        }
        return .restoredLocally
    }

    /// Completes the local half of an ingest-first Withheld promotion. The raw
    /// message has already repaired the retained SwiftData row; this restores
    /// its semantic sidecar before the move-to-Inbox mutation is enqueued.
    public func reactivatePromotedMessage(messageID: UUID) throws {
        let message = try fetchMessage(id: messageID)
        try localDeletionCascade?.setMessageActive(messageID: messageID, isActive: true)
        message.trashedAt = nil
        do {
            try context.save()
        } catch {
            try? localDeletionCascade?.setMessageActive(messageID: messageID, isActive: false)
            throw error
        }
    }

    /// Queue a server-side move into the account's Junk / Spam mailbox. This is
    /// a mailbox operation only: it does not apply Ohia categories or otherwise
    /// reclassify the message in the local semantic taxonomy. Cached folder
    /// state is only a hint that the async worker validates against a live LIST
    /// response. IMAP-backed rows remain local until that provider move
    /// succeeds, so a missing destination or failed move cannot discard the
    /// user's message from Ohia.
    public func markAsSpam(messageID: UUID) throws -> Outcome {
        let message = try fetchMessage(id: messageID)
        guard let mutation = makeMoveToJunkMutationIfPossible(for: message) else {
            if hasIMAPOrigin(message) {
                throw Error.junkDestinationUnavailable
            }
            if let feedbackMutation = makeLocalSpamFeedbackMutationIfPossible(for: message) {
                context.insert(feedbackMutation)
            }
            let deletedMessageID = message.id
            deleteMessageLocally(message)
            try context.save()
            try cleanupDeletedMessageArtifacts(messageID: deletedMessageID)
            return Outcome(propagatedToServer: false)
        }
        if try hasActiveMoveToJunkMutation(matching: mutation) {
            return Outcome(propagatedToServer: true)
        }
        context.insert(mutation)
        jobQueue.stage(type: .mailboxMutation, priority: 1, context: context)
        try context.save()
        publishQueuedActivity(mutation)
        return Outcome(propagatedToServer: true)
    }

    // MARK: - Helpers

    private func fetchMessage(id: UUID) throws -> Message {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let message = try context.fetch(descriptor).first else {
            throw Error.messageNotFound
        }
        return message
    }

    /// Junk handling retains its existing destructive semantics; the semantic
    /// Trash lifecycle is deliberately scoped to ordinary Delete.
    private func deleteMessageLocally(_ message: Message) {
        context.delete(message)
    }

    private func cleanupDeletedMessageArtifacts(messageID: UUID) throws {
        guard let localDeletionCascade else { return }
        let frames = try localDeletionCascade.removeLocalArtifacts(messageID: messageID)
        try localDeletionCascade.enqueueClusterRecomputeIfNeeded(
            frames: frames,
            context: context,
            jobQueue: jobQueue
        )
    }

    private func enqueueIfPossible(
        message: Message,
        kind: MailboxMutationKind
    ) throws -> (outcome: Outcome, mutation: MailboxMutation?) {
        guard let mutation = makeMutationIfPossible(for: message, kind: kind) else {
            return (Outcome(propagatedToServer: false), nil)
        }
        context.insert(mutation)
        try jobQueue.enqueue(type: .mailboxMutation, priority: 1, context: context)
        return (Outcome(propagatedToServer: true), mutation)
    }

    private func enqueueRemoteOnly(
        accountID: UUID,
        sourceFolder: String,
        uid: UInt32,
        uidValidity: UInt32,
        kind: MailboxMutationKind,
        messageID: UUID? = nil,
        rfcMessageIDHeader: String? = nil
    ) throws -> Outcome {
        guard !sourceFolder.isEmpty, uid > 0, uidValidity > 0 else {
            return Outcome(propagatedToServer: false)
        }
        let mutation = MailboxMutation(
            accountID: accountID,
            messageID: messageID ?? UUID(),
            imapFolderPath: sourceFolder,
            imapUID: uid,
            rfcMessageIDHeader: rfcMessageIDHeader,
            expectedUIDValidity: uidValidity,
            kind: kind
        )
        context.insert(mutation)
        try jobQueue.enqueue(type: .mailboxMutation, priority: 1, context: context)
        try context.save()
        publishQueuedActivity(mutation)
        return Outcome(propagatedToServer: true)
    }

    private func publishQueuedActivity(_ mutation: MailboxMutation) {
        NotificationCenter.default.post(
            name: .ohiaIMAPActivityQueued,
            object: WorkerIMAPActivitySnapshot(
                kind: .pending,
                accountID: mutation.accountID,
                folder: mutation.imapFolderPath
            )
        )
    }

    private func retainMessageInTrash(_ message: Message) throws {
        try localDeletionCascade?.setMessageActive(messageID: message.id, isActive: false)
        message.trashedAt = Date()
        do {
            try context.save()
        } catch {
            try? localDeletionCascade?.setMessageActive(messageID: message.id, isActive: true)
            throw error
        }
    }

    private func retainedTrashedMessageID(
        accountID: UUID,
        explicitMessageID: UUID?,
        rfcMessageIDHeader: String?
    ) -> UUID? {
        guard let messages = try? context.fetch(FetchDescriptor<Message>()) else {
            return nil
        }
        let retained = messages.filter { message in
            message.isTrashed
                && (message.accountID ?? message.account?.id) == accountID
        }
        if let explicitMessageID,
           retained.contains(where: { $0.id == explicitMessageID }) {
            return explicitMessageID
        }
        guard let canonicalHeader = canonicalProviderMessageID(rfcMessageIDHeader) else {
            return nil
        }
        return retained.first {
            canonicalProviderMessageID($0.messageIdHeader) == canonicalHeader
        }?.id
    }

    private func makeMutationIfPossible(
        for message: Message,
        kind: MailboxMutationKind
    ) -> MailboxMutation? {
        guard let folder = message.imapFolderPath,
              !folder.isEmpty,
              message.imapUID > 0,
              let accountID = message.accountID ?? message.account?.id else {
            return nil
        }
        return MailboxMutation(
            accountID: accountID,
            messageID: message.id,
            imapFolderPath: folder,
            imapUID: message.imapUID,
            rfcMessageIDHeader: message.messageIdHeader,
            expectedUIDValidity: sourceUIDValidity(accountID: accountID, folder: folder),
            kind: kind
        )
    }

    private func makeMoveToJunkMutationIfPossible(for message: Message) -> MailboxMutation? {
        guard let folder = message.imapFolderPath,
              !folder.isEmpty,
              message.imapUID > 0,
              let accountID = message.accountID ?? message.account?.id else {
            return nil
        }

        let junkFolder = junkFolderPath(accountID: accountID)
        let mutation = MailboxMutation(
            accountID: accountID,
            messageID: message.id,
            imapFolderPath: folder,
            imapUID: message.imapUID,
            rfcMessageIDHeader: canonicalProviderMessageID(message.messageIdHeader),
            expectedUIDValidity: sourceUIDValidity(accountID: accountID, folder: folder),
            kind: .moveToJunk,
            destinationFolderPath: junkFolder
        )
        mutation.applySpamFeedbackEvidence(
            spamFeedbackEvidence(for: message),
            sourceRoleRaw: "junk"
        )
        return mutation
    }

    private func hasActiveMoveToJunkMutation(
        matching proposed: MailboxMutation
    ) throws -> Bool {
        let mutations = try context.fetch(FetchDescriptor<MailboxMutation>())
        return mutations.contains { existing in
            guard existing.kind == .moveToJunk,
                  existing.messageID == proposed.messageID,
                  existing.accountID == proposed.accountID,
                  existing.imapUID == proposed.imapUID,
                  existing.imapFolderPath.caseInsensitiveCompare(proposed.imapFolderPath) == .orderedSame else {
                return false
            }
            switch existing.status {
            case .queued, .running:
                return true
            case .succeeded:
                return existing.localFinalizedAt == nil
            case .failed, .cancelled:
                return false
            }
        }
    }

    private func makeLocalSpamFeedbackMutationIfPossible(for message: Message) -> MailboxMutation? {
        guard let accountID = message.accountID ?? message.account?.id else {
            return nil
        }
        let evidence = spamFeedbackEvidence(for: message)
        guard evidence.hasSignals else { return nil }

        let sourceFolder = message.imapFolderPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folder: String
        if let sourceFolder, !sourceFolder.isEmpty {
            folder = sourceFolder
        } else {
            folder = "Ohia Local"
        }
        let mutation = MailboxMutation(
            accountID: accountID,
            messageID: message.id,
            imapFolderPath: folder,
            imapUID: message.imapUID,
            rfcMessageIDHeader: message.messageIdHeader,
            expectedUIDValidity: nil,
            kind: .moveToJunk,
            destinationFolderPath: nil
        )
        mutation.status = .succeeded
        mutation.lastAttemptAt = Date()
        mutation.applySpamFeedbackEvidence(
            evidence,
            sourceRoleRaw: "junk"
        )
        return mutation
    }

    private func makeMoveToTrashMutationIfPossible(for message: Message) -> MailboxMutation? {
        guard let folder = message.imapFolderPath,
              !folder.isEmpty,
              let accountID = message.accountID ?? message.account?.id else {
            return nil
        }
        let providerMessageID = canonicalProviderMessageID(message.messageIdHeader)
        guard message.imapUID > 0 || providerMessageID != nil else { return nil }
        guard let account = account(id: accountID) else { return nil }

        // Gmail exposes labels as IMAP folders, so an identity-poor UID move
        // can be acknowledged while merely adding a user label and leaving the
        // provider message in Inbox. OAuth Gmail deletion is provider-backed;
        // require the stable RFC Message-ID before removing the local row so
        // the worker can prove TRASH is present and INBOX is absent.
        if isOAuthGmailAccount(account), providerMessageID == nil {
            return nil
        }

        let trashFolder = trashFolderPath(accountID: accountID)
        if let trashFolder,
           trashFolder.caseInsensitiveCompare(folder) == .orderedSame {
            return nil
        }
        return MailboxMutation(
            accountID: accountID,
            messageID: message.id,
            imapFolderPath: folder,
            imapUID: message.imapUID,
            rfcMessageIDHeader: providerMessageID ?? message.messageIdHeader,
            expectedUIDValidity: sourceUIDValidity(accountID: accountID, folder: folder),
            kind: .moveToTrash,
            destinationFolderPath: trashFolder
        )
    }

    private func account(id: UUID) -> Account? {
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func isOAuthGmailAccount(_ account: Account) -> Bool {
        guard account.imapAuthMethod == .oauth2,
              let host = account.imapHost?.lowercased() else {
            return false
        }
        return host.contains("gmail") || host.contains("google")
    }

    private func sourceUIDValidity(accountID: UUID, folder: String) -> UInt32? {
        guard let states = try? context.fetch(FetchDescriptor<IMAPFolderState>()) else {
            return nil
        }
        guard let state = states.first(where: { state in
            state.account?.id == accountID &&
            state.folderName.caseInsensitiveCompare(folder) == .orderedSame
        }) else {
            return nil
        }
        return state.uidValidity > 0 ? state.uidValidity : nil
    }

    private func junkFolderPath(accountID: UUID) -> String? {
        guard let states = try? context.fetch(FetchDescriptor<IMAPFolderState>()) else {
            return nil
        }
        let accountStates = states.filter { $0.account?.id == accountID }
        if let specialUse = accountStates.first(where: Self.isJunkSpecialUse) {
            return specialUse.folderName
        }
        return nil
    }

    private func trashFolderPath(accountID: UUID) -> String? {
        guard let states = try? context.fetch(FetchDescriptor<IMAPFolderState>()) else {
            return nil
        }
        let accountStates = states.filter { $0.account?.id == accountID }
        if let specialUse = accountStates.first(where: Self.isTrashSpecialUse) {
            return specialUse.folderName
        }

        return accountStates.first { state in
            IMAPFolderIngestionPolicy.matchesTrashLeafName(state.folderName)
        }?.folderName
    }

    private func hasIMAPOrigin(_ message: Message) -> Bool {
        let hasFolder = !(message.imapFolderPath ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard !hasFolder, message.imapUID <= 0 else { return true }
        if let account = message.account {
            return Self.hasConfiguredIMAP(account)
        }
        guard let accountID = message.accountID ?? message.account?.id else { return false }
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == accountID }
        )
        descriptor.fetchLimit = 1
        guard let account = try? context.fetch(descriptor).first else { return false }
        return Self.hasConfiguredIMAP(account)
    }

    private static func hasConfiguredIMAP(_ account: Account) -> Bool {
        account.imapHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && account.imapKeychainRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func spamFeedbackEvidence(for message: Message) -> MailboxSpamFeedbackEvidence {
        MailboxSpamFeedbackEvidence(
            accountID: message.accountID ?? message.account?.id,
            senderAddress: message.fromAddress,
            subject: message.subject,
            listId: message.listId
        )
    }

    private static func isJunkSpecialUse(_ state: IMAPFolderState) -> Bool {
        state.folderAttributes.contains { attribute in
            attribute.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
                .replacingOccurrences(of: "\\", with: "") == "JUNK"
        }
    }

    private static func isTrashSpecialUse(_ state: IMAPFolderState) -> Bool {
        state.folderAttributes.contains { attribute in
            attribute.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
                .replacingOccurrences(of: "\\", with: "") == "TRASH"
        }
    }
}
