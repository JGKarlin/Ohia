import Foundation
import simd
import OhiaCore

/// Coordinates the three Phase 1 layout primitives into pipeline operations:
/// PCA seeding, k-NN graph construction, and force-directed refinement.
///
/// Owns single instances of `KNNBuilder` and `ForceDirectedEngine` for the app's
/// lifetime so Metal resources (device, command queue, compiled pipeline state)
/// are reused across every layout operation — initializing them per-call would
/// cost ~15ms each on first hit and blow the Metal pipeline cache.
///
/// Shape of the work:
/// - `coldBuild` — full pipeline over all unplaced vectors. PCA → k-NN → 200
///   iterations of force-directed refine. Called once per corpus (onboarding or
///   manual re-layout).
/// - `indexNewVector` — single new vector placement. k-NN against placed set →
///   weighted-centroid seed → 25 iterations of local refine (new node vs. its
///   top-K neighbors; distant nodes stay put).
/// - `refineStep` — background single-step force simulation over the whole
///   placed corpus. Drained by `LayoutRefineWorker` on an idle cadence.
public actor LayoutOrchestrator {

    private let vectorStore: VectorStore
    private let neighborsStore: VectorNeighborsStore
    private let frameLayoutStore: VectorFrameLayoutStore
    private let knn: KNNBuilder
    private let engine: ForceDirectedEngine
    private static let indexKNNBatchLimit = 32
    private static let coldNeighborPersistenceBatchLimit = 10_000

    // Phase 1 tuning knobs — let properties so tests can read them. Hard-coded
    // for now; if these need to be adjusted at runtime they should move to a
    // settings struct rather than mutable actor state.
    public let topK: Int = 15
    public let coldRefineIterations: Int = 200
    public let indexSeedIterations: Int = 25

    /// Uniform random jitter vector of magnitude ≤ `seedJitterRange`. Used at
    /// bootstrap and at each seed centroid so the force-directed engine never
    /// starts the newcomer exactly on top of a frozen neighbor — coincident
    /// points have zero gradient and collapse the whole corpus to a single
    /// location until `refine` runs. Magnitude is several orders below the
    /// typical settled layout scale, so the jitter is visually invisible
    /// once the refine pass kicks in.
    private static let seedJitterRange: Float = 0.01
    static func seedJitter() -> SIMD3<Float> {
        SIMD3<Float>(
            Float.random(in: -seedJitterRange...seedJitterRange),
            Float.random(in: -seedJitterRange...seedJitterRange),
            Float.random(in: -seedJitterRange...seedJitterRange)
        )
    }

    public init(
        vectorStore: VectorStore,
        neighborsStore: VectorNeighborsStore,
        frameLayoutStore: VectorFrameLayoutStore
    ) throws {
        self.vectorStore = vectorStore
        self.neighborsStore = neighborsStore
        self.frameLayoutStore = frameLayoutStore
        // Both initializers can throw if Metal is unavailable (e.g. simulator);
        // propagate the underlying error so callers can fall back (e.g. skip
        // constellation mode) rather than opaquely reporting orchestrator init.
        self.knn = try KNNBuilder()
        self.engine = try ForceDirectedEngine()
    }

    // MARK: - Cold build

    /// Runs the full cold-start pipeline over every vector in the store:
    /// PCA seed → k-NN graph build (all-pairs brute force) → N iterations of
    /// force-directed refinement. Progress is reported via the callback at
    /// three milestones: 0.15 after PCA, 0.15→0.50 linearly during k-NN
    /// construction, and 1.0 after refinement.
    ///
    /// The all-pairs similarities are computed in bounded MPS query batches:
    /// the normalized corpus is uploaded once, and no N x N result matrix is
    /// retained or allocated.
    public func coldBuild(progress: @escaping @Sendable (Double) -> Void) async throws {
        let all = try vectorStore.allVectorsRaw()
        guard !all.isEmpty else { return }

        // Stage 1: PCA seed — top-3 principal components, normalized to [-1,1]³
        let raw = all.map(\.vec)
        var positions = try PCAProjector.project(vectors: raw)
        progress(0.15)

        // Persist the PCA-seeded positions so partial progress is durable
        // (a crash between PCA and force-refine leaves a usable layout).
        let now = Date()
        let seedBatch: [(vectorId: Int64, xyz: SIMD3<Float>, moveMagnitude: Float)] =
            zip(all, positions).map { (vectorId: $0.0.id, xyz: $0.1, moveMagnitude: Float(0)) }
        try vectorStore.updateLayoutAndArrivalBatch(seedBatch, at: now)

        // Stage 2: k-NN graph build. Normalize/upload the corpus once and stream
        // bounded query batches. Neighbor rows are buffered across sources so
        // SQLite gets bounded multi-source transactions rather than one
        // transaction for every source vector.
        let entries: [(id: Int64, vec: [Float])] = all.map { (id: $0.id, vec: $0.vec) }
        let idToIndex: [Int64: Int] = Dictionary(
            uniqueKeysWithValues: all.enumerated().map { (offset, v) in (v.id, offset) }
        )
        var neighborsByIndex: [[VectorNeighbor]] = Array(repeating: [], count: all.count)
        var neighborRowsToPersist: [VectorNeighbor] = []
        neighborRowsToPersist.reserveCapacity(Self.coldNeighborPersistenceBatchLimit + topK)

        try knn.buildAllKNNBatches(vectors: entries, topK: topK) { batch, completed, total in
            for row in batch {
                neighborRowsToPersist.append(contentsOf: row.neighbors)
                if neighborRowsToPersist.count >= Self.coldNeighborPersistenceBatchLimit {
                    try neighborsStore.insertBatch(neighborRowsToPersist)
                    neighborRowsToPersist.removeAll(keepingCapacity: true)
                }
                guard let sourceIndex = idToIndex[row.sourceId] else { continue }

                // The force kernel operates on dense position indices, not DB
                // ids. Every target should be present because this is an
                // all-corpus operation; retain the defensive lookup in case a
                // future caller supplies a filtered set.
                neighborsByIndex[sourceIndex] = row.neighbors.compactMap { neighbor in
                    guard let targetIndex = idToIndex[neighbor.targetId] else { return nil }
                    return VectorNeighbor(
                        sourceId: Int64(sourceIndex),
                        targetId: Int64(targetIndex),
                        similarity: neighbor.similarity,
                        rank: neighbor.rank
                    )
                }
            }

            if completed < total {
                progress(0.15 + 0.35 * Double(completed) / Double(total))
            }
        }
        try Task.checkCancellation()
        try neighborsStore.insertBatch(neighborRowsToPersist)
        progress(0.50)

        // Stage 3: Force-directed refinement. 200 iterations over the whole
        // corpus with all edges in-flight — converges from the PCA skeleton to
        // a cluster-faithful layout in <1s for N ≤ 2K.
        let refined = try await engine.step(
            positions: positions,
            neighbors: neighborsByIndex,
            iterations: coldRefineIterations
        )
        positions = refined
        let finalBatch: [(vectorId: Int64, xyz: SIMD3<Float>, moveMagnitude: Float)] =
            zip(all, positions).map { (vectorId: $0.0.id, xyz: $0.1, moveMagnitude: Float(0)) }
        try vectorStore.updateLayoutBatch(finalBatch)
        progress(1.0)
    }

    // MARK: - Index a single new vector

    /// Places a single newly-embedded vector into the constellation:
    /// 1. Find its top-K neighbors in embedding space (against placed set).
    /// 2. Persist those neighbor edges to `vector_neighbors`.
    /// 3. Seed its 3-D position at the similarity-weighted centroid of those
    ///    neighbors' current positions.
    /// 4. Run a small local force-directed step (default 25 iterations) where
    ///    only the newcomer moves — its neighbors are present in the positions
    ///    array but have no outgoing edges, so the kernel's symmetric-attractive
    ///    term is applied only from the newcomer side.
    /// 5. Persist the newcomer's settled position and stamp arrival_time.
    ///
    /// Degenerate cases:
    /// - Source vector not found → silent return.
    /// - Empty placed set (first vector ever) → place at origin.
    public func indexNewVector(vectorId: Int64) async throws {
        _ = try await indexNewVectors(vectorIds: [vectorId])
    }

    /// Batched variant of `indexNewVector`. It loads the placed corpus and the
    /// requested newcomer rows once, then places each newcomer sequentially
    /// against the incrementally growing placed set. This keeps the same visual
    /// semantics as one-by-one indexing while avoiding an O(N) SQLite/vector
    /// reload for every queued `.index` job.
    @discardableResult
    public func indexNewVectors(vectorIds: [Int64]) async throws -> Int {
        let orderedIds = Self.uniquePreservingOrder(vectorIds)
        guard !orderedIds.isEmpty else { return 0 }

        let requested = try vectorStore.vectorsRaw(ids: orderedIds)
        let byId: [Int64: VectorStore.RawVec] = Dictionary(
            uniqueKeysWithValues: requested.map { record in (record.id, record) }
        )
        let requestedSet = Set(orderedIds)

        let existing = try vectorStore.placedVectorsRaw().filter { !requestedSet.contains($0.id) }
        var entries: [(id: Int64, vec: [Float])] = existing.map { (id: $0.id, vec: $0.vec) }
        var idToPos: [Int64: SIMD3<Float>] = Dictionary(
            uniqueKeysWithValues: existing.compactMap { v -> (Int64, SIMD3<Float>)? in
                guard let p = v.position else { return nil }
                return (v.id, p)
            }
        )

        var layoutUpdates: [(vectorId: Int64, xyz: SIMD3<Float>, moveMagnitude: Float)] = []
        var neighborRows: [VectorNeighbor] = []
        layoutUpdates.reserveCapacity(orderedIds.count)
        neighborRows.reserveCapacity(orderedIds.count * topK)

        var pending = orderedIds.compactMap { vectorId -> (vectorId: Int64, rec: VectorStore.RawVec)? in
            guard let rec = byId[vectorId], !rec.hasPlacedLayout else { return nil }
            return (vectorId, rec)
        }

        while !pending.isEmpty {
            try Task.checkCancellation()

            guard !entries.isEmpty else {
                let next = pending.removeFirst()
                let position = Self.seedJitter()
                layoutUpdates.append((vectorId: next.vectorId, xyz: position, moveMagnitude: Float(0)))
                idToPos[next.vectorId] = position
                entries.append((id: next.rec.id, vec: next.rec.vec))
                continue
            }

            let chunk = Array(pending.prefix(Self.indexKNNBatchLimit))
            pending.removeFirst(chunk.count)
            let neighborsBySource = try knn.buildKNNBatch(
                newVectors: chunk.map { (id: $0.vectorId, vec: $0.rec.vec) },
                existing: entries,
                topK: topK
            )

            for item in chunk {
                let rawNeighbors = neighborsBySource[item.vectorId] ?? []
                neighborRows.append(contentsOf: rawNeighbors)

                let placedNeighbors: [(neighbor: VectorNeighbor, pos: SIMD3<Float>)] = rawNeighbors.compactMap { nb -> (neighbor: VectorNeighbor, pos: SIMD3<Float>)? in
                    guard let p = idToPos[nb.targetId] else { return nil }
                    return (nb, p)
                }

                let position: SIMD3<Float>
                if placedNeighbors.isEmpty {
                    position = Self.seedJitter()
                } else {
                    position = try await settledPosition(for: placedNeighbors)
                }

                layoutUpdates.append((vectorId: item.vectorId, xyz: position, moveMagnitude: Float(0)))
                idToPos[item.vectorId] = position
                entries.append((id: item.rec.id, vec: item.rec.vec))
            }
        }

        if !neighborRows.isEmpty {
            try neighborsStore.insertBatch(neighborRows)
        }
        try vectorStore.updateLayoutAndArrivalBatch(layoutUpdates, at: Date())
        return layoutUpdates.count
    }

    private static func uniquePreservingOrder(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        var out: [Int64] = []
        out.reserveCapacity(ids.count)
        for id in ids where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }

    private func settledPosition(
        for placedNeighbors: [(neighbor: VectorNeighbor, pos: SIMD3<Float>)]
    ) async throws -> SIMD3<Float> {
        let wSum = placedNeighbors.reduce(Float(0)) { $0 + $1.neighbor.similarity }
        var centroid = SIMD3<Float>.zero
        if wSum > 0 {
            for p in placedNeighbors {
                centroid += p.pos * (p.neighbor.similarity / wSum)
            }
        } else {
            centroid = placedNeighbors[0].pos
        }

        var positions: [SIMD3<Float>] = [centroid + Self.seedJitter()]
        positions.append(contentsOf: placedNeighbors.map(\.pos))

        var neighborsByIndex: [[VectorNeighbor]] = Array(repeating: [], count: positions.count)
        neighborsByIndex[0] = placedNeighbors.enumerated().map { (rank, pair) in
            VectorNeighbor(
                sourceId: 0,
                targetId: Int64(rank + 1),
                similarity: pair.neighbor.similarity,
                rank: rank
            )
        }

        let refined = try await engine.step(
            positions: positions,
            neighbors: neighborsByIndex,
            iterations: indexSeedIterations
        )
        return refined[0]
    }

    // MARK: - One-shot layout repair

    /// Detect and repair a collapsed layout — one where every placed vector
    /// sits at (approximately) the same world position. This is the end-state
    /// of the pre-jitter `indexNewVector`: the bootstrap wrote exactly
    /// `(0, 0, 0)`, every subsequent seed centroid was a weighted average of
    /// origin-only neighbors (= origin), and `engine.step` couldn't spread
    /// coincident points because symmetric configurations have zero gradient.
    ///
    /// Called once at app startup (from `OhiaApp.init`) so existing corpora
    /// that were indexed under the buggy code don't stay stacked on origin
    /// forever waiting for a `refine` tick — which is low priority and may
    /// sit behind thousands of summarize/embed jobs for hours.
    ///
    /// No-op when the corpus has natural spread. Threshold is 1e-3 world
    /// units (1mm) because any non-degenerate layout spans several units;
    /// we won't false-positive a healthy tight cluster.
    public func repairCollapsedLayoutIfNeeded() async throws {
        let placed = try vectorStore.allVectorsRaw().filter { $0.hasPlacedLayout }
        guard placed.count >= 2 else { return }

        let positions = placed.compactMap(\.position)
        guard positions.count == placed.count else { return }

        let xs = positions.map(\.x)
        let ys = positions.map(\.y)
        let zs = positions.map(\.z)
        let span = simd_length(SIMD3<Float>(
            xs.max()! - xs.min()!,
            ys.max()! - ys.min()!,
            zs.max()! - zs.min()!
        ))
        guard span < 0.001 else { return }

        // Large uniform jitter (±1 world unit) — the typical settled layout
        // spans several units, so this starting scatter puts nodes in the
        // right ballpark and gives force-directed a clear gradient. Small
        // jitter (0.01 like seedJitter) would leave the corpus visually
        // identical to collapsed until many refine passes pull it apart.
        let repaired: [(vectorId: Int64, xyz: SIMD3<Float>, moveMagnitude: Float)] = placed.map { v in
            let p = SIMD3<Float>(
                Float.random(in: -1.0...1.0),
                Float.random(in: -1.0...1.0),
                Float.random(in: -1.0...1.0)
            )
            return (vectorId: v.id, xyz: p, moveMagnitude: 0)
        }
        try vectorStore.updateLayoutBatch(repaired)
    }

    // MARK: - Background refinement step

    /// Continuous-refine pass: one (or a few) force-directed iteration(s) over
    /// the entire placed corpus, using each node's persisted top-K neighbors.
    /// Called periodically by `LayoutRefineWorker` while the UI is showing
    /// Constellation mode — keeps the layout slowly settling without ever
    /// doing a full cold rebuild.
    ///
    /// Nodes without layout are excluded; persisted neighbor edges whose target
    /// isn't currently placed (deleted source, filtered out) are skipped.
    public func refineStep(iterations: Int = 1) async throws {
        let all = try vectorStore.allVectorsRaw().filter { $0.hasPlacedLayout }
        guard all.count > 1 else { return }

        let positions = all.map { $0.position! }
        let idToIndex: [Int64: Int] = Dictionary(
            uniqueKeysWithValues: all.enumerated().map { (offset, v) in (v.id, offset) }
        )
        var byIndex: [[VectorNeighbor]] = Array(repeating: [], count: all.count)
        for (i, entry) in all.enumerated() {
            let persisted = try neighborsStore.neighborsOf(vectorId: entry.id, limit: topK)
            byIndex[i] = persisted.compactMap { nb in
                guard let tIdx = idToIndex[nb.targetId] else { return nil }
                return VectorNeighbor(
                    sourceId: Int64(i),
                    targetId: Int64(tIdx),
                    similarity: nb.similarity,
                    rank: nb.rank
                )
            }
        }

        let refined = try await engine.step(
            positions: positions,
            neighbors: byIndex,
            iterations: iterations
        )
        // Report per-node displacement as moveMagnitude — the UI uses this to
        // fade the "ignition" emissive boost on newly-settled nodes.
        let moveMags = zip(positions, refined).map { simd_distance($0, $1) }
        let batch: [(vectorId: Int64, xyz: SIMD3<Float>, moveMagnitude: Float)] =
            zip(all.indices, zip(refined, moveMags)).map { (i, pair) in
                (vectorId: all[i].id, xyz: pair.0, moveMagnitude: pair.1)
            }
        try vectorStore.updateLayoutBatch(batch)
    }

    // MARK: - Frame burst

    /// Seeds `frame` from `vector_frame_layout` if populated, otherwise from the
    /// Phase 1 default `vectors.layout_*` columns, then runs `iterations` force
    /// steps using composite edges built from cosine + provider-supplied
    /// structural / interpretation edges weighted by `weights`. Writes the
    /// settled positions back to `vector_frame_layout`.
    public func burstForFrame(
        _ frame: FrameKey,
        weights: FrameForceWeights,
        edgeProvider: FrameEdgeProvider,
        iterations: Int = 200
    ) async throws {
        let all = try vectorStore.allVectorsRaw().filter { $0.hasPlacedLayout }
        guard all.count > 1 else { return }

        // Seed positions: frame rows where available, default-layout fallback otherwise.
        let ids = all.map(\.id)
        let framePositions = try frameLayoutStore.positionsForFrame(frame, vectorIds: ids)
        let positions: [SIMD3<Float>] = all.map { v in
            framePositions[v.id] ?? v.position ?? .zero
        }

        // Build per-classification edges. Cosine is persisted in vector_neighbors so
        // fetch it once; structural and interpretation classifications come from the
        // provider.
        let idToIndex: [Int64: Int] = Dictionary(
            uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) }
        )
        func remapByIndex(_ srcByDbId: [Int64: [VectorNeighbor]]) -> [[VectorNeighbor]] {
            var out: [[VectorNeighbor]] = Array(repeating: [], count: ids.count)
            for (dbId, edges) in srcByDbId {
                guard let i = idToIndex[dbId] else { continue }
                out[i] = edges.compactMap { e in
                    guard let tIdx = idToIndex[e.targetId] else { return nil }
                    return VectorNeighbor(
                        sourceId: Int64(i),
                        targetId: Int64(tIdx),
                        similarity: e.similarity,
                        rank: e.rank
                    )
                }
            }
            return out
        }

        // NB: this cosine-fetch + structural-edge + CompositeEdgeBuilder.merge
        // block is mirrored in FrameEdgeResolver.resolve (OhiaML/Layout) so the
        // view layer can read composite edges without re-running the burst.
        // Any change to weighting / remap shape / topK must land in both sites.
        var cosineByIndex: [[VectorNeighbor]] = Array(repeating: [], count: ids.count)
        for (i, v) in all.enumerated() {
            let persisted = try neighborsStore.neighborsOf(vectorId: v.id, limit: topK)
            cosineByIndex[i] = persisted.compactMap { nb in
                guard let t = idToIndex[nb.targetId] else { return nil }
                return VectorNeighbor(sourceId: Int64(i), targetId: Int64(t),
                                       similarity: nb.similarity, rank: nb.rank)
            }
        }

        let threadByDb = weights.thread > 0
            ? try await edgeProvider.threadEdges(for: ids, topK: topK)
            : [:]
        let correspondentByDb = weights.correspondent > 0
            ? try await edgeProvider.correspondentEdges(for: ids, topK: topK)
            : [:]
        let temporalByDb = weights.temporal > 0
            ? try await edgeProvider.temporalEdges(for: ids, topK: topK, windowDays: 14)
            : [:]
        let actionByDb = weights.action > 0
            ? try await edgeProvider.actionEdges(for: ids, topK: topK)
            : [:]
        let classificationByDb = weights.classification > 0
            ? try await edgeProvider.classificationEdges(for: ids, topK: topK)
            : [:]
        let arcByDb = weights.arc > 0
            ? try await edgeProvider.arcEdges(for: ids, topK: topK)
            : [:]

        let threadByIdx = remapByIndex(threadByDb)
        let correspondentByIdx = remapByIndex(correspondentByDb)
        let temporalByIdx = remapByIndex(temporalByDb)
        let actionByIdx = remapByIndex(actionByDb)
        let classificationByIdx = remapByIndex(classificationByDb)
        let arcByIdx = remapByIndex(arcByDb)

        let merged = CompositeEdgeBuilder.merge(
            cosine: cosineByIndex,
            thread: threadByIdx,
            correspondent: correspondentByIdx,
            temporal: temporalByIdx,
            action: actionByIdx,
            classification: classificationByIdx,
            arc: arcByIdx,
            weights: weights,
            topK: topK
        )

        let refined = try await engine.step(
            positions: positions,
            neighbors: merged,
            iterations: iterations
        )

        let moveMags = zip(positions, refined).map { simd_distance($0, $1) }
        let batch = zip(all.indices, zip(refined, moveMags)).map { (i, pair) in
            (vectorId: all[i].id, xyz: pair.0, moveMagnitude: pair.1)
        }
        try frameLayoutStore.upsertBatch(frame: frame, positions: batch)
    }

    /// Continuous single-step refine for an already-seeded frame. No-op if the
    /// frame has no persisted rows — caller should run `burstForFrame` first.
    public func refineStepForFrame(
        _ frame: FrameKey,
        weights: FrameForceWeights,
        edgeProvider: FrameEdgeProvider,
        iterations: Int = 1
    ) async throws {
        // No-op when the frame hasn't been primed — the doc comment promises this,
        // and without the guard refineStep would silently seed from the default
        // layout and quietly do up to `iterations` steps of burst work under a
        // method name that implies "continuous tiny refine."
        guard try frameLayoutStore.rowCount(frame: frame) > 0 else { return }
        // Re-use burstForFrame but with small iteration count; the cold-start
        // seed logic is identical.
        try await burstForFrame(frame, weights: weights, edgeProvider: edgeProvider, iterations: iterations)
    }
}
