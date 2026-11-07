import SwiftUI

/// Wrapping horizontal stack for chip-character rows. Behaves like an
/// `HStack(spacing:)` while everything fits the proposed width, and wraps
/// onto additional rows once a chip would overflow. Used in place of
/// `HStack` only for chip content — scalar rows (sliders) keep their plain
/// `HStack` because their child sizing (a `GeometryReader` slider with a
/// fixed max width) doesn't negotiate well with `.unspecified` proposals.
/// Used by `WithheldDrawerView` and `HoverReadoutView`.
struct WrappingChipStack: Layout {
    var horizontalSpacing: CGFloat = 4
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        guard !subviews.isEmpty else { return .zero }

        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        var firstInRow = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needed = rowWidth + (firstInRow ? 0 : horizontalSpacing) + size.width
            if !firstInRow && needed > maxWidth {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight + verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
                firstInRow = false
            } else {
                if !firstInRow { rowWidth += horizontalSpacing }
                rowWidth += size.width
                rowHeight = max(rowHeight, size.height)
                firstInRow = false
            }
        }
        widestRow = max(widestRow, rowWidth)
        totalHeight += rowHeight

        let finalWidth = maxWidth.isFinite ? maxWidth : widestRow
        return CGSize(width: finalWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        var firstInRow = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !firstInRow {
                let needed = x + horizontalSpacing + size.width
                if needed > bounds.maxX {
                    y += rowHeight + verticalSpacing
                    x = bounds.minX
                    rowHeight = 0
                    firstInRow = true
                } else {
                    x += horizontalSpacing
                }
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width
            rowHeight = max(rowHeight, size.height)
            firstInRow = false
        }
    }
}
