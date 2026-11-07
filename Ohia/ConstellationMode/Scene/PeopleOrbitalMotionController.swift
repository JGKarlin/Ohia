import AppKit
import Foundation
import OhiaCore
import QuartzCore

/// Main-actor owner of the People solar system's orbital clock. Wraps the
/// pure `PeopleOrbitalMotionModel` state machine (OhiaCore, unit-tested)
/// with wall-clock feeds, hover-state transitions from the scene's hit
/// testing, the two freeze sources (settled locks from the host view;
/// transient camera flights from the draw loop), system reduce-motion,
/// and a wake callback so a paused MTKView starts drawing again when a
/// hover release's grace window elapses and the resume ramp is due.
///
/// The clock this controller accumulates is the single `t` behind every
/// orbital position in the scene: packet requests stamp it as the orbital
/// epoch (`ConstellationRenderRequest.peopleOrbitalClock`) and the
/// renderer displaces per frame by `position(clock) − position(epoch)`.
/// A frozen clock at packet time therefore means zero displacement and
/// fully settled geometry.
@MainActor
public final class PeopleOrbitalMotionController {
    public init() {}

    /// Fired when the model transitions from rest toward the resume ramp
    /// while the display may be paused — the host requests a redraw so
    /// the draw loop resumes advancing the clock.
    var onWakeNeeded: (() -> Void)?

    private var model = PeopleOrbitalMotionModel(startTime: CACurrentMediaTime())
    /// Settled-lock freeze, owned by the host view's lock lifecycle.
    private var lockFrozen = false
    /// Transient flight freeze (warp animator / source warp), refreshed
    /// by the draw loop each frame.
    private var flightFrozen = false
    private var wakeTask: Task<Void, Never>?

    /// Accumulated orbital seconds — the `t` for `PersonOrbitMath`.
    var clock: TimeInterval { model.clock }
    /// Current speed multiplier in [0, 1].
    var currentSpeed: Float { model.speed }
    /// Whether the display needs continuous frames for orbital motion.
    var isAnimating: Bool { model.isAnimating }

    /// Record whether the cursor is resting on a hoverable body (email
    /// node, planet, ring satellite, the sun) — the sole damping input:
    /// hover eases the system to a stop; release starts the grace window
    /// and then the gentle resume ramp. General pointer movement never
    /// damps motion.
    func setHoverEngaged(_ engaged: Bool) {
        // Transition guard: hover events arrive at pointer-move rate (and
        // the draw loop re-asserts release every non-solar frame); without
        // the guard each no-op call would cancel and recreate the pending
        // wake task at event rate.
        guard model.hoverEngaged != engaged else { return }
        model.setHoverEngaged(engaged, at: CACurrentMediaTime())
        // Reschedule (not merely cancel) the resume wake on release. If
        // the system is fully stopped and the view is paused, the release
        // is the only event that will ever re-arm the wake — without
        // rescheduling, the planets would stay frozen until some unrelated
        // redraw. On engage, any pending wake is stale; a fired wake while
        // held is harmless (advance() keeps the hold), but cancelling is
        // tidier.
        cancelScheduledWake()
        if !engaged {
            scheduleWakeIfNeeded()
        }
    }

    /// Settled-lock freeze — engaged for the whole life of a locked
    /// portrait/overlay, released on exit.
    func setLockFrozen(_ frozen: Bool) {
        guard lockFrozen != frozen else { return }
        lockFrozen = frozen
        applyFreeze()
    }

    /// Transient flight freeze — the draw loop reports whether a warp
    /// animator flight or lock-transition source warp is running.
    func setFlightFrozen(_ frozen: Bool) {
        guard flightFrozen != frozen else { return }
        flightFrozen = frozen
        applyFreeze()
    }

    private func applyFreeze() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.setFrozen(
            lockFrozen || flightFrozen || reduceMotion,
            at: CACurrentMediaTime()
        )
        if !model.frozen {
            cancelScheduledWake()
            scheduleWakeIfNeeded()
        }
    }

    /// Per-frame advance from the draw loop. Returns the orbital clock the
    /// renderer should displace against this frame.
    @discardableResult
    func advance() -> (clock: TimeInterval, speed: Float) {
        // Reduce-motion can change at any time; fold it in every frame so
        // toggling it mid-session takes effect without a restart.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.setFrozen(
            lockFrozen || flightFrozen || reduceMotion,
            at: CACurrentMediaTime()
        )
        let result = model.advance(to: CACurrentMediaTime())
        if !model.isAnimating {
            scheduleWakeIfNeeded()
        }
        return result
    }

    /// Schedule a display wake at the moment the resume ramp becomes due.
    /// No-op when the model is moving, hovered, frozen, or already
    /// scheduled.
    private func scheduleWakeIfNeeded() {
        guard wakeTask == nil,
              let eligibleAt = model.nextResumeEligibleTime() else { return }
        let delay = max(0, eligibleAt - CACurrentMediaTime())
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000) + 20_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.wakeTask = nil
                self.onWakeNeeded?()
            }
        }
    }

    private func cancelScheduledWake() {
        wakeTask?.cancel()
        wakeTask = nil
    }
}
