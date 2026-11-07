import Foundation
import SwiftData
import NaturalLanguage
import OhiaCore

#if canImport(AppKit)
import AppKit
#endif

/// Wires together the MIME parser, participant normalizer, attachment
/// extractor, deduplicator, and storage layer to ingest raw RFC 5322 IMAP
/// messages into the Ohia data store.
public final class IngestionOrchestrator {
    /// Per-attachment payload cap for the first-run extraction tier
    /// (`AttachmentExtractor.TextExtractionPolicy.bounded`). Office docs up to
    /// this size are extracted inline during ingest; PDFs, larger payloads, and
    /// images get deferred to dedicated attachment workers. 2 MB
    /// covers ~95% of real-world email attachments while keeping worst-case
    /// inline parse time bounded to a few hundred ms on Apple Silicon.
    public static let firstRunExtractionByteCap: Int = 2 * 1024 * 1024

    private let context: ModelContext
    private let canonicalStore: CanonicalStore
    private static let canonicalSummarizePriority = 6


    public init(context: ModelContext, canonicalStore: CanonicalStore) {
        self.context = context
        self.canonicalStore = canonicalStore
    }

    private struct PersistedAttachmentExtractionArtifacts {
        var extractedTextPath: String?
        var embeddingTextPath: String?
        var extractionMetadataPath: String?
        var ragDocumentPath: String?
    }

    /// All output from the off-MainActor parse phase. Sendable so the
    /// concurrent task that produced it can hand it back to MainActor for
    /// SwiftData persistence without copying overhead from `@unchecked`
    /// shenanigans. Heavy CPU/GPU work (LiteParse, Vision OCR, MIME decode)
    /// has already finished by the time a value of this type exists.
    static func detectedLanguageCode(
        in text: String,
        allowedLanguageIDs: [String]? = nil
    ) -> String? {
        let allowedFamilies = allowedLanguageIDs.map {
            Set($0.compactMap(DraftLanguage.familyID(for:)))
        }
        if let allowedFamilies, allowedFamilies.isEmpty {
            return nil
        }
        func isAllowed(_ identifier: String) -> Bool {
            guard let allowedFamilies else { return true }
            guard let family = DraftLanguage.familyID(for: identifier) else { return false }
            return allowedFamilies.contains(family)
        }

        let rawSample = languageRawSampleWindow(from: text)
        let sample = languageSample(fromRawSample: rawSample)
        guard languageMeaningfulCharacterCount(in: sample) >= languageMinimumMeaningfulCharacters else {
            return nil
        }

        if let primary = confidentLanguageCode(in: sample, confidenceFloor: languageMinimumConfidence),
           isAllowed(primary) {
            return primary
        }

        return languageFallbackCandidates(rawSample: rawSample, collapsedSample: sample)
            .first(where: isAllowed)
    }

    /// Languages this account is configured to draft in. An account without
    /// an explicit drafting list inherits Settings → Languages → Content
    /// languages, matching the Composer language menu.
    private static func configuredDraftLanguageIDs(for account: Account) -> [String]? {
        let accountIDs = account.draftLanguages.compactMap(DraftLanguage.familyID(for:))
        if !accountIDs.isEmpty {
            return accountIDs
        }

        let inheritedIDs = ContentLanguagesStore.modelSupportedIDs(
            from: OhiaSharedDefaults.store.data(forKey: ContentLanguagesStore.defaultsKey)
        )
        return inheritedIDs.isEmpty ? nil : inheritedIDs
    }

    private static let languageMinimumMeaningfulCharacters = 16
    private static let languageMinimumConfidence = 0.55
    private static let languageMinimumMixedEvidenceCharacters = 48
    private static let languageMinimumScriptEvidenceCharacters = 32
    private static let languageMinimumSegmentConfidence = 0.65
    private static let languageSampleCharacterLimit = 1_600
    private static let languageRawSampleWindowMultiplier = 4
    private static let languageMaxSegmentCandidates = 24

    private static func languageRawSampleWindow(from text: String) -> String {
        String(text.prefix(languageSampleCharacterLimit * languageRawSampleWindowMultiplier))
    }

    private static func languageSample(fromRawSample rawSample: String) -> String {
        let collapsed = rawSample
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return String(collapsed.prefix(languageSampleCharacterLimit))
    }

    private static func languageMeaningfulCharacterCount(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) {
                count += 1
            }
        }
    }

    private static func confidentLanguageCode(in text: String, confidenceFloor: Double) -> String? {
        guard languageMeaningfulCharacterCount(in: text) >= languageMinimumMeaningfulCharacters else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage,
              dominant != .undetermined else {
            return nil
        }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard (hypotheses[dominant] ?? 0) >= confidenceFloor else {
            return nil
        }
        return normalizedLanguageIdentifier(dominant.rawValue)
    }

    private static func normalizedLanguageIdentifier(_ identifier: String) -> String {
        identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    private static func languageFallbackCandidates(rawSample: String, collapsedSample: String) -> [String] {
        var candidates: [(code: String, weight: Int)] = []
        candidates.append(contentsOf: languageScriptCandidates(in: collapsedSample))
        candidates.append(contentsOf: languageSegmentCandidates(in: rawSample))
        return candidates
            .reduce(into: [String: (code: String, weight: Int)]()) { bestByCode, candidate in
                let key = candidate.code.split(separator: "-").first.map(String.init) ?? candidate.code
                guard let existing = bestByCode[key] else {
                    bestByCode[key] = candidate
                    return
                }
                if candidate.weight > existing.weight {
                    bestByCode[key] = candidate
                }
            }
            .values
            .sorted {
                if $0.weight == $1.weight { return $0.code < $1.code }
                return $0.weight > $1.weight
            }
            .map(\.code)
    }

    private static func languageSegmentCandidates(in sample: String) -> [(code: String, weight: Int)] {
        languageSegments(from: sample).compactMap { segment in
            let count = languageMeaningfulCharacterCount(in: segment)
            guard count >= languageMinimumMixedEvidenceCharacters,
                  let code = confidentLanguageCode(in: segment, confidenceFloor: languageMinimumSegmentConfidence) else {
                return nil
            }
            return (code, count)
        }
    }

    private static func languageSegments(from sample: String) -> [String] {
        var segments: [String] = []
        var current: [String] = []

        func flush() {
            let segment = current.joined(separator: " ")
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .joined(separator: " ")
            if segment.isEmpty == false {
                segments.append(String(segment.prefix(languageSampleCharacterLimit)))
            }
            current.removeAll(keepingCapacity: true)
        }

        for rawLine in sample.components(separatedBy: .newlines) {
            let line = strippedEmailQuotePrefix(from: rawLine)
            if line.isEmpty {
                flush()
            } else {
                current.append(line)
            }
            if segments.count >= languageMaxSegmentCandidates { break }
        }
        flush()
        return Array(segments.prefix(languageMaxSegmentCandidates))
    }

    private static func strippedEmailQuotePrefix(from line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix(">") {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func languageScriptCandidates(in sample: String) -> [(code: String, weight: Int)] {
        let buckets = LanguageScriptBuckets(sample)
        var candidates: [(code: String, weight: Int)] = []

        if buckets.japaneseEvidenceCount >= languageMinimumScriptEvidenceCharacters,
           let code = confidentLanguageCode(
            in: buckets.japaneseEvidence,
            confidenceFloor: languageMinimumSegmentConfidence
           ) {
            candidates.append((code, buckets.japaneseEvidenceCount))
        }

        for bucket in buckets.nonJapaneseBuckets where bucket.count >= languageMinimumScriptEvidenceCharacters {
            if let code = confidentLanguageCode(in: bucket.text, confidenceFloor: languageMinimumSegmentConfidence) {
                candidates.append((code, bucket.count))
            }
        }

        return candidates
    }

    private struct LanguageScriptBuckets {
        let japaneseEvidence: String
        let japaneseEvidenceCount: Int
        let nonJapaneseBuckets: [(text: String, count: Int)]

        init(_ sample: String) {
            var kanaScalars: [UnicodeScalar] = []
            var hanScalars: [UnicodeScalar] = []
            var hangulScalars: [UnicodeScalar] = []
            var cyrillicScalars: [UnicodeScalar] = []
            var arabicScalars: [UnicodeScalar] = []
            var hebrewScalars: [UnicodeScalar] = []
            var devanagariScalars: [UnicodeScalar] = []
            var thaiScalars: [UnicodeScalar] = []
            var greekScalars: [UnicodeScalar] = []

            for scalar in sample.unicodeScalars {
                switch scalar.value {
                case 0x3040...0x30FF:
                    kanaScalars.append(scalar)
                case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                    hanScalars.append(scalar)
                case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
                    hangulScalars.append(scalar)
                case 0x0400...0x052F:
                    cyrillicScalars.append(scalar)
                case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF:
                    arabicScalars.append(scalar)
                case 0x0590...0x05FF:
                    hebrewScalars.append(scalar)
                case 0x0900...0x097F:
                    devanagariScalars.append(scalar)
                case 0x0E00...0x0E7F:
                    thaiScalars.append(scalar)
                case 0x0370...0x03FF, 0x1F00...0x1FFF:
                    greekScalars.append(scalar)
                default:
                    continue
                }
            }

            let kana = String(String.UnicodeScalarView(kanaScalars))
            let han = String(String.UnicodeScalarView(hanScalars))
            self.japaneseEvidence = kana + han
            self.japaneseEvidenceCount = kanaScalars.count + hanScalars.count
            self.nonJapaneseBuckets = [
                String(String.UnicodeScalarView(hanScalars)),
                String(String.UnicodeScalarView(hangulScalars)),
                String(String.UnicodeScalarView(cyrillicScalars)),
                String(String.UnicodeScalarView(arabicScalars)),
                String(String.UnicodeScalarView(hebrewScalars)),
                String(String.UnicodeScalarView(devanagariScalars)),
                String(String.UnicodeScalarView(thaiScalars)),
                String(String.UnicodeScalarView(greekScalars))
            ].map { text in
                (text: text, count: text.unicodeScalars.count)
            }
        }
    }

    private func persistAttachmentExtractionResult(
        _ result: AttachmentExtractionResult,
        attachment: Attachment,
        messageId: String,
        filename: String
    ) throws {
        let artifacts = try persistAttachmentExtractionArtifacts(
            result,
            messageId: messageId,
            filename: filename
        )
        attachment.applyExtractionResult(result)
        AttachmentExtractionRetryPolicy.recordAttempt(
            attachment: attachment,
            result: result
        )
        attachment.extractedTextPath = artifacts.extractedTextPath
        attachment.embeddingTextPath = artifacts.embeddingTextPath
        attachment.extractionMetadataPath = artifacts.extractionMetadataPath
        attachment.ragDocumentPath = artifacts.ragDocumentPath
    }

    private func persistAttachmentExtractionArtifacts(
        _ result: AttachmentExtractionResult,
        messageId: String,
        filename: String
    ) throws -> PersistedAttachmentExtractionArtifacts {
        guard let text = result.text,
              result.hasExtractedText else {
            return PersistedAttachmentExtractionArtifacts()
        }
        try canonicalStore.saveAttachmentText(
            messageId: messageId,
            filename: filename,
            text: text
        )
        var artifacts = PersistedAttachmentExtractionArtifacts(
            extractedTextPath: canonicalStore.attachmentPath(
                messageId: messageId,
                filename: filename + ".txt"
            ).path
        )
        if let embeddingText = result.embeddingText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !embeddingText.isEmpty {
            try canonicalStore.saveAttachmentEmbeddingText(
                messageId: messageId,
                filename: filename,
                text: embeddingText
            )
            artifacts.embeddingTextPath = canonicalStore.attachmentEmbeddingTextPath(
                messageId: messageId,
                filename: filename
            ).path
        }
        if let metadataJSON = result.normalizedIRJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
           !metadataJSON.isEmpty {
            try canonicalStore.saveAttachmentExtractionMetadata(
                messageId: messageId,
                filename: filename,
                json: metadataJSON
            )
            artifacts.extractionMetadataPath = canonicalStore.attachmentExtractionMetadataPath(
                messageId: messageId,
                filename: filename
            ).path
        }
        if let ragDocumentJSON = result.ragDocumentJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ragDocumentJSON.isEmpty {
            try canonicalStore.saveAttachmentRAGDocument(
                messageId: messageId,
                filename: filename,
                json: ragDocumentJSON
            )
            artifacts.ragDocumentPath = canonicalStore.attachmentRAGDocumentPath(
                messageId: messageId,
                filename: filename
            ).path
        }
        return artifacts
    }

    private func findOrCreateParticipant(
        email: String,
        displayName: String?
    ) throws -> Participant {
        let lowered = email.lowercased()
        let fetchDescriptor = FetchDescriptor<Participant>(
            predicate: #Predicate<Participant> { participant in
                participant.emailAddress == lowered
            }
        )
        let existing = try context.fetch(fetchDescriptor)
        if let found = existing.first {
            // Update display name if we have a new one and the old is nil
            if found.displayName == nil, let name = displayName {
                found.displayName = name
            }
            return found
        }

        let participant = Participant(emailAddress: email, displayName: displayName)
        context.insert(participant)
        return participant
    }

    // MARK: - Pending-deletion early-exit hook

    /// Drop any `PendingDeletionCandidate` rows matching `(accountID,
    /// messageIdHeader)`. Called by the ingestion path immediately after a
    /// new `Message` is persisted, so a fast move (destination polled
    /// within seconds of source VANISHED) resolves without waiting for the
    /// configured grace-period boundary.
    ///
    /// The caller is responsible for executing this on the same actor that
    /// owns `modelContext` (MainActor for production contexts).
    public static func dropPendingDeletionsMatching(
        modelContext: ModelContext,
        accountID: UUID,
        messageIdHeader: String
    ) throws {
        guard let normalizedMessageID = normalizeMessageIDHeader(messageIdHeader) else { return }
        let descriptor = FetchDescriptor<PendingDeletionCandidate>(predicate: #Predicate { c in
            c.accountID == accountID
        })
        let matches = try modelContext.fetch(descriptor).filter {
            normalizeMessageIDHeader($0.messageIdHeader) == normalizedMessageID
        }
        guard !matches.isEmpty else { return }
        for candidate in matches {
            modelContext.delete(candidate)
        }
        try modelContext.save()
    }

    /// Parses an RFC 5322 date string into a `Date`.
    ///
    /// Tries multiple common formats:
    /// - "EEE, dd MMM yyyy HH:mm:ss Z"
    /// - "dd MMM yyyy HH:mm:ss Z"
    /// - "EEE, dd MMM yyyy HH:mm:ss ZZZZZ"
    public nonisolated static func parseEmailDateHeader(_ dateString: String?) -> Date? {
        guard let dateString else { return nil }

        let trimmed = dateString
            .replacingOccurrences(
                of: #"\s*\([^)]*\)"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespaces)

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss ZZZZZ",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "EEE, dd MMM yyyy HH:mm ZZZZZ",
            "EEE, dd MMM yyyy HH:mm zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss ZZZZZ",
            "dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm ZZZZZ",
            "dd MMM yyyy HH:mm zzz",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss ZZZZZ",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm Z",
            "EEE, d MMM yyyy HH:mm ZZZZZ",
            "EEE, d MMM yyyy HH:mm zzz",
            "d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss ZZZZZ",
            "d MMM yyyy HH:mm:ss zzz",
            "d MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm ZZZZZ",
            "d MMM yyyy HH:mm zzz"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    private func parseRFC5322Date(_ dateString: String?) -> Date? {
        Self.parseEmailDateHeader(dateString)
    }

    private static func summarizableBodyText(from parsed: ParsedEmail) -> String? {
        parsed.summarizableBodyText
    }

    private func enqueueCanonicalSummarizeJobIfNeeded(for message: Message) throws {
        let hasClassification = MailClassificationJSON.isComplete(
            message.analysis?.mailClassificationJSON
        )
        let hasRequiredTriage = !message.isLiveInboundTriageEligible
            || Self.hasCompleteTriageVerdict(message.analysis?.triageVerdictJSON)
        if hasClassification, hasRequiredTriage {
            return
        }

        try enqueueCanonicalInterpretationDrainIfNeeded()
    }

    private static func hasCompleteTriageVerdict(_ value: String?) -> Bool {
        TriageVerdictJSON.hasRequiredBooleanFields(value)
    }

    private func enqueueCanonicalInterpretationDrainIfNeeded() throws {
        let descriptor = FetchDescriptor<Job>()
        let jobs = try context.fetch(descriptor)
        if let existing = jobs.first(where: { job in
            (job.status == .pending || job.status == .running || job.status == .failed)
                && job.type == .summarize
                && job.messageId == nil
        }) {
            guard existing.status != .running else { return }
            existing.status = .pending
            existing.startedAt = nil
            existing.completedAt = nil
            existing.error = nil
            existing.nextAttemptAt = nil
            existing.retryCount = 0
            if existing.priority > Self.canonicalSummarizePriority {
                existing.priority = Self.canonicalSummarizePriority
            }
            return
        }

        let job = Job(type: .summarize, priority: Self.canonicalSummarizePriority)
        context.insert(job)
    }

    // MARK: - Single raw RFC 5322 ingestion (IMAP)

    /// Ingest a raw RFC 5322 message received over IMAP, including MIME parse,
    /// hash, dedup, language detect, canonical store, attachments, and participants.
    ///
    /// - Parameters:
    ///   - data: the full message bytes as returned by `UID FETCH BODY.PEEK[]`
    ///   - account: the owning IMAP account.
    ///   - folderPath: the IMAP folder path (e.g. `"INBOX"`, `"[Gmail]/All Mail"`)
    ///   - serverUID: the server-assigned UID for this message in `folderPath`
    @discardableResult
    public func ingestRawRFC5322(
        data: Data,
        account: Account,
        folderPath: String,
        folderAttributes: [String] = [],
        serverUID: UInt32,
        folderUIDValidity: UInt32? = nil,
        receivedAt: Date? = nil,
        seenAtSource: Bool? = nil,
        liveDetectedAt: Date? = nil,
        isPromotion: Bool = false
    ) throws -> IMAPRawMessageIngestionResult {
        guard !AccountDisconnectionRequest.isPending else { throw CancellationError() }
        guard isPromotion || !IMAPFolderIngestionPolicy.isExcluded(folderName: folderPath, attributes: folderAttributes) else {
            return .skipped
        }

        let parsed = try MIMEParser.parse(data: data)
        if IMAPFolderIngestionPolicy.isDraftsFolder(folderName: folderPath, attributes: folderAttributes) {
            try upsertMailboxDraft(
                parsed: parsed,
                account: account,
                folderPath: folderPath,
                serverUID: serverUID,
                folderUIDValidity: folderUIDValidity,
                sourceDate: receivedAt ?? parseRFC5322Date(parsed.date)
            )
            return .skipped
        }

        if !isPromotion {
            if let receivedAt,
               !account.acceptsIMAPLiveMessage(receivedAt: receivedAt) {
                return .skipped
            }
            if receivedAt == nil,
               !account.acceptsIMAPLiveMessage(receivedAt: parseRFC5322Date(parsed.date)) {
                return .skipped
            }
        }
        let fromHeader = parsed.from ?? ""
        let fromParticipants = ParticipantNormalizer.parse(fromHeader)
        let fromNormalized = fromParticipants.first
        let fromAddress = fromNormalized?.email ?? fromHeader.lowercased()
        let fromName = fromNormalized?.name

        // Gmail can expose a provider-synced Composer draft through All Mail
        // as well as Drafts. Require both the exact private Message-ID shape
        // and an account-owned author so an external sender cannot suppress
        // ingestion by spoofing the header.
        if account.ownsEmailAddress(fromAddress),
           isOhiaComposerMailboxDraftMessageID(parsed.messageId) {
            return .skipped
        }

        let bodySnippet = parsed.textBody ?? parsed.htmlBody ?? ""
        let hash = Deduplicator.contentHash(
            messageId: parsed.messageId,
            date: parsed.date,
            from: fromAddress,
            bodySnippet: bodySnippet
        )

        if let existingMessage = try existingMessage(
            accountID: account.id,
            folderPath: folderPath,
            serverUID: serverUID,
            contentHash: hash,
            messageIdHeader: parsed.messageId,
            fromAddress: fromAddress,
            sentAt: parseRFC5322Date(parsed.date)
        ) {
            try repairExistingMessageArtifacts(
                existingMessage,
                parsed: parsed,
                rawData: data,
                account: account,
                folderPath: folderPath,
                serverUID: serverUID,
                receivedAt: receivedAt,
                restoringFromTrash: isPromotion
            )
            ThreadAssigner.assignOnIngest(message: existingMessage, context: context)
            try enqueueCanonicalSummarizeJobIfNeeded(for: existingMessage)
            return IMAPRawMessageIngestionResult(
                disposition: .repairedExisting,
                messageId: existingMessage.id,
                isSentByUser: existingMessage.isSentByUser,
                hasSummarizableBody: Self.summarizableBodyText(from: parsed) != nil
                    || existingMessage.bodyTextPath != nil,
                allowsLiveInboundNotification: false
            )
        }

        let textForLanguage = parsed.textBody ?? parsed.htmlBody ?? ""
        let detectedLanguage = Self.detectedLanguageCode(
            in: textForLanguage,
            allowedLanguageIDs: Self.configuredDraftLanguageIDs(for: account)
        )

        let isSentByUser = account.ownsEmailAddress(fromAddress)

        let message = Message(
            fromAddress: fromAddress,
            subject: parsed.subject ?? "(no subject)"
        )
        message.fromName = fromName
        message.replyToAddressesJSON = Self.encodeAddresses(parsed.replyTo)
        message.contentHash = hash
        message.messageIdHeader = parsed.messageId
        message.inReplyTo = parsed.inReplyTo
        message.referencesChain = parsed.references
        message.languageDetected = detectedLanguage
        message.isSentByUser = isSentByUser
        let mailDropReferences = MailDropReference.references(in: parsed.headers)
        message.hasAttachments = !parsed.attachments.isEmpty || !mailDropReferences.isEmpty
        message.sentAt = parseRFC5322Date(parsed.date)
        message.receivedAt = receivedAt
        message.accountID = account.id
        message.account = account
        message.imapFolderPath = folderPath
        message.imapUID = serverUID
        let allowsLiveInboundNotification = !isPromotion && account.allowsIMAPLiveInboundNotification(
            dated: message.receivedAt ?? message.sentAt
        )
        if allowsLiveInboundNotification, !isSentByUser, let liveDetectedAt {
            message.liveDetectedAt = liveDetectedAt
        }
        // Seed read state from the IMAP \Seen flag captured by the
        // FETCH. nil leaves the message in the pre-migration unknown
        // state, which `isReadOrFalse` collapses to unread.
        message.applyReadState(
            seenAtSource,
            observedAt: message.ingestedAt
        )
        // The user's own sent messages should always be considered read
        // — they composed them. Overrides the \Seen flag in case a
        // server marks self-Sent rows unread (some Gmail filters do).
        if isSentByUser {
            message.applyReadState(true, observedAt: message.ingestedAt)
        }

        let messageIdString = message.id.uuidString
        try canonicalStore.saveRawMessage(messageId: messageIdString, data: data)
        message.rawPath = canonicalStore.messageDirectory(messageId: messageIdString)
            .appendingPathComponent("raw.eml").path

        if let bodyText = Self.summarizableBodyText(from: parsed) {
            try canonicalStore.saveBodyText(messageId: messageIdString, text: bodyText)
            message.bodyTextPath = canonicalStore.messageDirectory(messageId: messageIdString)
                .appendingPathComponent("body.txt").path
        }
        if let htmlBody = parsed.htmlBody {
            try canonicalStore.saveBodyHTML(messageId: messageIdString, html: htmlBody)
            message.bodyHtmlPath = canonicalStore.messageDirectory(messageId: messageIdString)
                .appendingPathComponent("body.html").path
        }
        context.insert(message)
        if isSentByUser {
            _ = try SentTrainingEvidenceStore().discover(
                message: message,
                account: account,
                context: context
            )
        }
        try enqueueCanonicalSummarizeJobIfNeeded(for: message)

        message.isAutomatedOrBulk = ListHeaderParser.isAutomatedOrBulk(parsed)

        if let listHeaders = ListHeaderParser.parse(
            parsed,
            accountOwnedAddresses: account.ownedEmailAddresses,
            isSentByUser: isSentByUser
        ) {
            MailingListAggregator.record(listHeaders, message: message, account: account, context: context)
        }

        // Fast-move early exit: if a PendingDeletionCandidate with the same
        // Message-ID exists (source VANISHED before destination was polled),
        // drop it now so the grace-period reaper is bypassed.
        if let header = message.messageIdHeader {
            try Self.dropPendingDeletionsMatching(
                modelContext: context,
                accountID: account.id,
                messageIdHeader: header
            )
        }

        for parsedAttachment in parsed.attachments {
            try canonicalStore.saveAttachment(
                messageId: messageIdString,
                filename: parsedAttachment.filename,
                data: parsedAttachment.data
            )
            let attachment = Attachment(
                filename: parsedAttachment.filename,
                mimeType: parsedAttachment.mimeType,
                sizeBytes: parsedAttachment.data.count
            )
            attachment.message = message
            attachment.filePath = canonicalStore.attachmentPath(
                messageId: messageIdString,
                filename: parsedAttachment.filename
            ).path
            attachment.contentId = Self.normalizedContentID(parsedAttachment.contentId)
            attachment.isInline = Self.computeIsInline(
                parsedAttachment: parsedAttachment,
                htmlBody: parsed.htmlBody
            )
            if let result = AttachmentExtractor.extract(
                data: parsedAttachment.data,
                mimeType: parsedAttachment.mimeType,
                filename: parsedAttachment.filename,
                policy: .bounded(maxBytes: Self.firstRunExtractionByteCap)
            ) {
                try persistAttachmentExtractionResult(
                    result,
                    attachment: attachment,
                    messageId: messageIdString,
                    filename: parsedAttachment.filename
                )
            }
            context.insert(attachment)
        }
        insertMailDropAttachments(mailDropReferences, into: message)

        let fromParticipant = try findOrCreateParticipant(
            email: fromAddress,
            displayName: fromName
        )
        context.insert(MessageParticipant(
            message: message,
            participant: fromParticipant,
            role: .from,
            headerPosition: 0
        ))

        if let toHeader = parsed.to {
            for (position, normalized) in ParticipantNormalizer.parse(toHeader).enumerated() {
                let p = try findOrCreateParticipant(
                    email: normalized.email,
                    displayName: normalized.name
                )
                context.insert(MessageParticipant(
                    message: message,
                    participant: p,
                    role: .to,
                    headerPosition: position
                ))
            }
        }
        if let ccHeader = parsed.cc {
            for (position, normalized) in ParticipantNormalizer.parse(ccHeader).enumerated() {
                let p = try findOrCreateParticipant(
                    email: normalized.email,
                    displayName: normalized.name
                )
                context.insert(MessageParticipant(
                    message: message,
                    participant: p,
                    role: .cc,
                    headerPosition: position
                ))
            }
        }
        if let bccHeader = parsed.bcc {
            for (position, normalized) in ParticipantNormalizer.parse(bccHeader).enumerated() {
                let p = try findOrCreateParticipant(
                    email: normalized.email,
                    displayName: normalized.name
                )
                context.insert(MessageParticipant(
                    message: message,
                    participant: p,
                    role: .bcc,
                    headerPosition: position
                ))
            }
        }

        // Attach the freshly inserted IMAP message to a `MessageThread` via
        // header-graph matching against existing rows.
        ThreadAssigner.assignOnIngest(message: message, context: context)

        account.messagesIngested += 1
        return IMAPRawMessageIngestionResult(
            disposition: .insertedNew,
            messageId: message.id,
            isSentByUser: isSentByUser,
            hasSummarizableBody: message.bodyTextPath != nil,
            allowsLiveInboundNotification: allowsLiveInboundNotification
        )
    }

    @discardableResult
    private func upsertMailboxDraft(
        parsed: ParsedEmail,
        account: Account,
        folderPath: String,
        serverUID: UInt32?,
        folderUIDValidity: UInt32?,
        sourceDate: Date?
    ) throws -> Draft {
        let fromIdentity = identityForMailboxDraft(parsed: parsed, account: account)
        let existing = try existingMailboxDraft(
            accountID: account.id,
            folderPath: folderPath,
            serverUID: serverUID,
            folderUIDValidity: folderUIDValidity,
            messageIDHeader: parsed.messageId
        )
        let draft = existing ?? {
            let created = Draft.userCompose(
                fromAccountID: account.id,
                identityID: fromIdentity?.id
            )
            context.insert(created)
            return created
        }()

        if let existing, existing.kind != .userCompose {
            let expectedMessageIDHeader = Self.stableMailboxDraftMessageIDHeader(for: existing)
            let providerMessageIDMatchesExpected =
                normalizeMessageIDHeader(parsed.messageId) == normalizeMessageIDHeader(expectedMessageIDHeader)
            stampMailboxDraftRemoteLocation(
                existing,
                accountID: account.id,
                folderPath: folderPath,
                serverUID: serverUID,
                folderUIDValidity: folderUIDValidity,
                messageIDHeader: providerMessageIDMatchesExpected ? parsed.messageId : nil
            )
            markReplyDraftSyncedIfProviderSnapshotMatches(
                existing,
                parsed: parsed,
                account: account,
                expectedMessageIDHeader: expectedMessageIDHeader
            )
            return existing
        }

        if let existing,
           existing.status == .pending,
           DraftRemoteSyncFingerprint.value(for: existing) != existing.mailboxDraftSyncFingerprint {
            if existing.kind == .userCompose {
                existing.composeFromAccountID = account.id
                existing.fromIdentityID = fromIdentity?.id
            }
            stampMailboxDraftRemoteLocation(
                existing,
                accountID: account.id,
                folderPath: folderPath,
                serverUID: serverUID,
                folderUIDValidity: folderUIDValidity,
                messageIDHeader: parsed.messageId
            )
            return existing
        }

        draft.kind = .userCompose
        draft.message = nil
        draft.status = .pending
        draft.composeFromAccountID = account.id
        draft.fromIdentityID = fromIdentity?.id
        draft.composeToJSON = Self.encodeAddresses(parsed.to)
        draft.composeCcJSON = Self.encodeAddresses(parsed.cc)
        draft.composeBccJSON = Self.encodeAddresses(parsed.bcc)
        draft.composeSubject = Self.nilIfBlank(parsed.subject)
        draft.replyText = Self.summarizableBodyText(from: parsed) ?? ""
        draft.bodyHTML = Self.nilIfBlank(parsed.htmlBody)
        draft.messageFormatRaw = (draft.bodyHTML == nil
            ? ComposerMessageFormat.plainText
            : ComposerMessageFormat.richText).rawValue
        draft.stageRaw = DraftStage.drafted
        draft.pendingInstruction = nil
        draft.draftingInstruction = nil
        draft.interviewStateJSON = nil
        draft.decisionResearchOverlayJSON = nil
        draft.decisionHistoryJSON = nil
        draft.composeInstruction = nil
        draft.mailboxDraftAccountID = account.id
        draft.mailboxDraftFolderPath = folderPath
        draft.mailboxDraftUID = serverUID.flatMap { $0 > 0 ? $0 : nil }
        draft.mailboxDraftUIDValidity = folderUIDValidity
        draft.mailboxDraftMessageIDHeader = Self.nilIfBlank(parsed.messageId)
        draft.mailboxDraftLastSeenAt = Date()
        draft.generatedAt = sourceDate ?? draft.generatedAt
        draft.deliverablesJSON = try persistMailboxDraftAttachments(parsed, draft: draft)
        draft.mailboxDraftSyncFingerprint = DraftRemoteSyncFingerprint.value(for: draft)
        draft.mailboxDraftLastSyncedAt = draft.mailboxDraftLastSeenAt
        draft.mailboxDraftSyncError = nil
        return draft
    }

    private func stampMailboxDraftRemoteLocation(
        _ draft: Draft,
        accountID: UUID,
        folderPath: String,
        serverUID: UInt32?,
        folderUIDValidity: UInt32?,
        messageIDHeader: String?
    ) {
        draft.mailboxDraftAccountID = accountID
        draft.mailboxDraftFolderPath = folderPath
        draft.mailboxDraftUID = serverUID.flatMap { $0 > 0 ? $0 : nil }
        draft.mailboxDraftUIDValidity = folderUIDValidity
        if let messageID = Self.nilIfBlank(messageIDHeader) {
            draft.mailboxDraftMessageIDHeader = messageID
        }
        draft.mailboxDraftLastSeenAt = Date()
    }

    private func markReplyDraftSyncedIfProviderSnapshotMatches(
        _ draft: Draft,
        parsed: ParsedEmail,
        account: Account,
        expectedMessageIDHeader: String
    ) {
        guard draft.status == .pending,
              let message = draft.message,
              let identity = account.resolveIdentity(for: draft.fromIdentityID),
              normalizeMessageIDHeader(parsed.messageId) == normalizeMessageIDHeader(expectedMessageIDHeader) else {
            return
        }
        let providerPlainBody = Self.summarizableBodyText(from: parsed) ?? ""
        let providerHTMLBody = Self.nilIfBlank(parsed.htmlBody)
        let draftHTMLBody = Self.nilIfBlank(draft.bodyHTML)
        guard providerPlainBody == draft.replyText,
              providerHTMLBody == draftHTMLBody,
              Self.replyAttachmentsMatch(draft: draft, parsed: parsed),
              Self.normalizedHeaderText(parsed.subject) == Self.normalizedHeaderText(Self.replySubject(for: message)),
              Self.addressEmails(parsed.from) == [identity.address.lowercased()],
              Self.firstDisplayName(parsed.from) == Self.nilIfBlank(identity.displayName),
              Self.addressEmails(parsed.headerValue(for: "Reply-To")) == Self.addressEmails(identity.replyTo),
              Self.addressEmails(parsed.to) == Self.expectedReplyToEmails(for: draft, message: message),
              Self.addressEmails(parsed.cc) == Self.expectedReplyCcEmails(for: draft),
              Self.addressEmails(parsed.bcc) == Self.expectedReplyBccEmails(for: draft),
              normalizeMessageIDHeader(parsed.inReplyTo) == normalizeMessageIDHeader(message.messageIdHeader),
              Self.normalizedMessageIDList(parsed.references) == Self.normalizedMessageIDList(Self.replyReferences(for: message)) else {
            return
        }
        draft.mailboxDraftSyncFingerprint = DraftRemoteSyncFingerprint.value(for: draft)
        draft.mailboxDraftLastSyncedAt = draft.mailboxDraftLastSeenAt
        draft.mailboxDraftSyncError = nil
    }

    /// A provider copy can reconcile a reply draft only when every user-added
    /// file attachment survived byte-for-byte. Inline body images are checked
    /// through the HTML/signature path and are not reply file attachments.
    private static func replyAttachmentsMatch(draft: Draft, parsed: ParsedEmail) -> Bool {
        let expectedPaths = ComposeAddressEncoding.decode(draft.replyAttachmentPathsJSON)
        var providerAttachments = parsed.attachments.filter {
            !computeIsInline(parsedAttachment: $0, htmlBody: parsed.htmlBody)
        }
        guard providerAttachments.count == expectedPaths.count else { return false }

        for path in expectedPaths {
            let url = URL(fileURLWithPath: path)
            guard let expectedData = try? Data(contentsOf: url) else { return false }
            let expectedName = normalizedAttachmentFilename(url.lastPathComponent)
            guard let matchIndex = providerAttachments.firstIndex(where: {
                normalizedAttachmentFilename($0.filename) == expectedName
                    && $0.data == expectedData
            }) else { return false }
            providerAttachments.remove(at: matchIndex)
        }
        return providerAttachments.isEmpty
    }

    private static func normalizedAttachmentFilename(_ filename: String) -> String {
        filename.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func stableMailboxDraftMessageIDHeader(for draft: Draft) -> String {
        if let stored = draft.mailboxDraftMessageIDHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored.hasPrefix("<") ? stored : "<\(stored)>"
        }
        return "<draft-\(draft.id.uuidString)@ohia.local>"
    }

    private static func replySubject(for message: Message) -> String {
        message.subject.hasPrefix("Re: ") ? message.subject : "Re: \(message.subject)"
    }

    private static func replyReferences(for message: Message) -> String? {
        var parts: [String] = []
        if let chain = message.referencesChain, !chain.isEmpty { parts.append(chain) }
        if let mid = message.messageIdHeader { parts.append(mid) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func expectedReplyToEmails(for draft: Draft, message: Message) -> [String] {
        if let json = draft.replyToAddressesJSON {
            return normalizedAddressList(ComposeAddressEncoding.decode(json))
        }
        return normalizedAddressList(
            ReplyRecipientPolicy.defaultRecipients(
                for: message,
                mode: draft.resolvedReplyRecipientMode
            ).to
        )
    }

    private static func expectedReplyCcEmails(for draft: Draft) -> [String] {
        if let json = draft.replyCcAddressesJSON {
            return normalizedAddressList(ComposeAddressEncoding.decode(json))
        }
        return normalizedAddressList(ReplyRecipientPolicy.effectiveRecipients(for: draft).cc)
    }

    private static func expectedReplyBccEmails(for draft: Draft) -> [String] {
        if let json = draft.replyBccAddressesJSON {
            return normalizedAddressList(ComposeAddressEncoding.decode(json))
        }
        return normalizedAddressList(ReplyRecipientPolicy.effectiveRecipients(for: draft).bcc)
    }

    private static func normalizedAddressList(_ addresses: [String]) -> [String] {
        addressEmails(addresses.joined(separator: ", "))
    }

    private static func addressEmails(_ header: String?) -> [String] {
        addressParticipants(header).map(\.email)
    }

    private static func addressParticipants(_ header: String?) -> [NormalizedParticipant] {
        guard let header = nilIfBlank(header) else { return [] }
        return ParticipantNormalizer.parse(MIMEHeaderDecoder.decodeEncodedWords(header))
    }

    private static func firstDisplayName(_ header: String?) -> String? {
        nilIfBlank(addressParticipants(header).first?.name)
    }

    private static func normalizedHeaderText(_ value: String?) -> String? {
        nilIfBlank(value)
    }

    private static func normalizedMessageIDList(_ value: String?) -> [String] {
        guard let value = nilIfBlank(value) else { return [] }
        return value
            .split(whereSeparator: \.isWhitespace)
            .compactMap { normalizeMessageIDHeader(String($0)) }
    }

    private func identityForMailboxDraft(parsed: ParsedEmail, account: Account) -> Identity? {
        let fromHeader = parsed.from ?? ""
        let fromAddress = ParticipantNormalizer.parse(fromHeader).first?.email
        if let fromAddress {
            return account.identities.first {
                $0.address.caseInsensitiveCompare(fromAddress) == .orderedSame
            } ?? account.primaryIdentity
        }
        return account.primaryIdentity
    }

    private func existingMailboxDraft(
        accountID: UUID,
        folderPath: String,
        serverUID: UInt32?,
        folderUIDValidity: UInt32?,
        messageIDHeader: String?
    ) throws -> Draft? {
        let drafts = try context.fetch(FetchDescriptor<Draft>())
        if let serverUID, serverUID > 0 {
            if let match = drafts.first(where: { draft in
                draft.mailboxDraftAccountID == accountID
                    && draft.mailboxDraftFolderPath == folderPath
                    && draft.mailboxDraftUID == serverUID
                    && (folderUIDValidity == nil || draft.mailboxDraftUIDValidity == folderUIDValidity)
            }) {
                return match
            }
        }

        guard let normalized = normalizeMessageIDHeader(messageIDHeader) else {
            return nil
        }
        let messageIDMatches = drafts.filter { draft in
            normalizeMessageIDHeader(draft.mailboxDraftMessageIDHeader) == normalized
        }
        if let currentAccountMatch = messageIDMatches.first(where: {
            $0.mailboxDraftAccountID == accountID
        }) {
            return currentAccountMatch
        }

        // Disconnect deletes the Account row but intentionally leaves Draft
        // rows in the shared Composer queue. A later reconnect creates a new
        // Account UUID, so reclaim an orphaned provider draft by its stable
        // RFC Message-ID instead of inserting a duplicate. Never adopt a row
        // owned by another still-connected account.
        let connectedAccountIDs = Set(
            try context.fetch(FetchDescriptor<Account>()).map(\.id)
        )
        return messageIDMatches.first(where: { draft in
            guard draft.kind == .userCompose,
                  let previousAccountID = draft.mailboxDraftAccountID else {
                return false
            }
            return !connectedAccountIDs.contains(previousAccountID)
        })
    }

    private static func encodeAddresses(_ header: String?) -> String? {
        ComposeAddressEncoding.encode(ParticipantNormalizer.parse(header ?? "").map(\.email))
    }

    private static func nilIfBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func persistMailboxDraftAttachments(
        _ parsed: ParsedEmail,
        draft: Draft
    ) throws -> String? {
        let attachmentPaths = try parsed.attachments.compactMap { attachment -> String? in
            if Self.computeIsInline(parsedAttachment: attachment, htmlBody: parsed.htmlBody) {
                return nil
            }
            let artifactID = "draft-\(draft.id.uuidString)"
            try canonicalStore.saveAttachment(
                messageId: artifactID,
                filename: attachment.filename,
                data: attachment.data
            )
            return canonicalStore.attachmentPath(
                messageId: artifactID,
                filename: attachment.filename
            ).path
        }
        return ComposeAddressEncoding.encode(attachmentPaths)
    }

    private func existingMessage(
        accountID: UUID,
        folderPath: String?,
        serverUID: UInt32?,
        contentHash: String,
        messageIdHeader: String?,
        fromAddress: String,
        sentAt: Date?
    ) throws -> Message? {
        if let folderPath,
           let serverUID,
           serverUID > 0,
           let message = try existingIMAPMessage(
            accountID: accountID,
            folderPath: folderPath,
            serverUID: serverUID
           ) {
            return message
        }

        if let message = try existingMessage(accountID: accountID, contentHash: contentHash) {
            return message
        }

        return try existingMessageByRFCMessageID(
            accountID: accountID,
            messageIdHeader: messageIdHeader,
            fromAddress: fromAddress,
            sentAt: sentAt
        )
    }

    private func existingMessage(accountID: UUID, contentHash: String) throws -> Message? {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                (message.accountID == accountID || message.account?.id == accountID)
                    && message.contentHash == contentHash
            },
            sortBy: [SortDescriptor(\.ingestedAt)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func existingIMAPMessage(
        accountID: UUID,
        folderPath: String,
        serverUID: UInt32
    ) throws -> Message? {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                (message.accountID == accountID || message.account?.id == accountID)
                    && message.imapFolderPath == folderPath
                    && message.imapUID == serverUID
            }
        )
        return try context.fetch(descriptor).first
    }

    private func existingMessageByRFCMessageID(
        accountID: UUID,
        messageIdHeader: String?,
        fromAddress: String,
        sentAt: Date?
    ) throws -> Message? {
        guard let normalized = normalizeMessageIDHeader(messageIdHeader) else { return nil }
        let rawHeader = messageIdHeader?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bracketed = "<\(normalized)>"
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                (message.accountID == accountID || message.account?.id == accountID)
                    && (message.messageIdHeader == rawHeader
                        || message.messageIdHeader == normalized
                        || message.messageIdHeader == bracketed)
            },
            sortBy: [SortDescriptor(\.ingestedAt)]
        )
        let candidates = try context.fetch(descriptor)
        return candidates.first(where: {
            sameLogicalSenderAndDate($0, fromAddress: fromAddress, sentAt: sentAt)
        })
    }

    private func sameLogicalSenderAndDate(
        _ message: Message,
        fromAddress: String,
        sentAt: Date?
    ) -> Bool {
        guard message.fromAddress.caseInsensitiveCompare(fromAddress) == .orderedSame else {
            return false
        }
        guard let lhs = message.sentAt, let rhs = sentAt else {
            return true
        }
        return abs(lhs.timeIntervalSince(rhs)) <= 24 * 60 * 60
    }

    /// Deduplication means repeated local/IMAP sightings reuse the existing
    /// SwiftData row. If file-backed artifacts were wiped or moved, however,
    /// a pure no-op leaves downstream jobs pointing at missing `body.txt`
    /// files forever. Repair only absent artifacts; healthy rows stay cheap.
    private func repairExistingMessageArtifacts(
        _ message: Message,
        parsed: ParsedEmail,
        rawData: Data,
        account: Account,
        folderPath: String?,
        serverUID: UInt32?,
        receivedAt: Date?,
        restoringFromTrash: Bool = false
    ) throws {
        let fileManager = FileManager.default
        let messageId = message.id.uuidString
        var repairedBodyText = false

        if restoringFromTrash {
            message.trashedAt = nil
        }

        if message.accountID == nil {
            message.accountID = account.id
        }
        if message.account == nil {
            message.account = account
        }
        if message.replyToAddressesJSON == nil {
            message.replyToAddressesJSON = Self.encodeAddresses(parsed.replyTo)
        }
        let folderIsExcluded = folderPath.map {
            IMAPFolderIngestionPolicy.isExcluded(folderName: $0, attributes: [])
        } ?? false
        if !folderIsExcluded, let folderPath {
            message.imapFolderPath = folderPath
        }
        if !folderIsExcluded, let serverUID {
            message.imapUID = serverUID
        }
        if message.receivedAt == nil, let receivedAt {
            message.receivedAt = receivedAt
        }
        if !message.isSentByUser, account.ownsEmailAddress(message.fromAddress) {
            message.isSentByUser = true
            message.applyReadState(true, observedAt: message.ingestedAt)
            message.trainingStatus = .pending
            if let analysis = message.analysis {
                analysis.bodySummary = nil
                analysis.bodySummaryInputFingerprint = nil
                analysis.mailClassificationJSON = nil
                analysis.triageVerdictJSON = nil
                analysis.interpretedAt = nil
                analysis.summarizedAt = nil
            }
            message.classifiedAt = nil
            message.messageType = .unclassified
            message.embeddingStatus = .pending
        }
        if folderPath != nil, !folderIsExcluded, let header = message.messageIdHeader {
            try Self.dropPendingDeletionsMatching(
                modelContext: context,
                accountID: account.id,
                messageIdHeader: header
            )
        }

        if artifactMissing(message.rawPath, fileManager: fileManager) {
            try canonicalStore.saveRawMessage(messageId: messageId, data: rawData)
            message.rawPath = canonicalStore.messageDirectory(messageId: messageId)
                .appendingPathComponent("raw.eml").path
        }

        if let bodyText = Self.summarizableBodyText(from: parsed),
           artifactMissing(message.bodyTextPath, fileManager: fileManager) {
            try canonicalStore.saveBodyText(messageId: messageId, text: bodyText)
            message.bodyTextPath = canonicalStore.messageDirectory(messageId: messageId)
                .appendingPathComponent("body.txt").path
            repairedBodyText = true
        }

        if let htmlBody = parsed.htmlBody,
           artifactMissing(message.bodyHtmlPath, fileManager: fileManager) {
            try canonicalStore.saveBodyHTML(messageId: messageId, html: htmlBody)
            message.bodyHtmlPath = canonicalStore.messageDirectory(messageId: messageId)
                .appendingPathComponent("body.html").path
        }

        // Backfill the inline-image distinction on existing Attachment rows
        // ingested before `contentId` / `isInline` were tracked. Only rows
        // missing both fields are touched, and only when the parsed MIME
        // still has matching parts (by filename + byte count) so we never
        // overwrite an explicit `false` set by a previous ingestion.
        backfillAttachmentInlineFlags(message: message, parsed: parsed)

        let knownRemoteURLs = Set(message.attachments.compactMap(\.remoteURL))
        let missingMailDrops = MailDropReference.references(in: parsed.headers)
            .filter { !knownRemoteURLs.contains($0.url.absoluteString) }
        if !missingMailDrops.isEmpty {
            insertMailDropAttachments(missingMailDrops, into: message)
            message.hasAttachments = true
        }

        if message.isSentByUser {
            _ = try SentTrainingEvidenceStore().discover(
                message: message,
                account: account,
                context: context
            )
        }

        guard repairedBodyText else { return }

        // Prior attempts may have embedded only metadata because the body file
        // was absent. Re-queue embedding so repaired text reaches the vector
        // pipeline.
        message.embeddingStatus = .pending
        if message.isSentByUser {
            message.trainingStatus = .pending
        }
    }

    /// Mail Drop files become attachment rows without a local file. Text
    /// extraction is terminal up front (the bytes are on iCloud, not in the
    /// message); the capture-metadata worker reads their header remotely.
    private func insertMailDropAttachments(_ references: [MailDropReference], into message: Message) {
        for reference in references {
            let attachment = Attachment(
                filename: reference.filename,
                mimeType: reference.mimeType,
                sizeBytes: reference.declaredSizeBytes
            )
            attachment.message = message
            attachment.remoteURL = reference.url.absoluteString
            attachment.remoteExpiresAt = reference.expiresAt
            attachment.isInline = false
            let failure = AttachmentExtractionResult.failure(
                kind: DocumentKind.detect(mimeType: reference.mimeType, filename: reference.filename),
                status: .unsupportedType,
                method: nil,
                failureReason: "Mail Drop file stored on iCloud"
            )
            attachment.applyExtractionResult(failure)
            AttachmentExtractionRetryPolicy.recordAttempt(attachment: attachment, result: failure)
            context.insert(attachment)
        }
    }

    private func artifactMissing(_ path: String?, fileManager: FileManager = .default) -> Bool {
        guard let path, !path.isEmpty else { return true }
        return !fileManager.fileExists(atPath: path)
    }

    /// Populates `contentId` / `isInline` on existing `Attachment` rows that
    /// pre-date the inline-distinction tracking. Matches parsed MIME parts to
    /// SwiftData rows by filename + byte count (the only stable identity pair
    /// available, since `Attachment` doesn't preserve part order). Idempotent:
    /// rows whose `isInline` is already non-nil are skipped, so a re-touched
    /// message never silently overrides an earlier ingestion's decision.
    private func backfillAttachmentInlineFlags(
        message: Message,
        parsed: ParsedEmail
    ) {
        let staleRows = message.attachments.filter { $0.isInline == nil }
        guard !staleRows.isEmpty, !parsed.attachments.isEmpty else { return }
        // Group parsed parts by (filename, byteCount) so two attachments with
        // the same name but different sizes don't collide.
        var partsByKey: [String: [ParsedAttachment]] = [:]
        for part in parsed.attachments {
            let key = "\(part.filename)|\(part.data.count)"
            partsByKey[key, default: []].append(part)
        }
        for row in staleRows {
            let key = "\(row.filename)|\(row.sizeBytes)"
            guard var matches = partsByKey[key], !matches.isEmpty else { continue }
            let part = matches.removeFirst()
            partsByKey[key] = matches
            row.contentId = Self.normalizedContentID(part.contentId)
            row.isInline = Self.computeIsInline(
                parsedAttachment: part,
                htmlBody: parsed.htmlBody
            )
        }
    }

    /// Strips surrounding `<` / `>` brackets and surrounding whitespace from a
    /// raw RFC 2045 `Content-ID` header value (`<abc123@example>` → `abc123@example`).
    /// A `cid:` URL in HTML references the bare form, so this normalization is
    /// required before substring-matching against the body.
    static func normalizedContentID(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("<") { value.removeFirst() }
        if value.hasSuffix(">") { value.removeLast() }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `true` when `htmlBody` contains a `cid:<contentID>` reference for the
    /// supplied (already-normalized) Content-ID. The `cid:` scheme prefix is
    /// matched case-insensitively (RFC 3986 §3.1 makes the scheme case-
    /// insensitive); the Content-ID value itself is matched case-sensitively
    /// (RFC 2392 §2 makes the cid value case-sensitive). A negative lookahead
    /// on the trailing character anchors the match so `cid:img1` cannot
    /// silently swallow `cid:img10@example` — the lookahead excludes every
    /// character that is legal inside an RFC 5322 `msg-id` so the match ends
    /// at the natural delimiter (`"`, `'`, `>`, `)`, whitespace, end of body).
    static func htmlBodyReferences(contentID: String, htmlBody: String?) -> Bool {
        guard let htmlBody, !htmlBody.isEmpty, !contentID.isEmpty else {
            return false
        }
        let escaped = NSRegularExpression.escapedPattern(for: contentID)
        // `(?i)cid:` turns case-insensitivity on for the scheme, `(?-i)`
        // turns it back off for the value. The trailing lookahead lists
        // the characters allowed in a `dot-atom-text` / `quoted-string`
        // msg-id body; anything outside this set is a real delimiter.
        let pattern = "(?i)cid:(?-i)\(escaped)(?![A-Za-z0-9._%+\\-@])"
        return htmlBody.range(of: pattern, options: [.regularExpression]) != nil
    }

    /// Computes the persisted `Attachment.isInline` flag from a parsed
    /// attachment and its parent message's HTML body. The flag is `true`
    /// only when both signals agree: the source part is `Content-Disposition:
    /// inline` AND its Content-ID is referenced by a `cid:` URL in the body.
    /// This is the suppress signal the locked-node overlay filters on.
    static func computeIsInline(
        parsedAttachment: ParsedAttachment,
        htmlBody: String?
    ) -> Bool {
        guard parsedAttachment.dispositionIsInline,
              let contentID = normalizedContentID(parsedAttachment.contentId) else {
            return false
        }
        return htmlBodyReferences(contentID: contentID, htmlBody: htmlBody)
    }
}
