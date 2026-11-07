import SwiftUI
import OhiaCore
import AppKit

/// SwiftUI driver for `OverflowChipOrdering`. Reads each subview's word
/// width, icon width, and pressed state via `LayoutValueKey`s, computes a
/// per-chip render mode (`.word` / `.icon`) plus a hidden count, then
/// places visible subviews left-to-right at the chosen mode's width.
///
/// Subviews must:
///   * Set their word width via `.chipWordWidth(_:)`.
///   * Set their icon width via `.chipIconWidth(_:)`.
///   * Set pressed state via `.chipPressed(_:)`.
///   * Adapt their content to the proposed width — see `AdaptiveChip`.
///
/// `hiddenCount` is published into the supplied binding so the section's
/// menu-pill can light its overflow dot.
struct OverflowChipFlowLayout: Layout {
    let spacing: CGFloat
    @Binding var hiddenCount: Int

    init(spacing: CGFloat = 4, hiddenCount: Binding<Int>) {
        self.spacing = spacing
        self._hiddenCount = hiddenCount
    }

    struct Cache {
        var wordWidths: [Double] = []
        var iconWidths: [Double] = []
        var pressed: [Bool] = []
        var wordsTotal: CGFloat = 0
        var iconsTotal: CGFloat = 0
        private var pendingHiddenCount: Int?
        private var pendingWidth: CGFloat?
        private var stableHiddenCountPasses = 0
        private var publishedHiddenCount: Int?

        init() {}

        init(subviews: Subviews, spacing: CGFloat) {
            update(subviews: subviews, spacing: spacing)
        }

        mutating func update(subviews: Subviews, spacing: CGFloat) {
            wordWidths = subviews.map { Double($0[ChipWordWidthKey.self]) }
            iconWidths = subviews.map { Double($0[ChipIconWidthKey.self]) }
            pressed = subviews.map { $0[ChipPressedKey.self] }

            let count = subviews.count
            let totalSpacing = spacing * CGFloat(max(0, count - 1))
            wordsTotal = CGFloat(wordWidths.reduce(0, +)) + totalSpacing
            iconsTotal = CGFloat(iconWidths.reduce(0, +)) + totalSpacing
        }

        mutating func shouldPublishHiddenCount(_ hiddenCount: Int, width: CGFloat) -> Bool {
            guard width.isFinite, width > 0 else { return false }
            let quantizedWidth = width.rounded(.toNearestOrAwayFromZero)
            if pendingHiddenCount == hiddenCount,
               let pendingWidth,
               abs(pendingWidth - quantizedWidth) < 0.5 {
                stableHiddenCountPasses += 1
            } else {
                pendingHiddenCount = hiddenCount
                pendingWidth = quantizedWidth
                stableHiddenCountPasses = 1
            }

            guard stableHiddenCountPasses >= 2 else { return false }
            if publishedHiddenCount == hiddenCount { return false }
            publishedHiddenCount = hiddenCount
            return true
        }
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(subviews: subviews, spacing: spacing)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.update(subviews: subviews, spacing: spacing)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        // Be a flexible layout, not a fixed-size one. SwiftUI's HStack
        // distribution interprets sizeThatFits as "ideal at this proposal";
        // a Layout that always returns its words-total ignores tighter
        // proposals and reports a fixed size, which makes the parent
        // HStack treat it as inflexible and allocate it equal share with
        // the rest. Reporting a bounded range — icons-total floor,
        // words-total ceiling, proposed-clamped between — lets SwiftUI
        // give the section more room than its peers when chips justify
        // it, and squeezes us first when the bar narrows.
        let proposed = proposal.width
        if proposed == nil || (proposed?.isFinite == false) {
            // No constraint — give back the full word-mode ideal.
            return CGSize(width: cache.wordsTotal, height: 22)
        }
        let availableWidth = max(0, proposed!)
        if cache.wordsTotal <= availableWidth {
            return CGSize(width: cache.wordsTotal, height: 22)
        }
        if cache.iconsTotal <= availableWidth {
            return CGSize(width: cache.iconsTotal, height: 22)
        }

        // Below icons-only width the resolver hides lower-priority chips to
        // fit the proposal, so the layout should accept the constrained width.
        return CGSize(width: availableWidth, height: 22)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let result = OverflowChipOrdering.resolve(
            wordWidths: cache.wordWidths,
            iconWidths: cache.iconWidths,
            pressed: cache.pressed,
            availableWidth: Double(bounds.width),
            spacing: Double(spacing)
        )

        // Publish hiddenCount so the section's menu-pill can light its
        // overflow dot. Dispatched async to avoid mutating state during
        // a SwiftUI layout pass.
        let n = result.hiddenCount
        if hiddenCount != n, cache.shouldPublishHiddenCount(n, width: bounds.width) {
            Task { @MainActor in
                if hiddenCount != n { hiddenCount = n }
            }
        }

        // Place visible subviews at the chosen mode's width.
        var visibleIndices = Array(repeating: false, count: subviews.count)
        for slot in result.slots where visibleIndices.indices.contains(slot.index) {
            visibleIndices[slot.index] = true
        }
        var x = bounds.minX
        for (n, slot) in result.slots.enumerated() {
            guard cache.wordWidths.indices.contains(slot.index),
                  cache.iconWidths.indices.contains(slot.index),
                  subviews.indices.contains(slot.index)
            else { continue }
            let chosenWidth = slot.mode == .word
                ? cache.wordWidths[slot.index]
                : cache.iconWidths[slot.index]
            subviews[slot.index].place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(
                    width: CGFloat(chosenWidth),
                    height: bounds.height
                )
            )
            x += CGFloat(chosenWidth)
            if n < result.slots.count - 1 {
                x += spacing
            }
        }
        // Hide non-visible subviews offscreen — same pattern
        // ChipFlowLayout uses to keep them measurable but invisible.
        for i in subviews.indices where !visibleIndices[i] {
            subviews[i].place(
                at: CGPoint(x: -10000, y: -10000),
                proposal: ProposedViewSize(width: 0, height: 0)
            )
        }
    }
}

// MARK: - Layout value keys

nonisolated private struct ChipWordWidthKey: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}
nonisolated private struct ChipIconWidthKey: LayoutValueKey {
    static let defaultValue: CGFloat = 24
}

// `ChipPressedKey` already exists in ChipFlowLayout.swift; reuse that
// `.chipPressed(_:)` modifier.

extension View {
    /// Tell `OverflowChipFlowLayout` how wide this chip is in word mode.
    /// Caller is responsible for measuring (see `String.chipWordWidth`).
    func chipWordWidth(_ width: CGFloat) -> some View {
        layoutValue(key: ChipWordWidthKey.self, value: width)
    }
    /// Tell `OverflowChipFlowLayout` how wide this chip is in icon mode.
    /// Defaults to 24pt; override only if the chip uses a different
    /// icon-mode shape.
    func chipIconWidth(_ width: CGFloat) -> some View {
        layoutValue(key: ChipIconWidthKey.self, value: width)
    }
}

// MARK: - Word-width measurement helper

extension String {
    /// Word-mode chip width for `self` rendered in a system font.
    /// Defaults match `FilterChipLabel` (11pt, +16 chrome for 8pt
    /// horizontal padding × 2). The `bold` parameter mirrors the
    /// pressed-state semibold weight (pressing thickens glyphs and
    /// pushes pixel widths up by ~5%). Sections with non-FilterChipLabel
    /// chip layouts can override `fontSize` and `chrome` to keep their
    /// measurement honest — e.g. `AccountFilterChips` measures at 10pt.
    func chipWordWidth(
        bold: Bool = false,
        fontSize: CGFloat = 11,
        chrome: CGFloat = 16
    ) -> CGFloat {
        let font = NSFont.systemFont(
            ofSize: fontSize,
            weight: bold ? .semibold : .regular
        )
        let attr = NSAttributedString(
            string: self,
            attributes: [.font: font]
        )
        return ceil(attr.size().width) + chrome
    }
}
