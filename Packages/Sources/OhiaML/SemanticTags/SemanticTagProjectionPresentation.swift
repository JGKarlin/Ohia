import Foundation

public enum SemanticTagProjectionPresentation {
    public static func canonical(
        _ projections: [SemanticTagProjection]
    ) -> [SemanticTagProjection] {
        var strongestByID: [UUID: SemanticTagProjection] = [:]
        for projection in projections {
            if let existing = strongestByID[projection.tagID],
               existing.weightedScore >= projection.weightedScore {
                continue
            }
            strongestByID[projection.tagID] = projection
        }
        return strongestByID.values.sorted(by: projectionOrder)
    }

    public static func topDisplayLabels(
        in dimensions: MessageDimensions,
        limit: Int = 2
    ) -> [String] {
        canonical(dimensions.semanticTags)
            .prefix(max(0, limit))
            .map(\.displayName)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func dominantDisplayLabel(
        in dimensions: MessageDimensions?
    ) -> String? {
        guard let dimensions,
              let top = canonical(dimensions.semanticTags).first,
              top.weightedScore >= 0.10 else {
            return nil
        }
        let display = top.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return display.isEmpty ? nil : display
    }

    private static func projectionOrder(
        _ lhs: SemanticTagProjection,
        _ rhs: SemanticTagProjection
    ) -> Bool {
        if lhs.weightedScore != rhs.weightedScore {
            return lhs.weightedScore > rhs.weightedScore
        }
        return lhs.tagID.uuidString < rhs.tagID.uuidString
    }
}
