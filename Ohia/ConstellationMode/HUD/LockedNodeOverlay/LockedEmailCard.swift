import AppKit
import SwiftUI
import OhiaCore
import OhiaML

struct LockedEmailCard: View {
    let content: LockedEmailCardContent
    var attachments: [LockedAttachmentSummary] = []
    /// Width of the card. The overlay owns this so the user can resize live via the
    /// bottom-right corner handle and the dashed leader stays anchored to the right edge.
    let width: CGFloat
    /// Manual height. `nil` means "size to content" (header + body + footer); a value
    /// switches the body region into a fixed-height scroll region so the user can shorten
    /// or lengthen the card explicitly.
    let manualHeight: CGFloat?
    /// Maximum total card height in automatic sizing mode. The overlay derives this
    /// from the live scene height so long bodies scroll inside the card instead of
    /// letting the card paint beyond the viewport.
    let maxAutomaticHeight: CGFloat
    /// Cap for the body region when the card is content-sized (`manualHeight == nil`).
    /// Computed by the overlay from the live scene size so long emails grow to fill the
    /// available room before falling back to scrolling.
    let maxBodyHeight: CGFloat
    /// Opens the shared message context menu for whichever message the card is
    /// currently displaying (the locked center or a People-ring selection).
    let onPresentMessageContextMenu: (String, NSPoint, NSView) -> Void
    let onRelease: () -> Void
    /// Drag-the-card-around handle. Attached to the header strip so clicks elsewhere in
    /// the card (text selection, link tracking) stay intact.
    let onMoveBy: (CGSize) -> Void
    let onMoveEnded: (CGSize) -> Void
    /// Bottom-right corner handle. Width grows with horizontal translation; vertical
    /// translation pins the card height (switching from auto-size to manual).
    let onResizeBy: (CGSize) -> Void
    let onResizeEnded: (CGSize) -> Void
    let onChromeHeightChange: (CGFloat) -> Void
    let accentColor: Color
    /// `true` while the rank-step navigator is focused on the main email
    /// pane. Drives a subtle accent halo on the card so the user sees
    /// where Tab landed.
    var isRankFocused: Bool = false
    /// Body-collapsed state, owned by the parent overlay so it can also
    /// be flipped by the rank-step expansion toggle (space key when the
    /// main email pane is focused). The header's chevron and the
    /// keyboard shortcut both write to this binding, so they stay in
    /// sync.
    @Binding var bodyCollapsed: Bool
    /// Forwarded to the header's classification pulldown so the parent can
    /// persist the shared purpose plus independent custom-category keys.
    let onClassificationChanged: (MailClassification?, Set<String>) -> Void
    /// Live custom-category catalog forwarded to the header's picker rows
    /// and chip strip.
    var customCategoryCatalog: [CustomMailCategoryDescriptor] = []
    /// Pass-through to the header's sender-row context menu so the parent
    /// overlay can persist the pin to SwiftData.
    let isSenderPinned: Bool
    let onToggleSenderPinned: () -> Void
    /// Meanings lens uses the scene-corner release control instead.
    var showsHeaderReleaseButton: Bool = true
    /// Meanings lens omits the short accent rule preceding the direction pill.
    var showsHeaderAccentRule: Bool = true

    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    @Environment(AppServices.self) private var appServices: AppServices?
    /// The single language used for both summaries and on-demand translation;
    /// read here so the translate affordance re-evaluates when the user changes
    /// it in Language Settings.
    @AppStorage("summaryOutputLanguage", store: OhiaSharedDefaults.store)
    private var summaryOutputLanguageRaw: String = ""
    @AppStorage(ModelManager.selectedTranslationEngineKey, store: OhiaSharedDefaults.store)
    private var selectedTranslationEngineRaw = TranslationEngineKind.defaultEngine.rawValue
    @State private var translation = EmailTranslationModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LockedEmailCardHeader(
                content: content,
                collapsed: bodyCollapsed,
                onToggleCollapse: { bodyCollapsed.toggle() },
                onRelease: onRelease,
                showsReleaseButton: showsHeaderReleaseButton,
                showsHeaderAccentRule: showsHeaderAccentRule,
                onClassificationChanged: onClassificationChanged,
                customCategoryCatalog: customCategoryCatalog,
                isSenderPinned: isSenderPinned,
                onToggleSenderPinned: onToggleSenderPinned,
                translation: translation,
                onTranslate: startTranslation
            )
            // Drag-to-move only fires when the gesture starts on header chrome that
            // isn't a button. The Image-only buttons inside the header own their own
            // hit areas, so dragging outside those circles slides the card.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { onMoveBy($0.translation) }
                    .onEnded { onMoveEnded($0.translation) }
            )
            .background(sectionHeightReader(key: LockedEmailCardHeaderHeightPreferenceKey.self))
            Divider().background(OhiaColors.glassBorder)
            if bodyCollapsed {
                LockedEmailCardSummary(summary: content.displaySummary)
            } else {
                messagePane
            }
            Divider().background(OhiaColors.glassBorder)
            LockedEmailCardFooter(onRelease: onRelease)
                .background(sectionHeightReader(key: LockedEmailCardFooterHeightPreferenceKey.self))
        }
        .frame(width: width)
        // Height is content-driven by default so short messages don't carry an empty
        // bottom region. Once the user grabs the corner handle, `manualHeight` flips
        // the card to a fixed total height (and the body scrolls inside it).
        .frame(height: bodyCollapsed ? nil : effectiveManualHeight, alignment: .top)
        .frame(maxHeight: cardHeightLimit, alignment: .top)
        // A flexible maximum-height frame accepts the scene's full proposal.
        // Reassert the collapsed card's ideal height outside that frame so the
        // summary state contracts to header + summary + footer. Expanded cards
        // keep the viewport cap and any user-selected manual height.
        .fixedSize(horizontal: false, vertical: bodyCollapsed)
        .background(cardBackground)
        .overlay { cardBorder }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accentColor.opacity(0.92))
                .frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            LockedCardResizeHandle()
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { onResizeBy($0.translation) }
                        .onEnded { onResizeEnded($0.translation) }
                )
                .accessibilityLabel("Resize locked email card")
        }
        .shadow(color: .black.opacity(0.60), radius: 18, x: 0, y: 18)
        .shadow(color: accentColor.opacity(isRankFocused ? 0.32 : 0.08), radius: isRankFocused ? 36 : 30)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Locked email \(content.displaySubject)")
        .onPreferenceChange(LockedEmailCardHeaderHeightPreferenceKey.self) { height in
            headerHeight = height
            publishChromeHeight()
        }
        .onPreferenceChange(LockedEmailCardFooterHeightPreferenceKey.self) { height in
            footerHeight = height
            publishChromeHeight()
        }
        .onAppear(perform: publishChromeHeight)
        .onChange(of: translationConfigKey, initial: true) { _, _ in
            configureTranslation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaRegenerateLockedEmailTranslation)) { _ in
            regenerateTranslation()
        }
        .translationLanguageDownload(translation, service: appServices?.translationService)
    }

    // MARK: - Translation

    /// Re-runs whenever the locked message, its loaded body length, or the
    /// chosen language changes — the inputs that decide whether to offer a
    /// translation and what to translate.
    private var translationConfigKey: String {
        var bodyKey = "pending"
        if case .loaded(let body) = content.bodyState {
            bodyKey = "loaded:\(body.plainText.count)"
        }
        return "\(content.messageId)|\(summaryOutputLanguageRaw)|\(selectedTranslationEngineRaw)|\(bodyKey)"
    }

    private func configureTranslation() {
        // Only (re)configure once the body is loaded; while it is loading we
        // keep the prior state rather than flicker the control off. An empty
        // loaded body configures to "no offer", which also resets any stale
        // offer carried over from a previously locked message.
        guard let uuid = UUID(uuidString: content.messageId),
              case .loaded(let body) = content.bodyState else {
            return
        }
        translation.configure(
            messageID: uuid,
            bodyText: body.plainText,
            targetLanguage: SummarizationTargetLanguage.ohiaPreferred()
        )
    }

    private func startTranslation() {
        guard let service = appServices?.translationService else { return }
        translation.translate(using: service)
    }

    private func regenerateTranslation() {
        guard !bodyCollapsed,
              let service = appServices?.translationService else { return }
        translation.regenerate(using: service)
    }

    @ViewBuilder
    private var messagePane: some View {
        switch LockedEmailCardLayoutMetrics.messagePaneKind(attachmentCount: attachments.count) {
        case .bodyOnly:
            standaloneMessageBody
                .background(messageContextMenuCatcher)
        case .bodyWithAttachments:
            ViewThatFits(in: .vertical) {
                unifiedMessageContent
                ScrollView {
                    unifiedMessageContent
                }
            }
            .frame(maxHeight: max(1, bodyHeightLimit), alignment: .top)
        }
    }

    @ViewBuilder
    private var standaloneMessageBody: some View {
        // The lock card's job is the full email body. The hover popup already
        // surfaces `bodySummary`, so we don't repeat it here. When a translation
        // is showing, the body region renders it in place (a toggle, not a
        // second column).
        if translation.translationVisible {
            translationBody
        } else {
            LockedEmailCardBody(
                bodyState: content.bodyState,
                maxBodyHeight: bodyHeightLimit,
                senderAddress: content.remoteImageSenderAddress,
                blendsHTMLWithCanvas: true
            )
        }
    }

    private var unifiedMessageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            unifiedMessageBody
                .background(messageContextMenuCatcher)
            LockedAttachmentsList(
                attachments: attachments,
                presentation: .contextSummary
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var messageContextMenuCatcher: some View {
        TimelineEventCatcher(onRightClick: { point, view in
            onPresentMessageContextMenu(content.messageId, point, view)
        })
    }

    @ViewBuilder
    private var unifiedMessageBody: some View {
        if translation.translationVisible {
            if translation.isTranslating {
                VStack(alignment: .leading, spacing: 0) {
                    AdaptiveSummaryLoadingPlaceholderView(preferredWidth: 320, slotHeight: 28)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let text = translation.translatedText {
                translatedTextBlock(text)
            }
        } else {
            LockedEmailCardBody(
                bodyState: content.bodyState,
                maxBodyHeight: bodyHeightLimit,
                senderAddress: content.remoteImageSenderAddress,
                blendsHTMLWithCanvas: true,
                presentation: .inline
            )
        }
    }

    @ViewBuilder
    private var translationBody: some View {
        if translation.isTranslating {
            VStack(alignment: .leading, spacing: 0) {
                AdaptiveSummaryLoadingPlaceholderView(preferredWidth: 320, slotHeight: 28)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let text = translation.translatedText {
            // Mirror LockedEmailCardBody's content-vs-scroll behaviour so a
            // short translation sizes to content and a long one scrolls within
            // the same body height budget the original would use.
            ViewThatFits(in: .vertical) {
                translatedTextBlock(text)
                ScrollView { translatedTextBlock(text) }
            }
            .frame(maxHeight: max(1, bodyHeightLimit), alignment: .top)
        }
    }

    private func translatedTextBlock(_ text: String) -> some View {
        TranslatedBodyText(text: text, baseFontSize: 12.5)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    private var chromeHeight: CGFloat {
        LockedEmailCardLayoutMetrics.chromeHeight(
            headerHeight: headerHeight,
            footerHeight: footerHeight
        )
    }

    private var bodyHeightLimit: CGFloat {
        LockedEmailCardLayoutMetrics.bodyHeightLimit(
            manualHeight: effectiveManualHeight,
            maxBodyHeight: maxBodyHeight,
            chromeHeight: chromeHeight
        )
    }

    private var effectiveManualHeight: CGFloat? {
        manualHeight.map { min(max(1, $0), cardHeightLimit) }
    }

    private var cardHeightLimit: CGFloat {
        max(1, maxAutomaticHeight)
    }

    private func publishChromeHeight() {
        let height = chromeHeight
        guard height > 1 else { return }
        onChromeHeightChange(height)
    }

    private func sectionHeightReader<Key: PreferenceKey>(key: Key.Type) -> some View where Key.Value == CGFloat {
        GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.size.height)
        }
    }

    private var cardBackground: some View {
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
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
    }
}

enum LockedEmailCardLayoutMetrics {
    enum MessagePaneKind: Equatable {
        case bodyOnly
        case bodyWithAttachments
    }

    static let fallbackChromeHeight: CGFloat = 116
    static let minimumBodyHeight: CGFloat = 80
    static let automaticMaximumCardHeight: CGFloat = 720
    static let dividerHeight: CGFloat = 2

    static func messagePaneKind(attachmentCount: Int) -> MessagePaneKind {
        attachmentCount > 0 ? .bodyWithAttachments : .bodyOnly
    }

    static func chromeHeight(headerHeight: CGFloat, footerHeight: CGFloat) -> CGFloat {
        let measured = headerHeight + footerHeight + dividerHeight
        return measured > dividerHeight ? measured : fallbackChromeHeight
    }

    static func bodyHeightLimit(
        manualHeight: CGFloat?,
        maxBodyHeight: CGFloat,
        chromeHeight: CGFloat
    ) -> CGFloat {
        guard let manualHeight else { return maxBodyHeight }
        return max(1, manualHeight - chromeHeight)
    }

    static func automaticCardHeightLimit(sceneHeight: CGFloat) -> CGFloat {
        max(
            1,
            min(
                automaticMaximumCardHeight,
                sceneHeight - LockedNodeOverlayMetrics.cardVerticalChromeAllowance
            )
        )
    }

    static func automaticBodyHeightLimit(
        maxCardHeight: CGFloat,
        chromeHeight: CGFloat
    ) -> CGFloat {
        max(1, maxCardHeight - chromeHeight)
    }

    static func automaticCardHeight(
        measuredHeight: CGFloat,
        fallbackHeight: CGFloat
    ) -> CGFloat {
        guard measuredHeight > 1 else { return fallbackHeight }
        return min(measuredHeight, fallbackHeight)
    }

    static func resizeMinimumHeight(chromeHeight: CGFloat) -> CGFloat {
        max(LockedNodeOverlayMetrics.minCardHeight, chromeHeight + minimumBodyHeight)
    }

}

enum LockedNodeOverlayMetrics {
    static let defaultCardWidth: CGFloat = 560
    static let minCardWidth: CGFloat = 320
    static let maxCardWidth: CGFloat = 900
    static let minCardHeight: CGFloat = 220
    /// Full-height control rails in Meaning / People locks are 70pt wide.
    /// The lock card reserves this lane plus a small gutter so pane chrome
    /// never sits underneath action discs.
    static let sideControlRailWidth: CGFloat = 70
    static let sideControlRailGutter: CGFloat = 12
    /// Distance from the near scene edge to the near edge of the lock card when it sits in
    /// its default (non-dragged) position. The default side flips with the sidebar so the
    /// card never overlaps it: sidebar leading → card on trailing edge with this gap to the
    /// right scene edge; sidebar trailing → card on leading edge with this gap to the left.
    static let cardSideMargin: CGFloat = 56
    /// Total vertical space (top + bottom) reserved between the lock card and the scene
    /// edges. Used to bound the card height so it never clips at the Constellation View
    /// borders, regardless of how long the email body is.
    static let cardVerticalChromeAllowance: CGFloat = 220
    /// Default top-left corner for the telemetry strip in lockedNodeOverlay
    /// scene coordinates. X starts at the shared 14pt scene margin; y starts
    /// at zero and is clamped by `FocusedOverlayPaneLayoutCoordinator.frame`
    /// to that same scene margin, so the strip reads as anchored to the
    /// corner without floating below the header.
    static let telemetryOrigin = CGPoint(x: 14, y: 0)
    static let telemetryWidth: CGFloat = 320
    static let telemetryMinimumHeight: CGFloat = 280
    /// CONTEXT pane fallback footprint. The live pane can grow taller after its
    /// orientation paragraph is measured, but this keeps the initial placement stable.
    static var telemetrySize: CGSize {
        CGSize(width: telemetryWidth, height: telemetryMinimumHeight)
    }
    static let visibleBadgeLimit = 4

    static var telemetryFrame: CGRect {
        CGRect(origin: telemetryOrigin, size: telemetrySize)
    }

    static func telemetrySize(contentHeight: CGFloat, availableHeight: CGFloat) -> CGSize {
        CGSize(
            width: telemetryWidth,
            height: min(
                max(telemetryMinimumHeight, ceil(contentHeight)),
                max(telemetryMinimumHeight, floor(availableHeight))
            )
        )
    }
}

private struct LockedEmailCardHeaderHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct LockedEmailCardFooterHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Draggable affordance pinned to the bottom-right corner of the lock card. Visually
/// quiet so it doesn't compete with the chart, but a 16pt hit target so the user has
/// something to grab. Hosts the resize gesture; the card itself owns the gesture wiring.
private struct LockedCardResizeHandle: View {
    @State private var isHovered = false

    var body: some View {
        ZStack {
            // Three-line corner glyph. Bottom-right diagonal striping is the macOS
            // convention for resize affordances.
            Path { path in
                path.move(to: CGPoint(x: 12, y: 4));  path.addLine(to: CGPoint(x: 4, y: 12))
                path.move(to: CGPoint(x: 12, y: 8));  path.addLine(to: CGPoint(x: 8, y: 12))
                path.move(to: CGPoint(x: 12, y: 12)); path.addLine(to: CGPoint(x: 12, y: 12))
            }
            .stroke(
                OhiaColors.chipActiveBorder.opacity(isHovered ? 0.95 : 0.55),
                style: StrokeStyle(lineWidth: 1.25, lineCap: .round)
            )
        }
        .frame(width: 16, height: 16)
        .padding(.trailing, 4)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onContinuousHover { _ in
            // SwiftUI's resize cursor is the hand pointer for diagonal-only corners on
            // macOS; the system cursor stack changes here look the same as text views.
        }
    }
}
