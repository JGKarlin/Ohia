import Foundation
import OhiaCore

/// Recomputes composite edges (cosine + thread + correspondent + temporal +
/// attention + classification + arc)
/// on demand for the given node set. Used by
/// Constellation render planning when the active frame needs composite edges.
/// Meaning/default remains cosine-led but now also consumes weak semantic
/// classification/arc reinforcement.
///
/// The cosine-fetch + DB-id↔index remap + `CompositeEdgeBuilder.merge`
/// logic intentionally duplicates the same block in
/// `LayoutOrchestrator.burstForFrame`. The burst needs position-indexed
/// output for the Metal kernel; the resolver needs DB-id output for the
/// view layer. A future change to structural-edge weighting, the remap
/// shape, or the cosine-fetch topK MUST be applied to both call sites.
///
/// Phase 2 design decision: structural edges are NOT persisted per frame
/// (they change as new mail arrives and are cheap to recompute). The
/// cost per call is bounded by `nodeIds.count` — typically ≤ 3000.
public enum FrameEdgeResolver {

    /// Returns composite edges as DB-id `VectorNeighbor` rows.
    public static func resolve(
        frame: FrameKey,
        nodeIds: [Int64],
        weights: FrameForceWeights,
        neighborsStore: VectorNeighborsStore,
        edgeProvider: FrameEdgeProvider,
        topK: Int = 15
    ) async throws -> [VectorNeighbor] {
        guard !nodeIds.isEmpty else { return [] }

        let idToIndex: [Int64: Int] = Dictionary(
            uniqueKeysWithValues: nodeIds.enumerated().map { ($1, $0) }
        )

        var cosineByIdx: [[VectorNeighbor]] = Array(repeating: [], count: nodeIds.count)
        for (i, id) in nodeIds.enumerated() {
            let persisted = try neighborsStore.neighborsOf(vectorId: id, limit: topK)
            cosineByIdx[i] = persisted.compactMap { nb in
                guard let t = idToIndex[nb.targetId] else { return nil }
                return VectorNeighbor(
                    sourceId: Int64(i),
                    targetId: Int64(t),
                    similarity: nb.similarity,
                    rank: nb.rank
                )
            }
        }

        let threadByDb = weights.thread > 0
            ? try await edgeProvider.threadEdges(for: nodeIds, topK: topK)
            : [:]
        let corrByDb = weights.correspondent > 0
            ? try await edgeProvider.correspondentEdges(for: nodeIds, topK: topK)
            : [:]
        let tempByDb = weights.temporal > 0
            ? try await edgeProvider.temporalEdges(for: nodeIds, topK: topK, windowDays: 14)
            : [:]
        let actionByDb = weights.action > 0
            ? try await edgeProvider.actionEdges(for: nodeIds, topK: topK)
            : [:]
        let classificationByDb = weights.classification > 0
            ? try await edgeProvider.classificationEdges(for: nodeIds, topK: topK)
            : [:]
        let arcByDb = weights.arc > 0
            ? try await edgeProvider.arcEdges(for: nodeIds, topK: topK)
            : [:]

        func remap(_ byDb: [Int64: [VectorNeighbor]]) -> [[VectorNeighbor]] {
            var out: [[VectorNeighbor]] = Array(repeating: [], count: nodeIds.count)
            for (dbId, rows) in byDb {
                guard let i = idToIndex[dbId] else { continue }
                out[i] = rows.compactMap { e in
                    guard let t = idToIndex[e.targetId] else { return nil }
                    return VectorNeighbor(
                        sourceId: Int64(i),
                        targetId: Int64(t),
                        similarity: e.similarity,
                        rank: e.rank
                    )
                }
            }
            return out
        }

        let merged = CompositeEdgeBuilder.merge(
            cosine: cosineByIdx,
            thread: remap(threadByDb),
            correspondent: remap(corrByDb),
            temporal: remap(tempByDb),
            action: remap(actionByDb),
            classification: remap(classificationByDb),
            arc: remap(arcByDb),
            weights: weights,
            topK: topK
        )

        var out: [VectorNeighbor] = []
        for (i, rows) in merged.enumerated() {
            let srcDbId = nodeIds[i]
            for e in rows {
                let tIdx = Int(e.targetId)
                guard tIdx >= 0, tIdx < nodeIds.count else { continue }
                out.append(VectorNeighbor(
                    sourceId: srcDbId,
                    targetId: nodeIds[tIdx],
                    similarity: e.similarity,
                    rank: e.rank
                ))
            }
        }
        return out
    }
}
