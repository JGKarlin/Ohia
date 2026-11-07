import Foundation
import Observation
import OhiaCore

public enum TimeRangePreset: String, Codable, CaseIterable, Identifiable {
    // Order here is the order rendered by `TimeRangeMenu.presetPicker`
    // (`ForEach(TimeRangePreset.allCases)`), matching the menu spec:
    // Now · Hour · Today · Yesterday · Week · Month · Quarter ·
    // Year-to-Date · Year · All Time · Custom…
    case now, hour, today, yesterday, week, month, quarter, yearToDate, year, all, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .now:        return "Now"
        case .hour:       return "Hour"
        case .today:      return "Today"
        case .yesterday:  return "Yesterday"
        case .week:       return "Week"
        case .month:      return "Month"
        case .quarter:    return "Quarter"
        case .year:       return "Year"
        case .yearToDate: return "Year to Date"
        case .all:        return "All Time"
        case .custom:     return "Custom…"
        }
    }
    /// Short / "watch new arrivals" presets. Moments presets are cumulative
    /// lookbacks whose upper bound is now, so yesterday still includes new
    /// arrivals until the user selects a fixed custom range.
    public var isRecent: Bool { self == .now || self == .hour || self == .today || self == .yesterday }

    /// True when the preset's window upper bound is "now" — newly-arriving
    /// messages (with `message_received_at` near now) fall inside the window
    /// and warrant a live scene refresh. False only for windows fixed away
    /// from now (`.custom`).
    ///
    /// Used by `ConstellationModeView` to gate `refreshSceneData(...)` when
    /// `.index` / `.ingest` / `.imapPollFolder` / etc. events fire — and by
    /// the placement-observation polling loop it kicks off.
    public var refreshesOnNewPlacements: Bool {
        switch self {
        case .now, .hour, .today, .yesterday, .week, .month, .quarter, .year, .yearToDate, .all:
            return true
        case .custom:
            return false
        }
    }

    public static var liveRefreshPresets: Set<TimeRangePreset> {
        Set(allCases.filter(\.refreshesOnNewPlacements))
    }

    /// SF Symbol that visually distinguishes each preset in the chip row.
    /// Picked for legibility at 11pt; semantics over decoration:
    /// - `.now` ignite/sparkle, matching the "watch new arrivals" register
    /// - `.hour` / `.today` clock + sun for short-window time
    /// - `.yesterday` moon-and-stars, the calendar-flanking past-day case
    /// - `.week` / `.month` calendar variants for date-range time
    /// - `.quarter` / `.year` chart + clock-flagged calendar for the
    ///   business-cadence and rolling-year cases
    /// - `.yearToDate` uptrend chart, the calendar-anchored YTD case
    /// - `.all` infinity, the no-bound case
    /// - `.custom` slider, the user-defined case
    public var symbolName: String {
        switch self {
        case .now:        return "sparkles"
        case .hour:       return "clock"
        case .today:      return "sun.max.fill"
        case .yesterday:  return "moon.stars"
        case .week:       return "calendar.day.timeline.leading"
        case .month:      return "calendar"
        case .quarter:    return "chart.bar.xaxis"
        case .year:       return "calendar.badge.clock"
        case .yearToDate: return "chart.line.uptrend.xyaxis"
        case .all:        return "infinity"
        case .custom:     return "slider.horizontal.3"
        }
    }
    public nonisolated func range(relativeTo now: Date = Date.now) -> ClosedRange<Date>? {
        let cal = Calendar.current
        let day: TimeInterval = 24 * 60 * 60
        switch self {
        case .now:        return now.addingTimeInterval(-5 * 60) ... now
        case .hour:       return now.addingTimeInterval(-60 * 60) ... now
        // Rolling 24h lookback from the present.
        case .today:      return now.addingTimeInterval(-day) ... now
        // Rolling 48h lookback from the present. This is cumulative:
        // it includes today's mail plus mail from the prior 24h, matching
        // the Moments scale's "now back to the selected moment" model.
        case .yesterday:  return now.addingTimeInterval(-2 * day) ... now
        case .week:       return now.addingTimeInterval(-7 * day) ... now
        case .month:      return now.addingTimeInterval(-30 * day) ... now
        case .quarter:    return now.addingTimeInterval(-90 * day) ... now
        case .year:       return now.addingTimeInterval(-365 * day) ... now
        // Calendar-anchored (start of current year → now), the one
        // Tableau-style "to-date" preset.
        case .yearToDate:
            let startOfYear = cal.date(from: cal.dateComponents([.year], from: now)) ?? now
            return startOfYear ... now
        case .all:        return nil
        case .custom:     return nil // caller assigns `filter.timeRange` directly
        }
    }
}

public enum FilterStateScopePreference: String, CaseIterable, Identifiable {
    case shared
    case lensSpecific

    public static let storageKey = "constellationFilterStateScope"
    public static let defaultPreference: FilterStateScopePreference = .lensSpecific

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shared: "Shared across scopes"
        case .lensSpecific: "Scope specific"
        }
    }

    public var detail: String {
        switch self {
        case .shared:
            "Filter changes in one scope carry into every scope."
        case .lensSpecific:
            "Each scope remembers its own filter state."
        }
    }

    public static func current(
        defaults: UserDefaults = .standard
    ) -> FilterStateScopePreference {
        guard let rawValue = defaults.string(forKey: storageKey) else {
            return defaultPreference
        }
        return FilterStateScopePreference(rawValue: rawValue) ?? defaultPreference
    }
}

public enum ConstellationFilterResolver {
    public nonisolated static func effectiveSceneFilter(
        baseFilter: VectorFilter,
        selectedTimeRange: TimeRangePreset,
        now: Date = Date.now
    ) -> VectorFilter {
        var filter = baseFilter
        // Re-derive the filter's time range from `now` for every preset
        // except `.custom` (whose window is set explicitly by the user).
        // This is intentionally a different gate than
        // `refreshesOnNewPlacements`: presets are recomputed here so
        // rolling lookbacks like `.today` / `.yesterday` slide with the
        // present, while `.custom` keeps the user's fixed explicit window.
        if selectedTimeRange != .custom {
            filter.timeRange = selectedTimeRange.range(relativeTo: now)
        }
        return filter
    }
}

@Observable @MainActor
public final class ConstellationState {
    // Front Page is the default landing lens: the mode opens into the
    // newspaper reading surface (a fresh, no-snapshot launch gets this
    // default; restored snapshots keep their saved frame). Onboarding
    // deliberately stays on `.defaultFrame` (the Metal witness scene) via
    // `makeOnboardingState()`.
    public var activeFrame: FrameKey = .frontPage {
        didSet {
            let previousLens = oldValue.spatialLens
            let newLens = activeFrame.spatialLens
            guard previousLens != newLens else { return }
            if preparedActionFilterFrame?.spatialLens == newLens {
                preparedActionFilterFrame = nil
                return
            }
            applyFilterStateTransition(from: previousLens, to: newLens)
        }
    }
    public var cameraStatesByFrame: [FrameKey: CameraState] = [:]
    // Default to `.all` so mode entry shows the entire universe — matches
    // the 2026-04-25 design shift away from the old warp-to-Today-centroid
    // entry contract (see the "Mode entry shows the entire universe"
    // paragraph in the Constellation Mode design doc §4.5). The time-range
    // buttons are still available as an explicit user action to narrow.
    public var selectedTimeRange: TimeRangePreset = .all
    public var filter: VectorFilter = ConstellationState.makeDefaultFilter()
    public var searchQuery: String = ""
    public var searchResultIds: [Int64] = []
    public var hoveredVectorId: Int64? = nil
    public var lockedVectorId: Int64? = nil
    public var lockOverlayDimEnabled: Bool = true
    @ObservationIgnored private var nonFrontPageActionCriteria = ActionFilterCriteria()
    @ObservationIgnored private var frontPageActionCriteria = ActionFilterCriteria.frontPageDefaults
    @ObservationIgnored private var preparedActionFilterFrame: FrameKey?
    @ObservationIgnored private var filterStatesByLens: [FrameKey: VectorFilter] = [:]
    @ObservationIgnored private let filterStateScopeProvider: @MainActor () -> FilterStateScopePreference

    public static func makeOnboardingState() -> ConstellationState {
        ConstellationState(
            activeFrame: .defaultFrame,
            selectedTimeRange: .all,
            filter: makeDefaultFilter()
        )
    }

    private static func makeDefaultFilter() -> VectorFilter {
        // Every lens starts from the canonical all-inclusive filter state.
        // Vector collection visibility remains a Developer Settings
        // diagnostic surface.
        var f = VectorFilter()
        f.collections = VectorCollectionVisibilityPreferences.collections()
        f.timeRange = TimeRangePreset.all.range()  // nil — no time filter
        return f
    }

    static func projectsLensMessageFilterRestState() -> VectorFilter {
        makeDefaultFilter()
    }

    /// Restores the Projects lens's shared message-display filter to its
    /// canonical all-inclusive state. Project rules and membership are separate
    /// persisted domains and are deliberately not touched here.
    func clearProjectsLensMessageFilters() {
        let restFilter = Self.makeDefaultFilter()
        selectedTimeRange = .all
        filter = restFilter
        nonFrontPageActionCriteria = ActionFilterCriteria(filter: restFilter)
        switch filterStateScopeProvider() {
        case .shared:
            filterStatesByLens.removeAll(keepingCapacity: true)
        case .lensSpecific:
            filterStatesByLens[.projects] = restFilter
        }
    }
    /// Camera-anchored aperture / scope control. 0.0 = tightest (nearest ~50
    /// stars only), 1.0 = widest (all filtered stars). Mirrored from the
    /// `constellationAperture` AppStorage key by ConstellationModeView.
    public var aperture: Double = 1.0
    public init(
        filterStateScopeProvider: @escaping @MainActor () -> FilterStateScopePreference = {
            FilterStateScopePreference.current()
        }
    ) {
        self.filterStateScopeProvider = filterStateScopeProvider
        frontPageActionCriteria.apply(to: &filter)
        filterStatesByLens[activeFrame.spatialLens] = filter
    }

    public init(
        activeFrame: FrameKey,
        selectedTimeRange: TimeRangePreset,
        filter: VectorFilter,
        cameraStatesByFrame: [FrameKey: CameraState] = [:],
        filterStatesByLens: [FrameKey: VectorFilter] = [:],
        frontPageActionFilter: VectorFilter? = nil,
        filterStateScopeProvider: @escaping @MainActor () -> FilterStateScopePreference = {
            FilterStateScopePreference.current()
        }
    ) {
        self.activeFrame = activeFrame
        self.selectedTimeRange = selectedTimeRange
        self.filter = filter
        self.filterStateScopeProvider = filterStateScopeProvider
        for (frame, cameraState) in cameraStatesByFrame {
            self.cameraStatesByFrame[frame.spatialLens] = cameraState
        }
        for (frame, filter) in filterStatesByLens {
            self.filterStatesByLens[frame.spatialLens] = filter
        }
        if let frontPageActionFilter {
            frontPageActionCriteria = ActionFilterCriteria(filter: frontPageActionFilter)
        } else if activeFrame.spatialLens == .frontPage {
            frontPageActionCriteria = .frontPageDefaults
        }
        if activeFrame.spatialLens == .frontPage {
            frontPageActionCriteria.apply(to: &self.filter)
        } else {
            nonFrontPageActionCriteria = ActionFilterCriteria(filter: self.filter)
        }
        self.filterStatesByLens[activeFrame.spatialLens] = self.filter
    }

    /// Applies lens-local Action criteria before a frame switch plans its
    /// destination render. The subsequent `activeFrame` assignment recognizes
    /// the prepared transition and does not apply it twice.
    func prepareActionFilters(forEntering frame: FrameKey) {
        let currentLens = activeFrame.spatialLens
        let destinationLens = frame.spatialLens
        guard currentLens != destinationLens else { return }
        applyFilterStateTransition(from: currentLens, to: destinationLens)
        preparedActionFilterFrame = destinationLens
    }

    func filterStatesForPersistence() -> [FrameKey: VectorFilter]? {
        guard filterStateScopeProvider() == .lensSpecific else { return nil }
        var states = filterStatesByLens
        states[frameForPersistence] = filter
        return states
    }

    var frameForPersistence: FrameKey {
        preparedActionFilterFrame?.spatialLens ?? activeFrame.spatialLens
    }

    func frontPageActionFilterForPersistence() -> VectorFilter {
        let criteria = frameForPersistence == .frontPage
            ? ActionFilterCriteria(filter: filter)
            : frontPageActionCriteria
        var filter = VectorFilter()
        criteria.apply(to: &filter)
        return filter
    }

    private struct ActionFilterCriteria {
        var reply: AttentionFilterCriterion = .any
        var confirmation: AttentionFilterCriterion = .any
        var resolution: AttentionFilterCriterion?

        init(filter: VectorFilter? = nil) {
            if let filter {
                reply = filter.replyNeededCriterion
                confirmation = filter.confirmationNeededCriterion
                resolution = filter.resolvedCriterion
            }
        }

        static var frontPageDefaults: ActionFilterCriteria {
            var filter = VectorFilter()
            filter.replyNeededCriterion = .excluded
            filter.confirmationNeededCriterion = .excluded
            filter.resolvedCriterion = .excluded
            return ActionFilterCriteria(filter: filter)
        }

        func apply(to filter: inout VectorFilter) {
            filter.replyNeededCriterion = reply
            filter.confirmationNeededCriterion = confirmation
            filter.resolvedCriterion = resolution
        }
    }

    private func applyFilterStateTransition(from previousLens: FrameKey, to newLens: FrameKey) {
        switch filterStateScopeProvider() {
        case .shared:
            filterStatesByLens.removeAll(keepingCapacity: true)
            applyActionFilterTransition(from: previousLens, to: newLens)
        case .lensSpecific:
            let activeTimeRange = filter.timeRange
            if previousLens == .frontPage {
                frontPageActionCriteria = ActionFilterCriteria(filter: filter)
            } else {
                nonFrontPageActionCriteria = ActionFilterCriteria(filter: filter)
            }
            filterStatesByLens[previousLens] = filter
            let savedDestinationFilter = filterStatesByLens[newLens]
            filter = savedDestinationFilter ?? Self.makeDefaultFilter()
            filter.timeRange = selectedTimeRange == .custom
                ? activeTimeRange
                : selectedTimeRange.range()
            if newLens == .frontPage {
                if savedDestinationFilter == nil {
                    frontPageActionCriteria = .frontPageDefaults
                    frontPageActionCriteria.apply(to: &filter)
                } else {
                    frontPageActionCriteria = ActionFilterCriteria(filter: filter)
                }
            } else {
                nonFrontPageActionCriteria = ActionFilterCriteria(filter: filter)
            }
            filterStatesByLens[newLens] = filter
        }
    }

    private func applyActionFilterTransition(from previousLens: FrameKey, to newLens: FrameKey) {
        if previousLens != .frontPage, newLens == .frontPage {
            nonFrontPageActionCriteria = ActionFilterCriteria(filter: filter)
            frontPageActionCriteria.apply(to: &filter)
        } else if previousLens == .frontPage, newLens != .frontPage {
            frontPageActionCriteria = ActionFilterCriteria(filter: filter)
            nonFrontPageActionCriteria.apply(to: &filter)
        } else if newLens != .frontPage {
            nonFrontPageActionCriteria = ActionFilterCriteria(filter: filter)
        }
    }

    public func selectTimeRange(_ preset: TimeRangePreset) {
        selectedTimeRange = preset
        filter.timeRange = preset.range()
    }

    public func cameraState(for frame: FrameKey) -> CameraState? {
        cameraStatesByFrame[frame.spatialLens]
    }

    public func setCameraState(_ cameraState: CameraState, for frame: FrameKey) {
        cameraStatesByFrame[frame.spatialLens] = cameraState
    }
}

@MainActor
enum ConstellationViewStatePersistence {
    private static let storageKey = "constellationViewStateSnapshotV1"

    struct RestoredState {
        var state: ConstellationState
        var customTimeRange: ClosedRange<Date>?
    }

    static func restore(defaults: UserDefaults = .standard) -> RestoredState? {
        guard let data = defaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return nil }

        func restoredFilter(_ savedFilter: VectorFilter) -> VectorFilter {
            var filter = savedFilter
            filter.messageTypes = nil
            filter.collections = VectorCollectionVisibilityPreferences.collections(defaults)
            filter.accountIds = nil
            filter.hasAttachmentsOnly = false
            filter.flaggedOnly = false
            if snapshot.selectedTimeRange == .custom {
                filter.timeRange = snapshot.customTimeRange
            } else {
                filter.timeRange = snapshot.selectedTimeRange.range()
            }
            return filter
        }

        var filterStatesByLens: [FrameKey: VectorFilter] = [:]
        for (frame, savedFilter) in snapshot.filterStatesByLens ?? [:] {
            filterStatesByLens[frame.spatialLens] = restoredFilter(savedFilter)
        }
        let activeFrame = snapshot.activeFrame
        var filter = filterStatesByLens[activeFrame.spatialLens]
            ?? restoredFilter(snapshot.filter)
        // Forms was retired from the toolbar in favor of Headline. Do not
        // let old saved MessageType chip selections keep narrowing the scene
        // invisibly after upgrade.
        filter.messageTypes = nil
        // Layers was also retired from the toolbar. Developer Settings owns
        // vector collection visibility now, so stale snapshot collections
        // should not fight the canonical kill-switch preferences.
        filter.collections = VectorCollectionVisibilityPreferences.collections(defaults)
        // Destination account chips are fast, session-scoped narrowing
        // controls. Restoring an old explicit set can make the scene come up
        // scoped to one mailbox even though the global toolbar owns filtering,
        // so launch from the all-accounts sentinel and let TopBar toggles opt
        // into account scope for the current session.
        filter.accountIds = nil
        // Attachments and flagged chips are session-scoped narrowing
        // toggles: they always start OFF at launch regardless of the saved
        // snapshot. Persisting them across launches surprised users — the
        // scene would silently come up narrowed to a subset they'd toggled
        // hours earlier. Reset both on every restore so the runtime toggle
        // is opt-in per session.
        filter.hasAttachmentsOnly = false
        filter.flaggedOnly = false
        if snapshot.selectedTimeRange == .custom {
            filter.timeRange = snapshot.customTimeRange
        } else {
            filter.timeRange = snapshot.selectedTimeRange.range()
        }

        return RestoredState(
            state: ConstellationState(
                activeFrame: activeFrame,
                selectedTimeRange: snapshot.selectedTimeRange,
                filter: filter,
                cameraStatesByFrame: [:],
                filterStatesByLens: filterStatesByLens,
                frontPageActionFilter: snapshot.frontPageActionFilter,
                filterStateScopeProvider: {
                    FilterStateScopePreference.current(defaults: defaults)
                }
            ),
            customTimeRange: snapshot.customTimeRange
        )
    }

    static func save(
        state: ConstellationState,
        customTimeRange: ClosedRange<Date>?,
        defaults: UserDefaults = .standard
    ) {
        var filter = state.filter
        filter.messageTypes = nil
        filter.collections = VectorCollectionVisibilityPreferences.collections(defaults)
        if state.selectedTimeRange == .custom {
            filter.timeRange = customTimeRange
        } else {
            // Presets like Today and Week are relative windows. Persist the
            // selected preset, not the timestamp range produced at save time.
            filter.timeRange = nil
        }

        let snapshot = Snapshot(
            activeFrame: state.frameForPersistence,
            selectedTimeRange: state.selectedTimeRange,
            customTimeRange: customTimeRange,
            filter: filter,
            filterStatesByLens: state.filterStatesForPersistence()?.mapValues { savedFilter in
                var savedFilter = savedFilter
                savedFilter.messageTypes = nil
                savedFilter.collections = VectorCollectionVisibilityPreferences.collections(defaults)
                if state.selectedTimeRange == .custom {
                    savedFilter.timeRange = customTimeRange
                } else {
                    savedFilter.timeRange = nil
                }
                return savedFilter
            },
            frontPageActionFilter: state.frontPageActionFilterForPersistence(),
            // Camera snapshots are session-only. Persisting them made fresh
            // launches skip the same recentered fit the reset-position button
            // produces for each lens.
            cameraStatesByFrame: nil
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private struct PersistedCameraState: Codable {
        var x: Float
        var y: Float
        var z: Float
        var yaw: Float
        var pitch: Float
        var roll: Float

        init(_ state: CameraState) {
            x = state.position.x
            y = state.position.y
            z = state.position.z
            yaw = state.yaw
            pitch = state.pitch
            roll = state.roll
        }

        var cameraState: CameraState {
            CameraState(
                position: SIMD3<Float>(x, y, z),
                velocity: .zero,
                yaw: yaw,
                pitch: pitch,
                yawRate: 0,
                pitchRate: 0,
                roll: roll,
                rollRate: 0
            )
        }
    }

    private struct Snapshot: Codable {
        var activeFrame: FrameKey
        var selectedTimeRange: TimeRangePreset
        var customTimeRange: ClosedRange<Date>?
        var filter: VectorFilter
        var filterStatesByLens: [FrameKey: VectorFilter]?
        var frontPageActionFilter: VectorFilter?
        var cameraStatesByFrame: [FrameKey: PersistedCameraState]?
    }
}
