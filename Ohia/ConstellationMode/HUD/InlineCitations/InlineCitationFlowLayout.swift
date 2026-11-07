import SwiftUI

/// Horizontal flow layout that wraps subviews onto multiple lines and
/// vertically centers each row's children inside the row's max height.
/// Used to interleave word / character text tokens with inline citation
/// chips so the chips ride within the prose rather than sitting in a
/// separate row below.
struct InlineFlowLayout: Layout {
    var lineSpacing: CGFloat = 2

    struct LineMetrics {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = computeLines(subviews: subviews, maxWidth: width)
        let totalHeight = lines.reduce(into: CGFloat(0)) { acc, line in acc += line.height }
            + max(0, CGFloat(lines.count - 1)) * lineSpacing
        let widest = lines.map(\.width).max() ?? 0
        let resolvedWidth = proposal.width ?? widest
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = computeLines(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for item in line.items {
                let yOffset = (line.height - item.size.height) / 2
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + yOffset),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width
            }
            y += line.height + lineSpacing
        }
    }

    private func computeLines(subviews: Subviews, maxWidth: CGFloat) -> [LineMetrics] {
        var lines: [LineMetrics] = []
        var current = LineMetrics()
        for (idx, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !current.items.isEmpty, current.width + size.width > maxWidth {
                lines.append(current)
                current = LineMetrics()
            }
            current.items.append((idx, size))
            current.width += size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty {
            lines.append(current)
        }
        return lines
    }
}
