import Foundation
import simd
import OhiaCore
import OhiaML

public struct ClusterDetectPayload: Codable, Sendable {
    public let frame: FrameKey
    public let semanticTargetClusters: Int?

    public init(frame: FrameKey, semanticTargetClusters: Int? = nil) {
        self.frame = frame
        self.semanticTargetClusters = semanticTargetClusters.map(Self.clampedMeaningTargetClusters)
    }

    public static let meaningTargetClustersDefaultsKey = "constellationMeaningClusterTargetCount"
    public static let noMeaningTargetClusters = 0
    public static let onboardingMeaningTargetClusters = noMeaningTargetClusters
    public static let defaultMeaningTargetClusters = 12
    public static let meaningTargetClustersRange = 0...32
    /// Meaning cluster generation always uses the fine, stable partition.
    /// The user-facing slider only caps how many ranked clusters render.
    public static let stableMeaningTargetClusters = meaningTargetClustersRange.upperBound

    public static func clampedMeaningTargetClusters(_ value: Int) -> Int {
        min(max(value, meaningTargetClustersRange.lowerBound), meaningTargetClustersRange.upperBound)
    }

    public static var preferredMeaningTargetClusters: Int {
        let raw = OhiaSharedDefaults.store.object(forKey: meaningTargetClustersDefaultsKey) as? Double
        guard let raw, raw.isFinite else {
            return defaultMeaningTargetClusters
        }
        return clampedMeaningTargetClusters(Int(raw.rounded()))
    }
}

public enum ClusterDetectionOutcome: Sendable, Equatable {
    case published
    case cancelled
}

private struct MeaningScopeCancelled: Error {}

/// Resolves authoritative semantic-tag identities for message ids. The live
/// worker supplies current `SemanticTagProjection.tagID` values from SwiftData.
public typealias MeaningCanonicalTagIdentityProvider = @MainActor @Sendable (
    _ messageIDs: [String]
) throws -> [String: [String]]

/// Drains `.clusterDetect` jobs for the Meaning frame, the only frame with a
/// cluster runner (`ClusterDetectSeeder.isRunnable`). It runs Leiden community
/// detection over a summary-vector kNN graph (`MeaningCommunityDetector`),
/// on demand from the active Meaning lens after the complete current corpus
/// settles. A corpus fingerprint preserves an established snapshot across
/// passes and selects incremental assignment or a full refit as appropriate.
/// All persistence goes through `VectorClusterStore.upsertClusters`, which
/// preserves cluster ids (and labels) across runs via member-overlap matching.
public actor ClusterDetectionWorker {

    /// Neighbor count for the Meaning kNN graph and for incremental
    /// assignment queries.
    static let meaningNeighborTopK = 10
    /// kNN edges below this cosine similarity are dropped from the graph.
    static let meaningEdgeSimilarityFloor: Float = 0.30
    /// Incremental assignment runs only while the per-run new-vector count
    /// stays at or below this fraction of the corpus.
    static let incrementalAddFractionCeiling = 0.05
    /// ... and while adds accumulated since the last full refit stay at or
    /// below this fraction of the corpus.
    static let accumulatedAddFractionCeiling = 0.10
    /// A corpus that shrank by more than this fraction since the last full
    /// refit forces a new full refit rather than the incremental reconcile.
    /// The incremental path only *adds* new vectors to existing clusters, so a
    /// large deletion would otherwise leave a stale partition (and un-re-anchored
    /// medoids) intact until the full-refit age expires.
    static let shrinkRefitFractionCeiling = 0.05
    /// ... and while the last full refit is younger than this.
    static let fullRefitMaxAge: TimeInterval = 6 * 60 * 60
    /// A new vector joins a cluster only when that cluster holds at least
    /// this share of the vector's summed edge weight toward already-clustered
    /// neighbors.
    static let incrementalAssignmentMinimumShare = 0.5
    /// ... and only when at least this many of its retained neighbors are
    /// already clustered.
    static let incrementalMinimumClusteredNeighbors = 2
    static let meaningResolution: Float = 1.0
    static let meaningFeatureBoost: Float = 0.6

    private static let hydrateChunkSize = 600

    private let vectorStore: VectorStore
    private let frameLayoutStore: VectorFrameLayoutStore
    private let clusterStore: VectorClusterStore
    private let featureStore: VectorMeaningFeatureStore
    private let knnBuilder: KNNBuilder
    private let meaningScopeContinuation: @Sendable () -> Bool
    private let meaningPublicationContinuation: @MainActor @Sendable (String) -> Bool
    private let meaningCanonicalTagIdentityProvider: MeaningCanonicalTagIdentityProvider

    /// Throws when Metal is unavailable (the kNN builder requires it),
    /// mirroring `LayoutOrchestrator`'s construction contract so callers fall
    /// back to running without cluster detection.
    public init(
        vectorStore: VectorStore,
        frameLayoutStore: VectorFrameLayoutStore,
        clusterStore: VectorClusterStore,
        featureStore: VectorMeaningFeatureStore,
        meaningScopeContinuation: @escaping @Sendable () -> Bool = { true },
        meaningPublicationContinuation: @escaping @MainActor @Sendable (String) -> Bool = { _ in true },
        meaningCanonicalTagIdentityProvider: @escaping MeaningCanonicalTagIdentityProvider = { _ in [:] }
    ) throws {
        self.vectorStore = vectorStore
        self.frameLayoutStore = frameLayoutStore
        self.clusterStore = clusterStore
        self.featureStore = featureStore
        self.meaningScopeContinuation = meaningScopeContinuation
        self.meaningPublicationContinuation = meaningPublicationContinuation
        self.meaningCanonicalTagIdentityProvider = meaningCanonicalTagIdentityProvider
        self.knnBuilder = try KNNBuilder()
    }

    /// Runs one Meaning membership pass and persists it under
    /// `FrameKey.meaning`.
    @discardableResult
    public func run(
        minPoints: Int = 4,
        semanticTargetClusters: Int? = nil
    ) async throws -> ClusterDetectionOutcome {
        do {
            try await runMeaningClusters(
                frame: .meaning,
                minPoints: minPoints,
                semanticTargetClusters: semanticTargetClusters
            )
            return .published
        } catch is MeaningScopeCancelled {
            return .cancelled
        }
    }

    // MARK: - Meaning frame

    private func runMeaningClusters(
        frame: FrameKey,
        minPoints: Int,
        semanticTargetClusters: Int?
    ) async throws {
        try requireMeaningScope()
        let requestedClusterCount = semanticTargetClusters.map(ClusterDetectPayload.clampedMeaningTargetClusters)
            ?? ClusterDetectPayload.stableMeaningTargetClusters
        let raw = try vectorStore.placedContextSummaryVectorsRaw()
        // `placedContextSummaryVectorsRaw` orders by vector_id ascending — the
        // order the fingerprint (and the medoid sampling downstream) requires.
        let ids = raw.map(\.id)
        let fingerprint = Self.corpusFingerprint(ascendingVectorIds: ids)
        guard raw.count >= minPoints, requestedClusterCount > 0 else {
            try await requireMeaningPublication(fingerprint: fingerprint)
            try clusterStore.upsertClusters(frame: frame, clusters: [])
            try clusterStore.deleteClusterRun(frame: frame)
            return
        }

        let previousRun = try clusterStore.clusterRun(frame: frame)

        if let previousRun, previousRun.inputFingerprint == fingerprint {
            // Same corpus: membership is current; only re-anchor medoids so
            // stored cluster anchors keep tracking the settling layout.
            try refreshStoredMedoids(frame: frame, raw: raw)
            return
        }

        if let previousRun,
           let previousMaxVectorId = Self.maxVectorId(fromFingerprint: previousRun.inputFingerprint) {
            // Vector ids are AUTOINCREMENT, so ids above the previous run's
            // maximum are exactly the never-before-seen vectors. Vectors the
            // previous run saw but left unclustered stay unclustered until
            // the next full refit.
            let newRaw = raw.filter { $0.id > previousMaxVectorId }
            let withinPerRunBudget =
                Double(newRaw.count) <= Self.incrementalAddFractionCeiling * Double(raw.count)
            let withinAccumulatedBudget =
                Double(previousRun.incrementalAdds + newRaw.count)
                    <= Self.accumulatedAddFractionCeiling * Double(raw.count)
            let fullRefitFresh =
                Date().timeIntervalSince(previousRun.fullRefitAt) < Self.fullRefitMaxAge
            // A significant corpus shrink (bulk deletion) can't be reconciled by
            // the add-only incremental path; force a full refit so the partition
            // and medoids reflect the reduced corpus.
            let withinShrinkBudget: Bool
            if let previousCount = Self.corpusCount(fromFingerprint: previousRun.inputFingerprint),
               previousCount > 0 {
                withinShrinkBudget = Double(previousCount - raw.count)
                    <= Self.shrinkRefitFractionCeiling * Double(previousCount)
            } else {
                withinShrinkBudget = true
            }
            if withinPerRunBudget, withinAccumulatedBudget, fullRefitFresh, withinShrinkBudget {
                try await runIncrementalMeaningAssignment(
                    frame: frame,
                    raw: raw,
                    newRaw: newRaw,
                    fingerprint: fingerprint,
                    previousRun: previousRun
                )
                return
            }
        }

        try await runFullMeaningRefit(
            frame: frame,
            raw: raw,
            minPoints: minPoints,
            fingerprint: fingerprint
        )
    }

    /// Fingerprint-skip path: recompute each stored cluster's medoid over its
    /// current member positions and update the rows in place. Membership,
    /// labels, detection timestamps, and the run record stay untouched.
    private func refreshStoredMedoids(frame: FrameKey, raw: [VectorStore.RawVec]) throws {
        try requireMeaningScope()
        let membership = try clusterStore.vectorToCluster(frame: frame)
        guard membership.isEmpty == false else { return }

        var membersByCluster: [Int64: [Int64]] = [:]
        for (vectorId, clusterId) in membership {
            membersByCluster[clusterId, default: []].append(vectorId)
        }
        let memberIds = Array(membership.keys)
        let framePositions = try frameLayoutStore.positionsForFrame(frame, vectorIds: memberIds)
        var basePositions: [Int64: SIMD3<Float>] = [:]
        basePositions.reserveCapacity(raw.count)
        for vector in raw {
            if let position = vector.position { basePositions[vector.id] = position }
        }

        var anchors: [(clusterId: Int64, medoid: SIMD3<Float>)] = []
        anchors.reserveCapacity(membersByCluster.count)
        for clusterId in membersByCluster.keys.sorted() {
            // Ascending member-id order is the deterministic ordering
            // `MeaningCommunityDetector.medoid` expects for tie-breaking and
            // stride sampling.
            let positions = membersByCluster[clusterId, default: []]
                .sorted()
                .compactMap { framePositions[$0] ?? basePositions[$0] }
            guard positions.isEmpty == false else { continue }
            anchors.append((clusterId, MeaningCommunityDetector.medoid(of: positions)))
        }
        try requireMeaningScope()
        try clusterStore.updateClusterAnchors(anchors)
    }

    /// Incremental path: kNN the new summary vectors against the whole
    /// summary corpus and attach each one to the cluster that dominates its
    /// clustered neighborhood. Vectors without a dominant cluster stay
    /// unclustered until the next full refit.
    private func runIncrementalMeaningAssignment(
        frame: FrameKey,
        raw: [VectorStore.RawVec],
        newRaw: [VectorStore.RawVec],
        fingerprint: String,
        previousRun: ClusterRunRecord
    ) async throws {
        try requireMeaningScope()
        var inserts: [(clusterId: Int64, vectorId: Int64, weight: Float)] = []
        if newRaw.isEmpty == false {
            let membership = try clusterStore.vectorToCluster(frame: frame)
            let neighborsBySource = try knnBuilder.buildKNNBatch(
                newVectors: newRaw.map { ($0.id, $0.vec) },
                existing: raw.map { ($0.id, $0.vec) },
                topK: Self.meaningNeighborTopK
            )
            // Incremental attachment must honor the destination cluster's
            // canonical identity, not merely a tag shared with one bridge
            // neighbor. Load the established membership so we can intersect
            // exact tags across every member of each cluster.
            let newFeatureRows = try await canonicalMeaningFeatureRows(
                vectorIds: newRaw.map(\.id)
            )
            try featureStore.upsertBatch(newFeatureRows)
            let featureIds = Array(Set(newRaw.map(\.id) + membership.keys))
            let featuresById = try featureStore.features(for: featureIds)
            var sharedTagsByCluster = Self.sharedCanonicalTagsByCluster(
                membership: membership,
                featuresById: featuresById
            )
            try requireMeaningScope()
            for vector in newRaw {
                guard let neighbors = neighborsBySource[vector.id] else { continue }
                let sourceFeatures = featuresById[vector.id] ?? [:]
                let sourceTags = MeaningCommunityDetector.canonicalTagKeys(in: sourceFeatures)
                var weightByCluster: [Int64: Double] = [:]
                var totalClusteredWeight = 0.0
                var clusteredNeighborCount = 0
                for neighbor in neighbors {
                    guard neighbor.targetId != vector.id,
                          neighbor.similarity >= Self.meaningEdgeSimilarityFloor,
                          let clusterId = membership[neighbor.targetId],
                          let clusterTags = sharedTagsByCluster[clusterId],
                          clusterTags.isDisjoint(with: sourceTags) == false else { continue }
                    clusteredNeighborCount += 1
                    weightByCluster[clusterId, default: 0] += Double(neighbor.similarity)
                    totalClusteredWeight += Double(neighbor.similarity)
                }
                guard clusteredNeighborCount >= Self.incrementalMinimumClusteredNeighbors,
                      totalClusteredWeight > 0 else { continue }
                // Deterministic argmax: highest summed weight, ties to the
                // smaller cluster id.
                guard let best = weightByCluster.max(by: { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value < rhs.value }
                    return lhs.key > rhs.key
                }) else { continue }
                let share = best.value / totalClusteredWeight
                guard share >= Self.incrementalAssignmentMinimumShare else { continue }
                inserts.append((
                    clusterId: best.key,
                    vectorId: vector.id,
                    weight: Float(min(max(share, 0), 1))
                ))
                // This batch is ordered by vector id. Narrow the destination
                // identity immediately so a later competing attachment cannot
                // leave the final cluster with no tag shared by every member.
                if let current = sharedTagsByCluster[best.key] {
                    sharedTagsByCluster[best.key] = current.intersection(sourceTags)
                }
            }
        }
        // Runs even with no inserts: the member-count refresh inside
        // reconciles counts after removal-only corpus changes (cascade
        // deletions), which also arrive here as a fingerprint change.
        try await requireMeaningPublication(fingerprint: fingerprint)
        try clusterStore.insertMembers(inserts)
        try clusterStore.recordClusterRun(ClusterRunRecord(
            frameKey: frame,
            inputFingerprint: fingerprint,
            fullRefitAt: previousRun.fullRefitAt,
            incrementalAdds: previousRun.incrementalAdds + newRaw.count
        ))
    }

    /// Exact tag identity of each established cluster. A tag is retained only
    /// when every current member carries it; missing or stale feature rows
    /// collapse the intersection to empty, conservatively leaving new vectors
    /// unclustered until the next full refit repairs the feature seam.
    static func sharedCanonicalTagsByCluster(
        membership: [Int64: Int64],
        featuresById: [Int64: [String: Float]]
    ) -> [Int64: Set<String>] {
        var shared: [Int64: Set<String>] = [:]
        for vectorId in membership.keys.sorted() {
            guard let clusterId = membership[vectorId] else { continue }
            let tags = MeaningCommunityDetector.canonicalTagKeys(
                in: featuresById[vectorId] ?? [:]
            )
            if let current = shared[clusterId] {
                shared[clusterId] = current.intersection(tags)
            } else {
                shared[clusterId] = tags
            }
        }
        return shared
    }

    /// Rebuilds the sparse cache from the summary payload plus current
    /// authoritative tag UUIDs. Full refits refresh every row; incremental
    /// runs refresh every new row before attachment.
    private func canonicalMeaningFeatureRows(
        vectorIds: [Int64]
    ) async throws -> [(vectorId: Int64, features: [String: Float])] {
        guard !vectorIds.isEmpty else { return [] }
        var records: [VectorRecord] = []
        records.reserveCapacity(vectorIds.count)
        for start in stride(from: 0, to: vectorIds.count, by: Self.hydrateChunkSize) {
            try requireMeaningScope()
            let chunk = Array(
                vectorIds[start..<min(start + Self.hydrateChunkSize, vectorIds.count)]
            )
            records.append(contentsOf: try vectorStore.hydrate(vectorIds: chunk))
        }

        try requireMeaningScope()
        let messageIDs = Array(Set(records.map { $0.messageId.lowercased() })).sorted()
        let provided = try await meaningCanonicalTagIdentityProvider(messageIDs)
        var identitiesByMessageID: [String: [String]] = [:]
        identitiesByMessageID.reserveCapacity(provided.count)
        for (messageID, tagIDs) in provided {
            identitiesByMessageID[messageID.lowercased()] = tagIDs
        }
        try requireMeaningScope()
        return records.map { record in
            (
                vectorId: record.vectorId,
                features: ClusterDetector.meaningFeatures(
                    from: record.textPayload,
                    canonicalSemanticTagIDs: identitiesByMessageID[
                        record.messageId.lowercased()
                    ] ?? []
                )
            )
        }
    }

    /// Full refit: refresh authoritative meaning features, build the summary-
    /// only kNN graph, run Leiden community detection, and reconcile
    /// the persisted clusters (ids and labels survive via Jaccard matching in
    /// `upsertClusters`).
    private func runFullMeaningRefit(
        frame: FrameKey,
        raw: [VectorStore.RawVec],
        minPoints: Int,
        fingerprint: String
    ) async throws {
        try requireMeaningScope()
        let ids = raw.map(\.id)

        // Refresh every row. This replaces raw labels with authoritative tag
        // UUIDs and also repairs stale, missing, or malformed cache entries.
        let refreshedFeatureRows = try await canonicalMeaningFeatureRows(vectorIds: ids)
        try featureStore.upsertBatch(refreshedFeatureRows)
        let featuresById = try featureStore.features(for: ids)

        let framePositions = try frameLayoutStore.positionsForFrame(frame, vectorIds: ids)
        let nodes: [MeaningGraphNode] = raw.map { vector in
            MeaningGraphNode(
                id: vector.id,
                xyz: framePositions[vector.id] ?? vector.position ?? .zero,
                features: featuresById[vector.id] ?? [:]
            )
        }

        var edges: [MeaningGraphEdge] = []
        edges.reserveCapacity(raw.count * Self.meaningNeighborTopK)
        try knnBuilder.buildAllKNNBatches(
            vectors: raw.map { ($0.id, $0.vec) },
            topK: Self.meaningNeighborTopK
        ) { batch, _, _ in
            try self.requireMeaningScope()
            for row in batch {
                for neighbor in row.neighbors where neighbor.similarity >= Self.meaningEdgeSimilarityFloor {
                    edges.append(MeaningGraphEdge(
                        a: neighbor.sourceId,
                        b: neighbor.targetId,
                        similarity: neighbor.similarity
                    ))
                }
            }
        }

        try requireMeaningScope()
        let communities = MeaningCommunityDetector.detect(
            nodes: nodes,
            edges: edges,
            minPoints: minPoints,
            // The UI count is a display limit, not a membership limit.
            // Truncating here would silently strand valid tag communities.
            maxClusters: max(1, nodes.count),
            resolution: Self.meaningResolution,
            featureBoost: Self.meaningFeatureBoost,
            requiresSharedCanonicalTag: true
        )
        try await requireMeaningPublication(fingerprint: fingerprint)
        try clusterStore.upsertClusters(
            frame: frame,
            clusters: communities.map { community in
                ClusterUpsert(
                    medoid: community.medoid,
                    members: community.members.map {
                        ClusterMemberUpsert(vectorId: $0.id, weight: $0.weight)
                    }
                )
            }
        )
        try clusterStore.recordClusterRun(ClusterRunRecord(
            frameKey: frame,
            inputFingerprint: fingerprint,
            fullRefitAt: Date(),
            incrementalAdds: 0
        ))
    }

    private func requireMeaningScope() throws {
        guard meaningScopeContinuation() else {
            throw MeaningScopeCancelled()
        }
    }

    private func requireMeaningPublication(fingerprint: String) async throws {
        try requireMeaningScope()
        guard await meaningPublicationContinuation(fingerprint) else {
            throw MeaningScopeCancelled()
        }
        // Scope can change while the live corpus gate crosses to MainActor.
        // Re-check at the final safe boundary immediately before persistence.
        try requireMeaningScope()
    }

    // MARK: - Fingerprint

    /// Deterministic corpus fingerprint: FNV-1a 64 over the ascending
    /// vector-id list (little-endian bytes), combined with the count and the
    /// maximum id — "v2:<count>:<hash>:<maxId>". Version 2 forces one full
    /// refit for the canonical-tag membership model. Every component is a pure
    /// function of the id list; the trailing max id lets the incremental path
    /// recover which ids are genuinely new without persisting the list.
    public static func corpusFingerprint(ascendingVectorIds ids: [Int64]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for id in ids {
            var value = UInt64(bitPattern: id)
            for _ in 0..<8 {
                hash = (hash ^ (value & 0xFF)) &* 0x0000_0100_0000_01B3
                value >>= 8
            }
        }
        let maxId = ids.last ?? 0
        return "v2:\(ids.count):\(String(hash, radix: 16)):\(maxId)"
    }

    /// Recovers the max-vector-id component from a stored fingerprint.
    /// Returns nil for unparseable/foreign formats, which forces a full refit.
    static func maxVectorId(fromFingerprint fingerprint: String) -> Int64? {
        let parts = fingerprint.split(separator: ":")
        guard parts.count == 4, parts[0] == "v2" else { return nil }
        return Int64(parts[3])
    }

    /// Recovers the corpus-count component from a stored fingerprint.
    /// Returns nil for unparseable/foreign formats.
    static func corpusCount(fromFingerprint fingerprint: String) -> Int? {
        let parts = fingerprint.split(separator: ":")
        guard parts.count == 4, parts[0] == "v2" else { return nil }
        return Int(parts[1])
    }
}
