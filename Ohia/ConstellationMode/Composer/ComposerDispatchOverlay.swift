import SwiftUI
import OhiaCore

/// Draws the one-shot send-to-Composer dispatch comet over the live Metal scene.
/// For each active dispatch it projects the message's node to screen with the
/// live camera and draws a comet approaching the viewer along that sightline,
/// growing into a full-canvas arrival flash on the card-exit sound beat.
///
/// Works in both Metal lenses. Meaning launches from the packet's base star
/// position; People's ring satellites orbit every frame, so `displacedWorld`
/// lifts each base position to where the satellite is actually drawn (identity in
/// Meaning). Mounted as a sibling above the scene (not inside the paused focus
/// `TimelineView`) so it re-renders the instant a dispatch begins; its own
/// `TimelineView` pauses whenever idle.
struct ComposerDispatchOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let coordinator: ComposerDispatchCoordinator
    let renderPacket: ConstellationRenderPacket
    let cameraController: CameraController
    var enabled: Bool = true
    /// Maps a launch's (messageId, base world) to its live world position,
    /// re-evaluated every frame so an orbiting People satellite's comet trails
    /// from the moving node. Identity by default (Meaning and any static lens).
    var displacedWorld: (String, SIMD3<Float>) -> SIMD3<Float> = { _, base in base }

    private struct Launch {
        let messageId: String
        let world: SIMD3<Float>
        let start: Date
        let tint: Color
    }

    var body: some View {
        // Reading `dispatches` here establishes observation, so a `begin()` while
        // idle re-evaluates this body and un-pauses the TimelineView below.
        let dispatches = coordinator.dispatches
        let launches = (enabled && !dispatches.isEmpty) ? resolveLaunches(dispatches) : []

        TimelineView(.animation(paused: launches.isEmpty)) { timeline in
            Canvas { context, size in
                let now = timeline.date
                var arrivalFlash = 0.0
                for launch in launches {
                    // Re-lift to the live world each frame so People's orbiting
                    // satellite carries its comet; identity elsewhere.
                    let world = displacedWorld(launch.messageId, launch.world)
                    guard let origin = ScreenProjection.project(
                        world: world,
                        camera: cameraController.state,
                        viewSize: size,
                        fovYRadians: .pi / 3
                    ) else { continue }
                    let elapsed = max(0, now.timeIntervalSince(launch.start))
                    arrivalFlash = max(arrivalFlash, drawApproachingComet(
                        &context, size: size, origin: origin, elapsed: elapsed, tint: launch.tint
                    ))
                }
                // One flash even for bulk sends; paint last so later comets
                // cannot obscure the arrival. The overlay spans the Metal lens.
                if arrivalFlash > 0 {
                    context.fill(Path(CGRect(origin: .zero, size: size)),
                                 with: .color(OhiaColors.composerArrivalFlash.opacity(arrivalFlash)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func resolveLaunches(
        _ dispatches: [UUID: ComposerDispatchCoordinator.Dispatch]
    ) -> [Launch] {
        let wanted = Set(dispatches.keys.map { $0.uuidString })
        var positions: [String: SIMD3<Float>] = [:]
        positions.reserveCapacity(wanted.count)
        for star in renderPacket.stars where wanted.contains(star.messageId) {
            positions[star.messageId] = star.position
        }
        return dispatches.compactMap { id, dispatch in
            guard let world = positions[id.uuidString] else { return nil }
            return Launch(
                messageId: id.uuidString, world: world,
                start: dispatch.start, tint: dispatch.tint
            )
        }
    }

    /// Use the card Bolide's onset, hold and arrival landmarks. Dispatch and
    /// sound start together; the existing 1.1-second dispatch lifetime leaves
    /// room for the flash to clear before Composer opens.
    private func drawApproachingComet(
        _ context: inout GraphicsContext, size: CGSize, origin: CGPoint,
        elapsed: Double, tint: Color
    ) -> Double {
        let phase = MessageStatusGesturePhase(
            elapsed: elapsed, floor: MessageStatusGesturePhase.floor(for: .sentToComposer)
        )
        let progress = clamp((phase.mid - departingHoldFraction) / (1 - departingHoldFraction))
        let approach = clamp((progress - 0.30) / 0.54)
        let fade = 1 - clamp((elapsed - phase.floor) / 0.15)
        guard fade > 0, size.width > 0, size.height > 0 else { return 0 }

        func circle(_ radius: Double) -> Path {
            Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - radius,
                                  width: radius * 2, height: radius * 2))
        }

        // A camera-directed flight stays on the launch sightline. Perspective
        // growth accelerates as depth approaches zero, rather than sliding the
        // comet toward a screen edge or another window.
        let farthestX = max(abs(origin.x), abs(size.width - origin.x))
        let farthestY = max(abs(origin.y), abs(size.height - origin.y))
        let coverage = hypot(farthestX, farthestY)
        let perspective = (1 / (1 - 0.985 * approach) - 1) / (1 / 0.015 - 1)
        let radius = 3.2 + (reduceMotion ? 18 : coverage) * perspective
        let bodyAlpha = (1 - clamp((progress - 0.86) / 0.10)) * fade

        let onset = sin(clamp(elapsed / MessageStatusGesturePhase.onset) * .pi)
        if onset > 0 {
            context.stroke(circle(6 + 24 * clamp(elapsed / MessageStatusGesturePhase.onset)),
                           with: .color(tint.opacity(onset)), lineWidth: 2)
        }
        if bodyAlpha > 0 {
            // Foreshortened wake and radial streaks supply depth around the
            // nucleus without giving the flight a sideways destination.
            if !reduceMotion, approach > 0 {
                for index in 0..<12 {
                    let angle = Double(index) * .pi / 6 + 0.17
                    let inner = radius * 1.15
                    let outer = inner + (24 + coverage * 0.25) * approach
                    var streak = Path()
                    streak.move(to: CGPoint(x: origin.x + cos(angle) * inner,
                                            y: origin.y + sin(angle) * inner))
                    streak.addLine(to: CGPoint(x: origin.x + cos(angle) * outer,
                                               y: origin.y + sin(angle) * outer))
                    context.stroke(streak, with: .color(tint.opacity(approach * bodyAlpha * 0.45)),
                                   lineWidth: 1 + approach * 3)
                }
            }
            context.fill(circle(radius * 1.8), with: .radialGradient(
                Gradient(colors: [tint.opacity(bodyAlpha * 0.8), tint.opacity(0)]),
                center: origin, startRadius: radius * 0.4, endRadius: radius * 1.8
            ))
            context.fill(circle(radius), with: .color(tint.opacity(bodyAlpha)))
            context.fill(circle(radius * 0.55),
                         with: .color(OhiaColors.composerArrivalFlash.opacity(bodyAlpha)))
        }
        // Match Bolide's flash onset, but hold its peak briefly so the full
        // arrival is readable before fading through the dispatch's final tail.
        let flash = clamp((progress - 0.84) / 0.12) * fade
        return flash * (reduceMotion ? 0.15 : 1)
    }

    private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

private extension OhiaColors {
    /// Emissive arrival light stays white in both appearances.
    static let composerArrivalFlash = Color.white
}
