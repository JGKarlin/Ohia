import AppKit
import OhiaCore
import OhiaML
import SwiftUI

struct AnnotationMessageAttachmentLink: Identifiable, Equatable {
    let id: UUID
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let filePath: String?
    let summaryText: String?

    init(
        id: UUID,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        filePath: String?,
        summaryText: String? = nil
    ) {
        self.id = id
        self.filename = MIMEHeaderDecoder.decodeEncodedWords(filename)
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.filePath = filePath
        self.summaryText = Self.cleanSummaryText(summaryText)
    }

    static func displaySummary(
        visualSummary: String?,
        attachmentSummary: String?,
        mimeType: String,
        filename: String
    ) -> String? {
        let decodedFilename = MIMEHeaderDecoder.decodeEncodedWords(filename)
        let isImage = TimelineAttachmentKind.classify(mimeType: mimeType, fileName: decodedFilename) == .image
        let primary = isImage ? visualSummary : attachmentSummary
        let secondary = isImage ? attachmentSummary : visualSummary
        guard let source = usefulDescription(primary) ?? usefulDescription(secondary) else {
            return nil
        }
        return AttachmentReferenceText.fullDescription(of: source)
    }

    private static func usefulDescription(_ value: String?) -> String? {
        value.flatMap(AttachmentSummaryPostProcessor.clean)
    }

    private static func cleanSummaryText(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = AttachmentReferenceText.fullDescription(of: value)
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Source of truth for the chevron-revealed summary block. When supplied,
/// the popup ignores `item.summary` and renders this state instead. Used
/// by attachment annotations and related-message annotations whose
/// summaries are generated lazily on first chevron expand.
enum AnnotationSummaryDisplay: Equatable {
    case loading
    case ready(String)
    case extracting     // attachment text/vision extraction is queued or running
    case waitingForAppleIntelligence
    case unsupported    // binary attachment; nothing to summarize
    case unavailable    // generation refused / failed
}

enum AnnotationExpandedContentMode: Equatable, Sendable {
    case summary
    case message
}

enum AnnotationMessageDisplay: Equatable {
    case loading
    case ready(String)
    case unavailable
}

nonisolated private struct AnnotationMessageBodyContentGeometry: Equatable, Sendable {
    let minY: CGFloat
    let height: CGFloat
}

private struct AnnotationMessageBodyScrollView: View {
    let text: String

    @State private var viewportHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var contentMinY: CGFloat = 0
    @Environment(\.readingTextSize) private var readingTextSize

    private static let maxHeight: CGFloat = 168
    private static let scrollCoordinateSpace = "AnnotationMessageBodyScrollView.scroll"

    private var shouldDissolveBottomEdge: Bool {
        guard viewportHeight > 0 else { return false }
        return SoftBottomDissolveGeometry.shouldDissolveBottomEdge(
            contentHeight: contentHeight,
            visibleHeight: viewportHeight,
            contentMinY: contentMinY
        )
    }

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(readingTextSize.font(base: 11.5))
                .lineSpacing(readingTextSize.spacing(2))
                .foregroundStyle(OhiaColors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: AnnotationMessageBodyContentGeometry.self) { proxy in
                    let frame = proxy.frame(in: .named(Self.scrollCoordinateSpace))
                    return AnnotationMessageBodyContentGeometry(
                        minY: SoftBottomDissolveGeometry.roundedHalfPoint(frame.minY),
                        height: SoftBottomDissolveGeometry.roundedNonnegativeHalfPoint(proxy.size.height)
                    )
                } action: { geometry in
                    if abs(contentHeight - geometry.height) > 0.5 {
                        contentHeight = geometry.height
                    }
                    if abs(contentMinY - geometry.minY) > 0.5 {
                        contentMinY = geometry.minY
                    }
                }
        }
        .frame(maxHeight: Self.maxHeight)
        .coordinateSpace(.named(Self.scrollCoordinateSpace))
        .onGeometryChange(for: CGFloat.self) { proxy in
            SoftBottomDissolveGeometry.roundedNonnegativeHalfPoint(proxy.size.height)
        } action: { height in
            guard abs(viewportHeight - height) > 0.5 else { return }
            viewportHeight = height
        }
        .mask(overflowMask)
    }

    @ViewBuilder
    private var overflowMask: some View {
        if shouldDissolveBottomEdge {
            bottomDissolveMask
        } else {
            Rectangle()
                .fill(Color.black)
        }
    }

    private var bottomDissolveMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: max(0, 1 - fadeFraction)),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var fadeFraction: CGFloat {
        SoftBottomDissolveGeometry.fadeFraction(height: viewportHeight)
    }
}

nonisolated struct AnnotationPopupCallout: Equatable {
    enum Edge: Equatable {
        case top
        case trailing
        case bottom
        case leading

        var isHorizontal: Bool {
            switch self {
            case .top, .bottom:
                return true
            case .leading, .trailing:
                return false
            }
        }

        var paddingEdges: SwiftUI.Edge.Set {
            switch self {
            case .top:
                return .top
            case .trailing:
                return .trailing
            case .bottom:
                return .bottom
            case .leading:
                return .leading
            }
        }
    }

    var edge: Edge
    var anchor: CGFloat
    var baseWidth: CGFloat = 18
    var depth: CGFloat = 10

    static func bottom(anchorX: CGFloat = 0.5) -> AnnotationPopupCallout {
        AnnotationPopupCallout(edge: .bottom, anchor: anchorX)
    }

    static func pointing(
        to nodePoint: CGPoint,
        from popupCenter: CGPoint,
        popupSize: CGSize
    ) -> AnnotationPopupCallout {
        let halfWidth = max(1, popupSize.width / 2)
        let halfHeight = max(1, popupSize.height / 2)
        let dx = nodePoint.x - popupCenter.x
        let dy = nodePoint.y - popupCenter.y

        guard abs(dx) > .ulpOfOne || abs(dy) > .ulpOfOne else {
            return .bottom()
        }

        let tx = abs(dx) > .ulpOfOne ? halfWidth / abs(dx) : CGFloat.greatestFiniteMagnitude
        let ty = abs(dy) > .ulpOfOne ? halfHeight / abs(dy) : CGFloat.greatestFiniteMagnitude
        let t = min(tx, ty)

        if tx < ty {
            let intersectionY = halfHeight + dy * t
            return AnnotationPopupCallout(
                edge: dx < 0 ? .leading : .trailing,
                anchor: intersectionY / max(1, popupSize.height)
            )
        } else {
            let intersectionX = halfWidth + dx * t
            return AnnotationPopupCallout(
                edge: dy < 0 ? .top : .bottom,
                anchor: intersectionX / max(1, popupSize.width)
            )
        }
    }
}

nonisolated struct AnnotationPopupChromeShape: Shape {
    var callout: AnnotationPopupCallout?
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard let callout, callout.depth > 0, callout.baseWidth > 0 else {
            return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .path(in: rect)
        }

        let bodyRect = bodyRect(in: rect, callout: callout)
        let radius = min(cornerRadius, bodyRect.width / 2, bodyRect.height / 2)

        var path = Path()
        path.move(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY))
        addTopEdge(to: &path, bodyRect: bodyRect, rect: rect, callout: callout, radius: radius)
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.maxX, y: bodyRect.minY + radius),
            control: CGPoint(x: bodyRect.maxX, y: bodyRect.minY)
        )
        addTrailingEdge(to: &path, bodyRect: bodyRect, rect: rect, callout: callout, radius: radius)
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.maxY),
            control: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY)
        )
        addBottomEdge(to: &path, bodyRect: bodyRect, rect: rect, callout: callout, radius: radius)
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - radius),
            control: CGPoint(x: bodyRect.minX, y: bodyRect.maxY)
        )
        addLeadingEdge(to: &path, bodyRect: bodyRect, rect: rect, callout: callout, radius: radius)
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY),
            control: CGPoint(x: bodyRect.minX, y: bodyRect.minY)
        )
        path.closeSubpath()
        return path
    }

    private func bodyRect(in rect: CGRect, callout: AnnotationPopupCallout) -> CGRect {
        let depth = max(0, callout.depth)
        switch callout.edge {
        case .top:
            return CGRect(
                x: rect.minX,
                y: min(rect.maxY, rect.minY + depth),
                width: rect.width,
                height: max(0, rect.height - depth)
            )
        case .trailing:
            return CGRect(
                x: rect.minX,
                y: rect.minY,
                width: max(0, rect.width - depth),
                height: rect.height
            )
        case .bottom:
            return CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: max(0, rect.height - depth)
            )
        case .leading:
            return CGRect(
                x: min(rect.maxX, rect.minX + depth),
                y: rect.minY,
                width: max(0, rect.width - depth),
                height: rect.height
            )
        }
    }

    private func addTopEdge(
        to path: inout Path,
        bodyRect: CGRect,
        rect: CGRect,
        callout: AnnotationPopupCallout,
        radius: CGFloat
    ) {
        guard callout.edge == .top else {
            path.addLine(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.minY))
            return
        }
        let anchorX = clampedHorizontalAnchor(in: bodyRect, callout: callout, radius: radius)
        let halfBase = horizontalHalfBase(in: bodyRect, callout: callout, radius: radius)
        path.addLine(to: CGPoint(x: anchorX - halfBase, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: anchorX, y: rect.minY))
        path.addLine(to: CGPoint(x: anchorX + halfBase, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.minY))
    }

    private func addTrailingEdge(
        to path: inout Path,
        bodyRect: CGRect,
        rect: CGRect,
        callout: AnnotationPopupCallout,
        radius: CGFloat
    ) {
        guard callout.edge == .trailing else {
            path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - radius))
            return
        }
        let anchorY = clampedVerticalAnchor(in: bodyRect, callout: callout, radius: radius)
        let halfBase = verticalHalfBase(in: bodyRect, callout: callout, radius: radius)
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: anchorY - halfBase))
        path.addLine(to: CGPoint(x: rect.maxX, y: anchorY))
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: anchorY + halfBase))
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - radius))
    }

    private func addBottomEdge(
        to path: inout Path,
        bodyRect: CGRect,
        rect: CGRect,
        callout: AnnotationPopupCallout,
        radius: CGFloat
    ) {
        guard callout.edge == .bottom else {
            path.addLine(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY))
            return
        }
        let anchorX = clampedHorizontalAnchor(in: bodyRect, callout: callout, radius: radius)
        let halfBase = horizontalHalfBase(in: bodyRect, callout: callout, radius: radius)
        path.addLine(to: CGPoint(x: anchorX + halfBase, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: anchorX, y: rect.maxY))
        path.addLine(to: CGPoint(x: anchorX - halfBase, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY))
    }

    private func addLeadingEdge(
        to path: inout Path,
        bodyRect: CGRect,
        rect: CGRect,
        callout: AnnotationPopupCallout,
        radius: CGFloat
    ) {
        guard callout.edge == .leading else {
            path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + radius))
            return
        }
        let anchorY = clampedVerticalAnchor(in: bodyRect, callout: callout, radius: radius)
        let halfBase = verticalHalfBase(in: bodyRect, callout: callout, radius: radius)
        path.addLine(to: CGPoint(x: bodyRect.minX, y: anchorY + halfBase))
        path.addLine(to: CGPoint(x: rect.minX, y: anchorY))
        path.addLine(to: CGPoint(x: bodyRect.minX, y: anchorY - halfBase))
        path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + radius))
    }

    private func clampedHorizontalAnchor(
        in bodyRect: CGRect,
        callout: AnnotationPopupCallout,
        radius: CGFloat
    ) -> CGFloat {
        let halfBase = horizontalHalfBase(in: bodyRect, callout: callout, radius: radius)
        let minX = bodyRect.minX + radius + halfBase
        let maxX = bodyRect.maxX - radius - halfBase
        guard minX <= maxX else { return bodyRect.midX }
        return min(max(bodyRect.minX + bodyRect.width * callout.anchor, minX), maxX)
    }

    private func clampedVerticalAnchor(
        in bodyRect: CGRect,
        callout: AnnotationPopupCallout,
        radius: CGFloat
    ) -> CGFloat {
        let halfBase = verticalHalfBase(in: bodyRect, callout: callout, radius: radius)
        let minY = bodyRect.minY + radius + halfBase
        let maxY = bodyRect.maxY - radius - halfBase
        guard minY <= maxY else { return bodyRect.midY }
        return min(max(bodyRect.minY + bodyRect.height * callout.anchor, minY), maxY)
    }

    private func horizontalHalfBase(
        in bodyRect: CGRect,
        callout: AnnotationPopupCallout,
        radius: CGFloat
    ) -> CGFloat {
        min(callout.baseWidth / 2, max(0, bodyRect.width - 2 * radius) / 2)
    }

    private func verticalHalfBase(
        in bodyRect: CGRect,
        callout: AnnotationPopupCallout,
        radius: CGFloat
    ) -> CGFloat {
        min(callout.baseWidth / 2, max(0, bodyRect.height - 2 * radius) / 2)
    }
}

struct AnnotationPopup: View {
    let item: AnnotationItem
    let expanded: Bool
    let expandedMode: AnnotationExpandedContentMode
    let onToggleExpanded: (AnnotationExpandedContentMode) -> Void
    let onClose: () -> Void
    var onMoveBy: (CGSize) -> Void = { _ in }
    var onMoveEnded: (CGSize) -> Void = { _ in }
    /// Optional lazy-summary override. When `nil` the popup falls back to
    /// `item.summary`. When non-nil, the popup renders this enum's state
    /// directly for lazy attachment and related-message summary requests.
    var summaryDisplay: AnnotationSummaryDisplay? = nil
    /// Optional lazy body override. Used when Shift-Space / Shift-click asks
    /// a related-message pane to show the original message text instead of
    /// its generated summary.
    var messageDisplay: AnnotationMessageDisplay? = nil
    /// File attachments carried by the same message body. Rendered only when
    /// the original-message preview is expanded.
    var messageAttachments: [AnnotationMessageAttachmentLink] = []
    /// When `true`, the popup renders just its content — no gradient
    /// background, no leading accent stripe, no border, no shadow.
    /// Used by the People-lens dial wedge where the inner-arc leader
    /// and the per-kind anchor marker already carry the visual signal,
    /// and the card sits free-floating beyond the projected ring's
    /// outer edge. Default `false` preserves the meanings-lens chrome.
    var transparentChrome: Bool = false
    /// Meanings lens omits the short accent rule on the header row.
    var showsHeaderAccentRule: Bool = true
    var callout: AnnotationPopupCallout? = nil
    /// Optional viewport height supplied by hosts that place the popup in a
    /// pre-computed rect. When content is taller than this, the popup scrolls
    /// internally so long attachment summaries remain readable without
    /// tail-truncation or painting outside the scene.
    var heightLimit: CGFloat? = nil
    /// `true` while the rank-step navigator is focused on this pane. Mirrors
    /// the lock card's accent-halo treatment (`LockedEmailCard.isRankFocused`)
    /// so the currently Tab-selected neighbour pane glows in its own per-kind
    /// accent, marking where Tab landed. No effect when `transparentChrome` is
    /// set (the People-lens dial wedge carries its own selection chrome).
    var isRankFocused: Bool = false

    /// Decoded inline image preview, refreshed via `.task(id:)` whenever
    /// the attachment's file path changes. The lock overlay's body
    /// re-evaluates at frame cadence (`TimelineView` 60 Hz), so without
    /// caching, `NSImage(contentsOfFile:)` would re-read the binary up
    /// to 60 times per second while the popup is expanded.
    /// `NSImage(contentsOfFile:)` itself carries no path-keyed cache.
    @State private var cachedImage: NSImage?

    @Environment(AppServices.self) private var appServices: AppServices?
    @Environment(\.readingTextSize) private var readingTextSize
    @AppStorage("summaryOutputLanguage", store: OhiaSharedDefaults.store)
    private var summaryOutputLanguageRaw: String = ""
    @AppStorage(ModelManager.selectedTranslationEngineKey, store: OhiaSharedDefaults.store)
    private var selectedTranslationEngineRaw = TranslationEngineKind.defaultEngine.rawValue
    /// Drives the on-demand translation toggle shown when the original message
    /// text is displayed in a language other than the chosen one.
    @State private var translation = EmailTranslationModel()

    var body: some View {
        let effectiveCallout = transparentChrome ? nil : callout
        let chromeShape = AnnotationPopupChromeShape(callout: effectiveCallout, cornerRadius: 4)

        popupViewport(maxHeight: contentViewportHeightLimit(callout: effectiveCallout))
            .padding(effectiveCallout?.edge.paddingEdges ?? [], effectiveCallout?.depth ?? 0)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                if !transparentChrome {
                    LinearGradient(
                        colors: [OhiaColors.hoverReadoutGradientTop, OhiaColors.hoverReadoutGradientBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .overlay(alignment: .leading) {
                if !transparentChrome {
                    Rectangle()
                        .fill(item.kind.accent)
                        .frame(width: 2)
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
            .shadow(color: rankFocusHaloColor, radius: rankFocusHaloRadius)
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
            .onChange(of: translationConfigKey, initial: true) { _, _ in
                configureTranslation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ohiaRegenerateAnnotationTranslation)) { _ in
                regenerateTranslation()
            }
    }

    @ViewBuilder
    private func popupViewport(maxHeight: CGFloat?) -> some View {
        if let maxHeight, maxHeight > 1 {
            ScrollView(.vertical) {
                popupContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: maxHeight, alignment: .top)
        } else {
            popupContent
        }
    }

    private func contentViewportHeightLimit(callout: AnnotationPopupCallout?) -> CGFloat? {
        guard let heightLimit, heightLimit > 1 else { return nil }
        let calloutDepth: CGFloat
        if let callout, callout.edge.isHorizontal {
            calloutDepth = max(0, callout.depth)
        } else {
            calloutDepth = 0
        }
        return max(96, heightLimit - calloutDepth)
    }

    private var popupContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(OhiaColors.glassBorder)
            brief
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
    }

    private var header: some View {
        headerAccessibilityActions(
        // The whole header strip is the expand/collapse target. The chevron
        // stays as a visual affordance pointing at the action, but the user
        // doesn't have to land on its 18×18 hitbox — clicking anywhere from
        // the accent rule on the left to the gap before the close X also
        // toggles. The close X stays as its own Button so it absorbs taps
        // before they reach the parent toggle.
        //
        // Thread/reply items (which carry a `headerPrimaryDetail` like "+1")
        // drop their `detail` (date · direction) to its own line under the
        // context label so the date is always fully visible — at narrow
        // popup widths a single-line detail used to scale and then
        // ellipsize the date away. Every other kind keeps the original
        // inline single-line detail so attachment / neighbour / entity /
        // chunk popups retain their pre-existing footprint.
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 7) {
                if rendersHeaderAccentRule {
                    Rectangle()
                        .fill(item.kind.accent)
                        .frame(width: 18, height: 1)
                }
                if let directionSymbol = item.directionSymbol {
                    // Sent / received icon, rendered just before the context
                    // label so the reader sees direction at a glance — same
                    // weight and accent as the label so it reads as a paired
                    // unit rather than a separate chip.
                    Image(systemName: directionSymbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(item.kind.accent)
                        .accessibilityLabel(directionSymbol == "paperplane.fill" ? "Sent" : "Received")
                }
                Text(item.kind.contextLabel)
                    .font(OhiaTypography.telemetrySectionCaps)
                    .tracking(0.4)
                    .foregroundStyle(item.kind.accent)
                if !item.headerPrimaryDetail.isEmpty {
                    // Thread/reply surface the signed sibling position here
                    // (e.g. "+1") so the position stays adjacent to the
                    // context label even when the longer date/direction
                    // string wraps to a second line below.
                    Text(item.headerPrimaryDetail)
                        .font(OhiaTypography.attachmentRowName)
                        .foregroundStyle(OhiaColors.textSecondary)
                        .lineLimit(1)
                } else if !item.detail.isEmpty {
                    // Kinds without a primary fragment keep the original
                    // single-line behaviour — detail rides next to the
                    // label and scales down before truncating.
                    Text(item.detail)
                        .font(OhiaTypography.attachmentRowName)
                        .foregroundStyle(OhiaColors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                }
                Spacer(minLength: 4)
                // Pure visual affordance now — the parent header toggle owns
                // the click. Keeping it as a static Image (not a Button)
                // prevents nested-button hit-testing from competing with the
                // header tap gesture and produces a clean single-tap toggle.
                // Chevron now sits in the top-right corner across both
                // lenses (close X removed app-wide): the popup is
                // dismissed by clicking outside its hit-zone or by the
                // overlay chrome's own close affordance, not by an
                // inline X. The `onClose` closure is still wired into
                // the type for callers that need to dismiss
                // programmatically (Esc handler, lock release, etc.).
                Image(systemName: headerChevronSymbol)
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(OhiaColors.textSecondary)
            }
            if !item.headerPrimaryDetail.isEmpty, !item.detail.isEmpty {
                // Indent matches accent-rule width (18) + spacing (7) when
                // the rule is visible so the detail's left edge aligns under
                // the direction icon / label group above it.
                Text(item.detail)
                    .font(OhiaTypography.attachmentRowName)
                    .foregroundStyle(OhiaColors.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, rendersHeaderAccentRule ? 25 : 0)
                    .padding(.trailing, 8)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
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

    /// The short header accent rule is one of several per-kind accent
    /// affordances. `transparentChrome` already strips the pane's leading
    /// vertical accent stripe (along with its background, border, and
    /// shadow), so the horizontal rule must drop with them — otherwise it
    /// floats free of any card as a stray dash left of the direction icon
    /// (the People-lens dial wedge, whose spoke + arc + anchor marker
    /// already carry the per-kind accent). The meanings lens suppresses it
    /// explicitly via `showsHeaderAccentRule`.
    private var rendersHeaderAccentRule: Bool {
        showsHeaderAccentRule && !transparentChrome
    }

    /// Accent-halo tint for the rank-focused pane. Matches the lock card's
    /// focused-halo opacity (`LockedEmailCard`, 0.32) but tinted with this
    /// pane's own per-kind accent. Clear when the pane isn't focused or when
    /// chrome is suppressed, so unfocused panes keep only their drop shadow.
    private var rankFocusHaloColor: Color {
        guard isRankFocused, !transparentChrome else { return .clear }
        return item.kind.accent.opacity(0.32)
    }

    private var rankFocusHaloRadius: CGFloat {
        (isRankFocused && !transparentChrome) ? 36 : 0
    }

    private var popupAccessibilityLabel: String {
        if expanded, expandedMode == .message {
            return "\(item.kind.contextLabel). Message"
        }
        return "\(item.kind.contextLabel). \(item.briefText)"
    }

    @ViewBuilder
    private func headerAccessibilityActions<Content: View>(_ content: Content) -> some View {
        let primary = content
            .accessibilityAction {
                onToggleExpanded(nextHeaderToggleMode)
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
        return Self.headerToggleMode(
            expanded: expanded,
            expandedMode: expandedMode,
            canShowMessage: item.anchorMessageId != nil,
            shiftPressed: flags?.contains(.shift) == true
        )
    }

    private var nextHeaderToggleMode: AnnotationExpandedContentMode {
        Self.headerToggleMode(
            expanded: expanded,
            expandedMode: expandedMode,
            canShowMessage: item.anchorMessageId != nil,
            shiftPressed: false
        )
    }

    static func headerToggleMode(
        expanded: Bool,
        expandedMode: AnnotationExpandedContentMode,
        canShowMessage: Bool,
        shiftPressed: Bool
    ) -> AnnotationExpandedContentMode {
        guard canShowMessage else { return .summary }
        if shiftPressed { return .message }
        guard expanded else { return .summary }
        switch expandedMode {
        case .summary:
            return .message
        case .message:
            return .message
        }
    }

    /// Disclosure glyph for the three-tier header cycle
    /// (compact → summary → full message → compact). The chevron is a pure
    /// indicator — the header strip owns the tap — so it only reflects the
    /// current depth: compact points right ("expand"), summary points down
    /// ("more below"), and the deepest full-message tier points up ("tap to
    /// collapse back to compact"). Items without an anchor message never reach
    /// `.message`, so they stay a simple right ⇄ down binary.
    private var headerChevronSymbol: String {
        Self.headerChevronSymbol(expanded: expanded, expandedMode: expandedMode)
    }

    static func headerChevronSymbol(
        expanded: Bool,
        expandedMode: AnnotationExpandedContentMode
    ) -> String {
        guard expanded else { return "chevron.right" }
        switch expandedMode {
        case .summary:
            return "chevron.down"
        case .message:
            return "chevron.up"
        }
    }

    private var headerHelpText: String {
        guard item.anchorMessageId != nil else {
            return expanded ? "Collapse annotation" : "Expand annotation"
        }
        guard expanded else { return "Show summary" }
        switch expandedMode {
        case .summary:
            return "Show message"
        case .message:
            return "Collapse annotation"
        }
    }

    private var headerAccessibilityLabel: String {
        guard item.anchorMessageId != nil else {
            return expanded
                ? "Collapse \(item.kind.contextLabel) details"
                : "Expand \(item.kind.contextLabel) details"
        }
        guard expanded else {
            return "Show \(item.kind.contextLabel) summary"
        }
        switch expandedMode {
        case .summary:
            return "Show \(item.kind.contextLabel) message"
        case .message:
            return "Collapse \(item.kind.contextLabel) message"
        }
    }

    private var headerMessageAccessibilityActionLabel: String {
        expanded && expandedMode == .message ? "Collapse message" : "Show message"
    }

    private var brief: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Body chunks have no separate title (per spec §8.1) — the quoted chunk text
            // *is* the brief. Hide the title row entirely when the kind doesn't supply one
            // so we don't render an empty leading line.
            if !item.title.isEmpty {
                Text(item.title)
                    .font(readingTextSize.font(base: 12, weight: .semibold, maximumScale: 1.35))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if shouldShowImageDescriptionLoader {
                briefLoadingPlaceholder
            } else if !item.briefText.isEmpty {
                Text(item.briefText)
                    .font(readingTextSize.font(base: 11.5).italic())
                    .lineSpacing(readingTextSize.spacing(1.5))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(item.kind.accent.opacity(0.65))
                            .frame(width: 1)
                    }
            }
            if !item.contextReason.isEmpty {
                Text(item.contextReason)
                    .font(readingTextSize.font(base: 10.5))
                    .foregroundStyle(item.kind.accent.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
        }
    }

    private var shouldShowImageDescriptionLoader: Bool {
        guard expanded,
              let attachmentRef = item.attachmentReference,
              attachmentRef.isImage else {
            return false
        }
        return summaryDisplay == .extracting || summaryDisplay == .loading
    }

    private var briefLoadingPlaceholder: some View {
        SummaryLoadingPlaceholderView(contentWidth: 232, slotHeight: 24)
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(item.kind.accent.opacity(0.65))
                    .frame(width: 1)
            }
    }

    private var extras: some View {
        VStack(alignment: .leading, spacing: 6) {
            if expandedMode == .message, item.anchorMessageId != nil {
                messageSection
            } else {
                // Image attachments swap the lazy-summary block for an inline
                // preview of the image itself — the visual-summary paragraph
                // already lives in `briefText` (rendered above the chevron),
                // so the expanded pane is for actually seeing the picture.
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

    /// Image-load key. Couples cache invalidation to the attachment's
    /// file path (and image-ness) so `.task(id:)` reloads exactly when
    /// the popup swaps to a different attachment and stays idle while
    /// the same attachment is on screen.
    private var imageLoadKey: String? {
        guard let attachmentRef = item.attachmentReference,
              attachmentRef.isImage,
              let path = attachmentRef.filePath,
              !path.isEmpty else {
            return nil
        }
        return path
    }

    /// Bottom-of-pane file link mirroring the FILES rows in
    /// `LockedAttachmentsList`/`SurveyTelemetryStrip`: filename in
    /// `accentOrange` underlined as a link, byte-formatted size on the
    /// trailing edge, click opens the file in its default app, and a
    /// right-click context menu offers Reveal in Finder.
    private func fileLinkFooter(
        attachment: AnnotationItem.AttachmentReference,
        filePath: String
    ) -> some View {
        let url = URL(fileURLWithPath: filePath)
        let canOpen = FileManager.default.fileExists(atPath: filePath)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(OhiaColors.textSecondary)
            Button {
                guard canOpen else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Text(attachment.filename)
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
                    Button("Open") { NSWorkspace.shared.open(url) }
                    Button("Reveal in Finder") {
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

    /// Routes to the lazy-summary state when one is provided (attachments),
    /// otherwise falls back to the cached `item.summary` string used by
    /// neighbours and thread siblings.
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
        VStack(alignment: .leading, spacing: 3) {
            summaryHeader
            Text(text)
                .font(readingTextSize.font(base: 11.5))
                .lineSpacing(readingTextSize.spacing(2))
                .foregroundStyle(OhiaColors.textPrimary)
                .lineLimit(nil)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryUnavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            summaryHeader
            Text(message)
                .font(readingTextSize.font(base: 11).italic())
                .foregroundStyle(OhiaColors.textTertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var messageSection: some View {
        switch messageDisplay {
        case .loading:
            messageHeader
            SummaryLoadingPlaceholderView(contentWidth: 264)
                .padding(.top, 1)
        case .ready(let text):
            messageParagraph(text, attachments: messageAttachments)
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

    private func messageParagraph(
        _ text: String,
        attachments: [AnnotationMessageAttachmentLink]
    ) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                messageHeader
                Spacer(minLength: 0)
                if translation.canOffer {
                    translateIconToggle
                }
            }
            if translation.isTranslating {
                SummaryLoadingPlaceholderView(contentWidth: 264)
                    .padding(.top, 1)
            } else if let translated = translation.translatedText, translation.isShowingTranslation {
                AnnotationMessageBodyScrollView(text: translated)
            } else if !trimmed.isEmpty {
                AnnotationMessageBodyScrollView(text: text)
            }
            if !attachments.isEmpty {
                messageAttachmentLinks(attachments)
            }
        }
        .translationLanguageDownload(translation, service: appServices?.translationService)
    }

    /// Icon-only translation toggle for the original-message view. First tap
    /// generates the translation (into the chosen summary/translation language);
    /// subsequent taps flip between original and translation. Tinted active
    /// while the translation is the visible side.
    private var translateIconToggle: some View {
        Button {
            if translation.canDownloadLanguages {
                translation.requestLanguageDownload()
            } else if translation.translatedText != nil {
                translation.toggle()
            } else {
                startTranslation()
            }
        } label: {
            Image(systemName: translateIconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(translateIconTint)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(translateHelpText)
        .accessibilityLabel(translateAccessibilityLabel)
    }

    private var translateIconName: String {
        if translation.canDownloadLanguages { return "arrow.down.circle" }
        return translation.failureMessage == nil ? "translate" : "exclamationmark.triangle.fill"
    }

    private var isShowingTranslationNow: Bool {
        translation.translatedText != nil && translation.isShowingTranslation
    }

    /// Active accent while the translation is the visible side, a warning accent
    /// when the last attempt failed (so the icon isn't indistinguishable from
    /// "untranslated"), and the resting secondary otherwise.
    private var translateIconTint: Color {
        if translation.canDownloadLanguages { return OhiaColors.chipActiveForeground }
        if translation.failureMessage != nil { return OhiaColors.accentOrange }
        return isShowingTranslationNow ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary
    }

    private var translateHelpText: String {
        if let message = translation.needsDownloadMessage {
            return "\(message.prefix(1).uppercased() + message.dropFirst()) Click to download the on-device languages."
        }
        if let message = translation.failureMessage {
            return "Translation failed: \(message). Click to retry."
        }
        if translation.translatedText == nil {
            return "Translate into \(translation.targetLanguageAutonym)"
        }
        return translation.isShowingTranslation
            ? "Show original"
            : "Show \(translation.targetLanguageAutonym) translation"
    }

    private var translateAccessibilityLabel: String {
        if translation.canDownloadLanguages {
            return "Download translation languages for \(translation.targetLanguageAutonym)"
        }
        if translation.failureMessage != nil {
            return "Translation failed. Retry."
        }
        if translation.translatedText == nil {
            return "Translate message into \(translation.targetLanguageAutonym)"
        }
        return translation.isShowingTranslation ? "Show original message" : "Show translated message"
    }

    private func startTranslation() {
        guard let service = appServices?.translationService else { return }
        translation.translate(using: service)
    }

    private func regenerateTranslation() {
        guard expanded,
              expandedMode == .message,
              let service = appServices?.translationService else { return }
        translation.regenerate(using: service)
    }

    /// Reads the ready original-message text, if the popup currently has one.
    private var readyMessageText: String? {
        if case .ready(let text) = messageDisplay { return text }
        return nil
    }

    /// Re-evaluates the translate offer when the popup switches messages, the
    /// message text resolves, the chosen language changes, or the message view
    /// is opened/closed.
    private var translationConfigKey: String {
        let id = item.anchorMessageId ?? "none"
        let textLength = readyMessageText?.count ?? 0
        let showingMessage = expanded && expandedMode == .message
        return "\(id)|\(summaryOutputLanguageRaw)|\(selectedTranslationEngineRaw)|\(textLength)|\(showingMessage)"
    }

    private func configureTranslation() {
        guard expanded,
              expandedMode == .message,
              let id = item.anchorMessageId,
              let uuid = UUID(uuidString: id),
              let text = readyMessageText else {
            return
        }
        translation.configure(
            messageID: uuid,
            bodyText: text,
            targetLanguage: SummarizationTargetLanguage.ohiaPreferred()
        )
    }

    private func messageAttachmentLinks(_ attachments: [AnnotationMessageAttachmentLink]) -> some View {
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "paperclip")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(item.kind.accent)
                Text("FILES")
                    .font(OhiaTypography.telemetrySectionCaps)
                    .tracking(0.7)
                    .foregroundStyle(item.kind.accent)
                Text("\(attachments.count)")
                    .font(OhiaTypography.attachmentRowMeta)
                    .foregroundStyle(OhiaColors.textTertiary)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(attachments) { attachment in
                    messageAttachmentRow(attachment)
                }
            }
        }
        .padding(.top, 2)
    }

    private func messageAttachmentRow(_ attachment: AnnotationMessageAttachmentLink) -> some View {
        let canOpen = attachment.filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let url = attachment.filePath.map { URL(fileURLWithPath: $0) }
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: attachmentIconName(for: attachment))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(canOpen ? item.kind.accent : OhiaColors.textTertiary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        guard canOpen, let url else { return }
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text(attachment.filename)
                            .font(OhiaTypography.attachmentRowName)
                            .foregroundStyle(canOpen ? item.kind.accent : OhiaColors.textTertiary)
                            .underline(canOpen, color: item.kind.accent.opacity(0.4))
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                        if canOpen, let url {
                            Button("Open") { NSWorkspace.shared.open(url) }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    }

                    Text(Self.byteFormatter.string(fromByteCount: Int64(max(0, attachment.sizeBytes))))
                        .font(OhiaTypography.attachmentRowMeta)
                        .foregroundStyle(OhiaColors.textTertiary)
                        .lineLimit(1)
                        .padding(.top, 1)
                }

                if let summaryText = attachment.summaryText {
                    Text(summaryText)
                        .font(readingTextSize.font(base: 12.5))
                        .lineSpacing(readingTextSize.spacing(2))
                        .foregroundStyle(OhiaColors.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func attachmentIconName(for attachment: AnnotationMessageAttachmentLink) -> String {
        let mime = attachment.mimeType.lowercased()
        let ext = (attachment.filename as NSString).pathExtension.lowercased()
        if mime.hasPrefix("image/") { return "photo" }
        if mime == "application/pdf" || ext == "pdf" { return "doc.richtext" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "film" }
        if ["zip", "tar", "gz", "bz2", "7z", "rar", "xz"].contains(ext) { return "archivebox" }
        return "doc"
    }

    private func messageUnavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            messageHeader
            Text(message)
                .font(readingTextSize.font(base: 11).italic())
                .foregroundStyle(OhiaColors.textTertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
