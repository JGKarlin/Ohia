import AppKit
import SwiftUI
import OhiaML

/// Attachments surfaced inside the CONTEXT pane, grouped by filetype family
/// (PDFs, images, archives, …) with each row acting as a Quick Look / Finder
/// link to the on-disk binary. Pure presentation — `LockedNodeContextLoader`
/// owns extracting the file paths.
struct LockedAttachmentsList: View {
    enum Presentation: Equatable {
        case telemetry
        case contextSummary
        case reader
    }

    let attachments: [LockedAttachmentSummary]
    /// Section caption above the kind groups. Defaults to the spatial
    /// inspector / Timeline idiom ("FILES"); the Front Page reader passes
    /// "Attachments" so the catalog reads as part of the newspaper article.
    var title: String = "FILES"
    var presentation: Presentation = .telemetry

    @Environment(\.readingTextSize) private var readingTextSize

    /// Static byte formatter: file sizes change every render; the formatter
    /// itself is constant.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .reader ? 8 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(OhiaTypography.telemetrySectionCaps)
                    .tracking(1.0)
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                Text("\(attachments.count)")
                    .font(OhiaTypography.attachmentRowMeta)
                    .foregroundStyle(OhiaColors.textTertiary)
            }

            ForEach(groups, id: \.id) { group in
                groupView(group)
            }
        }
    }

    @ViewBuilder
    private func groupView(_ group: AttachmentGroup) -> some View {
        VStack(alignment: .leading, spacing: presentation == .reader ? 6 : 4) {
            HStack(spacing: 6) {
                Image(systemName: group.symbolName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(group.tint)
                Text(group.heading)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(group.tint)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
            .help(group.tooltip)

            ForEach(group.items) { item in
                attachmentRow(item, tint: group.tint)
            }
        }
    }

    @ViewBuilder
    private func attachmentRow(_ attachment: LockedAttachmentSummary, tint: Color) -> some View {
        let canOpen = attachment.filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            || attachment.liveRemoteURL() != nil
        let extractionState = LockedAttachmentExtractionStatus.classify(attachment)
        let facts = factsString(for: attachment)
        let description = descriptionString(for: attachment)
        let datafiedDetail = datafiedDetail(for: attachment)
        if presentation == .contextSummary {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    attachmentTitle(
                        attachment,
                        canOpen: canOpen,
                        badge: extractionState.badge,
                        tint: tint
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    sizeLabel(for: attachment)
                }

                if facts != nil || description != nil || datafiedDetail != nil {
                    readerDetailRows(
                        facts: facts,
                        description: description,
                        datafiedDetail: datafiedDetail,
                        tint: tint
                    )
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        attachmentTitle(
                            attachment,
                            canOpen: canOpen,
                            badge: extractionState.badge,
                            tint: tint
                        )

                        if facts != nil || description != nil || datafiedDetail != nil {
                            switch presentation {
                            case .telemetry:
                                compactDetailRow(
                                    facts: facts,
                                    description: description,
                                    datafiedDetail: datafiedDetail,
                                    tint: tint
                                )
                            case .contextSummary, .reader:
                                readerDetailRows(
                                    facts: facts,
                                    description: description,
                                    datafiedDetail: datafiedDetail,
                                    tint: tint
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    sizeLabel(for: attachment)
                }
            }
        }
    }

    private func attachmentTitle(
        _ attachment: LockedAttachmentSummary,
        canOpen: Bool,
        badge: LockedAttachmentExtractionStatus.Badge?,
        tint: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                if let remote = attachment.liveRemoteURL() {
                    NSWorkspace.shared.open(remote)
                } else if let path = attachment.filePath {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            } label: {
                Text(attachment.filename)
                    .font(OhiaTypography.attachmentRowName)
                    .foregroundStyle(canOpen ? tint : OhiaColors.textTertiary)
                    .underline(canOpen, color: tint.opacity(0.4))
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            .help(titleHelp(for: attachment, canOpen: canOpen))
            .contextMenu {
                if let remote = attachment.liveRemoteURL() {
                    Button("Open Mail Drop Link") { NSWorkspace.shared.open(remote) }
                    Button("Copy Mail Drop Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(remote.absoluteString, forType: .string)
                    }
                } else if attachment.remoteURL != nil {
                    Button("Mail Drop Link Expired") {}
                        .disabled(true)
                } else if canOpen, let path = attachment.filePath {
                    let url = URL(fileURLWithPath: path)
                    Button("Open") { NSWorkspace.shared.open(url) }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }

            if let badge {
                extractionBadge(badge)
            }
        }
    }

    private func titleHelp(for attachment: LockedAttachmentSummary, canOpen: Bool) -> String {
        if attachment.remoteURL != nil {
            return canOpen
                ? "Open \(attachment.filename) from the sender's iCloud Mail Drop"
                : "\(attachment.filename) (Mail Drop link expired)"
        }
        return canOpen
            ? "Open \(attachment.filename) in its default app"
            : "\(attachment.filename) (binary not preserved)"
    }

    /// Mail Drop rows learn their size from iCloud; until then there is no
    /// size to show (the header declares 0).
    @ViewBuilder
    private func sizeLabel(for attachment: LockedAttachmentSummary) -> some View {
        if attachment.remoteURL == nil || attachment.sizeBytes > 0 {
            Text(Self.byteFormatter.string(fromByteCount: Int64(max(0, attachment.sizeBytes))))
                .font(OhiaTypography.attachmentRowMeta)
                .foregroundStyle(OhiaColors.textTertiary)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    private func compactDetailRow(
        facts: String?,
        description: String?,
        datafiedDetail: String?,
        tint: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let facts {
                Text(facts)
                    .font(OhiaTypography.attachmentRowMeta)
                    .foregroundStyle(tint.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if facts != nil && description != nil {
                Text("·")
                    .font(OhiaTypography.attachmentRowMeta)
                    .foregroundStyle(OhiaColors.textTertiary)
            }
            if let description {
                Text(description)
                    .font(OhiaTypography.attachmentRowMeta)
                    .foregroundStyle(OhiaColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            datafiedSeal(datafiedDetail, tint: tint)
        }
        .padding(.leading, 1)
    }

    private func readerDetailRows(
        facts: String?,
        description: String?,
        datafiedDetail: String?,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if facts != nil || datafiedDetail != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let facts {
                        Text(facts)
                            .font(OhiaTypography.attachmentRowMeta)
                            .foregroundStyle(tint.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    datafiedSeal(datafiedDetail, tint: tint)
                }
            }
            if let description {
                Text(description)
                    .font(readingTextSize.font(base: 12.5))
                    .lineSpacing(readingTextSize.spacing(2))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func datafiedSeal(_ datafiedDetail: String?, tint: Color) -> some View {
        if let datafiedDetail {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .help(datafiedDetail)
                .accessibilityLabel(datafiedDetail)
        }
    }

    private func extractionBadge(_ badge: LockedAttachmentExtractionStatus.Badge) -> some View {
        let foreground = foregroundColor(for: badge.tone)
        return Text(badge.label)
            .font(.system(size: 9, weight: .medium))
            .tracking(0.4)
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(backgroundColor(for: badge.tone))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(foreground.opacity(0.4), lineWidth: 1)
            }
            .help(badge.help)
    }

    private func foregroundColor(for tone: LockedAttachmentExtractionStatus.Tone) -> Color {
        switch tone {
        case .pending:
            return OhiaColors.accentOrange
        case .waiting:
            return OhiaColors.accentBlueGlow
        case .terminal:
            return OhiaColors.textTertiary
        case .failed:
            return OhiaColors.accentPink
        }
    }

    private func backgroundColor(for tone: LockedAttachmentExtractionStatus.Tone) -> Color {
        foregroundColor(for: tone).opacity(0.10)
    }

    /// Card-catalog fact for the row's secondary line: image dimensions and
    /// capture time / place, a video's capture time / place, page / slide /
    /// sheet count, or an estimated word count. `nil` when the relevant
    /// metric hasn't been extracted yet (or doesn't apply to the kind).
    private func factsString(for attachment: LockedAttachmentSummary) -> String? {
        switch AttachmentKind.classify(attachment) {
        case .image:
            var facts: [String] = []
            if let width = attachment.visualImagePixelWidth,
               let height = attachment.visualImagePixelHeight,
               width > 0, height > 0 {
                facts.append("\(width)×\(height)")
            }
            if let captureLine = attachment.captureLine {
                facts.append(captureLine)
            }
            return facts.isEmpty ? nil : facts.joined(separator: " · ")
        case .video:
            return attachment.captureLine
        case .pdf:
            return unitCount(attachment.extractionStructureUnitCount, singular: "page", plural: "pages")
        case .presentation:
            return unitCount(attachment.extractionStructureUnitCount, singular: "slide", plural: "slides")
        case .spreadsheet:
            return unitCount(attachment.extractionStructureUnitCount, singular: "sheet", plural: "sheets")
        default:
            return AttachmentReferenceText.wordEstimate(fromCharacterCount: attachment.extractionCharacterCount)
        }
    }

    private func unitCount(_ count: Int?, singular: String, plural: String) -> String? {
        guard let count, count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : plural)"
    }

    /// Reader-facing "what's in it" description drawn from extracted summaries:
    /// `visualSummary` for images, the generated `attachmentSummary` for
    /// documents. The catalog is the destination surface, so show the full
    /// cleaned paragraph instead of a teaser.
    private func descriptionString(for attachment: LockedAttachmentSummary) -> String? {
        let isImage = AttachmentKind.classify(attachment) == .image
        let primary = isImage ? attachment.visualSummary : attachment.attachmentSummary
        let secondary = isImage ? attachment.attachmentSummary : attachment.visualSummary
        guard let source = usefulDescription(primary) ?? usefulDescription(secondary) else { return nil }
        return AttachmentReferenceText.fullDescription(of: source)
    }

    private func usefulDescription(_ value: String?) -> String? {
        value.flatMap(AttachmentSummaryPostProcessor.clean)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Hover detail behind the "datafied" seal — enumerates the same visual
    /// evidence sources the old per-source badges spelled out (summary, OCR,
    /// labels, objects, evidence kind, extracted text), so the telemetry is
    /// preserved on demand without crowding the resting row. `nil` means the
    /// attachment carries no extracted evidence, so no seal is shown.
    private func datafiedDetail(for attachment: LockedAttachmentSummary) -> String? {
        var parts: [String] = []
        if nonEmpty(attachment.visualSummary) != nil || nonEmpty(attachment.attachmentSummary) != nil {
            parts.append("summary")
        }
        if let lines = attachment.visualOCRLineCount, lines > 0 {
            parts.append("OCR \(lines) \(lines == 1 ? "line" : "lines")")
        }
        if let labels = attachment.visualClassificationCount, labels > 0 {
            parts.append("\(labels) \(labels == 1 ? "label" : "labels")")
        }
        if let objects = attachment.visualObjectCount, objects > 0 {
            parts.append("\(objects) \(objects == 1 ? "object" : "objects")")
        }
        if let kind = nonEmpty(attachment.visualEvidenceKind) {
            parts.append(kind.replacingOccurrences(of: "-", with: " "))
        }
        if parts.isEmpty, nonEmpty(attachment.extractedTextPath) != nil {
            parts.append("text extracted")
        }
        guard !parts.isEmpty else { return nil }
        return "Datafied · " + parts.joined(separator: " · ")
    }

    private var groups: [AttachmentGroup] {
        let buckets = Dictionary(grouping: attachments) { AttachmentKind.classify($0) }
        return AttachmentKind.orderedCases.compactMap { kind in
            guard let items = buckets[kind], !items.isEmpty else { return nil }
            return AttachmentGroup(
                id: kind.rawValue,
                heading: kind.heading(count: items.count),
                symbolName: kind.symbolName,
                tooltip: kind.tooltip(count: items.count),
                tint: kind.tint,
                items: items.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
            )
        }
    }
}

private struct AttachmentGroup {
    let id: String
    let heading: String
    let symbolName: String
    let tooltip: String
    let tint: Color
    let items: [LockedAttachmentSummary]
}

private enum AttachmentKind: String, CaseIterable {
    case pdf, image, document, spreadsheet, presentation, archive, audio, video, code, calendar, other

    static let orderedCases: [AttachmentKind] = [
        .pdf, .document, .spreadsheet, .presentation,
        .image, .audio, .video, .archive, .code, .calendar, .other
    ]

    static func classify(_ attachment: LockedAttachmentSummary) -> AttachmentKind {
        let mime = attachment.mimeType.lowercased()
        let ext = (attachment.filename as NSString).pathExtension.lowercased()

        if mime == "application/pdf" || ext == "pdf" { return .pdf }
        if mime.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "bmp", "webp", "svg"].contains(ext) {
            return .image
        }
        if mime.hasPrefix("audio/") || ["mp3", "wav", "aiff", "flac", "m4a", "aac", "ogg"].contains(ext) {
            return .audio
        }
        if mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext) {
            return .video
        }
        if ["zip", "tar", "gz", "bz2", "7z", "rar", "xz"].contains(ext) || mime.contains("zip") || mime.contains("compressed") {
            return .archive
        }
        if ext == "ics" || mime.contains("calendar") { return .calendar }
        if ["doc", "docx", "rtf", "odt", "pages", "txt", "md"].contains(ext)
            || mime.contains("msword")
            || mime.contains("officedocument.wordprocessing")
            || mime == "text/plain" || mime == "text/markdown" {
            return .document
        }
        if ["xls", "xlsx", "ods", "numbers", "csv", "tsv"].contains(ext)
            || mime.contains("spreadsheet")
            || mime.contains("excel") {
            return .spreadsheet
        }
        if ["ppt", "pptx", "odp", "key"].contains(ext)
            || mime.contains("presentation")
            || mime.contains("powerpoint") {
            return .presentation
        }
        if ["json", "xml", "yaml", "yml", "html", "swift", "py", "js", "ts", "rb", "go", "rs", "c", "cpp", "h", "java", "kt", "sh"].contains(ext)
            || mime.contains("json") || mime.contains("xml") || mime.hasPrefix("text/x-") {
            return .code
        }
        return .other
    }

    var symbolName: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .archive: return "doc.zipper"
        case .audio: return "waveform"
        case .video: return "film"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .calendar: return "calendar"
        case .other: return "doc"
        }
    }

    /// Universal per-kind tint. Routes through
    /// `TimelineAttachmentKind.tint` so the Timeline multitrack
    /// attachment chips and the locked-overlay file rows agree on
    /// which color means "PDF" — the palette lives in exactly one
    /// place. `.calendar` is a locked-overlay-only kind so it picks
    /// its own neutral hue.
    var tint: Color {
        switch self {
        case .pdf:          return TimelineAttachmentKind.pdf.tint
        case .image:        return TimelineAttachmentKind.image.tint
        case .document:     return TimelineAttachmentKind.document.tint
        case .spreadsheet:  return TimelineAttachmentKind.spreadsheet.tint
        case .presentation: return TimelineAttachmentKind.presentation.tint
        case .archive:      return TimelineAttachmentKind.archive.tint
        case .audio:        return TimelineAttachmentKind.audio.tint
        case .video:        return TimelineAttachmentKind.video.tint
        case .code:         return TimelineAttachmentKind.code.tint
        case .calendar:     return OhiaColors.accentTeal
        case .other:        return TimelineAttachmentKind.other.tint
        }
    }

    func heading(count: Int) -> String {
        let label: String
        switch self {
        case .pdf: label = count == 1 ? "PDF" : "PDFs"
        case .image: label = count == 1 ? "Image" : "Images"
        case .document: label = count == 1 ? "Document" : "Documents"
        case .spreadsheet: label = count == 1 ? "Spreadsheet" : "Spreadsheets"
        case .presentation: label = count == 1 ? "Presentation" : "Presentations"
        case .archive: label = count == 1 ? "Archive" : "Archives"
        case .audio: label = count == 1 ? "Audio" : "Audio"
        case .video: label = count == 1 ? "Video" : "Videos"
        case .code: label = count == 1 ? "Code file" : "Code files"
        case .calendar: label = count == 1 ? "Calendar invite" : "Calendar invites"
        case .other: label = count == 1 ? "Other" : "Other"
        }
        return "\(label) · \(count)"
    }

    /// Hover tooltip explaining what an attachment-kind row represents.
    /// Kept short — `.help()` renders in a single small rect, so anything
    /// longer than a sentence wraps awkwardly.
    func tooltip(count: Int) -> String {
        let plural = count == 1 ? "" : "s"
        switch self {
        case .pdf:
            return "PDF document\(plural) attached to this email."
        case .image:
            return "Image\(plural) attached to this email."
        case .document:
            return "Word-processing or text document\(plural) attached to this email."
        case .spreadsheet:
            return "Spreadsheet\(plural) attached to this email."
        case .presentation:
            return "Slide deck\(plural) attached to this email."
        case .archive:
            return "Compressed archive\(plural) attached to this email."
        case .audio:
            return "Audio file\(plural) attached to this email."
        case .video:
            return "Video file\(plural) attached to this email."
        case .code:
            return "Source-code file\(plural) attached to this email."
        case .calendar:
            return "Calendar invite\(plural) attached to this email."
        case .other:
            return "Other attachment\(plural) on this email."
        }
    }
}
