import Foundation
import OhiaCore
import OhiaML

enum MeaningSemanticEdgeReasoner {
    private struct Candidate {
        let kind: SemanticEdgeReasonKind
        let key: String
        let label: String
        let score: Float
        let isSecondary: Bool
        let priority: Int
    }

    nonisolated static func reason(
        between lhs: MessageFilterRow,
        and rhs: MessageFilterRow
    ) -> SemanticEdgeReason? {
        if let arc = bestSharedReason(
            lhs: arcCandidates(for: lhs.dimensions),
            rhs: arcCandidates(for: rhs.dimensions)
        ) {
            return arc
        }
        return bestSharedReason(
            lhs: classificationCandidates(for: lhs),
            rhs: classificationCandidates(for: rhs)
        )
    }

    nonisolated static func strokeWidth(for strength: Float) -> Float {
        let t = smoothstep(edge0: 0.55, edge1: 1.0, x: strength)
        return max(1.0, min(3.25, 1.0 + 2.25 * t))
    }

    nonisolated private static func bestSharedReason(
        lhs: [Candidate],
        rhs: [Candidate]
    ) -> SemanticEdgeReason? {
        guard lhs.isEmpty == false, rhs.isEmpty == false else { return nil }
        let rhsByIdentity = Dictionary(grouping: rhs) { "\($0.kind.rawValue):\($0.key)" }
        let matches = lhs.compactMap { left -> Candidate? in
            guard let right = rhsByIdentity["\(left.kind.rawValue):\(left.key)"]?
                .max(by: { $0.score < $1.score }) else {
                return nil
            }
            return Candidate(
                kind: left.kind,
                key: left.key,
                label: left.label,
                score: min(left.score, right.score),
                isSecondary: left.isSecondary || right.isSecondary,
                priority: min(left.priority, right.priority)
            )
        }
        guard let best = matches.max(by: rankedBefore) else { return nil }
        return SemanticEdgeReason(
            kind: best.kind,
            label: best.label,
            score: best.score,
            isSecondary: best.isSecondary
        )
    }

    nonisolated private static func rankedBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.label > rhs.label
    }

    nonisolated private static func arcCandidates(for dimensions: MessageDimensions?) -> [Candidate] {
        guard let dimensions else { return [] }
        return SemanticTagProjectionPresentation.canonical(dimensions.semanticTags)
            .filter { $0.score >= 0.1 }
            .sorted { $0.weightedScore > $1.weightedScore }
            .prefix(4)
            .compactMap { tag in
                let display = tag.displayName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard display.isEmpty == false else { return nil }
                return Candidate(
                    kind: .tag,
                    key: tag.tagID.uuidString.lowercased(),
                    label: display,
                    score: max(0.2, min(1.0, Float(tag.weightedScore))),
                    isSecondary: tag.centrality != .primary,
                    priority: 0
                )
            }
    }

    nonisolated private static func classificationCandidates(for row: MessageFilterRow) -> [Candidate] {
        draftingMemoryFacets(
            classification: row.mailClassification,
            customCategoryKeys: []
        ).semanticAffinityKeys.compactMap { key in
            let components = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard components.count == 2 else { return nil }
            if components[0] == "purpose",
               let purpose = MailPurpose(rawValue: components[1]) {
                return Candidate(
                    kind: .purpose,
                    key: purpose.rawValue,
                    label: purpose.rawValue,
                    score: 0.40,
                    isSecondary: false,
                    priority: 3
                )
            }
            return nil
        }
    }

    nonisolated private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    nonisolated private static func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        guard edge0 != edge1 else { return x >= edge1 ? 1 : 0 }
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}
