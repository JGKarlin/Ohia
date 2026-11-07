import AppKit
import OhiaML
import SwiftUI

/// Projects-lens hover pane built on Variant E ("Age-prominent") from an
/// earlier design-sandbox study. The pane replaces the cross-lens
/// `AnnotationPopup` at the Projects call site so the popup speaks the
/// same visual language as the row's pip column — obligation kind drives
/// the verb tint, age is the dominant trailing metric, and sender + date
/// stay prominent under the subject.
///
/// The pane preserves every expand/summary/message behavior of
/// `AnnotationPopup`: the expanded body switches between the summary
/// section (default), the lazy-loaded message section
/// (Shift-click/Shift-Space), the inline image preview for image
/// attachments, the `item.extras` ledger rows, and the bottom-of-pane
/// file link for openable attachments. The chrome reuses
/// `AnnotationPopupChromeShape` so the callout still points at the
/// originating node.
struct ProjectsHoverPopup: View {
    // MARK: Public API (mirrors AnnotationPopup)
    let item: AnnotationItem
    let expanded: Bool
    let expandedMode: AnnotationExpandedContentMode
    let onToggleExpanded: (AnnotationExpandedContentMode) -> Void
    let onClose: () -> Void
    var onMoveBy: (CGSize) -> Void = { _ in }
    var onMoveEnded: (CGSize) -> Void = { _ in }
    var summaryDisplay: AnnotationSummaryDisplay? = nil
    var messageDisplay: AnnotationMessageDisplay? = nil
    var transparentChrome: Bool = false
    var callout: AnnotationPopupCallout? = nil

    // MARK: Projects-specific inputs

    /// Obligation kinds present on this message. Drives the verb + tint
    /// in the header. Empty for messages that carry no obligations.
    let obligationKinds: Set<ProjectOpenObligation.Kind>
    /// `true` when this message carries an evidence-backed deadline tick
    /// on its row. Falls back to the "Deadline" verb in red when no
    /// obligation outranks it.
    let hasDeadline: Bool
    let statusDescriptor: MessageStatusDescriptor?
    /// Message receipt timestamp used to compute the "DAYS" counter in
    /// the trailing column. `nil` hides the age stack and shows the
    /// chevron on its own row.
    let messageDate: Date?
    /// "to" or "from" — kept separate from the labels so the italic
    /// styling can tint the preposition in the tertiary color.
    let senderPrefix: String
    /// Display name (or address fallback) of the counterparty.
    let senderLabel: String
    /// Pre-formatted date string for the sender · date line.
    let dateLabel: String
    /// To recipient(s) of a received message the user wasn't addressed
    /// to directly — extends the sender line to "from X to Y". Empty
    /// when routing is implied (user in To) or unknown.
    var toLabel: String = ""
    /// `true` appends "cc you" to the sender line — the user appears in
    /// the recipient set without being a To recipient.
    var isUserCcd: Bool = false
    /// Height the viewport clamp shaved off the expanded frame
    /// (`ProjectsPopupPlacement.expandedGeometry` holds the header fixed
    /// and clamps growth at the viewport bottom). The body sections
    /// absorb it by shrinking their scroll windows, so clamped content
    /// scrolls instead of clipping past the pane bottom.
    var bodyHeightShortfall: CGFloat = 0

    @Environment(\.readingTextSize) private var readingTextSize
    @State private var cachedImage: NSImage?

    var body: some View {
        let effectiveCallout = transparentChrome ? nil : callout
        let chromeShape = AnnotationPopupChromeShape(callout: effectiveCallout, cornerRadius: 4)

        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            if expanded {
                Divider().background(OhiaColors.glassBorder)
                extras
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            if let attachmentRef = item.attachmentReference,
               let filePath = attachmentRef.filePath,
               !filePath.isEmpty {
                Divider().background(OhiaColors.glassBorder)
                fileLinkFooter(attachment: attachmentRef, filePath: filePath)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .padding(effectiveCallout?.edge.paddingEdges ?? [], effectiveCallout?.depth ?? 0)
        // Fill the frame's full proposed height (set by the caller in
        // `ProjectsMessageReadout`'s `.frame(width:, height: layoutSize.height)`)
        // so the background + chromeShape + clipShape see the same bounds the
        // placement math (`ProjectsPopupPlacement.geometry`) used. Without
        // `maxHeight: .infinity` the inner VStack stays at its content-natural
        // height, the parent frame contains it top-aligned with empty space
        // below, and the notch (drawn by `AnnotationPopupChromeShape` at
        // `rect.maxY`) lands at the content's bottom — short of the
        // placement-assumed node-anchored frame bottom.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if !transparentChrome {
                LinearGradient(
                    colors: [OhiaColors.hoverReadoutGradientTop, OhiaColors.hoverReadoutGradientBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .overlay {
            if !transparentChrome {
                chromeShape
                    .stroke(OhiaColors.glassBorder, lineWidth: 1)
            }
        }
        .clipShape(chromeShape)
        .contentShape(chromeShape)
        .shadow(color: transparentChrome ? .clear : .black.opacity(0.45), radius: 16, x: 0, y: 8)
        .accessibilityElement(children: expanded && expandedMode == .message ? .contain : .combine)
        .accessibilityLabel(popupAccessibilityLabel)
        .task(id: imageLoadKey) {
            guard let path = imageLoadKey,
                  FileManager.default.fileExists(atPath: path) else {
                cachedImage = nil
                return
            }
            cachedImage = NSImage(contentsOfFile: path)
        }
    }

    // MARK: - Header (Variant E layout)

    private var header: some View {
        headerAccessibilityActions(
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: verbSymbol)
                            .font(.system(size: 10, weight: .semibold))
                        Text(verbLabel)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(verbColor)

                    Text(item.title.isEmpty ? "(no subject)" : item.title)
                        .font(readingTextSize.font(base: 12, weight: .semibold, maximumScale: 1.35))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !senderLabel.isEmpty || !dateLabel.isEmpty {
                        senderLine
                            .font(readingTextSize.font(base: 10.5, maximumScale: 1.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let statusDescriptor {
                        MessageStatusMark(
                            descriptor: statusDescriptor,
                            size: 12,
                            showsTextGloss: true,
                            showsAmbientSharedEvidence: true,
                            glossFont: .system(size: 9.5, weight: .semibold)
                        )
                        .layoutPriority(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    if let ageDays {
                        Text("\(ageDays)")
                            .font(.system(size: 22, weight: .bold).monospacedDigit())
                            .foregroundStyle(ageColor)
                        Text("DAYS")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(OhiaColors.textTertiary)
                    }
                    // Depth-aware disclosure glyph shared with the locked-node
                    // AnnotationPopup so the same content depth reads as the
                    // same chevron across lenses: compact → right, summary →
                    // down, full message → up. (Normal tap here is a binary
                    // compact ⇄ summary toggle; Shift-click reaches the message
                    // tier — the glyph tracks depth either way.)
                    Image(systemName: AnnotationPopup.headerChevronSymbol(
                        expanded: expanded,
                        expandedMode: expandedMode
                    ))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OhiaColors.textTertiary)
                        .padding(.top, ageDays == nil ? 0 : 4)
                }
            }
            .contentShape(Rectangle())
            .help(headerHelpText)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(headerAccessibilityLabel)
            .onTapGesture { onToggleExpanded(headerToggleMode) }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { onMoveBy($0.translation) }
                    .onEnded { onMoveEnded($0.translation) }
            )
        )
    }

    /// Italic sender · routing · date composite mirroring the sandbox's
    /// `senderLine(for:)` styling. Prepositions and separators read in
    /// tertiary so the counterparty / recipient names are the
    /// load-bearing fragments. For received messages not addressed to
    /// the user, the routing segment extends the line to
    /// "from X to Y · cc you" before the date.
    private var senderLine: Text {
        var line = AttributedString()
        var hasContent = false
        if !senderPrefix.isEmpty, !senderLabel.isEmpty {
            line.appendItalic("\(senderPrefix) ", color: OhiaColors.textTertiary)
            line.appendItalic(senderLabel, color: OhiaColors.textSecondary)
            hasContent = true
        } else if !senderLabel.isEmpty {
            line.appendItalic(senderLabel, color: OhiaColors.textSecondary)
            hasContent = true
        } else if !senderPrefix.isEmpty {
            line.appendItalic(senderPrefix, color: OhiaColors.textTertiary)
            hasContent = true
        }
        if !toLabel.isEmpty {
            if hasContent {
                line.appendItalic(" ", color: OhiaColors.textSecondary)
            }
            line.appendItalic("to ", color: OhiaColors.textTertiary)
            line.appendItalic(toLabel, color: OhiaColors.textSecondary)
            hasContent = true
        }
        if isUserCcd {
            if hasContent {
                line.appendItalic(" · ", color: OhiaColors.textTertiary)
            }
            line.appendItalic("cc ", color: OhiaColors.textTertiary)
            line.appendItalic("you", color: OhiaColors.textSecondary)
            hasContent = true
        }
        if !dateLabel.isEmpty {
            if hasContent {
                line.appendItalic(" · ", color: OhiaColors.textTertiary)
            }
            line.appendItalic(dateLabel, color: OhiaColors.textTertiary)
        }
        return Text(line)
    }

    // MARK: - Verb / tint cascade

    /// Pure-value cascade — single source of truth for which verb,
    /// icon, and tint the header renders. Lives in `OhiaML` so the
    /// cascade is unit-tested headlessly; this view just maps the
    /// resolved tint to a SwiftUI `Color` via `ObligationKindColor`.
    private var verb: ProjectsHoverVerb {
        ProjectsHoverVerb.resolve(
            obligationKinds: obligationKinds,
            hasDeadline: hasDeadline,
            isOutgoing: isOutgoing
        )
    }

    private var verbLabel: String {
        guard verb == .deadline,
              let deadlineText = statusDescriptor?.deadlineText else {
            return verb.label
        }
        return "\(verb.label) (\(deadlineText))"
    }
    private var verbSymbol: String { verb.symbolName }
    private var verbColor: Color { ObligationKindColor.color(for: verb.tint) }

    /// The trailing "DAYS" count carries the same tint as the verb so
    /// the pane reads as a single urgency unit. Neutral tint falls back
    /// to `textSecondary` for routine sent/received messages.
    private var ageColor: Color { ObligationKindColor.color(for: verb.tint) }

    private var isOutgoing: Bool {
        item.directionSymbol == "paperplane.fill"
    }

    private var ageDays: Int? {
        guard let messageDate else { return nil }
        let elapsed = Date.now.timeIntervalSince(messageDate)
        return max(0, Int(elapsed / 86_400))
    }

    // MARK: - Accessibility / interaction helpers (mirrors AnnotationPopup)

    private var popupAccessibilityLabel: String {
        if expanded, expandedMode == .message {
            return "\(verbLabel). Message"
        }
        // VoiceOver pacing benefits from the same `·` separator the visible
        // sender · date line uses — period after the verb, period after the
        // subject, then "from/to <name> · <date>" matches what a sighted
        // reader hears as one phrase.
        let directedLabel: String
        if !senderPrefix.isEmpty, !senderLabel.isEmpty {
            directedLabel = "\(senderPrefix) \(senderLabel)"
        } else if !senderLabel.isEmpty {
            directedLabel = senderLabel
        } else {
            directedLabel = ""
        }
        let trailing = [directedLabel, dateLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        if trailing.isEmpty {
            return "\(verbLabel). \(item.title)."
        }
        return "\(verbLabel). \(item.title). \(trailing)."
    }

    @ViewBuilder
    private func headerAccessibilityActions<Content: View>(_ content: Content) -> some View {
        let primary = content
            .accessibilityAction {
                onToggleExpanded(.summary)
            }
        if item.anchorMessageId != nil {
            primary.accessibilityAction(named: Text(headerMessageAccessibilityActionLabel)) {
                onToggleExpanded(.message)
            }
        } else {
            primary
        }
    }

    private var headerToggleMode: AnnotationExpandedContentMode {
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags?.contains(.shift) == true ? .message : .summary
    }

    private var headerHelpText: String {
        if expanded {
            return expandedMode == .message ? "Show summary" : "Collapse annotation"
        }
        return item.anchorMessageId == nil ? "Expand annotation" : "Expand annotation; Shift-click shows message"
    }

    private var headerAccessibilityLabel: String {
        if expanded, expandedMode == .message {
            return "Show \(verbLabel) summary"
        }
        return expanded
            ? "Collapse \(verbLabel) details"
            : "Expand \(verbLabel) details"
    }

    private var headerMessageAccessibilityActionLabel: String {
        expanded && expandedMode == .message ? "Collapse message" : "Show message"
    }

    // MARK: - Expanded body (port of AnnotationPopup.extras)

    private var extras: some View {
        VStack(alignment: .leading, spacing: 6) {
            if expandedMode == .message, item.anchorMessageId != nil {
                messageSection
            } else {
                if let attachmentRef = item.attachmentReference,
                   attachmentRef.isImage,
                   let image = cachedImage {
                    imagePreview(image: image, attachmentRef: attachmentRef)
                } else {
                    summarySection
                }
                ForEach(item.extras) { extra in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(extra.key)
                            .font(OhiaTypography.telemetryLabel)
                            .foregroundStyle(OhiaColors.textTertiary)
                            .frame(width: 72, alignment: .trailing)
                        Text(extra.value)
                            .font(OhiaTypography.telemetryValue)
                            .foregroundStyle(OhiaColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func imagePreview(
        image: NSImage,
        attachmentRef: AnnotationItem.AttachmentReference
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("preview")
                .font(OhiaTypography.annotationBody)
                .tracking(0.3)
                .foregroundStyle(OhiaColors.textTertiary)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
                }
                .accessibilityLabel(Text("Preview of \(attachmentRef.filename)"))
        }
    }

    /// Image-load key keyed to the attachment file path so `.task(id:)`
    /// only reloads when the popup is rebound to a different attachment.
    private var imageLoadKey: String? {
        guard let attachmentRef = item.attachmentReference,
              attachmentRef.isImage,
              let path = attachmentRef.filePath,
              !path.isEmpty else {
            return nil
        }
        return path
    }

    /// Bottom-of-pane file link mirroring `AnnotationPopup.fileLinkFooter`.
    private func fileLinkFooter(
        attachment: AnnotationItem.AttachmentReference,
        filePath: String
    ) -> some View {
        let url = URL(fileURLWithPath: filePath)
        let canOpen = FileManager.default.fileExists(atPath: filePath)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                guard canOpen else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Label(attachment.filename, systemImage: "doc")
                    .font(OhiaTypography.attachmentRowName)
                    .foregroundStyle(canOpen ? OhiaColors.accentOrange : OhiaColors.textTertiary)
                    .underline(canOpen, color: OhiaColors.accentOrange.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            .help(canOpen
                  ? "Open \(attachment.filename) in its default app"
                  : "\(attachment.filename) (binary not preserved)")
            .accessibilityLabel(canOpen
                ? Text("Open \(attachment.filename)")
                : Text("\(attachment.filename), file not available"))
            .contextMenu {
                if canOpen {
                    Button("Open", systemImage: "arrow.up.right.square") {
                        NSWorkspace.shared.open(url)
                    }
                    Button("Reveal in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            Spacer(minLength: 6)
            Text(Self.byteFormatter.string(fromByteCount: Int64(max(0, attachment.sizeBytes))))
                .font(OhiaTypography.attachmentRowMeta)
                .foregroundStyle(OhiaColors.textTertiary)
                .lineLimit(1)
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    // MARK: - Summary section (port of AnnotationPopup.summarySection)

    @ViewBuilder
    private var summarySection: some View {
        if let summaryDisplay {
            switch summaryDisplay {
            case .loading:
                summaryHeader
                SummaryLoadingPlaceholderView(contentWidth: 264)
                    .padding(.top, 1)
            case .ready(let text):
                summaryParagraph(text)
            case .extracting:
                summaryHeader
                SummaryLoadingPlaceholderView(contentWidth: 264)
                    .padding(.top, 1)
            case .waitingForAppleIntelligence:
                summaryUnavailable("Image descriptions require Apple Intelligence. They will appear when it is available.")
            case .unsupported:
                summaryUnavailable("Binary contents — no text-based summary available.")
            case .unavailable:
                summaryUnavailable("Summary unavailable.")
            }
        } else if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty {
            summaryParagraph(summary)
        }
    }

    private var summaryHeader: some View {
        Text("summary")
            .font(OhiaTypography.annotationBody)
            .tracking(0.3)
            .foregroundStyle(OhiaColors.textTertiary)
    }

    private func summaryParagraph(_ text: String) -> some View {
        let readingTextScale = readingTextSize.pointSize(base: 11.5) / 11.5
        return VStack(alignment: .leading, spacing: 3) {
            summaryHeader
            // No truncation: ellipsis-cutting a summary is banned app-wide.
            // Summaries longer than the layout's reserved block — or squeezed
            // by a viewport-clamped expansion — scroll within the reserved
            // window instead, so every line stays reachable.
            ProjectsHoverMessageBody(
                text: text,
                contentWidth: ProjectsHoverPopupLayout.messageReadoutContentWidth,
                maxHeight: ProjectsHoverPopupLayout.summaryBodyMaxHeight(
                    readingTextScale: readingTextScale
                ) - bodyHeightShortfall
            )
        }
    }

    private func summaryUnavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            summaryHeader
            Text(message)
                .font(readingTextSize.font(base: 11).italic())
                .lineSpacing(readingTextSize.spacing(2))
                .foregroundStyle(OhiaColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Message section (port of AnnotationPopup.messageSection)

    @ViewBuilder
    private var messageSection: some View {
        switch messageDisplay {
        case .loading:
            messageHeader
            SummaryLoadingPlaceholderView(contentWidth: 264)
                .padding(.top, 1)
        case .ready(let text):
            messageParagraph(text)
        case .unavailable, nil:
            messageUnavailable("Message unavailable.")
        }
    }

    private var messageHeader: some View {
        Text("message")
            .font(OhiaTypography.annotationBody)
            .tracking(0.3)
            .foregroundStyle(OhiaColors.textTertiary)
    }

    private func messageParagraph(_ text: String) -> some View {
        let readingTextScale = readingTextSize.pointSize(base: 11.5) / 11.5
        return VStack(alignment: .leading, spacing: 3) {
            messageHeader
            ProjectsHoverMessageBody(
                text: text,
                contentWidth: ProjectsHoverPopupLayout.messageReadoutContentWidth,
                maxHeight: ProjectsHoverPopupLayout.messageBodyMaxHeight(
                    readingTextScale: readingTextScale
                ) - bodyHeightShortfall
            )
        }
    }

    private func messageUnavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            messageHeader
            Text(message)
                .font(readingTextSize.font(base: 11).italic())
                .lineSpacing(readingTextSize.spacing(2))
                .foregroundStyle(OhiaColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension AttributedString {
    mutating func appendItalic(_ value: String, color: Color) {
        var segment = AttributedString(value)
        segment.inlinePresentationIntent = .emphasized
        segment.foregroundColor = color
        append(segment)
    }
}
