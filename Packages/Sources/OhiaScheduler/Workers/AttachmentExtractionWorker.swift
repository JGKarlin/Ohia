import Foundation
import SwiftData
import OhiaCore
import OhiaIngest
import OhiaML

/// Drains the deferred-extraction backlog left behind by the bounded first-run
/// ingest tier. For each message that still has at least one text-bearing
/// attachment without `extractedTextPath`, runs `AttachmentExtractor.extractText`
/// with the full policy, persists the result via `CanonicalStore`, then deletes
/// the message's existing vectors and flips `embeddingStatus = .pending` so the
/// standard `.embed` pass re-embeds the body, entities, and the newly-extracted
/// attachment chunks together.
///
/// Self-reenqueues until no work remains. Bounded per tick by `messagesPerTick`
/// so a long-tail mailbox doesn't stall faster work — the scheduler picks
/// other jobs between ticks.
public final class AttachmentExtractionWorker: @unchecked Sendable {
    /// Legacy marker from stores created before structured extraction status.
    /// Retained for compatibility checks only; legacy rows are not enrolled in
    /// the forward-only retry policy.
    public static let unsupportedMarker = "unsupported"
    /// Attachment-level cap. The full extractor on a >50 MB PDF is unbounded,
    /// and most very-large attachments are video / archives that don't contain
    /// useful text anyway. Mark these unsupported and move on so the worker
    /// makes progress on the rest of the backlog.
    public static let maxAttemptedAttachmentBytes: Int = 50 * 1024 * 1024
    public static let messagesPerTick: Int = 4
    public static let retryPolicyVersion = AttachmentExtractionRetryPolicy.version
    public static let maxRetryAttempts = AttachmentExtractionRetryPolicy.maxRetryAttempts
    /// Returned by the worker for each tick's run.
    public struct Result: Sendable, Equatable {
        public let messagesProcessed: Int
        public let attachmentsExtracted: Int
        public let attachmentsMarkedUnsupported: Int
        public let messagesRequeued: Int
    }

    private let canonicalStore: CanonicalStore
    private let vectorStore: VectorStore
    private let messageStoreURL: URL?

    public init(
        canonicalStore: CanonicalStore,
        vectorStore: VectorStore,
        messageStoreURL: URL? = nil
    ) {
        self.canonicalStore = canonicalStore
        self.vectorStore = vectorStore
        self.messageStoreURL = messageStoreURL
    }

    /// Drains up to `messagesPerTick` messages whose attachments still need
    /// heavy extraction. Returns counters so PipelineRunner can decide whether
    /// to re-enqueue another `.extractAttachments` job.
    @MainActor
    public func runOnce(
        context: ModelContext,
        messageIDFromJob: UUID? = nil
    ) async throws -> Result {
        let candidates = try selectCandidateMessages(
            context: context,
            preferred: messageIDFromJob
        )
        guard !candidates.isEmpty else {
            return Result(
                messagesProcessed: 0,
                attachmentsExtracted: 0,
                attachmentsMarkedUnsupported: 0,
                messagesRequeued: 0
            )
        }

        var attachmentsExtracted = 0
        var attachmentsMarkedUnsupported = 0
        var messagesProcessed = 0
        var messagesRequeued = 0

        for message in candidates {
            let outcome = try await processMessage(message, context: context)
            attachmentsExtracted += outcome.extracted
            attachmentsMarkedUnsupported += outcome.markedUnsupported
            messagesProcessed += 1
            if outcome.extracted > 0 {
                messagesRequeued += 1
            }
        }

        return Result(
            messagesProcessed: messagesProcessed,
            attachmentsExtracted: attachmentsExtracted,
            attachmentsMarkedUnsupported: attachmentsMarkedUnsupported,
            messagesRequeued: messagesRequeued
        )
    }

    /// True when at least one `Attachment` row still has no `extractedTextPath`
    /// and still needs a full extraction attempt.
    @MainActor
    public static func hasPendingWork(context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<Attachment>(
            predicate: #Predicate<Attachment> { attachment in
                attachment.extractedTextPath == nil
            }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.contains(where: isPendingExtractionCandidate)
    }

    // MARK: - Internals

    private struct MessageOutcome {
        let extracted: Int
        let markedUnsupported: Int
    }

    private struct PersistedExtractionArtifacts {
        var extractedTextPath: String?
        var embeddingTextPath: String?
        var extractionMetadataPath: String?
        var ragDocumentPath: String?

        var hasExtractedText: Bool {
            extractedTextPath != nil
        }
    }

    @MainActor
    private func selectCandidateMessages(
        context: ModelContext,
        preferred: UUID?
    ) throws -> [Message] {
        // The job carries an optional messageID for "extract this one urgently"
        // (e.g. the lock view's currently-focused message); honour it first.
        if let preferred {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.id == preferred }
            )
            descriptor.fetchLimit = 1
            if let message = try context.fetch(descriptor).first,
               messageHasPendingAttachment(message) {
                return [message]
            }
        }

        // Newest first — recent mail is more likely to be looked at while the
        // backlog drains, so the orientation paragraph fills in for visible
        // messages first.
        let descriptor = FetchDescriptor<Attachment>(
            predicate: #Predicate<Attachment> { attachment in
                attachment.extractedTextPath == nil
            }
        )
        let pending = try context.fetch(descriptor).filter(Self.isPendingExtractionCandidate)
        var seen = Set<UUID>()
        var ordered: [Message] = []
        for attachment in pending {
            guard let message = attachment.message else { continue }
            guard seen.insert(message.id).inserted else { continue }
            ordered.append(message)
            if ordered.count >= Self.messagesPerTick { break }
        }
        ordered.sort { lhs, rhs in
            let lhsDate = lhs.receivedAt ?? lhs.sentAt ?? lhs.ingestedAt
            let rhsDate = rhs.receivedAt ?? rhs.sentAt ?? rhs.ingestedAt
            return lhsDate > rhsDate
        }
        return ordered
    }

    @MainActor
    private func messageHasPendingAttachment(_ message: Message) -> Bool {
        message.attachments.contains(where: Self.isPendingExtractionCandidate)
    }

    @MainActor
    private func processMessage(
        _ message: Message,
        context: ModelContext
    ) async throws -> MessageOutcome {
        let messageID = message.id.uuidString
        var extracted = 0
        var markedUnsupported = 0

        for attachment in message.attachments {
            guard Self.isPendingExtractionCandidate(attachment) else { continue }

            let kind = DocumentKind.detect(
                mimeType: attachment.mimeType,
                filename: attachment.filename
            )
            guard let filePath = attachment.filePath,
                  FileManager.default.fileExists(atPath: filePath) else {
                let failure = AttachmentExtractionResult.failure(
                    kind: kind,
                    status: .parseFailed,
                    method: kind.defaultMethod,
                    failureReason: "Attachment file is missing"
                )
                attachment.applyExtractionResult(failure)
                AttachmentExtractionRetryPolicy.recordAttempt(attachment: attachment, result: failure)
                attachment.clearAttachmentSummary()
                markedUnsupported += 1
                continue
            }
            guard kind.isTextBearing else {
                let failure = AttachmentExtractionResult.failure(
                    kind: kind,
                    status: .unsupportedType,
                    method: nil,
                    failureReason: "Unsupported attachment type"
                )
                attachment.applyExtractionResult(failure)
                AttachmentExtractionRetryPolicy.recordAttempt(attachment: attachment, result: failure)
                attachment.clearAttachmentSummary()
                markedUnsupported += 1
                continue
            }
            // Skip absurdly-large payloads so one user attachment can't burn
            // a whole tick.
            guard attachment.sizeBytes <= Self.maxAttemptedAttachmentBytes else {
                let failure = AttachmentExtractionResult.failure(
                    kind: kind,
                    status: .tooLarge,
                    method: kind.defaultMethod,
                    failureReason: "Attachment is larger than \(Self.maxAttemptedAttachmentBytes) bytes"
                )
                attachment.applyExtractionResult(failure)
                AttachmentExtractionRetryPolicy.recordAttempt(attachment: attachment, result: failure)
                attachment.clearAttachmentSummary()
                markedUnsupported += 1
                continue
            }

            let mimeType = attachment.mimeType
            let filename = attachment.filename
            let result: AttachmentExtractionResult?
            do {
                result = try await MultimodalAttachmentExtractor.extractFile(
                    at: URL(fileURLWithPath: filePath), mimeType: mimeType, filename: filename
                )
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                result = .failure(kind: kind, status: .parseFailed, method: kind.defaultMethod,
                                  failureReason: "Attachment data could not be read")
            }
            try Task.checkCancellation()

            guard let result else {
                let failure = AttachmentExtractionResult.failure(
                    kind: kind,
                    status: .parseFailed,
                    method: kind.defaultMethod,
                    failureReason: "Extraction policy skipped a full extraction attempt"
                )
                attachment.applyExtractionResult(failure)
                AttachmentExtractionRetryPolicy.recordAttempt(attachment: attachment, result: failure)
                attachment.clearAttachmentSummary()
                markedUnsupported += 1
                continue
            }
            let artifacts = try persistExtractionArtifacts(
                result,
                messageID: messageID,
                filename: filename
            )
            attachment.applyExtractionResult(result)
            AttachmentExtractionRetryPolicy.recordAttempt(attachment: attachment, result: result)
            attachment.extractedTextPath = artifacts.extractedTextPath
            attachment.embeddingTextPath = artifacts.embeddingTextPath
            attachment.extractionMetadataPath = artifacts.extractionMetadataPath
            attachment.ragDocumentPath = artifacts.ragDocumentPath
            attachment.clearAttachmentSummary()

            if artifacts.hasExtractedText {
                extracted += 1
            } else {
                markedUnsupported += 1
            }
        }

        if extracted > 0 {
            // The message's existing vectors don't include the newly-arriving
            // attachment chunks; rather than dual-write and risk drift, drop
            // the message's vector rows and let the standard `.embed` pass
            // re-create them all (body + entities + style + new attachments).
            try vectorStore.deleteVectors(forMessageId: messageID)
            message.embeddingStatus = .pending
            message.embeddedAt = nil
            try invalidateSummaryAndRequeue(message, context: context)
            try enqueueAttachmentSummaryIfNeeded(message, context: context)
        }

        try context.save()
        return MessageOutcome(extracted: extracted, markedUnsupported: markedUnsupported)
    }

    private static func isPendingExtractionCandidate(_ attachment: Attachment) -> Bool {
        guard attachment.extractedTextPath == nil else { return false }
        if AttachmentExtractionRetryPolicy.isRetryCandidate(attachment: attachment) {
            return true
        }
        if attachment.extractionStatus == nil && attachment.extractionMethod == nil {
            return DocumentKind
                .detect(mimeType: attachment.mimeType, filename: attachment.filename)
                .isDocument
        }
        return false
    }

    private func persistExtractionArtifacts(
        _ result: AttachmentExtractionResult,
        messageID: String,
        filename: String
    ) throws -> PersistedExtractionArtifacts {
        guard let text = result.text,
              result.hasExtractedText else {
            return PersistedExtractionArtifacts()
        }

        try canonicalStore.saveAttachmentText(
            messageId: messageID,
            filename: filename,
            text: text
        )
        var artifacts = PersistedExtractionArtifacts(
            extractedTextPath: canonicalStore.attachmentPath(
                messageId: messageID,
                filename: filename + ".txt"
            ).path
        )

        if let embeddingText = result.embeddingText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !embeddingText.isEmpty {
            try canonicalStore.saveAttachmentEmbeddingText(
                messageId: messageID,
                filename: filename,
                text: embeddingText
            )
            artifacts.embeddingTextPath = canonicalStore.attachmentEmbeddingTextPath(
                messageId: messageID,
                filename: filename
            ).path
        }
        if let metadataJSON = result.normalizedIRJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
           !metadataJSON.isEmpty {
            try canonicalStore.saveAttachmentExtractionMetadata(
                messageId: messageID,
                filename: filename,
                json: metadataJSON
            )
            artifacts.extractionMetadataPath = canonicalStore.attachmentExtractionMetadataPath(
                messageId: messageID,
                filename: filename
            ).path
        }
        if let ragDocumentJSON = result.ragDocumentJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ragDocumentJSON.isEmpty {
            try canonicalStore.saveAttachmentRAGDocument(
                messageId: messageID,
                filename: filename,
                json: ragDocumentJSON
            )
            artifacts.ragDocumentPath = canonicalStore.attachmentRAGDocumentPath(
                messageId: messageID,
                filename: filename
            ).path
        }
        return artifacts
    }

    @MainActor
    private func invalidateSummaryAndRequeue(_ message: Message, context: ModelContext) throws {
        if let analysis = message.analysis {
            analysis.bodySummary = nil
            analysis.bodySummaryInputFingerprint = nil
            analysis.mailClassificationJSON = nil
            analysis.triageVerdictJSON = nil
            analysis.interpretedAt = nil
            analysis.summarizedAt = nil
        }
        guard !message.isSentByUser else { return }
        let existing = try JobFetch.active(context: context).contains { job in
            job.type == .summarize
                && job.messageId == message.id
        }
        guard !existing else { return }
        let job = Job(type: .summarize, priority: 4)
        job.messageId = message.id
        context.insert(job)
    }

    @MainActor
    private func enqueueAttachmentSummaryIfNeeded(_ message: Message, context: ModelContext) throws {
        let existing = try JobFetch.active(context: context).contains { job in
            job.type == .summarizeAttachments
                && job.messageId == message.id
        }
        guard !existing else { return }
        let job = Job(type: .summarizeAttachments, priority: 7)
        job.messageId = message.id
        context.insert(job)
    }
}
