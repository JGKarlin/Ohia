// TrainingOrchestrator.swift
// 3-phase async training: prepare on MainActor → train loop with each
// `engine.trainStep` running in a detached task → checkpoint writes stay
// on MainActor (SwiftData requires it). The MainActor is idle between
// steps because `await` on a detached task releases it, so the UI stays
// responsive during multi-minute runs.

import CryptoKit
import Foundation
import SwiftData
import OhiaCore

/// Metrics returned after a training session completes.
public struct TrainingSessionMetrics: Sendable {
    public let stepsCompleted: Int
    public let totalSteps: Int
    public let finalLoss: Double
    public let durationSeconds: Double
    public let trainingPairsUsed: Int

    public init(
        stepsCompleted: Int,
        totalSteps: Int,
        finalLoss: Double,
        durationSeconds: Double,
        trainingPairsUsed: Int
    ) {
        self.stepsCompleted = stepsCompleted
        self.totalSteps = totalSteps
        self.finalLoss = finalLoss
        self.durationSeconds = durationSeconds
        self.trainingPairsUsed = trainingPairsUsed
    }
}

public extension TrainingOrchestrator {
    /// Advances one immutable run snapshot by at most `stepsPerJob` target
    /// visits within the current epoch. Optimizer success records an attempt;
    /// only a candidate judged at the end of an epoch and promoted
    /// incorporates those exact pair revisions. `peakLearningRate` is the top
    /// of the run's warmup-then-cosine schedule.
    @MainActor
    func runTrainingRun(
        runID: UUID,
        context: ModelContext,
        publisher: TrainingStatusPublisher,
        stepsPerJob: Int,
        peakLearningRate: Double,
        shouldYield: @escaping @MainActor @Sendable () -> String? = { nil }
    ) async throws -> TrainingSessionMetrics {
        let startTime = Date()
        let policy = TrainingOptimizationPolicy.current
        engine.resetCancellation()
        publisher.setPhase(.preparing)
        publisher.clearError()
        defer { publisher.setPhase(.idle) }

        // `forceRunRequested` is NOT consumed here: the scheduler clears it
        // when the manual-full snapshot it asks for actually exists. Consuming
        // it at job start silently dropped a Train Now issued while another
        // run was still active.
        let state = TrainingRunState.current(context: context)
        state.lastError = nil
        try context.save()

        guard engine.isModelLoaded else {
            publisher.setPhase(.idle)
            throw TrainingEngineError.modelNotLoaded
        }
        guard stepsPerJob > 0 else {
            publisher.setPhase(.idle)
            throw TrainingEngineError.trainingFailed("Training step count must be greater than zero.")
        }

        let runs = try context.fetch(FetchDescriptor<TrainingCorpusRun>())
        guard let run = runs.first(where: { $0.id == runID }) else {
            publisher.setPhase(.idle)
            throw TrainingEngineError.trainingFailed("Training run \(runID) was not found.")
        }
        if run.state == .completed {
            publisher.setPhase(.idle)
            return TrainingSessionMetrics(
                stepsCompleted: 0,
                totalSteps: TrainingRunState.current(context: context).lastStepCount,
                finalLoss: TrainingRunState.current(context: context).lastLoss ?? 0,
                durationSeconds: 0,
                trainingPairsUsed: 0
            )
        }
        guard let checkpointEngine = engine as? any CheckpointAwareTrainingEngine,
              let compatibility = checkpointEngine.checkpointCompatibility else {
            let message = "The loaded engine did not provide training compatibility metadata."
            publisher.recordError(message)
            state.lastError = message
            run.state = .failed
            run.failedAt = .now
            run.failureReason = message
            try context.save()
            throw TrainingEngineError.trainingFailed(message)
        }
        let currentProfileID = TrainingCorpusPlanner.trainingProfileID(for: compatibility)
        guard run.baseModelManifestID == compatibility.baseModelID,
              run.trainingProfileID == currentProfileID else {
            let message = "The active training run belongs to a different model or LoRA profile."
            publisher.recordError(message)
            state.lastError = message
            run.state = .failed
            run.failedAt = .now
            run.failureReason = message
            try context.save()
            throw TrainingCorpusPlannerError.activeRunManifestMismatch
        }

        let allPairs = try context.fetch(FetchDescriptor<TrainingPair>())
        let allTargets = try context.fetch(FetchDescriptor<TrainingCorpusRunTarget>())
        let snapshottedPairIDs = Set(allTargets.map(\.pairID))
        let trashedMessageIDs = try TrainingPair.trashedMessageIDs(in: context)
        func validationFailureProfile(_ pair: TrainingPair) -> String {
            // Prompt rebuilds can change the full input without changing the
            // authored evidence revision. Do not permanently suppress a
            // repaired input or one evaluated under a different model profile.
            var digest = SHA256()
            for text in [pair.promptText, pair.completionText] {
                digest.update(data: Data("\(text.utf8.count):".utf8))
                digest.update(data: Data(text.utf8))
            }
            let tokenLimit = (engine as? MLXTrainingEngine)?.trainingSequenceTokenLimit ?? 0
            return currentProfileID + ":validation-limit:\(tokenLimit):input:"
                + digest.finalize().map { String(format: "%02x", $0) }.joined()
        }

        func hasInvalidValidationInput(_ pair: TrainingPair) -> Bool {
            pair.latestFailedEvidenceRevision == pair.evidenceRevision
                && pair.latestFailedTrainingProfileID == validationFailureProfile(pair)
        }
        // Preparation continues while an immutable run is active. Reserve
        // fresh stable holdouts from never-snapshotted, unlearned rows using
        // the full eligible corpus size, even when just one new row arrived.
        // Known invalid holdouts cannot suppress that reservation, but retain
        // their role so an all-invalid corpus still blocks promotion below.
        let eligiblePairs = allPairs.filter {
            Self.isEligibleForValidation($0, trashedMessageIDs: trashedMessageIDs)
        }
        let roleCandidates = eligiblePairs.filter {
            if $0.trainingRoleRaw == TrainingPairRole.validationHoldout.rawValue {
                return !hasInvalidValidationInput($0)
            }
            return $0.latestPromotedCheckpointID == nil && !snapshottedPairIDs.contains($0.id)
        }
        if Self.assignStableTrainingRoles(to: roleCandidates, trashedMessageIDs: trashedMessageIDs,
                                         eligibleCorpusCount: eligiblePairs.count(where: { $0.signalSource == nil })) {
            try context.save()
        }
        let validationPairs = eligiblePairs.filter {
            $0.trainingRoleRaw == TrainingPairRole.validationHoldout.rawValue
        }
        // A stable, bounded subset of the holdout: every judgment in a run
        // measures the same authored examples at a fixed cost.
        let validationInputs = Array(validationPairs
            .filter { !hasInvalidValidationInput($0) }
            .sorted { Self.stableFingerprint(for: $0.id) < Self.stableFingerprint(for: $1.id) }
            .prefix(policy.maximumValidationExamples))
        // Every holdout is known to exceed this profile: no candidate could be
        // compared with the base model, so nothing trains until a usable
        // holdout exists (a rebuilt input, or a freshly reserved one).
        // Checked before any adapter is read: the wait costs nothing per seed.
        if !validationPairs.isEmpty, validationInputs.isEmpty {
            run.state = .interrupted
            run.interruptedAt = .now
            run.heartbeatAt = .now
            state.lastError = Self.noUsableHoldoutReason
            try context.save()
            publisher.recordError(Self.noUsableHoldoutReason)
            publisher.setResourceWaitReason(Self.noUsableHoldoutReason)
            return TrainingSessionMetrics(stepsCompleted: 0, totalSteps: state.lastStepCount,
                finalLoss: state.lastLoss ?? 0,
                durationSeconds: Date().timeIntervalSince(startTime), trainingPairsUsed: 0)
        }

        let promotedCheckpoint = try await checkpointManager.resumeTrainingFromLatest(
            engine: engine,
            context: context
        )
        guard run.state != .failed else {
            // Qualification may retire the job's run when its incorporated
            // work belonged to a rejected lineage. Complete this stale job;
            // the scheduler will snapshot remaining evidence from the retained
            // adapter instead of retrying an already-retired run as an error.
            return TrainingSessionMetrics(stepsCompleted: 0,
                totalSteps: promotedCheckpoint?.stepCount ?? 0,
                finalLoss: promotedCheckpoint?.loss ?? 0,
                durationSeconds: Date().timeIntervalSince(startTime), trainingPairsUsed: 0)
        }
        if promotedCheckpoint == nil {
            // `resumeTrainingFromLatest` may have loaded an adapter before a
            // corrupt optimizer sidecar made the composite checkpoint fail.
            // Nil therefore means "restore authoritative base", not merely
            // "there is no checkpoint row".
            try await Task.detached(priority: .background) {
                try checkpointEngine.resetAdapter()
            }.value
        }
        let baseStepCount = promotedCheckpoint?.stepCount ?? 0

        func evaluatePreemptibly(
            _ examples: [TrainingExample],
            invalidExample: ((Int, Int?) throws -> Void)? = nil
        ) async throws -> (evaluation: TrainingEvaluation?, yieldedReason: String?) {
            var weightedLoss = 0.0
            var completionTokenCount = 0
            var exampleCount = 0
            for (index, example) in examples.enumerated() {
                if let reason = shouldYield() {
                    return (nil, reason)
                }
                let evaluation: TrainingEvaluation
                do {
                    evaluation = try await Task.detached(priority: .background) {
                        try checkpointEngine.evaluate(examples: [example])
                    }.value
                } catch TrainingEngineError.invalidTrainingExample(let reason, let sequenceTokens) {
                    guard let invalidExample else {
                        throw TrainingEngineError.invalidTrainingExample(reason, sequenceTokens: sequenceTokens)
                    }
                    try invalidExample(index, sequenceTokens)
                    continue
                }
                weightedLoss += evaluation.loss * Double(evaluation.completionTokenCount)
                completionTokenCount += evaluation.completionTokenCount
                exampleCount += evaluation.exampleCount
                if let reason = shouldYield() {
                    return (nil, reason)
                }
            }
            guard completionTokenCount > 0 else {
                if invalidExample != nil { return (nil, nil) }
                throw TrainingEngineError.trainingFailed(
                    "Validation produced no completion tokens."
                )
            }
            return (
                TrainingEvaluation(
                    loss: weightedLoss / Double(completionTokenCount),
                    exampleCount: exampleCount,
                    completionTokenCount: completionTokenCount
                ),
                nil
            )
        }

        let targets = allTargets
            .filter { $0.run?.id == runID }
            .sorted {
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                return $0.id.uuidString < $1.id.uuidString
            }
        let pairByID = Dictionary(uniqueKeysWithValues: allPairs.map { ($0.id, $0) })

        // A promotion stamp counts only under the lineage this run continues;
        // a first run has none, and earlier tasks' stamps say nothing about it.
        func pendingRevisionCount() -> Int {
            allPairs.filter {
                $0.evidence?.disposition == .loraEligible
                    && $0.evidence?.revision == $0.evidenceRevision
                    && (promotedCheckpoint == nil || $0.latestPromotedEvidenceRevision != $0.evidenceRevision)
                    && !($0.latestFailedEvidenceRevision == $0.evidenceRevision
                        && $0.latestFailedTrainingProfileID == currentProfileID)
                    && !TrainingCorpusPlanner.isDeferred($0, trainingProfileID: currentProfileID, now: .now)
                    && $0.trainingRoleRaw != TrainingPairRole.validationHoldout.rawValue
                    && !$0.referencesTrashedMessage(in: trashedMessageIDs)
                    && $0.isTrainablePromptFormat
                    && !$0.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.completionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
        }

        func publishRun(_ lifecycle: TrainingCheckpointLifecycle?) {
            publisher.project(
                run: run,
                pendingTrainingTargetCount: pendingRevisionCount(),
                checkpointLifecycle: lifecycle
            )
        }

        func attempt(for target: TrainingCorpusRunTarget) -> TrainingCheckpointAttempt {
            TrainingCheckpointAttempt(
                targetID: target.id,
                pairID: target.pairID,
                evidenceRevision: target.evidenceRevision
            )
        }

        func frontier() -> [TrainingCorpusRunTarget] {
            targets.filter {
                $0.role == .target && $0.visitState == .attempted
            }
        }

        // Replay rows join the attempt ledger and resume manifests — their
        // optimizer motion must be reconciled or rolled back exactly like
        // target motion — but they never enter `frontier()`, so they can
        // never stamp incorporation or advance any target count.
        func attemptedRows() -> [TrainingCorpusRunTarget] {
            targets.filter { $0.visitState == .attempted }
        }

        func refreshCounts() {
            let corpusTargets = targets.filter { $0.role == .target }
            run.attemptedTargetCount = corpusTargets.filter { $0.attemptedAt != nil }.count
            run.incorporatedTargetCount = corpusTargets.filter { $0.visitState == .incorporated }.count
            run.skippedTargetCount = corpusTargets.filter { $0.visitState == .skipped }.count
            run.failedTargetCount = corpusTargets.filter { $0.visitState == .failed }.count
        }

        func completeIfTerminal() {
            refreshCounts()
            let terminalCount = run.incorporatedTargetCount + run.skippedTargetCount + run.failedTargetCount
            if terminalCount == run.targetCount {
                run.state = .completed
                run.completedAt = .now
            } else {
                run.state = .interrupted
                run.interruptedAt = .now
            }
        }

        func stampFailed(
            _ failedTargets: [TrainingCorpusRunTarget],
            reason: String,
            sequenceTokens: Int? = nil
        ) {
            for target in failedTargets {
                // Replay rows terminate as skipped, and their already-promoted
                // pairs never receive a not-learnable stamp — the failure is
                // about this run's targets, not evidence the adapter already
                // incorporated.
                if target.role == .replay {
                    target.visitState = .skipped
                    target.checkpointID = nil
                    target.failureReason = reason
                    continue
                }
                target.visitState = .failed
                target.checkpointID = nil
                target.failureReason = reason
                guard let pair = pairByID[target.pairID],
                      pair.evidenceRevision == target.evidenceRevision else { continue }
                pair.latestFailedEvidenceRevision = target.evidenceRevision
                pair.latestFailedTrainingProfileID = run.trainingProfileID
                // A length belongs to the pair's text, which only a rebuild
                // changes; a failure without one keeps it.
                if let sequenceTokens { pair.latestFailedSequenceTokens = sequenceTokens }
            }
        }

        func applyOperationalFailure(
            to failedTargets: [TrainingCorpusRunTarget],
            reason: String
        ) {
            run.failureAttemptCount += 1
            if run.failureAttemptCount >= Self.maximumRunFailureAttempts {
                stampFailed(failedTargets, reason: reason)
                run.state = .failed
                run.failedAt = .now
                run.failureReason = reason
            } else {
                for target in failedTargets where target.visitState == .attempted {
                    target.visitState = .pending
                    target.checkpointID = nil
                }
                run.state = .interrupted
                run.interruptedAt = .now
            }
            run.heartbeatAt = .now
            refreshCounts()
        }

        func pruneCheckpoints() {
            do {
                try checkpointManager.pruneOld(
                    keep: 5,
                    keepNonPromoted: 2,
                    compatibility: compatibility,
                    context: context
                )
            } catch {
                let message = "checkpoint retention failed: \(error.localizedDescription)"
                publisher.recordError(message)
                state.lastError = message
                try? context.save()
            }
        }

        func restorePromotedAdapter() async throws {
            if let promotedCheckpoint {
                do {
                    try await checkpointManager.restoreTrainingCheckpoint(
                        promotedCheckpoint,
                        engine: engine,
                        context: context
                    )
                } catch {
                    // Drafting must never see unjudged weights: when the
                    // promoted adapter cannot come back, fall back to base.
                    try? await Task.detached(priority: .background) {
                        try checkpointEngine.resetAdapter()
                    }.value
                    throw error
                }
            } else {
                try await Task.detached(priority: .background) {
                    try checkpointEngine.resetAdapter()
                }.value
            }
        }

        /// A rolled-back row is not in the frontier's weights: it trains again.
        func rollBack(_ target: TrainingCorpusRunTarget) {
            target.visitState = .pending
            target.checkpointID = nil
        }

        // The previous job of this run may have set its unjudged frontier
        // aside in memory. When it covers exactly the rows the ledger shows
        // attempted, it resumes without reading the disk artifact, and the
        // ledger is its authority.
        let stasher = engine as? any TrainingFrontierStashing
        var stashed: TrainingFrontierMarker?
        if let stasher, let marker = stasher.stashedTrainingFrontier {
            let ledgerAttempts = Set(attemptedRows().map(\.id))
            if marker.runID == runID, marker.parentCheckpointID == promotedCheckpoint?.id,
               !ledgerAttempts.isEmpty, marker.attemptIDs == ledgerAttempts {
                do {
                    if try await Task.detached(priority: .background, operation: {
                        try stasher.restoreStashedTrainingFrontier()
                    }).value {
                        stashed = marker
                    }
                } catch {
                    publisher.recordError("in-memory training frontier restore failed: \(error.localizedDescription)")
                    try await restorePromotedAdapter()
                }
            } else {
                stasher.discardStashedTrainingFrontier()
            }
        }

        // Otherwise attempted rows are trustworthy only when a loadable resume
        // artifact names the same target, pair, and evidence revision.
        var resumeLoadFailed = false
        var resume = try checkpointManager.resumeCandidate(
            for: runID,
            engine: engine,
            context: context,
            loading: stashed == nil,
            onLoadFailure: { _, _ in resumeLoadFailed = true }
        )
        if resume == nil, resumeLoadFailed {
            try await restorePromotedAdapter()
        }
        var resumeAttempts = Dictionary(
            uniqueKeysWithValues: (resume?.manifest.attempts ?? []).map { ($0.targetID, $0) }
        )
        if stashed == nil {
            // Rows attempted after the artifact was written (the frontier was
            // held in memory and lost) return to pending and train again.
            for target in targets where target.visitState == .attempted {
                let persisted = resumeAttempts[target.id]
                if persisted?.pairID != target.pairID
                    || persisted?.evidenceRevision != target.evidenceRevision {
                    rollBack(target)
                }
            }
            // A resume manifest cannot silently add attempts the run ledger
            // did not persist before the crash.
            let ledgerAttemptIDs = Set(attemptedRows().map(\.id))
            let manifestAttemptIDs = Set(resumeAttempts.keys)
            if resume == nil || ledgerAttemptIDs != manifestAttemptIDs {
                for target in targets where target.visitState == .attempted {
                    rollBack(target)
                }
                if resume != nil {
                    try? checkpointManager.setLifecycle(
                        .quarantined,
                        checkpoint: resume!.checkpoint,
                        reason: "Resume frontier did not match the persisted run ledger.",
                        context: context
                    )
                    try await restorePromotedAdapter()
                    resume = nil
                    resumeAttempts = [:]
                }
            }
        }

        let checkpointStepBase = stashed?.stepCount ?? resume?.checkpoint.stepCount ?? baseStepCount

        // The epoch in progress. Attempted rows all belong to one epoch
        // (every epoch is judged before the next trains). When that epoch
        // has no pending rows left, it finished in an earlier job but was not
        // judged yet — judge it before anything else trains.
        let epoch: Int?
        let judgeOnly: Bool
        if let attemptedEpoch = attemptedRows().map(\.resolvedEpoch).max() {
            epoch = attemptedEpoch
            judgeOnly = !targets.contains { $0.resolvedEpoch == attemptedEpoch && $0.visitState == .pending }
        } else {
            epoch = targets.filter { $0.visitState == .pending }.map(\.resolvedEpoch).min()
            judgeOnly = false
        }
        func isPendingInEpoch(_ target: TrainingCorpusRunTarget) -> Bool {
            target.visitState == .pending && target.resolvedEpoch == epoch
        }

        run.state = .training
        run.startedAt = run.startedAt ?? .now
        run.heartbeatAt = .now
        try context.save()
        publishRun(resume == nil && stashed == nil ? promotedCheckpoint.flatMap {
            $0.lifecycleRaw.flatMap(TrainingCheckpointLifecycle.init(rawValue:))
        } : .resumeCandidate)

        // Aggregate target loss counts target visits only; replay visits move
        // the optimizer but must not dilute the reported target measure.
        let targetByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        var frontierLossSampleCount = stashed?.lossSampleCount ?? resumeAttempts.keys
            .count(where: { targetByID[$0]?.role == .target })
        var frontierLossSum = stashed?.lossSum ?? (resume?.checkpoint.loss ?? 0) * Double(frontierLossSampleCount)
        var latestLoss = stashed.map { $0.lossSum / Double(max($0.lossSampleCount, 1)) }
            ?? resume?.checkpoint.loss ?? promotedCheckpoint?.loss ?? 0
        var localSteps = 0
        var jobTargetAttempts = 0
        var yieldedReason: String?
        // Schedule position: every visit the run's weights hold — the
        // frontier and promoted epochs. A rolled-back visit trains again and
        // is counted once, when it does.
        let scheduleOrigin = targets.count(where: { $0.visitState == .attempted || $0.visitState == .incorporated })
        func scheduledLearningRate(_ offset: Int) -> Double {
            policy.learningRate(step: scheduleOrigin + offset, totalSteps: targets.count, peak: peakLearningRate)
        }
        try engine.beginTrainingSession(learningRate: scheduledLearningRate(0))
        defer { engine.endTrainingSession() }

        while !judgeOnly, epoch != nil, localSteps < stepsPerJob {
            if engine.isCancelled { break }
            if let reason = shouldYield() {
                yieldedReason = reason
                break
            }
            // A job must attempt a pending target before spending budget on
            // replay. Proportional interleave can front-load replay rows, and
            // a job that burned its whole budget on replay would livelock the
            // run: replay-only motion rolls back, the same rows return to
            // pending, and no counter ever advances.
            let target: TrainingCorpusRunTarget
            if jobTargetAttempts == 0,
               let firstTarget = targets.first(where: { isPendingInEpoch($0) && $0.role == .target }) {
                target = firstTarget
            } else if let nextPending = targets.first(where: isPendingInEpoch) {
                target = nextPending
            } else { break }
            // Replay only ever interleaves with live target work. Once no
            // pending targets remain in the epoch, trailing replay rows drain
            // to skipped so the epoch can end instead of looping on replay.
            if target.role == .replay,
               !targets.contains(where: { isPendingInEpoch($0) && $0.role == .target }) {
                target.visitState = .skipped
                target.failureReason = "No pending targets remain for replay interleave."
                run.heartbeatAt = .now
                refreshCounts()
                try context.save()
                continue
            }
            guard let pair = pairByID[target.pairID],
                  let evidence = pair.evidence,
                  evidence.id == target.evidenceID else {
                target.visitState = .failed
                target.failureReason = "The immutable run target no longer resolves to its prepared evidence."
                run.heartbeatAt = .now
                refreshCounts()
                try context.save()
                continue
            }
            let skipReason: String?
            if pair.evidenceRevision != target.evidenceRevision
                || evidence.revision != target.evidenceRevision {
                skipReason = "Evidence changed after the run snapshot."
            } else if evidence.disposition != .loraEligible {
                skipReason = "Evidence became ineligible after the run snapshot."
            } else if evidence.learningPreference == .automaticDisabled
                || evidence.learningPreference == .explicitDisabled {
                skipReason = "Learning was disabled after the run snapshot."
            } else if pair.referencesTrashedMessage(in: trashedMessageIDs) {
                skipReason = "The source message was trashed after the run snapshot."
            } else if pair.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || pair.completionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                skipReason = "Prepared training text became empty after the run snapshot."
            } else {
                skipReason = nil
            }
            if let skipReason {
                target.visitState = .skipped
                target.failureReason = skipReason
                run.heartbeatAt = .now
                refreshCounts()
                try context.save()
                continue
            }

            let example = TrainingExample(
                prompt: pair.promptText,
                completion: pair.completionText,
                weight: pair.sourceWeight.isFinite && pair.sourceWeight > 0 ? pair.sourceWeight : 1
            )
            let stepLearningRate = scheduledLearningRate(localSteps)
            let result: TrainingStepResult
            do {
                result = try await Task.detached(priority: .background) {
                    try self.engine.trainStep(
                        examples: [example],
                        learningRate: stepLearningRate
                    )
                }.value
            } catch TrainingEngineError.invalidTrainingExample(let reason, let sequenceTokens) {
                // Token/boundary validation occurs before any optimizer update.
                // Isolate this unchanged invalid example; keep the valid work
                // already accumulated in this job for checkpoint validation.
                stampFailed([target], reason: reason, sequenceTokens: sequenceTokens)
                run.heartbeatAt = .now
                refreshCounts()
                try context.save()
                continue
            } catch {
                let message = "trainStep failed: \(error.localizedDescription)"
                publisher.recordError(message)
                state.lastError = message
                applyOperationalFailure(to: [target], reason: message)
                try? context.save()
                try? await restorePromotedAdapter()
                throw error
            }
            latestLoss = result.loss
            if target.role == .target {
                frontierLossSum += result.loss
                frontierLossSampleCount += 1
                jobTargetAttempts += 1
            }
            localSteps += 1
            target.visitState = .attempted
            target.attemptedAt = target.attemptedAt ?? .now
            target.failureReason = nil
            run.heartbeatAt = .now
            refreshCounts()
            try context.save()
            publishRun(resume?.manifest.lifecycle ?? promotedCheckpoint.flatMap {
                $0.lifecycleRaw.flatMap(TrainingCheckpointLifecycle.init(rawValue:))
            })
            publisher.setPhase(.training(step: localSteps, totalSteps: stepsPerJob, loss: latestLoss))
            if let reason = shouldYield() {
                yieldedReason = reason
                break
            }
        }

        let attemptedFrontier = frontier()
        let attemptedAll = attemptedRows()
        let epochComplete = !targets.contains(where: isPendingInEpoch)
        if yieldedReason != nil || engine.isCancelled || !epochComplete {
            // Mid-epoch: keep the exact optimizer frontier for the next job,
            // and restore the promoted adapter so drafting never uses weights
            // that have not been judged. The frontier waits in memory between
            // jobs; it is written to disk at most every
            // `resumePersistInterval`, and whenever it cannot be held.
            if !attemptedFrontier.isEmpty {
                func persistResumeCheckpoint() async throws {
                    do {
                        _ = try await checkpointManager.saveCheckpoint(
                            engine: engine,
                            stepCount: checkpointStepBase + localSteps,
                            loss: frontierLossSum / Double(max(frontierLossSampleCount, 1)),
                            learningRate: scheduledLearningRate(max(localSteps - 1, 0)),
                            corpusCoverage: Double(run.incorporatedTargetCount)
                                / Double(max(run.targetCount, 1)),
                            lifecycle: .resumeCandidate,
                            parentCheckpointID: promotedCheckpoint?.id,
                            runID: runID,
                            attempts: attemptedAll.map(attempt(for:)),
                            context: context
                        )
                    } catch {
                        let message = "resume checkpoint save failed: \(error.localizedDescription)"
                        publisher.recordError(message)
                        state.lastError = message
                        applyOperationalFailure(to: attemptedFrontier, reason: message)
                        try? context.save()
                        try? await restorePromotedAdapter()
                        throw error
                    }
                }
                let lastPersistedAt = stashed?.persistedAt ?? resume?.checkpoint.createdAt
                let persistDue = stasher == nil || engine.isCancelled
                    || lastPersistedAt.map { Date().timeIntervalSince($0) >= Self.resumePersistInterval } ?? true
                var persistedAt = lastPersistedAt
                if persistDue {
                    try await persistResumeCheckpoint()
                    persistedAt = .now
                }
                if let stasher {
                    let marker = TrainingFrontierMarker(
                        runID: runID,
                        parentCheckpointID: promotedCheckpoint?.id,
                        attemptIDs: Set(attemptedAll.map(\.id)),
                        stepCount: checkpointStepBase + localSteps,
                        lossSum: frontierLossSum,
                        lossSampleCount: frontierLossSampleCount,
                        persistedAt: persistedAt
                    )
                    do {
                        try await Task.detached(priority: .background) {
                            try stasher.stashTrainingFrontier(marker)
                        }.value
                    } catch {
                        stasher.discardStashedTrainingFrontier()
                        if !persistDue { try await persistResumeCheckpoint() }
                    }
                }
                do {
                    try await restorePromotedAdapter()
                } catch {
                    let message = "promoted adapter restore failed after yield: \(error.localizedDescription)"
                    publisher.recordError(message)
                    state.lastError = message
                    applyOperationalFailure(to: attemptedAll, reason: message)
                    try? context.save()
                    throw error
                }
            } else if !attemptedAll.isEmpty {
                // Replay-only optimizer motion: cheap to redo, so discard it
                // rather than persist a resume artifact — but the weights
                // moved, and the foreground must never draft with unvalidated
                // replay updates.
                for row in attemptedAll {
                    rollBack(row)
                }
                do {
                    try await restorePromotedAdapter()
                } catch {
                    let message = "promoted adapter restore failed after replay-only yield: \(error.localizedDescription)"
                    publisher.recordError(message)
                    state.lastError = message
                    applyOperationalFailure(to: attemptedAll, reason: message)
                    try? context.save()
                    throw error
                }
            }
            run.state = .interrupted
            run.interruptedAt = .now
            run.heartbeatAt = .now
            try context.save()
            pruneCheckpoints()
            publishRun(.resumeCandidate)
            if let yieldedReason { publisher.setResourceWaitReason(yieldedReason) }
            publisher.setPhase(.idle)
            return TrainingSessionMetrics(
                stepsCompleted: 0,
                totalSteps: baseStepCount,
                finalLoss: promotedCheckpoint?.loss ?? 0,
                durationSeconds: Date().timeIntervalSince(startTime),
                trainingPairsUsed: 0
            )
        }

        guard !attemptedFrontier.isEmpty else {
            if !attemptedAll.isEmpty {
                // Replay motion with no promotable target work: roll it back
                // so the persisted ledger and the loaded weights agree.
                for row in attemptedAll {
                    rollBack(row)
                }
                do {
                    try await restorePromotedAdapter()
                } catch {
                    let message = "promoted adapter restore failed after replay-only job: \(error.localizedDescription)"
                    publisher.recordError(message)
                    state.lastError = message
                    applyOperationalFailure(to: attemptedAll, reason: message)
                    try? context.save()
                    throw error
                }
            }
            completeIfTerminal()
            try context.save()
            publisher.setPhase(.idle)
            return TrainingSessionMetrics(
                stepsCompleted: 0,
                totalSteps: baseStepCount,
                finalLoss: promotedCheckpoint?.loss ?? 0,
                durationSeconds: Date().timeIntervalSince(startTime),
                trainingPairsUsed: 0
            )
        }

        // The epoch is complete: judge it. A judgment an earlier job began
        // continues on the very artifact it began with, which holds the
        // epoch's exact frontier and any quality drafts already made.
        let reusableFrontier = judgeOnly && localSteps == 0 && stashed == nil
            ? resume.flatMap { resume in
                Set(resume.manifest.attempts.map(\.targetID)) == Set(attemptedAll.map(\.id)) ? resume.checkpoint : nil
            }
            : nil
        let candidate: TrainingCheckpoint
        do {
            if let reusableFrontier {
                candidate = reusableFrontier
            } else {
                candidate = try await checkpointManager.saveCheckpoint(
                    engine: engine,
                    stepCount: checkpointStepBase + localSteps,
                    loss: frontierLossSum / Double(max(frontierLossSampleCount, 1)),
                    learningRate: scheduledLearningRate(max(localSteps - 1, 0)),
                    corpusCoverage: Double(run.incorporatedTargetCount + attemptedFrontier.count)
                        / Double(max(run.targetCount, 1)),
                    lifecycle: .candidate,
                    parentCheckpointID: promotedCheckpoint?.id,
                    runID: runID,
                    attempts: attemptedAll.map(attempt(for:)),
                    context: context
                )
            }
        } catch {
            let message = "candidate checkpoint save failed: \(error.localizedDescription)"
            publisher.recordError(message)
            state.lastError = message
            applyOperationalFailure(to: attemptedFrontier, reason: message)
            try? context.save()
            try? await restorePromotedAdapter()
            throw error
        }

        var promoted = false
        var rejectionReason: String?
        var validationYieldedReason: String?
        var judgedLoss: (base: Double, candidate: TrainingEvaluation, fingerprint: String)?
        run.state = .validating
        try context.save()
        do {
            let candidatePath = candidate.adapterPath
            if !validationInputs.isEmpty {
                // 1. The base model's held-out loss, reused while the exact
                //    held-out set is unchanged.
                var inputs = validationInputs
                var fingerprint = Self.validationFingerprint(inputs.map(validationFailureProfile))
                var baseLoss: Double?
                if state.baseValidationFingerprint == fingerprint, let cached = state.baseValidationLoss {
                    baseLoss = cached
                } else {
                    try await Task.detached(priority: .background) { try checkpointEngine.resetAdapter() }.value
                    var invalid = Set<Int>()
                    let identities = inputs.map { (revision: $0.evidenceRevision, profile: validationFailureProfile($0)) }
                    let base = try await evaluatePreemptibly(
                        inputs.map { TrainingExample(prompt: $0.promptText, completion: $0.completionText) },
                        invalidExample: { index, sequenceTokens in
                            invalid.insert(index)
                            inputs[index].latestFailedEvidenceRevision = identities[index].revision
                            inputs[index].latestFailedTrainingProfileID = identities[index].profile
                            // A length belongs to the pair's text, which only a
                            // rebuild changes; a failure without one keeps it.
                            if let sequenceTokens { inputs[index].latestFailedSequenceTokens = sequenceTokens }
                            try context.save()
                        })
                    if let reason = base.yieldedReason { throw CheckpointQualityError.yielded(reason) }
                    inputs = inputs.enumerated().filter { !invalid.contains($0.offset) }.map(\.element)
                    fingerprint = Self.validationFingerprint(inputs.map(validationFailureProfile))
                    baseLoss = base.evaluation?.loss
                    state.baseValidationLoss = baseLoss
                    state.baseValidationFingerprint = baseLoss == nil ? nil : fingerprint
                    try context.save()
                }
                if let baseLoss, !inputs.isEmpty {
                    let examples = inputs.map { TrainingExample(prompt: $0.promptText, completion: $0.completionText) }
                    // 2. The lineage's current adapter on the same set, from
                    //    its manifest when it was measured there.
                    var promotedLoss: Double?
                    if let promotedCheckpoint {
                        let manifest = CheckpointManager.manifest(for: promotedCheckpoint)
                        if manifest?.validationFingerprint == fingerprint, let loss = manifest?.validationLoss {
                            promotedLoss = loss
                        } else {
                            try await restorePromotedAdapter()
                            let measured = try await evaluatePreemptibly(examples)
                            if let reason = measured.yieldedReason { throw CheckpointQualityError.yielded(reason) }
                            promotedLoss = measured.evaluation?.loss
                        }
                    }
                    // 3. The candidate.
                    try await Task.detached(priority: .background) {
                        try self.engine.loadAdapter(from: candidatePath)
                    }.value
                    let measured = try await evaluatePreemptibly(examples)
                    if let reason = measured.yieldedReason { throw CheckpointQualityError.yielded(reason) }
                    guard let evaluation = measured.evaluation, evaluation.loss.isFinite else {
                        throw TrainingEngineError.trainingFailed("Validation produced no candidate loss.")
                    }
                    judgedLoss = (baseLoss, evaluation, fingerprint)
                    if evaluation.loss >= baseLoss {
                        rejectionReason = "held-out loss \(evaluation.loss) does not beat the base model's \(baseLoss)"
                    } else if let promotedLoss,
                              evaluation.loss > promotedLoss + max(abs(promotedLoss) * policy.maximumValidationRegressionFraction, 0.000_001) {
                        rejectionReason = "held-out loss regressed from \(promotedLoss) to \(evaluation.loss)"
                    }
                } else {
                    // Every held-out example exceeded this profile's limits:
                    // there is no honest comparison. Keep the epoch's frontier
                    // and judge it once a usable holdout exists.
                    state.lastError = Self.noUsableHoldoutReason
                    throw CheckpointQualityError.yielded(Self.noUsableHoldoutReason)
                }
            } else {
                try await Task.detached(priority: .background) {
                    try self.engine.loadAdapter(from: candidatePath)
                }.value
            }
            // 4. Behavioral invariants the base model keeps must survive.
            if rejectionReason == nil {
                if shouldYield() != nil { throw CheckpointQualityError.interrupted }
                let quality = try await checkpointManager.qualify(candidate, engine: engine, context: context, shouldYield: shouldYield)
                if !quality.passed { rejectionReason = quality.rejectionSummary }
            }
            if let rejectionReason {
                try checkpointManager.setLifecycle(.rejected, checkpoint: candidate,
                    baselineValidationLoss: judgedLoss?.base, validationLoss: judgedLoss?.candidate.loss,
                    validationExampleCount: judgedLoss?.candidate.exampleCount,
                    validationFingerprint: judgedLoss?.fingerprint,
                    reason: rejectionReason, saveChanges: false, context: context)
                publisher.recordError("checkpoint rejected: \(rejectionReason)")
            } else {
                try checkpointManager.setLifecycle(.promoted, checkpoint: candidate,
                    baselineValidationLoss: judgedLoss?.base, validationLoss: judgedLoss?.candidate.loss,
                    validationExampleCount: judgedLoss?.candidate.exampleCount,
                    validationFingerprint: judgedLoss?.fingerprint,
                    saveChanges: false, context: context)
                run.aggregateValidationLoss = judgedLoss?.candidate.loss
                promoted = true
            }
        } catch CheckpointQualityError.yielded(let reason) {
            validationYieldedReason = reason
        } catch CheckpointQualityError.interrupted {
            validationYieldedReason = "Checkpoint quality checks interrupted"
        } catch is CancellationError {
            validationYieldedReason = "Checkpoint quality checks cancelled"
        } catch CheckpointQualityError.rejected(let reason) {
            rejectionReason = reason
            try checkpointManager.setLifecycle(.rejected, checkpoint: candidate,
                baselineValidationLoss: judgedLoss?.base, reason: reason, saveChanges: false, context: context)
            publisher.recordError("checkpoint rejected: \(reason)")
        } catch {
            try? checkpointManager.setLifecycle(
                .quarantined,
                checkpoint: candidate,
                baselineValidationLoss: judgedLoss?.base,
                reason: error.localizedDescription,
                saveChanges: false,
                context: context
            )
            publisher.recordError("checkpoint validation failed: \(error.localizedDescription)")
        }
        if let reason = validationYieldedReason {
            do {
                try await restorePromotedAdapter()
            } catch {
                let message = "promoted adapter restore failed after validation yield: \(error.localizedDescription)"
                publisher.recordError(message)
                state.lastError = message
                try? checkpointManager.setLifecycle(
                    .quarantined,
                    checkpoint: candidate,
                    reason: message,
                    saveChanges: false,
                    context: context
                )
                applyOperationalFailure(to: attemptedAll, reason: message)
                try? context.save()
                throw error
            }
            // The whole epoch's optimizer frontier survives as the resume
            // artifact; the next job judges it without retraining.
            try checkpointManager.setLifecycle(
                .resumeCandidate,
                checkpoint: candidate,
                saveChanges: false,
                context: context
            )
            if let resumeCheckpoint = resume?.checkpoint, resumeCheckpoint.id != candidate.id {
                try? checkpointManager.setLifecycle(.rejected, checkpoint: resumeCheckpoint,
                    reason: "Superseded by the unjudged epoch frontier \(candidate.id).",
                    saveChanges: false, context: context)
            }
            run.state = .interrupted
            run.interruptedAt = .now
            run.heartbeatAt = .now
            try context.save()
            publishRun(.resumeCandidate)
            pruneCheckpoints()
            publisher.setResourceWaitReason(reason)
            return TrainingSessionMetrics(
                stepsCompleted: 0,
                totalSteps: baseStepCount,
                finalLoss: promotedCheckpoint?.loss ?? 0,
                durationSeconds: Date().timeIntervalSince(startTime),
                trainingPairsUsed: 0
            )
        }

        if let resumeCheckpoint = resume?.checkpoint, resumeCheckpoint.id != candidate.id {
            try? checkpointManager.setLifecycle(
                .rejected,
                checkpoint: resumeCheckpoint,
                reason: "Superseded by judged checkpoint \(candidate.id).",
                saveChanges: false,
                context: context
            )
        }
        if promoted {
            let incorporatedAt = Date()
            for target in attemptedFrontier {
                target.visitState = .incorporated
                target.incorporatedAt = incorporatedAt
                target.checkpointID = candidate.id
                if let pair = pairByID[target.pairID], pair.evidenceRevision == target.evidenceRevision {
                    pair.latestPromotedEvidenceRevision = target.evidenceRevision
                    pair.latestPromotedRunID = runID
                    pair.latestPromotedCheckpointID = candidate.id
                }
            }
            for row in attemptedAll where row.role == .replay {
                row.visitState = .incorporated
                row.incorporatedAt = incorporatedAt
                row.checkpointID = candidate.id
                // Rotate replay selection; promoted stamps stay untouched —
                // replay never re-incorporates a pair.
                pairByID[row.pairID]?.lastReplayedAt = incorporatedAt
            }
            run.latestPromotedCheckpointID = candidate.id
            run.failureAttemptCount = 0
            run.rejectedCandidateCount = 0
            run.targetLossSum += frontierLossSum
            run.targetLossSampleCount += frontierLossSampleCount
            run.aggregateTargetLoss = run.targetLossSum / Double(max(run.targetLossSampleCount, 1))
            completeIfTerminal()
        } else if let rejectionReason {
            run.rejectedCandidateCount += 1
            let now = Date()
            // An epoch after a promoted one that stops improving ends the
            // run early: the promoted epoch already holds this evidence.
            // Otherwise the evidence did not help yet; defer it for a while
            // rather than retrying the same judgment every tick.
            let earlyStop = run.latestPromotedCheckpointID != nil
            let reason = earlyStop
                ? "Early stop: \(rejectionReason)"
                : "Deferred after rejection: \(rejectionReason)"
            for row in attemptedAll {
                row.visitState = .skipped
                row.checkpointID = nil
                row.failureReason = reason
                guard !earlyStop, row.role == .target,
                      let pair = pairByID[row.pairID],
                      pair.evidenceRevision == row.evidenceRevision else { continue }
                pair.latestDeferredEvidenceRevision = row.evidenceRevision
                pair.latestDeferredTrainingProfileID = run.trainingProfileID
                pair.latestDeferredAt = now
            }
            for row in targets where row.visitState == .pending {
                row.visitState = .skipped
                row.failureReason = reason
            }
            completeIfTerminal()
        } else {
            let reason = candidate.rejectionReason
                ?? publisher.lastError
                ?? "Checkpoint candidate validation did not complete."
            applyOperationalFailure(to: attemptedAll, reason: reason)
        }
        run.heartbeatAt = .now
        do {
            if promoted {
                let lineage = try CheckpointManager.voiceLineage(
                    compatibility: (engine as? any CheckpointAwareTrainingEngine)?.checkpointCompatibility,
                    context: context)
                try TrainingCorpusPlanner.refreshRegisterTrainingCounts(context: context,
                    hasPromotedLineage: lineage != nil, learnedRevisions: lineage?.revisions)
            }
            try context.save()
        } catch {
            context.rollback()
            let message = "training promotion save failed: \(error.localizedDescription)"
            try? checkpointManager.setLifecycle(
                .quarantined,
                checkpoint: candidate,
                reason: message,
                context: context
            )
            applyOperationalFailure(to: attemptedAll, reason: message)
            publisher.recordError(message)
            state.lastError = message
            try? context.save()
            try? await restorePromotedAdapter()
            throw error
        }
        if !promoted {
            do {
                try await restorePromotedAdapter()
            } catch {
                let message = "promoted adapter restore failed after candidate rejection: \(error.localizedDescription)"
                publisher.recordError(message)
                state.lastError = message
                try? context.save()
                throw error
            }
        }
        publishRun(promoted ? .promoted : .rejected)
        pruneCheckpoints()

        let duration = Date().timeIntervalSince(startTime)
        let incorporatedThisJob = promoted ? attemptedFrontier.count : 0
        let metrics = TrainingSessionMetrics(
            stepsCompleted: promoted ? localSteps : 0,
            totalSteps: promoted ? candidate.stepCount : baseStepCount,
            finalLoss: promoted
                ? frontierLossSum / Double(max(frontierLossSampleCount, 1))
                : (promotedCheckpoint?.loss ?? 0),
            durationSeconds: duration,
            trainingPairsUsed: incorporatedThisJob
        )
        state.lastRunAt = .now
        state.lastLoss = metrics.finalLoss
        state.lastDurationSeconds = duration
        state.lastPairsUsed = incorporatedThisJob
        state.lastStepCount = metrics.totalSteps
        state.lastError = publisher.lastError
        try context.save()
        publisher.completeRun(metrics: metrics, clearError: publisher.lastError == nil)
        publisher.setPhase(.idle)
        return metrics
    }
}

public final class TrainingOrchestrator: Sendable {
    private let engine: TrainingEngine
    private let checkpointManager: CheckpointManager

    /// MLX cannot interrupt an optimizer update once its forward/backward pass
    /// has started. Each durable target visit is therefore one optimizer unit.
    public static let responsiveExamplesPerOptimizerStep = 1
    static let noUsableHoldoutReason = "Training is waiting for a usable validation holdout; current holdouts exceed this training profile's limits or have invalid boundaries."
    /// Unchanged evidence under one training profile stops automatic retrying
    /// after this many operational failures.
    public static let maximumRunFailureAttempts = 3

    /// Longest interval between disk writes of an unjudged mid-epoch
    /// frontier while the engine holds it in memory between jobs. Bounds the
    /// training a crash can lose; cooperative one-step jobs would otherwise
    /// write the adapter and optimizer state on every step.
    public static let resumePersistInterval: TimeInterval = 10 * 60
    private static let validationBucketCount: UInt64 = 10

    public init(
        engine: TrainingEngine,
        canonicalStore: CanonicalStore,
        checkpointDirectory: URL
    ) {
        self.engine = engine
        _ = canonicalStore
        self.checkpointManager = CheckpointManager(checkpointDirectory: checkpointDirectory)
    }

    @MainActor
    private static func isEligibleForValidation(_ pair: TrainingPair, trashedMessageIDs: Set<UUID>) -> Bool {
        guard let evidence = pair.evidence else { return false }
        return evidence.disposition == .loraEligible
            && evidence.revision == pair.evidenceRevision
            && evidence.learningPreference != .automaticDisabled
            && evidence.learningPreference != .explicitDisabled
            && !pair.referencesTrashedMessage(in: trashedMessageIDs)
            && pair.isTrainablePromptFormat
            && !pair.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pair.completionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    @discardableResult
    static func assignStableTrainingRoles(to pairs: [TrainingPair], trashedMessageIDs: Set<UUID> = [],
                                         eligibleCorpusCount: Int? = nil) -> Bool {
        var changed = false
        // An old-format holdout cannot be evaluated by the current writer
        // task. It must not suppress selection of a fresh, usable holdout.
        // Preserve old roles until those examples have been prepared again.
        let corpusPairs = pairs.filter {
            $0.signalSource == nil && isEligibleForValidation($0, trashedMessageIDs: trashedMessageIDs)
        }
        let corpusCount = max(corpusPairs.count, eligibleCorpusCount ?? 0)

        for pair in pairs where pair.signalSource != nil {
            if pair.trainingRoleRaw != TrainingPairRole.training.rawValue {
                pair.trainingRoleRaw = TrainingPairRole.training.rawValue
                changed = true
            }
        }
        for pair in corpusPairs where pair.trainingRoleRaw == nil {
            let role: TrainingPairRole = corpusCount >= Int(validationBucketCount)
                && stableBucket(for: pair.id) == 0
                ? .validationHoldout
                : .training
            pair.trainingRoleRaw = role.rawValue
            changed = true
        }

        if corpusCount >= Int(validationBucketCount),
           !corpusPairs.contains(where: {
               $0.trainingRoleRaw == TrainingPairRole.validationHoldout.rawValue
           }),
           let fallback = corpusPairs.filter({
               $0.latestPromotedCheckpointID == nil
           }).min(by: {
               stableFingerprint(for: $0.id) < stableFingerprint(for: $1.id)
           }) {
            fallback.trainingRoleRaw = TrainingPairRole.validationHoldout.rawValue
            changed = true
        }
        return changed
    }

    private static func stableBucket(for id: UUID) -> UInt64 {
        stableFingerprint(for: id) % validationBucketCount
    }

    /// Identity of a held-out set: its members' exact inputs under this
    /// profile and token limit, order-independent.
    static func validationFingerprint(_ memberProfiles: [String]) -> String {
        SHA256.hash(data: Data(memberProfiles.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func stableFingerprint(for id: UUID) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}
