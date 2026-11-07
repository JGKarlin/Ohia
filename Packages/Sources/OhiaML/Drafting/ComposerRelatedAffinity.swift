import Foundation
import OhiaCore

public struct ComposerRelatedAffinity: Sendable, Equatable {
    public var semanticSimilarity: Double?
    public var sharesMeaningCluster: Bool

    public init(
        semanticSimilarity: Double? = nil,
        sharesMeaningCluster: Bool = false
    ) {
        self.semanticSimilarity = semanticSimilarity
        self.sharesMeaningCluster = sharesMeaningCluster
    }
}

public protocol ComposerRelatedAffinityProviding: Sendable {
    func affinities(
        anchorMessageID: UUID,
        candidateMessageIDs: Set<UUID>,
        limit: Int
    ) -> [UUID: ComposerRelatedAffinity]
}

public final class StoredComposerRelatedAffinityProvider: ComposerRelatedAffinityProviding, @unchecked Sendable {
    private let vectorNeighborsStore: VectorNeighborsStore
    private let vectorClusterStore: VectorClusterStore?
    private let minimumSimilarity: Float

    public init(
        vectorNeighborsStore: VectorNeighborsStore,
        vectorClusterStore: VectorClusterStore? = nil,
        minimumSimilarity: Float = 0.60
    ) {
        self.vectorNeighborsStore = vectorNeighborsStore
        self.vectorClusterStore = vectorClusterStore
        self.minimumSimilarity = minimumSimilarity
    }

    public func affinities(
        anchorMessageID: UUID,
        candidateMessageIDs: Set<UUID>,
        limit: Int
    ) -> [UUID: ComposerRelatedAffinity] {
        guard limit > 0, candidateMessageIDs.isEmpty == false else { return [:] }

        let candidateByString = Dictionary(uniqueKeysWithValues: candidateMessageIDs.map { ($0.uuidString, $0) })
        let anchor = anchorMessageID.uuidString
        var out: [UUID: ComposerRelatedAffinity] = [:]

        let neighborScores = (try? vectorNeighborsStore.messageAffinities(
            forMessageId: anchor,
            limit: limit,
            similarityThreshold: minimumSimilarity
        )) ?? [:]
        for (messageIDString, score) in neighborScores {
            guard let messageID = candidateByString[messageIDString] else { continue }
            var affinity = out[messageID] ?? ComposerRelatedAffinity()
            affinity.semanticSimilarity = max(affinity.semanticSimilarity ?? 0, Double(score))
            out[messageID] = affinity
        }

        if let clusterPeers = try? vectorClusterStore?.messagesSharingCluster(
            withMessageId: anchor,
            frame: .meaning,
            limit: limit
        ) {
            for messageIDString in clusterPeers {
                guard let messageID = candidateByString[messageIDString] else { continue }
                var affinity = out[messageID] ?? ComposerRelatedAffinity()
                affinity.sharesMeaningCluster = true
                out[messageID] = affinity
            }
        }

        return out
    }
}
