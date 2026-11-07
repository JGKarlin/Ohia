import AppKit
import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

// Front Page is a SwiftUI reading workspace. The normal Metal scene should not
// mount for `.frontPage`. Structure mirrors `ProjectsWorkspaceView`:
// HStack(control column, page); the page swaps to the reader on focus.

/// Resolves card selection into the concrete message IDs that status actions
/// mutate. A collapsed thread package is one selected card but represents every
/// member email. Actions invoked from an unselected hover card keep their
/// explicit target, matching the right-click selection behavior.
struct FrontPageSelectionActionScope {
    static func messageIDs(
        requested: [UUID],
        selectedCardIDs: Set<UUID>,
        composition: FrontPageComposition?
    ) -> [UUID] {
        let requested = uniqued(requested)
        guard selectedCardIDs.count > 1, let composition else { return requested }

        let composed = [composition.lead].compactMap { $0 }
            + composition.features
            + composition.sections.flatMap(\.articles)
        var resolvedSelectedCards = Set<UUID>()
        var selectedMessageIDs: [UUID] = []
        var seenMessageIDs = Set<UUID>()

        for article in composed where selectedCardIDs.contains(article.id) {
            guard resolvedSelectedCards.insert(article.id).inserted else { continue }
            let messageIDs = article.thread?.members.map(\.id) ?? [article.id]
            for messageID in messageIDs where seenMessageIDs.insert(messageID).inserted {
                selectedMessageIDs.append(messageID)
            }
        }

        guard resolvedSelectedCards.count > 1 else { return requested }
        let requestedSet = Set(requested)
        let actionBelongsToSelection = requestedSet.isDisjoint(with: resolvedSelectedCards) == false
            || requestedSet.isDisjoint(with: seenMessageIDs) == false
        return actionBelongsToSelection ? selectedMessageIDs : requested
    }

    private static func uniqued(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }
}

struct FrontPageWorkspaceView: View {
    @Bindable var constellationState: ConstellationState
    @Bindable var workspace: FrontPageWorkspaceState
    let dataController: FrontPageDataController
    let modelContext: ModelContext
    let vectorStore: VectorStore
    @Bindable var newStarNavigator: NewStarNavigator
    @Bindable var manualRefresh: ManualRefreshCoordinator
    let summaryByMessageId: [String: String]
    let summaryUnavailableMessageIds: Set<String>
    let regeneratingSummaryMessageIds: Set<String>
    let onStarburstClick: () -> Void
    let onBeaconMenuCommand: (BeaconArrivalMenuRequest) -> Void
    let onMessagesPresented: (Set<String>) -> Void
    let onRequestSummary: (String, OnDemandSummaryScope) -> Void
    let actions: FrontPageMessageActionHandlers
    /// Live custom-category catalog, forwarded to the reader's category
    /// pulldown so it can list user-defined categories alongside the fixed
    /// taxonomy. Sourced from the host's `customCategoryStore.descriptors`.
    let customCategoryCatalog: [CustomMailCategoryDescriptor]
    let showsControlColumn: Bool

    @AppStorage("constellationSidebarSide") private var sidebarSideRaw: String = "leading"

    var body: some View {
        let columnOnLeading = sidebarSideRaw == "trailing"
        HStack(spacing: 0) {
            if showsControlColumn && columnOnLeading { controlColumn(onLeading: true) }

            pageRegion
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsControlColumn && !columnOnLeading { controlColumn(onLeading: false) }
        }
        // The Front Page lens sits on the night sky (starfield only — no Milky
        // Way band), rather than a flat `spaceBackground` fill.
        .background(NightSkyView(showsMilkyWay: false, twinkles: false))
        .background(
            FrontPageEscapeKeyCatcher {
                withAnimation(.easeInOut(duration: 0.16)) {
                    workspace.handleEscape()
                }
            }
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            // Animate the deselect so the masthead's SELECTED stat and the
            // cards' action clusters fade out the same way they fade in.
            withAnimation(.easeInOut(duration: 0.16)) {
                workspace.handleEscape()
            } ? .handled : .ignored
        }
        .onKeyPress(.space) {
            handleSpaceKey() ? .handled : .ignored
        }
        .onAppear { initializeIfNeeded() }
        .onDisappear { dataController.unbind() }
        .onChange(of: workspaceFingerprint) { previous, current in
            handleFingerprintChange(previous: previous, current: current)
        }
        .onChange(of: workspace.currentSnapshot?.builtAt) { _, _ in
            reconcileStatusGestures()
            reconcileOpenThread()
        }
    }

    /// Space toggles the thread under the pointer: opens the hovered package, or
    /// closes the open one. Returns false (so the key falls through to scrolling)
    /// when there is nothing to toggle.
    private func handleSpaceKey() -> Bool {
        // While a member's reader is open on top of an expanded thread, Space
        // belongs to the reader (scroll) — never refold the thread underneath it.
        guard workspace.focusedArticleID == nil else { return false }
        if workspace.openThreadID != nil {
            withAnimation(.smooth(duration: 0.34)) { workspace.closeThread() }
            return true
        }
        guard let hovered = workspace.hoveredArticleID,
              let snapshot = validSnapshot,
              Self.hasThreadPackage(id: hovered, in: snapshot) else {
            return false
        }
        withAnimation(.smooth(duration: 0.5)) { workspace.openThread(hovered) }
        return true
    }

    /// After a snapshot rebuild, close the open thread if its package no longer
    /// exists (e.g. a member was replied / resolved and the conversation
    /// collapsed below 2 in-feed messages).
    private func reconcileOpenThread() {
        guard let openID = workspace.openThreadID,
              let snapshot = workspace.currentSnapshot else { return }
        if Self.hasThreadPackage(id: openID, in: snapshot) == false {
            workspace.closeThread()
        }
    }

    private static func hasThreadPackage(id: UUID, in snapshot: FrontPageSnapshot) -> Bool {
        if let lead = snapshot.composition.lead, lead.id == id { return lead.thread != nil }
        if let feature = snapshot.composition.features.first(where: { $0.id == id }) {
            return feature.thread != nil
        }
        for section in snapshot.composition.sections {
            if let article = section.articles.first(where: { $0.id == id }) {
                return article.thread != nil
            }
        }
        return false
    }

    @ViewBuilder
    private var pageRegion: some View {
        if let article = workspace.focusedArticle {
            let departing = focusedReaderDepartingGesture
            ZStack {
                FrontPageReaderView(
                    article: article,
                    liveSummaries: summaryByMessageId,
                    summaryUnavailableMessageIds: summaryUnavailableMessageIds,
                    isSummaryRegenerating: regeneratingSummaryMessageIds.contains(article.messageIdString),
                    loadReaderPayload: { await dataController.loadReaderPayload(for: $0) },
                    onRequestSummary: onRequestSummary,
                    onBack: { workspace.dismissReader() },
                    actions: gestureActions,
                    searchHighlight: workspace.focusedReaderSearchHighlight,
                    customCategoryCatalog: customCategoryCatalog,
                    onClassificationChanged: { classification, customKeys in
                        // Optimistically reflect the edit in the open reader, then
                        // persist through the shared canonical mutation path.
                        workspace.applyClassificationState(
                            messageID: article.id,
                            classification: classification,
                            customCategoryKeys: customKeys
                        )
                        actions.setClassification(article.id, classification, customKeys)
                    }
                )
                // A resolve / delete on the open reader plays the Collapse in
                // place: the email sheet and its chrome fade out while the inset
                // crumple card below becomes the only thing on screen, then the
                // workspace returns to the grid (the deferred dismissal lives in
                // `FrontPageWorkspaceState`).
                .opacity(departing == nil ? 1 : 0)
                .allowsHitTesting(departing == nil)

                if let departing {
                    FrontPageReaderDepartureCard(gesture: departing)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.28), value: departing != nil)
            .modifier(ComposerDepartureSource(messageIDs: [article.id]))
        } else if workspace.focusedArticleID != nil {
            loadingPage
        } else {
            page
        }
    }

    /// The departing (resolve / delete) gesture playing on the focused reader,
    /// gated on the workspace's own departure marker so only the deferred reader
    /// teardown — never a stray grid-card gesture — drives the in-place Collapse.
    private var focusedReaderDepartingGesture: MessageStatusGesture? {
        guard let id = workspace.departingFocusedArticleID,
              let gesture = workspace.statusGestureCoordinator.gesture(for: id),
              gesture.action.usesDepartingOverlay
        else { return nil }
        return gesture
    }

    @ViewBuilder
    private var page: some View {
        if let snapshot = validSnapshot {
            ZStack(alignment: .top) {
                ScrollView {
                    pageContent(snapshot: snapshot)
                        .padding(.top, FrontPageMastheadView.height)
                }

                FrontPageMastheadView(
                    snapshot: snapshot,
                    selectionCount: workspace.selectedArticleIDs.count
                )
                // Blur into the nebula wash with the rest of the page while a
                // thread package is open.
                .blur(radius: workspace.openThreadID != nil ? 5 : 0)
                .opacity(workspace.openThreadID != nil ? 0.6 : 1)
                .allowsHitTesting(workspace.openThreadID == nil)
                .animation(.smooth(duration: 0.5), value: workspace.openThreadID)
                .zIndex(1)
            }
        } else {
            loadingPage
        }
    }

    private var validSnapshot: FrontPageSnapshot? {
        guard let snapshot = workspace.currentSnapshot,
              FrontPageDataController.signatureMatchesCurrentFilter(
                snapshot: snapshot,
                filter: constellationState.filter,
                selectedTimeRange: constellationState.selectedTimeRange,
                unreadOnly: workspace.unreadOnly
              )
        else { return nil }
        return snapshot
    }

    private func pageContent(snapshot: FrontPageSnapshot) -> some View {
        FrontPageLayoutView(
            snapshot: snapshot,
            workspace: workspace,
            liveSummaries: summaryByMessageId,
            summaryUnavailableIds: summaryUnavailableMessageIds,
            regeneratingSummaryMessageIds: regeneratingSummaryMessageIds,
            customCategoryCatalog: customCategoryCatalog,
            onFocus: { article in workspace.focusArticle(article) },
            onMessagesPresented: onMessagesPresented,
            onRequestSummary: onRequestSummary,
            actions: gestureActions
        )
        // A click that lands on the page background (not a card) — or on a dimmed
        // card while a thread is open (those disable hit-testing so the tap falls
        // through) — closes the open thread, else clears the selection. Live cards
        // consume their own taps, so this only fires off-card / on a dimmed card.
        .contentShape(Rectangle())
        .onTapGesture {
            if workspace.openThreadID != nil {
                withAnimation(.smooth(duration: 0.34)) { workspace.closeThread() }
            } else {
                withAnimation(.easeInOut(duration: 0.16)) { workspace.clearSelection() }
            }
        }
    }

    private var loadingPage: some View {
        OhiaLoadingIndicator(accessibilityLabel: "Loading digest")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 120)
            .background(OhiaColors.spaceBackground)
    }

    @ViewBuilder
    private func controlColumn(onLeading: Bool) -> some View {
        // The action bar fades out with the email sheet during a reader-departure
        // Collapse so the whole focused surface tears down as one, then returns.
        let departing = focusedReaderDepartingGesture != nil
        FrontPageRightControlColumn(
            workspace: workspace,
            onLeading: onLeading,
            newStarNavigator: newStarNavigator,
            manualRefresh: manualRefresh,
            onStarburstClick: onStarburstClick,
            onBeaconMenuCommand: onBeaconMenuCommand,
            actions: gestureActions
        )
        .opacity(departing ? 0 : 1)
        .allowsHitTesting(!departing)
        .animation(.easeOut(duration: 0.28), value: departing)
    }

    private struct WorkspaceFingerprint: Equatable {
        let filterFingerprint: String
        let displayRevision: Int
    }

    private var workspaceFingerprint: WorkspaceFingerprint {
        WorkspaceFingerprint(
            filterFingerprint: FrontPageDataController.snapshotFilterFingerprint(
                baseFilter: constellationState.filter,
                selectedTimeRange: constellationState.selectedTimeRange
            ),
            displayRevision: workspace.displayRevision
        )
    }

    private func initializeIfNeeded() {
        dataController.ensureBound(
            workspace: workspace,
            modelContext: modelContext,
            vectorStore: vectorStore
        )
        refresh()
    }

    private func handleFingerprintChange(
        previous: WorkspaceFingerprint,
        current: WorkspaceFingerprint
    ) {
        if previous.filterFingerprint != current.filterFingerprint {
            workspace.clearForFilterChange()
        }
        refresh()
    }

    private func refresh() {
        dataController.requestRefresh(
            filter: constellationState.filter,
            selectedTimeRange: constellationState.selectedTimeRange
        )
    }

    /// Action handlers that begin a masking gesture before each mutation. Used
    /// for the page, the reader, and the right control column so every surface
    /// drives the same per-message gestures.
    private var gestureActions: FrontPageMessageActionHandlers {
        selectionScopedActions.beginningStatusGestures(with: workspace.statusGestureCoordinator)
    }

    /// When a card inside a multi-selection invokes one of the status actions
    /// requested by the selection contract, route the mutation through every
    /// selected email. This sits before gesture wrapping so each affected card
    /// receives the same immediate action animation. Bulk menus also receive
    /// expanded thread-member IDs, making their labels and delete confirmation
    /// count concrete emails rather than representative cards.
    private var selectionScopedActions: FrontPageMessageActionHandlers {
        var scoped = actions
        let base = actions
        let resolveTargets: ([UUID]) -> [UUID] = { requested in
            FrontPageSelectionActionScope.messageIDs(
                requested: requested,
                selectedCardIDs: workspace.selectedArticleIDs,
                composition: workspace.currentSnapshot?.composition
            )
        }
        scoped.presentBulkMenu = { ids, point, view in
            base.presentBulkMenu(resolveTargets(ids), point, view)
        }
        scoped.setFlagged = { ids, value in
            base.setFlagged(resolveTargets(ids), value)
        }
        scoped.setConfirmed = { ids, value in
            base.setConfirmed(resolveTargets(ids), value)
        }
        scoped.setResolved = { ids, value in
            base.setResolved(resolveTargets(ids), value)
        }
        scoped.delete = { ids in
            base.delete(resolveTargets(ids))
        }
        return scoped
    }

    /// After each snapshot rebuild, clear gestures the page has caught up to.
    private func reconcileStatusGestures() {
        guard let snapshot = workspace.currentSnapshot else { return }
        workspace.statusGestureCoordinator.reconcile { id, gesture in
            Self.isGestureResolved(id: id, gesture: gesture, snapshot: snapshot)
        }
    }

    private static func isGestureResolved(
        id: UUID,
        gesture: MessageStatusGesture,
        snapshot: FrontPageSnapshot
    ) -> Bool {
        guard let article = snapshot.article(id: id) else {
            // Card gone. Keep departing gestures so the card's exit transition
            // can still read the action (they expire via the coordinator's
            // safety window); clear the in-place ones. Flag gestures are
            // coordinator-timed (see below), never resolved here.
            switch gesture.action {
            case .delete, .resolve, .ignore, .sentToComposer, .markReplied, .markConfirmed, .flag: return false
            case .replyNeeded, .confirmationNeeded: return true
            }
        }
        switch gesture.action {
        case .replyNeeded: return article.isActionable
        case .confirmationNeeded: return article.requiresConfirmation
        // Flag gestures settle on the coordinator's floor timer, not on snapshot
        // confirmation, so the place / strike motion always plays its full brief
        // flourish instead of being cut short when a fast rebuild lands (or held
        // when a slow one does). Never resolve them here.
        case .flag: return false
        case .markReplied: return article.isReplied
        case .markConfirmed: return article.isConfirmed
        case .delete, .resolve, .ignore, .sentToComposer: return false
        }
    }
}

/// The focused reader's in-place departure. The same `DepartingGestureOverlay`
/// the grid cards use, but mounted as a single centred, inset card sized to the
/// reading sheet (capped so the pane margin keeps showing the lens backdrop) and
/// scaled up from the card's core icon size for the much larger surface. Each
/// action plays its own field (Black hole / Protostar / Blackbody cooling /
/// Comet); the tint comes from the gesture. Internal (not private) so the
/// Timeline reader reuses the exact same in-place departure card for its
/// delete / resolve / send-to-Composer exit animations.
struct FrontPageReaderDepartureCard: View {
    let gesture: MessageStatusGesture

    var body: some View {
        GeometryReader { geo in
            // Inset ≥ 40pt on every edge, capped to a sheet-like card so the
            // crumple reads as the email leaving — not the whole pane — with the
            // backdrop visible in the surrounding margin.
            let cardWidth = min(geo.size.width - 80, 760)
            let cardHeight = min(geo.size.height - 80, 880)
            DepartingGestureOverlay(
                action: gesture.action,
                gesture: gesture,
                cornerRadius: 18,
                iconSize: 46
            )
            .frame(width: max(0, cardWidth), height: max(0, cardHeight))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }
}

/// SwiftUI `.onKeyPress` only fires while the workspace owns focus; the reader
/// can hand first-responder status to embedded scroll/WebView content. This
/// window-scoped catcher keeps Escape wired to the same workspace ladder while
/// Front Page is mounted.
private struct FrontPageEscapeKeyCatcher: NSViewRepresentable {
    let onEscape: @MainActor () -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.focusRingType = .none
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onEscape = onEscape
    }

    final class CatcherView: NSView {
        var onEscape: (@MainActor () -> Bool)?

        private var monitor: Any?
        private var monitorAttempted = false

        override var acceptsFirstResponder: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, !monitorAttempted {
                monitorAttempted = true
                installMonitor()
            } else if window == nil {
                removeMonitor()
                monitorAttempted = false
            }
        }

        deinit {
            removeMonitor()
        }

        private func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                guard event.keyCode == Self.escapeKeyCode else { return event }
                return self.onEscape?() == true ? nil : event
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private static let escapeKeyCode: UInt16 = 53
    }
}
