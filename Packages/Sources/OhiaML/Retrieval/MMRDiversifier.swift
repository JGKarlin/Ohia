import Accelerate
import Foundation

/// Greedy Maximal Marginal Relevance selection for retrieval context diversity.
public enum MMRDiversifier {

    public static func select(
        from items: [(id: Int64, vector: [Float], relevance: Float)],
        k: Int,
        lambda: Float = 0.5
    ) -> [(id: Int64, vector: [Float], relevance: Float)] {
        guard !items.isEmpty, k > 0 else { return [] }

        let target = min(k, items.count)
        let lambda = min(1, max(0, lambda))
        var remaining = items
        var selected: [(id: Int64, vector: [Float], relevance: Float)] = []

        for _ in 0..<target {
            let bestIndex = remaining.indices.max { lhs, rhs in
                mmrScore(remaining[lhs], selected: selected, lambda: lambda) <
                    mmrScore(remaining[rhs], selected: selected, lambda: lambda)
            }
            guard let bestIndex else { break }
            selected.append(remaining.remove(at: bestIndex))
        }

        return selected
    }

    private static func mmrScore(
        _ candidate: (id: Int64, vector: [Float], relevance: Float),
        selected: [(id: Int64, vector: [Float], relevance: Float)],
        lambda: Float
    ) -> Float {
        let maxSimilarity = selected
            .map { cosine(candidate.vector, $0.vector) }
            .max() ?? 0
        return lambda * candidate.relevance - (1 - lambda) * maxSimilarity
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = vDSP.dot(a, b)
        let normA = vDSP.sumOfSquares(a).squareRoot()
        let normB = vDSP.sumOfSquares(b).squareRoot()
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA * normB)
    }
}
