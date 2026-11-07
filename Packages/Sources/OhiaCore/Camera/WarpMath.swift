import Foundation
import simd

/// Cubic ease-out: 1 - (1-t)³.
/// Fast at the start, slow at the end. At t=0 returns 0; at t=1 returns 1.
public func easeOutCubic(_ t: Float) -> Float {
    let u = 1 - t
    return 1 - u * u * u
}

/// Lock-entry warp progress for camera travel through constellation space.
///
/// Three phases, jointly C² continuous (continuous acceleration across phase
/// transitions) so the camera reads as engaging warp drive, holding cruise,
/// and dropping out of warp without perceptible jolts at the joints:
///   • [0.00, 0.25] — quartic ramp-up: zero velocity AND zero acceleration
///     at t=0; matches cruise velocity (vmax = 4/3) with zero acceleration at
///     t=0.25.
///   • [0.25, 0.75] — linear cruise at constant velocity 4/3.
///   • [0.75, 1.00] — symmetric quartic ramp-down to zero velocity AND zero
///     acceleration at t=1.
///
/// The unique quartic on [0,1] satisfying f(0)=f'(0)=f''(0)=0, f(1)=1,
/// f'(1)=2, f''(1)=0 is f(τ) = 2τ³ − τ⁴. The 1/6 / 5/6 split points fall out
/// of requiring the cruise to reach the same velocity (4/3) and the whole
/// curve to integrate to 1 over t∈[0,1].
public func warpDriveProgress(_ t: Float) -> Float {
    let x = max(0, min(1, t))
    if x <= 0.25 {
        let τ = x * 4
        return (1.0 / 6.0) * (2 * τ * τ * τ - τ * τ * τ * τ)
    }
    if x <= 0.75 {
        return (1.0 / 6.0) + (4.0 / 3.0) * (x - 0.25)
    }
    let σ = (1 - x) * 4
    return 1 - (1.0 / 6.0) * (2 * σ * σ * σ - σ * σ * σ * σ)
}

/// Linear 3D warp travel aligned exactly from point A (`from`) to point B
/// (`to`), with `warpDriveProgress` applied to the distance covered.
///
/// Unlike `warpPosition`, this does not add a screen- or world-fixed arc. It
/// stays on the world-space A-to-B corridor so lock entry feels like moving
/// through the constellation rather than playing a canned overlay animation.
public func alignedWarpPosition(
    progress t: Float,
    from: SIMD3<Float>,
    to: SIMD3<Float>
) -> SIMD3<Float> {
    from + (to - from) * warpDriveProgress(t)
}

/// Quadratic Bezier from `from` to `to` with a single control point lifted in +Y.
///
/// `strength` in [0, 1] controls how high the path arcs above the direct line:
/// 0 = straight line, 1 = control point lifted by half the segment length.
/// The eased progress (see `easeOutCubic`) is applied to the Bezier parameter,
/// so motion starts fast and settles into the target.
///
/// At t=0 this returns exactly `from`; at t=1 it returns exactly `to`.
public func warpPosition(
    progress t: Float,
    from: SIMD3<Float>,
    to: SIMD3<Float>,
    strength: Float
) -> SIMD3<Float> {
    let eased = easeOutCubic(t)
    let dist = simd_distance(from, to)
    let lift = SIMD3<Float>(0, strength * dist * 0.5, 0)
    let ctrl = (from + to) * 0.5 + lift
    let u = 1 - eased
    return u * u * from + 2 * u * eased * ctrl + eased * eased * to
}
