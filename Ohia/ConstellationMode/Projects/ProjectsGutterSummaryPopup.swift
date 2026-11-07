import OhiaML
import SwiftUI

/// Display state for the Projects-lens gutter project-summary hover pane.
enum ProjectGutterSummaryState: Equatable {
    case loading
    case loaded(ProjectSummaryResult)
    case unavailable(String)
}

/// Three-state lifecycle badge shown in the pane header, derived from the
/// project row (not the model) so it always matches the gutter's own
/// active / inactive-resolved grouping.
enum ProjectSummaryStatusKind: Equatable {
    case active
    case inactive
    case resolved

    var label: String {
        switch self {
        case .active: return "Active"
        case .inactive: return "Inactive"
        case .resolved: return "Resolved"
        }
    }

    var symbolName: String {
        switch self {
        case .active: return "circle.fill"
        case .inactive: return "moon.zzz.fill"
        case .resolved: return "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .active: return OhiaColors.ohiaGreen
        case .inactive: return OhiaColors.textTertiary
        case .resolved: return OhiaColors.textSecondary
        }
    }
}

/// Deterministic open-obligation state for the bottom section, taken straight
/// from the project row's `obligationLoad` (the same source the gutter pips
/// use) so the pane never invents an open issue the messages don't support.
struct ProjectOpenItemsState: Equatable {
    let pendingReplyCount: Int
    let confirmationCount: Int
    let isResolved: Bool

    var hasOpenItems: Bool { pendingReplyCount + confirmationCount > 0 }

    /// Section caps label reflecting which kind of obligation is open.
    var sectionLabel: String {
        if pendingReplyCount > 0 { return "OPEN ISSUE" }
        if confirmationCount > 0 { return "AWAITING CONFIRMATION" }
        return "STATUS"
    }

    /// Deterministic one-liner used when there is nothing open, or as a
    /// fallback when the model declined to phrase the open issue.
    func statusText(modelOpenQuestion: String?) -> String {
        if hasOpenItems {
            if let modelOpenQuestion, !modelOpenQuestion.isEmpty {
                return modelOpenQuestion
            }
            var parts: [String] = []
            if pendingReplyCount > 0 {
                parts.append("\(pendingReplyCount) message\(pendingReplyCount == 1 ? "" : "s") awaiting your reply")
            }
            if confirmationCount > 0 {
                parts.append("\(confirmationCount) awaiting confirmation")
            }
            return parts.joined(separator: " · ") + "."
        }
        return isResolved
            ? "Resolved — nothing awaiting a reply or confirmation."
            : "No open items — nothing awaiting a reply or confirmation."
    }
}

/// Hover pane shown beside a project title in the Projects-lens gutter. It
/// mirrors the meanings-lens CONTEXT pane idiom: a flowing Qwen-generated
/// paragraph (project / goals / timeline / progress) with inline `[N]`
/// citations, followed by a visually distinct "open issue" line. Clicking a
/// citation opens that message's readout.
struct ProjectsGutterSummaryPopup: View {
    let projectTitle: String
    let state: ProjectGutterSummaryState
    /// Invoked when the pointer enters / leaves the pane, so the host can
    /// keep the pane alive while the user reads it or reaches a citation.
    let onHoverPane: (Bool) -> Void
    /// Invoked with a cited message id when the reader clicks a `[N]` chip.
    let onCitationSelected: (UUID) -> Void
    /// Lifecycle badge shown in the header.
    let statusKind: ProjectSummaryStatusKind
    /// Open-obligation state driving the bottom section deterministically.
    let openItems: ProjectOpenItemsState
    /// Vertical position (0…1, top→bottom) of the leading callout notch, so the
    /// little triangle points back at the project row that opened the pane.
    var calloutAnchor: CGFloat = 0.5

    @Environment(\.readingTextSize) private var readingTextSize

    static let contentWidth: CGFloat = 340
    static let calloutDepth: CGFloat = 9
    static let calloutBaseWidth: CGFloat = 16
    static let cornerRadius: CGFloat = 4
    /// Full footprint width (content + the leading notch strip). The host uses
    /// this to keep the notch tip pinned just right of the gutter.
    static var footprintWidth: CGFloat { contentWidth + calloutDepth }

    private var chromeShape: AnnotationPopupChromeShape {
        AnnotationPopupChromeShape(
            callout: AnnotationPopupCallout(
                edge: .leading,
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
            Rectangle().fill(OhiaColors.glassBorder).frame(height: 1)
            body(for: state)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
        .frame(width: Self.contentWidth, alignment: .topLeading)
        // Reserve the leading strip the notch occupies so content never sits
        // under the triangle.
        .padding(.leading, Self.calloutDepth)
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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("PROJECT SUMMARY")
                    .font(OhiaTypography.telemetrySectionCaps)
                    .tracking(0.5)
                    .foregroundStyle(OhiaColors.ohiaGreen)
                Spacer(minLength: 6)
                statusChip
            }
            Text(projectTitle)
                .font(readingTextSize.font(base: 12.5, weight: .semibold, maximumScale: 1.35))
                .foregroundStyle(OhiaColors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusChip: some View {
        HStack(spacing: 4) {
            Image(systemName: statusKind.symbolName)
                .font(.system(size: 8, weight: .semibold))
            Text(statusKind.label)
                .font(OhiaTypography.telemetrySectionCaps)
                .tracking(0.4)
        }
        .foregroundStyle(statusKind.tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(statusKind.tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(statusKind.tint.opacity(0.35), lineWidth: 0.6))
        .fixedSize()
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for state: ProjectGutterSummaryState) -> some View {
        switch state {
        case .loading:
            VStack(alignment: .leading, spacing: 6) {
                Text("reading the project")
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

    private func loadedBody(_ result: ProjectSummaryResult) -> some View {
        let sources = inlineSources(for: result.citations)
        return VStack(alignment: .leading, spacing: 0) {
            InlineCitationParagraph(
                paragraph: result.paragraph,
                sources: sources,
                font: readingTextSize.font(base: 12),
                textColor: OhiaColors.textPrimary,
                lineSpacing: readingTextSize.spacing(2.5),
                showsSourcePopover: false
            )
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(height: 1)
                .padding(.vertical, 9)
            // Bottom section is driven by the project's real obligation state,
            // not the model: a genuine open issue (model-phrased when present)
            // only when the row carries open obligations; otherwise a clear
            // "nothing pending" line.
            openSection(modelOpenQuestion: result.openQuestion, sources: sources)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func openSection(modelOpenQuestion: String?, sources: [InlineCitationSource]) -> some View {
        let hasOpen = openItems.hasOpenItems
        let tint = hasOpen ? OhiaColors.accentOrange : OhiaColors.textTertiary
        let symbol = hasOpen
            ? "arrow.turn.down.right"
            : (statusKind == .resolved ? "checkmark.circle" : "circle")
        let bodyText = openItems.statusText(modelOpenQuestion: modelOpenQuestion)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(openItems.sectionLabel)
                    .font(OhiaTypography.telemetrySectionCaps)
                    .tracking(0.5)
            }
            .foregroundStyle(tint)
            if hasOpen, let open = modelOpenQuestion, !open.isEmpty {
                // Model phrasing carries citations; render them.
                InlineCitationParagraph(
                    paragraph: open,
                    sources: sources,
                    font: readingTextSize.font(base: 12),
                    textColor: OhiaColors.textPrimary,
                    lineSpacing: readingTextSize.spacing(2.5),
                    showsSourcePopover: false
                )
            } else {
                Text(bodyText)
                    .font(hasOpen
                        ? readingTextSize.font(base: 12)
                        : readingTextSize.font(base: 12).italic())
                    .foregroundStyle(hasOpen ? OhiaColors.textPrimary : OhiaColors.textTertiary)
                    .lineSpacing(readingTextSize.spacing(2.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Citation mapping

    private func inlineSources(for citations: [ProjectSummaryCitation]) -> [InlineCitationSource] {
        citations.compactMap { citation -> InlineCitationSource? in
            guard let index = Int(citation.label) else { return nil }
            let messageID = ProjectSummaryInputBuilder.citationTargetMessageID(citation.targetID)
            return InlineCitationSource(
                index: index,
                symbolName: symbol(for: citation.kind),
                tint: tint(for: citation.kind),
                kindLabel: kindLabel(for: citation.kind),
                titleLine: citation.subjectDisplay,
                excerptLine: nil,
                fromLine: citation.senderDisplay,
                toLine: citation.recipientsDisplay,
                subjectLine: citation.subjectDisplay,
                dateLine: citation.receivedAt.map { Self.dateFormatter.string(from: $0) },
                onClick: {
                    if let messageID { onCitationSelected(messageID) }
                },
                onHover: { _ in }
            )
        }
    }

    private func symbol(for kind: ProjectSummaryCitation.SourceKind) -> String {
        switch kind {
        case .message: return "envelope"
        case .obligation: return "arrowshape.turn.up.left"
        case .deadline: return "calendar.badge.clock"
        }
    }

    private func tint(for kind: ProjectSummaryCitation.SourceKind) -> Color {
        switch kind {
        case .message: return OhiaColors.textSecondary
        case .obligation, .deadline: return OhiaColors.accentOrange
        }
    }

    private func kindLabel(for kind: ProjectSummaryCitation.SourceKind) -> String {
        switch kind {
        case .message: return "in this project"
        case .obligation: return "open obligation"
        case .deadline: return "deadline"
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .loading:
            return "Project summary for \(projectTitle), generating."
        case .loaded(let result):
            if let open = result.openQuestion {
                return "Project summary for \(projectTitle). \(result.paragraph). Open issue: \(open)"
            }
            return "Project summary for \(projectTitle). \(result.paragraph)"
        case .unavailable(let message):
            return "Project summary for \(projectTitle). \(message)"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
