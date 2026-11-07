import Foundation

/// Pure state machine for the People solar system's hover-damped orbital
/// motion. Wall-clock time is injected so the model is fully deterministic
/// and unit-testable; the app-side controller feeds it real time and
/// hover-state transitions.
///
/// Behavior contract (agreed interaction design, revised 2026-07-04 from
/// the earlier pointer-movement grammar):
///   * No body hovered → planets orbit at full speed (multiplier 1).
///     General pointer movement, drags, and scrolls do NOT damp motion.
///   * While the cursor rests on a hoverable body (email node, planet,
///     ring satellite, the sun), speed eases gracefully toward zero —
///     a sustained hover reaches a visual stop in ~1.8 s.
///   * When hover leaves, the system holds for a short grace
///     (`resumeGraceAfterHoverExit`) so sweeping across adjacent bodies
///     doesn't flutter, then ramps gently back to full speed over
///     `resumeRampDuration`.
///   * A freeze (locked portrait open, programmatic camera flight,
///     reduce-motion) pins speed at zero with a fast snap; unfreezing
///     resumes through the same grace-then-ramp path.
///
/// The orbital `clock` integrates `speed` over wall time, so a stopped
/// system holds its pose exactly and resuming continues from that pose.
public struct PeopleOrbitalMotionModel: Sendable, Equatable {
    /// Exponential decay time constant while a body is hovered. τ = 0.55 s
    /// ⇒ speed falls to ~4% after 1.8 s of sustained hover — a graceful
    /// stop that reads as the system settling around the user's attention,
    /// not a snap.
    public static let hoverDecayTau: Double = 0.55
    /// Fast decay for hard freezes (lock, flight, reduce-motion) — those
    /// want the field settled quickly, not a lingering drift.
    public static let holdDecayTau: Double = 0.10
    /// Grace after hover leaves a body before motion may resume, so a
    /// sweep across adjacent bodies reads as one continuous hold.
    public static let resumeGraceAfterHoverExit: TimeInterval = 0.4
    /// Duration of the eased ramp back to full speed.
    public static let resumeRampDuration: TimeInterval = 2.5
    /// Below this multiplier the system counts as visually stopped.
    public static let restingSpeedEpsilon: Float = 0.0005

    /// Accumulated orbital seconds (the `t` fed to `PersonOrbitMath`).
    public private(set) var clock: TimeInterval
    /// Current speed multiplier in [0, 1].
    public private(set) var speed: Float
    /// Wall-clock timestamp of the last `advance` call.
    public private(set) var lastAdvanceTime: TimeInterval
    /// Cursor currently resting on a hoverable body — graceful stop.
    public private(set) var hoverEngaged: Bool
    /// Lock/flight/reduce-motion freeze — hard hold, resume ineligible.
    public private(set) var frozen: Bool
    /// Wall time at which the system becomes eligible to ramp back up
    /// (hover release or unfreeze + grace), or `-.infinity` when no
    /// release has occurred.
    public private(set) var resumeEligibleAt: TimeInterval
    /// Wall-clock time the current resume ramp started, or nil.
    private var resumeRampStart: TimeInterval?

    public init(startTime: TimeInterval = 0, initialSpeed: Float = 1) {
        clock = 0
        speed = max(0, min(1, initialSpeed))
        lastAdvanceTime = startTime
        hoverEngaged = false
        frozen = false
        resumeEligibleAt = -.infinity
        resumeRampStart = nil
    }

    /// Record a hover-state transition at wall time `now`. Engaging
    /// cancels any pending resume; releasing starts the grace window.
    public mutating func setHoverEngaged(_ engaged: Bool, at now: TimeInterval) {
        guard hoverEngaged != engaged else { return }
        hoverEngaged = engaged
        resumeRampStart = nil
        if !engaged {
            resumeEligibleAt = now + Self.resumeGraceAfterHoverExit
        }
    }

    /// Record a freeze-state transition at wall time `now`. Unfreezing
    /// starts the same grace-then-ramp path as a hover release (unless a
    /// hover is still engaged, which then governs).
    public mutating func setFrozen(_ newFrozen: Bool, at now: TimeInterval) {
        guard frozen != newFrozen else { return }
        frozen = newFrozen
        resumeRampStart = nil
        if !newFrozen && !hoverEngaged {
            resumeEligibleAt = now + Self.resumeGraceAfterHoverExit
        }
    }

    /// Whether the display needs continuous frames right now: either the
    /// system is visibly moving, or a resume ramp is in progress.
    public var isAnimating: Bool {
        if frozen || hoverEngaged { return speed > Self.restingSpeedEpsilon }
        return speed > Self.restingSpeedEpsilon || resumeRampStart != nil
    }

    /// When the model is fully at rest but eligible to resume, the wall
    /// time at which the resume ramp will begin (so the controller can
    /// schedule a wake for a paused view). Nil when frozen, hovered,
    /// already moving, or already ramping.
    public func nextResumeEligibleTime() -> TimeInterval? {
        guard !frozen, !hoverEngaged,
              speed <= Self.restingSpeedEpsilon,
              resumeRampStart == nil,
              resumeEligibleAt.isFinite else {
            return nil
        }
        return resumeEligibleAt
    }

    /// Advance to wall time `now`, integrating the orbital clock with the
    /// evolving speed. Returns the new (clock, speed) pair.
    @discardableResult
    public mutating func advance(to now: TimeInterval) -> (clock: TimeInterval, speed: Float) {
        let dt = max(0, now - lastAdvanceTime)
        lastAdvanceTime = now
        guard dt > 0 else { return (clock, speed) }

        let speedBefore = speed

        if frozen || hoverEngaged {
            // Freeze snaps fast; hover settles gracefully. Freeze wins
            // when both apply — a locked portrait wants a settled field.
            resumeRampStart = nil
            let tau = frozen ? Self.holdDecayTau : Self.hoverDecayTau
            speed *= Float(exp(-dt / tau))
            if speed < Self.restingSpeedEpsilon { speed = 0 }
        } else if speed < 1 {
            if now >= resumeEligibleAt {
                // Grace elapsed: eased ramp back to full speed.
                let rampStart: TimeInterval
                if let existing = resumeRampStart {
                    rampStart = existing
                } else {
                    // Back-date the ramp start to the moment the grace
                    // elapsed so a late advance (paused view that woke up
                    // on a timer) doesn't stretch the ramp; clamp to "now"
                    // for monotonicity.
                    rampStart = min(now, resumeEligibleAt.isFinite ? resumeEligibleAt : now)
                    resumeRampStart = rampStart
                }
                let rampProgress = min(1, max(0, (now - rampStart) / Self.resumeRampDuration))
                // smoothstep for a gentle start and landing.
                let eased = Float(rampProgress * rampProgress * (3 - 2 * rampProgress))
                // Ramp from the speed at ramp start toward 1. Track the
                // origin implicitly: eased blending against the *current*
                // speed is monotone and lands exactly at 1.
                speed = max(speed, eased)
                if rampProgress >= 1 {
                    speed = 1
                    resumeRampStart = nil
                }
            }
            // Inside the grace window: hold whatever speed remains, so a
            // brief sweep between bodies neither stops harder nor resumes.
        } else {
            resumeRampStart = nil
        }

        // Trapezoidal integration keeps the pose continuous through speed
        // changes (no clock jump when a decel frame is long).
        clock += dt * Double((speedBefore + speed) * 0.5)
        return (clock, speed)
    }
}
