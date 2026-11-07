import SwiftUI

/// Bold, legibility-first pulsar: a bright core with two opposed thick beams
/// sweeping like a lighthouse, flashing brighter each time they cross the
/// horizontal. Reads as "a spinning beacon" at 70×36 — no field lines or
/// accretion detail.
struct PulsarFlowAnimation: View {
    let time: TimeInterval
    let reduceMotion: Bool

    init(time: TimeInterval, reduceMotion: Bool) {
        self.time = time
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        Canvas { context, size in
            let t = reduceMotion ? 0.55 : time
            let w = size.width
            let h = size.height
            let c = CGPoint(x: w * 0.5, y: h * 0.5)
            let angle = t / 3.4 * 2 * .pi
            // Brightest when the beam points across the wide cell (horizontal).
            let flash = 0.45 + 0.55 * abs(cos(angle))
            let L = w * 0.62
            let tipHalf = h * 0.20

            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(spaceHex: 0x02040A)))

            context.blendMode = .plusLighter
            for dir in [angle, angle + .pi] {
                let d = CGVector(dx: cos(dir), dy: sin(dir))
                let perp = CGVector(dx: -d.dy, dy: d.dx)
                let tip = CGPoint(x: c.x + d.dx * L, y: c.y + d.dy * L)
                var wedge = Path()
                wedge.move(to: c)
                wedge.addLine(to: CGPoint(x: tip.x + perp.dx * tipHalf, y: tip.y + perp.dy * tipHalf))
                wedge.addLine(to: CGPoint(x: tip.x - perp.dx * tipHalf, y: tip.y - perp.dy * tipHalf))
                wedge.closeSubpath()
                context.fill(wedge, with: .linearGradient(
                    Gradient(colors: [Color(spaceHex: 0xEAF3FF, opacity: 0.85 * flash),
                                      Color(spaceHex: 0x6FD8FF, opacity: 0.32 * flash), .clear]),
                    startPoint: c, endPoint: tip))
                // Bright center lance.
                var lance = Path()
                lance.move(to: c)
                lance.addLine(to: tip)
                context.stroke(lance, with: .color(Color(spaceHex: 0xEAF3FF, opacity: 0.7 * flash)),
                               style: StrokeStyle(lineWidth: max(1.2, h * 0.03), lineCap: .round))
            }

            // Pulsing core.
            let coreR = h * 0.13 * (0.85 + 0.3 * flash)
            let glowR = coreR * 2.6
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: glowR * 2, height: glowR * 2)),
                with: .radialGradient(
                    Gradient(colors: [Color(spaceHex: 0x9AD8FF, opacity: 0.7 * flash), .clear]),
                    center: c, startRadius: 0, endRadius: glowR))
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2)),
                with: .radialGradient(
                    Gradient(colors: [Color(spaceHex: 0xFFFFFF), Color(spaceHex: 0xEAF3FF), Color(spaceHex: 0x9AD8FF)]),
                    center: c, startRadius: 0, endRadius: coreR))
            context.blendMode = .normal
        }
    }
}
