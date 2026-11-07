import Foundation
import simd

struct WormholePhase: Sendable, Equatable {
    enum Direction: Sendable, Equatable {
        case opening
        case closing
    }

    struct Sample: Sendable, Equatable {
        let progress: Double
        let leaderProgress: Double
        let leaderOpacity: Double
        let popupScale: Double
        let popupOpacity: Double
        let popupOffset: SIMD2<Double>
        /// 0 = pane is at its layout-determined rect; 1 = pane has been
        /// pulled all the way to the wormhole anchor. The renderer lerps
        /// the pane's screen position from `rect.center` toward `anchor`
        /// by this value, which the closing animation drives in sync with
        /// `leaderProgress` so the leader appears to reel the pane in.
        /// Always 0 during opening (pane materializes at the rect).
        let paneTowardAnchor: Double
        let vortexRadius: Double
        let vortexOpacity: Double
        let outerRingScale: Double
        let popupAllowsHitTesting: Bool
        let isComplete: Bool
    }

    nonisolated static let defaultDuration: TimeInterval = 0.95

    let startedAt: Date
    let direction: Direction
    let duration: TimeInterval
    private let initialLeaderProgress: Double
    private let initialPopupOpacity: Double

    nonisolated init(
        startedAt: Date,
        direction: Direction,
        duration: TimeInterval = Self.defaultDuration,
        initialLeaderProgress: Double? = nil,
        initialPopupOpacity: Double? = nil
    ) {
        self.startedAt = startedAt
        self.direction = direction
        self.duration = duration
        let opens: Bool
        switch direction {
        case .opening:
            opens = true
        case .closing:
            opens = false
        }
        self.initialLeaderProgress = min(max(initialLeaderProgress ?? (opens ? 0 : 1), 0), 1)
        self.initialPopupOpacity = min(max(initialPopupOpacity ?? (opens ? 0 : 1), 0), 1)
    }

    nonisolated func at(_ now: Date) -> Sample {
        let elapsed = now.timeIntervalSince(startedAt)
        if elapsed < 0 {
            return Sample(
                progress: 0,
                leaderProgress: 0,
                leaderOpacity: 0,
                popupScale: 0.16,
                popupOpacity: 0,
                popupOffset: SIMD2<Double>(0, 0),
                paneTowardAnchor: 0,
                vortexRadius: 0,
                vortexOpacity: 0,
                outerRingScale: 1,
                popupAllowsHitTesting: false,
                isComplete: false
            )
        }
        let raw = max(0, min(1, elapsed / duration))
        let sample: PhaseValues
        switch direction {
        case .opening:
            sample = openingValues(raw: raw)
        case .closing:
            sample = closingValues(raw: raw)
        }

        return Sample(
            progress: raw,
            leaderProgress: sample.leaderProgress,
            leaderOpacity: sample.leaderOpacity,
            popupScale: sample.popupScale,
            popupOpacity: sample.popupOpacity,
            popupOffset: SIMD2<Double>(0, 0),
            paneTowardAnchor: sample.paneTowardAnchor,
            vortexRadius: sample.vortexRadius,
            vortexOpacity: sample.vortexOpacity,
            outerRingScale: sample.outerRingScale,
            popupAllowsHitTesting: popupAllowsHitTesting(
                popupOpacity: sample.popupOpacity,
                rawProgress: raw
            ),
            isComplete: raw >= 1
        )
    }

    nonisolated func remainingDuration(at now: Date) -> TimeInterval {
        max(0, duration - now.timeIntervalSince(startedAt))
    }

    nonisolated private func openingValues(raw: Double) -> PhaseValues {
        // Opening is deliberately staged: the vortex appears at the node,
        // then the leader emits from it, then the pane materializes.
        let leader = smoothstep(edge0: 0.22, edge1: 0.58, x: raw)
        let materialize = smoothstep(edge0: 0.58, edge1: 0.86, x: raw)
        let vortexPeak = smoothstep(edge0: 0.00, edge1: 0.18, x: raw)
            * (1 - smoothstep(edge0: 0.62, edge1: 0.92, x: raw))
        let radius = 22.0 * max(0, sin(Double.pi * min(raw / 0.92, 1)))
        return PhaseValues(
            leaderProgress: leader,
            leaderOpacity: leader,
            popupScale: 0.16 + 0.84 * easeOutCubic(materialize),
            popupOpacity: materialize,
            paneTowardAnchor: 0,
            vortexRadius: max(0, radius),
            vortexOpacity: max(0, min(1, vortexPeak)),
            outerRingScale: 1.0 + (1.0 - max(0.05, vortexPeak)) * 0.40
        )
    }

    nonisolated private func closingValues(raw: Double) -> PhaseValues {
        // Closing is choreographed as a single retraction: the leader
        // collapses, the pane rides the leader's path back to the anchor
        // (`paneTowardAnchor` lerps `rect.center → anchor`), and the pane
        // fades + shrinks as it reaches the wormhole. Sharing the
        // `collapse` smoothstep keeps the leader's tip and the pane's
        // motion on the same curve so the line visibly drags the pane in
        // — no gap between popup-fade-out and leader-retraction.
        let collapse = smoothstep(edge0: 0.05, edge1: 0.58, x: raw)
        let leader = initialLeaderProgress * (1 - collapse)
        // Hold the pane near full opacity for the first part of the
        // journey, then fade as it nears the anchor — so it stays a
        // visible "package" being pulled in rather than ghosting away
        // before the retraction starts.
        let dematerialize = smoothstep(edge0: 0.30, edge1: 0.65, x: raw)
        let popupOpacity = initialPopupOpacity * (1 - dematerialize)
        let vortexSeed = max(initialLeaderProgress, initialPopupOpacity)
        let vortex = vortexSeed
            * smoothstep(edge0: 0.00, edge1: 0.16, x: raw)
            * (1 - smoothstep(edge0: 0.72, edge1: 1.00, x: raw))
        let radius = 22.0 * max(0, sin(Double.pi * min(raw / 0.92, 1)))
        // Scale tracks the journey's progress (slight shrink while
        // travelling) but doesn't bottom out until the pane reaches the
        // anchor — `popupOpacity` already drops near the end so the
        // shrink reads as absorption rather than dissolve.
        let scaleEnvelope = max(0, min(1, 1 - 0.45 * collapse))
        return PhaseValues(
            leaderProgress: leader,
            leaderOpacity: leader > 0.001 ? max(0.20, leader) : 0,
            popupScale: 0.16 + 0.84 * easeOutCubic(scaleEnvelope * (popupOpacity > 0 ? 1 : 0)),
            popupOpacity: popupOpacity,
            paneTowardAnchor: collapse,
            vortexRadius: max(0, radius),
            vortexOpacity: max(0, min(1, vortex)),
            outerRingScale: 1.0 + (1.0 - max(0.05, vortex)) * 0.40
        )
    }

    nonisolated private func easeOutCubic(_ x: Double) -> Double {
        1 - pow(1 - x, 3)
    }

    nonisolated private func smoothstep(edge0: Double, edge1: Double, x: Double) -> Double {
        let t = max(0, min(1, (x - edge0) / max(0.0001, edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    nonisolated private func popupAllowsHitTesting(
        popupOpacity: Double,
        rawProgress: Double
    ) -> Bool {
        switch direction {
        case .opening:
            popupOpacity > 0.98 && rawProgress >= 0.86
        case .closing:
            false
        }
    }

    private struct PhaseValues {
        let leaderProgress: Double
        let leaderOpacity: Double
        let popupScale: Double
        let popupOpacity: Double
        let paneTowardAnchor: Double
        let vortexRadius: Double
        let vortexOpacity: Double
        let outerRingScale: Double
    }
}
