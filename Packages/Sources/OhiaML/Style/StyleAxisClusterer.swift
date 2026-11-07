// StyleAxisClusterer.swift
// Pure, deterministic core of style discovery. Clusters one language's sent
// emails by their six measured style axes and decides how many distinct
// styles the author consistently writes in. No SwiftData, no model calls.

import Foundation
import OhiaCore

public enum StyleAxisClusterer {
    /// Lloyd restarts per candidate style count; the lowest-inertia run wins.
    static let restarts = 10
    static let maximumIterations = 100

    /// The smallest discovered style a language of `corpusCount` measured
    /// emails may hold.
    public static func minimumMembers(corpusCount: Int) -> Int {
        max(StyleRegisterLifecycle.minimumStyleMembers,
            Int((Double(corpusCount) * StyleRegisterLifecycle.minimumStyleShare).rounded(.up)))
    }

    /// Splits `points` into the styles the author consistently writes in.
    /// A split into k ≥ 2 styles is accepted only when every style holds
    /// `minimumMembers`, every pair of centroids sits `minimumSeparation`
    /// apart, and the mean simplified silhouette reaches `minimumSilhouette`;
    /// the valid k with the highest silhouette wins. `previousStyleCount`
    /// (styles currently active in the language) is kept unless another
    /// count beats it by `splitHysteresis`. Deterministic for a given input.
    public static func cluster(_ points: [StylePoint], previousStyleCount: Int? = nil) -> StyleClustering {
        let ordered = points.sorted { $0.id.uuidString < $1.id.uuidString }
        let vectors = ordered.map(\.axes.components)
        let mean = StyleAxisValues.mean(ordered.map(\.axes)) ?? ComposerStyleRubric.neutral
        guard !ordered.isEmpty else {
            return StyleClustering(clusters: [], silhouette: nil, languageMean: mean)
        }
        let single = StyleClustering(
            clusters: [StyleCluster(centroid: mean, memberIDs: ordered.map(\.id))],
            silhouette: nil, languageMean: mean)
        let minimum = minimumMembers(corpusCount: ordered.count)
        let maximumK = min(StyleRegisterLifecycle.maximumStylesPerLanguage, ordered.count / max(minimum, 1))
        guard maximumK >= 2 else { return single }

        struct Candidate {
            let k: Int
            let silhouette: Double
            let assignment: [Int]
            let centroids: [[Double]]
        }
        var candidates: [Candidate] = []
        for k in 2...maximumK {
            let (assignment, centroids) = bestPartition(vectors, k: k)
            let sizes = (0..<k).map { index in assignment.count(where: { $0 == index }) }
            guard sizes.allSatisfy({ $0 >= minimum }) else { continue }
            let axes = centroids.map(axisValues)
            let separated = axes.indices.allSatisfy { i in
                axes.indices.allSatisfy { j in
                    i >= j || axes[i].rmsDistance(to: axes[j]) >= StyleRegisterLifecycle.minimumSeparation
                }
            }
            guard separated else { continue }
            let score = simplifiedSilhouette(vectors, assignment: assignment, centroids: centroids)
            guard score >= StyleRegisterLifecycle.minimumSilhouette else { continue }
            candidates.append(Candidate(k: k, silhouette: score, assignment: assignment, centroids: centroids))
        }
        guard var chosen = candidates.max(by: { lhs, rhs in
            lhs.silhouette == rhs.silhouette ? lhs.k > rhs.k : lhs.silhouette < rhs.silhouette
        }) else { return single }
        // Hysteresis: the current split survives unless another beats it
        // clearly. A single current style keeps the language whole unless a
        // split clears the silhouette floor by the same margin.
        if let previous = previousStyleCount, previous != chosen.k {
            if previous <= 1 {
                if chosen.silhouette < StyleRegisterLifecycle.minimumSilhouette
                    + StyleRegisterLifecycle.splitHysteresis { return single }
            } else if let kept = candidates.first(where: { $0.k == previous }),
                      chosen.silhouette < kept.silhouette + StyleRegisterLifecycle.splitHysteresis {
                chosen = kept
            }
        }
        var members = Array(repeating: [UUID](), count: chosen.k)
        for (index, cluster) in chosen.assignment.enumerated() {
            members[cluster].append(ordered[index].id)
        }
        let clusters = zip(chosen.centroids, members)
            .map { StyleCluster(centroid: axisValues($0.0), memberIDs: $0.1) }
            .sorted { lhs, rhs in
                if lhs.memberIDs.count != rhs.memberIDs.count { return lhs.memberIDs.count > rhs.memberIDs.count }
                return lhs.centroid.components.lexicographicallyPrecedes(rhs.centroid.components)
            }
        return StyleClustering(clusters: clusters, silhouette: chosen.silhouette, languageMean: mean)
    }

    // MARK: - k-means

    /// The lowest-inertia k-means++ partition over `restarts` seeded runs.
    static func bestPartition(_ vectors: [[Double]], k: Int) -> (assignment: [Int], centroids: [[Double]]) {
        var best: (inertia: Double, assignment: [Int], centroids: [[Double]])?
        for restart in 0..<restarts {
            var generator = SplitMix64(seed: UInt64(k) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(restart))
            var centroids = seededCentroids(vectors, k: k, generator: &generator)
            var assignment = Array(repeating: -1, count: vectors.count)
            for _ in 0..<maximumIterations {
                var changed = false
                for (index, vector) in vectors.enumerated() {
                    let nearest = nearestCentroid(vector, centroids)
                    if assignment[index] != nearest {
                        assignment[index] = nearest
                        changed = true
                    }
                }
                centroids = updatedCentroids(vectors, assignment: assignment, previous: centroids)
                if !changed { break }
            }
            let inertia = zip(vectors, assignment).reduce(0) { $0 + squaredDistance($1.0, centroids[$1.1]) }
            if best == nil || inertia < best!.inertia {
                best = (inertia, assignment, centroids)
            }
        }
        return (best!.assignment, best!.centroids)
    }

    /// k-means++ seeding: each further centroid is drawn with probability
    /// proportional to its squared distance from the nearest chosen one.
    static func seededCentroids(_ vectors: [[Double]], k: Int, generator: inout SplitMix64) -> [[Double]] {
        var centroids = [vectors[Int(generator.next() % UInt64(vectors.count))]]
        while centroids.count < k {
            let weights = vectors.map { vector in centroids.map { squaredDistance(vector, $0) }.min() ?? 0 }
            let total = weights.reduce(0, +)
            guard total > 0 else {
                // Every remaining vector coincides with a centroid.
                centroids.append(vectors[Int(generator.next() % UInt64(vectors.count))])
                continue
            }
            var target = Double(generator.next() >> 11) / Double(1 << 53) * total
            var chosen = vectors.count - 1
            for (index, weight) in weights.enumerated() {
                target -= weight
                if target <= 0 { chosen = index; break }
            }
            centroids.append(vectors[chosen])
        }
        return centroids
    }

    /// Member means; an emptied cluster moves to the vector farthest from
    /// its assigned centroid, so k clusters always survive an iteration.
    static func updatedCentroids(_ vectors: [[Double]], assignment: [Int], previous: [[Double]]) -> [[Double]] {
        var sums = Array(repeating: Array(repeating: 0.0, count: 6), count: previous.count)
        var counts = Array(repeating: 0, count: previous.count)
        for (vector, cluster) in zip(vectors, assignment) {
            counts[cluster] += 1
            for axis in 0..<6 { sums[cluster][axis] += vector[axis] }
        }
        var centroids = previous
        for cluster in previous.indices {
            if counts[cluster] > 0 {
                centroids[cluster] = sums[cluster].map { $0 / Double(counts[cluster]) }
            } else if let farthest = vectors.indices.max(by: { lhs, rhs in
                squaredDistance(vectors[lhs], previous[assignment[lhs]])
                    < squaredDistance(vectors[rhs], previous[assignment[rhs]])
            }) {
                centroids[cluster] = vectors[farthest]
            }
        }
        return centroids
    }

    /// Mean of (b − a) / max(a, b), where a is a vector's distance to its
    /// own centroid and b to the nearest other centroid. O(n·k), so it
    /// scales to large sent-mail corpora.
    static func simplifiedSilhouette(_ vectors: [[Double]], assignment: [Int], centroids: [[Double]]) -> Double {
        guard centroids.count > 1, !vectors.isEmpty else { return 0 }
        var total = 0.0
        for (vector, cluster) in zip(vectors, assignment) {
            let own = squaredDistance(vector, centroids[cluster]).squareRoot()
            let other = centroids.indices.filter { $0 != cluster }
                .map { squaredDistance(vector, centroids[$0]).squareRoot() }.min() ?? 0
            let scale = max(own, other)
            total += scale > 0 ? (other - own) / scale : 0
        }
        return total / Double(vectors.count)
    }

    static func nearestCentroid(_ vector: [Double], _ centroids: [[Double]]) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for (index, centroid) in centroids.enumerated() {
            let distance = squaredDistance(vector, centroid)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    static func squaredDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        var sum = 0.0
        for axis in lhs.indices {
            let delta = lhs[axis] - rhs[axis]
            sum += delta * delta
        }
        return sum
    }

    static func axisValues(_ vector: [Double]) -> StyleAxisValues {
        StyleAxisValues(detail: vector[0], formality: vector[1], urgency: vector[2],
                        technicality: vector[3], warmth: vector[4], seriousness: vector[5])
    }
}

/// Deterministic 64-bit generator (SplitMix64) so discovery is reproducible.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Names a discovered style from the two slider axes that most set it apart
/// from the author's other writing in the language.
public enum StyleRegisterNamer {
    /// (low, high) adjective for each axis, in `StyleAxisValues.components`
    /// order: detail, formality, urgency, technicality, warmth, seriousness.
    static let adjectives: [(low: String, high: String)] = [
        ("Brief", "Detailed"),
        ("Casual", "Formal"),
        ("Relaxed", "Pressing"),
        ("Plain", "Technical"),
        ("Reserved", "Warm"),
        ("Playful", "Earnest"),
    ]

    /// Axes ordered by how far `centroid` departs from `reference`, largest
    /// first; ties keep axis order.
    static func rankedAxes(_ centroid: StyleAxisValues, reference: StyleAxisValues) -> [(axis: Int, delta: Double)] {
        zip(centroid.components, reference.components).enumerated()
            .map { (axis: $0.offset, delta: $0.element.0 - $0.element.1) }
            .sorted { abs($0.delta) == abs($1.delta) ? $0.axis < $1.axis : abs($0.delta) > abs($1.delta) }
    }

    static func adjective(axis: Int, delta: Double) -> String {
        delta < 0 ? adjectives[axis].low : adjectives[axis].high
    }

    /// A two-adjective name ("Brief casual") not already in `taken`
    /// (case-insensitive). `reference` is the language mean when the
    /// language has several styles, the neutral midpoint when it has one.
    public static func name(for centroid: StyleAxisValues, reference: StyleAxisValues, taken: Set<String>) -> String {
        let ranked = rankedAxes(centroid, reference: reference)
        let takenFolded = Set(taken.map { $0.lowercased() })
        var fallback: String?
        for second in 1..<ranked.count {
            for first in 0..<second {
                let name = adjective(axis: ranked[first].axis, delta: ranked[first].delta) + " "
                    + adjective(axis: ranked[second].axis, delta: ranked[second].delta).lowercased()
                fallback = fallback ?? name
                if !takenFolded.contains(name.lowercased()) { return name }
            }
        }
        let base = fallback ?? "Everyday"
        var index = 2
        while takenFolded.contains("\(base) \(index)".lowercased()) { index += 1 }
        return "\(base) \(index)"
    }

    /// Comparative forms for the provisional summary, keyed by adjective.
    static let comparatives: [String: String] = [
        "Brief": "briefer", "Detailed": "more detailed", "Casual": "more casual", "Formal": "more formal",
        "Relaxed": "more relaxed", "Pressing": "more pressing", "Plain": "plainer", "Technical": "more technical",
        "Reserved": "more reserved", "Warm": "warmer", "Playful": "more playful", "Earnest": "more earnest",
    ]

    /// Hover text shown until the describer writes one from sample emails.
    public static func provisionalSummary(for centroid: StyleAxisValues, reference: StyleAxisValues,
                                          isOnlyStyle: Bool, memberCount: Int) -> String {
        let words = rankedAxes(centroid, reference: reference).prefix(2)
            .map { adjective(axis: $0.axis, delta: $0.delta) }
        let emails = memberCount == 1 ? "sent email" : "sent emails"
        if isOnlyStyle {
            return "The usual voice across \(memberCount) \(emails): "
                + words.map { $0.lowercased() }.joined(separator: " and ") + "."
        }
        return "\(memberCount) \(emails) written "
            + words.map { comparatives[$0] ?? $0.lowercased() }.joined(separator: " and ")
            + " than the rest in this language."
    }
}
