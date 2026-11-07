import Foundation
import simd

public enum SemanticEdgeReasonKind: String, Sendable, Hashable, Codable, CaseIterable {
    case tag
    case purpose

    public var displayLabel: String {
        switch self {
        case .tag: return "tag"
        case .purpose: return "purpose"
        }
    }
}

/// Human-readable semantic reason carried by Meaning-lens fibres.
///
/// The numeric edge strength still decides visual weight. This payload explains
/// why the relationship is visible: a shared canonical tag first,
/// or a shared purpose category when no narrower meaning overlaps.
public struct SemanticEdgeReason: Sendable, Equatable, Codable {
    public let kind: SemanticEdgeReasonKind
    public let label: String
    public let score: Float
    public let isSecondary: Bool

    public init(
        kind: SemanticEdgeReasonKind,
        label: String,
        score: Float,
        isSecondary: Bool = false
    ) {
        self.kind = kind
        self.label = label
        self.score = max(0, min(1, score))
        self.isSecondary = isSecondary
    }

    public var relationshipLine: String {
        let displayed: String
        switch kind {
        case .purpose:
            displayed = MailPurpose(rawValue: label)?.displayLabel ?? label
        case .tag:
            displayed = label
        }
        return "Related by \(kind.displayLabel): \(displayed)."
    }

    public var tint: SIMD3<Float> {
        let normalizedScore = max(0, min(1, score))
        let brightness = Double(0.76 + normalizedScore * 0.20)
        let raw: SIMD4<Float>
        switch kind {
        case .tag:
            raw = FrameColorationPalettes.arcLabelTint(
                label: "\(kind.rawValue):\(label)",
                brightness: brightness
            )
        case .purpose:
            if let purpose = MailPurpose(rawValue: label) {
                raw = FrameColorationPalettes.purposeTint(purpose: purpose, brightness: brightness)
            } else {
                raw = FrameColorationPalettes.arcLabelTint(
                    label: "purpose-invalid:\(label)",
                    brightness: brightness
                )
            }
        }
        return Self.meaningFiberTint(
            from: raw,
            kind: kind,
            score: normalizedScore,
            isSecondary: isSecondary
        )
    }

    private static func meaningFiberTint(
        from raw: SIMD4<Float>,
        kind: SemanticEdgeReasonKind,
        score: Float,
        isSecondary: Bool
    ) -> SIMD3<Float> {
        let base = SIMD3<Float>(0.30, 0.36, 0.46)
        let rgb = SIMD3<Float>(raw.x, raw.y, raw.z)
        let (saturationMultiplier, secondaryMix): (Float, Float)
        switch kind {
        case .tag:
            saturationMultiplier = 1.42
            secondaryMix = isSecondary ? 0.14 : 0
        case .purpose:
            saturationMultiplier = isSecondary ? 1.08 : 1.52
            secondaryMix = isSecondary ? 0.32 : 0.08
        }

        let scoreLift = 0.88 + max(0, min(1, score)) * 0.12
        let vivid = adjustSaturation(rgb, by: saturationMultiplier) * scoreLift
        return clamp(mix(vivid, base, secondaryMix))
    }

    private static func mix(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
        let t = max(0, min(1, amount))
        return lhs * (1 - t) + rhs * t
    }

    private static func adjustSaturation(_ rgb: SIMD3<Float>, by multiplier: Float) -> SIMD3<Float> {
        let m = max(0, multiplier)
        let grey = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        let neutral = SIMD3<Float>(repeating: grey)
        return neutral + (rgb - neutral) * m
    }

    private static func clamp(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            max(0, min(1, value.x)),
            max(0, min(1, value.y)),
            max(0, min(1, value.z))
        )
    }
}
