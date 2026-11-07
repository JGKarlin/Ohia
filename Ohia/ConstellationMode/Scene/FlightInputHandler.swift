import SwiftUI
import AppKit
import Combine
import simd
import OhiaCore

/// Main-actor-bound state wrapper that feeds `CameraController`.
///
/// SwiftUI gestures and key events push deltas / key-state into this handler;
/// the Metal view frame callback pulls a `CameraCommand` once per frame via
/// `consumeCommand()`. The command-build math itself lives in
/// `OhiaCore.buildCameraCommand` so it can be unit-tested without importing
/// SwiftUI/AppKit — this class owns only the stateful buffers + pressed-key
/// set and the gesture/keyboard entry points.
///
/// Conventions for accumulated inputs:
/// - Rotation deltas are scaled (`0.005` per pixel-ish unit) — typical
///   drag gestures yield yaw/pitch ≤ 1 after a single frame.
/// - Thrust/strafe/vertical drag deltas are scaled (`0.5`) — a single
///   large drag gesture can saturate at ±1 after clamping.
/// - Orbit deltas are angular radians applied directly around the current
///   scene anchor by `CameraController` after the inertial flight integrator.
/// - Pressed keyboard keys contribute a steady ±1 per axis while held.
///
/// After each `consumeCommand()` call the gesture accumulators are reset,
/// but the pressed-key set is retained until `keyUp` fires. This matches the
/// Task 10 spec in `docs/superpowers/plans/2026-04-23-ohia-constellation-mode-phase1.md`.
///
/// **Aperture is a separate side-channel.** Pinch and `-`/`=` events feed
/// `apertureAccum` via `handleMagnify` / `handleApertureKeyDown` and are
/// drained by `consumeApertureDelta()` — NOT by `consumeCommand()`. Both
/// consumers must be called once per frame. Aperture values flow into
/// `ConstellationState.aperture`, not into `CameraCommand`, because they
/// don't drive the camera integrator.
@MainActor
public final class FlightInputHandler: ObservableObject {

    /// Last command returned by `consumeCommand()`. NOT `@Published`:
    /// the Metal view frame callback calls `consumeCommand()` every frame,
    /// and publishing from within a view update triggers SwiftUI's
    /// "Publishing changes from within view updates is not allowed"
    /// runtime warning. Nothing reads this reactively — it's kept as a
    /// plain property for debugging / inspection.
    public private(set) var currentCommand: CameraCommand = .zero

    // Per-frame gesture accumulators, reset after consumption.
    private var yawAccum: Float = 0
    private var pitchAccum: Float = 0
    private var thrustAccum: Float = 0
    private var strafeAccum: Float = 0
    private var verticalAccum: Float = 0
    private var orbitYawAccum: Float = 0
    private var orbitPitchAccum: Float = 0

    // Held keyboard state (macOS virtual key codes).
    private var pressedKeys: Set<UInt16> = []
    private var orbitLeftKeyHeld = false
    private var orbitRightKeyHeld = false

    // MARK: - Aperture input (Phase 3)

    /// Accumulated aperture delta, reset after `consumeApertureDelta()`.
    private var apertureAccum: Float = 0

    /// Last observed magnification value from the active MagnifyGesture.
    /// MagnifyGesture emits cumulative scale relative to gesture start
    /// (not per-frame deltas), so we diff against the previous value.
    private var lastMagnification: CGFloat = 1.0

    /// Called from `.onChanged` on MagnifyGesture. Accumulates a log-scaled
    /// aperture delta proportional to the ratio between the previous and
    /// current magnification values.
    public func handleMagnify(_ magnification: CGFloat) {
        let delta = ApertureAccumulator.magnifyDelta(from: lastMagnification, to: magnification)
        apertureAccum += delta
        lastMagnification = magnification
    }

    /// Called from the MagnifyGesture end path (`.onEnded` or gesture
    /// cancellation). Resets the baseline so the next gesture starts fresh.
    public func resetMagnifyBaseline() {
        lastMagnification = 1.0
    }

    /// Handle a one-shot aperture key (`-` or `=`). Returns true if the
    /// key was consumed (so the caller can skip passing it to the
    /// generic `keyDown(_:)` path).
    @discardableResult
    public func handleApertureKeyDown(_ keyCode: UInt16) -> Bool {
        guard let step = ApertureAccumulator.keyboardStep(for: keyCode) else { return false }
        apertureAccum += step
        return true
    }

    /// Consume the accumulated aperture delta. Called once per frame from the
    /// Metal view frame callback; the returned scalar is applied to
    /// `ConstellationState.aperture`. Resets `apertureAccum` to zero.
    ///
    /// Note: aperture keys are one-shot — `handleApertureKeyDown` appends a
    /// fixed step once per press, with no key-up tracking. Holding `-` down
    /// does NOT continuously tighten the aperture.
    public func consumeApertureDelta() -> Float {
        let delta = apertureAccum
        apertureAccum = 0
        return delta
    }

    public init() {}

    public var hasActiveInput: Bool {
        !pressedKeys.isEmpty
            || yawAccum != 0
            || pitchAccum != 0
            || thrustAccum != 0
            || strafeAccum != 0
            || verticalAccum != 0
            || orbitYawAccum != 0
            || orbitPitchAccum != 0
            || orbitLeftKeyHeld
            || orbitRightKeyHeld
            || apertureAccum != 0
    }

    public func clearBufferedInput() {
        yawAccum = 0
        pitchAccum = 0
        thrustAccum = 0
        strafeAccum = 0
        verticalAccum = 0
        orbitYawAccum = 0
        orbitPitchAccum = 0
        apertureAccum = 0
        lastMagnification = 1.0
        pressedKeys.removeAll()
        orbitLeftKeyHeld = false
        orbitRightKeyHeld = false
        currentCommand = .zero
    }

    // MARK: - Per-frame consumption

    /// Call each frame (from the Metal view frame callback). Builds the
    /// command from current accumulators + pressed keys, clears the gesture
    /// accumulators, and returns the command for the integrator.
    ///
    /// Shift state is sampled live from `NSEvent.modifierFlags` rather than
    /// tracked alongside `pressedKeys`. macOS only delivers `keyDown` once
    /// per physical press, so a user who taps shift mid-flight (without
    /// re-pressing WASD) wouldn't otherwise be observed; sampling at consume
    /// time also means releasing shift drops back to precise speed on the
    /// very next frame.
    public func consumeCommand() -> CameraCommand {
        let shiftHeld = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)
        let wasdBoost: Float = shiftHeld ? 3.0 : 1.0
        let cmd = buildCameraCommand(
            yawAccum: yawAccum,
            pitchAccum: pitchAccum,
            thrustAccum: thrustAccum,
            strafeAccum: strafeAccum,
            verticalAccum: verticalAccum,
            pressedKeys: pressedKeys,
            wasdBoostFactor: wasdBoost
        )
        currentCommand = cmd
        yawAccum = 0
        pitchAccum = 0
        thrustAccum = 0
        strafeAccum = 0
        verticalAccum = 0
        return cmd
    }

    /// Consume direct orbit motion. Scroll contributes one-shot angular
    /// deltas; held `<` / `>` keys contribute a smooth per-frame angular rate.
    public func consumeOrbitDelta(dt: Float) -> (yaw: Float, pitch: Float) {
        let keyOrbitSpeed: Float = 0.9
        var yaw = orbitYawAccum
        let pitch = orbitPitchAccum
        if orbitLeftKeyHeld {
            yaw -= keyOrbitSpeed * dt
        }
        if orbitRightKeyHeld {
            yaw += keyOrbitSpeed * dt
        }
        orbitYawAccum = 0
        orbitPitchAccum = 0
        return (yaw, pitch)
    }

    // MARK: - Gesture entry points

    /// Mouse / trackpad drag delta mapped to yaw (x) + pitch (y) rotation.
    public func handleRotateDelta(_ delta: CGSize) {
        let scale: Float = 0.005
        yawAccum += Float(delta.width) * scale
        pitchAccum += Float(delta.height) * scale
    }

    /// Forward/back drag (e.g. vertical mouse-wheel or pinch).
    public func handleThrustDelta(_ delta: CGFloat) {
        thrustAccum += Float(delta) * 0.5
    }

    /// Scroll-wheel / 2-finger-scroll forwarding. `dy` is AppKit's
    /// `NSEvent.scrollingDeltaY` already inverted for "scroll up = forward."
    /// Scaled by `3/4` so a single mouse tick / trackpad swipe travels far
    /// enough through the scene to feel responsive — the older `1/4`
    /// mapping read as too slow at typical viewing distances.
    public func handleScrollThrustDelta(_ dy: CGFloat) {
        handleThrustDelta(dy * 3 / 4)
    }

    /// Shift-scroll panning. Trackpads can pan in two axes; mouse wheels
    /// usually report only vertical ticks, so those are treated as sideways
    /// truck movement when the event is not precise.
    public func handleScrollPanDelta(_ delta: CGSize, isPrecise: Bool) {
        let scale: CGFloat = 3 / 4
        if isPrecise {
            handleStrafeDelta(delta.width * scale)
            handleVerticalDelta(delta.height * scale)
        } else {
            let sideways = abs(delta.width) > 0.001 ? delta.width : delta.height
            handleStrafeDelta(sideways * scale)
        }
    }

    /// Option-scroll orbit. Trackpads use two axes when available; mouse
    /// wheels map their single vertical axis to horizontal orbit so the
    /// movement is still useful with a one-axis wheel.
    public func handleScrollOrbitDelta(_ delta: CGSize, isPrecise: Bool) {
        let scale: Float = 0.012
        if isPrecise {
            orbitYawAccum += Float(delta.width) * scale
            orbitPitchAccum += Float(delta.height) * scale
        } else {
            let yawDelta = abs(delta.width) > 0.001 ? delta.width : delta.height
            orbitYawAccum += Float(yawDelta) * scale
        }
    }

    /// Left/right strafe drag.
    public func handleStrafeDelta(_ delta: CGFloat) {
        strafeAccum += Float(delta) * 0.5
    }

    /// Up/down translation drag.
    public func handleVerticalDelta(_ delta: CGFloat) {
        verticalAccum += Float(delta) * 0.5
    }

    // MARK: - Keyboard

    /// Record a key-down event by macOS virtual key code.
    public func keyDown(_ code: UInt16) {
        pressedKeys.insert(code)
    }

    /// Record a key-up event by macOS virtual key code.
    public func keyUp(_ code: UInt16) {
        pressedKeys.remove(code)
    }

    public func orbitKeyDown(_ direction: OrbitKeyDirection) {
        switch direction {
        case .left:
            orbitLeftKeyHeld = true
        case .right:
            orbitRightKeyHeld = true
        }
    }

    public func orbitKeyUp(_ code: UInt16) {
        switch code {
        case OrbitKeyDirection.left.keyCode:
            orbitLeftKeyHeld = false
        case OrbitKeyDirection.right.keyCode:
            orbitRightKeyHeld = false
        default:
            break
        }
    }

    public enum OrbitKeyDirection {
        case left
        case right

        var keyCode: UInt16 {
            switch self {
            case .left: 0x2B   // comma key, shifted as <
            case .right: 0x2F  // period key, shifted as >
            }
        }
    }
}
