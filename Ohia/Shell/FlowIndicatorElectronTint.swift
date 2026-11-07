// FlowIndicatorElectronTint.swift
// Electron colouring for the activity-strip flow indicator (the atom).
//
// The electrons always render in ONE colour: the account colour of the work
// the strip's readout is currently naming. Summarizing a Gmail message tints
// them with the Gmail account's palette colour; an IMAP backfill on the University
// account tints them with University's. When the engaged activity carries no
// resolvable account (model warm-up, interactive retrieval, corpus-wide lanes
// such as training or layout refine), the tint falls back to the strip's active
// accent so the electrons still read as part of the strip.
//
// The crossfade between account colours is computed here rather than by a
// SwiftUI animation on purpose: the electron layer is a `Canvas` driven by a
// `TimelineView`, and plain values handed to a Canvas are NOT animatable —
// the timeline resets them on every tick. Interpolating against the animation
// clock (which already ticks at ~30 fps while the electrons are mounted) makes
// the fade real without relying on SwiftUI's animation system.

import Foundation

/// Which activity the electron tint is currently keyed to. Equatable so the
/// view can detect a change of engaged account without comparing `Color`s.
nonisolated enum FlowIndicatorTintSource: Equatable {
    /// Work attributable to a specific mailbox account.
    case account(UUID)
    /// Work with no resolvable account, or no accounts configured yet.
    case accent
}

/// What the electron tint is resolved from: the engaged activity's account
/// AND the colour that account (or the accent) currently resolves to.
///
/// The colour has to be part of the key, not just the source: the accent flips
/// between `ohiaYellow` and `ohiaGreen` with the colour scheme, and an
/// account's palette colour can be edited in Settings. Keying on the source
/// alone would freeze the electrons on a stale colour until some *other*
/// activity happened to change the source.
nonisolated struct FlowIndicatorTintKey: Equatable {
    var source: FlowIndicatorTintSource
    var rgb: SIMD3<Double>
}

/// A crossfading sRGB tint. `from` → `to` over `crossfadeDuration`, sampled
/// against the animation clock.
nonisolated struct FlowIndicatorElectronTint: Equatable {
    /// Matches the indicator's other transitions (electron fade-in, nucleus
    /// dim/brighten) so every state change in the cell moves at one tempo.
    static let crossfadeDuration: TimeInterval = 0.7

    private(set) var from: SIMD3<Double>
    private(set) var to: SIMD3<Double>
    private(set) var changedAt: Date
    private(set) var source: FlowIndicatorTintSource

    /// Seed the tint fully settled on `rgb` — no fade on first appearance.
    init(rgb: SIMD3<Double>, source: FlowIndicatorTintSource, at date: Date) {
        self.from = rgb
        self.to = rgb
        self.changedAt = date
        self.source = source
    }

    /// The colour the tint is heading to, ignoring any fade in progress. Used
    /// by the Reduce Motion path, which has no animation clock to sample and
    /// so shows the destination outright rather than a crossfade.
    var settled: SIMD3<Double> { to }

    /// The tint at `now`, eased with a smoothstep so the colour change starts
    /// and ends gently instead of ramping linearly.
    func rgb(at now: Date) -> SIMD3<Double> {
        let elapsed = now.timeIntervalSince(changedAt)
        guard elapsed > 0 else { return from }
        guard elapsed < Self.crossfadeDuration else { return to }
        let t = elapsed / Self.crossfadeDuration
        let eased = t * t * (3 - 2 * t)
        return from + (to - from) * eased
    }

    /// Retarget to a new colour, starting the fade from wherever the current
    /// fade has reached so back-to-back account switches stay continuous
    /// instead of snapping back to the previous colour.
    ///
    /// Retargets when EITHER the source or the resolved colour changes:
    ///  - a genuine source change always retargets, even when two accounts
    ///    happen to share a palette colour;
    ///  - the same source resolving to a new colour also retargets, which is
    ///    what repaints the electrons when the user switches Light/Dark (the
    ///    accent flips yellow↔green) or edits an account's palette colour.
    ///
    /// Re-resolving to an identical (source, colour) pair is a no-op, so the
    /// 1–3 s snapshot cadence never restarts an in-flight fade.
    mutating func retarget(to rgb: SIMD3<Double>, source next: FlowIndicatorTintSource, at date: Date) {
        guard next != source || rgb != to else { return }
        from = self.rgb(at: date)
        to = rgb
        changedAt = date
        source = next
    }
}
