import OhiaCore
import OhiaML
import SwiftUI

/// Content-aware popup dimensions for Projects-lens hover readouts.
/// `ProjectsPopupPlacement` must use the same heights the popup actually
/// renders — reserving `AnnotationItem.expandedSize` (built for
/// `AnnotationPopup`'s brief row + shorter header) leaves a tall empty
/// gradient band and mis-anchors the callout notch.
enum ProjectsHoverPopupLayout {
    static let messageReadoutExpandedWidth: CGFloat = 300

    static let horizontalInset: CGFloat = 24
    static var messageReadoutContentWidth: CGFloat { messageReadoutExpandedWidth - horizontalInset }
    private static let headerVerticalPadding: CGFloat = 20
    private static let expandedSectionPadding: CGFloat = 20
    private static let sectionDivider: CGFloat = 1
    private static let extrasSpacing: CGFloat = 6
    private static let sectionLabelHeight: CGFloat = 14
    private static let sectionLabelSpacing: CGFloat = 3
    private static let lineHeight: CGFloat = 16.5
    private static let summaryLineCap: CGFloat = 10
    /// Reading window for the message tier. The tier carries the FULL
    /// cleaned body (no character cap), so this window is what the reader
    /// scrolls a long email through — sized for reading, not peeking.
    private static let messageScrollCap: CGFloat = 280
    private static let loadingSlotHeight: CGFloat = 28
    private static let fileLinkFooterHeight: CGFloat = 36
    /// Small surplus so a conservative line estimate does not clip the
    /// last line inside the fixed placement frame.
    private static let expandedLayoutSlack: CGFloat = 10

    // MARK: - Public sizing

    static func messageReadoutBaseSize(
        item: AnnotationItem,
        senderLineText: String? = nil,
        expanded: Bool,
        expandedMode: AnnotationExpandedContentMode,
        summaryDisplay: AnnotationSummaryDisplay?,
        messageDisplay: AnnotationMessageDisplay?,
        readingTextScale: CGFloat = 1,
        maxViewportWidth: CGFloat,
        maxViewportHeight: CGFloat
    ) -> CGSize {
        let width = min(messageReadoutExpandedWidth, max(180, maxViewportWidth - 32))
        let height: CGFloat
        if expanded {
            height = expandedHeight(
                contentWidth: width - horizontalInset,
                expandedMode: expandedMode,
                summaryDisplay: summaryDisplay,
                messageDisplay: messageDisplay,
                title: item.title,
                senderLineText: senderLineText,
                extrasCount: item.extras.count,
                showsImagePreview: item.attachmentReference?.isImage == true,
                showsFileLink: item.attachmentReference?.filePath?.isEmpty == false,
                readingTextScale: readingTextScale
            )
        } else {
            height = collapsedMessageHeaderHeight(
                title: item.title,
                senderLineText: senderLineText,
                contentWidth: width - horizontalInset,
                readingTextScale: readingTextScale
            )
                + fileLinkHeight(item: item)
        }
        return cappedSize(
            width: width,
            height: height,
            maxViewportHeight: maxViewportHeight
        )
    }

    /// Scroll cap for the message body — matches `messageScrollCap`.
    static func messageBodyMaxHeight(readingTextScale: CGFloat) -> CGFloat {
        messageScrollCap * readingTextScale
    }

    /// Height the layout reserves for the summary text block — the cap the
    /// rendered summary must scroll within rather than clip past.
    static func summaryBodyMaxHeight(readingTextScale: CGFloat) -> CGFloat {
        summaryLineCap * lineHeight * readingTextScale
    }

    /// Minimum readable body window when a viewport-clamped expansion eats
    /// into the section budget: three lines, below which scrolling text
    /// stops being usable.
    static func minimumBodyHeight(readingTextScale: CGFloat) -> CGFloat {
        3 * lineHeight * readingTextScale
    }

    static func estimatedMessageBodyHeight(
        text: String,
        contentWidth: CGFloat,
        readingTextScale: CGFloat
    ) -> CGFloat {
        textBlockHeight(
            lineCount: estimatedLineCount(
                text: text,
                contentWidth: contentWidth,
                readingTextScale: readingTextScale
            ),
            readingTextScale: readingTextScale
        )
    }

    // MARK: - Expanded body height

    private static func expandedHeight(
        contentWidth: CGFloat,
        expandedMode: AnnotationExpandedContentMode,
        summaryDisplay: AnnotationSummaryDisplay?,
        messageDisplay: AnnotationMessageDisplay?,
        title: String,
        senderLineText: String? = nil,
        extrasCount: Int,
        showsImagePreview: Bool,
        showsFileLink: Bool,
        readingTextScale: CGFloat
    ) -> CGFloat {
        var height = collapsedMessageHeaderHeight(
            title: title,
            senderLineText: senderLineText,
            contentWidth: contentWidth,
            readingTextScale: readingTextScale
        )
        height += sectionDivider + expandedSectionPadding
        height += expandedBodyHeight(
            contentWidth: contentWidth,
            expandedMode: expandedMode,
            summaryDisplay: summaryDisplay,
            messageDisplay: messageDisplay,
            extrasCount: extrasCount,
            showsImagePreview: showsImagePreview,
            readingTextScale: readingTextScale
        )
        if showsFileLink {
            height += sectionDivider + fileLinkFooterHeight
        }
        return height + expandedLayoutSlack
    }

    private static func expandedBodyHeight(
        contentWidth: CGFloat,
        expandedMode: AnnotationExpandedContentMode,
        summaryDisplay: AnnotationSummaryDisplay?,
        messageDisplay: AnnotationMessageDisplay?,
        extrasCount: Int,
        showsImagePreview: Bool,
        readingTextScale: CGFloat
    ) -> CGFloat {
        if expandedMode == .message {
            return messageSectionHeight(
                contentWidth: contentWidth,
                messageDisplay: messageDisplay,
                readingTextScale: readingTextScale
            )
        }
        var height: CGFloat = 0
        if showsImagePreview {
            height += imagePreviewHeight
        } else {
            height += summarySectionHeight(
                contentWidth: contentWidth,
                summaryDisplay: summaryDisplay,
                readingTextScale: readingTextScale
            )
        }
        if extrasCount > 0 {
            height += CGFloat(extrasCount) * (extrasSpacing + 32)
        }
        return height
    }

    private static func summarySectionHeight(
        contentWidth: CGFloat,
        summaryDisplay: AnnotationSummaryDisplay?,
        readingTextScale: CGFloat
    ) -> CGFloat {
        let labelBlock = sectionLabelHeight + sectionLabelSpacing
        guard let summaryDisplay else {
            return labelBlock + singleLineHeight
        }
        switch summaryDisplay {
        case .loading, .extracting:
            return labelBlock + loadingSlotHeight + 1
        case .ready(let text):
            return labelBlock + summaryTextHeight(
                text: text,
                contentWidth: contentWidth,
                readingTextScale: readingTextScale
            )
        case .waitingForAppleIntelligence, .unsupported, .unavailable:
            return labelBlock + singleLineHeight * 2 * readingTextScale
        }
    }

    private static func messageSectionHeight(
        contentWidth: CGFloat,
        messageDisplay: AnnotationMessageDisplay?,
        readingTextScale: CGFloat
    ) -> CGFloat {
        let labelBlock = sectionLabelHeight + sectionLabelSpacing
        guard let messageDisplay else {
            return labelBlock + singleLineHeight
        }
        switch messageDisplay {
        case .loading:
            return labelBlock + loadingSlotHeight + 1
        case .ready(let text):
            return labelBlock + min(
                messageScrollCap * readingTextScale,
                textBlockHeight(
                    lineCount: estimatedLineCount(
                        text: text,
                        contentWidth: contentWidth,
                        readingTextScale: readingTextScale
                    ),
                    readingTextScale: readingTextScale
                )
            )
        case .unavailable:
            return labelBlock + singleLineHeight * readingTextScale
        }
    }

    private static func summaryTextHeight(
        text: String,
        contentWidth: CGFloat,
        readingTextScale: CGFloat
    ) -> CGFloat {
        textBlockHeight(
            lineCount: min(
                summaryLineCap,
                estimatedLineCount(
                    text: text,
                    contentWidth: contentWidth,
                    readingTextScale: readingTextScale
                )
            ),
            readingTextScale: readingTextScale
        )
    }

    // MARK: - Collapsed headers

    /// `senderLineText` is the plain-text rendition of the italic
    /// sender · routing · date composite. When provided, the reserved
    /// height tracks its wrapped line count (the routing variant — "from
    /// X to Y · cc you · date" — regularly wraps to two lines); `nil`
    /// falls back to the single-line reservation.
    private static func collapsedMessageHeaderHeight(
        title: String,
        senderLineText: String?,
        contentWidth: CGFloat,
        readingTextScale: CGFloat
    ) -> CGFloat {
        let headerTextScale = max(0.96, min(readingTextScale, 1.35))
        var height = headerVerticalPadding
        height += 16 + 6 // verb row + spacing
        height += titleBlockHeight(title: title, readingTextScale: headerTextScale)
        if let senderLineText, !senderLineText.isEmpty {
            height += estimatedSenderLineCount(
                text: senderLineText,
                contentWidth: contentWidth,
                readingTextScale: headerTextScale
            ) * 14 * headerTextScale
        } else {
            height += 14 * headerTextScale
        }
        return height
    }

    /// Wrap estimate for the 10.5pt italic sender · routing · date line.
    /// Width-accumulating (per-character) rather than chars-per-line so
    /// CJK names — roughly full-em glyphs — reserve real height; the
    /// header's trailing DAYS cluster narrows the line's column, so its
    /// width comes off the top before estimating wraps.
    private static func estimatedSenderLineCount(
        text: String,
        contentWidth: CGFloat,
        readingTextScale: CGFloat
    ) -> CGFloat {
        let trailingClusterWidth: CGFloat = 48
        let available = max(80, contentWidth - trailingClusterWidth)
        let estimatedWidth = text.unicodeScalars.reduce(CGFloat(0)) { acc, scalar in
            acc + (isFullWidthScalar(scalar) ? 10.5 : 5.8) * readingTextScale
        }
        return max(1, (estimatedWidth / available).rounded(.up))
    }

    /// Scalars that render at (approximately) a full em at the sender
    /// line's font size: CJK ideographs, kana, Hangul, CJK punctuation,
    /// and full-width forms.
    private static func isFullWidthScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,   // Hangul Jamo
             0x2E80...0x303F,   // CJK radicals, Kangxi, CJK punctuation
             0x3040...0x30FF,   // Hiragana, Katakana
             0x3130...0x318F,   // Hangul compatibility Jamo
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFF00...0xFF60,   // Full-width forms
             0x20000...0x2FA1F: // CJK Extensions B+
            return true
        default:
            return false
        }
    }

    // MARK: - Helpers

    private static let imagePreviewHeight: CGFloat = 14 + 3 + 220

    private static let singleLineHeight: CGFloat = 16

    private static func titleBlockHeight(title: String, readingTextScale: CGFloat) -> CGFloat {
        let lines = estimatedLineCount(
            text: title.isEmpty ? "(no subject)" : title,
            contentWidth: 240,
            readingTextScale: readingTextScale
        )
        return lines * 15 * readingTextScale
    }

    private static func estimatedLineCount(
        text: String,
        contentWidth: CGFloat,
        readingTextScale: CGFloat = 1
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let width = max(80, contentWidth)
        // Slightly pessimistic (fewer chars per line) so placement height
        // does not under-estimate and crop the last visible line.
        let chars = max(12, width / (7.2 * readingTextScale))
        return max(1, (CGFloat(text.count) / chars).rounded(.up))
    }

    private static func textBlockHeight(
        lineCount: CGFloat,
        cap: CGFloat = .greatestFiniteMagnitude,
        readingTextScale: CGFloat = 1
    ) -> CGFloat {
        guard lineCount > 0 else { return 0 }
        return min(lineCount, cap) * lineHeight * readingTextScale
    }

    private static func fileLinkHeight(item: AnnotationItem) -> CGFloat {
        guard item.kind == .attachment,
              let path = item.attachmentReference?.filePath,
              !path.isEmpty else {
            return 0
        }
        return sectionDivider + fileLinkFooterHeight
    }

    private static func cappedSize(
        width: CGFloat,
        height: CGFloat,
        maxViewportHeight: CGFloat
    ) -> CGSize {
        let margin = ProjectsPopupPlacement.margin * 2
        let maxHeight = max(120, maxViewportHeight - margin)
        return CGSize(width: width, height: min(height, maxHeight))
    }
}

/// Body text for Projects hover popups (message body and summary) —
/// scrolls only when content exceeds the layout cap so short text
/// doesn't leave a dead band inside the pane. `maxHeight` defaults to
/// the message-body cap; callers whose section budget was reduced (a
/// viewport-clamped expansion) pass the smaller remaining window so the
/// text scrolls within it instead of clipping past the pane bottom.
struct ProjectsHoverMessageBody: View {
    let text: String
    let contentWidth: CGFloat
    let maxHeight: CGFloat?

    @Environment(\.readingTextSize) private var readingTextSize

    init(text: String, contentWidth: CGFloat, maxHeight: CGFloat? = nil) {
        self.text = text
        self.contentWidth = contentWidth
        self.maxHeight = maxHeight
    }

    var body: some View {
        let readingTextScale = readingTextSize.pointSize(base: 11.5) / 11.5
        let resolvedMaximumHeight = maxHeight
            ?? ProjectsHoverPopupLayout.messageBodyMaxHeight(readingTextScale: readingTextScale)
        let cap = max(
            ProjectsHoverPopupLayout.minimumBodyHeight(readingTextScale: readingTextScale),
            resolvedMaximumHeight
        )
        let natural = ProjectsHoverPopupLayout.estimatedMessageBodyHeight(
            text: text,
            contentWidth: contentWidth,
            readingTextScale: readingTextScale
        )
        Group {
            if natural <= cap {
                Text(text)
                    .font(readingTextSize.font(base: 11.5))
                    .lineSpacing(readingTextSize.spacing(2))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.vertical) {
                    Text(text)
                        .font(readingTextSize.font(base: 11.5))
                        .lineSpacing(readingTextSize.spacing(2))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: cap)
            }
        }
    }
}
