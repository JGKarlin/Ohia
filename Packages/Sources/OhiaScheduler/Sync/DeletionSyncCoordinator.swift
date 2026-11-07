import Foundation
import SwiftData
import OhiaCore
import OhiaMail
import OhiaML

@MainActor
public final class DeletionSyncCoordinator {
    private struct LocalFolderMessage {
        let message: Message
        let messageID: UUID
        let uid: UInt32
        let messageIdHeader: String?
    }

    private struct GatheredMessageData {
        let knownUIDMessages: [(messageID: UUID, uid: UInt32, messageIdHeader: String?)]
        let localFolderMessages: [LocalFolderMessage]
        let accountMessages: [LocalFolderMessage]
        let accountMessageIdCounts: [String: Int]
    }

    private struct MessageIDReconciliationResult {
        var decisions: [MessageDeletionDecision] = []
        var linkedUIDCount = 0
    }

    private let modelContext: ModelContext
    private let applier: MessageDeletionApplier
    private let status: DeletionSyncStatusPublisher
    private let nonGmailGracePeriodSecondsProvider: () -> TimeInterval

    public init(
        modelContext: ModelContext,
        applier: MessageDeletionApplier,
        status: DeletionSyncStatusPublisher,
        nonGmailGracePeriodSecondsProvider: @escaping () -> TimeInterval = {
            DeletionSyncPreferences.nonGmailGracePeriodSeconds()
        }
    ) {
        self.modelContext = modelContext
        self.applier = applier
        self.status = status
        self.nonGmailGracePeriodSecondsProvider = nonGmailGracePeriodSecondsProvider
    }

    @discardableResult
    public func handle(
        event: IMAPDeletionEvent,
        accountID: UUID,
        onDeletionApplied: @MainActor ([UUID]) -> Void = { _ in }
    ) async throws -> [UUID] {
        let role = classifyIMAPFolderRole(folder: event.folder, attributes: event.folderAttributes)
        if IMAPFolderIngestionPolicy.isDraftsFolder(folderName: event.folder, attributes: event.folderAttributes) {
            try reconcileMailboxDrafts(event: event, accountID: accountID)
            try updateFolderState(accountID: accountID, event: event, decisions: [])
            status.recordSync(folder: event.folder, capability: .qresync, at: event.observedAt)
            return []
        }

        let isGmail = try isGmailAccount(accountID: accountID)
        let gathered = try gatherMessageData(accountID: accountID, folder: event.folder, isGmail: isGmail)
        let nonGmailGracePeriodSeconds = max(0, nonGmailGracePeriodSecondsProvider())
        let input = MessageDeletionDeciderInput(
            accountID: accountID,
            folder: event.folder,
            folderRole: role,
            isGmailAccount: isGmail,
            uidValidityBefore: event.uidValidityBefore,
            uidValidityAfter: event.uidValidityAfter,
            highestModSeqBefore: event.highestModSeqBefore,
            vanishedUIDs: event.vanishedUIDs,
            knownLocalMessages: gathered.knownUIDMessages,
            accountMessageIdCounts: gathered.accountMessageIdCounts,
            nonGmailGracePeriodSeconds: nonGmailGracePeriodSeconds
        )
        var decisions = decideMessageDeletions(input, now: event.observedAt)
        decisions.append(contentsOf: firstSyncUIDReconciliationDecisions(
            event: event,
            accountID: accountID,
            knownLocalMessages: gathered.knownUIDMessages,
            seedDecisions: decisions
        ))
        let messageIDReconciliation = try reconcileServerMessageIDs(
            event: event,
            accountID: accountID,
            folderRole: role,
            isGmail: isGmail,
            localFolderMessages: isGmail && role == .gmailAll
                ? gathered.accountMessages
                : gathered.localFolderMessages,
            accountMessageIdCounts: gathered.accountMessageIdCounts,
            nonGmailGracePeriodSeconds: nonGmailGracePeriodSeconds
        )
        decisions.append(contentsOf: messageIDReconciliation.decisions)
        decisions = deduplicateDestructiveDecisions(decisions)

        let applied = try await applier.apply(decisions)
        if applied.appliedMessageIDs.isEmpty == false {
            // Publish immediately after the atomic deletion save. Folder
            // cursor and deferred-candidate bookkeeping below can fail
            // independently without losing the committed message identity.
            onDeletionApplied(applied.appliedMessageIDs)
        }
        try stageDeferredCandidates(decisions: decisions, event: event)
        if messageIDReconciliation.linkedUIDCount > 0 {
            try modelContext.save()
        }

        try updateFolderState(accountID: accountID, event: event, decisions: decisions)
        if decisions.isEmpty || decisions.allSatisfy({ decision in
            if case .skipUidValidityChanged = decision { return false }
            return true
        }) {
            status.recordSync(folder: event.folder, capability: .qresync, at: event.observedAt)
        }
        return applied.appliedMessageIDs
    }

    /// Single-pass fetch: returns both the per-folder known-local list and the
    /// account-wide Message-ID header count map. Avoids two full table scans.
    /// For Gmail accounts `messageIdCounts` is always empty (not needed by that
    /// branch) so we skip the header-counting work via the `isGmail` flag.
    private func gatherMessageData(
        accountID: UUID,
        folder: String,
        isGmail: Bool
    ) throws -> GatheredMessageData {
        let accountDescriptor = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
        let account = try modelContext.fetch(accountDescriptor).first
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { m in
            m.accountID == accountID || m.account?.id == accountID
        })
        let messages = try modelContext.fetch(descriptor)
        var known: [(messageID: UUID, uid: UInt32, messageIdHeader: String?)] = []
        var localFolderMessages: [LocalFolderMessage] = []
        var accountMessages: [LocalFolderMessage] = []
        var counts: [String: Int] = [:]
        for message in messages {
            // A source-folder VANISHED is the expected provider consequence of
            // Ohia's own move-to-Trash. The retained row and its artifacts must
            // survive until explicit Restore or provider-confirmed permanent
            // deletion.
            if message.isTrashed { continue }
            if let account,
               !account.acceptsExistingMessageIngestionWindow(
                   receivedAt: message.receivedAt,
                   sentAt: message.sentAt
               ) {
                continue
            }
            let entry = LocalFolderMessage(
                message: message,
                messageID: message.id,
                uid: message.imapUID,
                messageIdHeader: message.messageIdHeader
            )
            accountMessages.append(entry)
            if !isGmail, let mid = normalizeMessageIDHeader(message.messageIdHeader) {
                counts[mid, default: 0] += 1
            }
            if message.imapFolderPath == folder {
                localFolderMessages.append(entry)
                if message.imapUID > 0 {
                    known.append((
                        messageID: message.id,
                        uid: message.imapUID,
                        messageIdHeader: message.messageIdHeader
                    ))
                }
            }
        }
        return GatheredMessageData(
            knownUIDMessages: known,
            localFolderMessages: localFolderMessages,
            accountMessages: accountMessages,
            accountMessageIdCounts: counts
        )
    }

    private func firstSyncUIDReconciliationDecisions(
        event: IMAPDeletionEvent,
        accountID: UUID,
        knownLocalMessages: [(messageID: UUID, uid: UInt32, messageIdHeader: String?)],
        seedDecisions: [MessageDeletionDecision]
    ) -> [MessageDeletionDecision] {
        guard let serverUids = event.serverUidSetForReconciliation else { return [] }
        let isFirstSyncDecision = seedDecisions.contains {
            if case .skipFirstSync = $0 { return true }
            return false
        }
        guard isFirstSyncDecision else { return [] }

        // Safety guard: an empty server UID set with many local messages looks
        // like a transient SEARCH glitch, not a real "everything deleted."
        guard !(serverUids.isEmpty && knownLocalMessages.count > 100) else {
            return []
        }
        let serverSet = Set(serverUids)
        return knownLocalMessages
            .filter { !serverSet.contains($0.uid) }
            .map { entry in
                .delete(
                    messageID: entry.messageID,
                    accountID: accountID,
                    folder: event.folder,
                    uid: entry.uid
                )
            }
    }

    private func reconcileServerMessageIDs(
        event: IMAPDeletionEvent,
        accountID: UUID,
        folderRole: IMAPFolderRole,
        isGmail: Bool,
        localFolderMessages: [LocalFolderMessage],
        accountMessageIdCounts: [String: Int],
        nonGmailGracePeriodSeconds: TimeInterval
    ) throws -> MessageIDReconciliationResult {
        guard let serverRows = event.serverMessageIDsForReconciliation else {
            return MessageIDReconciliationResult()
        }
        let localWithHeaders = localFolderMessages.compactMap { entry -> (LocalFolderMessage, String)? in
            guard let normalized = normalizeMessageIDHeader(entry.messageIdHeader) else { return nil }
            return (entry, normalized)
        }
        guard !localWithHeaders.isEmpty else {
            return MessageIDReconciliationResult()
        }

        var serverUIDByMessageID: [String: UInt32] = [:]
        serverUIDByMessageID.reserveCapacity(serverRows.count)
        for row in serverRows {
            guard let normalized = normalizeMessageIDHeader(row.messageID) else { continue }
            serverUIDByMessageID[normalized] = row.uid
        }

        // Safety guard: empty ENVELOPE snapshots can happen when a server or
        // parser omits Message-ID. Never mass-delete on an empty header map.
        guard !(serverUIDByMessageID.isEmpty && localWithHeaders.count > 100) else {
            return MessageIDReconciliationResult()
        }

        var result = MessageIDReconciliationResult()
        for (entry, normalized) in localWithHeaders {
            if let serverUID = serverUIDByMessageID[normalized] {
                let shouldCanonicalizeGmailAll = isGmail && folderRole == .gmailAll
                if entry.uid != serverUID {
                    entry.message.imapUID = serverUID
                    result.linkedUIDCount += 1
                }
                if shouldCanonicalizeGmailAll && entry.message.imapFolderPath != event.folder {
                    entry.message.imapFolderPath = event.folder
                    result.linkedUIDCount += 1
                }
                continue
            }

            if isGmail {
                guard folderRole == .gmailAll else { continue }
                result.decisions.append(.delete(
                    messageID: entry.messageID,
                    accountID: accountID,
                    folder: event.folder,
                    uid: entry.uid
                ))
            } else {
                let count = accountMessageIdCounts[normalized] ?? 0
                if count > 1 {
                    result.decisions.append(.skipMoveDetected(
                        folder: event.folder,
                        uid: entry.uid,
                        messageIdHeader: entry.messageIdHeader
                    ))
                } else if nonGmailGracePeriodSeconds == 0 {
                    result.decisions.append(.delete(
                        messageID: entry.messageID,
                        accountID: accountID,
                        folder: event.folder,
                        uid: entry.uid
                    ))
                } else {
                    result.decisions.append(.deferToGracePeriod(
                        messageID: entry.messageID,
                        accountID: accountID,
                        folder: event.folder,
                        uid: entry.uid,
                        messageIdHeader: entry.messageIdHeader,
                        deferUntil: event.observedAt.addingTimeInterval(nonGmailGracePeriodSeconds)
                    ))
                }
            }
        }
        return result
    }

    private func reconcileMailboxDrafts(event: IMAPDeletionEvent, accountID: UUID) throws {
        let drafts = try modelContext.fetch(FetchDescriptor<Draft>()).filter { draft in
            (draft.mailboxDraftAccountID == accountID || draft.composeFromAccountID == accountID)
                && draft.mailboxDraftFolderPath == event.folder
                && draft.status == .pending
        }
        guard !drafts.isEmpty else { return }

        let vanishedUIDs = Set(event.vanishedUIDs)
        let serverUIDs = event.serverUidSetForReconciliation.map(Set.init)
        let serverRowsByMessageID: [String: IMAPUIDMessageID]? = event.serverMessageIDsForReconciliation.map { rows in
            Dictionary(
                rows.compactMap { row in
                    normalizeMessageIDHeader(row.messageID).map { ($0, row) }
                },
                uniquingKeysWith: { first, _ in first }
            )
        }

        var changed = false
        for draft in drafts {
            if let normalized = normalizeMessageIDHeader(draft.mailboxDraftMessageIDHeader),
               let serverRowsByMessageID {
                guard let serverRow = serverRowsByMessageID[normalized] else {
                    modelContext.delete(draft)
                    changed = true
                    continue
                }
                if draft.mailboxDraftUID != serverRow.uid {
                    draft.mailboxDraftUID = serverRow.uid
                    changed = true
                }
                if draft.mailboxDraftUIDValidity != event.uidValidityAfter {
                    draft.mailboxDraftUIDValidity = event.uidValidityAfter
                    changed = true
                }
                continue
            }

            guard let uid = draft.mailboxDraftUID, uid > 0 else { continue }
            if let storedUIDValidity = draft.mailboxDraftUIDValidity,
               storedUIDValidity != event.uidValidityAfter {
                if DraftRemoteSyncFingerprint.value(for: draft) == draft.mailboxDraftSyncFingerprint {
                    modelContext.delete(draft)
                } else {
                    draft.mailboxDraftUID = nil
                    draft.mailboxDraftUIDValidity = nil
                    draft.mailboxDraftSyncFingerprint = nil
                    draft.mailboxDraftSyncError = nil
                }
                changed = true
                continue
            }

            if vanishedUIDs.contains(uid) || serverUIDs?.contains(uid) == false {
                modelContext.delete(draft)
                changed = true
            }
        }

        if changed {
            try modelContext.save()
        }
    }

    private func deduplicateDestructiveDecisions(_ decisions: [MessageDeletionDecision]) -> [MessageDeletionDecision] {
        var deleteIDs = Set<UUID>()
        for decision in decisions {
            if case .delete(let messageID, _, _, _) = decision {
                deleteIDs.insert(messageID)
            }
        }

        var emittedDeletes = Set<UUID>()
        var emittedDefers = Set<UUID>()
        var out: [MessageDeletionDecision] = []
        out.reserveCapacity(decisions.count)
        for decision in decisions {
            switch decision {
            case .delete(let messageID, _, _, _):
                guard emittedDeletes.insert(messageID).inserted else { continue }
                out.append(decision)
            case .deferToGracePeriod(let messageID, _, _, _, _, _):
                guard !deleteIDs.contains(messageID) else { continue }
                guard emittedDefers.insert(messageID).inserted else { continue }
                out.append(decision)
            default:
                out.append(decision)
            }
        }
        return out
    }

    /// Returns true when the account's IMAP host indicates a Gmail/Google server
    /// (advertises X-GM-EXT-1). Mirrors the detection used in `IMAPSession`.
    /// Fallback to false (safe: treats as non-Gmail).
    private func isGmailAccount(accountID: UUID) throws -> Bool {
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
        guard let account = try modelContext.fetch(descriptor).first else { return false }
        guard let host = account.imapHost?.lowercased() else { return false }
        return host.contains("gmail") || host.contains("google")
    }

    private func updateFolderState(
        accountID: UUID,
        event: IMAPDeletionEvent,
        decisions: [MessageDeletionDecision]
    ) throws {
        let folderState = try fetchOrCreateFolderState(accountID: accountID, event: event)
        let uidValidityChanged = decisions.contains {
            if case .skipUidValidityChanged = $0 { return true }
            return false
        }

        if uidValidityChanged {
            folderState.uidValidity = event.uidValidityAfter
            folderState.highestModSeq = nil
            folderState.highestFetchedUID = 0
            folderState.lowestFetchedUID = 0
            folderState.backfillComplete = false
            folderState.lastDeletionSyncAt = event.observedAt
            folderState.updatedAt = Date()
            try modelContext.save()
            return
        }

        folderState.uidValidity = event.uidValidityAfter
        if let highestModSeqAfter = event.highestModSeqAfter {
            folderState.highestModSeq = highestModSeqAfter
        }
        folderState.lastDeletionSyncAt = event.observedAt
        if event.serverMessageIDsForReconciliation != nil {
            folderState.lastMessageIDReconciliationAt = event.observedAt
        }
        folderState.updatedAt = Date()
        try modelContext.save()
    }

    /// Inserts `PendingDeletionCandidate` rows for any `.deferToGracePeriod`
    /// decisions in the batch. Spec §5 assigns this responsibility to the
    /// coordinator, not the applier. The applier reports the count via
    /// `AppliedSummary.deferredToGracePeriod`; the coordinator persists rows
    /// and updates the publisher.
    private func stageDeferredCandidates(
        decisions: [MessageDeletionDecision],
        event: IMAPDeletionEvent
    ) throws {
        var inserted = 0
        for decision in decisions {
            if case let .deferToGracePeriod(messageID, accountID, folder, uid, header, deferUntil) = decision {
                guard try !pendingCandidateExists(messageID: messageID, folder: folder, uid: uid) else {
                    continue
                }
                let candidate = PendingDeletionCandidate(
                    accountID: accountID,
                    messageID: messageID,
                    folder: folder,
                    uid: uid,
                    messageIdHeader: header,
                    vanishedAt: event.observedAt,
                    gracePeriodEndsAt: deferUntil
                )
                modelContext.insert(candidate)
                inserted += 1
            }
        }
        if inserted > 0 {
            try modelContext.save()
            let allPending = try modelContext.fetch(FetchDescriptor<PendingDeletionCandidate>())
            status.updatePendingCount(allPending.count)
        }
    }

    private func pendingCandidateExists(messageID: UUID, folder: String, uid: UInt32) throws -> Bool {
        let descriptor = FetchDescriptor<PendingDeletionCandidate>(predicate: #Predicate { candidate in
            candidate.messageID == messageID
        })
        let matches = try modelContext.fetch(descriptor)
        return matches.contains { $0.folder == folder && $0.uid == uid }
    }

    private func fetchOrCreateFolderState(accountID: UUID, event: IMAPDeletionEvent) throws -> IMAPFolderState {
        let folder = event.folder
        let descriptor = FetchDescriptor<IMAPFolderState>(predicate: #Predicate<IMAPFolderState> { state in
            state.account?.id == accountID && state.folderName == folder
        })
        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        }
        let accountDescriptor = FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == accountID })
        guard let account = try modelContext.fetch(accountDescriptor).first else {
            throw DeletionSyncCoordinatorError.accountMissing(accountID)
        }
        let created = IMAPFolderState(
            account: account,
            folderName: folder,
            attributes: event.folderAttributes,
            uidValidity: event.uidValidityAfter
        )
        modelContext.insert(created)
        return created
    }
}

public enum DeletionSyncCoordinatorError: Error, Sendable, Equatable {
    case accountMissing(UUID)
}
