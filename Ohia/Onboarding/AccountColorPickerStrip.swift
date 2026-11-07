import SwiftUI
import SwiftData
import OhiaCore

/// Onboarding picker for the constellation color of the account being
/// connected. Twelve dots, each labelled with its stellar name; the
/// selected swatch is ringed in the foreground color. Indices already
/// taken by other persisted accounts — rare during a first-run flow but
/// real for users restarting after an abandoned session — render dimmed
/// and inert so the new account never collides on hue.
struct AccountColorPickerStrip: View {
    @Binding var selectedIndex: Int

    @Query private var allAccounts: [Account]

    private var usedIndices: Set<Int> {
        Set(allAccounts.compactMap { $0.colorIndex })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Account Color")
                .font(OhiaTypography.caption)
                .foregroundStyle(OhiaColors.textSecondary)

            // Flow the swatches into as many columns as fit, with a per-cell
            // minimum wide enough to keep the longest stellar name word (e.g.
            // "Betelgeuse") on a single line. Labels then word-wrap to two
            // lines instead of breaking mid-word or truncating with an
            // ellipsis. In the wizard's ~552pt column this lays out as two
            // rows of six.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 86), spacing: 6, alignment: .top)],
                spacing: 12
            ) {
                ForEach(AccountColorPalette.all) { color in
                    let isSelected = selectedIndex == color.id
                    let inUse = usedIndices.contains(color.id) && !isSelected
                    SwatchCell(color: color, isSelected: isSelected, inUse: inUse) {
                        selectedIndex = color.id
                    }
                }
            }
        }
    }
}

private struct SwatchCell: View {
    let color: AccountColor
    let isSelected: Bool
    let inUse: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(swiftUIColor)
                        .frame(width: 20, height: 20)
                    if isSelected {
                        Circle()
                            .strokeBorder(OhiaColors.textPrimary, lineWidth: 2)
                            .frame(width: 28, height: 28)
                    }
                }
                .frame(width: 28, height: 28)

                Text(color.name)
                    .font(.system(size: 10))
                    .foregroundStyle(
                        isSelected ? OhiaColors.textPrimary : OhiaColors.textSecondary
                    )
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(inUse ? 0.35 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(inUse)
        .help(inUse ? "\(color.name) — already in use" : color.name)
        .accessibilityLabel(color.name)
        .accessibilityValue(
            isSelected ? "Selected" : (inUse ? "In use by another account" : "Not selected")
        )
    }

    private var swiftUIColor: Color {
        let rgb = AccountColorPalette.rgb(for: color, brightness: 1.0)
        return Color(
            .sRGB,
            red: Double(rgb.x),
            green: Double(rgb.y),
            blue: Double(rgb.z),
            opacity: 1.0
        )
    }
}
