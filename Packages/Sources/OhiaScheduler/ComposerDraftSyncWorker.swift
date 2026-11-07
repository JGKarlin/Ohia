import Foundation
import SwiftData
import OhiaCore
import OhiaMail

protocol ComposerDraftIMAPSyncing: Sendable {
    func saveDraft(
        preferredFolder: String?,
        previousFolder: String?,
        previousUID: UInt32?,
        previousUIDValidity: UInt32?,
        messageIDHeader: String,
        payload: Data,
        date: Date?
    ) async throws -> IMAPDraftRemoteLocation

    func deleteDraft(
        folder: String,
        uid: UInt32?,
        uidValidity: UInt32?,
        messageIDHeader: String?
    ) async throws
}

extension IMAPSession: ComposerDraftIMAPSyncing {}

public final class ComposerDraftSyncWorker: @unchecked Sendable {
    private let sessionProvider: @MainActor (UUID) -> (any ComposerDraftIMAPSyncing)?
    private let maxPerTick: Int
    private let reachability: NetworkReachability
    private let activityReporter: (any IMAPActivityReporting)?
    private let currentDate: @Sendable () -> Date

    public convenience init(
        sessionManager: IMAPSessionManager,
        reachability: NetworkReachability = AlwaysOnlineReachability(),
        maxPerTick: Int = 10
    ) {
        self.init(
            sessionProvider: { accountID in
                sessionManager.sessionForWork(accountID: accountID)
            },
            reachability: reachability,
            maxPerTick: maxPerTick,
            activityReporter: sessionManager
        )
    }

    init(
        sessionProvider: @escaping @MainActor (UUID) -> (any ComposerDraftIMAPSyncing)?,
        reachability: NetworkReachability = AlwaysOnlineReachability(),
        maxPerTick: Int = 10,
        activityReporter: (any IMAPActivityReporting)? = nil,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionProvider = sessionProvider
        self.reachability = reachability
        self.maxPerTick = maxPerTick
        self.activityReporter = activityReporter
        self.currentDate = currentDate
    }

    @MainActor
    public static func hasPendingWork(context: ModelContext, now: Date = Date()) -> Bool {
        let drafts = (try? context.fetch(FetchDescriptor<Draft>())) ?? []
        // Restore unresolved outcomes into each launch's visible log without
        // performing another provider request. recordState deduplicates scans.
        for draft in drafts { publishBlockedCleanupIfNeeded(draft) }
        return drafts.contains(where: { isActionable($0, context: context, now: now) })
    }

    @MainActor
    public static func hasPendingWork(for draft: Draft?, context: ModelContext) -> Bool {
        guard let draft else { return false }
        return isActionable(draft, context: context)
    }

    @MainActor
    public func drain(context: ModelContext, now: Date = Date()) async throws -> Int {
        guard reachability.isOnline else { return 0 }
        let drafts = try context.fetch(FetchDescriptor<Draft>())
            .filter { Self.isActionable($0, context: context, now: now) }
            .sorted { Self.sortForDrain($0, $1) }
            .prefix(maxPerTick)

        if let accountID = drafts.compactMap({ Self.accountID(for: $0) }).first {
            activityReporter?.reportIMAPActivity(
                .syncingDrafts,
                accountID: accountID,
                folder: nil
            )
        }

        var processed = 0
        for draft in drafts {
            switch draft.status {
            case .pending:
                if try await syncPendingDraft(draft, context: context, now: now) {
                    processed += 1
                }
            case .confirmed, .sent, .rejected, .discarded:
                if try await deleteRemoteDraftIfNeeded(draft, context: context, now: now) {
                    processed += 1
                }
            }
        }
        return processed
    }

    @MainActor
    private func syncPendingDraft(_ draft: Draft, context: ModelContext, now: Date) async throws -> Bool {
        let storedFingerprint = DraftRemoteSyncFingerprint.value(for: draft)
        let storedBodyHTML = draft.bodyHTML
        let storedInlinePhotosJSON = draft.inlinePhotosJSON

        // Normalize the persisted alternative before fingerprinting so a
        // generated rich draft does not immediately look dirty again after
        // its first provider save.
        let fingerprintSlot = (try? requireAccount(for: draft, context: context))
            .flatMap { SignatureSlotResolver.slot(for: draft, account: $0) }
        draft.bodyHTML = ComposerMessageBodyHTML.resolve(for: draft, slot: fingerprintSlot)
        let referencedPhotos = ComposerInlinePhotoEncoder.referencedAssets(
            html: draft.bodyHTML,
            ownerID: draft.id,
            assets: ComposerInlinePhotoAssetCoding.decode(draft.inlinePhotosJSON)
        )
        draft.inlinePhotosJSON = ComposerInlinePhotoAssetCoding.encode(referencedPhotos)
        let fingerprint = DraftRemoteSyncFingerprint.value(for: draft)
        guard fingerprint != draft.mailboxDraftSyncFingerprint else { return false }
        guard let accountID = Self.accountID(for: draft) else {
            draft.mailboxDraftSyncError = "No IMAP session available for this draft's account."
            try context.save()
            return false
        }
        guard let session = sessionProvider(accountID) else {
            activityReporter?.failIMAPActivity(
                accountID: accountID,
                folder: draft.mailboxDraftFolderPath,
                requiresAttention: false,
                cause: .mailboxOperation,
                operationID: nil
            )
            draft.mailboxDraftSyncError = "No IMAP session available for this draft's account."
            try context.save()
            return false
        }

        let messageID = stableMessageID(for: draft)
        let payload = try buildPayload(for: draft, messageID: messageID, context: context)
        let normalizedBodyHTML = draft.bodyHTML
        let normalizedInlinePhotosJSON = draft.inlinePhotosJSON
        let previousFolder = draft.mailboxDraftFolderPath
        let previousUID = draft.mailboxDraftUID
        let previousUIDValidity = draft.mailboxDraftUIDValidity

        // Do not hold local content mutations on a SwiftData model across the
        // provider await. Composer may save a newer recipient/body from a
        // separate process while the upload is in flight; a later save of
        // this registered snapshot would otherwise restore the older values.
        draft.bodyHTML = storedBodyHTML
        draft.inlinePhotosJSON = storedInlinePhotosJSON

        activityReporter?.reportIMAPActivity(
            .savingDraft,
            accountID: accountID,
            folder: previousFolder
        )
        let remote: IMAPDraftRemoteLocation
        do {
            remote = try await session.saveDraft(
                preferredFolder: previousFolder,
                previousFolder: previousFolder,
                previousUID: previousUID,
                previousUIDValidity: previousUIDValidity,
                messageIDHeader: messageID,
                payload: payload,
                date: now
            )
        } catch {
            activityReporter?.failIMAPActivity(
                accountID: accountID,
                folder: previousFolder,
                requiresAttention: false,
                cause: IMAPSessionManager.attentionCause(for: error),
                operationID: nil
            )
            throw error
        }
        activityReporter?.completeIMAPActivity(accountID: accountID, folder: previousFolder, operationID: nil)

        // Re-fetch after the network boundary. The worker's original context
        // can still contain the pre-upload row snapshot, while Composer writes
        // through another process/context. Apply only provider metadata to the
        // authoritative row; apply normalization only when its content has not
        // changed since the upload began.
        let persistenceContext = ModelContext(context.container)
        let draftID = draft.id
        let descriptor = FetchDescriptor<Draft>(
            predicate: #Predicate<Draft> { $0.id == draftID }
        )
        guard let persistedDraft = try persistenceContext.fetch(descriptor).first else {
            // Composer deleted the local draft while the provider save was in
            // flight. Persist the provider location before attempting cleanup
            // so a failed or interrupted deletion remains retryable.
            context.rollback()
            _ = try context.fetch(descriptor).first
            let tombstone = try persistDetachedCleanupTombstone(
                accountID: accountID,
                remote: remote,
                now: now,
                context: persistenceContext
            )
            _ = try await deleteRemoteDraftIfNeeded(
                tombstone,
                context: persistenceContext,
                now: now
            )
            return true
        }
        if DraftRemoteSyncFingerprint.value(for: persistedDraft) == storedFingerprint {
            persistedDraft.bodyHTML = normalizedBodyHTML
            persistedDraft.inlinePhotosJSON = normalizedInlinePhotosJSON
        }
        persistedDraft.mailboxDraftAccountID = accountID
        persistedDraft.mailboxDraftFolderPath = remote.folder
        persistedDraft.mailboxDraftUID = remote.uid
        persistedDraft.mailboxDraftUIDValidity = remote.uidValidity
        persistedDraft.mailboxDraftMessageIDHeader = remote.messageIDHeader
        persistedDraft.mailboxDraftSyncFingerprint = fingerprint
        persistedDraft.mailboxDraftLastSyncedAt = now
        if let cleanupError = remote.cleanupErrorDescription,
           !cleanupError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            persistedDraft.mailboxDraftSyncError = "Provider draft saved; stale draft cleanup failed: \(cleanupError)"
        } else {
            persistedDraft.mailboxDraftSyncError = nil
        }
        try persistenceContext.save()
        context.rollback()
        _ = try context.fetch(descriptor).first
        return true
    }

    @MainActor
    private func persistDetachedCleanupTombstone(
        accountID: UUID,
        remote: IMAPDraftRemoteLocation,
        now: Date,
        context: ModelContext
    ) throws -> Draft {
        let tombstone = Draft.userCompose(fromAccountID: nil, identityID: nil)
        tombstone.kind = .replyToMessage
        tombstone.status = .discarded
        tombstone.mailboxDraftAccountID = accountID
        tombstone.mailboxDraftFolderPath = remote.folder
        tombstone.mailboxDraftUID = remote.uid
        tombstone.mailboxDraftUIDValidity = remote.uidValidity
        tombstone.mailboxDraftMessageIDHeader = remote.messageIDHeader
        tombstone.mailboxDraftLastSyncedAt = now
        tombstone.mailboxDraftSyncError = "Provider draft cleanup pending."
        context.insert(tombstone)
        try context.save()
        return tombstone
    }

    @MainActor
    private func deleteRemoteDraftIfNeeded(_ draft: Draft, context: ModelContext, now: Date) async throws -> Bool {
        let folder: String
        if let trackedFolder = draft.mailboxDraftFolderPath,
           draft.mailboxDraftUID != nil || draft.mailboxDraftMessageIDHeader != nil {
            folder = trackedFolder
        } else if Self.isRecoverableGmailDiscard(draft, context: context) {
            // Older cleanup falsely cleared the remote folder/UID after Gmail
            // accepted an in-place Drafts expunge but left the draft visible.
            // OAuth Gmail deletion ignores this placeholder and resolves the
            // provider draft by the retained stable Message-ID.
            folder = "Drafts"
        } else {
            return false
        }
        guard let accountID = draft.mailboxDraftAccountID ?? Self.accountID(for: draft) else {
            draft.mailboxDraftSyncError = "No IMAP session available for this draft's account."
            try context.save()
            return false
        }
        let activity = SessionActivityEvent(operation: "Deleting Draft", phase: .started,
            subject: draft.composeSubject ?? draft.message?.subject, accountID: accountID,
            detail: folder, operationID: draft.id)
        let targetKey = Self.cleanupTargetKey(draft)
        SessionActivityLog.shared.recordState(activity, channel: "draft-cleanup-\(draft.id)")
        guard let session = sessionProvider(accountID) else {
            try recordCleanupFailure(IMAPError.notConnected, draft: draft,
                targetKey: targetKey, activity: activity, context: context, now: now)
            return false
        }

        activityReporter?.reportIMAPActivity(
            .deletingDraft,
            accountID: accountID,
            folder: folder
        )
        do {
            try await session.deleteDraft(
                folder: folder,
                uid: draft.mailboxDraftUID,
                uidValidity: draft.mailboxDraftUIDValidity,
                messageIDHeader: draft.mailboxDraftMessageIDHeader
            )
        } catch {
            let imapCancelled: Bool
            if let imap = error as? IMAPError, case .cancelled = imap { imapCancelled = true }
            else { imapCancelled = false }
            if error is CancellationError || imapCancelled || Task.isCancelled {
                SessionActivityLog.shared.recordState(activity.ending(.cancelled), channel: "draft-cleanup-\(draft.id)")
                activityReporter?.reportIMAPActivity(.pending, accountID: accountID, folder: folder)
                throw CancellationError()
            }
            try recordCleanupFailure(error, draft: draft, targetKey: targetKey,
                activity: activity, context: context, now: now)
            // One blocked provider draft must not starve later cleanup or saves.
            return false
        }

        // Re-read after the provider await. Never clear a replacement location
        // or overwrite changes saved by Composer while deletion was in flight.
        let persistenceContext = ModelContext(context.container)
        let draftID = draft.id
        let descriptor = FetchDescriptor<Draft>(predicate: #Predicate<Draft> { $0.id == draftID })
        guard let persistedDraft = try persistenceContext.fetch(descriptor).first else {
            SessionActivityLog.shared.recordState(activity.ending(.finished,
                detail: "\(folder) · Server cleanup verified; local draft already removed."),
                channel: "draft-cleanup-\(draftID)")
            activityReporter?.completeIMAPActivity(accountID: accountID, folder: folder, operationID: nil)
            context.rollback()
            _ = try context.fetch(descriptor).first
            return true
        }
        guard Self.cleanupTargetKey(persistedDraft) == targetKey else {
            SessionActivityLog.shared.recordState(activity.ending(.finished,
                detail: "\(folder) · Previous server draft cleanup verified; a newer target remains queued."),
                channel: "draft-cleanup-\(draftID)")
            activityReporter?.completeIMAPActivity(accountID: accountID, folder: folder, operationID: nil)
            context.rollback()
            _ = try context.fetch(descriptor).first
            return true
        }
        let draft = persistedDraft
        let previousFailures = draft.mailboxDraftCleanupTargetKey == targetKey
            ? draft.mailboxDraftCleanupFailureCount ?? 0 : 0

        let ownerID = draft.id
        let isDetachedReplyTombstone = Self.isDetachedReplyCleanupTombstone(draft)
        let shouldDeleteAssets = isDetachedReplyTombstone || draft.status == .discarded
        if isDetachedReplyTombstone {
            persistenceContext.delete(draft)
        } else {
            if shouldDeleteAssets {
                draft.inlinePhotosJSON = nil
            }
            draft.mailboxDraftFolderPath = nil
            draft.mailboxDraftUID = nil
            draft.mailboxDraftUIDValidity = nil
            draft.mailboxDraftMessageIDHeader = nil
            draft.mailboxDraftSyncFingerprint = nil
            draft.mailboxDraftLastSyncedAt = now
            draft.mailboxDraftSyncError = nil
            Self.clearCleanupRetry(draft)
        }
        do { try persistenceContext.save() }
        catch {
            SessionActivityLog.shared.recordState(activity.ending(.failed,
                detail: "Server cleanup completed, but its local result could not be saved: \(error.localizedDescription)"),
                channel: "draft-cleanup-\(draftID)")
            throw error
        }
        context.rollback()
        _ = try context.fetch(descriptor).first
        SessionActivityLog.shared.recordState(activity.ending(.finished,
            detail: "\(folder) · Server cleanup verified."
                + (previousFailures > 0 ? " Recovered after \(previousFailures) failed attempts." : "")),
            channel: "draft-cleanup-\(draftID)")
        activityReporter?.completeIMAPActivity(accountID: accountID, folder: folder, operationID: nil)
        if shouldDeleteAssets {
            ComposerDraftAssetCleanup.deleteAll(ownerID: ownerID)
        }
        return true
    }

    @MainActor
    private func recordCleanupFailure(
        _ error: Error, draft: Draft, targetKey: String, activity: SessionActivityEvent,
        context: ModelContext, now: Date
    ) throws {
        let persistenceContext = ModelContext(context.container)
        let draftID = draft.id
        let descriptor = FetchDescriptor<Draft>(predicate: #Predicate<Draft> { $0.id == draftID })
        guard let persisted = try persistenceContext.fetch(descriptor).first,
              Self.cleanupTargetKey(persisted) == targetKey else {
            SessionActivityLog.shared.recordState(activity.ending(.ended,
                detail: "Cleanup target changed while the request was running; current target remains queued."),
                channel: "draft-cleanup-\(draftID)")
            if let accountID = activity.accountID {
                activityReporter?.failIMAPActivity(accountID: accountID, folder: activity.detail,
                    requiresAttention: false, cause: IMAPSessionManager.attentionCause(for: error), operationID: nil)
            }
            context.rollback()
            _ = try context.fetch(descriptor).first
            return
        }
        let previousCount = persisted.mailboxDraftCleanupTargetKey == targetKey
            ? persisted.mailboxDraftCleanupFailureCount ?? 0 : 0
        let failures = previousCount + 1
        let blocked = JobErrorClassifier.isPermanent(error) || Self.permanentGmailFailure(error) || failures >= 5
        persisted.mailboxDraftCleanupTargetKey = targetKey
        persisted.mailboxDraftCleanupFailureCount = failures
        persisted.mailboxDraftSyncError = error.localizedDescription
        let detail: String
        if blocked {
            detail = "\(activity.detail ?? "Drafts") · \(error.localizedDescription)\nAutomatic retries paused"
                + (failures >= 5 ? " after \(failures) attempts" : " because this failure requires intervention")
                + ". Retry after correcting the account or draft reference."
            persisted.mailboxDraftCleanupBlockedReason = detail
            persisted.mailboxDraftCleanupNextAttemptAt = nil
        } else {
            // A slow provider request must not consume its own retry delay.
            let retryAt = max(now, currentDate()).addingTimeInterval(JobQueue.backoffDelay(for: failures))
            persisted.mailboxDraftCleanupBlockedReason = nil
            persisted.mailboxDraftCleanupNextAttemptAt = retryAt
            detail = "\(activity.detail ?? "Drafts") · Attempt \(failures) failed: \(error.localizedDescription)\nAutomatic retry scheduled for \(retryAt.formatted(date: .abbreviated, time: .standard))."
        }
        do { try persistenceContext.save() }
        catch {
            SessionActivityLog.shared.recordState(activity.ending(.failed,
                detail: "Cleanup failed and its retry state could not be saved: \(error.localizedDescription)"),
                channel: "draft-cleanup-\(draftID)")
            throw error
        }
        context.rollback()
        _ = try context.fetch(descriptor).first
        SessionActivityLog.shared.recordState(activity.ending(blocked ? .blocked : .retryScheduled, detail: detail),
            channel: "draft-cleanup-\(draftID)")
        if let accountID = activity.accountID {
            activityReporter?.failIMAPActivity(accountID: accountID, folder: activity.detail,
                requiresAttention: blocked, cause: IMAPSessionManager.attentionCause(for: error), operationID: nil)
        }
    }

    private static func permanentGmailFailure(_ error: Error) -> Bool {
        guard let error = error as? GmailDraftAPIError else { return false }
        switch error {
        case .requestFailed(let code): return (400..<500).contains(code) && code != 408 && code != 429
        case .missingMessageID, .invalidRequest, .invalidResponse, .deletionNotConfirmed: return true
        }
    }

    @MainActor
    private static func cleanupTargetKey(_ draft: Draft) -> String {
        [draft.mailboxDraftAccountID?.uuidString ?? accountID(for: draft)?.uuidString ?? "",
         draft.mailboxDraftFolderPath ?? "", draft.mailboxDraftUID.map(String.init) ?? "",
         draft.mailboxDraftUIDValidity.map(String.init) ?? "", draft.mailboxDraftMessageIDHeader ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }

    @MainActor
    private static func clearCleanupRetry(_ draft: Draft) {
        draft.mailboxDraftCleanupTargetKey = nil
        draft.mailboxDraftCleanupFailureCount = nil
        draft.mailboxDraftCleanupNextAttemptAt = nil
        draft.mailboxDraftCleanupBlockedReason = nil
    }

    @MainActor
    private static func publishBlockedCleanupIfNeeded(_ draft: Draft) {
        guard draft.status != .pending,
              draft.mailboxDraftCleanupTargetKey == cleanupTargetKey(draft),
              let reason = draft.mailboxDraftCleanupBlockedReason else { return }
        SessionActivityLog.shared.recordState(SessionActivityEvent(operation: "Deleting Draft", phase: .blocked,
            subject: draft.composeSubject ?? draft.message?.subject,
            accountID: draft.mailboxDraftAccountID ?? accountID(for: draft), detail: reason, operationID: draft.id),
            channel: "draft-cleanup-\(draft.id)")
    }

    /// Explicit user retry after correcting the account/reference. The reset
    /// and queue insertion share a save, so a restart cannot lose the request.
    @MainActor
    @discardableResult
    public static func retryCleanup(draftID: UUID, context: ModelContext) throws -> Bool {
        let descriptor = FetchDescriptor<Draft>(predicate: #Predicate<Draft> { $0.id == draftID })
        guard let draft = try context.fetch(descriptor).first, draft.status != .pending,
              draft.mailboxDraftCleanupBlockedReason != nil else { return false }
        guard terminalDraftHasIMAPCleanupTarget(draft, context: context) else {
            throw IMAPError.protocolViolation("Enable or reauthorize the draft's account before retrying cleanup.")
        }
        clearCleanupRetry(draft)
        try ComposerDraftSyncScheduler.stageDraftSync(draft: draft, context: context)
        try context.save()
        return true
    }

    @MainActor
    private func buildPayload(for draft: Draft, messageID: String, context: ModelContext) throws -> Data {
        let account = try requireAccount(for: draft, context: context)
        let identity = try requireIdentity(for: draft, account: account)
        let parsedFrom = try MailAddressParser.parseOne(identity.address)
            .withDisplayName(identity.displayName)
        let slot = SignatureSlotResolver.slot(for: draft, account: account)
        let htmlBody = ComposerMessageBodyHTML.resolve(for: draft, slot: slot)
        draft.bodyHTML = htmlBody

        // Provider-mailbox draft copies carry the same cid-referenced
        // inline images as a real send, so other clients render them.
        var sendHTML = htmlBody
        var inlineImages: [MessageBuilder.InlineImage] = []
        if let htmlBody, let slot, !slot.images.isEmpty {
            let encoded = SignatureInlineImageEncoder.encodeForSend(
                html: htmlBody, slot: slot, store: SignatureAssetStore()
            )
            sendHTML = encoded.html
            inlineImages.append(contentsOf: encoded.images.map {
                MessageBuilder.InlineImage(
                    path: $0.path, contentID: $0.contentID, mimeType: $0.mimeType
                )
            })
        }
        let composerPhotos = ComposerInlinePhotoAssetCoding.decode(draft.inlinePhotosJSON)
        if let currentHTML = sendHTML, !composerPhotos.isEmpty {
            let encoded = ComposerInlinePhotoEncoder.encodeForSend(
                html: currentHTML,
                ownerID: draft.id,
                assets: composerPhotos,
                store: ComposerInlinePhotoStore()
            )
            sendHTML = encoded.html
            inlineImages.append(contentsOf: encoded.images.map {
                MessageBuilder.InlineImage(
                    path: $0.path, contentID: $0.contentID, mimeType: $0.mimeType
                )
            })
        }

        if draft.kind == .userCompose {
            return try MessageBuilder.build(envelope: MessageBuilder.Envelope(
                from: parsedFrom,
                replyTo: parseReplyTo(identity.replyTo),
                to: try parseAddresses(draft.composeToJSON),
                cc: try parseAddresses(draft.composeCcJSON),
                bcc: try parseAddresses(draft.composeBccJSON),
                subject: draft.composeSubject ?? "",
                messageID: messageID,
                plainBody: draft.replyText,
                htmlBody: sendHTML,
                attachments: ComposeAddressEncoding.decode(draft.deliverablesJSON),
                inlineImages: inlineImages,
                date: Date(),
                includeBccHeader: true
            ))
        }

        guard let message = draft.message else {
            throw IMAPError.protocolViolation("reply draft has no source message")
        }
        let references: String? = {
            var parts: [String] = []
            if let chain = message.referencesChain, !chain.isEmpty { parts.append(chain) }
            if let mid = message.messageIdHeader { parts.append(mid) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }()
        let subject = message.subject.hasPrefix("Re: ") ? message.subject : "Re: \(message.subject)"
        let defaults = ReplyRecipientPolicy.defaultRecipients(
            for: message,
            mode: draft.resolvedReplyRecipientMode
        )
        let to: [EmailAddress]
        if let toJSON = draft.replyToAddressesJSON {
            to = try parseAddresses(toJSON)
        } else {
            to = try parseAddresses(defaults.to)
        }
        guard !to.isEmpty else {
            throw IMAPError.protocolViolation("reply draft has no recipient")
        }
        let cc = try draft.replyCcAddressesJSON.map(parseAddresses) ?? parseAddresses(defaults.cc)
        let bcc = try draft.replyBccAddressesJSON.map(parseAddresses) ?? parseAddresses(defaults.bcc)
        return try MessageBuilder.build(envelope: MessageBuilder.Envelope(
            from: parsedFrom,
            replyTo: parseReplyTo(identity.replyTo),
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            messageID: messageID,
            inReplyTo: message.messageIdHeader,
            referencesChain: references,
            plainBody: draft.replyText,
            htmlBody: sendHTML,
            attachments: ComposeAddressEncoding.decode(draft.replyAttachmentPathsJSON),
            inlineImages: inlineImages,
            date: Date(),
            includeBccHeader: !bcc.isEmpty
        ))
    }

    @MainActor
    private func stableMessageID(for draft: Draft) -> String {
        if let stored = draft.mailboxDraftMessageIDHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored.hasPrefix("<") ? stored : "<\(stored)>"
        }
        return "<draft-\(draft.id.uuidString)@ohia.local>"
    }

    @MainActor
    private func requireAccount(for draft: Draft, context: ModelContext) throws -> Account {
        guard let accountID = Self.accountID(for: draft),
              let account = Self.fetchAccount(id: accountID, context: context) else {
            throw IMAPError.protocolViolation("draft has no account")
        }
        return account
    }

    @MainActor
    private func requireIdentity(for draft: Draft, account: Account) throws -> Identity {
        if let identity = account.resolveIdentity(for: draft.fromIdentityID) {
            return identity
        }
        if let primary = account.primaryIdentity {
            return primary
        }
        throw IMAPError.protocolViolation("draft account has no send identity")
    }

    @MainActor
    private static func accountID(for draft: Draft) -> UUID? {
        if draft.kind == .userCompose {
            return draft.composeFromAccountID ?? draft.mailboxDraftAccountID
        }
        return draft.message?.accountID ?? draft.message?.account?.id
    }

    private static func shouldConsider(_ draft: Draft) -> Bool {
        if draft.kind == .userCompose { return true }
        if draft.message != nil { return true }
        return isDetachedReplyCleanupTombstone(draft)
    }

    private static func isDetachedReplyCleanupTombstone(_ draft: Draft) -> Bool {
        guard draft.kind != .userCompose,
              draft.message == nil,
              draft.mailboxDraftAccountID != nil,
              draft.mailboxDraftFolderPath != nil,
              draft.mailboxDraftUID != nil || draft.mailboxDraftMessageIDHeader != nil else {
            return false
        }
        switch draft.status {
        case .confirmed, .sent, .rejected, .discarded:
            return true
        case .pending:
            return false
        }
    }

    @MainActor
    private static func isActionable(_ draft: Draft, context: ModelContext, now: Date = Date()) -> Bool {
        guard shouldConsider(draft) else { return false }
        switch draft.status {
        case .pending:
            return accountIsIMAPSyncCapable(for: draft, context: context)
                && DraftRemoteSyncFingerprint.value(for: draft) != draft.mailboxDraftSyncFingerprint
        case .confirmed, .sent, .rejected, .discarded:
            if draft.mailboxDraftCleanupTargetKey == cleanupTargetKey(draft) {
                if draft.mailboxDraftCleanupBlockedReason != nil { return false }
                if let retryAt = draft.mailboxDraftCleanupNextAttemptAt, retryAt > now { return false }
            }
            return terminalDraftHasIMAPCleanupTarget(draft, context: context)
                && (
                    (draft.mailboxDraftFolderPath != nil
                        && (draft.mailboxDraftUID != nil || draft.mailboxDraftMessageIDHeader != nil))
                    || isRecoverableGmailDiscard(draft, context: context)
                )
        }
    }

    @MainActor
    private static func accountIsIMAPSyncCapable(for draft: Draft, context: ModelContext) -> Bool {
        guard let accountID = accountID(for: draft) else { return false }
        return accountIsIMAPSyncCapable(accountID: accountID, context: context)
    }

    @MainActor
    private static func terminalDraftHasIMAPCleanupTarget(_ draft: Draft, context: ModelContext) -> Bool {
        guard let accountID = draft.mailboxDraftAccountID ?? accountID(for: draft) else { return false }
        return accountIsIMAPSyncCapable(accountID: accountID, context: context)
    }

    @MainActor
    private static func isRecoverableGmailDiscard(_ draft: Draft, context: ModelContext) -> Bool {
        guard draft.kind == .userCompose,
              draft.status == .discarded,
              draft.mailboxDraftFolderPath == nil,
              draft.mailboxDraftUID == nil,
              draft.mailboxDraftLastSyncedAt != nil,
              let messageID = draft.mailboxDraftMessageIDHeader?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              !messageID.isEmpty,
              let accountID = draft.mailboxDraftAccountID ?? accountID(for: draft),
              let account = fetchAccount(id: accountID, context: context),
              account.imapAuthMethod == .oauth2,
              let host = account.imapHost?.lowercased() else {
            return false
        }
        return host.contains("gmail") || host.contains("google")
    }

    @MainActor
    private static func accountIsIMAPSyncCapable(accountID: UUID, context: ModelContext) -> Bool {
        guard let account = fetchAccount(id: accountID, context: context) else { return false }
        return accountIsIMAPSyncCapable(account)
    }

    private static func accountIsIMAPSyncCapable(_ account: Account) -> Bool {
        account.status != .paused
            && !account.needsImapReauth
            && account.imapHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && account.imapPort != nil
            && account.imapSecurity != nil
            && account.imapAuthMethod != nil
            && account.imapKeychainRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    @MainActor
    private static func sortForDrain(_ lhs: Draft, _ rhs: Draft) -> Bool {
        if lhs.generatedAt != rhs.generatedAt {
            return lhs.generatedAt < rhs.generatedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    @MainActor
    private static func fetchAccount(id: UUID, context: ModelContext) -> Account? {
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func parseAddresses(_ json: String?) throws -> [EmailAddress] {
        try ComposeAddressEncoding.decode(json).map { try MailAddressParser.parseOne($0) }
    }

    private func parseAddresses(_ addresses: [String]) throws -> [EmailAddress] {
        try addresses.map { try MailAddressParser.parseOne($0) }
    }

    private func parseReplyTo(_ raw: String?) -> EmailAddress? {
        guard let raw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try? MailAddressParser.parseOne(raw)
    }
}
