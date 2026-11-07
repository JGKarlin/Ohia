import Foundation
import SwiftData

public enum TrainingCorpusRunKind: String, Codable, Sendable {
    case initialFull
    case incremental
    case manualFull
}

public enum TrainingCorpusRunState: String, Codable, Sendable {
    case preparing
    case training
    case validating
    case checkpointing
    case completed
    case interrupted
    case failed
}

public enum TrainingCorpusRunTargetRole: String, Codable, Sendable {
    case target
    case replay
}

public enum TrainingCorpusRunVisitState: String, Codable, Sendable {
    case pending
    case attempted
    case incorporated
    case skipped
    case failed
}

/// Durable lifecycle and aggregate accounting for one immutable corpus
/// snapshot. A shared lineage spans every configured account.
@Model
public final class TrainingCorpusRun {
    public var id: UUID
    public var kindRaw: String
    public var stateRaw: String
    public var lineageID: String
    public var baseModelManifestID: String
    public var trainingProfileID: String
    public var snapshotCutoff: Date
    public var corpusFingerprint: String

    public var createdAt: Date
    public var startedAt: Date?
    public var heartbeatAt: Date?
    public var completedAt: Date?
    public var interruptedAt: Date?
    public var failedAt: Date?
    public var failureReason: String?

    public var targetCount: Int
    public var replayCount: Int
    public var attemptedTargetCount: Int
    public var incorporatedTargetCount: Int
    public var skippedTargetCount: Int
    public var failedTargetCount: Int
    public var rejectedCandidateCount: Int
    public var failureAttemptCount: Int
    public var targetLossSum: Double
    public var targetLossSampleCount: Int
    public var aggregateTargetLoss: Double?
    public var aggregateValidationLoss: Double?
    public var latestPromotedCheckpointID: UUID?
    /// Full passes over the run's targets. Every target pair appears once per
    /// epoch; a candidate is judged only when an epoch completes. Nil marks a
    /// run planned before epochs existed, which has a single pass.
    public var epochCount: Int?

    @Relationship(deleteRule: .cascade, inverse: \TrainingCorpusRunTarget.run)
    public var targets: [TrainingCorpusRunTarget] = []

    public init(
        kind: TrainingCorpusRunKind,
        lineageID: String,
        baseModelManifestID: String,
        trainingProfileID: String,
        snapshotCutoff: Date,
        corpusFingerprint: String,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.stateRaw = TrainingCorpusRunState.preparing.rawValue
        self.lineageID = lineageID
        self.baseModelManifestID = baseModelManifestID
        self.trainingProfileID = trainingProfileID
        self.snapshotCutoff = snapshotCutoff
        self.corpusFingerprint = corpusFingerprint
        self.createdAt = createdAt
        self.targetCount = 0
        self.replayCount = 0
        self.attemptedTargetCount = 0
        self.incorporatedTargetCount = 0
        self.skippedTargetCount = 0
        self.failedTargetCount = 0
        self.rejectedCandidateCount = 0
        self.failureAttemptCount = 0
        self.targetLossSum = 0
        self.targetLossSampleCount = 0
    }

    public var kind: TrainingCorpusRunKind {
        get { TrainingCorpusRunKind(rawValue: kindRaw) ?? .incremental }
        set { kindRaw = newValue.rawValue }
    }

    public var resolvedEpochCount: Int { max(1, epochCount ?? 1) }

    public var state: TrainingCorpusRunState {
        get { TrainingCorpusRunState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }
}

/// One immutable pair-revision entry in a run snapshot. Strata are copied at
/// planning time so later metadata changes cannot silently reorder the run.
@Model
public final class TrainingCorpusRunTarget {
    public var id: UUID
    public var run: TrainingCorpusRun?
    public var pairID: UUID
    public var evidenceID: UUID
    public var evidenceRevision: Int
    public var sequence: Int
    /// Zero-based pass this visit belongs to. Nil for runs planned before
    /// epochs existed, which are a single pass.
    public var epoch: Int?
    public var roleRaw: String
    public var visitStateRaw: String

    public var accountID: UUID?
    public var identityID: UUID?
    public var languageID: String?
    public var styleRegisterID: UUID?
    public var correspondentKey: String?
    public var threadID: UUID?
    public var sentAt: Date?

    public var attemptedAt: Date?
    public var incorporatedAt: Date?
    public var checkpointID: UUID?
    public var failureReason: String?

    public init(
        pairID: UUID,
        evidenceID: UUID,
        evidenceRevision: Int,
        sequence: Int,
        role: TrainingCorpusRunTargetRole
    ) {
        self.id = UUID()
        self.pairID = pairID
        self.evidenceID = evidenceID
        self.evidenceRevision = evidenceRevision
        self.sequence = sequence
        self.roleRaw = role.rawValue
        self.visitStateRaw = TrainingCorpusRunVisitState.pending.rawValue
    }

    public var role: TrainingCorpusRunTargetRole {
        get { TrainingCorpusRunTargetRole(rawValue: roleRaw) ?? .target }
        set { roleRaw = newValue.rawValue }
    }

    public var visitState: TrainingCorpusRunVisitState {
        get { TrainingCorpusRunVisitState(rawValue: visitStateRaw) ?? .failed }
        set { visitStateRaw = newValue.rawValue }
    }

    public var resolvedEpoch: Int { epoch ?? 0 }
}
