// ActivityStripGaugeMath.swift
// Pure phase-math helpers for ActivityStripGauge. No SwiftUI imports — every
// function is a deterministic mapping from time / phase → shape parameters
// so the gauge animations are unit-testable from OhiaTests without spinning
// up a render context.
//
// Spec: docs/superpowers/specs/2026-05-03-activity-strip-progress-bar-design.md

import Foundation

enum ActivityStripGaugeMath {

    // MARK: - Cycle phase

    /// Maps an absolute `Date` to a cycle phase in `[0, 1)`. Pure: depends
    /// only on `t` and the cycle length.
    static func cyclePhase(at t: Date, cycleSeconds: TimeInterval) -> Double {
        let seconds = t.timeIntervalSinceReferenceDate
        let modded = seconds.truncatingRemainder(dividingBy: cycleSeconds)
        let positive = modded < 0 ? modded + cycleSeconds : modded
        return positive / cycleSeconds
    }

    // MARK: - Flow particle (IMAP backfill)

    /// Horizontal offset of a single flow packet's leading edge, as a
    /// fraction of the track width. Mirrors the mockup CSS:
    /// `transform: translateX(-30%) -> translateX(720%)` on a packet whose
    /// own width is 14% of the track.
    static func flowParticleOffset(phase: Double, packetWidthFraction: Double) -> Double {
        let p = clamp(phase, 0, 1)
        return packetWidthFraction * (-0.30 + 7.50 * p)
    }

    /// Opacity envelope for a flow packet — ramps in 0–10%, holds, ramps
    /// out 90–100%. Returned in `[0, 1]`.
    ///
    /// Uses `p * 10.0` and `10.0 - p * 10.0` rather than dividing by 0.10
    /// so that the canonical test inputs (0.05, 0.95, etc.) yield exact IEEE
    /// 754 results without floating-point rounding error.
    static func flowParticleOpacity(phase: Double) -> Double {
        let p = clamp(phase, 0, 1)
        if p < 0.10 { return p * 10.0 }
        if p > 0.90 { return 10.0 - p * 10.0 }
        return 1.0
    }

    // MARK: - Heartbeat (watching)

    /// Sinusoidal breathe between dim+small at phase 0 and bright+full at
    /// phase 0.5. Caller picks the cycle period; this is a phase→shape map.
    static func heartbeatBreathe(phase: Double) -> (opacity: Double, scale: Double, unit: Double) {
        let p = clamp(phase, 0, 1)
        // sin(2π·p) shifted so the *minimum* is at p=0,1 and the *maximum*
        // is at p=0.5. (1 - cos(2π·p)) / 2 maps p∈[0,1] → [0,1] with the
        // peak at the half-cycle.
        let breath = (1.0 - cos(2.0 * .pi * p)) / 2.0
        let opacity = 0.30 + 0.70 * breath
        let scale = 0.78 + 0.22 * breath
        return (opacity, scale, breath)
    }

    /// Asymmetric attention pulse from the states mockup:
    /// dim → bright → dim → bright → dim, then a longer dim hold.
    static func attentionPulse(phase: Double) -> (opacity: Double, scale: Double) {
        let keyframes: [(phase: Double, opacity: Double, scale: Double)] = [
            (0.00, 0.55, 0.85),
            (0.18, 1.00, 1.05),
            (0.28, 0.55, 0.85),
            (0.44, 1.00, 1.05),
            (0.60, 0.55, 0.85),
            (1.00, 0.55, 0.85),
        ]
        return interpolateOpacityScaleKeyframes(
            phase: clamp(phase, 0, 1),
            keyframes: keyframes,
            easing: cssEaseInOut
        ) ?? (opacity: 0.55, scale: 0.85)
    }

    // MARK: - Hold (pending)

    /// Pending "Hold" envelope: a charge that eases up to full by ~35 % of the
    /// cycle, holds through ~70 %, then releases back to zero by the loop seam —
    /// so a queued job reads as "charged, waiting its turn", distinct from the
    /// watching heartbeat's smooth sinusoid, and the loop is seamless (charge is
    /// 0 at both p=0 and p=1).
    static func holdCharge(phase: Double) -> Double {
        let p = clamp(phase, 0, 1)
        let rise = cssEaseInOut(clamp(p / 0.35, 0, 1))
        let fall = cssEaseInOut(clamp((p - 0.7) / 0.3, 0, 1))
        return rise * (1 - fall)
    }

    // MARK: - Sync pulse (connecting / authing / syncing / gap-check)

    /// Pulse position as a fraction of the track (0 = leading edge,
    /// 1 = trailing edge), plus a soft opacity ramp at both ends so the
    /// pulse fades on/off rather than popping into existence.
    static func syncPulse(phase: Double) -> (position: Double, opacity: Double) {
        let p = clamp(phase, 0, 1)
        let opacity: Double
        if p < 0.12 { opacity = p / 0.12 }
        else if p > 0.88 { opacity = (1.0 - p) / 0.12 }
        else { opacity = 1.0 }
        return (position: cssEaseInOut(p), opacity: opacity)
    }

    /// Center-gate emphasis for the signing-in/authing state. The traveling
    /// pulse still describes network motion, while this gate makes authing
    /// visually distinct from plain connecting.
    static func authGatePulse(phase: Double) -> (opacity: Double, scale: Double) {
        let pulse = syncPulse(phase: phase)
        let distanceFromCenter = abs(pulse.position - 0.5)
        let unit = 1 - clamp(distanceFromCenter / 0.18, 0, 1)
        return (
            opacity: 0.35 + 0.65 * unit * pulse.opacity,
            scale: 0.75 + 0.25 * unit
        )
    }

    /// Gap-check ripple at the trailing edge. Mirrors the mockup's
    /// `gap-ripple` keyframes: inactive through 80%, visible at 85%, then
    /// expands to 3.2x while fading by the end of the cycle.
    static func gapRipple(phase: Double) -> (scale: Double, opacity: Double) {
        let p = clamp(phase, 0, 1)
        if p < 0.80 { return (scale: 0, opacity: 0) }
        if p <= 0.85 {
            let t = cssEaseOut((p - 0.80) / 0.05)
            return (scale: 0.6 * t, opacity: t)
        }
        let t = cssEaseOut((p - 0.85) / 0.15)
        return (scale: lerp(0.6, 3.2, t), opacity: 1 - t)
    }

    /// Reconnect pulse keyframes from the states mockup. The returned
    /// `left` is the CSS `left` percentage as a track fraction. The CSS
    /// uses `steps(4, end)`, so interpolation jumps in four discrete
    /// intervals instead of fading smoothly.
    static func reconnectPulse(phase: Double) -> (left: Double, opacity: Double) {
        let p = clamp(phase, 0, 1)
        let keyframes: [(phase: Double, left: Double, opacity: Double)] = [
            (0.00, 0.05, 0.0),
            (0.18, 0.05, 0.9),
            (0.25, 0.05, 0.0),
            (0.40, 0.35, 0.0),
            (0.55, 0.35, 0.9),
            (0.62, 0.35, 0.0),
            (0.75, 0.65, 0.0),
            (0.88, 0.65, 0.9),
            (1.00, 0.65, 0.0),
        ]
        guard let segment = keyframeSegment(phase: p, keyframes: keyframes.map(\.phase)) else {
            return (left: 0.05, opacity: 0)
        }
        let start = keyframes[segment.lower]
        let end = keyframes[segment.upper]
        let stepped = cssStepsEnd(4, segment.local)
        return (
            left: lerp(start.left, end.left, stepped),
            opacity: lerp(start.opacity, end.opacity, stepped)
        )
    }

    // MARK: - Supernova event narrative (new mail)
    // Reference: ConstellationMetalShaders.metal:272-325
    // Master cycle = `durationSeconds` (3.0s in the HTML mockup).
    // Comet:        master 0.00 - 0.36
    // Flash core:   master 0.35 - 0.55  (shader [0.00, 0.18] mapped onto
    //                                     supernova-internal [0, 0.30] for
    //                                     the rapid-then-fade envelope)
    // Shockwave:    master 0.385 - 0.95 (shader [0.10, 0.95])
    // Settled body: master 0.625 - 1.00 (shader [0.55, 1.00])

    /// Position of the chromatic shockwave ring relative to the white center
    /// per the shader's gravitational chromatic aberration: `inner` lags
    /// (red, 0.96× radius), `center` is the white wavefront (1.0× radius),
    /// `outer` leads (cyan, 1.04× radius).
    enum SupernovaShockColor { case inner, center, outer }

    /// Returns master phase in `[0, 1]` if `now` falls within the event
    /// window starting at `eventStart`; nil otherwise. Generic event-window
    /// helper used by both the supernova and event-horizon animations.
    static func animationPhase(at now: Date, eventStart: Date, durationSeconds: TimeInterval) -> Double? {
        let elapsed = now.timeIntervalSince(eventStart)
        guard elapsed >= 0, elapsed <= durationSeconds else { return nil }
        return elapsed / durationSeconds
    }

    /// Comet position as a track-fraction `[0, 1]` and opacity `[0, 1]`,
    /// or nil after it has handed off to the flash core.
    static func supernovaComet(phase: Double) -> (position: Double, opacity: Double)? {
        guard phase < 0.36 else { return nil }
        let position: Double
        if phase <= 0.33 {
            position = lerp(-0.10, 1.0, cssEaseIn(phase / 0.33))
        } else {
            position = 1.0
        }
        let opacity: Double
        if phase < 0.08 { opacity = phase / 0.08 }
        else if phase < 0.33 { opacity = 1 }
        else { opacity = max(0, 1 - (phase - 0.33) / 0.03) }
        return (position: position, opacity: opacity)
    }

    /// CSS-faithful frame for `.nm-comet`: `left: -10% -> 100%-14px -> 100%-6px`,
    /// `width: 14px -> 14px -> 0`, with `ease-in` timing.
    static func supernovaCometFrame(
        phase: Double,
        trackWidth: Double,
        baseWidth: Double
    ) -> (leadingX: Double, width: Double, opacity: Double)? {
        guard phase < 0.36 else { return nil }

        let leadingX: Double
        let width: Double
        if phase <= 0.33 {
            let eased = cssEaseIn(phase / 0.33)
            leadingX = lerp(-0.10 * trackWidth, trackWidth - baseWidth, eased)
            width = baseWidth
        } else {
            let eased = cssEaseIn((phase - 0.33) / 0.03)
            leadingX = lerp(trackWidth - baseWidth, trackWidth - 6, eased)
            width = lerp(baseWidth, 0, eased)
        }

        let opacity: Double
        if phase < 0.08 { opacity = phase / 0.08 }
        else if phase < 0.33 { opacity = 1 }
        else { opacity = max(0, 1 - (phase - 0.33) / 0.03) }
        return (leadingX, width, opacity)
    }

    /// White flash core: opacity bell-curves through master [0.35, 0.55],
    /// scale grows fast 0 → 2.0 over the same window.
    static func supernovaFlashCore(phase: Double) -> (opacity: Double, scale: Double) {
        let keyframes: [(phase: Double, opacity: Double, scale: Double)] = [
            (0.35, 0.0, 0.0),
            (0.37, 1.0, 0.4),
            (0.47, 1.0, 1.4),
            (0.55, 0.0, 2.0),
        ]
        guard let value = interpolateOpacityScaleKeyframes(
            phase: phase,
            keyframes: keyframes,
            easing: cssEaseOut
        ) else {
            return (opacity: 0, scale: 0)
        }
        return (opacity: value.0, scale: value.1)
    }

    /// Chromatic shockwave ring scale and opacity. Returns nil outside the
    /// shockwave window. Each color rides the same easeOutCubic timing but
    /// terminal radii at slightly different ratios — red 0.96×, white 1.0×,
    /// cyan 1.04× — the shader's gravitational chromatic aberration.
    static func supernovaShockwave(
        phase: Double,
        color: SupernovaShockColor
    ) -> (scale: Double, opacity: Double, lineWidth: Double)? {
        guard phase >= 0.385 && phase <= 0.95 else { return nil }
        let middleScale: Double
        let finalScale: Double
        let middleOpacity: Double
        switch color {
        case .inner:
            middleScale = 0.58
            finalScale = 2.69
            middleOpacity = 0.85
        case .center:
            middleScale = 0.60
            finalScale = 2.80
            middleOpacity = 1.0
        case .outer:
            middleScale = 0.62
            finalScale = 2.91
            middleOpacity = 0.90
        }

        let keyframes: [(phase: Double, scale: Double, opacity: Double, lineWidth: Double)] = [
            (0.385, 0.0, 0.0, 1.5),
            (0.42, middleScale, middleOpacity, 1.5),
            (0.95, finalScale, 0.0, 0.8),
        ]
        guard let value = interpolateScaleOpacityLineWidthKeyframes(
            phase: phase,
            keyframes: keyframes,
            easing: cssShockEase
        ) else {
            return nil
        }
        return (scale: value.0, opacity: value.1, lineWidth: value.2)
    }

    /// Settled cyan body fades in over master [0.625, 1.0] from scale 0.4×
    /// to scale 1.0×.
    static func supernovaSettledBody(phase: Double) -> (opacity: Double, scale: Double) {
        guard phase >= 0.625 else { return (opacity: 0, scale: 0.4) }
        let local = cssEaseOut((phase - 0.625) / 0.375)
        let opacity = clamp(local, 0, 1)
        let scale = 0.4 + 0.6 * opacity
        return (opacity, scale)
    }

    // MARK: - Event horizon event narrative (deletions updated)
    // Reference: ConstellationMetalShaders.metal:242-269
    // Master cycle = `durationSeconds` (3.0s in the HTML mockup).
    // Comet:        master 0.00 - 0.36 (matter pulled R→L, ease-in)
    // Body:         master 0.36 - 0.7825 (shader [0.00, 0.65] bodyShrink)
    // Black disc:   master 0.4575 - 0.9125 (grow, shader [0.15, 0.85])
    //               master 0.9125 - 1.00   (collapse, shader [0.85, 1.00])
    // Lens ring:    master 0.54 - 0.9125 (shader [0.277, 0.85] sin(π·t) bell —
    //               note: the master start of 0.54 maps to shader 0.277, slightly
    //               earlier than the shader's nominal [0.30, 0.85]; visually
    //               imperceptible at the strip's compact scale)

    /// Comet pulled R→L. Position is measured from the right edge as a
    /// fraction `[0, 1]` of the track (0 = right edge, 1 = left edge),
    /// since this animation conceptually "moves toward the sink." Returns
    /// nil after the comet has handed off into the body.
    static func eventHorizonComet(phase: Double) -> (positionFromRight: Double, opacity: Double)? {
        guard phase < 0.36 else { return nil }
        let position: Double
        if phase <= 0.28 {
            position = lerp(-0.10, 0.50, cssEaseIn(phase / 0.28))
        } else if phase <= 0.33 {
            position = lerp(0.50, 1.0, cssEaseIn((phase - 0.28) / 0.05))
        } else {
            position = 1.0
        }
        let opacity: Double
        if phase < 0.08 { opacity = phase / 0.08 }
        else if phase < 0.33 { opacity = 1 }
        else { opacity = max(0, 1 - (phase - 0.33) / 0.03) }
        return (positionFromRight: position, opacity: opacity)
    }

    /// CSS-faithful frame for `.eh-comet`: uses right-edge keyframes and
    /// `ease-in` timing to create the gravitational pull into the left sink.
    static func eventHorizonCometFrame(
        phase: Double,
        trackWidth: Double,
        baseWidth: Double
    ) -> (leadingX: Double, width: Double, opacity: Double)? {
        guard phase < 0.36 else { return nil }

        let right: Double
        let width: Double
        if phase <= 0.28 {
            let eased = cssEaseIn(phase / 0.28)
            right = lerp(-0.10 * trackWidth, 0.50 * trackWidth, eased)
            width = lerp(baseWidth, 18, eased)
        } else if phase <= 0.33 {
            let eased = cssEaseIn((phase - 0.28) / 0.05)
            right = lerp(0.50 * trackWidth, trackWidth - 14, eased)
            width = lerp(18, 8, eased)
        } else {
            let eased = cssEaseIn((phase - 0.33) / 0.03)
            right = lerp(trackWidth - 14, trackWidth - 6, eased)
            width = lerp(8, 0, eased)
        }

        let opacity: Double
        if phase < 0.08 { opacity = phase / 0.08 }
        else if phase < 0.33 { opacity = 1 }
        else { opacity = max(0, 1 - (phase - 0.33) / 0.03) }
        return (leadingX: trackWidth - right - width, width: width, opacity: opacity)
    }

    /// Body scale `[0, 1]` — materializes at scale 1 at master 0.36, then
    /// linearly shrinks to 0 by master 0.7825 (shader's `1 - clamp(d/0.65)`).
    /// Returns 0 outside the materialize window.
    static func eventHorizonBodyShrink(phase: Double) -> Double {
        eventHorizonBody(phase: phase).scale
    }

    static func eventHorizonBody(phase: Double) -> (opacity: Double, scale: Double) {
        let keyframes: [(phase: Double, opacity: Double, scale: Double)] = [
            (0.33, 0.0, 0.0),
            (0.36, 1.0, 1.0),
            (0.7825, 0.0, 0.0),
        ]
        return interpolateOpacityScaleKeyframes(
            phase: phase,
            keyframes: keyframes,
            easing: cssEaseInOut
        ) ?? (opacity: 0, scale: 0)
    }

    /// Black disc radial scale — grows from 0 to 2.10× over master
    /// [0.4575, 0.9125], then collapses linearly to 0 over [0.9125, 1.00].
    /// Follows the shader's `discRadius` formula (using shader's `deletion`
    /// variable d ∈ [0,1]: grow `(d/0.85) × 1.05`; collapse `1.05 × (1 − (d−0.85)/0.15)`)
    /// scaled by 2 because the shader returns a normalized UV radius in
    /// [0, ~1] while this function returns a SwiftUI scale multiplier
    /// relative to the 12 pt ring diameter.
    static func eventHorizonDisc(phase: Double) -> Double {
        eventHorizonDiscState(phase: phase).scale
    }

    static func eventHorizonDiscState(phase: Double) -> (opacity: Double, scale: Double) {
        let keyframes: [(phase: Double, opacity: Double, scale: Double)] = [
            (0.4575, 0.0, 0.0),
            (0.47, 1.0, 0.05),
            (0.9125, 1.0, 2.10),
            (0.99, 1.0, 0.0),
            (0.995, 0.0, 0.0),
        ]
        return interpolateOpacityScaleKeyframes(
            phase: phase,
            keyframes: keyframes,
            easing: linear
        ) ?? (opacity: 0, scale: 0)
    }

    /// Einstein lensing ring — opacity follows `sin(π × lensT)` bell over
    /// master [0.54, 0.9125], which corresponds to shader [0.277, 0.85].
    /// (Slightly wider than the shader's nominal [0.30, 0.85] — the master
    /// start is 0.54 rather than 0.555 to give the lensing a small head-start
    /// against the disc's growth; visually imperceptible.) Scale tracks the
    /// disc 0.05 → 1.65. Returns (opacity: 0, scale: 0) outside the window.
    /// The HTML mockup uses explicit opacity keyframes rather than computing
    /// the sine directly; the keyframes preserve the same bell shape and peak.
    static func eventHorizonLensRing(phase: Double) -> (opacity: Double, scale: Double) {
        let keyframes: [(phase: Double, opacity: Double, scale: Double)] = [
            (0.54, 0.0, 0.05),
            (0.60, 0.4, 0.55),
            (0.726, 1.0, 1.10),
            (0.85, 0.5, 1.50),
            (0.9125, 0.0, 1.65),
        ]
        return interpolateOpacityScaleKeyframes(
            phase: phase,
            keyframes: keyframes,
            easing: cssEaseInOut
        ) ?? (opacity: 0, scale: 0)
    }

    // MARK: - Weight spectrum (training)

    /// Normalized bar height in `[0, 1]` for the training "weight spectrum"
    /// gauge. Each bar oscillates on its own phase; as `jitter` falls toward 0
    /// (training progress rising) the bar relaxes from its live oscillation
    /// toward a fixed smooth target profile. `jitter` is clamped to `[0, 1]` —
    /// pass `1` for the indeterminate steady form, `1 - fraction` for the
    /// determinate form.
    static func spectrumBarHeight(phase: Double, index: Int, jitter: Double) -> Double {
        let live = 0.5 + 0.5 * sin(2.0 * .pi * clamp(phase, 0, 1) + Double(index))
        let target = 0.45 + 0.4 * sin(Double(index) * 1.1)
        return clamp(lerp(target, live, clamp(jitter, 0, 1)), 0, 1)
    }

    // MARK: - Reconcile tally (deletions reconciling)

    /// Travel fraction `[0, 1]` of a tally bead from its lane edge toward the
    /// center, reaching the meeting point at master phase 0.7. Eased so the
    /// beads ease-in and ease-out of their approach.
    static func reconcileTallyTravel(phase: Double) -> Double {
        cssEaseInOut(clamp(phase / 0.7, 0, 1))
    }

    /// Annihilation-spark progress `[0, 1]` after the beads meet (phase ≥ 0.7),
    /// or nil while the beads are still travelling. Drives the white flash and
    /// expanding amber ring at the meeting point.
    static func reconcileTallySpark(phase: Double) -> Double? {
        guard phase >= 0.7 else { return nil }
        return clamp((phase - 0.7) / 0.3, 0, 1)
    }

    // MARK: - Coalescence (dreaming)

    /// Convergence factor in `[0, 1]` for the dreaming "coalescence" gauge: 0 at
    /// the cycle edges (motes dispersed across the lane), 1 at mid-cycle (motes
    /// condensed into a single distilled node). Same `(1 - cos)/2` breathe shape
    /// the watching heartbeat uses, so the two share a tempo family.
    static func coalescenceConvergence(phase: Double) -> Double {
        (1.0 - cos(2.0 * .pi * clamp(phase, 0, 1))) / 2.0
    }

    // MARK: - Stage motifs (datafying / summarizing)
    //
    // Two "read the long body, leave a short gist" compression motifs, ported
    // from the ActivityStripGuide decision gallery. Each is a deterministic phase →
    // scalar map; the gauge composes geometry from these scalars. All use the
    // smoothstep (Hermite) easing the gallery used, distinct from the CSS-bezier
    // easings the IMAP/event animations above use.

    /// Distill (datafying): a field of body marks is drawn inward into a short
    /// bright essence. `appear` ramps the motif in over the first 10%;
    /// `compression` 0→1 collapses the marks toward center over the first 72%;
    /// `fade` ramps the essence out in the final 14%; `flash` is the white spark
    /// at near-full compression.
    static func distillFrame(phase: Double) -> (appear: Double, compression: Double, fade: Double, flash: Double) {
        let p = clamp(phase, 0, 1)
        let appear = clamp(p / 0.10, 0, 1)
        let compression = smoothstep(clamp(p / 0.72, 0, 1))
        let fade = p > 0.86 ? clamp(1 - (p - 0.86) / 0.14, 0, 1) : 1.0
        let flash = max(0, (compression - 0.9) / 0.1) * fade
        return (appear, compression, fade, flash)
    }

    /// Précis (summarizing): two arcs close inward (0→1) to ring the core, hold, then reopen.
    /// `appear` ramps in over the first 8%; `squeeze` rises to 1 by 70%, holds
    /// through 85%, then releases; `flash` is the white spark at full closure.
    static func precisFrame(phase: Double) -> (appear: Double, squeeze: Double, flash: Double) {
        let p = clamp(phase, 0, 1)
        let appear = clamp(p / 0.08, 0, 1)
        let squeeze: Double
        if p < 0.70 { squeeze = smoothstep(p / 0.70) }
        else if p < 0.85 { squeeze = 1 }
        else { squeeze = 1 - smoothstep((p - 0.85) / 0.15) }
        let flash = max(0, (squeeze - 0.92) / 0.08)
        return (appear, squeeze, flash)
    }

    /// Précis ring — one half-arc's angle span, in degrees. `leading` picks
    /// which side (left/right) it sweeps around; `start`/`delta` feed
    /// `Path.addRelativeArc` directly. The half-sweep grows from a short
    /// outward hook (32°) at `squeeze == 0` to an exact quarter-turn (90°)
    /// at `squeeze == 1`, so the leading arc (centered on 180°) and trailing
    /// arc (centered on 0°) meet edge-to-edge at 90°/270° and trace one
    /// continuous ring at full squeeze.
    static func precisArcAngles(leading: Bool, squeeze: Double) -> (start: Double, delta: Double) {
        let halfSweep = lerp(32, 90, clamp(squeeze, 0, 1))
        let centerAngle = leading ? 180.0 : 0.0
        return (start: centerAngle - halfSweep, delta: halfSweep * 2)
    }

    /// Smoothstep (Hermite) easing — symmetric ease-in-out, distinct from the
    /// CSS cubic-bezier easings used by the IMAP/event animations.
    nonisolated static func smoothstep(_ t: Double) -> Double {
        let x = clamp(t, 0, 1)
        return x * x * (3 - 2 * x)
    }

    // MARK: - Generation motifs (translating / asking / categorizing / drafting)
    //
    // Indeterminate generative-model activities — no progress fraction. Ported
    // from the ActivityStripGuide candidate study; each is a deterministic phase →
    // scalar map the gauge composes geometry from, in the smoothstep easing.

    /// Cipher (translating): scrambled source marks jitter, then resolve into
    /// clean target marks. `appear` ramps in over the first 6%; `resolve` 0→1
    /// settles the jitter and crossfades source → target over phase [0.15, 0.75].
    static func cipherFrame(phase: Double) -> (appear: Double, resolve: Double) {
        let p = clamp(phase, 0, 1)
        return (clamp(p / 0.06, 0, 1), smoothstep(clamp((p - 0.15) / 0.6, 0, 1)))
    }

    /// Converse (asking): a question dot and an answer dot lean in and link.
    /// `lean` is a 0→1→0 breathe (peak at mid-cycle); `appear` ramps in.
    static func converseFrame(phase: Double) -> (appear: Double, lean: Double) {
        let p = clamp(phase, 0, 1)
        let lean = (1 - cos(2 * Double.pi * p)) / 2
        return (clamp(p / 0.06, 0, 1), lean)
    }

    /// Tag (categorizing): a pass attaches a tag-cap to each mark. `sweep` 0→1
    /// advances the tagging front over the first 85%; `appear` ramps in.
    static func tagFrame(phase: Double) -> (appear: Double, sweep: Double) {
        let p = clamp(phase, 0, 1)
        return (clamp(p / 0.06, 0, 1), smoothstep(min(p / 0.85, 1)))
    }

    /// Typewriter (drafting): word-marks appear one by one. `reveal` 0→1 drives
    /// how many marks are visible over the first 90%; `appear` ramps in.
    static func typewriterFrame(phase: Double) -> (appear: Double, reveal: Double) {
        let p = clamp(phase, 0, 1)
        return (clamp(p / 0.06, 0, 1), clamp(p / 0.9, 0, 1))
    }

    // MARK: - Generation motifs II
    //
    // The seven model activities that previously shared the training spectrum,
    // now each with a bespoke motif: questioning (probe), extracting (pull),
    // remembering (consolidate), refining (hone), learning (weights), embedding
    // (encode), captioning (trace). Same convention as above — a deterministic
    // phase → scalar map the gauge composes geometry from, in smoothstep easing.

    /// Sift (compiling): a gate sweeps across candidate marks, splitting each
    /// into a kept or discarded track as it passes. `sweep` 0→1 advances the
    /// gate over the first 85%; `appear` ramps in.
    static func siftFrame(phase: Double) -> (appear: Double, sweep: Double) {
        let p = clamp(phase, 0, 1)
        return (clamp(p / 0.06, 0, 1), smoothstep(min(p / 0.85, 1)))
    }

    /// Probe (questioning): a lens sweeps the source, raising a question at each
    /// point. `sweep` 0→1 advances the lens over the first 85%; `appear` ramps in.
    static func probeFrame(phase: Double) -> (appear: Double, sweep: Double) {
        let p = clamp(phase, 0, 1)
        return (clamp(p / 0.06, 0, 1), smoothstep(min(p / 0.85, 1)))
    }

    /// Pull (extracting): marks are drawn out of a container one by one.
    /// `progress` is the raw cycle position the per-mark staggered extraction
    /// reads (each mark eases over a 0.55-wide window offset by index); `appear`
    /// ramps in.
    static func pullFrame(phase: Double) -> (appear: Double, progress: Double) {
        let p = clamp(phase, 0, 1)
        return (clamp(p / 0.06, 0, 1), p)
    }

    /// Consolidate (remembering): scattered traces drift inward and merge into a
    /// core. `gather` 0→1 pulls the motes to center over phase [0.05, 0.75];
    /// `merged` fades the motes out as the core completes; `appear` ramps in.
    static func consolidateFrame(phase: Double) -> (appear: Double, gather: Double, merged: Double) {
        let p = clamp(phase, 0, 1)
        let gather = smoothstep(clamp((p - 0.05) / 0.7, 0, 1))
        let merged = clamp((p - 0.7) / 0.2, 0, 1)
        return (clamp(p / 0.06, 0, 1), gather, merged)
    }

    /// Hone (refining): a jittery spread tightens and sharpens into a clean line.
    /// `sharp` 0→1 removes the jitter and crossfades source → target over phase
    /// [0.05, 0.85]; `appear` ramps in.
    static func honeFrame(phase: Double) -> (appear: Double, sharp: Double) {
        let p = clamp(phase, 0, 1)
        return (clamp(p / 0.06, 0, 1), smoothstep(clamp((p - 0.05) / 0.8, 0, 1)))
    }

    /// Weights (learning): a row of bars adjusts its heights toward a learned
    /// profile. `adjust` 0→1 drives the bars from a flat baseline to their target
    /// heights over phase [0.05, 0.85]; `appear` ramps in.
    static func weightsFrame(phase: Double) -> (appear: Double, adjust: Double) {
        let p = clamp(phase, 0, 1)
        return (clamp(p / 0.06, 0, 1), smoothstep(clamp((p - 0.05) / 0.8, 0, 1)))
    }

    /// Encode (embedding): a sweep quantizes irregular source marks into uniform
    /// points. `sweep` 0→1 advances the encoding front over the first 85%;
    /// `appear` ramps in.
    static func encodeFrame(phase: Double) -> (appear: Double, sweep: Double) {
        let p = clamp(phase, 0, 1)
        return (clamp(p / 0.06, 0, 1), smoothstep(min(p / 0.85, 1)))
    }

    /// Trace (captioning): an outline draws around a shape, then caption words
    /// emit from it. `drawn` 0→1 traces the outline over the first 55%; `emit`
    /// 0→1 releases the words over phase [0.55, 0.95]; `appear` ramps in.
    static func traceFrame(phase: Double) -> (appear: Double, drawn: Double, emit: Double) {
        let p = clamp(phase, 0, 1)
        let drawn = smoothstep(min(p / 0.55, 1))
        let emit = clamp((p - 0.55) / 0.4, 0, 1)
        return (clamp(p / 0.06, 0, 1), drawn, emit)
    }

    /// Docking (model loading into memory): the cycle envelope for the
    /// blocks-docking motif. `loaded` 0→1 over the first 82% drives how many
    /// parameter blocks have docked (per-slot timing is derived in the view from
    /// a scattered dock order); `env` holds full, then dims over the last 8% for a
    /// clean reset before the next load.
    static func dockingFrame(phase: Double) -> (loaded: Double, env: Double) {
        let p = clamp(phase, 0, 1)
        let loaded = p < 0.82 ? smoothstep(p / 0.82) : 1
        let env = p < 0.92 ? 1.0 : 1 - smoothstep((p - 0.92) / 0.08)
        return (loaded, env)
    }

    /// Whiteness of a rise-from-below docking block (the odd slots — the 2nd and
    /// 4th from the left) as it locks into its slot. Zero until the block's final
    /// approach, ramps 0→1 across the lock-in window, then holds at 1 for the rest
    /// of the cycle because a docked block's `local` saturates at 1. So those two
    /// blocks light to white as they arrive and *stay* white until the strip dims
    /// and re-arms — matching each other as a pair. Blocks dropping from above
    /// never call this and stay green.
    static func dockLockWhiteness(local: Double) -> Double {
        guard local > 0.82 else { return 0 }
        return smoothstep((local - 0.82) / 0.18)
    }

    /// Kindle (model loading / downloading): a spark sweeps a band of filaments,
    /// lighting each as it passes; once lit they hold while a unified glow
    /// confirms the model is online, then everything dims and re-arms. Expresses
    /// a one-time warm-up rather than a steady cyclic process — the long lit-hold
    /// dominates the cycle so it reads as "coming online," not "busy looping."
    /// - `appear`: entry/exit envelope — ramps in over the first 6%, out over the last 10%.
    /// - `sweep`: kindling-head position 0→1 over the first half, then holds at 1.
    /// - `glow`: unified "online" glow — rises as the sweep completes, holds, then fades.
    /// - `spark`: kindling-head brightness — bright while sweeping, fading after.
    static func kindleFrame(phase: Double) -> (appear: Double, sweep: Double, glow: Double, spark: Double) {
        let p = clamp(phase, 0, 1)
        let appearIn = clamp(p / 0.06, 0, 1)
        let appearOut = 1 - smoothstep(clamp((p - 0.90) / 0.10, 0, 1))
        let appear = appearIn * appearOut
        let sweep = smoothstep(min(p / 0.5, 1))
        let glow: Double
        if p < 0.45 {
            glow = 0
        } else if p < 0.65 {
            glow = smoothstep((p - 0.45) / 0.20)
        } else if p < 0.85 {
            glow = 1
        } else {
            glow = 1 - smoothstep(clamp((p - 0.85) / 0.10, 0, 1))
        }
        let spark = 1 - smoothstep(clamp((p - 0.42) / 0.12, 0, 1))
        return (appear, sweep, glow, spark)
    }

    /// Polling (running IMAP poll job): a radar ping. A baseline dot flashes as
    /// it emits a ring that expands outward (easeOut) and fades as it grows, then
    /// a short listen pause before the next ping. A periodic probe, distinct from
    /// `.syncing`'s one-way traveling sweep.
    /// - `dot`: central dot brightness — a flash at the ping decaying to a dim baseline.
    /// - `ringExpansion`: ring growth 0→1 over the active window, then 0 during the pause.
    /// - `ringOpacity`: ring fade — ramps in fast, then dies out as the ring expands; 0 during the pause.
    static func pollFrame(phase: Double) -> (dot: Double, ringExpansion: Double, ringOpacity: Double) {
        let p = clamp(phase, 0, 1)
        // Central dot: bright ping flash at the cycle start, decaying to a dim
        // baseline that holds through the listen/pause gap.
        let flash = 1 - smoothstep(clamp(p / 0.18, 0, 1))
        let dot = 0.45 + 0.55 * flash
        // Ring active window [0, 0.72]; [0.72, 1.0] is the quiet listen gap.
        let active = 0.72
        guard p < active else { return (dot, 0, 0) }
        let t = p / active
        let ringExpansion = 1 - (1 - t) * (1 - t)        // easeOutQuad 0→1
        let rampIn = clamp(t / 0.10, 0, 1)
        let ringOpacity = rampIn * (1 - smoothstep(t))   // peaks early, fades as it grows
        return (dot, ringExpansion, ringOpacity)
    }

    // MARK: - Helpers

    private nonisolated static func interpolateOpacityScaleKeyframes(
        phase: Double,
        keyframes: [(phase: Double, opacity: Double, scale: Double)],
        easing: (Double) -> Double
    ) -> (opacity: Double, scale: Double)? {
        guard let segment = keyframeSegment(phase: phase, keyframes: keyframes.map(\.phase)) else {
            return nil
        }
        let start = keyframes[segment.lower]
        let end = keyframes[segment.upper]
        let t = easing(segment.local)
        return (
            opacity: lerp(start.opacity, end.opacity, t),
            scale: lerp(start.scale, end.scale, t)
        )
    }

    private nonisolated static func interpolateScaleOpacityLineWidthKeyframes(
        phase: Double,
        keyframes: [(phase: Double, scale: Double, opacity: Double, lineWidth: Double)],
        easing: (Double) -> Double
    ) -> (scale: Double, opacity: Double, lineWidth: Double)? {
        guard let segment = keyframeSegment(phase: phase, keyframes: keyframes.map(\.phase)) else {
            return nil
        }
        let start = keyframes[segment.lower]
        let end = keyframes[segment.upper]
        let t = easing(segment.local)
        return (
            scale: lerp(start.scale, end.scale, t),
            opacity: lerp(start.opacity, end.opacity, t),
            lineWidth: lerp(start.lineWidth, end.lineWidth, t)
        )
    }

    private nonisolated static func keyframeSegment(
        phase: Double,
        keyframes: [Double]
    ) -> (lower: Int, upper: Int, local: Double)? {
        guard let first = keyframes.first,
              let last = keyframes.last,
              phase >= first,
              phase <= last else {
            return nil
        }
        for index in 0..<(keyframes.count - 1) {
            let lower = keyframes[index]
            let upper = keyframes[index + 1]
            if phase >= lower && phase <= upper {
                let span = max(upper - lower, .leastNonzeroMagnitude)
                return (index, index + 1, clamp((phase - lower) / span, 0, 1))
            }
        }
        return nil
    }

    private nonisolated static func linear(_ t: Double) -> Double {
        clamp(t, 0, 1)
    }

    private nonisolated static func cssEaseIn(_ t: Double) -> Double {
        cubicBezierY(forX: t, x1: 0.42, y1: 0.0, x2: 1.0, y2: 1.0)
    }

    private nonisolated static func cssEaseOut(_ t: Double) -> Double {
        cubicBezierY(forX: t, x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0)
    }

    private nonisolated static func cssEaseInOut(_ t: Double) -> Double {
        cubicBezierY(forX: t, x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0)
    }

    private nonisolated static func cssShockEase(_ t: Double) -> Double {
        cubicBezierY(forX: t, x1: 0.22, y1: 1.0, x2: 0.36, y2: 1.0)
    }

    private nonisolated static func cssStepsEnd(_ steps: Int, _ t: Double) -> Double {
        guard steps > 0 else { return clamp(t, 0, 1) }
        let clamped = clamp(t, 0, 1)
        if clamped >= 1 { return 1 }
        return floor(clamped * Double(steps)) / Double(steps)
    }

    private nonisolated static func cubicBezierY(
        forX x: Double,
        x1: Double,
        y1: Double,
        x2: Double,
        y2: Double
    ) -> Double {
        let x = clamp(x, 0, 1)
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var low = 0.0
        var high = 1.0
        var t = x
        for _ in 0..<18 {
            t = (low + high) / 2
            let sampleX = cubicBezier(t, 0, x1, x2, 1)
            if sampleX < x {
                low = t
            } else {
                high = t
            }
        }
        return clamp(cubicBezier(t, 0, y1, y2, 1), 0, 1)
    }

    private nonisolated static func cubicBezier(
        _ t: Double,
        _ p0: Double,
        _ p1: Double,
        _ p2: Double,
        _ p3: Double
    ) -> Double {
        let inv = 1 - t
        return inv * inv * inv * p0
            + 3 * inv * inv * t * p1
            + 3 * inv * t * t * p2
            + t * t * t * p3
    }

    nonisolated static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * clamp(t, 0, 1)
    }

    nonisolated static func clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T {
        return min(max(x, lo), hi)
    }
}
