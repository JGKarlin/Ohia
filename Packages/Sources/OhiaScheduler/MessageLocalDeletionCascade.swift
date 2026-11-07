import Foundation
import SwiftData
import OhiaCore
import OhiaML

@MainActor
public protocol MessageLocalDeletionArtifactCleaning: AnyObject {
    func setMessageActive(messageID: UUID, isActive: Bool) throws

    @discardableResult
    func removeLocalArtifacts(messageID: UUID) throws -> Set<FrameKey>

    func enqueueClusterRecomputeIfNeeded(
        frames: Set<FrameKey>,
        context: ModelContext,
        jobQueue: JobQueue
    ) throws
}

@MainActor
public final class MessageLocalDeletionCascade: MessageLocalDeletionArtifactCleaning {
    private let vectorStore: VectorStore
    private let neighborsStore: VectorNeighborsStore
    private let frameLayoutStore: VectorFrameLayoutStore
    private let clusterStore: VectorClusterStore
    private let canonicalStore: CanonicalStore

    public init(
        vectorStore: VectorStore,
        neighborsStore: VectorNeighborsStore,
        frameLayoutStore: VectorFrameLayoutStore,
        clusterStore: VectorClusterStore,
        canonicalStore: CanonicalStore
    ) {
        self.vectorStore = vectorStore
        self.neighborsStore = neighborsStore
        self.frameLayoutStore = frameLayoutStore
        self.clusterStore = clusterStore
        self.canonicalStore = canonicalStore
    }

    public convenience init(appServices services: AppServices) {
        self.init(
            vectorStore: services.vectorStore,
            neighborsStore: services.vectorNeighborsStore,
            frameLayoutStore: services.vectorFrameLayoutStore,
            clusterStore: services.vectorClusterStore,
            canonicalStore: services.canonicalStore
        )
    }

    @discardableResult
    public func removeLocalArtifacts(
        messageID: UUID
    ) throws -> Set<FrameKey> {
        let messageKey = messageID.uuidString
        let affectedFrames = try vectorStore.withTransaction {
            let frames = try clusterStore.framesContaining(messageId: messageKey)
            try clusterStore.removeMembership(forMessageId: messageKey)
            try frameLayoutStore.deletePositions(forMessageId: messageKey)
            try neighborsStore.deleteNeighbors(forMessageId: messageKey)
            try vectorStore.deleteVectors(forMessageId: messageKey)
            try canonicalStore.deleteAllArtifacts(messageId: messageKey)
            return frames
        }

        var framesNeedingRecompute: Set<FrameKey> = []
        for frame in affectedFrames where ClusterDetectSeeder.isRunnable(frame) {
            let clusters = try clusterStore.clusters(for: frame)
            guard clusters.contains(where: { $0.memberCount < ClusterDetector.defaultMinPoints }) else {
                continue
            }
            framesNeedingRecompute.insert(frame)
        }
        return framesNeedingRecompute
    }

    public func setMessageActive(messageID: UUID, isActive: Bool) throws {
        try vectorStore.setMessageActive(
            messageId: messageID.uuidString,
            isActive: isActive
        )
    }

    public func enqueueClusterRecomputeIfNeeded(
        frames: Set<FrameKey>,
        context: ModelContext,
        jobQueue: JobQueue
    ) throws {
        let runnableFrames = frames.filter(ClusterDetectSeeder.isRunnable)
        guard !runnableFrames.isEmpty else { return }
        for frame in runnableFrames {
            let payload = ClusterDetectPayload(
                frame: frame,
                semanticTargetClusters: ClusterDetectPayload.stableMeaningTargetClusters
            )
            let data = try JSONEncoder().encode(payload)
            let json = String(decoding: data, as: UTF8.self)
            jobQueue.stage(
                type: .clusterDetect,
                priority: ClusterDetectSeeder.priority,
                payload: json,
                context: context
            )
        }
        try context.save()
    }
}
