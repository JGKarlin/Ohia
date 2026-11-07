import SwiftUI

/// Looped processing indicator: a faint stamen glow with two moons drifting
/// on tilted, off-tempo orbital ellipses. Used on `SplashView` while the
/// retrieval and generative workers initialize. The two moons read as
/// emergent binary structure — never labelled, never anthropomorphic.
///
/// The indicator paints transparently over its parent background; place it
/// over the splash backdrop directly. It scales with the frame it's given,
/// so size it via `.frame(width:height:)` at the call site.
struct OrbitingMoonsIndicator: View {
    var accent: Color = OhiaColors.chipActiveBackground

    private static let loopDuration: TimeInterval = 5.6

    var body: some View {
        TimelineView(.animation(minimumInterval: OhiaAnimationCadence.frameInterval)) { timeline in
            OrbitingMoonsBody(
                phase: Self.loopPhase(at: timeline.date),
                accent: accent
            )
        }
    }

    private static func loopPhase(at date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate / loopDuration)
            .truncatingRemainder(dividingBy: 1)
    }
}

/// Pure-visual body of `OrbitingMoonsIndicator`, parameterized on phase so
/// the `DesignSandbox` can drive it from a scrub control alongside other
/// candidate indicators.
struct OrbitingMoonsBody: View {
    let phase: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let scale = min(proxy.size.width, proxy.size.height) / 220
            let aRadiusX = 70 * scale
            let aRadiusY = 36 * scale
            let bRadiusX = 42 * scale
            let bRadiusY = 78 * scale
            let aTilt: Double = -14
            let bTilt: Double = 78
            let aAngle = phase * .pi * 2
            let bAngle = phase * .pi * 2 * 1.27 + .pi * 0.42
            let trailCount = 14

            ZStack {
                // Faint halo around the stamen
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.55), accent.opacity(0.14), .clear],
                            center: .center,
                            startRadius: 1,
                            endRadius: 24 * scale
                        )
                    )
                    .frame(width: 56 * scale, height: 56 * scale)
                    .position(center)
                    .blendMode(.screen)

                // Central stamen point
                Circle()
                    .fill(Color.white.opacity(0.94))
                    .frame(width: 6 * scale, height: 6 * scale)
                    .shadow(color: accent.opacity(0.65), radius: 8 * scale)
                    .position(center)
                    .blendMode(.screen)

                // Orbit A path
                Ellipse()
                    .strokeBorder(accent.opacity(0.18), lineWidth: 0.7)
                    .frame(width: aRadiusX * 2, height: aRadiusY * 2)
                    .rotationEffect(.degrees(aTilt))
                    .position(center)

                // Orbit B path
                Ellipse()
                    .strokeBorder(accent.opacity(0.14), lineWidth: 0.7)
                    .frame(width: bRadiusX * 2, height: bRadiusY * 2)
                    .rotationEffect(.degrees(bTilt))
                    .position(center)

                // Trail A — pale, leading the moon
                ForEach(0..<trailCount, id: \.self) { i in
                    let trailAngle = aAngle - Double(i) * 0.075
                    let pt = orbitalPoint(
                        center: center,
                        radiusX: aRadiusX,
                        radiusY: aRadiusY,
                        tiltDegrees: aTilt,
                        angle: trailAngle
                    )
                    let opacity = (1 - Double(i) / Double(trailCount)) * 0.42
                    let r = max(0.6, 3.2 - Double(i) * 0.18) * scale
                    Circle()
                        .fill(Color.white.opacity(opacity))
                        .frame(width: r, height: r)
                        .position(pt)
                        .blendMode(.screen)
                }

                // Moon A — pale lunar
                Circle()
                    .fill(Color.white.opacity(0.96))
                    .frame(width: 5.5 * scale, height: 5.5 * scale)
                    .shadow(color: accent.opacity(0.55), radius: 7 * scale)
                    .position(orbitalPoint(
                        center: center,
                        radiusX: aRadiusX,
                        radiusY: aRadiusY,
                        tiltDegrees: aTilt,
                        angle: aAngle
                    ))
                    .blendMode(.screen)

                // Trail B — accent-tinted, trailing the second moon
                ForEach(0..<trailCount, id: \.self) { i in
                    let trailAngle = bAngle - Double(i) * 0.082
                    let pt = orbitalPoint(
                        center: center,
                        radiusX: bRadiusX,
                        radiusY: bRadiusY,
                        tiltDegrees: bTilt,
                        angle: trailAngle
                    )
                    let opacity = (1 - Double(i) / Double(trailCount)) * 0.40
                    let r = max(0.6, 2.9 - Double(i) * 0.16) * scale
                    Circle()
                        .fill(accent.opacity(opacity))
                        .frame(width: r, height: r)
                        .position(pt)
                        .blendMode(.screen)
                }

                // Moon B — accent-tinted lunar
                Circle()
                    .fill(accent.opacity(0.96))
                    .frame(width: 4.8 * scale, height: 4.8 * scale)
                    .shadow(color: accent.opacity(0.6), radius: 7 * scale)
                    .position(orbitalPoint(
                        center: center,
                        radiusX: bRadiusX,
                        radiusY: bRadiusY,
                        tiltDegrees: bTilt,
                        angle: bAngle
                    ))
                    .blendMode(.screen)
            }
        }
    }

    private func orbitalPoint(
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        tiltDegrees: Double,
        angle: Double
    ) -> CGPoint {
        let cosTilt = cos(tiltDegrees * .pi / 180)
        let sinTilt = sin(tiltDegrees * .pi / 180)
        let local = CGPoint(x: cos(angle) * radiusX, y: sin(angle) * radiusY)
        return CGPoint(
            x: center.x + local.x * cosTilt - local.y * sinTilt,
            y: center.y + local.x * sinTilt + local.y * cosTilt
        )
    }
}
