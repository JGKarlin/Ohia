import Foundation
import simd
import OhiaCore

/// Main-actor-bound warp driver: given a target position (and optional look-at
/// anchor), animates the `CameraController`'s state along a lifted Bezier arc
/// with a cubic ease-out over a distance-scaled duration.
///
/// The actual curve math lives in `OhiaCore.WarpMath` (`warpPosition`,
/// `easeOutCubic`) so it can be exercised without a renderer. This class
/// owns only the state machine: start/end time, from/to cache, and the
/// `tick(now:)` loop that the Metal view calls each frame.
@MainActor
public final class WarpAnimator {
    public enum Profile {
        case glide
        case lockEntry
        case meaningFocus
    }

    private let cameraController: CameraController
    private var startTime: Date = .distantPast
    private var endTime: Date = .distantPast
    private var from: SIMD3<Float> = .zero
    private var to: SIMD3<Float> = .zero
    private var fromYaw: Float = 0
    private var fromPitch: Float = 0
    private var fromRoll: Float = 0
    private var targetYaw: Float = 0
    private var targetPitch: Float = 0
    private var targetRoll: Float = 0
    private var profile: Profile = .glide

    /// `true` while an engaged warp is still advancing toward its target.
    public private(set) var isWarping: Bool = false

    /// Total duration (in seconds) of the most recently engaged warp.
    /// Callers that want to sequence work around the warp can read this
    /// after `engage(...)` and sleep for that many seconds rather than
    /// hooking `onComplete` (which would race with subsequent engagements).
    public private(set) var currentEngagementDuration: TimeInterval = 0

    /// Fires the moment a new warp is engaged. The Metal view runs with
    /// `isPaused = true; enableSetNeedsDisplay = true`, so its draw loop
    /// only resumes when something calls `setNeedsDisplay`. When `engage`
    /// is invoked from an async Task (e.g. the rank-step orchestrator) the
    /// runloop pass that handled the keystroke has already ended and no
    /// `setNeedsDisplay` would otherwise fire — leaving `isWarping == true`
    /// but the draw loop dormant. Hooking this from the host view's
    /// makeNSView wires the engagement to a `setNeedsDisplay` so the warp
    /// always begins ticking the next frame.
    public var onEngageRequested: (() -> Void)?

    /// Called on the main actor once, at the moment `tick(now:)` observes
    /// progress has reached 1.0.
    public var onComplete: (() -> Void)?

    /// Called every frame while a warp is active. Return `false` to unregister
    /// the progress callback after the current tick. Used by lock entry to
    /// reveal overlay chrome before the camera fully settles.
    public var onProgress: ((Float) -> Bool)?

    public init(cameraController: CameraController) {
        self.cameraController = cameraController
    }

    /// Engage a warp toward `target`. If `lookAt` is provided, the camera's
    /// yaw/pitch is interpolated so the camera is facing that anchor when the
    /// warp settles; otherwise the current orientation is held.
    public func engage(
        to target: SIMD3<Float>,
        lookAt: SIMD3<Float>? = nil,
        profile: Profile = .glide
    ) {
        from = cameraController.state.position
        to = target
        let dist = simd_distance(from, to)
        let duration = switch profile {
        case .glide:
            TimeInterval(max(1.0, min(3.0, dist * 1.0)))
        case .lockEntry:
            TimeInterval(max(0.72, min(1.35, 0.72 + dist * 0.36)))
        case .meaningFocus:
            TimeInterval(max(2.15, min(2.95, 2.15 + dist * 0.22)))
        }
        startTime = Date.now
        endTime = startTime.addingTimeInterval(duration)
        currentEngagementDuration = duration
        isWarping = true
        self.profile = profile
        onComplete = nil
        onProgress = nil

        // Capture orientation at engage time so `tick()` can lerp from a
        // stable baseline. Reading `cameraController.state.{yaw,pitch,roll}`
        // each frame would compose with `snap()`'s writes and turn the lerp
        // into a frame-rate-dependent geometric blend.
        fromYaw = cameraController.state.yaw
        fromPitch = cameraController.state.pitch
        fromRoll = cameraController.state.roll

        if let look = lookAt {
            // Same convention as `CameraMath`: camera looks down -Z at
            // yaw=pitch=0. Match the renderer/projection matrix's quaternion
            // convention so the look-at anchor lands at screen center.
            let dir = simd_normalize(look - target)
            targetYaw = Self.shortestYawTarget(from: fromYaw, to: atan2(-dir.x, -dir.z))
            targetPitch = asin(dir.y)
        } else {
            targetYaw = fromYaw
            targetPitch = fromPitch
        }
        targetRoll = fromRoll
        onEngageRequested?()
    }

    /// Re-express `to` so a linear yaw lerp from `from` sweeps the short
    /// way around. Free flight accumulates unbounded yaw while look-at
    /// targets come from `atan2` in [−π, π]; without the wrap a warp
    /// engaged near the ±π seam (or after a few full free-flight spins)
    /// lerps the long way — up to a ~350° pirouette mid-flight.
    nonisolated static func shortestYawTarget(from: Float, to: Float) -> Float {
        from + atan2f(sinf(to - from), cosf(to - from))
    }

    /// Engage a warp back to an exact camera state. Used when leaving a
    /// selected-node focus view so the broader constellation resumes from the
    /// same vantage point the user had before selection.
    public func engage(to state: CameraState, profile: Profile = .glide) {
        from = cameraController.state.position
        to = state.position
        let dist = simd_distance(from, to)
        let duration = switch profile {
        case .glide:
            TimeInterval(max(0.65, min(2.4, dist * 0.9)))
        case .lockEntry:
            TimeInterval(max(0.72, min(1.35, 0.72 + dist * 0.36)))
        case .meaningFocus:
            TimeInterval(max(2.00, min(2.80, 2.00 + dist * 0.20)))
        }
        startTime = Date.now
        endTime = startTime.addingTimeInterval(duration)
        currentEngagementDuration = duration
        isWarping = true
        self.profile = profile
        onComplete = nil
        onProgress = nil
        fromYaw = cameraController.state.yaw
        fromPitch = cameraController.state.pitch
        fromRoll = cameraController.state.roll
        targetYaw = Self.shortestYawTarget(from: fromYaw, to: state.yaw)
        targetPitch = state.pitch
        targetRoll = state.roll
        onEngageRequested?()
    }

    /// Stop the active warp in place. Used when the user changes spatial
    /// lenses while a lock-entry warp is still in flight; the destination
    /// lens owns the next camera state.
    public func cancel() {
        isWarping = false
        currentEngagementDuration = 0
        onComplete = nil
        onProgress = nil
    }

    /// Advance the warp by reading wall-clock time. Call each frame. Returns
    /// `true` while still warping, `false` after completion (or when no warp
    /// is engaged).
    @discardableResult
    public func tick(now: Date = Date.now) -> Bool {
        guard isWarping else { return false }

        let total = endTime.timeIntervalSince(startTime)
        let elapsed = now.timeIntervalSince(startTime)
        let tFloat = Float(min(1.0, max(0.0, elapsed / total)))

        let pos: SIMD3<Float>
        let easedT: Float
        switch profile {
        case .glide:
            pos = warpPosition(progress: tFloat, from: from, to: to, strength: 0.3)
            easedT = easeOutCubic(tFloat)
        case .lockEntry, .meaningFocus:
            pos = alignedWarpPosition(progress: tFloat, from: from, to: to)
            easedT = warpDriveProgress(tFloat)
        }
        let newYaw = fromYaw * (1 - easedT) + targetYaw * easedT
        let newPitch = fromPitch * (1 - easedT) + targetPitch * easedT
        let newRoll = profile == .lockEntry || profile == .meaningFocus
            ? 0
            : fromRoll * (1 - easedT) + targetRoll * easedT

        cameraController.snap(to: CameraState(
            position: pos,
            velocity: .zero,
            yaw: newYaw,
            pitch: newPitch,
            yawRate: 0,
            pitchRate: 0,
            roll: newRoll,
            rollRate: 0
        ))

        if let progress = onProgress, progress(tFloat) == false {
            onProgress = nil
        }

        if tFloat >= 1.0 {
            isWarping = false
            let completion = onComplete
            onComplete = nil
            onProgress = nil
            completion?()
        }
        return isWarping
    }
}
