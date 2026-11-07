import SwiftUI
import simd

struct LockNodeCoordReadout: View {
    let world: SIMD3<Float>
    let vectorId: Int64

    var body: some View {
        Text(LockNodeCoordReadoutFormatter.string(world: world, vectorId: vectorId))
            .font(OhiaTypography.coordReadout)
            .tracking(0.16)
            .foregroundStyle(OhiaColors.chipActiveForeground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(OhiaColors.surface(0.18))
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(OhiaColors.chipActiveBorder.opacity(0.55), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .allowsHitTesting(false)
    }
}
