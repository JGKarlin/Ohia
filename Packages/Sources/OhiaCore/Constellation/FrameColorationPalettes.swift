import Foundation
import simd

/// Pure color math for `FrameVisualLanguage.Coloration` variants. Returns
/// `SIMD4<Float>` so the renderer can bake values directly into instance
/// buffers — no AppKit / SwiftUI dependency, no appearance lookup. The
/// renderer modulates appearance at shader level via existing global
/// uniforms; these palettes provide the per-channel hue and saturation
/// only.
///
/// Mirrors the pattern of `AccountColorPalette`: HSV math returns RGBA
/// floats; brightness is passed in by the caller (typically derived from
/// message recency in the existing snapshot loader).
public enum FrameColorationPalettes {

    private static let ohiaGreenHue = 0.24166666666666667
    private static let ohiaGreenSaturation = 0.8695652173913043

    // MARK: - Arc (project / team / topic label hash → palette)

    /// Deterministic palette pick for an arc label. The same label string
    /// always produces the same SIMD4 — important because arc identity
    /// must read consistently across packets and across the user's
    /// lifetime in the corpus.
    ///
    /// 12 hues, saturation 0.50, value from `brightness` (caller-supplied,
    /// typically the per-message recency value the snapshot loader already
    /// computes). Hues are golden-ratio-spaced so visually adjacent
    /// hashes don't collide.
    public static func arcLabelTint(
        label: String,
        brightness: Double = 0.85
    ) -> SIMD4<Float> {
        let hue = arcLabelHue(label: label)
        return hsvToRGB(hue: hue, saturation: 0.50, brightness: brightness)
    }

    /// 0–1 hue value for the label. Stable across runs.
    public static func arcLabelHue(label: String) -> Double {
        let hash = fnv1a(label.lowercased())
        // Multiply by the golden ratio's fractional part so hues are
        // evenly distributed around the wheel for similar input strings.
        let phi: Double = 0.6180339887498949
        let fraction = Double(hash % 10_000) / 10_000.0
        let hue = (fraction + phi).truncatingRemainder(dividingBy: 1.0)
        return hue
    }

    /// FNV-1a 32-bit hash. Used both for the hue pick above and as the
    /// `labelHash` baked onto `SemanticNebulaInstance` so the renderer can
    /// detect "same arc" across packets.
    public static func fnv1a(_ string: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    // MARK: - Action heat (triage verdict → heat scale)

    /// Heat-scale tint for the triage obligation axes. Actionable is warm
    /// orange; requires-confirmation is Ohia green; neither is a muted
    /// grey-blue that recedes against the bright cases. Reply and confirmation
    /// are mutually exclusive (the binary obligation invariant), so the
    /// "both" quadrant is unreachable; if it is ever passed, a pending reply
    /// subsumes confirmation and it tints as actionable.
    public static func actionHeatTint(
        isActionable: Bool,
        requiresConfirmation: Bool,
        brightness: Double = 0.85
    ) -> SIMD4<Float> {
        let (hue, saturation): (Double, Double)
        switch (isActionable, requiresConfirmation) {
        case (true,  true):   (hue, saturation) = (0.07, 0.70)   // reply dominates → orange
        case (true,  false):  (hue, saturation) = (0.07, 0.70)   // orange
        case (false, true):   (hue, saturation) = (ohiaGreenHue, ohiaGreenSaturation)
        case (false, false):  (hue, saturation) = (0.60, 0.15)   // muted grey-blue
        }
        return hsvToRGB(hue: hue, saturation: saturation, brightness: brightness)
    }

    // MARK: - Purpose (MailPurpose → palette)

    /// Per-Purpose palette pick. Fixed assignments make the coloration stable;
    /// purposes without a distinct palette entry fall back to neutral grey.
    public static func purposeTint(
        purpose: MailPurpose,
        brightness: Double = 0.85
    ) -> SIMD4<Float> {
        let (hue, saturation) = purposeHueSaturation(purpose: purpose)
        return hsvToRGB(hue: hue, saturation: saturation, brightness: brightness)
    }

    private static func purposeHueSaturation(purpose: MailPurpose) -> (Double, Double) {
        switch purpose {
        case .correspondence:    return (0.30, 0.55)
        case .announcement:      return (0.05, 0.50)
        case .receipt:           return (0.13, 0.50)   // capella gold
        case .promotion:         return (0.95, 0.45)   // eagle pink
        case .newsletter:        return (0.76, 0.45)   // trapezium violet
        case .verificationCode:  return (0.55, 0.60)   // cygnus cyan
        case .notification:      return (0.62, 0.35)   // muted blue
        case .security:          return (0.02, 0.65)   // red-orange (security signals warm)
        case .shipping:          return (0.07, 0.55)   // arcturus orange
        case .travel:            return (0.10, 0.60)   // amber-orange
        case .finance:           return (0.42, 0.45)   // sea-green
        case .calendar:          return (0.18, 0.50)   // gold-yellow
        case .support:           return (0.55, 0.40)   // pale cyan
        case .legal:             return (0.70, 0.35)   // muted indigo
        case .socialActivity:    return (0.88, 0.40)   // rosette magenta
        case .other:             return (0.60, 0.10)   // near-neutral grey-blue
        }
    }

    // MARK: - Recency saturation multiplier (correspondent-ranking only)

    /// Saturation multiplier in `[0.30, 1.0]` as a function of age in days.
    /// Continuous so adjacent dates render close, monotonic so the gradient
    /// is unambiguous. The recency-tint *color* helper retired alongside
    /// the Timeline Metal scene; this multiplier is retained because
    /// `ConstellationRenderPlanner.recencyWeight(...)` reuses the same
    /// curve to rank major correspondents by recency.
    public static func recencySaturationMultiplier(ageDays: Double) -> Double {
        // Smoothed piecewise — full saturation through ~7 days, then a
        // gentle decay; floor at 0.30 so old mail keeps some hue.
        if ageDays <= 7 { return 1.0 }
        let normalized = min(1.0, (ageDays - 7) / 365.0)
        let eased = 1.0 - normalized * normalized
        return max(0.30, 0.30 + (1.0 - 0.30) * eased)
    }

    // MARK: - Correspondent palette helpers

    /// Returns the long-tail correspondent color — a desaturated version
    /// of the base color used for senders who aren't in the user's major
    /// set. Major correspondents render in their own AccountColor /
    /// per-correspondent palette; the long tail recedes.
    public static func neutralCorrespondent(base: SIMD4<Float>) -> SIMD4<Float> {
        desaturate(base, by: 0.30)
    }

    // MARK: - Shared math

    /// In-place saturation multiplier on an RGBA color (alpha preserved).
    /// `multiplier == 1.0` returns the input unchanged; `multiplier == 0.0`
    /// returns full grey.
    public static func desaturate(_ rgba: SIMD4<Float>, by multiplier: Double) -> SIMD4<Float> {
        let m = Float(max(0.0, min(1.0, multiplier)))
        // Rec. 709 luma weights for perceptual grey baseline.
        let grey = 0.2126 * rgba.x + 0.7152 * rgba.y + 0.0722 * rgba.z
        return SIMD4<Float>(
            grey + (rgba.x - grey) * m,
            grey + (rgba.y - grey) * m,
            grey + (rgba.z - grey) * m,
            rgba.w
        )
    }

    /// HSV → RGB conversion identical in math to `AccountColorPalette` so
    /// frame palettes and account palettes blend without seam.
    public static func hsvToRGB(
        hue: Double,
        saturation: Double,
        brightness: Double
    ) -> SIMD4<Float> {
        let h = (hue.truncatingRemainder(dividingBy: 1.0) + 1.0)
            .truncatingRemainder(dividingBy: 1.0)
        let s = max(0.0, min(1.0, saturation))
        let v = max(0.0, min(1.0, brightness))
        let c = v * s
        let x = c * (1.0 - abs((h * 6.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = v - c

        let rgb: SIMD3<Double>
        switch h * 6.0 {
        case 0..<1: rgb = SIMD3(c, x, 0)
        case 1..<2: rgb = SIMD3(x, c, 0)
        case 2..<3: rgb = SIMD3(0, c, x)
        case 3..<4: rgb = SIMD3(0, x, c)
        case 4..<5: rgb = SIMD3(x, 0, c)
        default:    rgb = SIMD3(c, 0, x)
        }
        return SIMD4<Float>(
            Float(rgb.x + m),
            Float(rgb.y + m),
            Float(rgb.z + m),
            1
        )
    }
}
