import AppKit
import CryptoKit
import Foundation
import QuickLook
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import OhiaCore
import OhiaIngest
import OhiaML

enum ProjectFileOrigin: Equatable, Sendable {
    case message(attachmentID: UUID, messageID: UUID)
    case manual(workFileID: String)
}

struct ProjectFileSummarySeed: Equatable, Sendable {
    let attachmentID: UUID
    let extractedTextPath: String?
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let documentKind: String?
    let structureUnitKind: String?
    let structureUnitCount: Int?
    let characterCount: Int?
    let documentTitle: String?
    let documentAuthor: String?
    let anchorSubject: String
    let anchorSenderName: String
    let anchorReceivedAt: Date?
    let anchorPurpose: MailPurpose?
}

struct ProjectFileRecord: Identifiable, Equatable, Sendable {
    let id: String
    let origin: ProjectFileOrigin
    let filename: String
    let mimeType: String
    let kind: TimelineAttachmentKind
    let sizeBytes: Int
    let fileURL: URL?
    let eventDate: Date
    let eventLabel: String
    let senderLabel: String
    let senderKey: String
    let sourceSubject: String?
    let metadataLines: [String]
    let storedSummary: String?
    let summaryInput: ProjectFileSummarySeed?
    /// iCloud Mail Drop link while it is still served; such rows have no
    /// `fileURL` (the bytes stay on iCloud).
    var remoteURL: URL? = nil
}

enum ProjectFileDateRange: String, CaseIterable, Hashable, Sendable {
    case all
    case last7Days
    case last30Days
    case last90Days
    case lastYear

    var label: String {
        switch self {
        case .all: "Any Date"
        case .last7Days: "Last 7 Days"
        case .last30Days: "Last 30 Days"
        case .last90Days: "Last 90 Days"
        case .lastYear: "Last Year"
        }
    }

    fileprivate var dayCount: Int? {
        switch self {
        case .all: nil
        case .last7Days: 7
        case .last30Days: 30
        case .last90Days: 90
        case .lastYear: 365
        }
    }
}

struct ProjectFileFilter: Equatable, Sendable {
    var dateRange: ProjectFileDateRange = .all
    var senderKey: String?
    var type: TimelineAttachmentKind?
}

struct ProjectFileImportResult: Equatable, Sendable {
    let requestedCount: Int
    let addedCount: Int

    init(requestedCount: Int, addedCount: Int) {
        self.requestedCount = max(0, requestedCount)
        self.addedCount = min(max(0, addedCount), self.requestedCount)
    }

    var failedCount: Int { requestedCount - addedCount }
    var isComplete: Bool { failedCount == 0 }

    func issueMessage(destinationNoun: String) -> String? {
        guard isComplete == false else { return nil }
        if addedCount == 0 {
            return "No files could be copied into this \(destinationNoun)."
        }
        return "Added \(addedCount) of \(requestedCount) files. The remaining files could not be copied."
    }
}

struct ProjectFileSummaryDisclosureState: Equatable {
    private(set) var expandedRecordIDs: Set<String> = []

    func isExpanded(_ recordID: String) -> Bool {
        expandedRecordIDs.contains(recordID)
    }

    mutating func toggle(_ recordID: String) {
        if expandedRecordIDs.remove(recordID) == nil {
            expandedRecordIDs.insert(recordID)
        }
    }
}

enum ProjectFileRefreshPolicy {
    static func requiresReload(after jobType: JobType) -> Bool {
        switch jobType {
        // Capture-metadata jobs are omitted on purpose: they complete about
        // once a second during a backlog, and each reload restarts the
        // workroom's file-summary generation. Capture lines appear on the
        // next catalog load.
        case .extractAttachments, .extractVisualAttachments, .summarizeAttachments:
            true
        default:
            false
        }
    }
}

enum ProjectFileCatalog {
    static func senderKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func filtered(
        _ records: [ProjectFileRecord],
        by filter: ProjectFileFilter,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [ProjectFileRecord] {
        let cutoff = filter.dateRange.dayCount.flatMap {
            calendar.date(byAdding: .day, value: -$0, to: now)
        }
        return records
            .filter { record in
                if let cutoff, record.eventDate < cutoff { return false }
                if let senderKey = filter.senderKey, record.senderKey != senderKey { return false }
                if let type = filter.type, record.kind != type { return false }
                return true
            }
            .sorted {
                if $0.eventDate != $1.eventDate { return $0.eventDate > $1.eventDate }
                return $0.id < $1.id
            }
    }

    @MainActor
    static func records(
        row: ProjectRow,
        modelContext: ModelContext,
        workFiles: [DeadlineWorkFile]
    ) -> [ProjectFileRecord] {
        var records: [ProjectFileRecord] = []
        records.reserveCapacity(workFiles.count + row.messageIDs.count)

        let projectMessageIDs = row.messageIDs
        let projectMessageIDSet = Set(projectMessageIDs)
        let scopedMessages: [Message]
        do {
            let descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { projectMessageIDs.contains($0.id) }
            )
            scopedMessages = try modelContext.fetch(descriptor)
        } catch {
            // A single full-store fallback keeps the catalog available if the
            // persistent backend cannot translate collection membership.
            scopedMessages = ((try? modelContext.fetch(FetchDescriptor<Message>())) ?? [])
                .filter { projectMessageIDSet.contains($0.id) }
        }
        let messageByID = Dictionary(
            scopedMessages.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for messageID in projectMessageIDs {
            guard let message = messageByID[messageID] else { continue }
            let date = message.isSentByUser
                ? (message.sentAt ?? message.receivedAt ?? message.ingestedAt)
                : (message.receivedAt ?? message.sentAt ?? message.ingestedAt)
            let sender = senderLabel(for: message)
            for attachment in message.attachments where attachment.isInline != true {
                let filename = MIMEHeaderDecoder.decodeEncodedWords(attachment.filename)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard filename.isEmpty == false else { continue }
                let kind = TimelineAttachmentKind.classify(
                    mimeType: attachment.mimeType,
                    fileName: filename
                )
                records.append(ProjectFileRecord(
                    id: "attachment-\(attachment.id.uuidString.lowercased())",
                    origin: .message(attachmentID: attachment.id, messageID: message.id),
                    filename: filename,
                    mimeType: attachment.mimeType,
                    kind: kind,
                    sizeBytes: attachment.sizeBytes,
                    fileURL: attachment.filePath.map { URL(fileURLWithPath: $0) },
                    eventDate: date,
                    eventLabel: message.isSentByUser ? "Sent" : "Received",
                    senderLabel: sender,
                    senderKey: senderKey(sender),
                    sourceSubject: message.subject,
                    metadataLines: metadataLines(for: attachment, kind: kind),
                    storedSummary: nonEmpty(attachment.attachmentSummary)
                        ?? nonEmpty(attachment.visualSummary),
                    summaryInput: attachment.remoteURL != nil ? nil : ProjectFileSummarySeed(
                        attachmentID: attachment.id,
                        extractedTextPath: attachment.extractedTextPath,
                        filename: filename,
                        mimeType: attachment.mimeType,
                        sizeBytes: attachment.sizeBytes,
                        documentKind: attachment.detectedDocumentKind,
                        structureUnitKind: attachment.extractionStructureUnitKind,
                        structureUnitCount: attachment.extractionStructureUnitCount,
                        characterCount: attachment.extractionCharacterCount,
                        documentTitle: attachment.documentTitle,
                        documentAuthor: attachment.documentAuthor,
                        anchorSubject: message.subject,
                        anchorSenderName: sender,
                        anchorReceivedAt: date,
                        anchorPurpose: MailClassificationJSON.decode(
                            message.analysis?.mailClassificationJSON
                        )?.purpose
                    ),
                    remoteURL: liveMailDropURL(for: attachment)
                ))
            }
        }

        for file in workFiles {
            let mimeType = mimeType(for: file.url)
            let kind = TimelineAttachmentKind.classify(mimeType: mimeType, fileName: file.filename)
            let addedByYou = "Added by you"
            records.append(ProjectFileRecord(
                id: "manual-\(file.id)",
                origin: .manual(workFileID: file.id),
                filename: file.filename,
                mimeType: mimeType,
                kind: kind,
                sizeBytes: file.sizeBytes,
                fileURL: file.url,
                eventDate: file.addedAt,
                eventLabel: "Added",
                senderLabel: addedByYou,
                senderKey: senderKey(addedByYou),
                sourceSubject: nil,
                metadataLines: [kind.label, mimeType, "Stored in this project by Ohia"],
                storedSummary: nil,
                summaryInput: ProjectFileSummarySeed(
                    attachmentID: stableUUID(for: file.id),
                    extractedTextPath: nil,
                    filename: file.filename,
                    mimeType: mimeType,
                    sizeBytes: file.sizeBytes,
                    documentKind: nil,
                    structureUnitKind: nil,
                    structureUnitCount: nil,
                    characterCount: nil,
                    documentTitle: nil,
                    documentAuthor: nil,
                    anchorSubject: row.displayLabel,
                    anchorSenderName: addedByYou,
                    anchorReceivedAt: file.addedAt,
                    anchorPurpose: nil
                )
            ))
        }
        return records
    }

    static func stableUUID(for value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        let uuid: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }

    @MainActor
    private static func senderLabel(for message: Message) -> String {
        if message.isSentByUser { return "You" }
        return nonEmpty(message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords))
            ?? nonEmpty(message.fromAddress)
            ?? "Unknown Sender"
    }

    @MainActor
    private static func metadataLines(
        for attachment: Attachment,
        kind: TimelineAttachmentKind
    ) -> [String] {
        var lines = [kind.label, attachment.mimeType]
        if let title = nonEmpty(attachment.documentTitle) { lines.append("Title: \(title)") }
        if let author = nonEmpty(attachment.documentAuthor) { lines.append("Author: \(author)") }
        if let unit = nonEmpty(attachment.extractionStructureUnitKind),
           let count = attachment.extractionStructureUnitCount, count > 0 {
            lines.append("\(count) \(unit)\(count == 1 ? "" : "s")")
        }
        if let width = attachment.visualOriginalImageWidth ?? attachment.visualImageWidth,
           let height = attachment.visualOriginalImageHeight ?? attachment.visualImageHeight {
            lines.append("\(width) × \(height) px")
        }
        if let capture = AttachmentCaptureMetadata
            .decode(attachment.captureMetadataJSON)?
            .readerLine(locale: .autoupdatingCurrent) {
            lines.append(capture)
        }
        if attachment.remoteURL != nil {
            if let expiry = attachment.remoteExpiresAt {
                let day = expiry.formatted(.dateTime.month(.abbreviated).day())
                lines.append(expiry <= Date() ? "Mail Drop · expired \(day)" : "Mail Drop · expires \(day)")
            } else {
                lines.append("Mail Drop")
            }
        }
        return lines
    }

    private static func liveMailDropURL(for attachment: Attachment) -> URL? {
        guard let remote = attachment.remoteURL,
              let url = URL(string: remote),
              MailDropReference.isTrustedDownloadURL(url) else { return nil }
        if let expiry = attachment.remoteExpiresAt, expiry <= Date() { return nil }
        return url
    }

    private static func mimeType(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        return values?.contentType?.preferredMIMEType
            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else { return nil }
        return value
    }
}

struct ProjectFileGeneratedSummary: Equatable, Sendable {
    let paragraph: String
    let fingerprint: String
}

enum ProjectFileSummaryLoader {
    static func summary(
        for record: ProjectFileRecord,
        workFiles: [DeadlineWorkFile],
        workFileStore: DeadlineWorkFileStore,
        service: AttachmentSummaryService
    ) async -> ProjectFileGeneratedSummary? {
        guard let seed = record.summaryInput else { return nil }
        let extractedText: String?
        switch record.origin {
        case .message:
            let path = seed.extractedTextPath
            extractedText = await Task.detached(priority: .utility) {
                guard let path else { return nil }
                return try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            }.value
        case .manual(let workFileID):
            guard let file = workFiles.first(where: { $0.id == workFileID }) else { return nil }
            extractedText = await workFileStore.extractedText(for: file)
        }
        guard Task.isCancelled == false,
              let extractedText,
              extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        let input = AttachmentSummaryInput(
            attachmentID: seed.attachmentID,
            filename: seed.filename,
            mimeType: seed.mimeType,
            sizeBytes: seed.sizeBytes,
            extractedText: extractedText,
            documentKind: seed.documentKind,
            structureUnitKind: seed.structureUnitKind,
            structureUnitCount: seed.structureUnitCount,
            characterCount: seed.characterCount,
            documentTitle: seed.documentTitle,
            documentAuthor: seed.documentAuthor,
            anchorSubject: seed.anchorSubject,
            anchorSenderName: seed.anchorSenderName,
            anchorReceivedAt: seed.anchorReceivedAt,
            anchorPurpose: seed.anchorPurpose
        )
        guard let result = await service.summary(for: seed.attachmentID, input: input),
              Task.isCancelled == false else { return nil }
        return ProjectFileGeneratedSummary(
            paragraph: result.paragraph,
            fingerprint: AttachmentSummaryService.fingerprint(
                input: input,
                targetLanguage: .ohiaPreferred()
            )
        )
    }
}

enum ProjectManualFileAskContextBuilder {
    @MainActor
    static func context(
        projectKey: String,
        projectName: String,
        maximumFiles: Int = 6,
        bodyCharacterLimit: Int = 1_800
    ) async -> AskThreadContext? {
        await context(
            projectKey: projectKey,
            projectName: projectName,
            workFileStore: DeadlineWorkFileStore(),
            maximumFiles: maximumFiles,
            bodyCharacterLimit: bodyCharacterLimit
        )
    }

    @MainActor
    static func context(
        projectKey: String,
        projectName: String,
        workFileStore: DeadlineWorkFileStore,
        maximumFiles: Int = 6,
        bodyCharacterLimit: Int = 1_800
    ) async -> AskThreadContext? {
        let files = Array(
            workFileStore.files(entryID: "project-\(projectKey)")
                .sorted { $0.addedAt > $1.addedAt }
                .prefix(max(1, maximumFiles))
        )
        guard files.isEmpty == false else { return nil }

        var messages: [AskThreadMessage] = []
        messages.reserveCapacity(files.count)
        for file in files {
            guard Task.isCancelled == false else { return nil }
            guard let extracted = await workFileStore.extractedText(for: file),
                  extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                continue
            }
            messages.append(AskThreadMessage(
                messageId: ProjectFileCatalog.stableUUID(for: file.id).uuidString,
                from: "Added by you",
                date: file.addedAt,
                subject: file.filename,
                bodyExcerpt: String(extracted.prefix(max(120, bodyCharacterLimit)))
            ))
        }
        guard messages.isEmpty == false else { return nil }
        return AskThreadContext(
            threadId: "project-files-\(projectKey)",
            subject: "Project files: \(projectName)",
            anchorMessageIds: [],
            messages: messages
        )
    }
}

struct ProjectFilesPane: View {
    enum Scope {
        case project
        case deadline

        var fileDialogMessage: String {
            switch self {
            case .project: "Choose files to copy into this project"
            case .deadline: "Choose files to copy into this deadline"
            }
        }

        var emptyTitle: String {
            switch self {
            case .project: "No project files yet"
            case .deadline: "No deadline files yet"
            }
        }

        var emptyDetail: String {
            switch self {
            case .project:
                "Attachments from project messages appear here. You can also add working files from your Mac."
            case .deadline:
                "Attachments from this deadline's correspondence appear here. You can also add working files from your Mac."
            }
        }

        var removalTitle: String {
            switch self {
            case .project: "Remove from Project"
            case .deadline: "Remove from Deadline"
            }
        }

        var removalFailure: String {
            switch self {
            case .project: "The file could not be removed from this project."
            case .deadline: "The file could not be removed from this deadline."
            }
        }

        var importDestinationNoun: String {
            switch self {
            case .project: "project"
            case .deadline: "deadline"
            }
        }
    }

    let scope: Scope
    let records: [ProjectFileRecord]
    let generatedSummaries: [String: String]
    let loadingSummaryIDs: Set<String>
    let onAddFiles: ([URL]) -> ProjectFileImportResult
    let onRemoveManualFile: (String) -> Bool

    @Environment(\.readingTextSize) private var readingTextSize
    @State private var filter = ProjectFileFilter()
    @State private var isDateFilterPresented = false
    @State private var isSenderFilterPresented = false
    @State private var isTypeFilterPresented = false
    @State private var summaryDisclosure = ProjectFileSummaryDisclosureState()
    @State private var importerPresented = false
    @State private var previewURL: URL?
    @State private var dropTargeted = false
    @State private var operationIssueMessage = ""
    @State private var operationIssuePresented = false

    fileprivate static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    fileprivate static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var visibleRecords: [ProjectFileRecord] {
        ProjectFileCatalog.filtered(records, by: filter)
    }

    private var senders: [(key: String, label: String)] {
        var labelsByKey: [String: String] = [:]
        for record in records where labelsByKey[record.senderKey] == nil {
            labelsByKey[record.senderKey] = record.senderLabel
        }
        return labelsByKey.map { (key: $0.key, label: $0.value) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private var types: [TimelineAttachmentKind] {
        let present = Set(records.map(\.kind))
        return TimelineAttachmentKind.allCases.filter(present.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(OhiaColors.glassBorder)
            if records.isEmpty {
                emptyState
            } else if visibleRecords.isEmpty {
                noMatchesState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleRecords) { record in
                            ProjectFileRow(
                                record: record,
                                summary: generatedSummaries[record.id] ?? record.storedSummary,
                                summaryIsLoading: loadingSummaryIDs.contains(record.id),
                                isSummaryExpanded: summaryDisclosure.isExpanded(record.id),
                                onToggleSummary: { summaryDisclosure.toggle(record.id) },
                                onPreview: { previewURL = record.fileURL },
                                removalTitle: scope.removalTitle,
                                onRemove: removalAction(for: record)
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OhiaColors.glassPanelBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(OhiaColors.glassBorder).frame(width: 1)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard files.isEmpty == false else { return false }
            let result = onAddFiles(files)
            presentIssueIfNeeded(for: result)
            return result.addedCount > 0
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            let urls: [URL]
            do {
                urls = try result.get()
            } catch {
                let cocoaError = error as NSError
                if error is CancellationError
                    || (cocoaError.domain == NSCocoaErrorDomain
                        && cocoaError.code == NSUserCancelledError) {
                    return
                }
                presentOperationIssue(error.localizedDescription)
                return
            }
            let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
            presentIssueIfNeeded(for: onAddFiles(urls))
        }
        .fileDialogMessage(scope.fileDialogMessage)
        .fileDialogConfirmationLabel("Add Files")
        .quickLookPreview($previewURL)
        .alert("File Operation Failed", isPresented: $operationIssuePresented) {
            Button("OK", systemImage: "checkmark", role: .cancel) {}
        } message: {
            Text(operationIssueMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(OhiaColors.iconPillForeground)
                        .frame(width: 22, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(OhiaColors.iconPillBackground)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 0.5)
                        }
                        .accessibilityHidden(true)
                    Text("Files")
                        .font(readingTextSize.font(base: 13, weight: .semibold, maximumScale: 1.25))
                        .foregroundStyle(OhiaColors.textSecondary)
                }
                Text("\(records.count) item\(records.count == 1 ? "" : "s")")
                    .font(readingTextSize.font(base: 11, maximumScale: 1.25))
                    .foregroundStyle(OhiaColors.textTertiary)
            }
            ViewThatFits(in: .horizontal) {
                filterControls
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        dateMenu
                        senderMenu
                    }
                    HStack(spacing: 7) {
                        typeMenu
                        clearFilterButton
                        Spacer(minLength: 7)
                        addFilesButton
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 7) {
                    dateMenu
                    senderMenu
                    typeMenu
                    clearFilterButton
                    HStack {
                        Spacer(minLength: 7)
                        addFilesButton
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var filterControls: some View {
        HStack(spacing: 7) {
            dateMenu
            senderMenu
            typeMenu
            clearFilterButton
            Spacer(minLength: 7)
            addFilesButton
        }
        .frame(maxWidth: .infinity)
    }

    private var addFilesButton: some View {
        Button {
            importerPresented = true
        } label: {
            Label("Add Files", systemImage: "folder.badge.plus")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 3))
        .fixedSize()
    }

    @ViewBuilder
    private var clearFilterButton: some View {
        if filter != ProjectFileFilter() {
            Button {
                filter = ProjectFileFilter()
            } label: {
                Label("Clear", systemImage: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 3))
        }
    }

    private var dateMenu: some View {
        Button {
            isDateFilterPresented.toggle()
        } label: {
            filterMenuLabel(
                filter.dateRange == .all ? "Date" : filter.dateRange.label,
                systemImage: "calendar"
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Filter files by date")
        .popover(isPresented: $isDateFilterPresented, arrowEdge: .bottom) {
            MenuPopoverContent(headerLabel: "Filter files by date") {
                ForEach(ProjectFileDateRange.allCases, id: \.self) { range in
                    MenuRow(
                        name: range.label,
                        symbolName: "calendar",
                        isChecked: filter.dateRange == range
                    ) {
                        filter.dateRange = range
                        isDateFilterPresented = false
                    }
                }
            }
        }
    }

    private var senderMenu: some View {
        Button {
            isSenderFilterPresented.toggle()
        } label: {
            filterMenuLabel(senderLabel, systemImage: "person")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Filter files by sender")
        .popover(isPresented: $isSenderFilterPresented, arrowEdge: .bottom) {
            MenuPopoverContent(headerLabel: "Filter files by sender") {
                MenuRow(
                    name: "Any Sender",
                    symbolName: "person",
                    isChecked: filter.senderKey == nil
                ) {
                    filter.senderKey = nil
                    isSenderFilterPresented = false
                }

                ForEach(senders, id: \.key) { sender in
                    MenuRow(
                        name: sender.label,
                        symbolName: "person",
                        isChecked: filter.senderKey == sender.key
                    ) {
                        filter.senderKey = sender.key
                        isSenderFilterPresented = false
                    }
                }
            }
        }
    }

    private var typeMenu: some View {
        Button {
            isTypeFilterPresented.toggle()
        } label: {
            filterMenuLabel(filter.type?.label ?? "Type", systemImage: "doc")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Filter files by type")
        .popover(isPresented: $isTypeFilterPresented, arrowEdge: .bottom) {
            MenuPopoverContent(headerLabel: "Filter files by type") {
                MenuRow(
                    name: "Any Type",
                    symbolName: "doc",
                    isChecked: filter.type == nil
                ) {
                    filter.type = nil
                    isTypeFilterPresented = false
                }

                ForEach(types, id: \.self) { type in
                    MenuRow(
                        name: type.label,
                        symbolName: type.symbolName,
                        isChecked: filter.type == type
                    ) {
                        filter.type = type
                        isTypeFilterPresented = false
                    }
                }
            }
        }
    }

    private func filterMenuLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .opacity(0.55)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(OhiaColors.chipActiveForeground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(minHeight: 22)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(OhiaColors.chipActiveBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    private var senderLabel: String {
        guard let selected = filter.senderKey,
              let sender = senders.first(where: { $0.key == selected }) else { return "Sender" }
        return sender.label
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(OhiaColors.ohiaYellow)
            Text(scope.emptyTitle)
                .font(readingTextSize.font(base: 14, weight: .semibold, maximumScale: 1.25))
                .foregroundStyle(OhiaColors.textPrimary)
            Text(scope.emptyDetail)
                .font(readingTextSize.font(base: 11.5, maximumScale: 1.25))
                .foregroundStyle(OhiaColors.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(OhiaColors.ohiaYellow)
            Text("No files match these filters")
                .font(readingTextSize.font(base: 13, weight: .semibold, maximumScale: 1.25))
                .foregroundStyle(OhiaColors.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func removalAction(for record: ProjectFileRecord) -> (() -> Void)? {
        guard case .manual(let workFileID) = record.origin else { return nil }
        return {
            guard onRemoveManualFile(workFileID) == false else { return }
            presentOperationIssue(scope.removalFailure)
        }
    }

    private func presentIssueIfNeeded(for result: ProjectFileImportResult) {
        guard let issueMessage = result.issueMessage(
            destinationNoun: scope.importDestinationNoun
        ) else { return }
        presentOperationIssue(issueMessage)
    }

    private func presentOperationIssue(_ message: String) {
        operationIssueMessage = message
        operationIssuePresented = true
    }
}

private struct ProjectFileRow: View {
    let record: ProjectFileRecord
    let summary: String?
    let summaryIsLoading: Bool
    let isSummaryExpanded: Bool
    let onToggleSummary: () -> Void
    let onPreview: () -> Void
    let removalTitle: String
    let onRemove: (() -> Void)?

    @Environment(\.readingTextSize) private var readingTextSize
    @State private var cachedImage: NSImage?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Text(record.filename)
                        .font(readingTextSize.font(base: 13, weight: .semibold, maximumScale: 1.3))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: isSummaryExpanded ? "chevron.down" : "chevron.right")
                        .font(readingTextSize.font(base: 10, weight: .semibold, maximumScale: 1.2))
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                        .frame(width: 18, height: 24)
                        .accessibilityHidden(true)
                }
                Text(provenanceLine)
                    .font(readingTextSize.font(base: 11, maximumScale: 1.3))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subject = record.sourceSubject, subject.isEmpty == false {
                    Text("Message: \(subject)")
                        .font(readingTextSize.font(base: 11, maximumScale: 1.3))
                        .foregroundStyle(OhiaColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                metadataAndPreview
                if isSummaryExpanded {
                    summaryBlock
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(OhiaColors.glassPanelBackground)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(OhiaColors.glassBorder, lineWidth: 1))
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused = true
            onToggleSummary()
        }
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovering in
            isFocused = isHovering
        }
        .onKeyPress(.space) {
            onToggleSummary()
            return .handled
        }
        .contextMenu {
            if let url = record.fileURL {
                Button("Open", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } else if let remote = record.remoteURL {
                Button("Open Mail Drop Link", systemImage: "icloud.and.arrow.down") {
                    NSWorkspace.shared.open(remote)
                }
                Button("Copy Mail Drop Link", systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(remote.absoluteString, forType: .string)
                }
            }
            if let onRemove {
                Divider()
                Button(removalTitle, systemImage: "trash", role: .destructive, action: onRemove)
            }
        }
        .task(id: imageLoadKey) {
            guard let path = imageLoadKey,
                  FileManager.default.fileExists(atPath: path) else {
                cachedImage = nil
                return
            }
            cachedImage = NSImage(contentsOfFile: path)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSummaryExpanded ? "Summary expanded" : "Summary collapsed")
        .accessibilityHint(isSummaryExpanded ? "Press Space to collapse summary" : "Press Space to expand summary")
        .accessibilityAddTraits(.isButton)
        .animation(.easeInOut(duration: 0.16), value: isSummaryExpanded)
    }

    @ViewBuilder
    private var metadataAndPreview: some View {
        if record.fileURL != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    metadataText
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    previewButton
                }
                VStack(alignment: .leading, spacing: 7) {
                    metadataText
                        .fixedSize(horizontal: false, vertical: true)
                    previewButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            metadataText
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var metadataText: some View {
        Text(metadataLine)
            .font(readingTextSize.font(base: 10.5, maximumScale: 1.3))
            .foregroundStyle(record.kind.tint)
    }

    private var previewButton: some View {
        ClusterButtonChip(
            glyph: .native("eye.circle.fill"),
            tint: OhiaColors.chipActiveForeground,
            help: "Preview",
            action: onPreview
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if record.kind == .image, let cachedImage {
            Image(nsImage: cachedImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 64)
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(OhiaColors.glassBorder, lineWidth: 1))
                .accessibilityHidden(true)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(OhiaColors.iconPillBackground)
                RoundedRectangle(cornerRadius: 7).strokeBorder(OhiaColors.iconPillBorder, lineWidth: 1)
                Image(systemName: record.kind.symbolName)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(record.kind.tint)
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "text.magnifyingglass")
                Text("SUMMARY")
            }
            .font(.system(
                size: readingTextSize.pointSize(base: 9, minimum: 8, maximumScale: 1.25),
                weight: .semibold
            ))
            .tracking(0.7)
            .foregroundStyle(OhiaColors.textTertiary)
            if let summary, summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                Text(summary)
                    .font(readingTextSize.font(base: 11.5, maximumScale: 1.3))
                    .lineSpacing(readingTextSize.spacing(2))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if summaryIsLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Preparing a grounded summary")
                }
                .font(readingTextSize.font(base: 11, maximumScale: 1.3).italic())
                .foregroundStyle(OhiaColors.textTertiary)
            } else {
                Text("No extractable content was available for a grounded summary.")
                    .font(readingTextSize.font(base: 11, maximumScale: 1.3).italic())
                    .foregroundStyle(OhiaColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
        }
    }

    private var imageLoadKey: String? {
        guard record.kind == .image else { return nil }
        return record.fileURL?.path
    }

    private var provenanceLine: String {
        "\(record.eventLabel) \(ProjectFilesPane.dateFormatter.string(from: record.eventDate)) · \(record.senderLabel)"
    }

    private var metadataLine: String {
        // A Mail Drop row's size is unknown (declared 0) until iCloud reports it.
        let size = record.fileURL == nil && record.sizeBytes <= 0
            ? []
            : [ProjectFilesPane.byteFormatter.string(fromByteCount: Int64(max(0, record.sizeBytes)))]
        return (size + record.metadataLines).joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        let visibleSummary = isSummaryExpanded ? summary : nil
        return [record.filename, provenanceLine, metadataLine, visibleSummary]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}
