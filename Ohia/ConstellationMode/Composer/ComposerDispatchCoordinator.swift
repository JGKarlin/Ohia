import Foundation
import CoreGraphics
import Observation
import SwiftUI

/// Elapsed-time spine for the send-to-Composer dispatch comet, read the same way
/// by every lens's overlay (so the motion survives ancestor `.animation` and
/// renders identically). Mirrors the floor-based shape of `MessageStatusGesturePhase`.
struct ComposerDispatchPhase: Equatable, Sendable {
    let elapsed: Double

    /// `nonisolated` so it can back `ComposerDispatchCoordinator.begin`'s default
    /// argument without a main-actor-isolation warning — it is a plain Sendable
    /// constant with no actor state.
    nonisolated static let duration: Double = 1.1
    static let flareWindow: Double = 0.20
    static let cometStart: Double = 0.10
    static let cometEnd: Double = 0.80

    /// Registered-beat flare, 0→1→0 across the onset window.
    var flare: Double {
        guard elapsed < Self.flareWindow else { return 0 }
        let t = elapsed / Self.flareWindow
        return sin(min(1, max(0, t)) * .pi)
    }

    /// Comet travel progress 0→1 across `[cometStart, cometEnd]`, eased in-and-out
    /// (smoothstep) so it glides off the node instead of bursting away.
    var comet: Double {
        let t = (elapsed - Self.cometStart) / (Self.cometEnd - Self.cometStart)
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    /// Comet opacity envelope — fades over the last stretch of travel.
    var cometFade: Double {
        let t = (elapsed - (Self.cometEnd - 0.2)) / 0.25
        return 1 - min(1, max(0, t))
    }

    var isComplete: Bool { elapsed > Self.duration }
}

/// Shared by the card renderer, its retirement/reader transition, and the
/// Composer opener. Start playback at the first rendered frame so mounting
/// cannot consume the animation. Then preserve real elapsed-time pacing:
/// capping progress per frame stretches the motion on slower renderers.
/// Completion still requires a rendered final frame and presentation removal.
@MainActor
final class ComposerCardDeparture: Equatable {
    nonisolated static func == (lhs: ComposerCardDeparture, rhs: ComposerCardDeparture) -> Bool {
        lhs === rhs
    }

    let floor: Double
    private(set) var sourceMessageIDs: Set<UUID>
    private static var visibleSources: [UUID: Set<UUID>] = [:]
    private let createdAt: Date
    private var renderers: Set<UUID> = []
    private var presentations: Set<UUID> = []
    private var lastFrame: Date?
    private var hasMounted = false
    private(set) var elapsed: Double = 0
    private(set) var motionComplete = false
    var presentationComplete: Bool { motionComplete && presentations.isEmpty }

    init(floor: Double, sourceMessageIDs: Set<UUID> = [], now: Date = .now) {
        self.floor = floor
        self.sourceMessageIDs = sourceMessageIDs
        self.createdAt = now
    }

    static func setSource(_ surface: UUID, messageIDs: Set<UUID>, visible: Bool) {
        visibleSources[surface] = visible ? messageIDs : nil
    }

    func addSource(_ messageID: UUID) { sourceMessageIDs.insert(messageID) }

    func mount(_ renderer: UUID) {
        hasMounted = true
        renderers.insert(renderer)
    }
    func unmount(_ renderer: UUID) { renderers.remove(renderer) }

    func supersedeBeforeMount() {
        if !hasMounted { motionComplete = true }
    }

    func phase(at date: Date) -> MessageStatusGesturePhase {
        if motionComplete, let lastFrame {
            return MessageStatusGesturePhase(elapsed: floor + max(0.001, date.timeIntervalSince(lastFrame)), floor: floor)
        }
        let step = lastFrame.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return MessageStatusGesturePhase(elapsed: min(floor, elapsed + step), floor: floor)
    }

    func didRender(at date: Date, elapsed renderedElapsed: Double) {
        guard !motionComplete, lastFrame.map({ date > $0 }) ?? true else { return }
        lastFrame = date
        elapsed = max(elapsed, renderedElapsed)
        motionComplete = elapsed >= floor
    }

    /// Each owning surface releases its lease from SwiftUI's `.removed`
    /// completion, not when it merely starts fading or removes its model row.
    func retainPresentation() -> UUID {
        let id = UUID()
        presentations.insert(id)
        return id
    }

    func releasePresentation(_ id: UUID) { presentations.remove(id) }

    func waitForMotion() async throws {
        while !motionComplete {
            try Task.checkCancellation()
            // Off-screen bulk members and navigation away have no visible
            // animation to await. A mounted renderer never takes this path.
            let sourceVisible = Self.visibleSources.values.contains { !$0.isDisjoint(with: sourceMessageIDs) }
            if renderers.isEmpty, (hasMounted || !sourceVisible), Date().timeIntervalSince(createdAt) >= floor {
                motionComplete = true
                break
            }
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    func waitForPresentation() async throws {
        try await waitForMotion()
        while !presentationComplete {
            try await Task.sleep(for: .milliseconds(16))
        }
        try Task.checkCancellation()
    }
}

/// A one-shot "dispatch comet" fired when a message is queued into the Composer.
/// Keyed by message id; each lens's overlay reads the active dispatch and draws
/// the comet from the message's node along `direction` (toward the Composer
/// window). One-shot: cleared when its motion completes.
///
/// `@MainActor` because it is written by main-actor action sinks and read by
/// SwiftUI overlays. Multiple ids can dispatch at once (a bulk send).
@Observable @MainActor
final class ComposerDispatchCoordinator {
    struct Dispatch: Equatable {
        /// Monotonic token: a re-dispatch of the same id bumps it, so a stale
        /// clear task (from the prior dispatch) no-ops instead of nuking the
        /// newer comet mid-flight.
        let generation: Int
        /// When the comet fired (flare + travel share one clock).
        let start: Date
        /// Unit direction in view space (y-down), toward the Composer window.
        let direction: CGVector
        /// The comet's colour — the sent message's account colour, resolved at
        /// dispatch time. Per-dispatch because a bulk send can span accounts, so
        /// each message's comet carries its own account hue.
        let tint: Color
    }

    private(set) var dispatches: [UUID: Dispatch] = [:]
    private var generationCounter = 0
    @ObservationIgnored private var pendingOpen: Task<Void, Never>?
    @ObservationIgnored private var cardDepartures: [ComposerCardDeparture] = []

    func dispatch(for id: UUID) -> Dispatch? { dispatches[id] }

    /// Fire a one-shot dispatch comet for `id`, aimed at the Composer window's
    /// current-best position, coloured `tint` (the sent message's account
    /// colour). `duration` is how long the comet plays before the entry clears —
    /// the caller passes the Timeline loop's longer span when the Timeline lens
    /// is active, and the default straight-comet span otherwise.
    func begin(
        _ id: UUID,
        now: Date = .now,
        duration: Double = ComposerDispatchPhase.duration,
        tint: Color,
        cardDeparture: ComposerCardDeparture? = nil
    ) {
        pendingOpen?.cancel()
        pendingOpen = nil
        cardDepartures.removeAll { $0.presentationComplete }
        for old in cardDepartures where old !== cardDeparture && old.sourceMessageIDs.contains(id) {
            old.supersedeBeforeMount()
        }
        if let cardDeparture, !cardDepartures.contains(cardDeparture) { cardDepartures.append(cardDeparture) }
        generationCounter += 1
        let generation = generationCounter
        dispatches[id] = Dispatch(
            generation: generation,
            start: now,
            direction: ComposerDispatchHeading.resolve(),
            tint: tint
        )
        scheduleClear(id, generation: generation, duration: duration)
    }

    func clearAll() {
        pendingOpen?.cancel()
        pendingOpen = nil
        generationCounter += 1
        cardDepartures.removeAll()
        dispatches.removeAll()
    }

    /// One owned opening request. A newer send (including a quiet send) cancels
    /// the older request, and a bulk send waits for every departure it started.
    func openAfterDepartures(_ open: @escaping @MainActor () -> Void) {
        pendingOpen?.cancel()
        let generation = generationCounter
        let departures = cardDepartures
        pendingOpen = Task { @MainActor [weak self] in
            do {
                for departure in departures { try await departure.waitForPresentation() }
                while let self, !self.dispatches.isEmpty {
                    try await Task.sleep(for: .milliseconds(16))
                }
                try Task.checkCancellation()
            } catch { return }
            guard let self, self.generationCounter == generation else { return }
            self.pendingOpen = nil
            self.cardDepartures.removeAll { $0.presentationComplete }
            open()
        }
    }

    /// Clears the dispatch once its comet has played out. The generation guard
    /// means a re-dispatch's newer comet is never cut short by this older timer.
    private func scheduleClear(_ id: UUID, generation: Int, duration: Double) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, self.dispatches[id]?.generation == generation else { return }
            self.dispatches[id] = nil
        }
    }
}
