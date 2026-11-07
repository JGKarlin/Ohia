import AppKit
import SwiftUI
import OhiaCore
import OhiaML

struct FrontPageThreadActionState: Equatable {
    let allMessageIDs: [UUID]
    let composerTargetID: UUID?
    let composerIsInQueue: Bool
    let replyActionIDs: [UUID]
    let confirmationActionIDs: [UUID]
    let allFlagged: Bool
    let allResolved: Bool
    let gesture: MessageStatusGesture?

    static func build(
        representativeID: UUID,
        thread: FrontPageThreadInfo,
        resolveArticle: (UUID) -> FrontPageArticle?,
        gestureForMessageID: (UUID) -> MessageStatusGesture?
    ) -> FrontPageThreadActionState {
        let resolvedMembers = thread.members.compactMap { member -> (UUID, FrontPageArticle)? in
            guard let article = resolveArticle(member.id) else { return nil }
            return (member.id, article)
        }
        let allMessageIDs = resolvedMembers.map(\.0)
        let representative = resolvedMembers.first(where: { $0.0 == representativeID })?.1
        let fallbackComposerTarget = resolvedMembers.first(where: { !$0.1.isSentByUser })
        let composerTargetID: UUID?
        let composerIsInQueue: Bool
        if let representative, !representative.isSentByUser {
            composerTargetID = representativeID
            composerIsInQueue = representative.isInComposerQueue
        } else if let fallbackComposerTarget {
            composerTargetID = fallbackComposerTarget.0
            composerIsInQueue = fallbackComposerTarget.1.isInComposerQueue
        } else {
            composerTargetID = nil
            composerIsInQueue = false
        }
        let replyActionIDs = resolvedMembers
            .filter { $0.1.isActionable }
            .map(\.0)
        let confirmationActionIDs = resolvedMembers
            .filter { $0.1.requiresConfirmation }
            .map(\.0)
        let gestures = thread.members.compactMap { gestureForMessageID($0.id) }
        return FrontPageThreadActionState(
            allMessageIDs: allMessageIDs,
            composerTargetID: composerTargetID,
            composerIsInQueue: composerIsInQueue,
            replyActionIDs: replyActionIDs,
            confirmationActionIDs: confirmationActionIDs,
            allFlagged: !resolvedMembers.isEmpty && resolvedMembers.allSatisfy { $0.1.isFlagged },
            allResolved: !resolvedMembers.isEmpty && resolvedMembers.allSatisfy { $0.1.isResolved },
            gesture: preferredGesture(in: gestures)
        )
    }

    private static func preferredGesture(in gestures: [MessageStatusGesture]) -> MessageStatusGesture? {
        gestures.max { lhs, rhs in
            if gesturePriority(lhs.action) != gesturePriority(rhs.action) {
                return gesturePriority(lhs.action) < gesturePriority(rhs.action)
            }
            return lhs.start < rhs.start
        }
    }

    private static func gesturePriority(_ action: MessageStatusGestureAction) -> Int {
        switch action {
        case .sentToComposer: return 7
        case .delete: return 6
        case .resolve: return 5
        case .ignore: return 4
        case .markReplied: return 3
        case .markConfirmed: return 2
        case .replyNeeded, .confirmationNeeded: return 1
        case .flag: return 0
        }
    }
}

/// The collapsed **thread package** card: a whole conversation (2+ still-open
/// messages) shown as one card in the newspaper grid. It is an ordinary card
/// masthead — account · rolled-up status · Purpose — plus a top-right thread
/// pair (stack glyph + message count + an expand chevron). Its headline is the
/// conversation's Re:/Fwd:-stripped subject; the byline, dateline, and summary
/// come from the action-first representative (`article`).
///
/// Composed from the same primitives the real `FrontPageArticleCard` uses
/// (`FrontPageAccountIndicator`, `MessageStatusMark`, `ToggleIconography`, the
/// glass frame, the `OhiaColors` tokens) so it reads as one surface with the
/// singleton cards beside it. Single click selects; double-click / the chevron
/// opens the thread in place (the layout dims the rest of the page and expands
/// this slot into member cards).
struct FrontPagePackageCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.readingTextSize) private var readingTextSize

    /// The action-first representative — supplies account, byline, dateline,
    /// summary, and the Purpose glyph.
    let article: FrontPageArticle
    let thread: FrontPageThreadInfo
    let tier: FrontPageLayoutTier
    let isSelected: Bool
    let isHovered: Bool
    let liveSummaries: [String: String]
    let summaryUnavailableIds: Set<String>
    let actions: FrontPageMessageActionHandlers
    let actionState: FrontPageThreadActionState
    /// True while any unread member is a current-session new arrival.
    let showsNewArrivalHighlight: Bool
    let newArrivalMessageIDs: Set<String>
    let unreadMessageIDs: Set<String>
    /// Reports that this collapsed package has a non-zero mounted geometry.
    let onPresented: () -> Void
    /// Retires member arrival identities once their authoritative rows are read.
    let onReadArrivalMembers: (Set<String>) -> Void
    /// Double-click / chevron: open the thread in place.
    let onOpen: () -> Void
    /// Single-click: modifier-aware selection (keyed by the representative id).
    let onSelectClick: (NSEvent.ModifierFlags) -> Void
    let onRightClick: (NSPoint, NSView) -> Void
    let onHoverChange: (Bool) -> Void
    let onRequestSummary: (String, OnDemandSummaryScope) -> Void
    var restHeight: CGFloat? = nil
    var isInteractionEnabled: Bool = true
    /// Live catalog used to resolve the representative's assigned custom
    /// categories while the thread is collapsed into one package card.
    var customCategoryCatalog: [CustomMailCategoryDescriptor] = []

    /// The stack-of-cards thread glyph, chosen in the design sandbox.
    private static let threadGlyph = "square.stack.3d.up.fill"
    private static let hoverHighlightAnimation = Animation.easeOut(duration: 0.16)
    private static let actionClusterHideAnimation = Animation.easeOut(duration: 0.12)

    @State private var isGlistening = false
    @State private var glistenStart = Date.distantPast
    /// The revealed action cluster's frame in the card's own coordinate space,
    /// fed to the event catcher's double-click exemption so a rapid second
    /// press on a cluster button activates the button instead of being
    /// consumed as an "open thread" double-click. `.null` contains no point,
    /// so an unmeasured cluster exempts nothing.
    @State private var actionClusterFrame: CGRect = .null
    /// Coordinate space shared by the catcher's converted points (flipped
    /// AppKit → top-left origin) and the measured action-cluster frame.
    private static let cardSpace = "frontPagePackageCardSpace"

    static func shouldGlisten(
        memberMessageIDs: Set<String>,
        newArrivalMessageIDs: Set<String>,
        unreadMessageIDs: Set<String>
    ) -> Bool {
        memberMessageIDs
            .intersection(newArrivalMessageIDs)
            .intersection(unreadMessageIDs)
            .isEmpty == false
    }

    var body: some View {
        cardSurface
            .background(
                TimelineEventCatcher(
                    isInteractionEnabled: isInteractionEnabled && !departingGestureActive,
                    onRightClick: { point, view in onRightClick(point, view) },
                    onDoubleClick: { _, _ in onOpen() },
                    isDoubleClickExempt: { point in
                        actionClusterRevealed && actionClusterFrame.contains(point)
                    }
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .animation(actionClusterAnimation, value: actionClusterRevealed)
            .gesture(TapGesture().modifiers(.command).onEnded { onSelectClick(.command) })
            .gesture(TapGesture().modifiers(.shift).onEnded { onSelectClick(.shift) })
            .onTapGesture { onSelectClick([]) }
            .onHover { hovering in
                onHoverChange(hovering)
                guard hovering else { return }
                if article.needsOnDemandSummary(
                    liveSummaries: liveSummaries,
                    unavailableMessageIds: summaryUnavailableIds
                ) {
                    onRequestSummary(article.messageIdString, .hover)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text("\(thread.subjectRoot), thread of \(thread.count) messages"))
            .accessibilityAction { onSelectClick([]) }
            .accessibilityAction(named: Text("Open thread")) { onOpen() }
            .onChange(of: showsNewArrivalHighlight, initial: true) { _, shouldShow in
                if shouldShow && !reduceMotion {
                    if !isGlistening {
                        glistenStart = .now
                        isGlistening = true
                    }
                } else {
                    isGlistening = false
                }
            }
            .onChange(of: readArrivalMessageIDs, initial: true) { _, readArrivals in
                if readArrivals.isEmpty == false {
                    onReadArrivalMembers(readArrivals)
                }
            }
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width > 0 && proxy.size.height > 0
            } action: { isPresented in
                if isPresented { onPresented() }
            }
    }

    private var sizedCardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            packageMetadata
            Text(thread.subjectRoot)
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
                Text("·").foregroundStyle(OhiaColors.textTertiary)
                Text(article.dateline())
                    .font(readingTextSize.font(base: bylineSize, maximumScale: 1.35))
                    .foregroundStyle(OhiaColors.textTertiary)
                    .lineLimit(1)
            }
            if let lede = article.resolvedLede(liveSummaries: liveSummaries) {
                Text(lede)
                    .font(summaryFont)
                    .foregroundStyle(OhiaColors.textSecondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(
            minHeight: minimumContentHeight,
            alignment: .topLeading
        )
        .padding(.bottom, actionClusterLayoutClearance)
        .padding(padding)
    }

    private var minimumContentHeight: CGFloat? {
        guard let height = restHeight else { return nil }
        return max(0, height - padding * 2 - actionClusterLayoutClearance)
    }

    private var cardSurface: some View {
        sizedCardContent
        .opacity(departingGestureActive ? 0 : 1)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(departingGestureActive ? Color.clear : OhiaColors.spaceBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(departingGestureActive ? Color.clear : OhiaColors.glassPanel)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    departingGestureActive ? .clear : borderColor,
                    lineWidth: isSelected || isGlistening ? 1.5 : 1
                )
        )
        .overlay {
            if isGlistening && !reduceMotion && !departingGestureActive {
                glistenOverlay
            }
        }
        .shadow(color: isSelected ? selectionGlowColor : .clear, radius: 14)
        .shadow(color: isSelected ? selectionGlowColor : .clear, radius: 34)
        .compositingGroup()
        .overlay {
            if let gesture = actionState.gesture, gesture.action.usesDepartingOverlay {
                DepartingGestureOverlay(
                    action: gesture.action,
                    gesture: gesture,
                    iconSize: departingIconSize
                )
            }
        }
        .animation(Self.hoverHighlightAnimation, value: isSelected)
        .animation(Self.hoverHighlightAnimation, value: isHovered)
        .animation(reduceMotion ? nil : Self.hoverHighlightAnimation, value: isGlistening)
        .modifier(ComposerDepartureSource(messageIDs: Set(actionState.allMessageIDs), inScrollView: true))
    }

    private var readArrivalMessageIDs: Set<String> {
        newArrivalMessageIDs.subtracting(unreadMessageIDs)
    }

    /// The same border-only traveling highlight used by singleton Front Page
    /// cards, applied to the visible collapsed package when any unread member
    /// is a current-session arrival.
    private var glistenOverlay: some View {
        TimelineView(
            .animation(
                minimumInterval: FrontPageArticleCard.glistenFrameInterval,
                paused: controlActiveState == .inactive
            )
        ) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(glistenStart))
            let phase = FrontPageArticleCard.glistenPhase(elapsed: elapsed)
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

    // MARK: - Masthead pieces

    /// Roll-up obligation marks: the real `MessageStatusMark`, one per obligation
    /// still open across the siblings, each with a small ×N when 2+ share it. A
    /// thread can show BOTH reply and confirmation, unlike a single card.
    @ViewBuilder
    private var rollupMarks: some View {
        if thread.replyCount > 0 {
            obligationMark(needsReply: true, count: thread.replyCount)
        }
        if thread.confirmCount > 0 {
            obligationMark(needsReply: false, count: thread.confirmCount)
        }
    }

    private func obligationMark(needsReply: Bool, count: Int) -> some View {
        HStack(spacing: 2) {
            MessageStatusMark(
                descriptor: MessageStatusDescriptor(
                    isSentByUser: false,
                    isRead: false,
                    isReplied: false,
                    isConfirmed: false,
                    needsReply: needsReply,
                    needsConfirmation: !needsReply,
                    hasDeadline: false,
                    deadlineText: nil,
                    isFlagged: false,
                    isRevivedAfterInactiveGap: false,
                    sharedEvidenceKinds: []
                ),
                size: statusMarkSize,
                showsDeadlineSignal: false,
                showsTextGloss: true,
                glossFont: .system(size: statusGlossSize, weight: .semibold)
            )
            if count > 1 {
                Text("×\(count)")
                    .font(.system(size: statusGlossSize, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(needsReply ? MessageStatusColors.pendingReply : MessageStatusColors.confirmation)
            }
        }
    }

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

    private var packageMetadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                metadataPrefix
                horizontalCustomCategoryBadges
                Spacer(minLength: 6)
                threadControl
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    metadataPrefix
                    Spacer(minLength: 6)
                    threadControl
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
        rollupMarks
        purposeBadge
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

    /// Stack glyph + message count, then the collapsed-state chevron (right).
    private var threadControl: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                Image(systemName: Self.threadGlyph)
                    .font(.system(size: tier == .lead ? 13 : 12, weight: .semibold))
                Text("\(thread.count)")
                    .font(.system(size: tier == .lead ? 12 : 11, weight: .heavy))
                    .monospacedDigit()
            }
            .foregroundStyle(OhiaColors.textSecondary)
            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OhiaColors.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open thread")
        }
    }

    private var actionCluster: some View {
        HStack(spacing: 2) {
            if let composerTargetID = actionState.composerTargetID {
                ComposeClusterButton(
                    isInQueue: actionState.composerIsInQueue,
                    capturesPressDown: true
                ) {
                    actions.sendToComposer([composerTargetID])
                }
            }
            if !actionState.allMessageIDs.isEmpty {
                clusterButton(
                    glyph: .native(actionState.allResolved ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill"),
                    help: actionState.allResolved ? "Reopen" : "Resolved",
                    tint: MessageStatusColors.resolved
                ) {
                    actions.setResolved(actionState.allMessageIDs, !actionState.allResolved)
                }
                clusterButton(
                    glyph: .native("xmark.bin.circle.fill"),
                    help: "Delete",
                    tint: OhiaColors.ohiaRed
                ) {
                    actions.delete(actionState.allMessageIDs)
                }
                if !actionState.replyActionIDs.isEmpty {
                    clusterButton(
                        glyph: .markReplied,
                        help: "Mark replied",
                        tint: MessageStatusColors.pendingReply
                    ) {
                        actions.setReplied(actionState.replyActionIDs, true)
                    }
                }
                if !actionState.confirmationActionIDs.isEmpty {
                    clusterButton(
                        glyph: .knockout("checkmark.seal.fill"),
                        help: "Mark confirmed",
                        tint: MessageStatusColors.confirmation
                    ) {
                        actions.setConfirmed(actionState.confirmationActionIDs, true)
                    }
                }
                clusterButton(
                    glyph: actionState.allFlagged
                        ? .native("flag.slash.circle.fill")
                        : .native("flag.circle.fill"),
                    help: actionState.allFlagged ? "Unflag thread" : "Flag thread",
                    tint: MessageStatusColors.flagged
                ) {
                    actions.setFlagged(actionState.allMessageIDs, !actionState.allFlagged)
                }
            }
        }
    }

    private func clusterButton(
        glyph: ActionDiscGlyph,
        help: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        ClusterButtonChip(
            glyph: glyph,
            tint: tint,
            help: help,
            capturesPressDown: true,
            action: action
        )
    }

    // MARK: - Style

    private var borderColor: Color {
        if isSelected { return OhiaColors.chipActiveForeground }
        if isGlistening { return OhiaColors.chipActiveBorder }
        return OhiaColors.glassBorder
    }

    private var selectionGlowColor: Color {
        OhiaColors.chipActiveForeground.opacity(0.5)
    }

    private var actionClusterRevealed: Bool { (isHovered || isSelected) && !departingGestureActive }

    private var actionClusterAnimation: Animation {
        guard !reduceMotion else { return Self.actionClusterHideAnimation }
        return actionClusterRevealed
            ? FrontPageCardHoverMotion.stableActionReveal
            : Self.actionClusterHideAnimation
    }

    private var departingGestureActive: Bool {
        actionState.gesture?.action.usesDepartingOverlay == true
    }

    private var actionClusterLayoutClearance: CGFloat {
        FrontPageArticleCard.actionClusterClearance(
            revealed: true,
            restHeight: restHeight,
            padding: padding
        )
    }

    private var departingIconSize: CGFloat {
        switch tier {
        case .lead: return 27
        case .feature: return 23
        case .standard: return 20
        case .brief: return 16
        }
    }

    // MARK: - Per-tier metrics (mirrors FrontPageArticleCard)

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
}

/// The open-state control overlaid on the newest member card while a thread is
/// expanded: the same stack glyph + count as the collapsed package, with the
/// chevron flipped DOWN to read "open." Tapping it closes the thread.
struct FrontPageOpenThreadControl: View {
    let count: Int
    let onClose: () -> Void

    private static let threadGlyph = "square.stack.3d.up.fill"

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                Image(systemName: Self.threadGlyph)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .heavy))
                    .monospacedDigit()
            }
            .foregroundStyle(OhiaColors.textSecondary)
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OhiaColors.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close thread")
        }
    }
}
