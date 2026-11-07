import Foundation
import SwiftData
import OhiaCore
import OhiaML

/// Builds the `DeadlineSummaryInput` consumed by `DeadlineSummaryService` from a
/// `DeadlineEntry`. It gathers the deadline thread's message bodies (the
/// deadline-bearing message plus the most recent context in either direction)
/// and every real, non-inline attachment, so the model can distil the deadline
/// and the grounding pass can validate any URL / phone / address it emits.
///
/// Body loading reads the on-disk artifacts off the main actor (the same path
/// `DeadlineFocusedView` uses for the reader); only the SwiftData fetch runs on
/// the main actor.
enum DeadlineSummaryInputBuilder {
    /// Number of recent thread messages (beyond the representative) to feed as
    /// context, and the per-body character cap applied before the prompt's own
    /// total cap.
    private static let maxRecentContext = 2
    private static let maxAttachments = 6
    private static let perBodyCharacterLimit = 6_000
    /// Per-document cap on extracted text loaded into the input. The prompt
    /// builders re-cap per section; this bounds what the input (and its cache
    /// fingerprint) carries.
    private static let perDocumentCharacterLimit = 6_000

    @MainActor
    static func build(
        entry: DeadlineEntry,
        modelContext: ModelContext,
        userIdentity: SummarizationUserIdentity?,
        workFileStore: DeadlineWorkFileStore? = nil
    ) async -> DeadlineSummaryInput? {
        guard let gathered = gatherThread(representativeID: entry.representativeMessageID, modelContext: modelContext) else {
            return nil
        }

        var bodies: [DeadlineSummaryMessageBody] = []
        for candidate in gathered.bodyCandidates {
            let text = await Task.detached(priority: .userInitiated) {
                Self.bodyText(htmlPath: candidate.htmlPath, textPath: candidate.textPath, rawPath: candidate.rawPath)
            }.value
            guard let text, text.isEmpty == false else { continue }
            bodies.append(
                DeadlineSummaryMessageBody(
                    role: candidate.isSentByUser ? "outgoing" : "incoming",
                    senderName: candidate.senderName,
                    receivedAt: candidate.date,
                    text: String(text.prefix(perBodyCharacterLimit))
                )
            )
        }

        // Fold each attachment's ingestion-extracted text into its record so
        // the distillation can read the documents, ground tokens stated inside
        // them, and the readout pass can deep-read each one.
        var attachments: [DeadlineSummaryAttachment] = []
        for (attachment, extractedTextPath) in gathered.attachments {
            let extracted = await Task.detached(priority: .userInitiated) {
                Self.documentText(extractedTextPath: extractedTextPath)
            }.value
            attachments.append(
                DeadlineSummaryAttachment(
                    filename: attachment.filename,
                    mimeType: attachment.mimeType,
                    filePath: attachment.filePath,
                    documentKind: attachment.documentKind,
                    extractedText: extracted
                )
            )
        }

        // The owner's working files for this deadline, parsed once (sidecar-
        // cached) by the store.
        var workingFiles: [DeadlineSummaryAttachment] = []
        if let workFileStore {
            for file in workFileStore.files(entryID: entry.id) {
                let extracted = await workFileStore.extractedText(for: file)
                workingFiles.append(
                    DeadlineSummaryAttachment(
                        filename: file.filename,
                        mimeType: "application/octet-stream",
                        filePath: file.url.path,
                        documentKind: nil,
                        extractedText: extracted.map { String($0.prefix(perDocumentCharacterLimit)) }
                    )
                )
            }
        }

        let correspondents = entry.correspondents.map {
            DeadlineSummaryParticipant(name: $0.displayName ?? "", email: $0.email)
        }
        let dateText = entry.granularity == .dateTime
            ? DeadlineFormatting.dayTimeLabel(entry.deadlineDate)
            : DeadlineFormatting.dayLabel(entry.deadlineDate)

        return DeadlineSummaryInput(
            accountID: gathered.accountID,
            title: entry.title,
            deadlineLabel: deadlineLabel(entry),
            deadlineDate: entry.deadlineDate,
            deadlineDateText: dateText,
            surfaceText: entry.surfaceText,
            correspondents: correspondents,
            bodies: bodies,
            attachments: attachments,
            workingFiles: workingFiles,
            userIdentity: userIdentity
        )
    }

    // MARK: - Thread gather (main actor)

    private struct BodyCandidate {
        let id: UUID
        let senderName: String
        let date: Date
        let isSentByUser: Bool
        let htmlPath: String?
        let textPath: String?
        let rawPath: String?
    }

    private struct Gathered {
        let accountID: UUID?
        let bodyCandidates: [BodyCandidate]
        /// Each attachment record paired with its ingestion-extracted text
        /// path, loaded off-main after the SwiftData fetch.
        let attachments: [(attachment: DeadlineSummaryAttachment, extractedTextPath: String?)]
    }

    @MainActor
    private static func gatherThread(representativeID: UUID, modelContext: ModelContext) -> Gathered? {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == representativeID })
        descriptor.fetchLimit = 1
        guard let representative = try? modelContext.fetch(descriptor).first else { return nil }
        let threadMessages = representative.thread?.messages ?? [representative]

        func sortDate(_ message: Message) -> Date {
            message.receivedAt ?? message.sentAt ?? message.ingestedAt
        }
        let ordered = threadMessages.sorted { sortDate($0) > sortDate($1) }
        let accountID = SummarizationAccountResolver.singleAccountID(
            in: ordered.map { $0.accountID ?? $0.account?.id }
        )

        // Representative first, then the most recent context in either
        // direction (excluding the representative), so the deadline-bearing
        // message always leads while the owner's replies can advance its state.
        var chosen: [Message] = [representative]
        for message in ordered where message.id != representative.id {
            guard chosen.count < 1 + maxRecentContext else { break }
            chosen.append(message)
        }

        let bodyCandidates = chosen.map { message in
            BodyCandidate(
                id: message.id,
                senderName: message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords) ?? message.fromAddress,
                date: sortDate(message),
                isSentByUser: message.isSentByUser,
                htmlPath: message.bodyHtmlPath,
                textPath: message.bodyTextPath,
                rawPath: message.rawPath
            )
        }

        // Attachments across the whole thread — a form can arrive in a different
        // message than the one that states the date. Inline images are excluded.
        var attachments: [(attachment: DeadlineSummaryAttachment, extractedTextPath: String?)] = []
        var seenFilenames = Set<String>()
        for message in ordered {
            for attachment in message.attachments where attachment.isInline != true {
                let filename = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines)
                guard filename.isEmpty == false else { continue }
                let key = filename.lowercased()
                guard seenFilenames.insert(key).inserted else { continue }
                attachments.append(
                    (
                        attachment: DeadlineSummaryAttachment(
                            filename: filename,
                            mimeType: attachment.mimeType,
                            filePath: attachment.filePath,
                            documentKind: attachment.detectedDocumentKind
                        ),
                        extractedTextPath: attachment.extractedTextPath
                    )
                )
                if attachments.count >= maxAttachments { break }
            }
            if attachments.count >= maxAttachments { break }
        }

        return Gathered(
            accountID: accountID,
            bodyCandidates: bodyCandidates,
            attachments: attachments
        )
    }

    /// Loads an attachment's ingestion-extracted text, capped for the input.
    /// `nil` when extraction never produced text for this attachment. Shared
    /// with `ProjectGuideInputBuilder`.
    nonisolated static func documentText(extractedTextPath: String?) -> String? {
        guard let extractedTextPath, extractedTextPath.isEmpty == false else { return nil }
        guard let text = try? String(contentsOfFile: extractedTextPath, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return String(trimmed.prefix(perDocumentCharacterLimit))
    }

    private static func deadlineLabel(_ entry: DeadlineEntry) -> String {
        let type = entry.deadlineType.trimmingCharacters(in: .whitespacesAndNewlines)
        return type.isEmpty ? "deadline" : type
    }

    // MARK: - Off-main body loading (shared with ProjectGuideInputBuilder)

    nonisolated static func bodyText(htmlPath: String?, textPath: String?, rawPath: String?) -> String? {
        guard case .loaded(let source) = LockReadoutBodyLoader.load(htmlPath: htmlPath, textPath: textPath, rawPath: rawPath) else {
            return nil
        }
        switch source.format {
        case .plainText:
            return OriginalMessageText.cleaned(from: source.text)
        case .html:
            return OriginalMessageText.cleaned(from: strippedHTML(source.text))
        }
    }

    /// Off-main-safe HTML → text (no WebKit): drop script/style, strip tags,
    /// decode the common entities. Mirrors `DeadlineFocusedView`'s reader path so
    /// the summary reads the same body the user would.
    nonisolated private static func strippedHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: "(?s)<(script|style)\\b[^>]*>.*?</\\1>", with: " ", options: .regularExpression
        )
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</p\\s*>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
    }
}
