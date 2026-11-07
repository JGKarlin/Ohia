import Foundation
import OhiaCore

/// A character range in source text that supports an extracted label.
public struct EvidenceSpan: Codable, Sendable, Equatable {
    public let start: Int
    public let end: Int
    public let text: String

    public init(start: Int, end: Int, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A single label with a probability score and optional evidence.
public struct WeightedLabel: Codable, Sendable, Equatable {
    public let label: String
    public let score: Double
    public let confidence: Double
    public let evidenceSpans: [EvidenceSpan]

    public init(label: String, score: Double, confidence: Double, evidenceSpans: [EvidenceSpan] = []) {
        self.label = label
        self.score = score
        self.confidence = confidence
        self.evidenceSpans = evidenceSpans
    }
}

/// Denormalized presentation and weighting data for one authoritative
/// canonical semantic-tag membership. `tagID` is the only identity; the
/// display name may change as preferred aliases change.
public struct SemanticTagProjection: Codable, Sendable, Equatable {
    public let tagID: UUID
    public let displayName: String
    public let score: Double
    public let confidence: Double
    public let centrality: SemanticTagCentrality
    public let roles: [SemanticTagRole]

    public init(
        tagID: UUID,
        displayName: String,
        score: Double,
        confidence: Double,
        centrality: SemanticTagCentrality,
        roles: [SemanticTagRole]
    ) {
        self.tagID = tagID
        self.displayName = displayName
        self.score = min(1, max(0, score.isFinite ? score : 0))
        self.confidence = min(1, max(0, confidence.isFinite ? confidence : 0))
        self.centrality = centrality
        var seenRoles = Set<SemanticTagRole>()
        self.roles = roles.filter { seenRoles.insert($0).inserted }
    }

    public var weightedScore: Double {
        score * confidence * centrality.weightMultiplier
    }
}

/// A scalar dimension (0.0–1.0) with confidence and optional evidence.
public struct ScalarDimension: Codable, Sendable, Equatable {
    public let value: Double
    public let confidence: Double
    public let evidenceSpans: [EvidenceSpan]

    public init(value: Double, confidence: Double, evidenceSpans: [EvidenceSpan] = []) {
        self.value = value
        self.confidence = confidence
        self.evidenceSpans = evidenceSpans
    }
}

/// A deadline candidate extracted from message text.
public struct DeadlineCandidate: Codable, Sendable, Equatable {
    public let dateString: String
    public let type: String  // "hard", "soft", "conditional"
    public let confidence: Double
    public let evidenceSpan: EvidenceSpan?

    public init(dateString: String, type: String, confidence: Double, evidenceSpan: EvidenceSpan? = nil) {
        self.dateString = dateString
        self.type = type
        self.confidence = confidence
        self.evidenceSpan = evidenceSpan
    }

    public var displayText: String? {
        let trimmedText = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              !Self.isPlaceholderText(trimmedText) else { return nil }
        return trimmedText
    }

    /// Builds a deadline from the LLM's surface-text + kind output.
    /// Returns nil when `text` is empty or contains only placeholder/list
    /// separator text after trimming. Unknown deadline kinds default to
    /// `"soft"` rather than dropping the deadline, since an unknown-kind
    /// deadline still carries actionable timing.
    public static func make(text: String, kind: String) -> DeadlineCandidate? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              !isPlaceholderText(trimmedText) else { return nil }
        let canonicalKind = switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "hard":        "hard"
            case "soft":        "soft"
            case "conditional": "conditional"
            default:            "soft"
        }
        return DeadlineCandidate(
            dateString: trimmedText,
            type: canonicalKind,
            confidence: 0.7,
            evidenceSpan: nil
        )
    }

    private static func isPlaceholderText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["|", "||", "none", "null", "nil", "n/a", "na", "[]", "empty", "<empty>"].contains(normalized) {
            return true
        }
        return normalized.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } == false
    }
}

/// A concrete timed meeting inferred from an email body. This is scheduling
/// evidence only: it does not participate in mail purpose or attention tags.
/// Recognized calendar invitations supersede these fields during tracking.
public struct MeetingCandidate: Codable, Sendable, Equatable {
    public let title: String
    public let startText: String
    public let endText: String?
    public let timeZoneIdentifier: String?
    public let location: String?
    public let onlineMeetingURL: String?
    public let confidence: Double

    public init(
        title: String,
        startText: String,
        endText: String? = nil,
        timeZoneIdentifier: String? = nil,
        location: String? = nil,
        onlineMeetingURL: String? = nil,
        confidence: Double = 0.7
    ) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startText = startText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endText = Self.nonEmpty(endText)
        self.timeZoneIdentifier = Self.nonEmpty(timeZoneIdentifier)
        self.location = Self.nonEmpty(location)
        self.onlineMeetingURL = Self.nonEmpty(onlineMeetingURL)
        self.confidence = min(1, max(0, confidence))
    }

    public static func make(
        title: String,
        startText: String,
        endText: String,
        timeZoneIdentifier: String,
        location: String,
        onlineMeetingURL: String
    ) -> MeetingCandidate? {
        let start = startText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard start.isEmpty == false else { return nil }
        return MeetingCandidate(
            title: title,
            startText: start,
            endText: endText,
            timeZoneIdentifier: timeZoneIdentifier,
            location: location,
            onlineMeetingURL: onlineMeetingURL
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

/// Shared utilities for normalizing LLM-emitted strings into the persistent
/// triage struct family. Used by both the Apple Foundation `@Generable`
/// adapter and the MLX line-prefix parser so the two paths produce
/// identically-shaped storage.
public enum TriageVerdictParsing {
    public static let arraySeparator = "||"
    private static let maxArrayItems = 5

    /// Trims each element, drops empties, and caps the result at 5 items.
    public static func trimmedNonEmpty(_ values: [String]) -> [String] {
        let trimmed = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(trimmed.prefix(maxArrayItems))
    }

    /// Splits a `||`-separated array string into trimmed, non-empty,
    /// 5-capped items. Empty input yields an empty array.
    public static func splitArrayString(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        return trimmedNonEmpty(raw.components(separatedBy: arraySeparator))
    }
}

/// A task requirement extracted from message text.
public struct TaskRequirement: Codable, Sendable, Equatable {
    public let taskType: String
    public let actionObject: String?
    public let assignee: String?  // "user", "correspondent", "third_party"
    public let dueCandidate: String?
    public let confidence: Double
    public let evidenceSpans: [EvidenceSpan]

    public init(
        taskType: String,
        actionObject: String? = nil,
        assignee: String? = nil,
        dueCandidate: String? = nil,
        confidence: Double,
        evidenceSpans: [EvidenceSpan] = []
    ) {
        self.taskType = taskType
        self.actionObject = actionObject
        self.assignee = assignee
        self.dueCandidate = dueCandidate
        self.confidence = confidence
        self.evidenceSpans = evidenceSpans
    }
}

/// The complete analysis output for a single message.
public struct MessageDimensions: Codable, Sendable {
    public var urgency: ScalarDimension
    public var formality: ScalarDimension
    public var familiarity: ScalarDimension
    public var deadlines: [DeadlineCandidate]
    /// Optional for lightweight decoding of rows written before meeting
    /// extraction existed.
    public var meetings: [MeetingCandidate]?
    public var tasks: [TaskRequirement]
    public var semanticTags: [SemanticTagProjection]
    public var extractionVersion: String

    public init(extractionVersion: String) {
        self.urgency = ScalarDimension(value: 0.0, confidence: 0.0)
        self.formality = ScalarDimension(value: 0.5, confidence: 0.0)
        self.familiarity = ScalarDimension(value: 0.0, confidence: 0.0)
        self.deadlines = []
        self.meetings = []
        self.tasks = []
        self.semanticTags = []
        self.extractionVersion = extractionVersion
    }

    /// Returns a copy with triage-owned action state removed while preserving
    /// semantic metadata that remains useful for historical/backfill mail.
    public func scrubbingTriageActionState() -> MessageDimensions {
        var copy = self
        copy.deadlines = []
        copy.meetings = []
        return copy
    }

    public var primaryDeadlineDisplayText: String? {
        deadlines.compactMap(\.displayText).first
    }
}

// MARK: - Triage verdict (LLM-driven)
//
// The triage verdict captures two orthogonal attention axes per message —
// `isActionable` (sender expects a reply or draftable response from the
// recipient) and `requiresConfirmation` (recipient must absorb /
// acknowledge information, no reply needed) — plus a structured payload
// describing what the action or acknowledgement actually is. Both flags are
// independent: a message can be neither, either, or both. Produced by the
// LLM in `.summarize` and persisted as JSON on
// `MessageAnalysis.triageVerdictJSON`.

/// What kind of response the sender is asking for. This is intentionally
/// narrower than every possible off-platform task: portal actions, payments,
/// marketing CTAs, and automated notices are not reply obligations unless
/// the sender explicitly asks for a direct response.
public enum ActionKind: String, Codable, Sendable, CaseIterable {
    /// Open-ended written reply.
    case reply
    /// Sender asks for a specific piece of information (figures, files, dates).
    case provideInformation
    /// Sender asks for a yes/no or a choice between options.
    case makeDecision
    /// Sender wants to coordinate a meeting time or schedule.
    case scheduleMeeting
    /// Sender wants the recipient to look at something and respond.
    case review
    /// Sender wants approval, sign-off, or a signature.
    case signOff
    case other
}

/// Who the action is directed at.
public enum Assignee: String, Codable, Sendable, CaseIterable {
    /// Directed at the account owner specifically.
    case user
    /// Directed at the user's team or organization (user is one of many recipients).
    case userTeam
    /// Directed at someone else; user is informed but not the responsible party.
    case thirdParty
    case ambiguous
}

/// What kind of acknowledgement signal the message carries.
public enum SignalKind: String, Codable, Sendable, CaseIterable {
    /// One-time codes, magic links, 2FA — transient, time-sensitive.
    case verificationCode
    /// Persistent security state changes (logins, password changes, breach notices).
    case securityAlert
    /// Meeting moved, accepted, declined, or cancelled.
    case calendarChange
    /// Statement available, payment due, charge posted.
    case financialAlert
    /// Contract / policy / compliance deadline.
    case legalDeadline
    /// Shipped, delivered, address-confirm needed.
    case shippingMilestone
    /// Hotel / restaurant / appointment confirmation.
    case bookingConfirmation
    /// Account settings changed, plan changed, profile updated.
    case accountChange
    /// Generic delivery or processing confirmation.
    case deliveryConfirmation
    case other
}

/// Structured description of what the sender is asking the recipient to do or
/// reply with.
/// Populated when `TriageVerdict.isActionable == true`. The `decisionInputs`
/// array seeds the Almanac question generator: each string is a question
/// the user must answer for a draft to be composed.
public struct ActionSpec: Codable, Sendable, Equatable {
    public let summary: String
    public let kind: ActionKind
    public let directedAt: Assignee
    public let deadline: DeadlineCandidate?
    public let decisionInputs: [String]
    public let evidenceSpans: [EvidenceSpan]

    public init(
        summary: String,
        kind: ActionKind,
        directedAt: Assignee,
        deadline: DeadlineCandidate? = nil,
        decisionInputs: [String] = [],
        evidenceSpans: [EvidenceSpan] = []
    ) {
        self.summary = summary
        self.kind = kind
        self.directedAt = directedAt
        self.deadline = deadline
        self.decisionInputs = decisionInputs
        self.evidenceSpans = evidenceSpans
    }

    /// Canonical primitive-input factory used by both the Apple Foundation
    /// `@Generable` adapter and the MLX line-prefix parser. Returns nil
    /// when `summary` is empty after trimming. Unknown enum strings degrade
    /// to `.other` / `.ambiguous`. Decision inputs are trimmed, empty
    /// entries dropped, and the array capped at 5.
    public static func make(
        summary: String,
        kind: String,
        directedAt: String,
        deadlineText: String,
        deadlineKind: String,
        decisionInputs: [String]
    ) -> ActionSpec? {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return nil }
        return ActionSpec(
            summary: trimmedSummary,
            kind: ActionKind(rawValue: kind.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .other,
            directedAt: Assignee(rawValue: directedAt.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .ambiguous,
            deadline: DeadlineCandidate.make(text: deadlineText, kind: deadlineKind),
            decisionInputs: TriageVerdictParsing.trimmedNonEmpty(decisionInputs),
            evidenceSpans: []
        )
    }
}

/// Structured description of information the recipient must absorb without
/// replying. Populated when `TriageVerdict.requiresConfirmation == true`.
/// `materialFacts` is the bullet list Almanac surfaces with a "got it"
/// affordance.
public struct AcknowledgementSpec: Codable, Sendable, Equatable {
    public let summary: String
    public let signalKind: SignalKind
    public let deadline: DeadlineCandidate?
    public let materialFacts: [String]
    public let evidenceSpans: [EvidenceSpan]

    public init(
        summary: String,
        signalKind: SignalKind,
        deadline: DeadlineCandidate? = nil,
        materialFacts: [String] = [],
        evidenceSpans: [EvidenceSpan] = []
    ) {
        self.summary = summary
        self.signalKind = signalKind
        self.deadline = deadline
        self.materialFacts = materialFacts
        self.evidenceSpans = evidenceSpans
    }

    /// Canonical primitive-input factory used by both the Apple Foundation
    /// `@Generable` adapter and the MLX line-prefix parser. Returns nil
    /// when `summary` is empty after trimming. Unknown signal kinds
    /// degrade to `.other`. Material facts are trimmed, empty entries
    /// dropped, and the array capped at 5.
    public static func make(
        summary: String,
        signalKind: String,
        deadlineText: String,
        deadlineKind: String,
        materialFacts: [String]
    ) -> AcknowledgementSpec? {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return nil }
        return AcknowledgementSpec(
            summary: trimmedSummary,
            signalKind: SignalKind(rawValue: signalKind.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .other,
            deadline: DeadlineCandidate.make(text: deadlineText, kind: deadlineKind),
            materialFacts: TriageVerdictParsing.trimmedNonEmpty(materialFacts),
            evidenceSpans: []
        )
    }
}

/// Two-axis triage classification produced by the summarization LLM. The
/// flags are independent — both can be true (e.g. "Please review the
/// contract and confirm receipt"), one can be true, or both can be false
/// (purely informational). Inconsistent states (`isActionable == false`
/// but `action != nil`) are representable but ignored by consumers, which
/// always read the booleans first.
public struct TriageVerdict: Codable, Sendable, Equatable {
    public let isActionable: Bool
    public let requiresConfirmation: Bool
    public let confidence: Double
    public let action: ActionSpec?
    public let acknowledgement: AcknowledgementSpec?
    public let extractionVersion: String

    public init(
        isActionable: Bool,
        requiresConfirmation: Bool,
        confidence: Double,
        action: ActionSpec? = nil,
        acknowledgement: AcknowledgementSpec? = nil,
        extractionVersion: String
    ) {
        self.isActionable = isActionable
        self.requiresConfirmation = requiresConfirmation
        self.confidence = confidence
        self.action = action
        self.acknowledgement = acknowledgement
        self.extractionVersion = extractionVersion
    }

    public var deadlineCandidates: [DeadlineCandidate] {
        [action?.deadline, acknowledgement?.deadline].compactMap { $0 }
    }

    /// Normalizes the verdict for attention/display. First strips reply
    /// obligations from sent mail (the account owner can never owe themselves
    /// a reply), then enforces the binary-obligation invariant. Applied at
    /// every read/write seam that feeds the attention pipeline, so downstream
    /// consumers never observe a verdict that is both actionable and
    /// confirmation-bearing.
    public func normalizingActionability(isSentByUser: Bool) -> TriageVerdict {
        let actionabilityNormalized: TriageVerdict
        if isSentByUser, isActionable || action != nil {
            actionabilityNormalized = TriageVerdict(
                isActionable: false,
                requiresConfirmation: requiresConfirmation,
                confidence: confidence,
                action: nil,
                acknowledgement: acknowledgement,
                extractionVersion: extractionVersion
            )
        } else {
            actionabilityNormalized = self
        }
        return actionabilityNormalized.enforcingBinaryObligation()
    }

    /// Reply and confirmation are mutually exclusive at the obligation level:
    /// a message either needs a reply — a human is waiting on the account
    /// owner's words — or needs confirmation — the owner must absorb its
    /// contents without responding — but never both. The extractor can emit
    /// both axes for a single message (commonly an institutional broadcast
    /// that frames a self-service portal task as an "action" while also
    /// carrying an acknowledgement signal). This collapses such a verdict to
    /// a single axis.
    ///
    /// A genuine interpersonal reply obligation (`reply`,
    /// `provideInformation`, `scheduleMeeting`, `signOff`) wins and the
    /// coincident acknowledgement is dropped — sending the reply demonstrates
    /// awareness, so the confirmation axis is redundant. A self-directed
    /// action (`review`, `makeDecision`, `other`) that arrives alongside a
    /// concrete acknowledgement is recognized as an absorb-task and demotes
    /// to confirmation-only. With no structured action, or no acknowledgement
    /// to land on, the reply axis is kept (conservative — never silently drop
    /// a reply the extractor could not characterize). This is language- and
    /// keyword-agnostic: it keys on the structured `ActionKind`, not on body
    /// phrases, so it fires identically on a Japanese institutional broadcast
    /// and an English one.
    public func enforcingBinaryObligation() -> TriageVerdict {
        guard isActionable, requiresConfirmation else { return self }
        if !actionIsGenuineReplyObligation, acknowledgement != nil {
            return TriageVerdict(
                isActionable: false,
                requiresConfirmation: true,
                confidence: confidence,
                action: nil,
                acknowledgement: acknowledgement,
                extractionVersion: extractionVersion
            )
        }
        return TriageVerdict(
            isActionable: true,
            requiresConfirmation: false,
            confidence: confidence,
            action: action,
            acknowledgement: nil,
            extractionVersion: extractionVersion
        )
    }

    /// Whether the actionable axis represents a human awaiting the owner's
    /// words rather than a self-service task the owner performs alone. Only
    /// the interpersonal kinds qualify; `review` / `makeDecision` / `other`
    /// are self-directed and yield to a co-present confirmation. A missing
    /// structured action defaults to `true` so an uncharacterized reply is
    /// never dropped.
    private var actionIsGenuineReplyObligation: Bool {
        guard let action else { return true }
        switch action.kind {
        case .reply, .provideInformation, .scheduleMeeting, .signOff:
            return true
        case .review, .makeDecision, .other:
            return false
        }
    }

    /// Maps the two-axis triage signal plus purpose and factual list metadata onto the
    /// legacy 6-case `MessageType` enum that existing UI consumers
    /// (Constellation chips, Map panes, hover icons, Frame colors) read.
    /// Resolution order matches the user-attention priority that the
    /// downstream pipeline expects:
    ///
    /// 1. `actionable` — anything the user must reply to wins, regardless
    ///    of classification. This is the single signal that gates draft generation,
    ///    so automated self-service tasks and broadcast CTAs should not reach
    ///    this state.
    /// 2. `confirmation` — booking / calendar / delivery confirmations the
    ///    user holds and must acknowledge but does not reply to.
    /// 3. `subscription` — newsletters / digests.
    /// 4. `receipt` — purchase or payment confirmations.
    /// 5. `report` — everything else (informational, ambient, automated,
    ///    verification codes, security alerts, generic notifications).
    ///
    /// Verification codes intentionally collapse to `.report`: they are
    /// real attention signals at the structured-payload level
    /// (`signalKind == .verificationCode`), but the legacy `MessageType`
    /// enum has no narrower bucket for them. Surfaces that need transient
    /// behaviour read the verdict directly.
    public func derivedMessageType(
        purpose: MailPurpose?,
        isMailingList: Bool
    ) -> MessageType {
        if isActionable {
            return .actionable
        }
        if requiresConfirmation {
            switch acknowledgement?.signalKind {
            case .bookingConfirmation, .calendarChange, .deliveryConfirmation:
                return .confirmation
            default:
                break
            }
            switch purpose {
            case .calendar, .travel:
                return .confirmation
            default:
                break
            }
        }
        if purpose == .newsletter || isMailingList {
            return .subscription
        }
        if purpose == .receipt {
            return .receipt
        }
        return .report
    }

    public func derivedMessageType(
        purpose: MailPurpose?,
        isMailingList: Bool,
        isSentByUser: Bool
    ) -> MessageType {
        normalizingActionability(isSentByUser: isSentByUser)
            .derivedMessageType(purpose: purpose, isMailingList: isMailingList)
    }
}

/// Correspondent profile built incrementally from observed messages.
public struct CorrespondentProfile: Codable, Sendable {
    public var relationshipDistribution: [WeightedLabel]
    public var formalityMean: Double
    public var formalityCount: Int
    public var familiarityScore: Double
    public var topTopics: [WeightedLabel]
    public var topProjects: [WeightedLabel]
    public var languagePreferences: [WeightedLabel]
    public var averageMessageLength: Int
    public var messageCount: Int
    public var commonOpenings: [String]
    public var commonClosings: [String]

    public init() {
        self.relationshipDistribution = []
        self.formalityMean = 0.5
        self.formalityCount = 0
        self.familiarityScore = 0.0
        self.topTopics = []
        self.topProjects = []
        self.languagePreferences = []
        self.averageMessageLength = 0
        self.messageCount = 0
        self.commonOpenings = []
        self.commonClosings = []
    }
}
