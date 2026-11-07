import AppKit
import SwiftUI
import OhiaML

/// Display state for the Deadlines-tab deadline-summary hover pane.
enum DeadlineSummaryState: Equatable {
    case loading
    case loaded(DeadlineSummaryResult)
    case unavailable(String)
}

/// Hover pane shown beside a deadline (an agenda row or a calendar day). It
/// mirrors the Projects gutter CONTEXT pane idiom: a flowing Qwen-generated
/// paragraph distilling what the deadline is for and what the owner must do,
/// followed by a "WHAT'S NEEDED" list of concrete, interactive actions — links
/// that open, documents that reveal, phone numbers and addresses that copy.
struct DeadlineSummaryPopup: View {
    let title: String
    /// Short countdown descriptor for the header chip ("3 days", "Today",
    /// "2 days ago", "Done").
    let countdownText: String
    let countdownTint: Color
    let state: DeadlineSummaryState
    /// Invoked when the pointer enters / leaves the pane, so the host can keep it
    /// alive while the reader acts on an item.
    let onHoverPane: (Bool) -> Void
    /// Which edge the callout notch points from — leading when the pane sits to
    /// the right of its anchor, trailing when it sits to the left.
    var calloutEdge: AnnotationPopupCallout.Edge = .leading
    /// Vertical fraction (0…1) of the notch so it points back at the row/cell.
    var calloutAnchor: CGFloat = 0.5
    /// Total pane-height cap supplied by the host's live viewport. Short panes
    /// remain content-sized; only an overflowing reading body becomes scrollable.
    var maximumHeight: CGFloat? = nil

    @Environment(\.readingTextSize) private var readingTextSize

    static let contentWidth: CGFloat = 340
    static let calloutDepth: CGFloat = 9
    static let calloutBaseWidth: CGFloat = 16
    static let cornerRadius: CGFloat = 4
    static let viewportMargin: CGFloat = 8
    /// Full footprint width (content + the notch strip).
    static var footprintWidth: CGFloat { contentWidth + calloutDepth }

    static func maximumHeight(in viewportHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight - viewportMargin * 2)
    }

    private var chromeShape: AnnotationPopupChromeShape {
        AnnotationPopupChromeShape(
            callout: AnnotationPopupCallout(
                edge: calloutEdge,
                anchor: min(max(calloutAnchor, 0.12), 0.88),
                baseWidth: Self.calloutBaseWidth,
                depth: Self.calloutDepth
            ),
            cornerRadius: Self.cornerRadius
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 9)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(OhiaColors.glassBorder).frame(height: 1)
            fittingBody
        }
        .frame(width: Self.contentWidth, alignment: .topLeading)
        // The pane shrink-wraps to its content. A `.frame(maxHeight:)` cannot be
        // used to cap height here: under the overlay's `.position` proposal it is
        // greedy and grows the pane to the full cap, top-aligning the content and
        // leaving dead space below. `fittingBody` still scrolls an overflowing
        // body when the content itself is proposed a bounded height.
        // Reserve the strip the notch occupies on whichever edge it sits.
        .padding(.leading, calloutEdge == .leading ? Self.calloutDepth : 0)
        .padding(.trailing, calloutEdge == .trailing ? Self.calloutDepth : 0)
        .background {
            LinearGradient(
                colors: [OhiaColors.hoverReadoutGradientTop, OhiaColors.hoverReadoutGradientBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .overlay {
            chromeShape.stroke(OhiaColors.glassBorder, lineWidth: 1)
        }
        .clipShape(chromeShape)
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
        .onHover { onHoverPane($0) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The header stays visible while the substantive reading region scrolls
    /// only when its natural height cannot fit below that header.
    private var fittingBody: some View {
        ViewThatFits(in: .vertical) {
            bodyContent
            ScrollView(.vertical) {
                bodyContent
            }
        }
    }

    private var bodyContent: some View {
        body(for: state)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("DEADLINE SUMMARY")
                    .font(OhiaTypography.telemetrySectionCaps)
                    .tracking(0.5)
                    .foregroundStyle(OhiaColors.ohiaGreen)
                Spacer(minLength: 6)
                countdownChip
            }
            Text(title.isEmpty ? "(no subject)" : title)
                .font(readingTextSize.font(base: 12.5, weight: .semibold, maximumScale: 1.35))
                .foregroundStyle(OhiaColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var countdownChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 8, weight: .semibold))
            Text(countdownText)
                .font(OhiaTypography.telemetrySectionCaps)
                .tracking(0.4)
                .monospacedDigit()
        }
        .foregroundStyle(countdownTint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(countdownTint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(countdownTint.opacity(0.35), lineWidth: 0.6))
        .fixedSize()
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for state: DeadlineSummaryState) -> some View {
        switch state {
        case .loading:
            VStack(alignment: .leading, spacing: 6) {
                Text("reading the deadline")
                    .font(.system(size: 10.5).italic())
                    .foregroundStyle(OhiaColors.textTertiary)
                SummaryLoadingPlaceholderView(contentWidth: Self.contentWidth - 28)
            }
        case .loaded(let result):
            loadedBody(result)
        case .unavailable(let message):
            Text(message)
                .font(readingTextSize.font(base: 11.5).italic())
                .lineSpacing(readingTextSize.spacing(2.5))
                .foregroundStyle(OhiaColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loadedBody(_ result: DeadlineSummaryResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(result.paragraph)
                .font(readingTextSize.font(base: 12))
                .lineSpacing(readingTextSize.spacing(2.5))
                .foregroundStyle(OhiaColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if result.actions.isEmpty == false {
                Rectangle()
                    .fill(OhiaColors.glassBorder)
                    .frame(height: 1)
                    .padding(.vertical, 9)
                needsSection(result.actions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func needsSection(_ actions: [DeadlineActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 9, weight: .semibold))
                Text("WHAT'S NEEDED")
                    .font(OhiaTypography.telemetrySectionCaps)
                    .tracking(0.5)
            }
            .foregroundStyle(OhiaColors.accentOrange)
            ForEach(actions) { item in
                DeadlineActionRow(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityLabel: String {
        switch state {
        case .loading:
            return "Deadline summary for \(title), generating."
        case .loaded(let result):
            let needs = result.actions.map { $0.label + ($0.value.map { " \($0)" } ?? "") }.joined(separator: ". ")
            return "Deadline summary for \(title). \(result.paragraph). \(needs)"
        case .unavailable(let message):
            return "Deadline summary for \(title). \(message)"
        }
    }
}

// MARK: - Action row

/// One "WHAT'S NEEDED" row. Interactive by kind: a link opens in the browser, a
/// document opens the saved file, a phone number or address copies to the
/// clipboard on click. Shared by the hover pane and the guide pane's step rows.
struct DeadlineActionRow: View {
    let item: DeadlineActionItem

    @Environment(\.readingTextSize) private var readingTextSize
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button(action: activate) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    if item.label.isEmpty == false {
                        Text(item.label)
                            .font(readingTextSize.font(
                                base: 12,
                                weight: primaryIsValue ? .regular : .medium
                            ))
                            .foregroundStyle(OhiaColors.textPrimary)
                            .lineSpacing(readingTextSize.spacing(1.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let valueLine {
                        Text(copied ? "Copied" : valueLine)
                            .font(readingTextSize.font(base: 11.5))
                            .foregroundStyle(copied ? OhiaColors.ohiaGreen : valueTint)
                            .underline(isOpenable && hovering, color: valueTint)
                            .lineSpacing(readingTextSize.spacing(1.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let detail = item.detail, detail.isEmpty == false {
                        Text(detail)
                            .font(readingTextSize.font(base: 11))
                            .foregroundStyle(OhiaColors.textSecondary)
                            .lineSpacing(readingTextSize.spacing(1.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isInteractive == false)
        .onHover { hovering = $0 }
        .help(helpText)
    }

    // MARK: Behavior

    private var isInteractive: Bool {
        switch item.kind {
        case .link: return openURL != nil
        case .document: return fileURL != nil
        case .call, .returnTo: return item.value?.isEmpty == false
        case .action: return false
        }
    }

    private var isOpenable: Bool {
        item.kind == .link || item.kind == .document
    }

    private func activate() {
        switch item.kind {
        case .link:
            if let openURL { NSWorkspace.shared.open(openURL) }
        case .document:
            if let fileURL { NSWorkspace.shared.open(fileURL) }
        case .call, .returnTo:
            copyValue()
        case .action:
            break
        }
    }

    private func copyValue() {
        guard let value = item.value, value.isEmpty == false else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }

    // MARK: Presentation

    /// True when the value is the row's primary datum (link/document/return with
    /// no separate instruction label emphasis).
    private var primaryIsValue: Bool {
        item.kind == .document
    }

    private var valueLine: String? {
        switch item.kind {
        case .link: return displayURL
        case .document: return item.value
        case .call, .returnTo: return item.value
        case .action: return nil
        }
    }

    private var displayURL: String? {
        guard var value = item.value else { return nil }
        for scheme in ["https://", "http://"] where value.lowercased().hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        return value
    }

    private var openURL: URL? {
        guard var value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else {
            return nil
        }
        let lower = value.lowercased()
        if lower.hasPrefix("http://") == false && lower.hasPrefix("https://") == false {
            value = "https://" + value
        }
        return URL(string: value)
    }

    private var fileURL: URL? {
        guard item.kind == .document, let filePath = item.filePath, filePath.isEmpty == false else { return nil }
        return URL(fileURLWithPath: filePath)
    }

    private var symbol: String {
        switch item.kind {
        case .link: return "link"
        case .document: return "paperclip"
        case .call: return "phone.fill"
        case .returnTo: return "paperplane.fill"
        case .action: return "arrow.turn.down.right"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .link, .document, .returnTo: return OhiaColors.chipActiveForeground
        case .call: return OhiaColors.chipActiveForeground
        case .action: return OhiaColors.textTertiary
        }
    }

    private var valueTint: Color {
        switch item.kind {
        case .link, .document: return OhiaColors.chipActiveForeground
        case .call, .returnTo: return OhiaColors.textSecondary
        case .action: return OhiaColors.textTertiary
        }
    }

    private var helpText: String {
        switch item.kind {
        case .link: return "Open in your browser"
        case .document: return fileURL == nil ? "Attached file" : "Open the attached file"
        case .call: return "Copy the phone number"
        case .returnTo: return "Copy the address"
        case .action: return ""
        }
    }
}
