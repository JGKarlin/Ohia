import SwiftUI

/// Replaces `AnnotationLeader` for the rank-focused neighbour. The leader
/// itself becomes a thin affinity gauge: a solid stroke from the anchor up
/// to a "score position" computed from `(bestSimilarity − threshold) /
/// (1 − threshold)`, then a dashed tail to the popup edge, with three
/// perpendicular tick marks at 25 / 50 / 75 % along the leader as a
/// visual ruler.
///
/// Geometry is split across three `Component` cases so each can be drawn
/// with its own `StrokeStyle` (solid fill vs. dashed tail vs. thin ticks)
/// without the cost of a single shape returning a multi-style path.
struct AffinityRankLeader: Shape {
    enum Component {
        /// Anchor → score position. Drawn solid, slightly thicker.
        case fill
        /// Score position → popup near-edge midpoint. Drawn dashed,
        /// matching the default `AnnotationLeader` style.
        case tail
        /// Three short perpendicular hash marks at 25 / 50 / 75 %
        /// of the leader's length, as ruler ticks.
        case ticks
    }

    let anchor: CGPoint
    let rect: CGRect
    let bestSimilarity: Float
    let threshold: Float
    let component: Component

    func path(in bounds: CGRect) -> Path {
        var path = Path()
        guard anchor.x.isFinite, anchor.y.isFinite, rect.width > 0, rect.height > 0 else {
            return path
        }

        // Same near-edge midpoint convention as `LockTetherShape` and
        // `AnnotationLeader` so the gauge slots cleanly into the
        // existing leader geometry without a visible jump on focus.
        let starOnLeft = anchor.x <= rect.midX
        let edgeX = starOnLeft ? rect.minX : rect.maxX
        let edgePoint = CGPoint(x: edgeX, y: rect.midY)

        let denom = max(0.0001, 1.0 - Double(threshold))
        let normalized = max(0.0, min(1.0, (Double(bestSimilarity) - Double(threshold)) / denom))
        let scorePoint = CGPoint(
            x: anchor.x + (edgePoint.x - anchor.x) * CGFloat(normalized),
            y: anchor.y + (edgePoint.y - anchor.y) * CGFloat(normalized)
        )

        switch component {
        case .fill:
            path.move(to: anchor)
            path.addLine(to: scorePoint)
        case .tail:
            path.move(to: scorePoint)
            path.addLine(to: edgePoint)
        case .ticks:
            let dx = edgePoint.x - anchor.x
            let dy = edgePoint.y - anchor.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 1 else { return path }
            // Unit vector perpendicular to the leader, used to draw
            // tick marks across the line. (dx, dy) → (−dy, dx) is the
            // 90° CCW rotation; either side is fine since tick marks
            // are symmetrical about the leader's centerline.
            let perpX = -dy / length
            let perpY = dx / length
            let halfLength: CGFloat = 4
            for fraction in [0.25, 0.5, 0.75] as [CGFloat] {
                let centerPoint = CGPoint(
                    x: anchor.x + dx * fraction,
                    y: anchor.y + dy * fraction
                )
                path.move(to: CGPoint(
                    x: centerPoint.x - perpX * halfLength,
                    y: centerPoint.y - perpY * halfLength
                ))
                path.addLine(to: CGPoint(
                    x: centerPoint.x + perpX * halfLength,
                    y: centerPoint.y + perpY * halfLength
                ))
            }
        }

        return path
    }
}
