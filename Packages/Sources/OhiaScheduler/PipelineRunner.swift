import Foundation
import OSLog
import SwiftData
import OhiaCore
import OhiaMail
import OhiaML

private let pipelineLogger = Logger(subsystem: "org.jgkarlin.Ohia", category: "pipeline")

// MARK: - PipelineResult

public struct PipelineResult: Sendable {
    public let success: Bool
    public let itemsProcessed: Int
    public let error: String?
    /// `nil` means this job type has not adopted message-scoped completion
    /// metadata. An empty array is an authoritative no-message-change result.
    public let messageMutations: [PipelineMessageMutation]?
    /// True when the runner declined the claimed job because the current
    /// model-compute budget does not admit its work class (e.g. a backlog
    /// per-message `.embed` while only `.bgeLiveFreshness` is borrowed
    /// through the foreground throttle). The scheduler returns the job to
    /// `.pending` untouched — no completion, no retry bump, no error —
    /// so it resumes once the budget re-admits its class.
    public let releasedJob: Bool

    public init(
        success: Bool,
        itemsProcessed: Int,
        error: String? = nil,
        releasedJob: Bool = false,
        messageMutations: [PipelineMessageMutation]? = nil
    ) {
        self.success = success
        self.itemsProcessed = itemsProcessed
        self.error = error
        self.releasedJob = releasedJob
        self.messageMutations = messageMutations
    }

    func addingProcessedItems(_ additionalItems: Int) -> PipelineResult {
        PipelineResult(
            success: success,
            itemsProcessed: itemsProcessed + additionalItems,
            error: error,
            releasedJob: releasedJob,
            messageMutations: messageMutations
        )
    }
}

// MARK: - PipelineRunner

/// Routes a Job to the appropriate orchestrator and returns a PipelineResult.
public final class PipelineRunner: @unchecked Sendable {

    private static let vectorIndexReconcileInterval: TimeInterval = 6 * 3600
    private static let embeddingReindexInterval: TimeInterval = 1
    private static let summarizeBatchCap = 3
    private static let firstLightInterpretationEmbedPriority = 4
    private static let interpretationEmbedPriority = 5
    private static let interpretationFallbackRetryLimit = JobQueue.maxRetries
    private static let interpretationTerminalRetryDelay = JobQueue.backoffDelay(
        for: JobQueue.maxRetries,
        jitter: 0
    )
    private static let refineActiveDelay: TimeInterval = 60
    private static let refineIdleDelay: TimeInterval = 60

    private enum InterpretationGenerationOutcome {
        case success(InterpretationResult)
        case parseFailure
        case transientFailure
    }

    private enum InterpretationMetadataGenerationOutcome {
        case success(InterpretationMetadataResult)
        case parseFailure
        case transientFailure
    }

    private struct InterpretationBatchSelection {
        let messageIDs: [UUID]
        let nextRetryAt: Date?
    }

    private struct ReplyPreparationDependencies {
        let sourceSelector: LLMComposerSourceSelector
        let contextPacker: ComposerContextPacker
        let relatedAffinityProvider: any ComposerRelatedAffinityProviding
        let webResearchPlanner: (any ComposerWebResearchPlanning)?
        let externalResearchProvider: (any ComposerExternalResearching)?
        let compiler: ReplySourceCompiler
        let interviewPlanner: ReplyPreparationInterviewPlanner
        let draftGenerator: DraftOrchestrator
    }

    private let canonicalStore: CanonicalStore
    private let vectorStore: VectorStore
    private let vectorIndex: VectorIndex?
    private let embedder: EmbeddingProvider
    private let embedderRegistry: EmbedderRegistry
    private let hybridRetriever: HybridRetriever?
    private let migrationCoordinator: EmbeddingMigrationCoordinator
    private let embeddingOrchestrator: EmbeddingOrchestrator
    private let engine: TrainingEngine
    private let appleSummarizer: (any Summarizing)?
    private let appleAvailabilityProvider: @Sendable () -> AppleIntelligenceAvailability.State
    private let summaryLanguageProvider: @Sendable () -> SummarizationTargetLanguage
    private let trainingStatusPublisher: TrainingStatusPublisher
    private let modelActivityStatusPublisher: ModelActivityStatusPublisher?
    private let toolRegistry: ToolRegistry?
    private let generationContextPackStore: GenerationContextPackStore?
    private let requiresGenerationContextPack: Bool
    private let sendExecutor: SendExecuting
    private let imapSessionManager: IMAPSessionManager?
    private let messageStoreURL: URL?
    private let checkpointDirectory: URL
    // Optional so PipelineRunner can still be constructed in test rigs or on
    // machines where Metal initialization fails (Layout* types throw at init).
    // When nil, `.index` / `.refine` jobs no-op and the `.embed` handler skips
    // the post-embed `.index` seed.
    private let layoutOrchestrator: LayoutOrchestrator?
    private let layoutIndexWorker: LayoutIndexWorker?
    private let layoutRefineWorker: LayoutRefineWorker?
    // Constructed externally — the worker needs a `FrameEdgeProvider` that
    // joins SwiftData `Message` rows on MainActor, so we accept it here
    // instead of deriving it from `layoutOrchestrator`. Nil → `.frameBurst`
    // no-ops (test rigs / headless environments).
    private let frameBurstWorker: FrameBurstWorker?
    // When nil, `.clusterDetect` jobs no-op (test rigs / headless
    // environments). Wired by `OhiaApp` against `services.vectorClusterStore`.
    private let clusterDetectionWorker: ClusterDetectionWorker?
    // Optional entity pipeline: headless/test rigs can omit it; entity jobs
    // then clear as successful no-ops instead of wedging the queue.
    private let entityOrchestrator: EntityOrchestrator?
    private let allowsVisiblePlacement: @MainActor @Sendable () -> Bool
    // Optional: when wired, `.refine` can avoid moving nodes while Constellation
    // is on screen. When nil, `.refine` uses the idle pacing.
    private let constellationActiveMonitor: ConstellationActiveMonitor?
    // Optional: when nil, `.pendingDeletionReaper` jobs no-op (test rigs /
    // environments where deletion sync is not configured).
    private let pendingDeletionReaperWorker: PendingDeletionReaperWorker?
    private let localDeletionCascade: MessageLocalDeletionCascade?
    private let performanceProfile: PipelinePerformanceProfile
    private let messagesTranscriptProvider: any MessagesTranscriptProviding
    private let mcpEnvironmentResolver: (@Sendable (MCPConfiguredServer) -> [String: String])?

    /// Set by `BackgroundScheduler` after construction so the runner can
    /// pass a live "should I stop?" check into the long-running ingest
    /// loop without taking a circular dependency on the scheduler. Default
    /// returns false (test rigs and any caller that doesn't wire it up
    /// behave as before).
    @MainActor public var trainingPreemptionProvider: @MainActor (ModelContext) -> String? = { _ in nil }
    @MainActor public var interactiveQwenGenerationProvider: @MainActor @Sendable () -> Bool = { false }
    @MainActor public var accountMemoryRefreshYieldProvider: @MainActor (ModelContext) -> Bool = { _ in false }
    @MainActor public var replySourcePreparationYieldProvider: @MainActor (ModelContext) -> Bool = { _ in false }
    @MainActor private var singleSlotInterpretationRetryTurn = true

    /// Body and attachment summaries withheld because they stayed outside
    /// the reading language. The lanes skip such an item while it waits out a
    /// retry or once its retries are spent, and a skipped item does not count
    /// as backlog, so the lanes neither regenerate it on every drain nor hold
    /// back the work that waits for the backlog to empty. An on-demand view
    /// still generates it.
    let bodySummaryRetries = ReadingLanguageRetrySchedule(
        retryDelays: ReadingLanguageRetrySchedule.bodySummaryDelays
    )
    let attachmentSummaryRetries = ReadingLanguageRetrySchedule(
        retryDelays: ReadingLanguageRetrySchedule.attachmentSummaryDelays
    )
    /// The clock the retry schedules read; tests move it forward.
    @MainActor var retryClock: @MainActor () -> Date = { Date() }

    public init(
        canonicalStore: CanonicalStore,
        vectorStore: VectorStore,
        vectorIndex: VectorIndex? = nil,
        embedder: EmbeddingProvider,
        embedderRegistry: EmbedderRegistry? = nil,
        hybridRetriever: HybridRetriever? = nil,
        migrationCoordinator: EmbeddingMigrationCoordinator? = nil,
        embeddingOrchestrator: EmbeddingOrchestrator? = nil,
        engine: TrainingEngine,
        appleSummarizer: (any Summarizing)? = AppleFoundationSummarizer(),
        appleAvailabilityProvider: @escaping @Sendable () -> AppleIntelligenceAvailability.State = {
            AppleIntelligenceAvailability.current()
        },
        summaryLanguageProvider: @escaping @Sendable () -> SummarizationTargetLanguage = {
            .ohiaPreferred()
        },
        trainingStatusPublisher: TrainingStatusPublisher,
        modelActivityStatusPublisher: ModelActivityStatusPublisher? = nil,
        toolRegistry: ToolRegistry? = nil,
        generationContextPackStore: GenerationContextPackStore? = nil,
        requiresGenerationContextPack: Bool = false,
        sendExecutor: SendExecuting,
        imapSessionManager: IMAPSessionManager? = nil,
        layoutOrchestrator: LayoutOrchestrator? = nil,
        frameBurstWorker: FrameBurstWorker? = nil,
        clusterDetectionWorker: ClusterDetectionWorker? = nil,
        entityOrchestrator: EntityOrchestrator? = nil,
        allowsIMAPWork _: @escaping @MainActor @Sendable () -> Bool = { true },
        allowsVisiblePlacement: @escaping @MainActor @Sendable () -> Bool = { true },
        constellationActiveMonitor: ConstellationActiveMonitor? = nil,
        pendingDeletionReaperWorker: PendingDeletionReaperWorker? = nil,
        localDeletionCascade: MessageLocalDeletionCascade? = nil,
        messageStoreURL: URL? = nil,
        checkpointDirectory: URL? = nil,
        messagesTranscriptProvider: any MessagesTranscriptProviding = UnavailableMessagesTranscriptProvider(),
        mcpEnvironmentResolver: (@Sendable (MCPConfiguredServer) -> [String: String])? = nil,
        performanceProfile: PipelinePerformanceProfile = .balanced
    ) {
        self.canonicalStore = canonicalStore
        self.vectorStore = vectorStore
        self.vectorIndex = vectorIndex
        self.embedder = embedder
        let resolvedRegistry = embedderRegistry ?? EmbedderRegistry(current: embedder)
        self.embedderRegistry = resolvedRegistry
        self.hybridRetriever = hybridRetriever
        self.migrationCoordinator = migrationCoordinator ?? EmbeddingMigrationCoordinator(
            registry: resolvedRegistry,
            vectorStore: vectorStore,
            canonicalStore: canonicalStore
        )
        self.embeddingOrchestrator = embeddingOrchestrator ?? EmbeddingOrchestrator(
            embedder: embedder,
            vectorStore: vectorStore,
            canonicalStore: canonicalStore,
            messageStoreURL: messageStoreURL
        )
        self.engine = engine
        self.appleSummarizer = appleSummarizer
        self.appleAvailabilityProvider = appleAvailabilityProvider
        self.summaryLanguageProvider = summaryLanguageProvider
        self.trainingStatusPublisher = trainingStatusPublisher
        self.modelActivityStatusPublisher = modelActivityStatusPublisher
        self.toolRegistry = toolRegistry
        self.generationContextPackStore = generationContextPackStore
        self.requiresGenerationContextPack = requiresGenerationContextPack
        self.sendExecutor = sendExecutor
        self.imapSessionManager = imapSessionManager
        self.messageStoreURL = messageStoreURL
        self.checkpointDirectory = checkpointDirectory
            ?? canonicalStore.baseDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("training_checkpoints", isDirectory: true)
        self.layoutOrchestrator = layoutOrchestrator
        self.layoutIndexWorker = layoutOrchestrator.map { LayoutIndexWorker(orchestrator: $0) }
        self.layoutRefineWorker = layoutOrchestrator.map { LayoutRefineWorker(orchestrator: $0) }
        self.frameBurstWorker = frameBurstWorker
        self.clusterDetectionWorker = clusterDetectionWorker
        self.entityOrchestrator = entityOrchestrator
        self.allowsVisiblePlacement = allowsVisiblePlacement
        self.constellationActiveMonitor = constellationActiveMonitor
        self.pendingDeletionReaperWorker = pendingDeletionReaperWorker
        self.localDeletionCascade = localDeletionCascade
        self.messagesTranscriptProvider = messagesTranscriptProvider
        self.mcpEnvironmentResolver = mcpEnvironmentResolver
        self.performanceProfile = performanceProfile
    }

    @MainActor
    private func makeReplyPreparationDependencies(
        container: ModelContainer?,
        shouldYield: @escaping @MainActor @Sendable () -> Bool = { false }
    ) -> ReplyPreparationDependencies {
        let sourceSelector = LLMComposerSourceSelector(
            engine: engine,
            modelActivityStatusPublisher: modelActivityStatusPublisher
        )
        let automaticResearchEnabled = MCPServerStore.hasEnabledAutomaticResearchServer()
        let webResearchPlanner: (any ComposerWebResearchPlanning)? =
            automaticResearchEnabled
                ? LLMComposerWebResearchPlanner(
                    engine: engine,
                    modelActivityStatusPublisher: modelActivityStatusPublisher
                )
                : nil
        let mcpProvider: MCPComposerResearchProvider?
        if automaticResearchEnabled {
            if let mcpEnvironmentResolver {
                mcpProvider = MCPComposerResearchProvider(
                    environmentResolver: mcpEnvironmentResolver
                )
            } else {
                mcpProvider = MCPComposerResearchProvider()
            }
        } else {
            mcpProvider = nil
        }
        let externalResearchProvider: (any ComposerExternalResearching)? = mcpProvider
        let relatedAffinityProvider = StoredComposerRelatedAffinityProvider(
            vectorNeighborsStore: VectorNeighborsStore(
                sharedDB: vectorStore.rawHandle,
                lock: vectorStore.rawLock
            ),
            vectorClusterStore: VectorClusterStore(
                sharedDB: vectorStore.rawHandle,
                lock: vectorStore.rawLock
            )
        )
        let contextPacker = ComposerContextPacker(
            tokenCounter: engine as? any PromptTokenCounting
        )
        let compiler = ReplySourceCompiler(
            sourceSelector: sourceSelector,
            hybridRetriever: hybridRetriever,
            contextPacker: contextPacker,
            relatedAffinityProvider: relatedAffinityProvider,
            webResearchPlanner: webResearchPlanner,
            externalResearchProvider: externalResearchProvider,
            messagesProvider: messagesTranscriptProvider,
            shouldYield: shouldYield
        )
        let interviewPlanner = ComposerInterviewPlanner(
            engine: engine,
            modelActivityStatusPublisher: modelActivityStatusPublisher,
            displayLanguageGuard: DisplayLanguageGuard(container: container, engine: engine)
        )
        let groundingResolver = QuestionGroundingResolver(
            engine: engine,
            modelActivityStatusPublisher: modelActivityStatusPublisher
        )
        let draftGenerator = DraftOrchestrator(
            engine: engine,
            vectorStore: vectorStore,
            embedder: embedder,
            canonicalStore: canonicalStore,
            hybridRetriever: hybridRetriever,
            toolRegistry: toolRegistry,
            contextPacker: contextPacker,
            modelActivityStatusPublisher: modelActivityStatusPublisher
        )
        return ReplyPreparationDependencies(
            sourceSelector: sourceSelector,
            contextPacker: contextPacker,
            relatedAffinityProvider: relatedAffinityProvider,
            webResearchPlanner: webResearchPlanner,
            externalResearchProvider: externalResearchProvider,
            compiler: compiler,
            interviewPlanner: ReplyPreparationInterviewPlanner(
                planner: interviewPlanner,
                groundingResolver: groundingResolver,
                contextPacker: contextPacker
            ),
            draftGenerator: draftGenerator
        )
    }

    // MARK: - Run

    @MainActor
    public func run(
        job: Job,
        context: ModelContext,
        batchSize: Int,
        resourceDecision: ResourceDecision = .unrestricted
    ) async throws -> PipelineResult {
        let message: Message? = job.messageId.flatMap { id in
            var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }
        let event = Self.activityEvent(SessionActivityLog.operationTitle(job.type.rawValue), message: message)
        SessionActivityLog.shared.record(event)
        do {
            let result = try await runLoggedJob(job: job, context: context, batchSize: batchSize, resourceDecision: resourceDecision)
            SessionActivityLog.shared.record(event.ending(
                job.type == .syncComposerDrafts && result.success ? .ended :
                    result.success || result.releasedJob ? .finished : .failed,
                detail: job.type == .syncComposerDrafts && result.success
                    ? "Draft sync pass ended. Individual draft outcomes are recorded separately."
                    : result.releasedJob ? "Deferred until resources are available" : result.error
            ))
            return result
        } catch {
            SessionActivityLog.shared.record(event.ending(error is CancellationError ? .cancelled : .failed, detail: error.localizedDescription))
            throw error
        }
    }

    @MainActor
    private static func activityEvent(_ operation: String, message: Message?) -> SessionActivityEvent {
        SessionActivityEvent(operation: operation, phase: .started,
                             subject: message?.subject, accountID: message?.accountID ?? message?.account?.id,
                             accountName: message?.account?.displayName)
    }

    @MainActor
    private func runLoggedJob(
        job: Job,
        context: ModelContext,
        batchSize: Int,
        resourceDecision: ResourceDecision
    ) async throws -> PipelineResult {
        switch job.type {

          case .imapLiveInbound:
            return PipelineResult(success: true, itemsProcessed: 0)

        case .prepareReplySources:
            guard let payload = ReplySourcePreparationJobPayload.decode(job.payload),
                  job.messageId == payload.messageID else {
                throw PipelineError.invalidPayload(
                    "prepareReplySources job missing or mismatched payload"
                )
            }
            guard engine.isModelLoaded else {
                throw TrainingEngineError.modelNotLoaded
            }
            let shouldYield: @MainActor @Sendable () -> Bool = { [replySourcePreparationYieldProvider, context] in
                replySourcePreparationYieldProvider(context)
            }
            let dependencies = makeReplyPreparationDependencies(
                container: context.container,
                shouldYield: shouldYield
            )
            let outcome = try await ReplySourcePreparationWorker(
                compiler: dependencies.compiler,
                interviewPlanner: dependencies.interviewPlanner,
                draftGenerator: dependencies.draftGenerator,
                reconciler: ReplySourcePreparationCoordinator(),
                shouldYield: shouldYield
            ).run(
                job: job,
                context: context
            )
            return PipelineResult(
                success: true,
                itemsProcessed: outcome == .published ? 1 : 0,
                releasedJob: outcome == .yielded
            )

        case .ingest:
            // Decode compatibility only. Old persisted Mail.app seed jobs must
            // drain without consulting or mutating an Account or mailbox.
            return PipelineResult(success: true, itemsProcessed: 0)

        case .parse:
            // No-op: handled inline during ingestion
            return PipelineResult(success: true, itemsProcessed: 0)

        case .triage:
            // Legacy typed-classifier jobs may still exist in older stores.
            // Qwen interpretation now owns MessageType via TriageVerdict, so
            // drain these without writing a competing heuristic classification.
            return PipelineResult(success: true, itemsProcessed: 0)

        case .summarize:
            let summarizeBatchLimit = summarizeBatchLimit(resourceDecision: resourceDecision)
            let messageMutations = try await interpretQueuedMessage(
                job: job,
                context: context,
                batchLimit: summarizeBatchLimit
            )
            let count = messageMutations.reduce(into: 0) { count, mutation in
                count += mutation.messageIDs.count
            }
            if job.messageId == nil,
               count == 0,
               let nextAttemptAt = job.nextAttemptAt,
               nextAttemptAt > Date() {
                return PipelineResult(
                    success: true,
                    itemsProcessed: 0,
                    releasedJob: true,
                    messageMutations: []
                )
            }
            return PipelineResult(
                success: true,
                itemsProcessed: count,
                messageMutations: messageMutations
            )

        case .summarizeAttachments:
            let service = AttachmentSummaryService(
                apple: AppleFoundationAttachmentSummarizer(),
                mlx: MLXAttachmentSummarizer(engine: engine),
                appleEnabled: Self.appleSummarizationFallbackEnabled(),
                displayLanguageGuard: displayLanguageGuard(context: context, modelAvailable: true),
                availabilityProvider: appleAvailabilityProvider
            )
            let worker = AttachmentSummaryBackfillWorker(
                service: service,
                targetLanguage: summaryLanguageProvider(),
                languageRetries: attachmentSummaryRetries
            )
            let outcome = try await worker.runOnce(
                context: context,
                messageIDFromJob: job.messageId
            )
            if AttachmentSummaryBackfillWorker.hasPendingWork(
                context: context,
                excluding: blockedAttachmentSummaryIDs(context: context)
            ) {
                let alreadyEnqueued = (try? JobFetch.active(context: context))?.contains {
                    $0.type == .summarizeAttachments
                        && ($0.status == .pending || $0.status == .running)
                        && $0.id != job.id
                } ?? false
                if !alreadyEnqueued {
                    try JobQueue().enqueueDeferred(
                        type: .summarizeAttachments,
                        priority: 7,
                        nextAttemptAt: Date().addingTimeInterval(2.0),
                        context: context
                    )
                }
            }
            return PipelineResult(success: true, itemsProcessed: outcome.attachmentsVisited)

        case .customCategoryDefinition:
            // Definition generation needs the local generative engine; when
            // the compute budget excludes Qwen work, complete as a no-op —
            // `ensurePipelineJobsExist` reseeds the job while
            // threshold-reaching collecting categories remain.
            guard resourceDecision.modelComputeBudget.allows(.qwenInterpretation) else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            let worker = CustomCategoryDefinitionWorker(engine: engine)
            let outcome = try await worker.run(context: context)
            return PipelineResult(success: true, itemsProcessed: outcome.categoriesActivated)

        case .generateDraftingRules:
            // Drain persisted jobs from the retired rule-distillation lane.
            // Sent-mail learning now feeds measured style and LoRA only.
            return PipelineResult(success: true, itemsProcessed: 0)

        case .distillStyleRegisters:
            // Style discovery measures missing slider axes and describes new
            // styles with the local generative engine; when the compute
            // budget excludes Qwen work, complete as a no-op —
            // `ensurePipelineJobsExist` reseeds while unmeasured or
            // unvisited pairs or undescribed styles remain.
            guard resourceDecision.modelComputeBudget.allows(.qwenInterpretation) else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            guard engine.isModelLoaded else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            let styleWorker = StyleRegisterWorker(
                engine: engine,
                displayLanguageGuard: displayLanguageGuard(context: context, modelAvailable: true),
                readingLanguage: summaryLanguageProvider()
            )
            let styleOutcome = try await styleWorker.run(context: context)
            return PipelineResult(
                success: true,
                itemsProcessed: styleOutcome.stylesCreated
                    + styleOutcome.stylesUpdated
                    + styleOutcome.stylesRetired
                    + styleOutcome.pairsStamped
                    + styleOutcome.descriptionsWritten
            )

        case .accountMemoryRefresh:
            let resourceShouldYield = resourceDecision.shouldPauseAll
                || !resourceDecision.isCatchUpModeActive
                || !resourceDecision.modelComputeBudget.allows(.qwenInterpretation)
            let worker = AccountMemoryRefreshWorker(
                engine: engine,
                messageStoreURL: messageStoreURL,
                shouldYield: { [accountMemoryRefreshYieldProvider] context in
                    resourceShouldYield || accountMemoryRefreshYieldProvider(context)
                },
                pacing: AccountMemoryRefreshWorker.Pacing(
                    maxExtractionsPerInvocation: min(2, resourceDecision.scaledLimit(2)),
                    interExtractionDelayNanoseconds: max(
                        250_000_000,
                        resourceDecision.interMessageDelayNanoseconds
                    ),
                    generationTaskPriority: resourceDecision.backgroundTaskPriority
                ),
                // Dreaming producer for the translation dossiers: style-rule
                // distillation + consolidation over the account's target-language
                // corpus, gated inside the worker by the same yield/budget rules.
                translationDreamer: TranslationMemoryDreamer(
                    engine: engine,
                    vectorStore: vectorStore,
                    generationTaskPriority: resourceDecision.backgroundTaskPriority
                ),
                // Embedding-backed semantic dedup backstop (Task 9): the same
                // embedder the rest of the pipeline uses for message vectors.
                memoryEmbedder: embedder
            )
            let outcome = try await worker.run(
                context: context,
                batchSize: batchSize
            )
            return PipelineResult(
                success: true,
                itemsProcessed: outcome.messagesVisited + outcome.memoriesProjected
            )

        case .translationGlossaryRefresh:
            let outcome = try await TranslationGlossaryRefreshWorker().run(context: context)
            return PipelineResult(success: true, itemsProcessed: outcome.processed)

        case .embed:
            guard !embeddingProviderUnavailable else {
                return PipelineResult(
                    success: true,
                    itemsProcessed: 0,
                    releasedJob: true
                )
            }
            let embeddingBatchLimit = embeddingBatchLimit(resourceDecision: resourceDecision)
            let inlineIndexLimit = hasAnyPlacedVectors()
                ? 0
                : resourceDecision.scaledLimit(performanceProfile.inlineLayoutBurstLimit)
            if let messageID = job.messageId {
                // Per-message embeds serve two lanes with different budget
                // classes. Live arrivals and accepted sent messages are
                // foreground freshness work and may borrow through the
                // foreground throttle. Backlog per-message embeds remain
                // bulk work.
                let requiredClass: ModelWorkClass =
                    try isForegroundFreshnessMessage(messageID: messageID, context: context)
                        ? .bgeLiveFreshness
                        : .bgeBulkEmbedding
                guard resourceDecision.modelComputeBudget.allows(requiredClass) else {
                    // Release, not complete or fail: the scheduler puts the
                    // job back to `.pending` untouched so the backlog resumes
                    // exactly where it paused once the budget re-admits its
                    // class. Mirrors the generic bulk-drain no-op below,
                    // minus losing the per-message row.
                    return PipelineResult(
                        success: true,
                        itemsProcessed: 0,
                        releasedJob: true
                    )
                }
                let count = try await embedSpecificMessage(
                    messageID: messageID,
                    context: context,
                    inlineIndexLimit: liveInlineIndexLimit(resourceDecision: resourceDecision)
                )
                return PipelineResult(success: true, itemsProcessed: count)
            }
            guard resourceDecision.modelComputeBudget.allows(.bgeBulkEmbedding) else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            let count = try await embedPendingMessages(
                context: context,
                batchSize: min(
                    batchSize,
                    embeddingBatchLimit
                ),
                documentBatchSize: embeddingDocumentBatchLimit(resourceDecision: resourceDecision),
                inlineIndexLimit: inlineIndexLimit,
                taskPriority: resourceDecision.backgroundTaskPriority,
                interMessageDelayNanoseconds: resourceDecision.interMessageDelayNanoseconds,
                embeddingLaneLimit: resourceDecision.bge.embeddingLaneLimit
            )
            return PipelineResult(success: true, itemsProcessed: count)

        case .resolveSemanticTags:
            guard let rawObservationID = job.payload,
                  let observationID = UUID(uuidString: rawObservationID) else {
                throw PipelineError.invalidPayload(
                    "resolveSemanticTags job missing observation UUID"
                )
            }
            guard !embeddingProviderUnavailable else {
                return PipelineResult(
                    success: true,
                    itemsProcessed: 0,
                    releasedJob: true
                )
            }
            var observationDescriptor = FetchDescriptor<SemanticTagObservation>(
                predicate: #Predicate { $0.id == observationID }
            )
            observationDescriptor.fetchLimit = 1
            let resolvedMessageID: UUID?
            if let messageID = job.messageId {
                resolvedMessageID = messageID
            } else {
                resolvedMessageID = try context.fetch(observationDescriptor).first?.messageID
            }
            let interpretationMutations = resolvedMessageID.map {
                [PipelineMessageMutation(
                    messageIDs: [$0],
                    facets: [.interpretation]
                )]
            } ?? []
            let outcome = try SemanticTagResolutionWorker(
                context: context,
                resolver: SemanticTagIdentityResolver(embedder: embedder)
            ).run(observationID: observationID)
            switch outcome {
            case .resolved:
                return PipelineResult(
                    success: true,
                    itemsProcessed: 1,
                    messageMutations: interpretationMutations
                )
            case .alreadyResolved:
                return PipelineResult(
                    success: true,
                    itemsProcessed: 0,
                    messageMutations: interpretationMutations
                )
            case .invalidated, .missingObservation:
                return PipelineResult(success: true, itemsProcessed: 0)
            case .pendingEmbedding:
                throw PipelineError.semanticTagResolutionDeferred
            }

        case .index:
            guard allowsVisiblePlacement() else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            guard layoutIndexWorker != nil else {
                // No orchestrator wired in — treat as a successful no-op so
                // the job clears rather than wedging the queue with retries.
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            if let messageID = job.messageId {
                let vectors = try vectorStore.vectorsForMessage(messageId: messageID.uuidString)
                let vectorIds = vectors
                    .filter { $0.layoutX == nil || $0.layoutY == nil || $0.layoutZ == nil }
                    .map(\.vectorId)
                let placed = try await runIndexBatch(vectorIds: vectorIds, context: context)
                if vectorIds.isEmpty, !vectors.isEmpty {
                    // Coordinates may already be durable when message-level
                    // placement was deferred or interrupted. Finish this job's
                    // normal completion without moving the existing vectors.
                    try markMessagesPlaced(for: vectors.map(\.vectorId), context: context)
                }
                return PipelineResult(success: true, itemsProcessed: placed)
            }
            if let payload = job.payload {
                guard let payloadData = payload.data(using: .utf8),
                      let legacyPayload = try? JSONDecoder().decode(IndexPayload.self, from: payloadData) else {
                    throw PipelineError.invalidPayload("index job has invalid vectorId payload")
                }
                let placed = try await runIndexBatch(vectorIds: [legacyPayload.vectorId], context: context)
                return PipelineResult(success: true, itemsProcessed: placed)
            }

            let placed = try await runIndexDrain(
                limit: indexDrainLimit(resourceDecision: resourceDecision),
                context: context
            )
            return PipelineResult(success: true, itemsProcessed: placed)

        case .refine:
            guard allowsVisiblePlacement() else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            // Self-reenqueuing maintenance job. Layout refinement is deferred
            // while Constellation is on screen so persisted node coordinates do
            // not jump underneath the user's current camera. Off-screen ticks
            // still settle the layout so it is pre-warmed when the user returns.
            guard let worker = layoutRefineWorker else {
                // No orchestrator wired — silent no-op (mirrors `.index`).
                // Don't self-reenqueue either; without the worker there's
                // nothing to pace and spinning would just burn tick budget.
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            // `isActive` is @MainActor on the monitor. `run` itself is also
            // @MainActor so this is a plain sync read — the refcount can only
            // be mutated by UI code that's also on MainActor, so no race.
            let active = constellationActiveMonitor?.isActive ?? false
            let iterations = active ? 0 : 5
            if iterations > 0 {
                try await worker.runBurst(iterations: iterations)
            }
            // Self-reenqueue for the next tick with a pacing delay baked in
            // via `nextAttemptAt`. `claimNext` respects the gate the same way
            // it does for backoff after failure.
            let delay = active ? Self.refineActiveDelay : Self.refineIdleDelay
            let nextAt = Date().addingTimeInterval(delay)
            try scheduleNextRefine(nextAttemptAt: nextAt, context: context)
            return PipelineResult(success: true, itemsProcessed: iterations)

        case .frameBurst:
            guard allowsVisiblePlacement() else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            guard let worker = frameBurstWorker else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            guard let payloadData = job.payload?.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(FrameBurstPayload.self, from: payloadData) else {
                throw PipelineError.invalidPayload("frameBurst job missing payload")
            }
            try await worker.run(payload: payload)
            return PipelineResult(success: true, itemsProcessed: payload.iterations)

        case .clusterDetect:
            guard allowsVisiblePlacement() else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            guard let worker = clusterDetectionWorker else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            guard let data = job.payload?.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ClusterDetectPayload.self, from: data) else {
                throw PipelineError.invalidPayload("clusterDetect job missing payload")
            }
            // Meaning is the only frame with a cluster runner.
            guard ClusterDetectSeeder.isRunnable(payload.frame) else {
                throw PipelineError.invalidPayload(
                    "clusterDetect job targets frame \(payload.frame.rawValue), which has no cluster runner"
                )
            }
            let outcome = try await worker.run(
                semanticTargetClusters: ClusterDetectPayload.stableMeaningTargetClusters
            )
            if outcome == .cancelled {
                return PipelineResult(
                    success: true,
                    itemsProcessed: 0,
                    releasedJob: true
                )
            }
            // Meaning is a demand-driven full-corpus snapshot. A completed
            // pass stays installed until a later Meaning-lens demand observes
            // a changed, settled corpus; nothing schedules a periodic refresh.
            return PipelineResult(success: true, itemsProcessed: 1)

        case .entityPromote:
            guard let entityOrchestrator else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            let work = try await entityOrchestrator.promoteEntities(context: context)
            try enqueueEntityWork(work, context: context)
            return PipelineResult(success: true, itemsProcessed: work.count)

        case .entityEmbed:
            guard let entityOrchestrator else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            let entityID = try entityID(from: job, payloadName: "entityEmbed")
            guard let entity = try entity(id: entityID, context: context) else {
                try retireEntityJobs(for: entityID, excluding: job.id, context: context)
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            if try entityOrchestrator.discardAttachmentEntityIfSourceMissing(
                entity,
                context: context
            ) {
                try retireEntityJobs(for: entityID, excluding: job.id, context: context)
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            guard !embeddingProviderUnavailable else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            guard entity.vectorRowId == nil else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            try await entityOrchestrator.embedEntity(entity, context: context)
            try enqueueIndexForEntityIfNeeded(entity, context: context)
            return PipelineResult(success: true, itemsProcessed: 1)

        case .entityRefresh:
            guard let entityOrchestrator else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            let entityID = try entityID(from: job, payloadName: "entityRefresh")
            guard let entity = try entity(id: entityID, context: context) else {
                try retireEntityJobs(for: entityID, excluding: job.id, context: context)
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            if try entityOrchestrator.discardAttachmentEntityIfSourceMissing(
                entity,
                context: context
            ) {
                try retireEntityJobs(for: entityID, excluding: job.id, context: context)
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            try await entityOrchestrator.refreshEntity(entity, context: context)
            try enqueueIndexForEntityIfNeeded(entity, context: context)
            return PipelineResult(success: true, itemsProcessed: 1)

        case .buildTrainingPairs:
            // A pending Train Now explicitly admits preparation, just as it
            // admits optimization. Background preparation still observes the
            // interpretation budget, and all batches yield to interactive work.
            let builder = TrainingPairBuilder(canonicalStore: canonicalStore)
            let manualPreparation = TrainingRunState.current(context: context).forceRunRequested
                && resourceDecision.qwen.allowsUserInitiatedWork
            let modelAllowed = engine.isModelLoaded
                && (manualPreparation || resourceDecision.modelComputeBudget.allows(.qwenInterpretation))
            let finalizedEvidenceCount = try await builder.buildPendingPairs(
                context: context,
                batchSize: batchSize,
                engine: modelAllowed ? engine : nil,
                shouldYield: { [weak self, context] in
                    self?.shouldYieldBackgroundQwenWork(context: context) ?? true
                }
            )
            return PipelineResult(success: true, itemsProcessed: finalizedEvidenceCount)

        case .train:
            guard let payload = job.payload,
                  let runID = UUID(uuidString: payload) else {
                throw PipelineError.invalidPayload("train job requires a corpus run UUID")
            }
            let metrics = try await TrainingOrchestrator(
                engine: engine,
                canonicalStore: canonicalStore,
                checkpointDirectory: checkpointDirectory
            ).runTrainingRun(
                runID: runID,
                context: context,
                publisher: trainingStatusPublisher,
                stepsPerJob: trainingStepsPerJob(resourceDecision: resourceDecision),
                peakLearningRate: TrainingOptimizationPolicy.current.peakLearningRate,
                shouldYield: { [weak self, context] in
                    self?.trainingPreemptionProvider(context)
                }
            )
            return PipelineResult(success: true, itemsProcessed: metrics.stepsCompleted)

        case .generateDraft:
            guard PipelineFeatureFlags.automaticReplyDraftGenerationEnabled else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            // Only runs when a real model is loaded. MapDataProvider falls
            // back to a placeholder entry when no Draft exists for an
            // actionable message.
            guard engine.isModelLoaded else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            let draftOrch = DraftOrchestrator(
                engine: engine,
                vectorStore: vectorStore,
                embedder: embedder,
                canonicalStore: canonicalStore,
                hybridRetriever: hybridRetriever,
                toolRegistry: toolRegistry,
                contextPackStore: generationContextPackStore,
                requiresContextPack: requiresGenerationContextPack,
                modelActivityStatusPublisher: modelActivityStatusPublisher
            )
            let interviewDisplayLanguageGuard = DisplayLanguageGuard(container: context.container, engine: engine)
            let interviewPlanner = ComposerInterviewPlanner(
                engine: engine,
                modelActivityStatusPublisher: modelActivityStatusPublisher,
                displayLanguageGuard: interviewDisplayLanguageGuard
            )
            let interviewRepairer = ComposerInterviewRepairer(
                engine: engine,
                modelActivityStatusPublisher: modelActivityStatusPublisher,
                displayLanguageGuard: interviewDisplayLanguageGuard
            )
            let questionGroundingResolver = QuestionGroundingResolver(
                engine: engine,
                modelActivityStatusPublisher: modelActivityStatusPublisher
            )
            let sourceDependencies = makeReplyPreparationDependencies(container: context.container)
            let generator = DraftGenerationOrchestrator(
                draftOrchestrator: draftOrch,
                interviewPlanner: interviewPlanner,
                interviewRepairer: interviewRepairer,
                questionGroundingResolver: questionGroundingResolver,
                sourceSelector: sourceDependencies.sourceSelector,
                hybridRetriever: hybridRetriever,
                contextPacker: sourceDependencies.contextPacker,
                replySourceCompiler: sourceDependencies.compiler,
                relatedAffinityProvider: sourceDependencies.relatedAffinityProvider,
                webResearchPlanner: sourceDependencies.webResearchPlanner,
                externalResearchProvider: sourceDependencies.externalResearchProvider,
                messagesProvider: messagesTranscriptProvider
            )
            // Drafts are expensive — cap at 3 per tick regardless of batchSize.
            // A Composer-enqueued job carries the selected message's id;
            // the orchestrator services that message first in every pass.
            let count = try await generator.generateDraftsForPendingMessages(
                context: context,
                batchSize: min(batchSize, 3),
                priorityMessageID: job.messageId
            )
            if count > 0 {
                try ComposerDraftSyncScheduler.enqueueIfNeeded(context: context)
            }
            return PipelineResult(success: true, itemsProcessed: count)

        case .categoryLifecycle:
            let engine = CategoryLifecycleEngine()
            let result = try engine.runLifecycle(context: context)
            return PipelineResult(success: true, itemsProcessed: result.promoted + result.deprecated + result.merged)

        case .sendOutbox:
            let worker = OutboxWorker(
                executor: sendExecutor,
                feedbackRecorder: SentTrainingFeedbackRecorder(canonicalStore: canonicalStore),
                glossaryCorrectionRecorder: TranslationGlossaryCorrectionRecorder(),
                canonicalStore: canonicalStore
            )
            try await worker.drain(context: context)
            // itemsProcessed is best-effort; OutboxWorker doesn't surface a
            // count today. Keep 0 and revisit if the scheduler needs it.
            return PipelineResult(success: true, itemsProcessed: 0)

        case .syncComposerDrafts:
            guard let manager = imapSessionManager else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            let worker = ComposerDraftSyncWorker(sessionManager: manager)
            let count = try await worker.drain(context: context)
            return PipelineResult(success: true, itemsProcessed: count)

        case .mailboxMutation:
            // Drain the user-initiated mark-read / delete propagation
            // queue. Same shape as `.sendOutbox`: event-driven, with a
            // periodic safety-net reseed via
            // `BackgroundScheduler.ensurePipelineJobsExist`.
            guard let manager = imapSessionManager else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            let worker = MailboxMutationWorker(
                sessionManager: manager,
                localDeletionCascade: localDeletionCascade
            )
            let messageMutations = try await worker.drain(context: context)
            return PipelineResult(
                success: true,
                itemsProcessed: 0,
                messageMutations: messageMutations
            )

        case .imapBackfill:
            let payload = try decodeIMAPBackfillPayload(from: job)
            if try shouldSkipIMAPJob(
                accountID: payload.accountID,
                context: context
            ) {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            guard let manager = imapSessionManager else {
                throw IMAPError.transient(underlying: IMAPError.notConnected)
            }
            try await IMAPBackfillWorker(sessionManager: manager).run(job: job, context: context)
            return PipelineResult(success: true, itemsProcessed: 0)

        case .imapPollFolder:
            let payload = try decodeIMAPPollPayload(from: job)
            if try shouldSkipIMAPJob(
                accountID: payload.accountID,
                context: context
            ) {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            guard let manager = imapSessionManager else {
                throw IMAPError.transient(underlying: IMAPError.notConnected)
            }
            try await IMAPPollFolderWorker(sessionManager: manager).run(job: job, context: context)
            return PipelineResult(success: true, itemsProcessed: 0)

        case .imapDeletionWatch:
            let payload = try decodeIMAPDeletionWatchPayload(from: job)
            if try shouldSkipIMAPJob(
                accountID: payload.accountID,
                context: context
            ) {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            guard let manager = imapSessionManager else {
                throw IMAPError.transient(underlying: IMAPError.notConnected)
            }
            try await IMAPDeletionWatchWorker(sessionManager: manager).run(
                job: job,
                context: context
            )
            return PipelineResult(success: true, itemsProcessed: 0)

        case .withheldAutoDelete:
            let accountID = try WithheldAutoDeleteWorker.decodePayload(from: job).accountID
            if try shouldSkipIMAPJob(accountID: accountID, context: context) {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            guard let manager = imapSessionManager else {
                throw IMAPError.transient(underlying: IMAPError.notConnected)
            }
            let deleted = try await WithheldAutoDeleteWorker(sessionManager: manager).run(
                job: job,
                context: context
            )
            return PipelineResult(success: true, itemsProcessed: deleted)

        case .pendingDeletionReaper:
            let deletedMessageIDs: [UUID]
            if let worker = pendingDeletionReaperWorker {
                deletedMessageIDs = try await worker.runOnce()
            } else if let manager = imapSessionManager {
                deletedMessageIDs = try await manager.runPendingDeletionReaper()
            } else {
                deletedMessageIDs = []
            }
            let messageMutations = deletedMessageIDs.isEmpty
                ? []
                : [PipelineMessageMutation(
                    messageIDs: deletedMessageIDs,
                    facets: [.visibility]
                )]
            return PipelineResult(
                success: true,
                itemsProcessed: deletedMessageIDs.count,
                messageMutations: messageMutations
            )

        case .reconcileVectorIndex:
            guard let vectorIndex else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            let stats = try VectorIndexReconciler.reconcile(store: vectorStore, index: vectorIndex)
            if stats.added > 0 || stats.removed > 0 {
                print("[Pipeline] vector index reconcile: scanned=\(stats.scanned) added=\(stats.added) removed=\(stats.removed)")
            }
            try JobQueue().enqueueDeferred(
                type: .reconcileVectorIndex,
                priority: 9,
                nextAttemptAt: Date().addingTimeInterval(Self.vectorIndexReconcileInterval),
                context: context
            )
            return PipelineResult(success: true, itemsProcessed: stats.added + stats.removed)

        case .extractAttachments:
            let worker = AttachmentExtractionWorker(
                canonicalStore: canonicalStore,
                vectorStore: vectorStore,
                messageStoreURL: messageStoreURL
            )
            let outcome = try await worker.runOnce(
                context: context,
                messageIDFromJob: job.messageId
            )
            // Re-enqueue if more pending work remains. Worker batches per tick
            // so the scheduler can interleave other priorities; the next tick
            // will drain the next batch.
            if AttachmentExtractionWorker.hasPendingWork(context: context) {
                let queue = JobQueue()
                let alreadyEnqueued = (try? JobFetch.active(context: context))?.contains {
                    $0.type == .extractAttachments
                        && ($0.status == .pending || $0.status == .running)
                        && $0.id != job.id
                } ?? false
                if !alreadyEnqueued {
                    try queue.enqueueDeferred(
                        type: .extractAttachments,
                        priority: 6,
                        nextAttemptAt: Date().addingTimeInterval(1.0),
                        context: context
                    )
                }
            }
            return PipelineResult(success: true, itemsProcessed: outcome.messagesProcessed)

        case .extractVisualAttachments:
            let worker = VisualAttachmentExtractionWorker(
                canonicalStore: canonicalStore,
                vectorStore: vectorStore,
                displayLanguageGuard: displayLanguageGuard(context: context, modelAvailable: true),
                targetLanguage: summaryLanguageProvider()
            )
            let outcome = try await worker.runOnce(
                context: context,
                messageIDFromJob: job.messageId
            )
            if VisualAttachmentExtractionWorker.hasPendingWork(context: context) {
                let queue = JobQueue()
                let alreadyEnqueued = (try? JobFetch.active(context: context))?.contains {
                    $0.type == .extractVisualAttachments
                        && ($0.status == .pending || $0.status == .running)
                        && $0.id != job.id
                } ?? false
                if !alreadyEnqueued {
                    try queue.enqueueDeferred(
                        type: .extractVisualAttachments,
                        priority: 6,
                        nextAttemptAt: Date().addingTimeInterval(1.0),
                        context: context
                    )
                }
            }
            return PipelineResult(success: true, itemsProcessed: outcome.messagesProcessed)

        case .extractCaptureMetadata:
            let language = summaryLanguageProvider().identifier
            let worker = CaptureMetadataWorker(languageIdentifier: { language })
            let outcome = try await worker.runOnce(context: context, messageID: job.messageId)
            if CaptureMetadataWorker.hasPendingWork(context: context, languageIdentifier: language) {
                let alreadyEnqueued = (try? JobFetch.active(context: context))?.contains {
                    $0.type == .extractCaptureMetadata
                        && ($0.status == .pending || $0.status == .running)
                        && $0.id != job.id
                } ?? false
                if !alreadyEnqueued {
                    try JobQueue().enqueueDeferred(
                        type: .extractCaptureMetadata,
                        priority: 6,
                        nextAttemptAt: Date().addingTimeInterval(1.0),
                        context: context
                    )
                }
            }
            return PipelineResult(success: true, itemsProcessed: outcome.attachmentsVisited)

        case .reindexEmbeddings:
            guard !embeddingProviderUnavailable else {
                return PipelineResult(success: true, itemsProcessed: 0)
            }
            let currentVersion = embedderRegistry.current.embeddingVersion
            let staleIds = try vectorStore.distinctMessageIds(
                whereVersionNot: currentVersion,
                limit: max(1, min(batchSize, 25))
            )
            guard !staleIds.isEmpty else {
                print("[Pipeline] reindexEmbeddings: nothing to do")
                return PipelineResult(success: true, itemsProcessed: 0)
            }

            let stats = try await migrationCoordinator.migrateBatchFull(
                messageIds: staleIds,
                orchestrator: embeddingOrchestrator,
                context: context
            )
            print("[Pipeline] reindex: migrated=\(stats.migrated) skipped=\(stats.skipped)")

            let remaining = try vectorStore.distinctMessageIds(
                whereVersionNot: currentVersion,
                limit: 1
            )
            if !remaining.isEmpty {
                try JobQueue().enqueueDeferred(
                    type: .reindexEmbeddings,
                    priority: 9,
                    nextAttemptAt: Date().addingTimeInterval(Self.embeddingReindexInterval),
                    context: context
                )
            }
            return PipelineResult(success: true, itemsProcessed: stats.migrated)
        }
    }

    @MainActor
    public func runIndexBatch(vectorIds: [Int64], context: ModelContext? = nil) async throws -> Int {
        guard allowsVisiblePlacement() else { return 0 }
        guard let worker = layoutIndexWorker else { return 0 }
        let eligibleVectorIds = try placementEligibleVectorIds(
            from: vectorIds,
            context: context
        )
        guard !eligibleVectorIds.isEmpty else { return 0 }
        let placed = try await worker.process(vectorIds: eligibleVectorIds)
        if placed > 0, let context {
            try markMessagesPlaced(for: eligibleVectorIds, context: context)
        }
        return placed
    }

    @MainActor
    public func runIndexDrain(limit: Int, context: ModelContext? = nil) async throws -> Int {
        guard allowsVisiblePlacement() else { return 0 }
        guard layoutIndexWorker != nil else { return 0 }
        let vectorIds = try vectorStore.unplacedVectorIds(limit: max(1, limit))
        guard !vectorIds.isEmpty else { return 0 }
        return try await runIndexBatch(vectorIds: vectorIds, context: context)
    }

    @MainActor
    private func placementEligibleVectorIds(
        from vectorIds: [Int64],
        context: ModelContext?
    ) throws -> [Int64] {
        guard let context, !vectorIds.isEmpty else { return vectorIds }
        let messageIdsByVector = try vectorStore.messageIds(for: vectorIds)
        var eligibilityByMessageID: [String: Bool] = [:]

        for rawMessageID in Set(messageIdsByVector.values) {
            guard let messageID = UUID(uuidString: rawMessageID) else {
                eligibilityByMessageID[rawMessageID] = true
                continue
            }
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { message in
                    message.id == messageID
                }
            )
            descriptor.fetchLimit = 1
            let message = try context.fetch(descriptor).first
            eligibilityByMessageID[rawMessageID] = message?.blocksFirstPresentationForReplyPreparation() != true
        }

        return vectorIds.filter { vectorID in
            guard let rawMessageID = messageIdsByVector[vectorID] else { return true }
            return eligibilityByMessageID[rawMessageID] != false
        }
    }

    @MainActor
    private func markMessagesPlaced(for vectorIds: [Int64], context: ModelContext) throws {
        let messageIds = Set(try vectorStore.messageIds(for: vectorIds).values)
        guard !messageIds.isEmpty else { return }
        let placedAt = Date()
        var changed = false
        for messageId in messageIds {
            guard let uuid = UUID(uuidString: messageId) else { continue }
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { message in
                    message.id == uuid
                }
            )
            descriptor.fetchLimit = 1
            guard let message = try context.fetch(descriptor).first else { continue }
            if message.placedAt == nil,
               message.blocksFirstPresentationForReplyPreparation() == false {
                message.placedAt = placedAt
                changed = true
            }
        }
        if changed {
            try context.save()
        }
    }

    private func indexDrainLimit(resourceDecision: ResourceDecision) -> Int {
        if isConstellationForegroundThrottled(resourceDecision) {
            return max(1, performanceProfile.inlineLayoutBurstLimit)
        }
        let scaledHigh = Int(
            (Double(performanceProfile.highIndexBurstLimit) * resourceDecision.indexBurstMultiplier)
                .rounded(.down)
        )
        if resourceDecision.indexBurstMultiplier < 1.0 {
            return max(1, scaledHigh)
        }
        return max(performanceProfile.steadyIndexJobsPerTick, scaledHigh)
    }

    /// Per-tick cap for the seeded-batch interpretation path. Qwen inference is
    /// model-heavy, so keeping the per-tick limit small lets the scheduler
    /// interleave with higher-priority work and respect catch-up / thermal
    /// throttling.
    private func summarizeBatchLimit(resourceDecision: ResourceDecision) -> Int {
        let protectedReasons: Set<ResourceThrottleReason> = [
            .memoryWarning,
            .memoryCritical,
            .thermalSerious,
            .thermalCritical,
            .notOnACPower,
            .lowPowerMode
        ]
        if resourceDecision.modelComputeBudget.allows(.qwenInterpretation),
           protectedReasons.isDisjoint(with: Set(resourceDecision.throttleReasons)) {
            return Self.summarizeBatchCap
        }
        return max(1, resourceDecision.scaledLimit(Self.summarizeBatchCap))
    }

    /// A cooperative training claim returns to the scheduler after one
    /// optimizer target so foreground demand can preempt between short jobs.
    /// Full-speed training retains the established ten-target slice.
    private func trainingStepsPerJob(resourceDecision: ResourceDecision) -> Int {
        resourceDecision.qwen.modelMode == .throttled ? 1 : 10
    }

    @MainActor
    private func processFreshIngestBatch(
        context: ModelContext,
        batchSize: Int,
        resourceDecision: ResourceDecision
    ) async throws {
        guard resourceDecision.bge.allowsModelHeavyWork,
              resourceDecision.modelComputeBudget.allows(.bgeBulkEmbedding),
              !embeddingProviderUnavailable else {
            return
        }
        _ = try await embedPendingMessages(
            context: context,
            batchSize: min(
                batchSize,
                embeddingBatchLimit(resourceDecision: resourceDecision)
            ),
            documentBatchSize: embeddingDocumentBatchLimit(resourceDecision: resourceDecision),
            inlineIndexLimit: resourceDecision.scaledLimit(performanceProfile.inlineLayoutBurstLimit),
            taskPriority: resourceDecision.backgroundTaskPriority,
            interMessageDelayNanoseconds: resourceDecision.interMessageDelayNanoseconds,
            embeddingLaneLimit: resourceDecision.bge.embeddingLaneLimit
        )
    }

    @MainActor
    private func processLiveInboundFreshnessBatch(
        context: ModelContext,
        batchSize: Int,
        resourceDecision: ResourceDecision
    ) async throws {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.liveDetectedAt != nil && !message.isSentByUser
            }
        )
        let messages = try context.fetch(descriptor)
            .filter { $0.embeddingStatus != .completed }
            .sorted(by: Message.newestPipelineFirst)
            .prefix(max(1, batchSize))
        guard !messages.isEmpty else { return }

        for message in messages {
            guard resourceDecision.bge.allowsModelHeavyWork,
                  resourceDecision.modelComputeBudget.allows(.bgeLiveFreshness),
                  !embeddingProviderUnavailable,
                  message.embeddingStatus != .completed else {
                continue
            }
            _ = try await embedSpecificMessage(
                messageID: message.id,
                context: context,
                inlineIndexLimit: liveInlineIndexLimit(resourceDecision: resourceDecision)
            )
        }
    }

    @MainActor
    func runEmbeddingCatchUpDrain(
        context: ModelContext,
        resourceDecision: ResourceDecision
    ) async throws -> Int {
        guard resourceDecision.isCatchUpModeActive, !embeddingProviderUnavailable else {
            return 0
        }

        let deadline = Date().addingTimeInterval(performanceProfile.catchUpEmbedDrainSeconds)
        var total = 0
        repeat {
            if try LiveInboundPipelinePrioritizer.hasPendingLiveEmbed(context: context) {
                break
            }
            let count = try await embedPendingMessages(
                context: context,
                batchSize: embeddingBatchLimit(resourceDecision: resourceDecision),
                documentBatchSize: embeddingDocumentBatchLimit(resourceDecision: resourceDecision),
                inlineIndexLimit: 0,
                taskPriority: resourceDecision.backgroundTaskPriority,
                interMessageDelayNanoseconds: 0,
                embeddingLaneLimit: resourceDecision.bge.embeddingLaneLimit
            )
            guard count > 0 else { break }
            total += count
            await Task.yield()
            if try LiveInboundPipelinePrioritizer.hasPendingLiveEmbed(context: context) {
                break
            }
        } while !Task.isCancelled && Date() < deadline
        return total
    }

    @MainActor
    private func embedPendingMessages(
        context: ModelContext,
        batchSize: Int,
        documentBatchSize: Int,
        inlineIndexLimit: Int = 0,
        taskPriority: TaskPriority = .utility,
        interMessageDelayNanoseconds: UInt64 = 0,
        embeddingLaneLimit: Int = 1
    ) async throws -> Int {
        // Capture an id watermark before the embed pass. This avoids the old
        // pre/post `allVectorsRaw()` snapshots, which decoded every vector blob
        // on MainActor and made Ohia's own UI hitch as the corpus grew.
        let preMaxVectorId = try vectorStore.maxVectorId()
        let count = try await embeddingOrchestrator.embedPendingMessages(
            context: context,
            batchSize: batchSize,
            documentBatchSize: documentBatchSize,
            taskPriority: taskPriority,
            interMessageDelayNanoseconds: interMessageDelayNanoseconds,
            embeddingLaneLimit: embeddingLaneLimit,
            shouldYield: {
                (try? LiveInboundPipelinePrioritizer.hasPendingLiveEmbed(
                    context: context
                )) == true
            }
        )

        try await finishPostEmbeddingWork(
            after: preMaxVectorId,
            inlineIndexLimit: inlineIndexLimit,
            context: context
        )
        return count
    }

    @MainActor
    private func embedSpecificMessage(
        messageID: UUID,
        context: ModelContext,
        inlineIndexLimit: Int
    ) async throws -> Int {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.id == messageID
            }
        )
        descriptor.fetchLimit = 1
        guard let message = try context.fetch(descriptor).first else { return 0 }
        guard message.embeddingStatus != .completed else { return 0 }

        let preMaxVectorId = try vectorStore.maxVectorId()
        try await embeddingOrchestrator.embedMessage(message, context: context)
        try await finishPostEmbeddingWork(
            after: preMaxVectorId,
            inlineIndexLimit: inlineIndexLimit,
            context: context
        )
        return message.embeddingStatus == .completed ? 1 : 0
    }

    @MainActor
    private func finishPostEmbeddingWork(
        after preMaxVectorId: Int64,
        inlineIndexLimit: Int,
        context: ModelContext
    ) async throws {
        // Seed one drain-style `.index` job for newly-inserted vectors so
        // the constellation layout stays incrementally up to date without
        // ballooning the SwiftData queue to one row per vector. No-op when
        // no layout orchestrator was provided (test rigs, Metal-unavailable
        // machines).
        if layoutIndexWorker != nil, allowsVisiblePlacement() {
            let newUnplacedIDs = try vectorStore.unplacedVectorIds(after: preMaxVectorId)
            let inlineIDs = Array(newUnplacedIDs.prefix(max(0, inlineIndexLimit)))
            let inlineIDSet = Set(inlineIDs)
            if !inlineIDs.isEmpty {
                _ = try await runIndexBatch(vectorIds: inlineIDs, context: context)
            }
            if newUnplacedIDs.contains(where: { !inlineIDSet.contains($0) }) {
                try enqueueIndexDrainIfMissing(context: context)
            }
        }
        if entityOrchestrator != nil, allowsVisiblePlacement() {
            try enqueueEntityPromoteIfMissing(context: context)
        }
    }

    private func hasAnyPlacedVectors() -> Bool {
        ((try? vectorStore.vectorsWithLayout(filter: nil, limit: 1))?.isEmpty == false)
    }

    @MainActor
    private func scheduleNextRefine(nextAttemptAt: Date, context: ModelContext) throws {
        let activeRefineJobs = try JobFetch.jobs(
            type: .refine,
            statuses: [.pending, .running],
            context: context
        )
        let pending = activeRefineJobs.filter { $0.status == .pending }
        if let survivor = pending.min(by: { lhs, rhs in
            (lhs.nextAttemptAt ?? .distantPast) < (rhs.nextAttemptAt ?? .distantPast)
        }) {
            var changed = false
            if survivor.priority != 9 {
                survivor.priority = 9
                changed = true
            }
            if survivor.nextAttemptAt != nextAttemptAt {
                survivor.nextAttemptAt = nextAttemptAt
                changed = true
            }
            for job in pending where job !== survivor {
                context.delete(job)
                changed = true
            }
            if changed {
                try context.save()
            }
            return
        }

        try JobQueue().enqueueDeferred(
            type: .refine,
            priority: 9,
            payload: nil,
            nextAttemptAt: nextAttemptAt,
            context: context
        )
    }

    private func embeddingBatchLimit(resourceDecision: ResourceDecision) -> Int {
        if isConstellationForegroundThrottled(resourceDecision) {
            return 1
        }
        let base = resourceDecision.isCatchUpModeActive
            ? performanceProfile.catchUpEmbeddingJobBatchLimit
            : performanceProfile.embeddingJobBatchLimit
        return resourceDecision.scaledLimit(base)
    }

    private func embeddingDocumentBatchLimit(resourceDecision: ResourceDecision) -> Int {
        if isConstellationForegroundThrottled(resourceDecision) {
            return 1
        }
        let base = resourceDecision.isCatchUpModeActive
            ? performanceProfile.catchUpEmbeddingDocumentBatchLimit
            : performanceProfile.embeddingDocumentBatchLimit
        return resourceDecision.scaledLimit(base)
    }

    private func liveInlineIndexLimit(resourceDecision: ResourceDecision) -> Int {
        if isConstellationForegroundThrottled(resourceDecision) {
            return 1
        }
        return max(1, resourceDecision.scaledLimit(performanceProfile.inlineLayoutBurstLimit))
    }

    private func isConstellationForegroundThrottled(_ resourceDecision: ResourceDecision) -> Bool {
        resourceDecision.throttleReasons.contains(.constellationActive)
    }

    private var embeddingProviderUnavailable: Bool {
        if embedder is UnavailableEmbedder { return true }
        if let swappable = embedder as? SwappableEmbedder {
            return swappable.isUsingUnavailableProvider
        }
        return false
    }

    @MainActor
    private func enqueueEntityPromoteIfMissing(context: ModelContext) throws {
        let jobs = try context.fetch(FetchDescriptor<Job>())
        let alreadyActive = jobs.contains {
            $0.type == .entityPromote && ($0.status == .pending || $0.status == .running)
        }
        guard !alreadyActive else { return }
        try JobQueue().enqueue(type: .entityPromote, priority: 7, context: context)
    }

    @MainActor
    private func enqueueEntityWork(_ work: EntityPromotionWork, context: ModelContext) throws {
        try retireEntityJobsWithMissingEntities(context: context)
        guard !work.isEmpty else { return }
        let activeJobs = try context.fetch(FetchDescriptor<Job>()).filter {
            ($0.type == .entityEmbed || $0.type == .entityRefresh)
                && ($0.status == .pending || $0.status == .running || $0.status == .failed)
        }
        let decoder = JSONDecoder()
        var activePairs = Set<String>()
        for job in activeJobs {
            guard let data = job.payload?.data(using: .utf8),
                  let payload = try? decoder.decode(EntityIdPayload.self, from: data) else { continue }
            activePairs.insert("\(job.type.rawValue):\(payload.entityId.uuidString)")
        }

        let queue = JobQueue()
        let encoder = JSONEncoder()
        for entityId in work.embedIds {
            let key = "\(JobType.entityEmbed.rawValue):\(entityId.uuidString)"
            guard !activePairs.contains(key) else { continue }
            try enqueueEntityJob(
                type: .entityEmbed,
                entityId: entityId,
                priority: 7,
                queue: queue,
                encoder: encoder,
                context: context
            )
            activePairs.insert(key)
        }
        for entityId in work.refreshIds {
            let key = "\(JobType.entityRefresh.rawValue):\(entityId.uuidString)"
            guard !activePairs.contains(key) else { continue }
            try enqueueEntityJob(
                type: .entityRefresh,
                entityId: entityId,
                priority: 7,
                queue: queue,
                encoder: encoder,
                context: context
            )
            activePairs.insert(key)
        }
    }

    @MainActor
    private func interpretQueuedMessage(
        job: Job,
        context: ModelContext,
        batchLimit: Int
    ) async throws -> [PipelineMessageMutation] {
        if let messageID = job.messageId {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.id == messageID }
            )
            descriptor.fetchLimit = 1
            guard let message = try context.fetch(descriptor).first else {
                return []
            }
            if Self.hasCompleteInterpretation(message) {
                guard Self.needsStableBodySummary(message),
                      let mutation = try await summarizeOneQueuedMessage(
                          messageID: messageID,
                          context: context
                      ) else {
                    return []
                }
                return [mutation]
            }
            guard let mutation = try await interpretOneMessage(
                messageID: messageID,
                job: job,
                sourcePriority: job.priority,
                context: context
            ) else {
                return []
            }
            return [mutation]
        }

        // Batch mode: drain a small backlog of pending structured mail
        // interpretations. The JobType remains `.summarize` because that lane
        // already owns Qwen mail interpretation. Historical rows get rich body
        // summaries only after the rest of the ingestion/indexing pipeline has
        // caught up; live arrivals still get a hover summary below.
        let selection = try claimablePendingInterpretationMessageIDs(
            limit: batchLimit,
            context: context
        )
        let pendingIDs = selection.messageIDs
        if pendingIDs.isEmpty == false {
            var messageMutations: [PipelineMessageMutation] = []
            for id in pendingIDs {
                if shouldYieldBackgroundQwenWork(context: context) {
                    break
                }
                do {
                    let mutation = try await withReportedMessageAccount(
                        id,
                        on: job,
                        context: context
                    ) {
                        try await interpretOneMessage(
                            messageID: id,
                            job: nil,
                            sourcePriority: job.priority,
                            context: context
                        )
                    }
                    if let mutation {
                        messageMutations.append(mutation)
                    }
                } catch let error as PipelineError {
                    pipelineLogger.warning(
                        "Interpretation batch skipped messageID=\(id.uuidString, privacy: .public) errorKind=\(String(reflecting: type(of: error)), privacy: .public)"
                    )
                }
            }
            return messageMutations
        }

        if job.messageId == nil, let nextRetryAt = selection.nextRetryAt {
            job.nextAttemptAt = nextRetryAt
            return []
        }

        return try await summarizeQueuedMessages(
            job: job,
            context: context,
            batchLimit: batchLimit
        )
    }

    /// A generic summarize job is a reusable drain signal, but the Activity
    /// Strip needs the account of the exact message it is processing. Publish
    /// that account through the otherwise-unused generic-drain payload while
    /// leaving `messageId` nil so retry selection still sees a generic drain.
    @MainActor
    private func withReportedMessageAccount<T>(
        _ messageID: UUID,
        on job: Job,
        context: ModelContext,
        operation: () async throws -> T
    ) async throws -> T {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.id == messageID
            }
        )
        descriptor.fetchLimit = 1
        guard let message = try context.fetch(descriptor).first,
              let accountID = message.accountID ?? message.account?.id else {
            return try await operation()
        }

        job.payload = accountID.uuidString
        do {
            try context.save()
        } catch {
            job.payload = nil
            throw error
        }

        do {
            let result = try await operation()
            job.payload = nil
            try context.save()
            return result
        } catch {
            let operationError = error
            job.payload = nil
            try context.save()
            throw operationError
        }
    }

    @MainActor
    private func interpretOneMessage(
        messageID: UUID,
        job: Job?,
        sourcePriority: Int,
        context: ModelContext
    ) async throws -> PipelineMessageMutation? {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.id == messageID
            }
        )
        descriptor.fetchLimit = 1
        guard let message = try context.fetch(descriptor).first else {
            return nil
        }
        if Self.hasCompleteInterpretation(message) {
            guard Self.needsAutomaticForegroundHoverSummary(message),
                  let knownInterpretation = Self.knownInterpretation(from: message) else {
                return nil
            }
            let bodyText = await Self.loadSummaryBodyText(path: message.bodyTextPath) ?? ""
            let senderName = Self.displaySender(for: message)
            let subject = message.subject
            guard try await generateHoverSummary(
                for: message,
                bodyText: bodyText,
                senderName: senderName,
                subject: subject,
                knownInterpretation: knownInterpretation,
                context: context
            ) else {
                return nil
            }
            return PipelineMessageMutation(
                messageIDs: [messageID],
                facets: [.summary]
            )
        }

        let bodyText = await Self.loadSummaryBodyText(path: message.bodyTextPath) ?? ""
        let senderName = Self.displaySender(for: message)
        let subject = message.subject
        let interpretationContext = await automaticInterpretationContext(
            for: message,
            context: context
        )
        guard Self.hasQueuedInterpretationSourceEvidence(
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            context: interpretationContext
        ) else {
            return nil
        }
        guard engine.isModelLoaded else {
            throw PipelineError.summaryUnavailable(
                "queued interpretation could not be generated for \(messageID) engineIsModelLoaded=false"
            )
        }

        if !message.isLiveInboundTriageEligible {
            let metadata: InterpretationMetadataResult
            switch await generateQwenInterpretationMetadata(
                activity: Self.activityEvent("Datafying", message: message),
                messageID: messageID,
                bodyText: bodyText,
                senderName: senderName,
                subject: subject,
                context: interpretationContext
            ) {
            case .success(let generated):
                metadata = await generated.finalizingDisplayLanguage(
                    using: displayLanguageGuard(context: context, modelAvailable: true),
                    targetLanguage: summaryLanguageProvider(),
                    source: Self.displayLanguageSource(for: message, subject: subject, bodyText: bodyText)
                )
            case .parseFailure:
                let persistedFallback = try handleInterpretationMetadataParseFailure(
                    message: message,
                    job: job,
                    sourcePriority: sourcePriority,
                    bodyText: bodyText,
                    senderName: senderName,
                    subject: subject,
                    context: context
                )
                if persistedFallback {
                    return PipelineMessageMutation(
                        messageIDs: [messageID],
                        facets: [.interpretation]
                    )
                }
                throw PipelineError.summaryUnavailable(
                    "queued metadata interpretation could not be parsed for \(messageID) engineIsModelLoaded=\(engine.isModelLoaded)"
                )
            case .transientFailure:
                throw PipelineError.summaryUnavailable(
                    "queued metadata interpretation could not be generated for \(messageID) engineIsModelLoaded=\(engine.isModelLoaded)"
                )
            }

            guard try MessageSummaryWriter.persistInterpretationMetadata(
                messageID: messageID,
                result: metadata,
                interpretedAt: Date(),
                context: context
            ) else {
                return nil
            }
            do {
                try completeFailedInterpretationRetries(for: messageID, context: context)
            } catch {
                pipelineLogger.warning(
                    "Interpretation retry cleanup deferred messageID=\(messageID.uuidString, privacy: .public) error=\(String(reflecting: type(of: error)), privacy: .public)"
                )
            }
            if message.embeddingStatus != .completed {
                do {
                    try seedImmediateEmbedAfterInterpretation(messageID: messageID, context: context)
                } catch {
                    pipelineLogger.warning(
                        "Post-interpretation embed seed deferred messageID=\(messageID.uuidString, privacy: .public) error=\(String(reflecting: type(of: error)), privacy: .public)"
                    )
                }
            }
            var facets: Set<PipelineMessageFacet> = [.interpretation]
            if Self.needsAutomaticForegroundHoverSummary(message),
               let knownInterpretation = Self.knownInterpretation(from: message) {
                do {
                    if try await generateHoverSummary(
                        for: message,
                        bodyText: bodyText,
                        senderName: senderName,
                        subject: subject,
                        knownInterpretation: knownInterpretation,
                        context: context
                    ) {
                        facets.insert(.summary)
                    }
                } catch {
                    pipelineLogger.warning(
                        "Post-interpretation hover summary deferred messageID=\(messageID.uuidString, privacy: .public) error=\(String(reflecting: type(of: error)), privacy: .public)"
                    )
                }
            }
            return PipelineMessageMutation(messageIDs: [messageID], facets: facets)
        }

        let result: InterpretationResult
        switch await generateQwenInterpretation(
            activity: Self.activityEvent("Datafying", message: message),
            messageID: messageID,
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            context: interpretationContext
        ) {
        case .success(let generated):
            result = await generated.finalizingDisplayLanguage(
                using: displayLanguageGuard(context: context, modelAvailable: true),
                targetLanguage: summaryLanguageProvider(),
                source: Self.displayLanguageSource(for: message, subject: subject, bodyText: bodyText)
            )
        case .parseFailure:
            let persistedFallback = try handleInterpretationParseFailure(
                message: message,
                job: job,
                sourcePriority: sourcePriority,
                bodyText: bodyText,
                senderName: senderName,
                subject: subject,
                context: context
            )
            if persistedFallback {
                return PipelineMessageMutation(
                    messageIDs: [messageID],
                    facets: [.interpretation]
                )
            }
            throw PipelineError.summaryUnavailable(
                "queued interpretation could not be parsed for \(messageID) engineIsModelLoaded=\(engine.isModelLoaded)"
            )
        case .transientFailure:
            throw PipelineError.summaryUnavailable(
                "queued interpretation could not be generated for \(messageID) engineIsModelLoaded=\(engine.isModelLoaded)"
            )
        }

        guard try MessageSummaryWriter.persistInterpretation(
            messageID: messageID,
            result: result,
            interpretedAt: Date(),
            context: context
        ) else {
            return nil
        }
        do {
            try completeFailedInterpretationRetries(for: messageID, context: context)
        } catch {
            pipelineLogger.warning(
                "Interpretation retry cleanup deferred messageID=\(messageID.uuidString, privacy: .public) error=\(String(reflecting: type(of: error)), privacy: .public)"
            )
        }
        let ignored: Bool
        do {
            ignored = try MailingListIgnoreRuleService(
                context: context,
                jobQueue: JobQueue(),
                localDeletionCascade: localDeletionCascade
            )
                .applyIgnoreIfNeeded(to: message)
        } catch {
            ignored = false
            pipelineLogger.warning(
                "Post-interpretation ignore check deferred messageID=\(messageID.uuidString, privacy: .public) error=\(String(reflecting: type(of: error)), privacy: .public)"
            )
        }
        if ignored {
            return PipelineMessageMutation(
                messageIDs: [messageID],
                facets: [.interpretation, .visibility]
            )
        }
        guard let classification = MailClassificationJSON.decode(
            message.analysis?.mailClassificationJSON
        ) else {
            pipelineLogger.warning(
                "Post-interpretation summary deferred because classification is incomplete messageID=\(messageID.uuidString, privacy: .public)"
            )
            return PipelineMessageMutation(
                messageIDs: [messageID],
                facets: [.interpretation]
            )
        }
        let knownInterpretation = SummaryKnownInterpretation(
            classification: classification,
            triageVerdict: result.triageVerdict.enforcingBinaryObligation(),
            customCategoryKeys: result.customCategoryKeys
        )
        if message.embeddingStatus != .completed {
            do {
                try seedImmediateEmbedAfterInterpretation(messageID: messageID, context: context)
            } catch {
                pipelineLogger.warning(
                    "Post-interpretation embed seed deferred messageID=\(messageID.uuidString, privacy: .public) error=\(String(reflecting: type(of: error)), privacy: .public)"
                )
            }
        }
        var facets: Set<PipelineMessageFacet> = [.interpretation]
        if Self.needsAutomaticForegroundHoverSummary(message) {
            do {
                if try await generateHoverSummary(
                    for: message,
                    bodyText: bodyText,
                    senderName: senderName,
                    subject: subject,
                    knownInterpretation: knownInterpretation,
                    context: context
                ) {
                    facets.insert(.summary)
                }
            } catch {
                pipelineLogger.warning(
                    "Post-interpretation hover summary deferred messageID=\(messageID.uuidString, privacy: .public) error=\(String(reflecting: type(of: error)), privacy: .public)"
                )
            }
        }
        return PipelineMessageMutation(messageIDs: [messageID], facets: facets)
    }

    @MainActor
    private func handleInterpretationParseFailure(
        message: Message,
        job: Job?,
        sourcePriority: Int,
        bodyText: String,
        senderName: String,
        subject: String,
        context: ModelContext
    ) throws -> Bool {
        let failureMessage = "queued interpretation parse failed"
        let messageID = message.id
        let retryJob = try interpretationRetryJob(for: messageID, context: context)
        let existingRetryCount = job?.retryCount ?? retryJob?.retryCount ?? 0
        let failedAttemptCount = existingRetryCount + 1

        guard failedAttemptCount >= Self.interpretationFallbackRetryLimit else {
            if job == nil {
                try scheduleInterpretationParseRetry(
                    messageID: messageID,
                    retryJob: retryJob,
                    failedAttemptCount: failedAttemptCount,
                    priority: interpretationRetryPriority(for: message, sourcePriority: sourcePriority),
                    error: failureMessage,
                    context: context
                )
            }
            pipelineLogger.warning(
                "Interpretation parse failed messageID=\(messageID.uuidString, privacy: .public) retryCount=\(failedAttemptCount, privacy: .public)"
            )
            return false
        }

        // Retries are spent. Some inputs never parse — an output that overruns
        // the token budget truncates mid-structure every single time — so
        // retrying again only re-spends a multi-second generation on a certain
        // failure while the message stays unclassified and invisible. Persist
        // the conservative interpretation instead: `.empty` model candidates
        // let the deterministic resolver classify from delivery facts alone,
        // and the zero-confidence verdict claims nothing the model never
        // established. The message becomes visible, and the retry lane is
        // closed for good.
        let persistedFallback = try persistTerminalInterpretationFallback(
            message: message,
            retryJob: retryJob,
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            error: failureMessage,
            context: context
        )

        pipelineLogger.error(
            "Interpretation parse retries exhausted; persisted conservative fallback messageID=\(messageID.uuidString, privacy: .public) retryCount=\(failedAttemptCount, privacy: .public)"
        )
        return persistedFallback
    }

    @MainActor
    private func handleInterpretationMetadataParseFailure(
        message: Message,
        job: Job?,
        sourcePriority: Int,
        bodyText: String,
        senderName: String,
        subject: String,
        context: ModelContext
    ) throws -> Bool {
        let failureMessage = "queued metadata interpretation parse failed"
        let messageID = message.id
        let retryJob = try interpretationRetryJob(for: messageID, context: context)
        let existingRetryCount = job?.retryCount ?? retryJob?.retryCount ?? 0
        let failedAttemptCount = existingRetryCount + 1

        guard failedAttemptCount >= Self.interpretationFallbackRetryLimit else {
            if job == nil {
                try scheduleInterpretationParseRetry(
                    messageID: messageID,
                    retryJob: retryJob,
                    failedAttemptCount: failedAttemptCount,
                    priority: interpretationRetryPriority(for: message, sourcePriority: sourcePriority),
                    error: failureMessage,
                    context: context
                )
            }
            pipelineLogger.warning(
                "Metadata interpretation parse failed messageID=\(messageID.uuidString, privacy: .public) retryCount=\(failedAttemptCount, privacy: .public)"
            )
            return false
        }

        // See `handleInterpretationParseFailure`: exhausted retries persist the
        // conservative metadata interpretation rather than looping forever on an
        // input that cannot parse.
        let persistedFallback = try persistTerminalInterpretationMetadataFallback(
            message: message,
            retryJob: retryJob,
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            error: failureMessage,
            context: context
        )

        pipelineLogger.error(
            "Metadata interpretation parse retries exhausted; persisted conservative fallback messageID=\(messageID.uuidString, privacy: .public) retryCount=\(failedAttemptCount, privacy: .public)"
        )
        return persistedFallback
    }

    @MainActor
    private func interpretationRetryJob(for messageID: UUID, context: ModelContext) throws -> Job? {
        try JobFetch.unfinished(context: context)
            .filter { $0.type == .summarize && $0.messageId == messageID }
            .max { lhs, rhs in
                if lhs.retryCount == rhs.retryCount {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.retryCount < rhs.retryCount
            }
    }

    @MainActor
    private func scheduleInterpretationParseRetry(
        messageID: UUID,
        retryJob: Job?,
        failedAttemptCount: Int,
        priority: Int,
        error: String,
        context: ModelContext
    ) throws {
        let job: Job
        if let retryJob {
            job = retryJob
            job.priority = min(job.priority, priority)
        } else {
            job = Job(type: .summarize, priority: priority)
            job.messageId = messageID
            context.insert(job)
        }
        job.status = .pending
        job.startedAt = nil
        job.completedAt = nil
        job.error = error
        job.retryCount = failedAttemptCount
        job.nextAttemptAt = Date().addingTimeInterval(JobQueue.backoffDelay(for: failedAttemptCount))
        try context.save()
    }

    private func interpretationRetryPriority(for message: Message, sourcePriority: Int) -> Int {
        guard message.isLiveInboundTriageEligible else { return sourcePriority }
        return min(sourcePriority, LiveInboundPipelinePrioritizer.liveStagePriority)
    }

    private func markInterpretationRetryCompleted(_ job: Job) {
        job.status = .completed
        job.completedAt = Date()
        job.startedAt = nil
        job.error = nil
        job.nextAttemptAt = nil
        job.retryCount = 0
    }

    @MainActor
    private func completeFailedInterpretationRetries(
        for messageID: UUID,
        context: ModelContext
    ) throws {
        let failed = try JobFetch.jobs(
            type: .summarize,
            statuses: [.failed],
            context: context
        ).filter { $0.messageId == messageID }
        guard failed.isEmpty == false else { return }
        failed.forEach(markInterpretationRetryCompleted)
        try context.save()
    }

    /// Persist the conservative interpretation for a message whose model output
    /// never parses, and close its retry lane.
    ///
    /// Marking the retry job `.completed` is what actually ends the loop.
    /// `claimablePendingInterpretationMessageIDs` re-selects any `.failed`
    /// summarize job once `interpretationTerminalRetryDelay` has elapsed since
    /// its `completedAt`; simply re-stamping `completedAt` on each exhausted
    /// attempt restarted that clock forever, so a message that could never parse
    /// re-spent a full generation every few minutes for the life of the process.
    @MainActor
    private func persistTerminalInterpretationFallback(
        message: Message,
        retryJob: Job?,
        bodyText: String,
        senderName: String,
        subject: String,
        error: String,
        context: ModelContext
    ) throws -> Bool {
        let fallback = MLXSummarizer.conservativeInterpretationFallback(
            bodyText: bodyText,
            senderName: senderName,
            subject: subject
        )
        let persisted = try MessageSummaryWriter.persistInterpretation(
            messageID: message.id,
            result: fallback,
            interpretedAt: Date(),
            context: context
        )
        try closeInterpretationRetryLane(retryJob, error: error, context: context)
        return persisted
    }

    /// Metadata-only counterpart to `persistTerminalInterpretationFallback`, for
    /// messages that are not live-inbound-triage eligible and therefore carry no
    /// triage verdict.
    @MainActor
    private func persistTerminalInterpretationMetadataFallback(
        message: Message,
        retryJob: Job?,
        bodyText: String,
        senderName: String,
        subject: String,
        error: String,
        context: ModelContext
    ) throws -> Bool {
        let fallback = MLXSummarizer.conservativeInterpretationMetadataFallback(
            bodyText: bodyText,
            senderName: senderName,
            subject: subject
        )
        let persisted = try MessageSummaryWriter.persistInterpretationMetadata(
            messageID: message.id,
            result: fallback,
            interpretedAt: Date(),
            context: context
        )
        try closeInterpretationRetryLane(retryJob, error: error, context: context)
        return persisted
    }

    @MainActor
    private func closeInterpretationRetryLane(
        _ retryJob: Job?,
        error: String,
        context: ModelContext
    ) throws {
        if let retryJob {
            markInterpretationRetryCompleted(retryJob)
            // Keep the terminal reason legible in the queue after the job is
            // marked complete; `markInterpretationRetryCompleted` clears it.
            retryJob.error = error
        }
        try context.save()
    }

    @MainActor
    @discardableResult
    private func generateHoverSummary(
        for message: Message,
        bodyText: String,
        senderName: String,
        subject: String,
        knownInterpretation: SummaryKnownInterpretation,
        context: ModelContext
    ) async throws -> Bool {
        guard Self.needsStableBodySummary(message) else { return false }
        let prepared = await automaticSummarizationInputs(
            for: message,
            senderName: senderName,
            subject: subject,
            bodyText: bodyText,
            knownInterpretation: knownInterpretation,
            includeVisualAttachmentSummaries: true,
            context: context
        )
        guard Self.hasQueuedInterpretationSourceEvidence(
            bodyText: prepared.bodyText,
            senderName: prepared.senderName,
            subject: prepared.subject,
            context: prepared.context
        ) else {
            return try await persistConservativeHoverSummary(
                for: message,
                prepared: prepared,
                modelError: nil,
                modelReturnedNil: false,
                modelLoaded: engine.isModelLoaded,
                modelContext: context
            )
        }
        let summaryOutcome = await generateQwenSummaryOnly(
            activity: Self.activityEvent("Summarizing", message: message),
            messageID: message.id,
            prepared: prepared
        )
        let result: SummarizationResult
        switch summaryOutcome {
        case .success(let generated):
            guard let finalized = try withholdingOutsideReadingLanguage(
                await prepared.finalizingDisplayLanguage(
                    of: generated,
                    using: displayLanguageGuard(context: context, modelAvailable: true),
                    messageID: message.id,
                    accountID: message.accountID ?? message.account?.id,
                    sourceLanguageHint: message.languageDetected
                ),
                message: message
            ) else {
                return false
            }
            result = finalized
        case .unusableOutput(let modelReturnedNil, let modelError):
            return try await persistConservativeHoverSummary(
                for: message,
                prepared: prepared,
                modelError: modelError,
                modelReturnedNil: modelReturnedNil,
                modelLoaded: engine.isModelLoaded,
                modelContext: context
            )
        case .transientFailure(let modelError):
            throw PipelineError.summaryUnavailable(
                "hover summary generation failed for \(message.id) engineIsModelLoaded=\(engine.isModelLoaded) error=\(modelError)"
            )
        }
        try Task.checkCancellation()
        bodySummaryRetries.clear(message.id)
        return try MessageSummaryWriter.persist(
            messageID: message.id,
            summaryInputFingerprint: prepared.summaryInputFingerprint,
            result: result,
            summarizedAt: Date(),
            context: context,
            updateInterpretationFromResult: false
        )
    }

    @MainActor
    private func persistConservativeHoverSummary(
        for message: Message,
        prepared: SummarizationTranslationGrounding.PreparedInputs,
        modelError: String?,
        modelReturnedNil: Bool,
        modelLoaded: Bool,
        modelContext: ModelContext
    ) async throws -> Bool {
        let fallback = MLXSummarizer.conservativeSummaryOnlyFallback(
            bodyText: prepared.bodyText,
            senderName: prepared.senderName,
            subject: prepared.subject,
            knownInterpretation: prepared.knownInterpretation!,
            context: prepared.context
        )
        // The fallback quotes body sentences, so source-language clauses
        // are translated whole by the model when it is loaded; otherwise, or
        // when translation fails, the summary is withheld and deferred.
        guard let restoredFallback = try withholdingOutsideReadingLanguage(
            await prepared.finalizingDisplayLanguage(
                of: try prepared.restoringSummaryResult(fallback),
                using: displayLanguageGuard(context: modelContext, modelAvailable: modelLoaded),
                messageID: message.id,
                accountID: message.accountID ?? message.account?.id,
                sourceLanguageHint: message.languageDetected
            ),
            message: message
        ) else {
            return false
        }
        try Task.checkCancellation()
        bodySummaryRetries.clear(message.id)
        let persisted = try MessageSummaryWriter.persist(
            messageID: message.id,
            summaryInputFingerprint: prepared.summaryInputFingerprint,
            result: restoredFallback,
            summarizedAt: Date(),
            context: modelContext,
            updateInterpretationFromResult: false
        )
        if persisted {
            pipelineLogger.error(
                "Hover summary fallback persisted messageID=\(message.id.uuidString, privacy: .public) modelReturnedNil=\(modelReturnedNil, privacy: .public) modelLoaded=\(modelLoaded, privacy: .public) hadError=\(modelError != nil, privacy: .public)"
            )
        }
        return persisted
    }

    @MainActor
    private static func displayLanguageSource(
        for message: Message,
        subject: String,
        bodyText: String
    ) -> DisplayLanguageGuard.Source {
        DisplayLanguageGuard.Source(
            languageHint: message.languageDetected,
            context: "\(subject)\n\(bodyText.prefix(1_200))",
            messageID: message.id,
            accountID: message.accountID ?? message.account?.id
        )
    }

    /// Residue pass for background-generated display text. Without a loaded
    /// model it falls back to glossary lookups and romanization of names and
    /// terms; a source-language passage is then left untranslated.
    @MainActor
    private func displayLanguageGuard(context: ModelContext, modelAvailable: Bool) -> DisplayLanguageGuard {
        DisplayLanguageGuard(
            container: context.container,
            engine: modelAvailable && engine.isModelLoaded ? engine : nil
        )
    }

    /// The summary to persist, or nil when it is withheld outside the reading
    /// language. A translation the model answered but that was missing or
    /// rejected defers the message; a pass that never reached an answer (the
    /// model unloaded or generation was cancelled, as memory handoffs do) is a
    /// transient failure the lane retries on its next drain instead.
    @MainActor
    private func withholdingOutsideReadingLanguage(
        _ finalized: SummarizationTranslationGrounding.PreparedInputs.FinalizedSummary,
        message: Message
    ) throws -> SummarizationResult? {
        switch finalized {
        case .displayable(let result):
            return result
        case .withheld(transient: true):
            try Task.checkCancellation()
            throw PipelineError.summaryUnavailable(
                "hover summary display-language pass did not run for \(message.id) engineIsModelLoaded=\(engine.isModelLoaded)"
            )
        case .withheld(transient: false):
            deferBodySummaryForReadingLanguage(message)
            return nil
        }
    }

    /// Withholds a body summary that could not be written in the reading
    /// language and schedules the message's next background attempt, if any
    /// remain.
    @MainActor
    private func deferBodySummaryForReadingLanguage(_ message: Message) {
        let now = retryClock()
        let readingLanguage = summaryLanguageProvider()
        let retryAt = bodySummaryRetries.recordFailure(
            message.id,
            readingLanguage: readingLanguage.identifier,
            inputMarker: Self.bodySummaryInputMarker(message),
            now: now
        )
        let failures = bodySummaryRetries.failures(of: message.id, readingLanguage: readingLanguage.identifier)
        if let retryAt {
            pipelineLogger.notice(
                "Body summary withheld outside the reading language messageID=\(message.id.uuidString, privacy: .public) failures=\(failures, privacy: .public) retryInSeconds=\(Int(retryAt.timeIntervalSince(now)), privacy: .public)"
            )
        } else {
            pipelineLogger.notice(
                "Body summary withheld outside the reading language; background retries spent messageID=\(message.id.uuidString, privacy: .public) failures=\(failures, privacy: .public)"
            )
        }
    }

    /// What a message's background summary was generated from, read from row
    /// fields alone so the backlog probe stays cheap: when the message was
    /// last interpreted (new attachment or visual evidence re-interprets it),
    /// and its attachments' capture metadata (which arrives without touching
    /// the interpretation). Either changing lifts a deferral; the reading
    /// language is already part of the entry.
    @MainActor
    static func bodySummaryInputMarker(_ message: Message) -> String {
        let interpretedAt = message.analysis?.interpretedAt?.timeIntervalSinceReferenceDate ?? 0
        var hash: UInt64 = 0xcbf29ce484222325
        for attachment in message.attachments.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            for byte in (attachment.captureMetadataJSON ?? "").utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            hash ^= 0x1f
            hash = hash &* 0x100000001b3
        }
        return "\(interpretedAt)|\(String(format: "%016llx", hash))"
    }

    /// Messages the body-summary lane must not select now: waiting out a
    /// reading-language retry, or with every retry spent, on unchanged input.
    @MainActor
    private func blockedBodySummaryMessageIDs(context: ModelContext) -> Set<UUID> {
        let readingLanguage = summaryLanguageProvider()
        let tracked = Array(bodySummaryRetries.trackedIDs(readingLanguage: readingLanguage.identifier))
        guard tracked.isEmpty == false else { return [] }
        let messages = (try? context.fetch(FetchDescriptor<Message>(
            predicate: #Predicate<Message> { tracked.contains($0.id) }
        ))) ?? []
        let markers = Dictionary(
            messages.map { ($0.id, Self.bodySummaryInputMarker($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        return bodySummaryRetries.blocked(
            readingLanguage: readingLanguage.identifier,
            now: retryClock(),
            inputMarker: { markers[$0] }
        )
    }

    /// Attachments the attachment-summary lane must not select now, by the
    /// same rule.
    @MainActor
    func blockedAttachmentSummaryIDs(context: ModelContext) -> Set<UUID> {
        AttachmentSummaryBackfillWorker.blockedByReadingLanguage(
            attachmentSummaryRetries,
            readingLanguage: summaryLanguageProvider().identifier,
            now: retryClock(),
            context: context
        )
    }

    /// Whether the body-summary backlog holds a message the lane may
    /// summarize now. The scheduler consults this before seeding a drain or
    /// holding back work behind the backlog; messages waiting out a
    /// reading-language retry, or with their retries spent, do not count. Any
    /// `blocked.count + 1` pending rows include one that is not blocked, so
    /// the probe reads that many unsorted rows and never scans the backlog.
    @MainActor
    func hasUndeferredBodySummaryWork(context: ModelContext) throws -> Bool {
        let blocked = blockedBodySummaryMessageIDs(context: context)
        guard blocked.isEmpty == false else { return true }
        return try Self.pendingBodySummaryMessageIDs(
            limit: blocked.count + 1,
            newestFirst: false,
            context: context,
            storeURL: messageStoreURL
        ).contains { blocked.contains($0) == false }
    }

    @MainActor
    private func summarizeQueuedMessages(
        job: Job,
        context: ModelContext,
        batchLimit: Int
    ) async throws -> [PipelineMessageMutation] {
        // Over-fetch by the blocked count so messages waiting out, or done
        // with, reading-language retries cannot crowd fresh work out of the
        // batch.
        let blocked = blockedBodySummaryMessageIDs(context: context)
        let candidates = try Self.pendingBodySummaryMessageIDs(
            limit: batchLimit + blocked.count,
            context: context,
            storeURL: messageStoreURL
        ).filter { blocked.contains($0) == false }
        let pendingIDs = try claimablePendingSummarizeMessageIDs(
            Array(candidates.prefix(batchLimit)),
            context: context
        )
        guard !pendingIDs.isEmpty else { return [] }

        var messageMutations: [PipelineMessageMutation] = []
        for id in pendingIDs {
            if shouldYieldBackgroundQwenWork(context: context) {
                break
            }
            do {
                let mutation = try await withReportedMessageAccount(
                    id,
                    on: job,
                    context: context
                ) {
                    try await summarizeOneQueuedMessage(
                        messageID: id,
                        context: context
                    )
                }
                if let mutation {
                    messageMutations.append(mutation)
                }
            } catch let error as PipelineError {
                pipelineLogger.warning(
                    "Body summary batch skipped messageID=\(id.uuidString, privacy: .public) errorKind=\(String(reflecting: type(of: error)), privacy: .public)"
                )
            }
        }
        return messageMutations
    }

    /// Background interpretation and summary batches yield between atomic
    /// generations as soon as a user-requested Composer job appears. The
    /// scheduler can then claim the Composer job without discarding partial
    /// model output or inflating retry counts.
    @MainActor
    private func shouldYieldBackgroundQwenWork(context: ModelContext) -> Bool {
        if interactiveQwenGenerationProvider() {
            return true
        }
        if (try? LiveInboundPipelinePrioritizer.hasPendingForegroundInterpretation(
            context: context
        )) == true {
            return true
        }
        let now = Date()
        let pendingComposerJobs = (try? JobFetch.jobs(
            type: .generateDraft,
            statuses: [.pending],
            context: context,
            sort: true
        )) ?? []
        let runnable = pendingComposerJobs.filter { job in
            job.priority <= ComposerDraftScheduling.userInitiatedPriority
                && (job.nextAttemptAt ?? .distantPast) <= now
        }
        guard !runnable.isEmpty else { return false }
        if runnable.contains(where: { $0.messageId != nil }) {
            return true
        }
        return DraftGenerationOrchestrator.hasPendingComposeWork(
            context: context,
            now: now
        )
    }

    @MainActor
    private func summarizeOneQueuedMessage(
        messageID: UUID,
        context: ModelContext
    ) async throws -> PipelineMessageMutation? {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.id == messageID
            }
        )
        descriptor.fetchLimit = 1
        guard let message = try context.fetch(descriptor).first,
              Self.hasCompleteInterpretation(message),
              let knownInterpretation = Self.knownInterpretation(from: message)
        else {
            return nil
        }

        let bodyText = await Self.loadSummaryBodyText(path: message.bodyTextPath) ?? ""
        let senderName = Self.displaySender(for: message)
        let subject = message.subject
        guard try await generateHoverSummary(
            for: message,
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            knownInterpretation: knownInterpretation,
            context: context
        ) else {
            return nil
        }
        return PipelineMessageMutation(
            messageIDs: [messageID],
            facets: [.summary]
        )
    }

    /// The foreground/backlog discriminator for per-message model work.
    /// Incoming live arrivals carry `liveDetectedAt`; accepted outgoing mail
    /// is identified by `isSentByUser` without borrowing the inbound-arrival
    /// presentation marker.
    @MainActor
    private func isForegroundFreshnessMessage(
        messageID: UUID,
        context: ModelContext
    ) throws -> Bool {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.id == messageID
            }
        )
        descriptor.fetchLimit = 1
        guard let message = try context.fetch(descriptor).first else {
            return false
        }
        return message.liveDetectedAt != nil || message.isSentByUser
    }

    @MainActor
    private func seedImmediateEmbedAfterInterpretation(messageID: UUID, context: ModelContext) throws {
        let priority = hasAnyPlacedVectors()
            ? Self.interpretationEmbedPriority
            : Self.firstLightInterpretationEmbedPriority
        let jobs = try JobFetch.unfinished(context: context)
        if jobs.contains(where: {
            $0.type == .embed && $0.messageId == messageID && $0.status == .running
        }) {
            return
        }
        if let job = jobs.first(where: {
            $0.type == .embed
                && $0.messageId == messageID
                && ($0.status == .pending || $0.status == .failed)
        }) {
            job.status = .pending
            job.priority = min(job.priority, priority)
            job.nextAttemptAt = nil
            job.error = nil
        } else {
            let job = Job(type: .embed, priority: priority)
            job.messageId = messageID
            context.insert(job)
        }
        try context.save()
    }

    @MainActor
    private static func pendingInterpretationMessageIDs(
        limit: Int,
        context: ModelContext,
        storeURL: URL?
    ) throws -> [UUID] {
        if let storeURL,
           let ids = try MessageStoreHotPath.pendingSummaryMessageIDs(limit: limit, storeURL: storeURL) {
            return ids
        }
        let messages = try context.fetch(FetchDescriptor<Message>())
            .filter { message in
                guard let analysis = message.analysis else { return true }
                return !Self.hasCompleteInterpretation(message, analysis: analysis)
            }
            .sorted(by: Message.newestPipelineFirst)
        return Array(messages.prefix(limit).map(\.id))
    }

    @MainActor
    private static func pendingBodySummaryMessageIDs(
        limit: Int,
        newestFirst: Bool = true,
        context: ModelContext,
        storeURL: URL?
    ) throws -> [UUID] {
        if let storeURL,
           let ids = try MessageStoreHotPath.pendingBodySummaryMessageIDs(
               limit: limit,
               newestFirst: newestFirst,
               storeURL: storeURL
           ) {
            return ids
        }
        let pending = try context.fetch(FetchDescriptor<Message>())
            .filter { message in
                guard Self.hasCompleteInterpretation(message) else { return false }
                return message.analysis?.bodySummary?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty != false
            }
        let messages = newestFirst ? pending.sorted(by: Message.newestPipelineFirst) : pending
        return Array(messages.prefix(limit).map(\.id))
    }

    @MainActor
    private func claimablePendingInterpretationMessageIDs(
        limit: Int,
        context: ModelContext
    ) throws -> InterpretationBatchSelection {
        guard limit > 0 else {
            return InterpretationBatchSelection(messageIDs: [], nextRetryAt: nil)
        }
        let now = Date()
        let jobs = try JobFetch.jobs(
            type: .summarize,
            statuses: [.pending, .running, .failed],
            context: context
        )
        var activeMessageIDs: Set<UUID> = []
        var failedJobsByMessageID: [UUID: [Job]] = [:]
        for job in jobs where job.type == .summarize {
            guard let messageID = job.messageId else { continue }
            if job.status == .pending || job.status == .running {
                activeMessageIDs.insert(messageID)
            } else if job.status == .failed {
                failedJobsByMessageID[messageID, default: []].append(job)
            }
        }

        // Failed messages may be older than an arbitrarily large fresh
        // backlog, so they cannot be discovered through a capped newest-first
        // candidate query. Resolve this small exceptional set directly.
        var latestFailureByMessageID: [UUID: Date] = [:]
        var clearedStaleFailure = false
        for (messageID, failedJobs) in failedJobsByMessageID {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { message in
                    message.id == messageID
                }
            )
            descriptor.fetchLimit = 1
            guard let message = try context.fetch(descriptor).first,
                  Self.hasCompleteInterpretation(message) == false else {
                failedJobs.forEach(markInterpretationRetryCompleted)
                clearedStaleFailure = true
                continue
            }
            latestFailureByMessageID[messageID] = failedJobs
                .map { $0.completedAt ?? .distantPast }
                .max() ?? .distantPast
        }
        if clearedStaleFailure {
            try context.save()
        }

        // Pull enough newest-first rows that removing every message already
        // represented by a job still leaves a complete fresh-work batch.
        // Retried rows come from the direct failure lookup above, so their
        // ordering remains independent of message recency and backlog depth.
        let representedMessageIDs = activeMessageIDs.union(latestFailureByMessageID.keys)
        let candidates = try Self.pendingInterpretationMessageIDs(
            limit: limit + representedMessageIDs.count,
            context: context,
            storeURL: messageStoreURL
        )
        let fresh = candidates.filter { representedMessageIDs.contains($0) == false }
        let retries = latestFailureByMessageID
            .filter { messageID, failedAt in
                activeMessageIDs.contains(messageID) == false
                    && now.timeIntervalSince(failedAt) >= Self.interpretationTerminalRetryDelay
            }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key.uuidString < rhs.key.uuidString
                }
                return lhs.value < rhs.value
            }
            .map(\.key)

        let selected: [UUID]
        if fresh.isEmpty {
            selected = Array(retries.prefix(limit))
        } else if retries.isEmpty {
            selected = Array(fresh.prefix(limit))
        } else if limit == 1 {
            // Protected resource modes reduce the batch to one. Alternate that
            // single slot so a continuing fresh stream cannot postpone retries,
            // while a permanently malformed retry cannot block fresh mail.
            selected = [singleSlotInterpretationRetryTurn ? retries[0] : fresh[0]]
            singleSlotInterpretationRetryTurn.toggle()
        } else {
            // Normal interpretation batches are capped at three. Reserve one
            // slot for the oldest eligible retry so neither fresh work nor a
            // population of previously failed messages can starve the other.
            var fairBatch = Array(fresh.prefix(limit - 1))
            fairBatch.append(retries[0])
            if fairBatch.count < limit {
                fairBatch.append(contentsOf: fresh.dropFirst(limit - 1).prefix(limit - fairBatch.count))
            }
            if fairBatch.count < limit {
                fairBatch.append(contentsOf: retries.dropFirst().prefix(limit - fairBatch.count))
            }
            selected = fairBatch
        }

        let nextRetryAt = latestFailureByMessageID
            .filter { messageID, failedAt in
                activeMessageIDs.contains(messageID) == false
                    && now.timeIntervalSince(failedAt) < Self.interpretationTerminalRetryDelay
            }
            .map { $0.value.addingTimeInterval(Self.interpretationTerminalRetryDelay) }
            .min()
        return InterpretationBatchSelection(messageIDs: selected, nextRetryAt: nextRetryAt)
    }

    @MainActor
    private func claimablePendingSummarizeMessageIDs(
        _ ids: [UUID],
        context: ModelContext
    ) throws -> [UUID] {
        guard ids.isEmpty == false else { return [] }
        let idSet = Set(ids)
        let blocked = Set(try JobFetch.active(context: context).compactMap { job -> UUID? in
            guard job.type == .summarize,
                  let messageID = job.messageId,
                  idSet.contains(messageID) else {
                return nil
            }
            return messageID
        })
        guard blocked.isEmpty == false else { return ids }
        return ids.filter { blocked.contains($0) == false }
    }

    private static func hasValidTriageVerdictJSON(_ value: String?) -> Bool {
        TriageVerdictJSON.hasRequiredBooleanFields(value)
    }

    private static func hasCompleteInterpretation(_ message: Message) -> Bool {
        hasCompleteInterpretation(message, analysis: message.analysis)
    }

    private static func needsAutomaticForegroundHoverSummary(_ message: Message) -> Bool {
        guard message.liveDetectedAt != nil || message.isSentByUser,
              message.bodyTextPath != nil else {
            return false
        }
        return needsHoverSummary(message)
    }

    private static func needsHoverSummary(_ message: Message) -> Bool {
        SummaryTextSanitizer.cleaned(message.analysis?.bodySummary ?? "") == nil
    }

    private static func needsStableBodySummary(_ message: Message) -> Bool {
        if needsHoverSummary(message) {
            return true
        }
        guard let fingerprint = message.analysis?.bodySummaryInputFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return true
        }
        return fingerprint.isEmpty
    }

    private static func hasCompleteInterpretation(_ message: Message, analysis: MessageAnalysis?) -> Bool {
        guard MailClassificationJSON.isComplete(analysis?.mailClassificationJSON) else {
            return false
        }
        guard message.isLiveInboundTriageEligible else {
            return true
        }
        return hasValidTriageVerdictJSON(analysis?.triageVerdictJSON)
    }

    private static func knownInterpretation(from message: Message) -> SummaryKnownInterpretation? {
        let analysis = message.analysis
        let customCategoryKeys = Set(CustomCategoryKeysJSON.decode(analysis?.customCategoryKeysJSON))
        guard let classification = MailClassificationJSON.decode(analysis?.mailClassificationJSON) else {
            return nil
        }
        if !message.isLiveInboundTriageEligible {
            let verdict = TriageVerdict(
                isActionable: false,
                requiresConfirmation: false,
                confidence: 0.0,
                extractionVersion: "historical-metadata-only"
            )
            return SummaryKnownInterpretation(
                classification: classification,
                triageVerdict: verdict,
                customCategoryKeys: customCategoryKeys
            )
        }
        guard let json = analysis?.triageVerdictJSON,
              let data = json.data(using: .utf8),
              let verdict = try? JSONDecoder().decode(TriageVerdict.self, from: data) else {
            return nil
        }
        return SummaryKnownInterpretation(
            classification: classification,
            // Enforce the binary obligation invariant so the prompt context
            // never shows both actionNeeded and confirm for pre-change rows
            // whose stored JSON is still both-true.
            triageVerdict: verdict.enforcingBinaryObligation(),
            customCategoryKeys: customCategoryKeys
        )
    }

    private static func hasQueuedInterpretationSourceEvidence(
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?
    ) -> Bool {
        bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || context?.hasSummarizableAnchorEvidence == true
    }

    private func logInterpretationGenerationFailure(
        messageID: UUID,
        error: any Error
    ) {
        let errorType = String(reflecting: type(of: error))
        pipelineLogger.error(
            "Interpretation generation failed engineArm=MLX messageID=\(messageID.uuidString, privacy: .public) errorKind=\(errorType, privacy: .public)"
        )
    }

    private func generateQwenInterpretation(
        activity: SessionActivityEvent,
        messageID: UUID,
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?
    ) async -> InterpretationGenerationOutcome {
        SessionActivityLog.shared.record(activity)
        do {
            if let result = try await MLXInterpreter(engine: engine).interpret(
                bodyText: bodyText,
                senderName: senderName,
                subject: subject,
                context: context
            ) {
                SessionActivityLog.shared.record(activity.ending(.finished))
                return .success(result)
            }
            let engineModelLoaded = engine.isModelLoaded
            pipelineLogger.warning(
                "Interpretation MLX returned nil messageID=\(messageID.uuidString, privacy: .public) engineModelLoaded=\(engineModelLoaded, privacy: .public)"
            )
            SessionActivityLog.shared.record(activity.ending(.failed, detail: "The model returned no usable interpretation"))
            return .parseFailure
        } catch {
            SessionActivityLog.shared.record(activity.ending(error is CancellationError ? .cancelled : .failed, detail: error.localizedDescription))
            logInterpretationGenerationFailure(
                messageID: messageID,
                error: error
            )
            return .transientFailure
        }
    }

    private func generateQwenInterpretationMetadata(
        activity: SessionActivityEvent,
        messageID: UUID,
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext?
    ) async -> InterpretationMetadataGenerationOutcome {
        SessionActivityLog.shared.record(activity)
        do {
            if let result = try await MLXInterpreter(engine: engine).interpretMetadata(
                bodyText: bodyText,
                senderName: senderName,
                subject: subject,
                context: context
            ) {
                SessionActivityLog.shared.record(activity.ending(.finished))
                return .success(result)
            }
            let engineModelLoaded = engine.isModelLoaded
            pipelineLogger.warning(
                "Metadata interpretation MLX returned nil messageID=\(messageID.uuidString, privacy: .public) engineModelLoaded=\(engineModelLoaded, privacy: .public)"
            )
            SessionActivityLog.shared.record(activity.ending(.failed, detail: "The model returned no usable interpretation"))
            return .parseFailure
        } catch {
            SessionActivityLog.shared.record(activity.ending(error is CancellationError ? .cancelled : .failed, detail: error.localizedDescription))
            logInterpretationGenerationFailure(
                messageID: messageID,
                error: error
            )
            return .transientFailure
        }
    }

    private enum SummaryOnlyGenerationOutcome {
        case success(SummarizationResult)
        case unusableOutput(modelReturnedNil: Bool, error: String?)
        case transientFailure(error: String)
    }

    private func generateQwenSummaryOnly(
        activity: SessionActivityEvent,
        messageID: UUID,
        prepared: SummarizationTranslationGrounding.PreparedInputs
    ) async -> SummaryOnlyGenerationOutcome {
        SessionActivityLog.shared.record(activity)
        do {
            if let result = try await MLXSummarizer(engine: engine).summarizeOnly(
                bodyText: prepared.bodyText,
                senderName: prepared.senderName,
                subject: prepared.subject,
                knownInterpretation: prepared.knownInterpretation!,
                context: prepared.context
            ) {
                let restored = try prepared.restoringSummaryResult(result)
                SessionActivityLog.shared.record(activity.ending(.finished))
                return .success(restored)
            }
            let engineModelLoaded = engine.isModelLoaded
            pipelineLogger.warning(
                "Hover summary MLX returned nil messageID=\(messageID.uuidString, privacy: .public) engineModelLoaded=\(engineModelLoaded, privacy: .public)"
            )
            SessionActivityLog.shared.record(activity.ending(.failed, detail: "The model returned no usable summary"))
            return .unusableOutput(modelReturnedNil: true, error: nil)
        } catch {
            SessionActivityLog.shared.record(activity.ending(error is CancellationError ? .cancelled : .failed, detail: error.localizedDescription))
            let errorType = String(reflecting: type(of: error))
            let errorDescription = String(describing: error)
            pipelineLogger.error(
                "Hover summary generation failed engineArm=MLX messageID=\(messageID.uuidString, privacy: .public) errorKind=\(errorType, privacy: .public)"
            )
            return .transientFailure(error: "\(errorType): \(errorDescription)")
        }
    }

    @MainActor
    private func automaticInterpretationContext(
        for message: Message,
        context: ModelContext
    ) async -> SummarizationContext? {
        let interpretationContext = SummarizationContext(
            analysisSignals: Self.summarizationSignals(from: message),
            messageEvidenceDigest: await Self.messageEvidenceDigest(for: message),
            visualAttachmentSummaries: await Self.visualAttachmentSummaries(for: message),
            textAttachmentEvidence: await Self.textAttachmentEvidence(for: message),
            userIdentity: Self.summarizationUserIdentity(for: message, context: context),
            anchorDirection: message.isSentByUser ? .outgoing : .incoming,
            anchorRecipients: Self.summaryRecipients(for: message),
            correspondenceExcludingListID: MessageSummaryWriter.interpretationListExclusionID(
                for: message,
                context: context
            ),
            summaryTargetLanguage: summaryLanguageProvider(),
            customCategories: CustomMailCategoryCatalog.activeDescriptors(in: context)
        )
        return interpretationContext.isEmpty ? nil : interpretationContext
    }

    @MainActor
    private func automaticSummarizationInputs(
        for message: Message,
        senderName: String,
        subject: String,
        bodyText: String,
        knownInterpretation: SummaryKnownInterpretation,
        includeVisualAttachmentSummaries: Bool,
        context: ModelContext
    ) async -> SummarizationTranslationGrounding.PreparedInputs {
        let messageId = message.id.uuidString
        let analysisSignals = Self.summarizationSignals(from: message)

        let anchorVectors = await Task.detached(priority: .utility) { [vectorStore] in
            (try? vectorStore.vectorsForMessage(messageId: messageId)) ?? []
        }.value

        let retrievalQuery = Self.summaryRetrievalQuery(
            senderName: senderName,
            subject: subject,
            bodyText: bodyText
        )
        let retrieved: [RetrievalResult] = await Task.detached(priority: .utility) { [hybridRetriever] () -> [RetrievalResult] in
            guard let hybridRetriever else { return [] }
            return (try? hybridRetriever.retrieve(
                query: retrievalQuery,
                filter: FilterSpec(collections: [.context]),
                k: 8
            )) ?? []
        }.value

        var seenMessageIds = Set<String>()
        var connectedResults: [RetrievalResult] = []
        for result in retrieved {
            let otherMessageId = result.record.messageId
            guard otherMessageId != messageId,
                  seenMessageIds.insert(otherMessageId).inserted else {
                continue
            }
            connectedResults.append(result)
            if connectedResults.count == 4 { break }
        }

        var connectedItems: [SummarizationContext.ConnectedItem] = []
        for result in connectedResults {
            guard let otherID = UUID(uuidString: result.record.messageId),
                  let other = try? Self.fetchMessage(id: otherID, context: context) else {
                continue
            }
            connectedItems.append(SummarizationContext.ConnectedItem(
                senderName: Self.displaySender(for: other),
                subject: other.subject.isEmpty ? "(no subject)" : other.subject,
                excerpt: result.record.textPayload,
                similarity: result.score,
                direction: other.isSentByUser ? .outgoing : .incoming,
                recipients: Self.summaryRecipients(for: other)
            ))
        }

        let vectorShape = Self.summaryVectorShape(
            anchorVectors: anchorVectors,
            neighborCount: connectedItems.count
        )
        let satelliteEvidence = anchorVectors
            .prefix(5)
            .map { record in
                SummarizationContext.SatelliteEvidence(
                    kind: Self.summarySatelliteKind(for: record),
                    text: record.textPayload
                )
            }
        let visualAttachmentSummaries = includeVisualAttachmentSummaries
            ? await Self.visualAttachmentSummaries(for: message)
            : []
        let textAttachmentEvidence = await Self.textAttachmentEvidence(for: message)
        let userIdentity = Self.summarizationUserIdentity(for: message, context: context)

        let summaryContext = SummarizationContext(
            vectorShape: vectorShape,
            analysisSignals: analysisSignals,
            connectedItems: connectedItems,
            satelliteEvidence: satelliteEvidence,
            messageEvidenceDigest: await Self.messageEvidenceDigest(for: message, bodyText: bodyText),
            visualAttachmentSummaries: visualAttachmentSummaries,
            textAttachmentEvidence: textAttachmentEvidence,
            userIdentity: userIdentity,
            anchorDirection: message.isSentByUser ? .outgoing : .incoming,
            anchorRecipients: Self.summaryRecipients(for: message),
            customCategories: CustomMailCategoryCatalog.activeDescriptors(in: context)
        )
        return SummarizationTranslationGrounding.applying(
            to: summaryContext.isEmpty ? nil : summaryContext,
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            knownInterpretation: knownInterpretation,
            sourceLanguageCode: message.languageDetected,
            accountID: message.accountID ?? message.account?.id,
            targetLanguage: summaryLanguageProvider(),
            provider: TranslationGlossaryProvider(container: context.container)
        )
    }

    private static func appleSummarizationFallbackEnabled() -> Bool {
        OhiaSharedDefaults.store.object(forKey: "summarizationUseAppleIntelligence") as? Bool ?? true
    }

    @MainActor
    private static func visualAttachmentSummaries(for message: Message) async -> [SummarizationContext.VisualAttachmentSummary] {
        let entries = message.attachments
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
            .compactMap { attachment -> (summary: SummarizationContext.VisualAttachmentSummary, hasVisual: Bool)? in
                let visual = attachment.visualExtractionStatus == VisualAttachmentExtractionStatus.completed.rawValue
                    ? attachment.visualSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil
                let capture = AttachmentCaptureMetadata.decode(attachment.captureMetadataJSON)
                // Short recorded time/place first, then the visual description,
                // then captions: the summarizer clips each entry, so the
                // optional captions are what a tight budget drops.
                let summary = [capture?.summaryLead, visual, capture?.summaryCaptions]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                guard summary.isEmpty == false else { return nil }
                return (
                    SummarizationContext.VisualAttachmentSummary(filename: attachment.filename, summary: summary),
                    visual?.isEmpty == false
                )
            }
        // Attachments with a visual description outrank metadata-only ones
        // (Mail Drop videos, undescribed photos) for the limited slots.
        return (entries.filter(\.hasVisual) + entries.filter { !$0.hasVisual })
            .prefix(4)
            .map(\.summary)
    }

    @MainActor
    private static func messageEvidenceDigest(
        for message: Message,
        bodyText providedBodyText: String? = nil
    ) async -> String? {
        let bodyText: String
        if let providedBodyText {
            bodyText = providedBodyText
        } else if let path = message.bodyTextPath,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) {
            bodyText = text
        } else {
            bodyText = ""
        }

        let attachmentPaths = message.attachments.compactMap { attachment -> (id: String, path: String)? in
            guard let path = attachment.extractedTextPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                return nil
            }
            return (attachment.id.uuidString, path)
        }
        let fallbackTextByAttachmentId: [String: String] = await Task.detached(priority: .utility) {
            var values: [String: String] = [:]
            for item in attachmentPaths {
                guard let text = try? String(contentsOfFile: item.path, encoding: .utf8) else {
                    continue
                }
                values[item.id] = text
            }
            return values
        }.value

        return MessageEvidenceBundle
            .build(
                message: message,
                bodyText: bodyText,
                fallbackTextByAttachmentId: fallbackTextByAttachmentId
            )?
            .digest(maxCharacters: 2_400)
    }

    @MainActor
    private static func textAttachmentEvidence(for message: Message) async -> [SummarizationContext.TextAttachmentEvidence] {
        let attachments = message.attachments
            .compactMap { attachment -> (filename: String, path: String)? in
                guard let path = attachment.extractedTextPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !path.isEmpty else {
                    return nil
                }
                return (attachment.filename, path)
            }
            .prefix(4)
            .map { $0 }

        guard !attachments.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            attachments.compactMap { item in
                guard let text = try? String(contentsOfFile: item.path, encoding: .utf8) else {
                    return nil
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return SummarizationContext.TextAttachmentEvidence(
                    filename: item.filename,
                    text: String(trimmed.prefix(2_400))
                )
            }
        }.value
    }

    @MainActor
    private static func fetchMessage(id: UUID, context: ModelContext) throws -> Message? {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.id == id
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func loadSummaryBodyText(path: String?) async -> String? {
        guard let path, !path.isEmpty else { return nil }
        let text = await Task.detached(priority: .utility) {
            try? String(contentsOfFile: path, encoding: .utf8)
        }.value
        guard let text,
              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return text
    }

    private static func displaySender(for message: Message) -> String {
        if let name = message.fromName?.trimmingCharacters(in: .whitespacesAndNewlines),
           name.isEmpty == false {
            return name
        }
        return message.fromAddress
    }

    @MainActor
    private static func summaryRecipients(for message: Message) -> SummarizationContext.AnchorRecipients? {
        let to = message.participants.compactMap { participant -> SummarizationContext.Recipient? in
            guard participant.role == .to,
                  let person = participant.participant else { return nil }
            return SummarizationContext.Recipient(
                displayName: person.displayName,
                address: person.emailAddress
            )
        }
        let cc = message.participants.compactMap { participant -> SummarizationContext.Recipient? in
            guard participant.role == .cc,
                  let person = participant.participant else { return nil }
            return SummarizationContext.Recipient(
                displayName: person.displayName,
                address: person.emailAddress
            )
        }
        let recipients = SummarizationContext.AnchorRecipients(to: to, cc: cc)
        return recipients.isUseful ? recipients : nil
    }

    @MainActor
    private static func summarizationUserIdentity(
        for message: Message,
        context: ModelContext
    ) -> SummarizationUserIdentity? {
        let account: Account?
        if let directAccount = message.account {
            account = directAccount
        } else if let accountID = message.accountID {
            var descriptor = FetchDescriptor<Account>(
                predicate: #Predicate<Account> { account in
                    account.id == accountID
                }
            )
            descriptor.fetchLimit = 1
            account = try? context.fetch(descriptor).first
        } else {
            account = nil
        }

        guard let account else { return nil }
        return summarizationUserIdentity(for: account)
    }

    private static func summarizationUserIdentity(for account: Account) -> SummarizationUserIdentity? {
        let primaryEmail = account.emailAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let candidateNames = [
            account.primaryIdentity?.displayName,
            account.displayName
        ] + account.identities.map(\.displayName)

        let displayName = candidateNames
            .compactMap { Self.personNameCandidate($0, primaryEmail: primaryEmail) }
            .first ?? ""
        let identity = SummarizationUserIdentity(
            displayName: displayName,
            primaryEmailAddress: primaryEmail,
            aliasEmailAddresses: account.identities.map(\.address)
        )
        return identity.isUseful ? identity : nil
    }

    private static func personNameCandidate(_ value: String?, primaryEmail: String) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.lowercased() != primaryEmail,
              !trimmed.contains("@") else {
            return nil
        }
        return trimmed
    }

    private static func summaryRetrievalQuery(
        senderName: String,
        subject: String,
        bodyText: String
    ) -> String {
        let clippedBody = bodyText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(2_000)
        return """
        sender=\(senderName)
        subject=\(subject)
        \(clippedBody)
        """
    }

    private static func summaryVectorShape(
        anchorVectors: [VectorRecord],
        neighborCount: Int
    ) -> SummarizationContext.VectorShape? {
        guard !anchorVectors.isEmpty || neighborCount > 0 else {
            return nil
        }
        var breakdown = MessageVectorCountBreakdown()
        for record in anchorVectors {
            switch record.collection {
            case .context:
                breakdown.context += 1
            case .attachment:
                breakdown.attachment += 1
            case .entity:
                breakdown.entity += 1
            case .style:
                break
            }
        }
        return SummarizationContext.VectorShape(
            contextCount: breakdown.context,
            attachmentCount: breakdown.attachment,
            entityCount: breakdown.entity,
            neighborCount: neighborCount
        )
    }

    private static func summarySatelliteKind(for record: VectorRecord) -> String {
        switch record.collection {
        case .context:
            return "body moon"
        case .attachment:
            return "attachment moon"
        case .entity:
            if let key = record.entityKey?.trimmingCharacters(in: .whitespacesAndNewlines),
               key.isEmpty == false {
                return "entity moon: \(key)"
            }
            return "entity moon"
        case .style:
            return "style"
        }
    }

    private static func summarizationSignals(from message: Message) -> [String] {
        guard let dimensionsJSON = message.analysis?.dimensionsJSON,
              let data = dimensionsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MessageDimensions.self, from: data) else {
            return []
        }
        let dims = message.isLiveInboundTriageEligible
            ? decoded
            : decoded.scrubbingTriageActionState()
        var signals: [String] = []
        signals.append(contentsOf: dims.semanticTags
            .sorted { $0.weightedScore > $1.weightedScore }
            .prefix(3)
            .map { "tag=\($0.displayName)" })

        for deadline in dims.deadlines.prefix(2) {
            let date = deadline.dateString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard date.isEmpty == false else { continue }
            signals.append("deadline=\(date) (\(deadline.type))")
        }

        for task in dims.tasks.prefix(2) {
            let object = task.actionObject?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let object, object.isEmpty == false {
                signals.append("task=\(task.taskType): \(object)")
            } else {
                signals.append("task=\(task.taskType)")
            }
        }

        return signals
    }

    private func decodeIMAPBackfillPayload(from job: Job) throws -> IMAPBackfillWorker.Payload {
        guard let data = job.payload?.data(using: .utf8),
              let payload = try? JSONDecoder().decode(IMAPBackfillWorker.Payload.self, from: data) else {
            throw PipelineError.invalidPayload("imapBackfill job missing payload")
        }
        return payload
    }

    private func decodeIMAPPollPayload(from job: Job) throws -> IMAPPollFolderWorker.Payload {
        guard let data = job.payload?.data(using: .utf8),
              let payload = try? JSONDecoder().decode(IMAPPollFolderWorker.Payload.self, from: data) else {
            throw PipelineError.invalidPayload("imapPollFolder job missing payload")
        }
        return payload
    }

    private func decodeIMAPDeletionWatchPayload(from job: Job) throws -> IMAPDeletionWatchWorker.Payload {
        guard let data = job.payload?.data(using: .utf8),
              let payload = try? JSONDecoder().decode(IMAPDeletionWatchWorker.Payload.self, from: data) else {
            throw PipelineError.invalidPayload("imapDeletionWatch job missing payload")
        }
        return payload
    }

    @MainActor
    private func shouldSkipIMAPJob(
        accountID: UUID,
        context: ModelContext
    ) throws -> Bool {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == accountID }
        )
        guard let account = try context.fetch(descriptor).first else {
            return false
        }
        return account.status == .paused
            || account.needsImapReauth
            || account.imapHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || account.imapKeychainRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    @MainActor
    private func enqueueEntityJob(
        type: JobType,
        entityId: UUID,
        priority: Int,
        queue: JobQueue,
        encoder: JSONEncoder,
        context: ModelContext
    ) throws {
        let payload = EntityIdPayload(entityId: entityId)
        let data = try encoder.encode(payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try queue.enqueue(type: type, priority: priority, payload: json, context: context)
    }

    @MainActor
    private func entityID(from job: Job, payloadName: String) throws -> UUID {
        guard let data = job.payload?.data(using: .utf8),
              let payload = try? JSONDecoder().decode(EntityIdPayload.self, from: data) else {
            throw PipelineError.invalidPayload("\(payloadName) job missing entityId payload")
        }
        return payload.entityId
    }

    @MainActor
    private func entity(id: UUID, context: ModelContext) throws -> Entity? {
        let entities = try context.fetch(FetchDescriptor<Entity>())
        return entities.first(where: { $0.id == id })
    }

    @MainActor
    private func retireEntityJobsWithMissingEntities(context: ModelContext) throws {
        let entityIDs = Set(try context.fetch(FetchDescriptor<Entity>()).map(\.id))
        let jobs = try context.fetch(FetchDescriptor<Job>())
        let decoder = JSONDecoder()
        var removed = false
        for job in jobs where Self.isRetirableEntityJob(job) {
            guard let data = job.payload?.data(using: .utf8),
                  let payload = try? decoder.decode(EntityIdPayload.self, from: data),
                  !entityIDs.contains(payload.entityId) else {
                continue
            }
            context.delete(job)
            removed = true
        }
        if removed {
            try context.save()
        }
    }

    @MainActor
    private func retireEntityJobs(
        for entityID: UUID,
        excluding currentJobID: UUID,
        context: ModelContext
    ) throws {
        let jobs = try context.fetch(FetchDescriptor<Job>())
        let decoder = JSONDecoder()
        var removed = false
        for job in jobs where job.id != currentJobID && Self.isRetirableEntityJob(job) {
            guard let data = job.payload?.data(using: .utf8),
                  let payload = try? decoder.decode(EntityIdPayload.self, from: data),
                  payload.entityId == entityID else {
                continue
            }
            context.delete(job)
            removed = true
        }
        if removed {
            try context.save()
        }
    }

    private static func isRetirableEntityJob(_ job: Job) -> Bool {
        (job.type == .entityEmbed || job.type == .entityRefresh)
            && (job.status == .pending || job.status == .running || job.status == .failed)
    }

    @MainActor
    private func enqueueIndexForEntityIfNeeded(_ entity: Entity, context: ModelContext) throws {
        guard allowsVisiblePlacement(), layoutIndexWorker != nil, entity.vectorRowId != nil else { return }
        try enqueueIndexDrainIfMissing(context: context)
    }

    @MainActor
    private func enqueueIndexDrainIfMissing(context: ModelContext) throws {
        let jobs = try context.fetch(FetchDescriptor<Job>())
        let alreadyActive = jobs.contains { job in
            job.type == .index
                && job.payload == nil
                && (job.status == .pending || job.status == .running)
        }
        guard !alreadyActive else { return }
        try JobQueue().enqueue(type: .index, priority: 6, context: context)
    }
}

public enum PipelineError: Error, CustomStringConvertible {
    case notImplemented(String)
    case invalidPayload(String)
    case summaryUnavailable(String)
    case semanticTagResolutionDeferred

    public var description: String {
        switch self {
        case .notImplemented(let msg): return "PipelineRunner: \(msg)"
        case .invalidPayload(let msg): return "PipelineRunner: invalid payload — \(msg)"
        case .summaryUnavailable(let msg): return "PipelineRunner: \(msg)"
        case .semanticTagResolutionDeferred:
            return "PipelineRunner: semantic tag embedding unavailable"
        }
    }
}

extension PipelineError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Legacy payload shape for old `.index` jobs that carried a single vector id.
/// New jobs use `payload == nil` and drain unplaced vectors in batches, but
/// keeping this decoder lets in-flight rows from older builds complete safely.
struct IndexPayload: Codable {
    let vectorId: Int64
}

struct EntityIdPayload: Codable {
    let entityId: UUID
}
