import Foundation
import SwiftData
import OhiaCore
import OhiaML

/// Generates the locked-node attachment-pane paragraph after attachment
/// evidence exists, so recently-ingested mail can open with attachment
/// summaries already present instead of waiting for chevron expansion.
///
/// A failed attempt is retried after `failedAttemptRetryInterval`. A
/// paragraph withheld because it could not be written in the reading language
/// follows `languageRetries` instead: a bounded schedule, after which only the
/// on-demand chevron generates it.
public final class AttachmentSummaryBackfillWorker: @unchecked Sendable {
    public typealias SummaryRunner = @Sendable (
        AttachmentSummaryInput,
        SummarizationTargetLanguage
    ) async -> AttachmentSummaryOutcome

    public static let attachmentsPerTick = 2
    public static let failedAttemptRetryInterval: TimeInterval = 30 * 60

    public struct RunOutcome: Sendable, Equatable {
        public let attachmentsVisited: Int
        public let summariesGenerated: Int
        public let summariesDeferred: Int
        public let summariesSkipped: Int
    }

    private static let evidenceReadByteLimit = 96_000

    private let summaryRunner: SummaryRunner
    private let targetLanguage: SummarizationTargetLanguage
    private let nowProvider: @Sendable () -> Date
    private let languageRetries: ReadingLanguageRetrySchedule?

    public convenience init(
        service: AttachmentSummaryService,
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred(),
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        languageRetries: ReadingLanguageRetrySchedule? = nil
    ) {
        self.init(
            targetLanguage: targetLanguage,
            nowProvider: nowProvider,
            languageRetries: languageRetries,
            summaryRunner: { input, language in
                await service.summaryOutcome(
                    for: input.attachmentID,
                    input: input,
                    targetLanguage: language
                )
            }
        )
    }

    public init(
        targetLanguage: SummarizationTargetLanguage = .ohiaPreferred(),
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        languageRetries: ReadingLanguageRetrySchedule? = nil,
        summaryRunner: @escaping SummaryRunner
    ) {
        self.targetLanguage = targetLanguage
        self.nowProvider = nowProvider
        self.languageRetries = languageRetries
        self.summaryRunner = summaryRunner
    }

    /// - Parameter excluding: attachments the reading-language retry schedule
    ///   holds back (`ReadingLanguageRetrySchedule.blocked`).
    @MainActor
    public static func hasPendingWork(
        context: ModelContext,
        now: Date = Date(),
        excluding: Set<UUID> = []
    ) -> Bool {
        let descriptor = FetchDescriptor<Attachment>(
            predicate: #Predicate<Attachment> { attachment in
                attachment.extractedTextPath != nil || attachment.visualSummary != nil
            }
        )
        let attachments = (try? context.fetch(descriptor)) ?? []
        return attachments.contains { excluding.contains($0.id) == false && needsSummaryAttempt($0, now: now) }
    }

    @MainActor
    public func runOnce(
        context: ModelContext,
        messageIDFromJob: UUID? = nil
    ) async throws -> RunOutcome {
        let now = nowProvider()
        let readingLanguage = targetLanguage.identifier
        let candidates = try selectCandidates(
            context: context,
            preferred: messageIDFromJob,
            now: now,
            excluding: Self.blockedByReadingLanguage(
                languageRetries,
                readingLanguage: readingLanguage,
                now: now,
                context: context
            )
        )
        guard candidates.isEmpty == false else {
            return RunOutcome(
                attachmentsVisited: 0,
                summariesGenerated: 0,
                summariesDeferred: 0,
                summariesSkipped: 0
            )
        }

        var generated = 0
        var deferred = 0
        var skipped = 0

        for attachment in candidates {
            guard let input = await Self.input(for: attachment) else {
                attachment.attachmentSummaryAttemptedAt = now
                attachment.attachmentSummaryFailureReason = "Attachment evidence could not be read"
                deferred += 1
                continue
            }

            let fingerprint = AttachmentSummaryService.fingerprint(
                input: input,
                targetLanguage: targetLanguage
            )
            if let current = Self.cleanedSummary(attachment.attachmentSummary),
               attachment.attachmentSummaryFingerprint == fingerprint {
                attachment.attachmentSummary = current
                attachment.attachmentSummaryFailureReason = nil
                skipped += 1
                continue
            }

            attachment.attachmentSummaryAttemptedAt = now
            let outcome = await summaryRunner(input, targetLanguage)
            if let paragraph = Self.cleanedSummary(outcome.result?.paragraph) {
                attachment.attachmentSummary = paragraph
                attachment.attachmentSummaryFingerprint = fingerprint
                attachment.attachmentSummaryGeneratedAt = now
                attachment.attachmentSummaryFailureReason = nil
                languageRetries?.clear(attachment.id)
                generated += 1
            } else if outcome == .withheldOutsideReadingLanguage {
                attachment.attachmentSummaryFailureReason =
                    "Attachment summary could not be written in \(targetLanguage.displayName)"
                languageRetries?.recordFailure(
                    attachment.id,
                    readingLanguage: readingLanguage,
                    inputMarker: Self.inputMarker(of: attachment),
                    now: now
                )
                deferred += 1
            } else {
                attachment.attachmentSummaryFailureReason = "Attachment summary generation returned no text"
                deferred += 1
            }
        }

        try context.save()
        return RunOutcome(
            attachmentsVisited: candidates.count,
            summariesGenerated: generated,
            summariesDeferred: deferred,
            summariesSkipped: skipped
        )
    }

    @MainActor
    private func selectCandidates(
        context: ModelContext,
        preferred messageID: UUID?,
        now: Date,
        excluding: Set<UUID>
    ) throws -> [Attachment] {
        if let messageID {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.id == messageID }
            )
            descriptor.fetchLimit = 1
            if let message = try context.fetch(descriptor).first {
                return message.attachments
                    .filter { excluding.contains($0.id) == false && Self.needsSummaryAttempt($0, now: now) }
                    .sorted { lhs, rhs in
                        lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
                    }
                    .prefix(Self.attachmentsPerTick)
                    .map { $0 }
            }
        }

        let descriptor = FetchDescriptor<Attachment>(
            predicate: #Predicate<Attachment> { attachment in
                attachment.extractedTextPath != nil || attachment.visualSummary != nil
            }
        )
        let attachments = try context.fetch(descriptor)
        return attachments
            .filter { excluding.contains($0.id) == false && Self.needsSummaryAttempt($0, now: now) }
            .sorted(by: Self.newestMessageFirst)
            .prefix(Self.attachmentsPerTick)
            .map { $0 }
    }

    @MainActor
    private static func input(for attachment: Attachment) async -> AttachmentSummaryInput? {
        let attachmentID = attachment.id
        let filename = attachment.filename
        let mimeType = attachment.mimeType
        let sizeBytes = attachment.sizeBytes
        let extractedTextPath = attachment.extractedTextPath
        let visualSummary = attachment.visualSummary
        let documentKind = attachment.detectedDocumentKind
        let structureUnitKind = attachment.extractionStructureUnitKind
        let structureUnitCount = attachment.extractionStructureUnitCount
        let characterCount = attachment.extractionCharacterCount
        let documentTitle = attachment.documentTitle
        let documentAuthor = attachment.documentAuthor
        guard let message = attachment.message else { return nil }
        let subject = message.subject
        let senderName = trimmed(message.fromName) ?? message.fromAddress
        let receivedAt = message.receivedAt ?? message.sentAt
        let purpose = MailClassificationJSON.decode(
            message.analysis?.mailClassificationJSON
        )?.purpose

        guard let evidence = await evidenceText(
            extractedTextPath: extractedTextPath,
            visualSummary: visualSummary
        ) else {
            return nil
        }

        return AttachmentSummaryInput(
            attachmentID: attachmentID,
            filename: filename,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            extractedText: evidence,
            documentKind: documentKind,
            structureUnitKind: structureUnitKind,
            structureUnitCount: structureUnitCount,
            characterCount: characterCount,
            documentTitle: documentTitle,
            documentAuthor: documentAuthor,
            anchorSubject: subject,
            anchorSenderName: senderName,
            anchorReceivedAt: receivedAt,
            anchorPurpose: purpose
        )
    }

    private static func evidenceText(
        extractedTextPath: String?,
        visualSummary: String?
    ) async -> String? {
        if let path = trimmed(extractedTextPath),
           let extracted = await readEvidenceText(path: path) {
            return extracted
        }
        guard let visualSummary = trimmed(visualSummary) else { return nil }
        return "VISUAL_SUMMARY: \(visualSummary)"
    }

    private static func readEvidenceText(path: String) async -> String? {
        await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path)
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return nil
            }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: Self.evidenceReadByteLimit) else {
                return nil
            }
            let text = String(decoding: data, as: UTF8.self)
            return trimmed(text)
        }.value
    }

    /// Attachments a reading-language retry schedule holds back now. One
    /// whose evidence changed since it failed is lifted.
    @MainActor
    public static func blockedByReadingLanguage(
        _ retries: ReadingLanguageRetrySchedule?,
        readingLanguage: String,
        now: Date,
        context: ModelContext
    ) -> Set<UUID> {
        guard let retries else { return [] }
        let tracked = Array(retries.trackedIDs(readingLanguage: readingLanguage))
        guard tracked.isEmpty == false else { return [] }
        let attachments = (try? context.fetch(FetchDescriptor<Attachment>(
            predicate: #Predicate<Attachment> { tracked.contains($0.id) }
        ))) ?? []
        let markers = Dictionary(
            attachments.map { ($0.id, inputMarker(of: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        return retries.blocked(readingLanguage: readingLanguage, now: now, inputMarker: { markers[$0] })
    }

    /// The evidence an attachment summary is generated from, read from the
    /// row without opening the text: the extracted-text file and its parser
    /// and size, and the visual extraction's parser and time. Re-extraction
    /// changes it.
    @MainActor
    static func inputMarker(of attachment: Attachment) -> String {
        [
            attachment.extractedTextPath ?? "",
            attachment.extractionParserVersion ?? "",
            attachment.extractionCharacterCount.map(String.init) ?? "",
            attachment.visualExtractionParserVersion ?? "",
            attachment.visualGeneratedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
        ].joined(separator: "|")
    }

    @MainActor
    private static func needsSummaryAttempt(_ attachment: Attachment, now: Date) -> Bool {
        guard hasEvidence(attachment) else { return false }
        if cleanedSummary(attachment.attachmentSummary) != nil,
           attachment.attachmentSummaryFingerprint?.isEmpty == false {
            return false
        }
        if let attemptedAt = attachment.attachmentSummaryAttemptedAt,
           now.timeIntervalSince(attemptedAt) < failedAttemptRetryInterval {
            return false
        }
        return true
    }

    @MainActor
    private static func hasEvidence(_ attachment: Attachment) -> Bool {
        trimmed(attachment.extractedTextPath) != nil || trimmed(attachment.visualSummary) != nil
    }

    @MainActor
    private static func newestMessageFirst(_ lhs: Attachment, _ rhs: Attachment) -> Bool {
        let lhsDate = lhs.message?.pipelineOrderingDate ?? .distantPast
        let rhsDate = rhs.message?.pipelineOrderingDate ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
    }

    private static func cleanedSummary(_ summary: String?) -> String? {
        guard let summary else { return nil }
        return AttachmentSummaryPostProcessor.clean(summary)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
