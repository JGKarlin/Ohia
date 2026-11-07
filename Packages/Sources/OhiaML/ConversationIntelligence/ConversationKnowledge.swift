import Foundation
import OhiaCore

/// In-memory snapshot types built by the Conversation Memory extractor
/// pipeline. None of these are `@Model` — they're recomputed per
/// `ConversationsSnapshot`. Stable identity comes from the `key: String`
/// each one carries (a content-hashed digest), so curation verdicts in
/// `ConversationCurationAction` resolve durably across recomputations.

/// Normalized sent or received message event used as the shared substrate
/// for the rest of the snapshot types. Holds the references and identity
/// the UI / extractors need without forcing them to walk SwiftData.
public struct ConversationEvent: Sendable, Equatable, Hashable {
    public let messageID: UUID
    public let threadID: UUID?
    public let isSentByUser: Bool
    public let fromAddress: String
    public let recipients: [String]
    public let subject: String
    public let timestamp: Date
    public let classificationHints: [String]
    public let summary: String?
    public let vectorRowID: Int64?
    public let attachmentCount: Int

    public init(
        messageID: UUID,
        threadID: UUID?,
        isSentByUser: Bool,
        fromAddress: String,
        recipients: [String],
        subject: String,
        timestamp: Date,
        classificationHints: [String],
        summary: String?,
        vectorRowID: Int64?,
        attachmentCount: Int
    ) {
        self.messageID = messageID
        self.threadID = threadID
        self.isSentByUser = isSentByUser
        self.fromAddress = fromAddress
        self.recipients = recipients
        self.subject = subject
        self.timestamp = timestamp
        self.classificationHints = classificationHints
        self.summary = summary
        self.vectorRowID = vectorRowID
        self.attachmentCount = attachmentCount
    }
}

/// Question, problem, unresolved matter, or decision frame. Identity is the
/// composite `key` so curation verdicts survive recomputation.
public struct IssueNode: Sendable, Equatable, Hashable {
    public let key: String
    public let title: String
    public let status: IssueStatus
    public let projectLabels: [String]
    public let teamLabels: [String]
    public let firstSeen: Date
    public let lastActive: Date
    public let relatedThreadIDs: [UUID]
    public let evidenceMessageIDs: [UUID]

    public init(
        key: String,
        title: String,
        status: IssueStatus,
        projectLabels: [String],
        teamLabels: [String],
        firstSeen: Date,
        lastActive: Date,
        relatedThreadIDs: [UUID],
        evidenceMessageIDs: [UUID]
    ) {
        self.key = key
        self.title = title
        self.status = status
        self.projectLabels = projectLabels
        self.teamLabels = teamLabels
        self.firstSeen = firstSeen
        self.lastActive = lastActive
        self.relatedThreadIDs = relatedThreadIDs
        self.evidenceMessageIDs = evidenceMessageIDs
    }
}

public enum IssueStatus: String, Sendable, Codable, CaseIterable, Equatable {
    case open
    case resolved
    case contested
    case stale
    case unresolved
}

/// Proposal, support, objection, constraint, clarification, counterexample.
/// Attached to an `IssueNode` via `issueKey`.
public struct ArgumentNode: Sendable, Equatable, Hashable {
    public let key: String
    public let issueKey: String
    public let type: ArgumentType
    public let stance: ArgumentStance
    public let text: String
    public let evidenceLinks: [EvidenceLink]
    public let firstSeen: Date

    public init(
        key: String,
        issueKey: String,
        type: ArgumentType,
        stance: ArgumentStance,
        text: String,
        evidenceLinks: [EvidenceLink],
        firstSeen: Date
    ) {
        self.key = key
        self.issueKey = issueKey
        self.type = type
        self.stance = stance
        self.text = text
        self.evidenceLinks = evidenceLinks
        self.firstSeen = firstSeen
    }
}

public enum ArgumentType: String, Sendable, Codable, CaseIterable, Equatable {
    case proposal
    case support
    case objection
    case constraint
    case clarification
    case counterexample
}

public enum ArgumentStance: String, Sendable, Codable, CaseIterable, Equatable {
    case affirming
    case opposing
    case neutral
}

/// Explicit or inferred closure of an issue.
public struct DecisionNode: Sendable, Equatable, Hashable {
    public let key: String
    public let text: String
    public let decider: String?
    public let decidedAt: Date
    public let resolvedIssueKey: String?
    public let signOffMessageIDs: [UUID]
    public let evidenceLinks: [EvidenceLink]

    public init(
        key: String,
        text: String,
        decider: String?,
        decidedAt: Date,
        resolvedIssueKey: String?,
        signOffMessageIDs: [UUID],
        evidenceLinks: [EvidenceLink]
    ) {
        self.key = key
        self.text = text
        self.decider = decider
        self.decidedAt = decidedAt
        self.resolvedIssueKey = resolvedIssueKey
        self.signOffMessageIDs = signOffMessageIDs
        self.evidenceLinks = evidenceLinks
    }
}

/// Durable assertion — what users will see as Memory Cards.
public struct KnowledgeClaim: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let key: String
    public let text: String
    public let status: ClaimStatusBundle
    public let weight: Double
    public let scope: [ScopeHint]
    public let firstSeen: Date
    public let lastAffirmed: Date
    public let evidenceCount: Int
    public let evidenceLinks: [EvidenceLink]
    public let sourceParticipants: [String]
    public let contradictionKeys: [String]
    /// Structured fields carried through from the contributing `ClaimCandidate`s
    /// (see `ConversationMemoryAssembler.aggregateClaims`). Newest-anchor policy
    /// for `kindRaw`/`subjectText`/`asOf`/`expiresAt`/`conditionsText`;
    /// `originRaw`/`directionRaw`/`assertedBy` are derived by voting across
    /// contributors. All optional — pre-ledger claims and non-assembler call
    /// sites (e.g. `ConversationCurationApplier`) leave these `nil`.
    public let kindRaw: String?
    public let subjectText: String?
    public let assertedBy: String?
    public let directionRaw: String?
    public let originRaw: String?
    public let asOf: Date?
    public let expiresAt: Date?
    public let conditionsText: String?
    public let futureUseText: String?
    public let formationBasisRaw: String?
    public let usePolicyRaw: String?

    public init(
        id: UUID = UUID(),
        key: String,
        text: String,
        status: ClaimStatusBundle,
        weight: Double,
        scope: [ScopeHint],
        firstSeen: Date,
        lastAffirmed: Date,
        evidenceCount: Int,
        evidenceLinks: [EvidenceLink],
        sourceParticipants: [String],
        contradictionKeys: [String],
        kindRaw: String? = nil,
        subjectText: String? = nil,
        assertedBy: String? = nil,
        directionRaw: String? = nil,
        originRaw: String? = nil,
        asOf: Date? = nil,
        expiresAt: Date? = nil,
        conditionsText: String? = nil,
        futureUseText: String? = nil,
        formationBasisRaw: String? = nil,
        usePolicyRaw: String? = nil
    ) {
        self.id = id
        self.key = key
        self.text = text
        self.status = status
        self.weight = weight
        self.scope = scope
        self.firstSeen = firstSeen
        self.lastAffirmed = lastAffirmed
        self.evidenceCount = evidenceCount
        self.evidenceLinks = evidenceLinks
        self.sourceParticipants = sourceParticipants
        self.contradictionKeys = contradictionKeys
        self.kindRaw = kindRaw
        self.subjectText = subjectText
        self.assertedBy = assertedBy
        self.directionRaw = directionRaw
        self.originRaw = originRaw
        self.asOf = asOf
        self.expiresAt = expiresAt
        self.conditionsText = conditionsText
        self.futureUseText = futureUseText
        self.formationBasisRaw = formationBasisRaw
        self.usePolicyRaw = usePolicyRaw
    }
}

/// Multi-axis claim status. A card can read "high extraction confidence,
/// weak evidence, unconfirmed, contested, elevated sensitivity" without
/// contradiction — the UI surfaces all five chips in a fixed order.
public struct ClaimStatusBundle: Sendable, Equatable, Hashable {
    public let extractionConfidence: Double
    public let evidenceStrength: Double
    public let userConfirmation: UserConfirmation
    public let contradictionState: ContradictionState
    public let sensitivityRisk: SensitivityRisk

    public init(
        extractionConfidence: Double,
        evidenceStrength: Double,
        userConfirmation: UserConfirmation,
        contradictionState: ContradictionState,
        sensitivityRisk: SensitivityRisk
    ) {
        self.extractionConfidence = extractionConfidence
        self.evidenceStrength = evidenceStrength
        self.userConfirmation = userConfirmation
        self.contradictionState = contradictionState
        self.sensitivityRisk = sensitivityRisk
    }
}

public enum UserConfirmation: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case none
    case confirmed
    case rejected
    case weakened
    case markedStale
}

public enum ContradictionState: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case clean
    case contested
    case superseded
    case scopeNarrowed
}

public enum SensitivityRisk: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case none
    case low
    case elevated
    case high
}

/// Repeated resolution pattern across multiple threads.
public struct Precedent: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let key: String
    public let statement: String
    public let recurrenceCount: Int
    public let sourceThreadIDs: [UUID]
    public let applicabilityScore: Double
    public let exceptions: [String]
    public let evidenceLinks: [EvidenceLink]
    public let sensitivityRisk: SensitivityRisk

    public init(
        id: UUID = UUID(),
        key: String,
        statement: String,
        recurrenceCount: Int,
        sourceThreadIDs: [UUID],
        applicabilityScore: Double,
        exceptions: [String],
        evidenceLinks: [EvidenceLink],
        sensitivityRisk: SensitivityRisk
    ) {
        self.id = id
        self.key = key
        self.statement = statement
        self.recurrenceCount = recurrenceCount
        self.sourceThreadIDs = sourceThreadIDs
        self.applicabilityScore = applicabilityScore
        self.exceptions = exceptions
        self.evidenceLinks = evidenceLinks
        self.sensitivityRisk = sensitivityRisk
    }
}

/// Inferred uncodified practice. UI labels these "Inferred" until the user
/// confirms; sensitive ones gate harder via the sensitivity rules in §8.
public struct TacitRule: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let key: String
    public let rule: String
    public let pattern: TacitRulePattern
    public let confidence: Double
    public let scope: [ScopeHint]
    public let confirmationState: UserConfirmation
    public let evidenceLinks: [EvidenceLink]
    public let sensitivityRisk: SensitivityRisk

    public init(
        id: UUID = UUID(),
        key: String,
        rule: String,
        pattern: TacitRulePattern,
        confidence: Double,
        scope: [ScopeHint],
        confirmationState: UserConfirmation,
        evidenceLinks: [EvidenceLink],
        sensitivityRisk: SensitivityRisk
    ) {
        self.id = id
        self.key = key
        self.rule = rule
        self.pattern = pattern
        self.confidence = confidence
        self.scope = scope
        self.confirmationState = confirmationState
        self.evidenceLinks = evidenceLinks
        self.sensitivityRisk = sensitivityRisk
    }
}

/// Provenance link from a knowledge object back to its source.
public struct EvidenceLink: Sendable, Equatable, Hashable {
    public let messageID: UUID
    public let threadID: UUID?
    public let fieldSource: DiscourseSourceField
    public let span: DiscourseEvidenceSpan?
    public let attachmentID: UUID?
    public let confidence: Double
    public let timestamp: Date

    public init(
        messageID: UUID,
        threadID: UUID? = nil,
        fieldSource: DiscourseSourceField,
        span: DiscourseEvidenceSpan?,
        attachmentID: UUID? = nil,
        confidence: Double,
        timestamp: Date
    ) {
        self.messageID = messageID
        self.threadID = threadID
        self.fieldSource = fieldSource
        self.span = span
        self.attachmentID = attachmentID
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

/// Incompatible claim relationship.
public struct ContradictionLink: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let olderClaimKey: String
    public let newerClaimKey: String
    public let type: ContradictionType
    public let sourceMessageIDs: [UUID]
    public let detectedAt: Date
    public let resolved: Bool

    public init(
        id: UUID = UUID(),
        olderClaimKey: String,
        newerClaimKey: String,
        type: ContradictionType,
        sourceMessageIDs: [UUID],
        detectedAt: Date,
        resolved: Bool
    ) {
        self.id = id
        self.olderClaimKey = olderClaimKey
        self.newerClaimKey = newerClaimKey
        self.type = type
        self.sourceMessageIDs = sourceMessageIDs
        self.detectedAt = detectedAt
        self.resolved = resolved
    }
}

public enum ContradictionType: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case contradiction
    case supersession
    case scopeNarrowing
}

/// Supersession record (older claim → newer claim) used by Ask context and
/// the Evidence Drawer timeline strip.
public struct SupersessionRecord: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let olderClaimKey: String
    public let newerClaimKey: String
    public let detectedAt: Date
    public let sourceMessageIDs: [UUID]

    public init(
        id: UUID = UUID(),
        olderClaimKey: String,
        newerClaimKey: String,
        detectedAt: Date,
        sourceMessageIDs: [UUID]
    ) {
        self.id = id
        self.olderClaimKey = olderClaimKey
        self.newerClaimKey = newerClaimKey
        self.detectedAt = detectedAt
        self.sourceMessageIDs = sourceMessageIDs
    }
}

/// Single row inside Open Loops. Tagged with category so the UI groups by
/// kind (unanswered questions / contested claims / pending decisions /
/// missing inputs / active contradictions).
public struct OpenLoopRow: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let category: OpenLoopCategory
    public let title: String
    public let detail: String?
    public let evidenceLinks: [EvidenceLink]
    public let issueKey: String?
    public let claimKey: String?
    public let deadline: Date?
    public let lastActive: Date
    public let owner: String?
    public let sensitivityRisk: SensitivityRisk

    public init(
        id: UUID = UUID(),
        category: OpenLoopCategory,
        title: String,
        detail: String?,
        evidenceLinks: [EvidenceLink],
        issueKey: String? = nil,
        claimKey: String? = nil,
        deadline: Date? = nil,
        lastActive: Date,
        owner: String? = nil,
        sensitivityRisk: SensitivityRisk
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.evidenceLinks = evidenceLinks
        self.issueKey = issueKey
        self.claimKey = claimKey
        self.deadline = deadline
        self.lastActive = lastActive
        self.owner = owner
        self.sensitivityRisk = sensitivityRisk
    }
}

public enum OpenLoopCategory: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case unansweredQuestion
    case contestedClaim
    case pendingDecision
    case missingInput
    case activeContradiction
}
