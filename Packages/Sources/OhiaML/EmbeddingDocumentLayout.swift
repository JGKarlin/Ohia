import Foundation
import OhiaCore

/// Sizes every document Ohia embeds to the embedding model's input window,
/// measured with the model's own tokenizer.
///
/// Two texts are produced for each vector: the document that is embedded,
/// which always fits the window, and the payload stored beside the vector for
/// display, retrieval prompts and meaning features, which keeps the message's
/// full header fields as before. Header fields in embedded documents are
/// capped so a long subject or a message with dozens of attachments cannot
/// crowd out the text the vector is meant to represent.
struct EmbeddingDocumentLayout: Sendable {
    /// Summary vectors open with up to this many tokens of the body (about the
    /// first 100 words of English) before the evidence digest.
    static let summaryBodyPreviewTokens = 150
    static let senderTokenLimit = 32
    static let subjectTokenLimit = 64
    static let attachmentListTokenLimit = 48
    static let attachmentOverflowReserveTokens = 6
    static let filenameTokenLimit = 32
    static let recipientTokenLimit = 64
    /// Room left for tokenization differences where a header meets its text.
    static let joinMarginTokens = 4
    static let minimumChunkTokens = 64

    let tokenizer: any EmbeddingDocumentTokenizing

    var capacity: Int { tokenizer.contentTokenCapacity }

    var overlapDivisor: Int { 4 }

    // MARK: Headers

    func fittedMetadata(_ metadata: MessageMetadata) -> MessageMetadata {
        MessageMetadata(
            from: fittedSender(metadata.from),
            to: prefix(metadata.to, fitting: Self.senderTokenLimit),
            dateBucket: metadata.dateBucket,
            subject: prefix(metadata.subject, fitting: Self.subjectTokenLimit),
            attachments: fittedAttachmentNames(metadata.attachments),
            language: metadata.language
        )
    }

    func fittedFilename(_ filename: String) -> String {
        prefix(filename, fitting: Self.filenameTokenLimit)
    }

    /// Keeps the address of a "Name <address>" sender whole, because sender
    /// domains feed meaning features, and shortens the display name instead.
    func fittedSender(_ sender: String) -> String {
        guard tokenizer.contentTokenCount(sender) > Self.senderTokenLimit else { return sender }
        guard let open = sender.lastIndex(of: "<"), sender.hasSuffix(">") else {
            return prefix(sender, fitting: Self.senderTokenLimit)
        }
        let address = String(sender[open...])
        let name = String(sender[..<open]).trimmingCharacters(in: .whitespaces)
        let room = Self.senderTokenLimit - tokenizer.contentTokenCount(address) - 1
        guard room > 0, name.isEmpty == false else {
            return prefix(address, fitting: Self.senderTokenLimit)
        }
        let shortened = prefix(name, fitting: room)
        return shortened.isEmpty ? address : "\(shortened) \(address)"
    }

    /// Lists attachment names until the list reaches its budget, then says
    /// how many more there are.
    func fittedAttachmentNames(_ names: [String]) -> [String] {
        guard names.isEmpty == false else { return [] }
        var kept: [String] = []
        var used = 0
        for name in names {
            let isLast = kept.count == names.count - 1
            let reserve = isLast ? 0 : Self.attachmentOverflowReserveTokens
            let cost = tokenizer.contentTokenCount(name) + 1
            guard used + cost + reserve <= Self.attachmentListTokenLimit else { break }
            kept.append(name)
            used += cost
        }
        if kept.isEmpty {
            let first = prefix(
                names[0],
                fitting: Self.attachmentListTokenLimit - Self.attachmentOverflowReserveTokens
            )
            if first.isEmpty == false {
                kept.append(first)
            }
        }
        let omitted = names.count - kept.count
        if omitted > 0 {
            kept.append("and \(omitted) more")
        }
        return kept
    }

    // MARK: Documents

    func bodyChunks(_ text: String) -> [TextChunk] {
        EmbeddingChunker.chunk(text, capacity: capacity, overlap: capacity / overlapDivisor, tokenizer: tokenizer)
    }

    func chunkTexts(_ text: String, capacity chunkCapacity: Int) -> [String] {
        EmbeddingChunker.chunk(
            text,
            capacity: chunkCapacity,
            overlap: chunkCapacity / overlapDivisor,
            tokenizer: tokenizer
        ).map(\.text)
    }

    /// Content tokens a chunk may hold after `header`.
    func chunkCapacity(afterHeader header: String) -> Int {
        max(Self.minimumChunkTokens, capacity - tokenizer.contentTokenCount(header) - Self.joinMarginTokens)
    }

    /// The summary vector's document and payload. The document holds the
    /// header, the body preview, and as much of the evidence digest as fits;
    /// the payload keeps the full header and the whole digest.
    func summaryDocuments(
        embeddedMetadata: MessageMetadata,
        payloadMetadata: MessageMetadata,
        body: String,
        digest: String?
    ) -> (document: String, payload: String) {
        let preview = bodyPreview(body)
        let payload = EmbeddingDocumentBuilder.buildSummaryDocument(
            metadata: payloadMetadata,
            bodyPreview: preview,
            messageEvidenceDigest: digest
        )
        let full = EmbeddingDocumentBuilder.buildSummaryDocument(
            metadata: embeddedMetadata,
            bodyPreview: preview,
            messageEvidenceDigest: digest
        )
        if tokenizer.contentTokenCount(full) <= capacity {
            return (full, payload)
        }
        let withoutDigest = EmbeddingDocumentBuilder.buildSummaryDocument(
            metadata: embeddedMetadata,
            bodyPreview: preview,
            messageEvidenceDigest: nil
        )
        let room = capacity - tokenizer.contentTokenCount(withoutDigest) - Self.joinMarginTokens
        guard let digest, room > 0 else {
            return (verified(withoutDigest), payload)
        }
        let fittedDigest = prefix(digest, fitting: room)
        let document = EmbeddingDocumentBuilder.buildSummaryDocument(
            metadata: embeddedMetadata,
            bodyPreview: preview,
            messageEvidenceDigest: fittedDigest.isEmpty ? nil : fittedDigest
        )
        return (verified(document), payload)
    }

    /// The opening of the body on one line. `BODY_PREVIEW` is a single
    /// `KEY: value` line: readers of the stored payload
    /// (`ClusterDetector.meaningFeatures`, neighbour excerpts, search cues)
    /// parse it line by line, so a body line break would cut the preview short
    /// and a body line such as "From: …" would pose as a header field.
    func bodyPreview(_ body: String) -> String {
        let previewTokens = min(Self.summaryBodyPreviewTokens, capacity / 2)
        // A token covers at most a few dozen characters, so this much of the
        // body always holds the preview; flattening stays proportional to it.
        let lead = body.drop(while: { $0.isWhitespace }).prefix(previewTokens * Self.maximumCharactersPerToken)
        let flattened = lead
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return prefix(flattened, fitting: previewTokens)
    }

    static let maximumCharactersPerToken = 24

    /// The style exemplar's document, the start of the sent text that fits,
    /// and its payload, the whole sent text.
    func styleDocuments(recipientInfo: String, sentText: String) -> (document: String, payload: String) {
        let payload = EmbeddingDocumentBuilder.buildStyleExemplar(recipientInfo: recipientInfo, sentText: sentText)
        if tokenizer.contentTokenCount(payload) <= capacity {
            return (payload, payload)
        }
        let recipients = prefix(recipientInfo, fitting: Self.recipientTokenLimit)
        let header = EmbeddingDocumentBuilder.styleExemplarHeader(recipientInfo: recipients)
        let room = capacity - tokenizer.contentTokenCount(header) - Self.joinMarginTokens
        let sent = room > 0 ? prefix(sentText, fitting: room) : ""
        let document = EmbeddingDocumentBuilder.buildStyleExemplar(recipientInfo: recipients, sentText: sent)
        return (verified(document), payload)
    }

    struct StructuredWindow: Sendable {
        let embeddingText: String
        let plainText: String
        let metadata: AttachmentRAGMetadata
    }

    /// Splits one structured attachment chunk (a PDF page region, a Word
    /// section, a sheet region) into windows that fit after the attachment
    /// header. When the chunk's embedding text is a locator header followed
    /// by its plain text, every window repeats that header, so later windows
    /// still name their file, page or section. Otherwise (a slide whose notes
    /// sit between locator and content) the embedding text itself is split and
    /// every window's payload stays the chunk's plain text, as it was when the
    /// chunk was one vector. Each window keeps the chunk's source metadata.
    func structuredWindows(for chunk: AttachmentRAGChunk, chunkCapacity: Int) -> [StructuredWindow] {
        let plain = chunk.plainText
        let embedding = chunk.embeddingText
        if plain.isEmpty == false, embedding.hasSuffix(plain) {
            let locator = String(embedding.dropLast(plain.count))
            let contentCapacity = chunkCapacity - tokenizer.contentTokenCount(locator) - Self.joinMarginTokens
            if contentCapacity >= Self.minimumChunkTokens {
                return chunkTexts(plain, capacity: contentCapacity).map {
                    StructuredWindow(embeddingText: locator + $0, plainText: $0, metadata: chunk.metadata)
                }
            }
        }
        return chunkTexts(embedding, capacity: chunkCapacity).map {
            StructuredWindow(embeddingText: $0, plainText: plain.isEmpty ? $0 : plain, metadata: chunk.metadata)
        }
    }

    /// Measures a finished document and, if it is still over the window,
    /// fits it rather than let the model cut it off unseen. Reaching the fit
    /// means a header or join was larger than its budget allowed for.
    func verified(_ document: String) -> String {
        guard tokenizer.contentTokenCount(document) > capacity else { return document }
        print("[Embed] a document exceeded the \(capacity)-token embedding window and was fitted to it")
        return prefix(document, fitting: capacity)
    }

    private func prefix(_ text: String, fitting tokens: Int) -> String {
        EmbeddingChunker.prefix(of: text, fitting: tokens, tokenizer: tokenizer)
    }
}
