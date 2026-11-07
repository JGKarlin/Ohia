import Foundation
import SwiftData
import OhiaCore
import OhiaML

public enum ReplySourcePreparationAdmissionOrigin: Sendable {
    case prePresentationTriage
    case alreadyVisibleManualAction
    case nonLiveThreadChange
}

/// Store-keyed admission and invalidation for reply-source preparation.
///
/// Every mutation is staged with its job before one save. Relationships are
/// conveniences only: Draft and preparation precedence always comes from a
/// fresh store-authoritative context so a worker process cannot create
/// duplicates behind a stale registered `Message` or stale fetch snapshot.
@MainActor
public final class ReplySourcePreparationCoordinator {
    public static let backgroundPriority = 4

    typealias InputReadiness = @MainActor (Message, ModelContext)
        -> ReplyPreparationInputReadiness.Result

    private let inputReadiness: InputReadiness
    private let jobQueue: JobQueue

    public init() {
        self.inputReadiness = { message, context in
            ReplyPreparationInputReadiness.evaluate(
                message: message,
                context: context
            )
        }
        self.jobQueue = JobQueue()
    }

    init(
        inputReadiness: @escaping InputReadiness,
        jobQueue: JobQueue = JobQueue()
    ) {
        self.inputReadiness = inputReadiness
        self.jobQueue = jobQueue
    }

    @discardableResult
    public func reconcile(
        messageIDs: Set<UUID>,
        origin: ReplySourcePreparationAdmissionOrigin,
        durablyAnnouncedMessageIDs _: Set<UUID>? = nil,
        context: ModelContext
    ) throws -> Int {
        // Scheduler and UI contexts can outlive writes made by the other
        // process. Once the caller has saved its own mutation, reconcile from
        // a new context so a newly adopted Draft always wins over a stale
        // preparation row. Preserve the supplied context only when it carries
        // unsaved work (the adopter's corrupt-row replacement is atomic here).
        let authoritativeContext = reconciliationContext(
            for: messageIDs,
            callerContext: context
        )
        // Preparation follows the conversation's reply target. A change to
        // any email of a conversation (a manual Needs Reply on an earlier
        // email, a resolution of the newest) can move the target, so the
        // target is reconciled with it.
        var reconciledIDs = messageIDs
        for messageID in messageIDs {
            guard let message = try fetchMessage(messageID, context: authoritativeContext),
                  let target = ReplySourcePreparationEligibility.conversationTarget(
                      for: message,
                      context: authoritativeContext
                  ) else { continue }
            reconciledIDs.insert(target.id)
        }
        var admitted = 0
        var changed = false
        for messageID in reconciledIDs.sorted(by: uuidSort) {
            guard let message = try fetchMessage(messageID, context: authoritativeContext) else {
                changed = try cancelStaged(messageID: messageID, context: authoritativeContext) || changed
                continue
            }
            if try fetchDraft(messageID: messageID, context: authoritativeContext) != nil {
                changed = try cancelStaged(messageID: messageID, context: authoritativeContext) || changed
                continue
            }

            let snapshot: ReplyPreparationInputSnapshot
            switch inputReadiness(message, authoritativeContext) {
            case .ineligible:
                changed = try cancelStaged(
                    messageID: messageID,
                    context: authoritativeContext
                ) || changed
                continue
            case let .waiting(blockers):
                changed = try invalidateWaitingInput(
                    message: message,
                    context: authoritativeContext
                ) || changed
                changed = try stagePrerequisite(
                    for: blockers,
                    messageID: message.id,
                    priority: Self.prerequisitePriority(for: message),
                    context: authoritativeContext
                ) || changed
                continue
            case let .ready(readySnapshot):
                snapshot = readySnapshot
            }

            let result = try admit(
                message: message,
                fingerprint: snapshot.fingerprint,
                witnessedLiveThreadMessageIDs: snapshot.witnessedLiveThreadMessageIDs,
                context: authoritativeContext
            )
            admitted += result.admitted
            changed = result.changed || changed
        }
        if changed {
            try authoritativeContext.save()
        }
        return admitted
    }

    /// Admits live Needs Reply rows whenever triage has stamped their durable
    /// preparation requirement. Placement may win the cross-process race with
    /// triage, but arrival presentation still waits for preparation readiness.
    @discardableResult
    public func reconcilePendingFirstPresentation(
        context: ModelContext
    ) throws -> Int {
        let authoritativeContext = ModelContext(context.container)
        let predicate = #Predicate<Message> {
            $0.replyPreparationRequiredAt != nil
        }
        let descriptor = FetchDescriptor<Message>(predicate: predicate)
        let candidates: [Message] = try authoritativeContext.fetch(descriptor).filter {
            $0.replyPreparationReadyAt == nil
        }
        let candidateIDs: Set<UUID> = Set(candidates.map { $0.id })
        guard !candidateIDs.isEmpty else { return 0 }
        return try reconcile(
            messageIDs: candidateIDs,
            origin: .prePresentationTriage,
            context: authoritativeContext
        )
    }

    public func cancel(
        messageIDs: Set<UUID>,
        context: ModelContext
    ) throws {
        var changed = false
        for messageID in messageIDs {
            changed = try cancelStaged(messageID: messageID, context: context) || changed
        }
        if changed {
            try context.save()
        }
    }

    @discardableResult
    public func reconcileChangedPreparationInputs(
        context: ModelContext
    ) throws -> Int {
        // This scheduler maintenance pass operates only on durable rows. It
        // must never inherit a long-lived worker context's fetch snapshot or
        // let unrelated pending scheduler mutations defeat freshness.
        let authoritativeContext = ModelContext(context.container)
        let existing = try authoritativeContext.fetch(
            FetchDescriptor<ReplySourcePreparation>()
        )
        let rowsByMessageID = Dictionary(grouping: existing, by: \.messageId)
        var replaced = 0
        // Targets admitted below in their own fresh context may have had
        // their rows replaced there; this context's copies of those rows are
        // stale and must not be read again.
        var reconciledTargetIDs: Set<UUID> = []
        for messageID in rowsByMessageID.keys.sorted(by: uuidSort) {
            guard !reconciledTargetIDs.contains(messageID),
                  let rows = rowsByMessageID[messageID] else { continue }
            guard let message = try fetchMessage(messageID, context: authoritativeContext) else {
                try cancel(messageIDs: [messageID], context: authoritativeContext)
                continue
            }
            if try fetchDraft(messageID: messageID, context: authoritativeContext) != nil {
                try cancel(messageIDs: [messageID], context: authoritativeContext)
                continue
            }

            let snapshot: ReplyPreparationInputSnapshot
            switch inputReadiness(message, authoritativeContext) {
            case .ineligible:
                try cancel(messageIDs: [messageID], context: authoritativeContext)
                // The conversation's reply target may have moved to another
                // email (a re-interpretation, a newer qualifying arrival).
                // Admit it now rather than when its own row next changes.
                if let target = ReplySourcePreparationEligibility.conversationTarget(
                    for: message,
                    context: authoritativeContext
                ), target.id != messageID, reconciledTargetIDs.insert(target.id).inserted {
                    replaced += try reconcile(
                        messageIDs: [target.id],
                        origin: .nonLiveThreadChange,
                        context: authoritativeContext
                    )
                }
                continue
            case let .waiting(blockers):
                var waitingChanged = try invalidateWaitingInput(
                    message: message,
                    context: authoritativeContext
                )
                waitingChanged = try stagePrerequisite(
                    for: blockers,
                    messageID: message.id,
                    priority: Self.prerequisitePriority(for: message),
                    context: authoritativeContext
                ) || waitingChanged
                if waitingChanged {
                    try authoritativeContext.save()
                }
                continue
            case let .ready(readySnapshot):
                snapshot = readySnapshot
            }

            let hasChangedInputs = rows.contains { preparation in
                preparation.contractVersion
                    != ReplySourcePreparationFingerprint.contractVersion
                    || preparation.inputFingerprint != snapshot.fingerprint
                    || witnessedLiveThreadMessageIDs(in: preparation)
                        != snapshot.witnessedLiveThreadMessageIDs
            }
            guard hasChangedInputs else { continue }

            replaced += try reconcile(
                messageIDs: [messageID],
                origin: .nonLiveThreadChange,
                context: authoritativeContext
            )
        }
        return replaced
    }

    /// Mirrors the exact retry state chosen by `JobQueue` onto the durable
    /// preparation record. Called only after the queue has saved its result.
    /// A terminal job hands its preserved preparation to Composer without
    /// another background job. `countsTowardCap` records semantic rejections;
    /// transient attempts are already counted on the job.
    public func mirrorFailure(
        from job: Job,
        countsTowardCap: Bool = true,
        context: ModelContext
    ) throws {
        guard job.type == .prepareReplySources,
              let messageID = job.messageId else {
            return
        }
        let rows = try fetchPreparations(messageID: messageID, context: context)
        guard let payload = ReplySourcePreparationJobPayload.decode(job.payload),
              let preparation = rows.first(where: {
                  $0.inputFingerprint == payload.fingerprint
                      && $0.contractVersion == payload.contractVersion
              }) else {
            return
        }
        // An older failed attempt cannot demote a completed reusable result.
        guard preparation.statusRaw != ReplySourcePreparationStatus.ready else { return }
        guard job.status == .failed else {
            preparation.statusRaw = ReplySourcePreparationStatus.pending
            preparation.lastError = job.error
            preparation.nextAttemptAt = job.nextAttemptAt
            preparation.updatedAt = .now
            try context.save()
            return
        }

        // JobQueue owns the complete bounded transient retry budget. A
        // terminal job must not start another round under a fresh job ID.
        if countsTowardCap { preparation.failureCount += 1 }
        preparation.lastError = job.error
        preparation.updatedAt = .now
        try publishExhausted(preparation, context: context)
    }

    /// Threshold used by Composer when adopting an older exhausted artifact.
    /// Current scheduler failures hand off immediately when their job ends.
    public static let maximumTerminalFailures = 3

    /// Whether a job failure is the model rejecting these inputs (a plan or
    /// review that does not validate, a draft the content check refuses, a
    /// malformed payload) rather than infrastructure that will clear.
    public static func isDeterministicFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let content = error as? ComposerContentError { return content != .deadlineExceeded }
        if error is DraftContentValidationError || error is ComposerContextPackingError { return true }
        if error is ReplySourcePreparationWorkerError { return true }
        // Generic generation failures also include worker/transport failures;
        // semantic rejection must carry a typed content error.
        if error is TrainingEngineError { return false }
        if let pipeline = error as? PipelineError, case .invalidPayload = pipeline { return true }
        return false
    }

    /// The end state after a terminal job: the message arrives and the author
    /// drafts it. The row keeps its compiled sources (or none) and an empty
    /// interview marked invalid, so the adopter creates a foreground Draft in
    /// the generating stage and the Composer shows that automatic questions
    /// were unavailable; `lastError` and `failureCount` stay as the record.
    private func publishExhausted(_ preparation: ReplySourcePreparation, context: ModelContext) throws {
        if preparation.sourcesJSON == nil {
            preparation.sourcesJSON = ComposerSourceCoding.encode([])
        }
        let state = ComposerInterviewStateCoding.decode(preparation.interviewStateJSON)
            ?? ComposerInterviewState(
                contractVersion: ComposerInterviewPlanner.contractVersion,
                inputFingerprint: preparation.inputFingerprint,
                evidenceFingerprint: "",
                generationEpoch: 0,
                planningOutcome: .invalid,
                baseProtocol: ComposerInterviewPlanner.emptyProtocol
            )
        preparation.interviewStateJSON = ComposerInterviewStateCoding.encode(state)
        preparation.questionCount = ComposerInterviewExecutor.project(state).currentNode == nil ? 0 : 1
        let readyAt = Date()
        preparation.statusRaw = ReplySourcePreparationStatus.ready
        preparation.preparedAt = readyAt
        preparation.updatedAt = readyAt
        preparation.nextAttemptAt = nil
        if let message = try fetchMessage(preparation.messageId, context: context) {
            message.replyPreparationReadyAt = readyAt
        }
        try context.save()
    }

    private struct AdmissionResult {
        let admitted: Int
        let changed: Bool
    }

    private func admit(
        message: Message,
        fingerprint currentFingerprint: String,
        witnessedLiveThreadMessageIDs: Set<UUID>,
        context: ModelContext
    ) throws -> AdmissionResult {
        let rows = try fetchPreparations(messageID: message.id, context: context)
        let matching = rows
            .filter {
                $0.inputFingerprint == currentFingerprint
                    && $0.contractVersion
                        == ReplySourcePreparationFingerprint.contractVersion
                    && self.witnessedLiveThreadMessageIDs(in: $0)
                        == witnessedLiveThreadMessageIDs
            }
            .sorted(by: preparationPreference)
            .first

        var changed = false
        if let matching {
            for duplicate in rows where duplicate.id != matching.id {
                deletePreparation(duplicate, context: context)
                changed = true
            }
            if message.replySourcePreparation?.id != matching.id {
                message.replySourcePreparation = nil
                message.replySourcePreparation = matching
                changed = true
            }

            switch matching.statusRaw {
            case ReplySourcePreparationStatus.ready:
                changed = try deduplicateJobs(
                    messageID: message.id,
                    expectedPayload: nil,
                    context: context
                ) || changed
                return AdmissionResult(admitted: 0, changed: changed)
            default:
                if message.replyPreparationReadyAt != nil {
                    message.replyPreparationReadyAt = nil
                    changed = true
                }
                let payload = ReplySourcePreparationJobPayload(
                    messageID: message.id,
                    fingerprint: currentFingerprint,
                    contractVersion: ReplySourcePreparationFingerprint.contractVersion
                )
                let staged = try ensureOneActiveJob(
                    payload: payload,
                    preparation: matching,
                    context: context
                )
                return AdmissionResult(
                    admitted: staged ? 1 : 0,
                    changed: staged || changed
                )
            }
        }

        for stale in rows {
            deletePreparation(stale, context: context)
            changed = true
        }
        changed = try deduplicateJobs(
            messageID: message.id,
            expectedPayload: nil,
            context: context
        ) || changed
        if message.replyPreparationReadyAt != nil {
            message.replyPreparationReadyAt = nil
            changed = true
        }

        let preparation = ReplySourcePreparation(
            message: message,
            inputFingerprint: currentFingerprint,
            contractVersion: ReplySourcePreparationFingerprint.contractVersion,
            witnessedLiveThreadMessageIDsJSON: try encodeLiveThreadMessageIDs(
                witnessedLiveThreadMessageIDs
            )
        )
        context.insert(preparation)
        message.replySourcePreparation = preparation
        let payload = ReplySourcePreparationJobPayload(
            messageID: message.id,
            fingerprint: currentFingerprint,
            contractVersion: ReplySourcePreparationFingerprint.contractVersion
        )
        _ = try ensureOneActiveJob(
            payload: payload,
            preparation: preparation,
            context: context
        )
        return AdmissionResult(admitted: 1, changed: true)
    }

    private func ensureOneActiveJob(
        payload: ReplySourcePreparationJobPayload,
        preparation: ReplySourcePreparation,
        context: ModelContext
    ) throws -> Bool {
        let encodedPayload = try payload.encoded()
        let active = try activePreparationJobs(
            messageID: payload.messageID,
            context: context
        )
        let matchingRunning = active.first {
            $0.status == .running
                && ReplySourcePreparationJobPayload.decode($0.payload) == payload
        }
        if matchingRunning != nil {
            for job in active where job.status == .pending {
                context.delete(job)
            }
            return active.contains { $0.status == .pending }
        }

        let matchingPending = active
            .filter {
                $0.status == .pending
                    && ReplySourcePreparationJobPayload.decode($0.payload) == payload
            }
            .sorted(by: jobSort)
            .first
        for job in active where job.status == .pending && job.id != matchingPending?.id {
            context.delete(job)
        }
        if matchingPending != nil {
            return active.filter { $0.status == .pending }.count > 1
        }

        if preparation.statusRaw == ReplySourcePreparationStatus.retryWaiting,
           let nextAttemptAt = preparation.nextAttemptAt {
            let replacement = jobQueue.stage(
                type: .prepareReplySources,
                priority: Self.backgroundPriority,
                messageId: payload.messageID,
                payload: encodedPayload,
                context: context
            )
            replacement.nextAttemptAt = nextAttemptAt
            return true
        }

        preparation.statusRaw = ReplySourcePreparationStatus.pending
        preparation.failureCount = 0
        preparation.lastError = nil
        preparation.nextAttemptAt = nil
        preparation.updatedAt = .now
        jobQueue.stage(
            type: .prepareReplySources,
            priority: Self.backgroundPriority,
            messageId: payload.messageID,
            payload: encodedPayload,
            context: context
        )
        return true
    }

    private func deduplicateJobs(
        messageID: UUID,
        expectedPayload: ReplySourcePreparationJobPayload?,
        context: ModelContext
    ) throws -> Bool {
        let active = try activePreparationJobs(
            messageID: messageID,
            context: context
        )
        var changed = false
        var keptExpectedPending = false
        let hasExpectedRunning = expectedPayload.map { payload in
            active.contains {
                $0.status == .running
                    && ReplySourcePreparationJobPayload.decode($0.payload) == payload
            }
        } ?? false

        for job in active where job.status == .pending {
            let matches = expectedPayload.map {
                ReplySourcePreparationJobPayload.decode(job.payload) == $0
            } ?? false
            if matches && !hasExpectedRunning && !keptExpectedPending {
                keptExpectedPending = true
                continue
            }
            context.delete(job)
            changed = true
        }
        return changed
    }

    private func cancelStaged(
        messageID: UUID,
        context: ModelContext
    ) throws -> Bool {
        // Cancel executable work without consuming completed model artifacts.
        // Queue exclusion and Draft ownership are temporary; semantic reply
        // resolution or removal of the source message still clears the cache.
        let message = try fetchMessage(messageID, context: context)
        let preserveReady = message.map {
            ReplySourcePreparationEligibility.canRetainCompletedPreparation($0, context: context)
        } ?? false
        var changed = false
        // Cancelling a no-longer-needed reply also releases its presentation
        // gate. Otherwise no preparation can publish readiness, placement
        // waits forever, and the training tail never becomes eligible.
        if let message, message.placedAt == nil,
           !ReplySourcePreparationEligibility.isEligible(message, context: context),
           message.replyPreparationRequiredAt != nil {
            message.replyPreparationRequiredAt = nil
            message.replyPreparationReadyAt = nil
            changed = true
        }
        for preparation in try fetchPreparations(
            messageID: messageID,
            context: context
        ) where !preserveReady || preparation.statusRaw != ReplySourcePreparationStatus.ready {
            deletePreparation(preparation, context: context)
            changed = true
        }
        for job in try activePreparationJobs(
            messageID: messageID,
            context: context
        ) where job.status == .pending {
            context.delete(job)
            changed = true
        }
        return changed
    }

    private func invalidateWaitingInput(
        message: Message,
        context: ModelContext
    ) throws -> Bool {
        var changed = false
        if message.replyPreparationReadyAt != nil {
            message.replyPreparationReadyAt = nil
            changed = true
        }
        for preparation in try fetchPreparations(
            messageID: message.id,
            context: context
        ) {
            deletePreparation(preparation, context: context)
            changed = true
        }
        for job in try activePreparationJobs(
            messageID: message.id,
            context: context
        ) {
            context.delete(job)
            changed = true
        }
        return changed
    }

    /// A new arrival's preparation waits on its summary, so that runs in the
    /// live interpretation lane rather than with the backlog.
    static func prerequisitePriority(for message: Message) -> Int {
        LiveInboundPipelinePrioritizer.awaitsArrivalPreparation(message)
            ? LiveInboundPipelinePrioritizer.liveStagePriority : backgroundPriority
    }

    private func stagePrerequisite(
        for blockers: Set<ReplyPreparationInputBlocker>,
        messageID: UUID,
        priority: Int,
        context: ModelContext
    ) throws -> Bool {
        let desiredType: JobType?
        if blockers.contains(.pendingDocumentExtraction) {
            desiredType = .extractAttachments
        } else if blockers.contains(.pendingVisualExtraction) {
            desiredType = .extractVisualAttachments
        } else if blockers.contains(.pendingCaptureMetadata) {
            desiredType = .extractCaptureMetadata
        } else if blockers.contains(.incompleteInterpretation)
                    || blockers.contains(.missingBodySummary) {
            desiredType = .summarize
        } else {
            desiredType = nil
        }

        let prerequisiteTypes: Set<JobType> = [
            .summarize,
            .extractAttachments,
            .extractVisualAttachments,
            .extractCaptureMetadata,
        ]
        let active = try context.fetch(
            FetchDescriptor<Job>(
                predicate: #Predicate<Job> { $0.messageId == messageID }
            )
        ).filter {
            prerequisiteTypes.contains($0.type)
                && ($0.status == .pending || $0.status == .running)
        }

        var changed = false
        for job in active where job.type != desiredType && job.status == .pending {
            context.delete(job)
            changed = true
        }
        guard let desiredType else { return changed }

        // A different prerequisite already running can still mutate the input.
        // Let it finish before admitting another stage rather than executing
        // attachment and summary work concurrently against one embargoed row.
        if active.contains(where: { $0.type != desiredType && $0.status == .running }) {
            return changed
        }

        let matching = active
            .filter { $0.type == desiredType }
            .sorted(by: prerequisiteJobPreference)
        if let kept = matching.first {
            for duplicate in matching.dropFirst() {
                context.delete(duplicate)
                changed = true
            }
            let keptPriority = desiredType == .summarize ? priority : Self.backgroundPriority
            if kept.priority > keptPriority {
                kept.priority = keptPriority
                changed = true
            }
            return changed
        }

        jobQueue.stage(
            type: desiredType,
            priority: desiredType == .summarize ? priority : Self.backgroundPriority,
            messageId: messageID,
            context: context
        )
        return true
    }

    private func deletePreparation(
        _ preparation: ReplySourcePreparation,
        context: ModelContext
    ) {
        if preparation.message?.replySourcePreparation?.id == preparation.id {
            preparation.message?.replySourcePreparation = nil
        }
        preparation.message = nil
        context.delete(preparation)
    }

    private func fetchMessage(
        _ messageID: UUID,
        context: ModelContext
    ) throws -> Message? {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Keep the caller's context only when this exact admission is already
    /// carrying an unsaved transactional mutation (the adopter's corrupt-row
    /// replacement). Unrelated pending work in a scheduler context must not
    /// forfeit the fresh store read that prevents duplicate preparation.
    private func reconciliationContext(
        for messageIDs: Set<UUID>,
        callerContext context: ModelContext
    ) -> ModelContext {
        let insertedHasRelatedWork = context.insertedModelsArray.contains { model in
            if let preparation = model as? ReplySourcePreparation {
                return messageIDs.contains(preparation.messageId)
            }
            if let job = model as? Job, let messageID = job.messageId {
                return messageIDs.contains(messageID)
            }
            if let draft = model as? Draft, let messageID = draft.message?.id {
                return messageIDs.contains(messageID)
            }
            if let message = model as? Message {
                return messageIDs.contains(message.id)
            }
            return false
        }
        let deletedHasRelatedWork = context.deletedModelsArray.contains { model in
            if let preparation = model as? ReplySourcePreparation {
                return messageIDs.contains(preparation.messageId)
            }
            if let job = model as? Job, let messageID = job.messageId {
                return messageIDs.contains(messageID)
            }
            if let draft = model as? Draft, let messageID = draft.message?.id {
                return messageIDs.contains(messageID)
            }
            return false
        }
        if insertedHasRelatedWork || deletedHasRelatedWork {
            return context
        }
        return ModelContext(context.container)
    }

    private func fetchDraft(
        messageID: UUID,
        context: ModelContext
    ) throws -> Draft? {
        var descriptor = FetchDescriptor<Draft>(
            predicate: #Predicate<Draft> { $0.message?.id == messageID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchPreparations(
        messageID: UUID,
        context: ModelContext
    ) throws -> [ReplySourcePreparation] {
        try context.fetch(
            FetchDescriptor<ReplySourcePreparation>(
                predicate: #Predicate<ReplySourcePreparation> {
                    $0.messageId == messageID
                }
            )
        )
    }

    private func activePreparationJobs(
        messageID: UUID,
        context: ModelContext
    ) throws -> [Job] {
        let descriptor = FetchDescriptor<Job>(
            predicate: #Predicate<Job> { job in
                job.messageId == messageID
            }
        )
        return try context.fetch(descriptor).filter {
            $0.type == .prepareReplySources
                && ($0.status == .pending || $0.status == .running)
        }
    }

    private func witnessedLiveThreadMessageIDs(
        in preparation: ReplySourcePreparation
    ) -> Set<UUID> {
        guard let encoded = preparation.witnessedLiveThreadMessageIDsJSON,
              let data = encoded.data(using: .utf8),
              let messageIDs = try? JSONDecoder().decode([UUID].self, from: data)
        else {
            return []
        }
        return Set(messageIDs)
    }

    private func encodeLiveThreadMessageIDs(_ messageIDs: Set<UUID>) throws -> String {
        let strings = messageIDs.map(\.uuidString).sorted()
        return String(decoding: try JSONEncoder().encode(strings), as: UTF8.self)
    }

    private func preparationPreference(
        _ lhs: ReplySourcePreparation,
        _ rhs: ReplySourcePreparation
    ) -> Bool {
        func rank(_ status: String) -> Int {
            switch status {
            case ReplySourcePreparationStatus.ready: return 0
            case ReplySourcePreparationStatus.drafting: return 1
            case ReplySourcePreparationStatus.formulatingQuestions: return 2
            case ReplySourcePreparationStatus.compilingSources: return 3
            case ReplySourcePreparationStatus.retryWaiting: return 4
            case ReplySourcePreparationStatus.pending: return 5
            default: return 4
            }
        }
        let lhsRank = rank(lhs.statusRaw)
        let rhsRank = rank(rhs.statusRaw)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func jobSort(_ lhs: Job, _ rhs: Job) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func prerequisiteJobPreference(_ lhs: Job, _ rhs: Job) -> Bool {
        if lhs.status != rhs.status {
            return lhs.status == .running
        }
        return jobSort(lhs, rhs)
    }

    private func uuidSort(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }
}

extension ReplySourcePreparationCoordinator: ReplySourcePreparationReconciling {}
