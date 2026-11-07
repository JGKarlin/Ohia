import SwiftUI

/// Bold, legibility-first burning star: one big breathing sun with a couple of
/// large drifting surface spots and a few thick prominences flicking off the
/// limb. Reads as "a live, throbbing sun" at 70×36 — no fine granulation.
struct BurningStarFlowAnimation: View {
    let time: TimeInterval
    let reduceMotion: Bool

    init(time: TimeInterval, reduceMotion: Bool) {
        self.time = time
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        Canvas { context, size in
            let t = reduceMotion ? 2.1 : time
            let w = size.width
            let h = size.height
            let c = CGPoint(x: w * 0.5, y: h * 0.5)
            let breathe = reduceMotion ? 1 : 1 + 0.055 * sin(t / 3.2 * 2 * .pi)
            let R = h * 0.30 * breathe

            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(spaceHex: 0x060302)))

            // Corona glow.
            context.blendMode = .plusLighter
            let glowR = R * 2.4
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: glowR * 2, height: glowR * 2)),
                with: .radialGradient(
                    Gradient(colors: [Color(spaceHex: 0xFF6A1E, opacity: 0.5), .clear]),
                    center: c, startRadius: 0, endRadius: glowR)
            )

            // Prominences off the limb.
            let nFlares = 3
            for k in 0..<nFlares {
                let life = SpaceAnimationMath.fract(t / 2.6 + Double(k) / Double(nFlares))
                let env = sin(.pi * life)
                if env <= 0.02 { continue }
                let a = Double(k) / Double(nFlares) * 2 * .pi + t * 0.12
                let ht = R * (0.35 + 0.5 * env)
                let spread = 0.34
                let base1 = CGPoint(x: c.x + CGFloat(cos(a - spread)) * R * 0.95,
                                    y: c.y + CGFloat(sin(a - spread)) * R * 0.95)
                let base2 = CGPoint(x: c.x + CGFloat(cos(a + spread)) * R * 0.95,
                                    y: c.y + CGFloat(sin(a + spread)) * R * 0.95)
                let peak = CGPoint(x: c.x + CGFloat(cos(a)) * (R + ht),
                                   y: c.y + CGFloat(sin(a)) * (R + ht))
                var arc = Path()
                arc.move(to: base1)
                arc.addQuadCurve(to: base2, control: peak)
                context.stroke(arc, with: .color(Color(spaceHex: 0xFF7A2E, opacity: 0.85 * env)),
                               style: StrokeStyle(lineWidth: max(1.3, h * 0.045), lineCap: .round))
            }
            context.blendMode = .normal

            // Star body.
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)),
                with: .radialGradient(
                    Gradient(colors: [Color(spaceHex: 0xFFF4D6), Color(spaceHex: 0xFFB02E), Color(spaceHex: 0xFF6A1E)]),
                    center: CGPoint(x: c.x - R * 0.15, y: c.y - R * 0.15),
                    startRadius: 0, endRadius: R * 1.05)
            )

            // A couple of big drifting spots, clipped to the disc.
            var disc = context
            disc.clip(to: Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)))
            disc.blendMode = .multiply
            for k in 0..<2 {
                let ph = Double(k) * 2.3
                let sx = cos(t * 0.5 + ph) * Double(R) * 0.45
                let sy = sin(t * 0.37 + ph * 1.7) * Double(R) * 0.35
                let sp = CGPoint(x: c.x + CGFloat(sx), y: c.y + CGFloat(sy))
                let sr = R * 0.32
                disc.fill(
                    Path(ellipseIn: CGRect(x: sp.x - sr, y: sp.y - sr, width: sr * 2, height: sr * 2)),
                    with: .radialGradient(
                        Gradient(colors: [Color(spaceHex: 0xC24A10, opacity: 0.75), .clear]),
                        center: sp, startRadius: 0, endRadius: sr)
                )
            }

            // Crisp core highlight.
            context.blendMode = .plusLighter
            let coreR = R * 0.5
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2)),
                with: .radialGradient(
                    Gradient(colors: [Color(spaceHex: 0xFFFBEA, opacity: 0.9), .clear]),
                    center: c, startRadius: 0, endRadius: coreR)
            )
            context.blendMode = .normal
        }
    }
}
