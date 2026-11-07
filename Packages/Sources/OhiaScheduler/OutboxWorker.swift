import Foundation
import SwiftData
import OhiaCore
import OhiaIngest
import OhiaMail
import OhiaML

public struct AcceptedSend: Sendable {
    public let rawMessage: Data?
    public let localIngestionRawMessage: Data?

    public init(
        rawMessage: Data?,
        localIngestionRawMessage: Data? = nil
    ) {
        self.rawMessage = rawMessage
        self.localIngestionRawMessage = localIngestionRawMessage
    }
}

public protocol SendExecuting: Sendable {
    @MainActor
    func send(item: OutboxItem) async throws

    @MainActor
    func send(
        item: OutboxItem,
        onAccepted: @MainActor @Sendable (AcceptedSend) -> Void
    ) async throws
}

public extension SendExecuting {
    @MainActor
    func send(
        item: OutboxItem,
        onAccepted: @MainActor @Sendable (AcceptedSend) -> Void
    ) async throws {
        try await send(item: item)
        onAccepted(AcceptedSend(rawMessage: nil))
    }
}

public protocol NetworkReachability: Sendable {
    var isOnline: Bool { get }
}

public struct AlwaysOnlineReachability: NetworkReachability {
    public init() {}
    public var isOnline: Bool { true }
}

public final class OutboxWorker: Sendable {
    private let executor: SendExecuting
    private let maxPerTick: Int
    private let maxAttempts: Int
    private let reachability: NetworkReachability
    private let feedbackRecorder: SentTrainingFeedbackRecorder?
    private let glossaryCorrectionRecorder: (any TranslationGlossaryCorrectionRecording)?
    private let canonicalStore: CanonicalStore?
    private let confirmationNotifier: @MainActor @Sendable (UUID) -> Void

    public init(
        executor: SendExecuting,
        reachability: NetworkReachability = AlwaysOnlineReachability(),
        maxPerTick: Int = 5,
        maxAttempts: Int = 5,
        feedbackRecorder: SentTrainingFeedbackRecorder? = nil,
        glossaryCorrectionRecorder: (any TranslationGlossaryCorrectionRecording)? = nil,
        canonicalStore: CanonicalStore? = nil,
        confirmationNotifier: @escaping @MainActor @Sendable (UUID) -> Void = { outboxItemID in
            DistributedNotificationCenter.default().postNotificationName(
                .ohiaMailSendConfirmed,
                object: outboxItemID.uuidString,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    ) {
        self.executor = executor
        self.reachability = reachability
        self.maxPerTick = maxPerTick
        self.maxAttempts = maxAttempts
        self.feedbackRecorder = feedbackRecorder
        self.glossaryCorrectionRecorder = glossaryCorrectionRecorder
        self.canonicalStore = canonicalStore
        self.confirmationNotifier = confirmationNotifier
    }

    @MainActor
    public func drain(context: ModelContext, now: Date = Date()) async throws {
        let all = try context.fetch(FetchDescriptor<OutboxItem>())
        // Terminal state is persisted before asset deletion. Reconcile every
        // drain so a process exit between those steps self-heals, including
        // while the machine is offline.
        for item in all where Self.isTerminal(item.status) {
            cleanupDraftAssetsIfOwnerIsTerminal(for: item, among: all)
        }
        // `.sending` is persisted immediately before the SMTP await. Because a
        // worker is constructed for each drain job, any row still in that state
        // at the start of a later drain was interrupted by process termination.
        // Delivery is unknowable at that boundary, so fail closed instead of
        // retrying automatically and risking a duplicate message.
        let interrupted = all.filter { $0.status == .sending }
        if !interrupted.isEmpty {
            for item in interrupted {
                item.status = .failed
                item.lastError = "Sending was interrupted; delivery status is unknown."
                item.deliveryErrorCategory = "interrupted"
            }
            try context.save()
        }
        if let feedbackRecorder {
            for item in all
                .filter({ $0.status == .sent && $0.trainingFeedbackProcessedAt == nil })
                .sorted(by: { $0.createdAt < $1.createdAt })
                .prefix(maxPerTick) {
                do {
                    try feedbackRecorder.record(item, context: context, now: now)
                } catch {
                    item.trainingFeedbackError = error.localizedDescription
                }
            }
            try context.save()
        }
        if let glossaryCorrectionRecorder {
            for item in all
                .filter({
                    $0.status == .sent
                        && $0.translationGlossaryFeedbackProcessedAt == nil
                })
                .sorted(by: { $0.createdAt < $1.createdAt })
                .prefix(maxPerTick) {
                do {
                    try glossaryCorrectionRecorder.record(item, context: context, now: now)
                } catch {
                    item.translationGlossaryFeedbackError = error.localizedDescription
                }
            }
            try context.save()
        }
        // Feedback reconciliation is local and must still make progress while
        // offline. Only the SMTP portion of the drain depends on reachability.
        if !reachability.isOnline { return }
        let eligible = all
            .filter { $0.status == .queued }
            .filter { $0.nextAttemptAfter == nil || $0.nextAttemptAfter! <= now }
            .filter { $0.account?.needsReauth != true }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(maxPerTick)

        var suspendedAccounts = Set<UUID>()
        for item in eligible {
            if let accID = item.account?.id, suspendedAccounts.contains(accID) { continue }
            if item.cancellationRequested {
                item.status = .cancelled
                try context.save()
                cleanupDraftAssetsIfOwnerIsTerminal(for: item, among: all)
                continue
            }
            item.status = .sending
            item.lastAttemptAt = Date()
            item.submissionAttemptCount += 1
            item.lastAttemptFinishedAt = nil
            item.deliveryErrorCategory = nil
            try context.save()

            var accepted = false
            let activity = SessionActivityEvent(operation: "Sending", phase: .started,
                subject: item.subject, accountID: item.account?.id, accountName: item.account?.displayName)
            SessionActivityLog.shared.record(activity)
            var acceptancePersistenceError: Error?
            do {
                try await executor.send(item: item) { acceptedSend in
                    accepted = true
                    do {
                        try persistAcceptedSend(
                            acceptedSend,
                            item: item,
                            context: context,
                            now: now
                        )
                    } catch {
                        // SMTP has already accepted the message. Preserve that
                        // irreversible state in memory and never route this
                        // error through the automatic SMTP retry path.
                        item.status = .sent
                        acceptancePersistenceError = error
                    }
                }
                item.lastAttemptFinishedAt = Date()
            } catch let err as SMTPError {
                SessionActivityLog.shared.record(activity.ending(.failed, detail: accepted
                    ? "Mail accepted; post-send processing failed: \(err.localizedDescription)" : err.localizedDescription))
                item.lastAttemptFinishedAt = Date()
                item.deliveryErrorCategory = accepted ? "postAcceptance" : Self.diagnosticCategory(for: err)
                if accepted {
                    item.status = .sent
                    item.lastError = "Post-acceptance processing failed: \(err.localizedDescription)"
                    try? context.save()
                } else {
                    handleSMTPError(err, item: item, now: now, suspended: &suspendedAccounts)
                    try context.save()
                    continue
                }
            } catch {
                SessionActivityLog.shared.record(activity.ending(error is CancellationError ? .cancelled : .failed,
                    detail: accepted ? "Mail accepted; post-send processing failed: \(error.localizedDescription)" : error.localizedDescription))
                item.lastAttemptFinishedAt = Date()
                item.deliveryErrorCategory = accepted ? "postAcceptance"
                    : (error is CancellationError ? "cancelled" : "unexpected")
                if accepted {
                    item.status = .sent
                    item.lastError = "Post-acceptance processing failed: \(error.localizedDescription)"
                    try? context.save()
                } else {
                    handleTransient(error: error.localizedDescription, item: item, now: now)
                    try context.save()
                    continue
                }
            }

            if let acceptancePersistenceError {
                SessionActivityLog.shared.record(activity.ending(.failed,
                    detail: "Mail accepted; saving its confirmation failed: \(acceptancePersistenceError.localizedDescription)"))
                item.deliveryErrorCategory = "acceptancePersistence"
                item.lastError = "Sent, but confirmation persistence failed: \(acceptancePersistenceError.localizedDescription)"
                try? context.save()
                throw acceptancePersistenceError
            }
            guard accepted else {
                SessionActivityLog.shared.record(activity.ending(.failed,
                    detail: "Sending finished without an SMTP acceptance confirmation"))
                item.status = .failed
                item.lastError = "Sending finished without an SMTP acceptance confirmation."
                item.deliveryErrorCategory = "missingAcceptance"
                try context.save()
                continue
            }

            if item.deliveryErrorCategory == nil {
                SessionActivityLog.shared.record(activity.ending(.finished, detail: "Accepted by the outgoing mail server"))
            }

            cleanupDraftAssetsIfOwnerIsTerminal(for: item, among: all)

            if let feedbackRecorder {
                do {
                    try feedbackRecorder.record(item, context: context, now: now)
                } catch {
                    // SMTP acceptance remains authoritative. Keep feedback
                    // pending and retry it from this sent outbox row later.
                    item.trainingFeedbackError = error.localizedDescription
                }
            }
            if let glossaryCorrectionRecorder {
                do {
                    try glossaryCorrectionRecorder.record(item, context: context, now: now)
                } catch {
                    // SMTP acceptance remains authoritative. Keep correction
                    // feedback pending and retry it from this sent row later.
                    item.translationGlossaryFeedbackError = error.localizedDescription
                }
            }
            try context.save()
            // Every write this drain() makes to `item` is now durable. Only
            // now is it safe to wake the main app: its real-time
            // consume-and-clear runs concurrently in a different process
            // once notified, and this context must not touch `item` again
            // afterward or a later save would resurrect the stale
            // pre-clear snapshot (see the comment in `persistAcceptedSend`).
            //
            // This ties the notify to housekeeping (asset cleanup, feedback
            // recording) that's otherwise unrelated to
            // the sound. If the save above ever throws, notify is skipped for
            // this tick — safe, not silent data loss: `sentConfirmationPendingPlayback`
            // is already durably true from the save in `persistAcceptedSend`,
            // so the next launch's sweep (`sweepPendingSentConfirmations`)
            // still plays the chime, just later than usual.
            confirmationNotifier(item.id)
            if let messageID = item.message?.id {
                NotificationCenter.default.post(
                    name: .ohiaMessageAttentionChanged,
                    object: nil,
                    userInfo: [
                        MessageAttentionNotificationUserInfoKey.messageIDs: [messageID.uuidString]
                    ]
                )
            }
        }
    }

    @MainActor
    private func persistAcceptedSend(
        _ acceptedSend: AcceptedSend,
        item: OutboxItem,
        context: ModelContext,
        now: Date
    ) throws {
        // SMTP acceptance is the irreversible boundary. Persist the terminal
        // state and durable sound marker now; the cross-process wake-up hint
        // fires later, once every write this drain() makes to `item` is
        // done (see the call site in `drain(context:now:)`). Firing it here
        // would let the main app's real-time consume-and-clear race this
        // context's own later saves (e.g. feedback recording): SwiftData
        // persists a save as a whole-row snapshot of everything this context
        // still holds dirty-or-not, so a later save on this same object would
        // silently resurrect this stale `true` over the app's `false`.
        item.status = .sent
        item.providerAcceptedAt = Date()
        item.sentConfirmationPendingPlayback = true
        item.lastError = nil
        if let message = item.message {
            message.repliedAt = now
            message.requiresReply = false
            clearSatisfiedReplyActions(for: message.id, in: context, now: now)
        }
        item.draft?.status = .sent
        try context.save()
        if let messageID = item.message?.id {
            try ReplySourcePreparationCoordinator().cancel(
                messageIDs: [messageID],
                context: context
            )
        }

        guard let rawMessage = acceptedSend.localIngestionRawMessage ?? acceptedSend.rawMessage,
              let canonicalStore,
              let account = item.account else {
            return
        }

        do {
            let result = try IngestionOrchestrator(
                context: context,
                canonicalStore: canonicalStore
            ).ingestRawRFC5322(
                data: rawMessage,
                account: account,
                folderPath: "Sent",
                folderAttributes: ["\\Sent"],
                serverUID: 0,
                receivedAt: now,
                seenAtSource: true
            )
            if result.isSentByUser, let messageID = result.messageId {
                try LiveInboundPipelinePrioritizer.seedForegroundMessage(
                    messageIDs: [messageID],
                    context: context
                )
            } else {
                try context.save()
            }
        } catch {
            // Delivery is already complete. Keep the row terminal and leave
            // normal IMAP ingestion as the recovery path.
            item.lastError = "Sent, but immediate sent-message ingestion failed: \(error.localizedDescription)"
            try? context.save()
        }
    }

    private static func diagnosticCategory(for error: SMTPError) -> String {
        switch error {
        case .transient: "transient"
        case .permanent: "permanent"
        case .authFailed: "authentication"
        case .transportFailed: "transport"
        case .protocolViolation: "protocol"
        }
    }

    private static func isTerminal(_ status: OutboxStatus) -> Bool {
        switch status {
        case .sent, .cancelled:
            true
        case .queued, .sending, .failed:
            false
        }
    }

    @MainActor
    private func cleanupDraftAssetsIfOwnerIsTerminal(
        for item: OutboxItem,
        among all: [OutboxItem]
    ) {
        guard Self.isTerminal(item.status), let ownerID = item.draft?.id else { return }
        let hasNonTerminalSibling = all.contains { candidate in
            candidate.draft?.id == ownerID && !Self.isTerminal(candidate.status)
        }
        guard !hasNonTerminalSibling else { return }
        ComposerDraftAssetCleanup.deleteAll(ownerID: ownerID)
    }

    @MainActor
    private func clearSatisfiedReplyActions(for messageID: UUID, in context: ModelContext, now: Date) {
        for row in ProjectLensAction.activeActions(in: context) where row.targetKind == .message && row.messageId == messageID {
            switch row.actionValue {
            case .replyNeededByUser, .confirmationNeededByUser:
                row.revoke(at: now)
            default:
                break
            }
        }
    }

    @MainActor
    private func handleSMTPError(
        _ err: SMTPError,
        item: OutboxItem,
        now: Date,
        suspended: inout Set<UUID>
    ) {
        switch err {
        case .transient(let d):
            handleTransient(error: d, item: item, now: now)
        case .permanent(let d), .protocolViolation(let d), .transportFailed(let d):
            item.status = .failed
            item.lastError = d
        case .authFailed(let d):
            item.status = .failed
            item.lastError = d
            item.account?.needsReauth = true
            if let id = item.account?.id { suspended.insert(id) }
        }
    }

    @MainActor
    private func handleTransient(error: String, item: OutboxItem, now: Date) {
        item.attempts += 1
        item.lastError = error
        if item.attempts >= maxAttempts {
            item.status = .failed
        } else {
            let delay = min(pow(2.0, Double(item.attempts)) * 30.0, 3600.0)
            item.nextAttemptAfter = now.addingTimeInterval(delay)
            item.status = .queued
        }
    }
}
