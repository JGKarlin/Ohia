import Foundation
import OhiaCore
import OhiaScheduler

struct WorkerResourceStatusProjection: Equatable, Sendable {
    let resource: WorkerResourceStatusSnapshot
    let throttle: WorkerThrottleSnapshot
}

enum WorkerResourceStatusMapper {
    static func mode(_ mode: BackgroundModelMode) -> WorkerResourceMode {
        switch mode {
        case .full:
            return .full
        case .throttled:
            return .throttled
        case .paused:
            return .paused
        }
    }

    static func blockReason(
        _ reason: PipelineReadinessBlockReason
    ) -> WorkerPipelineBlockReason {
        switch reason {
        case .embedding:
            return .embedding
        case .placement:
            return .placement
        case .reindexing:
            return .reindexing
        case .queuedBGEWork:
            return .queuedBGEWork
        }
    }

    static func projection(
        role: WorkerRole,
        snapshot: ModelResourceSnapshot
    ) -> WorkerResourceStatusProjection {
        WorkerResourceStatusProjection(
            resource: resource(role: role, snapshot: snapshot),
            throttle: throttle(role: role, snapshot: snapshot)
        )
    }

    private static func resource(
        role: WorkerRole,
        snapshot: ModelResourceSnapshot
    ) -> WorkerResourceStatusSnapshot {
        let readiness = WorkerPipelineReadinessSnapshot(
            isComplete: snapshot.bgeStatus.isComplete,
            blockingReason: snapshot.bgeStatus.blockingReason.map(blockReason)
        )

        switch role {
        case .bge:
            return WorkerResourceStatusSnapshot(
                mode: mode(snapshot.decision.bge.modelMode),
                embeddingLaneLimit: snapshot.decision.bge.embeddingLaneLimit,
                embeddingLaneCapacity: snapshot.maximumEmbeddingLanes,
                allowsBackgroundTraining: nil,
                allowsBackgroundGeneration: nil,
                allowsUserInitiatedWork: nil,
                allowsInterpretation: nil,
                pipelineReadiness: readiness,
                evaluatedAt: snapshot.evaluatedAt
            )
        case .qwen:
            return WorkerResourceStatusSnapshot(
                mode: mode(snapshot.decision.qwen.modelMode),
                embeddingLaneLimit: nil,
                embeddingLaneCapacity: nil,
                allowsBackgroundTraining:
                    snapshot.decision.qwen.allowsBackgroundTraining,
                allowsBackgroundGeneration:
                    snapshot.decision.qwen.allowsBackgroundGeneration,
                allowsUserInitiatedWork:
                    snapshot.decision.qwen.allowsUserInitiatedWork,
                allowsInterpretation:
                    snapshot.decision.modelComputeBudget.allows(
                        .qwenInterpretation
                    ),
                pipelineReadiness: readiness,
                evaluatedAt: snapshot.evaluatedAt
            )
        }
    }

    private static func throttle(
        role: WorkerRole,
        snapshot: ModelResourceSnapshot
    ) -> WorkerThrottleSnapshot {
        let decision = snapshot.decision
        let isThrottled: Bool

        switch role {
        case .bge:
            isThrottled = decision.shouldPauseAll
                || decision.bge.modelMode != .full
                || decision.bge.embeddingLaneLimit < snapshot.maximumEmbeddingLanes
                || decision.bge.allowsModelHeavyWork == false
        case .qwen:
            let allowsQwenInference = decision.qwen.allowsUserInitiatedWork
                && (
                    decision.qwen.allowsBackgroundGeneration
                    || decision.modelComputeBudget.allows(.qwenInteractive)
                    || decision.modelComputeBudget.allows(.qwenInterpretation)
                )
            isThrottled = decision.shouldPauseAll
                || decision.qwen.modelMode != .full
                || allowsQwenInference == false
        }

        return WorkerThrottleSnapshot(
            isThrottled: isThrottled,
            reasons: decision.throttleReasons.map(\.rawValue)
        )
    }
}

struct WorkerHeartbeatSignature: Equatable, Sendable {
    let state: WorkerState
    let currentJobType: String?
    let currentJobDescription: String?
    let promptUsage: WorkerPromptUsageSnapshot?
    let throttle: WorkerThrottleSnapshot
    let statusMessage: String?
    let model: WorkerModelStatusSnapshot?
    let training: WorkerTrainingStatusSnapshot?
    let resource: WorkerResourceStatusSnapshot.SemanticValue?

    init(
        state: WorkerState,
        currentJobType: String?,
        currentJobDescription: String?,
        promptUsage: WorkerPromptUsageSnapshot? = nil,
        throttle: WorkerThrottleSnapshot,
        statusMessage: String?,
        model: WorkerModelStatusSnapshot?,
        training: WorkerTrainingStatusSnapshot?,
        resource: WorkerResourceStatusSnapshot?
    ) {
        self.state = state
        self.currentJobType = currentJobType
        self.currentJobDescription = currentJobDescription
        self.promptUsage = promptUsage
        self.throttle = throttle
        self.statusMessage = statusMessage
        self.model = model
        self.training = training
        self.resource = resource?.semanticValue
    }
}

struct WorkerHeartbeatWriteGate: Sendable {
    private let maximumInterval: Duration
    private var lastSignature: WorkerHeartbeatSignature?
    private var lastSuccessfulWriteAt: ContinuousClock.Instant?

    init(maximumInterval: Duration) {
        self.maximumInterval = max(.zero, maximumInterval)
    }

    func shouldWrite(
        _ signature: WorkerHeartbeatSignature,
        at instant: ContinuousClock.Instant
    ) -> Bool {
        guard let lastSignature, let lastSuccessfulWriteAt else {
            return true
        }
        if signature != lastSignature {
            return true
        }
        let elapsed = lastSuccessfulWriteAt.duration(to: instant)
        guard elapsed >= .zero else { return true }
        return elapsed >= maximumInterval
    }

    mutating func recordSuccessfulWrite(
        _ signature: WorkerHeartbeatSignature,
        at instant: ContinuousClock.Instant
    ) {
        lastSignature = signature
        lastSuccessfulWriteAt = instant
    }
}
