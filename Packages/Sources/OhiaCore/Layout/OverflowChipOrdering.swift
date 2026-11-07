import Foundation

/// Pure: dual-mode chip ordering. Each chip carries two widths (a wider
/// "word" rendering and a narrower "icon" rendering); the resolver picks
/// per-chip mode and overflow set.
///
/// Behaviour (matches the design preview):
///   * **Pressed chips render first.** They take word slots while there's
///     room; if a pressed chip can't even fit at its icon width, it falls
///     into the hidden overflow last (so the user's active filters are
///     never silently dropped before unpressed siblings).
///   * **Unpressed chips fill remaining space.** Word mode is preferred;
///     when remaining budget isn't enough for an unpressed word but is
///     enough for its icon, the chip collapses to icon mode.
///   * **Visible order matches input order.** Mode varies per chip; the
///     visible array is sorted by original index.
///   * No abbreviations — only word or icon. The icon-mode chip is
///     expected to render with a `.help(...)` tooltip so the full word is
///     never lost.
public enum OverflowChipOrdering {
    public enum Mode: Equatable, Sendable { case word, icon }

    public struct Slot: Equatable, Sendable {
        public let index: Int
        public let mode: Mode
        public init(index: Int, mode: Mode) {
            self.index = index
            self.mode = mode
        }
    }

    public struct Result: Equatable, Sendable {
        public let slots: [Slot]      // index-sorted
        public let hiddenCount: Int
        public init(slots: [Slot], hiddenCount: Int) {
            self.slots = slots
            self.hiddenCount = hiddenCount
        }
    }

    public static func resolve(
        wordWidths: [Double],
        iconWidths: [Double],
        pressed: [Bool],
        availableWidth: Double,
        spacing: Double
    ) -> Result {
        precondition(wordWidths.count == iconWidths.count)
        precondition(wordWidths.count == pressed.count)

        let n = wordWidths.count
        guard n > 0 else { return Result(slots: [], hiddenCount: 0) }

        let totalSpacing = spacing * Double(max(0, n - 1))
        let wordsTotal = wordWidths.reduce(0, +) + totalSpacing
        let iconsTotal = iconWidths.reduce(0, +) + totalSpacing

        // Whole-row mode preference matches the narrow-state mockup in
        // the design preview: every chip is either at word width or all
        // at icon width, never a mix where one pressed chip monopolises
        // space at word size while siblings collapse to nothing. Mixing
        // is visually noisy and produces the "one yellow blob and
        // nothing else" failure mode that motivated this rewrite.
        if wordsTotal <= availableWidth + 1e-6 {
            // Comfortable — every chip renders at word width.
            let slots = (0..<n).map { Slot(index: $0, mode: .word) }
            return Result(slots: slots, hiddenCount: 0)
        }

        if iconsTotal <= availableWidth + 1e-6 {
            // Tight — every chip renders at icon width.
            let slots = (0..<n).map { Slot(index: $0, mode: .icon) }
            return Result(slots: slots, hiddenCount: 0)
        }

        // Even icons-only overflows: hide the lowest-priority chips first
        // (unpressed before pressed) until the rest fit. Pressed chips
        // are protected so the user's active filters are never silently
        // dropped before unpressed siblings.
        let pressedIdx = (0..<n).filter { pressed[$0] }
        let unpressedIdx = (0..<n).filter { !pressed[$0] }

        var visibleSet: Set<Int> = []
        var usedWidth: Double = 0
        func canFitIcon(_ i: Int) -> Bool {
            let extra = iconWidths[i] + (visibleSet.isEmpty ? 0 : spacing)
            return usedWidth + extra <= availableWidth + 1e-6
        }
        func placeIcon(_ i: Int) {
            usedWidth += iconWidths[i] + (visibleSet.isEmpty ? 0 : spacing)
            visibleSet.insert(i)
        }

        // Pressed chips first.
        for i in pressedIdx where canFitIcon(i) {
            placeIcon(i)
        }
        // Then unpressed chips (in original order so the visible row keeps
        // the section's source order).
        for i in unpressedIdx where canFitIcon(i) {
            placeIcon(i)
        }

        let slots = visibleSet
            .map { Slot(index: $0, mode: .icon) }
            .sorted { $0.index < $1.index }
        return Result(slots: slots, hiddenCount: n - slots.count)
    }
}
