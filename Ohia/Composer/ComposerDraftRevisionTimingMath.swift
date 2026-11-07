// Ohia/Composer/ComposerDraftRevisionTimingMath.swift
// Pure timing/easing helpers for ComposerDraftRevisionOverlay. No SwiftUI
// imports — deterministic mappings from elapsed time / word index → a
// per-word transform, so the landing cascade and scan-phase word selection
// are unit-testable from OhiaTests without spinning up a Canvas/TimelineView
// render context.
//
// The landing constants and easing started as an exact port of the Word
// Morph candidate in ComposerRevisionAnimationSandbox.swift — the one
// approved after comparing four candidates side by side — but that
// candidate's pace (a ~0.85s cascade, tens-of-percent scale swings) read as
// fast and spastic once seen against a real draft rather than the sandbox's
// isolated preview, so the durations were slowed and the scale/blur
// amplitude softened for a calmer, more meditative feel; the *shape* of the
// motion (ease-out growth, staggered arrival) still matches the approved
// candidate. The waiting-scan constants have no sandbox equivalent (the
// sandbox always shows every changed word at once, since its sample data is
// fixed; production can't know which words will change until the model
// responds, so it substitutes a rotating "as if parsing" scan instead).

import Foundation

enum ComposerDraftRevisionTimingMath {
    // MARK: Landing cascade

    static let resolveDuration: TimeInterval = 1.9
    static let addedWordDuration: TimeInterval = 0.7
    static let removedWordDuration: TimeInterval = 0.55
    static let removedStaggerSpan: TimeInterval = 0.45

    static func easeOut(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return 1 - pow(1 - x, 3)
    }

    struct WordEntrance {
        let scale: Double
        let opacity: Double
        let blur: Double
        /// True once past the yellow "still arriving" phase (the sandbox's
        /// `local < 0.6` threshold) — callers use this to pick green vs
        /// yellow for the word's color.
        let isLanded: Bool
    }

    /// An added word's transform at `elapsed` seconds into the landing
    /// cascade, staggered by its order among the other added words. `nil`
    /// before its own window starts (the word isn't drawn or hidden yet).
    static func addedWordEntrance(elapsed: TimeInterval, order: Int, groupCount: Int) -> WordEntrance? {
        let staggerSpan = max(0.05, resolveDuration - addedWordDuration)
        let stagger = groupCount > 1 ? Double(order) / Double(groupCount - 1) : 0
        let start = stagger * staggerSpan
        let local = (elapsed - start) / addedWordDuration
        guard local > 0.001 else { return nil }
        let eased = easeOut(local)
        return WordEntrance(
            scale: 1.06 - 0.06 * eased,
            opacity: eased,
            blur: (1 - eased) * 0.9,
            isLanded: min(1, local) >= 0.6
        )
    }

    struct WordExit {
        let scale: Double
        let opacity: Double
    }

    /// A removed word's transform at `elapsed` seconds into the landing
    /// cascade, staggered by its order among the other removed words. Every
    /// removed word starts at its dimmed resting state (scale 0.9, opacity
    /// 0.5) the instant landing begins, then continues shrinking toward
    /// nothing starting at its own stagger offset — matching the sandbox,
    /// where the stagger delays the *continued* fade, not the initial dim.
    /// `nil` once fully faded.
    static func removedWordExit(elapsed: TimeInterval, order: Int, groupCount: Int) -> WordExit? {
        let stagger = groupCount > 1 ? Double(order) / Double(groupCount - 1) : 0
        let start = stagger * removedStaggerSpan
        let exitT = min(1, max(0, (elapsed - start) / removedWordDuration))
        guard exitT < 1 else { return nil }
        return WordExit(scale: 0.92 - 0.22 * exitT, opacity: 0.5 * (1 - exitT))
    }

    // MARK: Waiting scan ("as if parsing")

    static let scanCycle: TimeInterval = 5.6
    static let scanActiveFraction: Double = 0.32

    struct ScanPulse {
        let scale: Double
        let opacity: Double
        let blur: Double
    }

    /// A word's transform while it's the rotating scan's current target — a
    /// smooth bell-curve pulse (fades in, peaks, fades out) rather than a
    /// hard on/off, so hiding/showing the real glyph underneath never pops.
    /// `nil` outside its active window.
    static func scanPulse(elapsed: TimeInterval, wordIndex: Int) -> ScanPulse? {
        let phase = (elapsed / scanCycle + wordHash(wordIndex)).truncatingRemainder(dividingBy: 1)
        guard phase < scanActiveFraction else { return nil }
        let t = phase / scanActiveFraction
        let envelope = sin(t * .pi)
        let opacity = 0.65 * envelope
        guard opacity > 0.01 else { return nil }
        return ScanPulse(scale: 1 - 0.08 * envelope, opacity: opacity, blur: 1.1 * envelope)
    }

    /// Deterministic per-word phase offset so the scan reads as continuous,
    /// organic activity rather than a repeating sweep — a pure function of
    /// word index, no external RNG.
    static func wordHash(_ i: Int) -> Double {
        let v = sin(Double(i) * 127.1 + 91.7) * 43758.5453
        return v - floor(v)
    }
}
