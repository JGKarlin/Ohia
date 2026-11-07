import SwiftUI

/// Compact filter-state control for high-cardinality filter sections: one
/// discrete LED per filterable item, laid out as a horizontal
/// light strip. Each item owns a stable
/// slot — lit in the canonical Ohia accent (yellow in dark / green in light)
/// when active, dimmed when filtered out. Hashes with a non-nil `onToggle`
/// act as toggle buttons (the hit target absorbs the inter-hash gap so the
/// whole strip is clickable); entries without one stay purely informational.
/// Hovering a hash shows its category name.
///
/// The slot count is dynamic: Categories contains the shared purpose cases,
/// Lists, and however many custom categories the user has defined. Hashes use
/// fixed width and spacing; the lane grows by one hash plus one gap for every
/// custom category instead of redistributing space between existing hashes.
///
/// This is a roomy-window affordance. The strip claims exactly the width its
/// hashes require; when the ConstellationTopBar cannot grant that full width,
/// it drops out entirely instead of squeezing into illegibility.
struct FilterRatioBar: View {
    /// One hash in the strip: its category name (for the hover tooltip),
    /// whether it's currently included by the filter, and an optional tap
    /// handler. A non-nil `onToggle` makes the hash a toggle button; nil
    /// leaves it purely informational.
    struct Entry {
        let label: String
        let isActive: Bool
        let onToggle: (() -> Void)?

        init(label: String, isActive: Bool, onToggle: (() -> Void)? = nil) {
            self.label = label
            self.isActive = isActive
            self.onToggle = onToggle
        }
    }

    /// One entry per filterable item, in stable canonical order.
    let entries: [Entry]

    /// Bare-state initializer: hashes with no per-tick tooltip. Active-state
    /// semantics unchanged — `true` = lit pip, `false` = dim slot.
    init(states: [Bool]) {
        self.entries = states.map { Entry(label: "", isActive: $0) }
    }

    /// Labeled initializer: each hash carries a category name surfaced in a
    /// hover tooltip (dimmed when that category is filtered out).
    init(entries: [Entry]) {
        self.entries = entries
    }

    private let rowHeight: CGFloat = 22
    private let tickHeight: CGFloat = 14

    private var litCount: Int { entries.lazy.filter(\.isActive).count }
    private var requiredWidth: CGFloat {
        FilterRatioBarMetrics.width(entryCount: entries.count)
    }

    var body: some View {
        GeometryReader { proxy in
            let granted = proxy.size.width

            if granted >= requiredWidth {
                HStack(spacing: FilterRatioBarMetrics.gap) {
                    ForEach(entries.indices, id: \.self) { index in
                        let entry = entries[index]
                        let pip = RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(entry.isActive
                                ? OhiaColors.chipActiveForeground
                                : OhiaColors.chipActiveForeground.opacity(0.16))
                            .frame(width: FilterRatioBarMetrics.tickWidth, height: tickHeight)

                        if let onToggle = entry.onToggle {
                            Button(action: onToggle) {
                                pip
                                    // Expand the hit target to tick + gap so the
                                    // whole strip is clickable — no dead zones
                                    // between hashes. The pip's own frame keeps
                                    // it at nominal thickness; this outer frame
                                    // only widens the button's clickable area.
                                    .frame(
                                        width: FilterRatioBarMetrics.tickWidth
                                            + FilterRatioBarMetrics.gap,
                                        height: rowHeight
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // Reclaim the extra width so the HStack spacing stays
                            // governed by the fixed gap, not the widened button.
                            .frame(width: FilterRatioBarMetrics.tickWidth, height: rowHeight)
                            .tooltipImmediate(entry.label)
                        } else {
                            pip.tooltipImmediate(entry.label)
                        }
                    }
                }
                .frame(width: granted, height: rowHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(litCount) of \(entries.count) active")
    }
}

/// Geometry shared by `FilterRatioBar` and its `OverflowChipFlowLayout`
/// metrics. Seventeen built-in entries occupy 147 points; each additional
/// custom category adds one 3-point hash and one 5-point gap.
enum FilterRatioBarMetrics {
    static let tickWidth: CGFloat = 3
    static let gap: CGFloat = 5
    static let horizontalInset: CGFloat = 8

    static func width(entryCount: Int) -> CGFloat {
        guard entryCount > 0 else { return 0 }
        return horizontalInset * 2
            + CGFloat(entryCount) * tickWidth
            + CGFloat(entryCount - 1) * gap
    }
}
