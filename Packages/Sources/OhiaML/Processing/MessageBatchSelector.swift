import Foundation
import SwiftData
import OhiaCore

enum MessageBatchSelector {
    enum Stage {
        case embeddingPending

        var workKind: MessageStoreWorkKind {
            switch self {
            case .embeddingPending:
                return .embeddingPending
            }
        }
    }

    @MainActor
    static func fetchMessages(
        stage: Stage,
        limit: Int,
        context: ModelContext,
        storeURL: URL? = nil,
        fallback: () throws -> [Message]
    ) throws -> [Message] {
        guard let storeURL else {
            return Array(
                try fallback()
                    .filter { isEligible($0, for: stage) }
                    .sorted(by: Message.newestPipelineFirst)
                    .prefix(limit)
            )
        }
        guard let ids = try MessageStoreHotPath.pendingMessageIDs(
            kind: stage.workKind,
            limit: limit,
            storeURL: storeURL
        ) else {
            return Array(
                try fallback()
                    .filter { isEligible($0, for: stage) }
                    .sorted(by: Message.newestPipelineFirst)
                    .prefix(limit)
            )
        }

        var messages: [Message] = []
        messages.reserveCapacity(ids.count)
        for id in ids {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { message in
                    message.id == id
                },
                sortBy: [SortDescriptor(\.ingestedAt)]
            )
            descriptor.fetchLimit = 1
            if let message = try context.fetch(descriptor).first {
                messages.append(message)
            }
        }
        if !ids.isEmpty && messages.isEmpty {
            return Array(
                try fallback()
                    .filter { isEligible($0, for: stage) }
                    .sorted(by: Message.newestPipelineFirst)
                    .prefix(limit)
            )
        }
        return messages
    }

    private static func isEligible(_ message: Message, for stage: Stage) -> Bool {
        message.embeddingStatus != .completed
    }
}
