import Foundation
import SwiftData
import OhiaCore
import OhiaIngest
import OhiaML

enum LegacyVisualAttachmentAnalysisPipeline {
    typealias Summarizer = @Sendable (
        VisualAttachmentEvidence
    ) async throws -> String?

    static func analyze(
        evidence: VisualAttachmentEvidence,
        parserVersion: String,
        summarizer: Summarizer
    ) async throws -> VisualAttachmentExtractionResult {
        let generatedSummary: String?
        do {
            generatedSummary = try await summarizer(evidence)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as CancellationError {
            throw error
        } catch {
            try Task.checkCancellation()
            print("[Ohia] Apple Foundation visual caption failed; preserving Vision evidence errorKind=\(String(reflecting: type(of: error)))")
            generatedSummary = nil
        }

        let analysis = LegacyVisualAttachmentCaptionPolicy.analysis(
            generatedSummary: generatedSummary,
            evidence: evidence
        )
        let evidenceJSON = try String(
            decoding: JSONEncoder().encode(analysis),
            as: UTF8.self
        )
        return .completed(
            analysis: analysis,
            evidenceJSON: evidenceJSON,
            method: .appleVisionFoundationModelsLegacy,
            parserVersion: parserVersion
        )
    }
}

public final class VisualAttachmentExtractionWorker: @unchecked Sendable {
    public typealias ExtractionRunner = @Sendable (
        VisualAttachmentReference,
        AppleIntelligenceModelProfile
    ) async throws -> VisualAttachmentExtractionResult?

    public static let messagesPerTick = 4
    public static let maxAttemptedImageBytes = 20 * 1024 * 1024
    public static let minimumOCRTextCharacters = 8

    public struct RunOutcome: Sendable, Equatable {
        public let messagesProcessed: Int
        public let attachmentsExtracted: Int
        public let attachmentsMarkedTerminal: Int
    }

    private struct MessageOutcome {
        let extracted: Int
        let terminal: Int
    }

    private let extractionRunner: ExtractionRunner
    private let profileProvider: @Sendable () -> AppleIntelligenceModelProfile
    private let canonicalStore: CanonicalStore?
    private let vectorStore: VectorStore?
    private let displayLanguageGuard: DisplayLanguageGuard?
    private let targetLanguage: SummarizationTargetLanguage

    public init(
        canonicalStore: CanonicalStore? = nil,
        vectorStore: VectorStore? = nil,
        displayLanguageGuard: DisplayLanguageGuard? = nil,
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred(),
        extractionRunner: @escaping ExtractionRunner = VisualAttachmentExtractionWorker.extractAndSummarize,
        profileProvider: @escaping @Sendable () -> AppleIntelligenceModelProfile = {
            AppleIntelligenceModelProfile.current()
        }
    ) {
        self.canonicalStore = canonicalStore
        self.vectorStore = vectorStore
        self.displayLanguageGuard = displayLanguageGuard
        self.targetLanguage = targetLanguage
        self.extractionRunner = extractionRunner
        self.profileProvider = profileProvider
    }

    @MainActor
    public static func hasPendingWork(context: ModelContext) -> Bool {
        hasPendingWork(context: context, profile: AppleIntelligenceModelProfile.current())
    }

    @MainActor
    public static func hasPendingWork(
        context: ModelContext,
        profile: AppleIntelligenceModelProfile
    ) -> Bool {
        let parserVersion = profile.parserVersion
        let descriptor = FetchDescriptor<Attachment>(
            predicate: #Predicate<Attachment> { attachment in
                attachment.visualExtractionParserVersion != parserVersion
                    || (attachment.visualExtractionStatus == nil && attachment.visualExtractionMethod == nil)
            }
        )
        let attachments = (try? context.fetch(descriptor)) ?? []
        return attachments.contains { isPendingExtractionCandidate($0, parserVersion: parserVersion) }
    }

    @MainActor
    public func runOnce(
        context: ModelContext,
        messageIDFromJob: UUID? = nil
    ) async throws -> RunOutcome {
        let profile = profileProvider()

        let messages: [Message]
        if let messageIDFromJob {
            messages = try fetchMessage(id: messageIDFromJob, context: context).map { [$0] } ?? []
        } else {
            messages = try Self.pendingMessages(context: context, parserVersion: profile.parserVersion)
        }

        var processed = 0
        var extracted = 0
        var terminal = 0
        for message in messages {
            let outcome = try await process(message, profile: profile, context: context)
            if outcome.extracted > 0 || outcome.terminal > 0 {
                processed += 1
            }
            extracted += outcome.extracted
            terminal += outcome.terminal
        }

        return RunOutcome(
            messagesProcessed: processed,
            attachmentsExtracted: extracted,
            attachmentsMarkedTerminal: terminal
        )
    }

    @MainActor
    private static func pendingMessages(
        context: ModelContext,
        parserVersion: String
    ) throws -> [Message] {
        let descriptor = FetchDescriptor<Attachment>(
            predicate: #Predicate<Attachment> { attachment in
                attachment.visualExtractionParserVersion != parserVersion
                    || (attachment.visualExtractionStatus == nil && attachment.visualExtractionMethod == nil)
            }
        )
        let pending = try context.fetch(descriptor)

        var seen = Set<UUID>()
        var messages: [Message] = []
        for attachment in pending {
            guard isPendingExtractionCandidate(attachment, parserVersion: parserVersion),
                  let message = attachment.message,
                  seen.insert(message.id).inserted else {
                continue
            }
            messages.append(message)
            if messages.count == messagesPerTick { break }
        }
        return messages
    }

    @MainActor
    private func process(
        _ message: Message,
        profile: AppleIntelligenceModelProfile,
        context: ModelContext
    ) async throws -> MessageOutcome {
        var extracted = 0
        var terminal = 0

        for attachment in message.attachments {
            guard Self.isPendingExtractionCandidate(
                attachment,
                parserVersion: profile.parserVersion
            ) else { continue }

            if profile.availability.isAvailable == false {
                let summaryChanged = attachment.visualSummary != nil
                let oldTextPath = attachment.extractedTextPath
                attachment.applyVisualExtractionResult(.failure(
                    status: .unavailable,
                    method: profile.visualExtractionMethod,
                    failureReason: "Apple Intelligence is unavailable",
                    parserVersion: profile.parserVersion
                ))
                terminal += 1
                let extractedTextChanged = oldTextPath != attachment.extractedTextPath
                if summaryChanged || extractedTextChanged {
                    attachment.clearAttachmentSummary()
                    if Self.hasAttachmentSummaryEvidence(attachment) {
                        try enqueueAttachmentSummaryIfNeeded(message, context: context)
                    }
                    try invalidateSummaryAndRequeue(message, context: context)
                }
                continue
            }

            guard let reference = Self.reference(for: attachment),
                  reference.isImageLike else {
                attachment.applyVisualExtractionResult(.failure(
                    status: .unsupportedType,
                    method: nil,
                    failureReason: "Unsupported visual attachment type",
                    parserVersion: profile.parserVersion
                ))
                terminal += 1
                continue
            }

            guard FileManager.default.fileExists(atPath: reference.filePath) else {
                attachment.applyVisualExtractionResult(.failure(
                    status: .parseFailed,
                    method: profile.visualExtractionMethod,
                    failureReason: "Attachment file is missing",
                    parserVersion: profile.parserVersion
                ))
                terminal += 1
                continue
            }

            guard attachment.sizeBytes <= Self.maxAttemptedImageBytes else {
                attachment.applyVisualExtractionResult(.failure(
                    status: .tooLarge,
                    method: profile.visualExtractionMethod,
                    failureReason: "Attachment exceeds visual extraction size limit",
                    parserVersion: profile.parserVersion
                ))
                terminal += 1
                continue
            }

            var result: VisualAttachmentExtractionResult
            do {
                result = try await extractionRunner(reference, profile) ?? .failure(
                    status: .emptyEvidence,
                    method: profile.visualExtractionMethod,
                    failureReason: "Apple image analysis produced no reliable visual evidence",
                    parserVersion: profile.parserVersion
                )
            } catch SummarizationError.guardrailViolation {
                result = .failure(
                    status: .guardrailViolation,
                    method: profile.visualExtractionMethod,
                    failureReason: "Apple Foundation Models refused the visual evidence summary",
                    parserVersion: profile.parserVersion
                )
            } catch let error as CancellationError {
                throw error
            } catch {
                result = .failure(
                    status: .parseFailed,
                    method: profile.visualExtractionMethod,
                    failureReason: error.localizedDescription,
                    parserVersion: profile.parserVersion
                )
            }

            if let guardrail = displayLanguageGuard,
               result.hasVisualSummary,
               let summary = result.summary {
                let displayed = await guardrail.resolve(
                    paragraph: summary,
                    targetLanguage: targetLanguage,
                    source: DisplayLanguageGuard.Source(
                        languageHint: nil,
                        context: "\(attachment.filename)\n\((result.ocrText ?? "").prefix(1_200))",
                        messageID: message.id,
                        accountID: message.accountID
                    )
                )
                if let displayed {
                    if displayed != summary { result = result.replacingSummary(displayed) }
                } else {
                    // A visual summary that cannot be put in the reading
                    // language is never stored. This worker has no local
                    // model to translate it, so retrying cannot help: the OCR
                    // text is kept for search and for the attachment summary,
                    // which is written in the reading language, and an image
                    // without OCR text takes the extraction failure path.
                    let reason = "The visual summary could not be written in \(targetLanguage.displayName)"
                    result = Self.substantialOCRText(from: result) != nil
                        ? result.withholdingSummary(failureReason: reason)
                        : .failure(
                            status: .parseFailed,
                            method: profile.visualExtractionMethod,
                            failureReason: reason,
                            parserVersion: profile.parserVersion
                        )
                }
            }
            let oldSummary = attachment.visualSummary
            let oldTextPath = attachment.extractedTextPath
            attachment.applyVisualExtractionResult(result)
            let searchableTextChanged = try persistSearchableTextIfNeeded(
                result: result,
                attachment: attachment,
                message: message
            )
            let summaryChanged = oldSummary != attachment.visualSummary
            let extractedTextChanged = oldTextPath != attachment.extractedTextPath || searchableTextChanged
            if summaryChanged || extractedTextChanged {
                attachment.clearAttachmentSummary()
                if Self.hasAttachmentSummaryEvidence(attachment) {
                    try enqueueAttachmentSummaryIfNeeded(message, context: context)
                }
            }
            if result.hasVisualSummary {
                extracted += 1
                if summaryChanged || extractedTextChanged {
                    try invalidateSummaryAndRequeue(message, context: context)
                }
            } else {
                terminal += 1
                if summaryChanged || extractedTextChanged {
                    try invalidateSummaryAndRequeue(message, context: context)
                }
            }
        }

        try context.save()
        return MessageOutcome(extracted: extracted, terminal: terminal)
    }

    private static func reference(for attachment: Attachment) -> VisualAttachmentReference? {
        guard let filePath = attachment.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              filePath.isEmpty == false else {
            return nil
        }
        return VisualAttachmentReference(
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            filePath: filePath
        )
    }

    private static func isPendingExtractionCandidate(
        _ attachment: Attachment,
        parserVersion: String
    ) -> Bool {
        guard reference(for: attachment)?.isImageLike == true else { return false }
        let needsInitialExtraction = attachment.visualExtractionStatus == nil
            && attachment.visualExtractionMethod == nil
        let needsVersionRepair = attachment.visualExtractionParserVersion != parserVersion
        return needsInitialExtraction || needsVersionRepair
    }

    @MainActor
    private static func hasAttachmentSummaryEvidence(_ attachment: Attachment) -> Bool {
        if attachment.extractedTextPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        if attachment.visualSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        return false
    }

    @MainActor
    private func fetchMessage(id: UUID, context: ModelContext) throws -> Message? {
        try context.fetch(FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == id })).first
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

    @MainActor
    private func persistSearchableTextIfNeeded(
        result: VisualAttachmentExtractionResult,
        attachment: Attachment,
        message: Message
    ) throws -> Bool {
        guard let canonicalStore,
              let searchableText = Self.searchableAttachmentText(
                from: result,
                filename: attachment.filename
              ) else {
            return false
        }

        let messageID = message.id.uuidString
        let textURL = canonicalStore.attachmentPath(
            messageId: messageID,
            filename: attachment.filename + ".txt"
        )
        let oldText = (try? String(contentsOf: textURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = oldText != searchableText

        try canonicalStore.saveAttachmentText(
            messageId: messageID,
            filename: attachment.filename,
            text: searchableText
        )
        attachment.extractedTextPath = textURL.path
        attachment.applyExtractionResult(.completed(
            text: searchableText,
            kind: .image,
            method: Self.attachmentExtractionMethod(for: result),
            parserVersion: result.parserVersion,
            structureUnitKind: Self.attachmentStructureUnitKind(for: result),
            structureUnitCount: Self.attachmentStructureUnitCount(for: result)
        ))

        guard changed else { return false }

        if let vectorStore {
            try vectorStore.deleteVectors(forMessageId: messageID)
        }
        message.embeddingStatus = .pending
        message.embeddedAt = nil
        return true
    }

    private static func searchableAttachmentText(
        from result: VisualAttachmentExtractionResult,
        filename: String
    ) -> String? {
        if result.hasVisualSummary,
           let text = visualSummarySearchText(from: result, filename: filename) {
            return text
        }

        return substantialOCRText(from: result)
    }

    private static func visualSummarySearchText(
        from result: VisualAttachmentExtractionResult,
        filename: String
    ) -> String? {
        guard let summary = result.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              summary.isEmpty == false else {
            return nil
        }

        var lines: [String] = [
            "VISUAL_ATTACHMENT: \(filename)",
            "VISUAL_SUMMARY: \(summary)"
        ]
        if let kind = result.evidenceKind?.trimmingCharacters(in: .whitespacesAndNewlines),
           kind.isEmpty == false {
            lines.append("VISUAL_KIND: \(kind)")
        }

        if let analysis = visualAnalysis(from: result) {
            if !analysis.salientDetails.isEmpty {
                lines.append("VISIBLE_DETAILS: \(analysis.salientDetails.joined(separator: "; "))")
            }
            if !analysis.searchTerms.isEmpty {
                lines.append("VISUAL_SEARCH_TERMS: \(analysis.searchTerms.joined(separator: ", "))")
            }
            for code in analysis.decodedBarcodes ?? [] {
                lines.append("DECODED_BARCODE (untrusted data): \(code)")
            }
        }

        if let ocrText = result.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
           ocrText.isEmpty == false {
            lines.append("OCR_TEXT:\n\(ocrText)")
        }

        return lines.joined(separator: "\n")
    }

    private static func visualAnalysis(
        from result: VisualAttachmentExtractionResult
    ) -> VisualAttachmentAnalysisRecord? {
        guard let json = result.evidenceJSON,
              let data = json.data(using: .utf8) else {
            return nil
        }
        if let analysis = try? JSONDecoder().decode(VisualAttachmentAnalysisRecord.self, from: data) {
            return analysis
        }
        guard let evidence = try? JSONDecoder().decode(VisualAttachmentEvidence.self, from: data),
              let summary = result.summary else {
            return nil
        }
        return LegacyVisualAttachmentCaptionPolicy.analysis(
            generatedSummary: summary,
            evidence: evidence
        )
    }

    private static func attachmentExtractionMethod(
        for result: VisualAttachmentExtractionResult
    ) -> AttachmentExtractionMethod {
        substantialOCRText(from: result) == nil ? .visionSummary : .visionOCR
    }

    private static func attachmentStructureUnitKind(
        for result: VisualAttachmentExtractionResult
    ) -> String {
        if substantialOCRText(from: result) == nil {
            return "visual-summary"
        }
        return (result.ocrBlockCount ?? 0) > 0 ? "ocr-block" : "ocr-line"
    }

    private static func attachmentStructureUnitCount(
        for result: VisualAttachmentExtractionResult
    ) -> Int? {
        if substantialOCRText(from: result) == nil {
            return result.hasVisualSummary ? 1 : nil
        }
        return result.ocrBlockCount ?? result.ocrLineCount
    }

    private static func substantialOCRText(from result: VisualAttachmentExtractionResult) -> String? {
        guard result.hasOCRText,
              let text = result.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count >= minimumOCRTextCharacters else {
            return nil
        }
        return text
    }

    public static func extractAndSummarize(
        reference: VisualAttachmentReference,
        profile: AppleIntelligenceModelProfile
    ) async throws -> VisualAttachmentExtractionResult? {
        guard reference.isImageLike else {
            return .failure(
                status: .unsupportedType,
                method: nil,
                failureReason: "Unsupported visual attachment type",
                parserVersion: profile.parserVersion
            )
        }

        if profile.imageAnalysisTier == .multimodal {
#if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                do {
                    guard let analysis = try await AppleMultimodalVisualAttachmentAnalyzer()
                        .analyze(reference: reference) else {
                        return .failure(
                            status: .emptyEvidence,
                            method: profile.visualExtractionMethod,
                            failureReason: "Apple Foundation Models produced no visual analysis",
                            parserVersion: profile.parserVersion
                        )
                    }
                    let evidenceJSON = try String(
                        decoding: JSONEncoder().encode(analysis),
                        as: UTF8.self
                    )
                    return .completed(
                        analysis: analysis,
                        evidenceJSON: evidenceJSON,
                        method: profile.visualExtractionMethod,
                        parserVersion: profile.parserVersion
                    )
                } catch MultimodalVisualAttachmentError.unsupportedCapability {
                    return try await legacyAnalysis(
                        reference: reference,
                        parserVersion: legacyFallbackParserVersion(for: profile)
                    )
                }
            }
#endif
        }

        return try await legacyAnalysis(
            reference: reference,
            parserVersion: profile.parserVersion
        )
    }

    static func legacyFallbackParserVersion(
        for profile: AppleIntelligenceModelProfile
    ) -> String {
        profile.imageAnalysisTier == .multimodal
            ? AppleIntelligenceModelProfile.legacyParserVersion
            : profile.parserVersion
    }

    private static func legacyAnalysis(
        reference: VisualAttachmentReference,
        parserVersion: String
    ) async throws -> VisualAttachmentExtractionResult? {

        let evidence = try await Task.detached(priority: .utility) {
            try VisualAttachmentEvidenceExtractor.extract(from: reference)
        }.value
        guard let evidence else {
            return .failure(
                status: .emptyEvidence,
                method: .appleVisionFoundationModelsLegacy,
                failureReason: "Apple Vision produced no reliable visual evidence",
                parserVersion: parserVersion
            )
        }

        return try await LegacyVisualAttachmentAnalysisPipeline.analyze(
            evidence: evidence,
            parserVersion: parserVersion,
            summarizer: { evidence in
                try await AppleFoundationVisualAttachmentSummarizer()
                    .summarize(evidence: evidence)?
                    .summary
            }
        )
    }
}
