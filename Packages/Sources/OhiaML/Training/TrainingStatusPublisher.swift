// TrainingStatusPublisher.swift
// Single source of truth for "what is training doing right now".
// Written by TrainingOrchestrator (during a run), BackgroundScheduler
// (per tick, readiness), ModelLoadingService (adapter load), and
// Settings UI (pause toggle writeback). Read by TrainingStatusChip and
// TrainingSettingsView.

import Foundation
import Observation
import OhiaCore

@MainActor
@Observable
public final class TrainingStatusPublisher {
    public enum Phase: Sendable, Equatable {
        case idle
        case preparing
        case training(step: Int, totalSteps: Int, loss: Double)
        case checkpointing(step: Int)
        case resetting
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastRunAt: Date? = nil
    public private(set) var lastDurationSeconds: Double? = nil
    public private(set) var totalSteps: Int = 0
    public private(set) var adapterLoadedAt: Date? = nil
    public private(set) var adapterStep: Int? = nil
    public private(set) var pendingTrainingTargetCount: Int = 0
    public private(set) var trainingCandidateCorpusProgress: TrainingCandidateCorpusProgress = .empty
    public private(set) var runID: UUID?
    public private(set) var runKind: TrainingCorpusRunKind?
    public private(set) var runState: TrainingCorpusRunState?
    public private(set) var runTargetCount: Int = 0
    /// The pass in progress (1-based) and the run's pass count.
    public private(set) var runEpoch: Int?
    public private(set) var runEpochCount: Int?
    public private(set) var attemptedTargetCount: Int = 0
    public private(set) var incorporatedTargetCount: Int = 0
    public private(set) var replayCount: Int = 0
    public private(set) var skippedTargetCount: Int = 0
    public private(set) var failedTargetCount: Int = 0
    public private(set) var rejectedCandidateCount: Int = 0
    public private(set) var aggregateTargetLoss: Double?
    public private(set) var aggregateValidationLoss: Double?
    public private(set) var checkpointLifecycle: TrainingCheckpointLifecycle?
    public private(set) var nextEligibleReason: TrainingReadiness = .waitingForModel
    public private(set) var resourceWaitReason: String? = nil
    public private(set) var isPaused: Bool = false
    public private(set) var lastError: String? = nil

    /// Mirrors `TrainingEngine.isModelLoaded`. False during the initial
    /// download + load window on first run. The UI reads this to gate the
    /// Train Now button so users don't queue a training run before the
    /// model is actually ready.
    public private(set) var isEngineReady: Bool = false

    /// The generative worker uses this hook to flush transient phase changes
    /// into its cross-process status snapshot while a long-running training
    /// job still owns the worker loop.
    @ObservationIgnored
    private var workerSnapshotReporter: ((WorkerTrainingStatusSnapshot) -> Void)?

    public init() {}

    // MARK: - Setters
    // All public so the orchestrator / scheduler / model loader / UI can
    // call them from the MainActor. External callers get read-only access
    // via `private(set)` on the stored properties.

    public func setPhase(_ phase: Phase) {
        self.phase = phase
        workerSnapshotReporter?(workerSnapshot())
    }

    public func setWorkerSnapshotReporter(
        _ reporter: ((WorkerTrainingStatusSnapshot) -> Void)?
    ) {
        workerSnapshotReporter = reporter
    }

    public func completeRun(metrics: TrainingSessionMetrics, clearError: Bool) {
        self.lastRunAt = Date()
        self.lastDurationSeconds = metrics.durationSeconds
        self.totalSteps = metrics.totalSteps
        if clearError { self.lastError = nil }
    }

    public func setAdapterLoaded(step: Int, at time: Date) {
        self.adapterStep = step
        self.adapterLoadedAt = time
    }

    public func setEngineReady(_ ready: Bool) {
        self.isEngineReady = ready
    }

    public func clearAdapter() {
        self.adapterStep = nil
        self.adapterLoadedAt = nil
    }

    public func refreshCadence(pendingTrainingTargetCount: Int, readiness: TrainingReadiness) {
        self.pendingTrainingTargetCount = pendingTrainingTargetCount
        self.nextEligibleReason = readiness
    }

    public func project(
        run: TrainingCorpusRun?,
        pendingTrainingTargetCount: Int,
        checkpointLifecycle: TrainingCheckpointLifecycle?,
        trainingCandidateCorpusProgress: TrainingCandidateCorpusProgress? = nil
    ) {
        self.pendingTrainingTargetCount = pendingTrainingTargetCount
        self.checkpointLifecycle = checkpointLifecycle
        if let trainingCandidateCorpusProgress {
            self.trainingCandidateCorpusProgress = trainingCandidateCorpusProgress
        }
        guard let run else {
            runID = nil
            runKind = nil
            runState = nil
            runTargetCount = 0
            runEpoch = nil
            runEpochCount = nil
            attemptedTargetCount = 0
            incorporatedTargetCount = 0
            replayCount = 0
            skippedTargetCount = 0
            failedTargetCount = 0
            rejectedCandidateCount = 0
            aggregateTargetLoss = nil
            aggregateValidationLoss = nil
            return
        }
        runID = run.id
        runKind = run.kind
        runState = run.state
        runTargetCount = run.targetCount
        runEpochCount = run.resolvedEpochCount
        let openEpochs = run.targets.filter {
            $0.visitState == .pending || $0.visitState == .attempted
        }.map(\.resolvedEpoch)
        runEpoch = min((openEpochs.min() ?? run.resolvedEpochCount - 1) + 1, run.resolvedEpochCount)
        attemptedTargetCount = run.attemptedTargetCount
        incorporatedTargetCount = run.incorporatedTargetCount
        replayCount = run.replayCount
        skippedTargetCount = run.skippedTargetCount
        failedTargetCount = run.failedTargetCount
        rejectedCandidateCount = run.rejectedCandidateCount
        aggregateTargetLoss = run.aggregateTargetLoss
        aggregateValidationLoss = run.aggregateValidationLoss
    }

    public func setResourceWaitReason(_ reason: String?) {
        self.resourceWaitReason = reason
    }

    public func recordError(_ message: String) {
        self.lastError = message
    }

    public func clearError() {
        self.lastError = nil
    }

    public func reflectPauseToggle(_ paused: Bool) {
        self.isPaused = paused
    }

    public func syncFromState(
        _ state: TrainingRunState,
        preserveTransientError: Bool = false
    ) {
        let transientError = lastError
        self.isPaused = state.isPaused
        self.lastRunAt = state.lastRunAt
        self.lastDurationSeconds = state.lastDurationSeconds
        self.totalSteps = state.lastStepCount
        self.lastError = if preserveTransientError, state.lastError == nil {
            transientError
        } else {
            state.lastError
        }
    }

    public func workerSnapshot() -> WorkerTrainingStatusSnapshot {
        WorkerTrainingStatusSnapshot(
            phase: WorkerTrainingPhaseSnapshot(phase),
            lastRunAt: lastRunAt,
            lastDurationSeconds: lastDurationSeconds,
            totalSteps: totalSteps,
            adapterLoadedAt: adapterLoadedAt,
            adapterStep: adapterStep,
            pendingTrainingTargetCount: pendingTrainingTargetCount,
            trainingCandidateCorpusProgress: trainingCandidateCorpusProgress,
            runID: runID,
            runKind: runKind,
            runState: runState,
            runTargetCount: runTargetCount,
            runEpoch: runEpoch,
            runEpochCount: runEpochCount,
            attemptedTargetCount: attemptedTargetCount,
            incorporatedTargetCount: incorporatedTargetCount,
            replayCount: replayCount,
            skippedTargetCount: skippedTargetCount,
            failedTargetCount: failedTargetCount,
            rejectedCandidateCount: rejectedCandidateCount,
            aggregateTargetLoss: aggregateTargetLoss,
            aggregateValidationLoss: aggregateValidationLoss,
            checkpointLifecycle: checkpointLifecycle,
            nextEligibleReason: nextEligibleReason,
            resourceWaitReason: resourceWaitReason,
            isPaused: isPaused,
            lastError: lastError,
            isEngineReady: isEngineReady
        )
    }

    public func applyWorkerSnapshot(_ snapshot: WorkerTrainingStatusSnapshot) {
        self.phase = TrainingStatusPublisher.Phase(snapshot.phase)
        self.lastRunAt = snapshot.lastRunAt
        self.lastDurationSeconds = snapshot.lastDurationSeconds
        self.totalSteps = snapshot.totalSteps
        self.adapterLoadedAt = snapshot.adapterLoadedAt
        self.adapterStep = snapshot.adapterStep
        self.pendingTrainingTargetCount = snapshot.pendingTrainingTargetCount
        if let trainingCandidateCorpusProgress = snapshot.trainingCandidateCorpusProgress {
            self.trainingCandidateCorpusProgress = trainingCandidateCorpusProgress
        }
        self.runID = snapshot.runID
        self.runKind = snapshot.runKind
        self.runState = snapshot.runState
        self.runTargetCount = snapshot.runTargetCount
        self.runEpoch = snapshot.runEpoch
        self.runEpochCount = snapshot.runEpochCount
        self.attemptedTargetCount = snapshot.attemptedTargetCount
        self.incorporatedTargetCount = snapshot.incorporatedTargetCount
        self.replayCount = snapshot.replayCount
        self.skippedTargetCount = snapshot.skippedTargetCount
        self.failedTargetCount = snapshot.failedTargetCount
        self.rejectedCandidateCount = snapshot.rejectedCandidateCount
        self.aggregateTargetLoss = snapshot.aggregateTargetLoss
        self.aggregateValidationLoss = snapshot.aggregateValidationLoss
        self.checkpointLifecycle = snapshot.checkpointLifecycle
        self.nextEligibleReason = snapshot.nextEligibleReason
        self.resourceWaitReason = snapshot.resourceWaitReason
        self.isPaused = snapshot.isPaused
        self.lastError = snapshot.lastError
        self.isEngineReady = snapshot.isEngineReady
    }
}

private extension WorkerTrainingPhaseSnapshot {
    init(_ phase: TrainingStatusPublisher.Phase) {
        switch phase {
        case .idle:
            self = .idle
        case .preparing:
            self = .preparing
        case .training(let step, let totalSteps, let loss):
            self = .training(step: step, totalSteps: totalSteps, loss: loss)
        case .checkpointing(let step):
            self = .checkpointing(step: step)
        case .resetting:
            self = .resetting
        }
    }
}

private extension TrainingStatusPublisher.Phase {
    init(_ snapshot: WorkerTrainingPhaseSnapshot) {
        switch snapshot {
        case .idle:
            self = .idle
        case .preparing:
            self = .preparing
        case .training(let step, let totalSteps, let loss):
            self = .training(step: step, totalSteps: totalSteps, loss: loss)
        case .checkpointing(let step):
            self = .checkpointing(step: step)
        case .resetting:
            self = .resetting
        }
    }
}
