import AppKit
import SwiftUI
import SwiftData
import OhiaCore

/// Top-level Timeline workspace. Mounted from `ConstellationModeView` when
/// `state.activeFrame.spatialLens == .timeline`. Stacked top-to-bottom
/// per NLE convention:
///   1. Semantic viewport — selected-message reader (program monitor)
///   2. Time ruler — major/minor ticks, playhead handle, transport bar
///      (prev/next/⏮/⏭, zoom slider, zoom-to-fit)
///   3. Minimap — range navigator showing the entire Moments range
///      with the current viewport drawn as a draggable window
///   4. (conv mode) Chapter strip — thread chapters
///   5. Multitrack — semantic rows + clips + event ticks + playhead
/// The ruler is bonded to the multitrack (ticks align with lanes); the
/// minimap separates them but stays narrow so the alignment still reads.
///
/// The ConstellationTopBar is mounted by ConstellationModeView OUTSIDE
/// this view — it's standardized chrome across every lens and must not
/// be duplicated or shadowed here.
struct TimelineWorkspaceView: View {

    @Bindable var constellationState: ConstellationState
    @Bindable var workspace: TimelineWorkspaceState
    let dataController: TimelineDataController
    let modelContext: ModelContext
    /// Plumbed in from `ConstellationModeView` (`services.vectorStore`) so
    /// `TimelineDataController` can bind it for indexed date-range fetches.
    /// Held by reference — never opened or closed in this layer.
    let vectorStore: VectorStore

    /// Beacon coordinators forwarded into `TimelineRightControlColumn` so
    /// the starburst at the top of the column is the exact same
    /// `NewStarFormationNoticeView` (forming pulse · ready badge · capsule
    /// · failure tint · acknowledge flicker) used by every other lens via
    /// the shared edge column.
    @Bindable var newStarNavigator: NewStarNavigator
    @Bindable var manualRefresh: ManualRefreshCoordinator
    let onStarburstClick: () -> Void
    let onBeaconMenuCommand: (BeaconArrivalMenuRequest) -> Void
    /// Closure invoked when the user right-clicks anywhere in the
    /// Timeline email pane. The parent (`ConstellationModeView`) owns
    /// the menu-builder so the Timeline lens reuses the exact same
    /// NSMenu the constellation scene uses for node right-clicks
    /// (Mark Read / Unread · Flag · Send to Composer · Classification · Delete).
    let onPresentMessageMenu: @MainActor (UUID, NSPoint, NSView) -> Void
    /// Single-message action closures for the current playhead email. This is
    /// the same shared bundle Front Page uses, so read/flag/reply/confirmation
    /// actions flow through one mutation path across lenses.
    let actions: FrontPageMessageActionHandlers
    /// Live custom-category catalog forwarded into the semantic viewport's
    /// masthead classification pulldown so it can list user-defined categories and
    /// render their assigned chips. Supplied by `ConstellationModeView`.
    let customCategoryCatalog: [CustomMailCategoryDescriptor]
    let showsControlColumn: Bool

    @AppStorage("timelineAttachmentSubtracksVisible") private var attachmentSubtracksAppStorage: Bool = true
    @AppStorage("timelineConversationModeEnabled") private var conversationModeAppStorage: Bool = false
    @AppStorage("timelineDefaultZoomTier") private var defaultZoomTierRaw: Int = TimelineZoomTier.weeks.rawValue
    /// AI-layer set, persisted as a comma-separated string per the plan's
    /// `timelineAIDisplayedLayers` (CSV) key (CLAUDE.md §19 display-vs-toggle).
    @AppStorage("timelineAIDisplayedLayers") private var aiLayersCSV: String = ""
    /// Semantic-viewport pane height stored as a fraction of the workspace
    /// height so it adapts to window resize and survives both restarts and
    /// lens switches (TimelineWorkspaceView unmounts when the user leaves
    /// `.timeline` and remounts on return — `@State` would reset the
    /// splitter; `@AppStorage` rehydrates it).
    @AppStorage("timelineSemanticPaneHeightFraction") private var semanticPaneHeightFraction: Double = 0.75
    /// Constellation-wide sidebar-side preference (set by the
    /// ConstellationTopBar's sidebar-side toggle). When this workspace is
    /// mounted standalone with its local rail visible, the rail follows the
    /// same side as the shared outer edge column.
    @AppStorage("constellationSidebarSide") private var sidebarSideRaw: String = "leading"

    @State private var didInitialize: Bool = false
    @State private var pendingLatestMessageSnap: Bool = false
    /// The filter identity represented by the email currently allowed to show
    /// in the semantic viewport. A top-bar filter change makes this differ
    /// from `requestedReaderFilterFingerprint` immediately, blanking the stale
    /// email until the matching Timeline snapshot has installed.
    @State private var installedReaderFilterFingerprint: ReaderFilterFingerprint?
    /// A filter rebuild that has been issued but not yet acknowledged by its
    /// authoritative snapshot. Kept separately from the installed identity so
    /// a rapid A → B → A sequence cannot reveal the old A reader while the B
    /// request is still being superseded.
    @State private var pendingReaderFilterFingerprint: ReaderFilterFingerprint?

    struct ReaderFilterFingerprint: Equatable {
        let preset: TimeRangePreset
        let filter: VectorFilter
    }

    /// The departing (delete / resolve / send-to-Composer) gesture playing on the
    /// playhead message, if any — drives the reader's in-place Collapse / Comet.
    private var readerDepartingGesture: MessageStatusGesture? {
        guard let id = workspace.playheadMessageID,
              let gesture = workspace.statusGestureCoordinator.gesture(for: id),
              gesture.action.usesDepartingOverlay
        else { return nil }
        return gesture
    }

    var body: some View {
        GeometryReader { proxy in
            // Clamp the stored fraction defensively so a stale or corrupt
            // value (e.g. from a much taller window in a prior session)
            // can't collapse a pane below usability.
            let clampedFraction = max(0.15, min(0.85, semanticPaneHeightFraction))
            let topHeight = proxy.size.height * CGFloat(clampedFraction)
            // Derived binding: the splitter still talks in points (so its
            // internal clamps to [120, container-200] read naturally), but
            // every drag tick writes back to the persisted fraction.
            let splitterBinding = Binding<CGFloat>(
                get: { topHeight },
                set: { newHeight in
                    let frac = Double(newHeight) / Double(max(1, proxy.size.height))
                    semanticPaneHeightFraction = max(0.15, min(0.85, frac))
                }
            )

            // When mounted standalone with its local rail visible, mirror
            // the shared outer edge column's side choice.
            let columnOnLeading = sidebarSideRaw == "trailing"
            let readerShowsProgress = readerFilterRefreshIsPending

            HStack(spacing: 0) {
                if showsControlColumn && columnOnLeading {
                    controlColumn(onLeading: true)
                }

                VStack(spacing: 0) {
                    TimelineSemanticViewport(
                        workspace: workspace,
                        constellationState: constellationState,
                        modelContext: modelContext,
                        contentAvailable: !readerShowsProgress,
                        customCategoryCatalog: customCategoryCatalog,
                        actions: actions
                    )
                    .opacity(readerShowsProgress ? 0 : 1)
                    .frame(height: topHeight)
                    .background(
                        // Right-click anywhere in the email pane to
                        // raise the same node context menu used in the
                        // constellation scene. Wraps the entire
                        // semantic viewport rather than only the
                        // header / body / footer rows so any empty
                        // area still surfaces the menu — required by
                        // the design ("Right click anywhere in the
                        // email pane").
                        TimelineEventCatcher(onRightClick: { point, view in
                            guard let messageID = workspace.playheadMessageID else { return }
                            onPresentMessageMenu(messageID, point, view)
                        })
                    )
                    // The playhead message's delete / resolve / send-to-Composer
                    // exit animation. Fade the email sheet + chrome out and let the
                    // same inset crumple card the Front Page focused reader uses
                    // collapse in its place — so the email itself appears to break
                    // down, rather than an animation sitting on top of it.
                    .modifier(TimelineReaderDepartureModifier(gesture: readerDepartingGesture))
                    .modifier(ComposerDepartureSource(messageIDs: Set([workspace.playheadMessageID].compactMap { $0 })))
                    .allowsHitTesting(!readerShowsProgress)
                    .accessibilityHidden(readerShowsProgress)
                    .overlay {
                        if readerShowsProgress {
                            ZStack {
                                OhiaColors.spaceBackground
                                OhiaLoadingIndicator(
                                    accessibilityLabel: workspace.currentSnapshot == nil
                                        ? "Loading timeline"
                                        : "Applying timeline filters"
                                )
                            }
                            .allowsHitTesting(false)
                        }
                    }

                    TimelineWorkspaceSplitter(
                        height: splitterBinding,
                        containerHeight: proxy.size.height,
                        defaultHeight: proxy.size.height * 0.75
                    )

                    // Ruler band — sits between the email-display
                    // viewport and the multitrack canvas. Wired to the
                    // same `workspace.handleScroll` the multitrack uses,
                    // so scroll-wheel scrubbing / zooming feels uniform
                    // across the whole middle space. The semantic
                    // viewport above is intentionally left out — the
                    // user reads email there and we don't want scroll
                    // to scrub away from what they're reading.
                    VStack(spacing: 0) {
                        TimelineRuler(workspace: workspace)

                        TimelineMinimap(workspace: workspace)

                        if conversationModeAppStorage {
                            TimelineChapterStrip(workspace: workspace)
                        }
                    }
                    .background(
                        TimelineEventCatcher(onScroll: { deltaY, modifiers in
                            workspace.handleScroll(deltaY: deltaY, modifiers: modifiers)
                        })
                    )

                    TimelineMultitrackArea(
                        workspace: workspace,
                        constellationState: constellationState,
                        onOpenAttachment: { attachmentID in
                            // Look up the Attachment row, resolve its
                            // on-disk path, and hand it to NSWorkspace.
                            // Mirrors LockedAttachmentsList's open
                            // behaviour so a chip click feels the same
                            // as clicking an attachment row in the
                            // focused-email overlay.
                            let descriptor = FetchDescriptor<Attachment>(
                                predicate: #Predicate<Attachment> { $0.id == attachmentID }
                            )
                            guard let attachment = try? modelContext.fetch(descriptor).first,
                                  let path = attachment.filePath,
                                  FileManager.default.fileExists(atPath: path) else { return }
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                    )
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)

                if showsControlColumn && !columnOnLeading {
                    controlColumn(onLeading: false)
                }
            }
        }
        .background(OhiaColors.spaceBackground)
        .background(
            // ←/→ step the playhead through messages while Timeline is
            // mounted. The catcher self-installs an NSEvent local
            // monitor scoped to this window and filters out events
            // bound for text-input first responders + modified arrows
            // (⌘← / ⌥← / ⇧← / ⌃←) so existing shortcuts still work.
            TimelineKeyboardCatcher(
                onLeftArrow: { workspace.stepPlayhead(direction: .backward) },
                onRightArrow: { workspace.stepPlayhead(direction: .forward) },
                onReturn: {
                    // Return commits a painted bracket: the viewport
                    // zooms to fit the bracket and the bracket itself
                    // clears. Returns `false` when no bracket is set so
                    // the keystroke passes through to other handlers.
                    guard let bracket = workspace.bracketedRange else { return false }
                    workspace.setViewportRange(bracket)
                    workspace.applyBracket(nil)
                    return true
                }
            )
        )
        .onAppear {
            initializeIfNeeded()
        }
        .onDisappear {
            dataController.unbind()
            didInitialize = false
            pendingLatestMessageSnap = false
        }
        .task(id: readerCompletionKey) { @MainActor in
            // Let the child viewport consume `contentAvailable == false` and
            // discard retained body state before a cache-hit snapshot can make
            // the reader eligible again in the next transaction.
            await Task.yield()
            applyPendingLatestMessageSnapIfReady()
            markReaderFilterReadyIfPossible()
        }
        // CLAUDE.md flags chained `.onChange` for hitting Swift type-checker
        // complexity. Collapse the dependency surface into a single
        // fingerprint observer that fans out internally.
        .onChange(of: workspaceFingerprint) { previous, current in
            handleFingerprintChange(previous: previous, current: current)
        }
        // Keep the AppStorage-backed Threads toggle in sync when
        // anything other than the side button drives it — the
        // multitrack's Threads chip and any future programmatic
        // path can mutate `workspace.conversationModeEnabled`
        // directly, and this observer mirrors the change out to
        // persistence so the next launch reads the right value.
        .onChange(of: workspace.conversationModeEnabled) { _, newValue in
            if conversationModeAppStorage != newValue {
                conversationModeAppStorage = newValue
            }
        }
    }

    /// Inputs that drive a snapshot rebuild. Row solo/mute is *not*
    /// included: it's purely visual (controls which rows the canvas
    /// renders) and never affects which messages are fetched. Including
    /// it would trigger a full off-main snapshot rebuild on every gutter
    /// toggle for zero data benefit.
    struct WorkspaceFingerprint: Equatable {
        let preset: TimeRangePreset
        /// Carry the full filter instead of a curated subset. Timeline's
        /// renderer applies SQL-backed date filters and in-memory row
        /// filters; omitting any visible top-bar field here can clear the
        /// expected snapshot signature without requesting a replacement.
        let filter: VectorFilter
        let viewportRange: ClosedRange<Date>
        let pixelsPerDay: Double
        let bracketedRange: ClosedRange<Date>?
        let isolatedCorrespondent: String?
        let aiLayers: Set<TimelineLayoutSnapshot.AIAnnotation.Kind>
        let conversationOn: Bool
        let attachmentsOn: Bool
    }

    private struct LatestEligibleMessageKey: Equatable {
        let signature: TimelineLayoutSignature?
        let messageID: UUID?
        let date: Date?
        let count: Int
    }

    private var workspaceFingerprint: WorkspaceFingerprint {
        WorkspaceFingerprint(
            preset: constellationState.selectedTimeRange,
            filter: constellationState.filter,
            viewportRange: workspace.viewportRange,
            pixelsPerDay: workspace.viewportPixelsPerDay,
            bracketedRange: workspace.bracketedRange,
            isolatedCorrespondent: workspace.isolatedCorrespondentEmail,
            aiLayers: workspace.aiLayers,
            conversationOn: conversationModeAppStorage,
            attachmentsOn: attachmentSubtracksAppStorage
        )
    }

    private var latestEligibleMessageKey: LatestEligibleMessageKey {
        guard let snapshot = workspace.currentSnapshot else {
            return LatestEligibleMessageKey(
                signature: nil,
                messageID: nil,
                date: nil,
                count: 0
            )
        }
        let latest = snapshot.sortedEligibleEntries.last
        return LatestEligibleMessageKey(
            signature: snapshot.signature,
            messageID: latest?.id,
            date: latest?.date,
            count: snapshot.sortedEligibleEntries.count
        )
    }

    private struct ReaderCompletionKey: Equatable {
        let snapshot: LatestEligibleMessageKey
        let requested: ReaderFilterFingerprint
        let pending: ReaderFilterFingerprint?
    }

    private var readerCompletionKey: ReaderCompletionKey {
        ReaderCompletionKey(
            snapshot: latestEligibleMessageKey,
            requested: requestedReaderFilterFingerprint,
            pending: pendingReaderFilterFingerprint
        )
    }

    private func handleFingerprintChange(
        previous: WorkspaceFingerprint,
        current: WorkspaceFingerprint
    ) {
        if previous.preset != current.preset || previous.filter != current.filter {
            pendingReaderFilterFingerprint = ReaderFilterFingerprint(
                preset: current.preset,
                filter: current.filter
            )
        }
        if previous.conversationOn != current.conversationOn {
            workspace.conversationModeEnabled = current.conversationOn
        }
        if previous.attachmentsOn != current.attachmentsOn {
            workspace.attachmentSubtracksVisible = current.attachmentsOn
        }
        // Correspondent isolation propagates into the shared filter so the
        // top bar's Voices chip and Ask scope agree with the multitrack.
        if previous.isolatedCorrespondent != current.isolatedCorrespondent {
            constellationState.filter.correspondentQuery = current.isolatedCorrespondent ?? ""
        }
        // Row solo/mute deliberately doesn't participate in the fingerprint
        // (see `WorkspaceFingerprint`'s doc comment). The old category
        // write-back is intentionally gone; canonical filters are shared.
        // Persist AI-layer toggles + the current zoom tier so they survive
        // launches (plan §State ownership — both keys called out).
        if previous.aiLayers != current.aiLayers {
            aiLayersCSV = TimelinePersistence.encodeAILayers(current.aiLayers)
        }
        if previous.pixelsPerDay != current.pixelsPerDay {
            defaultZoomTierRaw = TimelineZoomTier.tier(forPixelsPerDay: current.pixelsPerDay).rawValue
        }
        // A Moments preset / custom-range change both (a) refits the outer
        // (layout) range to the new timeframe's first → last email and
        // (b) rebuilds the filtered snapshot. Both happen inside
        // `TimelineDataController.requestRefresh` — it detects the scope
        // change (its Moments fit key) and calls `fitOuterRange` before the
        // rebuild, so the ruler / minimap span exactly the selected
        // timeframe. A non-Moments change (correspondent, account, zoom)
        // leaves the fit key unchanged and only rebuilds the snapshot.
        refresh()
    }

    /// Builds the optional local control column for standalone mounting.
    /// The main Constellation shell disables this and mounts the rail at
    /// the far window edge instead.
    private func controlColumn(onLeading: Bool) -> TimelineRightControlColumn {
        TimelineRightControlColumn(
            workspace: workspace,
            conversationModeOn: $conversationModeAppStorage,
            onLeading: onLeading,
            newStarNavigator: newStarNavigator,
            manualRefresh: manualRefresh,
            onStarburstClick: onStarburstClick,
            onBeaconMenuCommand: onBeaconMenuCommand,
            actions: actions
        )
    }

    private func initializeIfNeeded() {
        // Re-attach the controller to its parent-owned collaborators. Uses the
        // idempotent, non-rebaselining `ensureBound` (not `bind`) so a
        // transient lens-transition re-appearance doesn't reset the Moments
        // fit and yank the user's ruler. The outer-range fit is driven by the
        // Moments scope inside `requestRefresh`; genuine entry rebaselines it
        // via `invalidateMomentsFit()` from `ConstellationModeView`.
        dataController.ensureBound(
            workspace: workspace,
            modelContext: modelContext,
            vectorStore: vectorStore
        )
        if didInitialize == false {
            didInitialize = true
            pendingReaderFilterFingerprint = requestedReaderFilterFingerprint
            workspace.conversationModeEnabled = conversationModeAppStorage
            workspace.attachmentSubtracksVisible = attachmentSubtracksAppStorage
            workspace.aiLayers = TimelinePersistence.decodeAILayers(aiLayersCSV)
            // Default zoom tier seeded from `@AppStorage` so a user's
            // preferred zoom persists across launches. The viewport
            // span tracks the slider; here we only stamp the ppd.
            workspace.viewportPixelsPerDay = TimelinePersistence.defaultPixelsPerDay(
                forTier: TimelineZoomTier(rawValue: defaultZoomTierRaw) ?? .weeks
            )
            requestDefaultLatestMessageView()
        }
        refresh()
    }

    /// Timeline's default landing view: fit zoom, normal chronological mode,
    /// and the newest email eligible under the current top-bar filters once
    /// the matching snapshot is available. Moments remains a shared top-bar
    /// filter; entering Timeline must not silently reset it to All Time.
    private func requestDefaultLatestMessageView() {
        pendingLatestMessageSnap = true
        conversationModeAppStorage = false
        workspace.conversationModeEnabled = false
        workspace.resetZoom()
        workspace.applyBracket(nil)
        semanticPaneHeightFraction = 0.75
        workspace.setPlayhead(workspace.outerRange.upperBound)
        refresh()
        applyPendingLatestMessageSnapIfReady()
    }

    private func applyPendingLatestMessageSnapIfReady() {
        guard pendingLatestMessageSnap,
              currentSnapshotMatchesWorkspace else { return }
        if workspace.setPlayheadToLatestEligibleMessage() {
            pendingLatestMessageSnap = false
        }
    }

    private var currentSnapshotMatchesWorkspace: Bool {
        guard let snapshot = workspace.currentSnapshot else { return false }
        return snapshot.viewportRange == workspace.viewportRange
            && dataController.latestSignature.map { snapshot.signature == $0 } ?? true
    }

    private var requestedReaderFilterFingerprint: ReaderFilterFingerprint {
        ReaderFilterFingerprint(
            preset: constellationState.selectedTimeRange,
            filter: constellationState.filter
        )
    }

    private var readerFilterRefreshIsPending: Bool {
        Self.readerFilterRefreshIsPending(
            hasSnapshot: workspace.currentSnapshot != nil,
            installed: installedReaderFilterFingerprint,
            pending: pendingReaderFilterFingerprint,
            requested: requestedReaderFilterFingerprint
        )
    }

    static func readerFilterRefreshIsPending(
        hasSnapshot: Bool,
        installed: ReaderFilterFingerprint?,
        pending: ReaderFilterFingerprint?,
        requested: ReaderFilterFingerprint
    ) -> Bool {
        hasSnapshot == false
            || pending != nil
            || installed != requested
    }

    /// The data controller keeps the previous snapshot installed while a new
    /// filter is computed so the lower Timeline tracks do not collapse. Only
    /// release the reader's loading state after the authoritative replacement
    /// snapshot matches both the current viewport and latest request signature.
    private func markReaderFilterReadyIfPossible() {
        guard Self.readerFilterRefreshCanComplete(
            snapshotMatchesRequest: currentSnapshotMatchesWorkspace,
            pending: pendingReaderFilterFingerprint,
            requested: requestedReaderFilterFingerprint
        ) else {
            return
        }
        installedReaderFilterFingerprint = requestedReaderFilterFingerprint
        pendingReaderFilterFingerprint = nil
    }

    static func readerFilterRefreshCanComplete(
        snapshotMatchesRequest: Bool,
        pending: ReaderFilterFingerprint?,
        requested: ReaderFilterFingerprint
    ) -> Bool {
        snapshotMatchesRequest && pending == requested
    }

    private func refresh() {
        // Self-heal the data controller's binding before requesting. SwiftUI's
        // `onAppear`/`onDisappear` can fire unbalanced when the Timeline scene
        // transiently hosts two workspace views sharing one controller, so a
        // stale `unbind()` may have detached it. `ensureBound` is idempotent
        // and non-destructive when already bound.
        dataController.ensureBound(
            workspace: workspace,
            modelContext: modelContext,
            vectorStore: vectorStore
        )
        dataController.requestRefresh(
            viewportRange: workspace.viewportRange,
            pixelsPerDay: workspace.viewportPixelsPerDay,
            bracketedRange: workspace.bracketedRange,
            filter: constellationState.filter,
            selectedTimeRange: constellationState.selectedTimeRange,
            searchTokens: []
        )
    }

}

/// Plays a departing gesture (delete / resolve / send-to-Composer) as an in-place
/// collapse of the Timeline reader: fades the email sheet + chrome to transparent
/// and swaps in the same inset crumple card the Front Page focused reader uses, so
/// the email itself appears to break down rather than the animation sitting on top.
private struct TimelineReaderDepartureModifier: ViewModifier {
    let gesture: MessageStatusGesture?

    func body(content: Content) -> some View {
        content
            .opacity(gesture == nil ? 1 : 0)
            .allowsHitTesting(gesture == nil)
            .overlay {
                if let gesture {
                    FrontPageReaderDepartureCard(gesture: gesture)
                }
            }
            .animation(.easeOut(duration: 0.28), value: gesture != nil)
    }
}

private struct TimelineWorkspaceSplitter: View {
    @Binding var height: CGFloat
    let containerHeight: CGFloat
    let defaultHeight: CGFloat

    @State private var dragStart: CGFloat?
    @State private var isHovering: Bool = false

    var body: some View {
        ZStack {
            // Hover band — fills the full drag-target height with a faint
            // tint so the splitter reads as a distinct, hit-able region
            // before the user clicks.
            Rectangle()
                .fill(isHovering ? OhiaColors.glassPanel.opacity(0.7) : Color.clear)
            // Centered handle: a 1pt hairline across the full width plus
            // a short capsule grip. Brightens on hover so the affordance
            // is unmistakable.
            VStack(spacing: 2) {
                Rectangle()
                    .fill(isHovering ? OhiaColors.textSecondary : OhiaColors.textTertiary)
                    .frame(height: 1)
                Capsule()
                    .fill(isHovering ? OhiaColors.textPrimary : OhiaColors.textSecondary)
                    .frame(width: 40, height: 3)
            }
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            // `NSCursor.resizeUpDown.set()` replaces the active cursor
            // for the lifetime of the hover; pairing with `.arrow.set()`
            // on hover-end restores the normal pointer when the user
            // moves away. Using `set()` (instead of `push/pop`) avoids
            // the matching-pair fragility that can leave a stale cursor
            // stuck if SwiftUI drops a hover-end event.
            if hovering {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? (height > 0 ? height : defaultHeight)
                    if dragStart == nil { dragStart = start }
                    let proposed = start + value.translation.height
                    height = max(120, min(containerHeight - 200, proposed))
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}
