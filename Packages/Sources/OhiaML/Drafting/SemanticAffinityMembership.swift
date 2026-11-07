import Foundation
import OhiaCore

/// Internal quality tier used by Composer and non-Projects message-status
/// enrichment when consuming model-generated semantic labels.
enum SemanticAffinityStrength: String, Codable, Sendable, Hashable, Comparable {
    case primary
    case secondary
    case mention

    static func < (lhs: SemanticAffinityStrength, rhs: SemanticAffinityStrength) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .mention: return 0
        case .secondary: return 1
        case .primary: return 2
        }
    }
}

struct SemanticAffinityMembership: Codable, Sendable, Hashable {
    let semanticKey: String
    let displayLabel: String
    let score: Double
    let confidence: Double
    let strength: SemanticAffinityStrength
    let sourceCentrality: SemanticTagCentrality

    init(
        semanticKey: String,
        displayLabel: String,
        score: Double,
        confidence: Double,
        strength: SemanticAffinityStrength,
        sourceCentrality: SemanticTagCentrality
    ) {
        self.semanticKey = semanticKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.displayLabel = ProjectKeyNormalizer.displayLabel(displayLabel)
        self.score = min(1, max(0, score))
        self.confidence = min(1, max(0, confidence))
        self.strength = strength
        self.sourceCentrality = sourceCentrality
    }

    func resolvingSemanticKey(
        _ semanticKey: String,
        displayLabel: String? = nil
    ) -> SemanticAffinityMembership {
        SemanticAffinityMembership(
            semanticKey: semanticKey,
            displayLabel: displayLabel ?? self.displayLabel,
            score: score,
            confidence: confidence,
            strength: strength,
            sourceCentrality: sourceCentrality
        )
    }
}

/// The unchanged semantic-label quality policy used by Composer source
/// relevance. It describes semantic affinity only; it cannot construct or
/// mutate a manual project.
enum SemanticAffinityMembershipResolver {
    static func memberships(for message: ProjectMessageInput) -> [SemanticAffinityMembership] {
        memberships(forSemanticTags: message.semanticTags)
    }

    static func memberships(
        forSemanticTags semanticTags: [SemanticTagProjection]
    ) -> [SemanticAffinityMembership] {
        let tags = SemanticTagProjectionPresentation.canonical(semanticTags)
            .sorted { lhs, rhs in
                if lhs.centrality != rhs.centrality {
                    return strength(for: lhs.centrality) > strength(for: rhs.centrality)
                }
                if lhs.weightedScore != rhs.weightedScore {
                    return lhs.weightedScore > rhs.weightedScore
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }

        let strong = tags.filter { tag in
            tag.centrality != .mention
                && tag.confidence >= 0.35
                && tag.weightedScore >= 0.20
        }
        let selected: [SemanticTagProjection]
        if strong.isEmpty {
            selected = tags
                .filter { $0.centrality == .mention && $0.confidence >= 0.65 && $0.score >= 0.50 }
                .prefix(1)
                .map { $0 }
        } else {
            selected = strong.prefix(3).map { $0 }
        }

        return selected.map { tag in
            return SemanticAffinityMembership(
                semanticKey: tag.tagID.uuidString,
                displayLabel: tag.displayName,
                score: tag.score,
                confidence: tag.confidence,
                strength: strength(for: tag.centrality),
                sourceCentrality: tag.centrality
            )
        }
    }

    private static func strength(for centrality: SemanticTagCentrality) -> SemanticAffinityStrength {
        switch centrality {
        case .primary: return .primary
        case .secondary: return .secondary
        case .mention: return .mention
        }
    }
}
