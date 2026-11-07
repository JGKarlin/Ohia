import Foundation
import simd

public enum ScreenProjection {

    /// Projects a world-space point to a screen-space CGPoint using the camera
    /// state's yaw+pitch orientation and a vertical FOV. Returns nil when the
    /// point is behind the camera (positive Z in camera space after the
    /// view matrix) or at z=0 where perspective divide is undefined.
    public static func project(
        world: SIMD3<Float>,
        camera: CameraState,
        viewSize: CGSize,
        fovYRadians: Float
    ) -> CGPoint? {
        let view = viewMatrix(for: camera)
        let p4 = view * SIMD4<Float>(world.x, world.y, world.z, 1)
        // Camera looks down -Z, so visible points have negative z in camera space.
        guard p4.z < -1e-4 else { return nil }

        let aspect = Float(viewSize.width / max(viewSize.height, 1))
        let f = 1.0 / tanf(fovYRadians * 0.5)
        let ndcX = (p4.x * f / aspect) / -p4.z
        let ndcY = (p4.y * f) / -p4.z

        let sx = (ndcX * 0.5 + 0.5) * Float(viewSize.width)
        // SwiftUI screen y grows downward; NDC y grows upward.
        let sy = (1 - (ndcY * 0.5 + 0.5)) * Float(viewSize.height)
        return CGPoint(x: CGFloat(sx), y: CGFloat(sy))
    }

    /// Picks the closest candidate within `pixelRadius` of `point`. Returns
    /// nil if none qualify. Candidates behind the camera are silently skipped.
    public static func nearest(
        at point: CGPoint,
        candidates: [(id: Int64, world: SIMD3<Float>)],
        camera: CameraState,
        viewSize: CGSize,
        fovYRadians: Float,
        pixelRadius: CGFloat
    ) -> Int64? {
        var best: (id: Int64, dist: CGFloat)? = nil
        for c in candidates {
            guard let screen = project(
                world: c.world,
                camera: camera,
                viewSize: viewSize,
                fovYRadians: fovYRadians
            ) else { continue }
            let dx = screen.x - point.x
            let dy = screen.y - point.y
            let d = sqrt(dx * dx + dy * dy)
            if d <= pixelRadius, (best == nil || d < best!.dist) {
                best = (c.id, d)
            }
        }
        return best?.id
    }

    // MARK: - Helpers

    private static func viewMatrix(for cam: CameraState) -> matrix_float4x4 {
        let qYaw = simd_quatf(angle: cam.yaw, axis: SIMD3(0, 1, 0))
        let qPitch = simd_quatf(angle: cam.pitch, axis: SIMD3(1, 0, 0))
        let qRoll = simd_quatf(angle: cam.roll, axis: SIMD3(0, 0, -1))
        let rotWorld = matrix_float4x4(qYaw * qPitch * qRoll)
        var rotView = rotWorld.transpose
        rotView.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        var trans = matrix_identity_float4x4
        trans.columns.3 = SIMD4<Float>(-cam.position.x, -cam.position.y, -cam.position.z, 1)
        return rotView * trans
    }
}
