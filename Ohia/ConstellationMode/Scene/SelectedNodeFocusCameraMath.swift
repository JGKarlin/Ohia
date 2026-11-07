import Foundation
import simd
import OhiaCore

enum SelectedNodeFocusCameraMath {
    static let tanHalfVerticalFOV: Float = 0.57735026
    static let distanceMultiplier: Float = 0.82
    static let distancePadding: Float = 0.05
    static let minDistance: Float = 0.16
    static let maxDistance: Float = 1.05
    static let maxFitRadius: Float = 0.52

    static func cameraDistance(focusRadius: Float) -> Float {
        let fitRadius = min(max(0, focusRadius), maxFitRadius)
        let fitDistance = (fitRadius / tanHalfVerticalFOV) * distanceMultiplier
            + distancePadding
        return min(maxDistance, max(minDistance, fitDistance))
    }

    static func cameraState(
        focusing center: SIMD3<Float>,
        from current: CameraState,
        focusRadius: Float
    ) -> CameraState {
        let distance = cameraDistance(focusRadius: focusRadius)
        let delta = center - current.position
        let viewDirection: SIMD3<Float>
        if simd_length(delta) > 0.001 {
            viewDirection = simd_normalize(delta)
        } else {
            viewDirection = forwardVector(yaw: current.yaw, pitch: current.pitch)
        }
        let position = center - viewDirection * distance
        let lookDirection = simd_normalize(center - position)
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

    private static func forwardVector(yaw: Float, pitch: Float) -> SIMD3<Float> {
        let cy = cos(yaw)
        let sy = sin(yaw)
        let cp = cos(pitch)
        let sp = sin(pitch)
        return SIMD3<Float>(sy * cp, -sp, -cy * cp)
    }
}
