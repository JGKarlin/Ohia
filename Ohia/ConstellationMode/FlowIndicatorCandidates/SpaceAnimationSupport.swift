// SpaceAnimationSupport.swift
// Shared contract + helpers for the pipeline-flow indicator animation candidates.
//
// Each candidate is a self-contained SwiftUI `Canvas` view that renders a
// looping, space-themed motion expressing "the pipeline is running at full
// speed." The chosen one will replace the SF-symbol flow indicator at the
// activity strip's trailing edge (real footprint: ~70 × 36 pt, the HUD control
// column width by the strip's content-row height), so every candidate must
// read at that tiny size AND scale up richly for the design inspector.
//
// Contract every candidate conforms to (informal — a plain initializer, no
// protocol, so the gallery can hold them heterogeneously):
//
//     struct <Name>FlowAnimation: View {
//         let time: TimeInterval   // monotonic elapsed seconds from a shared clock
//         let reduceMotion: Bool   // true → render one composed still, no motion
//         init(time: TimeInterval, reduceMotion: Bool)
//         var body: some View      // a Canvas that fills whatever frame it is given
//     }
//
// Rules:
//  - Motion is a PURE FUNCTION of `time` (no @State mutation across frames) so
//    the gallery can drive every tile from one TimelineView clock and so the
//    loop is reproducible.
//  - Loop SEAMLESSLY: at the period boundary there must be no visible pop.
//  - Scale detail (particle counts, ray density) to the drawing area so the
//    70 × 36 tile stays cheap while the large inspector looks intricate.
//  - Palette is NOT constrained to Ohia's green/yellow — use astronomically
//    appropriate colors on near-black. Use `Color(spaceHex:)`.
//  - Determinism via `SpaceFieldRandom`. No external images or assets.
//  - No `#if DEBUG` in the candidate files: the winner ships in a release build.

import SwiftUI

// MARK: - Deterministic RNG (SplitMix64)

/// Seedable, value-stable generator so every candidate's field is identical
/// frame to frame and run to run. Mirrors the SplitMix64 used by NightSkyView,
/// duplicated here so the candidate views have no cross-file coupling.
struct SpaceFieldRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Avoid the zero fixed point; any nonzero seed is fine.
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform Double in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Uniform Double in [lower, upper).
    mutating func range(_ lower: Double, _ upper: Double) -> Double {
        lower + (upper - lower) * unit()
    }

    /// Standard-normal sample via Box–Muller.
    mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12)
        let u2 = unit()
        return (-2.0 * Foundation.log(u1)).squareRoot() * Foundation.cos(2.0 * .pi * u2)
    }
}

// MARK: - Hex color

extension Color {
    /// Build a color from a 0xRRGGBB literal — the candidate palettes are
    /// specified as astronomical hex values, not Ohia tokens.
    init(spaceHex: UInt32, opacity: Double = 1.0) {
        let r = Double((spaceHex >> 16) & 0xFF) / 255.0
        let g = Double((spaceHex >> 8) & 0xFF) / 255.0
        let b = Double(spaceHex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Shared math

enum SpaceAnimationMath {
    /// Ease-in-out smoothstep on [0, 1].
    static func smoothstep(_ x: Double) -> Double {
        let v = min(1, max(0, x))
        return v * v * (3 - 2 * v)
    }

    /// Fractional part in [0, 1), safe for negative inputs.
    static func fract(_ x: Double) -> Double {
        x - x.rounded(.down)
    }

    /// A triangle wave on [0, 1] with period 1 — seamless, symmetric.
    static func triangle(_ x: Double) -> Double {
        let f = fract(x)
        return f < 0.5 ? f * 2 : (1 - f) * 2
    }
}
