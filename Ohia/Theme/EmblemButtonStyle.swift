// Ohia/Theme/EmblemButtonStyle.swift
// The app's signature action affordance, codified as a reusable ButtonStyle.
//
// Per docs/design-system.md §3.7: flat `ohiaGreen` foreground (text + icon)
// inside a 1pt `ohiaYellow` strokeBorder over a faint `buttonBackground`
// fill, with 8pt corners. The framing (fill + border + corner) is
// INVARIANT — only the foreground (`tint`) changes to signal role/state.
// Destructive call sites pass `OhiaColors.ohiaRed`; error / unavailable
// states pass `OhiaColors.frameUrgencyHigh`.
//
// Reference implementation: WelcomeStepView's "Get Started" pill. This
// style replaces the inline duplication of that motif (AskInputArea,
// AskVoiceButton, MemoryEmblemButton) at the call sites that adopt it.

import SwiftUI

struct EmblemButtonStyle: ButtonStyle {
    /// Foreground for label + icon. Defaults to the leaf-green emblem hue.
    var tint: Color = OhiaColors.ohiaGreen
    /// Interior padding. Defaults suit caption-sized Settings buttons;
    /// larger CTAs widen via the initializer.
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        EmblemLabel(
            configuration: configuration,
            tint: tint,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        )
    }

    // Nested so the style can read `\.isEnabled` and dim the disabled
    // state (ButtonStyle.Configuration alone exposes only `isPressed`).
    private struct EmblemLabel: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(tint)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(OhiaColors.buttonBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

extension ButtonStyle where Self == EmblemButtonStyle {
    /// `.buttonStyle(.emblem)` — leaf-green emblem action button.
    static var emblem: EmblemButtonStyle { EmblemButtonStyle() }

    /// `.buttonStyle(.emblem(tint:))` — emblem framing with a role-driven
    /// foreground (e.g. `OhiaColors.ohiaRed` for destructive actions).
    static func emblem(tint: Color) -> EmblemButtonStyle {
        EmblemButtonStyle(tint: tint)
    }
}
