import Foundation
import SwiftData
import OhiaCore
import OhiaML

@MainActor
public final class MessageDeletionApplier {
    public struct AppliedSummary: Sendable, Equatable {
        public var appliedDeleteCount: Int
        public var skippedFirstSync: Int
        public var skippedNonAllFolder: Int
        public var skippedUidValidityChanged: Int
        public var deferredToGracePeriod: Int
        public var appliedMessageIDs: [UUID]
    }

    public let modelContext: ModelContext
    private let vectorStore: VectorStore
    private let neighborsStore: VectorNeighborsStore
    private let frameLayoutStore: VectorFrameLayoutStore
    private let clusterStore: VectorClusterStore
    private let canonicalStore: CanonicalStore
    private let jobQueue: JobQueue
    private let status: DeletionSyncStatusPublisher

    public init(
        modelContext: ModelContext,
        vectorStore: VectorStore,
        neighborsStore: VectorNeighborsStore,
        frameLayoutStore: VectorFrameLayoutStore,
        clusterStore: VectorClusterStore,
        canonicalStore: CanonicalStore,
        jobQueue: JobQueue = JobQueue(),
        status: DeletionSyncStatusPublisher
    ) {
        self.modelContext = modelContext
        self.vectorStore = vectorStore
        self.neighborsStore = neighborsStore
        self.frameLayoutStore = frameLayoutStore
        self.clusterStore = clusterStore
        self.canonicalStore = canonicalStore
        self.jobQueue = jobQueue
        self.status = status
    }

    public func apply(_ decisions: [MessageDeletionDecision]) async throws -> AppliedSummary {
        var applied = 0
        var firstSync = 0
        var nonAll = 0
        var uidValidity = 0
        var deferred = 0
        var appliedUIDs: [UInt32] = []
        var appliedMessageIDs: [UUID] = []
        var removedVectorIds: [Int64] = []
        var folder: String?

        do {
            let deletionMessageIDs = Set(decisions.compactMap { decision -> UUID? in
                guard case .delete(let messageID, _, _, _) = decision else { return nil }
                return messageID
            })
            if deletionMessageIDs.isEmpty == false {
                // Cancel preparation before mutating any Message rows. The
                // coordinator may save its own changes, so doing this once up
                // front prevents a later cancellation from partially
                // committing an earlier deletion in the same batch.
                try ReplySourcePreparationCoordinator().cancel(
                    messageIDs: deletionMessageIDs,
                    context: modelContext
                )
            }
            try vectorStore.withTransaction {
                for decision in decisions {
                    switch decision {
                    case .delete(let messageID, _, let f, let uid):
                        folder = f
                        let messageKey = messageID.uuidString
                        removedVectorIds.append(contentsOf: try vectorStore.vectorIds(forMessageId: messageKey))
                        try cascade(messageID: messageID)
                        applied += 1
                        appliedUIDs.append(uid)
                        appliedMessageIDs.append(messageID)
                    case .skipFirstSync(let f):
                        folder = f
                        firstSync += 1
                    case .skipNonAllFolder:
                        nonAll += 1
                    case .skipUidValidityChanged(let f, let oldValidity, let newValidity):
                        folder = f
                        uidValidity += 1
                        status.recordAbort(folder: f, reason: .uidValidityChanged(old: oldValidity, new: newValidity))
                    case .skipMoveDetected:
                        break
                    case .deferToGracePeriod(_, _, let f, _, _, _):
                        folder = f
                        deferred += 1
                    }
                }
            }
            if applied > 0 {
                try modelContext.save()
                status.recordApplied(folder: folder ?? "(unknown)", capability: .qresync, uids: appliedUIDs)
                NotificationCenter.default.post(
                    name: .ohiaDeletionApplied,
                    object: nil,
                    userInfo: [
                        "vectorIds": removedVectorIds,
                        "messageIds": appliedMessageIDs.map(\.uuidString),
                    ]
                )
            }
            // Push the live pending-deletion count to the publisher so the QA panel
            // reflects the current staging-table size after each apply (e.g. when
            // the reaper finalizes a deferred candidate via cascade).
            let allPending = (try? modelContext.fetch(FetchDescriptor<PendingDeletionCandidate>())) ?? []
            status.updatePendingCount(allPending.count)
        } catch {
            modelContext.rollback()
            status.recordAbort(
                folder: folder ?? "(unknown)",
                reason: .applierFailed(message: String(describing: error))
            )
            throw error
        }

        return AppliedSummary(
            appliedDeleteCount: applied,
            skippedFirstSync: firstSync,
            skippedNonAllFolder: nonAll,
            skippedUidValidityChanged: uidValidity,
            deferredToGracePeriod: deferred,
            appliedMessageIDs: appliedMessageIDs
        )
    }

    private func cascade(messageID: UUID) throws {
        let messageKey = messageID.uuidString
        let affectedFrames = try clusterStore.framesContaining(messageId: messageKey)
        try clusterStore.removeMembership(forMessageId: messageKey)
        try frameLayoutStore.deletePositions(forMessageId: messageKey)
        try neighborsStore.deleteNeighbors(forMessageId: messageKey)
        try vectorStore.deleteVectors(forMessageId: messageKey)
        try canonicalStore.deleteAllArtifacts(messageId: messageKey)

        if let message = try fetchMessage(id: messageID) {
            let thread = message.thread
            // TrainingPair is intentionally no longer a singular inverse on
            // Message: one sent evidence item may own multiple prepared pairs.
            // Nullify every direct source link explicitly before deleting the
            // mailbox row so the durable evidence/pairs remain loadable.
            let trainingPairs = try modelContext.fetch(FetchDescriptor<TrainingPair>())
            let affectedPairs = trainingPairs.filter {
                $0.message?.id == messageID || $0.replyToMessageId == messageID
            }
            let affectedEvidenceIDs = Set(affectedPairs.compactMap { $0.evidence?.id })
            for pair in affectedPairs {
                if pair.message?.id == messageID {
                    pair.message = nil
                }
                if pair.styleRegisterID != nil {
                    // Preserve the former register pointer just long enough
                    // for the style worker's stale-membership probe to run;
                    // the worker rebuilds any surviving pair unconditioned.
                    pair.styleRegisterRevision = nil
                }
            }
            let evidenceRows = try modelContext.fetch(FetchDescriptor<SentTrainingEvidence>())
            for evidence in evidenceRows where evidence.sourceMessage?.id == messageID
                || evidence.sourceMessageID == messageID
                || affectedEvidenceIDs.contains(evidence.id) {
                if evidence.sourceMessage?.id == messageID || evidence.sourceMessageID == messageID {
                    evidence.sourceMessage = nil
                }
                if evidence.disposition != .excluded || evidence.reason != .trashedSource {
                    evidence.disposition = .excluded
                    evidence.reason = .trashedSource
                    evidence.isRetryable = false
                    evidence.dispositionedAt = .now
                    evidence.updatedAt = .now
                    evidence.revision += 1
                }
            }
            // Front Page and other read-only contexts can still be projecting
            // this message when a worker observes the server-side deletion.
            // Deleting the SwiftData row would invalidate those live models and
            // trap on their next persisted-property access. Keep an inactive
            // tombstone while removing every search/vector/file artifact.
            message.trashedAt = message.trashedAt ?? .now
            message.imapFolderPath = nil
            message.imapUID = 0
            message.liveDetectedAt = nil
            message.rawPath = nil
            message.bodyTextPath = nil
            message.bodyHtmlPath = nil
            for attachment in message.attachments {
                attachment.filePath = nil
                attachment.extractedTextPath = nil
                attachment.embeddingTextPath = nil
                attachment.extractionMetadataPath = nil
                attachment.ragDocumentPath = nil
            }
            message.thread = nil
            if let thread {
                ThreadAssigner.refreshStats(for: thread)
            }
        }

        for frame in affectedFrames {
            try enqueueClusterRecomputeIfNeeded(frame: frame)
        }
    }

    private func fetchMessage(id: UUID) throws -> Message? {
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == id })
        return try modelContext.fetch(descriptor).first
    }

    private func enqueueClusterRecomputeIfNeeded(frame: FrameKey) throws {
        guard ClusterDetectSeeder.isRunnable(frame) else { return }
        let clusters = try clusterStore.clusters(for: frame)
        guard clusters.contains(where: { $0.memberCount < ClusterDetector.defaultMinPoints }) else {
            return
        }
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
            context: modelContext
        )
    }
}
