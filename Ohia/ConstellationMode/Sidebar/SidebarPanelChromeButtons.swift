import SwiftUI

/// Shared trailing chrome for Constellation side panels (Search/Ask and
/// Withheld): close control, matching pill size and accent treatment.
struct SidebarPanelChromeButtons: View {
    let closeLabel: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            SidebarCloseButton(label: closeLabel, action: onClose)
        }
        .layoutPriority(1)
    }
}

/// Dismisses a top-level surface. The active-accent disc and knocked-out X stay
/// unchanged on hover; only the inverse-accent edge ring and subtle lift signal
/// hover. Close is neutral chrome rather than a destructive removal action.
struct SidebarCloseButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ActionDiscGlyphView(
                glyph: .native("xmark.circle.fill"),
                tint: OhiaColors.chipActiveForeground,
                size: 16
            )
            .frame(width: 26, height: 24)
            .overlay {
                if isHovering {
                    Circle()
                        .stroke(OhiaColors.clusterHoverFillOnAccent, lineWidth: 1.5)
                        .frame(width: 17, height: 17)
                }
            }
            .scaleEffect(isHovering ? 1.08 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
        }
    }
}
