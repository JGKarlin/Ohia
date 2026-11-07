// Packages/Sources/OhiaML/Layout/MeaningCommunityDetector.swift
//
// Leiden community detection over the persisted meaning kNN graph.
// Pure: receives nodes and edges, performs no IO, fully deterministic.

import Foundation
import simd

/// One message vector in the meaning graph: identity, layout position, and
/// namespaced sparse meaning features.
public struct MeaningGraphNode: Sendable {
    public let id: Int64
    public let xyz: SIMD3<Float>
    /// Namespaced sparse meaning features (already weighted); may be empty.
    public let features: [String: Float]
    public init(id: Int64, xyz: SIMD3<Float>, features: [String: Float]) {
        self.id = id
        self.xyz = xyz
        self.features = features
    }
}

/// An undirected weighted edge between two meaning-graph nodes.
public struct MeaningGraphEdge: Sendable {
    public let a: Int64
    public let b: Int64
    /// Base cosine similarity, expected in [0, 1].
    public let similarity: Float
    public init(a: Int64, b: Int64, similarity: Float) {
        self.a = a
        self.b = b
        self.similarity = similarity
    }
}

/// A community member with its normalized intra-community attachment.
public struct WeightedClusterMember: Sendable, Equatable {
    public let id: Int64
    /// Normalized intra-community attachment in (0, 1]; strongest member is 1.0.
    public let weight: Float
    public init(id: Int64, weight: Float) {
        self.id = id
        self.weight = weight
    }
}

/// One detected community, anchored in layout space at an actual member position.
public struct WeightedRawCluster: Sendable {
    /// Layout-space anchor: the member position minimizing summed distance to the other members (medoid).
    public let medoid: SIMD3<Float>
    /// Sorted by weight desc, ties by id asc.
    public let members: [WeightedClusterMember]
    public init(medoid: SIMD3<Float>, members: [WeightedClusterMember]) {
        self.medoid = medoid
        self.members = members
    }
}

public enum MeaningCommunityDetector {

    /// Fraction ceiling for the document-frequency filter: feature keys present
    /// on more than this fraction of nodes are corpus-relative stopwords and
    /// are dropped before edge weighting.
    private static let documentFrequencyCeiling = 0.35

    /// Local moving converges in a handful of sweeps; the cap only guards
    /// against pathological floating-point non-monotonicity and never binds in
    /// practice.
    private static let maxLocalMoveSweeps = 512

    /// Communities larger than this compute their medoid over a deterministic
    /// stride sample instead of the full quadratic scan.
    private static let exactMedoidLimit = 512

    public static func detect(
        nodes: [MeaningGraphNode],
        edges: [MeaningGraphEdge],
        minPoints: Int,
        maxClusters: Int,
        resolution: Float = 1.0,
        featureBoost: Float = 0.6,
        requiresSharedCanonicalTag: Bool = false
    ) -> [WeightedRawCluster] {
        guard minPoints > 0, maxClusters > 0, nodes.isEmpty == false, edges.isEmpty == false else {
            return []
        }
        let gamma = Double(resolution.isFinite ? resolution : 1)
        let boost = featureBoost.isFinite ? featureBoost : 0

        // MARK: Node indexing (deduplicate ids, contiguous ascending-id order)

        var firstOccurrence: [Int64: Int] = [:]
        firstOccurrence.reserveCapacity(nodes.count)
        for (index, node) in nodes.enumerated() where firstOccurrence[node.id] == nil {
            firstOccurrence[node.id] = index
        }
        let orderedInput = firstOccurrence.values.sorted { nodes[$0].id < nodes[$1].id }
        let nodeCount = orderedInput.count
        var ids = [Int64](repeating: 0, count: nodeCount)
        var positions = [SIMD3<Float>](repeating: .zero, count: nodeCount)
        var canonicalTags = [Set<String>](repeating: [], count: nodeCount)
        var indexByID: [Int64: Int] = [:]
        indexByID.reserveCapacity(nodeCount)
        for (contiguous, inputIndex) in orderedInput.enumerated() {
            ids[contiguous] = nodes[inputIndex].id
            positions[contiguous] = nodes[inputIndex].xyz
            canonicalTags[contiguous] = canonicalTagKeys(in: nodes[inputIndex].features)
            indexByID[nodes[inputIndex].id] = contiguous
        }

        // MARK: Document-frequency filter (language-agnostic stopwording)

        var documentFrequency: [String: Int] = [:]
        for inputIndex in orderedInput {
            for (key, value) in nodes[inputIndex].features where value.isFinite && value != 0 {
                documentFrequency[key, default: 0] += 1
            }
        }
        var featureIndex: [String: Int32] = [:]
        do {
            let surviving = documentFrequency
                .filter { Double($0.value) / Double(nodeCount) <= Self.documentFrequencyCeiling }
                .keys
                .sorted()
            featureIndex.reserveCapacity(surviving.count)
            for (offset, key) in surviving.enumerated() {
                featureIndex[key] = Int32(offset)
            }
        }

        // Per-node surviving features, L2-renormalized, as CSR runs sorted by key id.
        var featureStart = [Int](repeating: 0, count: nodeCount + 1)
        var featureKey: [Int32] = []
        var featureValue: [Float] = []
        for (contiguous, inputIndex) in orderedInput.enumerated() {
            var entries: [(key: Int32, value: Float)] = []
            entries.reserveCapacity(nodes[inputIndex].features.count)
            for (key, value) in nodes[inputIndex].features {
                guard value.isFinite, value != 0, let keyID = featureIndex[key] else { continue }
                entries.append((keyID, value))
            }
            entries.sort { $0.key < $1.key }
            let normSquared = entries.reduce(0.0) { $0 + Double($1.value) * Double($1.value) }
            if normSquared > 1e-12 {
                let scale = Float(1 / normSquared.squareRoot())
                for entry in entries {
                    featureKey.append(entry.key)
                    featureValue.append(entry.value * scale)
                }
            }
            featureStart[contiguous + 1] = featureKey.count
        }

        /// Sparse cosine over the DF-filtered, L2-normalized feature runs.
        /// Nodes with no surviving features contribute 0.
        func featureCosine(_ a: Int, _ b: Int) -> Float {
            var indexA = featureStart[a]
            let endA = featureStart[a + 1]
            var indexB = featureStart[b]
            let endB = featureStart[b + 1]
            guard indexA < endA, indexB < endB else { return 0 }
            var dot = 0.0
            while indexA < endA, indexB < endB {
                let keyA = featureKey[indexA]
                let keyB = featureKey[indexB]
                if keyA == keyB {
                    dot += Double(featureValue[indexA]) * Double(featureValue[indexB])
                    indexA += 1
                    indexB += 1
                } else if keyA < keyB {
                    indexA += 1
                } else {
                    indexB += 1
                }
            }
            return Float(min(max(dot, -1), 1))
        }

        // MARK: Edge cleanup and weighting

        // Drop self-edges and unknown endpoints; deduplicate keeping max similarity.
        var bestSimilarity: [UInt64: Float] = [:]
        bestSimilarity.reserveCapacity(edges.count)
        for edge in edges {
            guard edge.similarity.isFinite,
                  let a = indexByID[edge.a],
                  let b = indexByID[edge.b],
                  a != b,
                  requiresSharedCanonicalTag == false
                    || canonicalTags[a].isDisjoint(with: canonicalTags[b]) == false else { continue }
            let similarity = min(max(edge.similarity, 0), 1)
            let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
            if let existing = bestSimilarity[key] {
                if similarity > existing { bestSimilarity[key] = similarity }
            } else {
                bestSimilarity[key] = similarity
            }
        }
        guard bestSimilarity.isEmpty == false else { return [] }

        let sortedEdgeKeys = bestSimilarity.keys.sorted()
        var edgeA = [Int](repeating: 0, count: sortedEdgeKeys.count)
        var edgeB = [Int](repeating: 0, count: sortedEdgeKeys.count)
        var edgeWeight = [Float](repeating: 0, count: sortedEdgeKeys.count)
        for (offset, key) in sortedEdgeKeys.enumerated() {
            let a = Int(key >> 32)
            let b = Int(key & 0xFFFF_FFFF)
            let similarity = bestSimilarity[key] ?? 0
            let multiplier = max(0, 1 + boost * featureCosine(a, b))
            edgeA[offset] = a
            edgeB[offset] = b
            edgeWeight[offset] = similarity * multiplier
        }

        // MARK: Level-0 graph over non-isolated nodes (CSR)

        var degree = [Int](repeating: 0, count: nodeCount)
        for offset in edgeA.indices {
            degree[edgeA[offset]] += 1
            degree[edgeB[offset]] += 1
        }
        var compactIndex = [Int](repeating: -1, count: nodeCount)
        var compactToContiguous: [Int] = []
        compactToContiguous.reserveCapacity(nodeCount)
        for contiguous in 0..<nodeCount where degree[contiguous] > 0 {
            compactIndex[contiguous] = compactToContiguous.count
            compactToContiguous.append(contiguous)
        }
        let graphCount = compactToContiguous.count
        guard graphCount > 0 else { return [] }

        var adjStart = [Int](repeating: 0, count: graphCount + 1)
        for compact in 0..<graphCount {
            adjStart[compact + 1] = adjStart[compact] + degree[compactToContiguous[compact]]
        }
        var fillCursor = Array(adjStart[0..<graphCount])
        var adjTarget = [Int32](repeating: 0, count: edgeA.count * 2)
        var adjWeight = [Float](repeating: 0, count: edgeA.count * 2)
        for offset in edgeA.indices {
            let a = compactIndex[edgeA[offset]]
            let b = compactIndex[edgeB[offset]]
            let weight = edgeWeight[offset]
            adjTarget[fillCursor[a]] = Int32(b)
            adjWeight[fillCursor[a]] = weight
            fillCursor[a] += 1
            adjTarget[fillCursor[b]] = Int32(a)
            adjWeight[fillCursor[b]] = weight
            fillCursor[b] += 1
        }
        var strength = [Double](repeating: 0, count: graphCount)
        for compact in 0..<graphCount {
            var sum = 0.0
            for slot in adjStart[compact]..<adjStart[compact + 1] {
                sum += Double(adjWeight[slot])
            }
            strength[compact] = sum
        }
        let totalWeight = strength.reduce(0, +) // == 2m

        // MARK: Leiden

        var membership: [Int]
        var communityCount: Int
        if totalWeight > 0 {
            let inverseTotalWeight = 1 / totalWeight
            var graph = Graph(
                count: graphCount,
                adjStart: adjStart,
                adjTarget: adjTarget,
                adjWeight: adjWeight,
                strength: strength
            )
            var partition = Array(0..<graphCount)
            var flat = Array(0..<graphCount)
            var lastCommunityCount = graphCount
            while true {
                lastCommunityCount = localMove(
                    graph: graph,
                    gamma: gamma,
                    inverseTotalWeight: inverseTotalWeight,
                    community: &partition
                )
                // Fully discrete partition: no merges happened at this level.
                if lastCommunityCount == graph.count { break }
                let (refined, refinedCount) = refine(
                    graph: graph,
                    gamma: gamma,
                    inverseTotalWeight: inverseTotalWeight,
                    community: partition,
                    communityCount: lastCommunityCount
                )
                // All-singleton refinement: aggregation would be the identity,
                // so no further progress is possible.
                if refinedCount == graph.count { break }
                let (aggregated, seed) = aggregate(
                    graph: graph,
                    refined: refined,
                    refinedCount: refinedCount,
                    community: partition
                )
                for index in 0..<graphCount {
                    flat[index] = refined[flat[index]]
                }
                graph = aggregated
                partition = seed
            }
            membership = [Int](repeating: 0, count: graphCount)
            for index in 0..<graphCount {
                membership[index] = partition[flat[index]]
            }
            communityCount = lastCommunityCount
        } else {
            // Every retained edge weighs zero: no modularity signal, every node
            // stays a singleton community.
            membership = Array(0..<graphCount)
            communityCount = graphCount
        }

        // MARK: Assemble clusters

        var groups = [[Int]](repeating: [], count: communityCount)
        for compact in 0..<graphCount {
            groups[membership[compact]].append(compact)
        }
        var kept = groups.filter { $0.count >= minPoints }
        if requiresSharedCanonicalTag {
            // Pairwise edge gating is necessary but not sufficient: a node
            // tagged A+B can otherwise bridge an A population and a B
            // population into one Leiden community. Partition each detected
            // community into deterministic, non-overlapping groups whose
            // members all share one exact canonical tag. The largest
            // remaining tag population wins first; ties resolve by tag key.
            var coherent: [[Int]] = []
            for group in kept {
                var remaining = Set(group)
                let tagKeys = Set(group.flatMap { compact in
                    canonicalTags[compactToContiguous[compact]]
                }).sorted()
                while true {
                    let candidate = tagKeys.compactMap { tag -> (tag: String, members: [Int])? in
                        let members = group.filter { compact in
                            remaining.contains(compact)
                                && canonicalTags[compactToContiguous[compact]].contains(tag)
                        }
                        return members.count >= minPoints ? (tag, members) : nil
                    }.sorted { lhs, rhs in
                        if lhs.members.count != rhs.members.count {
                            return lhs.members.count > rhs.members.count
                        }
                        return lhs.tag < rhs.tag
                    }.first
                    guard let candidate else { break }
                    coherent.append(candidate.members)
                    remaining.subtract(candidate.members)
                }
            }
            kept = coherent
        }
        // Groups were filled scanning compact indices ascending, and compact
        // order preserves ascending node id, so members[0] is the smallest id.
        kept.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return ids[compactToContiguous[lhs[0]]] < ids[compactToContiguous[rhs[0]]]
        }
        if kept.count > maxClusters {
            kept.removeSubrange(maxClusters..<kept.count)
        }

        var clusters: [WeightedRawCluster] = []
        clusters.reserveCapacity(kept.count)
        for group in kept {
            let groupMembers = Set(group)
            var rawAttachment = [Double](repeating: 0, count: group.count)
            for (offset, compact) in group.enumerated() {
                var intra = 0.0
                for slot in adjStart[compact]..<adjStart[compact + 1] {
                    if groupMembers.contains(Int(adjTarget[slot])) {
                        intra += Double(adjWeight[slot])
                    }
                }
                let total = strength[compact]
                rawAttachment[offset] = total > 0 ? intra / total : 0
            }
            let maxAttachment = rawAttachment.max() ?? 0
            var members = [WeightedClusterMember](); members.reserveCapacity(group.count)
            for (offset, compact) in group.enumerated() {
                let weight: Float
                if maxAttachment > 0 {
                    weight = Float(min(max(rawAttachment[offset] / maxAttachment, 0.05), 1))
                } else {
                    weight = 1
                }
                members.append(WeightedClusterMember(id: ids[compactToContiguous[compact]], weight: weight))
            }
            members.sort { lhs, rhs in
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                return lhs.id < rhs.id
            }
            // group is ascending by member id already, as medoid sampling requires.
            let memberPositions = group.map { positions[compactToContiguous[$0]] }
            clusters.append(WeightedRawCluster(medoid: medoid(of: memberPositions), members: members))
        }
        return clusters
    }

    /// Exact preferred-label identities emitted by `ClusterDetector` at the
    /// embedding seam. Soft `meaning:` tokens are intentionally excluded:
    /// sharing a generic word may affect proximity, but cannot establish
    /// semantic-cluster membership.
    public static func canonicalTagKeys(in features: [String: Float]) -> Set<String> {
        Set(features.compactMap { key, value in
            guard key.hasPrefix("tag:"), value.isFinite, value > 0 else { return nil }
            return key
        })
    }

    public static func sharesCanonicalTag(
        _ lhs: [String: Float],
        _ rhs: [String: Float]
    ) -> Bool {
        canonicalTagKeys(in: lhs).isDisjoint(with: canonicalTagKeys(in: rhs)) == false
    }

    // MARK: - Leiden internals

    private struct Graph {
        var count: Int
        var adjStart: [Int]
        var adjTarget: [Int32]
        var adjWeight: [Float]
        /// Node strength (sum of incident weights; self-loop weight, which is
        /// already both-orders-counted, contributes once). Invariant across
        /// levels: sum(strength) == 2m.
        var strength: [Double]
    }

    /// Louvain-style sequential local moving in ascending node order. Moves a
    /// node only on a strict modularity gain; among equally best candidates the
    /// smallest community id wins. Renumbers communities contiguously by first
    /// appearance and returns the community count.
    private static func localMove(
        graph: Graph,
        gamma: Double,
        inverseTotalWeight: Double,
        community: inout [Int]
    ) -> Int {
        let count = graph.count
        var communityStrength = [Double](repeating: 0, count: count)
        for node in 0..<count {
            communityStrength[community[node]] += graph.strength[node]
        }
        var edgeToCommunity = [Double](repeating: 0, count: count)
        var stamp = [Int](repeating: -1, count: count)
        var touched: [Int] = []
        touched.reserveCapacity(64)
        var epoch = 0

        var sweep = 0
        var changed = true
        while changed, sweep < Self.maxLocalMoveSweeps {
            changed = false
            sweep += 1
            for node in 0..<count {
                let old = community[node]
                let nodeStrength = graph.strength[node]
                communityStrength[old] -= nodeStrength

                epoch += 1
                touched.removeAll(keepingCapacity: true)
                stamp[old] = epoch
                edgeToCommunity[old] = 0
                touched.append(old)
                for slot in graph.adjStart[node]..<graph.adjStart[node + 1] {
                    let target = Int(graph.adjTarget[slot])
                    if target == node { continue } // self-loops move with the node
                    let candidate = community[target]
                    if stamp[candidate] != epoch {
                        stamp[candidate] = epoch
                        edgeToCommunity[candidate] = 0
                        touched.append(candidate)
                    }
                    edgeToCommunity[candidate] += Double(graph.adjWeight[slot])
                }

                var bestCommunity = old
                var bestScore = edgeToCommunity[old]
                    - gamma * nodeStrength * communityStrength[old] * inverseTotalWeight
                for candidate in touched where candidate != old {
                    let score = edgeToCommunity[candidate]
                        - gamma * nodeStrength * communityStrength[candidate] * inverseTotalWeight
                    if score > bestScore
                        || (score == bestScore && bestCommunity != old && candidate < bestCommunity) {
                        bestScore = score
                        bestCommunity = candidate
                    }
                }
                communityStrength[bestCommunity] += nodeStrength
                if bestCommunity != old {
                    community[node] = bestCommunity
                    changed = true
                }
            }
        }

        var renumber = [Int](repeating: -1, count: count)
        var next = 0
        for node in 0..<count {
            let label = community[node]
            if renumber[label] == -1 {
                renumber[label] = next
                next += 1
            }
            community[node] = renumber[label]
        }
        return next
    }

    /// Leiden refinement: within each local-moving community, singleton nodes
    /// greedily merge into well-connected sub-communities on strictly positive
    /// modularity gain (deterministic θ→0 variant; ties by smallest sub-community
    /// id). Returns the refined assignment renumbered by first appearance.
    private static func refine(
        graph: Graph,
        gamma: Double,
        inverseTotalWeight: Double,
        community: [Int],
        communityCount: Int
    ) -> (assignment: [Int], count: Int) {
        let count = graph.count
        var parentStrength = [Double](repeating: 0, count: communityCount)
        for node in 0..<count {
            parentStrength[community[node]] += graph.strength[node]
        }

        // Edge weight from each node into its parent community (self-loops excluded).
        var interiorWeight = [Double](repeating: 0, count: count)
        for node in 0..<count {
            let parent = community[node]
            var sum = 0.0
            for slot in graph.adjStart[node]..<graph.adjStart[node + 1] {
                let target = Int(graph.adjTarget[slot])
                if target != node, community[target] == parent {
                    sum += Double(graph.adjWeight[slot])
                }
            }
            interiorWeight[node] = sum
        }

        var refined = Array(0..<count)
        var refinedStrength = graph.strength
        var refinedExterior = interiorWeight // singleton: E({v}, C\v) == interior weight
        var refinedSize = [Int](repeating: 1, count: count)

        var edgeToRefined = [Double](repeating: 0, count: count)
        var stamp = [Int](repeating: -1, count: count)
        var touched: [Int] = []
        touched.reserveCapacity(64)

        for node in 0..<count {
            guard refinedSize[refined[node]] == 1 else { continue }
            let parent = community[node]
            let nodeStrength = graph.strength[node]
            let remainder = parentStrength[parent] - nodeStrength
            // Only nodes well-connected to their parent community may merge.
            guard interiorWeight[node] >= gamma * nodeStrength * remainder * inverseTotalWeight else {
                continue
            }

            touched.removeAll(keepingCapacity: true)
            for slot in graph.adjStart[node]..<graph.adjStart[node + 1] {
                let target = Int(graph.adjTarget[slot])
                guard target != node, community[target] == parent else { continue }
                let sub = refined[target]
                if stamp[sub] != node {
                    stamp[sub] = node
                    edgeToRefined[sub] = 0
                    touched.append(sub)
                }
                edgeToRefined[sub] += Double(graph.adjWeight[slot])
            }

            var bestSub = -1
            var bestGain = 0.0
            for sub in touched {
                let subStrength = refinedStrength[sub]
                let wellConnected = refinedExterior[sub]
                    >= gamma * subStrength * (parentStrength[parent] - subStrength) * inverseTotalWeight
                guard wellConnected else { continue }
                let gain = edgeToRefined[sub] - gamma * nodeStrength * subStrength * inverseTotalWeight
                guard gain > 0 else { continue }
                if bestSub == -1 || gain > bestGain || (gain == bestGain && sub < bestSub) {
                    bestSub = sub
                    bestGain = gain
                }
            }
            if bestSub >= 0 {
                refinedSize[refined[node]] = 0
                refined[node] = bestSub
                refinedSize[bestSub] += 1
                refinedExterior[bestSub] += interiorWeight[node] - 2 * edgeToRefined[bestSub]
                refinedStrength[bestSub] += nodeStrength
            }
        }

        var renumber = [Int](repeating: -1, count: count)
        var next = 0
        var out = [Int](repeating: 0, count: count)
        for node in 0..<count {
            let sub = refined[node]
            if renumber[sub] == -1 {
                renumber[sub] = next
                next += 1
            }
            out[node] = renumber[sub]
        }
        return (out, next)
    }

    /// Collapses each refined community into one aggregated node. Internal
    /// weight lands on the self-loop with both orders counted, keeping node
    /// strengths and 2m invariant. The seed partition assigns each aggregated
    /// node the local-moving community of its members.
    private static func aggregate(
        graph: Graph,
        refined: [Int],
        refinedCount: Int,
        community: [Int]
    ) -> (graph: Graph, seedPartition: [Int]) {
        let count = graph.count
        var memberStart = [Int](repeating: 0, count: refinedCount + 1)
        for node in 0..<count {
            memberStart[refined[node] + 1] += 1
        }
        for sub in 1...refinedCount {
            memberStart[sub] += memberStart[sub - 1]
        }
        var fillCursor = Array(memberStart[0..<refinedCount])
        var members = [Int](repeating: 0, count: count)
        for node in 0..<count {
            let sub = refined[node]
            members[fillCursor[sub]] = node
            fillCursor[sub] += 1
        }

        var adjStart = [Int](repeating: 0, count: refinedCount + 1)
        var adjTarget: [Int32] = []
        var adjWeight: [Float] = []
        adjTarget.reserveCapacity(graph.adjTarget.count)
        adjWeight.reserveCapacity(graph.adjWeight.count)
        var strength = [Double](repeating: 0, count: refinedCount)
        var seed = [Int](repeating: 0, count: refinedCount)

        var accumulated = [Double](repeating: 0, count: refinedCount)
        var stamp = [Int](repeating: -1, count: refinedCount)
        var touched: [Int] = []
        touched.reserveCapacity(64)

        for sub in 0..<refinedCount {
            touched.removeAll(keepingCapacity: true)
            var subStrength = 0.0
            for slot in memberStart[sub]..<memberStart[sub + 1] {
                let node = members[slot]
                subStrength += graph.strength[node]
                for adj in graph.adjStart[node]..<graph.adjStart[node + 1] {
                    let targetSub = refined[Int(graph.adjTarget[adj])]
                    if stamp[targetSub] != sub {
                        stamp[targetSub] = sub
                        accumulated[targetSub] = 0
                        touched.append(targetSub)
                    }
                    accumulated[targetSub] += Double(graph.adjWeight[adj])
                }
            }
            strength[sub] = subStrength
            seed[sub] = community[members[memberStart[sub]]]
            touched.sort()
            for targetSub in touched {
                adjTarget.append(Int32(targetSub))
                adjWeight.append(Float(accumulated[targetSub]))
            }
            adjStart[sub + 1] = adjTarget.count
        }
        let aggregated = Graph(
            count: refinedCount,
            adjStart: adjStart,
            adjTarget: adjTarget,
            adjWeight: adjWeight,
            strength: strength
        )
        return (aggregated, seed)
    }

    // MARK: - Medoid

    /// Exact medoid for small member sets; deterministic stride sample beyond
    /// `exactMedoidLimit`. `memberPositions` must be ordered by ascending
    /// member id; ties resolve to the earliest (smallest-id) position.
    /// Public so the cluster-detection worker can refresh stored medoids in
    /// place from current member positions without re-running detection.
    public static func medoid(of memberPositions: [SIMD3<Float>]) -> SIMD3<Float> {
        let count = memberPositions.count
        guard let first = memberPositions.first else { return .zero }
        guard count > 1 else { return first }
        let sample: [SIMD3<Float>]
        if count <= Self.exactMedoidLimit {
            sample = memberPositions
        } else {
            let stride = (count + Self.exactMedoidLimit - 1) / Self.exactMedoidLimit
            var selected: [SIMD3<Float>] = []
            selected.reserveCapacity(count / stride + 1)
            var index = 0
            while index < count {
                selected.append(memberPositions[index])
                index += stride
            }
            sample = selected
        }
        var bestIndex = 0
        var bestSum = Double.greatestFiniteMagnitude
        for candidate in 0..<sample.count {
            var sum = 0.0
            for other in 0..<sample.count where other != candidate {
                sum += Double(simd_distance(sample[candidate], sample[other]))
            }
            if sum < bestSum {
                bestSum = sum
                bestIndex = candidate
            }
        }
        return sample[bestIndex]
    }
}
