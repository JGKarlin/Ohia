import Foundation
import SwiftData
import Observation
import OhiaCore
import OhiaMail
import OhiaML

// Projects is a SwiftUI/Canvas workspace. The normal Metal scene should not mount for `.projects`.

struct ManualProjectsGatheredInput: Sendable {
    let projectRows: [ManualProjectRowInput]
    let allMemberInputs: [ProjectMessageInput]
    let filteredMessageRows: [String: MessageFilterRow]
    let sharedMessageActions: ProjectLensSharedMessageActionState
    let userAddresses: Set<String>
    let projectRevisionFingerprint: String
    let membershipRevisionFingerprint: String
    let projectMessageSourceFingerprint: String
    let sharedMessageActionFingerprint: String
    let fetchMetrics: ProjectsDataFetchMetrics
}

struct DeadlinesGatheredInput: Sendable {
    let observations: [DeadlineObservation]
    let inputFingerprint: String
    let fetchMetrics: ProjectsDataFetchMetrics
}

enum ProjectsDataGatherLane: Sendable, Equatable {
    case projects
    case deadlines
}

struct ProjectsDataFetchMetrics: Sendable, Equatable {
    var mailProjectFetchCount = 0
    var membershipFetchCount = 0
    var fullMessageTableFetchCount = 0
    var targetedMemberMessageFetchCount = 0
    var targetedMessageIDCount = 0
    var fetchedMessageCount = 0
}

@Observable @MainActor
final class ProjectsDataController {
    private struct ProjectsPublication {
        let sourceEpoch: UInt64
        let rowsSnapshot: ProjectRowsSnapshot
        let projectDefinitionRowsSnapshot: ProjectRowsSnapshot
        let messageFilterRows: [String: MessageFilterRow]
        let userAddresses: Set<String>
        let filteredMessageProjectionFingerprint: String
        let projectRevisionFingerprint: String
        let membershipRevisionFingerprint: String
        let projectMessageSourceFingerprint: String
        let userAddressesFingerprint: String
        let sharedMessageActionFingerprint: String
    }

    private struct DeadlinesPublication {
        let sourceEpoch: UInt64
        let observations: [DeadlineObservation]
        let inputFingerprint: String
    }

    private weak var workspaceState: ProjectsWorkspaceState?
    private var modelContext: ModelContext?
    private var vectorStore: VectorStore?
    private var projectsRefreshTask: Task<Void, Never>?
    private var deadlinesRefreshTask: Task<Void, Never>?
    /// Pending hold set by `invalidateAndRefresh(holdingFor:)`: a departing
    /// (delete / resolve) card's Collapse must finish playing before the rebuild
    /// drops or re-renders it, exactly as Front Page holds its grid.
    private var departingHoldTask: Task<Void, Never>?
    /// True from the moment a refresh is requested until that request's
    /// recompute finishes. The previous snapshot deliberately stays mounted
    /// through the window, so callers that must conclude something from a
    /// message's *absence* in the snapshot (e.g. the beacon's "belongs to
    /// no project" verdict) treat an in-flight refresh as not yet
    /// trustworthy. Generation-guarded: only the newest request's
    /// completion clears it.
    private var projectsRefreshInFlight = false
    private var deadlinesRefreshInFlight = false
    private var projectsRefreshGeneration: UInt64 = 0
    private var deadlinesRefreshGeneration: UInt64 = 0
    private var projectsSourceEpoch: UInt64 = 0
    private var deadlinesSourceEpoch: UInt64 = 0
    /// A lane can finish while the other tab is mounted and still be missing
    /// the other lane's exact-filter payload. Keep that work private until it
    /// can be merged without publishing an empty or mislabeled active tab.
    private var pendingProjectsByFilter: [String: ProjectsPublication] = [:]
    private var pendingDeadlinesByFilter: [String: DeadlinesPublication] = [:]
    private var pendingProjectFilterOrder: [String] = []
    private var pendingDeadlineFilterOrder: [String] = []
    private var lastRefreshFilter: VectorFilter?
    private var snapshotsBySignature: [ProjectsSnapshotSignature: ProjectsSnapshot] = [:]
    private var snapshotSignatureOrder: [ProjectsSnapshotSignature] = []
    private var latestSignature: ProjectsSnapshotSignature?
    @ObservationIgnored private let onGatherStarted: (@MainActor (ProjectsDataGatherLane) async -> Void)?
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let subscribesToLiveRefresh: Bool

    /// Cap on cached snapshots. Keeps memory bounded for long sessions with
    /// frequent filter or action-revision changes; oldest entries are evicted.
    private static let snapshotCacheLimit = 4
    private static let unavailableFingerprint = "not-loaded"

    /// A pending departing hold counts as in-flight: the hold defers a full
    /// invalidate-and-regather to the motion floor while the stale snapshot
    /// stays mounted, so any caller that must conclude something from a
    /// message's *absence* in the snapshot (the beacon's "belongs to no
    /// project" verdict, `hasTrustworthySnapshot`) must keep treating the
    /// window as not yet trustworthy — especially after the hold supersedes
    /// a live gather and clears the lane flags.
    var hasRefreshInFlight: Bool {
        projectsRefreshInFlight || deadlinesRefreshInFlight || departingHoldTask != nil
    }

    var hasProjectsRefreshInFlight: Bool {
        projectsRefreshInFlight || departingHoldTask != nil
    }

    @ObservationIgnored nonisolated(unsafe) private var deletionObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var ingestObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var messageAttentionObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var arrivalVisibilityObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var membershipObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var customCategoryObserver: NSObjectProtocol?

    deinit {
        if let deletionObserver { notificationCenter.removeObserver(deletionObserver) }
        if let ingestObserver { notificationCenter.removeObserver(ingestObserver) }
        if let messageAttentionObserver { notificationCenter.removeObserver(messageAttentionObserver) }
        if let arrivalVisibilityObserver { notificationCenter.removeObserver(arrivalVisibilityObserver) }
        if let membershipObserver { notificationCenter.removeObserver(membershipObserver) }
        if let customCategoryObserver { notificationCenter.removeObserver(customCategoryObserver) }
    }

    init(
        onGatherStarted: (@MainActor (ProjectsDataGatherLane) async -> Void)? = nil,
        notificationCenter: NotificationCenter = .default,
        subscribesToLiveRefresh: Bool = true
    ) {
        self.onGatherStarted = onGatherStarted
        self.notificationCenter = notificationCenter
        self.subscribesToLiveRefresh = subscribesToLiveRefresh
    }

    func bind(
        workspace: ProjectsWorkspaceState,
        modelContext: ModelContext,
        vectorStore: VectorStore
    ) {
        self.workspaceState = workspace
        self.modelContext = modelContext
        self.vectorStore = vectorStore
        if subscribesToLiveRefresh, deletionObserver == nil { subscribeToLiveRefresh() }
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
        if let messageAttentionObserver {
            notificationCenter.removeObserver(messageAttentionObserver)
            self.messageAttentionObserver = nil
        }
        if let arrivalVisibilityObserver {
            notificationCenter.removeObserver(arrivalVisibilityObserver)
            self.arrivalVisibilityObserver = nil
        }
        if let membershipObserver {
            notificationCenter.removeObserver(membershipObserver)
            self.membershipObserver = nil
        }
        if let customCategoryObserver {
            notificationCenter.removeObserver(customCategoryObserver)
            self.customCategoryObserver = nil
        }
        projectsRefreshTask?.cancel()
        projectsRefreshTask = nil
        deadlinesRefreshTask?.cancel()
        deadlinesRefreshTask = nil
        projectsRefreshInFlight = false
        deadlinesRefreshInFlight = false
        departingHoldTask?.cancel()
        departingHoldTask = nil
        workspaceState = nil
        modelContext = nil
        vectorStore = nil
        lastRefreshFilter = nil
        pendingProjectsByFilter.removeAll()
        pendingDeadlinesByFilter.removeAll()
        pendingProjectFilterOrder.removeAll()
        pendingDeadlineFilterOrder.removeAll()
    }

    func requestRefresh(filter: VectorFilter) {
        guard let workspace = workspaceState,
              let modelContext,
              let vectorStore else { return }
        lastRefreshFilter = filter
        let accountScopeKey = Self.accountScopeKey(for: filter)
        workspace.accountScopeKey = accountScopeKey
        switch workspace.lensTab {
        case .projects:
            requestProjectsRefresh(filter: filter, modelContext: modelContext)
        case .deadlines:
            requestDeadlinesRefresh(
                filter: filter,
                accountScopeKey: accountScopeKey,
                modelContext: modelContext,
                vectorStore: vectorStore
            )
        }
    }

    private func requestProjectsRefresh(filter: VectorFilter, modelContext: ModelContext) {
        projectsRefreshGeneration &+= 1
        let generation = projectsRefreshGeneration
        let requestedSourceEpoch = projectsSourceEpoch
        projectsRefreshInFlight = true
        projectsRefreshTask?.cancel()
        projectsRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.projectsRefreshGeneration {
                    self.projectsRefreshInFlight = false
                    self.projectsRefreshTask = nil
                }
            }
            if let onGatherStarted { await onGatherStarted(.projects) }
            if Task.isCancelled { return }
            try? modelContext.save()
            let arrivals = NewMailArrivalLedger.shared.gatherSnapshot()
            let container = modelContext.container
            let gathered = await Task.detached(priority: .userInitiated) {
                Self.gatherManualProjects(container: container, filter: filter, arrivals: arrivals)
            }.value
            if Task.isCancelled { return }
            await self.publishProjects(
                gathered,
                filter: filter,
                generation: generation,
                sourceEpoch: requestedSourceEpoch
            )
        }
    }

    private func requestDeadlinesRefresh(
        filter: VectorFilter,
        accountScopeKey: String,
        modelContext: ModelContext,
        vectorStore: VectorStore
    ) {
        deadlinesRefreshGeneration &+= 1
        let generation = deadlinesRefreshGeneration
        let requestedSourceEpoch = deadlinesSourceEpoch
        deadlinesRefreshInFlight = true
        deadlinesRefreshTask?.cancel()
        deadlinesRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.deadlinesRefreshGeneration {
                    self.deadlinesRefreshInFlight = false
                    self.deadlinesRefreshTask = nil
                }
            }
            if let onGatherStarted { await onGatherStarted(.deadlines) }
            if Task.isCancelled { return }
            try? modelContext.save()
            let arrivals = NewMailArrivalLedger.shared.gatherSnapshot()
            let container = modelContext.container
            let gathered = await Task.detached(priority: .userInitiated) {
                Self.gatherDeadlines(
                    container: container,
                    vectorStore: vectorStore,
                    filter: filter,
                    accountScopeKey: accountScopeKey,
                    arrivals: arrivals
                )
            }.value
            if Task.isCancelled { return }
            self.publishDeadlines(
                gathered,
                filter: filter,
                generation: generation,
                sourceEpoch: requestedSourceEpoch
            )
        }
    }

    private func publishProjects(
        _ gathered: ManualProjectsGatheredInput,
        filter: VectorFilter,
        generation: UInt64,
        sourceEpoch requestedSourceEpoch: UInt64
    ) async {
        guard generation == projectsRefreshGeneration,
              requestedSourceEpoch == projectsSourceEpoch,
              !Task.isCancelled else { return }
        let filterFingerprint = Self.filterFingerprint(filter)
        let computed = await Task.detached(priority: .userInitiated) {
            let definitions = ProjectRowComputation.snapshot(
                projects: gathered.projectRows,
                messages: gathered.allMemberInputs,
                sharedMessageActions: gathered.sharedMessageActions,
                configuration: ProjectRowComputationConfiguration(now: Date.now)
            )
            return (
                ProjectRowComputation.projectedSnapshot(
                    from: definitions,
                    matchingMessageIDs: Set(gathered.filteredMessageRows.keys.compactMap(UUID.init(uuidString:)))
                ),
                definitions
            )
        }.value
        guard generation == projectsRefreshGeneration,
              requestedSourceEpoch == projectsSourceEpoch,
              !Task.isCancelled else { return }
        let projects = ProjectsPublication(
            sourceEpoch: requestedSourceEpoch,
            rowsSnapshot: computed.0,
            projectDefinitionRowsSnapshot: computed.1,
            messageFilterRows: gathered.filteredMessageRows,
            userAddresses: gathered.userAddresses,
            filteredMessageProjectionFingerprint: Self.fingerprint(parts: gathered.filteredMessageRows.keys.sorted()),
            projectRevisionFingerprint: gathered.projectRevisionFingerprint,
            membershipRevisionFingerprint: gathered.membershipRevisionFingerprint,
            projectMessageSourceFingerprint: gathered.projectMessageSourceFingerprint,
            userAddressesFingerprint: Self.fingerprint(parts: gathered.userAddresses.sorted()),
            sharedMessageActionFingerprint: gathered.sharedMessageActionFingerprint
        )
        storePendingProjects(projects, for: filterFingerprint)

        if let deadlines = pendingDeadlinesByFilter[filterFingerprint],
           deadlines.sourceEpoch == deadlinesSourceEpoch {
            removePendingDeadlines(for: filterFingerprint)
            removePendingProjects(for: filterFingerprint)
            publishSnapshot(projects: projects, deadlines: deadlines, filterFingerprint: filterFingerprint)
            return
        }
        if let current = workspaceState?.currentSnapshot,
           current.signature.deadlinesSourceEpoch == deadlinesSourceEpoch,
           current.signature.deadlineDisplayFilterFingerprint == filterFingerprint {
            removePendingProjects(for: filterFingerprint)
            publishSnapshot(
                projects: projects,
                deadlines: DeadlinesPublication(
                    sourceEpoch: deadlinesSourceEpoch,
                    observations: current.deadlineObservations,
                    inputFingerprint: current.signature.deadlineInputFingerprint
                ),
                filterFingerprint: filterFingerprint
            )
            return
        }

        // A Projects-only result must not replace an initial or filter-changing
        // Deadline load with an empty/new-filter Deadline payload. The pending
        // result is merged when that exact-filter Deadline lane completes.
        guard workspaceState?.lensTab != .deadlines else { return }
        removePendingProjects(for: filterFingerprint)
        publishSnapshot(projects: projects, deadlines: nil, filterFingerprint: filterFingerprint)
    }

    private func publishDeadlines(
        _ gathered: DeadlinesGatheredInput,
        filter: VectorFilter,
        generation: UInt64,
        sourceEpoch requestedSourceEpoch: UInt64
    ) {
        guard generation == deadlinesRefreshGeneration,
              requestedSourceEpoch == deadlinesSourceEpoch,
              !Task.isCancelled else { return }
        let filterFingerprint = Self.filterFingerprint(filter)
        let deadlines = DeadlinesPublication(
            sourceEpoch: requestedSourceEpoch,
            observations: gathered.observations,
            inputFingerprint: gathered.inputFingerprint
        )
        storePendingDeadlines(deadlines, for: filterFingerprint)

        if let projects = pendingProjectsByFilter[filterFingerprint],
           projects.sourceEpoch == projectsSourceEpoch {
            removePendingProjects(for: filterFingerprint)
            removePendingDeadlines(for: filterFingerprint)
            publishSnapshot(projects: projects, deadlines: deadlines, filterFingerprint: filterFingerprint)
            return
        }
        if let current = workspaceState?.currentSnapshot,
           current.signature.projectsSourceEpoch == projectsSourceEpoch,
           current.signature.displayFilterFingerprint == filterFingerprint {
            removePendingDeadlines(for: filterFingerprint)
            publishSnapshot(
                projects: ProjectsPublication(
                    sourceEpoch: projectsSourceEpoch,
                    rowsSnapshot: current.rowsSnapshot,
                    projectDefinitionRowsSnapshot: current.projectDefinitionRowsSnapshot ?? current.rowsSnapshot,
                    messageFilterRows: current.messageFilterRows,
                    userAddresses: current.userAddresses,
                    filteredMessageProjectionFingerprint: current.signature.filteredMessageProjectionFingerprint,
                    projectRevisionFingerprint: current.signature.projectRevisionFingerprint,
                    membershipRevisionFingerprint: current.signature.membershipRevisionFingerprint,
                    projectMessageSourceFingerprint: current.signature.projectMessageSourceFingerprint,
                    userAddressesFingerprint: current.signature.userAddressesFingerprint,
                    sharedMessageActionFingerprint: current.signature.sharedMessageActionFingerprint
                ),
                deadlines: deadlines,
                filterFingerprint: filterFingerprint
            )
            return
        }

        // Symmetrically, never replace a mounted Projects tab with unavailable
        // Projects data. Retain the Deadline lane privately until Projects is
        // available, or publish it immediately when Deadlines is the active tab.
        guard workspaceState?.lensTab != .projects else { return }
        removePendingDeadlines(for: filterFingerprint)
        publishSnapshot(projects: nil, deadlines: deadlines, filterFingerprint: filterFingerprint)
    }

    private func publishSnapshot(
        projects: ProjectsPublication?,
        deadlines: DeadlinesPublication?,
        filterFingerprint: String
    ) {
        guard projects?.sourceEpoch == nil || projects?.sourceEpoch == projectsSourceEpoch,
              deadlines?.sourceEpoch == nil || deadlines?.sourceEpoch == deadlinesSourceEpoch else { return }
        let empty = Self.emptyRowsSnapshot()
        let signature = ProjectsSnapshotSignature(
            projectsSourceEpoch: projects?.sourceEpoch ?? projectsSourceEpoch,
            deadlinesSourceEpoch: deadlines?.sourceEpoch ?? deadlinesSourceEpoch,
            displayFilterFingerprint: projects == nil ? Self.unavailableFingerprint : filterFingerprint,
            deadlineDisplayFilterFingerprint: deadlines == nil ? Self.unavailableFingerprint : filterFingerprint,
            filteredMessageProjectionFingerprint: projects?.filteredMessageProjectionFingerprint ?? Self.unavailableFingerprint,
            projectRevisionFingerprint: projects?.projectRevisionFingerprint ?? Self.unavailableFingerprint,
            membershipRevisionFingerprint: projects?.membershipRevisionFingerprint ?? Self.unavailableFingerprint,
            projectMessageSourceFingerprint: projects?.projectMessageSourceFingerprint ?? Self.unavailableFingerprint,
            userAddressesFingerprint: projects?.userAddressesFingerprint ?? Self.unavailableFingerprint,
            sharedMessageActionFingerprint: projects?.sharedMessageActionFingerprint ?? Self.unavailableFingerprint,
            deadlineInputFingerprint: deadlines?.inputFingerprint ?? Self.unavailableFingerprint
        )
        if let cached = snapshotsBySignature[signature], Date.now.timeIntervalSince(cached.builtAt) <= 60 {
            workspaceState?.currentSnapshot = cached
            touchSignature(signature)
            return
        }
        let snapshot = ProjectsSnapshot(
            signature: signature,
            builtAt: Date.now,
            rowsSnapshot: projects?.rowsSnapshot ?? empty,
            projectDefinitionRowsSnapshot: projects?.projectDefinitionRowsSnapshot ?? empty,
            messageFilterRows: projects?.messageFilterRows ?? [:],
            userAddresses: projects?.userAddresses ?? [],
            deadlineObservations: deadlines?.observations ?? []
        )
        storeSnapshot(snapshot, for: signature)
        workspaceState?.currentSnapshot = snapshot
    }

    private static func emptyRowsSnapshot() -> ProjectRowsSnapshot {
        ProjectRowsSnapshot(
            builtAt: Date.now,
            rows: [],
            links: [],
            messageLookup: [:],
            membershipByMessageID: [:],
            dateRange: nil
        )
    }

    private func storeSnapshot(_ snapshot: ProjectsSnapshot, for signature: ProjectsSnapshotSignature) {
        snapshotsBySignature[signature] = snapshot
        touchSignature(signature)
        latestSignature = signature
        while snapshotSignatureOrder.count > Self.snapshotCacheLimit {
            let oldest = snapshotSignatureOrder.removeFirst()
            snapshotsBySignature.removeValue(forKey: oldest)
        }
    }

    private func touchSignature(_ signature: ProjectsSnapshotSignature) {
        snapshotSignatureOrder.removeAll { $0 == signature }
        snapshotSignatureOrder.append(signature)
    }

    private func storePendingProjects(_ publication: ProjectsPublication, for filter: String) {
        pendingProjectsByFilter[filter] = publication
        pendingProjectFilterOrder.removeAll { $0 == filter }
        pendingProjectFilterOrder.append(filter)
        while pendingProjectFilterOrder.count > Self.snapshotCacheLimit {
            removePendingProjects(for: pendingProjectFilterOrder[0])
        }
    }

    private func storePendingDeadlines(_ publication: DeadlinesPublication, for filter: String) {
        pendingDeadlinesByFilter[filter] = publication
        pendingDeadlineFilterOrder.removeAll { $0 == filter }
        pendingDeadlineFilterOrder.append(filter)
        while pendingDeadlineFilterOrder.count > Self.snapshotCacheLimit {
            removePendingDeadlines(for: pendingDeadlineFilterOrder[0])
        }
    }

    private func removePendingProjects(for filter: String) {
        pendingProjectsByFilter.removeValue(forKey: filter)
        pendingProjectFilterOrder.removeAll { $0 == filter }
    }

    private func removePendingDeadlines(for filter: String) {
        pendingDeadlinesByFilter.removeValue(forKey: filter)
        pendingDeadlineFilterOrder.removeAll { $0 == filter }
    }

    func invalidateAndRefresh() {
        // While a departing card's Collapse is being held (see
        // `invalidateAndRefresh(holdingFor:)`), coalesce any competing live
        // refresh into that pending hold so the card is not yanked out from
        // under its motion; the hold task rebuilds with the latest data at the
        // motion floor.
        guard departingHoldTask == nil else { return }
        invalidateCacheForNextRequest()
        guard let lastRefreshFilter else { return }
        requestRefresh(filter: lastRefreshFilter)
    }

    /// Invalidates reusable project snapshots without launching an inactive
    /// workspace refresh. The retained snapshot stays displayable until the
    /// next bound request replaces it.
    func invalidateCacheForNextRequest() {
        projectsSourceEpoch &+= 1
        deadlinesSourceEpoch &+= 1
        snapshotsBySignature.removeAll()
        snapshotSignatureOrder.removeAll()
        latestSignature = nil
        pendingProjectsByFilter.removeAll()
        pendingDeadlinesByFilter.removeAll()
        pendingProjectFilterOrder.removeAll()
        pendingDeadlineFilterOrder.removeAll()
    }

    /// Invalidate and refresh, but hold for `delay` seconds first so a departing
    /// (delete / resolve) card's Collapse finishes playing before the rebuild
    /// drops it. A local resolve writes and rebuilds almost instantly, which
    /// would otherwise yank the card out from under the green Collapse the way a
    /// slow IMAP delete never does. A non-positive `delay` refreshes immediately,
    /// and a fresh hold supersedes any pending one. Mirrors the Front Page hold.
    func invalidateAndRefresh(holdingFor delay: Double) {
        departingHoldTask?.cancel()
        departingHoldTask = nil
        guard delay > 0 else {
            invalidateAndRefresh()
            return
        }
        // The hold guard in `invalidateAndRefresh()` only coalesces refreshes
        // requested AFTER the hold begins. A gather already in flight right now
        // can read the freshly written action state and publish a snapshot that
        // drops the departing card mid-motion. Supersede each lane with a live
        // task: bump its generation so a late publish fails its guard even if
        // cancellation lands after the gather, and let the hold's rebuild
        // regather at the motion floor. The lane flags must be cleared here
        // (the bumped generation stops the cancelled task's defer from doing
        // it), while `hasRefreshInFlight` stays true through the hold itself.
        // Mirrors the Front Page hold.
        if projectsRefreshTask != nil {
            projectsRefreshGeneration &+= 1
            projectsRefreshTask?.cancel()
            projectsRefreshTask = nil
            projectsRefreshInFlight = false
        }
        if deadlinesRefreshTask != nil {
            deadlinesRefreshGeneration &+= 1
            deadlinesRefreshTask?.cancel()
            deadlinesRefreshTask = nil
            deadlinesRefreshInFlight = false
        }
        departingHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.departingHoldTask = nil
            self?.invalidateAndRefresh()
        }
    }

    /// Match a mounted snapshot against the live display filter. Project,
    /// membership, action, and Deadline revisions participate in cache identity
    /// but do not make the existing workspace disappear while refresh runs.
    static func signatureMatchesCurrentFilter(
        snapshot: ProjectsSnapshot,
        filter: VectorFilter
    ) -> Bool {
        snapshot.signature.displayFilterFingerprint == filterFingerprint(filter)
    }

    static func deadlineSignatureMatchesCurrentFilter(
        snapshot: ProjectsSnapshot?,
        filter: VectorFilter
    ) -> Bool {
        snapshot?.signature.deadlineDisplayFilterFingerprint == filterFingerprint(filter)
    }

    nonisolated static func accountScopeKey(for filter: VectorFilter) -> String {
        guard let accountIds = filter.accountIds, !accountIds.isEmpty else {
            return "all"
        }
        let sorted = accountIds.map(\.uuidString).sorted()
        if sorted.count == 1 {
            return "account:\(sorted[0])".lowercased()
        }
        return "accounts:\(sorted.joined(separator: ","))".lowercased()
    }

    static func filterFingerprint(_ filter: VectorFilter) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(filter),
              let encoded = String(data: data, encoding: .utf8) else {
            return String(describing: filter)
        }
        return encoded
    }

    private func subscribeToLiveRefresh() {
        let center = notificationCenter
        deletionObserver = center.addObserver(
            forName: .ohiaDeletionApplied,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateAndRefresh()
            }
        }
        ingestObserver = center.addObserver(
            forName: .ohiaIMAPNewInboundMessages,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateAndRefresh()
            }
        }
        messageAttentionObserver = center.addObserver(
            forName: .ohiaMessageAttentionChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateAndRefresh()
            }
        }
        arrivalVisibilityObserver = center.addObserver(
            forName: .ohiaNewMailArrivalVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateAndRefresh()
            }
        }
        membershipObserver = center.addObserver(
            forName: .ohiaManualProjectMembershipDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateProjectsAndRefresh()
            }
        }
        customCategoryObserver = center.addObserver(
            forName: .ohiaCustomCategoriesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateProjectsAndRefresh()
            }
        }
    }

    /// Project-only source notifications must never cause the Deadlines gather
    /// to fetch or observe manual-project state. The current Deadline payload
    /// remains mounted verbatim while the Projects half refreshes.
    private func invalidateProjectsAndRefresh() {
        guard departingHoldTask == nil else { return }
        projectsSourceEpoch &+= 1
        snapshotsBySignature.removeAll()
        snapshotSignatureOrder.removeAll()
        latestSignature = nil
        pendingProjectsByFilter.removeAll()
        pendingProjectFilterOrder.removeAll()
        guard let lastRefreshFilter else { return }
        guard let modelContext else { return }
        requestProjectsRefresh(filter: lastRefreshFilter, modelContext: modelContext)
    }

    private struct PreparedMessage {
        let message: Message
        let date: Date
        let triage: TriageVerdict?
        let dimensions: MessageDimensions?
        let projectInput: ProjectMessageInput?
        /// Deadlines read from the message's UNSCRUBBED dimensions. The Deadlines
        /// tracker treats a deadline as a fact about the message rather than
        /// transient triage action state, so it survives the historical-message
        /// scrub that `dimensions` (the Projects path) applies.
        let rawDeadlines: [DeadlineCandidate]
    }

    nonisolated static func gatherManualProjects(
        container: ModelContainer,
        filter: VectorFilter,
        arrivals: NewMailArrivalLedger.GatherSnapshot
    ) -> ManualProjectsGatheredInput {
        let modelContext = ModelContext(container)
        var fetchMetrics = ProjectsDataFetchMetrics()
        fetchMetrics.mailProjectFetchCount = 1
        let projects = ((try? modelContext.fetch(FetchDescriptor<MailProject>())) ?? [])
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let projectIDs = Set(projects.map(\.id))
        fetchMetrics.membershipFetchCount = 1
        let memberships = ((try? modelContext.fetch(FetchDescriptor<MailProjectMembership>())) ?? [])
            .filter { projectIDs.contains($0.projectID) }
            .sorted { lhs, rhs in
                if lhs.projectID != rhs.projectID {
                    return lhs.projectID.uuidString < rhs.projectID.uuidString
                }
                if lhs.messageID != rhs.messageID {
                    return lhs.messageID.uuidString < rhs.messageID.uuidString
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        let memberMessageIDs = Set(memberships.map(\.messageID))
        fetchMetrics.targetedMessageIDCount = memberMessageIDs.count
        let messages: [Message]
        if memberMessageIDs.isEmpty {
            messages = []
        } else {
            fetchMetrics.targetedMemberMessageFetchCount = 1
            let descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { memberMessageIDs.contains($0.id) }
            )
            messages = ((try? modelContext.fetch(descriptor)) ?? [])
                .filter { $0.isTrashed == false }
                .sorted(by: messageSort)
        }
        fetchMetrics.fetchedMessageCount = messages.count
        let triageDecoder = JSONDecoder()
        let dimensionsDecoder = JSONDecoder()
        let customCategoryCatalogKeys = CustomMailCategoryCatalog.allKeys(in: modelContext)
        let sharedActions = ProjectLensActionRepository(modelContext: modelContext)
            .sharedMessageActionState()
        var prepared: [PreparedMessage] = []
        for message in messages {
            guard let date = message.vectorTimeFilterDate else { continue }
            if message.isSentByUser == false,
               arrivals.isEmbargoed(messageID: message.id, liveDetectedAt: message.liveDetectedAt) {
                continue
            }
            let decodedTriage = decodeTriageVerdict(
                message.analysis?.triageVerdictJSON,
                decoder: triageDecoder,
                isSentByUser: message.isSentByUser
            )
            let triage = message.isLiveInboundTriageEligible ? decodedTriage : nil
            let rawDimensions = decodeDimensions(
                message.analysis?.dimensionsJSON,
                decoder: dimensionsDecoder,
                scrubTriageActionState: false
            )
            let dimensions = message.isLiveInboundTriageEligible
                ? rawDimensions
                : rawDimensions?.scrubbingTriageActionState()
            prepared.append(PreparedMessage(
                message: message,
                date: date,
                triage: triage,
                dimensions: dimensions,
                projectInput: ProjectMessageInputBuilder.projectInput(
                    for: message,
                    date: date,
                    dimensions: dimensions,
                    triageVerdict: triage
                ),
                rawDeadlines: rawDimensions?.deadlines ?? []
            ))
        }
        let inputs = prepared.compactMap(\.projectInput)
        let projectMessageSourceFingerprint = fingerprint(parts: [
            projectMessageFingerprint(prepared),
            fingerprint(parts: customCategoryCatalogKeys.sorted()),
        ])
        let attentionByMessageID = MessageAttentionResolver.states(
            messages: inputs.map(MessageAttentionInput.init(projectMessage:)),
            userActions: MessageAttentionUserActionState(projectActions: sharedActions)
        )
        var filteredRows: [String: MessageFilterRow] = [:]
        for value in prepared {
            let attention = attentionByMessageID[value.message.id]
                ?? MessageAttentionState(messageID: value.message.id, openKinds: [])
            let replied = isReplied(
                message: value.message,
                attention: attention,
                actionState: sharedActions
            )
            let row = messageFilterRow(
                for: value.message,
                date: value.date,
                customCategoryKeys: Set(CustomCategoryKeysJSON.decode(
                    value.message.analysis?.customCategoryKeysJSON
                )).intersection(customCategoryCatalogKeys),
                dimensions: value.dimensions,
                triageVerdict: value.triage,
                isActionable: attention.needsReply,
                requiresConfirmation: attention.needsConfirmation,
                isReplied: replied,
                isConfirmed: sharedActions.confirmedMessageIDs.contains(value.message.id),
                isResolved: sharedActions.resolvedMessageIDs.contains(value.message.id)
            )
            let dateMatches = filter.timeRange?.contains(value.date) ?? true
            if dateMatches, ConstellationMessageFilter.matches(row, filter: filter) {
                filteredRows[value.message.id.uuidString] = row
            }
        }

        let decoder = JSONDecoder()
        let membershipSnapshots = memberships.map { row -> MailProjectMembershipSnapshot in
            let conditionIDs = (try? row.matchingConditionIDs()) ?? []
            let provenance = row.provenanceJSON.data(using: .utf8).flatMap {
                try? decoder.decode(MailProjectMembershipProvenance.self, from: $0)
            } ?? MailProjectMembershipProvenance(
                rule: nil,
                decisionID: nil,
                decisionTargetKind: row.source == .messageOverride
                    ? .message
                    : (row.source == .threadOverride ? .thread : nil),
                isExceptionToAutomaticRules: row.source != .rule
            )
            return MailProjectMembershipSnapshot(
                id: row.id,
                projectID: row.projectID,
                messageID: row.messageID,
                configurationRevision: row.configurationRevision,
                source: row.source,
                matchingGroupID: row.matchingGroupID,
                matchingConditionIDs: conditionIDs,
                provenance: provenance,
                sourceFingerprint: row.sourceFingerprint,
                evaluatedAt: row.evaluatedAt
            )
        }
        let membershipsByProjectID = Dictionary(grouping: membershipSnapshots, by: \.projectID)
        let projectRows = projects.map { project in
            ManualProjectRowInput(
                id: project.id,
                displayName: project.displayName,
                configurationRevision: project.configurationRevision,
                createdAt: project.createdAt,
                isPinned: project.isPinned,
                pinSortIndex: project.pinSortIndex,
                resolvedAt: project.resolvedAt,
                health: project.health,
                memberships: membershipsByProjectID[project.id] ?? []
            )
        }
        return ManualProjectsGatheredInput(
            projectRows: projectRows,
            allMemberInputs: inputs,
            filteredMessageRows: filteredRows,
            sharedMessageActions: sharedActions,
            userAddresses: userAddressSet(modelContext: modelContext),
            projectRevisionFingerprint: fingerprint(parts: projects.flatMap { project in
                [
                    project.id.uuidString,
                    project.displayName,
                    String(project.configurationRevision),
                    String(project.createdAt.timeIntervalSinceReferenceDate.bitPattern),
                    project.isPinned ? "1" : "0",
                    project.pinSortIndex.map(String.init) ?? "nil",
                    project.resolvedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil",
                    project.healthRawValue,
                ]
            }),
            membershipRevisionFingerprint: fingerprint(parts: memberships.flatMap { membership in
                [
                    membership.id.uuidString,
                    membership.projectID.uuidString,
                    membership.messageID.uuidString,
                    String(membership.configurationRevision),
                    membership.sourceRawValue,
                    membership.matchingGroupID?.uuidString ?? "nil",
                    membership.matchingConditionIDsJSON,
                    membership.provenanceJSON,
                    membership.sourceFingerprint,
                    String(membership.evaluatedAt.timeIntervalSinceReferenceDate.bitPattern),
                ]
            }),
            projectMessageSourceFingerprint: projectMessageSourceFingerprint,
            sharedMessageActionFingerprint: sharedMessageActionFingerprint(sharedActions),
            fetchMetrics: fetchMetrics
        )
    }

    nonisolated static func gatherDeadlines(
        container: ModelContainer,
        vectorStore: VectorStore,
        filter: VectorFilter,
        accountScopeKey: String,
        arrivals: NewMailArrivalLedger.GatherSnapshot
    ) -> DeadlinesGatheredInput {
        let modelContext = ModelContext(container)
        let messages = fetchCandidateMessages(
            modelContext: modelContext,
            vectorStore: vectorStore,
            filter: filter
        )
        let triageDecoder = JSONDecoder()
        let dimensionsDecoder = JSONDecoder()
        let definitionFilter = Self.deadlineStructuralFilter(from: filter)
        var preparedMessages: [PreparedMessage] = []
        // Live custom-category catalog keys, resolved once per gather so row
        // decode can intersect stored custom keys against the catalog.
        let customCategoryCatalogKeys = CustomMailCategoryCatalog.allKeys(in: modelContext)

        for message in messages {
            guard let date = message.vectorTimeFilterDate else { continue }
            // Live arrivals stay invisible until their unified arrival
            // moment (starburst/dock badge, sound, system notification).
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
                decoder: dimensionsDecoder,
                scrubTriageActionState: false
            )
            // Preserve the historical Deadline behavior: action dimensions are
            // scrubbed for old mail while raw deadline evidence remains intact.
            let dimensions = message.isLiveInboundTriageEligible
                ? rawDimensions
                : rawDimensions?.scrubbingTriageActionState()
            let rawDeadlines = rawDimensions?.deadlines ?? []
            let customKeys = Set(CustomCategoryKeysJSON.decode(
                message.analysis?.customCategoryKeysJSON
            ))
                .intersection(customCategoryCatalogKeys)
            let row = Self.messageFilterRow(
                for: message,
                date: date,
                customCategoryKeys: customKeys,
                dimensions: dimensions,
                triageVerdict: triage
            )
            guard ConstellationMessageFilter.matches(
                row,
                filter: definitionFilter,
                includeHeadlineFlags: false
            ) else { continue }
            let input = ProjectMessageInputBuilder.projectInput(
                for: message,
                date: date,
                dimensions: dimensions,
                triageVerdict: triage
            )
            preparedMessages.append(
                PreparedMessage(
                    message: message,
                    date: date,
                    triage: triage,
                    dimensions: dimensions,
                    projectInput: input,
                    rawDeadlines: rawDeadlines
                )
            )
        }

        let actionState = ProjectLensActionRepository(modelContext: modelContext)
            .actionState(accountScopeKey: accountScopeKey)
        var draftStatusByMessageID: [UUID: DraftStatus] = [:]
        for draft in (try? modelContext.fetch(FetchDescriptor<Draft>())) ?? [] {
            if let messageID = draft.message?.id {
                draftStatusByMessageID[messageID] = draft.status
            }
        }
        let attentionByMessageID = MessageAttentionResolver.states(
            messages: preparedMessages.compactMap(\.projectInput).map(MessageAttentionInput.init(projectMessage:)),
            userActions: MessageAttentionUserActionState(projectActions: actionState)
        )
        // Prepared messages that survive the final filter feed the Deadlines
        // tracker (any dated deadline counts, regardless of project state).
        // `scopeThreadCounts` tallies EVERY passing
        // message per thread so a deadline's "N emails" reflects the whole
        // thread, not only its deadline-bearing messages.
        var passingForDeadlines: [PreparedMessage] = []
        var scopeThreadCounts: [UUID: Int] = [:]
        var deadlineActionFlags: [UUID: DeadlineActionFlags] = [:]
        for prepared in preparedMessages {
            let attention = attentionByMessageID[prepared.message.id]
                ?? MessageAttentionState(messageID: prepared.message.id, openKinds: [])
            let isReplied = Self.isReplied(message: prepared.message, attention: attention, actionState: actionState)
            let isConfirmed = actionState.confirmedMessageIDs.contains(prepared.message.id)
            let row = Self.messageFilterRow(
                for: prepared.message,
                date: prepared.date,
                customCategoryKeys: Set(CustomCategoryKeysJSON.decode(
                    prepared.message.analysis?.customCategoryKeysJSON
                ))
                    .intersection(customCategoryCatalogKeys),
                dimensions: prepared.dimensions,
                triageVerdict: prepared.triage,
                isActionable: attention.needsReply,
                requiresConfirmation: attention.needsConfirmation,
                isReplied: isReplied,
                isConfirmed: isConfirmed,
                isResolved: actionState.resolvedMessageIDs.contains(prepared.message.id)
            )
            guard ConstellationMessageFilter.matches(row, filter: filter) else { continue }
            if let threadID = prepared.message.thread?.id {
                scopeThreadCounts[threadID, default: 0] += 1
            }
            if !prepared.rawDeadlines.isEmpty {
                passingForDeadlines.append(prepared)
                deadlineActionFlags[prepared.message.id] = DeadlineActionFlags(
                    isActionable: attention.needsReply,
                    requiresConfirmation: attention.needsConfirmation,
                    isReplied: isReplied,
                    isConfirmed: isConfirmed,
                    isInComposerQueue: Self.deadlineComposerQueueMembership(
                        isEligible: prepared.message.isComposerQueueEligible,
                        draftStatus: draftStatusByMessageID[prepared.message.id]
                    )
                )
            }
        }
        let userAddresses = Self.userAddressSet(modelContext: modelContext)
        let deadlineObservations = Self.buildDeadlineObservations(
            from: passingForDeadlines,
            threadCounts: scopeThreadCounts,
            actionFlags: deadlineActionFlags,
            resolvedMessageIDs: actionState.resolvedMessageIDs,
            userAddresses: userAddresses
        )

        return DeadlinesGatheredInput(
            observations: deadlineObservations,
            inputFingerprint: fingerprint(parts: deadlineObservations.flatMap { observation in
                [
                    observation.messageID.uuidString,
                    observation.threadID?.uuidString ?? "nil",
                    observation.accountID?.uuidString ?? "nil",
                    String(observation.messageDate.timeIntervalSinceReferenceDate.bitPattern),
                    observation.subject,
                    observation.participants.map {
                        "\($0.role.rawValue):\($0.email):\($0.displayName ?? "")"
                    }.sorted().joined(separator: ","),
                    String(observation.threadMessageCount),
                    String(observation.deadline.date.timeIntervalSinceReferenceDate.bitPattern),
                    observation.deadlineType,
                    observation.surfaceText,
                    observation.evidenceText,
                    observation.isResolvedByUser ? "1" : "0",
                    observation.isSentByUser ? "1" : "0",
                    observation.isFlagged ? "1" : "0",
                    observation.isActionable ? "1" : "0",
                    observation.requiresConfirmation ? "1" : "0",
                    observation.isReplied ? "1" : "0",
                    observation.isConfirmed ? "1" : "0",
                    observation.isInComposerQueue ? "1" : "0",
                ]
            }),
            fetchMetrics: ProjectsDataFetchMetrics()
        )
    }

    /// The historical Deadline gather first establishes its account/time pool,
    /// then applies the remaining message filters after attention is resolved.
    /// Keeping this two-pass shape preserves the pre-cutover Deadline behavior.
    nonisolated static func deadlineStructuralFilter(from filter: VectorFilter) -> VectorFilter {
        var definition = VectorFilter()
        definition.accountIds = filter.accountIds
        definition.timeRange = filter.timeRange
        return definition
    }

    /// Turns filter-passing messages that carry a deadline phrase into resolved,
    /// dated `DeadlineObservation`s. Each message contributes its soonest
    /// resolvable deadline (the binding one); thread collapse and Upcoming /
    /// Past / Resolved classification happen later in `DeadlineTracker`.
    /// Per-message action state the Deadlines HUD rail needs to render the
    /// selected email's controls (reply / confirm / compose) with correct state.
    struct DeadlineActionFlags {
        let isActionable: Bool
        let requiresConfirmation: Bool
        let isReplied: Bool
        let isConfirmed: Bool
        let isInComposerQueue: Bool
    }

    /// Deadlines report the queue the user can currently see, including the
    /// draft-status gate that removes sent, confirmed, rejected, and discarded
    /// work. Eligibility alone can remain true after a reply has completed.
    nonisolated static func deadlineComposerQueueMembership(
        isEligible: Bool,
        draftStatus: DraftStatus?
    ) -> Bool {
        isEligible && (draftStatus == nil || draftStatus == .pending)
    }

    nonisolated private static func buildDeadlineObservations(
        from prepared: [PreparedMessage],
        threadCounts: [UUID: Int],
        actionFlags: [UUID: DeadlineActionFlags],
        resolvedMessageIDs: Set<UUID>,
        userAddresses: Set<String>,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [DeadlineObservation] {
        var observations: [DeadlineObservation] = []
        for prepared in prepared {
            let resolved = prepared.rawDeadlines.compactMap { candidate -> (DeadlineCandidate, ResolvedDeadlineDate)? in
                guard let surface = candidate.displayText,
                      let date = DeadlineDateResolver.resolve(surface, referenceDate: prepared.date, calendar: calendar) else {
                    return nil
                }
                return (candidate, date)
            }
            // The soonest resolvable date is the binding deadline on this message.
            guard let (candidate, deadline) = resolved.min(by: { $0.1.date < $1.1.date }) else { continue }

            let threadID = prepared.message.thread?.id
            observations.append(
                DeadlineObservation(
                    messageID: prepared.message.id,
                    threadID: threadID,
                    accountID: prepared.message.accountID,
                    messageDate: prepared.date,
                    subject: MIMEHeaderDecoder.decodeEncodedWords(prepared.message.subject),
                    participants: deadlineCorrespondents(message: prepared.message, userAddresses: userAddresses),
                    threadMessageCount: threadID.flatMap { threadCounts[$0] } ?? 1,
                    deadline: deadline,
                    deadlineType: candidate.type,
                    surfaceText: candidate.displayText ?? candidate.dateString,
                    evidenceText: candidate.evidenceSpan?.text ?? candidate.dateString,
                    isResolvedByUser: resolvedMessageIDs.contains(prepared.message.id),
                    isSentByUser: prepared.message.isSentByUser,
                    isFlagged: prepared.message.flaggedOrFalse,
                    isActionable: actionFlags[prepared.message.id]?.isActionable ?? false,
                    requiresConfirmation: actionFlags[prepared.message.id]?.requiresConfirmation ?? false,
                    isReplied: actionFlags[prepared.message.id]?.isReplied ?? false,
                    isConfirmed: actionFlags[prepared.message.id]?.isConfirmed ?? false,
                    isInComposerQueue: actionFlags[prepared.message.id]?.isInComposerQueue ?? false
                )
            )
        }
        return observations
    }

    /// Non-user participants on a message, mapped for the Deadlines tracker.
    nonisolated private static func deadlineCorrespondents(
        message: Message,
        userAddresses: Set<String>
    ) -> [ProjectParticipant] {
        message.participants.compactMap { link -> ProjectParticipant? in
            guard let participant = link.participant else { return nil }
            let email = participant.emailAddress.lowercased()
            guard !email.isEmpty, !userAddresses.contains(email) else { return nil }
            return ProjectParticipant(
                email: participant.emailAddress,
                displayName: participant.displayName.map(MIMEHeaderDecoder.decodeEncodedWords),
                role: link.role
            )
        }
    }

    /// Lowercased set of every address known to belong to the local user —
    /// every `Account.emailAddress` and every `Identity.address` across
    /// configured accounts. Mirrors `ConstellationModeView.userAddressSet`.
    nonisolated private static func userAddressSet(modelContext: ModelContext) -> Set<String> {
        let accounts = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
        var addresses: Set<String> = []
        for account in accounts {
            let primary = account.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !primary.isEmpty {
                addresses.insert(primary)
            }
            for identity in account.identities {
                let value = identity.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !value.isEmpty {
                    addresses.insert(value)
                }
            }
        }
        return addresses
    }

    private nonisolated static func fetchCandidateMessages(
        modelContext: ModelContext,
        vectorStore: VectorStore,
        filter: VectorFilter
    ) -> [Message] {
        guard let range = filter.timeRange else {
            let descriptor = FetchDescriptor<Message>()
            return ((try? modelContext.fetch(descriptor)) ?? [])
                .filter { !$0.isTrashed }
                .sorted(by: Self.messageSort)
        }

        let vectorRangeIDs: Set<UUID>
        do {
            vectorRangeIDs = try vectorStore.messageIDsInDateRange(range)
        } catch {
            assertionFailure("VectorStore.messageIDsInDateRange failed: \(error)")
            vectorRangeIDs = []
        }

        let sentOnlyDescriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { msg in
                msg.receivedAt == nil
                    && msg.sentAt != nil
                    && msg.sentAt! >= range.lowerBound
                    && msg.sentAt! <= range.upperBound
            }
        )
        let sentOnlyMessages = ((try? modelContext.fetch(sentOnlyDescriptor)) ?? [])
            .filter { !$0.isTrashed }

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

        var byID: [UUID: Message] = [:]
        for message in fetchedFromVectors { byID[message.id] = message }
        for message in sentOnlyMessages { byID[message.id] = message }
        return Array(byID.values).sorted(by: Self.messageSort)
    }

    private static func messageSort(_ lhs: Message, _ rhs: Message) -> Bool {
        let lhsDate = lhs.vectorTimeFilterDate ?? .distantPast
        let rhsDate = rhs.vectorTimeFilterDate ?? .distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    nonisolated static func messageFilterRow(
        for message: Message,
        date: Date,
        customCategoryKeys: Set<String> = [],
        dimensions: MessageDimensions?,
        triageVerdict: TriageVerdict?,
        isActionable: Bool? = nil,
        requiresConfirmation: Bool? = nil,
        isReplied: Bool? = nil,
        isConfirmed: Bool? = nil,
        isResolved: Bool = false
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
            isResolved: isResolved,
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

    nonisolated private static func messageType(for message: Message) -> MessageType {
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

    /// Cache identity for every value consumed by manual row computation and
    /// the focused-message presentation projection. IDs alone are insufficient:
    /// read/flag state, headers, participants, summaries, categories, analysis,
    /// and attachment shape can all change while membership remains constant.
    nonisolated private static func projectMessageFingerprint(
        _ prepared: [PreparedMessage]
    ) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return fingerprint(parts: prepared.sorted { $0.message.id.uuidString < $1.message.id.uuidString }.flatMap { value in
            let inputPayload = value.projectInput.flatMap { try? encoder.encode($0) }
                .map { $0.base64EncodedString() } ?? "nil"
            let message = value.message
            let analysis = message.analysis
            return [
                message.id.uuidString,
                inputPayload,
                String(message.ingestedAt.timeIntervalSinceReferenceDate.bitPattern),
                message.liveDetectedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil",
                message.bodyTextPath ?? "nil",
                message.bodyHtmlPath ?? "nil",
                String(describing: message.embeddingStatus),
                analysis?.bodySummary ?? "nil",
                analysis?.bodySummaryInputFingerprint ?? "nil",
                analysis?.mailClassificationJSON ?? "nil",
                analysis?.customCategoryKeysJSON ?? "nil",
                analysis?.triageVerdictJSON ?? "nil",
                analysis?.dimensionsJSON ?? "nil",
            ]
        })
    }

    /// Length framing makes every snapshot signature deterministic without
    /// separator collisions (for example, `["ab", "c"]` versus `["a", "bc"]`).
    nonisolated private static func fingerprint(parts: [String]) -> String {
        parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    nonisolated private static func sharedMessageActionFingerprint(
        _ actions: ProjectLensSharedMessageActionState
    ) -> String {
        func ids(_ values: Set<UUID>) -> String {
            values.map(\.uuidString).sorted().joined(separator: ",")
        }
        return fingerprint(parts: [
            "resolved", ids(actions.resolvedMessageIDs),
            "reply-needed", ids(actions.replyNeededMessageIDs),
            "replied", ids(actions.repliedMessageIDs),
            "confirmation-needed", ids(actions.confirmationNeededMessageIDs),
            "confirmed", ids(actions.confirmedMessageIDs),
        ])
    }

}
