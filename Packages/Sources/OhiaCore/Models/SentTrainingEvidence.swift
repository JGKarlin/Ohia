import Foundation
import SwiftData

extension SentTrainingEvidence {
    /// How long a retryable preparation failure waits before another attempt.
    public static let preparationRetryInterval: TimeInterval = 3_600
}

public enum SentTrainingEvidenceKind: String, Codable, Sendable {
    case historicalReply
    case historicalStandalone
    case composerReply
    case composerStandalone
}

/// Every sent email is either trained, excluded for a stated reason, waiting
/// for preparation, or failed preparation. A disposition written by an older
/// build that this enum no longer names is re-prepared by the builder.
public enum SentTrainingEvidenceDisposition: String, Codable, Sendable {
    case pendingPreparation
    case loraEligible
    case excluded
    case preparationFailed
}

public enum SentTrainingEvidenceReason: String, Codable, Sendable {
    case unchangedGeneratedOutput
    case userOptOut
    case trivialAcknowledgment
    case automatedResponse
    case duplicateContent
    case missingBody
    case missingParent
    case malformedThreading
    case trashedSource
    case unsupportedEvidenceShape
    /// Reconstruction outcomes, recorded individually so a preparation
    /// failure says which check rejected the sent email.
    case reconstructionCopiedSentText
    case reconstructionUnsupportedUnit
    case reconstructionRestatesIncoming
    case reconstructionEmpty
    case reconstructionMeaningMismatch
    /// Rejected under the earlier notes reserve (the full completion length).
    /// Due once more, where the bounded reserve decides again.
    case exceedsWriterWindow
    /// The example cannot share the trained window with its completion even
    /// with every droppable source left out.
    case exceedsTrainingWindow
    /// The incoming email has no text of its own (only quoted or forwarded
    /// mail), so there is nothing a reply example could answer.
    case incomingHasNoOriginalText
    /// The sent email mostly repeats the author's earlier send in the same
    /// thread; the earlier send is its own example.
    case resendOfEarlierSend
}

public enum SentTrainingLearningPreference: String, Codable, Sendable {
    case automaticEnabled
    case automaticDisabled
    case explicitEnabled
    case explicitDisabled
}

/// Audit authority for one discovered outgoing message. Preparation may
/// produce more than one pair (for example, a reply-shaped pair plus an
/// instruction-revision pair), but every pair remains attributable to this
/// single send and evidence revision.
@Model
public final class SentTrainingEvidence {
    public var id: UUID
    @Attribute(.unique) public var sourceIdentityKey: String
    public var accountID: UUID
    public var sourceMessageID: UUID?
    public var sourceOutboxID: UUID?
    public var normalizedMessageID: String?
    public var sourceMailboxLocator: String?

    public var kindRaw: String
    public var authoredTextFingerprint: String?
    public var authoredBodyPath: String?
    public var languageID: String?
    /// Measured final authored text, distinct from requested Composer controls.
    public var measuredStyleScoreJSON: String?
    public var styleScoringFailureCount: Int?
    public var styleScoringRetryAfter: Date?
    public var identityID: UUID?
    public var correspondentAddress: String?
    public var threadID: UUID?
    public var subjectRoot: String?
    public var sentAt: Date?

    public var learningPreferenceRaw: String
    public var learningPreferenceDecidedAt: Date?
    public var dispositionRaw: String
    public var reasonRaw: String?
    public var dispositionedAt: Date?
    public var preparationAttemptedAt: Date?
    public var isRetryable: Bool
    /// The prompt format the last preparation ran under. A failure recorded
    /// under an older format is retried once under the current one. Optional
    /// for lightweight migration; nil means "before the writer task".
    public var preparationTaskVersion: Int?
    public var revision: Int
    public var canonicalEvidenceID: UUID?

    public var createdAt: Date
    public var updatedAt: Date

    public var sourceMessage: Message?
    public var sourceOutbox: OutboxItem?

    @Relationship(deleteRule: .cascade, inverse: \TrainingPair.evidence)
    public var trainingPairs: [TrainingPair] = []

    public init(
        sourceIdentityKey: String,
        accountID: UUID,
        kind: SentTrainingEvidenceKind,
        learningPreference: SentTrainingLearningPreference = .automaticEnabled,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.sourceIdentityKey = sourceIdentityKey
        self.accountID = accountID
        self.kindRaw = kind.rawValue
        self.learningPreferenceRaw = learningPreference.rawValue
        self.dispositionRaw = SentTrainingEvidenceDisposition.pendingPreparation.rawValue
        self.isRetryable = false
        self.revision = 1
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public var kind: SentTrainingEvidenceKind {
        get { SentTrainingEvidenceKind(rawValue: kindRaw) ?? .historicalStandalone }
        set { kindRaw = newValue.rawValue }
    }

    public var learningPreference: SentTrainingLearningPreference {
        get { SentTrainingLearningPreference(rawValue: learningPreferenceRaw) ?? .automaticEnabled }
        set { learningPreferenceRaw = newValue.rawValue }
    }

    public var disposition: SentTrainingEvidenceDisposition {
        // A disposition an older build wrote is re-prepared: it is pending.
        get { SentTrainingEvidenceDisposition(rawValue: dispositionRaw) ?? .pendingPreparation }
        set { dispositionRaw = newValue.rawValue }
    }

    public var reason: SentTrainingEvidenceReason? {
        get { reasonRaw.flatMap(SentTrainingEvidenceReason.init(rawValue:)) }
        set { reasonRaw = newValue?.rawValue }
    }
}
