import SwiftUI

/// Bold, legibility-first comet: one bright head on a clear eccentric orbit
/// around a small star, with a single thick tail that streams anti-star and
/// grows long as it whips through perihelion. Reads as "a comet streaking
/// past" at 70×36 — no fine dual tails or dot-sampled wisps.
struct CometFlowAnimation: View {
    let time: TimeInterval
    let reduceMotion: Bool

    init(time: TimeInterval, reduceMotion: Bool) {
        self.time = time
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        Canvas { context, size in
            let t = reduceMotion ? 0.25 : time
            let w = size.width
            let h = size.height
            let ec = CGPoint(x: w * 0.5, y: h * 0.5)
            let A = w * 0.40, B = h * 0.34
            let e = 0.55
            let focus = CGPoint(x: ec.x + A * CGFloat(e), y: ec.y)
            let period = 5.0

            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(spaceHex: 0x03050A)))

            // Faint orbit path.
            context.stroke(Path(ellipseIn: CGRect(x: ec.x - A, y: ec.y - B, width: A * 2, height: B * 2)),
                           with: .color(.white.opacity(0.08)), lineWidth: max(0.75, h * 0.012))

            // Small central star.
            drawGlowDot(&context, at: focus, r: h * 0.09, core: 0xFFF3D0, glow: 0xFFB94D, glowScale: 2.4)

            // Kepler solve for the eccentric anomaly.
            let M = (t / period) * 2 * .pi
            var eAnom = M
            for _ in 0..<5 { eAnom -= (eAnom - e * sin(eAnom) - M) / (1 - e * cos(eAnom)) }
            let head = CGPoint(x: ec.x + A * CGFloat(cos(eAnom)), y: ec.y + B * CGFloat(sin(eAnom)))

            // Anti-star tail direction and a perihelion brightness factor.
            let dx = head.x - focus.x, dy = head.y - focus.y
            let dist = max(1, hypot(dx, dy))
            let tailDir = CGVector(dx: dx / dist, dy: dy / dist)
            let perp = CGVector(dx: -tailDir.dy, dy: tailDir.dx)
            let near = 1 - Double(dist) / Double(A * (1 + CGFloat(e)))   // ~1 at perihelion
            let peri = max(0.15, near)
            let L = w * 0.5 * CGFloat(peri)
            let headR = h * (0.06 + 0.03 * CGFloat(peri))
            let wBase = h * 0.16 * CGFloat(peri)

            // Bold tapering tail.
            context.blendMode = .plusLighter
            let tip = CGPoint(x: head.x + tailDir.dx * L, y: head.y + tailDir.dy * L)
            var tail = Path()
            tail.move(to: CGPoint(x: head.x + perp.dx * wBase, y: head.y + perp.dy * wBase))
            tail.addLine(to: CGPoint(x: head.x - perp.dx * wBase, y: head.y - perp.dy * wBase))
            tail.addLine(to: tip)
            tail.closeSubpath()
            context.fill(tail, with: .linearGradient(
                Gradient(colors: [Color(spaceHex: 0x9FD0FF, opacity: 0.85 * peri), .clear]),
                startPoint: head, endPoint: tip))
            context.blendMode = .normal

            // Bright head.
            drawGlowDot(&context, at: head, r: headR, core: 0xFFFFFF, glow: 0xBFE4FF, glowScale: 2.6)
        }
    }

    private func drawGlowDot(_ context: inout GraphicsContext, at p: CGPoint, r: CGFloat,
                             core: UInt32, glow: UInt32, glowScale: CGFloat) {
        context.blendMode = .plusLighter
        let gR = r * glowScale
        context.fill(
            Path(ellipseIn: CGRect(x: p.x - gR, y: p.y - gR, width: gR * 2, height: gR * 2)),
            with: .radialGradient(
                Gradient(colors: [Color(spaceHex: glow, opacity: 0.7), .clear]),
                center: p, startRadius: 0, endRadius: gR))
        context.fill(
            Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(
                Gradient(colors: [Color(spaceHex: core), Color(spaceHex: glow)]),
                center: p, startRadius: 0, endRadius: r))
        context.blendMode = .normal
    }
}
