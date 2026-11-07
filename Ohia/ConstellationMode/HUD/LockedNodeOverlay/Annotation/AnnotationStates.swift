import Foundation
import Observation

@MainActor
@Observable
final class AnnotationStates {
    private var openIDs: Set<String> = []
    private var expandedIDs: Set<String> = []
    private var expandedContentModes: [String: AnnotationExpandedContentMode] = [:]
    private var phases: [String: WormholePhase] = [:]
    /// Bumped every time the `phases` dictionary is mutated (install, remove,
    /// reset). Observers latch screen-space wormhole anchors against this
    /// counter so they refresh exactly once per phase change without
    /// snapshotting the whole dictionary.
    private(set) var phasesGeneration: UInt64 = 0
    @ObservationIgnored private var phaseCleanupTasks: [String: Task<Void, Never>] = [:]

    /// Read-only view of currently-open ids. Used by the locked-overlay
    /// orchestrator to compute screen-space latches before installing
    /// closing phases.
    var openAnnotationIDs: Set<String> { openIDs }

    func register(
        items: [AnnotationItem],
        initiallyOpen: [String],
        now: Date = Date.now,
        stagger: TimeInterval = 0.16
    ) {
        let ids = Set(items.map(\.id))
        openIDs.formIntersection(ids)
        expandedIDs.formIntersection(ids)
        expandedContentModes = expandedContentModes.filter { ids.contains($0.key) }
        cancelPhaseCleanupTasks(keeping: ids)
        let filteredPhases = phases.filter { ids.contains($0.key) }
        if filteredPhases.count != phases.count {
            phases = filteredPhases
            bumpPhasesGeneration()
        }

        var openIndex = 0
        for id in initiallyOpen where ids.contains(id) && !openIDs.contains(id) {
            openIDs.insert(id)
            installPhase(
                WormholePhase(
                    startedAt: now.addingTimeInterval(Double(openIndex) * stagger),
                    direction: .opening
                ),
                for: id
            )
            openIndex += 1
        }
    }

    func reset() {
        phaseCleanupTasks.values.forEach { $0.cancel() }
        phaseCleanupTasks.removeAll()
        openIDs.removeAll()
        expandedIDs.removeAll()
        expandedContentModes.removeAll()
        if !phases.isEmpty {
            phases.removeAll()
            bumpPhasesGeneration()
        }
    }

    func isOpen(_ id: String) -> Bool {
        openIDs.contains(id)
    }

    func isExpanded(_ id: String) -> Bool {
        expandedIDs.contains(id)
    }

    func expandedMode(for id: String) -> AnnotationExpandedContentMode? {
        guard expandedIDs.contains(id) else { return nil }
        return expandedContentModes[id] ?? .summary
    }

    func phase(for id: String) -> WormholePhase? {
        phases[id]
    }

    /// True while any wormhole phase is installed (opening or closing).
    /// Phase interpolation is time-driven — `phase.at(now)` sampled per
    /// timeline tick — so the locked overlay keeps its timeline at frame
    /// cadence while this is true and drops to the idle tick otherwise.
    /// Observable: installs and cleanups mutate `phases`, so a body that
    /// reads this re-evaluates exactly on phase boundaries.
    var hasActivePhases: Bool {
        phases.isEmpty == false
    }

    func open(_ id: String, now: Date = Date.now) {
        guard !openIDs.contains(id) else { return }
        openIDs.insert(id)
        installPhase(WormholePhase(startedAt: now, direction: .opening), for: id)
    }

    func close(_ id: String, now: Date = Date.now) {
        guard openIDs.contains(id) else { return }
        openIDs.remove(id)
        expandedIDs.remove(id)
        expandedContentModes[id] = nil
        guard let phase = closingPhase(for: id, now: now) else {
            if phases.removeValue(forKey: id) != nil {
                cancelPhaseCleanup(for: id)
                bumpPhasesGeneration()
            }
            return
        }
        installPhase(phase, for: id)
    }

    /// Closes every currently-open popup except those in `keep`. Each
    /// closure runs through the same `WormholePhase(.closing)` transition
    /// `close(_:now:)` uses, so the dismissal animates rather than
    /// snapping. Used by the affinity-rank navigator to enforce the
    /// "exactly one pane at a time during Tab / Shift+Tab stepping" invariant.
    func closeAll(except keep: Set<String> = [], now: Date = Date.now) {
        for id in openIDs where !keep.contains(id) {
            expandedIDs.remove(id)
            expandedContentModes[id] = nil
            if let phase = closingPhase(for: id, now: now) {
                installPhase(phase, for: id)
            } else if phases.removeValue(forKey: id) != nil {
                cancelPhaseCleanup(for: id)
                bumpPhasesGeneration()
            }
        }
        openIDs.formIntersection(keep)
    }

    func toggleExpanded(_ id: String) {
        toggleExpanded(id, mode: .summary)
    }

    /// Toggle the expanded popup into a specific content mode. Repeating
    /// the same mode collapses; choosing the alternate mode switches the
    /// already-open pane in place.
    @discardableResult
    func toggleExpanded(_ id: String, mode: AnnotationExpandedContentMode) -> Bool {
        if expandedIDs.contains(id), expandedMode(for: id) == mode {
            expandedIDs.remove(id)
            expandedContentModes[id] = nil
            return false
        } else {
            expandedIDs.insert(id)
            expandedContentModes[id] = mode
            return true
        }
    }

    func shouldShowPopup(_ id: String, now: Date) -> Bool {
        if openIDs.contains(id) { return true }
        guard let phase = phases[id], phase.direction == .closing else { return false }
        return phase.at(now).isComplete == false
    }

    func shouldShowBadge(_ id: String, now: Date) -> Bool {
        if openIDs.contains(id) { return false }
        guard let phase = phases[id], phase.direction == .closing else { return true }
        return phase.at(now).isComplete
    }

    func transitionOpacity(_ id: String, now: Date) -> Double {
        guard let phase = phases[id] else { return 1 }
        let sample = phase.at(now)
        guard !sample.isComplete else { return phase.direction == .closing ? 0 : 1 }
        return sample.popupOpacity
    }

    /// Longest remaining time across in-flight closing phases. Used by the
    /// rank-step orchestrator to await every active dismissal animation
    /// before warping the camera and opening the next pane.
    func maxRemainingClosingDuration(now: Date = Date.now) -> TimeInterval {
        activeClosingPhases(now: now)
            .map { $0.remainingDuration(at: now) }
            .max() ?? 0
    }

    private func installPhase(_ phase: WormholePhase, for id: String) {
        phases[id] = phase
        bumpPhasesGeneration()
        schedulePhaseCleanup(for: id, phase: phase)
    }

    private func closingPhase(for id: String, now: Date) -> WormholePhase? {
        if let openingPhase = phases[id], openingPhase.direction == .opening {
            let sample = openingPhase.at(now)
            let visibleAmount = max(sample.leaderProgress, sample.popupOpacity)
            guard visibleAmount > 0.001 else { return nil }
            return WormholePhase(
                startedAt: now,
                direction: .closing,
                initialLeaderProgress: sample.leaderProgress,
                initialPopupOpacity: sample.popupOpacity
            )
        }
        return WormholePhase(startedAt: now, direction: .closing)
    }

    private func activeClosingPhases(now: Date) -> [WormholePhase] {
        phases.values.filter { phase in
            phase.direction == .closing && !phase.at(now).isComplete
        }
    }

    private func schedulePhaseCleanup(for id: String, phase: WormholePhase) {
        phaseCleanupTasks[id]?.cancel()
        phaseCleanupTasks[id] = Task { @MainActor [weak self] in
            let remaining = phase.remainingDuration(at: Date.now)
            if remaining > 0 {
                do {
                    try await Self.sleep(for: remaining)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled,
                  self?.phases[id] == phase else {
                return
            }
            self?.phases.removeValue(forKey: id)
            self?.phaseCleanupTasks[id] = nil
            self?.bumpPhasesGeneration()
        }
    }

    private func cancelPhaseCleanup(for id: String) {
        phaseCleanupTasks[id]?.cancel()
        phaseCleanupTasks[id] = nil
    }

    private func cancelPhaseCleanupTasks(keeping ids: Set<String>) {
        for id in Array(phaseCleanupTasks.keys) where !ids.contains(id) {
            cancelPhaseCleanup(for: id)
        }
    }

    private func bumpPhasesGeneration() {
        phasesGeneration &+= 1
    }

    private static func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, interval)))
    }
}
