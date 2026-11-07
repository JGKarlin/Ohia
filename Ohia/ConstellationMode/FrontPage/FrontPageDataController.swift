import Foundation
import OSLog
import ImageIO
import SwiftData
import Observation
import OhiaCore
import OhiaMail
import OhiaML
import OhiaScheduler

nonisolated struct FrontPagePreflightKey: Equatable {
    let displayKey: FrontPageDataController.RefreshDisplayKey
    let sourceRevision: UInt64
}

nonisolated struct FrontPageSemanticStatusSnapshotBuilder: Sendable {
    private let buildSnapshot: @Sendable (
        [ProjectMessageInput],
        ProjectLensSharedMessageActionState,
        SemanticMessageStatusConfiguration
    ) -> SemanticMessageStatusSnapshot

    init(
        _ buildSnapshot: @escaping @Sendable (
            [ProjectMessageInput],
            ProjectLensSharedMessageActionState,
            SemanticMessageStatusConfiguration
        ) -> SemanticMessageStatusSnapshot
    ) {
        self.buildSnapshot = buildSnapshot
    }

    func build(
        messages: [ProjectMessageInput],
        sharedMessageActions: ProjectLensSharedMessageActionState,
        configuration: SemanticMessageStatusConfiguration
    ) -> SemanticMessageStatusSnapshot {
        buildSnapshot(messages, sharedMessageActions, configuration)
    }
}

nonisolated struct FrontPageArticleSelectionCandidate: Sendable {
    let id: UUID
    var isSentByUser = false
    var isRead = false
    var threadID: UUID? = nil
    var composerQueueOverride: ComposerQueueOverride? = nil
    var draftStatus: DraftStatus? = nil
    var matchesFinalFilter = true
}

/// A controller has one preparation lane. Actor-isolated synchronous phases
/// execute off MainActor and cannot overlap when a newer filter cancels its
/// predecessor. Cancellation remains part of the caller's task throughout.
actor FrontPageRefreshWorker {
    func run<Value: Sendable>(
        _ operation: @Sendable () throws -> Value
    ) throws -> Value {
        try Task.checkCancellation()
        let value = try operation()
        try Task.checkCancellation()
        return value
    }
}

// Front Page is a SwiftUI reading workspace. The normal Metal scene should not
// mount for `.frontPage`. The candidate-fetch + decode + filter pipeline
// mirrors `ProjectsDataController`; the per-message extra is a representative
// image path (first `image/*` attachment).

@Observable @MainActor
final class FrontPageDataController {
    private weak var workspaceState: FrontPageWorkspaceState?
    private var modelContext: ModelContext?
    private var vectorStore: VectorStore?
    private var refreshTask: Task<Void, Never>?
    /// Holds a refresh that would drop a departing card until its Collapse has
    /// played (see `invalidateAndRefresh(holdingFor:)`).
    private var departingHoldTask: Task<Void, Never>?
    private var lastRefreshRequest: RefreshRequest?
    private var activeRefreshDisplayKey: RefreshDisplayKey?
    private var pendingRefreshAfterCurrent = false
    private var pendingDeferredInvalidation: PendingDeferredInvalidation?
    private var cacheEntries: [CacheEntry] = []
    private var semanticStatusCacheEntries: [SemanticStatusCacheEntry] = []
    private var epoch: UInt64 = 0
    private var sourceRevision: UInt64 = 0
    private var semanticStatusSourceRevision: UInt64 = 0
    @ObservationIgnored private let onGatherStarted: (@MainActor (Int) async -> Void)?
    @ObservationIgnored private let semanticStatusSnapshotBuilder: FrontPageSemanticStatusSnapshotBuilder
    @ObservationIgnored private let subscribesToLiveRefresh: Bool
    @ObservationIgnored nonisolated private let notificationCenter: NotificationCenter
    @ObservationIgnored private var gatherInvocationCount = 0
    @ObservationIgnored private let refreshWorker = FrontPageRefreshWorker()

    /// Cap on cached snapshots; oldest evicted. Matches Projects.
    private static let cacheLimit = 4
    private static let semanticStatusCacheLimit = 4

    @ObservationIgnored nonisolated(unsafe) private var deletionObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var ingestObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var summaryInvalidationObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var accountColorObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var messageAttentionObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var arrivalVisibilityObserver: NSObjectProtocol?

    private struct RefreshRequest {
        let filter: VectorFilter
        let selectedTimeRange: TimeRangePreset
    }

    private struct PendingDeferredInvalidation {
        var preservingProjectDefinitions: Bool

        mutating func merge(preservingProjectDefinitions: Bool) {
            self.preservingProjectDefinitions =
                self.preservingProjectDefinitions
                && preservingProjectDefinitions
        }
    }

    init(
        onGatherStarted: (@MainActor (Int) async -> Void)? = nil,
        semanticStatusSnapshotBuilder: FrontPageSemanticStatusSnapshotBuilder = FrontPageSemanticStatusSnapshotBuilder {
            messages, sharedMessageActions, configuration in
            SemanticMessageStatusComputation.snapshot(
                messages: messages,
                sharedMessageActions: sharedMessageActions,
                configuration: configuration
            )
        },
        subscribesToLiveRefresh: Bool = true,
        notificationCenter: NotificationCenter = .default
    ) {
        self.onGatherStarted = onGatherStarted
        self.semanticStatusSnapshotBuilder = semanticStatusSnapshotBuilder
        self.subscribesToLiveRefresh = subscribesToLiveRefresh
        self.notificationCenter = notificationCenter
    }

    // A pending departing hold counts as queued: it defers a full
    // invalidate-and-refresh to the motion floor (superseding any live
    // request), so callers deciding whether more data is coming — the
    // new-star retire gate — must not conclude the page is settled mid-hold.
    var hasRefreshInFlightOrQueued: Bool {
        refreshTask != nil || pendingRefreshAfterCurrent || departingHoldTask != nil
    }

    nonisolated struct RefreshDisplayKey: Equatable {
        let filterFingerprint: String
        let unreadOnly: Bool
    }

    private struct CacheEntry {
        let signature: FrontPageSnapshotSignature
        let preflightKey: FrontPagePreflightKey
        let snapshot: FrontPageSnapshot
    }

    private struct SemanticStatusCacheKey: Hashable {
        let sourceRevision: UInt64
        let scopeFingerprint: String
        let actionFingerprint: String
        let freshStartPolicyFingerprint: String
        let definitionRevisionFingerprint: String
    }

    private struct SemanticStatusCacheEntry {
        let key: SemanticStatusCacheKey
        let snapshot: SemanticMessageStatusSnapshot
    }

    // `nonisolated` so its (and its nested types') `Encodable` conformance can be
    // used from the `nonisolated` `filterFingerprint` encoder. Pure data — a
    // flattened, sorted snapshot of a `VectorFilter` — with no main-actor state,
    // so opting out of the target's MainActor default isolation is safe.
    private nonisolated struct CanonicalFilterFingerprint: Encodable {
        nonisolated struct DateRange: Encodable {
            let lower: Date
            let upper: Date
        }

        let collections: [String]
        let accountIds: [String]?
        let timeRange: DateRange?
        let messageTypes: [String]?
        let readStates: [Bool]?
        let repliedStates: [Bool]?
        let sentStates: [Bool]?
        let flaggedOnly: Bool
        let hasAttachmentsOnly: Bool
        let replyNeededCriterion: String
        let confirmationNeededCriterion: String
        let resolvedCriterion: String?
        let purposes: [String]?
        let mailingListCategoryIncluded: Bool?
        let customCategoryKeys: [String]?
        let correspondentQuery: String
        let correspondentScopes: [String]
        let clusterIds: [Int64]?
        let listIds: [String]?
        let taskState: String
        let deadlineState: String

        init(filter: VectorFilter) {
            collections = filter.collections.map(\.rawValue).sorted()
            accountIds = filter.accountIds.map { $0.map(\.uuidString).sorted() }
            timeRange = filter.timeRange.map {
                DateRange(lower: $0.lowerBound, upper: $0.upperBound)
            }
            messageTypes = filter.messageTypes.map { $0.map(\.rawValue).sorted() }
            readStates = filter.readStates.map { $0.sorted { !$0 && $1 } }
            repliedStates = filter.repliedStates.map { $0.sorted { !$0 && $1 } }
            sentStates = filter.sentStates.map { $0.sorted { !$0 && $1 } }
            flaggedOnly = filter.flaggedOnly
            hasAttachmentsOnly = filter.hasAttachmentsOnly
            replyNeededCriterion = filter.replyNeededCriterion.rawValue
            confirmationNeededCriterion = filter.confirmationNeededCriterion.rawValue
            resolvedCriterion = filter.resolvedCriterion?.rawValue
            purposes = filter.purposes.map { $0.map(\.rawValue).sorted() }
            mailingListCategoryIncluded = filter.mailingListCategoryIncluded
            customCategoryKeys = filter.customCategoryKeys.map { $0.sorted() }
            correspondentQuery = filter.correspondentQuery
            correspondentScopes = filter.correspondentScopes.map(\.rawValue).sorted()
            clusterIds = filter.clusterIds.map { $0.sorted() }
            listIds = filter.listIds.map { $0.sorted() }
            taskState = filter.taskState.rawValue
            deadlineState = filter.deadlineState.rawValue
        }
    }

    deinit {
        if let deletionObserver { notificationCenter.removeObserver(deletionObserver) }
        if let ingestObserver { notificationCenter.removeObserver(ingestObserver) }
        if let summaryInvalidationObserver { notificationCenter.removeObserver(summaryInvalidationObserver) }
        if let accountColorObserver { notificationCenter.removeObserver(accountColorObserver) }
        if let messageAttentionObserver { notificationCenter.removeObserver(messageAttentionObserver) }
        if let arrivalVisibilityObserver { notificationCenter.removeObserver(arrivalVisibilityObserver) }
    }

    func bind(
        workspace: FrontPageWorkspaceState,
        modelContext: ModelContext,
        vectorStore: VectorStore
    ) {
        attach(
            workspace: workspace,
            modelContext: modelContext,
            vectorStore: vectorStore
        )
    }

    /// Idempotent re-attach for parent-driven refreshes. Front Page can be
    /// hidden behind the lens readiness surface while a switch is in progress,
    /// so refresh entry points must not depend only on the child view's
    /// `onAppear` lifecycle to keep this controller bound.
    func ensureBound(
        workspace: FrontPageWorkspaceState,
        modelContext: ModelContext,
        vectorStore: VectorStore
    ) {
        let alreadyBound = workspaceState === workspace
            && self.modelContext != nil
            && self.vectorStore != nil
        guard alreadyBound == false else { return }
        attach(
            workspace: workspace,
            modelContext: modelContext,
            vectorStore: vectorStore
        )
    }

    private func attach(
        workspace: FrontPageWorkspaceState,
        modelContext: ModelContext,
        vectorStore: VectorStore
    ) {
        self.workspaceState = workspace
        self.modelContext = modelContext
        self.vectorStore = vectorStore
        if subscribesToLiveRefresh, deletionObserver == nil {
            subscribeToLiveRefresh()
        }
    }

    func unbind() {
        if let deletionObserver {
            notificationCenter.removeObserver(deletionObserver)
            self.deletionObserver = nil
        }
        if let ingestObserver {
            notificationCenter.removeObserver(ingestObserver)
            self.ingestObserver = nil
        }
        if let summaryInvalidationObserver {
            notificationCenter.removeObserver(summaryInvalidationObserver)
            self.summaryInvalidationObserver = nil
        }
        if let accountColorObserver {
            notificationCenter.removeObserver(accountColorObserver)
            self.accountColorObserver = nil
        }
        if let messageAttentionObserver {
            notificationCenter.removeObserver(messageAttentionObserver)
            self.messageAttentionObserver = nil
        }
        if let arrivalVisibilityObserver {
            notificationCenter.removeObserver(arrivalVisibilityObserver)
            self.arrivalVisibilityObserver = nil
        }
        // SwiftUI can deliver stale, unbalanced `onDisappear` calls during
        // lens churn while the parent still owns the workspace. Match Timeline:
        // detach live observers and collaborators, but preserve the in-flight
        // refresh/request/cache so a completed build can still install into the
        // weakly-captured workspace and lift the Front Page readiness veil.
        workspaceState = nil
        modelContext = nil
        vectorStore = nil
    }

    func requestRefresh(
        filter baseFilter: VectorFilter,
        selectedTimeRange: TimeRangePreset
    ) {
        let requestStartedAt = LensLoadPerformanceLog.start()
        guard let workspace = workspaceState,
              let modelContext,
              let vectorStore else { return }
        lastRefreshRequest = RefreshRequest(
            filter: baseFilter,
            selectedTimeRange: selectedTimeRange
        )
        let unreadOnly = workspace.unreadOnly
        let effectiveFilter = Self.effectiveFrontPageFilter(
            baseFilter: baseFilter,
            selectedTimeRange: selectedTimeRange
        )
        let filterFingerprint = Self.snapshotFilterFingerprint(
            baseFilter: baseFilter,
            selectedTimeRange: selectedTimeRange
        )
        let semanticStatusScopeFingerprint = Self.semanticStatusScopeFingerprint(
            baseFilter: baseFilter,
            selectedTimeRange: selectedTimeRange
        )
        let displayKey = RefreshDisplayKey(
            filterFingerprint: filterFingerprint,
            unreadOnly: unreadOnly
        )
        if refreshTask != nil,
           activeRefreshDisplayKey != displayKey,
           let pendingDeferredInvalidation {
            self.pendingDeferredInvalidation = nil
            invalidateCacheForNextRequest(
                preservingProjectDefinitions:
                    pendingDeferredInvalidation.preservingProjectDefinitions
            )
        }
        let preflightKey = FrontPagePreflightKey(
            displayKey: displayKey,
            sourceRevision: sourceRevision
        )
        if let cached = cachedSnapshot(for: preflightKey, now: .now) {
            if Self.shouldSupersedeRefreshForPreflightHit(
                hasRefreshInFlight: refreshTask != nil,
                activeDisplayKey: activeRefreshDisplayKey,
                requestedDisplayKey: displayKey
            ) {
                epoch &+= 1
                refreshTask?.cancel()
                refreshTask = nil
                activeRefreshDisplayKey = nil
                pendingRefreshAfterCurrent = false
            }
            workspace.currentSnapshot = cached
            LensLoadPerformanceLog.record(
                lens: .frontPage,
                stage: "preflight",
                startedAt: requestStartedAt,
                resultCount: cached.articlesByID.count,
                cache: "hit"
            )
            return
        }
        LensLoadPerformanceLog.record(
            lens: .frontPage,
            stage: "preflight",
            startedAt: requestStartedAt,
            cache: "miss"
        )
        if Self.shouldCoalesceRefresh(
            hasRefreshInFlight: refreshTask != nil,
            activeDisplayKey: activeRefreshDisplayKey,
            requestedDisplayKey: displayKey
        ) {
            pendingRefreshAfterCurrent = true
            LensLoadPerformanceLog.record(
                lens: .frontPage,
                stage: "coalesce",
                startedAt: requestStartedAt,
                cache: "active-request"
            )
            return
        }
        epoch &+= 1
        let thisEpoch = epoch
        let requestSourceRevision = sourceRevision
        let requestSemanticStatusSourceRevision = semanticStatusSourceRevision

        pendingRefreshAfterCurrent = false
        refreshTask?.cancel()
        activeRefreshDisplayKey = displayKey
        refreshTask = Task { [weak self, weak workspace] in
            guard let self else { return }
            defer { self.finishRefresh(epoch: thisEpoch) }
            do {
                let gathered = try await self.gatherInput(
                    modelContext: modelContext,
                    vectorStore: vectorStore,
                    filter: effectiveFilter,
                    unreadOnly: unreadOnly,
                    semanticStatusScopeFingerprint: semanticStatusScopeFingerprint,
                    requestSourceRevision: requestSourceRevision,
                    requestSemanticStatusSourceRevision: requestSemanticStatusSourceRevision
                )
                if Task.isCancelled { return }
                guard thisEpoch == self.epoch,
                      requestSourceRevision == self.sourceRevision else { return }

                let signature = try await self.refreshWorker.run {
                    FrontPageSnapshotSignature(
                        filterFingerprint: filterFingerprint,
                        unreadOnly: unreadOnly,
                        actionFingerprint: gathered.actionFingerprint,
                        freshStartPolicyFingerprint: gathered.freshStartPolicyFingerprint,
                        statusFingerprint: gathered.statusFingerprint,
                        deadlineFingerprint: Self.deadlineFingerprint(gathered.inputs),
                        messageIDsFingerprint: Self.messageIDsFingerprint(gathered.inputs.map(\.id))
                    )
                }
                guard thisEpoch == self.epoch,
                      requestSourceRevision == self.sourceRevision else { return }
                if let cached = self.cachedSnapshot(for: signature, now: .now) {
                    workspace?.currentSnapshot = cached
                    LensLoadPerformanceLog.record(
                        lens: .frontPage,
                        stage: "signature",
                        startedAt: requestStartedAt,
                        resultCount: cached.articlesByID.count,
                        cache: "hit"
                    )
                    return
                }

                let now = Date.now
                let momentsWindow = effectiveFilter.timeRange
                let inputs = gathered.inputs
                let compositionStartedAt = LensLoadPerformanceLog.start()
                let snapshot = try await self.refreshWorker.run {
                    let composition = FrontPageComposer.compose(
                        inputs: inputs,
                        momentsWindow: momentsWindow,
                        now: now
                    )
                    try Task.checkCancellation()
                    return FrontPageSnapshot(
                        signature: signature,
                        builtAt: Date.now,
                        composition: composition,
                        articlesByID: gathered.articlesByID,
                        messageFilterRows: gathered.messageFilterRows
                    )
                }
                LensLoadPerformanceLog.record(
                    lens: .frontPage,
                    stage: "compose",
                    startedAt: compositionStartedAt,
                    candidateCount: inputs.count,
                    resultCount: gathered.articlesByID.count
                )
                if Task.isCancelled { return }
                guard thisEpoch == self.epoch,
                      requestSourceRevision == self.sourceRevision else { return }

                self.store(snapshot, for: signature, preflightKey: preflightKey)
                workspace?.currentSnapshot = snapshot
                LensLoadPerformanceLog.record(
                    lens: .frontPage,
                    stage: "install",
                    startedAt: requestStartedAt,
                    candidateCount: inputs.count,
                    resultCount: gathered.articlesByID.count,
                    cache: "miss"
                )
            } catch is CancellationError {
                return
            } catch {
                LensLoadPerformanceLog.logger.error("Front Page refresh failed: \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
    }

    nonisolated static func shouldCoalesceRefresh(
        hasRefreshInFlight: Bool,
        activeDisplayKey: RefreshDisplayKey?,
        requestedDisplayKey: RefreshDisplayKey
    ) -> Bool {
        hasRefreshInFlight
            && activeDisplayKey == requestedDisplayKey
    }

    nonisolated static func shouldSupersedeRefreshForPreflightHit(
        hasRefreshInFlight: Bool,
        activeDisplayKey: RefreshDisplayKey?,
        requestedDisplayKey: RefreshDisplayKey
    ) -> Bool {
        hasRefreshInFlight
            && activeDisplayKey != requestedDisplayKey
    }

    nonisolated static func snapshotMatchesDisplayKey(
        _ snapshot: FrontPageSnapshot?,
        displayKey: RefreshDisplayKey
    ) -> Bool {
        guard let snapshot else { return false }
        return snapshot.signature.filterFingerprint == displayKey.filterFingerprint
            && snapshot.signature.unreadOnly == displayKey.unreadOnly
    }

    nonisolated static func isPreflightCacheHit(
        cachedKey: FrontPagePreflightKey,
        requestedKey: FrontPagePreflightKey,
        builtAt: Date,
        now: Date,
        maximumAge: TimeInterval = 60
    ) -> Bool {
        cachedKey == requestedKey
            && now.timeIntervalSince(builtAt) <= maximumAge
    }

    private func finishRefresh(epoch finishedEpoch: UInt64) {
        guard finishedEpoch == epoch else { return }
        refreshTask = nil
        activeRefreshDisplayKey = nil
        let deferredInvalidation = pendingDeferredInvalidation
        pendingDeferredInvalidation = nil
        if let deferredInvalidation {
            invalidateCacheForNextRequest(
                preservingProjectDefinitions:
                    deferredInvalidation.preservingProjectDefinitions
            )
        }
        let shouldRefreshAgain = pendingRefreshAfterCurrent
            || deferredInvalidation != nil
        pendingRefreshAfterCurrent = false
        guard shouldRefreshAgain, let lastRefreshRequest else { return }
        requestRefresh(
            filter: lastRefreshRequest.filter,
            selectedTimeRange: lastRefreshRequest.selectedTimeRange
        )
    }

    func invalidateAndRefresh(
        preservingProjectDefinitions: Bool = false,
        deferringIfRefreshInFlight: Bool = false
    ) {
        // While a departing card's Collapse is being held (see
        // `invalidateAndRefresh(holdingFor:)`), coalesce any competing live refresh
        // (new mail, background summaries, deletion events) into that pending hold
        // so the card is not yanked out from under its motion. The hold task clears
        // `departingHoldTask` and rebuilds with the latest data at the motion floor.
        guard departingHoldTask == nil else { return }
        if deferringIfRefreshInFlight, refreshTask != nil {
            queueDeferredInvalidation(
                preservingProjectDefinitions: preservingProjectDefinitions
            )
            pendingRefreshAfterCurrent = true
            return
        }
        let mergedPreservation = consumeDeferredInvalidation(
            merging: preservingProjectDefinitions
        )
        invalidateCacheForNextRequest(
            preservingProjectDefinitions: mergedPreservation
        )
        // Destructive visibility changes must discard the old source turn.
        // Cancel its preparation too, not only its eventual installation.
        if refreshTask != nil {
            epoch &+= 1
            refreshTask?.cancel()
            refreshTask = nil
            activeRefreshDisplayKey = nil
            pendingRefreshAfterCurrent = false
        }
        guard let lastRefreshRequest else { return }
        requestRefresh(
            filter: lastRefreshRequest.filter,
            selectedTimeRange: lastRefreshRequest.selectedTimeRange
        )
    }

    /// Marks retained Front Page data stale without starting off-screen work.
    /// The mounted snapshot may remain visible; the next bound request misses
    /// preflight and silently rebuilds it from the new source revision.
    func invalidateCacheForNextRequest() {
        sourceRevision &+= 1
        semanticStatusSourceRevision &+= 1
        cacheEntries.removeAll()
        semanticStatusCacheEntries.removeAll()
    }

    /// Invalidates message-dependent snapshots while retaining structural
    /// semantic status, which does not depend on message read state.
    func invalidateMessageStateCacheForNextRequest() {
        sourceRevision &+= 1
        cacheEntries.removeAll()
    }

    private func queueDeferredInvalidation(
        preservingProjectDefinitions: Bool
    ) {
        if var pendingDeferredInvalidation {
            pendingDeferredInvalidation.merge(
                preservingProjectDefinitions: preservingProjectDefinitions
            )
            self.pendingDeferredInvalidation = pendingDeferredInvalidation
        } else {
            pendingDeferredInvalidation = PendingDeferredInvalidation(
                preservingProjectDefinitions: preservingProjectDefinitions
            )
        }
    }

    private func consumeDeferredInvalidation(
        merging preservingProjectDefinitions: Bool
    ) -> Bool {
        guard let pendingDeferredInvalidation else {
            return preservingProjectDefinitions
        }
        self.pendingDeferredInvalidation = nil
        return preservingProjectDefinitions
            && pendingDeferredInvalidation.preservingProjectDefinitions
    }

    private func invalidateCacheForNextRequest(
        preservingProjectDefinitions: Bool
    ) {
        if preservingProjectDefinitions {
            invalidateMessageStateCacheForNextRequest()
        } else {
            invalidateCacheForNextRequest()
        }
    }

    /// Invalidate and refresh, but hold for `delay` seconds first so a departing
    /// (delete / resolve) card's Collapse finishes playing before the rebuild
    /// drops it. A local resolve writes and rebuilds almost instantly, which would
    /// otherwise yank the card out from under the green Collapse the way a slow
    /// IMAP delete never does. A non-positive `delay` refreshes immediately, and a
    /// fresh hold supersedes any pending one.
    func invalidateAndRefresh(
        holdingFor delay: Double,
        preservingProjectDefinitions: Bool = false
    ) {
        departingHoldTask?.cancel()
        departingHoldTask = nil
        guard delay > 0 else {
            invalidateAndRefresh(preservingProjectDefinitions: preservingProjectDefinitions)
            return
        }
        // The `departingHoldTask` guard in `invalidateAndRefresh()` only
        // coalesces refreshes requested AFTER the hold begins. A refresh
        // already in flight right now (a background summary / live-mail
        // rebuild) can gather the freshly written action state and install a
        // snapshot that drops the departing card mid-motion — yanking it out
        // from under the Collapse the hold exists to protect. Supersede that
        // in-flight request: bump the epoch so its install guard fails even if
        // cancellation lands late, and let the hold's own rebuild regather
        // everything at the motion floor. Any invalidation it had deferred
        // stays queued and is consumed by that rebuild.
        if refreshTask != nil {
            epoch &+= 1
            refreshTask?.cancel()
            refreshTask = nil
            activeRefreshDisplayKey = nil
            pendingRefreshAfterCurrent = false
        }
        departingHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            // A delayed first frame or dropped frames can extend a Composer
            // departure beyond its nominal floor. Keep the source card mounted
            // until its renderer and reader transitions have acknowledged it.
            let departures = self?.workspaceState?.statusGestureCoordinator.gestures.values
                .compactMap(\.composerDeparture) ?? []
            do {
                for departure in departures { try await departure.waitForPresentation() }
                try Task.checkCancellation()
            } catch { return }
            self?.departingHoldTask = nil
            self?.invalidateAndRefresh(preservingProjectDefinitions: preservingProjectDefinitions)
        }
    }

    /// Resolves the focused article's conversation for the reader's threaded
    /// section. The primary source is the RFC 5322 header graph rooted at the
    /// focused message (`Message-ID`, `In-Reply-To`, and `References`) so the
    /// reader can recover same-thread mail even when a live IMAP row has not yet
    /// been attached to a `MessageThread`. If the header graph has no siblings,
    /// the persisted `MessageThread` relationship is used as the fallback. The
    /// focused message itself is included so the reply-tree builder can resolve
    /// parentage while omitting the article body above.
    func loadThreadContext(for messageID: UUID) -> FrontPageThreadContext {
        guard let modelContext else { return .absent }
        return Self.threadContext(for: messageID, modelContext: modelContext)
    }

    /// Loads the reader's expensive RFC-header thread graph in a private
    /// SwiftData context. The first suspension happens before any of that work,
    /// so committing `focusedArticleID` can paint the reader takeover without
    /// waiting for a large initial-ingestion store to finish header or
    /// attachment scans.
    func loadReaderPayload(for messageID: UUID) async -> FrontPageReaderPayload {
        guard let container = modelContext?.container else { return .empty }
        return await Self.readerPayload(for: messageID, in: container)
    }

    @concurrent
    static func readerPayload(
        for messageID: UUID,
        in container: ModelContainer
    ) async -> FrontPageReaderPayload {
        guard Task.isCancelled == false else { return .empty }
        let context = ModelContext(container)
        let threadContext = Self.threadContext(
            for: messageID,
            modelContext: context
        )
        guard Task.isCancelled == false else { return .empty }
        let attachments = Self.attachmentSummaries(
            for: messageID,
            modelContext: context
        )
        guard Task.isCancelled == false else { return .empty }
        return FrontPageReaderPayload(
            threadContext: threadContext,
            attachments: attachments
        )
    }

    nonisolated static func threadContext(
        for messageID: UUID,
        modelContext: ModelContext,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) -> FrontPageThreadContext {
        guard cancellationCheck() == false else { return .absent }
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first else { return .absent }
        guard cancellationCheck() == false else { return .absent }
        let recipientHeader = Self.recipientHeader(from: message)
        let headerLinkedMessages = Self.headerLinkedThreadMessages(
            from: message,
            context: modelContext,
            limit: 200,
            cancellationCheck: cancellationCheck
        )
        guard cancellationCheck() == false else { return .absent }
        let hasHeaderSibling = headerLinkedMessages.contains { $0.id != messageID }

        let candidateMessages: [Message]
        let hasStoredThread: Bool
        if hasHeaderSibling {
            candidateMessages = headerLinkedMessages
            hasStoredThread = true
        } else if let thread = message.thread {
            candidateMessages = Self.boundedRelationshipMessages(
                for: message,
                thread: thread,
                limit: 200
            )
            hasStoredThread = true
        } else {
            return FrontPageThreadContext(
                hasStoredThread: false,
                messages: [],
                recipientHeader: recipientHeader
            )
        }

        let messages = Self.deduplicatedThreadMessages(candidateMessages, focusedID: messageID)
        return FrontPageThreadContext(
            hasStoredThread: hasStoredThread,
            messages: messages.map(Self.threadMessage(from:)),
            recipientHeader: recipientHeader
        )
    }

    /// Resolves every attachment on the focused article for the reader's
    /// Attachments rail / end-of-story dossier. Unlike the spatial inspector's
    /// annotation factory (which drops inline cid: images so they are not shown
    /// twice), the Front Page catalog deliberately **keeps** inline images so
    /// the rail lists images alongside documents even when they also render
    /// inline in the HTML body. Mirrors `loadThreadContext`'s single-message
    /// fetch; `@MainActor` because it reads SwiftData.
    func loadAttachments(for messageID: UUID) -> [LockedAttachmentSummary] {
        guard let modelContext else { return [] }
        return Self.attachmentSummaries(
            for: messageID,
            modelContext: modelContext
        )
    }

    private nonisolated static func attachmentSummaries(
        for messageID: UUID,
        modelContext: ModelContext
    ) -> [LockedAttachmentSummary] {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first else { return [] }
        return message.attachments
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
            .map { LockedAttachmentSummary(attachment: $0) }
    }

    /// Resolves the Front Page article that can display a search hit. Direct
    /// received-message hits open their own article. Sent-message hits open the
    /// nearest visible received ancestor whose reply tree contains the sent
    /// row, matching the reader's `FrontPageReplyComposer` parentage rules.
    func displayArticleID(
        forMatchedMessageID messageID: UUID,
        in snapshot: FrontPageSnapshot
    ) -> UUID? {
        if snapshot.article(id: messageID) != nil {
            return messageID
        }
        guard let modelContext else { return nil }
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first,
              let thread = message.thread else {
            return nil
        }

        var boundedThreadMessages = Array(thread.messages.prefix(200))
        if boundedThreadMessages.contains(where: { $0.id == messageID }) == false {
            if boundedThreadMessages.count >= 200 {
                boundedThreadMessages.removeLast()
            }
            boundedThreadMessages.append(message)
        }

        let threadMessages = Self.deduplicatedThreadMessages(
            boundedThreadMessages,
            focusedID: messageID
        )
        let descriptors = threadMessages.map { Self.threadDescriptor(from: $0, bodyText: "") }
        let eligibleFocusIDs = Set(snapshot.articlesByID.keys.map(\.uuidString))
        guard let focusID = FrontPageReplyComposer.focusIDDisplayingReply(
            targetID: messageID.uuidString,
            descriptors: descriptors,
            eligibleFocusIDs: eligibleFocusIDs
        ),
              let articleID = UUID(uuidString: focusID),
              snapshot.article(id: articleID) != nil else {
            return nil
        }
        return articleID
    }

    /// Opens a search hit in the Front Page reader. Normal feed members and
    /// sent replies represented by a visible parent retain the snapshot-backed
    /// route. A toolbar-valid hit can still be absent from the Front Page feed
    /// because that feed independently removes sent, replied, confirmed, and
    /// resolved mail; in that case, build a transient article directly from the
    /// stored message so the Search tab never offers an inert Go action.
    @discardableResult
    func focusSearchMatch(
        messageID: UUID,
        in snapshot: FrontPageSnapshot,
        searchHighlight: SearchMatchHighlight? = nil
    ) -> Bool {
        guard let workspace = workspaceState else { return false }
        if let articleID = displayArticleID(
            forMatchedMessageID: messageID,
            in: snapshot
        ) {
            return workspace.focusArticleDisplayingSearchMatch(
                articleID,
                searchHighlight: searchHighlight
            )
        }
        guard let article = standaloneSearchArticle(messageID: messageID) else {
            return false
        }
        workspace.focusArticle(article, searchHighlight: searchHighlight)
        return true
    }

    /// Hydrates exactly one message for an immediate focus takeover. This does
    /// not invalidate or wait for the full Front Page snapshot.
    func loadArticleForFocus(messageID: UUID) async -> FrontPageArticle? {
        guard let container = modelContext?.container else { return nil }
        let task = Task.detached(priority: .userInitiated) { () -> FrontPageArticle? in
            guard Task.isCancelled == false else { return nil }
            let context = ModelContext(container)
            return Self.standaloneArticle(messageID: messageID, modelContext: context)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func standaloneSearchArticle(messageID: UUID) -> FrontPageArticle? {
        guard let modelContext else { return nil }
        return Self.standaloneArticle(messageID: messageID, modelContext: modelContext)
    }

    private nonisolated static func standaloneArticle(
        messageID: UUID,
        modelContext: ModelContext
    ) -> FrontPageArticle? {
        guard let enrichment = Self.articleEnrichments(
                  modelContext: modelContext,
                  messageIDs: [messageID]
              )[messageID] else {
            return nil
        }

        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first else {
            return nil
        }

        var threadMessages = Array((message.thread?.messages ?? [message]).prefix(200))
        if threadMessages.contains(where: { $0.id == messageID }) == false {
            if threadMessages.count >= 200 {
                threadMessages.removeLast()
            }
            threadMessages.append(message)
        }
        let triageDecoder = JSONDecoder()
        let attentionInputs = threadMessages.compactMap { candidate -> MessageAttentionInput? in
            guard let date = candidate.vectorTimeFilterDate else { return nil }
            let decodedTriage = Self.decodeTriageVerdict(
                candidate.analysis?.triageVerdictJSON,
                decoder: triageDecoder,
                isSentByUser: candidate.isSentByUser
            )
            let triage = candidate.isLiveInboundTriageEligible ? decodedTriage : nil
            return Self.attentionInput(for: candidate, date: date, triageVerdict: triage)
        }
        let actionState = ProjectLensActionRepository(modelContext: modelContext)
            .actionState(accountScopeKey: "")
        let attention = MessageAttentionResolver.states(
            messages: attentionInputs,
            userActions: MessageAttentionUserActionState(projectActions: actionState)
        )[messageID] ?? MessageAttentionState(messageID: messageID, openKinds: [])
        let isReplied = Self.isReplied(
            messageID: messageID,
            repliedAt: message.repliedAt,
            attention: attention,
            actionState: actionState
        )
        let bodyPreview = Self.bodyPreviews(for: [
            BodyPreviewCandidate(
                messageID: messageID,
                bodyHtmlPath: enrichment.baseFilterRow.bodyHtmlPath,
                bodyTextPath: enrichment.baseFilterRow.bodyTextPath,
                rawPath: enrichment.rawPath
            )
        ])[messageID]

        return Self.article(
            enrichment: enrichment,
            bodyPreview: bodyPreview,
            attention: attention,
            isReplied: isReplied,
            isConfirmed: actionState.confirmedMessageIDs.contains(messageID),
            isResolved: actionState.resolvedMessageIDs.contains(messageID),
            isRevivedAfterInactiveGap: false,
            sharedEvidenceKinds: []
        )
    }

    private nonisolated static func threadMessage(from message: Message) -> FrontPageThreadMessage {
        let decodedName = message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords)
        let author: String
        if message.isSentByUser {
            author = "You"
        } else if let decodedName,
                  decodedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            author = decodedName
        } else {
            author = message.fromAddress
        }
        return FrontPageThreadMessage(
            id: message.id,
            messageIDHeader: message.messageIdHeader,
            inReplyTo: message.inReplyTo,
            references: references(from: message),
            author: author,
            isSentByUser: message.isSentByUser,
            date: message.vectorTimeFilterDate,
            bodyHtmlPath: message.bodyHtmlPath,
            bodyTextPath: message.bodyTextPath,
            rawPath: message.rawPath
        )
    }

    /// Display-ready To/Cc/Bcc metadata for the focused reader. Source-header
    /// position wins when available; legacy rows without it retain their
    /// SwiftData relationship order.
    nonisolated static func recipientHeader(from message: Message) -> FrontPageRecipientHeader {
        let indexedLinks = Array(message.participants.enumerated())
        let lines: [FrontPageRecipientHeader.Line] = FrontPageRecipientHeader.Role.allCases.compactMap { role in
            let recipients = indexedLinks
                .filter { $0.element.role == role.participantRole }
                .sorted { lhs, rhs in
                    switch (lhs.element.headerPosition, rhs.element.headerPosition) {
                    case let (left?, right?):
                        return left == right ? lhs.offset < rhs.offset : left < right
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    case (nil, nil):
                        return lhs.offset < rhs.offset
                    }
                }
                .compactMap { recipientDisplayText($0.element.participant) }
            guard recipients.isEmpty == false else { return nil }
            return FrontPageRecipientHeader.Line(role: role, recipients: recipients)
        }
        return FrontPageRecipientHeader(lines: lines)
    }

    private nonisolated static func recipientDisplayText(_ participant: Participant?) -> String? {
        guard let participant else { return nil }
        let address = participant.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedName = participant.displayName
            .map(MIMEHeaderDecoder.decodeEncodedWords)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = decodedName?.isEmpty == false ? decodedName : nil

        if let name, address.isEmpty == false {
            return name.caseInsensitiveCompare(address) == .orderedSame
                ? address
                : "\(name) <\(address)>"
        }
        if let name { return name }
        return address.isEmpty ? nil : address
    }

    private nonisolated static func threadDescriptor(
        from message: Message,
        bodyText: String
    ) -> FrontPageThreadDescriptor {
        FrontPageThreadDescriptor(
            id: message.id.uuidString,
            messageID: message.messageIdHeader,
            inReplyTo: message.inReplyTo,
            references: references(from: message),
            author: nil,
            isSentByUser: message.isSentByUser,
            date: message.vectorTimeFilterDate,
            bodyText: bodyText
        )
    }

    private nonisolated static func references(from message: Message) -> [String] {
        (message.referencesChain ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
    }

    private nonisolated static func deduplicatedThreadMessages(
        _ messages: [Message],
        focusedID: UUID
    ) -> [Message] {
        var selectedByKey: [String: Message] = [:]
        var order: [String] = []

        for message in messages {
            let key = threadDuplicateKey(for: message)
            if let existing = selectedByKey[key] {
                if shouldPreferThreadDuplicate(message, over: existing, focusedID: focusedID) {
                    selectedByKey[key] = message
                }
            } else {
                selectedByKey[key] = message
                order.append(key)
            }
        }

        return order.compactMap { selectedByKey[$0] }
    }

    private nonisolated static func boundedRelationshipMessages(
        for message: Message,
        thread: MessageThread,
        limit: Int
    ) -> [Message] {
        var messages = Array(thread.messages.prefix(limit))
        if messages.contains(where: { $0.id == message.id }) == false {
            if messages.count >= limit {
                messages.removeLast()
            }
            messages.append(message)
        }
        return messages.sorted(by: threadMessagePrecedes)
    }

    private nonisolated static func headerLinkedThreadMessages(
        from seed: Message,
        context: ModelContext,
        limit: Int,
        cancellationCheck: @Sendable () -> Bool
    ) -> [Message] {
        guard cancellationCheck() == false else { return [] }
        let seedTokens = headerSearchTokens(for: seed)
        // A message with no Message-ID/In-Reply-To/References at all has
        // nothing to link on — skip the whole-mailbox index build entirely
        // rather than paying for it on every reader-open regardless of
        // whether the seed carries any header to search for.
        guard seedTokens.isEmpty == false else { return [seed] }

        let tokenIndex = headerTokenIndex(context: context, cancellationCheck: cancellationCheck)
        guard cancellationCheck() == false else { return [] }

        var selected: [UUID: Message] = [seed.id: seed]
        var visitedTokens = Set<String>()
        var queuedTokens = Set<String>()
        var queue: [String] = []

        func enqueue(_ tokens: Set<String>) {
            for token in tokens {
                guard cancellationCheck() == false else { return }
                guard let normalized = normalizeMessageIDHeader(token),
                      visitedTokens.contains(normalized) == false,
                      queuedTokens.insert(normalized).inserted else { continue }
                queue.append(token)
            }
            queue.sort()
        }

        enqueue(seedTokens)

        while let token = queue.first,
              selected.count < limit {
            guard cancellationCheck() == false else { return [] }
            queue.removeFirst()
            guard let normalizedToken = normalizeMessageIDHeader(token) else { continue }
            queuedTokens.remove(normalizedToken)
            guard visitedTokens.insert(normalizedToken).inserted else { continue }

            for candidate in tokenIndex[normalizedToken] ?? [] {
                guard cancellationCheck() == false else { return [] }
                if selected[candidate.id] == nil {
                    selected[candidate.id] = candidate
                    enqueue(headerSearchTokens(for: candidate))
                }
                if selected.count >= limit { break }
            }
        }

        return Array(selected.values).sorted(by: threadMessagePrecedes)
    }

    /// Every locally-stored message that carries at least one RFC-header
    /// (`Message-ID` / `In-Reply-To` / `References`) value, indexed by every
    /// normalized Message-ID token appearing in any of its three header
    /// fields. Built once per reader focus and then queried in memory for the
    /// whole BFS below.
    ///
    /// Previously each BFS-queued token re-fetched and re-parsed every
    /// header-bearing message in the mailbox, per header field, whenever the
    /// SQL `contains()` lookup found no match — which is the common case: most
    /// `References`/`In-Reply-To` tokens point to messages the local store
    /// never ingested (external participants, an earlier device or client, or
    /// a message nobody has replied to yet). For a mailbox of a few thousand
    /// messages that meant dozens of full-table rescans, each re-tokenizing
    /// every row, just to open a single email. One upfront pass plus O(1)
    /// dictionary lookups replaces all of that.
    private nonisolated static func headerTokenIndex(
        context: ModelContext,
        cancellationCheck: @Sendable () -> Bool
    ) -> [String: [Message]] {
        guard cancellationCheck() == false else { return [:] }
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> {
                $0.messageIdHeader != nil || $0.inReplyTo != nil || $0.referencesChain != nil
            }
        )
        let headerBearingMessages = (try? context.fetch(descriptor)) ?? []
        guard cancellationCheck() == false else { return [:] }

        var index: [String: [Message]] = [:]
        for message in headerBearingMessages {
            guard cancellationCheck() == false else { return [:] }
            for token in headerTokens(for: message) {
                index[token, default: []].append(message)
            }
        }
        return index
    }

    private nonisolated static func headerTokens(for message: Message) -> Set<String> {
        messageIDTokens(from: message.messageIdHeader)
            .union(messageIDTokens(from: message.inReplyTo))
            .union(messageIDTokens(from: message.referencesChain))
    }

    private nonisolated static func headerSearchTokens(for message: Message) -> Set<String> {
        messageIDSearchTokens(from: message.messageIdHeader)
            .union(messageIDSearchTokens(from: message.inReplyTo))
            .union(messageIDSearchTokens(from: message.referencesChain))
    }

    private nonisolated static func messageIDTokens(from value: String?) -> Set<String> {
        guard let value else { return [] }
        let tokens = value
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .compactMap { raw -> String? in
                let trimmed = String(raw).trimmingCharacters(
                    in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
                )
                return normalizeMessageIDHeader(trimmed)
            }
        return Set(tokens)
    }

    private nonisolated static func messageIDSearchTokens(from value: String?) -> Set<String> {
        guard let value else { return [] }
        let tokens = value
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .flatMap { raw -> [String] in
                let stripped = String(raw).trimmingCharacters(
                    in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>,"))
                )
                guard stripped.isEmpty == false else { return [] }
                if let normalized = normalizeMessageIDHeader(stripped), normalized != stripped {
                    return [stripped, normalized]
                }
                return [stripped]
            }
        return Set(tokens)
    }

    private nonisolated static func threadMessagePrecedes(_ lhs: Message, _ rhs: Message) -> Bool {
        switch (lhs.vectorTimeFilterDate, rhs.vectorTimeFilterDate) {
        case let (l?, r?):
            return l == r ? lhs.id.uuidString < rhs.id.uuidString : l < r
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private nonisolated static func shouldPreferThreadDuplicate(
        _ candidate: Message,
        over existing: Message,
        focusedID: UUID
    ) -> Bool {
        if candidate.id == focusedID { return true }
        if existing.id == focusedID { return false }

        let candidateArtifacts = artifactScore(candidate)
        let existingArtifacts = artifactScore(existing)
        if candidateArtifacts != existingArtifacts {
            return candidateArtifacts > existingArtifacts
        }
        if candidate.ingestedAt != existing.ingestedAt {
            return candidate.ingestedAt < existing.ingestedAt
        }
        return candidate.id.uuidString < existing.id.uuidString
    }

    private nonisolated static func threadDuplicateKey(for message: Message) -> String {
        if let messageID = normalizeMessageIDHeader(message.messageIdHeader) {
            return "message-id:\(messageID)"
        }
        if let hash = message.contentHash?.trimmingCharacters(in: .whitespacesAndNewlines),
           hash.isEmpty == false {
            return "content:\(hash)"
        }
        if let folder = message.imapFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           folder.isEmpty == false,
           message.imapUID > 0 {
            return "imap:\(folder.lowercased()):\(message.imapUID)"
        }
        return "id:\(message.id.uuidString)"
    }

    /// Match a cached snapshot against the live filter for the loading guard.
    static func signatureMatchesCurrentFilter(
        snapshot: FrontPageSnapshot,
        filter: VectorFilter,
        selectedTimeRange: TimeRangePreset,
        unreadOnly: Bool
    ) -> Bool {
        snapshot.signature.filterFingerprint == snapshotFilterFingerprint(
            baseFilter: filter,
            selectedTimeRange: selectedTimeRange
        )
            && snapshot.signature.unreadOnly == unreadOnly
    }

    private func cachedSnapshot(
        for preflightKey: FrontPagePreflightKey,
        now: Date
    ) -> FrontPageSnapshot? {
        guard let index = cacheEntries.lastIndex(where: {
            Self.isPreflightCacheHit(
                cachedKey: $0.preflightKey,
                requestedKey: preflightKey,
                builtAt: $0.snapshot.builtAt,
                now: now
            )
        }) else {
            return nil
        }
        let entry = cacheEntries.remove(at: index)
        cacheEntries.append(entry)
        return entry.snapshot
    }

    private func cachedSnapshot(
        for signature: FrontPageSnapshotSignature,
        now: Date
    ) -> FrontPageSnapshot? {
        guard let index = cacheEntries.lastIndex(where: {
            $0.signature == signature
                && now.timeIntervalSince($0.snapshot.builtAt) <= 60
        }) else {
            return nil
        }
        let entry = cacheEntries.remove(at: index)
        cacheEntries.append(entry)
        return entry.snapshot
    }

    private func store(
        _ snapshot: FrontPageSnapshot,
        for signature: FrontPageSnapshotSignature,
        preflightKey: FrontPagePreflightKey
    ) {
        cacheEntries.removeAll { $0.signature == signature }
        cacheEntries.append(CacheEntry(
            signature: signature,
            preflightKey: preflightKey,
            snapshot: snapshot
        ))
        if cacheEntries.count > Self.cacheLimit {
            cacheEntries.removeFirst(cacheEntries.count - Self.cacheLimit)
        }
    }

    private func cachedSemanticStatus(
        for key: SemanticStatusCacheKey
    ) -> SemanticMessageStatusSnapshot? {
        guard let index = semanticStatusCacheEntries.lastIndex(where: { $0.key == key }) else {
            return nil
        }
        let entry = semanticStatusCacheEntries.remove(at: index)
        semanticStatusCacheEntries.append(entry)
        return entry.snapshot
    }

    private func storeSemanticStatus(
        _ snapshot: SemanticMessageStatusSnapshot,
        for key: SemanticStatusCacheKey
    ) {
        semanticStatusCacheEntries.removeAll { $0.key == key }
        semanticStatusCacheEntries.append(SemanticStatusCacheEntry(key: key, snapshot: snapshot))
        if semanticStatusCacheEntries.count > Self.semanticStatusCacheLimit {
            semanticStatusCacheEntries.removeFirst(
                semanticStatusCacheEntries.count - Self.semanticStatusCacheLimit
            )
        }
    }

    nonisolated static func effectiveFrontPageFilter(
        baseFilter: VectorFilter,
        selectedTimeRange: TimeRangePreset,
        now: Date = Date.now
    ) -> VectorFilter {
        var resolved = ConstellationFilterResolver.effectiveSceneFilter(
            baseFilter: baseFilter,
            selectedTimeRange: selectedTimeRange,
            now: now
        )
        // Front Page has no received/sent direction control; it is always the
        // received-mail reading surface. Do not let a hidden direction scope
        // carried from another lens suppress its articles.
        resolved.sentStates = nil
        resolved.resolvedCriterion = ResolvedActionFilterPolicy.criterion(
            stored: resolved.resolvedCriterion,
            lens: .frontPage
        )
        return resolved
    }

    /// Semantic-status definitions retain the account and concrete Moments window but
    /// deliberately ignore message-level controls such as Topics, Read, and
    /// attention state. The active filter is projected onto this stable pool
    /// after semantic grouping.
    nonisolated static func semanticStatusDefinitionFilter(from filter: VectorFilter) -> VectorFilter {
        var definition = VectorFilter()
        definition.accountIds = filter.accountIds
        definition.timeRange = filter.timeRange
        return definition
    }

    nonisolated static func snapshotFilterFingerprint(
        baseFilter: VectorFilter,
        selectedTimeRange: TimeRangePreset
    ) -> String {
        var normalized = baseFilter
        normalized.sentStates = nil
        if selectedTimeRange != .custom {
            normalized.timeRange = nil
        }
        return "preset:\(selectedTimeRange.rawValue)|filter:\(filterFingerprint(normalized))"
    }

    /// Semantic status is stable inside an account + Moments scope. All other
    /// controls are message-level projections and should reuse the same costly
    /// definition snapshot. Rolling presets key by preset identity instead of
    /// their continuously moving concrete bounds; custom ranges retain their
    /// exact dates.
    nonisolated static func semanticStatusScopeFingerprint(
        baseFilter: VectorFilter,
        selectedTimeRange: TimeRangePreset
    ) -> String {
        var structural = VectorFilter()
        structural.accountIds = baseFilter.accountIds
        if selectedTimeRange == .custom {
            structural.timeRange = baseFilter.timeRange
        }
        return "preset:\(selectedTimeRange.rawValue)|filter:\(filterFingerprint(structural))"
    }

    /// Stable while the same structural messages remain on the same side of
    /// the time-sensitive status boundaries. This lets message-level
    /// filters reuse definitions for as long as they are actually equivalent,
    /// while a rolling-window departure, 21-day revival expiry, or 45-day
    /// quiet transition forces a rebuild at the first subsequent refresh.
    nonisolated static func semanticStatusRevisionFingerprint(
        messages: [ProjectMessageInput],
        configuration: SemanticMessageStatusConfiguration
    ) -> String {
        let quietWindow: TimeInterval = 45 * 86_400
        let rows = messages.map { message in
            let age = configuration.now.timeIntervalSince(message.date)
            let isQuiet = age > quietWindow ? "1" : "0"
            let isRevivalRecent = age <= configuration.revivalRecentWindow ? "1" : "0"
            return "\(message.id.uuidString):quiet=\(isQuiet):revivalRecent=\(isRevivalRecent)"
        }
        return rows.sorted().joined(separator: "|")
    }

    nonisolated static func filterFingerprint(_ filter: VectorFilter) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(CanonicalFilterFingerprint(filter: filter)),
              let encoded = String(data: data, encoding: .utf8) else {
            return String(describing: filter)
        }
        return encoded
    }

    nonisolated private static func messageIDsFingerprint(_ ids: [UUID]) -> String {
        ids.map(\.uuidString).sorted().joined(separator: "|")
    }

    private func subscribeToLiveRefresh() {
        let center = notificationCenter
        deletionObserver = center.addObserver(
            forName: .ohiaDeletionApplied,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateAndRefresh() }
        }
        ingestObserver = center.addObserver(
            forName: .ohiaIMAPNewInboundMessages,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateAndRefresh(deferringIfRefreshInFlight: true)
            }
        }
        summaryInvalidationObserver = center.addObserver(
            forName: .ohiaEmailSummariesInvalidated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateAndRefresh() }
        }
        accountColorObserver = center.addObserver(
            forName: .ohiaAccountColorChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateAndRefresh(deferringIfRefreshInFlight: true)
            }
        }
        messageAttentionObserver = center.addObserver(
            forName: .ohiaMessageAttentionChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateAndRefresh() }
        }
        arrivalVisibilityObserver = center.addObserver(
            forName: .ohiaNewMailArrivalVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateAndRefresh() }
        }
    }

    private struct GatheredInput: Sendable {
        let inputs: [FrontPageArticleInput]
        let articlesByID: [UUID: FrontPageArticle]
        let messageFilterRows: [String: MessageFilterRow]
        let actionFingerprint: String
        let freshStartPolicyFingerprint: String
        let statusFingerprint: String
    }

    /// Pass-one projection. It contains only values needed to decide project,
    /// attention, duplicate, and final filter membership. Reader/card fields and
    /// attachment relationships are intentionally deferred until pass two.
    struct PreparedCandidate: Sendable {
        let id: UUID
        let date: Date
        let duplicateKey: String
        let projectInput: ProjectMessageInput?
        let attentionInput: MessageAttentionInput
        let baseFilterRow: MessageFilterRow
        let hasDirectSharedRecipientEvidence: Bool
        let hasSummary: Bool
        let artifactScore: Int
    }

    struct ComposerEligibilityState: Sendable {
        let override: ComposerQueueOverride?
        let draftStatus: DraftStatus?
    }

    /// Pass-two projection freshly fetched after project computation. This is
    /// the only refresh value that traverses attachments or carries reader paths.
    struct ArticleEnrichment: Sendable {
        let id: UUID
        let date: Date
        let dimensions: MessageDimensions?
        let hasDeadline: Bool
        let deadlineText: String?
        let classification: MailClassification?
        let customCategoryKeys: Set<String>
        let baseFilterRow: MessageFilterRow
        let readAt: Date?
        let isInComposerQueue: Bool
        let rawPath: String?
        let imagePath: String?
        let accountInfo: AccountInfo
        let rawMessageType: MessageType
        let summary: String?
        let hasListID: Bool
        let isDirectToUser: Bool
    }

    private struct BodyPreviewCandidate: Sendable {
        let messageID: UUID
        let bodyHtmlPath: String?
        let bodyTextPath: String?
        let rawPath: String?
    }

    struct AccountInfo: Equatable, Sendable {
        let displayName: String
        let emailAddress: String
        let colorIndex: Int
        let ownedEmailAddresses: Set<String>
    }

    nonisolated static func accountsByID(modelContext: ModelContext) -> [UUID: AccountInfo] {
        let accountDescriptor = FetchDescriptor<Account>()
        return ((try? modelContext.fetch(accountDescriptor)) ?? [])
            .reduce(into: [:]) { dict, account in
                dict[account.id] = AccountInfo(
                    displayName: account.displayName,
                    emailAddress: account.emailAddress,
                    colorIndex: account.colorIndex ?? AccountColorPalette.defaultIndex,
                    ownedEmailAddresses: account.ownedEmailAddresses
                )
            }
    }

    /// Resolves pass-one values synchronously. No `Message` or relationship
    /// model escapes this call.
    nonisolated static func preparedCandidateSnapshot(
        for message: Message,
        date: Date,
        triage: TriageVerdict?,
        dimensions: MessageDimensions?,
        classification: MailClassification?,
        customCategoryKeys: Set<String>,
        baseFilterRow suppliedBaseFilterRow: MessageFilterRow? = nil
    ) -> PreparedCandidate {
        let fullFilterRow = suppliedBaseFilterRow ?? Self.messageFilterRow(
            for: message,
            date: date,
            classificationJSON: classification.flatMap { try? MailClassificationJSON.encode($0) },
            customCategoryKeys: customCategoryKeys,
            dimensions: dimensions,
            triageVerdict: triage
        )
        let baseFilterRow = Self.candidateFilterRow(from: fullFilterRow)
        let projectInput = ProjectMessageInputBuilder.projectInput(
            for: message,
            date: date,
            dimensions: dimensions,
            triageVerdict: triage
        )
        let attentionInput = projectInput.map(MessageAttentionInput.init(projectMessage:))
            ?? Self.attentionInput(for: message, date: date, triageVerdict: triage)
        return PreparedCandidate(
            id: message.id,
            date: date,
            duplicateKey: Self.duplicateKey(for: message),
            projectInput: projectInput,
            attentionInput: attentionInput,
            baseFilterRow: baseFilterRow,
            hasDirectSharedRecipientEvidence: projectInput.map {
                ProjectMessageInputBuilder.hasDirectSharedRecipientEvidence(for: $0)
            } ?? false,
            hasSummary: SummaryTextSanitizer.cleaned(message.analysis?.bodySummary) != nil,
            artifactScore: Self.artifactScore(message)
        )
    }

    /// Completes the entire SwiftData candidate traversal synchronously so no
    /// fetched model or relationship fault remains live across project await.
    private nonisolated static func prepareCandidates(
        modelContext: ModelContext,
        vectorStore: VectorStore,
        filter: VectorFilter,
        arrivals: NewMailArrivalLedger.GatherSnapshot
    ) throws -> [PreparedCandidate] {
        try Task.checkCancellation()
        let candidateFetchStartedAt = LensLoadPerformanceLog.start()
        let messages = fetchCandidateMessages(
            modelContext: modelContext,
            vectorStore: vectorStore,
            filter: filter
        )
        try Task.checkCancellation()
        LensLoadPerformanceLog.record(
            lens: .frontPage,
            stage: "candidate-fetch",
            startedAt: candidateFetchStartedAt,
            resultCount: messages.count
        )
        let projectionStartedAt = LensLoadPerformanceLog.start()
        let triageDecoder = JSONDecoder()
        let dimensionsDecoder = JSONDecoder()
        let customCategoryCatalogKeys = CustomMailCategoryCatalog.allKeys(in: modelContext)
        var candidates: [PreparedCandidate] = []
        candidates.reserveCapacity(messages.count)

        for message in messages {
            try Task.checkCancellation()
            guard let date = message.vectorTimeFilterDate else { continue }
            if message.isSentByUser == false,
               arrivals.isEmbargoed(
                   messageID: message.id,
                   liveDetectedAt: message.liveDetectedAt
               ) {
                continue
            }
            let decodedTriage = Self.decodeTriageVerdict(
                message.analysis?.triageVerdictJSON,
                decoder: triageDecoder,
                isSentByUser: message.isSentByUser
            )
            let triage = message.isLiveInboundTriageEligible ? decodedTriage : nil
            let rawDimensions = Self.decodeDimensions(
                message.analysis?.dimensionsJSON,
                decoder: dimensionsDecoder
            )
            let dimensions = message.isLiveInboundTriageEligible
                ? rawDimensions
                : rawDimensions?.scrubbingTriageActionState()
            let customKeys = Set(CustomCategoryKeysJSON.decode(
                message.analysis?.customCategoryKeysJSON
            ))
                .intersection(customCategoryCatalogKeys)
            let row = Self.messageFilterRow(
                for: message,
                date: date,
                classificationJSON: message.analysis?.mailClassificationJSON,
                customCategoryKeys: customKeys,
                dimensions: dimensions,
                triageVerdict: triage
            )
            let classification = row.mailClassification
            if message.isSentByUser {
                guard Self.frontPageAttentionScopeMatches(row, filter: filter) else { continue }
            } else if ConstellationMessageFilter.matches(
                row,
                filter: filter,
                includeHeadlineFlags: false
            ) == false {
                continue
            }
            candidates.append(Self.preparedCandidateSnapshot(
                for: message,
                date: date,
                triage: triage,
                dimensions: dimensions,
                classification: classification,
                customCategoryKeys: customKeys,
                baseFilterRow: row
            ))
        }
        LensLoadPerformanceLog.record(
            lens: .frontPage,
            stage: "pass-one-projection",
            startedAt: projectionStartedAt,
            candidateCount: messages.count,
            resultCount: candidates.count
        )
        return candidates
    }

    nonisolated private static func scopedCandidates(
        _ candidates: [PreparedCandidate],
        matching filter: VectorFilter
    ) throws -> [PreparedCandidate] {
        try candidates.filter { candidate in
            try Task.checkCancellation()
            if candidate.baseFilterRow.isSentByUser {
                return frontPageAttentionScopeMatches(candidate.baseFilterRow, filter: filter)
            }
            return ConstellationMessageFilter.matches(
                candidate.baseFilterRow,
                filter: filter,
                includeHeadlineFlags: false
            )
        }
    }

    private func gatherInput(
        modelContext: ModelContext,
        vectorStore: VectorStore,
        filter: VectorFilter,
        unreadOnly: Bool,
        semanticStatusScopeFingerprint: String,
        requestSourceRevision: UInt64,
        requestSemanticStatusSourceRevision: UInt64
    ) async throws -> GatheredInput {
        try Task.checkCancellation()
        gatherInvocationCount += 1
        if let onGatherStarted {
            await onGatherStarted(gatherInvocationCount)
        }
        try Task.checkCancellation()
        guard requestSourceRevision == sourceRevision else { throw CancellationError() }
        // Flush any pending main-context changes (an action write, a local
        // deletion cascade) so the worker phases' fresh background contexts
        // read the state the user just produced, not the last autosave.
        try? modelContext.save()
        let arrivals = NewMailArrivalLedger.shared.gatherSnapshot()
        let container = modelContext.container
        // Pass one runs entirely off the main actor: candidate fetch, per-message
        // projection, action state, and fresh-start policy in a private context.
        // The main thread stays free for clicks while thousands of rows decode.
        let passOne = try await refreshWorker.run {
            try Self.gatherPassOne(
                container: container,
                vectorStore: vectorStore,
                filter: filter,
                arrivals: arrivals
            )
        }
        try Task.checkCancellation()
        guard requestSourceRevision == sourceRevision else { throw CancellationError() }
        let semanticStatusKey = SemanticStatusCacheKey(
            sourceRevision: requestSemanticStatusSourceRevision,
            scopeFingerprint: semanticStatusScopeFingerprint,
            actionFingerprint: passOne.actionFingerprint,
            freshStartPolicyFingerprint: passOne.freshStartPolicyFingerprint,
            definitionRevisionFingerprint: passOne.definitionRevisionFingerprint
        )
        let semanticStatusStartedAt = LensLoadPerformanceLog.start()
        let cachedSemanticStatus = cachedSemanticStatus(for: semanticStatusKey)
        let semanticStatusDefinitions: SemanticMessageStatusSnapshot
        let semanticStatusCacheResult: String
        if let cachedSemanticStatus {
            semanticStatusDefinitions = cachedSemanticStatus
            semanticStatusCacheResult = "hit"
        } else {
            let semanticStatusSnapshotBuilder = self.semanticStatusSnapshotBuilder
            let semanticStatusInputs = passOne.semanticStatusInputs
            let sharedMessageActions = passOne.sharedMessageActions
            let semanticStatusConfiguration = passOne.semanticStatusConfiguration
            semanticStatusDefinitions = try await refreshWorker.run {
                semanticStatusSnapshotBuilder.build(
                    messages: semanticStatusInputs,
                    sharedMessageActions: sharedMessageActions,
                    configuration: semanticStatusConfiguration
                )
            }
            semanticStatusCacheResult = "miss"
            if Task.isCancelled == false,
               requestSemanticStatusSourceRevision == semanticStatusSourceRevision {
                storeSemanticStatus(semanticStatusDefinitions, for: semanticStatusKey)
            }
        }
        try Task.checkCancellation()
        guard requestSourceRevision == sourceRevision else { throw CancellationError() }
        // Pass two also runs off-main: projection, composer state, enrichment,
        // body previews, and article assembly against a private context.
        return try await refreshWorker.run {
            try Self.gatherPassTwo(
                container: container,
                filter: filter,
                unreadOnly: unreadOnly,
                passOne: passOne,
                semanticStatusDefinitions: semanticStatusDefinitions,
                semanticStatusCacheResult: semanticStatusCacheResult,
                semanticStatusStartedAt: semanticStatusStartedAt
            )
        }
    }

    /// Everything the off-main first gather pass produces. All value snapshots —
    /// no `Message` or other model crosses out of the pass.
    private struct GatherPassOne: Sendable {
        let preparedMessages: [PreparedCandidate]
        let semanticStatusInputs: [ProjectMessageInput]
        let scopedSemanticMessageIDs: Set<UUID>
        let actionState: ProjectLensUserActionState
        let sharedMessageActions: ProjectLensSharedMessageActionState
        let rawAttentionByMessageID: [UUID: MessageAttentionState]
        let semanticStatusConfiguration: SemanticMessageStatusConfiguration
        let actionFingerprint: String
        let freshStartPolicyFingerprint: String
        let definitionRevisionFingerprint: String
    }

    /// Off-main pass one: candidate fetch + per-message projection + action
    /// state + fresh-start policy, all in a fresh background `ModelContext`.
    private nonisolated static func gatherPassOne(
        container: ModelContainer,
        vectorStore: VectorStore,
        filter: VectorFilter,
        arrivals: NewMailArrivalLedger.GatherSnapshot
    ) throws -> GatherPassOne {
        try Task.checkCancellation()
        let modelContext = ModelContext(container)
        let definitionFilter = Self.semanticStatusDefinitionFilter(from: filter)
        let definitionMessages = try prepareCandidates(
            modelContext: modelContext,
            vectorStore: vectorStore,
            filter: definitionFilter,
            arrivals: arrivals
        )
        let preparedMessages = try Self.scopedCandidates(definitionMessages, matching: filter)

        let accountScopeKey = ProjectsDataController.accountScopeKey(for: filter)
        let actionState = ProjectLensActionRepository(modelContext: modelContext)
            .actionState(accountScopeKey: accountScopeKey)
        let messageActions = MessageAttentionUserActionState(projectActions: actionState)
        try Task.checkCancellation()
        let rawAttentionByMessageID = MessageAttentionResolver.states(
            messages: preparedMessages.map(\.attentionInput),
            userActions: messageActions
        )
        let freshStartActiveWindow = ProjectFreshStartPolicy.activeWindow(
            modelContext: modelContext,
            filter: filter
        )
        try Task.checkCancellation()
        let semanticStatusInputs = definitionMessages.compactMap(\.projectInput)
        let scopedSemanticMessageIDs = Set(preparedMessages.compactMap(\.projectInput).map(\.id))
        let sharedMessageActions = actionState.sharedMessageActions
        let selfAddresses = Set(
            ((try? modelContext.fetch(FetchDescriptor<Identity>())) ?? []).map(\.address)
        )
        let semanticStatusConfiguration = SemanticMessageStatusConfiguration(
            now: Date.now,
            activeWindow: freshStartActiveWindow,
            selfAddresses: selfAddresses
        )
        return GatherPassOne(
            preparedMessages: preparedMessages,
            semanticStatusInputs: semanticStatusInputs,
            scopedSemanticMessageIDs: scopedSemanticMessageIDs,
            actionState: actionState,
            sharedMessageActions: sharedMessageActions,
            rawAttentionByMessageID: rawAttentionByMessageID,
            semanticStatusConfiguration: semanticStatusConfiguration,
            actionFingerprint: messageActions.fingerprint,
            freshStartPolicyFingerprint: freshStartActiveWindow?.fingerprint ?? "off",
            definitionRevisionFingerprint: Self.semanticStatusRevisionFingerprint(
                messages: semanticStatusInputs,
                configuration: semanticStatusConfiguration
            )
        )
    }

    /// Off-main pass two: project projection, composer state, enrichment, body
    /// previews, and article assembly in a fresh background `ModelContext`.
    private nonisolated static func gatherPassTwo(
        container: ModelContainer,
        filter: VectorFilter,
        unreadOnly: Bool,
        passOne: GatherPassOne,
        semanticStatusDefinitions: SemanticMessageStatusSnapshot,
        semanticStatusCacheResult: String,
        semanticStatusStartedAt: UInt64
    ) throws -> GatheredInput {
        try Task.checkCancellation()
        let modelContext = ModelContext(container)
        let preparedMessages = passOne.preparedMessages
        let actionState = passOne.actionState
        var inputs: [FrontPageArticleInput] = []
        var articlesByID: [UUID: FrontPageArticle] = [:]
        var rows: [String: MessageFilterRow] = [:]

        let semanticStatusSnapshot = semanticStatusDefinitions.projected(
            matchingMessageIDs: passOne.scopedSemanticMessageIDs
        )
        LensLoadPerformanceLog.record(
            lens: .frontPage,
            stage: "semantic-status-computation",
            startedAt: semanticStatusStartedAt,
            candidateCount: passOne.semanticStatusInputs.count,
            resultCount: semanticStatusSnapshot.semanticGroupCount,
            cache: semanticStatusCacheResult
        )
        let directSharedRecipientMessageIDs = Set(preparedMessages.compactMap { prepared -> UUID? in
            prepared.hasDirectSharedRecipientEvidence
                ? prepared.id
                : nil
        })
        let statusSignals = semanticStatusSnapshot.statusSignals
            .addingDirectSharedRecipientEvidence(messageIDs: directSharedRecipientMessageIDs)
        let attentionByMessageID = semanticStatusSnapshot.applyingAttentionGate(
            to: passOne.rawAttentionByMessageID
        )
        let visibleMessages = Self.deduplicatedMessages(
            preparedMessages,
            attentionByMessageID: attentionByMessageID
        )
        try Task.checkCancellation()
        let composerStateStartedAt = LensLoadPerformanceLog.start()
        let composerStateByID = composerEligibilityStates(
            modelContext: modelContext,
            messageIDs: Set(visibleMessages.map(\.id))
        )
        LensLoadPerformanceLog.record(
            lens: .frontPage,
            stage: "composer-state",
            startedAt: composerStateStartedAt,
            candidateCount: visibleMessages.count,
            resultCount: composerStateByID.count
        )
        var attentionStateByID: [UUID: MessageAttentionState] = [:]
        var isRepliedByID: [UUID: Bool] = [:]
        var isConfirmedByID: [UUID: Bool] = [:]
        var isResolvedByID: [UUID: Bool] = [:]
        let selectionCandidates = try visibleMessages.map { prepared in
            try Task.checkCancellation()
            let attention = attentionByMessageID[prepared.id]
                ?? MessageAttentionState(messageID: prepared.id, openKinds: [])
            let isReplied = Self.isReplied(
                messageID: prepared.id,
                repliedAt: prepared.attentionInput.repliedAt,
                attention: attention,
                actionState: actionState
            )
            let isConfirmed = actionState.confirmedMessageIDs.contains(prepared.id)
            let isResolved = actionState.resolvedMessageIDs.contains(prepared.id)
            let row = Self.messageFilterRow(
                from: prepared.baseFilterRow,
                isActionable: attention.needsReply,
                requiresConfirmation: attention.needsConfirmation,
                isReplied: isReplied,
                isConfirmed: isConfirmed,
                isResolved: isResolved
            )
            attentionStateByID[prepared.id] = attention
            isRepliedByID[prepared.id] = isReplied
            isConfirmedByID[prepared.id] = isConfirmed
            isResolvedByID[prepared.id] = isResolved
            let composerState = composerStateByID[prepared.id]
            return FrontPageArticleSelectionCandidate(
                id: prepared.id,
                isSentByUser: prepared.baseFilterRow.isSentByUser,
                isRead: prepared.baseFilterRow.isRead,
                threadID: prepared.baseFilterRow.threadId,
                composerQueueOverride: composerState?.override,
                draftStatus: composerState?.draftStatus,
                matchesFinalFilter: ConstellationMessageFilter.matches(row, filter: filter)
            )
        }
        let survivingIDs = Self.survivingArticleIDs(
            selectionCandidates,
            unreadOnly: unreadOnly
        )
        LensLoadPerformanceLog.record(
            lens: .frontPage,
            stage: "selection",
            candidateCount: selectionCandidates.count,
            resultCount: survivingIDs.count
        )
        let enrichmentStartedAt = LensLoadPerformanceLog.start()
        try Task.checkCancellation()
        let enrichmentsByID = articleEnrichments(
            modelContext: modelContext,
            messageIDs: Set(survivingIDs)
        )
        LensLoadPerformanceLog.record(
            lens: .frontPage,
            stage: "article-enrichment",
            startedAt: enrichmentStartedAt,
            candidateCount: survivingIDs.count,
            resultCount: enrichmentsByID.count
        )
        let bodyPreviewCandidates = survivingIDs.compactMap { messageID -> BodyPreviewCandidate? in
            guard let enrichment = enrichmentsByID[messageID],
                  !Self.hasNonEmptySummary(enrichment),
                  Self.hasReadableBodyPath(enrichment) else {
                return nil
            }
            return BodyPreviewCandidate(
                messageID: messageID,
                bodyHtmlPath: enrichment.baseFilterRow.bodyHtmlPath,
                bodyTextPath: enrichment.baseFilterRow.bodyTextPath,
                rawPath: enrichment.rawPath
            )
        }
        let bodyPreviewStartedAt = LensLoadPerformanceLog.start()
        try Task.checkCancellation()
        let bodyPreviews = Self.bodyPreviews(for: bodyPreviewCandidates)
        LensLoadPerformanceLog.record(
            lens: .frontPage,
            stage: "body-preview",
            startedAt: bodyPreviewStartedAt,
            candidateCount: bodyPreviewCandidates.count,
            resultCount: bodyPreviews.count
        )
        let preparedByID = Dictionary(uniqueKeysWithValues: visibleMessages.map { ($0.id, $0) })
        for messageID in survivingIDs {
            try Task.checkCancellation()
            guard let prepared = preparedByID[messageID],
                  let enrichment = enrichmentsByID[messageID],
                  let attention = attentionStateByID[messageID],
                  let isReplied = isRepliedByID[messageID],
                  let isConfirmed = isConfirmedByID[messageID],
                  let isResolved = isResolvedByID[messageID] else {
                continue
            }
            let row = Self.messageFilterRow(
                from: enrichment.baseFilterRow,
                isActionable: attention.needsReply,
                requiresConfirmation: attention.needsConfirmation,
                isReplied: isReplied,
                isConfirmed: isConfirmed,
                isResolved: isResolved
            )
            guard ConstellationMessageFilter.matches(row, filter: filter) else { continue }
            rows[prepared.id.uuidString] = row

            let input = FrontPageArticleInput(
                id: prepared.id,
                date: enrichment.date,
                subject: enrichment.baseFilterRow.subject,
                fromName: enrichment.baseFilterRow.fromName,
                fromAddress: enrichment.baseFilterRow.fromAddress,
                isSentByUser: enrichment.baseFilterRow.isSentByUser,
                isRead: enrichment.baseFilterRow.isRead,
                isActionable: attention.needsReply,
                requiresConfirmation: attention.needsConfirmation,
                isConfirmed: isConfirmed,
                messageType: enrichment.rawMessageType,
                hasDeadline: enrichment.hasDeadline,
                classification: enrichment.classification,
                isMailingList: enrichment.hasListID,
                isDirectToUser: enrichment.isDirectToUser,
                hasImage: enrichment.imagePath != nil,
                hasSummary: enrichment.summary?.isEmpty == false,
                threadID: enrichment.baseFilterRow.threadId
            )
            inputs.append(input)
            let rawAttention = passOne.rawAttentionByMessageID[prepared.id]
                ?? MessageAttentionState(messageID: prepared.id, openKinds: [])
            let rawIsReplied = Self.isReplied(
                messageID: prepared.id,
                repliedAt: prepared.attentionInput.repliedAt,
                attention: rawAttention,
                actionState: actionState
            )
            articlesByID[prepared.id] = Self.article(
                enrichment: enrichment,
                bodyPreview: bodyPreviews[prepared.id],
                attention: rawAttention,
                isReplied: rawIsReplied,
                isConfirmed: isConfirmed,
                isResolved: isResolved,
                isRevivedAfterInactiveGap: statusSignals.isRevivedAfterInactiveGap(prepared.id),
                sharedEvidenceKinds: statusSignals.sharedEvidenceKinds(for: prepared.id)
            )
        }

        return GatheredInput(
            inputs: inputs,
            articlesByID: articlesByID,
            messageFilterRows: rows,
            actionFingerprint: passOne.actionFingerprint,
            freshStartPolicyFingerprint: passOne.freshStartPolicyFingerprint,
            statusFingerprint: Self.statusFingerprint(Array(articlesByID.values))
        )
    }

    nonisolated private static func deadlineFingerprint(_ inputs: [FrontPageArticleInput]) -> String {
        "deadline=\(inputs.filter(\.hasDeadline).count)"
    }

    nonisolated private static func statusFingerprint(_ articles: [FrontPageArticle]) -> String {
        articles.map { article in
            [
                article.id.uuidString,
                article.isSentByUser ? "sent" : "received",
                article.isUnread ? "unread" : "read",
                article.isActionable ? "needs-reply" : "no-open-reply",
                article.requiresConfirmation ? "needs-confirmation" : "no-open-confirmation",
                article.isReplied ? "replied" : "not-replied",
                article.isConfirmed ? "confirmed" : "not-confirmed",
                article.isResolved ? "resolved" : "no-resolved-tag",
                article.isFlagged ? "flagged" : "not-flagged",
                article.hasDeadline ? "deadline" : "no-deadline",
                article.isRevivedAfterInactiveGap ? "revived" : "not-revived",
                article.sharedEvidenceKinds.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: ",")
            ].joined(separator: ":")
        }
        .sorted()
        .joined(separator: "|")
    }

    nonisolated private static func deduplicatedMessages(
        _ messages: [PreparedCandidate],
        attentionByMessageID: [UUID: MessageAttentionState]
    ) -> [PreparedCandidate] {
        var selectedByKey: [String: PreparedCandidate] = [:]
        var order: [String] = []
        for message in messages {
            guard !Task.isCancelled else { return [] }
            if let existing = selectedByKey[message.duplicateKey] {
                if shouldPreferDuplicate(
                    message,
                    over: existing,
                    attentionByMessageID: attentionByMessageID
                ) {
                    selectedByKey[message.duplicateKey] = message
                }
            } else {
                selectedByKey[message.duplicateKey] = message
                order.append(message.duplicateKey)
            }
        }
        return order.compactMap { selectedByKey[$0] }
    }

    nonisolated private static func shouldPreferDuplicate(
        _ candidate: PreparedCandidate,
        over existing: PreparedCandidate,
        attentionByMessageID: [UUID: MessageAttentionState]
    ) -> Bool {
        let candidateAttention = duplicateAttentionRank(
            attentionByMessageID[candidate.id]
        )
        let existingAttention = duplicateAttentionRank(
            attentionByMessageID[existing.id]
        )
        if candidateAttention != existingAttention {
            return candidateAttention > existingAttention
        }
        if candidate.baseFilterRow.isRead != existing.baseFilterRow.isRead {
            return candidate.baseFilterRow.isRead == false
        }
        let candidateSummary = candidate.hasSummary
        let existingSummary = existing.hasSummary
        if candidateSummary != existingSummary {
            return candidateSummary
        }
        let candidateArtifacts = candidate.artifactScore
        let existingArtifacts = existing.artifactScore
        if candidateArtifacts != existingArtifacts {
            return candidateArtifacts > existingArtifacts
        }
        if candidate.baseFilterRow.ingestedAt != existing.baseFilterRow.ingestedAt {
            return candidate.baseFilterRow.ingestedAt < existing.baseFilterRow.ingestedAt
        }
        return candidate.id.uuidString < existing.id.uuidString
    }

    /// Front Page is the received-mail reading surface. Sent rows remain
    /// available to the focused reader's thread loader, but never become
    /// standalone front-page articles. The top bar hides the received/sent
    /// pair in this lens, so any carried direction scope is ignored here.
    nonisolated static func frontPageDirectionMatches(
        isSentByUser: Bool,
        filter _: VectorFilter
    ) -> Bool {
        isSentByUser == false
    }

    nonisolated static func survivingArticleIDs(
        _ candidates: [FrontPageArticleSelectionCandidate],
        unreadOnly: Bool
    ) -> [UUID] {
        let hiddenComposerThreadIDs = frontPageHiddenComposerThreadIDs(
            candidates.map {
                (
                    threadID: $0.threadID,
                    override: $0.composerQueueOverride,
                    draftStatus: $0.draftStatus
                )
            }
        )
        return candidates.compactMap { candidate in
            guard candidate.isSentByUser == false else { return nil }
            if unreadOnly, candidate.isRead { return nil }
            if let threadID = candidate.threadID,
               hiddenComposerThreadIDs.contains(threadID) {
                return nil
            }
            guard frontPageHiddenByLiveComposerDraft(
                override: candidate.composerQueueOverride,
                draftStatus: candidate.draftStatus
            ) == false else {
                return nil
            }
            guard candidate.matchesFinalFilter else {
                return nil
            }
            return candidate.id
        }
    }

    /// A message is hidden from the Front Page only while it is *actively* in the
    /// Composer reply queue: the user sent it (`.include` override) and its draft
    /// is still live — generating (no row yet), `.pending`, or `.confirmed`.
    /// This is the launch-comet's departure: the card leaves the feed while
    /// the reply is being drafted / delivered.
    ///
    /// It RETURNS to the feed the moment the reply attempt is abandoned — an
    /// `.exclude` override (removed from the queue / "No Reply Needed") or a
    /// `.rejected` / `.discarded` draft — so a message never falls through the
    /// cracks. A `nil` override (auto-triaged candidate or ordinary unhandled
    /// mail) is never hidden here. A restored card stays until the user actually
    /// handles it. Once Composer is no longer live, Reply, Confirm, and Resolve
    /// visibility is owned exclusively by the Action filter. Driven by persisted
    /// SwiftData state
    /// (`composerQueueOverride` + `draft.status`), so it survives relaunch with no
    /// separate hidden-pending marker.
    nonisolated static func frontPageHiddenByLiveComposerDraft(
        override: ComposerQueueOverride?,
        draftStatus: DraftStatus?
    ) -> Bool {
        guard override == .include else { return false }
        switch draftStatus {
        case nil, .pending, .confirmed:
            return true
        case .sent, .rejected, .discarded:
            return false
        }
    }

    nonisolated static func frontPageHiddenComposerThreadIDs(
        _ draftStates: [(threadID: UUID?, override: ComposerQueueOverride?, draftStatus: DraftStatus?)]
    ) -> Set<UUID> {
        Set(
            draftStates.compactMap { state in
                guard let threadID = state.threadID,
                      frontPageHiddenByLiveComposerDraft(
                          override: state.override,
                          draftStatus: state.draftStatus
                      ) else {
                    return nil
                }
                return threadID
            }
        )
    }

    nonisolated private static func frontPageAttentionScopeMatches(
        _ row: MessageFilterRow,
        filter: VectorFilter
    ) -> Bool {
        if let accountIds = filter.accountIds {
            guard let rowAccountId = row.accountId else { return false }
            if accountIds.contains(rowAccountId) == false { return false }
        }
        if let range = filter.timeRange,
           let date = row.receivedAt,
           range.contains(date) == false {
            return false
        }
        return true
    }

    nonisolated private static func duplicateAttentionRank(_ attention: MessageAttentionState?) -> Int {
        guard let attention else { return 0 }
        if attention.needsReply { return 2 }
        if attention.needsConfirmation { return 1 }
        return 0
    }

    nonisolated private static func hasNonEmptySummary(_ enrichment: ArticleEnrichment) -> Bool {
        SummaryTextSanitizer.cleaned(enrichment.summary) != nil
    }

    nonisolated private static func hasReadableBodyPath(_ enrichment: ArticleEnrichment) -> Bool {
        [
            enrichment.baseFilterRow.bodyTextPath,
            enrichment.baseFilterRow.bodyHtmlPath,
            enrichment.rawPath
        ].contains { path in
            path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    nonisolated private static func bodyPreviews(
        for candidates: [BodyPreviewCandidate]
    ) -> [UUID: String] {
        var previews: [UUID: String] = [:]
        for candidate in candidates {
            guard !Task.isCancelled else { return [:] }
            guard let preview = bodyPreview(
                htmlPath: candidate.bodyHtmlPath,
                textPath: candidate.bodyTextPath,
                rawPath: candidate.rawPath
            ) else { continue }
            previews[candidate.messageID] = preview
        }
        return previews
    }

    nonisolated private static func bodyPreview(
        htmlPath: String?,
        textPath: String?,
        rawPath: String?
    ) -> String? {
        if let preview = bodyPreviewFromLoadedBody(htmlPath: nil, textPath: textPath, rawPath: nil) {
            return preview
        }
        if let preview = bodyPreviewFromLoadedBody(htmlPath: htmlPath, textPath: nil, rawPath: nil) {
            return preview
        }
        return bodyPreviewFromLoadedBody(htmlPath: nil, textPath: nil, rawPath: rawPath)
    }

    nonisolated static func bodyPreviewFromLoadedBody(
        htmlPath: String?,
        textPath: String?,
        rawPath: String?
    ) -> String? {
        guard case .loaded(let source) = LockReadoutBodyLoader.load(
            htmlPath: htmlPath,
            textPath: textPath,
            rawPath: rawPath
        ) else {
            return nil
        }
        let text = source.format == .html
            ? frontPageStripHTML(source.text)
            : source.text
        let cleaned = OriginalMessageText.cleaned(from: text) ?? text
        // This preview is the card's single-line lede, not a full-body read —
        // `OriginalMessageText.cleaned` deliberately preserves the sender's own
        // hard-wrapped lines and paragraph breaks (correct for readers), but a
        // non-flowed plain-text sender (no RFC 3676 trailing-space marker) then
        // renders as several short lines with blank space beside them instead
        // of prose that reflows to the card's width. Flatten every whitespace
        // run — including newlines — into a single joining space so the lede
        // always reads as continuous prose.
        let flattened = Self.flattenedLede(from: cleaned)
        guard !flattened.isEmpty else { return nil }
        return String(flattened.prefix(900)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Joins whitespace-separated tokens into one line, recovering the space a
    /// hard-wrapped English sentence actually had at its original break. CJK
    /// text never had a space there in the first place — Japanese/Chinese/
    /// Korean prose isn't word-spaced — so a break between two CJK tokens is
    /// closed with no separator instead of inserting a Latin space that was
    /// never part of the sender's text.
    nonisolated static func flattenedLede(from text: String) -> String {
        let tokens = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        var result = ""
        for token in tokens {
            if let lastScalar = result.unicodeScalars.last,
               let firstScalar = token.unicodeScalars.first,
               Self.isCJKScalar(lastScalar),
               Self.isCJKScalar(firstScalar) {
                result += token
            } else if result.isEmpty {
                result = token
            } else {
                result += " " + token
            }
        }
        return result
    }

    /// Covers CJK punctuation (、。「」 etc. — the characters a Japanese
    /// sentence actually ends a hard-wrapped line on), Hiragana/Katakana, the
    /// common CJK Unified Ideograph blocks (shared by Japanese kanji and
    /// Chinese hanzi), CJK compatibility ideographs, halfwidth katakana, and
    /// Hangul syllables.
    nonisolated private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF66...0xFF9D, 0xAC00...0xD7A3:
            return true
        default:
            return false
        }
    }

    /// Synchronous focused-thread loading still works directly from SwiftData;
    /// unlike the refresh gather, that path does not retain these models across
    /// an `await`.
    nonisolated private static func artifactScore(_ message: Message) -> Int {
        var score = 0
        if message.bodyTextPath?.isEmpty == false { score += 1 }
        if message.bodyHtmlPath?.isEmpty == false { score += 1 }
        if message.rawPath?.isEmpty == false { score += 1 }
        return score
    }

    nonisolated private static func duplicateKey(for message: Message) -> String {
        let accountKey = message.accountID?.uuidString
            ?? message.account?.id.uuidString
            ?? "none"
        if let messageID = normalizeMessageIDHeader(message.messageIdHeader) {
            return "message-id:\(accountKey):\(messageID)"
        }
        if let folder = message.imapFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           folder.isEmpty == false,
           message.imapUID > 0 {
            return "imap:\(accountKey):\(folder.lowercased()):\(message.imapUID)"
        }
        if let hash = message.contentHash?.trimmingCharacters(in: .whitespacesAndNewlines),
           hash.isEmpty == false {
            return "content:\(accountKey):\(hash)"
        }
        return "id:\(message.id.uuidString)"
    }

    private nonisolated static func fetchCandidateMessages(
        modelContext: ModelContext,
        vectorStore: VectorStore,
        filter: VectorFilter
    ) -> [Message] {
        guard !Task.isCancelled else { return [] }
        guard let range = filter.timeRange else {
            let descriptor = FetchDescriptor<Message>()
            return ((try? modelContext.fetch(descriptor)) ?? []).filter {
                !Task.isCancelled && !$0.isTrashed
            }
        }

        let vectorRangeIDs: Set<UUID>
        do {
            vectorRangeIDs = try vectorStore.messageIDsInDateRange(range)
        } catch {
            assertionFailure("VectorStore.messageIDsInDateRange failed: \(error)")
            vectorRangeIDs = []
        }
        guard !Task.isCancelled else { return [] }

        let sentOnlyDescriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { msg in
                msg.receivedAt == nil
                    && msg.sentAt != nil
                    && msg.sentAt! >= range.lowerBound
                    && msg.sentAt! <= range.upperBound
            }
        )
        let sentOnlyMessages = ((try? modelContext.fetch(sentOnlyDescriptor)) ?? [])
            .filter { !Task.isCancelled && !$0.isTrashed }
        guard !Task.isCancelled else { return [] }

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
                .filter { !Task.isCancelled && !$0.isTrashed }
        }

        var byID: [UUID: Message] = [:]
        for message in fetchedFromVectors {
            guard !Task.isCancelled else { return [] }
            byID[message.id] = message
        }
        for message in sentOnlyMessages {
            guard !Task.isCancelled else { return [] }
            byID[message.id] = message
        }
        return Array(byID.values)
    }

    /// Re-fetches Composer membership after the worker's project phase so pass
    /// one never faults `Message.draft` and the eligibility decision cannot use
    /// pre-await queue state.
    nonisolated static func composerEligibilityStates(
        modelContext: ModelContext,
        messageIDs: Set<UUID>
    ) -> [UUID: ComposerEligibilityState] {
        guard !Task.isCancelled, messageIDs.isEmpty == false else { return [:] }
        let idSet = messageIDs
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                idSet.contains(message.id)
            }
        )
        let messages = (try? modelContext.fetch(descriptor)) ?? []
        var states: [UUID: ComposerEligibilityState] = [:]
        for message in messages {
            guard !Task.isCancelled else { return [:] }
            states[message.id] = ComposerEligibilityState(
                override: message.composerQueueOverride,
                draftStatus: message.draft?.status
            )
        }
        return states
    }

    /// Re-fetches only final article IDs after the worker's project phase, then
    /// immediately projects fresh SwiftData models to value types. Missing IDs
    /// (for example, a concurrent deletion) are simply omitted.
    nonisolated static func articleEnrichments(
        modelContext: ModelContext,
        messageIDs: Set<UUID>
    ) -> [UUID: ArticleEnrichment] {
        guard !Task.isCancelled, messageIDs.isEmpty == false else { return [:] }
        let idSet = messageIDs
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                idSet.contains(message.id)
            }
        )
        let messages = (try? modelContext.fetch(descriptor)) ?? []
        let triageDecoder = JSONDecoder()
        let dimensionsDecoder = JSONDecoder()
        let customCategoryCatalogKeys = CustomMailCategoryCatalog.allKeys(in: modelContext)
        let accountsByID = Self.accountsByID(modelContext: modelContext)
        var enrichments: [UUID: ArticleEnrichment] = [:]
        enrichments.reserveCapacity(messages.count)

        for message in messages {
            guard !Task.isCancelled else { return [:] }
            guard let date = message.vectorTimeFilterDate else { continue }
            let decodedTriage = Self.decodeTriageVerdict(
                message.analysis?.triageVerdictJSON,
                decoder: triageDecoder,
                isSentByUser: message.isSentByUser
            )
            let triage = message.isLiveInboundTriageEligible ? decodedTriage : nil
            let rawDimensions = Self.decodeDimensions(
                message.analysis?.dimensionsJSON,
                decoder: dimensionsDecoder
            )
            let dimensions = message.isLiveInboundTriageEligible
                ? rawDimensions
                : rawDimensions?.scrubbingTriageActionState()
            let customKeys = Set(CustomCategoryKeysJSON.decode(
                message.analysis?.customCategoryKeysJSON
            ))
                .intersection(customCategoryCatalogKeys)
            let row = Self.messageFilterRow(
                for: message,
                date: date,
                classificationJSON: message.analysis?.mailClassificationJSON,
                customCategoryKeys: customKeys,
                dimensions: dimensions,
                triageVerdict: triage
            )
            let classification = row.mailClassification
            let accountInfo = Self.accountInfo(for: message, accountsByID: accountsByID)
            let isDirectToUser = row.toAddresses.contains { address in
                accountInfo.ownedEmailAddresses.contains(address)
            }
            enrichments[message.id] = ArticleEnrichment(
                id: message.id,
                date: date,
                dimensions: dimensions,
                hasDeadline: rawDimensions?.deadlines.isEmpty == false,
                deadlineText: rawDimensions?.primaryDeadlineDisplayText,
                classification: classification,
                customCategoryKeys: customKeys,
                baseFilterRow: row,
                readAt: message.readAt,
                isInComposerQueue: message.isComposerQueueEligible,
                rawPath: message.rawPath,
                imagePath: Self.representativeImagePath(for: message),
                accountInfo: accountInfo,
                rawMessageType: message.messageType,
                summary: message.analysis?.bodySummary,
                hasListID: message.listId?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false,
                isDirectToUser: isDirectToUser
            )
        }
        return enrichments
    }

    /// First card-sized `image/*` attachment with an on-disk path. Tiny inline
    /// affordances such as PDF icons are not editorial artwork; skip them and
    /// keep looking so the card is text-only unless a later eligible image is
    /// available.
    nonisolated private static func representativeImagePath(for message: Message) -> String? {
        for attachment in message.attachments {
            guard attachment.mimeType.lowercased().hasPrefix("image/"),
                  let path = attachment.filePath,
                  path.isEmpty == false else { continue }
            if let dimensions = imagePixelDimensions(at: path),
               dimensions.width < 64 || dimensions.height < 64 {
                continue
            }
            return path
        }
        return nil
    }

    /// Reads source metadata without decoding the bitmap. Unknown/vector image
    /// geometry preserves the existing behavior and remains eligible.
    nonisolated private static func imagePixelDimensions(at path: String) -> (width: Int, height: Int)? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            options as CFDictionary
        ),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    nonisolated private static func attentionInput(
        for message: Message,
        date: Date,
        triageVerdict: TriageVerdict?
    ) -> MessageAttentionInput {
        MessageAttentionInput(
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

    nonisolated static func accountInfo(
        for message: Message,
        accountsByID: [UUID: AccountInfo]
    ) -> AccountInfo {
        if let accountID = message.accountID,
           let info = accountsByID[accountID] {
            return info
        }
        if let account = message.account {
            return AccountInfo(
                displayName: account.displayName,
                emailAddress: account.emailAddress,
                colorIndex: account.colorIndex ?? AccountColorPalette.defaultIndex,
                ownedEmailAddresses: account.ownedEmailAddresses
            )
        }
        return AccountInfo(
            displayName: "Unknown account",
            emailAddress: "",
            colorIndex: AccountColorPalette.defaultIndex,
            ownedEmailAddresses: []
        )
    }

    nonisolated static func article(
        enrichment: ArticleEnrichment,
        bodyPreview: String?,
        attention: MessageAttentionState,
        isReplied: Bool,
        isConfirmed: Bool,
        isResolved: Bool,
        isRevivedAfterInactiveGap: Bool,
        sharedEvidenceKinds: Set<MessageSharedEvidenceKind>
    ) -> FrontPageArticle {
        let trimmedSubject = enrichment.baseFilterRow.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = trimmedSubject.isEmpty ? "(no subject)" : trimmedSubject
        let byline = Self.byline(
            isSentByUser: enrichment.baseFilterRow.isSentByUser,
            fromName: enrichment.baseFilterRow.fromName,
            fromAddress: enrichment.baseFilterRow.fromAddress
        )
        return FrontPageArticle(
            id: enrichment.id,
            messageIdString: enrichment.id.uuidString,
            headline: headline,
            byline: byline,
            senderAddress: enrichment.baseFilterRow.fromAddress,
            accountDisplayName: enrichment.accountInfo.displayName,
            accountEmailAddress: enrichment.accountInfo.emailAddress,
            accountColorIndex: enrichment.accountInfo.colorIndex,
            date: enrichment.date,
            readAt: enrichment.readAt,
            summary: SummaryTextSanitizer.cleaned(enrichment.summary),
            bodyPreview: bodyPreview,
            classification: enrichment.classification,
            customCategoryKeys: enrichment.customCategoryKeys,
            isListIgnoreEligible: MailingListIgnoreRuleService.isEligibleList(
                hasListID: enrichment.hasListID,
                purpose: enrichment.classification?.purpose
            ),
            isMailingList: enrichment.hasListID,
            isDirectToUser: enrichment.isDirectToUser,
            isSentByUser: enrichment.baseFilterRow.isSentByUser,
            isUnread: !enrichment.baseFilterRow.isRead,
            isActionable: attention.needsReply,
            isInComposerQueue: enrichment.isInComposerQueue,
            requiresConfirmation: attention.needsConfirmation,
            isReplied: isReplied,
            isConfirmed: isConfirmed,
            isResolved: isResolved,
            hasDeadline: enrichment.hasDeadline,
            deadlineText: enrichment.deadlineText,
            isFlagged: enrichment.baseFilterRow.flagged,
            isRevivedAfterInactiveGap: isRevivedAfterInactiveGap,
            sharedEvidenceKinds: sharedEvidenceKinds,
            hasAttachments: enrichment.baseFilterRow.hasAttachments,
            imagePath: enrichment.imagePath,
            bodyHtmlPath: enrichment.baseFilterRow.bodyHtmlPath,
            bodyTextPath: enrichment.baseFilterRow.bodyTextPath,
            rawPath: enrichment.rawPath
        )
    }

    nonisolated private static func isReplied(
        messageID: UUID,
        repliedAt: Date?,
        attention: MessageAttentionState,
        actionState: ProjectLensUserActionState
    ) -> Bool {
        if actionState.repliedMessageIDs.contains(messageID) {
            return true
        }
        if actionState.replyNeededMessageIDs.contains(messageID) {
            return false
        }
        return repliedAt != nil || attention.clearsByMessageID != nil
    }

    nonisolated private static func byline(isSentByUser: Bool, fromName: String?, fromAddress: String) -> String {
        if isSentByUser { return "You" }
        if let fromName, fromName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return fromName
        }
        return fromAddress.isEmpty ? "Unknown sender" : fromAddress
    }

    /// Removes reader-only paths and summary text from pass one while retaining
    /// every field used by canonical filtering and duplicate selection.
    nonisolated private static func candidateFilterRow(from base: MessageFilterRow) -> MessageFilterRow {
        MessageFilterRow(
            accountId: base.accountId,
            threadId: base.threadId,
            messageType: base.messageType,
            embeddingStatus: base.embeddingStatus,
            isRead: base.isRead,
            isReplied: base.isReplied,
            isConfirmed: base.isConfirmed,
            isResolved: base.isResolved,
            isSentByUser: base.isSentByUser,
            flagged: base.flagged,
            hasAttachments: base.hasAttachments,
            fromAddress: base.fromAddress,
            fromName: base.fromName,
            toAddresses: base.toAddresses,
            toNames: base.toNames,
            toDisplayNames: base.toDisplayNames,
            ccAddresses: base.ccAddresses,
            ccNames: base.ccNames,
            ccDisplayNames: base.ccDisplayNames,
            bccAddresses: base.bccAddresses,
            bccNames: base.bccNames,
            bccDisplayNames: base.bccDisplayNames,
            recipientAddresses: base.recipientAddresses,
            clusterId: base.clusterId,
            dimensions: base.dimensions,
            subject: base.subject,
            receivedAt: base.receivedAt,
            ingestedAt: base.ingestedAt,
            liveDetectedAt: base.liveDetectedAt,
            bodyTextPath: nil,
            bodyHtmlPath: nil,
            bodySummary: nil,
            bodySummaryInputFingerprint: nil,
            mailClassificationJSON: base.mailClassificationJSON,
            customCategoryKeys: base.customCategoryKeys,
            vectorBreakdown: base.vectorBreakdown,
            neighborCount: base.neighborCount,
            isActionable: base.isActionable,
            requiresConfirmation: base.requiresConfirmation,
            listId: base.listId
        )
    }

    /// Reprojects the value-only pre-await row with resolved attention state.
    /// This intentionally takes no SwiftData model: callers use it only after
    /// background project computation has yielded the main actor.
    nonisolated private static func messageFilterRow(
        from base: MessageFilterRow,
        isActionable: Bool,
        requiresConfirmation: Bool,
        isReplied: Bool,
        isConfirmed: Bool,
        isResolved: Bool
    ) -> MessageFilterRow {
        MessageFilterRow(
            accountId: base.accountId,
            threadId: base.threadId,
            messageType: base.messageType,
            embeddingStatus: base.embeddingStatus,
            isRead: base.isRead,
            isReplied: isReplied,
            isConfirmed: isConfirmed,
            isResolved: isResolved,
            isSentByUser: base.isSentByUser,
            flagged: base.flagged,
            hasAttachments: base.hasAttachments,
            fromAddress: base.fromAddress,
            fromName: base.fromName,
            toAddresses: base.toAddresses,
            toNames: base.toNames,
            toDisplayNames: base.toDisplayNames,
            ccAddresses: base.ccAddresses,
            ccNames: base.ccNames,
            ccDisplayNames: base.ccDisplayNames,
            bccAddresses: base.bccAddresses,
            bccNames: base.bccNames,
            bccDisplayNames: base.bccDisplayNames,
            recipientAddresses: base.recipientAddresses,
            clusterId: base.clusterId,
            dimensions: base.dimensions,
            subject: base.subject,
            receivedAt: base.receivedAt,
            ingestedAt: base.ingestedAt,
            liveDetectedAt: base.liveDetectedAt,
            bodyTextPath: base.bodyTextPath,
            bodyHtmlPath: base.bodyHtmlPath,
            bodySummary: base.bodySummary,
            bodySummaryInputFingerprint: base.bodySummaryInputFingerprint,
            mailClassificationJSON: base.mailClassificationJSON,
            customCategoryKeys: base.customCategoryKeys,
            vectorBreakdown: base.vectorBreakdown,
            neighborCount: base.neighborCount,
            isActionable: isActionable,
            requiresConfirmation: requiresConfirmation,
            listId: base.listId
        )
    }

    nonisolated private static func messageFilterRow(
        for message: Message,
        date: Date,
        classificationJSON: String?,
        customCategoryKeys: Set<String> = [],
        dimensions: MessageDimensions?,
        triageVerdict: TriageVerdict?,
        isActionable: Bool? = nil,
        requiresConfirmation: Bool? = nil,
        isReplied: Bool? = nil,
        isConfirmed: Bool? = nil
    ) -> MessageFilterRow {
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
            guard !email.isEmpty else { continue }
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
            isSentByUser: message.isSentByUser,
            flagged: message.flaggedOrFalse,
            hasAttachments: message.hasAttachments,
            fromAddress: message.fromAddress,
            fromName: message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords),
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
            dimensions: dimensions,
            subject: MIMEHeaderDecoder.decodeEncodedWords(message.subject),
            receivedAt: date,
            ingestedAt: message.ingestedAt,
            liveDetectedAt: message.liveDetectedAt,
            bodyTextPath: message.bodyTextPath,
            bodyHtmlPath: message.bodyHtmlPath,
            bodySummary: message.analysis?.bodySummary,
            bodySummaryInputFingerprint: message.analysis?.bodySummaryInputFingerprint,
            mailClassificationJSON: classificationJSON,
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
            ),
            listId: message.listId
        )
    }

    nonisolated private static func messageType(for message: Message) -> MessageType {
        guard !message.isLiveInboundTriageEligible,
              !message.isSentByUser,
              message.messageType == .actionable || message.messageType == .confirmation else {
            return message.messageType
        }
        return .report
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
        decoder: JSONDecoder,
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
}

/// The reader's stored-thread lookup result. `hasStoredThread` distinguishes a
/// known single-message thread from missing thread metadata, which controls
/// whether the reader may fall back to in-body quote extraction.
struct FrontPageThreadContext: Sendable, Equatable {
    let hasStoredThread: Bool
    let messages: [FrontPageThreadMessage]
    let recipientHeader: FrontPageRecipientHeader

    nonisolated static let absent = FrontPageThreadContext(
        hasStoredThread: false,
        messages: [],
        recipientHeader: .empty
    )
}

/// All store-backed metadata needed before the focused reader resolves its
/// body. Keeping this as a value type lets the thread graph cross back from its
/// private SwiftData context without leaking models across actors.
struct FrontPageReaderPayload: Sendable, Equatable {
    let threadContext: FrontPageThreadContext
    let attachments: [LockedAttachmentSummary]

    nonisolated static let empty = FrontPageReaderPayload(
        threadContext: .absent,
        attachments: []
    )
}

/// Ordered, display-ready recipient metadata for the focused Front Page
/// masthead. Empty roles are omitted instead of displaying placeholder text.
struct FrontPageRecipientHeader: Sendable, Equatable {
    enum Role: String, CaseIterable, Sendable {
        case to
        case cc
        case bcc

        var label: String {
            switch self {
            case .to: return "To"
            case .cc: return "Cc"
            case .bcc: return "Bcc"
            }
        }

        nonisolated fileprivate var participantRole: ParticipantRole {
            switch self {
            case .to: return .to
            case .cc: return .cc
            case .bcc: return .bcc
            }
        }
    }

    struct Line: Identifiable, Sendable, Equatable {
        let role: Role
        let recipients: [String]

        var id: Role { role }
        var plainText: String {
            "\(role.label): \(recipients.joined(separator: ", "))"
        }
    }

    let lines: [Line]

    static let empty = FrontPageRecipientHeader(lines: [])
}

/// One message in the focused article's conversation, reduced to the metadata
/// the reader's reply-tree needs plus the on-disk body paths (the bodies are
/// loaded and quote-stripped off-main by the reader). `Sendable` so it can be
/// handed from the `@MainActor` data controller into the reader's async load.
struct FrontPageThreadMessage: Sendable, Identifiable, Equatable {
    let id: UUID
    let messageIDHeader: String?
    let inReplyTo: String?
    let references: [String]
    /// Display author resolved at fetch time ("You" for the user's own sent
    /// mail, else the decoded From name, else the address).
    let author: String
    let isSentByUser: Bool
    let date: Date?
    let bodyHtmlPath: String?
    let bodyTextPath: String?
    let rawPath: String?
}
