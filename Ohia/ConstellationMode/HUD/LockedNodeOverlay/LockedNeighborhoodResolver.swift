import Foundation
import OhiaCore

struct LockedNeighborhoodResolver {
    nonisolated init() {}

    struct NeighbourMessage: Sendable, Equatable {
        let messageId: String
        let bestSimilarity: Float
        let matchedSourceVectorId: Int64
        let matchedTargetVectorId: Int64
        let bestRank: Int
    }

    /// Two-stage filter applied to per-message best edges *after* collapsing.
    ///
    /// `absoluteFloor` rejects any neighbour whose best vector-pair similarity falls below
    /// the floor — a guard against showing weak matches when nothing in the corpus is
    /// genuinely related yet. `topToMedianMargin` rejects the entire result list when the
    /// best similarity is not meaningfully above the median of all per-message candidates;
    /// this catches the "uniform mediocre noise floor" case where every score sits in the
    /// same band, which means the embedder is finding nothing distinctive — better to
    /// surface zero neighbours than the closest of many equally-bad matches.
    struct QualityGate: Sendable, Equatable {
        let absoluteFloor: Float
        let topToMedianMargin: Float

        init(absoluteFloor: Float, topToMedianMargin: Float) {
            self.absoluteFloor = absoluteFloor
            self.topToMedianMargin = topToMedianMargin
        }

        /// Calibrated for the BGE-M3 embedder with body-only-embedded body chunks.
        /// 0.95 lands above the transactional-shape baseline that drives unrelated
        /// receipts / payment confirmations / order updates into the ~0.85–0.92 band
        /// purely on form similarity (one iHerb order against an unrelated county
        /// permit payment surfaced at 0.91). Reserving "neighbour" for genuinely
        /// close pairs means fewer rows but every row earns its place. 0.05 is enough
        /// margin to distinguish a real signal from a uniformly-elevated neighbourhood.
        /// Marked `nonisolated` so the static stored property doesn't inherit MainActor
        /// isolation under Swift 6 — `QualityGate` is `Sendable`, so the access is safe
        /// without the `unsafe` qualifier.
        nonisolated static let `default` = QualityGate(absoluteFloor: 0.95, topToMedianMargin: 0.05)

        /// Disables filtering entirely. Tests use this to exercise the un-gated behaviour.
        nonisolated static let disabled = QualityGate(absoluteFloor: 0, topToMedianMargin: 0)
    }

    nonisolated func resolve(
        anchorMessageId: String,
        anchorVectorIds: Set<Int64>,
        neighborsBySource: [Int64: [VectorNeighbor]],
        messageByVectorId: [Int64: String],
        eligibleMessageIds: Set<String>?,
        limit: Int,
        gate: QualityGate = .default
    ) -> [NeighbourMessage] {
        guard limit > 0, !anchorVectorIds.isEmpty, !neighborsBySource.isEmpty else { return [] }

        var bestByMessage: [String: NeighbourMessage] = [:]
        for sourceId in anchorVectorIds.sorted() {
            guard let neighbors = neighborsBySource[sourceId] else { continue }
            for edge in neighbors {
                guard edge.sourceId == sourceId,
                      let targetMessageId = messageByVectorId[edge.targetId],
                      targetMessageId != anchorMessageId else {
                    continue
                }
                if let eligibleMessageIds, !eligibleMessageIds.contains(targetMessageId) {
                    continue
                }

                let candidate = NeighbourMessage(
                    messageId: targetMessageId,
                    bestSimilarity: edge.similarity,
                    matchedSourceVectorId: edge.sourceId,
                    matchedTargetVectorId: edge.targetId,
                    bestRank: edge.rank
                )
                if let existing = bestByMessage[targetMessageId] {
                    if Self.isBetter(candidate, than: existing) {
                        bestByMessage[targetMessageId] = candidate
                    }
                } else {
                    bestByMessage[targetMessageId] = candidate
                }
            }
        }

        let candidates = bestByMessage.values.sorted(by: Self.messageSort)
        let gated = Self.applyQualityGate(candidates: candidates, gate: gate)
        return Array(gated.prefix(limit))
    }

    /// Applied after per-message collapse, before the limit prefix. Uses the full candidate
    /// pool (not the limited pool) for median computation so the margin reflects the actual
    /// distribution the resolver observed.
    private nonisolated static func applyQualityGate(
        candidates: [NeighbourMessage],
        gate: QualityGate
    ) -> [NeighbourMessage] {
        guard let top = candidates.first else { return candidates }
        if top.bestSimilarity < gate.absoluteFloor { return [] }
        // The top-to-median margin suppresses a "uniformly-mediocre noise floor" —
        // every candidate sitting in the same band, which means the embedder found
        // nothing distinctive. That comparison only has signal with at least three
        // candidates; with one or two there is no distribution to detect uniformity
        // in, and a single strong match would otherwise be wrongly discarded.
        if candidates.count >= Self.medianMarginMinCandidates {
            let median = Self.median(of: candidates.map(\.bestSimilarity))
            if top.bestSimilarity - median < gate.topToMedianMargin { return [] }
        }
        return candidates.filter { $0.bestSimilarity >= gate.absoluteFloor }
    }

    private nonisolated static let medianMarginMinCandidates = 3

    private nonisolated static func median(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let count = sorted.count
        if count.isMultiple(of: 2) {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }
        return sorted[count / 2]
    }

    private nonisolated static func isBetter(_ candidate: NeighbourMessage, than existing: NeighbourMessage) -> Bool {
        if candidate.bestSimilarity != existing.bestSimilarity {
            return candidate.bestSimilarity > existing.bestSimilarity
        }
        if candidate.bestRank != existing.bestRank {
            return candidate.bestRank < existing.bestRank
        }
        if candidate.matchedTargetVectorId != existing.matchedTargetVectorId {
            return candidate.matchedTargetVectorId < existing.matchedTargetVectorId
        }
        return candidate.matchedSourceVectorId < existing.matchedSourceVectorId
    }

    private nonisolated static func messageSort(_ lhs: NeighbourMessage, _ rhs: NeighbourMessage) -> Bool {
        if lhs.bestSimilarity != rhs.bestSimilarity {
            return lhs.bestSimilarity > rhs.bestSimilarity
        }
        if lhs.bestRank != rhs.bestRank {
            return lhs.bestRank < rhs.bestRank
        }
        return lhs.messageId < rhs.messageId
    }
}
