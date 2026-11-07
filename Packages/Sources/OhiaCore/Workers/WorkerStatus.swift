import Foundation

public enum WorkerRole: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case bge
    case qwen

    public var id: String { rawValue }

    public var processName: String {
        switch self {
        case .bge:
            return "OhiaRetrievalWorker"
        case .qwen:
            return "OhiaGenerativeWorker"
        }
    }

    public var displayName: String {
        switch self {
        case .bge:
            return "Retrieval Worker"
        case .qwen:
            return "Generative Worker"
        }
    }

    public var statusFilename: String {
        switch self {
        case .bge:
            return "worker-retrieval.status.json"
        case .qwen:
            return "worker-generative.status.json"
        }
    }
}

public enum WorkerState: String, Codable, Equatable, Sendable {
    case unknown
    case starting
    case idle
    case waiting
    case running
    case busy
    case throttled
    case paused
    case stopping
    case stopped
    case failed
}

public enum InteractiveGenerationLane: String, Codable, Equatable, Sendable, Hashable, Comparable {
    case lensAssist = "lens_assist"
    case userInteractive = "user_interactive"

    private var priorityRank: Int {
        switch self {
        case .lensAssist: return 0
        case .userInteractive: return 1
        }
    }

    public static func < (lhs: InteractiveGenerationLane, rhs: InteractiveGenerationLane) -> Bool {
        lhs.priorityRank < rhs.priorityRank
    }
}

public enum WorkerInteractiveGenerationLeaseError: Error, Equatable, Sendable {
    case higherPriorityActive(
        activeLane: InteractiveGenerationLane,
        activeReason: String,
        requestedLane: InteractiveGenerationLane,
        requestedReason: String
    )
}

public final class InteractiveGenerationPreemptionBroker: @unchecked Sendable {
    public static let shared = InteractiveGenerationPreemptionBroker()

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    private init() {}

    public func stream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    public func publishUserInteractiveBegan() {
        lock.lock()
        let active = Array(continuations.values)
        lock.unlock()
        for continuation in active {
            continuation.yield(())
        }
    }
}

public enum WorkerModelLoadState: Codable, Equatable, Sendable {
    case unavailable
    case downloading(fraction: Double)
    case downloaded
    case loading
    case paused(String?)
    case ready
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public struct WorkerModelDownloadSnapshot: Codable, Equatable, Sendable {
    public let downloadedBytes: Int64
    public let totalBytes: Int64?

    public init(
        downloadedBytes: Int64,
        totalBytes: Int64? = nil
    ) {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }
}

public struct WorkerModelStatusSnapshot: Codable, Equatable, Sendable {
    public let name: String
    public let state: WorkerModelLoadState
    /// Actual in-process model residency, independent of preparation state.
    /// A pending model switch can download new artifacts while the previous
    /// model remains resident. Optional so snapshots from older workers still
    /// decode and can use the conservative state-based fallback.
    public let isResident: Bool?
    public let laneCount: Int?
    public let message: String?
    public let download: WorkerModelDownloadSnapshot?

    public init(
        name: String,
        state: WorkerModelLoadState,
        laneCount: Int? = nil,
        message: String? = nil
    ) {
        self.init(
            name: name,
            state: state,
            laneCount: laneCount,
            message: message,
            download: nil
        )
    }

    public init(
        name: String,
        state: WorkerModelLoadState,
        laneCount: Int? = nil,
        message: String? = nil,
        download: WorkerModelDownloadSnapshot?
    ) {
        self.name = name
        self.state = state
        self.isResident = nil
        self.laneCount = laneCount
        self.message = message
        self.download = download
    }

    public init(
        name: String,
        state: WorkerModelLoadState,
        isResident: Bool,
        laneCount: Int? = nil,
        message: String? = nil
    ) {
        self.init(
            name: name,
            state: state,
            isResident: isResident,
            laneCount: laneCount,
            message: message,
            download: nil
        )
    }

    public init(
        name: String,
        state: WorkerModelLoadState,
        isResident: Bool,
        laneCount: Int? = nil,
        message: String? = nil,
        download: WorkerModelDownloadSnapshot?
    ) {
        self.name = name
        self.state = state
        self.isResident = isResident
        self.laneCount = laneCount
        self.message = message
        self.download = download
    }
}

public struct WorkerThrottleSnapshot: Codable, Equatable, Sendable {
    public let isThrottled: Bool
    public let reasons: [String]
    public let resumeAfter: Date?

    public init(
        isThrottled: Bool = false,
        reasons: [String] = [],
        resumeAfter: Date? = nil
    ) {
        self.isThrottled = isThrottled
        self.reasons = reasons
        self.resumeAfter = resumeAfter
    }

    public static let notThrottled = WorkerThrottleSnapshot()
}

public struct WorkerCompletionSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let jobType: String
    public let payload: String?
    public let summary: String?
    public let completedAt: Date
    /// Absent in snapshots written by workers that predate message-scoped
    /// completion metadata. `nil` preserves the app's broad fallback path.
    public let messageMutations: [PipelineMessageMutation]?
    /// Monotonic position within `WorkerStatusSnapshot.completionStreamID`.
    /// Older workers omit this field, in which case the app retains UUID
    /// deduplication without attempting gap detection.
    public let sequence: UInt64?

    public init(
        id: UUID = UUID(),
        jobType: String,
        payload: String? = nil,
        summary: String? = nil,
        completedAt: Date = Date(),
        messageMutations: [PipelineMessageMutation]? = nil,
        sequence: UInt64? = nil
    ) {
        self.id = id
        self.jobType = jobType
        self.payload = payload
        self.summary = summary
        self.completedAt = completedAt
        self.messageMutations = messageMutations
        self.sequence = sequence
    }

    public init(event: JobCompletionEvent) {
        self.init(
            jobType: event.type.rawValue,
            payload: event.payload,
            completedAt: event.completedAt,
            messageMutations: event.messageMutations
        )
    }

    public var jobCompletionEvent: JobCompletionEvent? {
        guard let type = JobType(rawValue: jobType) else { return nil }
        return JobCompletionEvent(
            type: type,
            payload: payload,
            completedAt: completedAt,
            messageMutations: messageMutations
        )
    }

    public func assigning(sequence: UInt64) -> WorkerCompletionSnapshot {
        WorkerCompletionSnapshot(
            id: id,
            jobType: jobType,
            payload: payload,
            summary: summary,
            completedAt: completedAt,
            messageMutations: messageMutations,
            sequence: sequence
        )
    }
}

/// User-visible IMAP work emitted by the process that actually owns the
/// connection or mailbox command. These values cross the worker status-file
/// boundary, so fast transitions are retained even when the app observes the
/// file after the work has already completed.
public enum WorkerIMAPActivityKind: String, Codable, CaseIterable, Equatable, Sendable {
    case ready
    case watching
    case pending
    case connecting
    case authenticating
    case syncing
    case polling
    case gapChecking
    case verifyingDeletions
    case reconciling
    case deletionsUpdated
    case reconnecting
    case needsAttention
    case backfilling
    case checking
    case forming
    case movingToTrash
    case deleting
    case movingToJunk
    case movingToInbox
    case updatingMail
    case savingDraft
    case deletingDraft
    case syncingDrafts

    public init(mailboxMutation: MailboxMutationKind) {
        switch mailboxMutation {
        case .setSeen, .clearSeen, .setFlagged, .clearFlagged:
            self = .updatingMail
        case .delete:
            self = .deleting
        case .moveToTrash:
            self = .movingToTrash
        case .moveToJunk:
            self = .movingToJunk
        case .moveToInbox:
            self = .movingToInbox
        }
    }
}

/// Safe failure categories only: never carry raw server responses or credentials
/// into the status file or a user-facing tooltip.
public enum WorkerIMAPAttentionCause: String, Codable, CaseIterable, Sendable {
    case authentication, certificate, secureConnection, protocolFailure, mailboxOperation, localReconciliation

    public var explanation: String {
        switch self {
        case .authentication:
            "The mail server rejected authorization. Reconnect this account in Settings using the provider's required sign-in method."
        case .certificate:
            "The server certificate did not match the trusted certificate. Verify the incoming server address and contact your mail administrator before trusting a changed certificate."
        case .secureConnection:
            "A secure connection could not be established and mail synchronization stopped. Check the incoming server and security settings, then reconnect the account."
        case .protocolFailure:
            "The server returned an invalid IMAP response and mail synchronization stopped. Check the incoming server settings and reconnect the account. If this repeats, report it to Ohia support."
        case .mailboxOperation:
            "A mailbox operation could not finish and needs review. Check the account connection and retry the failed action. If it fails again, report it to Ohia support."
        case .localReconciliation:
            "Ohia could not apply confirmed server changes to its local mail data. Restart Ohia; if the problem persists, report it to Ohia support."
        }
    }
}

public struct WorkerIMAPActivitySnapshot: Codable, Equatable, Sendable {
    public let kind: WorkerIMAPActivityKind
    public let accountID: UUID?
    public let folder: String?
    public let occurredAt: Date
    /// Monotonic position within `WorkerStatusSnapshot.imapActivityStreamID`.
    public let sequence: UInt64?
    public let attentionCause: WorkerIMAPAttentionCause?
    public let operationID: UUID?

    public init(
        kind: WorkerIMAPActivityKind,
        accountID: UUID? = nil,
        folder: String? = nil,
        occurredAt: Date = Date(),
        sequence: UInt64? = nil,
        attentionCause: WorkerIMAPAttentionCause? = nil,
        operationID: UUID? = nil
    ) {
        self.kind = kind
        self.accountID = accountID
        self.folder = folder
        self.occurredAt = occurredAt
        self.sequence = sequence
        self.attentionCause = attentionCause
        self.operationID = operationID
    }

    public func assigning(sequence: UInt64) -> WorkerIMAPActivitySnapshot {
        WorkerIMAPActivitySnapshot(
            kind: kind,
            accountID: accountID,
            folder: folder,
            occurredAt: occurredAt,
            sequence: sequence,
            attentionCause: attentionCause,
            operationID: operationID
        )
    }
}

public extension Notification.Name {
    /// Process-local enqueue signal used to give an explicit mailbox or draft
    /// command immediate UI precedence while the worker's durable status ring
    /// remains the authoritative cross-process execution history.
    static let ohiaIMAPActivityQueued = Notification.Name("Ohia.IMAPActivityQueued")
}

public enum WorkerTrainingPhaseSnapshot: Codable, Equatable, Sendable {
    case idle
    case preparing
    case training(step: Int, totalSteps: Int, loss: Double)
    case checkpointing(step: Int)
    case resetting
}

public struct WorkerTrainingStatusSnapshot: Codable, Equatable, Sendable {
    public let phase: WorkerTrainingPhaseSnapshot
    public let lastRunAt: Date?
    public let lastDurationSeconds: Double?
    public let totalSteps: Int
    public let adapterLoadedAt: Date?
    public let adapterStep: Int?
    public let pendingTrainingTargetCount: Int
    /// Optional so app processes can still decode a status file written by a
    /// worker from before candidate-corpus telemetry was added.
    public let trainingCandidateCorpusProgress: TrainingCandidateCorpusProgress?
    public let runID: UUID?
    public let runKind: TrainingCorpusRunKind?
    public let runState: TrainingCorpusRunState?
    public let runTargetCount: Int
    /// The pass over the run's targets in progress (1-based) and the run's
    /// pass count; `runTargetCount` counts every pass's visits.
    public let runEpoch: Int?
    public let runEpochCount: Int?
    public let attemptedTargetCount: Int
    public let incorporatedTargetCount: Int
    public let replayCount: Int
    public let skippedTargetCount: Int
    public let failedTargetCount: Int
    public let rejectedCandidateCount: Int
    public let aggregateTargetLoss: Double?
    public let aggregateValidationLoss: Double?
    public let checkpointLifecycle: TrainingCheckpointLifecycle?
    public let nextEligibleReason: TrainingReadiness
    public let resourceWaitReason: String?
    public let isPaused: Bool
    public let lastError: String?
    public let isEngineReady: Bool

    public init(
        phase: WorkerTrainingPhaseSnapshot,
        lastRunAt: Date? = nil,
        lastDurationSeconds: Double? = nil,
        totalSteps: Int = 0,
        adapterLoadedAt: Date? = nil,
        adapterStep: Int? = nil,
        pendingTrainingTargetCount: Int = 0,
        trainingCandidateCorpusProgress: TrainingCandidateCorpusProgress? = nil,
        runID: UUID? = nil,
        runKind: TrainingCorpusRunKind? = nil,
        runState: TrainingCorpusRunState? = nil,
        runTargetCount: Int = 0,
        runEpoch: Int? = nil,
        runEpochCount: Int? = nil,
        attemptedTargetCount: Int = 0,
        incorporatedTargetCount: Int = 0,
        replayCount: Int = 0,
        skippedTargetCount: Int = 0,
        failedTargetCount: Int = 0,
        rejectedCandidateCount: Int = 0,
        aggregateTargetLoss: Double? = nil,
        aggregateValidationLoss: Double? = nil,
        checkpointLifecycle: TrainingCheckpointLifecycle? = nil,
        nextEligibleReason: TrainingReadiness = .waitingForModel,
        resourceWaitReason: String? = nil,
        isPaused: Bool = false,
        lastError: String? = nil,
        isEngineReady: Bool = false
    ) {
        self.phase = phase
        self.lastRunAt = lastRunAt
        self.lastDurationSeconds = lastDurationSeconds
        self.totalSteps = totalSteps
        self.adapterLoadedAt = adapterLoadedAt
        self.adapterStep = adapterStep
        self.pendingTrainingTargetCount = pendingTrainingTargetCount
        self.trainingCandidateCorpusProgress = trainingCandidateCorpusProgress
        self.runID = runID
        self.runKind = runKind
        self.runState = runState
        self.runTargetCount = runTargetCount
        self.runEpoch = runEpoch
        self.runEpochCount = runEpochCount
        self.attemptedTargetCount = attemptedTargetCount
        self.incorporatedTargetCount = incorporatedTargetCount
        self.replayCount = replayCount
        self.skippedTargetCount = skippedTargetCount
        self.failedTargetCount = failedTargetCount
        self.rejectedCandidateCount = rejectedCandidateCount
        self.aggregateTargetLoss = aggregateTargetLoss
        self.aggregateValidationLoss = aggregateValidationLoss
        self.checkpointLifecycle = checkpointLifecycle
        self.nextEligibleReason = nextEligibleReason
        self.resourceWaitReason = resourceWaitReason
        self.isPaused = isPaused
        self.lastError = lastError
        self.isEngineReady = isEngineReady
    }
}

public enum WorkerResourceMode: String, Codable, CaseIterable, Sendable {
    case full
    case throttled
    case paused
}

public enum WorkerPipelineBlockReason: String, Codable, CaseIterable, Sendable {
    case embedding
    case placement
    case reindexing
    case queuedBGEWork
}

public struct WorkerPipelineReadinessSnapshot: Codable, Equatable, Sendable {
    public let isComplete: Bool
    public let blockingReason: WorkerPipelineBlockReason?

    public init(
        isComplete: Bool,
        blockingReason: WorkerPipelineBlockReason?
    ) {
        self.isComplete = isComplete
        self.blockingReason = blockingReason
    }

    private enum CodingKeys: String, CodingKey {
        case isComplete
        case blockingReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isComplete = try container.decode(Bool.self, forKey: .isComplete)
        let rawReason = try container.decodeIfPresent(String.self, forKey: .blockingReason)
        blockingReason = rawReason.flatMap(WorkerPipelineBlockReason.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isComplete, forKey: .isComplete)
        try container.encodeIfPresent(blockingReason?.rawValue, forKey: .blockingReason)
    }

    public static let complete = Self(isComplete: true, blockingReason: nil)

    public static func blocked(
        _ reason: WorkerPipelineBlockReason
    ) -> Self {
        Self(isComplete: false, blockingReason: reason)
    }
}

public struct WorkerResourceStatusSnapshot: Codable, Equatable, Sendable {
    public struct SemanticValue: Equatable, Sendable {
        public let mode: WorkerResourceMode
        public let embeddingLaneLimit: Int?
        public let embeddingLaneCapacity: Int?
        public let allowsBackgroundTraining: Bool?
        public let allowsBackgroundGeneration: Bool?
        public let allowsUserInitiatedWork: Bool?
        public let allowsInterpretation: Bool?
        public let pipelineReadiness: WorkerPipelineReadinessSnapshot

        public init(
            mode: WorkerResourceMode,
            embeddingLaneLimit: Int?,
            embeddingLaneCapacity: Int?,
            allowsBackgroundTraining: Bool?,
            allowsBackgroundGeneration: Bool?,
            allowsUserInitiatedWork: Bool?,
            allowsInterpretation: Bool?,
            pipelineReadiness: WorkerPipelineReadinessSnapshot
        ) {
            self.mode = mode
            self.embeddingLaneLimit = embeddingLaneLimit
            self.embeddingLaneCapacity = embeddingLaneCapacity
            self.allowsBackgroundTraining = allowsBackgroundTraining
            self.allowsBackgroundGeneration = allowsBackgroundGeneration
            self.allowsUserInitiatedWork = allowsUserInitiatedWork
            self.allowsInterpretation = allowsInterpretation
            self.pipelineReadiness = pipelineReadiness
        }
    }

    public let mode: WorkerResourceMode
    public let embeddingLaneLimit: Int?
    public let embeddingLaneCapacity: Int?
    public let allowsBackgroundTraining: Bool?
    public let allowsBackgroundGeneration: Bool?
    public let allowsUserInitiatedWork: Bool?
    public let allowsInterpretation: Bool?
    public let pipelineReadiness: WorkerPipelineReadinessSnapshot
    public let evaluatedAt: Date

    public init(
        mode: WorkerResourceMode,
        embeddingLaneLimit: Int?,
        embeddingLaneCapacity: Int?,
        allowsBackgroundTraining: Bool?,
        allowsBackgroundGeneration: Bool?,
        allowsUserInitiatedWork: Bool?,
        allowsInterpretation: Bool?,
        pipelineReadiness: WorkerPipelineReadinessSnapshot,
        evaluatedAt: Date
    ) {
        self.mode = mode
        self.embeddingLaneLimit = embeddingLaneLimit
        self.embeddingLaneCapacity = embeddingLaneCapacity
        self.allowsBackgroundTraining = allowsBackgroundTraining
        self.allowsBackgroundGeneration = allowsBackgroundGeneration
        self.allowsUserInitiatedWork = allowsUserInitiatedWork
        self.allowsInterpretation = allowsInterpretation
        self.pipelineReadiness = pipelineReadiness
        self.evaluatedAt = evaluatedAt
    }

    public var semanticValue: SemanticValue {
        SemanticValue(
            mode: mode,
            embeddingLaneLimit: embeddingLaneLimit,
            embeddingLaneCapacity: embeddingLaneCapacity,
            allowsBackgroundTraining: allowsBackgroundTraining,
            allowsBackgroundGeneration: allowsBackgroundGeneration,
            allowsUserInitiatedWork: allowsUserInitiatedWork,
            allowsInterpretation: allowsInterpretation,
            pipelineReadiness: pipelineReadiness
        )
    }
}

public enum WorkerCommandKind: String, Codable, Equatable, Sendable {
    case cancelTraining
    case resetTrainingToBase
    case generateText
    case cancelGeneration
    case embedQueries
    case cancelQueryEmbedding
    case requestInteractiveQwenModelTurn
    case requestInteractiveBGEModelTurn
    case selectGenerationModel
    case cancelGenerationModelPreparation

    public var requiresLiveConnection: Bool {
        self == .generateText || self == .embedQueries
    }
}

public enum WorkerGenerationActivityKind: String, Codable, Equatable, Sendable {
    case generating
    case summarizing
    case translating
    case asking
    case drafting
    /// Composer source triage — fuzzy candidate filtering and automatic
    /// web-research planning that build the source list before the user ever
    /// sees the Continue button. Distinct from `.questioning`, which covers
    /// the clarification-question pass that runs after sources are submitted.
    case compiling
    case questioning
    case categorizing
    case extracting
    case remembering
    /// Account-memory distillation — the "dreaming" pass. The qwen worker runs
    /// the distillation generations; tagging them lets the worker self-report as
    /// dreaming so the activity strip shows the dreaming gauge and label instead
    /// of the generic generating spectrum.
    case dreaming
    case refining
    case learning
    /// Semantic title generation for Meaning-lens email clusters.
    case clustering
    /// Signature-studio generations (Settings → Signatures): designing,
    /// regenerating, or revising an email signature.
    case designing

    public var label: String { rawValue }
}

/// Tokenizer-measured context usage for the generation request currently
/// owned by the Qwen worker. Optional on `WorkerStatusSnapshot` so status
/// files written by earlier workers remain decodable.
public struct WorkerPromptUsageSnapshot: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let maximumContextTokens: Int
    public let maximumOutputTokens: Int

    public init(
        inputTokens: Int,
        maximumContextTokens: Int,
        maximumOutputTokens: Int
    ) {
        self.inputTokens = max(0, inputTokens)
        self.maximumContextTokens = max(0, maximumContextTokens)
        self.maximumOutputTokens = max(0, maximumOutputTokens)
    }

    public var inputFraction: Double {
        guard maximumContextTokens > 0 else { return 0 }
        return Double(inputTokens) / Double(maximumContextTokens)
    }
}

/// Sampling controls for one generation request. Every lane in the app is
/// deterministic by default; only surfaces whose whole point is design
/// variation opt into `.creative`.
public struct GenerationSampling: Codable, Equatable, Sendable {
    public var temperature: Float
    public var topP: Float
    public var topK: Int?
    public var minP: Float?
    public var repetitionPenalty: Float?
    public var presencePenalty: Float?
    public var seed: UInt64?
    /// For a JSON answer: the most commas one object may hold before it
    /// closes. A list the model keeps extending (counting through IDs until
    /// the token limit) is closed at the limit instead. Nil leaves the
    /// answer unbounded; never set it for free text, whose commas are words.
    public var objectCommaLimit: Int?

    public init(
        temperature: Float,
        topP: Float,
        topK: Int? = nil,
        minP: Float? = nil,
        repetitionPenalty: Float? = nil,
        presencePenalty: Float? = nil,
        seed: UInt64? = nil,
        objectCommaLimit: Int? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.presencePenalty = presencePenalty
        self.seed = seed
        self.objectCommaLimit = objectCommaLimit
    }

    /// The engine default every non-design lane uses: drafting, Ask,
    /// triage, summarization, extraction. Reproducible output matters more
    /// than variety there.
    public static let deterministic = GenerationSampling(temperature: 0.1, topP: 1.0)

    /// Qwen3.8 preserved-thinking decode. These are the model's documented
    /// text-generation settings for thinking mode; the final draft remains
    /// tightly constrained by its grounded prompt and stop protocol.
    public static let reasoning = GenerationSampling(
        temperature: 1.0,
        topP: 0.95,
        topK: 20,
        minP: 0
    )

    /// Qwen3.5 thinking-mode settings for general tasks. Low effort is
    /// controlled by the conversation prompt; these controls keep decoding
    /// on the model family's documented non-greedy path.
    public static let qwen35Reasoning = GenerationSampling(
        temperature: 1.0,
        topP: 0.95,
        topK: 20,
        minP: 0,
        presencePenalty: 1.5
    )

    /// Original Qwen3 thinking-mode settings. Catalog models currently use
    /// Qwen3.5 or Qwen3.8, but this preserves correct behavior for compatible
    /// Qwen3 checkpoints selected outside the catalog.
    public static let qwen3Reasoning = GenerationSampling(
        temperature: 0.6,
        topP: 0.95,
        topK: 20,
        minP: 0
    )

    /// Signature design only. The studio's whole contract is that three
    /// tiers and each regenerate produce materially different designs, and
    /// a near-greedy decode collapses them onto one another.
    ///
    /// Tuned against the live local model, not copied from guidance written
    /// for frontier models. At 0.9 the small Qwen loses HTML syntax — it
    /// drops the closing `">` of a style attribute often enough that most
    /// designs arrived malformed, and a signature is structured output
    /// before it is a creative one. 0.4 varies the design while holding the
    /// markup together. Variation does not rest on temperature alone: the
    /// per-tier field lists, the attempt line, and the design history all
    /// push each generation somewhere new.
    public static let creative = GenerationSampling(temperature: 0.4, topP: 0.9)
}

public struct WorkerGenerationRequest: Codable, Equatable, Sendable {
    public let prompt: String
    /// Structured turns for models that support conversational continuation.
    /// Optional so requests from older app builds remain decodable.
    public let conversation: GenerationConversation?
    /// The checkpointed form of `prompt`, for requests the caller split for
    /// prompt-state reuse. Nil for plain and conversational requests. A
    /// request file from a build before checkpoints decodes with nil here
    /// (its old prefix keys are ignored) and runs as a plain prompt from
    /// `prompt`, which always holds the full text.
    public let cachedPrompt: PrefixCachedPrompt?
    public let lane: InteractiveGenerationLane?
    public let activityKind: WorkerGenerationActivityKind?
    /// Optional for compatibility with request files written by an older
    /// app, and because nil is the correct default: the worker falls back
    /// to `.deterministic`.
    public let sampling: GenerationSampling?
    /// Optional for compatibility with request files written by an older app.
    /// Missing values resolve to `.base` so adapter use fails closed.
    public let personalization: GenerationPersonalizationScope?
    public let maxTokens: Int
    /// Wall-clock instant captured immediately before live XPC submission.
    /// The worker echoes it through the response for pickup-latency metrics.
    public let enqueuedAt: Date?
    /// Absolute deadline shared with the worker.
    public let deadline: Date?

    public init(
        prompt: String,
        maxTokens: Int,
        lane: InteractiveGenerationLane? = .userInteractive,
        activityKind: WorkerGenerationActivityKind? = nil,
        personalization: GenerationPersonalizationScope = .base,
        sampling: GenerationSampling? = nil,
        enqueuedAt: Date = Date(),
        deadline: Date? = nil
    ) {
        self.prompt = prompt
        self.conversation = nil
        self.cachedPrompt = nil
        self.lane = lane
        self.activityKind = activityKind
        self.personalization = personalization
        self.sampling = sampling
        self.maxTokens = maxTokens
        self.enqueuedAt = enqueuedAt
        self.deadline = deadline
    }

    public init(
        cachedPrompt: PrefixCachedPrompt,
        maxTokens: Int,
        lane: InteractiveGenerationLane? = .userInteractive,
        activityKind: WorkerGenerationActivityKind? = nil,
        personalization: GenerationPersonalizationScope = .base,
        sampling: GenerationSampling? = nil,
        enqueuedAt: Date = Date(),
        deadline: Date? = nil
    ) {
        self.prompt = cachedPrompt.prompt
        self.conversation = nil
        self.cachedPrompt = cachedPrompt
        self.lane = lane
        self.activityKind = activityKind
        self.personalization = personalization
        self.sampling = sampling
        self.maxTokens = maxTokens
        self.enqueuedAt = enqueuedAt
        self.deadline = deadline
    }

    public init(
        conversation: GenerationConversation,
        maxTokens: Int,
        lane: InteractiveGenerationLane? = .userInteractive,
        activityKind: WorkerGenerationActivityKind? = nil,
        personalization: GenerationPersonalizationScope = .base,
        sampling: GenerationSampling? = nil,
        enqueuedAt: Date = Date(),
        deadline: Date? = nil
    ) {
        self.prompt = conversation.fallbackPrompt
        self.conversation = conversation
        self.cachedPrompt = nil
        self.lane = lane
        self.activityKind = activityKind
        self.personalization = personalization
        self.sampling = sampling
        self.maxTokens = maxTokens
        self.enqueuedAt = enqueuedAt
        self.deadline = deadline
    }

    public var resolvedPrompt: String {
        cachedPrompt?.prompt ?? prompt
    }

    public var isInteractiveSummarizationFastLane: Bool {
        guard let cacheKey = cachedPrompt?.cacheKey else { return false }
        return Self.interactiveSummarizationCacheKeys.contains(cacheKey)
    }

    public var resolvedLane: InteractiveGenerationLane {
        lane ?? .userInteractive
    }

    public var resolvedPersonalization: GenerationPersonalizationScope {
        personalization ?? .base
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        guard let deadline else { return false }
        return date >= deadline
    }

    public var resolvedActivityKind: WorkerGenerationActivityKind {
        if let activityKind {
            return activityKind
        }
        guard let cacheKey = cachedPrompt?.cacheKey else {
            return .generating
        }
        return Self.activityKind(forCacheKey: cacheKey)
    }

    public var activityLabel: String {
        resolvedActivityKind.label
    }

    private static let interactiveSummarizationCacheKeys: Set<String> = [
        "email-body-summary-v1",
        "email-body-summary-v2",
        "email-summary-only-v1",
        "context-orientation-v1",
        "context-correspondent-relationship-v1",
        "attachment-summary-v1",
        "attachment-summary-v2",
        "project-summary-v1"
    ]

    private static func activityKind(forCacheKey cacheKey: String) -> WorkerGenerationActivityKind {
        if cacheKey.hasPrefix("email-translation-v1:") {
            return .translating
        }
        if cacheKey == "translation-dream-v2" {
            return .remembering
        }
        if cacheKey.hasPrefix("email-body-summary-v")
            || cacheKey.hasPrefix("email-summary-only-v")
            || cacheKey == "context-orientation-v1"
            || cacheKey == "context-correspondent-relationship-v1"
            || cacheKey == "project-summary-v1"
            || cacheKey.hasPrefix("attachment-summary-v") {
            return .summarizing
        }
        if cacheKey.hasPrefix("draft-questions-") {
            return .questioning
        }
        if cacheKey.hasPrefix("drafting-rules-v") {
            return .learning
        }
        if cacheKey.hasPrefix("receipt-extraction-v") {
            return .extracting
        }
        if cacheKey.hasPrefix("email-interpretation-v")
            || cacheKey.hasPrefix("email-interpretation-metadata-v") {
            return .categorizing
        }
        // Must match MemoryDistiller.distillVersion (OhiaML isn't importable here).
        if cacheKey == "memory-distill-v1" {
            return .dreaming
        }
        return .generating
    }
}

public enum WorkerGenerationResponseStatus: String, Codable, Equatable, Sendable {
    case success
    case cancelled
    case modelNotLoaded
    case failed
}

public struct WorkerGenerationResponseSnapshot: Codable, Equatable, Sendable {
    public let personalization: GenerationPersonalization?
    public let diagnostics: GenerationDiagnostics?
    public let responseKind: WorkerCommandKind
    public let commandID: UUID
    public let status: WorkerGenerationResponseStatus
    public let text: String?
    /// Hidden reasoning is separate from user-visible text by construction.
    /// Optional for responses written by older worker builds.
    public let reasoningContent: String?
    /// Runtime state that produced the hidden reasoning.
    public let continuationFingerprint: String?
    /// Why model decoding stopped. Optional for responses written by older
    /// worker builds.
    public let stopReason: GenerationStopReason?
    public let errorMessage: String?
    public let completedAt: Date
    /// Set by the worker the moment `consumeCommand` returned the request.
    /// Optional so older worker builds and stale on-disk responses still decode.
    public let pickedUpAt: Date?
    /// Set by the worker immediately before invoking the model's `generate`.
    public let decodeStartedAt: Date?
    /// Set by the worker immediately after `generate` returned.
    public let decodeFinishedAt: Date?

    public init(
        commandID: UUID,
        status: WorkerGenerationResponseStatus,
        text: String? = nil,
        reasoningContent: String? = nil,
        continuationFingerprint: String? = nil,
        stopReason: GenerationStopReason? = nil,
        errorMessage: String? = nil,
        completedAt: Date = Date(),
        pickedUpAt: Date? = nil,
        decodeStartedAt: Date? = nil,
        decodeFinishedAt: Date? = nil,
        personalization: GenerationPersonalization? = nil,
        diagnostics: GenerationDiagnostics? = nil
    ) {
        self.responseKind = .generateText
        self.commandID = commandID
        self.status = status
        self.text = text
        self.reasoningContent = reasoningContent
        self.continuationFingerprint = continuationFingerprint
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.completedAt = completedAt
        self.pickedUpAt = pickedUpAt
        self.decodeStartedAt = decodeStartedAt
        self.decodeFinishedAt = decodeFinishedAt
        self.personalization = personalization
        self.diagnostics = diagnostics
    }
}

/// One request-scoped IPC payload for all query texts needed by a retrieval
/// operation. Batching here avoids one command/response round trip per query.
public struct WorkerQueryEmbeddingRequest: Codable, Equatable, Sendable {
    public let texts: [String]
    public let embeddingDimension: Int
    public let embeddingVersion: String
    public let enqueuedAt: Date
    public let deadline: Date

    public init(
        texts: [String],
        embeddingDimension: Int,
        embeddingVersion: String,
        enqueuedAt: Date = Date(),
        deadline: Date
    ) {
        self.texts = texts
        self.embeddingDimension = embeddingDimension
        self.embeddingVersion = embeddingVersion
        self.enqueuedAt = enqueuedAt
        self.deadline = deadline
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        date >= deadline
    }
}

public enum WorkerQueryEmbeddingResponseStatus: String, Codable, Equatable, Sendable {
    case success
    case cancelled
    case modelNotLoaded
    case failed
}

public struct WorkerQueryEmbeddingResponseSnapshot: Codable, Equatable, Sendable {
    public let responseKind: WorkerCommandKind
    public let commandID: UUID
    public let status: WorkerQueryEmbeddingResponseStatus
    public let embeddings: [[Float]?]?
    public let embeddingDimension: Int
    public let embeddingVersion: String
    public let errorMessage: String?
    public let completedAt: Date

    public init(
        commandID: UUID,
        status: WorkerQueryEmbeddingResponseStatus,
        embeddings: [[Float]?]? = nil,
        embeddingDimension: Int,
        embeddingVersion: String,
        errorMessage: String? = nil,
        completedAt: Date = Date()
    ) {
        self.responseKind = .embedQueries
        self.commandID = commandID
        self.status = status
        self.embeddings = embeddings
        self.embeddingDimension = embeddingDimension
        self.embeddingVersion = embeddingVersion
        self.errorMessage = errorMessage
        self.completedAt = completedAt
    }
}

public struct WorkerInteractiveGenerationSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let reason: String
    public let lane: InteractiveGenerationLane
    public let startedAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        reason: String,
        lane: InteractiveGenerationLane = .userInteractive,
        startedAt: Date = Date(),
        expiresAt: Date
    ) {
        self.id = id
        self.reason = reason
        self.lane = lane
        self.startedAt = startedAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case reason
        case lane
        case startedAt
        case expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.reason = try container.decode(String.self, forKey: .reason)
        self.lane = try container.decodeIfPresent(InteractiveGenerationLane.self, forKey: .lane)
            ?? .userInteractive
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }

    public func isActive(at date: Date = Date()) -> Bool {
        expiresAt > date
    }
}

public struct WorkerCommandSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: WorkerCommandKind
    public let issuedAt: Date
    public let message: String?
    public let generationRequest: WorkerGenerationRequest?
    public let queryEmbeddingRequest: WorkerQueryEmbeddingRequest?
    /// Request-specific target for cancellation commands. Optional so commands
    /// persisted by older app builds continue to decode.
    public let targetCommandID: UUID?

    public init(
        id: UUID = UUID(),
        kind: WorkerCommandKind,
        issuedAt: Date = Date(),
        message: String? = nil,
        generationRequest: WorkerGenerationRequest? = nil,
        queryEmbeddingRequest: WorkerQueryEmbeddingRequest? = nil,
        targetCommandID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.issuedAt = issuedAt
        self.message = message
        self.generationRequest = generationRequest
        self.queryEmbeddingRequest = queryEmbeddingRequest
        self.targetCommandID = targetCommandID
    }

    public var isInteractiveSummarizationFastLane: Bool {
        kind == .generateText
            && generationRequest?.isInteractiveSummarizationFastLane == true
    }

    public var isUserInteractiveGeneration: Bool {
        kind == .generateText
            && generationRequest?.resolvedLane == .userInteractive
    }

    public var isLensAssistGeneration: Bool {
        kind == .generateText
            && generationRequest?.resolvedLane == .lensAssist
    }

    public var cancelledGenerationCommandID: UUID? {
        guard kind == .cancelGeneration else { return nil }
        return targetCommandID
    }

    public var isQueryEmbeddingRequest: Bool {
        kind == .embedQueries && queryEmbeddingRequest != nil
    }

    public var cancelledQueryEmbeddingCommandID: UUID? {
        guard kind == .cancelQueryEmbedding else { return nil }
        return targetCommandID
    }
}

public struct WorkerStatusSnapshot: Codable, Equatable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case role
        case processName
        case pid
        case parentPID
        case state
        case currentJobType
        case currentJobDescription
        case promptUsage
        case throttle
        case statusMessage
        case model
        case training
        case resource
        case startedAt
        case updatedAt
        case completionStreamID
        case completionSequence
        case recentCompletions
        case imapActivityStreamID
        case imapActivitySequence
        case recentIMAPActivities
    }

    public struct SemanticValue: Equatable, Sendable {
        public let role: WorkerRole
        public let processName: String
        public let pid: Int32?
        public let parentPID: Int32?
        public let state: WorkerState
        public let currentJobType: String?
        public let currentJobDescription: String?
        public let promptUsage: WorkerPromptUsageSnapshot?
        public let throttle: WorkerThrottleSnapshot
        public let statusMessage: String?
        public let model: WorkerModelStatusSnapshot?
        public let training: WorkerTrainingStatusSnapshot?
        public let resource: WorkerResourceStatusSnapshot.SemanticValue?
        public let startedAt: Date?
    }

    public var id: WorkerRole { role }

    public let role: WorkerRole
    public let processName: String
    public let pid: Int32?
    public let parentPID: Int32?
    public let state: WorkerState
    public let currentJobType: String?
    public let currentJobDescription: String?
    public let promptUsage: WorkerPromptUsageSnapshot?
    public let throttle: WorkerThrottleSnapshot
    public let statusMessage: String?
    public let model: WorkerModelStatusSnapshot?
    public let training: WorkerTrainingStatusSnapshot?
    public let resource: WorkerResourceStatusSnapshot?
    public let startedAt: Date?
    public let updatedAt: Date
    /// Identifies one worker-runtime completion stream. A worker restart uses
    /// a new value so a reset sequence cannot be mistaken for lost events.
    /// Both fields remain optional for status files written by older workers.
    public let completionStreamID: UUID?
    /// Highest completion sequence committed to this status snapshot.
    public let completionSequence: UInt64?
    public let recentCompletions: [WorkerCompletionSnapshot]
    /// Independent stream for short-lived IMAP lifecycle and command states.
    /// It intentionally does not share the completion watermark: a burst of
    /// mailbox states cannot evict or create gaps in pipeline completions.
    public let imapActivityStreamID: UUID?
    public let imapActivitySequence: UInt64?
    public let recentIMAPActivities: [WorkerIMAPActivitySnapshot]

    public init(
        role: WorkerRole,
        processName: String? = nil,
        pid: Int32? = nil,
        parentPID: Int32? = nil,
        state: WorkerState = .unknown,
        currentJobType: String? = nil,
        currentJobDescription: String? = nil,
        promptUsage: WorkerPromptUsageSnapshot? = nil,
        throttle: WorkerThrottleSnapshot = .notThrottled,
        statusMessage: String? = nil,
        model: WorkerModelStatusSnapshot? = nil,
        training: WorkerTrainingStatusSnapshot? = nil,
        resource: WorkerResourceStatusSnapshot? = nil,
        startedAt: Date? = nil,
        updatedAt: Date = Date(),
        completionStreamID: UUID? = nil,
        completionSequence: UInt64? = nil,
        recentCompletions: [WorkerCompletionSnapshot] = [],
        imapActivityStreamID: UUID? = nil,
        imapActivitySequence: UInt64? = nil,
        recentIMAPActivities: [WorkerIMAPActivitySnapshot] = []
    ) {
        self.role = role
        self.processName = processName ?? role.processName
        self.pid = pid
        self.parentPID = parentPID
        self.state = state
        self.currentJobType = currentJobType
        self.currentJobDescription = currentJobDescription
        self.promptUsage = promptUsage
        self.throttle = throttle
        self.statusMessage = statusMessage
        self.model = model
        self.training = training
        self.resource = resource
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completionStreamID = completionStreamID
        self.completionSequence = completionSequence
        self.recentCompletions = recentCompletions
        self.imapActivityStreamID = imapActivityStreamID
        self.imapActivitySequence = imapActivitySequence
        self.recentIMAPActivities = recentIMAPActivities
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        role = try values.decode(WorkerRole.self, forKey: .role)
        processName = try values.decodeIfPresent(String.self, forKey: .processName)
            ?? role.processName
        pid = try values.decodeIfPresent(Int32.self, forKey: .pid)
        parentPID = try values.decodeIfPresent(Int32.self, forKey: .parentPID)
        state = try values.decodeIfPresent(WorkerState.self, forKey: .state) ?? .unknown
        currentJobType = try values.decodeIfPresent(String.self, forKey: .currentJobType)
        currentJobDescription = try values.decodeIfPresent(
            String.self,
            forKey: .currentJobDescription
        )
        promptUsage = try values.decodeIfPresent(
            WorkerPromptUsageSnapshot.self,
            forKey: .promptUsage
        )
        throttle = try values.decodeIfPresent(
            WorkerThrottleSnapshot.self,
            forKey: .throttle
        ) ?? .notThrottled
        statusMessage = try values.decodeIfPresent(String.self, forKey: .statusMessage)
        model = try values.decodeIfPresent(WorkerModelStatusSnapshot.self, forKey: .model)
        training = try values.decodeIfPresent(
            WorkerTrainingStatusSnapshot.self,
            forKey: .training
        )
        resource = try values.decodeIfPresent(
            WorkerResourceStatusSnapshot.self,
            forKey: .resource
        )
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        completionStreamID = try values.decodeIfPresent(UUID.self, forKey: .completionStreamID)
        completionSequence = try values.decodeIfPresent(UInt64.self, forKey: .completionSequence)
        recentCompletions = try values.decodeIfPresent(
            [WorkerCompletionSnapshot].self,
            forKey: .recentCompletions
        ) ?? []
        imapActivityStreamID = try values.decodeIfPresent(
            UUID.self,
            forKey: .imapActivityStreamID
        )
        imapActivitySequence = try values.decodeIfPresent(
            UInt64.self,
            forKey: .imapActivitySequence
        )
        recentIMAPActivities = try values.decodeIfPresent(
            [WorkerIMAPActivitySnapshot].self,
            forKey: .recentIMAPActivities
        ) ?? []
    }

    public func replacing(
        pid: Int32? = nil,
        parentPID: Int32? = nil,
        state: WorkerState? = nil,
        currentJobType: String? = nil,
        currentJobDescription: String? = nil,
        promptUsage: WorkerPromptUsageSnapshot? = nil,
        throttle: WorkerThrottleSnapshot? = nil,
        statusMessage: String? = nil,
        model: WorkerModelStatusSnapshot? = nil,
        training: WorkerTrainingStatusSnapshot? = nil,
        resource: WorkerResourceStatusSnapshot? = nil,
        startedAt: Date? = nil,
        updatedAt: Date = Date(),
        completionStreamID: UUID? = nil,
        completionSequence: UInt64? = nil,
        recentCompletions: [WorkerCompletionSnapshot]? = nil,
        imapActivityStreamID: UUID? = nil,
        imapActivitySequence: UInt64? = nil,
        recentIMAPActivities: [WorkerIMAPActivitySnapshot]? = nil
    ) -> WorkerStatusSnapshot {
        WorkerStatusSnapshot(
            role: role,
            processName: processName,
            pid: pid ?? self.pid,
            parentPID: parentPID ?? self.parentPID,
            state: state ?? self.state,
            currentJobType: currentJobType ?? self.currentJobType,
            currentJobDescription: currentJobDescription ?? self.currentJobDescription,
            promptUsage: promptUsage ?? self.promptUsage,
            throttle: throttle ?? self.throttle,
            statusMessage: statusMessage ?? self.statusMessage,
            model: model ?? self.model,
            training: training ?? self.training,
            resource: resource ?? self.resource,
            startedAt: startedAt ?? self.startedAt,
            updatedAt: updatedAt,
            completionStreamID: completionStreamID ?? self.completionStreamID,
            completionSequence: completionSequence ?? self.completionSequence,
            recentCompletions: recentCompletions ?? self.recentCompletions,
            imapActivityStreamID: imapActivityStreamID ?? self.imapActivityStreamID,
            imapActivitySequence: imapActivitySequence ?? self.imapActivitySequence,
            recentIMAPActivities: recentIMAPActivities ?? self.recentIMAPActivities
        )
    }

    public var semanticValue: SemanticValue {
        SemanticValue(
            role: role,
            processName: processName,
            pid: pid,
            parentPID: parentPID,
            state: state,
            currentJobType: currentJobType,
            currentJobDescription: currentJobDescription,
            promptUsage: promptUsage,
            throttle: throttle,
            statusMessage: statusMessage,
            model: model,
            training: training,
            resource: resource?.semanticValue,
            startedAt: startedAt
        )
    }

    public func isHeartbeatStale(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) > maxAge
    }

    public func hasLoadedModelInRunningProcess(processIsRunning: Bool) -> Bool {
        processIsRunning && model?.state.isReady == true
    }
}

public struct WorkerFleetStatusSnapshot: Codable, Equatable, Sendable {
    public let workers: [WorkerStatusSnapshot]
    public let updatedAt: Date

    public init(workers: [WorkerStatusSnapshot], updatedAt: Date = Date()) {
        self.workers = workers.sorted { $0.role.rawValue < $1.role.rawValue }
        self.updatedAt = updatedAt
    }

    public func status(for role: WorkerRole) -> WorkerStatusSnapshot? {
        workers.first { $0.role == role }
    }
}
