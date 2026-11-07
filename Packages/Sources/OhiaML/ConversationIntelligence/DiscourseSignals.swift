import Foundation
import OhiaCore

/// Durable assertion candidate emitted by the extractor. Promoted to a
/// `KnowledgeClaim` in the snapshot when `support.qualifiesAsCandidate`
/// and the sensitivity gate clears.
public struct ClaimCandidate: Codable, Sendable, Equatable {
    public var text: String
    public var support: SupportLevel
    public var confidence: Double
    public var evidenceSpans: [DiscourseEvidenceSpan]
    public var scope: [ScopeHint]
    public var sourceField: DiscourseSourceField
    public var kindRaw: String?
    public var subjectText: String?
    public var assertedBy: String?
    public var directionRaw: String?
    public var asOf: Date?
    public var expiresAt: Date?
    public var conditionsText: String?
    /// Why this guidance will matter when handling future correspondence.
    public var futureUseText: String?
    /// One of `AccountMemoryFormationBasis`; optional for legacy JSON only.
    public var formationBasisRaw: String?
    /// One of `AccountMemoryUsePolicy`; optional for legacy JSON only.
    public var usePolicyRaw: String?
    /// Explicit extractor classification. `true` candidates are never admitted.
    public var isEpisodic: Bool?

    public init(
        text: String,
        support: SupportLevel,
        confidence: Double,
        evidenceSpans: [DiscourseEvidenceSpan] = [],
        scope: [ScopeHint] = [],
        sourceField: DiscourseSourceField,
        kindRaw: String? = nil,
        subjectText: String? = nil,
        assertedBy: String? = nil,
        directionRaw: String? = nil,
        asOf: Date? = nil,
        expiresAt: Date? = nil,
        conditionsText: String? = nil,
        futureUseText: String? = nil,
        formationBasisRaw: String? = nil,
        usePolicyRaw: String? = nil,
        isEpisodic: Bool? = nil
    ) {
        self.text = text
        self.support = support
        self.confidence = confidence
        self.evidenceSpans = evidenceSpans
        self.scope = scope
        self.sourceField = sourceField
        self.kindRaw = kindRaw
        self.subjectText = subjectText
        self.assertedBy = assertedBy
        self.directionRaw = directionRaw
        self.asOf = asOf
        self.expiresAt = expiresAt
        self.conditionsText = conditionsText
        self.futureUseText = futureUseText
        self.formationBasisRaw = formationBasisRaw
        self.usePolicyRaw = usePolicyRaw
        self.isEpisodic = isEpisodic
    }
}

/// Explicit or strongly-implied decision detected in the message.
public struct DecisionCandidate: Codable, Sendable, Equatable {
    public var text: String
    public var decider: String?
    public var support: SupportLevel
    public var confidence: Double
    public var evidenceSpans: [DiscourseEvidenceSpan]
    public var resolvedIssueText: String?
    public var sourceField: DiscourseSourceField

    public init(
        text: String,
        decider: String? = nil,
        support: SupportLevel,
        confidence: Double,
        evidenceSpans: [DiscourseEvidenceSpan] = [],
        resolvedIssueText: String? = nil,
        sourceField: DiscourseSourceField
    ) {
        self.text = text
        self.decider = decider
        self.support = support
        self.confidence = confidence
        self.evidenceSpans = evidenceSpans
        self.resolvedIssueText = resolvedIssueText
        self.sourceField = sourceField
    }
}

/// Signal that this message references a prior practice or repeated
/// resolution. Cross-thread mining promotes these to first-class
/// `Precedent` records once two or more signals converge.
public struct PrecedentSignal: Codable, Sendable, Equatable {
    public var statement: String
    public var referencedThreadHint: String?
    public var support: SupportLevel
    public var confidence: Double
    public var evidenceSpans: [DiscourseEvidenceSpan]
    public var sourceField: DiscourseSourceField

    public init(
        statement: String,
        referencedThreadHint: String? = nil,
        support: SupportLevel,
        confidence: Double,
        evidenceSpans: [DiscourseEvidenceSpan] = [],
        sourceField: DiscourseSourceField
    ) {
        self.statement = statement
        self.referencedThreadHint = referencedThreadHint
        self.support = support
        self.confidence = confidence
        self.evidenceSpans = evidenceSpans
        self.sourceField = sourceField
    }
}

/// "Usually," "as before," "standard process," repeated workflow cues, or
/// observed repetition from cross-thread mining. Detected pattern type is
/// surfaced so the UI can label the rule appropriately.
public struct TacitRuleSignal: Codable, Sendable, Equatable {
    public var rule: String
    public var pattern: TacitRulePattern
    public var support: SupportLevel
    public var confidence: Double
    public var evidenceSpans: [DiscourseEvidenceSpan]
    public var sourceField: DiscourseSourceField

    public init(
        rule: String,
        pattern: TacitRulePattern,
        support: SupportLevel,
        confidence: Double,
        evidenceSpans: [DiscourseEvidenceSpan] = [],
        sourceField: DiscourseSourceField
    ) {
        self.rule = rule
        self.pattern = pattern
        self.support = support
        self.confidence = confidence
        self.evidenceSpans = evidenceSpans
        self.sourceField = sourceField
    }
}

public enum TacitRulePattern: String, Codable, Sendable, CaseIterable, Equatable {
    case repeatedQA
    case repeatedApprovalPath
    case repeatedDependency
    case repeatedAssignee
    case repeatedException
    case explicitNormLanguage
    case reaffirmedPrecedent
}

/// Statement that conflicts with an existing claim. Pair-up to a
/// `ContradictionLink` happens during snapshot assembly when the older
/// claim can be identified.
public struct ContradictionSignal: Codable, Sendable, Equatable {
    public var conflictingClaim: String
    public var negationCue: String?
    public var support: SupportLevel
    public var confidence: Double
    public var evidenceSpans: [DiscourseEvidenceSpan]
    public var sourceField: DiscourseSourceField

    public init(
        conflictingClaim: String,
        negationCue: String? = nil,
        support: SupportLevel,
        confidence: Double,
        evidenceSpans: [DiscourseEvidenceSpan] = [],
        sourceField: DiscourseSourceField
    ) {
        self.conflictingClaim = conflictingClaim
        self.negationCue = negationCue
        self.support = support
        self.confidence = confidence
        self.evidenceSpans = evidenceSpans
        self.sourceField = sourceField
    }
}

/// Update that replaces older information. Distinct from contradiction:
/// a supersession does not refute the older statement, it announces a
/// later authoritative version of it.
public struct SupersessionSignal: Codable, Sendable, Equatable {
    public var newerStatement: String
    public var olderHint: String?
    public var support: SupportLevel
    public var confidence: Double
    public var evidenceSpans: [DiscourseEvidenceSpan]
    public var sourceField: DiscourseSourceField

    public init(
        newerStatement: String,
        olderHint: String? = nil,
        support: SupportLevel,
        confidence: Double,
        evidenceSpans: [DiscourseEvidenceSpan] = [],
        sourceField: DiscourseSourceField
    ) {
        self.newerStatement = newerStatement
        self.olderHint = olderHint
        self.support = support
        self.confidence = confidence
        self.evidenceSpans = evidenceSpans
        self.sourceField = sourceField
    }
}

/// Semantic tag / time / policy / amount / location / exception /
/// classification / correspondent / language boundary on an extracted item.
/// Constrains the applicability of claims, precedents, and tacit rules;
/// consumed by `ClaimWeightingEngine.scopeFit`.
public struct ScopeHint: Codable, Sendable, Equatable, Hashable {
    public var kind: ScopeKind
    public var value: String
    public init(kind: ScopeKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public enum ScopeKind: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    case semanticTag
    case project
    case team
    case time
    case policy
    case amount
    case location
    case exception
    case classification
    case correspondent
    case language
}

/// Ambiguous item the model could not commit to. Surfaces in the UI as a
/// review item — never promoted to a memory card without user confirmation.
public struct Uncertainty: Codable, Sendable, Equatable {
    public var question: String
    public var candidate: String
    public var evidenceSpans: [DiscourseEvidenceSpan]
    public var sourceField: DiscourseSourceField

    public init(
        question: String,
        candidate: String,
        evidenceSpans: [DiscourseEvidenceSpan] = [],
        sourceField: DiscourseSourceField
    ) {
        self.question = question
        self.candidate = candidate
        self.evidenceSpans = evidenceSpans
        self.sourceField = sourceField
    }
}
