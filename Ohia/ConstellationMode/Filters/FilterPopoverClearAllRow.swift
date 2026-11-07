import SwiftUI

/// Footer action rows appended to high-cardinality filter popovers such as
/// Topics. Sit below a hairline separator so they read as
/// distinct actions, not "another checkbox row." Disabled state mirrors
/// the rest visual of an unpressed chip — present but quiet — when the
/// action would be a no-op.
///
/// - `FilterPopoverClearAllRow`: deactivates every entry in one click.
/// - `FilterPopoverDisplayAllRow`: checks every entry in one click,
///   covering the "I want to see emails with any category" use case
///   without making the user tick 17 boxes individually.

struct FilterPopoverClearAllRow: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        FilterPopoverActionRow(
            iconSymbol: "xmark.circle",
            label: "Clear all",
            isEnabled: isEnabled,
            showSeparator: true,
            action: action
        )
    }
}

struct FilterPopoverDisplayAllRow: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        FilterPopoverActionRow(
            iconSymbol: "checkmark.circle",
            label: "Display all",
            isEnabled: isEnabled,
            showSeparator: false,
            action: action
        )
    }
}

private struct FilterPopoverActionRow: View {
    let iconSymbol: String
    let label: String
    let isEnabled: Bool
    let showSeparator: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showSeparator {
                Rectangle()
                    .fill(OhiaColors.glassBorder)
                    .frame(height: 1)
                    .padding(.top, 4)
            }
            Button(action: action) {
                HStack(spacing: 9) {
                    Image(systemName: iconSymbol)
                        .font(.system(size: 12))
                        .foregroundStyle(foreground)
                        .frame(width: 13, height: 13)
                    Text(label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(foreground)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }
    }

    private var foreground: Color {
        isEnabled ? OhiaColors.textSecondary : OhiaColors.textTertiary
    }
}
