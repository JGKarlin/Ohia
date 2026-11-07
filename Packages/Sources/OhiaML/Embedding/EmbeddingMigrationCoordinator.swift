import Foundation
import OhiaCore
import SwiftData

/// Drives migration from legacy embedding versions into the current embedder.
public final class EmbeddingMigrationCoordinator: @unchecked Sendable {
    private let registry: EmbedderRegistry
    private let vectorStore: VectorStore
    private let canonicalStore: CanonicalStore

    public struct Stats: Sendable, Equatable {
        public let scanned: Int
        public let migrated: Int
        public let skipped: Int

        public init(scanned: Int, migrated: Int, skipped: Int) {
            self.scanned = scanned
            self.migrated = migrated
            self.skipped = skipped
        }
    }

    public init(
        registry: EmbedderRegistry,
        vectorStore: VectorStore,
        canonicalStore: CanonicalStore
    ) {
        self.registry = registry
        self.vectorStore = vectorStore
        self.canonicalStore = canonicalStore
    }

    public func staleMessageIds(limit: Int) throws -> [String] {
        try vectorStore.distinctMessageIds(
            whereVersionNot: registry.current.embeddingVersion,
            limit: limit
        )
    }

    public func migrateBatch(messageIds: [String]) throws -> Stats {
        var migrated = 0
        var skipped = 0

        for messageId in messageIds {
            do {
                let bodyText = try canonicalStore.readBody(messageId: messageId)
                let searchableBodyText = OriginalMessageText.cleaned(from: bodyText) ?? ""
                guard let vector = registry.current.embed(searchableBodyText) else {
                    skipped += 1
                    continue
                }

                try vectorStore.deleteVectors(forMessageId: messageId)
                try vectorStore.insert(
                    messageId: messageId,
                    collection: .context,
                    chunkIndex: 0,
                    embeddingVersion: registry.current.embeddingVersion,
                    vector: vector,
                    textPayload: searchableBodyText,
                    metadataJSON: "{}"
                )
                migrated += 1
            } catch {
                print("[EmbeddingMigrationCoordinator] skipped messageId=\(messageId): \(String(reflecting: type(of: error)))")
                skipped += 1
            }
        }

        return Stats(scanned: messageIds.count, migrated: migrated, skipped: skipped)
    }

    @MainActor
    public func migrateBatchFull(
        messageIds: [String],
        orchestrator: EmbeddingOrchestrator,
        context: ModelContext
    ) async throws -> Stats {
        var migrated = 0
        var skipped = 0

        for messageId in messageIds {
            do {
                try await orchestrator.reembedMessage(messageId: messageId, context: context)
                migrated += 1
            } catch {
                print("[EmbeddingMigrationCoordinator] full-pipeline skip messageId=\(messageId): \(String(reflecting: type(of: error)))")
                skipped += 1
            }
        }

        return Stats(scanned: messageIds.count, migrated: migrated, skipped: skipped)
    }
}
