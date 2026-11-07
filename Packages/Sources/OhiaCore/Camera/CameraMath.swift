import Foundation
import simd

/// Internal state the camera integrator mutates. Separated from any renderer
/// transform so the flight math is unit-testable.
///
/// 5-DOF default. Roll remains in the state so older camera snapshots and
/// projection math can preserve it, but the app no longer exposes roll as a
/// primary navigation control.
public struct CameraState: Sendable {
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>        // world-space linear velocity
    public var yaw: Float                    // radians; rotation about world Y axis
    public var pitch: Float                  // radians; rotation about local X axis
    public var yawRate: Float
    public var pitchRate: Float
    public var roll: Float                   // radians; rotation about camera forward axis
    public var rollRate: Float

    public init(
        position: SIMD3<Float>,
        velocity: SIMD3<Float>,
        yaw: Float,
        pitch: Float,
        yawRate: Float,
        pitchRate: Float,
        roll: Float = 0,
        rollRate: Float = 0
    ) {
        self.position = position
        self.velocity = velocity
        self.yaw = yaw
        self.pitch = pitch
        self.yawRate = yawRate
        self.pitchRate = pitchRate
        self.roll = roll
        self.rollRate = rollRate
    }

    public static let identity = CameraState(
        position: SIMD3<Float>(0, 0, 2),     // start slightly outside the unit cube
        velocity: .zero, yaw: 0, pitch: 0,
        yawRate: 0, pitchRate: 0,
        roll: 0, rollRate: 0
    )
}

/// Per-frame input from `FlightInputHandler`. Most fields are normalized to
/// `[-1, +1]`; `thrust` and `strafe` may extend up to ±N when shift-boosted
/// fast travel is active (see `buildCameraCommand(wasdBoostFactor:)`), in
/// which case the integrator's velocity cap scales to match.
public struct CameraCommand: Sendable {
    public var thrust: Float            // forward (+) / back (-)
    public var strafe: Float            // right (+) / left (-)
    public var verticalTranslate: Float // up (+) / down (-)
    public var yawInput: Float          // right (+) / left (-)
    public var pitchInput: Float        // down (+) / up (-)
    public var rollInput: Float         // clockwise (+) / counter-clockwise (-) from user's POV

    public init(
        thrust: Float,
        strafe: Float,
        verticalTranslate: Float,
        yawInput: Float,
        pitchInput: Float,
        rollInput: Float = 0
    ) {
        self.thrust = thrust
        self.strafe = strafe
        self.verticalTranslate = verticalTranslate
        self.yawInput = yawInput
        self.pitchInput = pitchInput
        self.rollInput = rollInput
    }

    public static let zero = CameraCommand(
        thrust: 0, strafe: 0, verticalTranslate: 0, yawInput: 0, pitchInput: 0, rollInput: 0
    )
}

/// Pure integrator — takes state + command + dt, returns new state.
///
/// Uses semi-implicit Euler for velocity → position and rate → angle,
/// with per-frame exponential damping on both linear and angular velocity.
/// Damping is parameterized by a time constant τ: after τ seconds of zero
/// input, velocity decays to `1/e` (~0.368) of its original magnitude.
public func integrateCamera(
    _ s: CameraState,
    command c: CameraCommand,
    dt: Float,
    transDampingTau: Float = 0.5,   // exponential damping time constant (s) for translation
    rotDampingTau: Float = 0.8,     // ditto for rotation
    thrustAccel: Float = 1.0,       // m/s² per unit input
    yawAccel: Float = 2.0,          // rad/s² per unit input
    pitchAccel: Float = 2.0,
    rollAccel: Float = 2.0
) -> CameraState {
    // Build forward and right vectors from yaw/pitch.
    // Convention: camera looks down -Z at yaw=0, pitch=0; yaw rotates about world +Y.
    let cy = cos(s.yaw), sy = sin(s.yaw)
    let cp = cos(s.pitch), sp = sin(s.pitch)
    let forward = SIMD3<Float>(sy * cp, -sp, -cy * cp)
    let right = SIMD3<Float>(cy, 0, sy)
    let up = SIMD3<Float>(0, 1, 0)

    // Linear acceleration in world space
    let accel = forward * (c.thrust * thrustAccel)
              + right   * (c.strafe * thrustAccel)
              + up      * (c.verticalTranslate * thrustAccel)

    // Integrate velocity + damping
    var v = s.velocity + accel * dt
    let transDecay = exp(-dt / transDampingTau)
    v *= transDecay

    // Clamp speed. Cap scales with the max translation input so a boosted
    // command (e.g. shift+WASD fast travel at thrust=3) gets a proportionally
    // higher ceiling; default 1.0 input keeps the historical 2 m/s cap.
    let maxAxisInput = max(abs(c.thrust), abs(c.strafe), abs(c.verticalTranslate))
    let velocityCap: Float = 2.0 * max(1.0, maxAxisInput)
    let vmag = simd_length(v)
    if vmag > velocityCap { v *= (velocityCap / vmag) }

    let p = s.position + v * dt

    // Rotation integration
    var yr = s.yawRate + c.yawInput * yawAccel * dt
    var pr = s.pitchRate + c.pitchInput * pitchAccel * dt
    let rotDecay = exp(-dt / rotDampingTau)
    yr *= rotDecay; pr *= rotDecay

    let yaw = s.yaw + yr * dt
    var pitch = s.pitch + pr * dt
    // Clamp pitch to avoid gimbal flip
    pitch = max(-1.5, min(1.5, pitch))

    // Roll integration
    var rr = s.rollRate + c.rollInput * rollAccel * dt
    rr *= rotDecay
    let roll = s.roll + rr * dt

    return CameraState(
        position: p,
        velocity: v,
        yaw: yaw,
        pitch: pitch,
        yawRate: yr,
        pitchRate: pr,
        roll: roll,
        rollRate: rr
    )
}

/// Moves the camera around an anchor while keeping that anchor centered.
///
/// `yawDelta` rotates around world-up. `pitchDelta` raises/lowers the camera
/// on the orbit sphere and is clamped before it can flip over the poles.
/// The returned state is settled, with velocity and angular rates cleared,
/// because an orbit action is direct manipulation rather than inertial flight.
public func orbitCamera(
    _ s: CameraState,
    around anchor: SIMD3<Float>,
    yawDelta: Float,
    pitchDelta: Float,
    minDistance: Float = 0.05,
    minElevation: Float = -1.35,
    maxElevation: Float = 1.35
) -> CameraState {
    var offset = s.position - anchor
    var distance = simd_length(offset)
    if distance < minDistance {
        distance = minDistance
        offset = SIMD3<Float>(0, 0, minDistance)
    }

    let horizontalDistance = simd_length(SIMD2<Float>(offset.x, offset.z))
    var azimuth = atan2(offset.x, offset.z)
    var elevation = atan2(offset.y, horizontalDistance)
    azimuth += yawDelta
    elevation = max(minElevation, min(maxElevation, elevation + pitchDelta))

    let cosElevation = cos(elevation)
    let newOffset = SIMD3<Float>(
        sin(azimuth) * cosElevation * distance,
        sin(elevation) * distance,
        cos(azimuth) * cosElevation * distance
    )
    let position = anchor + newOffset
    let lookDirection = simd_normalize(anchor - position)

    return CameraState(
        position: position,
        velocity: .zero,
        yaw: atan2(-lookDirection.x, -lookDirection.z),
        pitch: asin(lookDirection.y),
        yawRate: 0,
        pitchRate: 0,
        roll: 0,
        rollRate: 0
    )
}
