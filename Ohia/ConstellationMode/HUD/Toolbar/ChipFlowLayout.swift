import SwiftUI
import OhiaCore

/// Layout that uses ChipFlowOrdering to drop unpressed chips when the
/// row exceeds available width.
///
/// Pressed status is conveyed by a `LayoutValueKey` on each subview
/// via the `.chipPressed(_:)` view modifier.
///
/// The number of hidden chips is published into a `Binding<Int>` so the
/// caller can render an external `+N` overflow chip.
struct ChipFlowLayout: Layout {
    let spacing: CGFloat
    @Binding var hiddenCount: Int

    init(spacing: CGFloat = 4, hiddenCount: Binding<Int>) {
        self.spacing = spacing
        self._hiddenCount = hiddenCount
    }

    struct Cache {
        var widths: [Double] = []
        var sizes: [CGSize] = []
        var pressed: [Bool] = []
        var totalWidth: CGFloat = 0
        var maxHeight: CGFloat = 0
        private var pendingHiddenCount: Int?
        private var pendingWidth: CGFloat?
        private var stableHiddenCountPasses = 0
        private var publishedHiddenCount: Int?

        init() {}

        init(subviews: Subviews, spacing: CGFloat) {
            update(subviews: subviews, spacing: spacing)
        }

        mutating func update(subviews: Subviews, spacing: CGFloat) {
            sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            widths = sizes.map { Double($0.width) }
            pressed = subviews.map { $0[ChipPressedKey.self] }

            totalWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width }
                + spacing * CGFloat(max(0, subviews.count - 1))
            maxHeight = sizes.map(\.height).max() ?? 0
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
        CGSize(width: cache.totalWidth, height: cache.maxHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let result = ChipFlowOrdering.resolve(
            chipWidths: cache.widths,
            pressed: cache.pressed,
            availableWidth: Double(bounds.width),
            spacing: Double(spacing),
            overflowChipWidth: 0   // we don't reserve internal space; the
                                   // caller renders +N as a sibling outside
                                   // the ChipFlowLayout container
        )

        // Publish the hidden count so the caller can render the +N chip
        // OUTSIDE this layout. We dispatch async to avoid mutating state
        // during a SwiftUI layout pass.
        let n = result.hiddenCount
        if hiddenCount != n, cache.shouldPublishHiddenCount(n, width: bounds.width) {
            Task { @MainActor in
                if hiddenCount != n { hiddenCount = n }
            }
        }

        // Place visible subviews left-to-right.
        var x = bounds.minX
        for (n, i) in result.visible.enumerated() {
            guard cache.sizes.indices.contains(i), subviews.indices.contains(i) else { continue }
            let w = cache.sizes[i].width
            subviews[i].place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: w, height: bounds.height)
            )
            x += w
            if n < result.visible.count - 1 {
                x += spacing
            }
        }

        // Hide subviews not in the visible set by placing them at -10000pt
        // (offscreen). This is safer than not calling place() at all.
        var visible = Array(repeating: false, count: subviews.count)
        for i in result.visible where visible.indices.contains(i) {
            visible[i] = true
        }
        for i in subviews.indices where !visible[i] {
            subviews[i].place(
                at: CGPoint(x: -10000, y: -10000),
                proposal: ProposedViewSize(width: 0, height: 0)
            )
        }
    }
}

nonisolated struct ChipPressedKey: LayoutValueKey {
    static let defaultValue: Bool = false
}

extension View {
    /// Mark a chip as pressed/unpressed for ChipFlowLayout's pressed-first
    /// overflow rule. Default is unpressed.
    func chipPressed(_ on: Bool) -> some View {
        layoutValue(key: ChipPressedKey.self, value: on)
    }
}
