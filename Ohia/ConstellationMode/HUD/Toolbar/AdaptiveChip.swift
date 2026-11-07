import SwiftUI

/// Chip wrapper used inside `OverflowChipFlowLayout`. Holds a word
/// rendering and an icon rendering plus their measured widths. The body
/// reads the actual frame width chosen by the parent layout and renders
/// whichever mode fits — never both, never an abbreviation.
///
/// Word mode is always preferred when the layout proposes ≥ wordWidth;
/// otherwise the icon variant renders. Hover help follows the same contract:
/// word mode shows the description only, while icon mode prefixes that
/// description with the chip's full label so the collapsed control is
/// identifiable before it is explained.
public struct AdaptiveChip<Word: View, Icon: View>: View {
    public let wordWidth: CGFloat
    public let iconWidth: CGFloat
    public let isPressed: Bool
    private let wordTooltip: String?
    private let iconTooltip: String?
    @ViewBuilder public let wordView: () -> Word
    @ViewBuilder public let iconView: () -> Icon

    public init(
        wordWidth: CGFloat,
        iconWidth: CGFloat = 24,
        isPressed: Bool,
        tooltipLabel: String? = nil,
        tooltipDescription: String? = nil,
        @ViewBuilder word: @escaping () -> Word,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.wordWidth = wordWidth
        self.iconWidth = iconWidth
        self.isPressed = isPressed
        self.wordTooltip = Self.tooltipText(
            label: tooltipLabel,
            description: tooltipDescription,
            includeLabel: false
        )
        self.iconTooltip = Self.tooltipText(
            label: tooltipLabel,
            description: tooltipDescription,
            includeLabel: true
        )
        self.wordView = word
        self.iconView = icon
    }

    public var body: some View {
        // The parent layout proposes either wordWidth or iconWidth via
        // its place(_:proposal:) call. GeometryReader reports the actual
        // size we were proposed; we render word when there's room for it,
        // icon otherwise.
        GeometryReader { geo in
            let usesWord = geo.size.width + 0.5 >= wordWidth
            let tooltip = usesWord ? wordTooltip : iconTooltip
            Group {
                // Tolerance of 0.5pt absorbs rounding noise.
                if usesWord {
                    wordView()
                } else {
                    iconView()
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .leading
            )
            .hoverHelpIfPresent(tooltip)
        }
        .frame(height: 22)
    }

    private static func tooltipText(
        label: String?,
        description: String?,
        includeLabel: Bool
    ) -> String? {
        guard
            let description,
            !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let cleanedDescription = cleanTooltipFragment(description)
        guard includeLabel else { return cleanedDescription }

        guard
            let label,
            !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return cleanedDescription }

        let cleanedLabel = cleanTooltipFragment(label)
        if cleanedLabel.caseInsensitiveCompare(cleanedDescription) == .orderedSame {
            return cleanedDescription
        }
        return "\(cleanedLabel): \(cleanedDescription)"
    }

    private static func cleanTooltipFragment(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = cleaned.last, ".!?".contains(last) {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}

extension View {
    /// Apply the chip's word width, icon width, and pressed state as
    /// layout values so `OverflowChipFlowLayout` can read them when
    /// deciding render mode and overflow. Must be called on whichever
    /// view is the **direct child** of the layout — typically the Button
    /// wrapping `AdaptiveChip`. Setting the same modifiers inside
    /// `AdaptiveChip` doesn't propagate up to the Button, so the layout
    /// reads default zero values and treats every chip as zero-width.
    public func chipMetrics(
        wordWidth: CGFloat,
        iconWidth: CGFloat = 24,
        isPressed: Bool
    ) -> some View {
        self
            .chipWordWidth(wordWidth)
            .chipIconWidth(iconWidth)
            .chipPressed(isPressed)
    }
}

private extension View {
    @ViewBuilder
    func hoverHelpIfPresent(_ text: String?) -> some View {
        if let text {
            self
                .tooltip(text)
        } else {
            self
        }
    }
}
