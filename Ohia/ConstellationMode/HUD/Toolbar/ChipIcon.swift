import SwiftUI

/// Shared icon-mode chip styling used by every section's `AdaptiveChip`
/// icon variant. Matches `FilterChipLabel`'s frame chrome (height,
/// corner radius, fill / border tokens) so word and icon modes feel
/// like the same chip in two states.
@ViewBuilder
func chipIcon(systemName: String, isOn: Bool) -> some View {
    Image(systemName: systemName)
        .font(.system(size: 12, weight: isOn ? .semibold : .regular))
        .foregroundStyle(isOn
            ? OhiaColors.chipActiveForeground
            : OhiaColors.textSecondary)
        .frame(width: 24, height: 22)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isOn
                    ? OhiaColors.chipActiveBackground
                    : OhiaColors.chipRestBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isOn
                    ? OhiaColors.chipActiveBorder
                    : OhiaColors.chipRestBorder, lineWidth: 1)
        }
}
