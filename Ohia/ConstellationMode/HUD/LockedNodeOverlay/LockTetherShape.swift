import SwiftUI

struct LockTetherShape: Shape {
    let from: CGPoint
    let to: CGPoint
    let popupSize: CGSize
    /// Which side of the locked star the card sits on, so the dashed leader can terminate
    /// on the card's near-edge midpoint instead of cutting through the body. Card to the
    /// right of the star → leader hits the card's left edge; card to the left → leader hits
    /// the card's right edge. Updated live as the user drags the card so the line stays
    /// anchored to the closest edge no matter where the card is moved.
    let starSide: HorizontalEdge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard from != .zero, popupSize.width > 0 else { return path }
        let edgeX: CGFloat
        switch starSide {
        case .leading:
            edgeX = to.x - popupSize.width / 2
        case .trailing:
            edgeX = to.x + popupSize.width / 2
        }
        path.move(to: from)
        path.addLine(to: CGPoint(x: edgeX, y: to.y))
        return path
    }
}
