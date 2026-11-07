import SwiftUI
import OhiaCore

public struct RenderDebugHUD: View {
    public let stats: ConstellationMetalFrameStats
    public let packet: ConstellationRenderPacket

    public init(stats: ConstellationMetalFrameStats, packet: ConstellationRenderPacket) {
        self.stats = stats
        self.packet = packet
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Metal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(OhiaColors.textTertiary)
            row("stars", "\(stats.starCount)")
            row("nebulae", "\(stats.nebulaCount)")
            row("fibers", "\(stats.fiberCount)")
            row("total", "\(packet.totalMessageCount)")
            row("prepare", "\(stats.packetPreparationMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms")
            row("CPU encode", "\(stats.cpuEncodingMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms")
            row("GPU frame", "\(stats.gpuFrameMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms")
            row("tier", "\(stats.degradationTier.rawValue)")
        }
        .padding(9)
        .background(OhiaColors.spaceBackground.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.system(size: 10))
                .foregroundStyle(OhiaColors.textSecondary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(OhiaTypography.legendLine)
                .foregroundStyle(OhiaColors.textPrimary)
                .monospacedDigit()
        }
    }
}
