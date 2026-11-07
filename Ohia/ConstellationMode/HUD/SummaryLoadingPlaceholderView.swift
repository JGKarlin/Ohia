import SwiftUI

/// Particle-on-a-line loading animation used while a summary is being generated.
/// Originally lived as a `private struct` inside `HoverReadoutView`; lifted here
/// so the locked overlay's CONTEXT pane can reuse the exact same affordance.
struct SummaryLoadingPlaceholderView: View {
    /// Width of the animated track. The hover popup uses 280; the locked
    /// CONTEXT pane is narrower, so the caller passes its own value.
    let contentWidth: CGFloat
    /// Vertical room reserved for the animation.
    var slotHeight: CGFloat = 28

    private static let particleSize: CGFloat = 5
    private static let cycleSeconds: Double = 3.2

    var body: some View {
        TimelineView(.animation(minimumInterval: OhiaAnimationCadence.frameInterval)) { timeline in
            let phase = (timeline.date.timeIntervalSinceReferenceDate)
                .truncatingRemainder(dividingBy: Self.cycleSeconds) / Self.cycleSeconds
            let travel = contentWidth - Self.particleSize
            let opacity = particleOpacity(for: phase)

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(OhiaColors.glassBorder)
                    .frame(width: contentWidth, height: 1)
                Circle()
                    .fill(OhiaColors.textSecondary)
                    .frame(width: Self.particleSize, height: Self.particleSize)
                    .shadow(color: OhiaColors.textSecondary.opacity(0.55 * opacity), radius: 4)
                    .opacity(opacity)
                    .offset(x: travel * phase)
            }
            .frame(width: contentWidth, height: slotHeight, alignment: .leading)
        }
        .frame(width: contentWidth, height: slotHeight, alignment: .leading)
        .accessibilityLabel("Summary loading")
    }

    private func particleOpacity(for phase: Double) -> Double {
        let edge = 0.08
        if phase < edge { return (phase / edge) * 0.9 }
        if phase > 1.0 - edge { return ((1.0 - phase) / edge) * 0.9 }
        return 0.9
    }
}

/// Wraps `SummaryLoadingPlaceholderView` so the animated track shrinks to the
/// caller's `preferredWidth` but never overflows the space it's given.
struct AdaptiveSummaryLoadingPlaceholderView: View {
    let preferredWidth: CGFloat
    var slotHeight: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            let width = min(preferredWidth, max(1, proxy.size.width))
            SummaryLoadingPlaceholderView(contentWidth: width, slotHeight: slotHeight)
        }
        .frame(height: slotHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
