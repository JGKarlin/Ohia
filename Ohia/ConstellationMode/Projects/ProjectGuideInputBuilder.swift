import Foundation
import SwiftData
import OhiaCore
import OhiaML

/// Builds the project-framed `DeadlineSummaryInput` the workroom's guide
/// distills — the Projects sibling of `DeadlineSummaryInputBuilder`. Where the
/// deadline builder reads one thread, this gathers across the whole project:
/// the most recent message bodies regardless of thread, every real attachment
/// on the project's messages (with their ingestion-extracted text), and the
/// owner's working files for the project. The input carries
/// `framing: .project`, so the shared pipeline prompts in the project
/// register and caches under project-scoped keys.
enum ProjectGuideInputBuilder {
    /// The most recent messages whose bodies feed the distillation, the
    /// attachment cap shared with the deadline builder, and how many of the
    /// newest messages are scanned for attachments before giving up.
    private static let maxBodies = 4
    private static let maxAttachments = 6
    private static let perBodyCharacterLimit = 6_000
    private static let maxMessagesScanned = 30

    @MainActor
    static func build(
        row: ProjectRow,
        marks: [ProjectMessageMark],
        modelContext: ModelContext,
        userIdentity: SummarizationUserIdentity?,
        workFileStore: DeadlineWorkFileStore,
        guideKey: String,
        userAddresses: Set<String>
    ) async -> DeadlineSummaryInput? {
        // Newest-first, matching the workroom feed the guide sits above.
        let orderedMarks = marks.sorted { $0.date > $1.date }
        guard orderedMarks.isEmpty == false else { return nil }

        // Single-id equality is the only Message-predicate shape this
        // codebase trusts to translate across SwiftData revisions (an array
        // `contains` can silently fail translation and would blank the whole
        // guide); at most `maxMessagesScanned` unique-keyed fetches, each
        // O(1) on the id index.
        let scannedMarks = Array(orderedMarks.prefix(maxMessagesScanned))
        var messagesByID: [UUID: Message] = [:]
        for mark in scannedMarks where messagesByID[mark.messageID] == nil {
            let targetID = mark.messageID
            var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == targetID })
            descriptor.fetchLimit = 1
            if let message = try? modelContext.fetch(descriptor).first {
                messagesByID[targetID] = message
            }
        }
        guard messagesByID.isEmpty == false else { return nil }

        // Bodies: the newest messages across the project, any direction, so
        // the model sees where the project currently stands.
        var bodies: [DeadlineSummaryMessageBody] = []
        for mark in scannedMarks {
            guard bodies.count < maxBodies else { break }
            guard let message = messagesByID[mark.messageID] else { continue }
            let htmlPath = message.bodyHtmlPath
            let textPath = message.bodyTextPath
            let rawPath = message.rawPath
            let text = await Task.detached(priority: .userInitiated) {
                DeadlineSummaryInputBuilder.bodyText(htmlPath: htmlPath, textPath: textPath, rawPath: rawPath)
            }.value
            guard let text, text.isEmpty == false else { continue }
            bodies.append(
                DeadlineSummaryMessageBody(
                    role: message.isSentByUser ? "outgoing" : "incoming",
                    senderName: message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords) ?? message.fromAddress,
                    receivedAt: mark.date,
                    text: String(text.prefix(perBodyCharacterLimit))
                )
            )
        }

        // Attachments across the project's newest messages — a form can live
        // in any thread. Inline images are excluded; filenames dedupe.
        var attachments: [DeadlineSummaryAttachment] = []
        var seenFilenames = Set<String>()
        for mark in scannedMarks {
            guard attachments.count < maxAttachments else { break }
            guard let message = messagesByID[mark.messageID] else { continue }
            for attachment in message.attachments where attachment.isInline != true {
                let filename = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines)
                guard filename.isEmpty == false else { continue }
                guard seenFilenames.insert(filename.lowercased()).inserted else { continue }
                let extractedTextPath = attachment.extractedTextPath
                let extracted = await Task.detached(priority: .userInitiated) {
                    DeadlineSummaryInputBuilder.documentText(extractedTextPath: extractedTextPath)
                }.value
                attachments.append(
                    DeadlineSummaryAttachment(
                        filename: filename,
                        mimeType: attachment.mimeType,
                        filePath: attachment.filePath,
                        documentKind: attachment.detectedDocumentKind,
                        extractedText: extracted
                    )
                )
                if attachments.count >= maxAttachments { break }
            }
        }

        // The owner's working files for this project, parsed once
        // (sidecar-cached) by the store.
        var workingFiles: [DeadlineSummaryAttachment] = []
        for file in workFileStore.files(entryID: guideKey) {
            let extracted = await workFileStore.extractedText(for: file)
            workingFiles.append(
                DeadlineSummaryAttachment(
                    filename: file.filename,
                    mimeType: "application/octet-stream",
                    filePath: file.url.path,
                    documentKind: nil,
                    extractedText: extracted.map { String($0.prefix(perBodyCharacterLimit)) }
                )
            )
        }

        let correspondents = row.participants
            .filter { !userAddresses.contains($0.email) }
            .map { DeadlineSummaryParticipant(name: $0.displayName ?? "", email: $0.email) }

        // The guard above proves orderedMarks is non-empty; the row fields
        // remain as defensive fallbacks only.
        let firstActivityAt = orderedMarks.last?.date ?? row.firstActivityAt
        let lastActivityAt = orderedMarks.first?.date ?? row.lastActivityAt
        let accountID = SummarizationAccountResolver.singleAccountID(
            in: row.messageIDs.map { messagesByID[$0]?.accountID ?? messagesByID[$0]?.account?.id }
        )

        return DeadlineSummaryInput(
            accountID: accountID,
            title: row.displayLabel,
            deadlineLabel: "project",
            deadlineDate: lastActivityAt,
            deadlineDateText: ProjectsWorkroomView.activitySpanText(first: firstActivityAt, last: lastActivityAt),
            surfaceText: "",
            correspondents: correspondents,
            bodies: bodies,
            attachments: attachments,
            workingFiles: workingFiles,
            userIdentity: userIdentity,
            framing: .project
        )
    }
}
