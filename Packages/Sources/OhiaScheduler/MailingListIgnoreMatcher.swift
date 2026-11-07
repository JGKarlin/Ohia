import Foundation
import OhiaCore

public enum MailingListIgnoreDeliveryPriority: String, Codable, Sendable {
    case direct
    case copied
    case list
    case unknown
}

/// Source-derived values used by both rule evidence and future candidates.
/// Keeping this value Sendable prevents SwiftData models and ModelContext from
/// crossing the matcher boundary.
public struct MailingListIgnoreFeatureSnapshot: Codable, Sendable, Equatable {
    public let subjectFingerprint: String
    public let subjectAnchors: [String]
    public let bodyAnchors: [String]
    public let primaryTagIDs: [String]
    public let supportingTagIDs: [String]
    public let purpose: MailPurpose?
    public let deliveryPriority: MailingListIgnoreDeliveryPriority
    public let isActionable: Bool
    public let requiresConfirmation: Bool

    public init(
        subjectFingerprint: String,
        subjectAnchors: [String],
        bodyAnchors: [String],
        primaryTagIDs: [String],
        supportingTagIDs: [String],
        purpose: MailPurpose?,
        deliveryPriority: MailingListIgnoreDeliveryPriority,
        isActionable: Bool,
        requiresConfirmation: Bool
    ) {
        self.subjectFingerprint = subjectFingerprint
        self.subjectAnchors = subjectAnchors
        self.bodyAnchors = bodyAnchors
        self.primaryTagIDs = primaryTagIDs
        self.supportingTagIDs = supportingTagIDs
        self.purpose = purpose
        self.deliveryPriority = deliveryPriority
        self.isActionable = isActionable
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct MailingListIgnorePreviewCandidate: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let subject: String
    public let messageDate: Date?
    public let score: Double
    public let reasonSummary: String
    public let isSuggestedMatch: Bool
    public let features: MailingListIgnoreFeatureSnapshot

    public init(
        id: UUID,
        subject: String,
        messageDate: Date?,
        score: Double,
        reasonSummary: String,
        isSuggestedMatch: Bool,
        features: MailingListIgnoreFeatureSnapshot
    ) {
        self.id = id
        self.subject = subject
        self.messageDate = messageDate
        self.score = score
        self.reasonSummary = reasonSummary
        self.isSuggestedMatch = isSuggestedMatch
        self.features = features
    }
}

struct MailingListIgnoreEvaluation: Sendable, Equatable {
    let matched: Bool
    let score: Double
    let subjectScore: Double
    let matchedSignals: Set<String>
    let blockedReason: String?
}

enum MailingListIgnoreMatcher {
    static let version = "precision-v4-purpose-list-facts"

    static let neverIgnoredPurposes: Set<MailPurpose> = [
        .security,
        .verificationCode,
    ]

    private static let alignmentProtectedPurposes: Set<MailPurpose> = [
        .finance,
        .legal,
    ]

    static func evaluate(
        candidate: MailingListIgnoreFeatureSnapshot,
        positives: [MailingListIgnoreFeatureSnapshot],
        negatives: [MailingListIgnoreFeatureSnapshot],
        aggressiveness: Double
    ) -> MailingListIgnoreEvaluation {
        guard !positives.isEmpty else {
            return MailingListIgnoreEvaluation(
                matched: false,
                score: 0,
                subjectScore: 0,
                matchedSignals: [],
                blockedReason: "missing positive evidence"
            )
        }

        if let safetyReason = safetyBlock(candidate: candidate, positives: positives) {
            return MailingListIgnoreEvaluation(
                matched: false,
                score: 0,
                subjectScore: 0,
                matchedSignals: [],
                blockedReason: safetyReason
            )
        }

        let positive = positives
            .map { pairEvaluation(candidate: candidate, evidence: $0, aggressiveness: aggressiveness) }
            .max { lhs, rhs in lhs.score < rhs.score }
            ?? PairEvaluation(matched: false, score: 0, subjectScore: 0, signals: [])

        let strongestNegative = negatives
            .map { pairEvaluation(candidate: candidate, evidence: $0, aggressiveness: aggressiveness) }
            .max { lhs, rhs in lhs.score < rhs.score }

        if let strongestNegative,
           strongestNegative.matched,
           strongestNegative.score >= positive.score - 0.08 {
            return MailingListIgnoreEvaluation(
                matched: false,
                score: positive.score,
                subjectScore: positive.subjectScore,
                matchedSignals: positive.signals.union(["negativeExample"]),
                blockedReason: "closer to an excluded example"
            )
        }

        return MailingListIgnoreEvaluation(
            matched: positive.matched,
            score: positive.score,
            subjectScore: positive.subjectScore,
            matchedSignals: positive.signals,
            blockedReason: nil
        )
    }

    static func reasonSummary(for signals: Set<String>, blockedReason: String?) -> String {
        if let blockedReason { return blockedReason }
        let ordered: [(String, String)] = [
            ("subjectFamily", "subject family"),
            ("subjectAnchor", "distinctive subject phrase"),
            ("primaryTag", "primary tag"),
            ("bodyEvidence", "body evidence"),
            ("supportingTag", "supporting tag"),
        ]
        let labels = ordered.compactMap { signals.contains($0.0) ? $0.1 : nil }
        return labels.isEmpty ? "no specific agreement" : labels.joined(separator: " · ")
    }

    private struct PairEvaluation {
        let matched: Bool
        let score: Double
        let subjectScore: Double
        let signals: Set<String>
    }

    private static func pairEvaluation(
        candidate: MailingListIgnoreFeatureSnapshot,
        evidence: MailingListIgnoreFeatureSnapshot,
        aggressiveness: Double
    ) -> PairEvaluation {
        let subjectScore = MailingListIgnoreRuleService.similarity(
            evidence.subjectFingerprint,
            candidate.subjectFingerprint
        )
        let subjectAnchor = MailingListIgnoreRuleService.anchorsOverlap(
            evidence.subjectAnchors,
            candidate.subjectAnchors
        )
        let primaryTag = !Set(evidence.primaryTagIDs)
            .isDisjoint(with: Set(candidate.primaryTagIDs))
        let supportingTag = !Set(evidence.supportingTagIDs)
            .isDisjoint(with: Set(candidate.supportingTagIDs))
        let bodyEvidence = MailingListIgnoreRuleService.anchorsOverlap(
            evidence.bodyAnchors,
            candidate.bodyAnchors
        )

        var signals = Set<String>()
        if subjectAnchor { signals.insert("subjectAnchor") }
        if primaryTag { signals.insert("primaryTag") }
        if supportingTag { signals.insert("supportingTag") }
        if bodyEvidence { signals.insert("bodyEvidence") }

        let effectiveSubjectScore = max(subjectScore, subjectAnchor ? 0.74 : 0)
        let clampedAggressiveness = min(max(aggressiveness, 0), 1)
        let strongSubjectThreshold = 0.88 - (0.12 * clampedAggressiveness)
        let supportedSubjectThreshold = 0.66 - (0.08 * clampedAggressiveness)
        let vagueSubject = MailingListIgnoreRuleService.isVagueSubject(
            evidence.subjectFingerprint,
            anchors: evidence.subjectAnchors
        )

        let strongSubject = !vagueSubject && subjectScore >= strongSubjectThreshold
        if strongSubject { signals.insert("subjectFamily") }

        // Precision is intentionally asymmetric: broad semantic or body
        // agreement can support a recognizable subject family, but it can never
        // manufacture one. This prevents list-wide wrapper text such as
        // "announcement" plus a secondary "registration" tag from trashing
        // a different event.
        let matched = strongSubject
            || (vagueSubject && primaryTag && bodyEvidence)
            || (effectiveSubjectScore >= supportedSubjectThreshold && primaryTag)
            || (effectiveSubjectScore >= supportedSubjectThreshold + 0.06 && bodyEvidence)

        let score = min(
            1,
            (subjectScore * 0.75)
                + (subjectAnchor ? 0.08 : 0)
                + (primaryTag ? 0.12 : 0)
                + (bodyEvidence ? 0.04 : 0)
                + (supportingTag ? 0.01 : 0)
        )
        return PairEvaluation(
            matched: matched,
            score: score,
            subjectScore: subjectScore,
            signals: signals
        )
    }

    private static func safetyBlock(
        candidate: MailingListIgnoreFeatureSnapshot,
        positives: [MailingListIgnoreFeatureSnapshot]
    ) -> String? {
        guard let candidatePurpose = candidate.purpose else {
            return "unresolved purpose"
        }
        let allowedDeliveries = Set(positives.map(\.deliveryPriority))
        switch candidate.deliveryPriority {
        case .direct where !allowedDeliveries.contains(.direct):
            return "delivered directly to you"
        case .copied where allowedDeliveries.isDisjoint(with: [.direct, .copied]):
            return "copied directly to you"
        default:
            break
        }

        if candidate.isActionable, !positives.contains(where: \.isActionable) {
            return "introduces a new reply or action"
        }
        if candidate.requiresConfirmation, !positives.contains(where: \.requiresConfirmation) {
            return "introduces a new confirmation"
        }

        if neverIgnoredPurposes.contains(candidatePurpose) {
            return "introduces protected content"
        }
        if alignmentProtectedPurposes.contains(candidatePurpose),
           positives.contains(where: { $0.purpose == candidatePurpose }) == false {
            return "introduces protected content"
        }
        return nil
    }
}
