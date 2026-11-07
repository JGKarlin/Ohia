import SwiftUI
import OhiaCore

public struct ConstellationLegendView: View {
    private static let keyColumnWidth: CGFloat = 132

    public let hasSearch: Bool
    public let hasCitations: Bool
    /// `true` when a node is locked. Surfaces the lock-only affordances at the
    /// top of each input-device section (keyboard: N/P/esc; pointer: pane
    /// drag/resize and close/expand) and hides the unlocked hover/click rows.
    public let hasSelection: Bool
    public let hasNebulae: Bool
    public let hasFibers: Bool
    /// `true` in the Meaning lens, where meaning-cluster orbs add click
    /// (filter to cluster) and right-click (cluster filter menu) affordances.
    public let showsClusterActions: Bool
    /// `true` in the People lens's solar system, where the orbit grammar
    /// (distance = recency, speed = owed attention, shape = reciprocity,
    /// dashed arc = broadcast) needs a reading key.
    public let showsOrbitGrammar: Bool

    public init(
        hasSearch: Bool,
        hasCitations: Bool,
        hasSelection: Bool,
        hasNebulae: Bool,
        hasFibers: Bool,
        showsClusterActions: Bool = false,
        showsOrbitGrammar: Bool = false
    ) {
        self.hasSearch = hasSearch
        self.hasCitations = hasCitations
        self.hasSelection = hasSelection
        self.hasNebulae = hasNebulae
        self.hasFibers = hasFibers
        self.showsClusterActions = showsClusterActions
        self.showsOrbitGrammar = showsOrbitGrammar
    }

    public var body: some View {
        ConstellationLegendScrollContainer {
            VStack(alignment: .leading, spacing: 12) {
                Text("Legend")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
                ConstellationShortcutLegendSection()
                Divider().background(OhiaColors.glassBorder)
                if showsOrbitGrammar {
                    orbitGrammarSection
                    Divider().background(OhiaColors.glassBorder)
                }
                keyboardSection
                if hasSearch {
                    Divider().background(OhiaColors.glassBorder)
                    searchSection
                }
                Divider().background(OhiaColors.glassBorder)
                pointerSection
                Divider().background(OhiaColors.glassBorder)
                selectionSection
            }
        }
    }

    @ViewBuilder
    private var orbitGrammarSection: some View {
        sectionTitle("Orbits")
        shortcutRow(keys: ["distance"], detail: "recency — inner orbits are fresher; band rings mark 1 day · 1 week · 1 month · 3 months · 1 year · 2 years")
        shortcutRow(keys: ["speed"], detail: "owed attention — open asks quicken the orbit; a petal-red rim marks them while the system is still")
        shortcutRow(keys: ["shape"], detail: "reciprocity — near-circles are balanced relationships; long ellipses are one-sided")
        shortcutRow(keys: ["dashed arc"], detail: "broadcast — newsletters and no-reply senders ride comet arcs")
        shortcutRow(keys: ["hover a body"], detail: "stills the system while you rest on it; leaving resumes the motion gently")
        shortcutRow(keys: ["sun"], detail: "you — hover for totals · click to reframe the whole system")
    }

    @ViewBuilder
    private var keyboardSection: some View {
        sectionTitle("Keyboard")
        if hasSelection {
            shortcutRow(keys: ["N", "P"], detail: "step neighbours by affinity (next · prev)")
            shortcutRow(keys: ["esc"], detail: "exit affinity step · release lock")
        }
        shortcutRow(keys: ["W", "A", "S", "D"], detail: "fly forward · strafe · back")
        shortcutRow(keys: ["⇧ W A S D"], detail: "fast fly forward · strafe · back")
        shortcutRow(keys: ["Q", "E"], detail: "descend · ascend")
        shortcutRow(keys: ["←", "↑", "↓", "→"], detail: "yaw · pitch")
        shortcutRow(keys: ["<", ">"], detail: "orbit left · right")
        shortcutRow(keys: ["−", "="], detail: "aperture tighten · widen")
    }

    @ViewBuilder
    private var searchSection: some View {
        sectionTitle("Search")
        shortcutRow(keys: ["⌘", "return"], detail: "warp to selected match")
        shortcutRow(keys: ["⌘ G", "⇧⌘ G"], detail: "step matches")
        shortcutRow(keys: ["tab", "⇧ tab"], detail: "step matches after warp")
    }

    @ViewBuilder
    private var pointerSection: some View {
        sectionTitle("Mouse & Trackpad")
        if hasSelection {
            shortcutRow(keys: ["drag header"], detail: "reposition pane")
            shortcutRow(keys: ["drag corner"], detail: "resize email card")
            shortcutRow(keys: ["✕"], detail: "close annotation pane")
            shortcutRow(keys: ["▸"], detail: "expand pane summary")
        }
        shortcutRow(keys: ["drag"], detail: "yaw · pitch")
        shortcutRow(keys: ["scroll"], detail: "fly forward · back")
        shortcutRow(keys: ["⇧ scroll"], detail: "pan across the field")
        shortcutRow(keys: ["⌥ scroll"], detail: "orbit around focus")
        shortcutRow(keys: ["pinch"], detail: "aperture")
    }

    @ViewBuilder
    private var selectionSection: some View {
        sectionTitle("Selection")
        if !hasSelection {
            shortcutRow(keys: ["hover"], detail: "preview node")
            shortcutRow(keys: ["click"], detail: "zoom to node")
            if showsClusterActions {
                shortcutRow(keys: ["click"], detail: "cluster — filter the scene to it")
                shortcutRow(keys: ["right-click"], detail: "cluster — filter to it · remove the cluster filter")
                shortcutRow(keys: ["esc"], detail: "clear the active cluster filter")
            }
        }
        shortcutRow(keys: ["right-click"], detail: "message actions menu (Send to Composer when eligible · read · spam · categories · delete)")
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(OhiaTypography.telemetrySectionCaps)
            .tracking(0.6)
            .foregroundStyle(OhiaColors.textTertiary)
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

struct ConstellationLegendScrollContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .padding(14)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: 560)
        .background(OhiaColors.spaceBackground.opacity(0.96))
    }
}

struct ConstellationShortcutLegendSection: View {
    private static let keyColumnWidth: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("App Shortcuts")
                .font(OhiaTypography.telemetrySectionCaps)
                .tracking(0.6)
                .foregroundStyle(OhiaColors.textTertiary)

            ForEach(ConstellationShortcutLegendModel.entries, id: \.self) { entry in
                shortcutRow(entry)
            }
        }
    }

    private func shortcutRow(
        _ entry: ConstellationShortcutLegendEntry
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            keyCap(entry.keys)
                .frame(width: Self.keyColumnWidth, alignment: .leading)
            Text(entry.detail)
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
