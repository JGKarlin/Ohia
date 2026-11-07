import Foundation
import OhiaCore

public struct AskRetrievalResult: Sendable, Equatable {
    public let route: AskScopeRoute
    public let sources: [RetrievalResult]

    public init(route: AskScopeRoute, sources: [RetrievalResult]) {
        self.route = route
        self.sources = sources
    }

    public var uiSummary: String {
        route.uiSummary(actualSourceCount: sources.count)
    }
}

public final class HybridRetriever: @unchecked Sendable {

    private let dense: DenseRetriever
    private let sparse: SparseRetriever
    private var reranker: (any RetrievalReranking)?
    private let rerankerLock = NSLock()
    private var activeRerankCount = 0
    private var rerankerDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private let registry: EmbedderRegistry
    private let vectorStore: VectorStore
    private let performanceProfile: RetrievalPerformanceProfile
    /// The persisted cosine kNN graph, injected by `AppServices`. When nil the
    /// relation-expansion pass is disabled and behaviour is identical to the
    /// pre-expansion pipeline.
    private let neighborsStore: VectorNeighborsStore?

    public init(
        vectorStore: VectorStore,
        ftsIndex: MessageFTSIndex,
        registry: EmbedderRegistry,
        reranker: (any RetrievalReranking)?,
        neighborsStore: VectorNeighborsStore? = nil,
        performanceProfile: RetrievalPerformanceProfile = .current()
    ) {
        self.dense = DenseRetriever(vectorStore: vectorStore, registry: registry)
        self.sparse = SparseRetriever(ftsIndex: ftsIndex, vectorStore: vectorStore)
        self.reranker = reranker
        self.registry = registry
        self.vectorStore = vectorStore
        self.neighborsStore = neighborsStore
        self.performanceProfile = performanceProfile
    }

    public func setReranker(_ reranker: (any RetrievalReranking)?) {
        rerankerLock.lock()
        self.reranker = reranker
        rerankerLock.unlock()
    }

    public var isRerankerAvailable: Bool {
        rerankerLock.lock()
        defer { rerankerLock.unlock() }
        return reranker != nil
    }

    /// Prevents new retrievals from capturing the current reranker and waits
    /// for every already-started score call to finish. The worker uses this as
    /// a model-residency handoff barrier before another helper loads Qwen.
    public func removeRerankerAndDrain() async {
        await withCheckedContinuation { continuation in
            rerankerLock.lock()
            reranker = nil
            if activeRerankCount == 0 {
                rerankerLock.unlock()
                continuation.resume()
            } else {
                rerankerDrainWaiters.append(continuation)
                rerankerLock.unlock()
            }
        }
    }

    /// Single entry point. Three stages: candidate generation, rerank, then
    /// MMR diversity with final filter re-validation.
    public func retrieve(
        query: String,
        filter: FilterSpec,
        k: Int = 6,
        expansionConfig: VectorNeighborExpansionConfig? = nil
    ) throws -> [RetrievalResult] {
        guard k > 0 else { return [] }
        try Task.checkCancellation()
        let stage1Cap = performanceProfile.stage1CandidateLimit(requestedResultCount: k)

        let denseIds: [Int64]
        if let queryVector = registry.current.embed(query) {
            try Task.checkCancellation()
            denseIds = (try? dense.retrieve(queryVector: queryVector, filter: filter, k: stage1Cap)) ?? []
        } else {
            denseIds = []
        }
        try Task.checkCancellation()
        let sparseIds = (try? sparse.retrieve(queryText: query, filter: filter, k: stage1Cap)) ?? []
        try Task.checkCancellation()
        let fused = RRFFusion.fuse(rankings: [denseIds, sparseIds])
        let topCandidateIds = fused.prefix(stage1Cap).map(\.id)
        guard !topCandidateIds.isEmpty else { return [] }

        let rerankCandidateLimit = performanceProfile.rerankCandidateLimit(
            requestedResultCount: k,
            availableCandidateCount: topCandidateIds.count
        )
        let rerankCandidateIds = Array(topCandidateIds.prefix(rerankCandidateLimit))
        let candidates = try vectorStore.hydrate(vectorIds: rerankCandidateIds)
        try Task.checkCancellation()
        let orderedCandidatesById = Dictionary(uniqueKeysWithValues: candidates.map { ($0.vectorId, $0) })
        let orderedCandidates = rerankCandidateIds.compactMap { orderedCandidatesById[$0] }

        let reranked = try rerank(query: query, candidates: orderedCandidates, fused: fused)
        try Task.checkCancellation()
        let diversificationLimit = performanceProfile.diversificationCandidateLimit(
            requestedResultCount: k,
            availableCandidateCount: reranked.count
        )
        let topReranked = Array(reranked.prefix(diversificationLimit))
        guard !topReranked.isEmpty else { return [] }

        let maxRelevance = topReranked.first?.relevance ?? 0
        let relevanceFloor = maxRelevance * 0.5
        let mmrSource = topReranked.filter { $0.relevance >= relevanceFloor }
        let mmrInput = (mmrSource.isEmpty ? topReranked : mmrSource).map {
            (id: $0.record.vectorId, vector: $0.record.vector, relevance: $0.relevance)
        }
        let diversified = MMRDiversifier.select(from: mmrInput, k: k, lambda: 0.5)
        try Task.checkCancellation()
        let revalidated = try vectorStore.filterVectorIds(diversified.map(\.id), filter: filter)
        try Task.checkCancellation()

        let recordById = Dictionary(uniqueKeysWithValues: topReranked.map { ($0.record.vectorId, $0) })
        let denseSet = Set(denseIds)
        let sparseSet = Set(sparseIds)
        let primaryResults = diversified.compactMap { selected -> RetrievalResult? in
            guard revalidated.contains(selected.id),
                  let pair = recordById[selected.id]
            else {
                return nil
            }
            return RetrievalResult(
                record: pair.record,
                score: pair.relevance,
                attribution: attribution(for: selected.id, denseSet: denseSet, sparseSet: sparseSet)
            )
        }

        // kNN-graph expansion: append messages semantically adjacent to the
        // primary anchors that the query did not rank directly (the join-query
        // gap). Only when the caller opts in AND a neighbor graph was injected.
        guard let expansionConfig, let neighborsStore else { return primaryResults }
        return primaryResults + (try expandedResults(
            query: query,
            filter: filter,
            primaryResults: primaryResults,
            config: expansionConfig,
            neighborsStore: neighborsStore
        ))
    }

    /// Recall-oriented variant for evidence gathering (translation glossary
    /// producers). Same dense+sparse candidate generation and RRF fusion as
    /// `retrieve`, but WITHOUT the relevance floor, reranker, or MMR pruning.
    /// Those stages optimize a short diverse answer set; evidence gathering
    /// needs the opposite — with RRF, one both-channel hit (e.g. a
    /// source-language chunk containing the queried name verbatim) scores
    /// roughly twice any dense-only hit, so the floor would silently discard
    /// exactly the cross-language chunks the caller wants to language-filter
    /// afterwards.
    public func retrieveCandidates(
        query: String,
        filter: FilterSpec,
        k: Int
    ) throws -> [RetrievalResult] {
        guard k > 0 else { return [] }
        try Task.checkCancellation()
        let stage1Cap = performanceProfile.stage1CandidateLimit(requestedResultCount: k)

        let denseIds: [Int64]
        if let queryVector = registry.current.embed(query) {
            try Task.checkCancellation()
            denseIds = (try? dense.retrieve(queryVector: queryVector, filter: filter, k: stage1Cap)) ?? []
        } else {
            denseIds = []
        }
        try Task.checkCancellation()
        let sparseIds = (try? sparse.retrieve(queryText: query, filter: filter, k: stage1Cap)) ?? []
        try Task.checkCancellation()
        let fused = RRFFusion.fuse(rankings: [denseIds, sparseIds])
        let topIds = fused.prefix(k).map(\.id)
        guard !topIds.isEmpty else { return [] }

        let revalidated = try vectorStore.filterVectorIds(Array(topIds), filter: filter)
        try Task.checkCancellation()
        let candidates = try vectorStore.hydrate(vectorIds: Array(topIds))
        try Task.checkCancellation()
        let recordById = Dictionary(uniqueKeysWithValues: candidates.map { ($0.vectorId, $0) })
        let scoreById = Dictionary(uniqueKeysWithValues: fused.map { ($0.id, $0.score) })
        let denseSet = Set(denseIds)
        let sparseSet = Set(sparseIds)
        return topIds.compactMap { id -> RetrievalResult? in
            guard revalidated.contains(id), let record = recordById[id] else { return nil }
            return RetrievalResult(
                record: record,
                score: Float(scoreById[id] ?? 0),
                attribution: attribution(for: id, denseSet: denseSet, sparseSet: sparseSet)
            )
        }
    }

    public func retrieveForAsk(
        query: String,
        filter: FilterSpec,
        budget: AskPromptBudget = .default
    ) throws -> AskRetrievalResult {
        try Task.checkCancellation()
        if filter.collections == [.entity] {
            let sourceCount = try vectorStore.count(collection: .entity)
            try Task.checkCancellation()
            let route = AskScopeRoute(
                mode: .standard,
                scopedMessageCount: sourceCount,
                sourceLimit: budget.standardSourceLimit,
                scopeUnit: "source"
            )
            let results = try retrieve(query: query, filter: filter, k: route.sourceLimit)
            return AskRetrievalResult(route: route, sources: results)
        }

        let scopeSize = try vectorStore.countMessages(filter: filter)
        try Task.checkCancellation()
        let route = ScopeRouter.decide(scopeSize: scopeSize, budget: budget)

        switch route.mode {
        case .direct:
            guard scopeSize > 0, route.sourceLimit > 0 else {
                return AskRetrievalResult(route: route, sources: [])
            }
            let messageIds = try vectorStore.enumerateMessageIds(
                filter: filter,
                orderBy: .receivedDesc,
                limit: scopeSize
            )
            try Task.checkCancellation()
            let vectorIds = try directModeVectorIds(
                messageIds: messageIds,
                filter: filter,
                sourceLimit: route.sourceLimit
            )
            let boostedVectorIds = try directModeAttachmentAwareVectorIds(
                query: query,
                messageIds: messageIds,
                filter: filter,
                sourceLimit: route.sourceLimit,
                primaryVectorIds: vectorIds
            )
            let records = try vectorStore.hydrate(vectorIds: boostedVectorIds)
            try Task.checkCancellation()
            return AskRetrievalResult(
                route: route,
                sources: records.map {
                    RetrievalResult(record: $0, score: 1, attribution: .both)
                }
            )
        case .wide, .standard:
            let results = try retrieveForAskSources(
                query: query,
                filter: filter,
                sourceLimit: route.sourceLimit
            )
            return AskRetrievalResult(route: route, sources: results)
        }
    }

    private func retrieveForAskSources(
        query: String,
        filter: FilterSpec,
        sourceLimit: Int
    ) throws -> [RetrievalResult] {
        guard sourceLimit > 0 else { return [] }
        try Task.checkCancellation()
        // Ask opts into kNN-graph expansion whenever the neighbor graph exists:
        // two facts split across messages of the same semantic neighborhood are
        // exactly what cosine-only retrieval cannot join.
        let expansionConfig: VectorNeighborExpansionConfig? = neighborsStore != nil ? .default : nil
        let primary = try retrieve(query: query, filter: filter, k: sourceLimit, expansionConfig: expansionConfig)
        try Task.checkCancellation()
        guard Self.hasVisualAttachmentIntent(query),
              let attachmentFilter = Self.attachmentEligibleFilter(from: filter) else {
            return primary
        }

        let attachmentLimit = min(max(2, sourceLimit / 3), sourceLimit)
        let attachmentResults = try retrieve(
            query: query,
            filter: attachmentFilter,
            k: attachmentLimit
        )
        try Task.checkCancellation()
        guard !attachmentResults.isEmpty else { return primary }

        let reservedAttachmentSlots = min(attachmentResults.count, attachmentLimit, sourceLimit)
        let primaryFirstLimit = max(0, sourceLimit - reservedAttachmentSlots)
        var seen = Set<Int64>()
        var merged: [RetrievalResult] = []
        for result in primary.prefix(primaryFirstLimit) where seen.insert(result.record.vectorId).inserted {
            try Task.checkCancellation()
            merged.append(result)
            if merged.count == sourceLimit { return merged }
        }
        for result in attachmentResults where seen.insert(result.record.vectorId).inserted {
            try Task.checkCancellation()
            merged.append(result)
            if merged.count == sourceLimit { break }
        }
        guard merged.count < sourceLimit else { return merged }
        for result in primary.dropFirst(primaryFirstLimit) where seen.insert(result.record.vectorId).inserted {
            try Task.checkCancellation()
            merged.append(result)
            if merged.count == sourceLimit { break }
        }
        return merged
    }

    private static func attachmentEligibleFilter(from filter: FilterSpec) -> FilterSpec? {
        if !filter.collections.isEmpty, !filter.collections.contains(.attachment) {
            return nil
        }
        var attachmentFilter = filter
        attachmentFilter.collections = [.attachment]
        return attachmentFilter
    }

    private static func hasVisualAttachmentIntent(_ query: String) -> Bool {
        let normalized = query.lowercased()
        if containsFilenameLikeTerm(normalized) {
            return true
        }
        let separators = CharacterSet.alphanumerics.inverted
        let tokens = Set(normalized.components(separatedBy: separators).filter { !$0.isEmpty })
        let terms: Set<String> = [
            "attachment", "attachments", "attached", "image", "images", "photo", "photos",
            "picture", "screenshot", "ocr", "receipt", "invoice", "diagram", "chart",
            "graph", "scan", "scanned", "pdf", "file", "files"
        ]
        if !tokens.isDisjoint(with: terms) { return true }
        if tokens.contains(where: Self.looksFilenameLike) {
            return true
        }
        let phrases = [
            "screen shot",
            "attached image",
            "attached photo",
            "attached pdf",
            "attached file",
            "image attachment",
            "photo attachment"
        ]
        return phrases.contains { normalized.contains($0) }
    }

    private static func containsFilenameLikeTerm(_ query: String) -> Bool {
        let pattern = #"(^|[^A-Za-z0-9_-])[A-Za-z0-9][A-Za-z0-9._-]{0,159}\.(pdf|png|jpg|jpeg|heic|gif|tiff|webp|doc|docx|xls|xlsx|csv|ppt|pptx|txt|rtf)($|[^A-Za-z0-9_-])"#
        return query.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func looksFilenameLike(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 2,
              let ext = parts.last,
              ext.count >= 2 && ext.count <= 6 else {
            return false
        }
        let known = [
            "pdf", "png", "jpg", "jpeg", "heic", "gif", "tiff", "webp",
            "doc", "docx", "xls", "xlsx", "csv", "ppt", "pptx", "txt", "rtf"
        ]
        return known.contains(String(ext))
    }

    private func directModeVectorIds(
        messageIds: [String],
        filter: FilterSpec,
        sourceLimit: Int
    ) throws -> [Int64] {
        guard sourceLimit > 0, !messageIds.isEmpty else { return [] }
        try Task.checkCancellation()
        let perMessageLimit = max(1, sourceLimit / messageIds.count)
        var selected: [Int64] = []
        selected.reserveCapacity(sourceLimit)

        for messageId in messageIds {
            try Task.checkCancellation()
            let ids = try vectorStore.vectorIds(
                forMessageIds: [messageId],
                filter: filter,
                limit: perMessageLimit
            )
            for id in ids where selected.count < sourceLimit {
                selected.append(id)
            }
        }

        guard selected.count < sourceLimit else { return selected }
        let alreadySelected = Set(selected)
        let remaining = try vectorStore.vectorIds(
            forMessageIds: messageIds,
            filter: filter,
            limit: sourceLimit.multipliedReportingOverflow(by: 2).overflow ? Int.max : sourceLimit * 2
        )
        for id in remaining where !alreadySelected.contains(id) {
            try Task.checkCancellation()
            selected.append(id)
            if selected.count == sourceLimit {
                break
            }
        }
        return selected
    }

    private func directModeAttachmentAwareVectorIds(
        query: String,
        messageIds: [String],
        filter: FilterSpec,
        sourceLimit: Int,
        primaryVectorIds: [Int64]
    ) throws -> [Int64] {
        guard sourceLimit > 0,
              Self.hasVisualAttachmentIntent(query),
              let attachmentFilter = Self.attachmentEligibleFilter(from: filter) else {
            return primaryVectorIds
        }
        try Task.checkCancellation()

        let attachmentLimit = min(max(2, sourceLimit / 3), sourceLimit)
        let attachmentIds = try vectorStore.vectorIds(
            forMessageIds: messageIds,
            filter: attachmentFilter,
            limit: attachmentLimit
        )
        guard !attachmentIds.isEmpty else { return primaryVectorIds }

        let reservedAttachmentSlots = min(attachmentIds.count, attachmentLimit, sourceLimit)
        let primaryFirstLimit = max(0, sourceLimit - reservedAttachmentSlots)
        var seen = Set<Int64>()
        var merged: [Int64] = []
        for id in primaryVectorIds.prefix(primaryFirstLimit) where seen.insert(id).inserted {
            try Task.checkCancellation()
            merged.append(id)
            if merged.count == sourceLimit { return merged }
        }
        for id in attachmentIds where seen.insert(id).inserted {
            try Task.checkCancellation()
            merged.append(id)
            if merged.count == sourceLimit { return merged }
        }
        for id in primaryVectorIds.dropFirst(primaryFirstLimit) where seen.insert(id).inserted {
            try Task.checkCancellation()
            merged.append(id)
            if merged.count == sourceLimit { break }
        }
        return merged
    }

    private func rerank(
        query: String,
        candidates: [VectorRecord],
        fused: [RRFFusion.Item]
    ) throws -> [(record: VectorRecord, relevance: Float)] {
        try Task.checkCancellation()
        let currentReranker = beginReranking()

        if let reranker = currentReranker {
            defer { endReranking() }
            let scores = try reranker.score(query: query, documents: candidates.map(\.textPayload))
            try Task.checkCancellation()
            return zip(candidates, scores)
                .map { (record: $0.0, relevance: $0.1) }
                .sorted {
                    if $0.relevance == $1.relevance {
                        return $0.record.vectorId < $1.record.vectorId
                    }
                    return $0.relevance > $1.relevance
                }
        }

        let fusedScoreById = Dictionary(uniqueKeysWithValues: fused.map { ($0.id, Float($0.score)) })
        return candidates
            .map { (record: $0, relevance: fusedScoreById[$0.vectorId] ?? 0) }
            .sorted {
                if $0.relevance == $1.relevance {
                    return $0.record.vectorId < $1.record.vectorId
                }
                return $0.relevance > $1.relevance
            }
    }

    private func attribution(
        for id: Int64,
        denseSet: Set<Int64>,
        sparseSet: Set<Int64>
    ) -> RetrievalResult.Attribution {
        switch (denseSet.contains(id), sparseSet.contains(id)) {
        case (true, true): return .both
        case (true, false): return .dense
        case (false, true): return .sparse
        case (false, false): return .dense
        }
    }

    /// kNN-graph expansion pass. Walks `vector_neighbors` for each anchor message
    /// in `primaryResults`, hydrates the novel neighbor vectors, scores them with
    /// the cross-encoder (or a fallback strictly below the weakest primary hit
    /// when no reranker is downloaded), re-validates against `filter`, and returns
    /// up to `config.maxExpansionSlots` additional `.expanded` results. Pure
    /// SQLite — no SwiftData required.
    private func expandedResults(
        query: String,
        filter: FilterSpec,
        primaryResults: [RetrievalResult],
        config: VectorNeighborExpansionConfig,
        neighborsStore: VectorNeighborsStore
    ) throws -> [RetrievalResult] {
        guard !primaryResults.isEmpty, config.maxExpansionSlots > 0 else { return [] }
        try Task.checkCancellation()
        // Dedup anchors while preserving the relevance order of `primaryResults`
        // so the top-scored hits drive the expansion budget deterministically
        // (a plain Set would hash-randomize traversal order, which matters most
        // in the no-reranker path where expansion scores are flat).
        var seenAnchors = Set<String>()
        let anchorMessageIds = primaryResults.map(\.record.messageId).filter { seenAnchors.insert($0).inserted }
        let seenVectorIds = Set(primaryResults.map(\.record.vectorId))
        try Task.checkCancellation()

        let candidates: [VectorRecord]
        do {
            candidates = try VectorNeighborExpander.candidates(
                anchorMessageIds: anchorMessageIds,
                seenVectorIds: seenVectorIds,
                filter: filter,
                config: config,
                vectorStore: vectorStore,
                neighborsStore: neighborsStore
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
        guard !candidates.isEmpty else { return [] }
        try Task.checkCancellation()

        let currentReranker = beginReranking()

        let scored: [(record: VectorRecord, score: Float)]
        if let reranker = currentReranker {
            defer { endReranking() }
            do {
                let scores = try reranker.score(query: query, documents: candidates.map(\.textPayload))
                try Task.checkCancellation()
                scored = zip(candidates, scores)
                    .map { (record: $0.0, score: $0.1) }
                    .sorted {
                        if $0.score == $1.score {
                            return $0.record.vectorId < $1.record.vectorId
                        }
                        return $0.score > $1.score
                    }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return []
            }
        } else {
            // Without a reranker the primaries carry tiny RRF fusion scores;
            // anchor the expansion strictly below the weakest of them so it can
            // never outrank a genuine hit in any downstream sort.
            let fallback = (primaryResults.map(\.score).min() ?? 0) * 0.5
            scored = candidates.map { (record: $0, score: fallback) }
        }

        guard let revalidated = try? vectorStore.filterVectorIds(scored.map(\.record.vectorId), filter: filter)
        else {
            return []
        }
        try Task.checkCancellation()

        var out: [RetrievalResult] = []
        for pair in scored where revalidated.contains(pair.record.vectorId) {
            try Task.checkCancellation()
            if out.count >= config.maxExpansionSlots { break }
            out.append(RetrievalResult(record: pair.record, score: pair.score, attribution: .expanded))
        }
        return out
    }

    private func beginReranking() -> (any RetrievalReranking)? {
        rerankerLock.lock()
        defer { rerankerLock.unlock() }
        guard let reranker else { return nil }
        activeRerankCount += 1
        return reranker
    }

    private func endReranking() {
        let waiters: [CheckedContinuation<Void, Never>]
        rerankerLock.lock()
        activeRerankCount -= 1
        if activeRerankCount == 0 {
            waiters = rerankerDrainWaiters
            rerankerDrainWaiters.removeAll(keepingCapacity: false)
        } else {
            waiters = []
        }
        rerankerLock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
