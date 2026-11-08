import Foundation
import OhiaCore
import SwiftData

/// Drives migration from legacy embedding versions into the current embedder.
public final class EmbeddingMigrationCoordinator: @unchecked Sendable {
    private let registry: EmbedderRegistry
    private let vectorStore: VectorStore

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
        vectorStore: VectorStore
    ) {
        self.registry = registry
        self.vectorStore = vectorStore
    }

    public func staleMessageIds(limit: Int) throws -> [String] {
        try vectorStore.distinctMessageIds(
            whereVersionNot: registry.current.embeddingVersion,
            limit: limit
        )
    }

    @MainActor
    public func migrateBatchFull(
        messageIds: [String],
        orchestrator: EmbeddingOrchestrator,
        context: ModelContext
    ) async throws -> Stats {
        var migrated = 0
        var skipped = 0

        for ownerId in messageIds {
            do {
                switch try owner(of: ownerId, context: context) {
                case .message:
                    try await orchestrator.reembedMessage(messageId: ownerId, context: context)
                    migrated += 1
                case .entity(let entity):
                    // Entity vectors share the table, keyed by the entity's id.
                    // Clearing the row hands the entity back to entity
                    // promotion, which embeds it with the current embedder.
                    try vectorStore.deleteVectors(forMessageId: ownerId)
                    entity.vectorRowId = nil
                    try context.save()
                    migrated += 1
                case .none:
                    // No message or entity owns these rows any more. Nothing
                    // can re-embed them, and kept, they would report stale
                    // vectors forever and keep re-queueing this migration.
                    try vectorStore.deleteVectors(forMessageId: ownerId)
                    skipped += 1
                }
            } catch {
                print("[EmbeddingMigrationCoordinator] full-pipeline skip id=\(ownerId): \(String(reflecting: type(of: error)))")
                skipped += 1
            }
        }

        return Stats(scanned: messageIds.count, migrated: migrated, skipped: skipped)
    }

    private enum VectorOwner {
        case message
        case entity(Entity)
        case none
    }

    @MainActor
    private func owner(of ownerId: String, context: ModelContext) throws -> VectorOwner {
        guard let id = UUID(uuidString: ownerId) else { return .none }
        var messageDescriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == id })
        messageDescriptor.fetchLimit = 1
        if try context.fetchCount(messageDescriptor) > 0 {
            return .message
        }
        var entityDescriptor = FetchDescriptor<Entity>(predicate: #Predicate<Entity> { $0.id == id })
        entityDescriptor.fetchLimit = 1
        if let entity = try context.fetch(entityDescriptor).first {
            return .entity(entity)
        }
        return .none
    }
}
