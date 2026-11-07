import Foundation

/// Pure: given a list of chip widths and a flag for each indicating
/// whether the chip is pressed, plus the available width, returns
/// the indices that should render and the count of hidden chips.
///
/// Pressed chips are always retained. Unpressed chips are dropped in
/// their original order until the remaining chips fit. If any chips
/// are dropped, an "overflow" chip of width `overflowChipWidth` is
/// reserved (and counted in the available-width budget).
public enum ChipFlowOrdering {
    public struct Result: Equatable, Sendable {
        public let visible: [Int]   // indices into the input
        public let hiddenCount: Int

        public init(visible: [Int], hiddenCount: Int) {
            self.visible = visible
            self.hiddenCount = hiddenCount
        }
    }

    public static func resolve(
        chipWidths: [Double],
        pressed: [Bool],
        availableWidth: Double,
        spacing: Double,
        overflowChipWidth: Double
    ) -> Result {
        precondition(chipWidths.count == pressed.count)
        let pressedIdx = chipWidths.indices.filter { pressed[$0] }
        let unpressedIdx = chipWidths.indices.filter { !pressed[$0] }

        // Start with all pressed chips (they always render).
        var visible = Set(pressedIdx)
        var width = pressedIdx.reduce(0.0) { $0 + chipWidths[$1] }
            + Double(max(0, pressedIdx.count - 1)) * spacing

        // Fit as many unpressed as possible, in original order.
        var dropped: [Int] = []
        for i in unpressedIdx {
            let extra = chipWidths[i] + (visible.isEmpty ? 0 : spacing)
            if width + extra <= availableWidth {
                visible.insert(i)
                width += extra
            } else {
                dropped.append(i)
            }
        }

        // If anything was dropped, reserve room for the overflow chip,
        // dropping more unpressed chips in reverse-fit-order if needed.
        if !dropped.isEmpty {
            let overflowExtra = overflowChipWidth + spacing
            while width + overflowExtra > availableWidth {
                // Pop a visible unpressed chip (the most recently fit).
                guard let lastUnpressed = visible
                    .filter({ !pressed[$0] })
                    .max() else { break }
                visible.remove(lastUnpressed)
                dropped.append(lastUnpressed)
                width -= chipWidths[lastUnpressed] + spacing
            }
        }

        let visibleSorted = visible.sorted()
        return Result(visible: visibleSorted, hiddenCount: dropped.count)
    }
}
