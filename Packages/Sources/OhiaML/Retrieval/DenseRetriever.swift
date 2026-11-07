import Foundation
import OhiaCore

public final class DenseRetriever: @unchecked Sendable {

    private let vectorStore: VectorStore
    private let registry: EmbedderRegistry
    private let reconcileLock = NSLock()
    private let minimumReconcileInterval: TimeInterval
    private var lastReconcileAttemptAt: Date = .distantPast

    public init(
        vectorStore: VectorStore,
        registry: EmbedderRegistry,
        minimumReconcileInterval: TimeInterval = 2
    ) {
        self.vectorStore = vectorStore
        self.registry = registry
        self.minimumReconcileInterval = minimumReconcileInterval
    }

    /// Run dense ANN against the current embedder version, then post-filter by
    /// FilterSpec via SQL. Empty collection filters default to context vectors.
    public func retrieve(queryVector: [Float], filter: FilterSpec, k: Int) throws -> [Int64] {
        try retrieveScored(queryVector: queryVector, filter: filter, k: k).map(\.id)
    }

    /// Same as `retrieve`, but keeps each result's similarity score. Used by
    /// the literal search path to report the strength of the nearest semantic
    /// neighbors when an exact match is weak or absent.
    public func retrieveScored(
        queryVector: [Float],
        filter: FilterSpec,
        k: Int
    ) throws -> [(id: Int64, score: Float)] {
        guard k > 0 else { return [] }

        let collections = filter.collections.isEmpty ? [.context] : filter.collections
        let embeddingVersion = registry.current.embeddingVersion
        try reconcileVectorIndexIfNeeded(
            collections: collections,
            embeddingVersion: embeddingVersion
        )

        var scored: [(id: Int64, score: Float)] = []
        for collection in collections {
            let raw = try vectorStore.search(
                query: queryVector,
                collection: collection,
                topK: max(k * 4, k),
                embeddingVersion: embeddingVersion
            )
            scored.append(contentsOf: raw.map { ($0.record.vectorId, $0.score) })
        }

        scored.sort {
            if $0.score == $1.score {
                return $0.id < $1.id
            }
            return $0.score > $1.score
        }
        let candidateIds = scored.map(\.id)
        let allowed = try vectorStore.filterVectorIds(candidateIds, filter: filter)
        let scoreById = Dictionary(scored.map { ($0.id, $0.score) }, uniquingKeysWith: { first, _ in first })

        var seen = Set<Int64>()
        var out: [(id: Int64, score: Float)] = []
        for id in candidateIds where allowed.contains(id) && seen.insert(id).inserted {
            out.append((id, scoreById[id] ?? 0))
            if out.count == k { break }
        }
        return out
    }

    private func reconcileVectorIndexIfNeeded(
        collections: [VectorCollection],
        embeddingVersion: String
    ) throws {
        var needsReconcile = false
        for collection in collections {
            guard let indexCount = vectorStore.indexCount(
                collection: collection,
                embeddingVersion: embeddingVersion
            ) else {
                return
            }
            let sqliteCount = try vectorStore.count(
                collection: collection,
                embeddingVersion: embeddingVersion
            )
            if indexCount != sqliteCount {
                needsReconcile = true
                break
            }
        }
        guard needsReconcile else { return }

        let now = Date()
        reconcileLock.lock()
        let shouldAttempt = now.timeIntervalSince(lastReconcileAttemptAt) >= minimumReconcileInterval
        if shouldAttempt {
            lastReconcileAttemptAt = now
        }
        reconcileLock.unlock()

        guard shouldAttempt else { return }
        _ = try vectorStore.reconcileIndexIfAvailable()
    }
}
