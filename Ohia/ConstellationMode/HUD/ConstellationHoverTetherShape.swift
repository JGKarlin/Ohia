import SwiftUI

struct ConstellationHoverTetherShape: Shape {
    let from: CGPoint
    let to: CGPoint
    let popupSize: CGSize
    /// When set, draws a HORIZONTAL leader: node → popup's near edge at this y.
    /// Used by the email-node hover where the popup sits beside the node and the
    /// leader terminates on the header's direction-label row. When nil, draws
    /// the legacy VERTICAL leader: node → popup top/bottom center.
    var attachY: CGFloat? = nil

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard from != .zero, popupSize.width > 0, popupSize.height > 0 else { return path }
        if let attachY {
            let halfWidth = popupSize.width / 2
            let attachX = from.x <= to.x
                ? to.x - halfWidth
                : to.x + halfWidth
            path.move(to: from)
            path.addLine(to: CGPoint(x: attachX, y: attachY))
        } else {
            // Vertical leader: node → top or bottom centre of the hover pane,
            // depending on whether the pane sits below or above the star.
            let halfHeight = popupSize.height / 2
            let endY = from.y <= to.y
                ? to.y - halfHeight
                : to.y + halfHeight
            path.move(to: from)
            path.addLine(to: CGPoint(x: to.x, y: endY))
        }
        return path
    }
}
