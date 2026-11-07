import OhiaCore

/// Tuning for the kNN-graph expansion pass.
public struct VectorNeighborExpansionConfig: Sendable, Equatable {
    /// Maximum additional results appended after the primary set.
    public var maxExpansionSlots: Int
    /// Neighbor message IDs pulled per primary anchor.
    public var neighborsPerAnchor: Int
    /// Cosine floor below which a `vector_neighbors` edge is too weak to trust.
    public var similarityThreshold: Float

    public init(
        maxExpansionSlots: Int = 4,
        neighborsPerAnchor: Int = 3,
        similarityThreshold: Float = 0.62
    ) {
        self.maxExpansionSlots = maxExpansionSlots
        self.neighborsPerAnchor = neighborsPerAnchor
        self.similarityThreshold = similarityThreshold
    }

    public static let `default` = VectorNeighborExpansionConfig()
}

/// Bounded relation expansion over the persisted cosine kNN graph
/// (`vector_neighbors`). Given the primary retrieval anchors, it walks one hop
/// out to the messages most similar to each anchor — surfacing a "second fact"
/// stated in a neighboring message that the query itself was not similar enough
/// to rank (the join-query gap). Pure SQLite: it needs only the `VectorStore`
/// and `VectorNeighborsStore`, never a SwiftData `ModelContext`, so it lives in
/// the retrieval layer and benefits every `HybridRetriever` consumer.
public enum VectorNeighborExpander {
    /// Novel `VectorRecord`s reachable from `anchorMessageIds` via the kNN graph,
    /// scoped to the message-body (`.context`) lane within `filter`, excluding the
    /// anchors themselves and any `seenVectorIds`. Returns an over-fetched pool;
    /// the caller reranks and caps it to `maxExpansionSlots`.
    public static func candidates(
        anchorMessageIds: [String],
        seenVectorIds: Set<Int64>,
        filter: FilterSpec,
        config: VectorNeighborExpansionConfig,
        vectorStore: VectorStore,
        neighborsStore: VectorNeighborsStore
    ) throws -> [VectorRecord] {
        guard !anchorMessageIds.isEmpty, config.maxExpansionSlots > 0 else { return [] }
        // Expansion targets the body-context lane where split facts live. If the
        // caller scoped to a collection set that excludes context (e.g. an
        // attachment-only query), there is nothing to expand.
        let collections = filter.collections
        guard collections.isEmpty || collections.contains(.context) else { return [] }

        let anchorSet = Set(anchorMessageIds)
        var seenMessage = anchorSet
        var orderedNeighborIds: [String] = []
        for anchor in anchorMessageIds {
            let affinities = try neighborsStore.messageAffinities(
                forMessageId: anchor,
                limit: config.neighborsPerAnchor,
                similarityThreshold: config.similarityThreshold
            )
            for (messageId, _) in affinities.sorted(by: { $0.value > $1.value })
            where seenMessage.insert(messageId).inserted {
                orderedNeighborIds.append(messageId)
            }
        }
        guard !orderedNeighborIds.isEmpty else { return [] }

        var scopeFilter = filter
        scopeFilter.collections = [.context]
        // Over-fetch a small pool so the reranker has room to pick the best
        // novel neighbors before the caller caps to `maxExpansionSlots`.
        let pool = config.maxExpansionSlots * 5
        let mappedIds = try vectorStore.vectorIds(
            forMessageIds: orderedNeighborIds,
            filter: scopeFilter,
            limit: pool
        )
        let novel = mappedIds.filter { !seenVectorIds.contains($0) }
        guard !novel.isEmpty else { return [] }
        return try vectorStore.hydrate(vectorIds: novel)
    }
}
