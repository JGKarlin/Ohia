import AppKit
import SwiftUI
import OhiaCore
import OhiaML

enum FrontPageNewArrivalInteraction {
    case hover
    case select
    case contextMenu
    case actionButton
    case focus

    var clearsNewArrivalBadge: Bool {
        switch self {
        case .focus:
            return true
        case .hover, .select, .contextMenu, .actionButton:
            return false
        }
    }
}

enum FrontPageCustomCategoryPresentation {
    static func assignedDescriptors(
        keys: Set<String>,
        catalog: [CustomMailCategoryDescriptor]
    ) -> [CustomMailCategoryDescriptor] {
        catalog.filter { keys.contains($0.key) }
    }
}

/// One modular rectangular newspaper unit. The headline weight/size, image
/// treatment scale by `tier`. Every available summary is visible at rest.
/// Hover changes only feedback and action visibility, preserving click targets.
struct FrontPageArticleCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.readingTextSize) private var readingTextSize

    let article: FrontPageArticle
    let tier: FrontPageLayoutTier
    let liveSummaries: [String: String]
    let summaryUnavailableIds: Set<String>
    let isSummaryRegenerating: Bool
    let isHovered: Bool
    /// True when this card is part of the workspace's multi-selection — draws
    /// the accent ring and keeps the action cluster visible without a hover.
    let isSelected: Bool
    /// Double-click (or the accessibility "Open" action): take over the page
    /// with the reader.
    let onOpen: () -> Void
    /// Single-click: modifier-aware selection. The card reads the live
    /// `NSEvent` modifier flags so ⌘ / ⇧ extend the selection.
    let onSelectClick: (NSEvent.ModifierFlags) -> Void
    /// Right-click (or control-click): present the message context menu at the
    /// click point in the catcher's `NSView`.
    let onRightClick: (NSPoint, NSView) -> Void
    let onHoverChange: (Bool) -> Void
    let onRequestSummary: (String, OnDemandSummaryScope) -> Void
    /// Per-message action closures driving the hover icon cluster.
    let actions: FrontPageMessageActionHandlers
    /// True while this message should show the Front Page new-arrival glisten.
    /// The visual remains active until the message becomes read.
    let showsNewArrivalHighlight: Bool
    /// Reports that this exact card has a non-zero mounted geometry.
    let onPresented: () -> Void
    /// Retires the new-arrival identity once authoritative state is read.
    let onBecameRead: () -> Void
    /// Marks the arrival visited so it is no longer counted as new
    /// (decrementing the dock / starburst badge). The card invokes this only for
    /// focus/open interactions; deletion purges arrivals from the mutation path.
    let onMarkArrivalVisited: () -> Void
    /// Minimum editorial height. Longer summaries grow naturally, independently
    /// of hover and selection; the full-width lead has no minimum.
    var restHeight: CGFloat? = nil
    /// Active masking gesture for this card's message, when one is in flight.
    /// Departing actions (delete / resolve) draw the centred overlay; obligation
    /// and flag actions animate the real status glyph inside the headline block.
    var gesture: MessageStatusGesture? = nil
    /// Force full intensity, bypassing age-based read-dimming — set for the
    /// member cards of an opened thread package, which are the page's focus and
    /// must read at full strength regardless of age, exactly like a hovered card.
    var suppressesReadDimming: Bool = false
    /// Explicitly disables the AppKit event bridge for receded thread siblings.
    var isInteractionEnabled: Bool = true
    /// Live catalog used to resolve the article's stored custom-category keys
    /// into the same user-facing names shown in the focused reader.
    var customCategoryCatalog: [CustomMailCategoryDescriptor] = []

    private var departingIconSize: CGFloat {
        switch tier {
        case .lead: return 27
        case .feature: return 23
        case .standard: return 20
        case .brief: return 16
        }
    }

    @State private var presentedImageHeight: CGFloat?
    /// Pixel aspect reported by the loaded representative image. Lead cards
    /// use it to place a portrait image beside the article text; `0` keeps the
    /// existing stacked layout while the image is unresolved.
    @State private var presentedImageAspect: CGFloat = 0
    /// The revealed action cluster's frame in the card's own coordinate space,
    /// fed to the event catcher's double-click exemption so a rapid second
    /// press on a cluster button activates the button instead of being
    /// consumed as an "open reader" double-click. `.null` contains no point,
    /// so an unmeasured cluster exempts nothing.
    @State private var actionClusterFrame: CGRect = .null
    /// Coordinate space shared by the catcher's converted points (flipped
    /// AppKit → top-left origin) and the measured action-cluster frame.
    private static let cardSpace = "frontPageArticleCardSpace"

    // New-arrival glisten. The sweep is clock-driven so ancestor animations
    // cannot strip its motion, but its changing geometry is drawn inside one
    // Canvas. Re-laying out the card subtree at display cadence can monopolize
    // the main thread while new mail remains unvisited.
    @State private var isGlistening = false
    /// When the current glisten began; the sweep phase is elapsed-since-this.
    @State private var glistenStart = Date.distantPast
    /// One full glisten sweep, left edge to right edge. Sweeps run back-to-back.
    private static let glistenCycleDuration: Double = 1.6
    /// A border glint reads smoothly at 30 fps and avoids making each new card
    /// a display-cadence SwiftUI layout source.
    static let glistenFrameInterval: TimeInterval = 1.0 / 30.0
    /// Read dimming is slow-moving by design: enough to keep a long-running
    /// Front Page honest as mail ages, without turning every card into an
    /// always-animating surface.
    private static let readDimmingUpdateInterval: TimeInterval = 30 * 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.readDimmingUpdateInterval)) { timeline in
            let dimming = FrontPageReadDimmingStyle.resolve(
                isUnread: article.isUnread,
                date: article.date,
                readAt: article.readAt,
                referenceDate: timeline.date
            )
            // A departing (delete / resolve) gesture must read at full intensity:
            // the card's content is hidden and the Collapse overlay is the only
            // thing visible, so suppress read-dimming for its duration too —
            // otherwise an aged-read card knocks the whole crumple down to ~half.
            let visibleDimming = dimming.suppressed(whileHovered: isHovered || departingGestureActive || suppressesReadDimming)
            cardSurface
            // Right-click → context menu; double-click → open the reader. A
            // window-scoped `NSEvent` monitor (bounds-filtered to this card)
            // bridges both AppKit events to the SwiftUI surface and hands back
            // the point + view the `NSMenu` presenter needs. Mounted behind the
            // content; single left-clicks are left for SwiftUI so the hover
            // icon cluster's own buttons stay clickable.
            .background(
                TimelineEventCatcher(
                    isInteractionEnabled: isInteractionEnabled && !departingGestureActive,
                    onRightClick: { point, view in
                        handleNewArrivalInteraction(.contextMenu)
                        onRightClick(point, view)
                    },
                    onDoubleClick: { _, _ in
                        onOpen()
                        handleNewArrivalInteraction(.focus)
                    },
                    isDoubleClickExempt: { point in
                        actionClusterRevealed && actionClusterFrame.contains(point)
                    }
                )
            )
            .overlay(alignment: .bottomTrailing) {
                if actionClusterRevealed {
                    actionCluster
                        .padding(8)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(Self.cardSpace))
                        } action: { frame in
                            actionClusterFrame = frame
                        }
                        .transition(.opacity)
                }
            }
            .coordinateSpace(name: Self.cardSpace)
            .animation(
                actionClusterAnimation,
                value: actionClusterRevealed
            )
            .frontPageReadDimming(visibleDimming)
            .animation(FrontPageCardHoverMotion.highlight, value: visibleDimming.cardOpacity)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            // SwiftUI's plain `.onTapGesture` does not recognize a click while a
            // keyboard modifier is held, so ⌘/⇧ clicks would be silently
            // dropped. Gate dedicated tap gestures on each modifier (they are
            // mutually exclusive with the plain tap, which only fires for an
            // unmodified click) and pass the modifier through explicitly rather
            // than reading the ambient `NSEvent`, which is unreliable inside a
            // SwiftUI gesture action.
            .gesture(TapGesture().modifiers(.command).onEnded {
                handleNewArrivalInteraction(.select)
                onSelectClick(.command)
            })
            .gesture(TapGesture().modifiers(.shift).onEnded {
                handleNewArrivalInteraction(.select)
                onSelectClick(.shift)
            })
            .onTapGesture {
                handleNewArrivalInteraction(.select)
                onSelectClick([])
            }
            .onHover { hovering in
                onHoverChange(hovering)
                guard hovering else { return }
                // Hover retires only the edge highlight. The new-arrival badge
                // remains until the reader is focused or the message is deleted.
                handleNewArrivalInteraction(.hover)
                // Any card with no resolved summary fetches one on hover. The
                // OnDemandSummarizer actor dedups per-message and preempts older
                // hover requests, so sweeping the grid won't pile up work; the full
                // summary then shows if the pointer lingers until it resolves.
                if article.needsOnDemandSummary(
                    liveSummaries: liveSummaries,
                    unavailableMessageIds: summaryUnavailableIds
                ) {
                    onRequestSummary(article.messageIdString, .hover)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text("\(article.headline), Account \(article.accountDisplayName), \(article.statusDescriptor.accessibilityLabel())"))
            .accessibilityValue(isSelected ? Text("Selected") : Text(""))
            .accessibilityAction {
                handleNewArrivalInteraction(.select)
                onSelectClick([])
            }
            .accessibilityAction(named: Text("Open")) {
                onOpen()
                handleNewArrivalInteraction(.focus)
            }
            // Keep the glisten alive for the full unread lifetime. A single
            // fingerprint observes both inputs so read-state snapshot updates
            // stop the clock immediately without chained observers.
            .onChange(
                of: Self.shouldGlisten(
                    showsNewArrivalHighlight: showsNewArrivalHighlight,
                    isUnread: article.isUnread
                ),
                initial: true
            ) { _, shouldShow in
                if shouldShow {
                    startGlistenIfNeeded()
                } else {
                    isGlistening = false
                    if !article.isUnread {
                        onBecameRead()
                    }
                }
            }
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width > 0 && proxy.size.height > 0
            } action: { isPresented in
                if isPresented { onPresented() }
            }
        }
    }

    private var sizedCardContent: some View {
        let placesImageBesideText = Self.shouldPlaceImageBesideText(
            tier: tier,
            imageAspect: presentedImageAspect
        )

        return Group {
            if placesImageBesideText {
                portraitCardContent
            } else {
                stackedCardContent
            }
        }
        .onChange(of: article.imagePath) { _, imagePath in
            presentedImageAspect = 0
            if imagePath == nil {
                presentedImageHeight = nil
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Natural content height includes every summary line. Reserving actions
        // before pointer entry keeps both this card and neighboring rows still.
        .frame(
            minHeight: minimumContentHeight,
            alignment: .topLeading
        )
        .padding(.bottom, actionClusterLayoutClearance)
        .padding(padding)
    }

    private var minimumContentHeight: CGFloat? {
        guard let height = effectiveRestHeight else { return nil }
        return max(0, height - padding * 2 - actionClusterLayoutClearance)
    }

    private var cardSurface: some View {
        sizedCardContent
        // A departing (delete / resolve) gesture turns the whole card into a
        // Collapse: the real content, fill, and border step aside so the faceted
        // overlay BECOMES the card — its shards crumpling inward to a dense core
        // over the page the hidden card reveals. The hand-off is flash-free
        // because at rest the shards reconstruct the card's own surface
        // (`spaceBackground` + `glassPanel`), so clearing the real fill is a
        // near-zero delta. The slot is still held (opacity, not removal) until
        // the snapshot drops the card.
        .opacity(departingGestureActive ? 0 : 1)
        .background(
            // Opaque base so the night-sky backdrop's stars don't show through
            // the card — it floats in front of the sky — with the faint glass
            // tint layered on top to keep the card's surface colour unchanged.
            // A departing (delete / resolve) gesture still clears both so the
            // Collapse overlay can reveal the background behind the card.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(departingGestureActive ? Color.clear : OhiaColors.spaceBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(departingGestureActive ? Color.clear : OhiaColors.glassPanel)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(departingGestureActive ? Color.clear : borderColor, lineWidth: borderWidth)
        )
        .overlay {
            if isGlistening && !reduceMotion && !departingGestureActive {
                glistenOverlay
            }
        }
        // Selection aura: a tight bright core plus a soft wide spread, so the
        // selected card glows like the locked email card rather than only
        // carrying a flat border. Both collapse to a clear (zero-cost) shadow
        // when the card is not selected.
        .shadow(color: selectionGlowColor, radius: 14)
        .shadow(color: selectionGlowColor, radius: 34)
        // Flatten the card and its glow into one layer so the read-dimming
        // `.opacity(_:)` applied by an ancestor (`frontPageReadDimming`) dims the
        // composite as a unit. Without this, SwiftUI applies that opacity per
        // primitive: a dimmed (read, aged) card fill turns translucent and the
        // glow shadows behind it bleed UP THROUGH the card interior instead of
        // staying behind it. A hovered card suppresses dimming (opacity 1) and so
        // never showed the artifact — it only surfaced on a selected-not-hovered
        // card, exactly where the dimming still applies.
        //
        // Keep the departing overlay OUTSIDE this group. It deliberately draws
        // beyond the card's layout bounds; grouping it with the card can rasterize
        // the overflow into the card-sized layer and clip the send-to-Composer
        // comet at the card edge.
        .compositingGroup()
        .overlay {
            if let gesture, gesture.action.usesDepartingOverlay {
                DepartingGestureOverlay(
                    action: gesture.action,
                    gesture: gesture,
                    iconSize: departingIconSize
                )
            }
        }
        .animation(FrontPageCardHoverMotion.highlight, value: isHovered)
        .animation(reduceMotion ? nil : FrontPageCardHoverMotion.highlight, value: isGlistening)
        .animation(FrontPageCardHoverMotion.highlight, value: isSelected)
        .modifier(ComposerDepartureSource(messageIDs: [article.id], inScrollView: true))
    }

    /// The full-width lead card is the only editorial slot spacious enough for
    /// a portrait media column without squeezing the article. Other tiers and
    /// landscape images retain the existing image-above-text composition.
    static func shouldPlaceImageBesideText(
        tier: FrontPageLayoutTier,
        imageAspect: CGFloat
    ) -> Bool {
        tier == .lead && imageAspect > 0 && imageAspect < 1
    }

    /// Match the media column to the fitted portrait itself instead of keeping
    /// the full-width neutral image band. Bounds prevent unusually narrow or
    /// near-square sources from starving either the image or the article text.
    static func portraitMediaColumnWidth(
        imageAspect: CGFloat,
        presentationHeight: CGFloat
    ) -> CGFloat {
        let fittedWidth = max(0, imageAspect) * max(0, presentationHeight)
        return min(320, max(160, fittedWidth))
    }

    /// A specular highlight that travels along the card's frame, masked to the
    /// border ring so the light rides the edge rather than crossing the face —
    /// candidate 3 ("Glisten sweep") from the design sandbox. One Canvas owns
    /// the moving gradient, so each tick redraws pixels without recomputing the
    /// article card's SwiftUI geometry. Phase = elapsed since `glistenStart`.
    private var glistenOverlay: some View {
        TimelineView(
            .animation(
                minimumInterval: Self.glistenFrameInterval,
                paused: controlActiveState == .inactive
            )
        ) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(glistenStart))
            let phase = Self.glistenPhase(elapsed: elapsed)
            Canvas(rendersAsynchronously: true) { context, size in
                guard size.width > 0, size.height > 0 else { return }
                let rect = CGRect(origin: .zero, size: size)
                let border = Path(
                    roundedRect: rect.insetBy(dx: 1.1, dy: 1.1),
                    cornerRadius: 6.9
                )
                .strokedPath(StrokeStyle(lineWidth: 2.2))
                let x = -50 + phase * (size.width + 100)

                context.drawLayer { layer in
                    layer.clip(to: border)
                    layer.translateBy(x: x, y: size.height / 2)
                    layer.rotate(by: .degrees(18))
                    let strip = CGRect(
                        x: -30,
                        y: -size.height * 0.9,
                        width: 60,
                        height: size.height * 1.8
                    )
                    layer.fill(
                        Path(strip),
                        with: .linearGradient(
                            Gradient(colors: [
                                .clear,
                                OhiaColors.surface(0.95),
                                .clear
                            ]),
                            startPoint: CGPoint(x: strip.minX, y: 0),
                            endPoint: CGPoint(x: strip.maxX, y: 0)
                        )
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func glistenPhase(elapsed: TimeInterval) -> Double {
        guard glistenCycleDuration > 0 else { return 0 }
        return (max(0, elapsed) / glistenCycleDuration)
            .truncatingRemainder(dividingBy: 1)
    }

    /// Selected → solid accent ring; glistening new arrival → accent ring for
    /// the sweep to ride; hovered → faint accent; otherwise the hairline glass
    /// border. (A glistening card is never also selected/hovered — engaging it
    /// clears the arrival — so the ordering here is just for clarity.)
    private var borderColor: Color {
        if isSelected { return OhiaColors.chipActiveBorder }
        if isGlistening { return OhiaColors.chipActiveBorder }
        if isHovered { return OhiaColors.chipActiveBorder.opacity(0.5) }
        return OhiaColors.glassBorder
    }

    private var borderWidth: CGFloat {
        if isSelected { return 2 }
        if isGlistening { return 1.5 }
        return 1
    }

    /// Warm ʻōhiʻa-accent aura behind a selected card, mirroring the locked
    /// email card's accent glow (`LockedEmailCard`). The selection border marks
    /// the card; this halo lifts it off the night sky the same way the focused
    /// reader card blooms in the Metal lenses. Cleared while a departing gesture
    /// owns the card (the Collapse overlay is the only thing that should
    /// read), and `nil`/clear otherwise so unselected cards cast no shadow.
    private var selectionGlowColor: Color {
        guard isSelected, !departingGestureActive else { return .clear }
        return OhiaColors.chipActiveBorder.opacity(0.42)
    }

    // MARK: - New-arrival glisten

    /// Focus/open clears the canonical arrival badge. No interaction retires
    /// the glisten; only the article becoming read does that.
    private func handleNewArrivalInteraction(_ interaction: FrontPageNewArrivalInteraction) {
        if interaction.clearsNewArrivalBadge {
            onMarkArrivalVisited()
        }
    }

    private var portraitCardContent: some View {
        HStack(alignment: .top, spacing: imageSpacing) {
            articleImage(
                width: Self.portraitMediaColumnWidth(
                    imageAspect: presentedImageAspect,
                    presentationHeight: presentedImageHeight ?? imageHeight
                )
            )
            headlineBlock
        }
    }

    private var stackedCardContent: some View {
        VStack(alignment: .leading, spacing: imageSpacing) {
            articleImage(width: nil)
            headlineBlock
        }
    }

    @ViewBuilder
    private func articleImage(width: CGFloat?) -> some View {
        if let imagePath = article.imagePath {
            FrontPageArticleImage(
                path: imagePath,
                tier: tier,
                baseHeight: imageHeight,
                onPresentationHeightChange: { height in
                    presentedImageHeight = height
                },
                onImageAspectChange: { aspect in
                    presentedImageAspect = aspect
                }
            )
            .frame(width: width)
        }
    }

    static func shouldGlisten(
        showsNewArrivalHighlight: Bool,
        isUnread: Bool
    ) -> Bool {
        showsNewArrivalHighlight && isUnread
    }

    /// Begin a continuously cycling glisten for an unread new arrival.
    private func startGlistenIfNeeded() {
        guard !reduceMotion,
              Self.shouldGlisten(
                showsNewArrivalHighlight: showsNewArrivalHighlight,
                isUnread: article.isUnread
              ),
              !isGlistening else { return }
        glistenStart = .now
        isGlistening = true
    }

    /// True while the bottom-right action cluster is visible — on hover or when
    /// the card is part of the selection. Suppressed once a departing gesture is
    /// in flight, so no action buttons hover over the Collapse overlay.
    private var actionClusterRevealed: Bool { (isHovered || isSelected) && !departingGestureActive }

    private var actionClusterAnimation: Animation {
        actionClusterRevealed
            ? FrontPageCardHoverMotion.stableActionReveal
            : FrontPageCardHoverMotion.actionClusterHide
    }

    /// True while a departing (delete / resolve) gesture is animating on this
    /// card. The card then holds its expanded size for the gesture's duration so
    /// the Collapse overlay fills the whole card the user was hovering,
    /// rather than a card that snapped back to its rest height when the hover was
    /// lost (e.g. to the delete confirmation alert or a dismissed context menu).
    private var departingGestureActive: Bool {
        gesture?.action.usesDepartingOverlay == true
    }

    /// Actions always own the same band, including while hidden.
    private var actionClusterLayoutClearance: CGFloat {
        Self.actionClusterClearance(
            revealed: true,
            restHeight: effectiveRestHeight,
            padding: padding
        )
    }

    /// Grid rows keep their editorial rest height unless the media itself needs
    /// more vertical room. This lets banners and readable graphics grow at rest
    /// without letting long summaries make every row uneven.
    private var effectiveRestHeight: CGFloat? {
        Self.effectiveRestHeight(
            restHeight: restHeight,
            baseImageHeight: imageHeight,
            presentedImageHeight: presentedImageHeight
        )
    }

    static func effectiveRestHeight(
        restHeight: CGFloat?,
        baseImageHeight: CGFloat,
        presentedImageHeight: CGFloat?
    ) -> CGFloat? {
        guard let restHeight else { return nil }
        let extraImageHeight = max(0, (presentedImageHeight ?? baseImageHeight) - baseImageHeight)
        return restHeight + extraImageHeight
    }

    /// Pure clearance computation, factored out so the geometry is unit-testable.
    ///
    /// The cluster occupies the bottom `iconBand` points of the card — the
    /// overlay's 8pt inset plus the 24pt icon-button height. `revealedTarget`
    /// is the breathing room we'd like above it. On a tall card we reserve the
    /// full target; on a short card (e.g. a paired mosaic member) we reserve
    /// only what the card can spare while still seating the masthead — status
    /// mark + headline + byline ≈ `contentFloor` — and never less than what it
    /// takes to clear the icons. So the byline survives wherever the card can
    /// afford it, and the icons never overlap text. Using the *same* value here
    /// and in both the clamp inset and the bottom padding keeps total card
    /// height == `restHeight`, preserving even rows.
    static func actionClusterClearance(revealed: Bool, restHeight: CGFloat?, padding: CGFloat) -> CGFloat {
        guard revealed else { return 0 }
        let iconBand: CGFloat = 32
        let revealedTarget: CGFloat = 30
        let contentFloor: CGFloat = 64
        let minimumToClearIcons = max(0, iconBand - padding)
        guard let restHeight else { return revealedTarget }   // lead card always has room
        let affordable = restHeight - padding * 2 - contentFloor
        // `max(0, ...)` floors the affordable term so the result can never go
        // negative even if a future tier uses padding ≥ iconBand (which would
        // make `minimumToClearIcons` zero); clearance always stays ≥ 0.
        return max(minimumToClearIcons, min(revealedTarget, max(0, affordable)))
    }

    // MARK: - Hover action cluster

    static func isComposerClusterActionEnabled(isReplied: Bool) -> Bool {
        isReplied == false
    }

    static func composerClusterOpacity(isReplied: Bool) -> Double {
        isReplied ? 0.4 : 1
    }

    /// Bottom-right icon cluster revealed on hover (and kept visible while
    /// selected). The stable left-to-right order is Compose, Resolved, Delete,
    /// Mark Replied, Mark Confirmed, Flag, Ignore; conditional actions simply
    /// leave their slot out.
    private var actionCluster: some View {
        HStack(spacing: 2) {
            if !article.isSentByUser {
                // ⌥ still fronts the Composer when the setting calls for it.
                ComposeClusterButton(
                    isInQueue: article.isInComposerQueue,
                    capturesPressDown: true
                ) {
                    handleNewArrivalInteraction(.actionButton)
                    actions.sendToComposer([article.id])
                }
                .disabled(!Self.isComposerClusterActionEnabled(isReplied: article.isReplied))
                .opacity(Self.composerClusterOpacity(isReplied: article.isReplied))
            }
            clusterButton(
                glyph: .native(article.isResolved ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill"),
                help: article.isResolved ? "Reopen" : "Resolved",
                tint: MessageStatusColors.resolved
            ) {
                actions.setResolved([article.id], !article.isResolved)
            }
            clusterButton(
                glyph: .native("xmark.bin.circle.fill"),
                help: "Delete",
                tint: OhiaColors.ohiaRed
            ) {
                actions.delete([article.id])
            }
            if article.isActionable {
                clusterButton(
                    glyph: .markReplied,
                    help: "Mark replied",
                    tint: MessageStatusColors.pendingReply
                ) {
                    actions.setReplied([article.id], true)
                }
            }
            if article.requiresConfirmation {
                clusterButton(
                    glyph: .knockout("checkmark.seal.fill"),
                    help: "Mark confirmed",
                    tint: MessageStatusColors.confirmation
                ) {
                    actions.setConfirmed([article.id], true)
                }
            }
            clusterButton(
                glyph: article.isFlagged ? .native("flag.slash.circle.fill") : .native("flag.circle.fill"),
                help: article.isFlagged ? "Unflag" : "Flag",
                tint: MessageStatusColors.flagged
            ) {
                actions.setFlagged([article.id], !article.isFlagged)
            }
            if article.isListIgnoreEligible {
                clusterButton(
                    glyph: .native("eye.slash.circle.fill"),
                    help: "Ignore",
                    tint: OhiaColors.ohiaYellow
                ) {
                    actions.ignore(article.id)
                }
            }
        }
    }

    /// Cluster action button — a compact circle-family glyph (shared
    /// `ActionDiscGlyphView`, matching the control-column discs) with no label;
    /// the `.help` tooltip is kept since the cluster carries no gloss text.
    private func clusterButton(
        glyph: ActionDiscGlyph,
        help: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        // Pressing a cluster action retires only the edge highlight. Delete
        // clears the new-arrival badge after the shared delete mutation succeeds.
        // The shared chip carries the hover recolour + lift (§3.10).
        ClusterButtonChip(
            glyph: glyph,
            tint: tint,
            help: help,
            capturesPressDown: true
        ) {
            handleNewArrivalInteraction(.actionButton)
            action()
        }
    }

    private var headlineBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            headlineHeaderBlock
            summaryBlock
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var headlineHeaderBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            headlineMetadata
            Text(article.headline)
                .font(headlineFont)
                .foregroundStyle(OhiaColors.textPrimary)
                .lineLimit(headlineLineLimit)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(article.byline)
                    .font(readingTextSize.font(
                        base: bylineSize,
                        weight: .medium,
                        maximumScale: 1.35
                    ))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(OhiaColors.textTertiary)
                Text(article.dateline())
                    .font(readingTextSize.font(base: bylineSize, maximumScale: 1.35))
                    .foregroundStyle(OhiaColors.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var summaryBlock: some View {
        if showsSummary {
            if isSummaryRegenerating {
                summaryLoadingView
            } else if let lede = resolvedLede {
                summaryView(lede)
            }
        }
    }

    /// Masthead Purpose tag. Pending and uncertain reuse the same badge
    /// geometry while remaining explicit non-Purpose states.
    private var purposeBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: article.purposePresentation.systemImageName)
                .font(.system(size: purposeGlyphSize, weight: .semibold))
            Text(article.purposeLabel)
                .font(.system(size: purposeLabelSize, weight: .heavy))
                .tracking(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(OhiaColors.chipActiveForeground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Category: \(article.purposeLabel)"))
    }

    private var headlineMetadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                metadataPrefix
                horizontalCustomCategoryBadges
                deadlineMark
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    metadataPrefix
                    deadlineMark
                    Spacer(minLength: 0)
                }
                verticalCustomCategoryBadges
            }
        }
    }

    @ViewBuilder
    private var metadataPrefix: some View {
        FrontPageAccountIndicator(
            accountName: article.accountDisplayName,
            accountEmailAddress: article.accountEmailAddress,
            accountColor: article.accountColor,
            size: tier == .lead ? 12 : 11
        )
        MessageStatusMark(
            descriptor: preCategoryStatusDescriptor,
            size: statusMarkSize,
            showsDeadlineSignal: false,
            showsTextGloss: true,
            glossFont: .system(size: statusGlossSize, weight: .semibold),
            gesture: preCategoryStatusGesture
        )
        purposeBadge
        postCategoryObligationMark
    }

    /// Keeps direction/read state and settled status evidence ahead of the
    /// category while moving only the open reply/confirmation obligation after
    /// it. Deadline remains independently pinned to the trailing edge below.
    private var preCategoryStatusDescriptor: MessageStatusDescriptor {
        let descriptor = article.statusDescriptor
        let gestureTarget = gesture?.action.targetObligation
        return MessageStatusDescriptor(
            isSentByUser: descriptor.isSentByUser,
            isRead: descriptor.isRead,
            isReplied: gestureTarget == .pendingReply ? false : descriptor.isReplied,
            isConfirmed: gestureTarget == .needsConfirmation ? false : descriptor.isConfirmed,
            isResolved: descriptor.isResolved,
            needsReply: false,
            needsConfirmation: false,
            hasDeadline: false,
            deadlineText: nil,
            isFlagged: descriptor.isFlagged,
            isRevivedAfterInactiveGap: descriptor.isRevivedAfterInactiveGap,
            sharedEvidenceKinds: descriptor.sharedEvidenceKinds,
            paintedSharedEvidenceKinds: descriptor.paintedSharedEvidenceKinds
        )
    }

    private var preCategoryStatusGesture: MessageStatusGesture? {
        guard let gesture else { return nil }
        let target = gesture.action.targetObligation
        return gesture.action.isFlag || target == .replied || target == .confirmed
            ? gesture
            : nil
    }

    /// The single open obligation follows the category. Settled reply and
    /// confirmation evidence remains with the leading context marks above.
    @ViewBuilder
    private var postCategoryObligationMark: some View {
        if let action = postCategoryObligationAction {
            let label = article.statusDescriptor.actionLabel(action)
            let glyph = GestureObligationGlyph(
                action: action,
                gesture: gesture?.action.targetObligation == action ? gesture : nil,
                size: statusMarkSize
            )
            ViewThatFits(in: .horizontal) {
                HStack(spacing: max(3, statusMarkSize * 0.2)) {
                    glyph
                    Text(label)
                        .font(.system(size: statusGlossSize, weight: .semibold))
                        .foregroundStyle(action.tint)
                        .lineLimit(1)
                        .fixedSize()
                }
                glyph
            }
            .help(label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
    }

    private var postCategoryObligationAction: MessageStatusActionState? {
        if let target = gesture?.action.targetObligation,
           target == .pendingReply || target == .needsConfirmation {
            return target
        }
        if article.statusDescriptor.needsReply {
            return .pendingReply
        }
        if article.statusDescriptor.needsConfirmation {
            return .needsConfirmation
        }
        return nil
    }

    /// Deadline trails the whole metadata line. It keeps the lowest layout
    /// priority so its long gloss collapses to the calendar glyph first.
    private var deadlineMark: some View {
        MessageStatusDeadlineMark(
            descriptor: article.statusDescriptor,
            size: statusMarkSize,
            glossFont: .system(size: statusGlossSize, weight: .semibold)
        )
        .layoutPriority(-1)
    }

    private var assignedCustomCategories: [CustomMailCategoryDescriptor] {
        FrontPageCustomCategoryPresentation.assignedDescriptors(
            keys: article.customCategoryKeys,
            catalog: customCategoryCatalog
        )
    }

    @ViewBuilder
    private var horizontalCustomCategoryBadges: some View {
        ForEach(assignedCustomCategories) { descriptor in
            customCategoryBadge(descriptor)
        }
    }

    private var verticalCustomCategoryBadges: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(assignedCustomCategories) { descriptor in
                customCategoryBadge(descriptor)
            }
        }
    }

    private func customCategoryBadge(
        _ descriptor: CustomMailCategoryDescriptor
    ) -> some View {
        FilterChipLabel(
            text: descriptor.displayName,
            isOn: true,
            size: purposeLabelSize,
            height: tier == .lead ? 22 : 20,
            horizontalPadding: tier == .lead ? 8 : 6
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Text("Custom category: \(descriptor.displayName)"))
    }

    private var summaryLoadingView: some View {
        AdaptiveSummaryLoadingPlaceholderView(preferredWidth: summaryPlaceholderWidth, slotHeight: 24)
            .transition(.opacity)
    }

    private var summaryPlaceholderWidth: CGFloat {
        switch tier {
        case .lead:
            return 360
        case .feature:
            return 260
        default:
            return 220
        }
    }

    /// The full available summary has the same view identity in every pointer state.
    private func summaryView(_ summary: String) -> some View {
        Text(summary)
            .font(summaryFont)
            .foregroundStyle(OhiaColors.textSecondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .transition(.opacity)
    }

    // MARK: - Derived

    private var resolvedLede: String? {
        article.resolvedLede(liveSummaries: liveSummaries)
    }

    private var showsSummary: Bool {
        isSummaryRegenerating || resolvedLede != nil
    }

    // MARK: - Per-tier metrics

    private var headlineFont: Font {
        switch tier {
        case .lead: return readingTextSize.font(base: 30, weight: .heavy, maximumScale: 1.20)
        case .feature: return readingTextSize.font(base: 21, weight: .bold, maximumScale: 1.20)
        case .standard: return readingTextSize.font(base: 16, weight: .semibold, maximumScale: 1.20)
        case .brief: return readingTextSize.font(base: 14, weight: .semibold, maximumScale: 1.20)
        }
    }

    private var summaryFont: Font {
        switch tier {
        case .lead: return readingTextSize.font(base: 15)
        case .feature: return readingTextSize.font(base: 13)
        default: return readingTextSize.font(base: 12)
        }
    }

    private var headlineLineLimit: Int {
        switch tier {
        case .lead: return 4
        case .feature: return 3
        default: return 2
        }
    }

    private var bylineSize: CGFloat { tier == .lead ? 13 : 11 }
    private var statusMarkSize: CGFloat { tier == .lead ? 18 : 16 }
    private var statusGlossSize: CGFloat { tier == .lead ? 11 : 10 }
    private var purposeGlyphSize: CGFloat { tier == .lead ? 11 : 10 }
    private var purposeLabelSize: CGFloat { tier == .lead ? 11 : 9.5 }
    private var padding: CGFloat { tier == .lead ? 20 : (tier == .feature ? 16 : 12) }
    private var imageSpacing: CGFloat { 10 }

    private var imageHeight: CGFloat {
        switch tier {
        case .lead: return 280
        case .feature: return 160
        case .standard: return 120
        case .brief: return 0
        }
    }
}

struct FrontPageReadDimmingStyle: Equatable {
    let intensity: Double
    let cardOpacity: Double

    static let undimmed = FrontPageReadDimmingStyle(
        intensity: 0,
        cardOpacity: 1
    )
    static let minimumReadIntensity: Double = 0.16
    static let recentMessageUndimmedInterval: TimeInterval = 24 * 60 * 60
    static let fullDimmingInterval: TimeInterval = 7 * 24 * 60 * 60
    static let minimumCardOpacity: Double = 0.48

    static func resolve(
        isUnread: Bool,
        date: Date,
        readAt: Date?,
        referenceDate: Date
    ) -> FrontPageReadDimmingStyle {
        guard !isUnread else { return .undimmed }
        guard !isRecentlyReceived(date: date, referenceDate: referenceDate) else { return .undimmed }
        let dimmingStartedAt = readAt ?? date
        let age = max(0, referenceDate.timeIntervalSince(dimmingStartedAt))
        let progress = min(1, age / fullDimmingInterval)
        let easedProgress = 1 - pow(1 - progress, 2)
        let intensity = minimumReadIntensity + (1 - minimumReadIntensity) * easedProgress
        return style(forIntensity: intensity)
    }

    static func style(forIntensity intensity: Double) -> FrontPageReadDimmingStyle {
        let clamped = min(1, max(0, intensity))
        return FrontPageReadDimmingStyle(
            intensity: clamped,
            cardOpacity: 1 - (1 - minimumCardOpacity) * clamped
        )
    }

    func suppressed(whileHovered isHovered: Bool) -> FrontPageReadDimmingStyle {
        isHovered ? .undimmed : self
    }

    private static func isRecentlyReceived(date: Date, referenceDate: Date) -> Bool {
        date >= referenceDate.addingTimeInterval(-recentMessageUndimmedInterval)
    }
}

private struct FrontPageReadDimmingModifier: ViewModifier {
    let style: FrontPageReadDimmingStyle

    func body(content: Content) -> some View {
        content
            .opacity(style.cardOpacity)
    }
}

private extension View {
    func frontPageReadDimming(_ style: FrontPageReadDimmingStyle) -> some View {
        modifier(FrontPageReadDimmingModifier(style: style))
    }
}

/// Lazily loads a representative email image from disk, off-main, and renders
/// it through a shape-aware presentation policy. A load failure collapses to
/// nothing (the card is text-only), never a broken-image placeholder.
struct FrontPageArticleImage: View {
    let path: String
    let tier: FrontPageLayoutTier
    let baseHeight: CGFloat
    let onPresentationHeightChange: (CGFloat) -> Void
    let onImageAspectChange: (CGFloat) -> Void

    @State private var image: NSImage?
    /// Pixel aspect (width / height) of the loaded image; `0` until known.
    @State private var imageAspect: CGFloat = 0
    @State private var pixelWidth: Int = 0
    @State private var pixelHeight: Int = 0
    @State private var naturalWidth: CGFloat = 0
    @State private var naturalHeight: CGFloat = 0
    @State private var availableWidth: CGFloat = 0
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                imageContainer(image)
            } else if !didFail {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(OhiaColors.surface(0.08))
                    .frame(maxWidth: .infinity)
                    .frame(height: baseHeight)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            (proxy.size.width * 2).rounded() / 2
        } action: { width in
            availableWidth = width
        }
        .onChange(of: presentation.height, initial: true) { _, height in
            onPresentationHeightChange(height)
        }
        .task(id: path) {
            await load()
        }
    }

    private var presentation: FrontPageImagePresentation {
        FrontPageImagePresentation.resolve(
            imageAspect: imageAspect,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            naturalWidth: naturalWidth,
            naturalHeight: naturalHeight,
            availableWidth: availableWidth,
            baseHeight: baseHeight,
            tier: tier
        )
    }

    private func imageContainer(_ image: NSImage) -> some View {
        let presentation = presentation
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(OhiaColors.surface(0.08))
            .frame(maxWidth: .infinity)
            .frame(height: presentation.height)
            .overlay {
                GeometryReader { geo in
                    renderedImage(image, presentation: presentation, size: geo.size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func renderedImage(
        _ image: NSImage,
        presentation: FrontPageImagePresentation,
        size: CGSize
    ) -> some View {
        switch presentation.mode {
        case .containedLogo:
            let imageSize = presentation.fittedImageSize(in: size)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: imageSize.width, height: imageSize.height)
                .frame(width: size.width, height: size.height, alignment: .leading)
        case .naturalBanner, .readableGraphic, .tallPreview:
            let imageSize = presentation.fittedImageSize(in: size)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: imageSize.width, height: imageSize.height)
                .frame(width: size.width, height: size.height, alignment: .leading)
        default:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: presentation.contentMode)
                .frame(width: size.width, height: size.height)
        }
    }

    private func load() async {
        let target = path
        // Reset first so a recycled view (scroll reuse with a new `path`)
        // never shows the previous image while the new one loads or fails.
        image = nil
        imageAspect = 0
        pixelWidth = 0
        pixelHeight = 0
        naturalWidth = 0
        naturalHeight = 0
        didFail = false
        onPresentationHeightChange(baseHeight)
        // Read bytes off-main (`Data` is Sendable); build the non-Sendable
        // `NSImage` back on the main actor to satisfy strict concurrency.
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            try? Data(contentsOf: URL(fileURLWithPath: target))
        }.value
        if Task.isCancelled { return }
        if let data, let loaded = NSImage(data: data) {
            image = loaded
            let geometry = Self.pixelGeometry(of: loaded)
            pixelWidth = geometry.width
            pixelHeight = geometry.height
            naturalWidth = geometry.naturalWidth
            naturalHeight = geometry.naturalHeight
            imageAspect = geometry.aspect
            onImageAspectChange(geometry.aspect)
        } else {
            didFail = true
        }
    }

    /// True pixel geometry from the largest bitmap representation (more
    /// reliable than `NSImage.size`, which can be DPI-adjusted); falls back to
    /// `size` for vector or unusual reps.
    private static func pixelGeometry(
        of image: NSImage
    ) -> (width: Int, height: Int, naturalWidth: CGFloat, naturalHeight: CGFloat, aspect: CGFloat) {
        let size = image.size
        let naturalWidth = max(0, size.width)
        let naturalHeight = max(0, size.height)
        let reps = image.representations.filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
        if let rep = reps.max(by: { lhs, rhs in
            lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
        }) {
            return (
                rep.pixelsWide,
                rep.pixelsHigh,
                naturalWidth > 0 ? naturalWidth : CGFloat(rep.pixelsWide),
                naturalHeight > 0 ? naturalHeight : CGFloat(rep.pixelsHigh),
                CGFloat(rep.pixelsWide) / CGFloat(rep.pixelsHigh)
            )
        }
        let width = max(0, Int(size.width.rounded()))
        let height = max(0, Int(size.height.rounded()))
        return (
            width,
            height,
            naturalWidth,
            naturalHeight,
            height > 0 ? CGFloat(width) / CGFloat(height) : 0
        )
    }
}

/// Decides how a representative email image should occupy a Front Page card.
/// It deliberately distinguishes informational graphics from decorative photos:
/// banners and screenshots preserve their whole shape, tiny logos stay
/// contained, while ordinary photos retain the existing editorial crop.
struct FrontPageImagePresentation: Equatable {
    enum Mode: String, Equatable {
        case naturalBanner
        case readableGraphic
        case editorialPhoto
        case containedLogo
        case tallPreview
    }

    enum Scaling: Equatable {
        case fit
        case fill
    }

    let mode: Mode
    let scaling: Scaling
    let height: CGFloat
    let pixelWidth: Int
    let naturalWidth: CGFloat
    let naturalHeight: CGFloat
    let imageAspect: CGFloat

    var contentMode: ContentMode {
        scaling == .fit ? .fit : .fill
    }

    static func resolve(
        imageAspect: CGFloat,
        pixelWidth: Int,
        pixelHeight: Int,
        naturalWidth: CGFloat = 0,
        naturalHeight: CGFloat = 0,
        availableWidth: CGFloat,
        baseHeight: CGFloat,
        tier: FrontPageLayoutTier
    ) -> FrontPageImagePresentation {
        guard baseHeight > 0 else {
            return FrontPageImagePresentation(
                mode: .editorialPhoto,
                scaling: .fill,
                height: 0,
                pixelWidth: pixelWidth,
                naturalWidth: naturalWidth,
                naturalHeight: naturalHeight,
                imageAspect: imageAspect
            )
        }
        guard imageAspect > 0, availableWidth > 0, pixelWidth > 0, pixelHeight > 0 else {
            return FrontPageImagePresentation(
                mode: .editorialPhoto,
                scaling: .fill,
                height: baseHeight,
                pixelWidth: pixelWidth,
                naturalWidth: naturalWidth,
                naturalHeight: naturalHeight,
                imageAspect: imageAspect
            )
        }

        let style = Style(tier: tier, baseHeight: baseHeight)
        let displayWidth = naturalWidth > 0 ? naturalWidth : CGFloat(pixelWidth)
        let displayHeight = naturalHeight > 0 ? naturalHeight : CGFloat(pixelHeight)
        let cellAspect = availableWidth / max(baseHeight, 1)
        let cropDivergence = max(imageAspect / cellAspect, cellAspect / imageAspect)

        if isWideBanner(aspect: imageAspect, pixelWidth: pixelWidth) {
            return FrontPageImagePresentation(
                mode: .naturalBanner,
                scaling: .fit,
                height: Self.naturalHeight(
                    aspect: imageAspect,
                    availableWidth: availableWidth,
                    naturalWidth: displayWidth,
                    minimum: style.minimumReadableHeight,
                    maximum: style.maximumReadableHeight
                ),
                pixelWidth: pixelWidth,
                naturalWidth: displayWidth,
                naturalHeight: displayHeight,
                imageAspect: imageAspect
            )
        }

        if isTinyLogo(pixelWidth: pixelWidth, pixelHeight: pixelHeight, aspect: imageAspect) {
            return FrontPageImagePresentation(
                mode: .containedLogo,
                scaling: .fit,
                height: style.logoHeight,
                pixelWidth: pixelWidth,
                naturalWidth: displayWidth,
                naturalHeight: displayHeight,
                imageAspect: imageAspect
            )
        }

        if imageAspect <= 0.72 {
            return FrontPageImagePresentation(
                mode: .tallPreview,
                scaling: .fit,
                height: style.maximumReadableHeight,
                pixelWidth: pixelWidth,
                naturalWidth: displayWidth,
                naturalHeight: displayHeight,
                imageAspect: imageAspect
            )
        }

        if isReadableGraphic(
            aspect: imageAspect,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            cropDivergence: cropDivergence
        ) {
            return FrontPageImagePresentation(
                mode: .readableGraphic,
                scaling: .fit,
                height: Self.naturalHeight(
                    aspect: imageAspect,
                    availableWidth: availableWidth,
                    naturalWidth: displayWidth,
                    minimum: baseHeight,
                    maximum: style.maximumReadableHeight
                ),
                pixelWidth: pixelWidth,
                naturalWidth: displayWidth,
                naturalHeight: displayHeight,
                imageAspect: imageAspect
            )
        }

        return FrontPageImagePresentation(
            mode: .editorialPhoto,
            scaling: .fill,
            height: baseHeight,
            pixelWidth: pixelWidth,
            naturalWidth: displayWidth,
            naturalHeight: displayHeight,
            imageAspect: imageAspect
        )
    }

    func fittedImageSize(in containerSize: CGSize) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0, imageAspect > 0 else {
            return .zero
        }
        if scaling == .fill {
            return containerSize
        }

        let maxNaturalWidth = naturalWidth > 0 ? naturalWidth : CGFloat(pixelWidth)
        let maxNaturalHeight = naturalHeight > 0 ? naturalHeight : (maxNaturalWidth / imageAspect)
        let widthLimit: CGFloat
        let heightLimit: CGFloat
        if mode == .containedLogo {
            widthLimit = min(containerSize.width * 0.68, maxNaturalWidth)
            heightLimit = min(containerSize.height, maxNaturalHeight)
        } else {
            widthLimit = min(containerSize.width, maxNaturalWidth)
            heightLimit = min(containerSize.height, maxNaturalHeight)
        }
        guard widthLimit > 0, heightLimit > 0 else { return .zero }

        let heightFromWidth = widthLimit / imageAspect
        if heightFromWidth <= heightLimit {
            return CGSize(width: Self.roundHalfPoint(widthLimit), height: Self.roundHalfPoint(heightFromWidth))
        }
        return CGSize(
            width: Self.roundHalfPoint(heightLimit * imageAspect),
            height: Self.roundHalfPoint(heightLimit)
        )
    }

    private static func isWideBanner(aspect: CGFloat, pixelWidth: Int) -> Bool {
        aspect >= 2.8 && pixelWidth >= 420
    }

    private static func isTinyLogo(pixelWidth: Int, pixelHeight: Int, aspect: CGFloat) -> Bool {
        guard aspect >= 0.75, aspect <= 1.35 else { return false }
        let maxDimension = max(pixelWidth, pixelHeight)
        let pixelArea = pixelWidth * pixelHeight
        return maxDimension <= 180 || pixelArea <= 32_000
    }

    private static func isReadableGraphic(
        aspect: CGFloat,
        pixelWidth: Int,
        pixelHeight: Int,
        cropDivergence: CGFloat
    ) -> Bool {
        if aspect >= 1.8 || aspect <= 0.88 { return true }
        let maxDimension = max(pixelWidth, pixelHeight)
        let pixelArea = pixelWidth * pixelHeight
        return cropDivergence >= 1.65 && maxDimension <= 1_000 && pixelArea <= 600_000
    }

    private static func naturalHeight(
        aspect: CGFloat,
        availableWidth: CGFloat,
        naturalWidth: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let targetWidth = naturalWidth > 0 ? min(availableWidth, naturalWidth) : availableWidth
        let rawHeight = targetWidth / max(aspect, 0.01)
        let clamped = min(maximum, max(minimum, rawHeight))
        return roundHalfPoint(clamped)
    }

    private static func roundHalfPoint(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }

    private struct Style {
        let minimumReadableHeight: CGFloat
        let maximumReadableHeight: CGFloat
        let logoHeight: CGFloat

        init(tier: FrontPageLayoutTier, baseHeight: CGFloat) {
            switch tier {
            case .lead:
                minimumReadableHeight = max(140, baseHeight * 0.55)
                maximumReadableHeight = max(baseHeight, 340)
                logoHeight = max(120, baseHeight * 0.45)
            case .feature:
                minimumReadableHeight = max(110, baseHeight * 0.62)
                maximumReadableHeight = max(baseHeight, 260)
                logoHeight = max(96, baseHeight * 0.55)
            case .standard:
                minimumReadableHeight = max(88, baseHeight * 0.70)
                maximumReadableHeight = max(baseHeight, 220)
                logoHeight = max(82, baseHeight * 0.68)
            case .brief:
                minimumReadableHeight = 0
                maximumReadableHeight = 0
                logoHeight = 0
            }
        }
    }
}
