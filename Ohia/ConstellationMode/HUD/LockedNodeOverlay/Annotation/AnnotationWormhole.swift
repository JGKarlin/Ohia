import SwiftUI

struct AnnotationWormhole<Content: View>: View {
    let anchor: CGPoint
    let rect: CGRect
    let phase: WormholePhase?
    let palette: AnnotationWormholePalette
    let vortexScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: Content

    init(
        anchor: CGPoint,
        rect: CGRect,
        phase: WormholePhase?,
        palette: AnnotationWormholePalette,
        vortexScale: CGFloat = 1,
        @ViewBuilder content: () -> Content
    ) {
        self.anchor = anchor
        self.rect = rect
        self.phase = phase
        self.palette = palette
        self.vortexScale = vortexScale
        self.content = content()
    }

    var body: some View {
        // Only run a TimelineView while a wormhole transition is actively in flight. Once
        // the phase is `nil` (steady state) or has reported `isComplete`, render statically
        // so the popup doesn't keep recomputing positions on every animation tick — that
        // outer-level animation loop was the source of the field-wide jitter.
        if shouldAnimate {
            TimelineView(.animation(minimumInterval: OhiaAnimationCadence.frameInterval)) { context in
                renderedContent(now: context.date)
            }
        } else {
            renderedContent(now: Date.now)
        }
    }

    private var shouldAnimate: Bool {
        guard !reduceMotion, let phase else { return false }
        return !phase.at(Date.now).isComplete
    }

    @ViewBuilder
    private func renderedContent(now: Date) -> some View {
        let sample = phase?.at(now)
        // Closing rides the leader: the pane translates from its rect
        // toward the wormhole anchor by `paneTowardAnchor`, so the
        // retracting line visibly drags it in. Opening keeps
        // `paneTowardAnchor` at 0, so this is a no-op for materialize and
        // steady-state.
        let towardAnchor = reduceMotion ? 0 : (sample?.paneTowardAnchor ?? 0)
        let popupX = rect.midX + (anchor.x - rect.midX) * towardAnchor
        let popupY = rect.midY + (anchor.y - rect.midY) * towardAnchor
        ZStack(alignment: .topLeading) {
            if let sample, sample.vortexOpacity > 0.01, !reduceMotion {
                WormholeVortex(
                    sample: sample,
                    now: now,
                    palette: palette,
                    vortexScale: vortexScale
                )
                    .position(anchor)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if reduceMotion || (sample?.popupOpacity ?? 1) > 0.001 {
                content
                    .frame(width: rect.width, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .position(x: popupX, y: popupY)
                    .scaleEffect(reduceMotion ? 1 : (sample?.popupScale ?? 1), anchor: .center)
                    .opacity(reduceMotion ? 1 : (sample?.popupOpacity ?? 1))
                    .allowsHitTesting(reduceMotion || (sample?.popupAllowsHitTesting ?? true))
            }
        }
    }
}

private struct WormholeVortex: View {
    let sample: WormholePhase.Sample
    let now: Date
    let palette: AnnotationWormholePalette
    let vortexScale: CGFloat

    var body: some View {
        let radius = sample.vortexRadius * Double(vortexScale)
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            palette.core.color,
                            palette.halo.color,
                            palette.mid.color,
                            palette.outer.color
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: max(1, radius)
                    )
                )
            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(palette.dashedRing.color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
                .rotationEffect(.degrees(now.timeIntervalSinceReferenceDate * 110))
            Circle()
                .stroke(palette.innerRipple.color, lineWidth: 1)
                .scaleEffect(sample.outerRingScale)
            Circle()
                .stroke(palette.outerRipple.color, lineWidth: 1)
                .scaleEffect(sample.outerRingScale + 0.28)
        }
        .frame(width: max(2, radius * 2), height: max(2, radius * 2))
        .opacity(sample.vortexOpacity)
    }
}
