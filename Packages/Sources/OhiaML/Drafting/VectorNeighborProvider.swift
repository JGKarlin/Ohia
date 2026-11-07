// VectorNeighborProvider.swift
// Real implementation of NeighborProviding. Uses the VectorStore to resolve
// citation/finding sources to real message records and HybridRetriever to
// surface additional similar messages.
//
// Source panel:
//   1. Each Citation → look up its sourceMessageId in VectorStore
//      (.context collection) and pull FROM:/SUBJECT: from the text payload.
//   2. Each Finding that references a source message → same.
//   3. Top-K hybrid neighbors from the .context collection, keyed by
//      `correspondent + subject`, excluding already-cited messages.
//
// (The Composer's Style panel no longer lists exemplar messages — it renders
// the resolved StyleRegister card; exemplar retrieval for prompts lives in
// StyleExemplarRetriever.)
//
// Everything degrades gracefully: empty vectors, unparsable payloads, or
// embedding failures return sensible defaults instead of throwing.

import Foundation
import OhiaCore

public final class VectorNeighborProvider: NeighborProviding, @unchecked Sendable {

    private let vectorStore: VectorStore
    private let hybridRetriever: HybridRetriever
    private let maxSourceNeighbors: Int

    public init(
        vectorStore: VectorStore,
        hybridRetriever: HybridRetriever,
        maxSourceNeighbors: Int = 6
    ) {
        self.vectorStore = vectorStore
        self.hybridRetriever = hybridRetriever
        self.maxSourceNeighbors = maxSourceNeighbors
    }

    public func fetchNeighbors(
        citations: [Citation],
        findings: [Finding],
        correspondentEmail: String,
        subject: String
    ) -> FocusNeighborSet {
        FocusNeighborSet(
            sourceNeighbors: buildSourceNeighbors(
                citations: citations,
                findings: findings,
                subject: subject,
                correspondentEmail: correspondentEmail
            )
        )
    }

    // MARK: - Source neighbors

    private func buildSourceNeighbors(
        citations: [Citation],
        findings: [Finding],
        subject: String,
        correspondentEmail: String
    ) -> [NeighborData] {
        var neighbors: [NeighborData] = []
        var seen = Set<String>()

        // 1) Cited sources
        for citation in citations {
            let msgId = citation.sourceMessageId
            guard !seen.contains(msgId) else { continue }
            seen.insert(msgId)

            let record = firstRecord(forMessageId: msgId)
            neighbors.append(NeighborData(
                senderName: record.flatMap { extractField($0.textPayload, key: "FROM") } ?? "(source)",
                subject: record.flatMap { extractField($0.textPayload, key: "SUBJECT") } ?? citation.claim,
                similarityScore: citation.confidence,
                relationshipLabel: "cited source",
                excerpt: String(citation.claim.prefix(80)),
                messageID: UUID(uuidString: msgId)
            ))
        }

        // 2) Findings that name a source message
        for finding in findings {
            guard let msgId = finding.sourceMessageId, !seen.contains(msgId) else { continue }
            seen.insert(msgId)

            let record = firstRecord(forMessageId: msgId)
            neighbors.append(NeighborData(
                senderName: record.flatMap { extractField($0.textPayload, key: "FROM") } ?? "(source)",
                subject: record.flatMap { extractField($0.textPayload, key: "SUBJECT") } ?? finding.text,
                similarityScore: finding.confidence,
                relationshipLabel: "agent finding",
                excerpt: String(finding.text.prefix(80)),
                messageID: UUID(uuidString: msgId)
            ))
        }

        // 3) Semantic neighbors from the broader context corpus
        let query = "correspondent=\(correspondentEmail) subject=\(subject)"
        let results = (try? hybridRetriever.retrieve(
            query: query,
            filter: FilterSpec(collections: [.context]),
            k: maxSourceNeighbors * 2
        )) ?? []
        for result in results {
            let msgId = result.record.messageId
            if seen.contains(msgId) { continue }
            seen.insert(msgId)

            let payload = result.record.textPayload
            let excerpt = extractField(payload, key: "BODY_PREVIEW")
                ?? extractField(payload, key: "BODY")
                ?? ""
            neighbors.append(NeighborData(
                senderName: extractField(payload, key: "FROM") ?? "(unknown)",
                subject: extractField(payload, key: "SUBJECT") ?? "(untitled)",
                similarityScore: Double(result.score),
                relationshipLabel: "similar context",
                excerpt: String(excerpt.prefix(80)),
                messageID: UUID(uuidString: msgId)
            ))
            if neighbors.count >= maxSourceNeighbors { break }
        }

        return Array(neighbors.prefix(maxSourceNeighbors))
    }

    // MARK: - Payload parsing

    /// Pulls the first vector record for the given message id — typically
    /// the summary embedding at chunkIndex 0, whose payload carries the
    /// `FROM:`/`SUBJECT:` metadata we want for display.
    private func firstRecord(forMessageId id: String) -> VectorRecord? {
        guard let records = try? vectorStore.vectorsForMessage(messageId: id) else { return nil }
        return records.sorted { $0.chunkIndex < $1.chunkIndex }.first
    }

    /// Extracts a single `KEY: value` line from the embedding document.
    private func extractField(_ payload: String, key: String) -> String? {
        let prefix = "\(key): "
        for rawLine in payload.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

}
