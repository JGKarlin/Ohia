import SwiftUI
import OhiaCore

/// Scope chooser rendered as an adaptive chip strip. Each `FrameKey` chip
/// shows its title text at full width and collapses to an SF Symbol (from
/// `ToggleIconography`) as the bar narrows — driven by the
/// `OverflowChipFlowLayout` parent enabled via `useOverflowFlow: true` on
/// the section's `ToolbarSection`. The selected chip uses the toolbar's
/// active accent tint so the current spatial scope, including the default
/// Meaning scope, reads as on. `AdaptiveChip` builds the per-mode tooltip
/// (description alone in word mode, prefixed with the title in icon mode)
/// so the collapsed control stays identifiable.
///
/// `displayed` is the user-curated subset of frames to render as chips
/// (configured via the section's icon-pulldown menu in `ConstellationTopBar`).
/// Frames omitted from the set drop out of the strip; the active frame keeps
/// rendering at the renderer level regardless of whether its chip is visible.
public struct FrameSelectorBar: View {
    @Binding public var activeFrame: FrameKey
    public let displayed: Set<FrameKey>
    public let onSelect: (FrameKey) -> Void

    /// Canonical frame roster shared with the icon-pulldown menu so the
    /// chip strip and the menu read from the same source of truth.
    public static let allFrames: [(key: FrameKey, title: String, description: String)] = [
        (.frontPage,     "Digest",        "Read your newest and most important mail first."),
        (.meaning,       "Meanings",      "Explore mail grouped by meaning and shared context."),
        (.people,        "Correspondents", "Browse mail organized by correspondent."),
        (.projects,      "Projects",      "Track project correspondence, progress, and deadlines."),
        (.timeline,      "Timeline",      "Read mail chronologically along a spatial timeline.")
    ]

    /// User-facing title for `frame`. Falls back to the raw value when a
    /// fork registers a custom frame outside the canonical roster.
    public static func title(for frame: FrameKey) -> String {
        allFrames.first(where: { $0.key == frame.spatialLens })?.title
            ?? frame.rawValue.capitalized
    }

    public init(
        activeFrame: Binding<FrameKey>,
        displayed: Set<FrameKey>,
        onSelect: @escaping (FrameKey) -> Void
    ) {
        self._activeFrame = activeFrame
        self.displayed = displayed
        self.onSelect = onSelect
    }

    public var body: some View {
        let selectedFrame = activeFrame.spatialLens
        let visible = Self.allFrames.filter { displayed.contains($0.key) }
        ForEach(visible, id: \.key) { f in
            segment(
                key: f.key,
                selectedFrame: selectedFrame,
                title: f.title,
                description: f.description
            )
        }
    }

    @ViewBuilder
    private func segment(
        key: FrameKey,
        selectedFrame: FrameKey,
        title: String,
        description: String
    ) -> some View {
        let isSelected = (key == selectedFrame)
        let wordWidth = title.chipWordWidth(bold: isSelected)
        Button {
            onSelect(key)
        } label: {
            AdaptiveChip(
                wordWidth: wordWidth,
                isPressed: isSelected,
                tooltipLabel: title,
                tooltipDescription: description,
                word: { FilterChipLabel(text: title, isOn: isSelected) },
                icon: {
                    chipIcon(
                        systemName: ToggleIconography.symbolName(for: key),
                        isOn: isSelected
                    )
                }
            )
        }
        .buttonStyle(.plain)
        .chipMetrics(wordWidth: wordWidth, isPressed: isSelected)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Active" : "Inactive")
        .accessibilityHint(description)
    }
}
