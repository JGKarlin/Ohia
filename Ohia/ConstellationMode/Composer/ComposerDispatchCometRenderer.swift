import SwiftUI

/// Shared drawing for the send-to-Composer dispatch comet, so every lens's
/// overlay renders a pixel-identical flare + comet. The only per-lens difference
/// is how the launch `origin` is resolved (Metal screen projection in the
/// Meaning / People lenses, the Timeline projector in the Timeline lens); the
/// motion and look live here.
enum ComposerDispatchCometRenderer {
    /// Draws the registered-beat flare at `origin`, then the comet travelling
    /// along `direction` (a unit vector in view space, y-down, toward the
    /// Composer window) from `origin`, at the given elapsed `phase`. `size` is the
    /// hosting canvas size — the comet's travel distance scales to it, matching
    /// how it reads across every lens.
    static func draw(
        _ ctx: inout GraphicsContext,
        size: CGSize,
        origin: CGPoint,
        direction: CGVector,
        phase: ComposerDispatchPhase,
        tint: Color
    ) {
        // Registered-beat flare: one expanding ring + a bright core.
        let ring = min(1, phase.elapsed / ComposerDispatchPhase.flareWindow)
        if ring > 0, ring < 1 {
            let r = 6 + 24 * easeOut(ring)
            ctx.stroke(circle(origin, r), with: .color(tint.opacity((1 - ring) * 0.85)), lineWidth: 2)
        }
        if phase.flare > 0.01 {
            ctx.fill(circle(origin, 3 + 5 * phase.flare), with: .color(tint.opacity(0.9 * phase.flare)))
        }

        // Comet travelling along the heading toward the Composer window.
        guard phase.comet > 0 else { return }
        let travel = hypot(size.width, size.height) * 0.95
        let fade = phase.cometFade
        guard fade > 0.02 else { return }

        let tailCount = 12
        for i in stride(from: tailCount - 1, through: 0, by: -1) {
            let p = max(0, phase.comet - Double(i) * 0.028)
            let d = travel * p
            let point = CGPoint(x: origin.x + direction.dx * d, y: origin.y + direction.dy * d)
            let radius = (2.8 - Double(i) * 0.2) * max(0.2, fade)
            guard radius > 0 else { continue }
            ctx.fill(circle(point, radius), with: .color(tint.opacity((0.5 - Double(i) * 0.038) * fade)))
        }
        let head = CGPoint(
            x: origin.x + direction.dx * travel * phase.comet,
            y: origin.y + direction.dy * travel * phase.comet
        )
        ctx.fill(circle(head, 3.2 * max(0.3, fade)), with: .color(tint.opacity(fade)))
    }

    private static func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - min(1, max(0, t)), 3) }
}
