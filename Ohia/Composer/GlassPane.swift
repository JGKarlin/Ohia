// Ohia/Composer/GlassPane.swift
import SwiftUI

/// Composer panel chrome. The type name is retained because the Composer
/// workflow already uses it widely, but the visual language now follows the
/// Constellation toolbar: solid tokenized surfaces, quiet hairline borders,
/// and the single Ohia active accent only for focused state.
struct GlassPane<Content: View>: View {
    let isForeground: Bool
    let isFocused: Bool
    let horizontalPadding: CGFloat
    @ViewBuilder let content: Content

    init(
        accentColor _: Color = OhiaColors.chipActiveForeground,
        isForeground: Bool = true,
        isFocused: Bool = false,
        horizontalPadding: CGFloat = 12,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isForeground = isForeground
        self.isFocused = isFocused
        self.horizontalPadding = horizontalPadding
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)

        content
            .padding(.vertical, 12)
            .padding(.horizontal, horizontalPadding)
            .background(
                shape.fill(isForeground
                    ? OhiaColors.composerRaisedPanelBackground
                    : OhiaColors.composerPanelBackground)
            )
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: borderWidth)
            }
            .compositingGroup()
            .clipShape(shape)
    }

    private var borderColor: Color {
        isFocused ? OhiaColors.chipActiveBorder : OhiaColors.iconPillBorder
    }

    private var borderWidth: CGFloat {
        isFocused ? 1 : 0.5
    }
}

/// Shared Composer section header, aligned with `ConstellationTopBar`'s
/// icon-pill + normal-case title vocabulary.
struct ComposerSectionHeader: View {
    let title: String
    let symbolName: String
    var count: Int?
    var accessory: String?
    /// Title weight and size; defaults match the standard section header. Opt
    /// in to a heavier/larger title per call site for emphasized headers.
    var titleWeight: Font.Weight = .medium
    var titleSize: CGFloat = 11.5

    var body: some View {
        HStack(spacing: 6) {
            ComposerSectionIcon(symbolName: symbolName)

            Text(title)
                .font(.system(size: titleSize, weight: titleWeight))
                .foregroundStyle(OhiaColors.textPrimary)
                .fixedSize(horizontal: true, vertical: false)

            if let count {
                ComposerSectionCountBadge(count: count)
            }

            if let accessory, !accessory.isEmpty {
                Text(accessory.uppercased())
                    .font(.system(size: 9))
                    .tracking(1.0)
                    .foregroundStyle(OhiaColors.textTertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

/// The icon pill that leads every Composer section header; also carried by
/// a closed column's rail.
struct ComposerSectionIcon: View {
    static let width: CGFloat = 22

    let symbolName: String

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 12))
            .foregroundStyle(OhiaColors.iconPillForeground)
            .frame(width: Self.width, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(OhiaColors.iconPillBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// The count badge beside a Composer section title.
struct ComposerSectionCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(OhiaTypography.cardSignal.monospacedDigit())
            .foregroundStyle(OhiaColors.textTertiary)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(OhiaColors.chipRestBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
            }
    }
}
