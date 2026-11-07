import Foundation

/// Reciprocal Rank Fusion over ranked vector-id lists.
public enum RRFFusion {

    public struct Item: Sendable, Equatable {
        public let id: Int64
        public let score: Double

        public init(id: Int64, score: Double) {
            self.id = id
            self.score = score
        }
    }

    public static func fuse(rankings: [[Int64]], k: Int = 60) -> [Item] {
        var scores: [Int64: Double] = [:]
        for ranking in rankings {
            for (index, id) in ranking.enumerated() {
                let rank = index + 1
                scores[id, default: 0] += 1.0 / Double(k + rank)
            }
        }

        return scores
            .map { Item(id: $0.key, score: $0.value) }
            .sorted {
                if $0.score == $1.score {
                    return $0.id < $1.id
                }
                return $0.score > $1.score
            }
    }
}
