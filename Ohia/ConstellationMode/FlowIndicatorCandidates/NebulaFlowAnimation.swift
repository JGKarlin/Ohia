import SwiftUI

/// Bold, legibility-first nebula: three big overlapping color lobes that
/// breathe and drift, with a few large twinkling stars on top. Reads as "a
/// glowing colored cloud with twinkles" at 70×36 — no fine gas texture, dust
/// lanes, or dense star beds.
struct NebulaFlowAnimation: View {
    let time: TimeInterval
    let reduceMotion: Bool

    init(time: TimeInterval, reduceMotion: Bool) {
        self.time = time
        self.reduceMotion = reduceMotion
    }

    private struct Lobe { let ox: Double; let oy: Double; let fx: Double; let fy: Double; let color: UInt32 }
    private let lobes: [Lobe] = [
        Lobe(ox: -0.16, oy: -0.05, fx: 0.13, fy: 0.17, color: 0xE0578C),
        Lobe(ox:  0.16, oy:  0.06, fx: 0.11, fy: 0.15, color: 0x7A5CFF),
        Lobe(ox:  0.00, oy:  0.02, fx: 0.15, fy: 0.12, color: 0x2FB6C0),
    ]
    private struct Star { let x: Double; let y: Double; let phase: Double; let size: Double }
    private let stars: [Star] = [
        Star(x: 0.30, y: 0.34, phase: 0.0, size: 0.075),
        Star(x: 0.66, y: 0.62, phase: 1.7, size: 0.09),
        Star(x: 0.52, y: 0.28, phase: 3.1, size: 0.06),
    ]

    var body: some View {
        Canvas { context, size in
            let t = reduceMotion ? 0.8 : time
            let w = size.width
            let h = size.height
            let c = CGPoint(x: w * 0.5, y: h * 0.5)

            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(spaceHex: 0x04030A)))

            // Soft, blurred, additive gas lobes.
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: max(3, h * 0.14)))
                layer.blendMode = .plusLighter
                for (i, lobe) in lobes.enumerated() {
                    let ph = Double(i) * 1.7
                    let dx = lobe.ox + 0.05 * sin(t * lobe.fx * 2 * .pi + ph)
                    let dy = lobe.oy + 0.05 * cos(t * lobe.fy * 2 * .pi + ph * 1.3)
                    let pulse = 0.8 + 0.2 * sin(t * 0.5 + ph)
                    let center = CGPoint(x: c.x + CGFloat(dx) * w, y: c.y + CGFloat(dy) * h)
                    let r = h * 0.6 * CGFloat(pulse)
                    layer.fill(
                        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(
                            Gradient(colors: [Color(spaceHex: lobe.color, opacity: 0.55), .clear]),
                            center: center, startRadius: 0, endRadius: r))
                }
            }

            // Bold twinkling stars.
            context.blendMode = .plusLighter
            for star in stars {
                let tw = 0.55 + 0.45 * sin(t * 2.1 + star.phase)
                let p = CGPoint(x: CGFloat(star.x) * w, y: CGFloat(star.y) * h)
                let r = h * CGFloat(star.size)
                let glowR = r * 2.4
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - glowR, y: p.y - glowR, width: glowR * 2, height: glowR * 2)),
                    with: .radialGradient(
                        Gradient(colors: [Color(spaceHex: 0xCFE8FF, opacity: 0.7 * tw), .clear]),
                        center: p, startRadius: 0, endRadius: glowR))
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                    with: .color(Color(spaceHex: 0xFFFFFF, opacity: 0.7 + 0.3 * tw)))
            }
            context.blendMode = .normal
        }
    }
}
