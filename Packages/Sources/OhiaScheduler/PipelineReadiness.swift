import Foundation
import SwiftData
import OhiaCore

public enum PipelineReadinessBlockReason: String, Sendable, Equatable, CaseIterable {
    case embedding = "BGE embedding"
    case placement = "BGE placement"
    case reindexing = "BGE reindexing"
    case queuedBGEWork = "BGE work"

    public var trainingStatusLabel: String {
        switch self {
        case .embedding:
            return "BGE embedding"
        case .placement:
            return "BGE indexing"
        case .reindexing:
            return "BGE reindexing"
        case .queuedBGEWork:
            return "BGE work"
        }
    }
}

public struct PipelineReadinessStatus: Sendable, Equatable {
    public let isComplete: Bool
    public let blockingReason: PipelineReadinessBlockReason?

    public init(isComplete: Bool, blockingReason: PipelineReadinessBlockReason?) {
        self.isComplete = isComplete
        self.blockingReason = blockingReason
    }

    public static let complete = PipelineReadinessStatus(isComplete: true, blockingReason: nil)

    public static func blocked(_ reason: PipelineReadinessBlockReason) -> PipelineReadinessStatus {
        PipelineReadinessStatus(isComplete: false, blockingReason: reason)
    }
}

/// Readiness of the Meaning lens's persisted cluster snapshot.
/// An established snapshot stays displayable while live mail settles and
/// while its atomic replacement is being detected.
public enum MeaningClusterPipelineStatus: Sendable, Equatable {
    case processing
    case incrementalProcessing
    case detecting
    case refreshing
    case ready

    public var sourceDataIsSettled: Bool {
        switch self {
        case .processing, .incrementalProcessing:
            return false
        case .detecting, .refreshing, .ready:
            return true
        }
    }

    public var isReadyForDisplay: Bool {
        switch self {
        case .processing, .detecting:
            return false
        case .incrementalProcessing, .refreshing, .ready:
            return true
        }
    }

    public var needsDetection: Bool {
        self == .detecting || self == .refreshing
    }
}

public enum PipelineReadiness {
    private static let meaningClusterMinimumVectorCount = 4

    @MainActor
    public static func initialImportWorkIsPending(
        context: ModelContext,
        now: Date = Date()
    ) -> Bool {
        do {
            let accounts = try context.fetch(FetchDescriptor<Account>())
            _ = now
            return accounts.contains { account in
                account.status != .paused
                    && account.imapHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    && account.imapKeychainRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    && account.initialIMAPImportCompletedAt == nil
            }
        } catch {
            return true
        }
    }

    @MainActor
    public static func meaningClusterStatus(
        context: ModelContext,
        vectorStore: VectorStore,
        clusterStore: VectorClusterStore,
        messageStoreURL: URL?,
        currentEmbeddingVersion: String?,
        initialImportWorkPending: Bool
    ) -> MeaningClusterPipelineStatus {
        do {
            let existingRun = try clusterStore.clusterRun(frame: .defaultFrame)
            let existingClusters = try clusterStore.clusters(for: .defaultFrame)
            let establishedSnapshotExists = existingRun != nil || !existingClusters.isEmpty
            func unsettledSourceStatus() -> MeaningClusterPipelineStatus {
                establishedSnapshotExists ? .incrementalProcessing : .processing
            }
            guard !initialImportWorkPending else {
                return unsettledSourceStatus()
            }
            let messages: [Message]?
            let expectedMessageCount: Int
            var sourceDataPending = false

            if let messageStoreURL {
                guard let snapshot = try MessageStoreHotPath.actionabilitySnapshot(
                    storeURL: messageStoreURL
                ) else {
                    return .processing
                }
                if snapshot.hasEmbeddingPending {
                    sourceDataPending = true
                }
                messages = nil
                expectedMessageCount = snapshot.totalMessages
            } else {
                let fetched = try context.fetch(FetchDescriptor<Message>())
                let incompleteMessages = fetched.filter { $0.embeddingStatus != .completed }
                if !establishedSnapshotExists,
                   incompleteMessages.contains(where: { $0.liveDetectedAt == nil }) {
                    return .processing
                }
                if !incompleteMessages.isEmpty {
                    sourceDataPending = true
                }
                messages = fetched
                expectedMessageCount = fetched.count
            }

            let contextVectorCount = try vectorStore.count(collection: .context)
            guard contextVectorCount == 0 || currentEmbeddingVersion != nil else {
                return unsettledSourceStatus()
            }
            if let currentEmbeddingVersion,
               try vectorStore.count(
                   collection: .context,
                   embeddingVersion: currentEmbeddingVersion
               ) != contextVectorCount {
                return unsettledSourceStatus()
            }

            var contextFilter = VectorFilter()
            contextFilter.collections = [.context]
            var corpus = try vectorStore.renderRowsWithLayout(
                filter: contextFilter,
                limit: Int.max
            )
            .filter { $0.chunkIndex == 0 }
            .sorted { $0.vectorId < $1.vectorId }

            if let messageStoreURL {
                let candidateMessageIDs = corpus.compactMap {
                    UUID(uuidString: $0.messageId)
                }
                guard candidateMessageIDs.count == corpus.count,
                      let activeMessageIDs = try MessageStoreHotPath.activeMessageIDs(
                          matching: candidateMessageIDs,
                          storeURL: messageStoreURL
                      ) else {
                    return .processing
                }
                let activeMessageIDStrings = Set(activeMessageIDs.map(\.uuidString))
                corpus.removeAll {
                    !activeMessageIDStrings.contains($0.messageId)
                }
            }

            let placedMessageIDs = Set(corpus.map(\.messageId))
            if let messages {
                let unplacedMessages = messages.filter {
                    !placedMessageIDs.contains($0.id.uuidString)
                }
                if !establishedSnapshotExists,
                   unplacedMessages.contains(where: { $0.liveDetectedAt == nil }) {
                    return .processing
                }
                if !unplacedMessages.isEmpty {
                    sourceDataPending = true
                }
            } else if placedMessageIDs.count < expectedMessageCount {
                sourceDataPending = true
            }

            let fingerprint = ClusterDetectionWorker.corpusFingerprint(
                ascendingVectorIds: corpus.map(\.vectorId)
            )
            func changedSnapshotStatus() -> MeaningClusterPipelineStatus {
                establishedSnapshotExists ? .refreshing : .detecting
            }

            if sourceDataPending {
                return establishedSnapshotExists ? .incrementalProcessing : .processing
            }

            guard corpus.count >= meaningClusterMinimumVectorCount else {
                guard establishedSnapshotExists else { return .ready }
                guard existingRun?.inputFingerprint != fingerprint else { return .ready }
                return changedSnapshotStatus()
            }

            guard let run = existingRun,
                  run.inputFingerprint == fingerprint else {
                return changedSnapshotStatus()
            }
            return .ready
        } catch {
            return .processing
        }
    }

    static func hasCompleteInterpretation(_ message: Message) -> Bool {
        guard MailClassificationJSON.isComplete(message.analysis?.mailClassificationJSON) else {
            return false
        }
        guard message.isLiveInboundTriageEligible else {
            return true
        }
        return TriageVerdictJSON.hasRequiredBooleanFields(message.analysis?.triageVerdictJSON)
    }

    @MainActor
    public static func initialBGEPipelineStatus(
        context: ModelContext,
        vectorStore: VectorStore,
        messageStoreURL: URL?
    ) -> PipelineReadinessStatus {
        if let messageStoreURL,
           let snapshot = try? MessageStoreHotPath.actionabilitySnapshot(storeURL: messageStoreURL) {
            if snapshot.totalMessages > 0, snapshot.hasEmbeddingPending {
                return .blocked(.embedding)
            }
        } else {
            let messages = (try? context.fetch(FetchDescriptor<Message>())) ?? []
            if !messages.isEmpty,
               messages.contains(where: { $0.embeddingStatus != .completed }) {
                return .blocked(.embedding)
            }
        }

        guard let placement = try? vectorStore.placementCounts(), placement.total > 0 else {
            return .complete
        }
        return placement.placed >= placement.total ? .complete : .blocked(.placement)
    }

    @MainActor
    public static func bgeModelWorkStatus(
        context: ModelContext,
        vectorStore: VectorStore,
        messageStoreURL: URL?,
        currentEmbeddingVersion: String?,
        activeJobTypes: Set<JobType> = []
    ) -> PipelineReadinessStatus {
        let initial = initialBGEPipelineStatus(
            context: context,
            vectorStore: vectorStore,
            messageStoreURL: messageStoreURL
        )
        if !initial.isComplete {
            return initial
        }

        if let currentEmbeddingVersion,
           ((try? vectorStore.distinctMessageIds(
                whereVersionNot: currentEmbeddingVersion,
                limit: 1
           ).isEmpty == false) ?? false) {
            return .blocked(.reindexing)
        }

        let bgeJobTypes: Set<JobType> = [
            .embed,
            .index,
            .reindexEmbeddings,
            .entityEmbed,
            .entityRefresh
        ]
        if !activeJobTypes.isDisjoint(with: bgeJobTypes) {
            return .blocked(.queuedBGEWork)
        }

        return .complete
    }
}
