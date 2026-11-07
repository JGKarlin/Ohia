import Foundation
import os
import SwiftData
import OhiaCore
import OhiaIngest
import OhiaML

/// Instruments signpost logger. Profile with the `os_signpost` Instrument or
/// the Points of Interest template to see per-tick duration + claimed job
/// type. Subsystem matches the app bundle identifier so records are easy to
/// filter in the Instruments timeline.
private let schedulerSignposter = OSSignposter(
    subsystem: "org.jgkarlin.Ohia",
    category: "scheduler"
)

private var shouldLogLayoutBurstDiagnostics: Bool {
    ProcessInfo.processInfo.environment["OHIA_DEBUG_LAYOUT_BURSTS"] == "1"
        || OhiaSharedDefaults.store.bool(forKey: "ohia.debug.layoutBursts")
}

nonisolated struct InterpretationBackpressureSnapshot: Sendable, Equatable {
    let embeddedEmailNodes: Int
    let placedEmailNodes: Int
    let pendingEmbeddedInterpretation: Int
    let pendingPlacedInterpretation: Int

    var visibleLead: Int {
        pendingPlacedInterpretation
    }

    var embeddedLead: Int {
        pendingEmbeddedInterpretation
    }

    var lead: Int {
        max(visibleLead, embeddedLead)
    }

    var pendingInterpretation: Int {
        max(pendingEmbeddedInterpretation, pendingPlacedInterpretation)
    }

    var isSettled: Bool {
        pendingInterpretation == 0 && embeddedEmailNodes == placedEmailNodes
    }
}

/// Reuses only a fully settled interpretation snapshot. Active backlog is
/// always loaded afresh; once the corpus is complete, the short reuse window
/// prevents every adjacent worker tick from repeating the same JSON-heavy SQL.
nonisolated struct InterpretationBackpressureSnapshotCache: Sendable {
    private struct Entry: Sendable {
        let snapshot: InterpretationBackpressureSnapshot
        let loadedAt: Date
    }

    let settledReuseInterval: TimeInterval
    private var entry: Entry?

    init(settledReuseInterval: TimeInterval) {
        self.settledReuseInterval = max(0, settledReuseInterval)
    }

    mutating func value(
        at now: Date,
        load: () -> InterpretationBackpressureSnapshot?
    ) -> InterpretationBackpressureSnapshot? {
        if let entry {
            let age = now.timeIntervalSince(entry.loadedAt)
            if age >= 0, age < settledReuseInterval {
                return entry.snapshot
            }
        }

        let loaded = load()
        if let loaded, loaded.isSettled {
            entry = Entry(snapshot: loaded, loadedAt: now)
        } else {
            entry = nil
        }
        return loaded
    }

    mutating func invalidate() {
        entry = nil
    }
}

private struct ComposerJobCancellationTarget: Sendable {
    let preparationIDs: Set<UUID>
    let draftIDs: Set<UUID>
    let messageIDs: Set<UUID>

    var isEmpty: Bool {
        preparationIDs.isEmpty && draftIDs.isEmpty && messageIDs.isEmpty
    }
}

private struct ComposerJobCancellationEvidence: Sendable {
    var missingPreparationIDs: Set<UUID> = []
    var missingDraftIDs: Set<UUID> = []
    var discardedDraftIDs: Set<UUID> = []
    var inactiveDraftIDs: Set<UUID> = []
    var missingMessageIDs: Set<UUID> = []
    var excludedMessageIDs: Set<UUID> = []

    var isEmpty: Bool {
        missingPreparationIDs.isEmpty
            && missingDraftIDs.isEmpty
            && discardedDraftIDs.isEmpty
            && inactiveDraftIDs.isEmpty
            && missingMessageIDs.isEmpty
            && excludedMessageIDs.isEmpty
    }

    mutating func formUnion(_ other: Self) {
        missingPreparationIDs.formUnion(other.missingPreparationIDs)
        missingDraftIDs.formUnion(other.missingDraftIDs)
        discardedDraftIDs.formUnion(other.discardedDraftIDs)
        inactiveDraftIDs.formUnion(other.inactiveDraftIDs)
        missingMessageIDs.formUnion(other.missingMessageIDs)
        excludedMessageIDs.formUnion(other.excludedMessageIDs)
    }
}

/// Polls from a newly-created context on its own executor so it can observe a
/// foreground deletion even while synchronous Qwen generation occupies the
/// MainActor in the worker process.
private actor DurableComposerJobCancellationMonitor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func cancellationEvidence(
        for target: ComposerJobCancellationTarget
    ) throws -> ComposerJobCancellationEvidence {
        let context = ModelContext(container)
        var evidence = ComposerJobCancellationEvidence()

        for preparationID in target.preparationIDs {
            var descriptor = FetchDescriptor<ReplySourcePreparation>(
                predicate: #Predicate<ReplySourcePreparation> {
                    $0.id == preparationID
                }
            )
            descriptor.fetchLimit = 1
            if try context.fetch(descriptor).isEmpty {
                evidence.missingPreparationIDs.insert(preparationID)
            }
        }

        for draftID in target.draftIDs {
            var descriptor = FetchDescriptor<Draft>(
                predicate: #Predicate<Draft> { $0.id == draftID }
            )
            descriptor.fetchLimit = 1
            guard let draft = try context.fetch(descriptor).first else {
                evidence.missingDraftIDs.insert(draftID)
                continue
            }
            if draft.status == .discarded {
                evidence.discardedDraftIDs.insert(draftID)
            } else if draft.status != .pending {
                evidence.inactiveDraftIDs.insert(draftID)
            }
        }

        for messageID in target.messageIDs {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.id == messageID }
            )
            descriptor.fetchLimit = 1
            guard let message = try context.fetch(descriptor).first else {
                evidence.missingMessageIDs.insert(messageID)
                continue
            }
            if message.composerQueueOverride == .exclude,
               target.preparationIDs.isEmpty
                || !ReplySourcePreparationEligibility.isEligible(message, context: context) {
                evidence.excludedMessageIDs.insert(messageID)
            }
        }

        return evidence
    }

    /// Removes output that crossed the publication boundary after the app
    /// durably discarded its Composer owner. Missing rows that reappear are
    /// stale-context resurrection and are deleted; provider tombstones stay
    /// present but have all generated content scrubbed again.
    func discardLatePublications(
        for evidence: ComposerJobCancellationEvidence
    ) throws {
        let context = ModelContext(container)
        var changed = false

        for preparationID in evidence.missingPreparationIDs {
            var descriptor = FetchDescriptor<ReplySourcePreparation>(
                predicate: #Predicate<ReplySourcePreparation> { $0.id == preparationID }
            )
            descriptor.fetchLimit = 1
            if let preparation = try context.fetch(descriptor).first {
                deletePreparation(preparation, context: context)
                changed = true
            }
        }

        for draftID in evidence.missingDraftIDs {
            var descriptor = FetchDescriptor<Draft>(
                predicate: #Predicate<Draft> { $0.id == draftID }
            )
            descriptor.fetchLimit = 1
            if let draft = try context.fetch(descriptor).first {
                context.delete(draft)
                changed = true
            }
        }

        for draftID in evidence.discardedDraftIDs {
            var descriptor = FetchDescriptor<Draft>(
                predicate: #Predicate<Draft> { $0.id == draftID }
            )
            descriptor.fetchLimit = 1
            if let draft = try context.fetch(descriptor).first {
                draft.status = .discarded
                scrubGeneratedContent(from: draft, context: context)
                changed = true
            }
        }

        for messageID in evidence.excludedMessageIDs {
            var messageDescriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.id == messageID }
            )
            messageDescriptor.fetchLimit = 1
            guard let message = try context.fetch(messageDescriptor).first,
                  message.composerQueueOverride == .exclude else {
                continue
            }

            let drafts = try context.fetch(
                FetchDescriptor<Draft>(
                    predicate: #Predicate<Draft> { $0.message?.id == messageID }
                )
            )
            for draft in drafts {
                if draft.status == .discarded {
                    scrubGeneratedContent(from: draft, context: context)
                } else {
                    message.draft = nil
                    context.delete(draft)
                }
                changed = true
            }

            let preparations = try context.fetch(
                FetchDescriptor<ReplySourcePreparation>(
                    predicate: #Predicate<ReplySourcePreparation> {
                        $0.messageId == messageID
                    }
                )
            )
            // Completed preparation is reusable message context, independent
            // of the deleted Draft. Missing-ID resurrection is still removed
            // above. A newly admitted Needs Reply preparation belongs to the
            // still-open obligation, not to this cancelled foreground job.
            let preservesIndependentPreparation = !message.isTrashed
                && ReplySourcePreparationEligibility.isEligible(message, context: context)
            for preparation in preparations where !preservesIndependentPreparation
                && preparation.statusRaw != ReplySourcePreparationStatus.ready {
                deletePreparation(preparation, context: context)
                changed = true
            }
        }

        if changed {
            try context.save()
        }
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

    private func scrubGeneratedContent(from draft: Draft, context: ModelContext) {
        draft.replyText = ""
        draft.confidence = 0
        draft.citationsJSON = nil
        draft.gapsJSON = nil
        draft.deliverablesJSON = nil
        draft.replyAttachmentPathsJSON = nil
        draft.interviewStateJSON = nil
        draft.decisionHistoryJSON = nil
        draft.sourcesJSON = nil
        draft.sourceThreadCoverageJSON = nil
        draft.generatedSourcesJSON = nil
        draft.sourceContextTokenCount = nil
        draft.sourceContextFitJSON = nil
        draft.sourceContextTokenLimit = nil
        draft.sourceContextMeasurementRequestedAt = nil
        draft.automaticSourceResearchStateRaw = nil
        draft.automaticSourceResearchInputFingerprint = nil
        draft.decisionResearchOverlayJSON = nil
        draft.sourcesCuratedAt = nil
        draft.sourceThreadCount = 0
        draft.sourceExemplarCount = 0
        draft.styleMatch = 0
        draft.stageRaw = nil
        draft.bodyHTML = nil
        draft.inlinePhotosJSON = nil
        draft.pendingInstruction = nil
        draft.draftingInstruction = nil
        draft.appliedRuleIDsJSON = nil
        draft.personalizationJSON = nil
        draft.modelVersion = nil
        for revision in draft.orderedRevisions {
            context.delete(revision)
        }
        draft.revisions = []
        draft.baseRevisionID = nil
    }
}

private final class ComposerJobCancellationRace: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var evidence = ComposerJobCancellationEvidence()

    func requestCancellation(_ newEvidence: ComposerJobCancellationEvidence) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !newEvidence.isEmpty else { return false }
        let shouldSignal = evidence.isEmpty
        evidence.formUnion(newEvidence)
        return shouldSignal
    }

    func finish() -> ComposerJobCancellationEvidence {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        return evidence
    }
}

/// Per-account Dreaming eligibility counts: the message store's aggregate
/// query when it is configured, otherwise one in-memory pass over eligible
/// messages, loaded at most once per reader.
private struct AccountMemoryCountsReader {
    let messageStoreURL: URL?
    let context: ModelContext
    private var fallbackEligibleMessages: [Message]?

    init(messageStoreURL: URL?, context: ModelContext) {
        self.messageStoreURL = messageStoreURL
        self.context = context
    }

    mutating func counts(for accountID: UUID) throws -> AccountMemoryMessageCounts {
        if let messageStoreURL {
            return (try? MessageStoreHotPath.accountMemoryMessageCounts(
                accountID: accountID,
                storeURL: messageStoreURL
            )) ?? AccountMemoryMessageCounts(
                eligibleMessages: 0,
                sentMessages: 0,
                receivedMessages: 0
            )
        }
        if fallbackEligibleMessages == nil {
            fallbackEligibleMessages = try context.fetch(FetchDescriptor<Message>()).filter { message in
                message.analysis?.bodySummary?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty == false
                    && message.vectorTimeFilterDate != nil
            }
        }
        let accountMessages = (fallbackEligibleMessages ?? []).filter {
            $0.accountID == accountID || $0.account?.id == accountID
        }
        let sent = accountMessages.filter(\.isSentByUser).count
        return AccountMemoryMessageCounts(
            eligibleMessages: accountMessages.count,
            sentMessages: sent,
            receivedMessages: max(0, accountMessages.count - sent)
        )
    }
}

public struct ModelResourceSnapshot: Sendable {
    public let decision: ResourceDecision
    public let maximumEmbeddingLanes: Int
    public let bgeStatus: PipelineReadinessStatus
    public let evaluatedAt: Date

    public init(
        decision: ResourceDecision,
        maximumEmbeddingLanes: Int,
        bgeStatus: PipelineReadinessStatus,
        evaluatedAt: Date = Date()
    ) {
        self.decision = decision
        self.maximumEmbeddingLanes = maximumEmbeddingLanes
        self.bgeStatus = bgeStatus
        self.evaluatedAt = evaluatedAt
    }
}

public final class BackgroundScheduler: @unchecked Sendable {

    private struct MeaningLensScopeState {
        let isEnabled: Bool
        let isActive: Bool
        let hasLiveAuthority: Bool
    }

    private static let vectorIndexReconcileInterval: TimeInterval = 6 * 3600
    private static let embeddingReindexInterval: TimeInterval = 1
    private static let healthSnapshotInterval = 10
    private static let maintenanceFairnessInterval = 12
    private static let failedIMAPJobReseedCooldown: TimeInterval = 30 * 60
    /// Coalesce settled corpus changes while Meaning is closed. Active demand
    /// and a missing initial snapshot bypass this refresh-only cooldown.
    private static let meaningMembershipBackgroundCooldown: TimeInterval = 60 * 60
    private static let maintenanceFairnessTypes: [JobType] = [
        .refine,
        .reconcileVectorIndex,
        .reindexEmbeddings
    ]
    private static let qwenBackpressureMaintenanceMinimumAge: TimeInterval = 60
    private static let qwenBackpressureMaintenanceTypes: [JobType] = [
        .extractAttachments,
        .extractVisualAttachments,
        .entityPromote
    ]
    private static let qwenInterpretationBackpressureEnterLead = 48
    private static let qwenInterpretationBackpressureExitLead = 16
    private static let qwenInterpretationBackpressureMinimumPlacedNodes = 12
    private static let settledInterpretationSnapshotReuseInterval: TimeInterval = 5
    private static let interpretationSnapshotInvalidatingJobTypes: Set<JobType> = [
        .imapBackfill,
        .embed,
        .index,
        .summarize,
        .reindexEmbeddings,
    ]
    private static let catchUpMaintenanceTypes: Set<JobType> = [
        .refine,
        .reconcileVectorIndex,
        .reindexEmbeddings,
        .entityEmbed,
        .entityRefresh,
        .resolveSemanticTags
    ]
    private static let visiblePlacementTypes: Set<JobType> = [
        .index,
        .refine,
        .frameBurst,
        .clusterDetect
    ]
    private static let interactivePlacementMutationTypes: Set<JobType> = [
        .index,
        .refine,
        .frameBurst
    ]
    private static let coreProgressTypes: Set<JobType> = [
        .imapBackfill,
        .embed,
        .index
    ]
    private static let initialImportDeferredTypes: Set<JobType> = [
        .embed,
        .index,
        .frameBurst,
        .clusterDetect,
        .extractAttachments,
        .extractVisualAttachments,
        .entityPromote,
        .entityEmbed,
        .entityRefresh,
        .resolveSemanticTags,
        .refine,
        .reconcileVectorIndex,
        .reindexEmbeddings,
        .accountMemoryRefresh,
        .customCategoryDefinition,
        .generateDraft,
        .generateDraftingRules,
        .distillStyleRegisters,
        .categoryLifecycle
    ]
    private static let initialImportFirstLightTypes: Set<JobType> = [
        .embed,
        .index
    ]
    private static let qwenInterpretationBackpressureTypes: Set<JobType> = [
        .extractAttachments,
        .extractVisualAttachments,
        .summarizeAttachments,
        .entityEmbed,
        .entityRefresh,
        .index,
        .refine,
        .frameBurst,
        .reconcileVectorIndex,
        .reindexEmbeddings,
        .categoryLifecycle
    ]
    private static let accountMemoryRefreshBlockingTypes: Set<JobType> = [
        .summarize,
        .summarizeAttachments,
        .resolveSemanticTags,
        .generateDraft,
        .prepareReplySources,
        .buildTrainingPairs,
        .train,
        .imapBackfill,
        .extractAttachments,
        .extractVisualAttachments,
        .extractCaptureMetadata
    ]
    private static let accountMemoryRefreshPreemptibleTrainingTypes: Set<JobType> = [
        .buildTrainingPairs,
        .train
    ]
    private static let generativeWorkerJobTypes = Set(JobType.allCases.filter {
        $0.workerRole == .qwen
    })
    /// Backstop for the Dreaming hold anchor cache; the seeding pass and every
    /// Dreaming job invalidate it well within this age.
    private static let dreamingHoldAnchorMaximumAge: TimeInterval = 30
    private static let qwenInterpretationModelDemandTypes: Set<JobType> = [
        .summarize,
        .summarizeAttachments,
        .accountMemoryRefresh,
        .customCategoryDefinition,
        .prepareReplySources,
        .generateDraftingRules,
        .distillStyleRegisters,
    ]
    private static let bgeModelDemandTypes: Set<JobType> = [
        .embed,
        .entityEmbed,
        .entityRefresh,
        .reindexEmbeddings,
        .resolveSemanticTags,
    ]

    let runner: PipelineRunner
    private let queue: JobQueue
    private let monitor: SystemMonitor
    private let idleThreshold: TimeInterval
    public let publisher: TrainingStatusPublisher
    private let engine: any TrainingEngine
    private let imapSessionManager: IMAPSessionManager?
    // `.refine` seed is actionability-gated on "at least one placed vector".
    // Stored so `ensurePipelineJobsExist` can check without each call having
    // to re-discover the store from an orchestrator parameter.
    //
    // Module-internal (not `private`) so `@testable` teardown can call
    // `vectorStore.close()` before deleting a temp database directory; closing
    // deterministically avoids the macOS SQLite "vnode unlinked while in use"
    // log that fires when the file is removed while this handle is still open.
    let vectorStore: VectorStore
    private let vectorIndex: VectorIndex?
    private let embedder: EmbeddingProvider
    private let embedderRegistry: EmbedderRegistry
    private let messageStoreURL: URL?
    private let constellationActiveMonitor: ConstellationActiveMonitor?
    private let appActivityMonitor: SharedAppActivityMonitor?
    private let workerRole: WorkerRole?
    private let generationContextPackStore: GenerationContextPackStore?
    private let siblingModelWorkerActive: (() -> Bool)?
    private let siblingModelResident: (() -> Bool)?
    private let interactiveQwenGenerationActive: (() -> Bool)?
    private let interactiveQwenGenerationLane: (() -> InteractiveGenerationLane?)?
    /// Runtime check for Apple Foundation Models availability used by older
    /// tests and Apple-backed on-demand paths. Background interpretation is
    /// Qwen-only.
    private let appleAvailabilityProvider: @Sendable () -> Bool
    /// Optional pub/sub sink for successful job completions. When non-nil,
    /// `tick` yields a `JobCompletionEvent` after every `queue.complete`.
    /// Failed jobs (the `catch` branch → `queue.fail`) do NOT broadcast.
    private let broadcaster: JobCompletionBroadcaster?
    private let onManualProjectSourceChange: @MainActor @Sendable (
        Set<UUID>,
        Set<MailProjectRuleFacet>
    ) -> Void
    private let entityOrchestrator: EntityOrchestrator?
    private let allowsVisiblePlacement: @MainActor @Sendable () -> Bool
    private var preferEmbedOverIndexNext = true
    private var maintenanceFairnessCredit = 0
    private var healthSnapshotTickCounter = 0
    private var lastHealthSnapshotSignature: String?
    private var qwenInterpretationBackpressureActive = false
    @MainActor private var taggingWindowLedger = IngestionTailStageAuthority.TaggingWindowLedger()
    /// Dreaming's hold anchor reads per-account message counts, too costly
    /// for every tick and Dreaming yield poll. Reused until the seeding pass
    /// or a Dreaming job (the only writer of Dreaming state) invalidates it.
    private struct DreamingHoldAnchorCache {
        let anchor: Date?
        let loadedAt: Date
    }
    @MainActor private var dreamingHoldAnchorCache: DreamingHoldAnchorCache?
    @MainActor var dreamingHoldAnchorLoadObserver: (() -> Void)?
    @MainActor private var interpretationBackpressureSnapshotCache =
        InterpretationBackpressureSnapshotCache(
            settledReuseInterval: BackgroundScheduler.settledInterpretationSnapshotReuseInterval
        )
    private let performanceProfile: PipelinePerformanceProfile
    @MainActor private var lastModelResourceSnapshot: ModelResourceSnapshot?
    @MainActor private var runningUserInitiatedQwenJob = false
    @MainActor public var currentJobReporter: ((JobType?) -> Void)?
    @MainActor var interpretationSnapshotLoadObserver: (() -> Void)?
    /// Hard pipeline pause. While `true`:
    ///   - `tick()` returns false immediately without claiming a job.
    /// Used by the developer "Delete All Data" reset to stop in-flight work
    /// from racing with the wipe + by a user-facing pause/resume control.
    /// Toggled from MainActor; reads are non-isolated and tolerate the
    /// at-most-one-tick race that produces (since each tick is short
    /// relative to user-perceived pause latency).
    public nonisolated(unsafe) var isPaused: Bool = false

    /// Each user mail-action type runs serially, independently of backfill.
    public static let independentMailActionTypes: Set<JobType> = [.sendOutbox, .syncComposerDrafts, .mailboxMutation]
    @MainActor public var usesIndependentMailActions = false
    @MainActor private var activeMailActions: Set<JobType> = []
    @MainActor private var nextMailActionReconciliation: [JobType: Date] = [:]
    private let mailActionReachability: any NetworkReachability

    @MainActor
    public func tickMailAction(type: JobType, context: ModelContext) async throws -> Bool {
        guard !AccountDisconnectionRequest.isPending else { return false }
        guard usesIndependentMailActions, !isPaused, !Task.isCancelled, mailActionReachability.isOnline,
              Self.independentMailActionTypes.contains(type),
              !activeMailActions.contains(type), type.isOwned(by: workerRole) else { return false }
        // These operations share the mutation connection and its activity
        // presentation. Keep their execution serial; SMTP stays independent.
        if type != .sendOutbox,
           !activeMailActions.isDisjoint(with: [.syncComposerDrafts, .mailboxMutation]) { return false }
        activeMailActions.insert(type)
        defer { activeMailActions.remove(type) }
        if type != .sendOutbox {
            let other: JobType = type == .syncComposerDrafts ? .mailboxMutation : .syncComposerDrafts
            if try !JobFetch.jobs(type: other, statuses: [.running], context: context).isEmpty { return false }
        }
        // Retry deadlines must progress even if the background seeding loop
        // is still awaiting a slow IMAP operation.
        let active = try JobFetch.jobs(type: type, statuses: [.pending, .running], context: context)
        if active.contains(where: { $0.status == .running }) { return false }
        if active.isEmpty {
            let now = Date()
            if let next = nextMailActionReconciliation[type], next > now { return false }
            nextMailActionReconciliation[type] = now.addingTimeInterval(10)
        }
        if active.isEmpty, type == .sendOutbox {
            let now = Date()
            let items = try context.fetch(FetchDescriptor<OutboxItem>())
            if items.contains(where: {
                $0.status == .queued && $0.account?.needsReauth != true
                    && ($0.nextAttemptAfter == nil || $0.nextAttemptAfter! <= now)
            }) {
                try queue.enqueue(type: .sendOutbox, priority: 1, context: context)
            }
        }
        if active.isEmpty, type == .syncComposerDrafts {
            try ComposerDraftSyncScheduler.enqueueIfNeeded(context: context)
        }
        if active.isEmpty, type == .mailboxMutation {
            let now = Date()
            let mutations = try context.fetch(FetchDescriptor<MailboxMutation>())
            if mutations.contains(where: {
                $0.status == .queued && ($0.nextAttemptAfter == nil || $0.nextAttemptAfter! <= now)
            }) {
                try queue.enqueue(type: type, priority: 2, context: context)
            }
        }
        let job: Job?
        if let workerRole {
            job = try queue.claimSpecificType(type, context: context, workerRole: workerRole)
        } else {
            job = try queue.claimSpecificType(type, context: context)
        }
        guard let job else { return false }
        do {
            let result = try await runner.run(job: job, context: context, batchSize: 1)
            try queue.complete(job: job, context: context)
            reportManualProjectSourceChanges(result.messageMutations)
            broadcaster?.yield(JobCompletionEvent(
                type: type, payload: job.payload, completedAt: Date(),
                messageMutations: result.messageMutations
            ))
        } catch {
            // OutboxWorker owns delivery retries and ambiguous-send protection.
            // A later drain reconciles any interrupted item without resending it.
            try queue.fail(job: job, error: error.localizedDescription, context: context)
            throw error
        }
        return true
    }

    public init(
        monitor: SystemMonitor,
        canonicalStore: CanonicalStore,
        vectorStore: VectorStore,
        vectorIndex: VectorIndex? = nil,
        embedder: EmbeddingProvider,
        embedderRegistry: EmbedderRegistry? = nil,
        hybridRetriever: HybridRetriever? = nil,
        migrationCoordinator: EmbeddingMigrationCoordinator? = nil,
        embeddingOrchestrator: EmbeddingOrchestrator? = nil,
        engine: TrainingEngine,
        sendExecutor: SendExecuting,
        trainingStatusPublisher: TrainingStatusPublisher,
        modelActivityStatusPublisher: ModelActivityStatusPublisher? = nil,
        toolRegistry: ToolRegistry? = nil,
        generationContextPackStore: GenerationContextPackStore? = nil,
        requiresGenerationContextPack: Bool = false,
        imapSessionManager: IMAPSessionManager? = nil,
        layoutOrchestrator: LayoutOrchestrator? = nil,
        frameBurstWorker: FrameBurstWorker? = nil,
        clusterDetectionWorker: ClusterDetectionWorker? = nil,
        entityOrchestrator: EntityOrchestrator? = nil,
        allowsIMAPWork _: @escaping @MainActor @Sendable () -> Bool = { true },
        allowsVisiblePlacement: @escaping @MainActor @Sendable () -> Bool = { true },
        constellationActiveMonitor: ConstellationActiveMonitor? = nil,
        appActivityMonitor: SharedAppActivityMonitor? = nil,
        broadcaster: JobCompletionBroadcaster? = nil,
        onManualProjectSourceChange: @escaping @MainActor @Sendable (
            Set<UUID>,
            Set<MailProjectRuleFacet>
        ) -> Void = { _, _ in },
        messageStoreURL: URL? = nil,
        checkpointDirectory: URL? = nil,
        workerRole: WorkerRole? = nil,
        mailActionReachability: any NetworkReachability = AlwaysOnlineReachability(),
        siblingModelWorkerActive: (() -> Bool)? = nil,
        siblingModelResident: (() -> Bool)? = nil,
        interactiveQwenGenerationActive: (() -> Bool)? = nil,
        interactiveQwenGenerationLane: (() -> InteractiveGenerationLane?)? = nil,
        messagesTranscriptProvider: any MessagesTranscriptProviding = UnavailableMessagesTranscriptProvider(),
        mcpEnvironmentResolver: (@Sendable (MCPConfiguredServer) -> [String: String])? = nil,
        idleThreshold: TimeInterval = 300,
        localDeletionCascade: MessageLocalDeletionCascade? = nil,
        performanceProfile: PipelinePerformanceProfile = .current(),
        appleAvailabilityProvider: @escaping @Sendable () -> Bool = {
            AppleIntelligenceAvailability.current().isAvailable
        }
    ) {
        self.monitor = monitor
        self.queue = JobQueue()
        self.idleThreshold = idleThreshold
        self.publisher = trainingStatusPublisher
        self.engine = engine
        self.imapSessionManager = imapSessionManager
        self.vectorStore = vectorStore
        self.vectorIndex = vectorIndex
        self.embedder = embedder
        let resolvedRegistry = embedderRegistry ?? EmbedderRegistry(current: embedder)
        self.embedderRegistry = resolvedRegistry
        self.messageStoreURL = messageStoreURL
        self.constellationActiveMonitor = constellationActiveMonitor
        self.appActivityMonitor = appActivityMonitor
        self.workerRole = workerRole
        self.mailActionReachability = mailActionReachability
        self.generationContextPackStore = generationContextPackStore
        self.siblingModelWorkerActive = siblingModelWorkerActive
        self.siblingModelResident = siblingModelResident
        self.interactiveQwenGenerationActive = interactiveQwenGenerationActive
        self.interactiveQwenGenerationLane = interactiveQwenGenerationLane
        self.broadcaster = broadcaster
        self.onManualProjectSourceChange = onManualProjectSourceChange
        self.entityOrchestrator = entityOrchestrator
        self.allowsVisiblePlacement = allowsVisiblePlacement
        self.performanceProfile = performanceProfile
        self.appleAvailabilityProvider = appleAvailabilityProvider
        self.runner = PipelineRunner(
            canonicalStore: canonicalStore,
            vectorStore: vectorStore,
            vectorIndex: vectorIndex,
            embedder: embedder,
            embedderRegistry: resolvedRegistry,
            hybridRetriever: hybridRetriever,
            migrationCoordinator: migrationCoordinator,
            embeddingOrchestrator: embeddingOrchestrator,
            engine: engine,
            trainingStatusPublisher: trainingStatusPublisher,
            modelActivityStatusPublisher: modelActivityStatusPublisher,
            toolRegistry: toolRegistry,
            generationContextPackStore: generationContextPackStore,
            requiresGenerationContextPack: requiresGenerationContextPack,
            sendExecutor: sendExecutor,
            imapSessionManager: imapSessionManager,
            layoutOrchestrator: layoutOrchestrator,
            frameBurstWorker: frameBurstWorker,
            clusterDetectionWorker: clusterDetectionWorker,
            entityOrchestrator: entityOrchestrator,
            allowsVisiblePlacement: allowsVisiblePlacement,
            constellationActiveMonitor: constellationActiveMonitor,
            localDeletionCascade: localDeletionCascade,
            messageStoreURL: messageStoreURL,
            checkpointDirectory: checkpointDirectory,
            messagesTranscriptProvider: messagesTranscriptProvider,
            mcpEnvironmentResolver: mcpEnvironmentResolver,
            performanceProfile: performanceProfile
        )
        // Captured weakly to avoid retaining the scheduler through runner
        // callbacks.
        Task { @MainActor [weak self] in
            self?.runner.trainingPreemptionProvider = { [weak self] context in
                self?.trainingPreemptionReason(context: context)
            }
            self?.runner.interactiveQwenGenerationProvider = { [weak self] in
                guard let self else { return false }
                return (self.interactiveQwenGenerationActive?() ?? false)
                    || self.composerDraftingForegroundActive()
            }
            self?.runner.accountMemoryRefreshYieldProvider = { [weak self] context in
                guard let self else { return true }
                return self.shouldYieldAccountMemoryRefresh(context: context)
            }
            self?.runner.replySourcePreparationYieldProvider = { [weak self] context in
                guard let self else { return true }
                return self.shouldYieldReplySourcePreparation(context: context)
            }
        }
    }

    // MARK: - Startup sweep

    /// Reset any jobs left in `.running` state back to `.pending`. A `.running`
    /// row in a fresh process means the prior process died mid-job — the job
    /// isn't actually running anywhere, but `claimNext` ignores `.running` and
    /// `ensurePipelineJobsExist` counts it as active, so the type is effec-
    /// tively wedged. Sweep on init; cheap. MailboxMutation rows use their own
    /// lifecycle table, but follow the same crash-recovery rule when this role
    /// owns `.mailboxMutation`.
    @MainActor
    public func resetStaleRunningJobs(
        context: ModelContext,
        workerRole: WorkerRole? = nil
    ) throws {
        let all = try JobFetch.running(context: context)
        var reset = 0
        var resetAccountMemoryRefresh = false
        var resetReplySourcePreparationJobs: [Job] = []
        for job in all {
            if let workerRole, !job.type.isOwned(by: workerRole) {
                continue
            }
            if job.type == .accountMemoryRefresh {
                resetAccountMemoryRefresh = true
            }
            if job.type == .prepareReplySources {
                resetReplySourcePreparationJobs.append(job)
            }
            job.status = .pending
            job.startedAt = nil
            reset += 1
        }
        if resetAccountMemoryRefresh {
            dreamingHoldAnchorCache = nil
            let states = try context.fetch(FetchDescriptor<AccountMemoryRefreshState>())
            for state in states where state.lastStatusRaw == AccountMemoryRefreshStatus.running {
                let now = Date()
                state.lastStatusRaw = AccountMemoryRefreshStatus.deferred
                state.lastRunCompletedAt = now
                state.updatedAt = now
                state.lastError = nil
            }
        }
        var resetMailboxMutations = 0
        if JobType.mailboxMutation.isOwned(by: workerRole) {
            let rows = try context.fetch(FetchDescriptor<MailboxMutation>())
            for row in rows where row.status == .running {
                row.status = .queued
                row.nextAttemptAfter = nil
                resetMailboxMutations += 1
            }
        }
        if reset > 0 || resetMailboxMutations > 0 {
            try context.save()
            let preparationCoordinator = ReplySourcePreparationCoordinator()
            for job in resetReplySourcePreparationJobs {
                // A job reset after an unclean stop is not the model rejecting its inputs.
                try preparationCoordinator.mirrorFailure(
                    from: job,
                    countsTowardCap: false,
                    context: context
                )
            }
            print("[Ohia] scheduler: reset \(reset) stale .running job(s) to .pending; \(resetMailboxMutations) mailbox mutation(s) to .queued")
        }
    }

    // MARK: - Tick

    /// Attempt to process one job from the queue.
    /// Returns `true` if a job was processed, `false` if nothing was done.
    @MainActor
    public func tick(context: ModelContext) async throws -> Bool {
        guard !AccountDisconnectionRequest.isPending else { return false }
        // Hard pause — set by the developer reset and the user-facing
        // pause control. Skip claiming any new job; in-flight orchestrators
        // observe the same flag through a cancellation closure.
        if isPaused {
            return false
        }

        // An explicit Composer model request owns model and local-processing
        // capacity until its Qwen pass finishes. Network-only IMAP acquisition
        // remains independent and may continue feeding the store concurrently.
        let composerModelDemandOwnsBGE = workerRole == .bge
            && Self.hasActiveUserInitiatedComposerDemand(context: context)

        let runState = TrainingRunState.current(context: context)
        let evaluatedDecision = currentResourceDecision(context: context)
        if workerRole != .bge {
            _ = try completeSatisfiedGenericSummarizeDrains(context: context)
            try normalizeHistoricalInterpretationBacklog(context: context)
            try normalizeAttachmentSummaryBacklogPriority(context: context)
        }
        let bodySummaryBacklogPending = workerRole != .bge
            && ((try? hasBodySummaryBacklogPending(context: context)) == true)
        let activeTypes = activeJobTypes(context: context)
        let resourceSnapshot = recordModelResourceSnapshot(
            decision: evaluatedDecision,
            activeJobTypes: activeTypes,
            context: context,
            at: Date()
        )
        let decision = resourceSnapshot.decision
        let bgeStatus = resourceSnapshot.bgeStatus
        // Train Now claims as user-initiated work only inside its exclusive
        // hour. Afterwards the request flag can stay set until the run it is
        // accelerating ends, but its slices take ordinary turns.
        let trainNowLaneOpen = try PipelineFeatureFlags.qwenPersonalizationTrainingEnabled
            && runState.forceRunRequested
            && trainNowIsExclusive(runState: runState, context: context)
        let exposedTrainingWait = runState.forceRunRequested || activeTypes.contains(.train)
        if exposedTrainingWait {
            publisher.setResourceWaitReason(trainingWaitReason(
                decision: decision,
                allowsUserInitiatedQwen: trainNowLaneOpen && decision.qwen.allowsUserInitiatedWork
            ))
        }

        if decision.shouldPauseAll {
            return false
        }

        // Force-run bypass: when the user explicitly requested training, skip
        // the background priority bands and claim the pending .train job after
        // user-visible sends and active Composer requests. Without this,
        // .train (priority 8) stays queued behind any backlog of priority 6–7
        // work. Gated on engine.isModelLoaded so that a force-run click while
        // the model is still downloading doesn't claim the job — Phase 1's
        // engine.loadModel would otherwise block the main actor on the download.
        // Critical thermal + memory still block via shouldPauseAll above.
        let job: Job
        var claimedViaMaintenanceSlot = false
        var claimedUserInitiatedQwenJob = false
        var claimedOnboardingFirstLightEmbed = false
        let composerDrafting = composerPriorityDemandActive(context: context)
        let contextReadyComposerWork = hasContextReadyComposerWork(context: context)
        let initialImportWorkPending = try hasInitialImportWorkPending(context: context)
        let visiblePlacementAllowed = allowsVisiblePlacement()
        let onboardingWitnessEmbedAllowed = shouldClaimOnboardingWitnessEmbed(
            visiblePlacementAllowed: visiblePlacementAllowed
        )
        let onboardingFirstPlacementPending = onboardingWitnessEmbedAllowed
            && ((try? vectorStore.vectorsWithLayout(filter: nil, limit: 1).isEmpty) == true)
        let meaningLensScope = meaningLensScopeState()
        let meaningClusterStatus = PipelineReadiness.meaningClusterStatus(
            context: context,
            vectorStore: vectorStore,
            clusterStore: VectorClusterStore(
                sharedDB: vectorStore.rawHandle,
                lock: vectorStore.rawLock
            ),
            messageStoreURL: messageStoreURL,
            currentEmbeddingVersion: embedderRegistry.current.embeddingVersion,
            initialImportWorkPending: initialImportWorkPending
        )
        let ingestionTail = try currentIngestionTail(
            context: context,
            meaningScope: meaningLensScope,
            meaningClusterStatus: meaningClusterStatus,
            activeTypes: activeTypes
        )
        let ingestionTailStage = ingestionTail.stage
        var excludedTypes = excludedJobTypes(
            decision: decision,
            bgeStatus: bgeStatus,
            qwenModelLoaded: engine.isModelLoaded,
            composerDraftingActive: composerDrafting,
            contextReadyComposerWork: contextReadyComposerWork
        )
        if initialImportWorkPending {
            var initialImportDeferredTypes = Self.initialImportDeferredTypes
            if visiblePlacementAllowed {
                initialImportDeferredTypes.subtract(Self.initialImportFirstLightTypes)
            }
            if composerDrafting {
                initialImportDeferredTypes.remove(.generateDraft)
            }
            excludedTypes.formUnion(initialImportDeferredTypes)
        }
        // Cluster jobs are admitted only through `claimClusterDetect` below,
        // behind the Meaning scope, readiness and resource gates. A generic
        // priority claim would bypass every one of them.
        excludedTypes.insert(.clusterDetect)
        excludedTypes.formUnion(ingestionTail.blockedJobTypes)
        if JobType.accountMemoryRefresh.isOwned(by: workerRole),
           (bodySummaryBacklogPending
            || (try? hasAccountMemoryRefreshBlockingWork(
                context: context,
                tail: ingestionTail
            )) == true) {
            excludedTypes.insert(.accountMemoryRefresh)
        }
        // Released tagging or Dreaming outwaited training's hold. A slice
        // already running keeps the model; the next one waits. Tagging needs
        // this Qwen worker idle, because the retrieval worker is throttled
        // below maintenance priority while its sibling is active. Dreaming
        // takes its alternating turn in its own lane below so neither the
        // re-enqueued `.train` nor other priority 6-8 work claims first.
        let trainingDeferral = try trainingTailDeferral(
            tail: ingestionTail,
            runState: runState,
            maxAllowedPriority: decision.maxAllowedPriority,
            excludedTypes: excludedTypes,
            initialImportWorkPending: initialImportWorkPending,
            context: context
        )
        if trainingDeferral != nil {
            excludedTypes.formUnion(Self.accountMemoryRefreshPreemptibleTrainingTypes)
            if exposedTrainingWait {
                publisher.setResourceWaitReason(trainingWaitReason(
                    decision: decision,
                    tailDeferral: trainingDeferral
                ))
            }
        }
        if composerModelDemandOwnsBGE {
            let networkAcquisitionTypes: Set<JobType> = [
                .imapPollFolder,
                .imapBackfill
            ]
            guard let acquisitionJob = try claimNext(
                maxPriority: 4,
                context: context,
                excluding: Set(JobType.allCases).subtracting(networkAcquisitionTypes)
            ) else {
                return false
            }
            job = acquisitionJob
        } else if decision.maxAllowedPriority >= 1,
                  let sendJob = try claimSpecificType(.sendOutbox, context: context) {
            // User-visible sends keep absolute priority even when the fairness
            // slot below is due.
            job = sendJob
        } else if composerDrafting,
                  decision.maxAllowedPriority >= 1,
                  decision.modelComputeBudget.qwenAllowsGeneration,
                  let composerJob = try claimUserInitiatedComposerJob(context: context) {
            // User-initiated Composer work (source preparation / select /
            // Generate now / instruction / regenerate, enqueued at priority
            // ≤ 3) means someone is waiting on the model. Service it ahead
            // of live-inbound freshness and the normal priority bands. The
            // explicit priority is the authority that bypasses background
            // preparation exclusions; ordinary priority-4 preparation stays
            // in the normal queue lane.
            job = composerJob
        } else if trainNowLaneOpen,
                  ingestionTailStage != .membership,
                  engine.isModelLoaded,
                  decision.qwen.allowsUserInitiatedWork,
                  let trainJob = try claimSpecificType(.train, context: context) {
            job = trainJob
            claimedUserInitiatedQwenJob = true
        } else if trainNowLaneOpen,
                  bgeStatus.isComplete,
                  ingestionTailStage != .membership,
                  engine.isModelLoaded,
                  decision.qwen.allowsUserInitiatedWork,
                  let preparationJob = try claimSpecificType(.buildTrainingPairs, context: context) {
            // Train Now includes preparing its first usable examples. Keep
            // the request pending until a nonempty training snapshot exists.
            job = preparationJob
            claimedUserInitiatedQwenJob = true
        } else if let summaryJob = try claimUserInitiatedSummaryJob(
            decision: decision,
            context: context
        ) {
            job = summaryJob
            claimedUserInitiatedQwenJob = true
        } else if let liveFreshnessJob = try claimLiveInboundFreshnessJob(
            decision: decision,
            context: context
        ) {
            job = liveFreshnessJob
        } else if !initialImportWorkPending,
                  !excludedTypes.contains(.entityPromote),
                  let entityPromotionJob = try claimSpecificType(.entityPromote, context: context) {
            // Promotion also reconciles stale derived attachment entities and
            // their jobs. That bookkeeping is lightweight and does not invoke
            // BGE, so it remains runnable while model work is paused.
            job = entityPromotionJob
        } else if let coreProgressJob = try claimQwenBackpressureInitialCoreProgressJob(
            decision: decision,
            excluding: excludedTypes,
            context: context
        ) {
            job = coreProgressJob
        } else if !initialImportWorkPending,
                  shouldClaimMaintenanceFairness(decision: decision),
                  let maintenanceJob = try claimMaintenanceFairnessJob(context: context) {
            job = maintenanceJob
            claimedViaMaintenanceSlot = true
        } else if !initialImportWorkPending,
                  shouldClaimQwenBackpressureMaintenance(decision: decision),
                  let maintenanceJob = try claimQwenBackpressureMaintenanceJob(context: context) {
            job = maintenanceJob
            claimedViaMaintenanceSlot = true
        } else if !initialImportWorkPending,
                  shouldClaimQwenBackpressureVisibleIndex(decision: decision, context: context),
                  let indexJob = try claimSpecificType(.index, context: context) {
            job = indexJob
            claimedViaMaintenanceSlot = true
        } else if decision.maxAllowedPriority >= 5,
                  onboardingWitnessEmbedAllowed,
                  !excludedTypes.contains(.embed),
                  let embedJob = try claimSpecificType(.embed, context: context) {
            // The witness panel exists to show the Constellation populating
            // while historical acquisition continues. Keep embed work ahead
            // of priority-3 IMAP backfill for the lifetime of the panel. Only
            // the very first batch is cut to one message for minimum latency;
            // later witness batches use the normal performance-profile size.
            job = embedJob
            claimedOnboardingFirstLightEmbed = onboardingFirstPlacementPending
        } else if decision.maxAllowedPriority >= 1,
                  let urgentJob = try claimNext(
                    maxPriority: min(4, decision.maxAllowedPriority),
                    context: context,
                    excluding: excludedTypes
                  ) {
            // Strict priority for the user-facing band: send → IMAP poll
            // → IMAP backfill. Held above the embed fast-lane below so live
            // mailbox work remains responsive during historical import.
            job = urgentJob
        } else if trainingDeferral == .dreaming,
                  let dreamingJob = try claimSpecificType(.accountMemoryRefresh, context: context) {
            // Released Dreaming's alternating turn between training slices.
            job = dreamingJob
        } else if meaningLensScope.isEnabled,
                  meaningClusterStatus.sourceDataIsSettled,
                  try meaningMembershipMayRun(
                    scope: meaningLensScope,
                    status: meaningClusterStatus,
                    context: context
                  ),
                  shouldClaimForegroundClusterDetect(decision: decision),
                  let clusterJob = try claimClusterDetect(
                    frame: .meaning,
                    context: context
                  ) {
            // Cluster labels/tints are visible Meaning-lens content, not
            // idle-only maintenance. This path also drains legacy priority-9
            // cluster jobs that were seeded before the foreground lane existed.
            job = clusterJob
        } else if decision.maxAllowedPriority >= 5,
                  preferEmbedOverIndexNext,
                  !excludedTypes.contains(.embed),
                  let embedJob = try claimSpecificType(.embed, context: context) {
            // A single embed batch can enqueue many `.index` jobs. If those
            // get claimed ahead of the next `.embed`, the embedded count sits
            // at 50 even though an embed job is pending. Cut one embed batch
            // through after an index-heavy tick; the flag below flips back
            // once index gets a turn, preserving live star placement.
            job = embedJob
        } else {
            guard let normalJob = try claimNext(
                maxPriority: decision.maxAllowedPriority,
                context: context,
                excluding: excludedTypes
            ) else {
                return false
            }
            job = normalJob
        }
        let jobType = job.type
        let jobPayload = job.payload
        let jobPriority = job.priority
        let jobRetryCount = job.retryCount
        defer {
            // Dreaming is the only writer of the state its hold anchor reads.
            if jobType == .accountMemoryRefresh {
                dreamingHoldAnchorCache = nil
            }
        }

        if jobType == .embed {
            preferEmbedOverIndexNext = false
        } else if jobType == .index {
            preferEmbedOverIndexNext = true
        }

        let batchSize = claimedOnboardingFirstLightEmbed
            ? 1
            : performanceProfile.scaledBatchSize(multiplier: decision.batchSizeMultiplier)

        let signpostID = schedulerSignposter.makeSignpostID()
        let signpostState = schedulerSignposter.beginInterval(
            "pipeline.tick",
            id: signpostID,
            "type=\(jobType.rawValue) priority=\(jobPriority)"
        )
        let previousUserInitiatedQwenJob = runningUserInitiatedQwenJob
        runningUserInitiatedQwenJob = claimedUserInitiatedQwenJob
        defer {
            runningUserInitiatedQwenJob = previousUserInitiatedQwenJob
        }
        do {
            let resultForJob: PipelineResult
            currentJobReporter?(jobType)
            do {
                defer { currentJobReporter?(nil) }
                let executionContext = Self.pipelineExecutionContext(
                    for: jobType,
                    schedulerContext: context
                )
                resultForJob = try await runPipelineJob(
                    job: job,
                    context: executionContext,
                    batchSize: batchSize,
                    resourceDecision: decision
                )
            }
            if resultForJob.releasedJob {
                // The runner declined the job under the current compute
                // budget (e.g. a backlog per-message embed while only the
                // live-freshness class is borrowed through the foreground
                // throttle). Hand it back untouched; the claim-side budget
                // exclusions keep it unclaimed until its class is
                // re-admitted, so there is no claim/release churn.
                try releaseDeclinedJob(job, context: context)
                schedulerSignposter.endInterval("pipeline.tick", signpostState, "status=released")
                return true
            }
            var result = resultForJob
            try queue.complete(job: job, context: context)
            reportManualProjectSourceChanges(result.messageMutations)
            if Self.interpretationSnapshotInvalidatingJobTypes.contains(jobType) {
                interpretationBackpressureSnapshotCache.invalidate()
            }
            // A message-specific embed is the live-freshness lane. Do not let
            // it spill into the historical backlog in the same tick; generic
            // embed jobs are the explicit bulk-drain signal.
            if jobType == .embed,
               job.messageId == nil,
               !claimedOnboardingFirstLightEmbed,
               decision.isCatchUpModeActive {
                do {
                    let extra = try await runner.runEmbeddingCatchUpDrain(
                        context: context,
                        resourceDecision: decision
                    )
                    if extra > 0 {
                        result = result.addingProcessedItems(extra)
                    }
                } catch {
                    print("[Scheduler] catch-up embed drain stopped: \(String(reflecting: type(of: error)))")
                }
            }
            try requeueBatchJobIfNeeded(
                type: jobType,
                result: result,
                context: context
            )
            let completedAt = Date()
            let shouldDrainVisibleIndexAfterTick = !composerModelDemandOwnsBGE
                && (!initialImportWorkPending || visiblePlacementAllowed)
            if shouldDrainVisibleIndexAfterTick {
                if jobType == .embed {
                    let placed = await drainAdditionalIndexJobs(
                        resourceDecision: decision,
                        context: context
                    )
                    if placed > 0 {
                        if shouldLogLayoutBurstDiagnostics {
                            print("[Layout] post-embed index burst: placed \(placed) vector(s)")
                        }
                        broadcaster?.yield(JobCompletionEvent(
                            type: .index,
                            payload: nil,
                            completedAt: Date()
                        ))
                    }
                } else if jobType == .index {
                    let extra = await drainAdditionalIndexJobs(
                        resourceDecision: decision,
                        alreadyProcessedThisTick: result.itemsProcessed,
                        context: context
                    )
                    if extra > 0 {
                        if shouldLogLayoutBurstDiagnostics {
                            print("[Layout] index burst: placed \(extra + result.itemsProcessed) vector(s) this tick")
                        }
                    }
                } else {
                    // Every other tick (.embed / IMAP / etc.) also drains a
                    // small index burst once visible placement has been released.
                    // Before the witness panel owns the reveal, the placement
                    // gate above stays closed and embedded vectors remain hidden.
                    let placed = await drainAdditionalIndexJobs(
                        resourceDecision: decision,
                        context: context
                    )
                    if placed > 0 {
                        if shouldLogLayoutBurstDiagnostics {
                            print("[Layout] post-tick index burst: placed \(placed) vector(s)")
                        }
                        broadcaster?.yield(JobCompletionEvent(
                            type: .index,
                            payload: nil,
                            completedAt: Date()
                        ))
                    }
                }
            }
            broadcaster?.yield(JobCompletionEvent(
                type: jobType,
                payload: jobPayload,
                completedAt: completedAt,
                messageMutations: result.messageMutations
            ))
            updateMaintenanceFairness(
                jobType: jobType,
                result: result,
                decision: decision,
                claimedViaMaintenanceSlot: claimedViaMaintenanceSlot
            )
            recordPipelineHealthIfNeeded(
                jobType: jobType,
                result: result,
                batchSize: batchSize,
                decision: decision,
                context: context
            )
            schedulerSignposter.endInterval("pipeline.tick", signpostState, "status=ok")
        } catch {
            // Surface job failures with their type so layout-drain failures
            // are visible instead of only appearing as a stale placement gauge.
            // Permanent errors (TLS handshake, auth, protocol violation,
            // invalid payload) bypass the 3x retry budget — `IMAPSession`
            // already halts on these for the live IDLE session, and burning
            // two more retries against the same failing TLS handshake just
            // floods the dev panel.
            let permanent = (jobType == .prepareReplySources
                && ReplySourcePreparationCoordinator.isDeterministicFailure(error)) || JobErrorClassifier.isPermanent(
                error,
                allowMissingOAuthTokenRetry: true
            )
            let retryNote = permanent ? "permanent" : "retry \(jobRetryCount + 1)"
            print("[Scheduler] \(jobType) job failed: \(String(reflecting: type(of: error))) (\(retryNote))")
            if permanent {
                try queue.failPermanently(job: job, error: error.localizedDescription, context: context)
            } else {
                try queue.fail(job: job, error: error.localizedDescription, context: context)
            }
            if jobType == .prepareReplySources {
                try ReplySourcePreparationCoordinator().mirrorFailure(
                    from: job,
                    countsTowardCap: ReplySourcePreparationCoordinator.isDeterministicFailure(error),
                    context: context
                )
            }
            let failedResult = PipelineResult(
                success: false,
                itemsProcessed: 0,
                error: error.localizedDescription
            )
            updateMaintenanceFairness(
                jobType: jobType,
                result: failedResult,
                decision: decision,
                claimedViaMaintenanceSlot: claimedViaMaintenanceSlot
            )
            recordPipelineHealthIfNeeded(
                jobType: jobType,
                result: failedResult,
                batchSize: batchSize,
                decision: decision,
                context: context
            )
            schedulerSignposter.endInterval("pipeline.tick", signpostState, "status=fail")
        }

        return true
    }

    @MainActor
    private func drainAdditionalIndexJobs(
        resourceDecision: ResourceDecision,
        alreadyProcessedThisTick: Int = 0,
        context: ModelContext
    ) async -> Int {
        guard allowsVisiblePlacement() else { return 0 }
        if resourceDecision.throttleReasons.contains(.qwenInterpretationBackpressure) {
            guard shouldAllowQwenBackpressureVisibleIndex(
                decision: resourceDecision,
                context: context
            ) else {
                return 0
            }
        }
        let target = adaptiveIndexJobsPerTick(resourceDecision: resourceDecision)
        let maxAdditional = max(0, target - alreadyProcessedThisTick)
        guard maxAdditional > 0 else { return 0 }
        guard ((try? vectorStore.unplacedVectorIds(limit: 1)) ?? []).isEmpty == false else {
            return 0
        }

        do {
            currentJobReporter?(.index)
            defer { currentJobReporter?(nil) }
            return try await runner.runIndexDrain(limit: maxAdditional, context: context)
        } catch {
            print("[Scheduler] index burst aborted: \(String(reflecting: type(of: error)))")
            return 0
        }
    }

    @MainActor
    private func reportManualProjectSourceChanges(
        _ mutations: [PipelineMessageMutation]?
    ) {
        guard let mutations else { return }
        let messageIDs = mutations.reduce(into: Set<UUID>()) { ids, mutation in
            guard mutation.facets.contains(.interpretation) else { return }
            ids.formUnion(mutation.messageIDs)
        }
        guard messageIDs.isEmpty == false else { return }
        onManualProjectSourceChange(messageIDs, [
            .fixedCategory,
            .customCategory,
            .semanticTag,
        ])
    }

    private func adaptiveIndexJobsPerTick(resourceDecision: ResourceDecision) -> Int {
        if resourceDecision.throttleReasons.contains(.constellationActive) {
            return max(1, performanceProfile.inlineLayoutBurstLimit)
        }
        let multiplier = resourceDecision.indexBurstMultiplier
        guard let placement = try? vectorStore.placementCounts() else {
            return max(1, Int((Double(performanceProfile.steadyIndexJobsPerTick) * multiplier).rounded(.down)))
        }
        let base = Self.indexBurstLimit(
            total: placement.total,
            placed: placement.placed,
            profile: performanceProfile
        )
        let scaled = max(1, Int((Double(base) * multiplier).rounded(.down)))
        if multiplier < 1.0 {
            return scaled
        }
        let backlog = max(0, placement.total - placement.placed)
        if backlog >= 1_000 {
            return max(performanceProfile.mediumIndexBurstLimit, scaled)
        }
        if backlog >= 250 {
            return max(performanceProfile.steadyIndexJobsPerTick, scaled)
        }
        return scaled
    }

    static func indexBurstLimit(
        total: Int,
        placed: Int,
        profile: PipelinePerformanceProfile = .balanced
    ) -> Int {
        let steady = profile.steadyIndexJobsPerTick
        let backlog = max(0, total - placed)
        guard total >= 200, backlog > 0 else {
            return steady
        }

        let placedFraction = Double(max(0, placed)) / Double(max(1, total))
        if backlog >= 1_000 || placedFraction < 0.50 {
            return profile.highIndexBurstLimit
        }
        if backlog >= 250 || placedFraction < 0.85 {
            return profile.mediumIndexBurstLimit
        }
        if backlog >= 75 {
            return max(steady, (steady + profile.mediumIndexBurstLimit) / 2)
        }
        return steady
    }

    @MainActor
    private func requeueBatchJobIfNeeded(
        type: JobType,
        result: PipelineResult,
        context: ModelContext
    ) throws {
        guard result.itemsProcessed > 0 else { return }

        let priority: Int?
        switch type {
        case .embed:
            priority = 5
        case .generateDraft:
            priority = 6
        case .index:
            guard allowsVisiblePlacement() else { return }
            let hasUnplaced = ((try? vectorStore.unplacedVectorIds(limit: 1)) ?? []).isEmpty == false
            priority = hasUnplaced ? 6 : nil
        case .buildTrainingPairs:
            priority = PipelineFeatureFlags.qwenPersonalizationTrainingEnabled ? 7 : nil
        case .translationGlossaryRefresh:
            // Requeue only after the active batch row has completed. This
            // avoids colliding with the running job and intentionally permits
            // one final no-op probe when the last full batch drained exactly.
            priority = 7
        default:
            priority = nil
        }
        guard let priority else { return }

        // Requeue directly so the app loop can avoid rescanning the whole
        // SwiftData corpus every two seconds just to rediscover a still-hot
        // batch lane. If this was the final partial batch, the next run will
        // no-op once and then stop requeueing.
        try queue.enqueue(type: type, priority: priority, context: context)
    }

    /// Return a claimed job to `.pending` untouched after the runner declined
    /// it under the current model-compute budget (`PipelineResult.releasedJob`).
    /// Not a failure: no retry bump, no error, no backoff — the claim-side
    /// budget exclusions keep the job unclaimed until its work class is
    /// re-admitted, at which point it resumes exactly where it paused.
    @MainActor
    func releaseDeclinedJob(_ job: Job, context: ModelContext) throws {
        job.status = .pending
        job.startedAt = nil
        try context.save()
    }

    private var embeddingProviderUnavailable: Bool {
        if embedder is UnavailableEmbedder { return true }
        if let swappable = embedder as? SwappableEmbedder {
            return swappable.isUsingUnavailableProvider
        }
        return false
    }

    private var maximumEmbeddingLanes: Int {
        (embedder as? RuntimeLaneLimitedEmbeddingProvider)?.parallelLaneCount ?? 1
    }

    @MainActor
    private func activeJobTypes(context: ModelContext) -> Set<JobType> {
        (try? JobFetch.activeTypes(context: context)) ?? []
    }

    /// True while the Composer is the mounted, frontmost surface in the app
    /// process (per the shared activity snapshot). Grants user-initiated
    /// Composer jobs the foreground lane: claims stay allowed under user-active /
    /// backpressure throttles and the BGE-readiness gate, so question prep
    /// and drafting happen while the user is watching instead of waiting
    /// for the app to go idle. Stale snapshots (app gone, crashed) read
    /// as inactive.
    @MainActor
    private func composerDraftingForegroundActive(now: Date = Date()) -> Bool {
        guard let snapshot = appActivityMonitor?.snapshot(),
              snapshot.isFresh(now: now) else {
            return false
        }
        return snapshot.isComposerActive && snapshot.isAppFrontmost
    }

    /// A queued user request remains interactive demand after Ohia resigns
    /// active. Switching to another app must not hand Qwen back to ingestion
    /// while the Composer is still waiting for its source compilation or draft.
    @MainActor
    private func composerPriorityDemandActive(
        context: ModelContext,
        now: Date = Date()
    ) -> Bool {
        composerDraftingForegroundActive(now: now)
            || Self.hasActiveUserInitiatedComposerDemand(context: context, now: now)
    }

    /// True when a Composer draft can run without waiting for global BGE
    /// readiness. Compose-from-scratch never needs a message context pack; reply
    /// drafts can run once their specific generation pack exists, even if
    /// unrelated embed/index maintenance is still queued.
    @MainActor
    private func hasContextReadyComposerWork(context: ModelContext, now: Date = Date()) -> Bool {
        if DraftGenerationOrchestrator.hasPendingComposeWork(context: context, now: now) {
            return true
        }

        let drafts = (try? context.fetch(FetchDescriptor<Draft>())) ?? []
        if drafts.contains(where: { draft in
            draft.kind != .userCompose
                && draft.status == .pending
                && draft.message != nil
                && draft.isAutomaticSourceResearchPending
                && (draft.nextGenerationAttemptAt ?? .distantPast) <= now
        }) {
            return true
        }

        guard let generationContextPackStore else { return false }
        if drafts.contains(where: { draft in
            guard draft.kind != .userCompose,
                  draft.status == .pending,
                  (draft.nextGenerationAttemptAt ?? .distantPast) <= now,
                  let messageID = draft.message?.id,
                  generationContextPackStore.containsPack(for: messageID) else {
                return false
            }
            return draft.resolvedStage == DraftStage.generating
                || draft.resolvedStage == DraftStage.evaluatingSources
                || draft.isAutomaticSourceResearchPending
                || draft.pendingInstruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }) {
            return true
        }

        guard PipelineFeatureFlags.automaticReplyDraftGenerationEnabled else { return false }
        let automaticTriageQueueingEnabled = ComposerQueueIntakePreference
            .automaticTriageQueueingEnabled()
        return DraftGenerationOrchestrator.queueCandidateMessages(
            context: context,
            automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
        ).contains { message in
            // Only a conversation's queue item is intake work. An email a
            // newer qualifying one superseded keeps the pack built while it
            // was the item, yet intake would seed nothing for it.
            message.analysis != nil
                && message.draft == nil
                && message.isComposerQueueEligible(
                    automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
                )
                && generationContextPackStore.containsPack(for: message.id)
                && !ReplySourcePreparationEligibility.isEligible(
                    message,
                    context: context
                )
                && ReplySourcePreparationEligibility.otherEmailHoldingUnsentReplyDraft(
                    for: message,
                    context: context
                ) == nil
        }
    }

    /// Claim a pending user-initiated Composer generation or source-preparation job
    /// (priority ≤ `ComposerDraftScheduling.userInitiatedPriority`).
    /// Background draft intake (priority 6) and source preparation (priority 4)
    /// are intentionally not claimable through this path.
    @MainActor
    private func claimUserInitiatedComposerJob(
        context: ModelContext,
        now: Date = Date()
    ) throws -> Job? {
        guard engine.isModelLoaded else { return nil }
        let pending = try JobFetch.pending(context: context)
        guard let job = pending.first(where: { job in
            guard Self.isComposerJobType(job.type),
                  job.type.isOwned(by: workerRole),
                  job.priority <= ComposerDraftScheduling.userInitiatedPriority else {
                return false
            }
            if let nextAt = job.nextAttemptAt, nextAt > now { return false }
            return true
        }) else {
            return nil
        }
        job.status = .running
        job.startedAt = now
        try context.save()
        return job
    }

    /// Claim a specific, user-visible message interpretation or hover-summary
    /// job. Bulk `.summarize` drains are gated during initial import, but
    /// priority per-message summaries still run when the user asks for them.
    @MainActor
    private func claimUserInitiatedSummaryJob(
        decision: ResourceDecision,
        context: ModelContext,
        now: Date = Date()
    ) throws -> Job? {
        guard JobType.summarize.isOwned(by: workerRole),
              engine.isModelLoaded,
              !decision.shouldPauseAll,
              decision.modelComputeBudget.allows(.qwenInterpretation)
                || decision.modelComputeBudget.allows(.qwenInteractive) else {
            return nil
        }

        let pending = try JobFetch.pending(context: context)
        guard let job = pending.first(where: { job in
            guard job.type == .summarize,
                  job.messageId != nil,
                  job.priority <= LiveInboundPipelinePrioritizer.liveStagePriority else {
                return false
            }
            if let nextAt = job.nextAttemptAt, nextAt > now { return false }
            return true
        }) else {
            return nil
        }

        job.status = .running
        job.startedAt = now
        try context.save()
        return job
    }

    @MainActor
    private func excludedJobTypes(
        decision: ResourceDecision,
        bgeStatus: PipelineReadinessStatus,
        qwenModelLoaded: Bool,
        composerDraftingActive: Bool,
        contextReadyComposerWork: Bool
    ) -> Set<JobType> {
        var excluded = Set<JobType>()
        let accountMemoryRefreshSurfaceActive = accountMemoryRefreshAppActivityBlocks()
        if !decision.isCatchUpModeActive {
            excluded.formUnion(Self.catchUpMaintenanceTypes)
            excluded.insert(.accountMemoryRefresh)
        }
        if !allowsVisiblePlacement() {
            excluded.formUnion(Self.visiblePlacementTypes)
        }
        if decision.throttleReasons.contains(.userActive)
            || decision.throttleReasons.contains(.constellationActive) {
            excluded.formUnion(Self.interactivePlacementMutationTypes)
        }
        if decision.throttleReasons.contains(.constellationActive) {
            excluded.insert(.clusterDetect)
        }
        if decision.throttleReasons.contains(.userActive)
            || decision.throttleReasons.contains(.ohiaForeground)
            || decision.throttleReasons.contains(.constellationActive)
            || accountMemoryRefreshSurfaceActive {
            excluded.insert(.accountMemoryRefresh)
        }
        let budget = decision.modelComputeBudget
        if embeddingProviderUnavailable {
            excluded.formUnion([
                .embed,
                .entityEmbed,
                .entityRefresh,
                .reindexEmbeddings,
                .resolveSemanticTags,
            ])
        }
        // `.embed` in the general claim ladder (embed fast-lane, urgent band,
        // generic `claimNext`) is backlog work: generic bulk drains plus the
        // per-message jobs seeded behind interpretation. Live-arrival embeds
        // are claimed exclusively through `claimLiveInboundFreshnessJob`,
        // which checks `.bgeLiveFreshness` itself and ignores this exclusion
        // set. Requiring the bulk class here keeps a live-borrow budget
        // (`[.bgeLiveFreshness]` only, rule 6a) from letting backlog
        // per-message embeds slip through the foreground throttle.
        if decision.bge.allowsModelHeavyWork == false || !budget.allows(.bgeBulkEmbedding) {
            excluded.insert(.embed)
        }
        if decision.bge.allowsModelHeavyWork == false || !budget.allows(.bgeMaintenance) {
            excluded.formUnion([
                .entityEmbed,
                .entityRefresh,
                .reindexEmbeddings,
                .resolveSemanticTags,
            ])
        }
        if decision.throttleReasons.contains(.qwenInterpretationBackpressure) {
            excluded.formUnion(Self.qwenInterpretationBackpressureTypes)
            excluded.insert(.accountMemoryRefresh)
            // A frontmost Composer keeps its drafting lane even while the
            // interpretation backlog applies backpressure — the user is
            // actively waiting on questions or a draft.
            if !composerDraftingActive && !contextReadyComposerWork {
                excluded.insert(.generateDraft)
            }
            excluded.insert(.buildTrainingPairs)
            excluded.insert(.train)
        }
        if !PipelineFeatureFlags.qwenPersonalizationTrainingEnabled
            || !budget.allows(.qwenTraining) {
            excluded.insert(.buildTrainingPairs)
            excluded.insert(.train)
        }
        if !budget.allows(.qwenInterpretation) {
            excluded.insert(.summarize)
            excluded.insert(.summarizeAttachments)
            excluded.insert(.accountMemoryRefresh)
        }
        // Drafting normally waits for retrieval readiness so generations are
        // fully grounded, but a frontmost Composer is user-facing inference —
        // it proceeds on whatever portion of the corpus is embedded so far
        // (mirrors the Ask / summarization gating invariant).
        if !budget.qwenAllowsGeneration
            || (!bgeStatus.isComplete && !composerDraftingActive && !contextReadyComposerWork) {
            excluded.insert(.generateDraft)
        }
        if decision.throttleReasons.contains(.interactiveQwenGeneration) {
            excluded.insert(.summarize)
            excluded.insert(.summarizeAttachments)
            excluded.insert(.accountMemoryRefresh)
            excluded.insert(.extractAttachments)
            excluded.insert(.extractVisualAttachments)
        }
        if !qwenModelLoaded {
            excluded.insert(.summarize)
            excluded.insert(.summarizeAttachments)
            excluded.insert(.accountMemoryRefresh)
            excluded.insert(.generateDraft)
            // A train job may have been queued while Qwen was resident, then
            // outlive a model-memory handoff to the retrieval helper. Keep it
            // pending until the generative helper reacquires its model slot and
            // reloads weights through ModelLoadingService.
            excluded.insert(.train)
        }
        if !budget.qwenAllowsGeneration
            || decision.throttleReasons.contains(.interactiveQwenGeneration)
            || !qwenModelLoaded {
            excluded.insert(.prepareReplySources)
        }
        return excluded
    }

    @MainActor
    private func hasInitialImportWorkPending(
        context: ModelContext,
        now: Date = Date()
    ) throws -> Bool {
        PipelineReadiness.initialImportWorkIsPending(context: context, now: now)
    }

    @MainActor
    private func completeSatisfiedIMAPBackfillJobs(
        activeJobs: [Job],
        folderStates: [IMAPFolderState],
        context: ModelContext
    ) throws -> Bool {
        let satisfiedPendingJobs = activeJobs.filter { job in
            job.type == .imapBackfill
                && job.status == .pending
                && Self.imapBackfillJobIsAlreadySatisfied(job, folderStates: folderStates)
        }
        guard !satisfiedPendingJobs.isEmpty else { return false }
        try queue.complete(jobs: satisfiedPendingJobs, context: context)
        return true
    }

    private static func imapBackfillJobIsAlreadySatisfied(
        _ job: Job,
        folderStates: [IMAPFolderState]
    ) -> Bool {
        guard job.type == .imapBackfill,
              let payloadStr = job.payload,
              let data = payloadStr.data(using: .utf8),
              let payload = try? JSONDecoder().decode(IMAPBackfillWorker.Payload.self, from: data),
              let folder = folderStates.first(where: { folder in
                  folder.account?.id == payload.accountID
                      && folder.folderName == payload.folderName
              })
        else { return false }

        guard folder.backfillComplete else { return false }
        let lowerBound = folder.account?.ingestionLowerBoundAt
        guard folder.backfillLowerBoundAt == lowerBound else { return false }
        if lowerBound == nil, folder.lowestFetchedUID > 1 {
            return false
        }
        return true
    }

    @MainActor
    func shouldYieldAccountMemoryRefresh(context: ModelContext) -> Bool {
        if isPaused { return true }
        if accountMemoryRefreshAppActivityBlocks() { return true }
        if (try? hasBodySummaryBacklogPending(context: context)) == true { return true }
        let tail = try? currentIngestionTail(context: context)
        if let tail, tail.blockedJobTypes.contains(.accountMemoryRefresh) {
            return true
        }
        let decision = currentResourceDecision(context: context)
        guard decision.isCatchUpModeActive,
              decision.modelComputeBudget.allows(.qwenInterpretation),
              decision.throttleReasons.contains(.interactiveQwenGeneration) == false,
              engine.isModelLoaded else {
            return true
        }
        // Within training's hold Dreaming yields to any runnable training job.
        // Once released it keeps its turn between slices; only Train Now,
        // inside its exclusive window, still takes the model back.
        if tail?.releasesDreaming != true
            || (try? trainNowIsExclusive(
                runState: TrainingRunState.current(context: context),
                context: context
            )) != false,
           (try? hasRunnablePendingTrainingWork(
               decision: decision,
               context: context
           )) == true {
            return true
        }
        return (try? hasAccountMemoryRefreshBlockingWork(context: context, tail: tail)) ?? true
    }

    /// Train Now owns training for `trainNowExclusiveWindow` from its latest
    /// request, whatever run it accelerates, or from planning a manual full
    /// run. Seeding keeps the request time when it consumes the flag, so a
    /// repeated Train Now during an older manual run starts a fresh hour.
    @MainActor
    private func trainNowIsExclusive(
        runState: TrainingRunState,
        context: ModelContext,
        now: Date = Date()
    ) throws -> Bool {
        let manualFull = TrainingCorpusRunKind.manualFull.rawValue
        let lineageID = "global-personalization"
        let settledStates: Set<String> = [
            TrainingCorpusRunState.completed.rawValue,
            TrainingCorpusRunState.failed.rawValue,
        ]
        let manualRunPlannedAt = try context.fetch(FetchDescriptor<TrainingCorpusRun>(
            predicate: #Predicate<TrainingCorpusRun> { run in
                run.kindRaw == manualFull && run.lineageID == lineageID
            }
        ))
        .filter { settledStates.contains($0.stateRaw) == false }
        .map(\.createdAt)
        .max()
        return IngestionTailStageAuthority.trainNowIsExclusive(
            requestedAt: runState.forceRunRequestedAt,
            manualRunPlannedAt: manualRunPlannedAt,
            now: now
        )
    }

    /// Gathers the durable queue evidence for the authority's training
    /// deferral. Tagging cannot drain during initial import: the retrieval
    /// worker defers it until the import completes. Every call reaches the
    /// authority so the tagging window ledger stays current.
    @MainActor
    private func trainingTailDeferral(
        tail: IngestionTailStageAuthority.Decision,
        runState: TrainingRunState,
        maxAllowedPriority: Int,
        excludedTypes: Set<JobType>,
        initialImportWorkPending: Bool,
        context: ModelContext,
        now: Date = Date()
    ) throws -> IngestionTailStageAuthority.TrainingDeferral? {
        guard Self.accountMemoryRefreshPreemptibleTrainingTypes.contains(where: {
            $0.isOwned(by: workerRole)
        }) else {
            return nil
        }

        var taggingRunnable = false
        if tail.releasesTagging, !initialImportWorkPending {
            taggingRunnable = try !JobFetch.claimablePendingJobs(
                type: .resolveSemanticTags,
                now: now,
                limit: 1,
                context: context
            ).isEmpty || JobFetch.activeJobExists(
                type: .resolveSemanticTags,
                statuses: [.running],
                context: context
            )
        }
        var dreamingClaimable = false
        if tail.releasesDreaming,
           JobType.accountMemoryRefresh.isOwned(by: workerRole),
           !excludedTypes.contains(.accountMemoryRefresh) {
            dreamingClaimable = try !JobFetch.claimablePendingJobs(
                maxPriority: maxAllowedPriority,
                now: now,
                excludedTypes: excludedTypes,
                ownedTypes: [.accountMemoryRefresh],
                limit: 1,
                context: context
            ).isEmpty
        }
        let deferrableWork = taggingRunnable || dreamingClaimable
        let trainNowExclusive = try deferrableWork
            && trainNowIsExclusive(runState: runState, context: context, now: now)
        let needsTurnEvidence = deferrableWork && !trainNowExclusive
        // A turn ends at any terminal completion, failures included; tagging
        // progresses only when a resolution succeeds.
        let turnStatuses: [JobStatus] = [.completed, .failed]
        // Whether the generative worker stayed idle matters only for closing
        // an open drain window.
        let needsBusyEvidence = needsTurnEvidence
            && taggingRunnable
            && taggingWindowLedger.openedAt != nil

        return IngestionTailStageAuthority.trainingDeferral(
            decision: tail,
            evidence: .init(
                trainNowExclusive: trainNowExclusive,
                taggingRunnable: taggingRunnable,
                dreamingClaimable: dreamingClaimable,
                lastTrainingTurnEndedAt: needsTurnEvidence
                    ? try JobFetch.latestCompletedAt(
                        types: Self.accountMemoryRefreshPreemptibleTrainingTypes,
                        statuses: turnStatuses,
                        notAfter: now,
                        context: context
                    )
                    : nil,
                lastTaggingCompletedAt: needsTurnEvidence && taggingRunnable
                    ? try JobFetch.latestCompletedAt(
                        types: [.resolveSemanticTags],
                        statuses: [.completed],
                        notAfter: now,
                        context: context
                    )
                    : nil,
                lastDreamingTurnEndedAt: needsTurnEvidence
                    ? try JobFetch.latestCompletedAt(
                        types: [.accountMemoryRefresh],
                        statuses: turnStatuses,
                        notAfter: now,
                        context: context
                    )
                    : nil,
                lastGenerativeJobEndedAt: needsBusyEvidence
                    ? try JobFetch.latestCompletedAt(
                        types: Self.generativeWorkerJobTypes,
                        statuses: turnStatuses,
                        notAfter: now,
                        context: context
                    )
                    : nil
            ),
            ledger: &taggingWindowLedger,
            now: now
        )
    }

    @MainActor
    private func hasRunnablePendingTrainingWork(
        decision: ResourceDecision,
        context: ModelContext,
        now: Date = Date()
    ) throws -> Bool {
        guard PipelineFeatureFlags.qwenPersonalizationTrainingEnabled,
              TrainingRunState.current(context: context).isPaused == false,
              decision.modelComputeBudget.allows(.qwenTraining),
              decision.throttleReasons.contains(.qwenInterpretationBackpressure) == false else {
            return false
        }

        return try JobFetch.pending(context: context).contains { job in
            guard Self.accountMemoryRefreshPreemptibleTrainingTypes.contains(job.type),
                  job.type.isOwned(by: workerRole) else {
                return false
            }
            return (job.nextAttemptAt ?? .distantPast) <= now
        }
    }

    @MainActor
    func shouldYieldReplySourcePreparation(
        context: ModelContext,
        now: Date = Date()
    ) -> Bool {
        if isPaused { return true }
        // Composer can promote this running job from the app process. Read a
        // fresh durable snapshot so the worker's long-lived context cannot
        // miss that ownership transfer.
        let queueContext = ModelContext(context.container)
        if Self.hasRunningUserInitiatedReplySourcePreparation(
            context: queueContext
        ) {
            return false
        }
        // Only Composer demand the Composer lane will actually claim; yielding
        // to a stale or untargeted request would release this job every tick.
        if Self.hasActiveUserInitiatedComposerDemand(context: queueContext, now: now) {
            return true
        }
        let decision = currentResourceDecision(context: queueContext)
        if decision.shouldPauseAll
            || decision.throttleReasons.contains(.workerMemoryGuard)
            || decision.throttleReasons.contains(.memoryWarning)
            || decision.throttleReasons.contains(.memoryCritical)
            || decision.throttleReasons.contains(.interactiveQwenGeneration)
            || !engine.isModelLoaded {
            return true
        }
        let arrivals = (try? LiveInboundPipelinePrioritizer.arrivalReplyPreparationJobs(
            context: queueContext, now: now
        )) ?? []
        if arrivals.contains(where: { $0.job.status == .running }) {
            // The running preparation is a new arrival's. While the user works
            // in Ohia, another arrival's first interpretation goes first: that
            // is what shows the other email at all.
            if !arrivalReplyPreparationMayRun(decision: decision, context: queueContext, now: now) {
                return true
            }
            return Self.isForegroundThrottled(decision)
                && (try? LiveInboundPipelinePrioritizer.hasRunnableLiveInterpretation(
                    context: queueContext, now: now
                )) == true
        }
        guard decision.modelComputeBudget.qwenAllowsGeneration else { return true }
        // A new arrival's preparation goes first; this one resumes after it.
        return arrivals.contains { LiveInboundPipelinePrioritizer.isClaimable($0, now: now) }
            && arrivalReplyPreparationMayRun(decision: decision, context: queueContext, now: now)
    }

    @MainActor
    private func hasAccountMemoryRefreshBlockingWork(
        context: ModelContext,
        tail suppliedTail: IngestionTailStageAuthority.Decision? = nil
    ) throws -> Bool {
        let tail = try suppliedTail ?? currentIngestionTail(context: context)
        if tail.blockedJobTypes.contains(.accountMemoryRefresh) {
            return true
        }

        if try hasPendingSemanticTagObservations(context: context) {
            return true
        }

        var active = activeJobTypes(context: context)
        active.remove(.accountMemoryRefresh)

        let nonTrainingBlockers = active
            .intersection(Self.accountMemoryRefreshBlockingTypes)
            .subtracting(Self.accountMemoryRefreshPreemptibleTrainingTypes)
        if nonTrainingBlockers.isEmpty == false {
            return true
        }

        let runningTraining = Set(try JobFetch.running(context: context).map(\.type))
            .intersection(Self.accountMemoryRefreshPreemptibleTrainingTypes)
        return runningTraining.isEmpty == false
    }

    /// An existence probe: an initial-import backlog can hold hundreds of
    /// thousands of pending observations, and the tail asks this every tick.
    @MainActor
    private func hasPendingSemanticTagObservations(context: ModelContext) throws -> Bool {
        let pending = SemanticTagObservationState.pending.rawValue
        var descriptor = FetchDescriptor<SemanticTagObservation>(
            predicate: #Predicate<SemanticTagObservation> { observation in
                observation.stateRaw == pending
                    && observation.message != nil
                    && observation.message?.trashedAt == nil
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).isEmpty == false
    }

    @MainActor
    private func actionablePendingSemanticTagObservations(
        context: ModelContext
    ) throws -> [SemanticTagObservation] {
        let pending = SemanticTagObservationState.pending.rawValue
        let descriptor = FetchDescriptor<SemanticTagObservation>(
            predicate: #Predicate<SemanticTagObservation> { observation in
                observation.stateRaw == pending
            }
        )
        return try context.fetch(descriptor).filter { observation in
            guard let message = observation.message else { return false }
            return message.isTrashed == false
        }
    }

    @MainActor
    private func reconcileSemanticTagResolutionJobs(context: ModelContext) throws {
        let actionableObservations = try actionablePendingSemanticTagObservations(context: context)
        let actionableObservationIDs = Set(actionableObservations.map(\.id))
        let activeJobs = try JobFetch.jobs(
            type: .resolveSemanticTags,
            statuses: [.pending, .running],
            context: context,
            sort: false
        )
        var activeObservationIDs = Set<UUID>()
        var changed = false

        for job in activeJobs {
            guard let payload = job.payload,
                  let observationID = UUID(uuidString: payload) else {
                continue
            }
            if actionableObservationIDs.contains(observationID) {
                activeObservationIDs.insert(observationID)
                continue
            }
            guard job.status == .pending else { continue }

            var descriptor = FetchDescriptor<SemanticTagObservation>(
                predicate: #Predicate<SemanticTagObservation> { observation in
                    observation.id == observationID
                }
            )
            descriptor.fetchLimit = 1
            if try context.fetch(descriptor).first != nil {
                context.delete(job)
                changed = true
            }
        }

        for observation in actionableObservations
            where activeObservationIDs.contains(observation.id) == false {
            let job = Job(
                type: .resolveSemanticTags,
                priority: SemanticTagIntake.maintenancePriority
            )
            job.messageId = observation.messageID
            job.payload = observation.id.uuidString
            context.insert(job)
            changed = true
        }

        if changed {
            try context.save()
        }
    }

    /// Whether a body summary is waiting that the summarize lane may write
    /// now. Messages whose summary was withheld outside the reading language
    /// and are waiting out their retry time, or have spent every background
    /// retry, do not count; if that probe cannot read the store, the backlog
    /// counts as pending, as it did before deferrals existed.
    @MainActor
    private func hasBodySummaryBacklogPending(
        context: ModelContext,
        snapshot: MessageStoreActionabilitySnapshot? = nil
    ) throws -> Bool {
        let pending: Bool
        if let snapshot {
            pending = snapshot.hasBodySummaryPending
        } else if let messageStoreURL,
                  let snapshot = try? MessageStoreHotPath.actionabilitySnapshot(storeURL: messageStoreURL) {
            pending = snapshot.hasBodySummaryPending
        } else {
            pending = try context.fetch(FetchDescriptor<Message>()).contains { message in
                guard Self.hasCompleteInterpretation(message) else { return false }
                return message.analysis?.bodySummary?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty != false
            }
        }
        guard pending else { return false }
        return (try? runner.hasUndeferredBodySummaryWork(context: context)) ?? true
    }

    @MainActor
    private func hasAccountMemoryRefreshWork(
        context: ModelContext,
        accounts: [Account],
        now: Date
    ) throws -> Bool {
        let stateByAccount = try accountMemoryRefreshStates(context: context)
        var counts = AccountMemoryCountsReader(messageStoreURL: messageStoreURL, context: context)

        for account in accounts {
            guard AccountMemoryRefreshEligibility.triggerReason(
                state: stateByAccount[account.id],
                counts: try counts.counts(for: account.id),
                now: now
            ) != nil else {
                continue
            }

            return true
        }

        return false
    }

    @MainActor
    private func accountMemoryRefreshStates(
        context: ModelContext
    ) throws -> [UUID: AccountMemoryRefreshState] {
        var stateByAccount: [UUID: AccountMemoryRefreshState] = [:]
        for state in try context.fetch(FetchDescriptor<AccountMemoryRefreshState>()) {
            stateByAccount[state.accountID] = state
        }
        return stateByAccount
    }

    /// Whether an account still owes Dreaming work: it has eligible messages
    /// and its trigger fires, judged past the resume delay, which paces a
    /// deferred pass rather than settling it. A running pass is owed until it
    /// finishes; it has already stamped the counts its trigger measured.
    @MainActor
    private func dreamingWorkIsOutstanding(
        accountID: UUID,
        state: AccountMemoryRefreshState?,
        counts: inout AccountMemoryCountsReader,
        now: Date
    ) throws -> Bool {
        let accountCounts = try counts.counts(for: accountID)
        guard accountCounts.eligibleMessages > 0 else { return false }
        if state?.lastStatusRaw == AccountMemoryRefreshStatus.running { return true }
        var evaluatedAt = now
        if let state,
           state.lastStatusRaw == AccountMemoryRefreshStatus.deferred,
           let deferredAt = state.lastRunCompletedAt {
            evaluatedAt = max(
                now,
                deferredAt.addingTimeInterval(AccountMemoryRefreshEligibility.deferredResumeDelay)
            )
        }
        return AccountMemoryRefreshEligibility.triggerReason(
            state: state,
            counts: accountCounts,
            now: evaluatedAt
        ) != nil
    }

    @MainActor
    private func accountMemoryRefreshAppActivityBlocks(now: Date = Date()) -> Bool {
        guard let snapshot = appActivityMonitor?.snapshot() else { return false }
        // Match ResourcePolicy's foreground-idle semantics. A fresh, frontmost
        // Ohia window blocks this bulk Qwen pass only while the user has
        // interacted recently; merely leaving the app visible must not stall a
        // corpus-wide refresh forever. The onboarding witness remains exempt.
        guard snapshot.isFresh(now: now),
              snapshot.isAppFrontmost,
              snapshot.isOnboardingWitnessActive == false else {
            return false
        }
        return snapshot.hasRecentOhiaInteraction(
            now: now,
            within: min(max(30, idleThreshold), 300)
        )
    }

    private func trainingWaitReason(
        decision: ResourceDecision,
        allowsUserInitiatedQwen: Bool = false,
        tailDeferral: IngestionTailStageAuthority.TrainingDeferral? = nil
    ) -> String? {
        if !PipelineFeatureFlags.qwenPersonalizationTrainingEnabled {
            return "personalization paused"
        }
        if !decision.qwen.allowsBackgroundTraining && !allowsUserInitiatedQwen {
            if decision.throttleReasons.contains(.notOnACPower) {
                return "AC power"
            }
            if decision.throttleReasons.contains(.lowPowerMode) {
                return "Low Power Mode"
            }
            if decision.throttleReasons.contains(.thermalSerious)
                || decision.throttleReasons.contains(.thermalCritical) {
                return "cooling down"
            }
            if decision.throttleReasons.contains(.memoryWarning)
                || decision.throttleReasons.contains(.memoryCritical) {
                return "memory pressure"
            }
            if decision.throttleReasons.contains(.ohiaForeground)
                || decision.throttleReasons.contains(.userActive) {
                return "Ohia active"
            }
            return "resources"
        }
        return tailDeferral?.waitReason
    }

    @MainActor
    private func currentResourceDecision(context: ModelContext) -> ResourceDecision {
        let state = monitor.currentState()
        let runState = TrainingRunState.current(context: context)
        // The training "idle minutes" setting gates only training
        // eligibility inside `ResourcePolicy.evaluate`. The foreground /
        // user-active determination always uses the scheduler's base
        // `idleThreshold`; substituting the training setting there used to
        // stretch how long a frontmost-but-untouched Ohia kept all bulk
        // ingestion paused.
        let trainingIdleThreshold: TimeInterval?
        if let minutes = runState.idleMinutesThreshold, minutes > 0 {
            trainingIdleThreshold = TimeInterval(minutes * 60)
        } else {
            trainingIdleThreshold = nil
        }
        let liveFreshnessActive = (try? hasLiveFreshnessWork(context: context)) ?? false
        let liveInterpretationActive = (
            try? LiveInboundPipelinePrioritizer.hasPendingForegroundInterpretation(context: context)
        ) ?? false
        let monitorsInterpretationBackpressure = (workerRole == .bge || workerRole == .qwen)
            && allowsVisiblePlacement()
        let interpretationSnapshot = monitorsInterpretationBackpressure
            ? interpretationBackpressureSnapshot(context: context)
            : nil
        let backpressureActive = qwenInterpretationBackpressureIsActive(
            snapshot: interpretationSnapshot
        )
        let initialCoreProgressActive = monitorsInterpretationBackpressure
            ? initialIngestionCoreProgressActive(
                context: context,
                interpretationSnapshot: interpretationSnapshot
            )
            : initialIngestionCoreProgressActive(context: context)
        return ResourcePolicy.evaluate(
            state,
            idleThreshold: idleThreshold,
            trainingIdleThreshold: trainingIdleThreshold,
            isInteractiveViewActive: constellationActiveMonitor?.isActive ?? false,
            catchUpModeEnabled: true,
            appActivity: appActivityMonitor?.snapshot(),
            maxEmbeddingLanes: maximumEmbeddingLanes,
            workerRole: workerRole,
            siblingModelWorkerActive: siblingModelWorkerActive?() ?? false,
            siblingModelResident: siblingModelResident?() ?? false,
            interactiveQwenGenerationActive: interactiveQwenGenerationActive?() ?? false,
            interactiveGenerationLane: interactiveQwenGenerationLane?(),
            qwenInterpretationBackpressureActive: backpressureActive,
            initialIngestionCoreProgressActive: initialCoreProgressActive,
            liveFreshnessActive: liveFreshnessActive,
            liveInterpretationActive: liveInterpretationActive,
            composerDraftingActive: composerPriorityDemandActive(context: context),
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
        )
    }

    @MainActor
    private func qwenInterpretationBackpressureIsActive(
        snapshot: InterpretationBackpressureSnapshot?
    ) -> Bool {
        guard workerRole == .bge || workerRole == .qwen else {
            qwenInterpretationBackpressureActive = false
            return false
        }
        guard allowsVisiblePlacement() else {
            qwenInterpretationBackpressureActive = false
            return false
        }
        guard let snapshot else {
            return qwenInterpretationBackpressureActive
        }
        guard snapshot.pendingInterpretation > 0,
              snapshot.placedEmailNodes >= Self.qwenInterpretationBackpressureMinimumPlacedNodes
        else {
            qwenInterpretationBackpressureActive = false
            return false
        }
        let shouldActivate: Bool
        if qwenInterpretationBackpressureActive {
            shouldActivate = snapshot.lead > Self.qwenInterpretationBackpressureExitLead
        } else {
            shouldActivate = snapshot.lead >= Self.qwenInterpretationBackpressureEnterLead
        }
        qwenInterpretationBackpressureActive = shouldActivate
        return shouldActivate
    }

    @MainActor
    private func interpretationBackpressureSnapshot(
        context: ModelContext,
        now: Date = Date()
    ) -> InterpretationBackpressureSnapshot? {
        interpretationBackpressureSnapshotCache.value(at: now) {
            interpretationSnapshotLoadObserver?()
            let interpretationCounts: MessageStoreInterpretationCounts
            if let messageStoreURL,
               let hotPathCounts = try? MessageStoreHotPath.interpretationCounts(storeURL: messageStoreURL) {
                interpretationCounts = hotPathCounts
            } else if let fallback = try? interpretationCountsFromContext(context: context) {
                interpretationCounts = fallback
            } else {
                return nil
            }
            return InterpretationBackpressureSnapshot(
                embeddedEmailNodes: interpretationCounts.embeddedMessages,
                placedEmailNodes: interpretationCounts.placedMessages,
                pendingEmbeddedInterpretation: interpretationCounts.pendingEmbeddedInterpretation,
                pendingPlacedInterpretation: interpretationCounts.pendingPlacedInterpretation
            )
        }
    }

    @MainActor
    private func initialIngestionCoreProgressActive(context: ModelContext) -> Bool {
        initialIngestionCoreProgressActive(
            context: context,
            interpretationSnapshot: interpretationBackpressureSnapshot(context: context)
        )
    }

    @MainActor
    private func initialIngestionCoreProgressActive(
        context: ModelContext,
        interpretationSnapshot: @autoclosure () -> InterpretationBackpressureSnapshot?
    ) -> Bool {
        if let messageStoreURL,
           let hasCoreBacklog = try? MessageStoreHotPath.initialIngestionCoreBacklogExists(storeURL: messageStoreURL),
           hasCoreBacklog {
            return true
        }

        if messageStoreURL == nil,
           initialIngestionEmbeddingBacklogExists(context: context) {
            return true
        }

        if let snapshot = interpretationSnapshot(),
           snapshot.embeddedEmailNodes > snapshot.placedEmailNodes {
            return true
        }

        if hasUnplacedVisibleEmailNodes() {
            return true
        }

        for type in [JobType.imapBackfill] {
            let activeJobs = (try? JobFetch.jobs(
                type: type,
                statuses: [.pending, .running],
                context: context
            )) ?? []
            if activeJobs.isEmpty == false {
                return true
            }
        }
        return false
    }

    @MainActor
    private func hasUnplacedVisibleEmailNodes() -> Bool {
        guard allowsVisiblePlacement(),
              let counts = try? vectorStore.emailNodeCounts() else {
            return false
        }
        return counts.total > counts.placed
    }

    @MainActor
    private func initialIngestionEmbeddingBacklogExists(context: ModelContext) -> Bool {
        guard let messages = try? context.fetch(FetchDescriptor<Message>()) else {
            return false
        }
        return messages.contains { message in
            guard message.liveDetectedAt == nil else { return false }
            return message.embeddingStatus != .completed
        }
    }

    @MainActor
    private func interpretationCountsFromContext(
        context: ModelContext
    ) throws -> MessageStoreInterpretationCounts {
        let messages = try context.fetch(FetchDescriptor<Message>())
        var completedInterpretation = 0
        var bodySummaries = 0
        var pendingInterpretation = 0
        var embeddedMessages = 0
        var pendingEmbeddedInterpretation = 0
        var placedMessages = 0
        var pendingPlacedInterpretation = 0
        for message in messages {
            let hasCompleteInterpretation = Self.hasCompleteInterpretation(message)
            if message.analysis?.bodySummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                bodySummaries += 1
            }
            if message.embeddingStatus == .completed {
                embeddedMessages += 1
                if !hasCompleteInterpretation {
                    pendingEmbeddedInterpretation += 1
                }
            }
            if message.embeddingStatus == .completed, message.placedAt != nil {
                placedMessages += 1
                if !hasCompleteInterpretation {
                    pendingPlacedInterpretation += 1
                }
            }
            if hasCompleteInterpretation {
                completedInterpretation += 1
            } else {
                pendingInterpretation += 1
            }
        }
        return MessageStoreInterpretationCounts(
            completedInterpretation: completedInterpretation,
            bodySummaries: bodySummaries,
            pendingInterpretation: pendingInterpretation,
            embeddedMessages: embeddedMessages,
            pendingEmbeddedInterpretation: pendingEmbeddedInterpretation,
            placedMessages: placedMessages,
            pendingPlacedInterpretation: pendingPlacedInterpretation
        )
    }

    @MainActor
    private func hasLiveFreshnessWork(context: ModelContext) throws -> Bool {
        if try LiveInboundPipelinePrioritizer.hasPendingLiveEmbed(context: context) {
            return true
        }
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.liveDetectedAt != nil && message.placedAt == nil
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).isEmpty == false
    }

    @MainActor
    private func claimLiveInboundFreshnessJob(
        decision: ResourceDecision,
        context: ModelContext
    ) throws -> Job? {
        guard !decision.shouldPauseAll,
              !decision.throttleReasons.contains(.interactiveQwenGeneration) else {
            return nil
        }
        let allowedTypes: Set<JobType>
        switch workerRole {
        case .bge where !embeddingProviderUnavailable
                && decision.modelComputeBudget.allows(.bgeLiveFreshness):
            allowedTypes = [.embed, .index]
        case .qwen where engine.isModelLoaded:
            if decision.modelComputeBudget.allows(.qwenInterpretation) {
                allowedTypes = [.summarize]
            } else {
                return try claimArrivalReplyPreparation(decision: decision, context: context)
            }
        default:
            return nil
        }

        let now = Date()
        for job in try JobFetch.pending(context: context) {
            guard allowedTypes.contains(job.type),
                  liveInboundPriorityLimit(for: job.type).map({ job.priority <= $0 }) == true,
                  job.nextAttemptAt.map({ $0 <= now }) ?? true else {
                continue
            }
            guard let messageID = job.messageId,
                  try isForegroundFreshnessJob(job, messageID: messageID, context: context) else {
                continue
            }
            job.status = .running
            job.startedAt = now
            try context.save()
            return job
        }
        if workerRole == .qwen {
            return try claimArrivalReplyPreparation(decision: decision, context: context)
        }
        return nil
    }

    /// A newly arrived email's reply preparation. Its lookup reads only mail
    /// that arrived within the arrival window, never the whole queue.
    @MainActor
    private func claimArrivalReplyPreparation(
        decision: ResourceDecision,
        context: ModelContext,
        now: Date = Date()
    ) throws -> Job? {
        guard arrivalReplyPreparationMayRun(decision: decision, context: context, now: now),
              let job = try LiveInboundPipelinePrioritizer.arrivalReplyPreparationJobs(context: context, now: now)
                .first(where: { LiveInboundPipelinePrioritizer.isClaimable($0, now: now) })?.job else {
            return nil
        }
        job.status = .running
        job.startedAt = now
        try context.save()
        return job
    }

    private static func isForegroundThrottled(_ decision: ResourceDecision) -> Bool {
        decision.throttleReasons.contains { [.userActive, .ohiaForeground, .constellationActive].contains($0) }
    }

    /// Whether a newly arrived email's reply preparation may run now. Claim
    /// and yield read the same conditions, so a claimed preparation is never
    /// released again on its first yield check.
    @MainActor
    private func arrivalReplyPreparationMayRun(
        decision: ResourceDecision,
        context: ModelContext,
        now: Date = Date()
    ) -> Bool {
        !isPaused && engine.isModelLoaded && decision.qwen.allowsArrivalReplyPreparation
            && !Self.hasActiveUserInitiatedComposerDemand(context: context, now: now)
    }

    @MainActor
    private func liveInboundPriorityLimit(for type: JobType) -> Int? {
        switch type {
        case .embed, .index:
            return LiveInboundPipelinePrioritizer.liveEmbedPriority
        case .summarize:
            return LiveInboundPipelinePrioritizer.liveStagePriority
        default:
            return nil
        }
    }

    @MainActor
    private func isForegroundFreshnessJob(
        _ job: Job,
        messageID: UUID,
        context: ModelContext
    ) throws -> Bool {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.id == messageID
            }
        )
        descriptor.fetchLimit = 1
        guard let message = try context.fetch(descriptor).first,
              message.liveDetectedAt != nil || message.isSentByUser else {
            return false
        }
        switch job.type {
        case .embed:
            return message.embeddingStatus != .completed
        case .index:
            return message.embeddingStatus == .completed && message.placedAt == nil
        case .summarize:
            return true
        default:
            return false
        }
    }

    @MainActor
    func trainingPreemptionReason(context: ModelContext) -> String? {
        if isPaused {
            return "pipeline paused"
        }
        if Self.hasRunnableUserInitiatedComposerJob(context: context) {
            return "Composer request"
        }
        if Self.hasRunnableReplyPreparation(context: context) {
            return "Needs Reply preparation"
        }
        // Polled between optimizer steps: membership is the only tail stage
        // that preempts a running slice, so skip the rest of the tail.
        if (try? meaningMembershipIsRequired(
            context: context,
            scope: meaningLensScopeState(),
            status: nil
        )) == true {
            return "Meaning clustering"
        }
        let decision = currentResourceDecision(context: context)
        return trainingWaitReason(
            decision: decision,
            allowsUserInitiatedQwen: runningUserInitiatedQwenJob && decision.qwen.allowsUserInitiatedWork
        )
    }

    /// Training polls this between optimizer steps. Check the durable queue
    /// directly rather than `runningUserInitiatedQwenJob`: that flag is set
    /// only after the scheduler claims a job, and a pending Composer job
    /// cannot be claimed while the current training tick still owns Qwen.
    @MainActor
    private static func hasRunnableUserInitiatedComposerJob(
        context: ModelContext,
        now: Date = Date()
    ) -> Bool {
        let pending = ((try? JobFetch.jobs(
            type: .generateDraft,
            statuses: [.pending],
            context: context,
            sort: false
        )) ?? []) + ((try? JobFetch.jobs(
            type: .prepareReplySources,
            statuses: [.pending],
            context: context,
            sort: false
        )) ?? [])
        return pending.contains { job in
            job.priority <= ComposerDraftScheduling.userInitiatedPriority
                && (job.nextAttemptAt ?? .distantPast) <= now
        }
    }

    @MainActor
    private static func hasRunnableReplyPreparation(
        context: ModelContext,
        now: Date = Date()
    ) -> Bool {
        ((try? JobFetch.jobs(
            type: .prepareReplySources,
            statuses: [.pending],
            context: context,
            sort: false
        )) ?? []).contains { job in
            job.priority <= ReplySourcePreparationCoordinator.backgroundPriority
                && (job.nextAttemptAt ?? .distantPast) <= now
        }
    }

    @MainActor
    private static func hasRunningUserInitiatedReplySourcePreparation(
        context: ModelContext
    ) -> Bool {
        ((try? JobFetch.jobs(
            type: .prepareReplySources,
            statuses: [.running],
            context: context,
            sort: false
        )) ?? []).contains {
            $0.priority <= ComposerDraftScheduling.userInitiatedPriority
        }
    }

    /// Priority alone is insufficient to prove durable Composer demand: a
    /// stale or synthetic untargeted job must not bypass initial-import gates.
    /// Reply actions target a message; compose-from-scratch actions have an
    /// owed `.userCompose` draft in the durable store.
    @MainActor
    private static func hasActiveUserInitiatedComposerDemand(
        context: ModelContext,
        now: Date = Date()
    ) -> Bool {
        let active = ((try? JobFetch.jobs(
            type: .generateDraft,
            statuses: [.pending, .running],
            context: context,
            sort: true
        )) ?? []) + ((try? JobFetch.jobs(
            type: .prepareReplySources,
            statuses: [.pending, .running],
            context: context,
            sort: true
        )) ?? [])
        let userInitiated = active.filter {
            $0.priority <= ComposerDraftScheduling.userInitiatedPriority
        }
        guard !userInitiated.isEmpty else { return false }

        // A running priority-3 job was already validated and claimed by the
        // Qwen scheduler. Keep ownership through its terminal transition even
        // if the orchestrator has already advanced the Draft's workflow stage.
        if userInitiated.contains(where: { $0.status == .running }) {
            return true
        }

        let runnablePending = userInitiated.filter { job in
            job.status == .pending
                && (job.nextAttemptAt ?? .distantPast) <= now
        }
        guard !runnablePending.isEmpty else { return false }
        if runnablePending.contains(where: { $0.messageId != nil }) {
            return true
        }
        return DraftGenerationOrchestrator.hasPendingComposeWork(
            context: context,
            now: now
        )
    }

    private static func isComposerJobType(_ type: JobType) -> Bool {
        type == .generateDraft || type == .prepareReplySources
    }

    /// Composer generation and provider-Drafts sync must read the current
    /// durable object graph. Worker scheduler contexts live across jobs and
    /// can retain Message/Draft values from before an app-process discard.
    @MainActor
    static func pipelineExecutionContext(
        for jobType: JobType,
        schedulerContext: ModelContext
    ) -> ModelContext {
        switch jobType {
        case .generateDraft, .syncComposerDrafts:
            return ModelContext(schedulerContext.container)
        default:
            return schedulerContext
        }
    }

    @MainActor
    private func runPipelineJob(
        job: Job,
        context: ModelContext,
        batchSize: Int,
        resourceDecision: ResourceDecision
    ) async throws -> PipelineResult {
        guard let target = composerCancellationTarget(job: job, context: context),
              !target.isEmpty else {
            return try await runner.run(
                job: job,
                context: context,
                batchSize: batchSize,
                resourceDecision: resourceDecision
            )
        }

        let race = ComposerJobCancellationRace()
        let storeMonitor = DurableComposerJobCancellationMonitor(
            container: context.container
        )
        let engine = self.engine
        let operation = Task { @MainActor in
            try await runner.run(
                job: job,
                context: context,
                batchSize: batchSize,
                resourceDecision: resourceDecision
            )
        }
        let monitor = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                do {
                    let evidence = try await storeMonitor.cancellationEvidence(for: target)
                    if race.requestCancellation(evidence) {
                        Self.cancelEngineWork(for: target, engine: engine)
                        operation.cancel()
                        return
                    }
                } catch {
                    // A transient store read failure is not user intent.
                    // Retry the narrow authoritative fetch on the next poll.
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        do {
            let result = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
                monitor.cancel()
                Self.cancelEngineWork(for: target, engine: engine)
            }
            if let evidence = try? await storeMonitor.cancellationEvidence(for: target) {
                _ = race.requestCancellation(evidence)
            }
            monitor.cancel()
            await monitor.value
            let cancellationEvidence = race.finish()
            if !cancellationEvidence.isEmpty {
                context.rollback()
                try await storeMonitor.discardLatePublications(for: cancellationEvidence)
                engine.resetCancellation()
                print("[Scheduler] \(job.type) stopped because its Composer item was deleted")
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            return result
        } catch {
            if let evidence = try? await storeMonitor.cancellationEvidence(for: target) {
                _ = race.requestCancellation(evidence)
            }
            monitor.cancel()
            await monitor.value
            let cancellationEvidence = race.finish()
            if !cancellationEvidence.isEmpty {
                context.rollback()
                do {
                    try await storeMonitor.discardLatePublications(for: cancellationEvidence)
                } catch {
                    engine.resetCancellation()
                    throw error
                }
                engine.resetCancellation()
                print("[Scheduler] \(job.type) stopped because its Composer item was deleted")
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            if error is CancellationError {
                engine.resetCancellation()
            }
            throw error
        }
    }

    /// Cancels only the drafting actions registered for this job's drafts and
    /// messages. The engine-wide cancel remains the fallback for work that
    /// predates action registration (source preparation, interview planning).
    private nonisolated static func cancelEngineWork(for target: ComposerJobCancellationTarget, engine: any TrainingEngine) {
        if !ComposerGenerationActions.shared.cancel(draftIDs: target.draftIDs, messageIDs: target.messageIDs) {
            engine.cancel()
        }
    }

    @MainActor
    private func composerCancellationTarget(
        job: Job,
        context: ModelContext
    ) -> ComposerJobCancellationTarget? {
        switch job.type {
        case .prepareReplySources:
            guard let payload = ReplySourcePreparationJobPayload.decode(job.payload) else {
                return nil
            }
            let messageID = payload.messageID
            let matching = ((try? context.fetch(
                FetchDescriptor<ReplySourcePreparation>(
                    predicate: #Predicate<ReplySourcePreparation> {
                        $0.messageId == messageID
                    }
                )
            )) ?? []).filter { preparation in
                preparation.inputFingerprint == payload.fingerprint
                    && preparation.contractVersion == payload.contractVersion
            }.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return ComposerJobCancellationTarget(
                preparationIDs: Set(matching.prefix(1).map(\.id)),
                draftIDs: [],
                messageIDs: [payload.messageID]
            )

        case .generateDraft:
            let pendingDrafts = ((try? context.fetch(FetchDescriptor<Draft>())) ?? [])
                .filter { draft in
                    draft.status == .pending
                        && (job.messageId == nil || draft.message?.id == job.messageId)
                }
            let automaticTriageQueueingEnabled = ComposerQueueIntakePreference
                .automaticTriageQueueingEnabled()
            let intakeMessageIDs: Set<UUID>
            if job.messageId == nil {
                intakeMessageIDs = Set(
                    DraftGenerationOrchestrator.queueCandidateMessages(
                        context: context,
                        automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
                    ).filter { message in
                        message.isComposerQueueEligible(
                            automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
                        )
                            && message.analysis != nil
                            && message.draft == nil
                            && !ReplySourcePreparationEligibility.isEligible(
                                message,
                                context: context
                            )
                    }.map(\.id)
                )
            } else {
                intakeMessageIDs = []
            }
            return ComposerJobCancellationTarget(
                preparationIDs: [],
                draftIDs: Set(pendingDrafts.map(\.id)),
                messageIDs: Set(job.messageId.map { [$0] } ?? []).union(intakeMessageIDs)
            )

        default:
            return nil
        }
    }

    @MainActor
    public func allowsQwenModelLoading(context: ModelContext) -> Bool {
        let decision = currentResourceDecision(context: context)
        guard !decision.shouldPauseAll else { return false }
        guard !decision.throttleReasons.contains(.workerMemoryGuard) else {
            return false
        }
        if decision.throttleReasons.contains(.memoryWarning),
           !Self.hasActiveUserInitiatedComposerDemand(context: context) {
            return false
        }
        return true
    }

    /// Whether the Qwen helper currently has executable model work. This is
    /// separate from mere queue presence: low-power/thermal policy may defer a
    /// seeded job. The low-memory helper handoff uses this signal so model turns
    /// alternate only for real demand instead of repeatedly loading idle weights.
    @MainActor
    public func hasQwenModelDemand(
        context: ModelContext,
        resourceSnapshot suppliedSnapshot: ModelResourceSnapshot? = nil,
        now: Date = Date()
    ) -> Bool {
        let snapshot = suppliedSnapshot ?? refreshModelResourceSnapshot(context: context)
        var runnableTypes = (try? JobFetch.runnableActiveTypes(
            now: now,
            context: context
        )) ?? []
        let decision = snapshot.decision
        let composerDrafting = composerPriorityDemandActive(context: context, now: now)
        let contextReadyComposerWork = hasContextReadyComposerWork(context: context, now: now)
        var excludedTypes = excludedJobTypes(
            decision: decision,
            bgeStatus: snapshot.bgeStatus,
            qwenModelLoaded: true,
            composerDraftingActive: composerDrafting,
            contextReadyComposerWork: contextReadyComposerWork
        )
        if (try? hasInitialImportWorkPending(context: context)) == true {
            var initialImportDeferredTypes = Self.initialImportDeferredTypes
            if allowsVisiblePlacement() {
                initialImportDeferredTypes.subtract(Self.initialImportFirstLightTypes)
            }
            if composerDrafting {
                initialImportDeferredTypes.remove(.generateDraft)
            }
            excludedTypes.formUnion(initialImportDeferredTypes)
        }
        if (try? hasBodySummaryBacklogPending(context: context)) == true {
            excludedTypes.insert(.accountMemoryRefresh)
        }
        if (try? hasAccountMemoryRefreshBlockingWork(context: context)) != false {
            excludedTypes.insert(.accountMemoryRefresh)
        }
        if !PipelineFeatureFlags.automaticReplyDraftGenerationEnabled
            || !contextReadyComposerWork {
            excludedTypes.insert(.generateDraft)
        }
        runnableTypes.subtract(excludedTypes)
        let budget = decision.modelComputeBudget

        if Self.hasActiveUserInitiatedComposerDemand(context: context, now: now),
           budget.qwenAllowsGeneration {
            return true
        }
        if runnableTypes.isDisjoint(with: Self.qwenInterpretationModelDemandTypes) == false,
           budget.allows(.qwenInterpretation) {
            return true
        }
        if runnableTypes.contains(.generateDraft), budget.qwenAllowsGeneration {
            return true
        }
        if runnableTypes.contains(.train), budget.allows(.qwenTraining) {
            return true
        }
        return false
    }

    /// Whether the retrieval helper has model work it can advance now. This
    /// deliberately differs from pipeline readiness: deferred jobs, analysis,
    /// and placement can keep readiness blocked without needing resident BGE
    /// weights. An unseeded embedding/reindex backlog is still real demand,
    /// because loading the provider is what lets the next seeding pass create
    /// its executable job.
    @MainActor
    public func hasBGEModelDemand(
        context: ModelContext,
        now: Date = Date()
    ) -> Bool {
        let runnableTypes = (try? JobFetch.runnableActiveTypes(
            now: now,
            context: context
        )) ?? []
        if runnableTypes.isDisjoint(with: Self.bgeModelDemandTypes) == false {
            return true
        }

        let activeTypes = (try? JobFetch.activeTypes(context: context)) ?? []
        if !activeTypes.contains(.embed), hasUnseededEmbeddingModelWork(context: context) {
            return true
        }
        if !activeTypes.contains(.reindexEmbeddings), hasUnseededReindexModelWork() {
            return true
        }
        return false
    }

    @MainActor
    private func hasUnseededEmbeddingModelWork(context: ModelContext) -> Bool {
        if let messageStoreURL,
           let snapshot = try? MessageStoreHotPath.actionabilitySnapshot(storeURL: messageStoreURL) {
            return snapshot.hasEmbeddingPending
        }
        let messages = (try? context.fetch(FetchDescriptor<Message>())) ?? []
        return messages.contains { $0.embeddingStatus != .completed }
    }

    private func hasUnseededReindexModelWork() -> Bool {
        let version = embedderRegistry.current.embeddingVersion
        return (try? vectorStore.distinctMessageIds(
            whereVersionNot: version,
            limit: 1
        ).isEmpty == false) ?? false
    }

    /// Background Qwen work here means personalization work such as training
    /// and training-pair preparation. Foreground inference for Ask and
    /// summarization must not wait on retrieval readiness.
    @MainActor
    public func allowsQwenBackgroundModelWork(context: ModelContext) -> Bool {
        let snapshot = refreshModelResourceSnapshot(context: context)
        return PipelineFeatureFlags.qwenPersonalizationTrainingEnabled
            && snapshot.decision.qwen.allowsBackgroundTraining
    }

    @MainActor
    public var cachedModelResourceSnapshot: ModelResourceSnapshot? {
        lastModelResourceSnapshot
    }

    @MainActor
    public func refreshModelResourceSnapshot(
        context: ModelContext,
        at date: Date = Date()
    ) -> ModelResourceSnapshot {
        recordModelResourceSnapshot(
            decision: currentResourceDecision(context: context),
            activeJobTypes: activeJobTypes(context: context),
            context: context,
            at: date
        )
    }

    @MainActor
    private func recordModelResourceSnapshot(
        decision: ResourceDecision,
        activeJobTypes: Set<JobType>,
        context: ModelContext,
        at date: Date
    ) -> ModelResourceSnapshot {
        let snapshot = ModelResourceSnapshot(
            decision: decision,
            maximumEmbeddingLanes: maximumEmbeddingLanes,
            bgeStatus: PipelineReadiness.bgeModelWorkStatus(
                context: context,
                vectorStore: vectorStore,
                messageStoreURL: messageStoreURL,
                currentEmbeddingVersion: embeddingProviderUnavailable
                    ? nil
                    : embedderRegistry.current.embeddingVersion,
                activeJobTypes: activeJobTypes
            ),
            evaluatedAt: date
        )
        lastModelResourceSnapshot = snapshot
        return snapshot
    }

    // MARK: - Scheduler Health

    private func maintenanceFairnessAllowed(decision: ResourceDecision) -> Bool {
        decision.isCatchUpModeActive
            && decision.maxAllowedPriority >= 9
            && decision.batchSizeMultiplier >= 1.0
            && decision.indexBurstMultiplier >= 1.0
            && !decision.shouldPauseAll
    }

    private func shouldClaimMaintenanceFairness(decision: ResourceDecision) -> Bool {
        maintenanceFairnessCredit >= Self.maintenanceFairnessInterval
            && maintenanceFairnessAllowed(decision: decision)
    }

    private func shouldClaimQwenBackpressureMaintenance(decision: ResourceDecision) -> Bool {
        guard workerRole == .bge,
              decision.throttleReasons.contains(.qwenInterpretationBackpressure),
              !decision.throttleReasons.contains(.interactiveQwenGeneration),
              userInteractiveQwenGenerationActive() == false,
              !decision.shouldPauseAll else {
            return false
        }

        return !hasProtectedQwenBackpressureReason(decision)
    }

    @MainActor
    private func claimQwenBackpressureInitialCoreProgressJob(
        decision: ResourceDecision,
        excluding excludedTypes: Set<JobType>,
        context: ModelContext
    ) throws -> Job? {
        guard workerRole == .bge,
              decision.throttleReasons.contains(.qwenInterpretationBackpressure),
              decision.modelComputeBudget.allows(.bgeBulkEmbedding),
              initialIngestionCoreProgressActive(context: context),
              !decision.throttleReasons.contains(.interactiveQwenGeneration),
              userInteractiveQwenGenerationActive() == false,
              !decision.shouldPauseAll,
              !hasProtectedQwenBackpressureReason(decision) else {
            return nil
        }

        let candidateTypes = [JobType.embed, .index]
        for type in candidateTypes {
            if excludedTypes.contains(type), type != .index {
                continue
            }
            if type == .index,
               !shouldAllowQwenBackpressureVisibleIndex(decision: decision, context: context) {
                continue
            }
            if let job = try claimSpecificType(type, context: context) {
                return job
            }
        }
        return nil
    }

    @MainActor
    private func shouldClaimQwenBackpressureVisibleIndex(
        decision: ResourceDecision,
        context: ModelContext
    ) -> Bool {
        guard JobType.index.isOwned(by: workerRole),
              shouldAllowQwenBackpressureVisibleIndex(decision: decision, context: context) else {
            return false
        }
        return hasUnplacedVisibleEmailNodes()
    }

    @MainActor
    private func shouldAllowQwenBackpressureVisibleIndex(
        decision: ResourceDecision,
        context: ModelContext
    ) -> Bool {
        guard allowsVisiblePlacement(),
              decision.throttleReasons.contains(.qwenInterpretationBackpressure),
              !decision.throttleReasons.contains(.interactiveQwenGeneration),
              userInteractiveQwenGenerationActive() == false,
              !decision.shouldPauseAll,
              !hasProtectedQwenBackpressureReason(decision) else {
            return false
        }
        guard let snapshot = interpretationBackpressureSnapshot(context: context) else {
            return false
        }
        if hasUnplacedVisibleEmailNodes() {
            return true
        }
        if initialIngestionCoreProgressActive(
            context: context,
            interpretationSnapshot: snapshot
        ),
           snapshot.embeddedEmailNodes > snapshot.placedEmailNodes {
            return true
        }
        let visibleLeadLimit = max(
            Self.qwenInterpretationBackpressureExitLead,
            Self.qwenInterpretationBackpressureEnterLead - performanceProfile.inlineLayoutBurstLimit
        )
        return snapshot.pendingPlacedInterpretation <= visibleLeadLimit
    }

    private func hasProtectedQwenBackpressureReason(_ decision: ResourceDecision) -> Bool {
        let protectedReasons: [ResourceThrottleReason] = [
            .notOnACPower,
            .lowPowerMode,
            .memoryWarning,
            .memoryCritical,
            .thermalSerious,
            .thermalCritical,
            .workerMemoryGuard
        ]
        return protectedReasons.contains { decision.throttleReasons.contains($0) }
    }

    private func userInteractiveQwenGenerationActive() -> Bool {
        if let lane = interactiveQwenGenerationLane?() {
            return lane == .userInteractive
        }
        return interactiveQwenGenerationActive?() == true
    }

    @MainActor
    private func shouldClaimForegroundClusterDetect(decision: ResourceDecision) -> Bool {
        if let workerRole, workerRole != .bge { return false }
        guard allowsVisiblePlacement(), !decision.shouldPauseAll else { return false }
        guard !decision.throttleReasons.contains(.qwenInterpretationBackpressure) else {
            return false
        }
        guard !decision.throttleReasons.contains(.interactiveQwenGeneration) else {
            return false
        }
        let protectedReasons: [ResourceThrottleReason] = [
            .notOnACPower,
            .lowPowerMode,
            .memoryWarning,
            .memoryCritical,
            .thermalSerious,
            .thermalCritical,
            .workerMemoryGuard
        ]
        return !protectedReasons.contains { decision.throttleReasons.contains($0) }
    }

    /// The app process publishes independent Meaning enabled/active bits from
    /// the Top Bar preferences. A stale production heartbeat has no authority:
    /// it cannot seed, claim, or hold a tail barrier. Headless schedulers retain
    /// explicit queue-driven behavior for tests and command-line tools.
    private func meaningLensScopeState(now: Date = Date()) -> MeaningLensScopeState {
        guard let appActivityMonitor else {
            return MeaningLensScopeState(
                isEnabled: true,
                isActive: true,
                hasLiveAuthority: false
            )
        }
        let snapshot = appActivityMonitor.snapshot()
        guard snapshot.isFresh(now: now) else {
            return MeaningLensScopeState(
                isEnabled: false,
                isActive: false,
                hasLiveAuthority: false
            )
        }
        return MeaningLensScopeState(
            isEnabled: snapshot.isMeaningLensEnabled,
            isActive: snapshot.isMeaningLensActive,
            hasLiveAuthority: true
        )
    }

    @MainActor
    private func meaningMembershipIdleGateSatisfied(context: ModelContext) -> Bool {
        let runState = TrainingRunState.current(context: context)
        let threshold: TimeInterval
        if let minutes = runState.idleMinutesThreshold, minutes > 0 {
            threshold = TimeInterval(minutes * 60)
        } else {
            threshold = idleThreshold
        }
        return monitor.currentState().idleSeconds >= threshold
    }

    @MainActor
    private func meaningMembershipMayRun(
        scope: MeaningLensScopeState,
        status: MeaningClusterPipelineStatus,
        context: ModelContext,
        now: Date = Date()
    ) throws -> Bool {
        if scope.isActive { return true }
        guard meaningMembershipIdleGateSatisfied(context: context) else { return false }
        guard status.isReadyForDisplay else { return true }

        let decoder = JSONDecoder()
        let lastCompletedAt = try JobFetch.jobs(
            type: .clusterDetect,
            statuses: [.completed],
            context: context,
            sort: false
        ).compactMap { job -> Date? in
            guard let data = job.payload?.data(using: .utf8),
                  let payload = try? decoder.decode(ClusterDetectPayload.self, from: data),
                  payload.frame.spatialLens == FrameKey.meaning.spatialLens else {
                return nil
            }
            return job.completedAt
        }.max()

        guard let lastCompletedAt else { return true }
        return now.timeIntervalSince(lastCompletedAt)
            >= Self.meaningMembershipBackgroundCooldown
    }

    @MainActor
    private func currentIngestionTail(
        context: ModelContext,
        meaningScope suppliedMeaningScope: MeaningLensScopeState? = nil,
        meaningClusterStatus suppliedMeaningClusterStatus: MeaningClusterPipelineStatus? = nil,
        activeTypes suppliedActiveTypes: Set<JobType>? = nil,
        now: Date = Date()
    ) throws -> IngestionTailStageAuthority.Decision {
        let activeTypes = suppliedActiveTypes ?? activeJobTypes(context: context)
        let meaningScope = suppliedMeaningScope ?? meaningLensScopeState()
        let membershipRequired = try meaningMembershipIsRequired(
            context: context,
            scope: meaningScope,
            status: suppliedMeaningClusterStatus
        )
        let trainingRequired = try hasDurableTrainingTailWork(
            context: context,
            activeTypes: activeTypes
        )
        let taggingRequired = try activeTypes.contains(.resolveSemanticTags)
            || hasPendingSemanticTagObservations(context: context)

        // Hold evidence matters only while training is the barrier; membership
        // never releases. Dreaming's anchor also releases tagging.
        var taggingHeldSince: Date?
        var dreamingHeldSince: Date?
        if !membershipRequired, trainingRequired {
            if taggingRequired {
                // A resolution job is created when its observation becomes
                // pending, including a re-pended one whose own `createdAt` is
                // older, or later when the scheduler reseeds it.
                taggingHeldSince = try JobFetch.earliestCreatedAt(
                    type: .resolveSemanticTags,
                    statuses: [.pending, .running],
                    context: context
                )
            }
            // Dreaming's anchor releases Dreaming on the worker that owns it
            // and, on either worker, tagging not yet past its own hold.
            let needsDreamingAnchor = taggingRequired
                ? !IngestionTailStageAuthority.holdHasExpired(since: taggingHeldSince, now: now)
                : JobType.accountMemoryRefresh.isOwned(by: workerRole)
            if needsDreamingAnchor {
                dreamingHeldSince = try dreamingTrainingHoldAnchor(context: context, now: now)
            }
        }
        return IngestionTailStageAuthority.decision(
            for: .init(
                membershipRequired: membershipRequired,
                trainingRequired: trainingRequired,
                taggingRequired: taggingRequired,
                dreamingRequired: activeTypes.contains(.accountMemoryRefresh),
                taggingHeldSince: taggingHeldSince,
                dreamingHeldSince: dreamingHeldSince
            ),
            now: now
        )
    }

    /// When the longest-waiting account's Dreaming work began: the moment
    /// training's hold on Dreaming is measured from. Only accounts that still
    /// owe Dreaming work count, so one account finishing its pass never
    /// re-holds another whose pass is still owed. An account waits from its
    /// last finished pass, or, never having finished one, from its initial
    /// import (or creation, with no IMAP import). A deferred invocation pauses
    /// a pass rather than finishing it, so a long backfill stays released.
    @MainActor
    private func dreamingTrainingHoldAnchor(
        context: ModelContext,
        now: Date
    ) throws -> Date? {
        if let cache = dreamingHoldAnchorCache {
            let age = now.timeIntervalSince(cache.loadedAt)
            if age >= 0, age < Self.dreamingHoldAnchorMaximumAge {
                return cache.anchor
            }
        }
        dreamingHoldAnchorLoadObserver?()
        let anchor = try loadDreamingTrainingHoldAnchor(context: context, now: now)
        dreamingHoldAnchorCache = DreamingHoldAnchorCache(anchor: anchor, loadedAt: now)
        return anchor
    }

    @MainActor
    private func loadDreamingTrainingHoldAnchor(
        context: ModelContext,
        now: Date
    ) throws -> Date? {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        guard accounts.isEmpty == false else { return nil }
        let stateByAccount = try accountMemoryRefreshStates(context: context)
        var counts = AccountMemoryCountsReader(messageStoreURL: messageStoreURL, context: context)
        let byWait = accounts.map { account in
            let state = stateByAccount[account.id]
            let waitingSince = state?.lastSuccessfulRunAt
                ?? account.initialIMAPImportCompletedAt
                ?? account.createdAt
            return (account.id, state, waitingSince)
        }.sorted { $0.2 < $1.2 }
        // Oldest wait first: the first account still owing work is the
        // anchor, so the rest never need their counts read.
        for (accountID, state, waitingSince) in byWait {
            if try dreamingWorkIsOutstanding(
                accountID: accountID,
                state: state,
                counts: &counts,
                now: now
            ) {
                return waitingSince
            }
        }
        return nil
    }

    @MainActor
    private func meaningMembershipIsRequired(
        context: ModelContext,
        scope: MeaningLensScopeState,
        status suppliedStatus: MeaningClusterPipelineStatus?
    ) throws -> Bool {
        guard scope.isEnabled else { return false }
        if try hasActiveMeaningMembershipJob(context: context) {
            return true
        }

        // Without a live app heartbeat, queued Meaning work is the only
        // authority. This prevents a headless worker from inventing scope
        // demand while preserving explicitly enqueued jobs.
        guard scope.hasLiveAuthority else { return false }

        let status: MeaningClusterPipelineStatus
        if let suppliedStatus {
            status = suppliedStatus
        } else {
            let initialImportWorkPending = try hasInitialImportWorkPending(context: context)
            status = PipelineReadiness.meaningClusterStatus(
                context: context,
                vectorStore: vectorStore,
                clusterStore: VectorClusterStore(
                    sharedDB: vectorStore.rawHandle,
                    lock: vectorStore.rawLock
                ),
                messageStoreURL: messageStoreURL,
                currentEmbeddingVersion: embedderRegistry.current.embeddingVersion,
                initialImportWorkPending: initialImportWorkPending
            )
        }
        // Enabled Meaning owns the front of the strict tail until the complete
        // current membership corpus exists and its matching snapshot has
        // published. While source data is still embedding or placing there is
        // nothing to claim yet, but later tail stages must remain blocked.
        return !status.sourceDataIsSettled || status.needsDetection
    }

    @MainActor
    private func hasActiveMeaningMembershipJob(context: ModelContext) throws -> Bool {
        let jobs = try JobFetch.jobs(
            type: .clusterDetect,
            statuses: [.pending, .running],
            context: context,
            sort: false
        )
        let decoder = JSONDecoder()
        return jobs.contains { job in
            guard let data = job.payload?.data(using: .utf8),
                  let payload = try? decoder.decode(ClusterDetectPayload.self, from: data) else {
                return false
            }
            return payload.frame.spatialLens == FrameKey.meaning.spatialLens
        }
    }

    /// A promoted checkpoint the loaded engine can use, by the checkpoint
    /// manager's own resume tests. Pair promotion stamps are read only under
    /// such a lineage.
    @MainActor
    private static func hasPromotedLineage(
        compatibility: TrainingCheckpointCompatibility?,
        context: ModelContext
    ) throws -> Bool {
        try CheckpointManager.hasPromotedLineage(compatibility: compatibility, context: context)
    }

    /// The loaded engine's training profile, for exact training counts in the
    /// actionability snapshot. Nil while no model is loaded.
    private func trainingHoldScope(now: Date = .now) -> TrainingHoldScope? {
        (engine as? any CheckpointAwareTrainingEngine)?.checkpointCompatibility.map {
            TrainingHoldScope(
                trainingProfileID: TrainingCorpusPlanner.trainingProfileID(for: $0),
                deferredSince: now.addingTimeInterval(-TrainingOptimizationPolicy.current.deferralRetryInterval))
        }
    }

    @MainActor
    private func hasDurableTrainingTailWork(
        context: ModelContext,
        activeTypes: Set<JobType>
    ) throws -> Bool {
        guard PipelineFeatureFlags.qwenPersonalizationTrainingEnabled else { return false }
        if activeTypes.contains(.buildTrainingPairs) || activeTypes.contains(.train) {
            return true
        }

        let runState = TrainingRunState.current(context: context)
        if runState.forceRunRequested { return true }

        var messageSnapshot: MessageStoreActionabilitySnapshot?
        if let messageStoreURL,
           let snapshot = try? MessageStoreHotPath.actionabilitySnapshot(
               storeURL: messageStoreURL, trainingHolds: trainingHoldScope()) {
            messageSnapshot = snapshot
            if snapshot.hasTrainingPairBuildPending { return true }
        }

        // The hot snapshot is authoritative for pending evidence. Its target
        // count is exact when taken for the loaded profile's failure and
        // deferral stamps; otherwise a positive count is validated through
        // SwiftData so a pair already failed/deferred for the current
        // profile cannot hold tagging and Dreaming forever.
        if messageSnapshot == nil {
            let settled = [SentTrainingEvidenceDisposition.loraEligible, .excluded, .preparationFailed].map(\.rawValue)
            let (eligible, excluded, failed) = (settled[0], settled[1], settled[2])
            var pendingEvidence = FetchDescriptor<SentTrainingEvidence>(
                predicate: #Predicate<SentTrainingEvidence> { evidence in
                    evidence.dispositionRaw != eligible
                        && evidence.dispositionRaw != excluded
                        && evidence.dispositionRaw != failed
                }
            )
            pendingEvidence.fetchLimit = 1
            if try !context.fetch(pendingEvidence).isEmpty { return true }
        }

        let compatibility = (engine as? any CheckpointAwareTrainingEngine)?.checkpointCompatibility
        let hasPromotedLineage = try Self.hasPromotedLineage(compatibility: compatibility, context: context)
        let snapshotTargetCount = messageSnapshot.map {
            hasPromotedLineage ? $0.pendingTrainingTargetCount : $0.eligibleTrainingPairCount
        }
        if messageSnapshot?.trainingHolds != nil, let snapshotTargetCount {
            if snapshotTargetCount > 0 { return true }
        } else if snapshotTargetCount == nil || (snapshotTargetCount ?? 0) > 0 {
            let currentProfileID = compatibility.map { TrainingCorpusPlanner.trainingProfileID(for: $0) }
            let now = Date()
            let trashedMessageIDs = try TrainingPair.trashedMessageIDs(in: context)
            let pairs = try context.fetch(FetchDescriptor<TrainingPair>())
            if pairs.contains(where: { pair in
                guard let evidence = pair.evidence else { return false }
                return evidence.disposition == .loraEligible
                    && evidence.revision == pair.evidenceRevision
                    && (evidence.sentAt ?? evidence.createdAt) <= now
                    && (!hasPromotedLineage || pair.latestPromotedEvidenceRevision != pair.evidenceRevision)
                    && !(pair.latestFailedEvidenceRevision == pair.evidenceRevision
                        && pair.latestFailedTrainingProfileID == currentProfileID)
                    && !TrainingCorpusPlanner.isDeferred(pair, trainingProfileID: currentProfileID ?? "", now: now)
                    && !pair.referencesTrashedMessage(in: trashedMessageIDs)
                    && pair.trainingRoleRaw != TrainingPairRole.validationHoldout.rawValue
                    && pair.isTrainablePromptFormat
                    && !pair.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !pair.completionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                return true
            }
        }

        let activeRunStates: Set<String> = [
            TrainingCorpusRunState.preparing.rawValue,
            TrainingCorpusRunState.training.rawValue,
            TrainingCorpusRunState.validating.rawValue,
            TrainingCorpusRunState.checkpointing.rawValue,
            TrainingCorpusRunState.interrupted.rawValue,
        ]
        return try context.fetch(FetchDescriptor<TrainingCorpusRun>()).contains { run in
            run.lineageID == "global-personalization"
                && activeRunStates.contains(run.stateRaw)
        }
    }

    private func shouldClaimOnboardingWitnessEmbed(
        visiblePlacementAllowed: Bool
    ) -> Bool {
        guard visiblePlacementAllowed,
              appActivityMonitor?.snapshot().isOnboardingWitnessActive == true else {
            return false
        }
        return true
    }

    @MainActor
    private func claimMaintenanceFairnessJob(context: ModelContext) throws -> Job? {
        for type in Self.maintenanceFairnessTypes {
            if !allowsVisiblePlacement(), Self.visiblePlacementTypes.contains(type) {
                continue
            }
            if let job = try claimSpecificType(type, context: context) {
                return job
            }
        }
        return nil
    }

    @MainActor
    private func claimQwenBackpressureMaintenanceJob(context: ModelContext) throws -> Job? {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.qwenBackpressureMaintenanceMinimumAge)
        let pending = try JobFetch.pending(context: context)
        for type in Self.qwenBackpressureMaintenanceTypes {
            guard let job = pending.first(where: { job in
                guard job.type == type, job.createdAt <= cutoff else { return false }
                if let nextAt = job.nextAttemptAt, nextAt > now { return false }
                return true
            }) else { continue }
            job.status = .running
            job.startedAt = now
            try context.save()
            return job
        }
        return nil
    }

    @MainActor
    private func claimNext(
        maxPriority: Int,
        context: ModelContext,
        excluding excludedTypes: Set<JobType>
    ) throws -> Job? {
        let excludedTypes = usesIndependentMailActions
            ? excludedTypes.union(Self.independentMailActionTypes) : excludedTypes
        if let workerRole {
            return try queue.claimNext(
                maxPriority: maxPriority,
                context: context,
                excluding: excludedTypes,
                workerRole: workerRole
            )
        }
        return try queue.claimNext(
            maxPriority: maxPriority,
            context: context,
            excluding: excludedTypes
        )
    }

    @MainActor
    private func normalizeHistoricalInterpretationBacklog(context: ModelContext) throws {
        let activeJobs = try JobFetch.jobs(
            type: .summarize,
            statuses: [.pending, .running],
            context: context
        )
        var hasGenericDrain = false
        var removed = 0

        for job in activeJobs {
            if job.messageId == nil {
                hasGenericDrain = true
                continue
            }
            guard job.priority >= 6,
                  job.status != .running,
                  !isInterpretationParseRetry(job) else { continue }
            context.delete(job)
            removed += 1
        }

        if removed > 0 && !hasGenericDrain {
            context.insert(Job(type: .summarize, priority: 6))
        }
        if removed > 0 {
            try context.save()
            print("[Scheduler] normalized interpretation backlog: removed \(removed) historical per-message job(s)")
        }
    }

    /// Generic `.summarize` rows are drain signals, not durable units of
    /// per-message work. If both the interpretation and rich-summary queues
    /// are already empty, a pending generic row is satisfied and should be
    /// completed instead of waiting indefinitely for a future Qwen-eligible
    /// tick. Per-message jobs are intentionally excluded.
    @MainActor
    @discardableResult
    private func completeSatisfiedGenericSummarizeDrains(
        context: ModelContext
    ) throws -> Int {
        guard JobType.summarize.isOwned(by: workerRole) else { return 0 }
        let pending = try JobFetch.jobs(
            type: .summarize,
            statuses: [.pending],
            context: context
        )
        let genericDrains = pending.filter { $0.messageId == nil }
        guard genericDrains.isEmpty == false else { return 0 }

        let hasBacklog: Bool
        if let messageStoreURL,
           let pipelineCounts = try? MessageStoreHotPath.pipelineCounts(storeURL: messageStoreURL),
           let interpretationCounts = try? MessageStoreHotPath.interpretationCounts(storeURL: messageStoreURL) {
            hasBacklog = interpretationCounts.completedInterpretation < pipelineCounts.totalMessages
                || interpretationCounts.bodySummaries < pipelineCounts.totalMessages
        } else {
            let messages = try context.fetch(FetchDescriptor<Message>())
            hasBacklog = messages.contains { message in
                if Self.hasCompleteInterpretation(message) == false {
                    return true
                }
                return message.analysis?.bodySummary?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty != false
            }
        }
        guard hasBacklog == false else { return 0 }

        try queue.complete(jobs: genericDrains, context: context)
        print("[Scheduler] completed \(genericDrains.count) satisfied generic summarize drain(s)")
        return genericDrains.count
    }

    private func isInterpretationParseRetry(_ job: Job) -> Bool {
        job.retryCount > 0
            || job.nextAttemptAt != nil
            || job.error == "queued interpretation parse failed"
    }

    @MainActor
    private func normalizeAttachmentSummaryBacklogPriority(context: ModelContext) throws {
        let activeJobs = try JobFetch.jobs(
            type: .summarizeAttachments,
            statuses: [.pending, .running],
            context: context
        )
        var adjusted = 0

        for job in activeJobs {
            guard job.status != .running, job.priority < 7 else { continue }
            job.priority = 7
            adjusted += 1
        }

        guard adjusted > 0 else { return }
        try context.save()
        print("[Scheduler] normalized attachment summary backlog: demoted \(adjusted) job(s) to priority 7")
    }

    @MainActor
    private func claimSpecificType(_ type: JobType, context: ModelContext) throws -> Job? {
        if usesIndependentMailActions, Self.independentMailActionTypes.contains(type) { return nil }
        if let workerRole {
            return try queue.claimSpecificType(type, context: context, workerRole: workerRole)
        }
        return try queue.claimSpecificType(type, context: context)
    }

    @MainActor
    private func claimClusterDetect(
        frame: FrameKey,
        context: ModelContext,
        now: Date = Date()
    ) throws -> Job? {
        if let workerRole, !JobType.clusterDetect.isOwned(by: workerRole) {
            return nil
        }
        let decoder = JSONDecoder()
        let pending = try JobFetch.claimablePendingJobs(
            type: .clusterDetect,
            now: now,
            limit: Int.max,
            context: context
        )
        guard let job = pending.first(where: { job in
            guard let payload = job.payload?.data(using: .utf8),
                  let decoded = try? decoder.decode(ClusterDetectPayload.self, from: payload) else {
                return false
            }
            return decoded.frame.spatialLens == frame.spatialLens
        }) else {
            return nil
        }
        job.status = .running
        job.startedAt = now
        try context.save()
        return job
    }

    @MainActor
    private func representedEntityWorkIds(
        context: ModelContext
    ) throws -> (embed: Set<UUID>, refresh: Set<UUID>) {
        let representedStatuses: [JobStatus] = [.pending, .running, .failed]
        let embedJobs = try JobFetch.jobs(
            type: .entityEmbed,
            statuses: representedStatuses,
            context: context
        )
        let refreshJobs = try JobFetch.jobs(
            type: .entityRefresh,
            statuses: representedStatuses,
            context: context
        )
        let decoder = JSONDecoder()

        func entityIds(from jobs: [Job]) -> Set<UUID> {
            Set(jobs.compactMap { job in
                guard let payload = job.payload,
                      let data = payload.data(using: .utf8) else {
                    return nil
                }
                return try? decoder.decode(EntityIdPayload.self, from: data).entityId
            })
        }

        return (
            embed: entityIds(from: embedJobs),
            refresh: entityIds(from: refreshJobs)
        )
    }

    private func updateMaintenanceFairness(
        jobType: JobType,
        result: PipelineResult,
        decision: ResourceDecision,
        claimedViaMaintenanceSlot: Bool
    ) {
        guard maintenanceFairnessAllowed(decision: decision) else {
            maintenanceFairnessCredit = 0
            return
        }

        if claimedViaMaintenanceSlot || Self.maintenanceFairnessTypes.contains(jobType) {
            maintenanceFairnessCredit = 0
            return
        }

        guard result.success,
              result.itemsProcessed > 0,
              Self.coreProgressTypes.contains(jobType) else {
            return
        }
        maintenanceFairnessCredit = min(
            Self.maintenanceFairnessInterval,
            maintenanceFairnessCredit + 1
        )
    }

    @MainActor
    private func recordPipelineHealthIfNeeded(
        jobType: JobType,
        result: PipelineResult,
        batchSize: Int,
        decision: ResourceDecision,
        context: ModelContext
    ) {
        healthSnapshotTickCounter += 1
        let signature = healthSnapshotSignature(decision: decision, batchSize: batchSize)
        let shouldLog = !result.success
            || healthSnapshotTickCounter >= Self.healthSnapshotInterval
            || signature != lastHealthSnapshotSignature
        guard shouldLog else { return }

        healthSnapshotTickCounter = 0
        lastHealthSnapshotSignature = signature

        let queue = queueCounts(context: context)
        let queueDepth = queue.values.reduce(0, +)
        print("""
        [Scheduler] health job=\(jobType.rawValue) success=\(result.success) \
        processed=\(result.itemsProcessed) failureKind=\(result.success ? "none" : "job_failed") \
        batch=\(batchSize) maxPriority=\(decision.maxAllowedPriority) \
        catchUp=\(decision.isCatchUpModeActive) throttleCount=\(decision.throttleReasons.count) \
        maintenanceCredit=\(maintenanceFairnessCredit) queueTypes=\(queue.count) queueDepth=\(queueDepth)
        """)
    }

    private func healthSnapshotSignature(decision: ResourceDecision, batchSize: Int) -> String {
        let throttleReasonList = decision.throttleReasons.map(\.rawValue).joined(separator: ",")
        return [
            "max=\(decision.maxAllowedPriority)",
            "batch=\(batchSize)",
            "batchMultiplier=\(decision.batchSizeMultiplier)",
            "indexMultiplier=\(decision.indexBurstMultiplier)",
            "catchUp=\(decision.isCatchUpModeActive)",
            "budget=\(decision.modelComputeBudget.activeClass?.rawValue ?? "none")",
            "bgeLanes=\(decision.modelComputeBudget.bgeLaneLimit)",
            "reasons=\(throttleReasonList)"
        ].joined(separator: "|")
    }

    @MainActor
    private func queueCounts(context: ModelContext) -> [String: Int] {
        (try? JobFetch.unfinishedCountsByTypeAndStatus(context: context)) ?? [:]
    }

    // MARK: - Pipeline Seeding

    /// Ensure the standard pipeline job types are present in the queue.
    ///
    /// Every pipeline type self-gates on "is there actionable work?" — a seed
    /// only happens when the type has something to do. This prevents priority
    /// inversion starvation: under strict-priority-first claim (`JobQueue.-
    /// claimNext` takes lowest-number-first), any type that re-seeds uncondi-
    /// tionally and completes as a no-op monopolizes the tick loop and
    /// starves higher-number-priority types indefinitely.
    ///
    /// `.train` is special-cased further by `TrainingTrigger.decide` which
    /// adds pause-dominant + force-run + backfill-vs-incremental seed semantics
    /// on top of the actionability check.
    @MainActor
    public func ensurePipelineJobsExist(context: ModelContext) throws {
        // New mail moves Dreaming triggers; the next tail read reloads it.
        dreamingHoldAnchorCache = nil
        // Establish the Composer snapshot before any queue normalization can
        // save through the long-lived scheduler context.
        let composerContext = ModelContext(context.container)
        let now = Date()
        let automaticTriageQueueingEnabled =
            ComposerQueueIntakePreference.automaticTriageQueueingEnabled()
        let draftSyncActionable = ComposerDraftSyncWorker.hasPendingWork(
            context: composerContext
        )
        let composerDraftingActive = composerPriorityDemandActive(
            context: composerContext,
            now: now
        )
        let contextReadyComposerWork = hasContextReadyComposerWork(
            context: composerContext,
            now: now
        )
        let pendingComposerWork = DraftGenerationOrchestrator.hasPendingComposerWork(
            context: composerContext,
            now: now
        )
        let pendingComposeWork = DraftGenerationOrchestrator.hasPendingComposeWork(
            context: composerContext,
            now: now
        )
        let canonicalDraftIntakeCandidate = DraftGenerationOrchestrator.queueCandidateMessages(
            context: composerContext,
            automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
        ).contains { message in
            message.isComposerQueueEligible(
                automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
            )
                && message.analysis != nil
                && message.draft == nil
                && !ReplySourcePreparationEligibility.isEligible(
                    message,
                    context: composerContext
                )
                // Mirrors intake: the conversation's pending Draft on an
                // older email moves here, so nothing is seeded meanwhile.
                && ReplySourcePreparationEligibility.otherEmailHoldingUnsentReplyDraft(
                    for: message,
                    context: composerContext
                ) == nil
        }
        let visiblePlacementAllowed = allowsVisiblePlacement()
        if JobType.syncComposerDrafts.isOwned(by: workerRole) {
            _ = try queue.collapseRedundantComposerDraftSyncJobs(context: context)
        }
        if JobType.prepareReplySources.isOwned(by: workerRole) {
            let coordinator = ReplySourcePreparationCoordinator()
            _ = try coordinator.reconcilePendingFirstPresentation(context: context)
            _ = try coordinator.reconcileChangedPreparationInputs(context: context)
            let pendingPreparationMessageIDs = Set(
                try context.fetch(FetchDescriptor<ReplySourcePreparation>())
                    .compactMap { preparation in
                        switch preparation.statusRaw {
                        case ReplySourcePreparationStatus.pending,
                             ReplySourcePreparationStatus.compilingSources,
                             ReplySourcePreparationStatus.formulatingQuestions,
                             ReplySourcePreparationStatus.drafting,
                             ReplySourcePreparationStatus.retryWaiting:
                            return preparation.messageId
                        default:
                            return nil
                        }
                    }
            )
            if !pendingPreparationMessageIDs.isEmpty {
                _ = try coordinator.reconcile(
                    messageIDs: pendingPreparationMessageIDs,
                    origin: .nonLiveThreadChange,
                    context: context
                )
            }
        }
        if JobType.generateDraft.isOwned(by: workerRole) {
            // Fresh context: the pass saves its own mutations and must read
            // threads as the ingestion lanes last wrote them. The open reply
            // is honored even from a stale snapshot; at worst a reply that was
            // just closed takes the non-destructive path for one more pass.
            // A reply opened in the moment before the app's snapshot write
            // lands is not yet protected: its draft can be rebuilt or moved,
            // and the Composer then reconciles that session against the
            // rebuilt queue. A failure here must not abort the rest of this
            // maintenance pass.
            do {
                try ComposerThreadChangeReconciler.reconcile(
                    context: ModelContext(context.container),
                    openReplyMessageID: appActivityMonitor?.snapshot().composerOpenReplyMessageID
                )
            } catch {
                print("[Ohia] ⚠ Composer thread-change reconcile failed: \(String(reflecting: type(of: error)))")
            }
        }
        if JobType.resolveSemanticTags.isOwned(by: workerRole) {
            try reconcileSemanticTagResolutionJobs(context: context)
        }
        if JobType.clusterDetect.isOwned(by: workerRole) {
            // A failure here must not abort the rest of this maintenance pass.
            do {
                try ClusterDetectSeeder.discardUnrunnable(context: context)
            } catch {
                print("[Ohia] ⚠ Unrunnable cluster job discard failed: \(String(reflecting: type(of: error)))")
            }
        }
        _ = try completeSatisfiedGenericSummarizeDrains(context: context)
        var activeTypes = try JobFetch.activeTypes(context: context)
        let indexDrainJobs = try JobFetch.jobs(
            type: .index,
            statuses: [.pending, .running, .failed],
            context: context
        )
        if try normalizeIndexDrainJobs(
            jobs: indexDrainJobs,
            visiblePlacementAllowed: visiblePlacementAllowed,
            context: context
        ) {
            activeTypes = try JobFetch.activeTypes(context: context)
        }
        if try LiveInboundPipelinePrioritizer.nudgeStalledLiveMessages(context: context) > 0 {
            activeTypes = try JobFetch.activeTypes(context: context)
        }
        let catchUpMaintenanceAllowed = currentResourceDecision(context: context).isCatchUpModeActive

        let accounts = try context.fetch(FetchDescriptor<Account>())
        let allFolderStates = try context.fetch(FetchDescriptor<IMAPFolderState>())

        let initialActiveIMAPBackfillJobs = try JobFetch.jobs(
            type: .imapBackfill,
            statuses: [.pending, .running],
            context: context
        )
        if try completeSatisfiedIMAPBackfillJobs(
            activeJobs: initialActiveIMAPBackfillJobs,
            folderStates: allFolderStates,
            context: context
        ) {
            activeTypes = try JobFetch.activeTypes(context: context)
        }

        imapSessionManager?.syncSessions()

        let messageSnapshot: MessageStoreActionabilitySnapshot?
        if let messageStoreURL {
            // Training counts are exact for the loaded engine's profile, so
            // the `.train` gate never re-reads every pair to discount failed
            // or deferred revisions.
            messageSnapshot = try? MessageStoreHotPath.actionabilitySnapshot(
                storeURL: messageStoreURL, trainingHolds: trainingHoldScope())
        } else {
            messageSnapshot = nil
        }
        var fallbackMessages: [Message]?
        func messagesForFallback() throws -> [Message] {
            if let fallbackMessages { return fallbackMessages }
            let fetched = try context.fetch(FetchDescriptor<Message>())
            fallbackMessages = fetched
            return fetched
        }

        // sendOutbox is event-driven: SendDispatcher.enqueueSend enqueues
        // directly when a draft is confirmed. The periodic re-seed is also a
        // safety net for sends interrupted mid-flight and for durable local
        // feedback work left pending after SMTP acceptance or a format rebuild.
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>())
        let outboxActionable = outbox.contains {
            $0.status == .queued
                || $0.status == .sending
                || ($0.status == .sent && (
                    $0.trainingFeedbackProcessedAt == nil
                        || $0.translationGlossaryFeedbackProcessedAt == nil
                ))
        }

        // syncComposerDrafts is event-driven from Composer autosaves and
        // generation passes. The periodic re-seed catches app exits while a
        // draft was dirty or a transient IMAP write failure after its backoff.
        // Composer state is read through one authoritative context throughout
        // this ensure pass; the scheduler context can retain objects registered
        // before an app-process discard, generation, or provider sync.

        // Authored bilingual evidence is deterministic retrieval work. It is
        // intentionally independent of Qwen demand/backpressure and BGE
        // embedding readiness: a stale stamp is the only admission signal.
        let translationGlossaryRefreshActionable: Bool
        if JobType.translationGlossaryRefresh.isOwned(by: workerRole) {
            translationGlossaryRefreshActionable = try TranslationGlossaryRefreshWorker.hasPendingWork(context: context)
        } else {
            translationGlossaryRefreshActionable = false
        }

        // mailboxMutation is also event-driven (the Constellation context
        // menu enqueues both the row and the job at the same instant). The
        // periodic re-seed catches mutations interrupted mid-attempt
        // (status .running at crash time) and rows whose nextAttemptAfter
        // is ready after a transient backoff. A destructive provider mutation
        // can also be `.succeeded` while its crash-safe local deletion remains
        // pending; that cleanup-only phase must be reachable without resending
        // the provider command.
        let mailboxMutations = try context.fetch(FetchDescriptor<MailboxMutation>())
        let mailboxMutationActionable = mailboxMutations.contains {
            $0.status == .queued
                || $0.status == .running
                || ($0.status == .succeeded
                    && $0.localFinalizedAt == nil
                    && ($0.kind == .delete || $0.kind == .moveToJunk))
        }

        // LLM-backed drafting no-ops when the engine isn't loaded yet. Without
        // this check they'd get re-seeded every tick, claimed (lowest-number-
        // priority wins), no-op'd, and completed — starving priority 7+ work
        // (buildTrainingPairs, categoryLifecycle, train) during the multi-
        // second model-load window on app startup.
        let engineReady = engine.isModelLoaded
        let currentEmbedder = embedderRegistry.current
        let bgeStatusForGenerativeContext = PipelineReadiness.bgeModelWorkStatus(
            context: context,
            vectorStore: vectorStore,
            messageStoreURL: messageStoreURL,
            currentEmbeddingVersion: embeddingProviderUnavailable ? nil : currentEmbedder.embeddingVersion,
            activeJobTypes: activeTypes
        )

        // .embed: any Message still awaiting vector embedding. Eligibility
        // includes `.failed` and `.processing` in addition to `.pending` so
        // transient errors and crash-interrupted attempts self-heal without
        // operator intervention — `EmbeddingOrchestrator.embedPendingMessages`
        // re-attempts every non-`.completed` row on each batch.
        let embeddingAvailable = !embeddingProviderUnavailable
        let hasEmbeddingBacklog: Bool
        if let messageSnapshot {
            hasEmbeddingBacklog = messageSnapshot.hasEmbeddingPending
        } else {
            hasEmbeddingBacklog = try messagesForFallback().contains { $0.embeddingStatus != .completed }
        }
        let embedActionable = embeddingAvailable && hasEmbeddingBacklog

        // .summarize: first drains the lightweight Qwen interpretation lane for
        // any Message with no complete classification document or structured
        // triage verdict. Rich body summaries are seeded separately at the
        // very end of the ingestion/indexing pipeline below.
        let interpretationEngineAvailable = engine.isModelLoaded
        let summarizeActionable: Bool
        if !interpretationEngineAvailable {
            summarizeActionable = false
        } else if let messageSnapshot {
            summarizeActionable = messageSnapshot.hasSummaryPending
        } else {
            summarizeActionable = try messagesForFallback().contains { msg in
                guard msg.analysis != nil else { return true }
                return !Self.hasCompleteInterpretation(msg)
            }
        }

        // .generateDraft: queue-eligible messages with analysis but no
        // persisted draft, plus existing Composer drafts that owe generation.
        // Background intake waits for global BGE readiness; an existing compose
        // draft or reply draft with its message-specific context pack can run
        // without waiting for unrelated BGE maintenance.
        let generateDraftActionable: Bool
        if !PipelineFeatureFlags.automaticReplyDraftGenerationEnabled {
            generateDraftActionable = false
        } else if !engineReady {
            generateDraftActionable = false
        } else if !bgeStatusForGenerativeContext.isComplete
                    && !composerDraftingActive
                    && !contextReadyComposerWork {
            generateDraftActionable = false
        } else if let messageSnapshot {
            generateDraftActionable = contextReadyComposerWork
                || (messageSnapshot.hasDraftPending && canonicalDraftIntakeCandidate)
        } else if contextReadyComposerWork {
            generateDraftActionable = true
        } else {
            generateDraftActionable = canonicalDraftIntakeCandidate
        }

        // .summarizeAttachments: late, small Qwen jobs that fill the
        // locked-node attachment pane from already-extracted document text or
        // visual evidence. This must not wait for BGE retrieval readiness;
        // the Qwen budget and interactive-generation gate are enough.
        let summarizeAttachmentsActionable = interpretationEngineAvailable
            && AttachmentSummaryBackfillWorker.hasPendingWork(
                context: context,
                excluding: runner.blockedAttachmentSummaryIDs(context: context)
            )

        // .buildTrainingPairs: evidence rows preparation has not yet
        // finalized. Admission keys on the evidence ledger the builder drains
        // — standalone evidence must be prepared or excluded even after every
        // pending reply is done. This evidence is intrinsic to training
        // and does not depend on retrieval embedding or placement.
        // First preparation of new evidence is admitted whenever it exists:
        // sends render from a frozen basis and standalone evidence finalizes
        // without the model. Rebuilding pairs left at an older prompt format
        // and retrying failed preparations need the model, so that work is
        // admitted only once the model is loaded.
        let buildPairsActionable: Bool
        if !PipelineFeatureFlags.qwenPersonalizationTrainingEnabled {
            buildPairsActionable = false
        } else if let messageSnapshot {
            buildPairsActionable = messageSnapshot.hasTrainingPairBuildPending
                || (engineReady && messageSnapshot.hasTrainingPairRebuildPending)
        } else {
            let settled = [SentTrainingEvidenceDisposition.loraEligible, .excluded, .preparationFailed].map(\.rawValue)
            let (eligible, excluded, failed) = (settled[0], settled[1], settled[2])
            var pendingEvidence = FetchDescriptor<SentTrainingEvidence>(
                predicate: #Predicate<SentTrainingEvidence> {
                    $0.dispositionRaw != eligible && $0.dispositionRaw != excluded && $0.dispositionRaw != failed
                }
            )
            pendingEvidence.fetchLimit = 1
            if try !context.fetch(pendingEvidence).isEmpty {
                buildPairsActionable = true
            } else if engineReady {
                buildPairsActionable = try TrainingPairBuilder.hasRebuildWork(context: context)
            } else {
                buildPairsActionable = false
            }
        }

        let bodySummaryBacklogPending = interpretationEngineAvailable
            ? try hasBodySummaryBacklogPending(context: context, snapshot: messageSnapshot)
            : false
        let memoryDecision = currentResourceDecision(context: context)
        let accountMemoryRefreshSurfaceActive = accountMemoryRefreshAppActivityBlocks()
        let accountMemoryRefreshBlockingWorkActive = try hasAccountMemoryRefreshBlockingWork(context: context)
        let accountMemoryRefreshFullAllowed = !activeTypes.contains(.accountMemoryRefresh)
            && engineReady
            && !bodySummaryBacklogPending
            && memoryDecision.isCatchUpModeActive
            && memoryDecision.modelComputeBudget.allows(.qwenInterpretation)
            && !memoryDecision.throttleReasons.contains(.userActive)
            && !memoryDecision.throttleReasons.contains(.ohiaForeground)
            && !memoryDecision.throttleReasons.contains(.constellationActive)
            && !accountMemoryRefreshSurfaceActive
            && !memoryDecision.throttleReasons.contains(.interactiveQwenGeneration)
            && !accountMemoryRefreshBlockingWorkActive
        let shouldScheduleAccountMemoryRefresh: Bool
        if accountMemoryRefreshFullAllowed {
            shouldScheduleAccountMemoryRefresh = try hasAccountMemoryRefreshWork(
                context: context,
                accounts: accounts,
                now: now
            )
        } else {
            shouldScheduleAccountMemoryRefresh = false
        }

        // .categoryLifecycle: any candidate category needing promotion review.
        // Deprecation / merge paths also run via this job, but they act on
        // active categories that become stale — a condition that requires
        // time to elapse. Running once per promotion candidate is enough.
        let categories = try context.fetch(FetchDescriptor<CategoryDefinition>())
        let categoryLifecycleActionable = categories.contains { $0.status == .candidate }

        // .refine: background continuous-refine pacing. Actionable only once
        // the cold build has produced at least one placed vector — otherwise
        // `refineStep` would immediately no-op on an empty corpus and the
        // self-reenqueue would spin the scheduler. One placed vector is the
        // cheapest "cold build happened" signal that doesn't require tracking
        // a separate milestone marker. The worker itself also requires ≥ 2
        // placed vectors to do real work, but gating the seed at 1 is enough
        // to avoid pre-cold-build spinning; between 1 and 2 the worker returns
        // without touching SQL, which is cheap.
        let refineActionable = visiblePlacementAllowed
            && catchUpMaintenanceAllowed
            && ((try? vectorStore.vectorsWithLayout(filter: nil, limit: 1))
                .map { !$0.isEmpty } ?? false)

        let initialImportWorkPending = try hasInitialImportWorkPending(context: context, now: now)
        let firstLightCoreWorkAllowed = !initialImportWorkPending || visiblePlacementAllowed
        // Initial acquisition must keep draining continuously. The Qwen worker
        // may datafy already-arrived messages in parallel when ResourcePolicy
        // admits that model work, while retrieval embedding/index work waits
        // behind this BGE-owned network lane.
        let historicalIMAPBackfillPriority = 3
        let activeIMAPBackfillJobs = try JobFetch.jobs(
            type: .imapBackfill,
            statuses: [.pending, .running],
            context: context
        )
        if !activeIMAPBackfillJobs.isEmpty {
            activeTypes.insert(.imapBackfill)
        }
        let reprioritizedBackfillJobs = activeIMAPBackfillJobs.filter {
            $0.status == .pending
                && $0.priority != historicalIMAPBackfillPriority
        }
        if !reprioritizedBackfillJobs.isEmpty {
            for job in reprioritizedBackfillJobs {
                job.priority = historicalIMAPBackfillPriority
            }
            try context.save()
        }
        // Priority ordering note (lower number = claimed first):
        //   1: sendOutbox — user-visible sends.
        //   2: syncComposerDrafts — provider Drafts mirrors Composer state,
        //      but never gets ahead of an explicit Send.
        //   2: imapPollFolder — IMAP live deltas + INBOX gap-check. Users
        //      don't wait for years of historical seed before they can
        //      receive new mail.
        //   3: imapBackfill — historical UID walk for configured accounts.
        //      It stays ahead of retrieval embedding / placement so initial
        //      acquisition does not pause. Qwen interpretation remains
        //      independent on its own worker and retains its normal resource
        //      and foreground throttling.
        //   5: embed / pendingDeletionReaper — share a priority so
        //      Constellation can start populating while ingestion continues.
        //   6: generateDraft, interpretation backfill, index drain, clusterDetect.
        //      Qwen Headline/structured-triage interpretation is canonical and is
        //      not blocked by BGE readiness; per-message interpretation from IMAP
        //      arrivals enqueues at priority 4 separately for live-mail
        //      responsiveness. `.summarize` is now the canonical source of
        //      `messageType` through the Qwen structured triage verdict; legacy
        //      `.triage` jobs from existing databases drain as no-ops.
        //   7: summarizeAttachments / buildTrainingPairs / categoryLifecycle / entity*.
        //   8: train.
        //   9: refine / reconcile / reindex.
        let standardJobs: [(JobType, Int, Bool)] = [
            (.sendOutbox, 1, outboxActionable),
            (.syncComposerDrafts, ComposerDraftSyncScheduler.priority, draftSyncActionable),
            (.mailboxMutation, 1, mailboxMutationActionable),
            (.translationGlossaryRefresh, 7, translationGlossaryRefreshActionable),
            (.embed, 5, embedActionable && firstLightCoreWorkAllowed),
            (.generateDraft, 6, generateDraftActionable && !initialImportWorkPending),
            (.summarize, 6, summarizeActionable),
            (.summarizeAttachments, 7, summarizeAttachmentsActionable),
            (.buildTrainingPairs, 7, buildPairsActionable),
            (.refine, 9, refineActionable && !initialImportWorkPending),
            (.categoryLifecycle, 7, categoryLifecycleActionable && !initialImportWorkPending),
        ]

        for (type, priority, actionable) in standardJobs {
            if !actionable { continue }
            if !activeTypes.contains(type) {
                let enqueueContext = switch type {
                case .generateDraft, .syncComposerDrafts:
                    composerContext
                default:
                    context
                }
                try queue.enqueue(type: type, priority: priority, context: enqueueContext)
                activeTypes.insert(type)
            }
        }

        // .reconcileVectorIndex: periodic drift repair for the USearch ANN
        // sidecar. Launch already runs an immediate reconcile through
        // AppServices, so the scheduler seeds the next periodic pass six
        // hours out and the runner keeps pacing it after each successful run.
        if catchUpMaintenanceAllowed,
           !initialImportWorkPending,
           vectorIndex != nil,
           !activeTypes.contains(.reconcileVectorIndex) {
            try queue.enqueueDeferred(
                type: .reconcileVectorIndex,
                priority: 9,
                nextAttemptAt: Date().addingTimeInterval(Self.vectorIndexReconcileInterval),
                context: context
            )
        }

        // .reindexEmbeddings: finite migration from stale embedding versions
        // into the current writer. AppServices drains aggressively at launch;
        // this near-immediate seed catches interrupted batches and future
        // embedder upgrades without spinning when no stale rows exist.
        let reindexActionable = catchUpMaintenanceAllowed && embeddingAvailable && !initialImportWorkPending && (
            (try? vectorStore.distinctMessageIds(
                whereVersionNot: currentEmbedder.embeddingVersion,
                limit: 1
            ).isEmpty == false) ?? false
        )
        if reindexActionable, !activeTypes.contains(.reindexEmbeddings) {
            try queue.enqueueDeferred(
                type: .reindexEmbeddings,
                priority: 9,
                nextAttemptAt: Date(),
                context: context
            )
        }

        // .clusterDetect: enabled Meaning demands one full pass after the
        // complete current context-vector corpus is placed. Meaning does not
        // self-reenqueue; later scope demand seeds another pass only after the
        // settled corpus fingerprint changes.
        //
        // NOT gated on `catchUpMaintenanceAllowed`: clusters are a
        // foreground deliverable for the Meaning lens, not best-effort
        // maintenance. Gating them behind system-idle mode meant they
        // never seeded for users who actively use the app, leaving the
        // Meaning lens permanently blank. Explicit Meaning-lens demand,
        // `visiblePlacementAllowed` (post-onboarding), and the data-readiness
        // check are the correct preconditions.
        let clusterStatus = PipelineReadiness.meaningClusterStatus(
            context: context,
            vectorStore: vectorStore,
            clusterStore: VectorClusterStore(
                sharedDB: vectorStore.rawHandle,
                lock: vectorStore.rawLock
            ),
            messageStoreURL: messageStoreURL,
            currentEmbeddingVersion: currentEmbedder.embeddingVersion,
            initialImportWorkPending: initialImportWorkPending
        )
        let meaningScope = meaningLensScopeState(now: now)
        let clusterActionable = meaningScope.isEnabled
            && visiblePlacementAllowed
            && clusterStatus.needsDetection

        if clusterActionable {
            try ClusterDetectSeeder.seedIfNeeded(
                frame: .defaultFrame,
                context: context,
                promoteDeferred: meaningScope.isActive
            )
        }

        if !initialImportWorkPending,
           !activeTypes.contains(.entityPromote),
           let entityOrchestrator {
            var promotionActionable = try entityOrchestrator.hasOrphanedAttachmentEntities(
                context: context
            )
            if !promotionActionable {
                let represented = try representedEntityWorkIds(context: context)
                promotionActionable = try entityOrchestrator.hasUnrepresentedPromotionOrRefreshWork(
                    context: context,
                    representedEmbedIds: represented.embed,
                    representedRefreshIds: represented.refresh
                )
            }
            if promotionActionable {
                try queue.enqueue(type: .entityPromote, priority: 7, context: context)
            }
        }

        // .train — event-driven via TrainingTrigger.
        let state = TrainingRunState.current(context: context)
        let currentTrainingCompatibility = (engine as? any CheckpointAwareTrainingEngine)?
            .checkpointCompatibility
        let currentTrainingProfileID = currentTrainingCompatibility.map {
            TrainingCorpusPlanner.trainingProfileID(for: $0)
        }
        let trainingNow = Date()
        // A promotion stamp on a pair is meaningful only under a promoted
        // checkpoint this engine can load. With no compatible lineage (a
        // fresh install, a reset, or a task change that orphaned the old
        // adapter) every eligible pair is a target and nothing counts as
        // trained, however an earlier task stamped it: the new task's first
        // run must not wait for evidence the old task never saw.
        let hasPromotedLineage = try Self.hasPromotedLineage(compatibility: currentTrainingCompatibility, context: context)
        let trainingCandidateCorpusProgress: TrainingCandidateCorpusProgress
        if let messageSnapshot {
            let progress = messageSnapshot.trainingCandidateCorpusProgress
            trainingCandidateCorpusProgress = hasPromotedLineage ? progress : TrainingCandidateCorpusProgress(
                discoveredMessageCount: progress.discoveredMessageCount,
                assessedMessageCount: progress.assessedMessageCount,
                eligibleMessageCount: progress.eligibleMessageCount,
                trainedMessageCount: 0
            )
        } else {
            let evidenceRows = try context.fetch(FetchDescriptor<SentTrainingEvidence>())
            let trashedMessageIDs = try TrainingPair.trashedMessageIDs(in: context)
            var eligibleMessageCount = 0
            var trainedMessageCount = 0

            for evidence in evidenceRows where evidence.disposition == .loraEligible {
                guard (evidence.sentAt ?? evidence.createdAt) <= trainingNow else { continue }
                let eligiblePairs = evidence.trainingPairs.filter { pair in
                    pair.evidenceRevision == evidence.revision
                        && pair.trainingRoleRaw != TrainingPairRole.validationHoldout.rawValue
                        && !pair.referencesTrashedMessage(in: trashedMessageIDs)
                        && pair.isTrainablePromptFormat
                        && !pair.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !pair.completionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard !eligiblePairs.isEmpty else { continue }
                eligibleMessageCount += 1
                if hasPromotedLineage, eligiblePairs.allSatisfy({
                    $0.latestPromotedEvidenceRevision == $0.evidenceRevision
                }) {
                    trainedMessageCount += 1
                }
            }

            trainingCandidateCorpusProgress = TrainingCandidateCorpusProgress(
                discoveredMessageCount: evidenceRows.count,
                assessedMessageCount: evidenceRows.count(where: {
                    $0.disposition != .pendingPreparation
                }),
                eligibleMessageCount: eligibleMessageCount,
                trainedMessageCount: trainedMessageCount
            )
        }
        let pendingTargetCount: Int
        let deferredTargetCount: Int
        let deferredSince: Date?
        let snapshotTargetCount = messageSnapshot.map {
            hasPromotedLineage ? $0.pendingTrainingTargetCount : $0.eligibleTrainingPairCount
        }
        if let snapshot = messageSnapshot, let snapshotTargetCount,
           snapshot.trainingHolds != nil || snapshotTargetCount == 0 {
            // Exact under the loaded profile's failure and deferral stamps;
            // without them, zero is still exact.
            pendingTargetCount = snapshotTargetCount
            let holds = snapshot.trainingHolds
            deferredTargetCount = (hasPromotedLineage ? holds?.deferredTargetCount : holds?.deferredEligibleCount) ?? 0
            deferredSince = hasPromotedLineage ? holds?.earliestDeferredTargetAt : holds?.earliestDeferredEligibleAt
        } else {
            let allPairs = try context.fetch(FetchDescriptor<TrainingPair>())
            let trashedMessageIDs = try TrainingPair.trashedMessageIDs(in: context)
            let candidates = allPairs.filter { pair in
                guard let evidence = pair.evidence else { return false }
                return evidence.disposition == .loraEligible
                    && evidence.revision == pair.evidenceRevision
                    && (evidence.sentAt ?? evidence.createdAt) <= trainingNow
                    && (!hasPromotedLineage || pair.latestPromotedEvidenceRevision != pair.evidenceRevision)
                    && !(pair.latestFailedEvidenceRevision == pair.evidenceRevision
                        && pair.latestFailedTrainingProfileID == currentTrainingProfileID)
                    && !pair.referencesTrashedMessage(in: trashedMessageIDs)
                    && pair.trainingRoleRaw != TrainingPairRole.validationHoldout.rawValue
                    && pair.isTrainablePromptFormat
                    && !pair.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !pair.completionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let deferred = candidates.filter {
                TrainingCorpusPlanner.isDeferred($0, trainingProfileID: currentTrainingProfileID ?? "", now: trainingNow)
            }
            pendingTargetCount = candidates.count - deferred.count
            deferredTargetCount = deferred.count
            deferredSince = deferred.compactMap(\.latestDeferredAt).min()
        }
        let deferredRetryAt = deferredSince.map {
            $0.addingTimeInterval(TrainingOptimizationPolicy.current.deferralRetryInterval)
        }

        let lineageID = "global-personalization"
        let activeRunStates: Set<String> = [
            TrainingCorpusRunState.preparing.rawValue,
            TrainingCorpusRunState.training.rawValue,
            TrainingCorpusRunState.validating.rawValue,
            TrainingCorpusRunState.checkpointing.rawValue,
            TrainingCorpusRunState.interrupted.rawValue,
        ]
        let staleHeartbeatCutoff = trainingNow.addingTimeInterval(-15 * 60)
        let allRuns = try context.fetch(FetchDescriptor<TrainingCorpusRun>())
        for run in allRuns where run.lineageID == lineageID
            && activeRunStates.contains(run.stateRaw)
            && run.state != .interrupted
            && (run.heartbeatAt ?? run.startedAt ?? run.createdAt) < staleHeartbeatCutoff {
            run.state = .interrupted
            run.interruptedAt = trainingNow
        }
        if context.hasChanges {
            try context.save()
        }
        var activeRun = allRuns
            .filter { $0.lineageID == lineageID && activeRunStates.contains($0.stateRaw) }
            .sorted { $0.createdAt < $1.createdAt }
            .first

        if let run = activeRun,
           let compatibility = currentTrainingCompatibility {
            let currentProfileID = TrainingCorpusPlanner.trainingProfileID(for: compatibility)
            if run.baseModelManifestID != compatibility.baseModelID
                || run.trainingProfileID != currentProfileID {
                run.state = .failed
                run.failedAt = trainingNow
                run.failureReason = "Loaded model or LoRA profile no longer matches this run."
                try context.save()
                activeRun = nil
            }
        }
        // The first full pass waits for the corpus to finish its first
        // preparation under the current format, so all prepared mail trains
        // together in full epochs; hourly retries of current-format failures
        // never hold it. Once a lineage is promoted, later examples enter
        // incremental runs as they are prepared.
        let preparationRemaining = !hasPromotedLineage && activeRun == nil
            ? try messageSnapshot?.outstandingTrainingPreparationCount
                ?? TrainingPairBuilder.outstandingPreparationCount(context: context)
            : 0
        let decision = TrainingTrigger.decide(
            isPaused: state.isPaused,
            engineReady: engine.isModelLoaded,
            forceRunRequested: state.forceRunRequested,
            hasPromotedLineage: hasPromotedLineage,
            lastRunAt: state.lastRunAt,
            pendingTargetCount: pendingTargetCount,
            preparationRemaining: preparationRemaining,
            deferredTargetCount: deferredTargetCount,
            deferredRetryAt: deferredRetryAt,
            now: trainingNow
        )

        publisher.refreshCadence(
            pendingTrainingTargetCount: pendingTargetCount,
            readiness: decision.readiness
        )
        publisher.reflectPauseToggle(state.isPaused)
        publisher.setEngineReady(engine.isModelLoaded)

        // Model loading is owned by the generative helper's
        // resource-coordinated loader; training never constructs weights
        // itself. Retrieval progress is not a training wait reason.
        publisher.setResourceWaitReason(nil)
        // Seed shape comes straight from the trigger:
        //   incremental → priority 5 (background lane). Strictly BELOW
        //     `.generateDraft` (enqueued at priority 4 by SendDispatcher /
        //     live-inbound), so the urgent claim band (`claimNext maxPriority
        //     ≤ 4`) never picks incremental training ahead of interactive
        //     drafting after a send. It is also still subject to every `.train`
        //     exclude rule (foreground / throttle), so it
        //     only claims on background-eligible ticks.
        //   initial/full → priority 5 as well: prepared examples must train
        //     before the next priority-7 preparation batch can starve them.
        //     All training still obeys the foreground/resource exclusions.
        if activeRun == nil,
           let seedMode = decision.seedMode,
           trainingCandidateCorpusProgress.eligibleMessageCount > 0,
           PipelineFeatureFlags.qwenPersonalizationTrainingEnabled,
           !activeTypes.contains(.train),
           engine.isModelLoaded {
            if let checkpointEngine = engine as? any CheckpointAwareTrainingEngine,
               let compatibility = checkpointEngine.checkpointCompatibility {
                let kind: TrainingCorpusRunKind
                switch seedMode {
                case .initialFull:
                    kind = .initialFull
                case .incremental:
                    kind = .incremental
                case .manualFull:
                    kind = .manualFull
                }
                let profileID = TrainingCorpusPlanner.trainingProfileID(for: compatibility)
                activeRun = try TrainingCorpusPlanner().planRun(
                    kind: kind,
                    lineageID: lineageID,
                    baseModelManifestID: compatibility.baseModelID,
                    trainingProfileID: profileID,
                    snapshotCutoff: trainingNow,
                    context: context
                )
            }
        }

        if let activeRun,
           !state.isPaused,
           PipelineFeatureFlags.qwenPersonalizationTrainingEnabled,
           !activeTypes.contains(.train),
           engine.isModelLoaded,
           currentTrainingCompatibility != nil {
            let priority = 5
            try queue.enqueue(
                type: .train,
                priority: priority,
                payload: activeRun.id.uuidString.lowercased(),
                context: context
            )
        }
        // Train Now is satisfied only when its manual-full snapshot durably
        // exists — either just planned above or already active. Consuming the
        // flag anywhere earlier (the orchestrator once cleared it at job
        // start) silently dropped a Train Now issued mid-run.
        if state.forceRunRequested,
           let manualRun = activeRun,
           manualRun.kind == .manualFull {
            // The request time stays: Train Now's exclusive hour runs from
            // the latest request, including a repeat during an older run.
            state.forceRunRequested = false
            try context.save()
        }
        let latestCheckpointLifecycle = try context.fetch(FetchDescriptor<TrainingCheckpoint>())
            .filter { !$0.archived }
            .sorted { $0.createdAt < $1.createdAt }
            .last
            .flatMap { checkpoint in
                checkpoint.lifecycleRaw.flatMap(TrainingCheckpointLifecycle.init(rawValue:))
            }
        let projectedRun = activeRun ?? allRuns
            .filter { $0.lineageID == lineageID }
            .sorted { $0.createdAt < $1.createdAt }
            .last
        publisher.project(
            run: projectedRun,
            pendingTrainingTargetCount: pendingTargetCount,
            checkpointLifecycle: latestCheckpointLifecycle,
            trainingCandidateCorpusProgress: trainingCandidateCorpusProgress
        )

        // .extractAttachments: any Attachment row still has neither
        // `extractedTextPath` nor an `extractionMethod` marker — i.e. ingest
        // skipped it under the bounded first-run policy and the worker hasn't
        // visited it yet. Priority 6 so it sits behind .embed (5) but ahead of
        // training maintenance (7+); attachment text feeds the orientation
        // paragraph and per-attachment retrieval, so we want it to land soon
        // after the regular pipeline catches up.
        if catchUpMaintenanceAllowed,
           !initialImportWorkPending,
           !activeTypes.contains(.extractAttachments),
           AttachmentExtractionWorker.hasPendingWork(context: context) {
            try queue.enqueue(type: .extractAttachments, priority: 6, context: context)
        }

        // .extractVisualAttachments: image attachments whose grounded visual
        // inputs have not reached a terminal state for the current parser.
        // The worker persists an explicit unavailable outcome when the local
        // model cannot run so reply preparation cannot wait indefinitely.
        if catchUpMaintenanceAllowed,
           !initialImportWorkPending,
           !activeTypes.contains(.extractVisualAttachments),
           VisualAttachmentExtractionWorker.hasPendingWork(context: context) {
            try queue.enqueue(type: .extractVisualAttachments, priority: 6, context: context)
        }

        // .extractCaptureMetadata: photo / video attachments whose capture
        // time, place and captions have not been read for the current reader
        // version and reading language, or whose retry delay has elapsed.
        // It uses no model, so it is deliberately absent from the Qwen
        // backpressure, interactive-generation and initial-import holds:
        // reply preparation stages it per message for live mail and must not
        // wait behind model work. (The summary reruns it queues are gated as
        // `.summarize` jobs.) MapKit lookups are paced inside the resolver.
        if catchUpMaintenanceAllowed,
           !initialImportWorkPending,
           !activeTypes.contains(.extractCaptureMetadata),
           CaptureMetadataWorker.hasPendingWork(context: context) {
            try queue.enqueue(type: .extractCaptureMetadata, priority: 6, context: context)
        }

        // .pendingDeletionReaper: any PendingDeletionCandidate rows exist.
        // No payload — the worker scans the whole table internally.
        // priority=5 keeps it peer with .embed so grace-period
        // expiries are processed promptly without starving higher-priority work.
        let pendingDeletionCandidates = try context.fetch(FetchDescriptor<PendingDeletionCandidate>())
        let pendingDeletionReaperActionable = !pendingDeletionCandidates.isEmpty
        if pendingDeletionReaperActionable, !activeTypes.contains(.pendingDeletionReaper) {
            try queue.enqueue(type: .pendingDeletionReaper, priority: 5, context: context)
        }

        // MARK: - IMAP seeders

        // Per-folder granularity for IMAP workers. Content acquisition has one
        // authority: every configured, non-paused account is admitted unless
        // an actionable reauthentication error requires user intervention.
        let imapAccounts = accounts.filter { account in
            account.status != .paused
                && account.needsImapReauth == false
                && account.imapHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && account.imapKeychainRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        let recentFailedWithheldAutoDeleteJobs = try JobFetch.jobs(
            type: .withheldAutoDelete,
            statuses: [.failed],
            context: context
        ).filter { Self.isRecentFailedIMAPJob($0, now: now) }
        let activeWithheldAutoDeleteJobs = try JobFetch.jobs(
            type: .withheldAutoDelete,
            statuses: [.pending, .running],
            context: context
        )
        let withheldAutoDeleteJobs = activeWithheldAutoDeleteJobs
            + recentFailedWithheldAutoDeleteJobs
        var activeWithheldAutoDeleteAccounts = Set(withheldAutoDeleteJobs.compactMap { job -> UUID? in
            guard let payload = try? WithheldAutoDeleteWorker.decodePayload(from: job) else {
                return nil
            }
            return payload.accountID
        })

        let recentFailedIMAPBackfillJobs = try JobFetch.jobs(
            type: .imapBackfill,
            statuses: [.failed],
            context: context
        ).filter { Self.isRecentFailedIMAPJob($0, now: now) }
        let imapBackfillJobs = (
            activeIMAPBackfillJobs + recentFailedIMAPBackfillJobs
        ).filter {
            !Self.imapBackfillJobIsAlreadySatisfied($0, folderStates: allFolderStates)
        }
        let recentFailedIMAPPollJobs = try JobFetch.jobs(
            type: .imapPollFolder,
            statuses: [.failed],
            context: context
        ).filter { Self.isRecentFailedIMAPJob($0, now: now) }
        let recentFailedIMAPDeletionWatchJobs = try JobFetch.jobs(
            type: .imapDeletionWatch,
            statuses: [.failed],
            context: context
        ).filter { Self.isRecentFailedIMAPJob($0, now: now) }
        let activeIMAPPollJobs = try JobFetch.jobs(
            type: .imapPollFolder,
            statuses: [.pending, .running],
            context: context
        )
        let activeIMAPDeletionWatchJobs = try JobFetch.jobs(
            type: .imapDeletionWatch,
            statuses: [.pending, .running],
            context: context
        )
        let imapPollJobs = activeIMAPPollJobs + recentFailedIMAPPollJobs
        let imapDeletionWatchJobs = activeIMAPDeletionWatchJobs + recentFailedIMAPDeletionWatchJobs
        func deletionWatchPairKey(accountID: UUID, folderName: String) -> String {
            "\(accountID.uuidString)\u{1F}\(folderName)"
        }
        var activeDeletionWatchPairs = Set(imapDeletionWatchJobs.compactMap { job -> String? in
            guard let payloadStr = job.payload,
                  let data = payloadStr.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(IMAPDeletionWatchWorker.Payload.self, from: data)
            else { return nil }
            return deletionWatchPairKey(accountID: payload.accountID, folderName: payload.folderName)
        })

        for account in imapAccounts {
            if account.isWithheldAutoDeleteDue(now: now),
               !activeWithheldAutoDeleteAccounts.contains(account.id) {
                let payload = try WithheldAutoDeleteWorker.payloadString(accountID: account.id)
                try queue.enqueue(
                    type: .withheldAutoDelete,
                    priority: WithheldAutoDeleteWorker.priority,
                    payload: payload,
                    context: context
                )
                activeWithheldAutoDeleteAccounts.insert(account.id)
            }

            let folderStates = allFolderStates.filter { $0.account?.id == account.id }
            let shouldRunHistoricalBodyJobs = true
            let shouldRunLivePollJobs = true

            if shouldRunHistoricalBodyJobs {
                let lowerBound = account.ingestionLowerBoundAt
                for folder in folderStates {
                    if folder.backfillComplete,
                       folder.backfillLowerBoundAt != lowerBound {
                        folder.backfillComplete = false
                        folder.backfillLowerBoundAt = nil
                    } else if lowerBound == nil,
                              folder.backfillComplete,
                              folder.lowestFetchedUID > 1 {
                        // Legacy all-time self-heal: completion used to be
                        // possible before walking down to UID 1.
                        folder.backfillComplete = false
                    }
                }

                // .imapBackfill — one job per (account, folder) when backfill
                // has further UIDs to walk toward 1.
                for folder in folderStates {
                    guard !folder.backfillComplete else { continue }
                    if folder.lowestFetchedUID == 0 {
                        continue
                    }
                    guard folder.lowestFetchedUID > 1 else { continue }

                    let activePairJob = imapBackfillJobs.first { job in
                        guard let payloadStr = job.payload,
                              let data = payloadStr.data(using: .utf8),
                              let payload = try? JSONDecoder().decode(IMAPBackfillWorker.Payload.self, from: data) else {
                            return false
                        }
                        return payload.accountID == account.id && payload.folderName == folder.folderName
                    }
                    if let activePairJob {
                        if activePairJob.status == .pending,
                           activePairJob.priority != historicalIMAPBackfillPriority {
                            activePairJob.priority = historicalIMAPBackfillPriority
                            try context.save()
                        }
                        continue
                    }

                    let payload = IMAPBackfillWorker.Payload(
                        accountID: account.id,
                        folderName: folder.folderName,
                        batchSize: IMAPBackfillWorker.defaultBatchSize
                    )
                    let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? "{}"
                    try queue.enqueue(
                        type: .imapBackfill,
                        priority: historicalIMAPBackfillPriority,
                        payload: json,
                        context: context
                    )
                }
            }

            // .imapPollFolder — non-INBOX folders (INBOX covered by IDLE).
            // 30-minute cadence.
            if shouldRunLivePollJobs {
                for folder in folderStates {
                    guard folder.folderName.uppercased() != "INBOX" else { continue }

                    if let lastPollFailureAt = folder.lastPollFailureAt,
                       now.timeIntervalSince(lastPollFailureAt) < Self.failedIMAPJobReseedCooldown {
                        continue
                    }

                    if let lastPollAt = folder.lastPollAt,
                       now.timeIntervalSince(lastPollAt) < 30 * 60 {
                        continue
                    }

                    let pairAlreadyActive = imapPollJobs.contains { job in
                        guard let payloadStr = job.payload,
                              let data = payloadStr.data(using: .utf8),
                              let payload = try? JSONDecoder().decode(IMAPPollFolderWorker.Payload.self, from: data) else {
                            return false
                        }
                        return payload.accountID == account.id && payload.folderName == folder.folderName
                    }
                    if pairAlreadyActive { continue }

                    let payload = IMAPPollFolderWorker.Payload(
                        accountID: account.id,
                        folderName: folder.folderName,
                        batchSize: IMAPPollFolderWorker.defaultBatchSize
                    )
                    let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? "{}"
                    try queue.enqueue(type: .imapPollFolder, priority: 2, payload: json, context: context)
                }
            }

            // .imapDeletionWatch — SELECT-only deletion-watch tick. Keep a
            // fast Gmail All Mail watch alive because Gmail INBOX EXPUNGE
            // is only a label/archive signal; destructive deletes are safe to
            // apply only after All Mail reports VANISHED or reconciliation
            // confirms the Message-ID is gone.
            if shouldRunLivePollJobs {
                let host = account.imapHost?.lowercased() ?? ""
                let isGmail = host.contains("gmail") || host.contains("google")
                let deletionWatchCadence: TimeInterval = shouldRunLivePollJobs ? 60 : 10 * 60
                for folder in folderStates {
                    if shouldRunLivePollJobs {
                        guard isGmail,
                              classifyIMAPFolderRole(
                                  folder: folder.folderName,
                                  attributes: folder.folderAttributes
                              ) == .gmailAll
                        else { continue }
                    }
                    if let lastDeletionWatchFailureAt = folder.lastDeletionWatchFailureAt,
                       now.timeIntervalSince(lastDeletionWatchFailureAt) < Self.failedIMAPJobReseedCooldown {
                        continue
                    }
                    if let lastDeletionWatchAt = folder.lastDeletionWatchAt,
                       now.timeIntervalSince(lastDeletionWatchAt) < deletionWatchCadence {
                        continue
                    }

                    let pairKey = deletionWatchPairKey(
                        accountID: account.id,
                        folderName: folder.folderName
                    )
                    if activeDeletionWatchPairs.contains(pairKey) { continue }

                    let payload = IMAPDeletionWatchWorker.Payload(
                        accountID: account.id,
                        folderName: folder.folderName
                    )
                    let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? "{}"
                    try queue.enqueue(type: .imapDeletionWatch, priority: 4, payload: json, context: context)
                    activeDeletionWatchPairs.insert(pairKey)
                }
            }

        }

        if bodySummaryBacklogPending,
           !activeTypes.contains(.summarize) {
            try queue.enqueue(type: .summarize, priority: 6, context: context)
            activeTypes.insert(.summarize)
        }

        if shouldScheduleAccountMemoryRefresh, !initialImportWorkPending {
            let latestActiveTypes = try JobFetch.activeTypes(context: context)
            if !latestActiveTypes.contains(.accountMemoryRefresh),
               try !hasAccountMemoryRefreshBlockingWork(context: context) {
                try queue.enqueue(type: .accountMemoryRefresh, priority: 9, context: context)
            }
        }

        // Custom-category definition generation. The user-facing tag flow
        // enqueues this job the moment the activation threshold is reached;
        // this reseed covers restarts, budget-gated no-op completions, and
        // exhausted retry budgets so a collecting category can never wedge
        // short of activation while the engine is available.
        if interpretationEngineAvailable,
           !initialImportWorkPending,
           CustomCategoryDefinitionWorker.hasPendingWork(context: context) {
            let latestActiveTypes = try JobFetch.activeTypes(context: context)
            if !latestActiveTypes.contains(.customCategoryDefinition) {
                try queue.enqueue(type: .customCategoryDefinition, priority: 6, context: context)
            }
        }

        // Composer-owed generation work: drafts waiting on a generation
        // (answers submitted, regenerate) or an instruction revision. The
        // Composer enqueues `.generateDraft` at action time; this reseed
        // covers engine-unloaded no-op completions and transient generation
        // failures so a draft can never strand in "writing draft".
        if PipelineFeatureFlags.automaticReplyDraftGenerationEnabled,
           interpretationEngineAvailable,
           (!initialImportWorkPending || composerDraftingActive),
           (pendingComposerWork || pendingComposeWork) {
            let latestActiveTypes = try JobFetch.activeTypes(context: composerContext)
            if !latestActiveTypes.contains(.generateDraft) {
                try queue.enqueue(type: .generateDraft, priority: 4, context: composerContext)
            }
        }

        try ComposerDraftSyncScheduler.enqueueIfNeeded(context: composerContext)

        // Style discovery. Reseeds while trained sent email awaits
        // measurement or a style visit, or a style's membership or
        // description is stale, so the pulldown keeps pace with the corpus.
        if interpretationEngineAvailable,
           !initialImportWorkPending,
           StyleRegisterWorker.hasPendingWork(context: context) {
            let latestActiveTypes = try JobFetch.activeTypes(context: context)
            if !latestActiveTypes.contains(.distillStyleRegisters) {
                try queue.enqueue(type: .distillStyleRegisters, priority: 7, context: context)
            }
        }
    }

    private static func isRecentFailedIMAPJob(_ job: Job, now: Date) -> Bool {
        guard job.status == .failed,
              let completedAt = job.completedAt else {
            return false
        }
        return now.timeIntervalSince(completedAt) < failedIMAPJobReseedCooldown
    }

    @MainActor
    @discardableResult
    private func normalizeIndexDrainJobs(
        jobs: [Job],
        visiblePlacementAllowed: Bool,
        context: ModelContext
    ) throws -> Bool {
        let tracked = jobs.filter {
            $0.type == .index && $0.messageId == nil && (
                $0.status == .pending ||
                $0.status == .running ||
                $0.status == .failed
            )
        }
        guard visiblePlacementAllowed else {
            guard !tracked.isEmpty else { return false }
            for job in tracked {
                context.delete(job)
            }
            try context.save()
            print("[Layout] cleared \(tracked.count) index job(s); visible placement is gated")
            return true
        }
        let hasUnplaced = ((try? vectorStore.unplacedVectorIds(limit: 1)) ?? []).isEmpty == false
        guard hasUnplaced else {
            guard !tracked.isEmpty else { return false }
            for job in tracked {
                context.delete(job)
            }
            try context.save()
            print("[Layout] cleared \(tracked.count) index job(s); no unplaced vectors remain")
            return true
        }

        let activeDrainJobs = tracked.filter {
            $0.payload == nil && ($0.status == .pending || $0.status == .running)
        }
        let keepDrain = activeDrainJobs.first
        var removed = 0
        var priorityFixes = 0

        for job in tracked {
            if let keepDrain, job === keepDrain {
                continue
            }
            context.delete(job)
            removed += 1
        }

        if let keepDrain, keepDrain.priority != 6 {
            keepDrain.priority = 6
            priorityFixes += 1
        }

        var scheduled = false
        if keepDrain == nil {
            context.insert(Job(type: .index, priority: 6))
            scheduled = true
        }

        guard removed > 0 || priorityFixes > 0 || scheduled else { return false }
        try context.save()

        if removed > 0 || scheduled {
            let action = scheduled ? "scheduled drain" : "kept drain"
            print("[Layout] normalized index backlog: removed \(removed) legacy/duplicate job(s), \(action)")
        }
        return true
    }

    private static func hasValidTriageVerdictJSON(_ value: String?) -> Bool {
        TriageVerdictJSON.hasRequiredBooleanFields(value)
    }

    static func hasCompleteInterpretation(_ message: Message) -> Bool {
        PipelineReadiness.hasCompleteInterpretation(message)
    }

    // MARK: - Requeue

    /// Re-seed a pipeline job after completion.
    @MainActor
    public func requeuePipelineJob(type: JobType, priority: Int, context: ModelContext) throws {
        try queue.enqueue(type: type, priority: priority, context: context)
    }
}
