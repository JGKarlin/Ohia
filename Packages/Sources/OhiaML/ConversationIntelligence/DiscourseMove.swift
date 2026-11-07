import Foundation
import OhiaCore

/// Atomic communicative act detected inside a single message. Several moves
/// may fire per message — e.g. "I agree with Sarah's plan, but legal needs
/// to approve the contract first" emits affirmation + support + constraint
/// + dependency. The taxonomy combines Speech Act Theory, IBIS, and the
/// argumentation-mining vocabulary used throughout the design doc.
public struct DiscourseMove: Codable, Sendable, Equatable {
    public var kind: SpeechActKind
    /// Sender (usually the message's `fromAddress`) or `"system"` for
    /// signals derived from analyzer fields rather than message body.
    public var speaker: String
    /// Optional target address — used by request / answer / commitment
    /// moves where the move is directed at a specific recipient.
    public var target: String?
    public var evidenceSpan: DiscourseEvidenceSpan?
    public var support: SupportLevel
    public var confidence: Double
    /// Which analyzer field or heuristic produced this move. Recorded for
    /// provenance — the Evidence Drawer surfaces this in the "Source
    /// fields" section.
    public var sourceField: DiscourseSourceField

    public init(
        kind: SpeechActKind,
        speaker: String,
        target: String? = nil,
        evidenceSpan: DiscourseEvidenceSpan? = nil,
        support: SupportLevel,
        confidence: Double,
        sourceField: DiscourseSourceField
    ) {
        self.kind = kind
        self.speaker = speaker
        self.target = target
        self.evidenceSpan = evidenceSpan
        self.support = support
        self.confidence = confidence
        self.sourceField = sourceField
    }
}

/// Combined speech-act taxonomy per §9 of the design spec.
public enum SpeechActKind: String, Codable, Sendable, CaseIterable, Equatable {
    case request
    case question
    case answer
    case acknowledgement
    case clarification
    case correction
    case proposal
    case approval
    case refusal
    case objection
    case delegation
    case commitment
    case followUp
    case escalation
    case closure
}

/// IBIS role assigned to a piece of content in the message.
public struct IBISRoleAssignment: Codable, Sendable, Equatable {
    public var role: IBISRole
    public var text: String
    public var evidenceSpan: DiscourseEvidenceSpan?
    public var support: SupportLevel
    public var confidence: Double

    public init(
        role: IBISRole,
        text: String,
        evidenceSpan: DiscourseEvidenceSpan? = nil,
        support: SupportLevel,
        confidence: Double
    ) {
        self.role = role
        self.text = text
        self.evidenceSpan = evidenceSpan
        self.support = support
        self.confidence = confidence
    }
}

public enum IBISRole: String, Codable, Sendable, CaseIterable, Equatable {
    case issue
    case position
    case support
    case objection
    case counterexample
    case constraint
    case dependency
    case decision
    case unresolvedQuestion
}

/// Source-field tag used for provenance routing. Mirrors the §7 prompt
/// input packet plus a few derived buckets.
public enum DiscourseSourceField: String, Codable, Sendable, CaseIterable, Equatable {
    case mailboxFacts
    case quickTags
    case classification
    case meaningLabels
    case triageVerdict
    case triageActionSummary
    case triageActionInputs
    case triageAcknowledgementSummary
    case triageAcknowledgementFacts
    case bodySummary
    case attentionBucket
    case embeddingNeighbors
    case attachmentNotes
    case clusterLabels
    case dimensionsTasks
    case dimensionsDeadlines
    case dimensionsTone
    case threadContext
    case llmDirectExtraction
    case crossThreadPattern
}

/// Span pointing back into the message text body. Wraps the existing
/// `EvidenceSpan` from `AnalysisDimensions.swift` so the Evidence Drawer
/// can highlight the exact substring.
public struct DiscourseEvidenceSpan: Codable, Sendable, Equatable, Hashable {
    public var start: Int
    public var end: Int
    public var text: String
    public init(start: Int, end: Int, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
    public init(from existing: EvidenceSpan) {
        self.start = existing.start
        self.end = existing.end
        self.text = existing.text
    }
}
