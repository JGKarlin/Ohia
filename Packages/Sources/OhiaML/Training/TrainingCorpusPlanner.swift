import CryptoKit
import Foundation
import SwiftData
import OhiaCore

public enum TrainingCorpusPlannerError: Error, LocalizedError {
    case activeRunManifestMismatch

    public var errorDescription: String? {
        switch self {
        case .activeRunManifestMismatch:
            "The active training run belongs to a different model or LoRA profile."
        }
    }
}

/// Creates immutable, deterministic target snapshots for the one shared
/// cross-account adapter lineage.
public struct TrainingCorpusPlanner: Sendable {
    public init() {}

    /// Loading may reject a previously promoted descendant. Its incorporation
    /// stamps must not suppress training from the voice weights actually retained.
    /// This is part of checkpoint selection, not a historical evidence repair.
    @MainActor
    static func reconcileRetainedCheckpoint(_ checkpoint: TrainingCheckpoint?, context: ModelContext) throws {
        let state = TrainingRunState.current(context: context)
        let checkpoints = try context.fetch(FetchDescriptor<TrainingCheckpoint>())
        let byID = Dictionary(checkpoints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var retainedIDs = Set<UUID>()
        var incorporated: [UUID: [Int: TrainingCheckpoint]] = [:]
        let compatibility = checkpoint.flatMap { CheckpointManager.manifest(for: $0)?.compatibility }
        var next = checkpoint
        while let row = next, !retainedIDs.contains(row.id),
              row.lifecycleRaw == TrainingCheckpointLifecycle.promoted.rawValue,
              let manifest = CheckpointManager.manifest(for: row),
              manifest.checkpointID == row.id, manifest.stepCount == row.stepCount,
              manifest.lifecycle == .promoted,
              compatibility?.canRetainVoice(from: manifest.compatibility) == true {
            retainedIDs.insert(row.id)
            for attempt in manifest.attempts where incorporated[attempt.pairID]?[attempt.evidenceRevision] == nil {
                incorporated[attempt.pairID, default: [:]][attempt.evidenceRevision] = row
            }
            next = manifest.parentCheckpointID.flatMap { byID[$0] }
        }
        for pair in try context.fetch(FetchDescriptor<TrainingPair>()) {
            guard let stampedCheckpoint = pair.latestPromotedCheckpointID,
                  !retainedIDs.contains(stampedCheckpoint) else { continue }
            let retained = pair.latestPromotedEvidenceRevision.flatMap { incorporated[pair.id]?[$0] }
            pair.latestPromotedCheckpointID = retained?.id
            pair.latestPromotedRunID = retained.flatMap { CheckpointManager.manifest(for: $0)?.runID }
            if retained == nil { pair.latestPromotedEvidenceRevision = nil }
        }
        for run in try context.fetch(FetchDescriptor<TrainingCorpusRun>()) where Self.isActive(run.state) {
            let discardedPromotion = run.latestPromotedCheckpointID.map { !retainedIDs.contains($0) } ?? false
            // Only promoted epochs are the run's durable work. Attempted rows
            // are an unjudged frontier: the next job resumes it only from an
            // artifact (on disk or in memory) whose parent is the retained
            // checkpoint, and otherwise returns those rows to pending.
            let discardedWork = run.targets.contains { target in
                guard target.visitState == .incorporated else { return false }
                return target.checkpointID.map { !retainedIDs.contains($0) } ?? true
            }
            if discardedPromotion || discardedWork {
                run.state = .failed
                run.failedAt = .now
                run.failureReason = "Checkpoint qualification retained a different training lineage."
            }
        }
        let revisions = incorporated.mapValues { Set($0.keys) }
        try Self.refreshRegisterTrainingCounts(context: context,
            hasPromotedLineage: checkpoint != nil, learnedRevisions: revisions)
        if state.lastStepCount != (checkpoint?.stepCount ?? 0) {
            state.lastStepCount = checkpoint?.stepCount ?? 0
            state.lastLoss = checkpoint?.loss
            state.lastPairsUsed = nil
            state.lastDurationSeconds = nil
        }
        do { try context.save() }
        catch {
            context.rollback()
            throw error
        }
    }

    /// Current authored revisions incorporated into the retained voice lineage.
    /// A pending prompt-only rerender does not erase learned correspondence.
    @MainActor
    static func incorporatedPairs(context: ModelContext, learnedRevisions: [UUID: Set<Int>]? = nil) throws -> [TrainingPair] {
        let trashed = try TrainingPair.trashedMessageIDs(in: context)
        return try context.fetch(FetchDescriptor<TrainingPair>()).filter { pair in
            guard let evidence = pair.evidence else { return false }
            let retainsVoice = ComposerWriterTraining.hasCurrentLearningSemantics(
                basis: ComposerGenerationBasis.decode(pair.generationBasisJSON),
                score: SentMessageStyleScore.decode(pair.measuredStyleScoreJSON))
            return (pair.isTrainablePromptFormat || retainsVoice)
                && evidence.disposition == .loraEligible
                && evidence.revision == pair.evidenceRevision
                && evidence.learningPreference != .automaticDisabled
                && evidence.learningPreference != .explicitDisabled
                && pair.trainingRoleRaw != TrainingPairRole.validationHoldout.rawValue
                && !pair.referencesTrashedMessage(in: trashed)
                && (learnedRevisions.map { $0[pair.id]?.contains(pair.evidenceRevision) == true }
                    ?? (pair.latestPromotedCheckpointID != nil && pair.latestPromotedEvidenceRevision == pair.evidenceRevision))
        }
    }

    /// Update evidence counts deterministically when training or membership
    /// changes, without another style-distillation inference.
    @MainActor
    @discardableResult
    static func refreshRegisterTrainingCounts(context: ModelContext, hasPromotedLineage: Bool,
                                             learnedRevisions: [UUID: Set<Int>]? = nil) throws -> Bool {
        let pairs = hasPromotedLineage ? try incorporatedPairs(context: context, learnedRevisions: learnedRevisions) : []
        let counts = Dictionary(grouping: pairs.compactMap(\.styleRegisterID), by: { $0 }).mapValues(\.count)
        var changed = false
        for register in try context.fetch(FetchDescriptor<StyleRegister>()) {
            let count = counts[register.id] ?? 0
            if register.trainedPairCount != count {
                register.trainedPairCount = count
                changed = true
            }
        }
        return changed
    }

    public static func trainingProfileID(
        for compatibility: TrainingCheckpointCompatibility
    ) -> String {
        [
            String(compatibility.schemaVersion),
            compatibility.baseModelID,
            String(compatibility.promptFormatVersion),
            String(compatibility.chatTemplateVersion),
            String(compatibility.loraLayerCount),
            String(compatibility.loraRank),
            String(compatibility.loraScale),
            TrainingOptimizationPolicy.current.identifier,
        ].joined(separator: ":")
        // The legacy sent-reply task keeps its persisted profile form so its
        // historical runs still match; every other task appends its identity,
        // so two tasks can never share a run or a failure/deferral stamp.
        + (compatibility.taskIdentifier == TrainingTaskIdentity.legacySentReply.identifier
            ? "" : ":" + compatibility.taskIdentifier)
    }

    @MainActor
    public func planRun(
        kind: TrainingCorpusRunKind,
        lineageID: String,
        baseModelManifestID: String,
        trainingProfileID: String,
        snapshotCutoff: Date,
        context: ModelContext
    ) throws -> TrainingCorpusRun {
        if let active = try context.fetch(FetchDescriptor<TrainingCorpusRun>())
            .first(where: {
                $0.lineageID == lineageID && Self.isActive($0.state)
            }) {
            guard active.baseModelManifestID == baseModelManifestID,
                  active.trainingProfileID == trainingProfileID else {
                throw TrainingCorpusPlannerError.activeRunManifestMismatch
            }
            return active
        }

        let allPairs = try context.fetch(FetchDescriptor<TrainingPair>())
        _ = TrainingOrchestrator.assignStableTrainingRoles(to: allPairs,
            trashedMessageIDs: try TrainingPair.trashedMessageIDs(in: context))
        let candidates = try eligibleCandidates(
            kind: kind,
            snapshotCutoff: snapshotCutoff,
            trainingProfileID: trainingProfileID,
            allPairs: allPairs,
            context: context
        )
        // Replay ballast guards incremental runs against catastrophic
        // forgetting: already-promoted pairs interleave with the new targets
        // in every epoch so an update never trains on fresh evidence alone.
        // Replay is excluded from the corpus fingerprint and every target count.
        let replay: [Candidate]
        if kind == .incremental, !candidates.isEmpty {
            replay = try replayCandidates(
                excludingPairIDs: Set(candidates.map(\.pair.id)),
                snapshotCutoff: snapshotCutoff,
                allPairs: allPairs,
                context: context
            )
        } else {
            replay = []
        }
        let epochs = candidates.isEmpty ? 1 : TrainingOptimizationPolicy.current.epochs(for: kind)
        let fingerprint = Self.corpusFingerprint(for: candidates)
        let run = TrainingCorpusRun(
            kind: kind,
            lineageID: lineageID,
            baseModelManifestID: baseModelManifestID,
            trainingProfileID: trainingProfileID,
            snapshotCutoff: snapshotCutoff,
            corpusFingerprint: fingerprint
        )
        run.epochCount = epochs
        run.targetCount = candidates.count * epochs
        run.replayCount = replay.count * epochs
        context.insert(run)

        // Each epoch is one full, differently ordered pass over the targets.
        var sequenced: [(candidate: Candidate, role: TrainingCorpusRunTargetRole, epoch: Int)] = []
        for epoch in 0..<epochs {
            let pass = Self.proportionalMerge([
                Self.balancedOrder(candidates, epoch: epoch).map { ($0, TrainingCorpusRunTargetRole.target) },
                Self.balancedOrder(replay, epoch: epoch).map { ($0, TrainingCorpusRunTargetRole.replay) },
            ].filter { !$0.isEmpty })
            sequenced += pass.map { ($0.0, $0.1, epoch) }
        }
        for (sequence, scheduled) in sequenced.enumerated() {
            let candidate = scheduled.candidate
            let target = TrainingCorpusRunTarget(
                pairID: candidate.pair.id,
                evidenceID: candidate.evidence.id,
                evidenceRevision: candidate.evidence.revision,
                sequence: sequence,
                role: scheduled.role
            )
            target.epoch = scheduled.epoch
            target.accountID = candidate.evidence.accountID
            target.identityID = candidate.evidence.identityID
            target.languageID = candidate.pair.languageID ?? candidate.evidence.languageID
            target.styleRegisterID = candidate.pair.styleRegisterID
            target.correspondentKey = candidate.evidence.correspondentAddress
            target.threadID = candidate.evidence.threadID
            target.sentAt = candidate.evidence.sentAt
            target.run = run
            context.insert(target)
        }
        try context.save()
        return run
    }

    /// How many already-promoted pairs interleave into an incremental run as
    /// forgetting protection. Matches the pre-durable-run replay sample size.
    public static let incrementalReplayBudget = 20

    /// Least-recently-replayed promoted pairs, oldest replay first. Only pairs
    /// whose current revision is fully incorporated qualify — replay must
    /// re-read learned evidence, never substitute for target scheduling.
    @MainActor
    private func replayCandidates(
        excludingPairIDs: Set<UUID>,
        snapshotCutoff: Date,
        allPairs: [TrainingPair],
        context: ModelContext
    ) throws -> [Candidate] {
        let trashedMessageIDs = try TrainingPair.trashedMessageIDs(in: context)
        let incorporated = allPairs.compactMap { pair -> Candidate? in
            guard let evidence = pair.evidence,
                  evidence.dispositionRaw == SentTrainingEvidenceDisposition.loraEligible.rawValue,
                  evidence.revision == pair.evidenceRevision,
                  evidence.learningPreference != .automaticDisabled,
                  evidence.learningPreference != .explicitDisabled,
                  (evidence.sentAt ?? evidence.createdAt) <= snapshotCutoff,
                  pair.latestPromotedEvidenceRevision == pair.evidenceRevision,
                  !excludingPairIDs.contains(pair.id),
                  pair.trainingRoleRaw != TrainingPairRole.validationHoldout.rawValue,
                  pair.referencesTrashedMessage(in: trashedMessageIDs) == false,
                  pair.isTrainablePromptFormat,
                  pair.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  pair.completionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return nil
            }
            return Candidate(pair: pair, evidence: evidence)
        }
        return incorporated
            .sorted { lhs, rhs in
                let leftReplayed = lhs.pair.lastReplayedAt ?? Date.distantPast
                let rightReplayed = rhs.pair.lastReplayedAt ?? Date.distantPast
                if leftReplayed != rightReplayed { return leftReplayed < rightReplayed }
                return Self.evidenceDateOrder(lhs, rhs)
            }
            .prefix(Self.incrementalReplayBudget)
            .map { $0 }
    }

    @MainActor
    private func eligibleCandidates(
        kind: TrainingCorpusRunKind,
        snapshotCutoff: Date,
        trainingProfileID: String,
        allPairs: [TrainingPair],
        context: ModelContext
    ) throws -> [Candidate] {
        let trashedMessageIDs = try TrainingPair.trashedMessageIDs(in: context)
        return allPairs.compactMap { pair in
            guard let evidence = pair.evidence,
                  evidence.dispositionRaw == SentTrainingEvidenceDisposition.loraEligible.rawValue,
                  evidence.revision == pair.evidenceRevision,
                  (evidence.sentAt ?? evidence.createdAt) <= snapshotCutoff,
                  pair.trainingRoleRaw != TrainingPairRole.validationHoldout.rawValue,
                  pair.referencesTrashedMessage(in: trashedMessageIDs) == false,
                  pair.isTrainablePromptFormat,
                  pair.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  pair.completionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return nil
            }
            if kind == .incremental,
               pair.latestPromotedEvidenceRevision == pair.evidenceRevision {
                return nil
            }
            if kind != .manualFull,
               pair.latestFailedEvidenceRevision == pair.evidenceRevision,
               pair.latestFailedTrainingProfileID == trainingProfileID {
                return nil
            }
            // Deferral pauses automatic retries for a while; Train Now does not wait.
            if kind != .manualFull, Self.isDeferred(pair, trainingProfileID: trainingProfileID, now: snapshotCutoff) {
                return nil
            }
            return Candidate(pair: pair, evidence: evidence)
        }
    }

    private static func isActive(_ state: TrainingCorpusRunState) -> Bool {
        switch state {
        case .preparing, .training, .validating, .checkpointing, .interrupted:
            true
        case .completed, .failed:
            false
        }
    }

    /// Priority order of the balance dimensions. Earlier dimensions partition
    /// first, so their groups interleave most strictly at the head of a run.
    private static let balanceDimensionCount = 7

    private static func balanceKey(_ candidate: Candidate, dimension: Int) -> String {
        let evidence = candidate.evidence
        switch dimension {
        case 0: return evidence.accountID.uuidString
        case 1: return evidence.identityID?.uuidString ?? "none"
        case 2: return candidate.pair.languageID ?? evidence.languageID ?? "und"
        case 3: return candidate.pair.styleRegisterID?.uuidString ?? "none"
        case 4: return evidence.correspondentAddress ?? "none"
        case 5: return evidence.threadID?.uuidString ?? "none"
        default:
            let sentAt = evidence.sentAt ?? evidence.createdAt
            return String(Int(sentAt.timeIntervalSince1970 / (30 * 24 * 60 * 60)))
        }
    }

    /// Deterministic hierarchical interleave, O(dimensions · n log n). Each
    /// dimension partitions its slice in priority order, recursively orders
    /// every group, then spreads each group's members proportionally across
    /// the merged result. A high-volume account, correspondent, language, or
    /// template family therefore appears evenly through the run instead of
    /// monopolizing its head — without the quadratic greedy scan this
    /// replaces, which stalled the main actor at real corpus scale.
    /// Whether a rejected candidate's deferral still holds for this exact
    /// revision and profile.
    public static func isDeferred(_ pair: TrainingPair, trainingProfileID: String, now: Date) -> Bool {
        guard pair.latestDeferredEvidenceRevision == pair.evidenceRevision,
              pair.latestDeferredTrainingProfileID == trainingProfileID else { return false }
        let deferredAt = pair.latestDeferredAt ?? .distantPast
        return now.timeIntervalSince(deferredAt) < TrainingOptimizationPolicy.current.deferralRetryInterval
    }

    /// Epoch 0 keeps the chronological balanced interleave; later epochs
    /// reorder groups and members by a stable epoch-salted hash, so every
    /// pass is balanced but no two passes present the corpus identically.
    private static func balancedOrder(_ candidates: [Candidate], epoch: Int = 0) -> [Candidate] {
        interleave(candidates, dimension: 0, epoch: epoch)
    }

    private static func interleave(_ candidates: [Candidate], dimension: Int, epoch: Int) -> [Candidate] {
        guard candidates.count > 1 else { return candidates }
        guard dimension < balanceDimensionCount else {
            guard epoch > 0 else { return candidates.sorted(by: evidenceDateOrder) }
            return candidates.sorted {
                saltedHash($0.pair.id.uuidString, epoch: epoch) < saltedHash($1.pair.id.uuidString, epoch: epoch)
            }
        }
        var groups: [String: [Candidate]] = [:]
        for candidate in candidates {
            groups[balanceKey(candidate, dimension: dimension), default: []].append(candidate)
        }
        guard groups.count > 1 else {
            return interleave(candidates, dimension: dimension + 1, epoch: epoch)
        }
        let orderedGroups = groups
            .map { entry in
                (
                    key: entry.key,
                    earliest: entry.value
                        .map { $0.evidence.sentAt ?? $0.evidence.createdAt }
                        .min() ?? Date.distantPast,
                    members: interleave(entry.value, dimension: dimension + 1, epoch: epoch)
                )
            }
            .sorted { lhs, rhs in
                if epoch > 0 {
                    return saltedHash(lhs.key, epoch: epoch) < saltedHash(rhs.key, epoch: epoch)
                }
                if lhs.earliest != rhs.earliest { return lhs.earliest < rhs.earliest }
                return lhs.key < rhs.key
            }
        return proportionalMerge(orderedGroups.map(\.members))
    }

    /// FNV-1a over the key and epoch: deterministic across launches.
    private static func saltedHash(_ key: String, epoch: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(epoch)|\(key)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Merges pre-ordered groups so each group's members spread evenly across
    /// the result: member k of a size-n group lands at rational position
    /// (2k+1)/(2n), compared exactly by cross-multiplication; earlier groups
    /// win ties. Equal-size groups therefore alternate strictly.
    private static func proportionalMerge<Element>(_ groups: [[Element]]) -> [Element] {
        var slots: [(group: Int, index: Int, size: Int)] = []
        slots.reserveCapacity(groups.reduce(0) { $0 + $1.count })
        for (groupIndex, members) in groups.enumerated() {
            for index in members.indices {
                slots.append((group: groupIndex, index: index, size: members.count))
            }
        }
        slots.sort { lhs, rhs in
            let left = Int64(2 * lhs.index + 1) * Int64(rhs.size)
            let right = Int64(2 * rhs.index + 1) * Int64(lhs.size)
            if left != right { return left < right }
            return lhs.group < rhs.group
        }
        return slots.map { groups[$0.group][$0.index] }
    }

    private static func evidenceDateOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let leftDate = lhs.evidence.sentAt ?? lhs.evidence.createdAt
        let rightDate = rhs.evidence.sentAt ?? rhs.evidence.createdAt
        if leftDate != rightDate { return leftDate < rightDate }
        return lhs.pair.id.uuidString < rhs.pair.id.uuidString
    }

    private static func corpusFingerprint(for candidates: [Candidate]) -> String {
        let canonical = candidates
            .map { "\($0.pair.id.uuidString.lowercased()):\($0.evidence.revision)" }
            .sorted()
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private struct Candidate {
        let pair: TrainingPair
        let evidence: SentTrainingEvidence
    }
}
