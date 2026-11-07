// HoverNodeIndicator.swift
// The reticle drawn around a hovered node in Constellation Mode: a
// static accent outline ring close to the node, plus a larger ring that
// pulses outward and fades on a slow ease-in-out loop. Reads as the
// astronomical "this body, here" annotation in the design preview —
// orientation in the time it takes to move the cursor.
//
// The Metal view renders the actual node dot; this overlay only adds
// the chrome around it. Sized in absolute screen points so the reticle
// remains legible regardless of camera distance.

import SwiftUI

struct HoverNodeIndicator: View {
    /// Diameter of the static accent ring drawn just outside the node.
    private let outlineDiameter: CGFloat = 13

    /// Diameter of the pulse ring at scale 1.0. The HTML reference uses
    /// inset:-22px around an 11px node — 55pt total. Scaled here to
    /// match Ohia's smaller Metal-rendered node.
    private let pulseBaseDiameter: CGFloat = 36

    /// Peak scale at the midpoint of the cycle (0.50 phase).
    private let pulsePeakScale: CGFloat = 1.45

    /// Full pulse cycle in seconds. 3.5s ease-in-out matches the
    /// preview's `@keyframes ring` cadence.
    private let cycleSeconds: TimeInterval = 3.5

    /// Reset point so each new hover begins at scale 1.0 / opacity 0.50.
    @State private var startDate = Date.now

    var body: some View {
        ZStack {
            pulseRing
            outlineRing
        }
        .allowsHitTesting(false)
    }

    /// Static thin accent ring sitting just outside the node — the
    /// "you are here" outline. Drawn on top of the pulse so the
    /// pulse appears to emanate from behind it.
    private var outlineRing: some View {
        Circle()
            .strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1)
            .frame(width: outlineDiameter, height: outlineDiameter)
    }

    /// Pulse ring driven by TimelineView so the animation is fully
    /// deterministic — independent of SwiftUI body re-evaluations
    /// triggered by the surrounding hover state. Phase is computed from
    /// elapsed time since the view appeared, so each new hover begins
    /// at scale 1.0 / opacity 0.50 instead of mid-cycle.
    private var pulseRing: some View {
        TimelineView(.animation(minimumInterval: OhiaAnimationCadence.frameInterval)) { context in
            let phase = pulsePhase(at: context.date)
            // Triangle wave 0 → 1 → 0 across one cycle, smoothed for
            // ease-in-out.
            let triangle = 1 - abs(2 * phase - 1)
            let eased = triangle * triangle * (3 - 2 * triangle)
            let scale = 1.0 + (pulsePeakScale - 1.0) * eased
            // Opacity 0.50 at scale=1.0, fading to 0 at peak — matches
            // the HTML keyframe pair exactly.
            let opacity = 0.50 * (1 - eased)

            Circle()
                .strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1)
                .frame(width: pulseBaseDiameter, height: pulseBaseDiameter)
                .scaleEffect(scale)
                .opacity(opacity)
        }
    }

    private func pulsePhase(at date: Date) -> CGFloat {
        let elapsed = date.timeIntervalSince(startDate)
        let cycles = elapsed / cycleSeconds
        return CGFloat(cycles - floor(cycles))
    }
}
