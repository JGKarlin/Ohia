import Foundation
import SwiftUI
import SwiftData
import Observation
import OhiaCore
import OhiaMail
import OhiaML
import OhiaScheduler

/// `@MainActor @Observable` orchestrator: watches the workspace state and
/// the shared `ConstellationState`, dispatches SwiftData fetches, hands
/// pre-fetched value-type rows to `TimelineLayoutEngine` off-main, and
/// stashes the resulting snapshot on `TimelineWorkspaceState.currentSnapshot`.
///
/// Mirrors the architecture of `ConstellationSnapshotLoader` +
/// `ConstellationSnapshotCache` so the lifecycle / cancellation /
/// off-main contract is identical.
@Observable @MainActor
final class TimelineDataController {

    private let cache = TimelineLayoutSnapshotCache()
    private weak var workspaceState: TimelineWorkspaceState?
    private var modelContext: ModelContext?
    /// Indexed source of "which messages have an email date in the viewport
    /// window". `VectorStore` exposes `messageIDsInDateRange` on the
    /// `message_received_at REAL` column (`Message.vectorTimeFilterDate`
    /// at insert time) backed by `idx_vectors_received_at`. Plumbed in via
    /// `bind(...)` from `AppServices` — the data controller holds a
    /// reference but never opens the DB itself.
    private var vectorStore: VectorStore?
    private var refreshTask: Task<Void, Never>?

    /// The latest requested snapshot signature. While a rebuild is in flight,
    /// this points at the pending signature so the parent lens does not treat
    /// the previous all-time snapshot as ready after a Moments change.
    private(set) var latestSignature: TimelineLayoutSignature?
    private var pendingSignature: TimelineLayoutSignature?
    private var dataRevision: UInt64 = 0
    private var installedSnapshotDataRevision: UInt64?
    private var pendingDataRevision: UInt64?
    private var lastRefreshArgs: RefreshArgs?
    private var lastResolvedRefreshRequest: ResolvedRefreshRequest?

    /// Identifies the Moments scope the outer (layout) range was last fitted
    /// to. A change here — picking a different preset, or editing the custom
    /// window — is what re-fits the ruler to the new timeframe's first → last
    /// email. Rolling presets key on the preset alone so a drifting `now`
    /// doesn't constantly refit; `.custom` carries its explicit window.
    private struct MomentsFitKey: Equatable {
        let preset: TimeRangePreset
        let customWindow: ClosedRange<Date>?
    }
    private var lastFittedMomentsKey: MomentsFitKey?

    /// Notification observers for live-refresh on ingestion / deletion /
    /// message attention / account identity changes.
    /// Opted out of `@Observable` tracking via `@ObservationIgnored` so the
    /// macro doesn't synthesize tracked accessors (those reject any
    /// `nonisolated` modifier). The `nonisolated(unsafe)` then lets the
    /// deinit — which Swift 6 treats as nonisolated by default — read the
    /// tokens to deregister from `NotificationCenter`. Tokens are opaque
    /// markers, only mutated on the main actor during `bind` / `unbind`,
    /// and only read in deinit when no other references exist.
    @ObservationIgnored nonisolated(unsafe) private var deletionObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var ingestObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var sentObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var messageAttentionObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var arrivalVisibilityObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var accountIdentityObserver: NSObjectProtocol?

    init() {}

    deinit {
        // Defence in depth — `unbind()` should already have torn down
        // subscriptions when the Timeline view disappeared.
        if let token = deletionObserver { NotificationCenter.default.removeObserver(token) }
        if let token = ingestObserver { NotificationCenter.default.removeObserver(token) }
        if let token = sentObserver { NotificationCenter.default.removeObserver(token) }
        if let token = messageAttentionObserver { NotificationCenter.default.removeObserver(token) }
        if let token = arrivalVisibilityObserver { NotificationCenter.default.removeObserver(token) }
        if let token = accountIdentityObserver { NotificationCenter.default.removeObserver(token) }
    }

    /// Idempotent (re-)attach of the controller to its parent-owned
    /// collaborators (workspace / model context / vector store) plus the
    /// live-refresh observers. Never touches the outer range, so it is safe to
    /// call on every refresh request and on every view (re-)appearance.
    ///
    /// This is the resilience seam for SwiftUI's unbalanced
    /// `onAppear` / `onDisappear`. The Timeline scene can transiently mount
    /// two `TimelineWorkspaceView` instances that share this single
    /// controller (the lens-transition / `if let workspace … else` swap),
    /// so the departing instance's `onDisappear → unbind()` can detach the
    /// controller the surviving instance still needs — leaving the lens
    /// frozen because every `requestRefresh` then bails at its bound-state
    /// guard. Every refresh entry point calls `ensureBound` first so a stale
    /// `unbind()` self-heals before the request is evaluated.
    func ensureBound(
        workspace: TimelineWorkspaceState,
        modelContext: ModelContext,
        vectorStore: VectorStore
    ) {
        let alreadyBound = workspaceState != nil
            && self.modelContext != nil
            && self.vectorStore != nil
        guard alreadyBound == false else { return }
        attach(
            workspace: workspace,
            modelContext: modelContext,
            vectorStore: vectorStore
        )
        // Re-attaching after a spurious `unbind()` must NOT refit the outer
        // range — the workspace's outer range and the user's zoom survive the
        // detach untouched, and `lastFittedMomentsKey` is deliberately left
        // intact by `unbind()` so the next `requestRefresh` (same Moments
        // scope) is a no-op for the fit. A genuine scope change still refits.
    }

    /// Shared ref + observer wiring for `ensureBound`.
    private func attach(
        workspace: TimelineWorkspaceState,
        modelContext: ModelContext,
        vectorStore: VectorStore
    ) {
        self.workspaceState = workspace
        self.modelContext = modelContext
        self.vectorStore = vectorStore
        if deletionObserver == nil { subscribeToLiveRefresh() }
    }

    /// Fit the workspace's outer (layout) range to the first → last email of
    /// the selected Moments window, so the ruler and minimap span exactly the
    /// timeframe in view. `window == nil` (All Time) fits to the full store.
    ///
    /// `destructive` chooses the workspace mutator:
    /// - `true` (`setOuterRange`) — refit the viewport to the new scope. Used
    ///   on a Moments-scope change, the NLE "zoom to fit on scope change."
    /// - `false` (`extendOuterRange`) — preserve the user's current zoom /
    ///   viewport. Used by ingest / deletion live-refresh so a background
    ///   arrival doesn't yank the viewport mid-task.
    @MainActor
    func fitOuterRange(toMomentsWindow window: ClosedRange<Date>?, destructive: Bool) {
        guard let workspace = workspaceState, let vectorStore else { return }
        var bounds = (try? vectorStore.receivedDateBounds(in: window)) ?? nil
        if let modelContext {
            let context = ModelContext(modelContext.container)
            let sent = Self.sentMessagesWithReceiptDate(
                in: window ?? Date.distantPast...Date.distantFuture, context: context
            )
            for message in sent {
                guard let date = message.receivedAt else { continue }
                bounds = (min(bounds?.min ?? date, date), max(bounds?.max ?? date, date))
            }
        }
        let computed = Self.fittedOuterRange(bounds: bounds, window: window, now: Date())
        // Skip the no-op so we don't pointlessly invalidate the cache and
        // trip a fingerprint-driven refresh.
        guard workspace.outerRange != computed else { return }
        if destructive {
            workspace.setOuterRange(computed)
        } else {
            workspace.extendOuterRange(computed)
        }
    }

    /// Pure outer-range computation from the in-window message-date bounds.
    /// Pads degenerate spans (single / tightly-clustered emails) up to a one
    /// hour floor so the projector can subdivide, and falls back to the
    /// nominal window (or `now ± 1 day` for All Time on an empty store) when
    /// the timeframe holds no email.
    nonisolated static func fittedOuterRange(
        bounds: (min: Date, max: Date)?,
        window: ClosedRange<Date>?,
        now: Date
    ) -> ClosedRange<Date> {
        let minSpan = TimelineWorkspaceState.minimumViewportSpan
        if let bounds {
            let span = bounds.max.timeIntervalSince(bounds.min)
            if span < minSpan {
                let pad = (minSpan - span) / 2
                return bounds.min.addingTimeInterval(-pad) ... bounds.max.addingTimeInterval(pad)
            }
            return bounds.min ... bounds.max
        }
        // No email in the window — keep the ruler reading as the selected
        // timeframe when there is one, otherwise a non-zero span around now.
        if let window, window.lowerBound < window.upperBound {
            return window
        }
        return now.addingTimeInterval(-86_400) ... now.addingTimeInterval(86_400)
    }

    /// The currently-selected Moments window, resolved from the last refresh
    /// request. Used by the live-refresh observers to refit the outer range to
    /// the in-scope timeframe (not the whole store) when mail arrives or is
    /// deleted. `nil` for All Time or before the first refresh.
    private func currentMomentsWindow() -> ClosedRange<Date>? {
        guard let args = lastRefreshArgs else { return nil }
        return Self.effectiveTimelineFilter(
            baseFilter: args.filter,
            selectedTimeRange: args.selectedTimeRange
        ).timeRange
    }

    /// Detach observers and drop the cache. Called when the Timeline view
    /// disappears so the data controller doesn't sit attached to
    /// `NotificationCenter` while a different lens is mounted.
    func unbind() {
        if let token = deletionObserver {
            NotificationCenter.default.removeObserver(token)
            deletionObserver = nil
        }
        if let token = ingestObserver {
            NotificationCenter.default.removeObserver(token)
            ingestObserver = nil
        }
        if let token = sentObserver {
            NotificationCenter.default.removeObserver(token)
            sentObserver = nil
        }
        if let token = messageAttentionObserver {
            NotificationCenter.default.removeObserver(token)
            messageAttentionObserver = nil
        }
        if let token = arrivalVisibilityObserver {
            NotificationCenter.default.removeObserver(token)
            arrivalVisibilityObserver = nil
        }
        if let token = accountIdentityObserver {
            NotificationCenter.default.removeObserver(token)
            accountIdentityObserver = nil
        }
        // `unbind` ONLY detaches the live-refresh observers and marks the
        // controller unbound (nils the three collaborator refs). It deliberately
        // preserves ALL resolution caches — in-flight task, `pendingSignature`,
        // `latestSignature`, `lastRefreshArgs`, `lastResolvedRefreshRequest`,
        // `lastFittedMomentsKey`. The reason is the SwiftUI lens-transition
        // churn: `onDisappear` fires (often unbalanced) while the workspace is
        // still on-screen, and `ensureBound` re-attaches on the next refresh.
        // Wiping caches here was catastrophic:
        //   • clearing `pendingSignature` dropped the completed rebuild's
        //     install → the lens froze on the prior snapshot;
        //   • clearing `lastResolvedRefreshRequest` forced every churn cycle to
        //     re-resolve a rolling preset's window from a fresh `Date.now`,
        //     minting a new signature each time → an infinite rebuild loop that
        //     never settled (the large-timeframe "flicks through every email
        //     then crashes" symptom).
        // The build task captures the workspace weakly and it outlives the
        // churn (parent `@State`), so the install lands; only the observers go.
        // Genuine teardown (deinit) and explicit invalidation own cache resets.
        workspaceState = nil
        modelContext = nil
        vectorStore = nil
    }

    /// Force the next `requestRefresh` to refit the outer (layout) range to
    /// the current Moments scope, even if the preset is unchanged. Called on a
    /// genuine lens entry so re-entering Timeline rebaselines the ruler to the
    /// latest data extent (mail may have arrived / been deleted while away).
    func invalidateMomentsFit() {
        lastFittedMomentsKey = nil
    }

    private struct RefreshArgs {
        let viewportRange: ClosedRange<Date>
        let pixelsPerDay: Double
        let bracketedRange: ClosedRange<Date>?
        let filter: VectorFilter
        let selectedTimeRange: TimeRangePreset
        let searchTokens: [String]
    }

    struct RefreshResolutionKey: Equatable {
        let viewportRange: ClosedRange<Date>
        let pixelsPerDay: Double
        let bracketedRange: ClosedRange<Date>?
        let filter: VectorFilter
        let selectedTimeRange: TimeRangePreset
        let searchTokens: [String]
    }

    private struct ResolvedRefreshRequest {
        let key: RefreshResolutionKey
        let effectiveFilter: VectorFilter
    }

    private func subscribeToLiveRefresh() {
        let center = NotificationCenter.default
        // Both observers request `queue: .main`, so the callback runs on the
        // main thread. `MainActor.assumeIsolated` adopts main-actor isolation
        // synchronously without creating a `Task` — this avoids two Swift 6
        // strict-concurrency errors that the `Task { @MainActor in ... }`
        // form trips: (a) capturing the weak `self` `var` in a @Sendable
        // closure, and (b) capturing the non-Sendable `Notification` value
        // across an actor hop.
        deletionObserver = center.addObserver(
            forName: .ohiaDeletionApplied,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleDeletion(note: note)
            }
        }
        // Processed live mail fires `.ohiaIMAPNewInboundMessages` once the
        // row has completed summarization and embedding. The Timeline
        // workspace refreshes then without a manual action.
        ingestObserver = center.addObserver(
            forName: .ohiaIMAPNewInboundMessages,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.markSnapshotDataChanged()
                self?.cache.clearAll()
                // New mail can extend the in-scope timeframe (a just-arrived
                // message now-newer than the prior last email). Refit the
                // outer range to the current Moments window's first → last
                // email, non-destructively so the user's zoom is preserved.
                self?.fitOuterRange(
                    toMomentsWindow: self?.currentMomentsWindow() ?? nil,
                    destructive: false
                )
                self?.refreshIfBound(resolveRollingWindow: true)
            }
        }
        sentObserver = center.addObserver(
            forName: .ohiaMailSendConfirmed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSentConfirmation()
            }
        }
        messageAttentionObserver = center.addObserver(
            forName: .ohiaMessageAttentionChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateAndRefreshIfBound()
            }
        }
        arrivalVisibilityObserver = center.addObserver(
            forName: .ohiaNewMailArrivalVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleArrivalVisibilityChange()
            }
        }
        accountIdentityObserver = center.addObserver(
            forName: .ohiaAccountIdentityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateAndRefreshIfBound()
            }
        }
    }

    private func handleSentConfirmation() {
        guard let workspace = workspaceState, let args = lastRefreshArgs else { return }
        // Follow the newest sent mail when already zoomed to fit. Keep an
        // intentionally zoomed or panned viewport in place.
        let wasFitted = workspace.viewportRange == workspace.outerRange
        invalidateAll(resolveRollingWindow: true)
        fitOuterRange(toMomentsWindow: currentMomentsWindow(), destructive: wasFitted)
        requestRefresh(
            viewportRange: workspace.viewportRange,
            pixelsPerDay: workspace.viewportPixelsPerDay,
            bracketedRange: workspace.bracketedRange,
            filter: args.filter,
            selectedTimeRange: args.selectedTimeRange,
            searchTokens: args.searchTokens
        )
    }

    private func handleDeletion(note: Notification) {
        // Timeline's safest deletion path is to clear every cached snapshot
        // and rebuild from live SwiftData state. The Constellation bridge uses
        // the notification's message and vector IDs for more surgical cleanup.
        _ = note
        markSnapshotDataChanged()
        cache.clearAll()
        // Only fire a fresh refresh when Timeline is the active surface —
        // otherwise the deletion notification (which broadcasts across
        // every lens) would trigger an off-main snapshot rebuild that the
        // user can't see, burning CPU on every delete in a different lens.
        // `unbind()` is called on Timeline disappearance and tears down
        // the observer, so reaching this method implies the workspace is
        // currently bound, but the user may still have left the lens
        // between binding and the notification firing — guard anyway.
        guard workspaceState != nil else { return }
        // Deletion can contract the in-scope timeframe (the first / last email
        // gone). Refit the outer range to the current Moments window's
        // surviving first → last email, non-destructively.
        fitOuterRange(toMomentsWindow: currentMomentsWindow(), destructive: false)
        refreshIfBound(resolveRollingWindow: false)
    }

    private func handleArrivalVisibilityChange() {
        guard workspaceState != nil else { return }
        markSnapshotDataChanged()
        cache.clearAll()
        fitOuterRange(toMomentsWindow: currentMomentsWindow(), destructive: false)
        refreshIfBound(resolveRollingWindow: true)
    }

    @MainActor
    private func refreshIfBound(resolveRollingWindow: Bool) {
        guard let args = lastRefreshArgs else { return }
        cache.clearAll()
        if resolveRollingWindow {
            lastResolvedRefreshRequest = nil
        }
        requestRefresh(
            viewportRange: args.viewportRange,
            pixelsPerDay: args.pixelsPerDay,
            bracketedRange: args.bracketedRange,
            filter: args.filter,
            selectedTimeRange: args.selectedTimeRange,
            searchTokens: args.searchTokens
        )
    }

    /// Trigger a refresh. Coalesces in-flight requests; cancels the prior
    /// task if a new signature has landed.
    func requestRefresh(
        viewportRange: ClosedRange<Date>,
        pixelsPerDay: Double,
        bracketedRange: ClosedRange<Date>?,
        filter: VectorFilter,
        selectedTimeRange: TimeRangePreset,
        searchTokens: [String]
    ) {
        guard let workspace = workspaceState,
              let modelContext,
              let vectorStore else {
            return
        }
        // Refit the layout (outer) range whenever the Moments scope changes,
        // so the ruler / minimap span the first → last email of the selected
        // timeframe instead of the full database. Gated on a scope key — not
        // the per-call resolved window — so rolling-window `now` drift and
        // non-Moments filter toggles (correspondent, account, zoom) don't keep
        // yanking the user's viewport. Destructive (`setOuterRange`) refits the
        // viewport to the new scope, the NLE "zoom to fit on scope change."
        var viewportRange = viewportRange
        var pixelsPerDay = pixelsPerDay
        let fitKey = MomentsFitKey(
            preset: selectedTimeRange,
            customWindow: selectedTimeRange == .custom ? filter.timeRange : nil
        )
        if fitKey != lastFittedMomentsKey {
            lastFittedMomentsKey = fitKey
            let momentsWindow = Self.effectiveTimelineFilter(
                baseFilter: filter,
                selectedTimeRange: selectedTimeRange
            ).timeRange
            fitOuterRange(toMomentsWindow: momentsWindow, destructive: true)
            // The destructive refit rewrote the viewport / zoom; re-read so the
            // signature and the off-main fetch below use the fitted window.
            viewportRange = workspace.viewportRange
            pixelsPerDay = workspace.viewportPixelsPerDay
        }
        lastRefreshArgs = RefreshArgs(
            viewportRange: viewportRange,
            pixelsPerDay: pixelsPerDay,
            bracketedRange: bracketedRange,
            filter: filter,
            selectedTimeRange: selectedTimeRange,
            searchTokens: searchTokens
        )
        let effectiveFilter = effectiveFilterForRequest(
            viewportRange: viewportRange,
            pixelsPerDay: pixelsPerDay,
            bracketedRange: bracketedRange,
            filter: filter,
            selectedTimeRange: selectedTimeRange,
            searchTokens: searchTokens
        )
        let signature = makeSignature(
            filter: effectiveFilter,
            viewportRange: viewportRange,
            bracketedRange: bracketedRange,
            searchTokens: searchTokens,
            pixelsPerDay: pixelsPerDay
        )
        latestSignature = signature
        let requestDataRevision = dataRevision
        if Self.currentSnapshotSatisfiesRequest(
            snapshotSignature: workspace.currentSnapshot?.signature,
            requestedSignature: signature,
            installedDataRevision: installedSnapshotDataRevision,
            currentDataRevision: requestDataRevision
        ) {
            pendingSignature = nil
            pendingDataRevision = nil
            return
        }

        if pendingSignature == signature,
           pendingDataRevision == requestDataRevision,
           refreshTask != nil {
            return
        }

        if let cached = cache.snapshot(for: signature, maxAge: 60) {
            workspace.currentSnapshot = cached
            installedSnapshotDataRevision = requestDataRevision
            pendingSignature = nil
            pendingDataRevision = nil
            return
        }

        refreshTask?.cancel()
        pendingSignature = signature
        pendingDataRevision = requestDataRevision
        let captureFilter = effectiveFilter
        let captureViewport = viewportRange
        let captureBracket = bracketedRange
        let captureTokens = searchTokens
        let capturePPD = pixelsPerDay

        refreshTask = Task { [weak self, weak workspace] in
            guard let self else { return }
            let input = await self.gatherInput(
                modelContext: modelContext,
                vectorStore: vectorStore,
                signature: signature,
                filter: captureFilter,
                viewportRange: captureViewport,
                bracketedRange: captureBracket,
                searchTokens: captureTokens,
                pixelsPerDay: capturePPD
            )
            if Task.isCancelled {
                return
            }
            // `TimelineLayoutEngine.snapshot` and every nested initializer
            // are explicitly `nonisolated`, so the computation safely runs
            // off the main actor inside `Task.detached`. `gatherInput` also
            // runs its SwiftData reads off-main in a private context; the
            // outer `Task` inherits MainActor isolation and resumes here to
            // write the result back without an extra `MainActor.run` hop.
            let snapshot = await Task.detached(priority: .userInitiated) {
                TimelineLayoutEngine.snapshot(input: input)
            }.value
            guard self.pendingSignature == signature,
                  self.pendingDataRevision == requestDataRevision,
                  self.dataRevision == requestDataRevision else {
                return
            }
            self.cache.store(snapshot)
            workspace?.currentSnapshot = snapshot
            self.installedSnapshotDataRevision = requestDataRevision
            self.pendingSignature = nil
            self.pendingDataRevision = nil
            self.refreshTask = nil
        }
    }

    nonisolated static func currentSnapshotSatisfiesRequest(
        snapshotSignature: TimelineLayoutSignature?,
        requestedSignature: TimelineLayoutSignature,
        installedDataRevision: UInt64?,
        currentDataRevision: UInt64
    ) -> Bool {
        snapshotSignature == requestedSignature
            && installedDataRevision == currentDataRevision
    }

    /// Invalidate cached snapshots that cover a given date (e.g., after a
    /// new message lands). Caller typically calls `requestRefresh` next.
    func invalidate(coveringDate date: Date) {
        markSnapshotDataChanged()
        cache.invalidate(coveringDate: date)
    }

    func invalidate(messageIDs: Set<UUID>) {
        markSnapshotDataChanged()
        cache.invalidate(messageIDs: messageIDs)
    }

    func invalidateAll(resolveRollingWindow: Bool = true) {
        markSnapshotDataChanged()
        cache.clearAll()
        refreshTask?.cancel()
        refreshTask = nil
        pendingSignature = nil
        pendingDataRevision = nil
        if resolveRollingWindow {
            lastResolvedRefreshRequest = nil
        }
    }

    func invalidateAndRefreshIfBound(resolveRollingWindow: Bool = false) {
        invalidateAll(resolveRollingWindow: resolveRollingWindow)
        refreshIfBound(resolveRollingWindow: resolveRollingWindow)
    }

    func cancelInFlight() {
        refreshTask?.cancel()
        refreshTask = nil
        pendingSignature = nil
        pendingDataRevision = nil
    }

    private func markSnapshotDataChanged() {
        dataRevision &+= 1
    }

    // MARK: - Private

    nonisolated static func signature(
        filter: VectorFilter,
        viewportRange: ClosedRange<Date>,
        bracketedRange: ClosedRange<Date>?,
        searchTokens: [String],
        pixelsPerDay: Double
    ) -> TimelineLayoutSignature {
        // Pass the optional sets through untouched so the cache can
        // tell `nil` (default-all) apart from `Set()` (explicit
        // empty-set filter). Collapsing them previously caused the
        // snapshot to be reused when the user filtered everything
        // out — the stale message kept rendering in the email pane.
        let accountIDs = filter.accountIds
        let correspondentEmails: Set<String> = filter.correspondentQuery.isEmpty
            ? []
            : [filter.correspondentQuery.lowercased()]
        let purposes = filter.purposes
        return TimelineLayoutSignature(
            accountIDs: accountIDs,
            correspondentEmails: correspondentEmails,
            purposes: purposes,
            statusFingerprint: filterFingerprint(filter),
            presetWindow: viewportRange,
            bracketedWindow: bracketedRange,
            searchTokens: searchTokens,
            zoomTier: TimelineZoomTier.tier(forPixelsPerDay: pixelsPerDay)
        )
    }

    private func makeSignature(
        filter: VectorFilter,
        viewportRange: ClosedRange<Date>,
        bracketedRange: ClosedRange<Date>?,
        searchTokens: [String],
        pixelsPerDay: Double
    ) -> TimelineLayoutSignature {
        Self.signature(
            filter: filter,
            viewportRange: viewportRange,
            bracketedRange: bracketedRange,
            searchTokens: searchTokens,
            pixelsPerDay: pixelsPerDay
        )
    }

    nonisolated static func effectiveTimelineFilter(
        baseFilter: VectorFilter,
        selectedTimeRange: TimeRangePreset,
        now: Date = Date.now
    ) -> VectorFilter {
        ConstellationFilterResolver.effectiveSceneFilter(
            baseFilter: baseFilter,
            selectedTimeRange: selectedTimeRange,
            now: now
        )
    }

    private func effectiveFilterForRequest(
        viewportRange: ClosedRange<Date>,
        pixelsPerDay: Double,
        bracketedRange: ClosedRange<Date>?,
        filter: VectorFilter,
        selectedTimeRange: TimeRangePreset,
        searchTokens: [String]
    ) -> VectorFilter {
        let key = Self.refreshResolutionKey(
            viewportRange: viewportRange,
            pixelsPerDay: pixelsPerDay,
            bracketedRange: bracketedRange,
            filter: filter,
            selectedTimeRange: selectedTimeRange,
            searchTokens: searchTokens
        )
        if let resolved = lastResolvedRefreshRequest,
           resolved.key == key {
            return resolved.effectiveFilter
        }
        let effective = Self.effectiveTimelineFilter(
            baseFilter: filter,
            selectedTimeRange: selectedTimeRange
        )
        lastResolvedRefreshRequest = ResolvedRefreshRequest(
            key: key,
            effectiveFilter: effective
        )
        return effective
    }

    nonisolated static func refreshResolutionKey(
        viewportRange: ClosedRange<Date>,
        pixelsPerDay: Double,
        bracketedRange: ClosedRange<Date>?,
        filter: VectorFilter,
        selectedTimeRange: TimeRangePreset,
        searchTokens: [String]
    ) -> RefreshResolutionKey {
        var normalizedFilter = filter
        if selectedTimeRange != .custom {
            normalizedFilter.timeRange = nil
        }
        return RefreshResolutionKey(
            viewportRange: viewportRange,
            pixelsPerDay: pixelsPerDay,
            bracketedRange: bracketedRange,
            filter: normalizedFilter,
            selectedTimeRange: selectedTimeRange,
            searchTokens: searchTokens
        )
    }

    nonisolated private static func filterFingerprint(_ filter: VectorFilter) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(filter),
              let encoded = String(data: data, encoding: .utf8) else {
            return String(describing: filter)
        }
        return encoded
    }

    /// Main-actor prelude for the off-main gather: flushes pending main-context
    /// changes and snapshots the arrival ledger, then runs the entire SwiftData
    /// read + projection in a detached pass over a fresh background context so
    /// the main thread stays free for clicks while thousands of rows decode.
    private func gatherInput(
        modelContext: ModelContext,
        vectorStore: VectorStore,
        signature: TimelineLayoutSignature,
        filter: VectorFilter,
        viewportRange: ClosedRange<Date>,
        bracketedRange: ClosedRange<Date>?,
        searchTokens: [String],
        pixelsPerDay: Double
    ) async -> TimelineLayoutEngine.Input {
        try? modelContext.save()
        let arrivals = NewMailArrivalLedger.shared.gatherSnapshot()
        let container = modelContext.container
        return await Task.detached(priority: .userInitiated) {
            Self.gatherDetached(
                container: container,
                vectorStore: vectorStore,
                signature: signature,
                filter: filter,
                viewportRange: viewportRange,
                bracketedRange: bracketedRange,
                pixelsPerDay: pixelsPerDay,
                arrivals: arrivals
            )
        }.value
    }

    /// Confirmed sends are durable before embedding. Fetch the authored
    /// subset, then compare dates in memory: optional Date predicates can
    /// silently return no rows on the current SwiftData runtime.
    private nonisolated static func sentMessagesWithReceiptDate(
        in range: ClosedRange<Date>, context: ModelContext
    ) -> [Message] {
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { message in
            message.isSentByUser
        })
        return ((try? context.fetch(descriptor)) ?? []).filter { message in
            guard !message.isTrashed, let date = message.receivedAt else { return false }
            return range.contains(date)
        }
    }

    /// The gather itself: fetches SwiftData rows in its own background
    /// `ModelContext` and converts them to value-type engine inputs. Fully
    /// synchronous — no suspension point exists while fetched models are
    /// alive, so no model or relationship fault ever survives an actor
    /// re-entrancy boundary.
    private nonisolated static func gatherDetached(
        container: ModelContainer,
        vectorStore: VectorStore,
        signature: TimelineLayoutSignature,
        filter: VectorFilter,
        viewportRange: ClosedRange<Date>,
        bracketedRange: ClosedRange<Date>?,
        pixelsPerDay: Double,
        arrivals: NewMailArrivalLedger.GatherSnapshot
    ) -> TimelineLayoutEngine.Input {
        let modelContext = ModelContext(container)
        let effective = TimelineFilterIntersection.intersect(
            filter: filter,
            viewportRange: viewportRange,
            bracketedRange: bracketedRange
        )
        let lower = effective.timeRange?.lowerBound ?? viewportRange.lowerBound
        let upper = effective.timeRange?.upperBound ?? viewportRange.upperBound

        var messages: [TimelineLayoutEngine.MessageRow] = []
        var threads: [TimelineLayoutEngine.ThreadRow] = []
        var attachments: [TimelineLayoutEngine.AttachmentRow] = []
        var aiAnnotations: [TimelineLayoutSnapshot.AIAnnotation] = []
        var threadOutstanding: [UUID: TimelineUnresolvedHeuristic.ThreadOutstanding] = [:]
        let triageDecoder = JSONDecoder()
        // Live custom-category catalog keys, resolved once per rebuild so
        // row decode can intersect raw `custom.*` CSV tokens against the
        // catalog (removed categories drop out of the timeline immediately).
        let customCategoryCatalogKeys = CustomMailCategoryCatalog.allKeys(in: modelContext)
        // Display names for the multitrack category-row chips.
        let customCategoryNamesByKey = Dictionary(
            uniqueKeysWithValues: CustomMailCategoryCatalog.descriptors(in: modelContext)
                .map { ($0.key, $0.displayName) }
        )

        // Primary path: ask `VectorStore` for the distinct message UUIDs
        // whose `message_received_at` (= `Message.vectorTimeFilterDate` at
        // insert time) is in `[lower, upper]`. This rides
        // `idx_vectors_received_at` so the scan is O(log n) over the
        // vector rows — at 100k messages this is sub-millisecond vs the
        // hundreds-of-ms a full SwiftData fetch took. SwiftData's
        // `#Predicate` can't be used directly because the
        // `(receivedAt in window) || (receivedAt == nil && sentAt in window)`
        // expression times out the macro type-checker; the split form
        // compiles but translates to SQL that matches nothing under the
        // macOS 26 SDK (Constellation hit this and silently emptied).
        let vectorRangeIDs: Set<UUID>
        do {
            vectorRangeIDs = try vectorStore.messageIDsInDateRange(lower ... upper)
        } catch {
            // Fail-soft: an SQL prepare failure here would otherwise empty
            // the multitrack on a degraded store. Surface the error in the
            // logs (logger framework not wired into this layer yet) and
            // proceed with the SwiftData-only path so the user still sees
            // their sent-only messages.
            assertionFailure("VectorStore.messageIDsInDateRange failed: \(error)")
            vectorRangeIDs = []
        }

        // Secondary path: catch messages whose `receivedAt` is nil but
        // `sentAt` is in the window (the "sent-but-not-received" case —
        // typically drafts moved to Sent or messages where the server did
        // not stamp a Received date). `message_received_at` was populated
        // from `receivedAt ?? sentAt`, so these rows are *already* in
        // `vectorRangeIDs` once they've been embedded. This fetch only
        // matters for the sliver of messages that have `receivedAt == nil`
        // AND no vector row yet (rare; bounded by the embed queue).
        // Single-attribute predicates on stored `Date` properties compile
        // and execute reliably — the prior union form was the one that
        // miscompiled.
        let sentOnlyDescriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { msg in
                msg.receivedAt == nil
                    && msg.sentAt != nil
                    && msg.sentAt! >= lower
                    && msg.sentAt! <= upper
            }
        )
        let sentOnlyMessages = ((try? modelContext.fetch(sentOnlyDescriptor)) ?? [])
            .filter { !$0.isTrashed }

        // Materialize the vector-indexed UUIDs as `Message` rows via a
        // single primary-key `IN`-style predicate. SwiftData lowers
        // `Set<UUID>.contains(msg.id)` to an indexed `WHERE id IN (...)`
        // — identical access pattern to the existing single-id callsites
        // in `ConstellationModeView` (see `$0.id == uuid`), just batched.
        let fetchedFromVectors: [Message]
        if vectorRangeIDs.isEmpty {
            fetchedFromVectors = []
        } else {
            let idSet = vectorRangeIDs
            let descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { msg in
                    idSet.contains(msg.id)
                }
            )
            fetchedFromVectors = ((try? modelContext.fetch(descriptor)) ?? [])
                .filter { !$0.isTrashed }
        }

        // Sent ingestion supplies receivedAt before embedding finishes.
        // Include those rows immediately, using the same canonical date as
        // the vector index; incoming mail still follows its readiness gate.
        let sentWithReceipt = Self.sentMessagesWithReceiptDate(
            in: lower...upper, context: modelContext
        )
        var byID: [UUID: Message] = [:]
        byID.reserveCapacity(fetchedFromVectors.count + sentOnlyMessages.count + sentWithReceipt.count)
        for msg in fetchedFromVectors { byID[msg.id] = msg }
        for msg in sentOnlyMessages { byID[msg.id] = msg }
        for msg in sentWithReceipt { byID[msg.id] = msg }
        // Live arrivals stay invisible until their unified arrival moment
        // (starburst/dock badge, sound, system notification). Filtered at
        // the merge so every downstream structure — message rows, threads,
        // attention, project inputs — sees one consistent universe.
        let fetchedRaw = byID.values.filter { msg in
            msg.isSentByUser
                || arrivals.isEmbargoed(
                    messageID: msg.id,
                    liveDetectedAt: msg.liveDetectedAt
                ) == false
        }
        // The unresolved-thread heuristic depends on processing messages in
        // chronological order (so "sent message landed after the last
        // received" can be observed correctly). SwiftData's fetch order is
        // not guaranteed; sort here before the per-message loop.
        let fetched = fetchedRaw.sorted { lhs, rhs in
            let lhsDate = lhs.vectorTimeFilterDate ?? Date.distantPast
            let rhsDate = rhs.vectorTimeFilterDate ?? Date.distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        // Thread assignment reads the persisted `Message.thread`
        // relationship populated by `ThreadAssigner` at ingest time —
        // header graph per message, plus the subject fallback reconciliation
        // run at ingestion milestones (seed / backfill completion).
        // Using the persisted relationship — instead of running the
        // union-find over `fetched` here — means a thread is grouped
        // by every member ingested into the database, not just the
        // ones that happen to fall inside the current viewport's
        // date range. Singletons (messages whose thread is `nil`)
        // render as orphan chapters; that includes both genuinely
        // single-message conversations and threads whose other
        // members were never ingested (e.g. user selected a narrow
        // history window during onboarding).
        var threadMap: [UUID: TimelineLayoutEngine.ThreadRow] = [:]

        // Build account UUID → (display name, colorIndex) lookup so the
        // .account row chip can render a human-readable name and the
        // per-row context ticks can paint with the account's
        // `AccountColorPalette` hue. Cheap: there are typically 1–4
        // accounts on a personal install.
        let accountDescriptor = FetchDescriptor<Account>()
        struct AccountInfo {
            let displayName: String
            let colorIndex: Int
        }
        let accountsByID: [UUID: AccountInfo] = ((try? modelContext.fetch(accountDescriptor)) ?? [])
            .reduce(into: [:]) { dict, account in
                dict[account.id] = AccountInfo(
                    displayName: account.displayName,
                    colorIndex: account.colorIndex ?? AccountColorPalette.defaultIndex
                )
            }
        let actionState = ProjectLensActionRepository(modelContext: modelContext)
            .actionState(accountScopeKey: ProjectsDataController.accountScopeKey(for: filter))
        let attentionByMessageID = MessageAttentionResolver.states(
            messages: fetched.compactMap { message in
                Self.attentionInput(for: message, decoder: triageDecoder)
            },
            userActions: MessageAttentionUserActionState(projectActions: actionState)
        )
        let freshStartActiveWindow = ProjectFreshStartPolicy.activeWindow(
            modelContext: modelContext,
            filter: filter
        )
        let semanticStatusInputs = fetched.compactMap { msg -> ProjectMessageInput? in
            guard let date = msg.vectorTimeFilterDate else { return nil }
            let decodedTriageVerdict = Self.decodeTriageVerdict(
                msg.analysis?.triageVerdictJSON,
                decoder: triageDecoder,
                isSentByUser: msg.isSentByUser
            )
            let triageVerdict = msg.isLiveInboundTriageEligible ? decodedTriageVerdict : nil
            let dimensions = Self.decodeDimensions(
                msg.analysis?.dimensionsJSON,
                decoder: triageDecoder,
                scrubTriageActionState: !msg.isLiveInboundTriageEligible
            )
            return ProjectMessageInputBuilder.projectInput(
                for: msg,
                date: date,
                dimensions: dimensions,
                triageVerdict: triageVerdict
            )
        }
        // Every SwiftData read below happens synchronously in this pass's own
        // background context — no suspension point exists while these fetched
        // models are alive, so no relationship fault can be detached by a
        // concurrent store merge. Only Sendable value rows leave this pass.
        for msg in fetched {
            guard let date = msg.vectorTimeFilterDate else { continue }
            let decodedTriageVerdict = Self.decodeTriageVerdict(
                msg.analysis?.triageVerdictJSON,
                decoder: triageDecoder,
                isSentByUser: msg.isSentByUser
            )
            let triageVerdict = msg.isLiveInboundTriageEligible ? decodedTriageVerdict : nil
            let dimensions = Self.decodeDimensions(
                msg.analysis?.dimensionsJSON,
                decoder: triageDecoder,
                scrubTriageActionState: !msg.isLiveInboundTriageEligible
            )
            let customCategoryKeys = Set(CustomCategoryKeysJSON.decode(
                msg.analysis?.customCategoryKeysJSON
            ))
                .intersection(customCategoryCatalogKeys)
            let attention = attentionByMessageID[msg.id]
                ?? MessageAttentionState(messageID: msg.id, openKinds: [])
            let isResolved = actionState.resolvedMessageIDs.contains(msg.id)
            let isReplied = Self.isReplied(message: msg, attention: attention, actionState: actionState)
            let isConfirmed = actionState.confirmedMessageIDs.contains(msg.id)
            let filterRow = Self.messageFilterRow(
                for: msg,
                date: date,
                customCategoryKeys: customCategoryKeys,
                triageVerdict: triageVerdict,
                isActionable: attention.needsReply,
                requiresConfirmation: attention.needsConfirmation,
                isReplied: isReplied,
                isConfirmed: isConfirmed,
                isResolved: isResolved
            )
            guard ConstellationMessageFilter.matches(filterRow, filter: effective) else { continue }
            let purposeState = TimelinePurposeState(classification: filterRow.mailClassification)

            // Extract recipients (To / Cc / Bcc) preserving role so the
            // .receiver row chip can group them. From is intentionally
            // excluded — the sender is already surfaced via .sender row
            // from `fromAddress` / `fromName`.
            var recipients: [TimelineLayoutSnapshot.Recipient] = []
            for link in msg.participants {
                guard let participant = link.participant else { continue }
                let email = participant.emailAddress.lowercased()
                guard email.isEmpty == false else { continue }
                let displayName = Self.timelineRecipientDisplayName(
                    for: msg,
                    participant: participant
                )
                let role: TimelineLayoutSnapshot.Recipient.Role
                switch link.role {
                case .from:
                    continue
                case .to:
                    role = .to
                case .cc:
                    role = .cc
                case .bcc:
                    role = .bcc
                }
                recipients.append(
                    TimelineLayoutSnapshot.Recipient(
                        email: email,
                        displayName: displayName,
                        role: role
                    )
                )
            }
            let accountInfo = msg.accountID.flatMap { accountsByID[$0] }
            let accountName = accountInfo?.displayName ?? ""
            let accountColorIndex = accountInfo?.colorIndex ?? AccountColorPalette.defaultIndex
            let decodedSubject = MIMEHeaderDecoder.decodeEncodedWords(msg.subject)
            let decodedFromName = msg.fromName.map(MIMEHeaderDecoder.decodeEncodedWords)

            messages.append(
                TimelineLayoutEngine.MessageRow(
                    id: msg.id,
                    threadID: msg.thread?.id,
                    date: date,
                    purposeState: purposeState,
                    customCategories: customCategoryKeys
                        .map { key in
                            TimelineLayoutSnapshot.CustomCategoryTag(
                                key: key,
                                displayName: customCategoryNamesByKey[key] ?? key
                            )
                        }
                        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending },
                    subject: decodedSubject,
                    isSentByUser: msg.isSentByUser,
                    hasAttachments: msg.hasAttachments,
                    fromAddress: msg.fromAddress,
                    fromName: decodedFromName,
                    recipients: recipients,
                    accountID: msg.accountID,
                    accountName: accountName,
                    accountColorIndex: accountColorIndex,
                    isRead: msg.isReadOrFalse,
                    isListIgnoreEligible: MailingListIgnoreRuleService.isEligibleList(
                        hasListID: msg.listId?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty == false,
                        purpose: filterRow.mailClassification?.purpose
                    ),
                    isActionable: attention.needsReply,
                    isInComposerQueue: msg.isComposerQueueEligible,
                    requiresConfirmation: attention.needsConfirmation,
                    isReplied: isReplied,
                    isConfirmed: isConfirmed,
                    hasDeadline: dimensions?.deadlines.isEmpty == false,
                    deadlineText: dimensions?.primaryDeadlineDisplayText,
                    isResolved: isResolved,
                    isFlagged: msg.flaggedOrFalse,
                    isRevivedAfterInactiveGap: false,
                    sharedEvidenceKinds: []
                )
            )

            if let thread = msg.thread, threadMap[thread.id] == nil {
                threadMap[thread.id] = TimelineLayoutEngine.ThreadRow(
                    id: thread.id,
                    subjectRoot: thread.subjectRoot,
                    participantCount: thread.participantCount
                )
            }

            if msg.hasAttachments {
                for att in msg.attachments {
                    let kind = TimelineAttachmentKind.classify(
                        mimeType: att.mimeType,
                        fileName: att.filename
                    )
                    // Filenames from RFC 2231 / 2047 headers arrive
                    // pre-encoded (e.g. `=?UTF-8?B?...?=`). Decode before
                    // surfacing to the chip so the user sees the actual
                    // filename, not the wire form.
                    let displayName = MIMEHeaderDecoder.decodeEncodedWords(att.filename)
                    attachments.append(
                        TimelineLayoutEngine.AttachmentRow(
                            id: att.id,
                            parentMessageID: msg.id,
                            kind: kind,
                            name: displayName
                        )
                    )
                }
            }

            // Surface only open shared-attention states on the multitrack;
            // raw triage can be stale after a reply, confirmation, or user
            // dismissal.
            if attention.needsReply {
                aiAnnotations.append(
                    TimelineLayoutSnapshot.AIAnnotation(
                        kind: .actionItems,
                        messageID: msg.id,
                        date: date,
                        purposeState: purposeState
                    )
                )
            }
            if attention.needsConfirmation {
                aiAnnotations.append(
                    TimelineLayoutSnapshot.AIAnnotation(
                        kind: .deadlines,
                        messageID: msg.id,
                        date: date,
                        purposeState: purposeState
                    )
                )
            }

            // Track unresolved threads. The pure logic lives in
            // `TimelineUnresolvedHeuristic` so it can be tested directly.
            if let threadID = msg.thread?.id {
                threadOutstanding[threadID] = TimelineUnresolvedHeuristic.update(
                    state: threadOutstanding[threadID],
                    messageID: msg.id,
                    date: date,
                    purposeState: purposeState,
                    isSentByUser: msg.isSentByUser
                )
            }
        }

        let directSharedRecipientMessageIDs = Set(semanticStatusInputs.compactMap { input -> UUID? in
            ProjectMessageInputBuilder.hasDirectSharedRecipientEvidence(for: input) ? input.id : nil
        })
        // Already off the main actor — compute semantic status inline. Keeping
        // this synchronous (no detached hop) means no suspension point exists
        // while this pass's fetched models are alive.
        let selfAddresses = Set(
            ((try? modelContext.fetch(FetchDescriptor<Identity>())) ?? []).map(\.address)
        )
        let semanticStatusSnapshot = SemanticMessageStatusComputation.snapshot(
            messages: semanticStatusInputs,
            sharedMessageActions: actionState.sharedMessageActions,
            configuration: SemanticMessageStatusConfiguration(
                now: Date.now,
                activeWindow: freshStartActiveWindow,
                selfAddresses: selfAddresses
            )
        )
        let statusSignals = semanticStatusSnapshot.statusSignals
            .addingDirectSharedRecipientEvidence(messageIDs: directSharedRecipientMessageIDs)
        messages = messages.map { message in
            Self.applyingSemanticStatusSignals(to: message, statusSignals: statusSignals)
        }

        // Emit `.unresolved` annotations for threads with a trailing
        // received-but-not-replied tail.
        aiAnnotations.append(contentsOf:
            TimelineUnresolvedHeuristic.annotations(from: threadOutstanding.values)
        )

        threads = Array(threadMap.values)

        return TimelineLayoutEngine.Input(
            signature: signature,
            viewportRange: viewportRange,
            pixelsPerDay: pixelsPerDay,
            bracketedRange: bracketedRange,
            messages: messages,
            threads: threads,
            attachments: attachments,
            aiAnnotations: aiAnnotations
        )
    }

    /// Enriches the pre-suspension value row with semantic status. This
    /// deliberately accepts and returns Sendable values so `gatherInput` never
    /// needs to retain or re-fault a SwiftData model after its detached work.
    nonisolated private static func applyingSemanticStatusSignals(
        to message: TimelineLayoutEngine.MessageRow,
        statusSignals: MessageStatusSignalIndex
    ) -> TimelineLayoutEngine.MessageRow {
        TimelineLayoutEngine.MessageRow(
            id: message.id,
            threadID: message.threadID,
            date: message.date,
            purposeState: message.purposeState,
            customCategories: message.customCategories,
            subject: message.subject,
            isSentByUser: message.isSentByUser,
            hasAttachments: message.hasAttachments,
            fromAddress: message.fromAddress,
            fromName: message.fromName,
            recipients: message.recipients,
            accountID: message.accountID,
            accountName: message.accountName,
            accountColorIndex: message.accountColorIndex,
            isRead: message.isRead,
            isListIgnoreEligible: message.isListIgnoreEligible,
            isActionable: message.isActionable,
            isInComposerQueue: message.isInComposerQueue,
            requiresConfirmation: message.requiresConfirmation,
            isReplied: message.isReplied,
            isConfirmed: message.isConfirmed,
            hasDeadline: message.hasDeadline,
            deadlineText: message.deadlineText,
            isResolved: message.isResolved,
            isFlagged: message.isFlagged,
            isRevivedAfterInactiveGap: statusSignals.isRevivedAfterInactiveGap(message.id),
            sharedEvidenceKinds: statusSignals.sharedEvidenceKinds(for: message.id)
        )
    }

    nonisolated private static func decodeTriageVerdict(
        _ json: String?,
        decoder: JSONDecoder,
        isSentByUser: Bool
    ) -> TriageVerdict? {
        guard let json,
              let data = json.data(using: .utf8),
              let verdict = try? decoder.decode(TriageVerdict.self, from: data) else {
            return nil
        }
        return verdict.normalizingActionability(isSentByUser: isSentByUser)
    }

    nonisolated private static func decodeDimensions(
        _ json: String?,
        decoder: JSONDecoder = JSONDecoder(),
        scrubTriageActionState: Bool = false
    ) -> MessageDimensions? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        guard let dimensions = try? decoder.decode(MessageDimensions.self, from: data) else {
            return nil
        }
        return scrubTriageActionState ? dimensions.scrubbingTriageActionState() : dimensions
    }

    nonisolated private static func attentionInput(
        for message: Message,
        decoder: JSONDecoder
    ) -> MessageAttentionInput? {
        guard let date = message.vectorTimeFilterDate else { return nil }
        let decodedTriageVerdict = decodeTriageVerdict(
            message.analysis?.triageVerdictJSON,
            decoder: decoder,
            isSentByUser: message.isSentByUser
        )
        let triageVerdict = message.isLiveInboundTriageEligible ? decodedTriageVerdict : nil
        return MessageAttentionInput(
            id: message.id,
            threadID: message.thread?.id,
            date: date,
            isSentByUser: message.isSentByUser,
            messageType: message.messageType,
            triageVerdict: triageVerdict,
            messageIDHeader: message.messageIdHeader,
            inReplyTo: message.inReplyTo,
            referencesChain: message.referencesChain,
            repliedAt: message.repliedAt
        )
    }

    nonisolated static func timelineRecipientDisplayName(
        for message: Message,
        participant: Participant
    ) -> String {
        let canonicalDisplayName = participant.displayName
            .map(MIMEHeaderDecoder.decodeEncodedWords)
        return TimelineSemanticViewport.timelineParticipantDisplayName(
            for: message,
            emailAddress: participant.emailAddress,
            canonicalDisplayName: canonicalDisplayName
        )
    }

    nonisolated private static func messageFilterRow(
        for message: Message,
        date: Date,
        customCategoryKeys: Set<String> = [],
        triageVerdict: TriageVerdict?,
        isActionable: Bool? = nil,
        requiresConfirmation: Bool? = nil,
        isReplied: Bool? = nil,
        isConfirmed: Bool? = nil,
        isResolved: Bool = false
    ) -> MessageFilterRow {
        let decodedFromName = message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords)
        var toAddresses: [String] = []
        var toNames: [String] = []
        var toDisplayNames: [String] = []
        var ccAddresses: [String] = []
        var ccNames: [String] = []
        var ccDisplayNames: [String] = []
        var bccAddresses: [String] = []
        var bccNames: [String] = []
        var bccDisplayNames: [String] = []
        var recipientAddresses: [String] = []
        for link in message.participants {
            guard let participant = link.participant else { continue }
            let email = participant.emailAddress.lowercased()
            guard email.isEmpty == false else { continue }
            let decodedName = participant.displayName.map(MIMEHeaderDecoder.decodeEncodedWords) ?? ""
            switch link.role {
            case .from:
                continue
            case .to:
                toAddresses.append(email)
                toNames.append(decodedName.lowercased())
                toDisplayNames.append(decodedName)
                recipientAddresses.append(email)
            case .cc:
                ccAddresses.append(email)
                ccNames.append(decodedName.lowercased())
                ccDisplayNames.append(decodedName)
                recipientAddresses.append(email)
            case .bcc:
                bccAddresses.append(email)
                bccNames.append(decodedName.lowercased())
                bccDisplayNames.append(decodedName)
                recipientAddresses.append(email)
            }
        }
        let resolvedIsReplied = isReplied ?? (message.repliedAt != nil)
        let rowMessageType = messageType(for: message)
        return MessageFilterRow(
            accountId: message.accountID,
            threadId: message.thread?.id,
            messageType: rowMessageType,
            embeddingStatus: message.embeddingStatus,
            isRead: message.isReadOrFalse,
            isReplied: resolvedIsReplied,
            isConfirmed: isConfirmed ?? false,
            isResolved: isResolved,
            isSentByUser: message.isSentByUser,
            flagged: message.flaggedOrFalse,
            hasAttachments: message.hasAttachments,
            fromAddress: message.fromAddress,
            fromName: decodedFromName,
            toAddresses: toAddresses,
            toNames: toNames,
            toDisplayNames: toDisplayNames,
            ccAddresses: ccAddresses,
            ccNames: ccNames,
            ccDisplayNames: ccDisplayNames,
            bccAddresses: bccAddresses,
            bccNames: bccNames,
            bccDisplayNames: bccDisplayNames,
            recipientAddresses: recipientAddresses,
            dimensions: decodeDimensions(
                message.analysis?.dimensionsJSON,
                scrubTriageActionState: !message.isLiveInboundTriageEligible
            ),
            subject: MIMEHeaderDecoder.decodeEncodedWords(message.subject),
            receivedAt: date,
            ingestedAt: message.ingestedAt,
            liveDetectedAt: message.liveDetectedAt,
            bodyTextPath: message.bodyTextPath,
            bodyHtmlPath: message.bodyHtmlPath,
            bodySummary: message.analysis?.bodySummary,
            bodySummaryInputFingerprint: message.analysis?.bodySummaryInputFingerprint,
            mailClassificationJSON: message.analysis?.mailClassificationJSON,
            customCategoryKeys: customCategoryKeys,
            isActionable: isActionable ?? MessageFilterRow.currentReplyNeededFromRawTriage(
                triageVerdict?.isActionable,
                isReplied: resolvedIsReplied,
                isSentByUser: message.isSentByUser
            ),
            requiresConfirmation: requiresConfirmation ?? MessageFilterRow.currentConfirmationNeededFromRawTriage(
                triageVerdict?.requiresConfirmation,
                isReplied: resolvedIsReplied,
                isSentByUser: message.isSentByUser
            )
        )
    }

    private nonisolated static func messageType(for message: Message) -> MessageType {
        guard !message.isLiveInboundTriageEligible,
              !message.isSentByUser,
              message.messageType == .actionable || message.messageType == .confirmation else {
            return message.messageType
        }
        return .report
    }

    nonisolated private static func isReplied(
        message: Message,
        attention: MessageAttentionState,
        actionState: ProjectLensUserActionState
    ) -> Bool {
        if actionState.repliedMessageIDs.contains(message.id) {
            return true
        }
        if actionState.replyNeededMessageIDs.contains(message.id) {
            return false
        }
        return message.repliedAt != nil || attention.clearsByMessageID != nil
    }
}
