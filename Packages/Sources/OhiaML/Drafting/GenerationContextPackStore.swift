import Foundation
import SwiftData
import OhiaCore

public struct GenerationContextPack: Codable, Sendable {
    public let messageID: UUID
    public let context: AggregatedContext
    public let createdAt: Date

    public init(messageID: UUID, context: AggregatedContext, createdAt: Date = Date()) {
        self.messageID = messageID
        self.context = context
        self.createdAt = createdAt
    }
}

public struct GenerationContextPackStore: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static func directoryURL(appSupportDirectory: URL) -> URL {
        appSupportDirectory.appendingPathComponent("generation_context_packs", isDirectory: true)
    }

    public func packURL(for messageID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(messageID.uuidString).json", isDirectory: false)
    }

    public func containsPack(for messageID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: packURL(for: messageID).path)
    }

    public func pack(for messageID: UUID) throws -> GenerationContextPack? {
        let url = packURL(for: messageID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder().decode(GenerationContextPack.self, from: data)
    }

    @discardableResult
    public func write(_ pack: GenerationContextPack) throws -> GenerationContextPack {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(pack)
        try data.write(to: packURL(for: pack.messageID), options: .atomic)
        return pack
    }

    /// Deletes a stored pack so the next generation rebuilds it. Used when
    /// an input the pack bakes in changes — e.g. a draft language switch,
    /// which re-scopes the pack's style exemplars. Missing files are fine.
    public func removePack(for messageID: UUID) {
        let url = packURL(for: messageID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}

public enum GenerationContextPackError: LocalizedError, Sendable {
    case missing(UUID)

    public var errorDescription: String? {
        switch self {
        case .missing(let id):
            return "generation context pack missing for \(id.uuidString)"
        }
    }
}

public enum DraftContextPackBuilder {
    @MainActor
    public static func build(
        for message: Message,
        context: ModelContext,
        vectorStore: VectorStore,
        embedder: EmbeddingProvider,
        canonicalStore: CanonicalStore,
        hybridRetriever: HybridRetriever?,
        toolRegistry: ToolRegistry?
    ) throws -> AggregatedContext {
        let bodyText: String
        if let bodyTextPath = message.bodyTextPath {
            bodyText = try String(contentsOfFile: bodyTextPath, encoding: .utf8)
        } else {
            bodyText = ""
        }

        let decoder = JSONDecoder()
        let dimensions: MessageDimensions
        if let dimsJSON = message.analysis?.dimensionsJSON,
           let data = dimsJSON.data(using: .utf8),
           let decoded = try? decoder.decode(MessageDimensions.self, from: data) {
            dimensions = decoded
        } else {
            // TaskDecomposer's body-text fallback still produces general
            // research/attachment work when historical dimensions are absent.
            dimensions = MessageDimensions(extractionVersion: "none")
        }

        let tasks = TaskDecomposer.decompose(
            subject: message.subject,
            bodyText: bodyText,
            dimensions: dimensions,
            triageVerdict: ComposerSourceRelevance.triageVerdict(of: message),
            hasAttachmentEvidence: !message.attachments.isEmpty
                || (message.thread?.messages.contains { !$0.attachments.isEmpty } == true)
        )

        let taskToolRegistry: ToolRegistry
        if let toolRegistry {
            taskToolRegistry = toolRegistry
        } else {
            let builtIns = ToolRegistry()
            builtIns.registerBuiltInCorpusTools()
            taskToolRegistry = builtIns
        }

        let toolContext = ToolContext(
            vectorStore: vectorStore,
            embedder: embedder,
            modelContext: context,
            canonicalStore: canonicalStore,
            hybridRetriever: hybridRetriever
        )
        let results = try AgentExecutor(toolRegistry: taskToolRegistry).executeAll(
            tasks: tasks,
            toolContext: toolContext
        )
        let aggregated = AgentExecutor.aggregate(results)

        let correspondentName: String
        var correspondentProfile: CorrespondentProfile?
        let targetEmail = message.fromAddress.lowercased()
        let allParticipants = (try? context.fetch(FetchDescriptor<Participant>())) ?? []
        if let participant = allParticipants.first(where: { $0.emailAddress.lowercased() == targetEmail }),
           let correspondent = participant.correspondent {
            correspondentName = correspondent.primaryName
            if let profileJSON = correspondent.profileJSON,
               let profileData = profileJSON.data(using: .utf8) {
                correspondentProfile = try? decoder.decode(CorrespondentProfile.self, from: profileData)
            }
        } else {
            correspondentName = message.fromName ?? message.fromAddress
        }

        let styleExemplars: [String]
        if let hybridRetriever {
            let styleRetriever = StyleExemplarRetriever(hybridRetriever: hybridRetriever)
            // Restrict exemplars to the steering register's member replies
            // so the model imitates the voice this context is actually
            // written in, not merely vocabulary-similar replies from a
            // different register. The user's explicit picker choice outranks
            // resolution — the same precedence generation itself applies —
            // but never across a language switch, and the widening fallback
            // stays inside the draft's language: styles are language-scoped.
            let languageID = DraftLanguage.resolvedID(for: message)
            let explicitID = message.draft?.pendingStyleRegisterID ?? message.draft?.styleRegisterID
            let explicit = explicitID
                .flatMap {
                    StyleRegisterResolver.register(
                        withID: $0,
                        language: languageID,
                        context: context
                    )
                }
            let register = explicit ?? StyleRegisterResolver.resolve(
                forIncoming: message,
                language: languageID,
                context: context
            )
            let memberIDs = register.map {
                StyleRegisterResolver.memberMessageIDs(forRegisterID: $0.id, context: context)
            }
            let languagePool = StyleRegisterResolver.sentMessageIDs(
                inLanguage: languageID,
                context: context
            )
            styleExemplars = (try? styleRetriever.retrieve(
                correspondentName: correspondentName,
                subject: message.subject,
                restrictToMessageIDs: (memberIDs?.isEmpty == false) ? memberIDs : nil,
                fallbackMessageIDs: languagePool
            )) ?? []
        } else {
            styleExemplars = []
        }

        let threadContext: String
        if let thread = message.thread {
            let sortedMessages = thread.messages.sorted {
                ($0.sentAt ?? $0.ingestedAt) < ($1.sentAt ?? $1.ingestedAt)
            }
            let lastMessages = sortedMessages.suffix(5)
            let lines = lastMessages.map { msg -> String in
                let sender = msg.fromName ?? msg.fromAddress
                let preview: String
                if let bodyPath = msg.bodyTextPath,
                   let body = try? String(contentsOfFile: bodyPath, encoding: .utf8) {
                    let words = body.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                    preview = words.prefix(20).joined(separator: " ")
                } else {
                    preview = msg.subject
                }
                return "\(sender): \(preview)"
            }
            threadContext = lines.joined(separator: "\n")
        } else {
            threadContext = ""
        }
        let messageEvidenceDigest = messageEvidenceDigest(
            for: message,
            bodyText: bodyText
        )

        let memoryNotes = AccountMemoryDraftSelector.memoryNotes(
            for: message,
            context: context,
            embedder: embedder
        )

        return AggregatedContext(
            findings: aggregated.findings,
            deliverables: aggregated.deliverables,
            gaps: aggregated.gaps,
            taskStatuses: aggregated.taskStatuses,
            threadContext: threadContext,
            messageEvidenceDigest: messageEvidenceDigest,
            correspondentName: correspondentName,
            correspondentProfile: correspondentProfile,
            styleExemplars: styleExemplars,
            memoryNotes: memoryNotes
        )
    }

    @MainActor
    private static func messageEvidenceDigest(
        for message: Message,
        bodyText: String
    ) -> String? {
        var fallbackTextByAttachmentId: [String: String] = [:]
        for attachment in message.attachments {
            guard let path = attachment.extractedTextPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            fallbackTextByAttachmentId[attachment.id.uuidString] = text
        }
        return MessageEvidenceBundle
            .build(
                message: message,
                bodyText: bodyText,
                fallbackTextByAttachmentId: fallbackTextByAttachmentId
            )?
            .digest(maxCharacters: 2_400)
    }
}
