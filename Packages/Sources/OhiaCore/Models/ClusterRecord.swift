import Foundation
import simd

/// A detected cluster persisted in `vector_clusters`; labels land later via
/// `ClusterSummarizer`. Cluster ids are stable across re-clustering runs —
/// `VectorClusterStore.upsertClusters` matches by member overlap.
public struct ClusterRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let frameKey: FrameKey
    /// Layout-space anchor of the cluster: the medoid — an actual member
    /// position — of the Meaning community, refreshed in place as the layout
    /// settles.
    public let centroid: SIMD3<Float>
    public let memberCount: Int
    public let detectedAt: Date
    public let label: String?

    public init(id: Int64, frameKey: FrameKey, centroid: SIMD3<Float>,
                memberCount: Int, detectedAt: Date, label: String? = nil) {
        self.id = id
        self.frameKey = frameKey
        self.centroid = centroid
        self.memberCount = memberCount
        self.detectedAt = detectedAt
        self.label = label
    }
}

public struct ClusterMember: Sendable, Equatable {
    public let clusterId: Int64
    public let vectorId: Int64
    public init(clusterId: Int64, vectorId: Int64) {
        self.clusterId = clusterId
        self.vectorId = vectorId
    }
}
