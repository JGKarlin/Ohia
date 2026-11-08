import Foundation
import os
import SwiftData
import OhiaCore

// MARK: - EmbeddingOrchestrator

/// Signposter for the detached embed phase. Profile via Instruments ->
/// Points of Interest or os_signpost to confirm embedding work actually
/// runs off MainActor and to measure per-batch duration.
private let embedSignposter = OSSignposter(
    subsystem: "org.jgkarlin.Ohia",
    category: "embed"
)

/// Processes messages through the full embedding pipeline: context chunks,
/// style exemplars, and attachment embeddings.
public final class EmbeddingOrchestrator: @unchecked Sendable {

    private let embedder: EmbeddingProvider
    private let vectorStore: VectorStore
    private let canonicalStore: CanonicalStore
    private let ftsIndex: MessageFTSIndex?
    private let messageStoreURL: URL?
    private let meaningFeatureStore: VectorMeaningFeatureStore

    public var currentEmbeddingVersion: String { embedder.embeddingVersion }

    public enum EmbeddingError: Error, Sendable, Equatable {
        case noVectorsProduced
        /// The embedder cannot measure documents right now (its model is not
        /// loaded), so nothing is embedded and existing vectors are kept.
        case documentTokenizerUnavailable
    }

    public init(
        embedder: EmbeddingProvider,
        vectorStore: VectorStore,
        canonicalStore: CanonicalStore,
        ftsIndex: MessageFTSIndex? = nil,
        messageStoreURL: URL? = nil,
        meaningFeatureStore: VectorMeaningFeatureStore? = nil
    ) {
        self.embedder = embedder
        self.vectorStore = vectorStore
        self.canonicalStore = canonicalStore
        self.ftsIndex = ftsIndex
        self.messageStoreURL = messageStoreURL
        // The feature store is a sibling of the vector store (shared SQLite
        // handle + lock), so when the caller does not inject one — AppServices
        // passes its shared instance — deriving it here keeps every
        // construction site writing meaning features with no parallel
        // featureless path.
        self.meaningFeatureStore = meaningFeatureStore ?? VectorMeaningFeatureStore(
            sharedDB: vectorStore.rawHandle,
            lock: vectorStore.rawLock
        )
    }

    // MARK: - Single Message Embedding

    /// Embeds a single message through the full pipeline:
    /// 1. Deletes any existing vectors (for re-embedding)
    /// 2. Loads body text from CanonicalStore
    /// 3. Creates summary embedding (context collection, chunkIndex 0)
    /// 4. Creates body chunk embeddings (context collection, sequential chunkIndex)
    /// 5. If sent by user, creates style exemplar (style collection)
    /// 6. For each attachment with extracted text, creates attachment embeddings
    /// 7. Sets embeddingStatus to .completed
    ///
    /// Async shape: the detached phase does embedding work + VectorStore
    /// inserts off MainActor. VectorStore is SQLite in serialized mode so the
    /// writes are thread-safe. A message can drive several embedding calls
    /// (summary + body chunks + style + attachment chunks), so a batch of
    /// messages on MainActor would freeze the UI — now it happens in the
    /// background.
    @MainActor
    public func embedMessage(_ message: Message, context: ModelContext) async throws {
        guard !message.isTrashed else { return }
        // Checked before extraction, which deletes the message's existing
        // vectors, so a model that is not loaded leaves them in place. A model
        // unloaded after this point still fails the message (`.failed`), and
        // the next pass re-embeds it.
        guard let tokenizer = embedder.documentTokenizer else {
            throw EmbeddingError.documentTokenizerUnavailable
        }
        let messageId = message.id.uuidString
        var completedSuccessfully = false
        defer {
            if !completedSuccessfully {
                message.embeddingStatus = .failed
                message.embeddedAt = nil
                try? context.save()
            }
        }

        // Phase 1: extract all Sendable inputs on MainActor.
        let seed = try extractInputSeed(messageId: messageId, message: message)

        // Phase 2: detached — read files, measure and build documents, embed,
        // and persist vectors. Measuring tokenizes every document, so none of
        // it runs on the MainActor.
        let embedder = self.embedder
        let vectorStore = self.vectorStore
        let meaningFeatureStore = self.meaningFeatureStore
        let (input, vectorsInserted) = try await Task.detached(priority: .utility) {
            [embedder, vectorStore, meaningFeatureStore] in
            let input = EmbeddingOrchestrator.materializeInput(seed, tokenizer: tokenizer)
            let chunkCount = input.bodyChunks.count
                + input.attachmentChunks.reduce(0) { total, attachment in
                    total + attachment.cardChunks.reduce(0) { $0 + $1.embeddingDocuments.count }
                }
                + 1
            let sig = embedSignposter.beginInterval(
                "message", id: embedSignposter.makeSignpostID(),
                "chunks=\(chunkCount)"
            )
            let inserted = try EmbeddingOrchestrator.performEmbedding(
                input: input,
                embedder: embedder,
                vectorStore: vectorStore,
                meaningFeatureStore: meaningFeatureStore
            )
            embedSignposter.endInterval("message", sig, "status=ok")
            return (input, inserted)
        }.value
        guard vectorsInserted > 0 else {
            throw EmbeddingError.noVectorsProduced
        }
        try EmbeddingOrchestrator.syncFTS(input: input, ftsIndex: ftsIndex)
        if message.isTrashed {
            // Delete may run while detached inference is suspended. Enforce the
            // current SwiftData lifecycle after every sidecar write so those
            // late vectors/FTS rows cannot re-enter active search or retrieval.
            try vectorStore.setMessageActive(messageId: messageId, isActive: false)
            try ftsIndex?.setMessageActive(messageId: messageId, isActive: false)
        }

        // Phase 3: mark completed on MainActor.
        message.embeddingStatus = .completed
        message.embeddedAt = Date()
        try context.save()
        completedSuccessfully = true
    }

    @MainActor
    public func reembedMessage(messageId: String, context: ModelContext) async throws {
        guard let id = UUID(uuidString: messageId) else { return }
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == id }
        )
        guard let message = try context.fetch(descriptor).first else { return }
        try await embedMessage(message, context: context)
    }

    // MARK: - Batch Embedding

    /// Fetches messages still awaiting embedding and processes them.
    ///
    /// Eligibility includes both `.pending` (never attempted) and `.failed`
    /// (a previous attempt threw and was marked retryable by `embedMessage`).
    /// `.processing` would
    /// indicate a crash mid-attempt and is also retried.
    ///
    /// Errors are isolated per message: a single throw is logged and the
    /// loop continues with the next row. Without this isolation a single
    /// poisonous message would kill the whole batch and the same row would
    /// block every subsequent attempt — leaving the user with a permanently-
    /// stalled `embedded N / total` gauge and no recovery path short of a
    /// developer button. Per-message errors do NOT propagate to the
    /// scheduler — the `.embed` job always completes successfully so that
    /// a fresh job re-enqueues and the next 50 messages get a chance.
    @MainActor
    public func embedPendingMessages(
        context: ModelContext,
        batchSize: Int = 50,
        documentBatchSize: Int = 24,
        taskPriority: TaskPriority = .utility,
        interMessageDelayNanoseconds: UInt64 = 0,
        embeddingLaneLimit: Int = 1,
        shouldYield: @escaping @MainActor @Sendable () -> Bool = { false }
    ) async throws -> Int {
        guard !embeddingProviderUnavailable, let tokenizer = embedder.documentTokenizer else {
            return 0
        }

        let messages = try MessageBatchSelector.fetchMessages(
            stage: .embeddingPending,
            limit: batchSize,
            context: context,
            storeURL: messageStoreURL
        ) {
            try context.fetch(FetchDescriptor<Message>())
                .filter { !$0.isTrashed && $0.embeddingStatus != .completed }
        }

        // Phase 1: extract every Sendable input on MainActor, in one pass.
        // This is the only phase that touches `Message` directly. Messages
        // that fail extraction are flagged `.failed` here and excluded
        // from the parallel embed phase below.
        var inputs: [(messageId: UUID, input: EmbeddingInputSeed)] = []
        inputs.reserveCapacity(messages.count)
        for message in messages {
            do {
                let input = try extractInputSeed(messageId: message.id.uuidString, message: message)
                inputs.append((message.id, input))
            } catch {
                message.embeddingStatus = .failed
                print("[Embed] extract failed \(message.id.uuidString): \(String(reflecting: type(of: error)))")
            }
        }

        // Phase 2: materialize documents and embed off MainActor. The Core ML
        // adapter owns tokenizer/model serialization, so throughput comes from
        // feeding it bounded batches instead of launching competing predictors.
        let embedder = self.embedder
        let vectorStore = self.vectorStore
        let ftsIndex = self.ftsIndex
        let meaningFeatureStore = self.meaningFeatureStore
        let signposter = embedSignposter

        let batchOutcome = await Task.detached(priority: taskPriority) {
            let sig = signposter.beginInterval(
                "batch", id: signposter.makeSignpostID(),
                "messages=\(inputs.count)"
            )
            // Measuring documents is real work, so the foreground throttle is
            // honored between messages here too; messages not reached stay
            // pending for the next pass.
            var materialized: [(messageId: UUID, input: EmbeddingInput)] = []
            materialized.reserveCapacity(inputs.count)
            var notReached: Set<UUID> = []
            for (offset, item) in inputs.enumerated() {
                if await shouldYield() {
                    notReached = Set(inputs[offset...].map(\.messageId))
                    break
                }
                materialized.append((
                    messageId: item.messageId,
                    input: EmbeddingOrchestrator.materializeInput(item.input, tokenizer: tokenizer)
                ))
            }
            let embedded = await EmbeddingOrchestrator.performEmbeddingBatch(
                inputs: materialized,
                embedder: embedder,
                vectorStore: vectorStore,
                ftsIndex: ftsIndex,
                meaningFeatureStore: meaningFeatureStore,
                documentBatchSize: documentBatchSize,
                taskPriority: taskPriority,
                interMessageDelayNanoseconds: interMessageDelayNanoseconds,
                embeddingLaneLimit: embeddingLaneLimit,
                shouldYield: shouldYield
            )
            let outcome = EmbeddingBatchOutcome(
                succeededIds: embedded.succeededIds,
                deferredIds: embedded.deferredIds.union(notReached)
            )
            signposter.endInterval(
                "batch",
                sig,
                "succeeded=\(outcome.succeededIds.count) deferred=\(outcome.deferredIds.count)"
            )
            return outcome
        }.value

        // Phase 3: mark statuses on MainActor in a single pass and save
        // once. Saving per-message used to fan out a SwiftData
        // notification storm to every observing @Query in the UI.
        let completedAt = Date()
        for message in messages {
            if batchOutcome.succeededIds.contains(message.id) {
                if message.isTrashed {
                    let messageId = message.id.uuidString
                    try vectorStore.setMessageActive(messageId: messageId, isActive: false)
                    try ftsIndex?.setMessageActive(messageId: messageId, isActive: false)
                }
                message.embeddingStatus = .completed
                message.embeddedAt = completedAt
            } else if batchOutcome.deferredIds.contains(message.id) {
                message.embeddingStatus = .pending
            } else if message.embeddingStatus != .failed {
                // `.failed` rows from extraction are already set above;
                // don't downgrade them.
                message.embeddingStatus = .failed
            }
        }
        try? context.save()

        return batchOutcome.succeededIds.count
    }

    private var embeddingProviderUnavailable: Bool {
        if embedder is UnavailableEmbedder { return true }
        if let swappable = embedder as? SwappableEmbedder {
            return swappable.isUsingUnavailableProvider
        }
        return false
    }

    // MARK: - Phase 1 — MainActor input extraction

    private struct EmbeddingInputSeed: Sendable {
        let messageId: String
        let subject: String
        let senderEmail: String
        let accountId: String?
        let hasAttachment: Bool
        let metadata: MessageMetadata
        let bodyTextPath: String?
        let isSentByUser: Bool
        let recipientInfo: String
        let embeddingVersion: String
        let attachmentTextFiles: [AttachmentTextFile]
        /// Message-date timestamp forwarded to every `VectorStore.insert`
        /// call below. Populated from `Message.vectorTimeFilterDate` at
        /// extract time. Stored on the vector row as the canonical source for
        /// the HUD time-filter buttons. Nil means the email has no sent or
        /// received date and must not match ranged Moments filters.
        let messageReceivedAt: TimeInterval?
    }

    /// Every document here already fits the embedding model's window
    /// (`EmbeddingDocumentLayout`); payloads are what is stored beside each
    /// vector.
    private struct EmbeddingInput: Sendable {
        let messageId: String
        let subject: String
        let senderEmail: String
        let accountId: String?
        let hasAttachment: Bool
        let metadata: MessageMetadata
        let summaryDocument: String
        let summaryPayload: String
        let bodyChunks: [TextChunk]
        let bodyText: String
        let styleDocument: String?
        let stylePayload: String?
        let embeddingVersion: String
        let attachmentChunks: [AttachmentChunks]
        let messageReceivedAt: TimeInterval?
    }

    private struct AttachmentTextFile: Sendable {
        let attachmentId: String?
        let filename: String
        let mimeType: String
        /// `nil` for attachments with no extracted text whose only evidence is
        /// recorded capture metadata (Mail Drop videos, photos without a caption).
        let path: String?
        let embeddingPath: String?
        let ragDocumentPath: String?
        let contentId: String?
        let isInline: Bool
        let evidencePacket: AttachmentEvidencePacket?
    }

    private struct AttachmentCardChunks: Sendable {
        let card: AttachmentEvidenceCard
        /// Attachment header plus one text window each, ready to embed.
        let embeddingDocuments: [String]
        /// Aligned with `embeddingDocuments`: the full-header payload stored
        /// beside each vector.
        let payloadDocuments: [String]
        let chunkMetadata: [AttachmentRAGMetadata?]
    }

    private struct AttachmentChunks: Sendable {
        let attachmentId: String?
        let filename: String
        let mimeType: String
        let contentId: String?
        let isInline: Bool
        let cardChunks: [AttachmentCardChunks]
        let evidencePacket: AttachmentEvidencePacket?
    }

    @MainActor
    private func extractInputSeed(messageId: String, message: Message) throws -> EmbeddingInputSeed {
        // Delete any existing vectors up front so a re-embed replaces them.
        // Safe to do on MainActor — SQLite write is fast.
        try vectorStore.deleteVectors(forMessageId: messageId)

        let metadata = buildMetadata(from: message)
        let isSentByUser = message.isSentByUser
        let recipientInfo = isSentByUser ? buildRecipientInfo(from: message) : ""
        let attachmentTextFiles = message.attachments.compactMap { attachment -> AttachmentTextFile? in
            let packet = AttachmentEvidencePacket(attachment: attachment, messageId: messageId)
            guard attachment.extractedTextPath != nil || packet?.hasCaptureMetadata == true else { return nil }
            return AttachmentTextFile(
                attachmentId: attachment.id.uuidString,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                path: attachment.extractedTextPath,
                embeddingPath: attachment.embeddingTextPath,
                ragDocumentPath: attachment.ragDocumentPath,
                contentId: attachment.contentId,
                isInline: attachment.isInline == true,
                evidencePacket: packet
            )
        }

        return EmbeddingInputSeed(
            messageId: messageId,
            subject: message.subject,
            senderEmail: message.fromAddress,
            accountId: (message.accountID ?? message.account?.id)?.uuidString,
            hasAttachment: message.hasAttachments,
            metadata: metadata,
            bodyTextPath: message.bodyTextPath,
            isSentByUser: isSentByUser,
            recipientInfo: recipientInfo,
            embeddingVersion: embedder.embeddingVersion,
            attachmentTextFiles: attachmentTextFiles,
            messageReceivedAt: message.vectorTimeFilterDate?.timeIntervalSince1970
        )
    }

    // MARK: - Phase 2 — detached embedding + storage

    private static func materializeInput(
        _ seed: EmbeddingInputSeed,
        tokenizer: any EmbeddingDocumentTokenizing
    ) -> EmbeddingInput {
        let layout = EmbeddingDocumentLayout(tokenizer: tokenizer)
        let embeddedMetadata = layout.fittedMetadata(seed.metadata)
        let bodyText: String
        if let bodyTextPath = seed.bodyTextPath {
            bodyText = (try? String(contentsOfFile: bodyTextPath, encoding: .utf8)) ?? ""
        } else {
            bodyText = ""
        }
        let searchableBodyText = OriginalMessageText.cleaned(from: bodyText) ?? ""
        let styleBodyText = seed.isSentByUser
            ? AuthoredReplyText.extract(from: bodyText)
            : ""

        var attachmentChunks: [AttachmentChunks] = []
        for attachment in seed.attachmentTextFiles {
            let extractedText: String
            if let path = attachment.path {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                extractedText = text
            } else {
                guard attachment.evidencePacket?.hasCaptureMetadata == true else { continue }
                extractedText = ""
            }
            let embeddingSourceText = attachment.embeddingPath
                .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackEmbeddingText = embeddingSourceText?.isEmpty == false
                ? embeddingSourceText!
                : extractedText
            let structuredDocument = attachment.ragDocumentPath.flatMap(Self.loadRAGDocument)
            let embeddedHeader = EmbeddingDocumentBuilder.attachmentDocumentHeader(
                metadata: embeddedMetadata,
                filename: layout.fittedFilename(attachment.filename)
            )
            let payloadHeader = EmbeddingDocumentBuilder.attachmentDocumentHeader(
                metadata: seed.metadata,
                filename: attachment.filename
            )
            let chunkCapacity = layout.chunkCapacity(afterHeader: embeddedHeader)
            let cards = attachment.evidencePacket?.evidenceCards(fallbackExtractedText: extractedText) ?? [
                AttachmentEvidenceCard(
                    id: [attachment.attachmentId, attachment.filename, AttachmentEvidenceModality.extractedText.rawValue]
                        .compactMap { $0 }
                        .joined(separator: ":"),
                    messageId: seed.messageId,
                    attachmentId: attachment.attachmentId,
                    filename: attachment.filename,
                    mimeType: attachment.mimeType,
                    modality: .extractedText,
                    evidenceKind: nil,
                    confidence: nil,
                    text: extractedText
                )
            ]
            let cardChunks: [AttachmentCardChunks]
            if let structuredDocument, !structuredDocument.chunks.isEmpty {
                let card = cards.first(where: { $0.modality == .extractedText }) ?? AttachmentEvidenceCard(
                    id: [attachment.attachmentId, attachment.filename, AttachmentEvidenceModality.extractedText.rawValue]
                        .compactMap { $0 }
                        .joined(separator: ":"),
                    messageId: seed.messageId,
                    attachmentId: attachment.attachmentId,
                    filename: attachment.filename,
                    mimeType: attachment.mimeType,
                    modality: .extractedText,
                    evidenceKind: "structured-rag",
                    confidence: nil,
                    text: structuredDocument.plainText.isEmpty ? extractedText : structuredDocument.plainText
                )
                let windows = structuredDocument.chunks.flatMap {
                    layout.structuredWindows(for: $0, chunkCapacity: chunkCapacity)
                }
                cardChunks = [
                    AttachmentCardChunks(
                        card: card,
                        embeddingDocuments: windows.map { layout.verified(embeddedHeader + $0.embeddingText) },
                        payloadDocuments: windows.map { payloadHeader + $0.plainText },
                        chunkMetadata: windows.map(\.metadata)
                    )
                ].filter { !$0.embeddingDocuments.isEmpty }
            } else {
                cardChunks = cards
                    .filter(\.isUseful)
                    .map { card in
                        let embeddingPayload = card.modality == .extractedText
                            ? extractedTextSemanticPayload(card: card, text: fallbackEmbeddingText)
                            : card.semanticText
                        let embeddingChunks = layout.chunkTexts(embeddingPayload, capacity: chunkCapacity)
                        let plainChunks = layout.chunkTexts(card.semanticText, capacity: chunkCapacity)
                        let payloadChunks = embeddingChunks.indices.map { index in
                            plainChunks.indices.contains(index)
                                ? plainChunks[index]
                                : (plainChunks.last ?? card.semanticText)
                        }
                        return AttachmentCardChunks(
                            card: card,
                            embeddingDocuments: embeddingChunks.map { layout.verified(embeddedHeader + $0) },
                            payloadDocuments: payloadChunks.map { payloadHeader + $0 },
                            chunkMetadata: Array(repeating: nil, count: embeddingChunks.count)
                        )
                    }
                    .filter { !$0.embeddingDocuments.isEmpty }
            }
            attachmentChunks.append(AttachmentChunks(
                attachmentId: attachment.attachmentId,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                contentId: attachment.contentId,
                isInline: attachment.isInline,
                cardChunks: cardChunks,
                evidencePacket: attachment.evidencePacket
            ))
        }
        let evidenceBundle = MessageEvidenceBundle(
            messageId: seed.messageId,
            subject: seed.subject,
            bodyText: searchableBodyText,
            attachments: attachmentChunks.map { attachment in
                MessageEvidenceBundle.AttachmentItem(
                    attachmentId: attachment.attachmentId,
                    filename: attachment.filename,
                    mimeType: attachment.mimeType,
                    contentId: attachment.contentId,
                    isInline: attachment.isInline,
                    cards: attachment.cardChunks.map(\.card)
                )
            }
        )

        let summary = layout.summaryDocuments(
            embeddedMetadata: embeddedMetadata,
            payloadMetadata: seed.metadata,
            body: searchableBodyText,
            digest: evidenceBundle.hasUsefulEvidence ? evidenceBundle.digest(maxCharacters: 1_800) : nil
        )
        let style = seed.isSentByUser && !styleBodyText.isEmpty
            ? layout.styleDocuments(recipientInfo: seed.recipientInfo, sentText: styleBodyText)
            : nil

        return EmbeddingInput(
            messageId: seed.messageId,
            subject: seed.subject,
            senderEmail: seed.senderEmail,
            accountId: seed.accountId,
            hasAttachment: seed.hasAttachment,
            metadata: seed.metadata,
            summaryDocument: summary.document,
            summaryPayload: summary.payload,
            bodyChunks: layout.bodyChunks(searchableBodyText),
            bodyText: searchableBodyText,
            styleDocument: style?.document,
            stylePayload: style?.payload,
            embeddingVersion: seed.embeddingVersion,
            attachmentChunks: attachmentChunks,
            messageReceivedAt: seed.messageReceivedAt
        )
    }

    private static func performEmbedding(
        input: EmbeddingInput,
        embedder: EmbeddingProvider,
        vectorStore: VectorStore,
        meaningFeatureStore: VectorMeaningFeatureStore
    ) throws -> Int {
        let pending = pendingVectors(messageId: nil, input: input)

        let vectors = embedder.embedBatch(pending.map(\.embeddingDocument))
        var vectorsInserted = 0
        for (candidate, vector) in zip(pending, vectors) {
            guard let vector else { continue }
            let rowId = try vectorStore.insert(
                messageId: input.messageId,
                collection: candidate.collection,
                chunkIndex: candidate.chunkIndex,
                embeddingVersion: input.embeddingVersion,
                vector: vector,
                textPayload: candidate.textPayload,
                metadataJSON: candidate.metadataJSON,
                messageReceivedAt: input.messageReceivedAt
            )
            vectorsInserted += 1
            if candidate.collection == .context, candidate.chunkIndex == 0 {
                writeMeaningFeatures(
                    vectorId: rowId,
                    textPayload: candidate.textPayload,
                    meaningFeatureStore: meaningFeatureStore
                )
            }
        }

        guard vectorsInserted > 0 else {
            throw EmbeddingError.noVectorsProduced
        }
        return vectorsInserted
    }

    /// Persists the meaning-feature row for a freshly inserted summary
    /// vector (context collection, chunk 0). A feature-write failure must
    /// never fail the embed itself — the cluster-detection worker lazily
    /// backfills missing rows on its next full refit.
    private static func writeMeaningFeatures(
        vectorId: Int64,
        textPayload: String,
        meaningFeatureStore: VectorMeaningFeatureStore
    ) {
        let features = ClusterDetector.meaningFeatures(from: textPayload)
        do {
            try meaningFeatureStore.upsertBatch([(vectorId: vectorId, features: features)])
        } catch {
            print("[Embed] meaning-feature write failed for vector \(vectorId): \(String(reflecting: type(of: error)))")
        }
    }

    private struct PendingVector: Sendable {
        let messageId: UUID?
        let collection: VectorCollection
        let chunkIndex: Int
        let embeddingDocument: String
        let textPayload: String
        let storageMessageId: String
        let embeddingVersion: String
        let messageReceivedAt: TimeInterval?
        let metadataJSON: String
    }

    private static func pendingVectors(messageId: UUID?, input: EmbeddingInput) -> [PendingVector] {
        var chunkIndex = 0
        var pending: [PendingVector] = []

        func append(
            collection: VectorCollection,
            chunkIndex: Int,
            document: String,
            textPayload: String? = nil,
            metadataJSON: String = "{}"
        ) {
            pending.append(PendingVector(
                messageId: messageId,
                collection: collection,
                chunkIndex: chunkIndex,
                embeddingDocument: document,
                textPayload: textPayload ?? document,
                storageMessageId: input.messageId,
                embeddingVersion: input.embeddingVersion,
                messageReceivedAt: input.messageReceivedAt,
                metadataJSON: metadataJSON
            ))
        }

        // Summary
        append(
            collection: .context,
            chunkIndex: chunkIndex,
            document: input.summaryDocument,
            textPayload: input.summaryPayload
        )
        chunkIndex += 1

        // Body chunks
        for chunk in input.bodyChunks {
            let contextDocument = EmbeddingDocumentBuilder.buildContextDocument(
                metadata: input.metadata, bodyChunk: chunk.text
            )
            append(
                collection: .context,
                chunkIndex: chunkIndex,
                document: contextDocument,
                metadataJSON: bodyChunkMetadataJSON(chunk)
            )
            chunkIndex += 1
        }

        // Style exemplar
        if let styleDocument = input.styleDocument {
            append(
                collection: .style,
                chunkIndex: 0,
                document: styleDocument,
                textPayload: input.stylePayload
            )
        }

        // Attachments
        for attachment in input.attachmentChunks {
            var vectorChunkIndex = 0
            for (cardIndex, cardChunks) in attachment.cardChunks.enumerated() {
                for (chunkIndex, embeddingDocument) in cardChunks.embeddingDocuments.enumerated() {
                    let ragMetadata = cardChunks.chunkMetadata.indices.contains(chunkIndex)
                        ? cardChunks.chunkMetadata[chunkIndex]
                        : nil
                    append(
                        collection: .attachment,
                        chunkIndex: vectorChunkIndex,
                        document: embeddingDocument,
                        textPayload: cardChunks.payloadDocuments[chunkIndex],
                        metadataJSON: attachmentChunkMetadataJSON(
                            attachment,
                            card: cardChunks.card,
                            cardIndex: cardIndex,
                            chunkIndex: chunkIndex,
                            chunkCount: cardChunks.embeddingDocuments.count,
                            ragMetadata: ragMetadata
                        )
                    )
                    vectorChunkIndex += 1
                }
            }
        }

        return pending
    }

    private struct BodyChunkMetadata: Codable, Sendable {
        let kind: String
        let bodyRangeStart: Int
        let bodyRangeEnd: Int
        let bodyChunkText: String
    }

    private static func bodyChunkMetadataJSON(_ chunk: TextChunk) -> String {
        let metadata = BodyChunkMetadata(
            kind: "bodyChunk",
            bodyRangeStart: chunk.bodyRange.lowerBound,
            bodyRangeEnd: chunk.bodyRange.upperBound,
            bodyChunkText: chunk.text
        )
        guard let data = try? JSONEncoder().encode(metadata),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static func attachmentChunkMetadataJSON(
        _ attachment: AttachmentChunks,
        card: AttachmentEvidenceCard,
        cardIndex: Int,
        chunkIndex: Int,
        chunkCount: Int,
        ragMetadata: AttachmentRAGMetadata? = nil
    ) -> String {
        AttachmentVectorMetadata(
            card: card,
            packet: attachment.evidencePacket,
            cardIndex: cardIndex,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            ragMetadata: ragMetadata
        ).jsonString()
    }

    private static func loadRAGDocument(path: String) -> AttachmentRAGDocument? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONDecoder().decode(AttachmentRAGDocument.self, from: data)
    }

    private struct EmbeddingBatchOutcome: Sendable {
        let succeededIds: Set<UUID>
        let deferredIds: Set<UUID>
    }

    private static func performEmbeddingBatch(
        inputs: [(messageId: UUID, input: EmbeddingInput)],
        embedder: EmbeddingProvider,
        vectorStore: VectorStore,
        ftsIndex: MessageFTSIndex?,
        meaningFeatureStore: VectorMeaningFeatureStore,
        documentBatchSize: Int,
        taskPriority: TaskPriority,
        interMessageDelayNanoseconds: UInt64,
        embeddingLaneLimit: Int,
        shouldYield: @escaping @MainActor @Sendable () -> Bool
    ) async -> EmbeddingBatchOutcome {
        guard !inputs.isEmpty else {
            return EmbeddingBatchOutcome(succeededIds: [], deferredIds: [])
        }

        let inputsByID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.messageId, $0.input) })
        var pending: [PendingVector] = []
        pending.reserveCapacity(inputs.count * 2)
        for item in inputs {
            pending.append(contentsOf: pendingVectors(messageId: item.messageId, input: item.input))
        }

        var insertedByMessage: [UUID: Int] = [:]
        var failedMessages: Set<UUID> = []
        let documentBatchSize = max(1, documentBatchSize)
        var start = 0
        while start < pending.count {
            if await shouldYield() {
                break
            }
            let end = min(start + documentBatchSize, pending.count)
            let batch = Array(pending[start..<end])
            let vectors = await embedBatch(
                batch.map(\.embeddingDocument),
                embedder: embedder,
                taskPriority: taskPriority,
                laneLimit: embeddingLaneLimit
            )
            var inserts: [(messageId: UUID, request: VectorInsertRequest)] = []
            inserts.reserveCapacity(batch.count)
            for (candidate, vector) in zip(batch, vectors) {
                guard let messageId = candidate.messageId else { continue }
                guard let vector else { continue }
                inserts.append((
                    messageId: messageId,
                    request: VectorInsertRequest(
                        messageId: candidate.storageMessageId,
                        collection: candidate.collection,
                        chunkIndex: candidate.chunkIndex,
                        embeddingVersion: candidate.embeddingVersion,
                        vector: vector,
                        textPayload: candidate.textPayload,
                        metadataJSON: candidate.metadataJSON,
                        messageReceivedAt: candidate.messageReceivedAt
                    )
                ))
            }
            do {
                let rowIds = try vectorStore.insertBatch(inserts.map { $0.request })
                for insert in inserts {
                    insertedByMessage[insert.messageId, default: 0] += 1
                }
                // `insertBatch` returns row ids aligned with its requests;
                // summary vectors (context collection, chunk 0) get their
                // meaning-feature row keyed by the fresh vector id.
                let summaryRows: [(vectorId: Int64, features: [String: Float])] = zip(inserts, rowIds)
                    .compactMap { insert, rowId in
                        guard insert.request.collection == .context,
                              insert.request.chunkIndex == 0 else { return nil }
                        return (
                            vectorId: rowId,
                            features: ClusterDetector.meaningFeatures(from: insert.request.textPayload)
                        )
                    }
                if summaryRows.isEmpty == false {
                    do {
                        try meaningFeatureStore.upsertBatch(summaryRows)
                    } catch {
                        // Never fail the embed for a feature write; the
                        // cluster worker lazily backfills missing rows.
                        print("[Embed] meaning-feature batch write failed: \(String(reflecting: type(of: error)))")
                    }
                }
            } catch {
                let ids = Set(inserts.map { $0.messageId })
                for messageId in ids {
                    failedMessages.insert(messageId)
                    print("[Embed] failed \(messageId.uuidString): \(String(reflecting: type(of: error))). Will retry on next batch.")
                }
            }
            start = end
            if interMessageDelayNanoseconds > 0, start < pending.count {
                try? await Task.sleep(nanoseconds: interMessageDelayNanoseconds)
            }
        }

        let deferredIds = Set(
            pending[start...].compactMap(\.messageId)
        )

        var succeeded: Set<UUID> = []
        for item in inputs {
            let messageId = item.messageId
            guard !deferredIds.contains(messageId) else {
                continue
            }
            guard insertedByMessage[messageId, default: 0] > 0 else {
                print("[Embed] failed \(messageId.uuidString): \(EmbeddingError.noVectorsProduced). Will retry on next batch.")
                continue
            }
            guard !failedMessages.contains(messageId), let input = inputsByID[messageId] else {
                continue
            }
            do {
                try syncFTS(input: input, ftsIndex: ftsIndex)
                succeeded.insert(messageId)
            } catch {
                print("[Embed] failed \(messageId.uuidString): \(String(reflecting: type(of: error))). Will retry on next batch.")
            }
            if interMessageDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: interMessageDelayNanoseconds)
            }
        }
        return EmbeddingBatchOutcome(
            succeededIds: succeeded,
            deferredIds: deferredIds
        )
    }

    private static func embedBatch(
        _ documents: [String],
        embedder: EmbeddingProvider,
        taskPriority: TaskPriority,
        laneLimit: Int
    ) async -> [[Float]?] {
        if let laneLimitedEmbedder = embedder as? RuntimeLaneLimitedEmbeddingProvider {
            return await laneLimitedEmbedder.embedBatchAsync(
                documents,
                priority: taskPriority,
                laneLimit: laneLimit
            )
        }
        if let asyncEmbedder = embedder as? AsyncEmbeddingProvider {
            return await asyncEmbedder.embedBatchAsync(documents, priority: taskPriority)
        }
        return embedder.embedBatch(documents)
    }

    private static func syncFTS(input: EmbeddingInput, ftsIndex: MessageFTSIndex?) throws {
        guard let ftsIndex else { return }
        try ftsIndex.upsert(
            messageId: input.messageId,
            subject: input.subject,
            body: ftsBodyText(input),
            senderEmail: input.senderEmail,
            accountId: input.accountId,
            receivedAt: input.messageReceivedAt,
            hasAttachment: input.hasAttachment,
            attachments: ftsAttachmentDocuments(input)
        )
    }

    private static func ftsBodyText(_ input: EmbeddingInput) -> String {
        input.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ftsAttachmentDocuments(_ input: EmbeddingInput) -> [FTSAttachmentDocument] {
        input.attachmentChunks.flatMap { attachment in
            attachment.cardChunks.compactMap { cardChunks in
                let body = cardChunks.card.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                return FTSAttachmentDocument(
                    attachmentId: attachment.attachmentId,
                    filename: attachment.filename,
                    modality: cardChunks.card.modality.rawValue,
                    body: body
                )
            }
        }
    }

    private static func extractedTextSemanticPayload(card: AttachmentEvidenceCard, text: String) -> String {
        var lines: [String] = [
            "ATTACHMENT_EVIDENCE_CARD: \(card.filename)",
            "MIME_TYPE: \(card.mimeType)",
            "MODALITY: \(card.modality.rawValue)"
        ]
        lines.append("\(card.modality.searchPrefix): \(text)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Private Helpers

    private func buildMetadata(from message: Message) -> MessageMetadata {
        let fromField: String
        if let fromName = message.fromName, !fromName.isEmpty {
            fromField = "\(fromName) <\(message.fromAddress)>"
        } else {
            fromField = message.fromAddress
        }

        let dateBucket: String
        if let sentAt = message.sentAt {
            dateBucket = EmbeddingDocumentBuilder.dateBucket(from: sentAt)
        } else {
            dateBucket = "unknown"
        }

        let attachmentFilenames = message.attachments.map(\.filename)

        return MessageMetadata(
            from: fromField,
            to: "",
            dateBucket: dateBucket,
            subject: message.subject,
            attachments: attachmentFilenames,
            language: message.languageDetected
        )
    }

    private func buildRecipientInfo(from message: Message) -> String {
        let toParticipants = message.participants.filter { $0.role == .to }
        if !toParticipants.isEmpty {
            let names = toParticipants.compactMap { mp -> String? in
                if let name = mp.participant?.displayName, !name.isEmpty {
                    return "correspondent=\(name)"
                } else if let email = mp.participant?.emailAddress {
                    return "correspondent=\(email)"
                }
                return nil
            }
            if !names.isEmpty {
                return names.joined(separator: ", ")
            }
        }
        return "correspondent=unknown"
    }
}
