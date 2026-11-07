// AppServices.swift
// Central initialization point for all Ohia services.

import Foundation
import Observation
import OhiaCore
import SwiftData
import os

public enum BGE3ModelRuntimeState: Equatable, Sendable {
    case unavailable(reason: String, missingArtifacts: [String])
    case downloading(fraction: Double, missingArtifacts: [String])
    case loading
    case ready(lanes: Int)
    case failed(String)

    public var statusMessage: String? {
        switch self {
        case .unavailable(let reason, let missingArtifacts):
            return Self.message(reason: reason, missingArtifacts: missingArtifacts)
        case .downloading(let fraction, let missingArtifacts):
            let percent = Int((min(1, max(0, fraction)) * 100).rounded())
            return Self.message(
                reason: "downloading bge-m3 model (\(percent)%)",
                missingArtifacts: missingArtifacts
            )
        case .loading:
            return "loading bge-m3 model"
        case .ready:
            return nil
        case .failed(let message):
            return "bge-m3 model failed: \(message)"
        }
    }

    private static func message(reason: String, missingArtifacts: [String]) -> String {
        guard !missingArtifacts.isEmpty else { return reason }
        return "\(reason); missing \(missingArtifacts.joined(separator: ", "))"
    }
}

@MainActor
final class BGE3DownloadCoordinator {
    static let initialRetryDelay: TimeInterval = 30
    static let maximumRetryDelay: TimeInterval = 15 * 60

    enum Completion: Equatable, Sendable {
        case available
        case failed(String)
    }

    typealias ProgressHandler = @Sendable (Double) -> Void
    typealias Operation = @Sendable (
        _ progress: @escaping ProgressHandler
    ) async throws -> Void

    private let initialRetryDelay: TimeInterval
    private let maximumRetryDelay: TimeInterval
    private let now: @MainActor @Sendable () -> Date
    private let artifactsAreAvailable: @MainActor @Sendable () -> Bool
    private let operation: Operation
    private var operationTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var nextRetryAt: Date?

    init(
        initialRetryDelay: TimeInterval = BGE3DownloadCoordinator.initialRetryDelay,
        maximumRetryDelay: TimeInterval = BGE3DownloadCoordinator.maximumRetryDelay,
        now: @escaping @MainActor @Sendable () -> Date = { Date() },
        artifactsAreAvailable: @escaping @MainActor @Sendable () -> Bool,
        operation: @escaping Operation
    ) {
        precondition(initialRetryDelay > 0)
        precondition(maximumRetryDelay >= initialRetryDelay)
        self.initialRetryDelay = initialRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
        self.now = now
        self.artifactsAreAvailable = artifactsAreAvailable
        self.operation = operation
    }

    deinit {
        operationTask?.cancel()
    }

    @discardableResult
    func startIfNeeded(
        hasModelDemand: Bool,
        starting: @escaping @MainActor @Sendable () -> Void,
        progress: @escaping ProgressHandler,
        completion: @escaping @MainActor @Sendable (Completion) -> Void
    ) -> Bool {
        guard operationTask == nil else { return false }
        if artifactsAreAvailable() {
            resetRetryHistory()
            return false
        }
        guard hasModelDemand else { return false }
        if let nextRetryAt, now() < nextRetryAt { return false }

        starting()
        let operation = self.operation
        operationTask = Task.detached(priority: .background) { [weak self] in
            let errorDescription: String?
            do {
                try await operation(progress)
                errorDescription = nil
            } catch {
                errorDescription = error.localizedDescription
            }
            await self?.finish(
                errorDescription: errorDescription,
                completion: completion
            )
        }
        return true
    }

    private func finish(
        errorDescription: String?,
        completion: @MainActor @Sendable (Completion) -> Void
    ) {
        operationTask = nil

        let artifactsAvailable = artifactsAreAvailable()
        if artifactsAvailable {
            resetRetryHistory()
            completion(.available)
            return
        }

        consecutiveFailures += 1
        nextRetryAt = now().addingTimeInterval(retryDelay())
        completion(.failed(
            errorDescription ?? "download completed without required artifacts"
        ))
    }

    private func retryDelay() -> TimeInterval {
        var delay = initialRetryDelay
        if consecutiveFailures > 1 {
            for _ in 1..<consecutiveFailures {
                delay = min(maximumRetryDelay, delay * 2)
                if delay == maximumRetryDelay { break }
            }
        }
        return delay
    }

    private func resetRetryHistory() {
        consecutiveFailures = 0
        nextRetryAt = nil
    }
}

@MainActor
private final class MessageSummaryPersistence {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func persist(
        messageID: UUID,
        result: SummarizationResult,
        summarizedAt: Date,
        summaryInputFingerprint: String
    ) throws {
        guard try MessageSummaryWriter.persist(
            messageID: messageID,
            summaryInputFingerprint: summaryInputFingerprint,
            result: result,
            summarizedAt: summarizedAt,
            context: modelContext,
            updateInterpretationFromResult: false,
            updateMessageTypeFromVerdict: false
        ) else {
            throw MessageSummaryPersistenceError.rejected
        }
    }
}

private enum MessageSummaryPersistenceError: Error {
    case rejected
}

/// Central initialization point for all Ohia services.
/// Created at app launch. Wires EngineSelector, ToolRegistry,
/// MCPSessionManager, and all orchestrators together.
///
/// `@Observable` so SwiftUI views can pull real providers out of the
/// environment (see `makeEditAnalyzer`, `makeNeighborProvider`, etc.).
@Observable
public final class AppServices: @unchecked Sendable {

    public enum RuntimeRole: Sendable, Equatable {
        case application
        case retrievalWorker
        case generativeWorker
    }

    // MARK: - Core Storage

    public let runtimeRole: RuntimeRole
    public let canonicalStore: CanonicalStore
    public let vectorStore: VectorStore
    public let vectorIndex: VectorIndex
    public let vectorNeighborsStore: VectorNeighborsStore
    public let vectorFrameLayoutStore: VectorFrameLayoutStore
    public let vectorClusterStore: VectorClusterStore
    public let vectorMeaningFeatureStore: VectorMeaningFeatureStore
    public let messageFTSIndex: MessageFTSIndex
    public let messageStoreURL: URL

    // MARK: - ML Engines

    public let engineSelector: EngineSelector
    public let onDemandSummarizer: OnDemandSummarizer
    /// Keeps generated reader-facing text in the reader's language (see
    /// `DisplayLanguageGuard`); shared by every app-process generation surface.
    public let displayLanguageGuard: DisplayLanguageGuard
    public let translationService: TranslationService
    public let translationCacheURL: URL
    public let contextOrientationService: ContextOrientationService
    public let contextOrientationCacheURL: URL
    public let projectSummaryService: ProjectSummaryService
    public let projectSummaryCacheURL: URL
    public let deadlineSummaryService: DeadlineSummaryService
    public let deadlineSummaryCacheURL: URL
    public let attachmentSummaryService: AttachmentSummaryService
    public let attachmentSummaryCacheURL: URL
    public let signatureGenerationService: SignatureGenerationService
    public let modelActivityStatusPublisher: ModelActivityStatusPublisher
    public let generationModelDownloadBaseDirectory: URL
    public let personalizedModelDirectory: URL

    // MARK: - Tools

    public let toolRegistry: ToolRegistry
    public let mcpSessionManager: MCPSessionManager

    // MARK: - Embedding

    public let embedder: EmbeddingProvider
    public let usesWorkerQueryEmbedding: Bool
    public let embedderRegistry: EmbedderRegistry
    public let bge3Downloader: BGE3ModelDownloader
    public let crossEncoderDownloader: CrossEncoderDownloader
    public let modelCacheDirectory: URL
    public private(set) var crossEncoderReranker: CrossEncoderReranker?
    public let hybridRetriever: HybridRetriever
    public let askMemoryProvider: (any AskMemoryProvider)?
    public let migrationCoordinator: EmbeddingMigrationCoordinator
    private let managedBGE3Embedder: SwappableEmbedder?
    private let bge3DownloadCoordinator: BGE3DownloadCoordinator
    private var bge3EmbedderLoaded = false
    @ObservationIgnored private var bge3LoadTask: Task<BGE3Embedder, Error>?
    @ObservationIgnored private var bge3LoadGeneration: UInt64 = 0
    @ObservationIgnored private var crossEncoderLoadTask: Task<CrossEncoderReranker, Error>?
    @ObservationIgnored private var crossEncoderLoadGeneration: UInt64 = 0
    @ObservationIgnored private var retrievalModelReleaseOperation: RetrievalModelReleaseOperation?
    @ObservationIgnored private let bge3StateLock = NSLock()
    @ObservationIgnored private var _bge3RuntimeState: BGE3ModelRuntimeState = .unavailable(
        reason: "bge-m3 state not initialized",
        missingArtifacts: []
    )
    @ObservationIgnored private let vectorIndexDirectory: URL
    @ObservationIgnored private let modelLogger = Logger(subsystem: "org.jgkarlin.Ohia", category: "models")

    private struct RetrievalModelReleaseOperation {
        let id: UUID
        let includesBGE: Bool
        let task: Task<Void, Never>
    }

    // MARK: - Training Status

    /// Single source of truth for "what is training doing right now".
    /// Shared across the activity strip, Settings → Training tab, and
    /// TrainingOrchestrator / BackgroundScheduler / ModelLoadingService
    /// writes. Created once per AppServices, injected into the SwiftUI
    /// environment by OhiaApp.
    public let trainingStatusPublisher: TrainingStatusPublisher

    // MARK: - Deletion Sync Status

    public let deletionSyncStatusPublisher: DeletionSyncStatusPublisher

    // MARK: - Worker Handoffs

    public let generationContextPackStore: GenerationContextPackStore

    // MARK: - Job Completion Events

    /// Broadcasts every successful job completion surfaced by
    /// `BackgroundScheduler`. Consumers: `ConstellationModeView`
    /// (post-burst / post-cluster-detect repaint), potential future
    /// listeners (training panel, ingestion progress).
    public let jobCompletionBroadcaster: JobCompletionBroadcaster

    /// Process-lifetime authority for every manual-project membership source
    /// change. Ingestion, Qwen metadata, and user category edits all enqueue
    /// through this one actor so their projections cannot race one another.
    public let manualProjectMembershipCoordinator: ManualProjectMembershipCoordinator?

    // MARK: - Init

    @MainActor
    public init(
        storageLayout: OhiaStorageLayout,
        runtimeRole: RuntimeRole = .application,
        modelContext: ModelContext? = nil,
        embedder: EmbeddingProvider? = nil,
        askMemoryProvider: (any AskMemoryProvider)? = nil,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) throws {
        self.runtimeRole = runtimeRole
        // Training status publisher — created first so all subsystems can
        // be wired to the same shared instance.
        self.trainingStatusPublisher = TrainingStatusPublisher()
        self.deletionSyncStatusPublisher = DeletionSyncStatusPublisher()
        self.modelActivityStatusPublisher = ModelActivityStatusPublisher()
        self.generationContextPackStore = GenerationContextPackStore(
            directoryURL: storageLayout.cacheData
                .appendingPathComponent("generation_context_packs", isDirectory: true)
        )
        self.contextOrientationCacheURL = storageLayout.cacheData.appendingPathComponent(
            "context_orientation_cache.json"
        )
        self.attachmentSummaryCacheURL = storageLayout.cacheData.appendingPathComponent(
            "attachment_summary_cache.json"
        )
        self.projectSummaryCacheURL = storageLayout.cacheData.appendingPathComponent(
            "project_summary_cache.json"
        )
        self.deadlineSummaryCacheURL = storageLayout.cacheData.appendingPathComponent(
            "deadline_summary_cache.json"
        )
        self.translationCacheURL = storageLayout.cacheData.appendingPathComponent(
            "translation_cache.json"
        )
        self.generationModelDownloadBaseDirectory = storageLayout.publicModels
        self.personalizedModelDirectory = storageLayout.personalizedModels
        do {
            try GenerationModelStorage.prepareDownloadBase(generationModelDownloadBaseDirectory)
        } catch {
            print("[Ohia] Generation model storage preparation failed: \(String(reflecting: type(of: error)))")
        }

        // Job completion broadcaster — shared pub/sub for job success
        // events. `BackgroundScheduler` yields to it; `ConstellationModeView`
        // (and future panels) subscribe.
        self.jobCompletionBroadcaster = JobCompletionBroadcaster()
        self.manualProjectMembershipCoordinator = modelContext.map {
            ManualProjectMembershipCoordinator(
                container: $0.container,
                textReader: ProjectTextFileReader()
            )
        }

        // Storage
        self.canonicalStore = try CanonicalStore(baseDirectory: storageLayout.canonicalStore)
        let messageStoreURL = storageLayout.swiftDataStore
        self.messageStoreURL = messageStoreURL
        try MessageStoreHotPath.installHotPathIndexes(storeURL: messageStoreURL)
        let vectorPath = storageLayout.vectorData.path

        // Embedder selection: bge-m3 is the only default writer. While the
        // model is not downloaded yet, the current version is still bge-m3 but
        // backed by a null embedder so no fake vectors are written.
        let modelCacheDirectory = storageLayout.retrievalModels
        self.modelCacheDirectory = modelCacheDirectory
        let modelsDir = modelCacheDirectory.appendingPathComponent("bge-m3", isDirectory: true)
        let downloader = BGE3ModelDownloader(
            cacheDirectory: modelsDir,
            bundledDirectory: Self.bge3BundledDirectory(
                runtimeRole: runtimeRole,
                discoveredBundledDirectory: BGE3ModelDownloader.defaultBundledDirectory()
            )
        )
        self.bge3Downloader = downloader
        self.bge3DownloadCoordinator = BGE3DownloadCoordinator(
            artifactsAreAvailable: { downloader.isAvailable },
            operation: { progress in
                try await downloader.download(progress: progress)
            }
        )

        let resolvedEmbedder: EmbeddingProvider
        let managedDefaultEmbedder: SwappableEmbedder?
        if let provided = embedder {
            resolvedEmbedder = provided
            managedDefaultEmbedder = nil
        } else if Self.shouldUseWorkerQueryEmbedding(
            runtimeRole: runtimeRole,
            physicalMemoryBytes: physicalMemoryBytes
        ) {
            resolvedEmbedder = WorkerQueryEmbedder(statusStore: WorkerStatusStore(
                directoryURL: storageLayout.workerState
            ))
            managedDefaultEmbedder = nil
            print("[Ohia] query embedding delegated to retrieval worker for low-memory model exclusivity.")
        } else {
            if !downloader.isAvailable {
                print("[Ohia] bge-m3 not yet available. Embedding writes are paused until download completes.")
            }
            let placeholder = UnavailableEmbedder(
                dimension: BGE3Embedder.embeddingDimension,
                embeddingVersion: BGE3Embedder.embeddingVersion
            )
            let managed = SwappableEmbedder(initial: placeholder)
            resolvedEmbedder = managed
            managedDefaultEmbedder = managed
        }
        self.embedder = resolvedEmbedder
        self.usesWorkerQueryEmbedding = resolvedEmbedder is WorkerQueryEmbedder
        self.managedBGE3Embedder = managedDefaultEmbedder
        self._bge3RuntimeState = downloader.isAvailable
            ? .unavailable(reason: "bge-m3 artifacts ready; waiting for loader", missingArtifacts: [])
            : .unavailable(
                reason: "waiting for bge-m3 artifacts",
                missingArtifacts: downloader.missingArtifactNames
            )
        let registry = EmbedderRegistry(current: resolvedEmbedder)
        self.embedderRegistry = registry

        let indexDir = storageLayout.vectorIndex
        self.vectorIndexDirectory = indexDir
        let selectedVectorIndex: any VectorIndex
        switch runtimeRole {
        case .application, .retrievalWorker:
            selectedVectorIndex = try USearchVectorIndex(
                directory: indexDir,
                dimensionsByVersion: registry.dimensionsByVersion
            )
        case .generativeWorker:
            selectedVectorIndex = NonresidentVectorIndex()
        }
        self.vectorIndex = selectedVectorIndex

        self.vectorStore = try VectorStore(path: vectorPath, index: selectedVectorIndex)
        self.messageFTSIndex = try MessageFTSIndex(
            sharedDB: self.vectorStore.rawHandle,
            lock: self.vectorStore.rawLock
        )
        let rerankerDir = modelCacheDirectory.appendingPathComponent("bge-reranker-v2-m3", isDirectory: true)
        self.crossEncoderDownloader = CrossEncoderDownloader(cacheDirectory: rerankerDir)
        self.crossEncoderReranker = nil
        // Built before the retriever so the kNN-graph expansion pass can be
        // injected: the persisted cosine neighbor graph now feeds retrieval
        // (Ask + drafting + QA), not just the Constellation layout.
        self.vectorNeighborsStore = VectorNeighborsStore(
            sharedDB: self.vectorStore.rawHandle,
            lock: self.vectorStore.rawLock
        )
        self.hybridRetriever = HybridRetriever(
            vectorStore: self.vectorStore,
            ftsIndex: self.messageFTSIndex,
            registry: registry,
            reranker: nil,
            neighborsStore: self.vectorNeighborsStore
        )
        self.askMemoryProvider = askMemoryProvider
        self.vectorFrameLayoutStore = VectorFrameLayoutStore(
            sharedDB: self.vectorStore.rawHandle,
            lock: self.vectorStore.rawLock
        )
        self.vectorClusterStore = VectorClusterStore(
            sharedDB: self.vectorStore.rawHandle,
            lock: self.vectorStore.rawLock
        )
        self.vectorMeaningFeatureStore = VectorMeaningFeatureStore(
            sharedDB: self.vectorStore.rawHandle,
            lock: self.vectorStore.rawLock
        )
        self.migrationCoordinator = EmbeddingMigrationCoordinator(
            registry: registry,
            vectorStore: self.vectorStore,
            canonicalStore: self.canonicalStore
        )

        // Engine selector: MLX/Qwen primary. Apple Intelligence remains a
        // fallback for small on-demand summaries and visual-evidence helpers,
        // not the canonical classifier.
        let mlxEngine = MLXTrainingEngine(
            modelDownloadBaseDirectory: generationModelDownloadBaseDirectory
        )
        self.engineSelector = EngineSelector(primary: mlxEngine, fallback: nil)

        let appleEnabledDefault = OhiaSharedDefaults.store.object(
            forKey: "summarizationUseAppleIntelligence"
        ) as? Bool ?? true
        let summaryEngine: any TrainingEngine = ProcessInfo.processInfo.environment["OHIA_QWEN_WORKER"] == "1"
            ? mlxEngine
            : WorkerGenerationEngine(
                readinessTimeout: WorkerGenerationEngine.interactiveModelHandoffReadinessTimeout
            )
        let translationContextProvider: (any TranslationContextProviding)? = modelContext
            .map { TranslationGlossaryProvider(container: $0.container) }
        let summaryDisplayLanguageGuard = DisplayLanguageGuard(
            container: modelContext?.container,
            engine: summaryEngine,
            priority: .userInitiated
        )
        self.displayLanguageGuard = summaryDisplayLanguageGuard
        if let modelContext {
            let persistence = MessageSummaryPersistence(modelContext: modelContext)
            self.onDemandSummarizer = OnDemandSummarizer(
                apple: AppleFoundationSummarizer(),
                mlx: MLXSummarizer(
                    engine: summaryEngine,
                    generationTaskPriority: .userInitiated
                ),
                appleEnabled: appleEnabledDefault,
                modelActivityStatusPublisher: modelActivityStatusPublisher,
                translationContextProvider: translationContextProvider,
                displayLanguageGuard: summaryDisplayLanguageGuard,
                persist: { id, result, when, summaryInputFingerprint in
                    try persistence.persist(
                        messageID: id,
                        result: result,
                        summarizedAt: when,
                        summaryInputFingerprint: summaryInputFingerprint
                    )
                }
            )
        } else {
            self.onDemandSummarizer = OnDemandSummarizer(
                apple: AppleFoundationSummarizer(),
                mlx: MLXSummarizer(
                    engine: summaryEngine,
                    generationTaskPriority: .userInitiated
                ),
                appleEnabled: appleEnabledDefault,
                modelActivityStatusPublisher: modelActivityStatusPublisher,
                translationContextProvider: translationContextProvider,
                displayLanguageGuard: summaryDisplayLanguageGuard,
                persist: { _, _, _, _ in }
            )
        }

        // On-demand body translation. The user picks the engine in Settings →
        // Models; `RoutingTranslator` reads that choice live per request and
        // delegates to Apple's Translation framework (on-device Apple
        // Intelligence, the default) or the Qwen engine. Results are cached on
        // disk keyed by the active engine so a given (message, target language,
        // engine) is generated once. Every engine receives exact protection for
        // source-applicable user-wide canonical dyads; Qwen additionally receives
        // provisional dyads and account-scoped target-language style rules.
        self.translationService = TranslationService(
            translator: RoutingTranslator(
                qwen: MLXTranslator(
                    engine: summaryEngine,
                    generationTaskPriority: .userInitiated
                ),
                appleOnDevice: AppleTranslationAPITranslator(),
                selection: { ModelManager.selectedTranslationEngine() }
            ),
            contextProvider: translationContextProvider,
            modelActivityStatusPublisher: modelActivityStatusPublisher,
            persistentCacheURL: translationCacheURL
        )

        // Context-orientation service for the locked-node CONTEXT pane. It shares
        // the same Qwen-first posture as summaries, but with an orientation prompt that
        // describes the anchor's place in the local cluster rather than its body.
        self.contextOrientationService = ContextOrientationService(
            apple: AppleFoundationContextOrientator(),
            mlx: MLXContextOrientator(
                engine: summaryEngine,
                generationTaskPriority: .userInitiated
            ),
            appleEnabled: appleEnabledDefault,
            modelActivityStatusPublisher: modelActivityStatusPublisher,
            persistentCacheURL: contextOrientationCacheURL,
            displayLanguageGuard: summaryDisplayLanguageGuard
        )

        // Project-summary service for the Projects-lens gutter hover pane. Same
        // Qwen-first posture, but the prompt briefs the whole project (goals,
        // timetable, current state, open issue) instead of one message's place.
        self.projectSummaryService = ProjectSummaryService(
            apple: AppleFoundationProjectSummarizer(),
            mlx: MLXProjectSummarizer(
                engine: summaryEngine,
                generationTaskPriority: .userInitiated
            ),
            appleEnabled: appleEnabledDefault,
            modelActivityStatusPublisher: modelActivityStatusPublisher,
            persistentCacheURL: projectSummaryCacheURL
        )

        // Deadline-summary service for the Deadlines-tab hover pane. Same
        // Qwen-first posture, but the prompt distils one dated deadline — what
        // it is for, what the owner must do, and the concrete actions it demands
        // (links, documents, phone numbers) grounded against the source text.
        self.deadlineSummaryService = DeadlineSummaryService(
            apple: AppleFoundationDeadlineSummarizer(),
            mlx: MLXDeadlineSummarizer(
                engine: summaryEngine,
                generationTaskPriority: .userInitiated
            ),
            appleReadout: AppleFoundationDeadlineResourceReadoutGenerator(),
            mlxReadout: MLXDeadlineResourceReadoutGenerator(
                engine: summaryEngine,
                generationTaskPriority: .userInitiated
            ),
            appleEnabled: appleEnabledDefault,
            modelActivityStatusPublisher: modelActivityStatusPublisher,
            persistentCacheURL: deadlineSummaryCacheURL,
            displayLanguageGuard: summaryDisplayLanguageGuard
        )

        // Lazy attachment summarizer for the locked-overlay chevron. Apple
        // is preferred for the small three-sentence prompt; MLX picks up the
        // long tail (refusals, oversize prompts, Apple Intelligence off).
        self.attachmentSummaryService = AttachmentSummaryService(
            apple: AppleFoundationAttachmentSummarizer(),
            mlx: MLXAttachmentSummarizer(engine: summaryEngine),
            appleEnabled: appleEnabledDefault,
            modelActivityStatusPublisher: modelActivityStatusPublisher,
            persistentCacheURL: attachmentSummaryCacheURL,
            displayLanguageGuard: summaryDisplayLanguageGuard
        )
        // Signature studio (Settings → Signatures): tier generation,
        // regenerate, and revision, all against the shared summary engine
        // (worker-routed in the UI process), grounded by the same curated
        // target-language memories the Qwen translator consumes.
        self.signatureGenerationService = SignatureGenerationService(
            engine: summaryEngine,
            translationContextProvider: translationContextProvider
        )

        // Tool registry: register built-in corpus and sandbox-safe native tools.
        // Local file search is intentionally absent until Ohia has an explicit
        // user-selected-folder and security-scoped-bookmark flow.
        self.toolRegistry = ToolRegistry()
        toolRegistry.registerBuiltInCorpusTools()
        toolRegistry.register(ToolRegistration(tool: CalendarTool(), tier: .native))
        toolRegistry.register(ToolRegistration(tool: ContactsTool(), tier: .native))
        toolRegistry.register(ToolRegistration(tool: RemindersTool(), tier: .native))
        toolRegistry.register(ToolRegistration(tool: WebFetchTool(), tier: .native))

        // MCP sessions are lazy: one HTTPS connection per configured server,
        // opened on first use and kept for the app session.
        self.mcpSessionManager = .shared

        pruneInactiveOhiaModelCachesInBackground()
    }

    // MARK: - Engine Access

    /// The engine that should be used right now (from EngineSelector).
    public var activeEngine: (any TrainingEngine)? {
        engineSelector.activeEngine
    }

    /// The primary engine if its model is loaded, otherwise nil.
    public var trainingEngine: (any TrainingEngine)? {
        engineSelector.trainingEngine
    }

    // MARK: - Orchestrator Factories

    /// Create an EmbeddingOrchestrator for message and attachment retrieval.
    public func makeEmbeddingOrchestrator() -> EmbeddingOrchestrator {
        EmbeddingOrchestrator(
            embedder: embedder,
            vectorStore: vectorStore,
            canonicalStore: canonicalStore,
            ftsIndex: messageFTSIndex,
            messageStoreURL: messageStoreURL,
            meaningFeatureStore: vectorMeaningFeatureStore
        )
    }

    /// Create an EntityOrchestrator wired to the shared vector store.
    public func makeEntityOrchestrator() -> EntityOrchestrator {
        EntityOrchestrator(
            embedder: embedder,
            vectorStore: vectorStore,
            canonicalStore: canonicalStore
        )
    }

    // MARK: - UI Provider Factories
    //
    // Each method returns the best available implementation given the
    // current engine/embedder state. Views construct these per-render —
    // the objects are lightweight and stateless.

    /// Real `EditAnalyzing`. Stateless — pure heuristics over the diff.
    public func makeEditAnalyzer() -> any EditAnalyzing {
        HeuristicEditAnalyzer()
    }

    /// Real `NeighborProviding` wired to the VectorStore + embedder.
    public func makeNeighborProvider() -> any NeighborProviding {
        VectorNeighborProvider(vectorStore: vectorStore, hybridRetriever: hybridRetriever)
    }

    /// Real stored-affinity provider for Composer automatic cross-thread
    /// sources. This consumes persisted vector-neighbor and Meaning-cluster
    /// evidence only; it does not run embeddings or retrieval.
    public func makeComposerRelatedAffinityProvider() -> any ComposerRelatedAffinityProviding {
        StoredComposerRelatedAffinityProvider(
            vectorNeighborsStore: vectorNeighborsStore,
            vectorClusterStore: vectorClusterStore
        )
    }

    /// Real `DigestBuilding` that clusters by embedding similarity.
    public func makeDigestBuilder() -> any DigestBuilding {
        EmbeddingDigestBuilder(embedder: embedder)
    }

    /// Real `ReceiptExtracting`. Uses the LLM when a model is loaded and
    /// falls back to pure heuristics otherwise.
    public func makeReceiptExtractor() -> any ReceiptExtracting {
        if let engine = activeEngine {
            return LLMReceiptExtractor(
                engine: engine,
                modelActivityStatusPublisher: modelActivityStatusPublisher
            )
        }
        return HeuristicReceiptExtractor()
    }

    /// One-call conditional-interview planner. A missing model is explicit;
    /// foreground orchestration keeps the draft in source evaluation and lets
    /// the existing retry policy handle infrastructure readiness.
    public func makeInterviewPlanner() -> ComposerInterviewPlanner? {
        guard let engine = activeEngine, engine.isModelLoaded else { return nil }
        return ComposerInterviewPlanner(
            engine: engine,
            modelActivityStatusPublisher: modelActivityStatusPublisher,
            displayLanguageGuard: displayLanguageGuard.with(engine: engine)
        )
    }

    /// Create a DraftOrchestrator wired to the active engine and tool registry.
    /// Returns nil when no engine is available.
    public func makeDraftOrchestrator() -> DraftOrchestrator? {
        guard let engine = activeEngine else { return nil }
        return DraftOrchestrator(
            engine: engine,
            vectorStore: vectorStore,
            embedder: embedder,
            canonicalStore: canonicalStore,
            hybridRetriever: hybridRetriever,
            toolRegistry: toolRegistry,
            contextPacker: ComposerContextPacker(
                tokenCounter: engine as? any PromptTokenCounting
            ),
            modelActivityStatusPublisher: modelActivityStatusPublisher
        )
    }

    /// Create a TrainingOrchestrator wired to the training engine.
    /// Returns nil when the primary engine model is not loaded.
    public func makeTrainingOrchestrator(checkpointDirectory: URL) -> TrainingOrchestrator? {
        guard let engine = trainingEngine else { return nil }
        return TrainingOrchestrator(
            engine: engine,
            canonicalStore: canonicalStore,
            checkpointDirectory: checkpointDirectory
        )
    }

    // MARK: - Shutdown

    /// Persists the vector index and disconnects remote MCP sessions. The
    /// stop is bounded so app termination cannot hang on a wedged server.
    public func shutdown() {
        do {
            try vectorIndex.save()
        } catch {
            print("[Ohia] ⚠ vectorIndex.save failed at shutdown: \(String(reflecting: type(of: error)))")
        }
        let manager = mcpSessionManager
        let stopped = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await manager.stopAll()
            stopped.signal()
        }
        _ = stopped.wait(timeout: .now() + 2)
    }

    /// Repairs drift between `VectorStore` and `VectorIndex` after launch.
    /// Runs on a detached background task so app launch is not blocked.
    /// Safe to call multiple times because the reconciler is idempotent.
    public func reconcileVectorIndexInBackground() {
        let store = self.vectorStore
        let index = self.vectorIndex
        Task.detached(priority: .utility) {
            do {
                let stats = try VectorIndexReconciler.reconcile(store: store, index: index)
                if stats.added > 0 || stats.removed > 0 {
                    print("[Ohia] vector index reconciled: scanned=\(stats.scanned) added=\(stats.added) removed=\(stats.removed)")
                }
            } catch {
                print("[Ohia] ⚠ vector index reconcile failed: \(String(reflecting: type(of: error)))")
            }
        }
    }

    /// Downloads bge-m3 while retrieval demand exists, coalescing callers and
    /// backing off transient failures. Model installation stays with the
    /// worker runtime so exclusive-residency Macs cannot bypass Qwen/BGE
    /// arbitration when a download finishes.
    @MainActor
    @discardableResult
    public func startBGE3DownloadIfNeeded(hasModelDemand: Bool) -> Bool {
        let missingArtifacts = bge3Downloader.missingArtifactNames
        let started = bge3DownloadCoordinator.startIfNeeded(
            hasModelDemand: hasModelDemand,
            starting: { [weak self] in
                self?.updateBGE3RuntimeState(.downloading(
                    fraction: 0,
                    missingArtifacts: missingArtifacts
                ))
            },
            progress: { [weak self] progress in
                self?.updateBGE3RuntimeState(.downloading(
                    fraction: progress,
                    missingArtifacts: missingArtifacts
                ))
            },
            completion: { [weak self] completion in
                guard let self else { return }
                switch completion {
                case .available:
                    self.updateBGE3RuntimeState(.unavailable(
                        reason: "bge-m3 artifacts ready; waiting for loader",
                        missingArtifacts: []
                    ))
                case .failed(let message):
                    self.updateBGE3RuntimeState(.failed(message))
                }
            }
        )
        if bge3Downloader.isAvailable {
            updateBGE3RuntimeState(.unavailable(
                reason: "bge-m3 artifacts ready; waiting for loader",
                missingArtifacts: []
            ))
        }
        return started
    }

    /// Loads the bundled or cached bge-m3 Core ML embedder away from the main
    /// actor, then hot-swaps it into the shared provider used by schedulers and
    /// orchestrators.
    @MainActor
    public func setupBGE3IfAvailable() async {
        guard retrievalModelReleaseOperation == nil else { return }
        guard let managedBGE3Embedder, !bge3EmbedderLoaded else { return }
        guard bge3Downloader.isAvailable else {
            if case .downloading = bge3RuntimeState {
                return
            }
            updateBGE3RuntimeState(.unavailable(
                reason: "waiting for bge-m3 artifacts",
                missingArtifacts: bge3Downloader.missingArtifactNames
            ))
            return
        }

        let downloader = bge3Downloader
        updateBGE3RuntimeState(.loading)
        let loadGeneration: UInt64
        let loadTask: Task<BGE3Embedder, Error>
        if let existing = bge3LoadTask {
            loadGeneration = bge3LoadGeneration
            loadTask = existing
        } else {
            bge3LoadGeneration &+= 1
            loadGeneration = bge3LoadGeneration
            let newTask = Task.detached(priority: .utility) {
                try BGE3Embedder(downloader: downloader)
            }
            bge3LoadTask = newTask
            loadTask = newTask
        }
        do {
            let loadedEmbedder = try await loadTask.value
            guard bge3LoadGeneration == loadGeneration else { return }
            try managedBGE3Embedder.replace(with: loadedEmbedder)
            bge3EmbedderLoaded = true
            bge3LoadTask = nil
            updateBGE3RuntimeState(.ready(lanes: loadedEmbedder.parallelLaneCount))
        } catch {
            guard bge3LoadGeneration == loadGeneration else { return }
            bge3LoadTask = nil
            if error is CancellationError {
                updateBGE3RuntimeState(.unavailable(
                    reason: "bge-m3 artifacts ready; waiting for loader",
                    missingArtifacts: []
                ))
                return
            }
            updateBGE3RuntimeState(.failed(error.localizedDescription))
        }
    }

    /// Ensures interactive semantic retrieval has a BGE provider. Low-memory
    /// applications use the retrieval-worker facade; larger machines may load
    /// a local provider when cached artifacts are available.
    @MainActor
    public func prepareBGE3ForInteractiveRetrievalIfAvailable() async -> Bool {
        if embedder is WorkerQueryEmbedder {
            return true
        }
        guard let managedBGE3Embedder else {
            if let swappable = embedder as? SwappableEmbedder {
                return !swappable.isUsingUnavailableProvider
            }
            return !(embedder is UnavailableEmbedder)
        }
        guard managedBGE3Embedder.isUsingUnavailableProvider else { return true }
        await setupBGE3IfAvailable()
        return !managedBGE3Embedder.isUsingUnavailableProvider
    }

    nonisolated static func shouldUseWorkerQueryEmbedding(
        runtimeRole: RuntimeRole,
        physicalMemoryBytes: UInt64
    ) -> Bool {
        let exclusiveMemoryLimit = UInt64(16) * 1024 * 1024 * 1024
        return runtimeRole == .application
            && physicalMemoryBytes <= exclusiveMemoryLimit
    }

    nonisolated static func bge3BundledDirectory(
        runtimeRole: RuntimeRole,
        discoveredBundledDirectory: URL?
    ) -> URL? {
        switch runtimeRole {
        case .retrievalWorker:
            return nil
        case .application, .generativeWorker:
            return discoveredBundledDirectory
        }
    }

    /// Loads the cross-encoder reranker when its Core ML package and tokenizer
    /// are present. Hybrid retrieval remains usable through RRF until this
    /// succeeds.
    @MainActor
    public func setupCrossEncoderIfAvailable() async {
        guard retrievalModelReleaseOperation == nil else { return }
        guard crossEncoderDownloader.isAvailable, crossEncoderReranker == nil else { return }
        let downloader = crossEncoderDownloader
        let loadGeneration: UInt64
        let loadTask: Task<CrossEncoderReranker, Error>
        if let existing = crossEncoderLoadTask {
            loadGeneration = crossEncoderLoadGeneration
            loadTask = existing
        } else {
            crossEncoderLoadGeneration &+= 1
            loadGeneration = crossEncoderLoadGeneration
            let newTask = Task.detached(priority: .utility) {
                try await CrossEncoderReranker(downloader: downloader)
            }
            crossEncoderLoadTask = newTask
            loadTask = newTask
        }
        do {
            let reranker = try await loadTask.value
            guard crossEncoderLoadGeneration == loadGeneration else { return }
            crossEncoderLoadTask = nil
            self.crossEncoderReranker = reranker
            self.hybridRetriever.setReranker(reranker)
            print("[Ohia] cross-encoder reranker loaded.")
        } catch {
            guard crossEncoderLoadGeneration == loadGeneration else { return }
            crossEncoderLoadTask = nil
            if error is CancellationError { return }
            print("[Ohia] cross-encoder load failed: \(String(reflecting: type(of: error)))")
        }
    }

    /// Drops resident retrieval model resources so the worker can respond to
    /// pressure from memory or higher-priority generation work. The cross-
    /// encoder is optional and can always be released. BGE is released only
    /// when requested; the swappable provider keeps the embedding version
    /// stable while future scheduler ticks reload it when resources recover.
    @MainActor
    public func releaseRetrievalModelResources(
        includeBGE: Bool = false,
        reason: String = "memory pressure"
    ) async {
        while let existing = retrievalModelReleaseOperation {
            await existing.task.value
            if retrievalModelReleaseOperation?.id == existing.id {
                retrievalModelReleaseOperation = nil
            }
            if includeBGE == false || existing.includesBGE {
                return
            }
            // The coalesced operation released only the reranker. This caller
            // also needs BGE drained, so begin one follow-up operation after
            // the shared release has completed.
        }

        let operationID = UUID()
        let releaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRetrievalModelResourceRelease(
                includeBGE: includeBGE,
                reason: reason
            )
        }
        retrievalModelReleaseOperation = RetrievalModelReleaseOperation(
            id: operationID,
            includesBGE: includeBGE,
            task: releaseTask
        )
        await releaseTask.value
        if retrievalModelReleaseOperation?.id == operationID {
            retrievalModelReleaseOperation = nil
        }
    }

    @MainActor
    private func performRetrievalModelResourceRelease(
        includeBGE: Bool,
        reason: String
    ) async {
        let pendingCrossEncoderLoad = crossEncoderLoadTask
        crossEncoderLoadGeneration &+= 1
        pendingCrossEncoderLoad?.cancel()
        crossEncoderLoadTask = nil
        if let pendingCrossEncoderLoad {
            _ = try? await pendingCrossEncoderLoad.value
        }
        let hadCrossEncoder = crossEncoderReranker != nil
        crossEncoderReranker = nil
        await hybridRetriever.removeRerankerAndDrain()
        if hadCrossEncoder {
            print("[Ohia] released cross-encoder reranker")
        }

        guard includeBGE, let managedBGE3Embedder else { return }
        let pendingBGE3Load = bge3LoadTask
        bge3LoadGeneration &+= 1
        pendingBGE3Load?.cancel()
        bge3LoadTask = nil
        if let pendingBGE3Load {
            _ = try? await pendingBGE3Load.value
        }
        if bge3EmbedderLoaded {
            do {
                try await managedBGE3Embedder.replaceAndDrain(with: UnavailableEmbedder(
                    dimension: BGE3Embedder.embeddingDimension,
                    embeddingVersion: BGE3Embedder.embeddingVersion
                ))
                bge3EmbedderLoaded = false
            } catch {
                updateBGE3RuntimeState(.failed("release failed: \(error.localizedDescription)"))
                return
            }
        }
        updateBGE3RuntimeState(.unavailable(
            reason: "bge-m3 released for \(reason)",
            missingArtifacts: []
        ))
    }

    public var bge3RuntimeState: BGE3ModelRuntimeState {
        bge3StateLock.lock()
        defer { bge3StateLock.unlock() }
        return _bge3RuntimeState
    }

    public func ohiaModelCacheSnapshot() -> OhiaModelCacheSnapshot {
        ohiaModelCacheJanitor().snapshot()
    }

    public func pruneInactiveOhiaModelCaches() throws -> OhiaModelCachePruneResult {
        try ohiaModelCacheJanitor().pruneInactive()
    }

    public func pruneInactiveOhiaModelCachesInBackground() {
        let janitor = ohiaModelCacheJanitor()
        let logger = modelLogger
        Task.detached(priority: .utility) {
            do {
                let result = try janitor.pruneInactive()
                if !result.removedEntries.isEmpty {
                    logger.info("Pruned \(result.removedEntries.count) inactive model cache folder(s), reclaimed \(result.reclaimedBytes) bytes")
                }
            } catch {
                logger.warning("Inactive model cache cleanup failed: \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
    }

    private func ohiaModelCacheJanitor() -> OhiaModelCacheJanitor {
        OhiaModelCacheJanitor(
            modelsDirectory: modelCacheDirectory,
            activeDirectoryNames: [
                bge3Downloader.cacheDirectoryURL.lastPathComponent,
                crossEncoderDownloader.cacheDirectoryURL.lastPathComponent,
            ]
        )
    }

    private func updateBGE3RuntimeState(_ state: BGE3ModelRuntimeState) {
        bge3StateLock.lock()
        let oldState = _bge3RuntimeState
        _bge3RuntimeState = state
        bge3StateLock.unlock()

        guard oldState != state else { return }
        let stateKind: String
        switch state {
        case .unavailable: stateKind = "unavailable"
        case .downloading: stateKind = "downloading"
        case .loading: stateKind = "loading"
        case .ready: stateKind = "ready"
        case .failed: stateKind = "failed"
        }
        modelLogger.info("bge-m3 state=\(stateKind, privacy: .public)")
    }

    /// Downloads the cross-encoder in the background if neither bundled nor
    /// cached artifacts are available. The runtime's resource-policy pass owns
    /// installation so download completion cannot create hidden co-residency.
    @MainActor
    public func startCrossEncoderDownloadIfNeeded() {
        guard !crossEncoderDownloader.isAvailable else { return }
        Task.detached(priority: .background) { [downloader = crossEncoderDownloader, weak self] in
            do {
                try await downloader.download { progress in
                    print("[Ohia] cross-encoder download: \(Int(progress * 100))%")
                }
                guard self != nil else { return }
                print("[Ohia] cross-encoder artifacts ready; waiting for loader.")
            } catch {
                print("[Ohia] cross-encoder download failed: \(String(reflecting: type(of: error)))")
            }
        }
    }

    /// Drains stale-version messages through the full embedding pipeline once
    /// the current embedder can actually produce vectors.
    @MainActor
    public func kickoffMigration(modelContext: ModelContext, batchSize: Int = 25) {
        guard managedBGE3Embedder == nil || bge3EmbedderLoaded else { return }
        guard !(embedder is UnavailableEmbedder) else { return }

        let coordinator = self.migrationCoordinator
        let orchestrator = self.makeEmbeddingOrchestrator()
        Task { @MainActor [coordinator, orchestrator, modelContext] in
            while !Task.isCancelled {
                let batch: [String]
                do {
                    batch = try coordinator.staleMessageIds(limit: batchSize)
                } catch {
                    print("[Migrate] stale-version scan failed: \(String(reflecting: type(of: error)))")
                    break
                }
                guard !batch.isEmpty else { break }

                do {
                    let stats = try await coordinator.migrateBatchFull(
                        messageIds: batch,
                        orchestrator: orchestrator,
                        context: modelContext
                    )
                    print("[Migrate] batch: scanned=\(stats.scanned) migrated=\(stats.migrated) skipped=\(stats.skipped)")
                    if stats.migrated == 0, stats.skipped == stats.scanned {
                        break
                    }
                } catch {
                    print("[Migrate] batch failed: \(String(reflecting: type(of: error)))")
                    break
                }
            }
        }
    }

    /// Clears file-backed user data owned by AppServices while preserving the
    /// live service objects. Reset flows run inside the current process, so the
    /// vector database must be emptied through SQLite instead of deleting the
    /// database file beneath the open handle.
    public func resetUserDataStores() throws {
        try vectorStore.removeAllData()
        try messageFTSIndex.removeAllData()
        try recreateDirectory(at: canonicalStore.baseDirectory)
        try recreateDirectory(at: generationContextPackStore.directoryURL)
        try? FileManager.default.removeItem(at: contextOrientationCacheURL)
        try? FileManager.default.removeItem(at: projectSummaryCacheURL)
        try? FileManager.default.removeItem(at: deadlineSummaryCacheURL)
        try? FileManager.default.removeItem(at: translationCacheURL)

        // `VectorStore.removeAllData()` resets the live index and removes
        // sidecars for known embedding versions. Clear remaining children
        // in-place so sidecars from older versions cannot make a fresh ingest
        // look stale without invalidating the live index object's directory.
        try clearDirectoryContents(at: vectorIndexDirectory)
    }

    private func recreateDirectory(at directory: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func clearDirectoryContents(at directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for child in children {
            try fileManager.removeItem(at: child)
        }
    }
}
