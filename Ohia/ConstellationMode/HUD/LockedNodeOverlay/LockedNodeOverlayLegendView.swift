import SwiftUI

/// Mouse + keyboard navigation guide shown from the locked-node overlay's
/// help button. Mirrors the structure of `ConstellationLegendView` but
/// scopes content to the lock-overlay surface — the keyboard shortcuts
/// here (Tab, space, Esc) and the pointer affordances (chip clicks,
/// drag-to-move, right-click actions menu) are specific to the lock
/// overlay's pane index, annotation popups, and lock card.
struct LockedNodeOverlayLegendView: View {
    enum Scope {
        case generic
        case peopleFocus
    }

    private static let keyColumnWidth: CGFloat = 132
    let scope: Scope

    init(scope: Scope = .generic) {
        self.scope = scope
    }

    var body: some View {
        ConstellationLegendScrollContainer {
            VStack(alignment: .leading, spacing: 12) {
                Text("Legend")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OhiaColors.textPrimary)

                ConstellationShortcutLegendSection()
                Divider().background(OhiaColors.glassBorder)
                keyboardSection
                Divider().background(OhiaColors.glassBorder)
                pointerSection
            }
        }
    }

    @ViewBuilder
    private var keyboardSection: some View {
        sectionTitle("Keyboard")
        shortcutRow(keys: ["⇥"], detail: nextPaneDetail)
        shortcutRow(keys: ["⇧⇥"], detail: "previous pane")
        if scope == .peopleFocus {
            shortcutRow(keys: ["⌥⇥"], detail: "step strictly chronological, oldest → newest")
            shortcutRow(keys: ["⌥⇧⇥"], detail: "step strictly chronological, newest → oldest")
        }
        shortcutRow(keys: ["space"], detail: "toggle focus (summary • message)")
        shortcutRow(keys: ["esc"], detail: "Return to the constellation")
    }

    @ViewBuilder
    private var pointerSection: some View {
        sectionTitle("Mouse & Trackpad")
        shortcutRow(keys: ["click chip"], detail: "cycle panes within a kind")
        shortcutRow(keys: ["click ▸"], detail: "expand pane summary")
        shortcutRow(keys: ["click ✕"], detail: "close annotation pane")
        shortcutRow(keys: ["drag header"], detail: "reposition pane or card")
        shortcutRow(keys: ["drag corner"], detail: "resize email card")
        shortcutRow(keys: ["right-click"], detail: "message actions menu (Send to Composer when eligible · read · spam · categories · delete)")
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(OhiaTypography.telemetrySectionCaps)
            .tracking(0.6)
            .foregroundStyle(OhiaColors.textTertiary)
    }

    private var nextPaneDetail: String {
        switch scope {
        case .generic:
            return "next pane by relevance"
        case .peopleFocus:
            return "next pane (Sent → Sent·Included → Received → Included, newest first)"
        }
    }

    private func shortcutRow(keys: [String], detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    keyCap(key)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: Self.keyColumnWidth, alignment: .leading)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textSecondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(OhiaTypography.legendLine)
            .foregroundStyle(OhiaColors.textPrimary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(OhiaColors.surface(0.10))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
            }
    }
}
