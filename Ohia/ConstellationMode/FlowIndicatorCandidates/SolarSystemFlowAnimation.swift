import SwiftUI

/// Bold, legibility-first solar system: one big breathing sun and just two
/// large planets on clear elliptical orbits — reads as "planets circling a
/// star" at 70×36. No fine rings or crowds of tiny worlds.
struct SolarSystemFlowAnimation: View {
    let time: TimeInterval
    let reduceMotion: Bool

    init(time: TimeInterval, reduceMotion: Bool) {
        self.time = time
        self.reduceMotion = reduceMotion
    }

    private struct Planet {
        let rx: CGFloat        // orbit half-width  (fraction of W)
        let ry: CGFloat        // orbit half-height (fraction of H)
        let radius: CGFloat    // planet size (fraction of H)
        let period: Double
        let phase0: Double
        let color: UInt32
    }

    private let planets: [Planet] = [
        Planet(rx: 0.26, ry: 0.26, radius: 0.13, period: 3.1, phase0: 0.0, color: 0x8FB7FF),
        Planet(rx: 0.42, ry: 0.37, radius: 0.16, period: 5.3, phase0: 2.2, color: 0xC97A4A),
    ]

    var body: some View {
        Canvas { context, size in
            let t = reduceMotion ? 1.35 : time
            let w = size.width
            let h = size.height
            let center = CGPoint(x: w * 0.5, y: h * 0.5)

            // Deep field.
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(spaceHex: 0x05060B)))

            // Faint orbit rings.
            for p in planets {
                let rect = CGRect(
                    x: center.x - w * p.rx, y: center.y - h * p.ry,
                    width: w * p.rx * 2, height: h * p.ry * 2
                )
                context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.10)),
                               lineWidth: max(0.75, h * 0.012))
            }

            // Positions + depth (sin < 0 → far side, behind the sun).
            func pos(_ p: Planet) -> (pt: CGPoint, far: Bool, r: CGFloat) {
                let a = p.phase0 + (t / p.period) * 2 * .pi
                let pt = CGPoint(x: center.x + cos(a) * w * p.rx,
                                 y: center.y + sin(a) * h * p.ry)
                return (pt, sin(a) < 0, max(1.6, h * p.radius))
            }
            let placed = planets.map(pos)

            // Far planets (behind the sun) first.
            for (i, pl) in placed.enumerated() where pl.far {
                drawPlanet(&context, at: pl.pt, r: pl.r, color: planets[i].color)
            }

            // The sun.
            let breathe = reduceMotion ? 1 : 1 + 0.06 * sin(t / 4 * 2 * .pi)
            let sunR = h * 0.22 * breathe
            drawSun(&context, at: center, r: sunR)

            // Near planets over the sun.
            for (i, pl) in placed.enumerated() where !pl.far {
                drawPlanet(&context, at: pl.pt, r: pl.r, color: planets[i].color)
            }
        }
    }

    private func drawSun(_ context: inout GraphicsContext, at c: CGPoint, r: CGFloat) {
        context.blendMode = .plusLighter
        let glowR = r * 2.6
        context.fill(
            Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: glowR * 2, height: glowR * 2)),
            with: .radialGradient(
                Gradient(colors: [Color(spaceHex: 0xFF9A3C, opacity: 0.55), .clear]),
                center: c, startRadius: 0, endRadius: glowR)
        )
        context.fill(
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(
                Gradient(colors: [Color(spaceHex: 0xFFF6D8), Color(spaceHex: 0xFFD27A), Color(spaceHex: 0xFF9A3C)]),
                center: c, startRadius: 0, endRadius: r)
        )
        context.blendMode = .normal
    }

    private func drawPlanet(_ context: inout GraphicsContext, at c: CGPoint, r: CGFloat, color: UInt32) {
        // Additive halo.
        context.blendMode = .plusLighter
        let hR = r * 1.9
        context.fill(
            Path(ellipseIn: CGRect(x: c.x - hR, y: c.y - hR, width: hR * 2, height: hR * 2)),
            with: .radialGradient(
                Gradient(colors: [Color(spaceHex: color, opacity: 0.45), .clear]),
                center: c, startRadius: 0, endRadius: hR)
        )
        context.blendMode = .normal
        // Body with a simple lit side.
        context.fill(
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(
                Gradient(colors: [Color(spaceHex: color), Color(spaceHex: color, opacity: 0.55)]),
                center: CGPoint(x: c.x - r * 0.35, y: c.y - r * 0.35),
                startRadius: 0, endRadius: r * 1.4)
        )
    }
}
