// AtomFlowAnimation.swift
// Flow-indicator candidate — "Atom": a glowing Bohr-style atom.
//
// A warm white-gold nucleus breathes at the centre while cool electrons dart
// around three faintly-drawn, differently-tilted elliptical shells, each
// dragging a short tapered comet streak sampled from its own recent path.
// All motion is a pure closed-form function of `time`; every dimension scales
// to the drawing `size`, so the same view reads at the 70×36 activity-strip
// tile and the ~560×320 design sandbox. See SpaceAnimationSupport.swift for
// the shared contract and helpers.

import SwiftUI

struct AtomFlowAnimation: View {
    let time: TimeInterval
    let reduceMotion: Bool
    /// The deep-field fill. Defaults to near-black for the design sandbox; the
    /// activity strip passes its own background so the cell blends into the
    /// strip instead of reading as a pasted-on dark sticker.
    var backgroundColor: Color = Color(spaceHex: 0x04060A)
    /// The nucleus colour — a solid accent dot echoing the activity strip's
    /// pipeline stage dots. Defaults to warm gold for the design sandbox; the
    /// strip passes the active accent (Ohia yellow on dark, green on light).
    var coreColor: Color = Color(spaceHex: 0xFFF3C0)
    /// The electron colour — every electron shares it. The strip passes the
    /// account colour of the work its readout is currently naming, so the
    /// orbiting colour says *whose* mail is being processed; it defaults to
    /// cyan for the design sandbox.
    var electronColor: Color = Color(spaceHex: 0x7FE3FF)
    /// Draw the nucleus (halo + core). The activity strip mounts the nucleus as
    /// its own always-present static SwiftUI layer whose dim/bright is a real
    /// opacity animation, so it renders only the nucleus (`drawsElectrons` off).
    var drawsNucleus: Bool = true
    /// Draw the electrons, shells, and background dust — the "full animation"
    /// layer. The strip mounts these in a separate animated layer that fades in
    /// and out via a SwiftUI transition, so it renders only the electrons
    /// (`drawsNucleus` off). The design sandbox draws both.
    var drawsElectrons: Bool = true

    init(
        time: TimeInterval,
        reduceMotion: Bool,
        backgroundColor: Color = Color(spaceHex: 0x04060A),
        coreColor: Color = Color(spaceHex: 0xFFF3C0),
        electronColor: Color = Color(spaceHex: 0x7FE3FF),
        drawsNucleus: Bool = true,
        drawsElectrons: Bool = true
    ) {
        self.time = time
        self.reduceMotion = reduceMotion
        self.backgroundColor = backgroundColor
        self.coreColor = coreColor
        self.electronColor = electronColor
        self.drawsNucleus = drawsNucleus
        self.drawsElectrons = drawsElectrons
    }

    // MARK: Palette (astronomical hex on near-black)
    private let shellStroke  = Color(spaceHex: 0xBFE6FF, opacity: 0.10)
    private let dustHue: UInt32 = 0xBFD4FF

    var body: some View {
        Canvas { context, size in
            // --- deep-field fill first ---
            let w = Double(size.width)
            let h = Double(size.height)
            context.fill(
                Path(CGRect(x: 0, y: 0, width: w, height: h)),
                with: .color(backgroundColor)
            )
            guard w > 0, h > 0 else { return }

            // Motion is a pure function of `te`; reduceMotion freezes one phase.
            let te = reduceMotion ? 3.10 : time
            let twoPi = Double.pi * 2

            let cx = w * 0.5
            let cy = h * 0.5
            let halfW = w * 0.5
            let halfH = h * 0.5
            let unit = min(w, h)          // element sizing keyed to the short edge
            let margin = 0.955

            // A filled disc path centred at (px,py) with radius r.
            func disc(_ px: Double, _ py: Double, _ r: Double) -> Path {
                Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))
            }

            // ---- shell definitions (fractions of halfW/halfH, tilt, rate, e-count) ----
            // Fractions + modest tilts chosen so every rotated ellipse fits the
            // wide cell at its most extreme aspect; inner (smaller) shells can
            // afford steeper tilts. Shapes stay wider-than-tall (landscape).
            let axFrac: [Double] = [0.86,  0.60,  0.48]
            let byFrac: [Double] = [0.42,  0.44,  0.30]
            let tilt:   [Double] = [0.20, -0.35,  0.62]   // radians
            let omega:  [Double] = [0.90, -1.40,  2.10]   // rad/s (shell 2 retrograde)
            let phase0: [Double] = [0.40,  1.90,  3.50]
            let eCount: [Int]    = [1, 2, 1]

            // Parametric point on shell `i` at ellipse angle `theta`.
            func shellPoint(_ i: Int, _ theta: Double) -> (Double, Double) {
                let a = halfW * axFrac[i] * margin
                let b = halfH * byFrac[i] * margin
                let ct = cos(tilt[i]), st = sin(tilt[i])
                let lx = a * cos(theta)
                let ly = b * sin(theta)
                return (cx + lx * ct - ly * st, cy + lx * st + ly * ct)
            }

            // ---- background dust: count scales with area, near-nothing at 70×36 ----
            if drawsElectrons {
                let area = w * h
                let dustCount = min(150, Int(area / 1400.0))
                if dustCount > 0 {
                    var rng = SpaceFieldRandom(seed: 0xA70F_10D5)   // fixed seed → deterministic
                    context.blendMode = .plusLighter
                    for _ in 0..<dustCount {
                        let x = rng.range(0, w)
                        let y = rng.range(0, h)
                        let base = rng.range(0.05, 0.20)
                        let ph = rng.range(0, twoPi)
                        let rate = rng.range(0.10, 0.35)
                        let tw = 0.4 + 0.6 * (0.5 + 0.5 * sin(twoPi * rate * te + ph))
                        let r = max(0.4, unit * 0.006) * rng.range(0.6, 1.4)
                        context.fill(disc(x, y, r), with: .color(Color(spaceHex: dustHue, opacity: base * tw)))
                    }
                    context.blendMode = .normal
                }
            }

            // ---- faint shell ellipses ----
            if drawsElectrons {
                let ringSteps = max(64, min(200, Int(unit * 0.9)))
                let ringWidth = CGFloat(max(0.5, unit * 0.006))
                for i in 0..<3 {
                    var ring = Path()
                    for k in 0...ringSteps {
                        let (px, py) = shellPoint(i, twoPi * Double(k) / Double(ringSteps))
                        if k == 0 { ring.move(to: CGPoint(x: px, y: py)) }
                        else { ring.addLine(to: CGPoint(x: px, y: py)) }
                    }
                    ring.closeSubpath()
                    context.stroke(ring, with: .color(shellStroke), lineWidth: ringWidth)
                }
            }

            // ---- nucleus: a solid accent dot with a soft halo, echoing the
            // activity strip's pipeline stage dots so the indicator shares
            // their visual language ----
            if drawsNucleus {
                let breathe = 1.0 + 0.07 * sin(twoPi * 0.16 * te)
                let coreR = unit * 0.16 * breathe
                let glowR = coreR * 3.0

                // soft accent halo
                context.blendMode = .plusLighter
                context.fill(
                    disc(cx, cy, glowR),
                    with: .radialGradient(
                        Gradient(colors: [coreColor.opacity(0.55), coreColor.opacity(0.0)]),
                        center: CGPoint(x: cx, y: cy),
                        startRadius: 0, endRadius: CGFloat(glowR)
                    )
                )
                context.blendMode = .normal

                // crisp solid core dot
                context.fill(disc(cx, cy, coreR), with: .color(coreColor))
            }

            // ---- electrons + comet trails (additive) ----
            if drawsElectrons {
                let trailSamples = max(6, min(16, Int(unit * 0.14)))
                let trailArc = 0.60                                   // radians the tail spans
                let electronR = max(1.3, unit * 0.042)

                // Every electron shares one colour — the account whose work is
                // engaged right now.
                let base = electronColor

                context.blendMode = .plusLighter
                for i in 0..<3 {
                    let count = eCount[i]
                    let dt = trailArc / (abs(omega[i]) * Double(trailSamples - 1))
                    for j in 0..<count {
                        let headAngle = omega[i] * te + phase0[i] + twoPi * Double(j) / Double(count)

                        // trail: sample the electron's own recent positions (t − k·dt)
                        var pts: [(Double, Double)] = []
                        pts.reserveCapacity(trailSamples)
                        for k in 0..<trailSamples {
                            pts.append(shellPoint(i, headAngle - omega[i] * Double(k) * dt))
                        }
                        // draw tail→head so the brightest segment lands on top
                        var k = trailSamples - 2
                        while k >= 0 {
                            let f = 1.0 - Double(k) / Double(trailSamples - 1)   // 1 at head, →0 at tail
                            let (ax, ay) = pts[k + 1]
                            let (bx, by) = pts[k]
                            var seg = Path()
                            seg.move(to: CGPoint(x: ax, y: ay))
                            seg.addLine(to: CGPoint(x: bx, y: by))
                            let width = CGFloat(electronR * (0.9 * f + 0.18))
                            context.stroke(
                                seg,
                                with: .color(base.opacity(0.55 * f * f)),
                                style: StrokeStyle(lineWidth: width, lineCap: .round)
                            )
                            k -= 1
                        }

                        // electron head: soft glow + hot near-white core
                        let (hx, hy) = pts[0]
                        context.fill(
                            disc(hx, hy, electronR * 2.8),
                            with: .radialGradient(
                                Gradient(colors: [
                                    base.opacity(0.55),
                                    base.opacity(0.0)
                                ]),
                                center: CGPoint(x: hx, y: hy),
                                startRadius: 0, endRadius: CGFloat(electronR * 2.8)
                            )
                        )
                        context.fill(
                            disc(hx, hy, electronR * 1.5),
                            with: .radialGradient(
                                Gradient(colors: [
                                    Color(.sRGB, red: 1.0, green: 1.0, blue: 1.0, opacity: 0.95),
                                    base.opacity(0.90),
                                    base.opacity(0.0)
                                ]),
                                center: CGPoint(x: hx, y: hy),
                                startRadius: 0, endRadius: CGFloat(electronR * 1.5)
                            )
                        )
                    }
                }
                context.blendMode = .normal
            }
        }
    }
}
