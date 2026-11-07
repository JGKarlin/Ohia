import SwiftUI

/// The shared blue-and-teal cloud wash used to lift focused content off a
/// band-less night sky. Always pair with `NightSkyView(showsMilkyWay: false)`
/// (or `OhiaColors.spaceBackground` on non-starfield surfaces) — never with
/// the Milky Way band enabled. This overlay does not draw the band itself.
struct NightSkyNebulaOverlay: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [OhiaColors.nightSkyNebulaBlue.opacity(0.55), .clear],
                center: UnitPoint(x: 0.30, y: 0.34),
                startRadius: 8,
                endRadius: 600
            )
            RadialGradient(
                colors: [OhiaColors.nightSkyNebulaTeal.opacity(0.42), .clear],
                center: UnitPoint(x: 0.72, y: 0.64),
                startRadius: 8,
                endRadius: 620
            )
        }
        .blur(radius: 64)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
