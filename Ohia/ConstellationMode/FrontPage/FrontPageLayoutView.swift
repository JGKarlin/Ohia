import SwiftUI
import OhiaCore
import OhiaML

/// Gates card hover while an action-driven removal reflows the newspaper grid.
/// The gate intentionally retains no pending hover target: a card that slides
/// under a stationary pointer stays at rest until the user moves the pointer.
struct FrontPageHoverReflowGate {
    private(set) var isSuppressingHover = false

    @discardableResult
    mutating func beginIfCardsWereRemoved(
        previousIDs: [UUID],
        currentIDs: [UUID]
    ) -> Bool {
        let currentIDSet = Set(currentIDs)
        guard previousIDs.contains(where: { currentIDSet.contains($0) == false }) else {
            return false
        }
        isSuppressingHover = true
        return true
    }

    @discardableResult
    mutating func beginIfCardRetirementWasAdded(
        previousIDs: Set<UUID>,
        currentIDs: Set<UUID>
    ) -> Bool {
        guard currentIDs.subtracting(previousIDs).isEmpty == false else {
            return false
        }
        isSuppressingHover = true
        return true
    }

    mutating func endSuppression() {
        isSuppressingHover = false
    }

    func hoverTarget(for articleID: UUID) -> UUID? {
        isSuppressingHover ? nil : articleID
    }
}

/// The modular newspaper grid: a thin masthead, a headline band (lead above
/// the fold + feature cards), then Purpose sections that recede down the
/// page. Width-responsive — feature and section grids collapse columns as the
/// page narrows.
struct FrontPageLayoutView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let snapshot: FrontPageSnapshot
    @Bindable var workspace: FrontPageWorkspaceState
    let liveSummaries: [String: String]
    let summaryUnavailableIds: Set<String>
    let regeneratingSummaryMessageIds: Set<String>
    let customCategoryCatalog: [CustomMailCategoryDescriptor]
    let onFocus: (FrontPageArticle) -> Void
    let onMessagesPresented: (Set<String>) -> Void
    let onRequestSummary: (String, OnDemandSummaryScope) -> Void
    let actions: FrontPageMessageActionHandlers

    // Mosaic sizing: blocks pack into rows of at most `mosaicColumns`, each row
    // filling the width (cells share it equally). Cards use their full natural
    // summary height, with per-tier minimums; pointer activity never reflows rows.
    private let mosaicColumns = 4
    private let mosaicHSpacing: CGFloat = 14
    private let mosaicVSpacing: CGFloat = 16

    /// Keeps a momentary pointer overshoot from hiding actions while the user
    /// is moving toward its newly revealed action cluster. Re-entering any card
    /// cancels the pending collapse immediately.
    @State private var hoverExitTask: Task<Void, Never>?

    /// A card removal animates the surrounding grid for 0.4 seconds. During
    /// that interval hover must not activate whichever card is moving under the
    /// pointer.
    @State private var hoverReflowGate = FrontPageHoverReflowGate()
    @State private var hoverReflowTask: Task<Void, Never>?
    private static let cardRemovalReflowDuration: Double = 0.4
    private static let cardRemovalReflowAnimation = Animation.smooth(
        duration: cardRemovalReflowDuration
    )

    // Per-tier minimums preserve the newspaper proportions for short summaries.
    private let featureCardHeight: CGFloat = 320
    private let standardCardHeight: CGFloat = 236

    /// While a package is open, the rest of the page blurs into a nebula wash
    /// (rather than merely dimming) so the sharp thread cards read as the focus.
    private let openThreadBlurRadius: CGFloat = 5
    private let openThreadRecedeOpacity: CGFloat = 0.6
    private static let threadConnectorSpace = "frontPageThreadConnector"

    // MARK: - Thread packages

    /// Thread info for the package currently open in place, if any.
    private var openThreadInfo: FrontPageThreadInfo? {
        guard let openID = workspace.openThreadID else { return nil }
        return composedArticle(withID: openID)?.thread
    }

    /// The open thread's member ids — the only cards that stay at full intensity
    /// while a package is expanded.
    private var openThreadMemberIDs: Set<UUID> {
        guard let openID = workspace.openThreadID else { return [] }
        return snapshot.threadMemberIDsByArticleID[openID] ?? []
    }

    /// The newest member (first in the open thread's `members`), which carries
    /// the down-chevron "open" control in the package's old top-right corner.
    private var openThreadHeadID: UUID? {
        openThreadInfo?.members.first?.id
    }

    /// Every currently-placed package, keyed by its representative id, so a card
    /// can tell whether to render as a package or a plain card.
    private var threadByArticleID: [UUID: FrontPageThreadInfo] {
        snapshot.threadsByArticleID
    }

    private func composedArticle(withID id: UUID) -> FrontPageComposedArticle? {
        snapshot.composedArticlesByID[id]
    }

    /// True while a package is open and this card is not one of its members —
    /// the receding "everything else" state.
    private func isDimmedByOpenThread(_ id: UUID) -> Bool {
        workspace.openThreadID != nil && !openThreadMemberIDs.contains(id)
    }

    /// True for a collapsed package card (a package that is not the open one).
    private func isCollapsedPackage(_ articleID: UUID) -> Bool {
        threadByArticleID[articleID] != nil && workspace.openThreadID != articleID
    }

    /// True when this card is a member of the currently-open package — the
    /// focus, which must read at full intensity (no age-based read-dimming).
    private func isOpenThreadMember(_ articleID: UUID) -> Bool {
        workspace.openThreadID != nil && openThreadMemberIDs.contains(articleID)
    }

    /// Replaces the open package in a composed list with its member cards
    /// (newest → oldest), so the mosaic packer lays them into the neighbouring
    /// grid spots in place. Everything else passes through unchanged.
    private func expandingOpenThread(_ composed: [FrontPageComposedArticle]) -> [FrontPageComposedArticle] {
        guard workspace.openThreadID != nil else { return composed }
        return composed.flatMap { entry -> [FrontPageComposedArticle] in
            if entry.id == workspace.openThreadID, let members = entry.thread?.members {
                return members
            }
            return [entry]
        }
    }

    private func openPackage(_ id: UUID) {
        withAnimation(.smooth(duration: 0.5)) { workspace.openThread(id) }
    }

    var body: some View {
        pageContent
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .coordinateSpace(name: Self.threadConnectorSpace)
            // The ohiaʻ-yellow thread line, drawn behind the cards so the opaque
            // cards occlude it and it shows only in the gaps between members.
            .backgroundPreferenceValue(FrontPageThreadMemberFrameKey.self) { frames in
                threadConnector(frames: frames)
            }
            // The nebula wash the receded cards blur into while a thread is open.
            .background {
                if workspace.openThreadID != nil { nebulaVeil }
            }
            // Animate the set of rendered cards so a card the rebuilt snapshot
            // drops (after a reply / confirm or a fast departure) eases out with
            // its per-action exit transition rather than vanishing. The second
            // key covers a slow departure that retires locally after its overlay
            // lands, including an expanded thread member that is not represented
            // in the composition's top-level id list.
            .animation(Self.cardRemovalReflowAnimation, value: visibleOrderedIDs)
            .animation(Self.cardRemovalReflowAnimation, value: workspace.retiredDepartingArticleIDs)
            .animation(.smooth(duration: 0.5), value: workspace.openThreadID)
            .onChange(of: visibleOrderedIDs) { previousIDs, currentIDs in
                beginHoverSuppressionIfCardsWereRemoved(
                    previousIDs: previousIDs,
                    currentIDs: currentIDs
                )
            }
            .onChange(of: workspace.retiredDepartingArticleIDs) { previousIDs, currentIDs in
                beginHoverSuppressionIfCardRetirementWasAdded(
                    previousIDs: previousIDs,
                    currentIDs: currentIDs
                )
            }
            .onDisappear {
                hoverExitTask?.cancel()
                hoverExitTask = nil
                hoverReflowTask?.cancel()
                hoverReflowTask = nil
                hoverReflowGate.endSuppression()
                workspace.hoveredArticleID = nil
            }
    }

    /// A soft, heavily-blurred nebula — a few faint coloured clouds over the
    /// night sky — revealed behind the page while a thread is open, so the
    /// blurred receded cards dissolve into deep space and the sharp thread cards
    /// read as the focus. Purely decorative; never hit-tests.
    private var nebulaVeil: some View {
        NightSkyNebulaOverlay()
            .transition(.opacity)
    }

    /// Per-action card-exit transition, read from the message's active gesture so
    /// the way a card leaves matches what the user did. Insertions are identity
    /// (new mail appears in place); only removals animate.
    private func cardExitTransition(for id: UUID) -> AnyTransition {
        let removal: AnyTransition
        switch gestureForCard(id)?.action {
        case .delete, .resolve, .ignore, .sentToComposer:
            // Collapse / launch: the card has already gathered into its dense core
            // (Collapse) or launched away as a comet (send-to-Composer), so the
            // vacated slot converges to a point as the row reflows over it.
            removal = .scale(scale: 0.02, anchor: .center).combined(with: .opacity)
        case .markReplied, .markConfirmed:
            removal = .scale(scale: 0.92, anchor: .center).combined(with: .opacity)
        default:
            removal = .opacity
        }
        return .asymmetric(insertion: .identity, removal: removal)
    }

    private func gestureForCard(_ id: UUID) -> MessageStatusGesture? {
        guard let thread = threadByArticleID[id],
              let article = snapshot.article(id: id) else {
            return workspace.statusGestureCoordinator.gesture(for: id)
        }
        return threadActionState(article: article, thread: thread).gesture
    }

    @ViewBuilder
    private var pageContent: some View {
        if snapshot.isEmpty {
            emptyState
        } else {
            headlineBand
            ForEach(snapshot.composition.sections) { section in
                sectionView(section)
            }
        }
    }

    // MARK: - Headline band

    @ViewBuilder
    private var headlineBand: some View {
        if let leadComposed = snapshot.composition.lead {
            if workspace.openThreadID == leadComposed.id, let members = leadComposed.thread?.members {
                // The lead itself is an opened package: its members fill the lead
                // slot as a feature-tier mosaic in place.
                mosaic(members, forcedTier: .feature, cardHeight: featureCardHeight)
                    .padding(.bottom, 16)
            } else if let lead = renderableArticle(leadComposed) {
                card(article: lead, tier: .lead)
                    .padding(.bottom, 16)
                    .zIndex(isDepartingCard(lead.id) ? 1 : 0)
            }
        }
        if snapshot.composition.features.isEmpty == false {
            mosaic(expandingOpenThread(snapshot.composition.features), forcedTier: .feature, cardHeight: featureCardHeight)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionView(_ section: FrontPageSection) -> some View {
        let isExpanded = workspace.isExpanded(section.purposePresentation)
        let visible: [FrontPageComposedArticle] = isExpanded
            ? section.articles
            : Array(section.shownArticles)

        VStack(alignment: .leading, spacing: 10) {
            FrontPageSectionHeader(
                section: section,
                isExpanded: isExpanded,
                onToggleExpanded: { workspace.toggleExpanded(section.purposePresentation) }
            )
            .blur(radius: workspace.openThreadID != nil ? openThreadBlurRadius : 0)
            .opacity(workspace.openThreadID != nil ? openThreadRecedeOpacity : 1)
            .allowsHitTesting(workspace.openThreadID == nil)
            mosaic(expandingOpenThread(visible), forcedTier: nil, cardHeight: standardCardHeight)
        }
    }

    // MARK: - Card factory

    /// Dispatcher: renders a collapsed **package** card for a thread
    /// representative, or the ordinary article card otherwise, then layers the
    /// open-thread affordances (dim everything that isn't a member of the open
    /// package; the down-chevron close control on the newest member).
    @ViewBuilder
    private func card(
        article: FrontPageArticle,
        tier: FrontPageLayoutTier,
        restHeight: CGFloat? = nil
    ) -> some View {
        Group {
            if let thread = threadByArticleID[article.id], workspace.openThreadID != article.id {
                packageCard(article: article, thread: thread, tier: tier, restHeight: restHeight)
            } else {
                articleCard(article: article, tier: tier, restHeight: restHeight)
            }
        }
        .blur(radius: isDimmedByOpenThread(article.id) ? openThreadBlurRadius : 0)
        .opacity(isDimmedByOpenThread(article.id) ? openThreadRecedeOpacity : 1)
        .allowsHitTesting(!isDimmedByOpenThread(article.id))
        .overlay(alignment: .topTrailing) {
            if article.id == openThreadHeadID, let info = openThreadInfo {
                FrontPageOpenThreadControl(count: info.count) {
                    withAnimation(.smooth(duration: 0.34)) { workspace.closeThread() }
                }
                .padding(openThreadControlPadding(for: tier))
            }
        }
        // Report each open-thread member's frame so the connector line can be
        // drawn through their centers. Only members report (gated), so the
        // preference stays empty on an ordinary page.
        .background {
            if isOpenThreadMember(article.id) {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: FrontPageThreadMemberFrameKey.self,
                        value: [article.id: proxy.frame(in: .named(Self.threadConnectorSpace))]
                    )
                }
            }
        }
        .transition(cardTransition(for: article.id))
    }

    /// Insertion / removal transition per card. An opened thread's member cards
    /// **scale-settle into place** as they populate the grid (matching the
    /// design sandbox); every other card keeps the per-action exit transition,
    /// whose insertion is `.identity` so ordinary new mail still appears in
    /// place without a flourish.
    private func cardTransition(for id: UUID) -> AnyTransition {
        if isOpenThreadMember(id) {
            // Each member carries its own delayed animation so they cascade in
            // newest → oldest rather than arriving together; removal is a plain
            // quick fade (no stagger on close).
            let delay = memberStaggerDelay(for: id)
            return .asymmetric(
                insertion: .scale(scale: 0.75, anchor: .center)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.42).delay(delay)),
                removal: AnyTransition.opacity.animation(.smooth(duration: 0.28))
            )
        }
        return cardExitTransition(for: id)
    }

    /// Newest → oldest stagger (newest = 0) so an opened thread's member cards
    /// arrive in sequence, one beat after another.
    private func memberStaggerDelay(for id: UUID) -> Double {
        guard let members = openThreadInfo?.members,
              let index = members.firstIndex(where: { $0.id == id }) else { return 0 }
        return Double(index) * 0.07
    }

    /// The ʻōhiʻa-yellow "strung thread": a polyline through the open thread's
    /// member centers (newest → oldest), drawn behind the cards so the opaque
    /// cards occlude it and it shows only in the gaps between them. Steps down
    /// where the member run wraps to the next row.
    @ViewBuilder
    private func threadConnector(frames: [UUID: CGRect]) -> some View {
        if let members = openThreadInfo?.members {
            let segments = zip(members, members.dropFirst()).compactMap { source, target -> FrontPageThreadConnectorSegmentGeometry? in
                guard let sourceFrame = frames[source.id], let targetFrame = frames[target.id] else { return nil }
                return FrontPageThreadConnectorSegmentGeometry(
                    id: FrontPageThreadConnectorSegmentID(sourceID: source.id, targetID: target.id),
                    start: CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
                    end: CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                )
            }
            if !segments.isEmpty {
                ZStack {
                    ForEach(segments) { segment in
                        FrontPageThreadConnectorSegmentShape(start: segment.start, end: segment.end)
                            .stroke(
                                OhiaColors.ohiaYellow,
                                style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
                            )
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }

    private func openThreadControlPadding(for tier: FrontPageLayoutTier) -> CGFloat {
        switch tier {
        case .lead: return 20
        case .feature: return 16
        default: return 12
        }
    }

    private func packageCard(
        article: FrontPageArticle,
        thread: FrontPageThreadInfo,
        tier: FrontPageLayoutTier,
        restHeight: CGFloat?
    ) -> some View {
        let memberIDs = Set(thread.members.map { $0.id.uuidString })
        let newArrivalIDs = Set(thread.members.compactMap { member in
            NewMailArrivalLedger.shared.isNewArrival(messageID: member.id)
                ? member.id.uuidString
                : nil
        })
        let unreadIDs = Set(thread.members.compactMap { member in
            snapshot.article(id: member.id)?.isUnread == true
                ? member.id.uuidString
                : nil
        })
        let showsNewArrivalHighlight = FrontPagePackageCard.shouldGlisten(
            memberMessageIDs: memberIDs,
            newArrivalMessageIDs: newArrivalIDs,
            unreadMessageIDs: unreadIDs
        )
        return FrontPagePackageCard(
            article: article,
            thread: thread,
            tier: tier,
            isSelected: workspace.isSelected(article.id),
            isHovered: workspace.hoveredArticleID == article.id,
            liveSummaries: liveSummaries,
            summaryUnavailableIds: summaryUnavailableIds,
            actions: actions,
            actionState: threadActionState(article: article, thread: thread),
            showsNewArrivalHighlight: showsNewArrivalHighlight,
            newArrivalMessageIDs: newArrivalIDs,
            unreadMessageIDs: unreadIDs,
            onPresented: {
                onMessagesPresented(memberIDs.union([article.messageIdString]))
            },
            onReadArrivalMembers: { messageIDs in
                NewMailArrivalLedger.shared.retireReadArrivals(messageIds: messageIDs)
            },
            onOpen: { openPackage(article.id) },
            onSelectClick: { modifiers in
                withAnimation(.easeInOut(duration: 0.16)) {
                    workspace.handleSelectionClick(
                        id: article.id,
                        modifiers: modifiers,
                        orderedIDs: visibleOrderedIDs
                    )
                }
                requestSummaryIfNeeded(for: article)
            },
            onRightClick: { point, view in
                handleRightClick(article: article, isThreadPackage: true, point: point, view: view)
            },
            onHoverChange: { hovering in
                handleHoverChange(hovering, articleID: article.id)
            },
            onRequestSummary: onRequestSummary,
            restHeight: restHeight,
            isInteractionEnabled: !isDimmedByOpenThread(article.id),
            customCategoryCatalog: customCategoryCatalog
        )
        .onContinuousHover { phase in
            handleContinuousHoverPhase(phase, articleID: article.id)
        }
    }

    private func threadActionState(
        article: FrontPageArticle,
        thread: FrontPageThreadInfo
    ) -> FrontPageThreadActionState {
        FrontPageThreadActionState.build(
            representativeID: article.id,
            thread: thread,
            resolveArticle: { snapshot.article(id: $0) },
            gestureForMessageID: { workspace.statusGestureCoordinator.gesture(for: $0) }
        )
    }

    private func articleCard(
        article: FrontPageArticle,
        tier: FrontPageLayoutTier,
        restHeight: CGFloat? = nil
    ) -> some View {
        let isNewArrival = NewMailArrivalLedger.shared.isNewArrival(messageID: article.id)
        return FrontPageArticleCard(
            article: article,
            tier: tier,
            liveSummaries: liveSummaries,
            summaryUnavailableIds: summaryUnavailableIds,
            isSummaryRegenerating: regeneratingSummaryMessageIds.contains(article.messageIdString),
            isHovered: workspace.hoveredArticleID == article.id,
            isSelected: workspace.isSelected(article.id),
            onOpen: { onFocus(article) },
            onSelectClick: { modifiers in
                // Animate the selection change so the action cluster fades in
                // (and the selection ring eases on) the same way it does on
                // hover, rather than snapping in on click.
                withAnimation(.easeInOut(duration: 0.16)) {
                    workspace.handleSelectionClick(
                        id: article.id,
                        modifiers: modifiers,
                        orderedIDs: visibleOrderedIDs
                    )
                }
                requestSummaryIfNeeded(for: article)
            },
            onRightClick: { point, view in
                handleRightClick(article: article, point: point, view: view)
            },
            onHoverChange: { hovering in
                handleHoverChange(hovering, articleID: article.id)
            },
            onRequestSummary: onRequestSummary,
            actions: actions,
            showsNewArrivalHighlight: isNewArrival,
            onPresented: {
                onMessagesPresented([article.messageIdString])
            },
            onBecameRead: {
                NewMailArrivalLedger.shared.retireReadArrivals(
                    messageIds: [article.messageIdString]
                )
            },
            onMarkArrivalVisited: { NewMailArrivalLedger.shared.markVisited(messageId: article.messageIdString) },
            restHeight: restHeight,
            gesture: workspace.statusGestureCoordinator.gesture(for: article.id),
            suppressesReadDimming: isOpenThreadMember(article.id),
            isInteractionEnabled: !isDimmedByOpenThread(article.id),
            customCategoryCatalog: customCategoryCatalog
        )
        .onContinuousHover { phase in
            handleContinuousHoverPhase(phase, articleID: article.id)
        }
    }

    private func handleContinuousHoverPhase(_ phase: HoverPhase, articleID: UUID) {
        switch phase {
        case .active:
            handleHoverChange(true, articleID: articleID)
        case .ended:
            handleHoverChange(false, articleID: articleID)
        }
    }

    private func handleHoverChange(_ hovering: Bool, articleID: UUID) {
        if hovering {
            guard let hoverTarget = hoverReflowGate.hoverTarget(for: articleID) else {
                return
            }
            hoverExitTask?.cancel()
            hoverExitTask = nil
            guard workspace.hoveredArticleID != hoverTarget else { return }
            workspace.hoveredArticleID = hoverTarget
            return
        }

        guard workspace.hoveredArticleID == articleID else { return }
        hoverExitTask?.cancel()
        hoverExitTask = Task { @MainActor in
            do {
                try await Task.sleep(for: FrontPageCardHoverMotion.exitGracePeriod)
            } catch {
                return
            }
            guard workspace.hoveredArticleID == articleID else { return }
            workspace.hoveredArticleID = nil
            hoverExitTask = nil
        }
    }

    private func beginHoverSuppressionIfCardsWereRemoved(
        previousIDs: [UUID],
        currentIDs: [UUID]
    ) {
        guard hoverReflowGate.beginIfCardsWereRemoved(
            previousIDs: previousIDs,
            currentIDs: currentIDs
        ) else {
            return
        }

        suppressHoverDuringCardReflow()
    }

    private func beginHoverSuppressionIfCardRetirementWasAdded(
        previousIDs: Set<UUID>,
        currentIDs: Set<UUID>
    ) {
        guard hoverReflowGate.beginIfCardRetirementWasAdded(
            previousIDs: previousIDs,
            currentIDs: currentIDs
        ) else {
            return
        }

        suppressHoverDuringCardReflow()
    }

    private func suppressHoverDuringCardReflow() {
        hoverExitTask?.cancel()
        hoverExitTask = nil
        hoverReflowTask?.cancel()

        var hoverTransaction = Transaction()
        hoverTransaction.disablesAnimations = true
        withTransaction(hoverTransaction) {
            workspace.hoveredArticleID = nil
        }

        hoverReflowTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(Self.cardRemovalReflowDuration))
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            hoverReflowGate.endSuppression()
            hoverReflowTask = nil
        }
    }

    /// True while a departing (delete / resolve) Collapse gesture owns this card.
    private func isDepartingCard(_ id: UUID) -> Bool {
        workspace.statusGestureCoordinator.gesture(for: id)?.action.usesDepartingOverlay == true
    }

    /// A departing card rides above its row siblings — and its whole row above the
    /// other rows — so the Collapse overlay's overflow (flash / shockwave / ejected
    /// shards reaching past the card edge) draws over the neighbours instead of
    /// being occluded by them. zIndex is read from the stacking container's direct
    /// child, so these are applied in `mosaic` (after the `.frame`), not inside
    /// `card` where a wrapping `.frame` would swallow them.
    private func blockDepartingZ(_ block: MosaicBlock) -> Double {
        block.articleIDs.contains(where: isDepartingCard) ? 1 : 0
    }

    private func rowDepartingZ(_ blocks: [MosaicBlock]) -> Double {
        blocks.contains { blockDepartingZ($0) > 0 } ? 1 : 0
    }

    /// Right-click routing matching the Projects lens: right-clicking a card
    /// that is part of a 2+ multi-selection presents the bulk menu over the
    /// whole set; right-clicking anywhere else collapses the selection to that
    /// one card (standard Finder / Mail behavior) and presents its menu.
    private func handleRightClick(
        article: FrontPageArticle,
        isThreadPackage: Bool = false,
        point: NSPoint,
        view: NSView
    ) {
        let selected = workspace.selectedArticleIDs
        if selected.contains(article.id), selected.count >= 2 {
            let orderedSelection = visibleOrderedIDs.filter { selected.contains($0) }
            actions.presentBulkMenu(orderedSelection, point, view)
        } else {
            withAnimation(.easeInOut(duration: 0.16)) {
                workspace.selectOnly(article.id)
            }
            requestSummaryIfNeeded(for: article)
            if isThreadPackage {
                actions.presentThreadMenu(article.id, point, view)
            } else {
                actions.presentMenu(article.id, point, view)
            }
        }
    }

    private func requestSummaryIfNeeded(for article: FrontPageArticle) {
        guard article.needsOnDemandSummary(
            liveSummaries: liveSummaries,
            unavailableMessageIds: summaryUnavailableIds
        ) else { return }
        onRequestSummary(article.messageIdString, .hover)
    }

    /// Article IDs in the page's visible top-to-bottom order — lead, then
    /// features, then each section's currently-revealed articles. Drives
    /// ⇧-click range selection so a range matches what the eye sees. Only IDs
    /// that resolve to a rendered card are included.
    private var visibleOrderedIDs: [UUID] {
        var ids: [UUID] = []
        if let lead = snapshot.composition.lead, renderableArticle(lead) != nil {
            ids.append(lead.id)
        }
        appendResolved(snapshot.composition.features, into: &ids)
        for section in snapshot.composition.sections {
            let visible = workspace.isExpanded(section.purposePresentation)
                ? section.articles
                : Array(section.shownArticles)
            appendResolved(visible, into: &ids)
        }
        return ids
    }

    private func appendResolved(_ composed: [FrontPageComposedArticle], into ids: inout [UUID]) {
        for entry in composed where renderableArticle(entry) != nil {
            ids.append(entry.id)
        }
    }

    /// Resolves only cards still owned by the page. Successful departing actions
    /// retire locally after their overlay lands, so a stale snapshot cannot mount
    /// the original card again while the authoritative rebuild catches up. A
    /// collapsed package retires as a unit when any member drove its shared exit.
    private func renderableArticle(_ composed: FrontPageComposedArticle) -> FrontPageArticle? {
        guard let article = snapshot.article(composed) else { return nil }
        let threadMemberIDs = composed.thread != nil && workspace.openThreadID != composed.id
            ? (composed.thread?.members.map(\.id) ?? [])
            : []
        guard workspace.hidesCardAfterDeparture(
            messageID: article.id,
            threadMemberIDs: threadMemberIDs
        ) == false else {
            return nil
        }
        return article
    }

    // MARK: - Mosaic

    /// One mosaic cell. A photo article is its own full-height block; two
    /// consecutive photo-less articles stack into one block so the pair fills
    /// the height of a photo card beside it; a lone photo-less article becomes
    /// a single block that stretches to the row height.
    private enum MosaicBlock: Identifiable {
        case single(FrontPageArticle, FrontPageLayoutTier)
        case pair(FrontPageArticle, FrontPageArticle, FrontPageLayoutTier)

        var id: String {
            switch self {
            case .single(let a, _): return "s-\(a.id.uuidString)"
            case .pair(let top, let bottom, _): return "p-\(top.id.uuidString)-\(bottom.id.uuidString)"
            }
        }

        var articleIDs: [UUID] {
            switch self {
            case .single(let a, _): return [a.id]
            case .pair(let top, let bottom, _): return [top.id, bottom.id]
            }
        }
    }

    private func buildBlocks(
        _ composed: [FrontPageComposedArticle],
        forcedTier: FrontPageLayoutTier?
    ) -> [MosaicBlock] {
        var resolved: [(article: FrontPageArticle, tier: FrontPageLayoutTier)] = []
        for c in composed {
            guard let article = renderableArticle(c) else { continue }
            resolved.append((article, forcedTier ?? c.layoutTier))
        }
        var blocks: [MosaicBlock] = []
        var i = 0
        while i < resolved.count {
            let current = resolved[i]
            // Neither a collapsed package nor an opened thread's member card ever
            // pairs — each stays a single full-height block, so a package reads as
            // one card and expanded members flow one-per-column left → right (the
            // newest lands in the package's old slot), rather than stacking into
            // half-height pairs like ordinary photo-less cards do.
            if current.article.imagePath != nil
                || isCollapsedPackage(current.article.id)
                || isOpenThreadMember(current.article.id) {
                blocks.append(.single(current.article, current.tier))
                i += 1
            } else if i + 1 < resolved.count,
                      resolved[i + 1].article.imagePath == nil,
                      !isCollapsedPackage(resolved[i + 1].article.id),
                      !isOpenThreadMember(resolved[i + 1].article.id) {
                blocks.append(.pair(current.article, resolved[i + 1].article, current.tier))
                i += 2
            } else {
                blocks.append(.single(current.article, current.tier))
                i += 1
            }
        }
        return blocks
    }

    @ViewBuilder
    private func blockView(_ block: MosaicBlock, cardHeight: CGFloat) -> some View {
        switch block {
        case .single(let article, let tier):
            card(article: article, tier: tier, restHeight: cardHeight)
        case .pair(let top, let bottom, let tier):
            // Each member owns half the block's rest height (minus the gap), so
            // the pair's minimum matches a single card. Longer summaries grow
            // naturally before any pointer interaction.
            let memberHeight = (cardHeight - mosaicVSpacing) / 2
            VStack(spacing: mosaicVSpacing) {
                card(article: top, tier: tier, restHeight: memberHeight)
                    .zIndex(isDepartingCard(top.id) ? 1 : 0)
                card(article: bottom, tier: tier, restHeight: memberHeight)
                    .zIndex(isDepartingCard(bottom.id) ? 1 : 0)
            }
        }
    }

    @ViewBuilder
    private func mosaic(
        _ composed: [FrontPageComposedArticle],
        forcedTier: FrontPageLayoutTier?,
        cardHeight: CGFloat
    ) -> some View {
        let blocks = buildBlocks(composed, forcedTier: forcedTier)
        let rows = stride(from: 0, to: blocks.count, by: mosaicColumns).map {
            Array(blocks[$0..<min($0 + mosaicColumns, blocks.count)])
        }
        // Mount rows near the viewport rather than every expanded-section
        // image, animated border, and event catcher. Departure sources already
        // track scroll visibility and unregister when their row disappears.
        LazyVStack(spacing: mosaicVSpacing) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                // Top alignment preserves each card's natural summary height.
                HStack(alignment: .top, spacing: mosaicHSpacing) {
                    ForEach(rows[rowIndex]) { block in
                        blockView(block, cardHeight: cardHeight)
                            .frame(maxWidth: .infinity)
                            // zIndex on the HStack's direct child so a departing
                            // card floats over its row siblings as the Collapse
                            // overflow bursts past the card edge.
                            .zIndex(blockDepartingZ(block))
                    }
                }
                // Lift the whole row over the other rows so the overflow that
                // reaches above / below the card is not occluded by adjacent rows.
                .zIndex(rowDepartingZ(rows[rowIndex]))
            }
        }
    }

    private var emptyState: some View {
        OhiaEmptyPaneStateView(
            systemName: "newspaper",
            title: "No mail in this scope",
            detail: "Widen the time range or clear filters to see your digest."
        )
        .padding(.vertical, 80)
    }
}

/// Fixed masthead for the Front Page workspace. It is rendered outside the
/// scroll view so the date/window and counts remain visible while browsing
/// deeper stories.
struct FrontPageMastheadView: View {
    static let height: CGFloat = 86

    let snapshot: FrontPageSnapshot
    let selectionCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(windowLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OhiaColors.textTertiary)
                Spacer(minLength: 12)
                HStack(spacing: 16) {
                    countPill(
                        value: snapshot.composition.unreadCount,
                        label: "unread",
                        positiveColor: OhiaColors.chipActiveForeground
                    )
                    countPill(
                        value: snapshot.composition.replyNeededCount,
                        label: "needs reply",
                        positiveColor: OhiaColors.ohiaYellow
                    )
                    countPill(
                        value: snapshot.composition.confirmationNeededCount,
                        label: "confirmation",
                        positiveColor: OhiaColors.ohiaGreen
                    )
                    countPill(
                        value: snapshot.composition.deadlineInWindowCount,
                        label: "deadline",
                        positiveColor: OhiaColors.ohiaRed
                    )
                    if selectionCount > 0 {
                        countPill(
                            value: selectionCount,
                            label: "selected",
                            positiveColor: OhiaColors.chipActiveForeground
                        )
                            .transition(.opacity)
                    }
                }
            }
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider().overlay(OhiaColors.glassBorder)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 1180, alignment: .leading)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .top)
        .background(OhiaColors.spaceBackground)
    }

    private func countPill(
        value: Int,
        label: String,
        positiveColor: Color
    ) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? positiveColor : OhiaColors.textTertiary)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(OhiaColors.textTertiary)
        }
    }

    private var windowLabel: String {
        guard let range = snapshot.composition.effectiveWindow else { return "No mail in scope" }
        return frontPageWindowLabel(range, relativeTo: snapshot.builtAt)
    }
}

/// Human label for the page's effective window, used in the masthead. Uses a
/// real separator (`→`) for a date range — never ellipsis dots.
func frontPageWindowLabel(_ range: ClosedRange<Date>, relativeTo now: Date) -> String {
    var calendar = Calendar.current
    calendar.timeZone = .current
    let startOfToday = calendar.startOfDay(for: now)
    let oldestDay = calendar.startOfDay(for: range.lowerBound)
    let dayDelta = calendar.dateComponents([.day], from: oldestDay, to: startOfToday).day ?? Int.max
    switch dayDelta {
    case ..<0, 0: return "As of today"
    case 1: return "Past day"
    case 2...6: return "This week"
    case 7...31: return "This month"
    default:
        let lower = frontPageRangeFormatter.string(from: range.lowerBound)
        let upper = frontPageRangeFormatter.string(from: range.upperBound)
        return "\(lower) → \(upper)"
    }
}

private let frontPageRangeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
}()

/// Collects each open-thread member card's frame (in the layout's named
/// coordinate space) so the connector line can be drawn through their centers.
/// Empty on an ordinary page — only member cards contribute.
private struct FrontPageThreadMemberFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// One stable link in the open conversation's newest-to-oldest thread.
private struct FrontPageThreadConnectorSegmentID: Hashable {
    let sourceID: UUID
    let targetID: UUID
}

private struct FrontPageThreadConnectorSegmentGeometry: Identifiable, Equatable {
    let id: FrontPageThreadConnectorSegmentID
    let start: CGPoint
    let end: CGPoint
}

/// A connector segment whose endpoints participate in SwiftUI interpolation.
/// The geometry preference supplies destination frames immediately; animatable
/// endpoint data lets the line track the cards' presentation animation instead
/// of jumping to those destination frames.
private struct FrontPageThreadConnectorSegmentShape: Shape {
    var start: CGPoint
    var end: CGPoint

    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<CGFloat, CGFloat>
    > {
        get {
            AnimatablePair(
                AnimatablePair(start.x, start.y),
                AnimatablePair(end.x, end.y)
            )
        }
        set {
            start = CGPoint(x: newValue.first.first, y: newValue.first.second)
            end = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }
}
