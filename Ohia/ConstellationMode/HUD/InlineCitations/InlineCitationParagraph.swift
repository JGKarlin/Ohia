import SwiftUI

/// Renders a paragraph that contains `[N]` markers, replacing each
/// resolvable marker with a kind-tinted SF Symbol + `[N]` chip flowed
/// inline with the prose. Hover surfaces a popover with the source's
/// title + excerpt; click invokes the source's action. Used by both the
/// lock-overlay context paragraph and the Ask answer body so the two
/// surfaces share one citation idiom.
struct InlineCitationParagraph: View {
    let paragraph: String
    let sources: [InlineCitationSource]
    var font: Font = .system(size: 12)
    var textColor: Color = OhiaColors.textPrimary
    var lineSpacing: CGFloat = 2
    var showsSourcePopover: Bool = true

    private let sourceByIndex: [Int: InlineCitationSource]
    private let tokens: [InlineCitationToken]

    init(
        paragraph: String,
        sources: [InlineCitationSource],
        font: Font = .system(size: 12),
        textColor: Color = OhiaColors.textPrimary,
        lineSpacing: CGFloat = 2,
        showsSourcePopover: Bool = true
    ) {
        self.paragraph = paragraph
        self.sources = sources
        self.font = font
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.showsSourcePopover = showsSourcePopover
        self.sourceByIndex = Dictionary(
            sources.map { ($0.index, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.tokens = InlineCitationParser.parse(paragraph, sourceCount: sources.count)
    }

    var body: some View {
        InlineFlowLayout(lineSpacing: lineSpacing) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                tokenView(token)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func tokenView(_ token: InlineCitationToken) -> some View {
        switch token {
        case .text(let s):
            Text(s)
                .font(font)
                .foregroundStyle(textColor)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: true, vertical: true)
        case .citation(let n):
            if let source = sourceByIndex[n] {
                InlineCitationChip(source: source, showsSourcePopover: showsSourcePopover)
                    .fixedSize()
            } else {
                Text("[\(n)]")
                    .font(font)
                    .foregroundStyle(OhiaColors.textTertiary)
                    .fixedSize()
            }
        }
    }
}

/// Compact `[N]` pill rendered inline within prose. Mirrors the existing
/// Ask `Sources` chip visuals: SF Symbol by source kind, kind-tinted
/// background and border, hover-popover with title + scrollable excerpt,
/// click-through to the surface's selection action.
struct InlineCitationChip: View {
    static let sourcePopoverBodyMaxHeight: CGFloat = 320

    let source: InlineCitationSource
    let showsSourcePopover: Bool

    @Environment(\.readingTextSize) private var readingTextSize
    @State private var hovering = false
    @State private var showSource = false

    var body: some View {
        if showsSourcePopover {
            interactiveChip
                .popover(isPresented: $showSource, arrowEdge: .top) {
                    sourcePopover
                }
                .help("Source [\(source.index)]: \(source.subjectLine ?? "")")
        } else {
            interactiveChip
        }
    }

    private var interactiveChip: some View {
        Text("[\(source.index)]")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(source.tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(source.tint.opacity(hovering ? 0.20 : 0.12))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(source.tint.opacity(hovering ? 0.65 : 0.4), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(.horizontal, 1)
            .contentShape(Rectangle())
            // SwiftUI's `.popover` wraps an `NSPopover` with `.transient`
            // dismiss behaviour, so the first click on the anchor is
            // consumed as a dismiss event before any `Button(action:)`
            // or `onTapGesture` can fire — that's the double-click we
            // were seeing. `highPriorityGesture` jumps the gesture queue
            // ahead of the popover's dismiss recognizer, so the same
            // click both closes the popover (via our own state write)
            // and runs the source action in one pass.
            .highPriorityGesture(
                TapGesture(count: 1)
                    .onEnded {
                        showSource = false
                        source.onClick()
                    }
            )
            .onHover { isHovering in
                hovering = isHovering
                showSource = showsSourcePopover && isHovering
                source.onHover(isHovering)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Source \(source.index): \(source.subjectLine ?? "")")
    }

    /// Mirrors the locked-overlay `AnnotationPopup` style so a citation
    /// hover reads as a miniature evidence pane: accent-tinted left
    /// stripe, monospace kind header, hairline divider, then key/value
    /// rows for From/To/Subject/Date — the same key/value treatment the
    /// expanded annotation pane uses for its `extras` rows.
    private var sourcePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            popoverHeader
            Divider().background(OhiaColors.glassBorder)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 5) {
                    popoverLine(label: "title", value: source.titleLine)
                    popoverLine(label: "excerpt", value: source.excerptLine)
                    popoverLine(label: "from", value: source.fromLine)
                    popoverLine(label: "to", value: source.toLine)
                    popoverLine(label: "subject", value: source.subjectLine)
                    popoverLine(label: "date", value: source.dateLine)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: Self.sourcePopoverBodyMaxHeight)
        }
        .frame(width: 320, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [OhiaColors.hoverReadoutGradientTop, OhiaColors.hoverReadoutGradientBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(source.tint)
                .frame(width: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
    }

    private var popoverHeader: some View {
        HStack(alignment: .center, spacing: 7) {
            Rectangle()
                .fill(source.tint)
                .frame(width: 18, height: 1)
            Image(systemName: source.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(source.tint)
            Text(source.kindLabel)
                .font(OhiaTypography.telemetrySectionCaps)
                .tracking(0.4)
                .foregroundStyle(source.tint)
            Spacer(minLength: 4)
            Text("[\(source.index)]")
                .font(OhiaTypography.telemetryEmphasis)
                .monospacedDigit()
                .foregroundStyle(OhiaColors.textSecondary)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func popoverLine(label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(OhiaTypography.telemetryLabel)
                    .foregroundStyle(OhiaColors.textTertiary)
                    .frame(width: 56, alignment: .trailing)
                Text(value)
                    .font(readingTextSize.font(base: 11))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}
