import SwiftUI
import OhiaCore

/// Transient readout showing the current aperture state. Shown only
/// when `apertureReadoutTimer` is within `fadeDuration` of now; fades
/// linearly over the last 0.4s of that window.
///
/// Typography matches the beacon / time selector: thin, low-contrast,
/// diegetic.
public struct ApertureReadoutView: View {
    public let aperture: Double
    public let apertureNodeCount: Int
    public let totalNodeCount: Int
    public let lastInputAt: Date?
    public let now: Date

    private let fadeDuration: TimeInterval = 1.2
    private let fadeTail: TimeInterval = 0.4

    public init(
        aperture: Double,
        apertureNodeCount: Int,
        totalNodeCount: Int,
        lastInputAt: Date?,
        now: Date = Date.now
    ) {
        self.aperture = aperture
        self.apertureNodeCount = apertureNodeCount
        self.totalNodeCount = totalNodeCount
        self.lastInputAt = lastInputAt
        self.now = now
    }

    public var body: some View {
        if let opacity = currentOpacity {
            HStack(spacing: 6) {
                Text("aperture")
                    .foregroundStyle(OhiaColors.textTertiary)
                Text("\(apertureNodeCount) / \(totalNodeCount)")
                    .foregroundStyle(OhiaColors.textPrimary)
                Text("· \(ApertureSelector.radius(forAperture: aperture).formatted(.number.precision(.fractionLength(2))))")
                    .foregroundStyle(OhiaColors.textTertiary)
            }
            .font(.caption)
            .monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(OhiaColors.surface(0.18), in: RoundedRectangle(cornerRadius: 10))
            .opacity(opacity)
        }
    }

    private var currentOpacity: Double? {
        guard let lastInputAt else { return nil }
        let elapsed = now.timeIntervalSince(lastInputAt)
        guard elapsed >= 0, elapsed < fadeDuration else { return nil }
        let tailStart = fadeDuration - fadeTail
        if elapsed < tailStart { return 1.0 }
        let tailElapsed = elapsed - tailStart
        return max(0, 1.0 - tailElapsed / fadeTail)
    }
}
