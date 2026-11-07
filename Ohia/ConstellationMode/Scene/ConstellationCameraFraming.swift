import CoreGraphics
import Foundation
import simd
import OhiaCore

enum ConstellationCameraFraming {
    nonisolated static let tanHalfVerticalFOV: Float = 0.57735026

    nonisolated struct LayerProfile: Equatable, Sendable {
        let fill: Float
        let minDistance: Float
        let maxDistance: Float?
        let padding: Float
        let outlierTrimFraction: Float
        /// Multiplier on the fit-everything distance, in (0, 1]. Values
        /// below 1 pull the camera deliberately closer than the framed
        /// corpus strictly needs, accepting minor edge cropping of the
        /// outermost content in exchange for a larger resting view. The
        /// pull is lateral-only: the scaled distance is re-floored by the
        /// corpus depth clearance so nearby geometry never crosses the
        /// camera plane.
        let distanceScale: Float

        init(
            fill: Float,
            minDistance: Float,
            maxDistance: Float? = nil,
            padding: Float,
            outlierTrimFraction: Float,
            distanceScale: Float = 1
        ) {
            self.fill = fill
            self.minDistance = minDistance
            self.maxDistance = maxDistance
            self.padding = padding
            self.outlierTrimFraction = outlierTrimFraction
            self.distanceScale = distanceScale
        }
    }

    nonisolated static func layerProfile(for frame: FrameKey) -> LayerProfile {
        switch frame.spatialLens {
        case .people:
            // No outlier trim: the solar-system layout is hard-bounded by
            // the aphelion cap, and the framing corpus deliberately
            // includes the occupied orbital extent — trimming would cut
            // exactly those extent points and let comets orbit off-frame.
            //
            // The corpus is worst-case (every orbit's aphelion reach), so a
            // fit-everything camera sizes the resting view for the rare
            // moment the outermost body is at full stretch. The high fill
            // plus sub-1 distanceScale instead sit the camera ~30% closer
            // than fit-everything (2026-07-04 decision): the sun-centered
            // system fills the viewport, and an aphelion tip can crop past
            // the edge while a comet is actually out there — a few percent
            // in the ecliptic plane, up to ~9% of viewport height when the
            // galaxy tilt carries that extreme toward the vertical edge.
            // Accepted trade for the larger resting view.
            return LayerProfile(
                fill: 0.95,
                minDistance: 0.36,
                padding: 0.05,
                outlierTrimFraction: 0,
                distanceScale: 0.92
            )
        case .meaning:
            return LayerProfile(
                fill: 0.84,
                minDistance: 0.26,
                padding: 0.07,
                outlierTrimFraction: 0
            )
        // `.timeline` lens no longer mounts the Metal scene (the NLE
        // workspace owns its own viewport). The previous timeline profile
        // is retired; the lens never reaches camera framing.
        case .projects:
            return LayerProfile(
                fill: 0.62,
                minDistance: 0.38,
                padding: 0.18,
                outlierTrimFraction: 0.06
            )
        default:
            return LayerProfile(
                fill: 0.70,
                minDistance: 0.32,
                padding: 0.12,
                outlierTrimFraction: 0.08
            )
        }
    }

    nonisolated static func cameraState(
        fitting positions: [SIMD3<Float>],
        frame: FrameKey,
        viewSize: CGSize
    ) -> CameraState? {
        let profile = layerProfile(for: frame)
        return cameraState(
            fitting: positions,
            viewSize: viewSize,
            fill: profile.fill,
            minDistance: profile.minDistance,
            maxDistance: profile.maxDistance,
            padding: profile.padding,
            outlierTrimFraction: profile.outlierTrimFraction,
            distanceScale: profile.distanceScale
        )
    }

    nonisolated static func cameraState(
        fitting positions: [SIMD3<Float>],
        requiredPositions: [SIMD3<Float>] = [],
        viewSize: CGSize,
        fill: Float,
        minDistance: Float,
        maxDistance: Float? = nil,
        padding: Float = 0.05,
        outlierTrimFraction: Float = 0,
        distanceScale: Float = 1
    ) -> CameraState? {
        let framingPositions = positions.isEmpty ? requiredPositions : positions
        guard viewSize.width > 1,
              viewSize.height > 1,
              framingPositions.isEmpty == false else {
            return nil
        }

        var bounds = bulkBounds(for: framingPositions, outlierTrimFraction: outlierTrimFraction)
        if requiredPositions.isEmpty == false {
            bounds = union(bounds, exactBounds(for: requiredPositions))
        }
        let center = (bounds.min + bounds.max) * 0.5
        let span = bounds.max - bounds.min
        let aspect = Float(viewSize.width / max(viewSize.height, 1))
        let safeFill = max(0.35, min(0.95, fill))
        let safePadding = max(0, padding)
        let tanHalfHorizontalFOV = tanHalfVerticalFOV * max(aspect, 0.001)

        let distanceForWidth = (span.x * 0.5 + safePadding) / (tanHalfHorizontalFOV * safeFill)
        let distanceForHeight = (span.y * 0.5 + safePadding) / (tanHalfVerticalFOV * safeFill)
        let depthClearance = span.z * 0.5 + safePadding
        var distance = max(distanceForWidth, distanceForHeight, depthClearance, minDistance)
        // Closeness pull (see `LayerProfile.distanceScale`): deliberately
        // tighter than fit-everything. Re-floored by depth clearance and the
        // distance floor so the pull only ever crops laterally — it can
        // never push scene geometry across the camera plane.
        let safeDistanceScale = max(0.4, min(1, distanceScale))
        if safeDistanceScale < 1 {
            distance = max(distance * safeDistanceScale, depthClearance, minDistance)
        }
        // `maxDistance` is an absolute cap and clamps last, exactly as it
        // did before the pull existed — it wins over the floors in both the
        // scaled and unscaled paths, keeping the result continuous and
        // monotone in `distanceScale` for a profile that ever combines the
        // two.
        if let maxDistance {
            distance = min(distance, maxDistance)
        }

        return CameraState(
            position: SIMD3<Float>(center.x, center.y, center.z + distance),
            velocity: .zero,
            yaw: 0,
            pitch: 0,
            yawRate: 0,
            pitchRate: 0,
            roll: 0,
            rollRate: 0
        )
    }

    nonisolated private static func union(
        _ lhs: (min: SIMD3<Float>, max: SIMD3<Float>),
        _ rhs: (min: SIMD3<Float>, max: SIMD3<Float>)
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        (
            min: SIMD3<Float>(
                Swift.min(lhs.min.x, rhs.min.x),
                Swift.min(lhs.min.y, rhs.min.y),
                Swift.min(lhs.min.z, rhs.min.z)
            ),
            max: SIMD3<Float>(
                Swift.max(lhs.max.x, rhs.max.x),
                Swift.max(lhs.max.y, rhs.max.y),
                Swift.max(lhs.max.z, rhs.max.z)
            )
        )
    }

    nonisolated private static func bulkBounds(
        for positions: [SIMD3<Float>],
        outlierTrimFraction: Float
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let trimFraction = max(0, min(0.25, outlierTrimFraction))
        guard positions.count >= 8, trimFraction > 0 else {
            return exactBounds(for: positions)
        }

        let trimCount = min(
            positions.count - 1,
            max(1, Int((Float(positions.count) * trimFraction).rounded(.up)))
        )
        let keepCount = max(1, positions.count - trimCount)
        guard keepCount < positions.count else {
            return exactBounds(for: positions)
        }

        let center = medianPosition(for: positions)
        let selected = positions
            .sorted { lhs, rhs in
                bulkDistanceSquared(lhs, from: center) < bulkDistanceSquared(rhs, from: center)
            }
            .prefix(keepCount)
        return exactBounds(for: Array(selected))
    }

    nonisolated private static func exactBounds(for positions: [SIMD3<Float>]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var minP = positions[0]
        var maxP = positions[0]
        for position in positions.dropFirst() {
            minP = SIMD3<Float>(
                Swift.min(minP.x, position.x),
                Swift.min(minP.y, position.y),
                Swift.min(minP.z, position.z)
            )
            maxP = SIMD3<Float>(
                Swift.max(maxP.x, position.x),
                Swift.max(maxP.y, position.y),
                Swift.max(maxP.z, position.z)
            )
        }
        return (minP, maxP)
    }

    nonisolated private static func medianPosition(for positions: [SIMD3<Float>]) -> SIMD3<Float> {
        SIMD3<Float>(
            median(positions.map(\.x)),
            median(positions.map(\.y)),
            median(positions.map(\.z))
        )
    }

    nonisolated private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        guard sorted.count.isMultiple(of: 2) else {
            return sorted[midpoint]
        }
        return (sorted[midpoint - 1] + sorted[midpoint]) * 0.5
    }

    nonisolated private static func bulkDistanceSquared(
        _ position: SIMD3<Float>,
        from center: SIMD3<Float>
    ) -> Float {
        let dx = position.x - center.x
        let dy = position.y - center.y
        let dz = (position.z - center.z) * 0.35
        return dx * dx + dy * dy + dz * dz
    }
}
