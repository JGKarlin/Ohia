import SwiftUI
import Foundation
import OhiaCore
import OhiaML

struct SurveyTelemetryStrip: View {
    let telemetry: SurveyTelemetry
    var orientation: LockOrientationDisplayState = .pending
    var attachments: [LockedAttachmentSummary] = []
    var size: CGSize = LockedNodeOverlayMetrics.telemetrySize
    /// The frame the user is currently reading the constellation through.
    /// Drives the section heading and the leading summary line so the strip
    /// answers the frame's question without changing pane structure or
    /// placement. Defaults to `.defaultFrame` so test fixtures and preview
    /// call sites keep compiling unchanged.
    var activeFrame: FrameKey = .defaultFrame
    /// Pane index (chip strip + caption). `nil` when no panes
    /// are loaded — the strip omits the section entirely so an empty
    /// neighbourhood doesn't carry empty chrome.
    var panesIndex: LockedPanesIndexData? = nil
    /// Currently rank-focused pane's global index, or `nil` when idle.
    /// Drives chip highlight inside `LockedPanesIndex`.
    var focusedGlobalIndex: Int? = nil
    /// Per-account accent the locked email's focal chrome should use
    /// (chip for the `.mainEmail` group). When `nil`,
    /// `LockedPanesIndex` falls back to `AnnotationKind.mainEmail.accent`
    /// — the historical pink. Threaded through from `LockedNodeOverlay`'s
    /// `lockAccentColor`.
    var lockAccent: Color? = nil
    /// Frame-specific subject identity shown directly below the section
    /// heading. Currently populated for the People frame so the
    /// CORRESPONDENT pane names the person before showing reciprocity.
    var correspondentIdentityLine: String? = nil
    /// People-lens ring band colors keyed by `PersonRingInstance.Tier.insideOutIndex`
    /// (order: `receivedDirect`, `included`, `sentDirect`, `sentIncluded`).
    /// Forwarded into `LockedPanesIndex` so the People-tier chips colour-
    /// match the Saturn ring bands one-to-one, letting the user read the
    /// chip strip as a legend for the rings around the hub planet.
    var peopleRingTierColors: [Color] = []
    var onCitationSelected: (ContextOrientationCitation) -> Void = { _ in }
    /// Resolves a citation's `targetID` to the matching annotation pane
    /// (or `nil` for citations that map onto the main email rather than
    /// an annotation). The strip uses the looked-up pane's kind to tint
    /// and symbol-stamp the inline `[N]` chip so each citation matches
    /// the colour of the pane it leads to.
    var annotationLookup: (String) -> AnnotationItem? = { _ in nil }
    /// Receive date of the locked email itself. Used to render each
    /// citation's `Date:` line as `<absolute> · <relative-to-anchor>`,
    /// so the reader can see how much earlier or later the cited
    /// message landed relative to the one they're inspecting.
    var anchorReceivedAt: Date? = nil
    var onContentSizeChange: (CGSize) -> Void = { _ in }
    var onMoveBy: (CGSize) -> Void = { _ in }
    var onMoveEnded: (CGSize) -> Void = { _ in }
    /// Cycle to the next pane within the chosen kind. Wired to chip taps.
    var onChipClick: (AnnotationKind) -> Void = { _ in }
    /// Whether the trailing help/legend disc renders in the section title row.
    /// People focus and Meaning lock/focus suppress it (`false`) because the
    /// lock-overlay shortcut legend moves into the vertical action rail; other
    /// locked surfaces keep it here.
    var showsLegendButton: Bool = true

    /// Drives the popover for the lock-overlay shortcut legend. Local to
    /// this strip so the chrome can host the help icon without the
    /// overlay needing to plumb a binding through.
    @State private var legendPresented: Bool = false
    @Environment(\.readingTextSize) private var readingTextSize
    @AppStorage(LensLegendVisibilityPreference.storageKey)
    private var legendsVisible = LensLegendVisibilityPreference.defaultValue

    /// Width of the placeholder animation so it sits inside the pane padding
    /// without clipping. Pane has 12pt of horizontal padding on each side.
    private var placeholderWidth: CGFloat {
        max(120, size.width - 24)
    }

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .scrollIndicators(.automatic)
        .frame(
            width: size.width,
            height: size.height,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            OhiaColors.hoverReadoutGradientTop,
                            OhiaColors.hoverReadoutGradientBottom
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title row: section label on the leading edge, help affordance
            // on the trailing edge. The help icon mirrors the constellation
            // top-bar legend button (38pt disc, surface fill, chipActiveBorder
            // ring, questionmark.circle.fill) but its popover content is
            // scoped to the lock-overlay's keyboard / pointer affordances.
            titleRow

            if let correspondentIdentityLine {
                Text(correspondentIdentityLine)
                    .font(readingTextSize.font(base: 12, weight: .semibold, maximumScale: 1.35))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.85)
            }

            if let panesIndex {
                LockedPanesIndex(
                    data: panesIndex,
                    focusedGlobalIndex: focusedGlobalIndex,
                    mainEmailAccentOverride: lockAccent,
                    showsCaption: true,
                    peopleRingTierColors: peopleRingTierColors,
                    onChipClick: onChipClick
                )
            }

            divider

            orientationSection

            divider

            if let threads = telemetry.threadsValueLabel {
                telemetryRow("threads", threads)
            }
            telemetryRow(telemetry.threadReportRowLabel, telemetry.threadReportValueLabel)
            if let range = telemetry.periodRangeValueLabel {
                telemetryRow("range", range)
            } else {
                if let started = telemetry.periodStartValueLabel {
                    telemetryRow("started", started)
                } else if let started = telemetry.threadStartedValueLabel {
                    telemetryRow("started", started)
                }
                if let ended = telemetry.periodEndValueLabel {
                    telemetryRow("ended", ended)
                } else if let lastReply = telemetry.threadLastReplyValueLabel {
                    telemetryRow("last reply", lastReply)
                }
            }
            if !attachments.isEmpty {
                divider
                LockedAttachmentsList(
                    attachments: attachments,
                    presentation: attachmentListPresentation
                )
            }
        }
        .padding(12)
        .frame(
            width: size.width,
            alignment: .leading
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SurveyTelemetryContentSizePreferenceKey.self,
                    value: proxy.size
                )
            }
        )
        .onPreferenceChange(SurveyTelemetryContentSizePreferenceKey.self) { size in
            onContentSizeChange(size)
        }
    }

    /// Circular help affordance — same chrome as the constellation
    /// top-bar legend (38pt disc, surface fill, `chipActiveBorder` ring,
    /// `questionmark.circle.fill` glyph) — popping to a lock-overlay
    /// specific shortcut guide so the user can learn Tab / space / Esc
    /// and the chip / drag affordances without leaving the lock.
    private var legendButton: some View {
        Button {
            legendPresented.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(OhiaColors.surface(0.10))
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OhiaColors.chipActiveBorder.opacity(0.42))
            }
            .frame(width: 28, height: 28)
            .overlay {
                Circle()
                    .strokeBorder(OhiaColors.chipActiveBorder.opacity(0.38), lineWidth: 1)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Locked node shortcuts")
        .accessibilityLabel("Locked node shortcuts")
        .popover(isPresented: $legendPresented, arrowEdge: .top) {
            LockedNodeOverlayLegendView()
                .frame(width: 440)
        }
    }

    @ViewBuilder
    private var orientationSection: some View {
        switch orientation {
        case .pending, .loading:
            SummaryLoadingPlaceholderView(contentWidth: placeholderWidth)
                .padding(.top, 2)
        case .loaded(let result):
            InlineCitationParagraph(
                paragraph: result.paragraph,
                sources: contextInlineSources(
                    citations: result.citations,
                    annotationLookup: annotationLookup,
                    anchorReceivedAt: anchorReceivedAt,
                    mainEmailAccent: lockAccent,
                    onCitationSelected: onCitationSelected
                ),
                font: readingTextSize.font(base: 12),
                lineSpacing: readingTextSize.spacing(2)
            )
            .textSelection(.enabled)
        case .failed:
            Text("orientation unavailable")
                .font(readingTextSize.font(base: 11).italic())
                .foregroundStyle(OhiaColors.textTertiary)
        case .unavailable:
            Text("no nearby items to orient against")
                .font(readingTextSize.font(base: 11).italic())
                .foregroundStyle(OhiaColors.textTertiary)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(sectionHeading)
                .font(OhiaTypography.telemetrySectionCaps)
                .tracking(1.0)
                .foregroundStyle(OhiaColors.chipActiveForeground)
            Spacer(minLength: 4)
            if LensLegendVisibilityPreference.showsLegend(
                requestedBySurface: showsLegendButton,
                legendsVisible: legendsVisible
            ) {
                legendButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { onMoveBy($0.translation) }
                .onEnded { onMoveEnded($0.translation) }
        )
    }

    private func telemetryRow(_ label: String, _ value: String, warn: Bool = false) -> some View {
        Group {
            if isMeaningLens {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label)
                        .font(OhiaTypography.telemetryLabel)
                        .foregroundStyle(OhiaColors.textTertiary)
                        .lineLimit(1)
                    Text(value)
                        .font(OhiaTypography.telemetryValue)
                        .foregroundStyle(warn ? OhiaColors.accentOrange : OhiaColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(label)
                        .font(OhiaTypography.telemetryLabel)
                        .foregroundStyle(OhiaColors.textTertiary)
                        .frame(width: 72, alignment: .trailing)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.8)
                    Text(value)
                        .font(OhiaTypography.telemetryValue)
                        .foregroundStyle(warn ? OhiaColors.accentOrange : OhiaColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(OhiaColors.glassBorder)
            .frame(height: 1)
            .padding(.vertical, 1)
    }

    private var sectionHeading: String {
        SurveyTelemetryFraming.sectionHeading(for: activeFrame)
    }

    private var isPeopleLens: Bool {
        activeFrame.spatialLens == .people
    }

    private var isMeaningLens: Bool {
        activeFrame.spatialLens == .meaning
    }

    private var attachmentListPresentation: LockedAttachmentsList.Presentation {
        Self.attachmentPresentation(for: activeFrame)
    }

    static func attachmentPresentation(for activeFrame: FrameKey) -> LockedAttachmentsList.Presentation {
        switch activeFrame.spatialLens {
        case .people, .meaning:
            return .contextSummary
        default:
            return .telemetry
        }
    }

}

/// Maps the structural `ContextOrientationCitation` list (which arrives in
/// the same rank order the orientation prompt used) onto the surface-
/// agnostic `InlineCitationSource` list the inline renderer consumes. The
/// chip's tint and SF Symbol come from `SourceKind`; the popover surfaces
/// the citation's own title/excerpt; the click action passes the original
/// citation back to the overlay so the existing annotation-pane plumbing
/// keeps working.
private func contextInlineSources(
    citations: [ContextOrientationCitation],
    annotationLookup: @escaping (String) -> AnnotationItem?,
    anchorReceivedAt: Date?,
    mainEmailAccent: Color?,
    onCitationSelected: @escaping (ContextOrientationCitation) -> Void
) -> [InlineCitationSource] {
    citations.enumerated().map { index, citation in
        let resolvedKind = resolveCitationKind(citation: citation, annotationLookup: annotationLookup)
        // For `.mainEmail` (ownChunk citations pointing back at the
        // locked email), use the per-account focal accent threaded
        // from the host — otherwise the inline `[N]` chip would render
        // in the static pink fallback while the rest of the focal-
        // message chrome carries the account hue.
        let tint: Color = (resolvedKind == .mainEmail || resolvedKind == .correspondent)
            ? (mainEmailAccent ?? resolvedKind.accent)
            : resolvedKind.accent
        return InlineCitationSource(
            index: index + 1,
            symbolName: resolvedKind.symbolName,
            tint: tint,
            kindLabel: resolvedKind.contextLabel,
            titleLine: citation.title.isEmpty ? nil : citation.title,
            excerptLine: citation.excerpt.isEmpty ? nil : citation.excerpt,
            fromLine: citation.senderDisplay,
            toLine: citation.recipientsDisplay,
            subjectLine: citation.subjectDisplay ?? (citation.kind == .memory ? citation.detail : nil),
            dateLine: contextSourceDateLine(
                receivedAt: citation.receivedAt,
                anchorReceivedAt: anchorReceivedAt
            ),
            onClick: { onCitationSelected(citation) },
            onHover: { _ in }
        )
    }
}

/// Formats a citation's `Date:` line as `<absolute date> · <relative tail>`.
/// The relative tail describes how far in time the citation sits from the
/// locked email — e.g. "3 days earlier", "11 days later", "same day". Nil
/// when the citation has no date at all (the popover then omits the row
/// rather than printing an empty `Date:` label).
private func contextSourceDateLine(receivedAt: Date?, anchorReceivedAt: Date?) -> String? {
    guard let receivedAt else { return nil }
    let absolute = contextSourceDateFormatter.string(from: receivedAt)
    guard let anchorReceivedAt else { return absolute }
    let calendar = Calendar.current
    let delta = calendar.dateComponents([.day], from: anchorReceivedAt, to: receivedAt).day ?? 0
    let relative: String
    switch delta {
    case 0: relative = "same day"
    case 1: relative = "1 day later"
    case -1: relative = "1 day earlier"
    case 2...: relative = "\(delta) days later"
    case ...(-2): relative = "\(-delta) days earlier"
    default: relative = ""
    }
    return relative.isEmpty ? absolute : "\(absolute) · \(relative)"
}

private let contextSourceDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
}()

/// Resolves a citation to the `AnnotationKind` of the pane it leads to —
/// the chip then borrows that pane's accent + SF Symbol so colour and
/// glyph match the locked-overlay chip strip exactly. When the citation
/// can't be resolved (e.g. a related item that fell outside the visible
/// pane budget) we fall back to a kind-of-best-guess so the chip still
/// reads honestly rather than going to a default colour.
private func resolveCitationKind(
    citation: ContextOrientationCitation,
    annotationLookup: (String) -> AnnotationItem?
) -> AnnotationKind {
    if citation.kind == .ownChunk {
        return .mainEmail
    }
    if let targetID = citation.targetID, let item = annotationLookup(targetID) {
        return item.kind
    }
    switch citation.kind {
    case .timeline: return .thread
    case .memory: return .correspondent
    case .ownChunk: return .mainEmail
    case .threadSibling: return .thread
    case .relatedItem: return .threadRelative
    case .attachment: return .attachment
    }
}

private struct SurveyTelemetryContentSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        guard next.width > 1, next.height > 1 else { return }
        value = next
    }
}
