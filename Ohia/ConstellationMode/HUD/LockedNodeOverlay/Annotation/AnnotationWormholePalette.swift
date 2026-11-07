import SwiftUI
import OhiaCore

struct AnnotationWormholePalette: Sendable, Equatable {
    struct Component: Sendable, Equatable {
        let hue: Double
        let saturation: Double
        let brightness: Double
        let opacity: Double
        let isWhite: Bool

        var color: Color {
            if isWhite {
                return Color.white.opacity(opacity)
            }
            return Color(
                hue: hue,
                saturation: saturation,
                brightness: brightness,
                opacity: opacity
            )
        }

        static func white(opacity: Double) -> Component {
            Component(
                hue: 0,
                saturation: 0,
                brightness: 1,
                opacity: clamped(opacity),
                isWhite: true
            )
        }

        static func accountHue(
            _ hue: Double,
            saturation: Double,
            brightness: Double,
            opacity: Double
        ) -> Component {
            Component(
                hue: normalizedHue(hue),
                saturation: clamped(saturation),
                brightness: clamped(brightness),
                opacity: clamped(opacity),
                isWhite: false
            )
        }
    }

    let core: Component
    let halo: Component
    let mid: Component
    let outer: Component
    let dashedRing: Component
    let innerRipple: Component
    let outerRipple: Component

    static func account(_ accountColor: AccountColor) -> AnnotationWormholePalette {
        let baseHue = normalizedHue(accountColor.hue)
        // Low-saturation account colours still need enough chroma to read as a
        // wormhole; the white core carries brightness, while these stops carry
        // account identity.
        let baseSaturation = max(0.28, min(accountColor.saturation, 0.82))
        let vividSaturation = min(baseSaturation + 0.18, 0.92)
        let midSaturation = min(baseSaturation + 0.12, 0.86)
        let outerSaturation = min(baseSaturation + 0.22, 0.90)

        return AnnotationWormholePalette(
            core: .white(opacity: 0.95),
            halo: .accountHue(
                baseHue,
                saturation: vividSaturation,
                brightness: 1.0,
                opacity: 0.80
            ),
            mid: .accountHue(
                baseHue + 0.055,
                saturation: midSaturation,
                brightness: 0.96,
                opacity: 0.54
            ),
            outer: .accountHue(
                baseHue - 0.065,
                saturation: outerSaturation,
                brightness: 0.86,
                opacity: 0.13
            ),
            dashedRing: .accountHue(
                baseHue,
                saturation: vividSaturation,
                brightness: 1.0,
                opacity: 0.72
            ),
            innerRipple: .accountHue(
                baseHue + 0.055,
                saturation: midSaturation,
                brightness: 0.95,
                opacity: 0.38
            ),
            outerRipple: .accountHue(
                baseHue - 0.065,
                saturation: outerSaturation,
                brightness: 0.84,
                opacity: 0.28
            )
        )
    }
}

private func normalizedHue(_ hue: Double) -> Double {
    (hue.truncatingRemainder(dividingBy: 1.0) + 1.0)
        .truncatingRemainder(dividingBy: 1.0)
}

private func clamped(_ value: Double) -> Double {
    min(max(value, 0), 1)
}
