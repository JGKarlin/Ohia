import SwiftUI

/// Lays out toolbar sections horizontally. Sections announce their
/// preferred width via SwiftUI's idealSize; the layout grants each
/// its preferred width up to the available space, then truncates the
/// trailing flexible spacer.
struct ToolbarFlowLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        return CGSize(
            width: widths.reduce(0, +),
            height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        let height = bounds.height
        for sub in subviews {
            let width = sub.sizeThatFits(.unspecified).width
            sub.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: width, height: height)
            )
            x += width
        }
    }
}
