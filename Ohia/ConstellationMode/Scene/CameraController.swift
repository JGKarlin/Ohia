import Foundation
import Combine
import simd
import OhiaCore

/// Main-actor-bound wrapper around the pure `integrateCamera` function
/// (see `OhiaCore.CameraMath`). Holds camera state as a plain `var` and
/// exposes imperative camera state for the Custom Metal renderer.
///
/// Deviation: `state` is NOT `@Published`. The renderer update loop
/// writes it every frame via `integrate(...)`; publishing from
/// within a view update triggers SwiftUI's "Publishing changes from
/// within view updates is not allowed" runtime warning and, worse,
/// schedules redundant re-renders. All consumers (`WarpAnimator`,
/// search controller, hit-test context) read `state` imperatively from
/// the frame loop or from one-shot Tasks — none rely on reactive
/// observation. The class remains `ObservableObject` only so SwiftUI
/// still treats `@StateObject` as the identity owner.
///
/// The integrator is a free function in `OhiaCore` so it can be unit-
/// tested without pulling in a renderer or UI layer (see
/// `Packages/Tests/OhiaCoreTests/CameraMathTests.swift`).
@MainActor
public final class CameraController: ObservableObject {

    public var state: CameraState = .identity

    public init() {}

    /// Call each frame from the renderer update loop.
    public func integrate(command: CameraCommand, dt: Float) {
        state = integrateCamera(state, command: command, dt: dt)
    }

    /// Direct orbit around a scene anchor, used by modified scroll and
    /// keyboard orbit controls.
    public func orbit(around anchor: SIMD3<Float>, yawDelta: Float, pitchDelta: Float) {
        state = orbitCamera(state, around: anchor, yawDelta: yawDelta, pitchDelta: pitchDelta)
    }

    /// Set state directly — used by WarpAnimator.
    public func snap(to state: CameraState) {
        self.state = state
    }
}
