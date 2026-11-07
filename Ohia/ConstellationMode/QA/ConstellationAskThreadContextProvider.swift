import Foundation
import SwiftData
import OhiaCore
import OhiaML

@MainActor
struct ConstellationAskThreadContextProvider {
    private let modelContext: ModelContext
    private let vectorStore: VectorStore
    private let maxThreads: Int
    private let maxMessagesPerThread: Int
    private let bodyExcerptLimit: Int

    init(
        modelContext: ModelContext,
        vectorStore: VectorStore,
        maxThreads: Int = 6,
        maxMessagesPerThread: Int = 12,
        bodyExcerptLimit: Int = 1_200
    ) {
        self.modelContext = modelContext
        self.vectorStore = vectorStore
        self.maxThreads = max(1, maxThreads)
        self.maxMessagesPerThread = max(1, maxMessagesPerThread)
        self.bodyExcerptLimit = max(120, bodyExcerptLimit)
    }

    func expansion(for sources: [RetrievalResult]) async -> AskThreadExpansion {
        let anchors = uniqueAnchorMessageIds(from: sources)
        guard !anchors.isEmpty else { return .empty }
        let visualEvidence = visualEvidence(for: anchors)

        var contexts: [AskThreadContext] = []
        var additionalSources: [RetrievalResult] = []
        var seenVectorIds = Set(sources.map(\.record.vectorId))
        var seenThreadIds = Set<String>()

        for anchorId in anchors {
            guard contexts.count < maxThreads,
                  let anchor = fetchMessage(id: anchorId)
            else {
                continue
            }

            let threadMessages: [Message]
            let threadId: String
            let threadSubject: String
            if let thread = anchor.thread {
                threadId = thread.id.uuidString
                guard seenThreadIds.insert(threadId).inserted else { continue }
                threadSubject = thread.subjectRoot
                threadMessages = selectedMessages(
                    from: thread.messages,
                    anchorIds: anchors
                )
            } else {
                threadId = anchor.id.uuidString
                guard seenThreadIds.insert(threadId).inserted else { continue }
                threadSubject = anchor.subject
                threadMessages = [anchor]
            }

            guard !threadMessages.isEmpty else { continue }
            let threadMessageIds = Set(threadMessages.map { $0.id.uuidString })
            for message in threadMessages where !anchors.contains(message.id.uuidString) {
                guard let result = sourceResult(for: message),
                      seenVectorIds.insert(result.record.vectorId).inserted
                else {
                    continue
                }
                additionalSources.append(result)
            }

            let messages = await askThreadMessages(
                from: threadMessages.map(threadMessageSeed)
            )
            contexts.append(AskThreadContext(
                threadId: threadId,
                subject: threadSubject,
                anchorMessageIds: anchors.filter { threadMessageIds.contains($0) },
                messages: messages
            ))
        }

        return AskThreadExpansion(
            additionalSources: additionalSources,
            contexts: contexts,
            visualEvidence: visualEvidence
        )
    }

    private func uniqueAnchorMessageIds(from sources: [RetrievalResult]) -> [String] {
        var seen = Set<String>()
        return sources.compactMap { source in
            let messageId = source.record.messageId
            guard UUID(uuidString: messageId) != nil,
                  seen.insert(messageId).inserted
            else {
                return nil
            }
            return messageId
        }
    }

    private func visualEvidence(for messageIds: [String]) -> [AskVisualAttachmentEvidence] {
        var evidence: [AskVisualAttachmentEvidence] = []
        var seen = Set<String>()
        for messageId in messageIds {
            guard let message = fetchMessage(id: messageId) else { continue }
            for attachment in message.attachments {
                guard let packet = AttachmentEvidencePacket(attachment: attachment, messageId: messageId),
                      let item = AskVisualAttachmentEvidence(packet: packet) else {
                    continue
                }
                let key = item.attachmentId ?? "\(messageId):\(item.filename)"
                guard seen.insert(key).inserted else { continue }
                evidence.append(item)
                if evidence.count == 12 { return evidence }
            }
        }
        return evidence
    }

    private func fetchMessage(id messageId: String) -> Message? {
        guard let id = UUID(uuidString: messageId) else { return nil }
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func selectedMessages(from messages: [Message], anchorIds: [String]) -> [Message] {
        let sorted = messages.sorted(by: messageChronology)
        guard sorted.count > maxMessagesPerThread else { return sorted }

        let anchorSet = Set(anchorIds)
        var selectedIndexes = Set<Int>()
        for (index, message) in sorted.enumerated() where anchorSet.contains(message.id.uuidString) {
            let lower = max(0, index - 2)
            let upper = min(sorted.count - 1, index + 3)
            for candidate in lower...upper {
                selectedIndexes.insert(candidate)
            }
        }

        if selectedIndexes.isEmpty, let firstAnchor = sorted.firstIndex(where: { anchorSet.contains($0.id.uuidString) }) {
            selectedIndexes.insert(firstAnchor)
        }

        var newestIndex = sorted.count - 1
        while selectedIndexes.count < maxMessagesPerThread, newestIndex >= 0 {
            selectedIndexes.insert(newestIndex)
            newestIndex -= 1
        }

        return selectedIndexes
            .sorted()
            .prefix(maxMessagesPerThread)
            .map { sorted[$0] }
    }

    private func messageChronology(_ lhs: Message, _ rhs: Message) -> Bool {
        let lhsDate = lhs.vectorTimeFilterDate ?? lhs.ingestedAt
        let rhsDate = rhs.vectorTimeFilterDate ?? rhs.ingestedAt
        if lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func sourceResult(for message: Message) -> RetrievalResult? {
        do {
            let vectorIds = try vectorStore.vectorIds(
                forMessageIds: [message.id.uuidString],
                filter: FilterSpec(collections: [.context]),
                limit: 8
            )
            let records = try vectorStore.hydrate(vectorIds: vectorIds)
            // `chunkIndex == 0` is the summary vector (metadata-rich); body chunks live at
            // `chunkIndex >= 1` and now embed only their own body text. Prefer a body
            // chunk over the summary when available; fall back to the first record.
            guard let record = records.first(where: { $0.chunkIndex >= 1 }) ?? records.first
            else {
                return nil
            }
            return RetrievalResult(record: record, score: 0.5, attribution: .sparse)
        } catch {
            return nil
        }
    }

    private func displaySender(_ message: Message) -> String {
        if let name = message.fromName, !name.isEmpty {
            return "\(name) <\(message.fromAddress)>"
        }
        return message.fromAddress
    }

    private func threadMessageSeed(_ message: Message) -> ThreadMessageSeed {
        ThreadMessageSeed(
            messageId: message.id.uuidString,
            from: displaySender(message),
            date: message.vectorTimeFilterDate,
            subject: message.subject,
            bodyTextPath: message.bodyTextPath
        )
    }

    private func askThreadMessages(from seeds: [ThreadMessageSeed]) async -> [AskThreadMessage] {
        let bodyExcerptLimit = bodyExcerptLimit
        return await Task.detached(priority: .userInitiated) {
            seeds.map { seed in
                AskThreadMessage(
                    messageId: seed.messageId,
                    from: seed.from,
                    date: seed.date,
                    subject: seed.subject,
                    bodyExcerpt: Self.bodyExcerpt(
                        bodyTextPath: seed.bodyTextPath,
                        fallbackSubject: seed.subject,
                        limit: bodyExcerptLimit
                    )
                )
            }
        }.value
    }

    private nonisolated struct ThreadMessageSeed: Sendable {
        let messageId: String
        let from: String
        let date: Date?
        let subject: String
        let bodyTextPath: String?
    }

    private nonisolated static func bodyExcerpt(
        bodyTextPath: String?,
        fallbackSubject: String,
        limit: Int
    ) -> String {
        let raw: String
        if let path = bodyTextPath,
           let text = try? String(contentsOfFile: path, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = text
        } else {
            raw = fallbackSubject
        }

        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "..."
    }
}
