import SwiftUI

struct LockNodeReticle: View {
    let center: CGPoint

    var body: some View {
        Path { path in
            let geometry = LockNodeReticleGeometry(
                center: center,
                side: 60,
                bracketLength: 12
            )
            for segment in geometry.cornerSegments {
                path.move(to: segment.0)
                path.addLine(to: segment.1)
            }
        }
        .stroke(OhiaColors.chipActiveBorder.opacity(0.85), lineWidth: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
