import Foundation
import SwiftData
import OhiaCore

// MARK: - AgentTool Protocol

public protocol AgentTool: Sendable {
    var name: String { get }
    var toolDescription: String { get }
    func execute(query: String, context: ToolContext) throws -> ToolResult
}

// MARK: - ToolContext

public struct ToolContext: @unchecked Sendable {
    public let vectorStore: VectorStore
    public let embedder: EmbeddingProvider
    public let modelContext: ModelContext
    public let canonicalStore: CanonicalStore
    public let hybridRetriever: HybridRetriever?

    public init(
        vectorStore: VectorStore,
        embedder: EmbeddingProvider,
        modelContext: ModelContext,
        canonicalStore: CanonicalStore,
        hybridRetriever: HybridRetriever? = nil
    ) {
        self.vectorStore = vectorStore
        self.embedder = embedder
        self.modelContext = modelContext
        self.canonicalStore = canonicalStore
        self.hybridRetriever = hybridRetriever
    }
}

// MARK: - CorpusSearchTool

/// Embeds the query and searches the `.context` vector collection, returning top-10 findings with scores.
public struct CorpusSearchTool: AgentTool {
    public let name = "corpus_search"
    public let toolDescription = "Search the email corpus for semantically similar messages"

    public init() {}

    public func execute(query: String, context: ToolContext) throws -> ToolResult {
        guard let hybridRetriever = context.hybridRetriever else {
            return ToolResult()
        }

        let results: [RetrievalResult]
        do {
            results = try hybridRetriever.retrieve(
                query: query,
                filter: FilterSpec(collections: [.context]),
                k: 10,
                // kNN-graph expansion fills the join-query gap: a commitment or
                // fact split across related messages that ANN alone misses.
                expansionConfig: .default
            )
        } catch RetrievalError.embeddingUnavailable {
            return ToolResult()
        }

        let findings = results.map { result in
            Finding(
                text: result.record.textPayload,
                sourceMessageId: result.record.messageId,
                confidence: Double(result.score)
            )
        }

        return ToolResult(findings: findings)
    }
}

// MARK: - AttachmentSearchTool

/// Embeds the query and searches the `.attachment` vector collection.
/// Also looks up Attachment models to find file paths for deliverables.
public struct AttachmentSearchTool: AgentTool {
    public let name = "attachment_search"
    public let toolDescription = "Search email attachments for relevant documents"

    public init() {}

    public func execute(query: String, context: ToolContext) throws -> ToolResult {
        guard let hybridRetriever = context.hybridRetriever else {
            return ToolResult()
        }

        let results: [RetrievalResult]
        do {
            results = try hybridRetriever.retrieve(
                query: query,
                filter: FilterSpec(collections: [.attachment]),
                k: 10
            )
        } catch RetrievalError.embeddingUnavailable {
            return ToolResult()
        }

        let findings = results.map { result in
            Finding(
                text: result.record.textPayload,
                sourceMessageId: result.record.messageId,
                confidence: Double(result.score)
            )
        }

        // Gather the distinct message IDs from results so we can look up attachments.
        let messageIds = Set(results.map { $0.record.messageId })

        let allAttachments = try context.modelContext.fetch(FetchDescriptor<Attachment>())

        var deliverables: [Deliverable] = []
        for attachment in allAttachments {
            guard
                let message = attachment.message,
                messageIds.contains(message.id.uuidString),
                let filePath = attachment.filePath
            else { continue }

            deliverables.append(Deliverable(
                filename: attachment.filename,
                filePath: filePath,
                sourceMessageId: message.id.uuidString
            ))
        }

        return ToolResult(findings: findings, deliverables: deliverables)
    }
}

// MARK: - CorrespondentLookupTool

/// Searches Correspondent models by name or email substring match (case-insensitive).
/// Returns profile info as findings.
public struct CorrespondentLookupTool: AgentTool {
    public let name = "correspondent_lookup"
    public let toolDescription = "Look up correspondent profile by name or email"

    public init() {}

    public func execute(query: String, context: ToolContext) throws -> ToolResult {
        let lowercasedQuery = query.lowercased()

        let allCorrespondents = try context.modelContext.fetch(FetchDescriptor<Correspondent>())

        let matched = allCorrespondents.filter {
            $0.primaryName.lowercased().contains(lowercasedQuery) ||
            $0.primaryEmail.lowercased().contains(lowercasedQuery)
        }

        let findings = matched.map { correspondent -> Finding in
            var parts: [String] = []
            parts.append("Name: \(correspondent.primaryName)")
            parts.append("Email: \(correspondent.primaryEmail)")
            if let org = correspondent.organization {
                parts.append("Organization: \(org)")
            }
            if let domain = correspondent.domain {
                parts.append("Domain: \(domain)")
            }
            parts.append("Messages: \(correspondent.messageCount)")
            parts.append(String(format: "Familiarity: %.2f", correspondent.familiarityScore))
            if let profile = correspondent.profileJSON {
                parts.append("Profile: \(profile)")
            }

            return Finding(
                text: parts.joined(separator: "\n"),
                sourceMessageId: nil,
                confidence: 1.0
            )
        }

        return ToolResult(findings: findings)
    }
}

// MARK: - ThreadHistoryTool

/// Takes a message ID as query, finds its thread, returns all thread messages sorted
/// chronologically with sender and body preview (first 30 words).
public struct ThreadHistoryTool: AgentTool {
    public let name = "thread_history"
    public let toolDescription = "Retrieve the full thread history for a message"

    public init() {}

    public func execute(query: String, context: ToolContext) throws -> ToolResult {
        let allMessages = try context.modelContext.fetch(FetchDescriptor<Message>())

        // Find the target message by UUID string or message-id header.
        guard let targetMessage = allMessages.first(where: {
            $0.id.uuidString == query || $0.messageIdHeader == query
        }) else {
            return ToolResult()
        }

        guard let thread = targetMessage.thread else {
            // No thread — return just this message.
            let finding = makeFinding(for: targetMessage, context: context)
            return ToolResult(findings: [finding])
        }

        let sortedMessages = thread.messages.sorted {
            ($0.sentAt ?? $0.ingestedAt) < ($1.sentAt ?? $1.ingestedAt)
        }

        let findings = sortedMessages.map { makeFinding(for: $0, context: context) }
        return ToolResult(findings: findings)
    }

    // MARK: Private helpers

    private func makeFinding(for message: Message, context: ToolContext) -> Finding {
        let dateString: String
        if let sentAt = message.sentAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            dateString = formatter.string(from: sentAt)
        } else {
            dateString = "unknown date"
        }

        let sender = message.fromName.map { "\($0) <\(message.fromAddress)>" } ?? message.fromAddress

        let bodyPreview = bodyPreview(for: message, context: context)

        let text = """
        Date: \(dateString)
        From: \(sender)
        Subject: \(message.subject)
        \(bodyPreview)
        """

        return Finding(
            text: text,
            sourceMessageId: message.id.uuidString,
            confidence: 1.0
        )
    }

    private func bodyPreview(for message: Message, context: ToolContext) -> String {
        // Attempt to load body text from the canonical store.
        if let _ = message.bodyTextPath {
            if let body = try? context.canonicalStore.loadBodyText(messageId: message.id.uuidString) {
                return previewText(body)
            }
        }
        return ""
    }

    private func previewText(_ text: String) -> String {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let preview = words.prefix(30).joined(separator: " ")
        return words.count > 30 ? preview + "…" : preview
    }
}
