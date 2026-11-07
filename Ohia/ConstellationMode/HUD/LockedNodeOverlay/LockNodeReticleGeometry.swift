import CoreGraphics

struct LockNodeReticleGeometry: Equatable {
    let center: CGPoint
    let side: CGFloat
    let bracketLength: CGFloat

    var cornerSegments: [(CGPoint, CGPoint)] {
        let half = side / 2
        let left = center.x - half
        let right = center.x + half
        let top = center.y - half
        let bottom = center.y + half
        return [
            (CGPoint(x: left, y: top + bracketLength), CGPoint(x: left, y: top)),
            (CGPoint(x: left, y: top), CGPoint(x: left + bracketLength, y: top)),
            (CGPoint(x: right - bracketLength, y: top), CGPoint(x: right, y: top)),
            (CGPoint(x: right, y: top), CGPoint(x: right, y: top + bracketLength)),
            (CGPoint(x: right, y: bottom - bracketLength), CGPoint(x: right, y: bottom)),
            (CGPoint(x: right, y: bottom), CGPoint(x: right - bracketLength, y: bottom)),
            (CGPoint(x: left + bracketLength, y: bottom), CGPoint(x: left, y: bottom)),
            (CGPoint(x: left, y: bottom), CGPoint(x: left, y: bottom - bracketLength))
        ]
    }
}
