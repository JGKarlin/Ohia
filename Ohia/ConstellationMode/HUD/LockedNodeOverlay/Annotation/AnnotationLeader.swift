import SwiftUI

struct AnnotationLeader: Shape {
    let anchor: CGPoint
    let rect: CGRect

    func path(in bounds: CGRect) -> Path {
        var path = Path()
        guard anchor.x.isFinite, anchor.y.isFinite, rect.width > 0, rect.height > 0 else {
            return path
        }
        // Mirrors `LockTetherShape`: the leader always terminates on the popup's
        // near-edge midpoint, anchored to the live screen projection of the
        // related-message node. Same model as the main email tether so the line
        // visibly originates at the star and stays glued to it whether the camera
        // pans (anchor moves) or the user drags the popup (rect moves).
        let starOnLeft = anchor.x <= rect.midX
        let edgeX = starOnLeft ? rect.minX : rect.maxX
        path.move(to: anchor)
        path.addLine(to: CGPoint(x: edgeX, y: rect.midY))
        return path
    }
}
