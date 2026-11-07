import CoreGraphics

/// Screen placement for Constellation hover readouts — centered on the
/// hovered node horizontally, opening downward with a small gap (flips
/// above when the bottom edge would clip).
enum HoverPopupPlacement {
    static let defaultEnvelope = CGSize(width: 308, height: 210)

    /// Reading-size-aware envelope for the email hover pane. The persistent
    /// readers can scroll, but this transient pane cannot accept scrolling;
    /// its placement envelope therefore grows with the prose so the full
    /// generated summary remains visible instead of clipping at the edges.
    static func emailEnvelope(for readingTextSize: ReadingTextSize) -> CGSize {
        switch readingTextSize {
        case .smallest:
            CGSize(width: 308, height: 190)
        case .smaller:
            CGSize(width: 308, height: 200)
        case .standard:
            defaultEnvelope
        case .larger:
            CGSize(width: 360, height: 300)
        case .largest:
            CGSize(width: 408, height: 380)
        }
    }
    static let nodeGap: CGFloat = 14
    static let windowMargin: CGFloat = 12
    /// Horizontal gap between the node and the near edge of the popup in the
    /// adjacent-side placement (used by the email-node hover so the leader
    /// line reads as a tether, not free chrome).
    static let adjacentLeaderGap: CGFloat = 20
    /// Distance from the popup's top edge to the y at which the leader line
    /// lands — i.e. the center of the header's annotation-mark row in
    /// `HoverReadoutView`. The popup is shifted vertically so this y lines up
    /// with the node's screen y.
    static let adjacentDashYFromTop: CGFloat = 6

    enum AdjacentSide: Equatable {
        case trailing  // popup sits to the right of the node
        case leading   // popup sits to the left of the node
    }

    struct AdjacentPlacement: Equatable {
        let center: CGPoint
        let side: AdjacentSide
    }

    /// Side-of-node placement: the popup sits to the right of the node with a
    /// small horizontal gap, and is shifted vertically so the header's leader-
    /// line row aligns with the node's y. Flips to the left when it has more
    /// room, then clamps the popup inside the usable viewport when neither side
    /// can preserve the full leader gap.
    static func adjacent(
        nodePoint: CGPoint,
        viewSize: CGSize,
        popupSize: CGSize = defaultEnvelope
    ) -> AdjacentPlacement {
        let halfWidth = popupSize.width / 2
        let halfHeight = popupSize.height / 2

        guard viewSize.width > 0, viewSize.height > 0 else {
            return AdjacentPlacement(
                center: CGPoint(
                    x: nodePoint.x + adjacentLeaderGap + halfWidth,
                    y: nodePoint.y + halfHeight - adjacentDashYFromTop
                ),
                side: .trailing
            )
        }

        let rightSpace = viewSize.width - nodePoint.x - adjacentLeaderGap - windowMargin
        let leftSpace = nodePoint.x - adjacentLeaderGap - windowMargin
        let fitsRight = rightSpace >= popupSize.width
        let fitsLeft = leftSpace >= popupSize.width
        let placeRight = fitsRight || (!fitsLeft && rightSpace >= leftSpace)
        var centerX = placeRight
            ? nodePoint.x + adjacentLeaderGap + halfWidth
            : nodePoint.x - adjacentLeaderGap - halfWidth
        let minimumCenterX = halfWidth + windowMargin
        let maximumCenterX = viewSize.width - halfWidth - windowMargin
        centerX = maximumCenterX >= minimumCenterX
            ? min(max(centerX, minimumCenterX), maximumCenterX)
            : viewSize.width / 2
        var centerY = nodePoint.y + halfHeight - adjacentDashYFromTop
        centerY = min(
            max(centerY, halfHeight + windowMargin),
            viewSize.height - halfHeight - windowMargin
        )
        return AdjacentPlacement(
            center: CGPoint(x: centerX, y: centerY),
            side: placeRight ? .trailing : .leading
        )
    }

    static func center(
        nodePoint: CGPoint,
        viewSize: CGSize,
        popupSize: CGSize = defaultEnvelope
    ) -> CGPoint {
        let halfWidth = popupSize.width / 2
        let halfHeight = popupSize.height / 2

        guard viewSize.width > 0, viewSize.height > 0 else {
            return CGPoint(x: nodePoint.x, y: nodePoint.y + halfHeight + nodeGap)
        }

        var dy = halfHeight + nodeGap
        if nodePoint.y + dy + halfHeight > viewSize.height - windowMargin {
            dy = -(halfHeight + nodeGap)
        }

        var center = CGPoint(x: nodePoint.x, y: nodePoint.y + dy)
        center.x = min(
            max(center.x, halfWidth + windowMargin),
            viewSize.width - halfWidth - windowMargin
        )
        center.y = min(
            max(center.y, halfHeight + windowMargin),
            viewSize.height - halfHeight - windowMargin
        )
        return center
    }
}
