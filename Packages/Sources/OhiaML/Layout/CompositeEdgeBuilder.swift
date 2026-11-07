// Packages/Sources/OhiaML/Layout/CompositeEdgeBuilder.swift
import Foundation
import OhiaCore

/// Pure helper: blends per-source neighbor lists into a single list per
/// source node, combining duplicate targets with summed weighted similarity.
///
/// **ID convention.** All inputs and outputs use *position indices* (0..<n),
/// not DB `vector_id`s, matching `ForceDirectedEngine.step`'s expectation.
/// Callers that source edges from DB-keyed stores (e.g. `FrameEdgeProvider`,
/// `VectorNeighborsStore`) must translate DB ids → positions before passing
/// them in. Mis-wiring this is silent: the force kernel will still run, but
/// apply forces to the wrong nodes — the failure mode is purely visual.
///
/// Each input is `[[VectorNeighbor]]` indexed by the source-position index.
/// Inputs need not share outer lengths — the builder uses `max(counts)` and
/// skips sources whose outer length falls short of the current row. The
/// output similarity for a target is
///   `clamp(sum over sources of (weight[source] * sim[source]), 0, 1)`
/// which is then sorted desc and truncated to `topK`.
public enum CompositeEdgeBuilder {

    public static func merge(
        cosine: [[VectorNeighbor]],
        thread: [[VectorNeighbor]],
        correspondent: [[VectorNeighbor]],
        temporal: [[VectorNeighbor]],
        action: [[VectorNeighbor]] = [],
        classification: [[VectorNeighbor]] = [],
        arc: [[VectorNeighbor]] = [],
        weights: FrameForceWeights,
        topK: Int
    ) -> [[VectorNeighbor]] {
        let n = [
            cosine.count,
            thread.count,
            correspondent.count,
            temporal.count,
            action.count,
            classification.count,
            arc.count
        ].max() ?? 0
        var out: [[VectorNeighbor]] = Array(repeating: [], count: n)
        let wCos = Swift.max(0, Swift.min(weights.cosine, 2))
        let wThr = Swift.max(0, Swift.min(weights.thread, 2))
        let wCor = Swift.max(0, Swift.min(weights.correspondent, 2))
        let wTmp = Swift.max(0, Swift.min(weights.temporal, 2))
        let wAct = Swift.max(0, Swift.min(weights.action, 2))
        let wClassification = Swift.max(0, Swift.min(weights.classification, 2))
        let wArc = Swift.max(0, Swift.min(weights.arc, 2))

        for i in 0..<n {
            var accum: [Int64: Float] = [:]
            func add(_ rows: [[VectorNeighbor]], weight: Float) {
                guard weight > 0, i < rows.count else { return }
                for row in rows[i] {
                    accum[row.targetId, default: 0] += weight * row.similarity
                }
            }
            add(cosine, weight: wCos)
            add(thread, weight: wThr)
            add(correspondent, weight: wCor)
            add(temporal, weight: wTmp)
            add(action, weight: wAct)
            add(classification, weight: wClassification)
            add(arc, weight: wArc)

            let sorted = accum.sorted { $0.value > $1.value }.prefix(topK)
            out[i] = sorted.enumerated().map { rank, pair in
                VectorNeighbor(
                    sourceId: Int64(i),
                    targetId: pair.key,
                    similarity: Swift.max(0, Swift.min(pair.value, 1)),
                    rank: rank
                )
            }
        }
        return out
    }
}
