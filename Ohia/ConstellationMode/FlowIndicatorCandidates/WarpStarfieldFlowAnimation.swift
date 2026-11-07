import SwiftUI

/// Bold, legibility-first warp: a handful of thick streaks accelerating out of
/// a central glow. Reads as "flying through stars" at 70×36 — a dozen bold
/// lines, not hundreds of fine specks.
struct WarpStarfieldFlowAnimation: View {
    let time: TimeInterval
    let reduceMotion: Bool

    init(time: TimeInterval, reduceMotion: Bool) {
        self.time = time
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let c = CGPoint(x: w * 0.5, y: h * 0.5)
            let RX = w * 0.62, RY = h * 0.62

            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(spaceHex: 0x01020A)))

            let area = w * h
            let n = max(8, min(18, Int(area / 260)))
            var rng = SpaceFieldRandom(seed: 0x5A7B_11FE_2026)

            // Central convergence glow.
            context.blendMode = .plusLighter
            let gR = h * 0.5
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - gR, y: c.y - gR, width: gR * 2, height: gR * 2)),
                with: .radialGradient(
                    Gradient(colors: [Color(spaceHex: 0xBCD8FF, opacity: 0.45), .clear]),
                    center: c, startRadius: 0, endRadius: gR))

            for _ in 0..<n {
                let ang = rng.range(0, 2 * .pi)
                let rate = rng.range(0.28, 0.5)
                let off = rng.unit()
                let ca = cos(ang), sa = sin(ang)
                let t = reduceMotion ? 0.45 : time * rate
                let p = SpaceAnimationMath.fract(t + off)

                let rHead = p * p                     // accelerate outward
                let rTail = max(0, p - 0.22)
                let rTailA = rTail * rTail
                let alpha = SpaceAnimationMath.smoothstep(p / 0.12)
                    * (1 - SpaceAnimationMath.smoothstep((p - 0.85) / 0.15))
                if alpha <= 0.02 { continue }

                let head = CGPoint(x: c.x + CGFloat(ca * rHead) * RX, y: c.y + CGFloat(sa * rHead) * RY)
                let tail = CGPoint(x: c.x + CGFloat(ca * rTailA) * RX, y: c.y + CGFloat(sa * rTailA) * RY)
                var path = Path()
                path.move(to: tail)
                path.addLine(to: head)
                let width = max(1.4, h * (0.03 + 0.05 * rHead))
                context.stroke(path, with: .linearGradient(
                    Gradient(colors: [.clear,
                                      Color(spaceHex: 0xFFD9A0, opacity: 0.5 * alpha),
                                      Color(spaceHex: 0xFFFFFF, opacity: alpha)]),
                    startPoint: tail, endPoint: head),
                    style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            context.blendMode = .normal
        }
    }
}
