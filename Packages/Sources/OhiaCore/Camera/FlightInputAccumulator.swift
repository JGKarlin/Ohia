import Foundation
import simd

/// Pure command-build math for `FlightInputHandler`.
///
/// Given per-frame accumulated gesture deltas (already scaled by the handler)
/// and the current set of pressed keyboard key codes, produces a
/// `CameraCommand`. Most axes are clamped to `[-1, +1]`; W/A/S/D thrust and
/// strafe can extend to `[-wasdBoostFactor, +wasdBoostFactor]` when the caller
/// passes a boost > 1 (shift-held fast travel — see `FlightInputHandler`).
///
/// Kept free of `SwiftUI` / `AppKit` / any actor-bound state so it can be
/// unit-tested without an app test target (mirrors the `CameraMath` /
/// `WarpMath` split used by `CameraController` and `WarpAnimator`).
///
/// macOS virtual key codes (physical-position-based — don't vary with
/// keyboard layout):
/// - 0x00 A, 0x01 S, 0x02 D, 0x0C Q, 0x0D W, 0x0E E
/// - 0x7B left, 0x7C right, 0x7D down, 0x7E up
public func buildCameraCommand(
    yawAccum: Float,
    pitchAccum: Float,
    thrustAccum: Float,
    strafeAccum: Float,
    verticalAccum: Float,
    pressedKeys: Set<UInt16>,
    wasdBoostFactor: Float = 1.0
) -> CameraCommand {
    var thrust = thrustAccum
    var strafe = strafeAccum
    var vert = verticalAccum
    var yaw = yawAccum
    var pitch = pitchAccum

    // W/A/S/D contributions scale with the WASD boost factor (≥ 1) so shift
    // can produce a faster steady-state velocity. Q/E and arrows hold their
    // precise ±1 rate regardless of shift.
    let wasdStep = max(1, wasdBoostFactor)
    if pressedKeys.contains(0x0D) { thrust += wasdStep }   // W
    if pressedKeys.contains(0x01) { thrust -= wasdStep }   // S
    if pressedKeys.contains(0x00) { strafe -= wasdStep }   // A
    if pressedKeys.contains(0x02) { strafe += wasdStep }   // D
    if pressedKeys.contains(0x0C) { vert -= 1 }            // Q
    if pressedKeys.contains(0x0E) { vert += 1 }            // E
    if pressedKeys.contains(0x7E) { pitch -= 1 }           // up arrow
    if pressedKeys.contains(0x7D) { pitch += 1 }           // down arrow
    if pressedKeys.contains(0x7B) { yaw -= 1 }             // left arrow
    if pressedKeys.contains(0x7C) { yaw += 1 }             // right arrow

    // Translation clamps on thrust/strafe expand with the boost so the W/A/S/D
    // contribution survives. Vertical and rotation clamps stay at ±1.
    return CameraCommand(
        thrust: simd_clamp(thrust, -wasdStep, wasdStep),
        strafe: simd_clamp(strafe, -wasdStep, wasdStep),
        verticalTranslate: simd_clamp(vert, -1, 1),
        yawInput: simd_clamp(yaw, -1, 1),
        pitchInput: simd_clamp(pitch, -1, 1),
        rollInput: 0
    )
}
