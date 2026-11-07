import OhiaCore

// MARK: - RetrievalCandidate

/// Intermediate candidate produced by dense and sparse retrieval channels.
public struct RetrievalCandidate: Sendable, Equatable {
    public let vectorId: Int64
    public let denseRank: Int?
    public let sparseRank: Int?
    public let denseScore: Float?
    public let sparseScore: Float?

    public init(
        vectorId: Int64,
        denseRank: Int? = nil,
        sparseRank: Int? = nil,
        denseScore: Float? = nil,
        sparseScore: Float? = nil
    ) {
        self.vectorId = vectorId
        self.denseRank = denseRank
        self.sparseRank = sparseRank
        self.denseScore = denseScore
        self.sparseScore = sparseScore
    }
}

// MARK: - RetrievalResult

public struct RetrievalResult: Sendable, Equatable {
    public let record: VectorRecord
    public let score: Float
    public let attribution: Attribution

    public init(record: VectorRecord, score: Float, attribution: Attribution) {
        self.record = record
        self.score = score
        self.attribution = attribution
    }

    public static func == (lhs: RetrievalResult, rhs: RetrievalResult) -> Bool {
        lhs.record.vectorId == rhs.record.vectorId &&
            lhs.score == rhs.score &&
            lhs.attribution == rhs.attribution
    }

    public enum Attribution: Sendable, Equatable {
        case dense
        case sparse
        case both
        /// Surfaced by the kNN-graph expansion pass (a message semantically
        /// adjacent to a primary anchor that ANN/BM25 missed), not the primary
        /// dense+sparse query. Always scored at or below the primary hits and
        /// appended after them. Lets callers label expansion sources distinctly.
        case expanded
    }
}

public enum RetrievalError: Error, Sendable, Equatable {
    case embeddingUnavailable
    case denseFailure(String)
    case sparseFailure(String)
    case rerankerFailure(String)
}
