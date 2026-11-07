// Ohia/Composer/ComposerDraftRevisionOverlay.swift
// The word-morph reconstitution effect that plays directly over the real
// draft body while a typed Revise instruction is being applied to an
// already-completed draft. Picked over three other sandboxed candidates
// (Decode Reveal, Unravel & Reweave, Ink Rewrite — see
// Ohia/Previews/ComposerRevisionAnimationSandbox.swift) as the calmest of
// the four. Regenerate and a style-register restyle both rewrite the whole
// body, so they keep the generic AdaptiveSummaryLoadingPlaceholderView
// dot-on-a-line loader instead — a word-level diff isn't meaningful when
// nearly everything changed. This overlay only mounts for the narrower
// `isAwaitingInstructionRevision` case (ComposerDraftStep.swift).
//
// Unlike the sandbox candidate, this can't just draw its own plain-text
// layout — the real draft is a rich NSTextView (arbitrary fonts, bold,
// inline photos). So it draws directly on the real text: for whichever
// words are currently animating, ComposerRichTextController.hideGlyphs
// temporarily blanks the real glyphs (a display-only NSLayoutManager
// attribute, never touching NSTextStorage) and this overlay draws an
// animated replica in their place — same text, same real font (via
// attributedRun), scaled/blurred/tinted per ComposerDraftRevisionTimingMath
// — so it reads as the text itself transforming, not a decoration layered
// on top. Every word MUST be unhidden the instant it stops animating (a
// tracked hidden-range set, reconciled every frame, plus unconditional
// cleanup on deactivation/disappear) or it would stay permanently invisible.
//
// Layout stays fixed the whole time this plays. ComposerDraftStep holds the
// real document at its pre-revision content — `resolvedContent` here is the
// *pending* new body, supplied once the model resolves but deliberately not
// yet applied to the live NSTextView — so nothing below the edit reflows
// mid-animation; the parent only swaps in the real content (a single clean
// cut, not animated) once `onLandingComplete` fires. That also means an
// added word has no real position of its own to hide/reveal, since it
// doesn't exist in the live text yet: its replica borrows the live position
// of the old-document word it's replacing (`Diff.addedAnchors`), so it reads
// as growing in "in place of" what's fading away rather than at some
// disconnected future location.
//
// While waiting: the model hasn't responded yet, so which words it will
// actually touch isn't knowable in advance. Rather than fake that
// knowledge, a rotating, deterministic subset of the real words pulses
// yellow — "as if parsing," purely decorative, never claiming to preview
// the edit. The moment the new body is resolved, a real word-level diff
// (ComposerTextRevisionWordDiff) runs between the (still live and
// unchanged) old text and the pending new text, and the landing cascade
// plays: words that left shrink and fade red at their live position; words
// that arrived scale/blur/fade in at their anchor's live position, yellow
// while still landing then green once settled, staggered word by word —
// cooling toward rest once the whole cascade finishes, at which point the
// real swap and the word-morph replicas hand off invisibly.

import AppKit
import SwiftUI

struct ComposerDraftRevisionOverlay: View {
    /// True while a typed Revise instruction is outstanding — drives the
    /// "as if parsing" waiting scan. Becomes false once the model resolves;
    /// see `currentPhase` for how this and `resolvedContent` combine into
    /// one lifecycle signal.
    let isActive: Bool
    /// The pending new body once the model has resolved it — still `nil`
    /// while waiting. The parent deliberately withholds applying this to
    /// the live text view until `onLandingComplete` fires, so this overlay
    /// receives it purely for diffing/measurement.
    let resolvedContent: NSAttributedString?
    let controller: ComposerRichTextController
    /// Called once the landing cascade finishes settling — the parent's
    /// signal to finally apply `resolvedContent` to the live text view.
    let onLandingComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct CachedWord {
        let range: NSRange
        let text: String
        let font: Font
    }

    private struct LandingWord {
        let range: NSRange
        let text: String
        let font: Font
        let order: Int
        let groupCount: Int
        /// Set only for added words — the old-document range whose live
        /// position stands in for this word's not-yet-real position. Unused
        /// for removed words, which already have a real live position.
        let anchorRange: NSRange?
        /// Set only for added words: this word's 0-based position among
        /// other added words sharing the exact same `anchorRange` (a
        /// multi-word insertion with no old word between them all anchor to
        /// the same spot). Used to fan them out horizontally instead of
        /// drawing them fully stacked on top of each other.
        let anchorGroupIndex: Int
    }

    @State private var beforeWordCache: [CachedWord] = []
    @State private var activatedAt: Date?
    @State private var resolvedAt: Date?
    @State private var removedWords: [LandingWord] = []
    @State private var addedWords: [LandingWord] = []
    @State private var isRunning = false
    /// Ranges whose real glyphs are currently blanked so this overlay can
    /// draw their animated replica. Reconciled every frame against whatever
    /// should be hidden right now — the single source of truth preventing a
    /// word from being left permanently invisible. Backed by a plain
    /// reference type, not `@State` directly: `reconcileHidden` is called
    /// from inside the `Canvas` render closure, and writing `@State`
    /// synchronously during a view's own render pass is the "modifying
    /// state during view update" anti-pattern (SwiftUI can coalesce/drop
    /// such writes) — the same hazard the `CameraController` retention note
    /// elsewhere in this codebase works around. A plain box mutated
    /// in-place never touches SwiftUI's invalidation machinery.
    @State private var hiddenTracker = HiddenRangeTracker()

    private final class HiddenRangeTracker {
        var ranges: Set<NSRange> = []
    }

    private static let fallbackFont = Font.system(size: ComposerRichTextController.defaultFontSize)
    private static let settleDuration = ComposerDraftRevisionTimingMath.resolveDuration + 0.15
    /// The underline-under-added-words highlight fades out over roughly the
    /// first 80% of the cascade, matching how long the entrance animation
    /// itself takes to finish staggering in the last word.
    private static let underlineFadeDuration = ComposerDraftRevisionTimingMath.resolveDuration * 0.81

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isRunning)) { timeline in
            Canvas { ctx, _ in
                draw(&ctx, now: timeline.date)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: currentPhase, initial: true) { _, phase in
            handlePhaseChange(phase)
        }
        .onDisappear { unhideAll() }
    }

    // MARK: Lifecycle

    /// `isActive` and `resolvedContent` change together (the parent sets
    /// both from the same session update), so they're collapsed into one
    /// derived value tracked by a single `onChange` — two independent
    /// `onChange`s on the same two properties would depend on which fires
    /// first, and that ordering isn't something SwiftUI documents or
    /// guarantees. `resolvedContent` takes priority: its presence alone
    /// means the model has resolved, regardless of what `isActive` says at
    /// that instant.
    private enum Phase: Equatable { case idle, scanning, landing }

    private var currentPhase: Phase {
        if resolvedContent != nil { return .landing }
        return isActive ? .scanning : .idle
    }

    private func handlePhaseChange(_ phase: Phase) {
        switch phase {
        case .scanning:
            unhideAll()
            // Read from the live text view's raw string, not
            // `plainEditorText` — that projection strips inline-photo
            // placeholder characters, which would desync every offset after
            // a photo from the positions `documentGlyphRects` (indexing the
            // real, unstripped text storage) actually returns.
            let text = controller.rawText
            beforeWordCache = ComposerTextRevisionWordDiff.wordRanges(in: text).map { range in
                let run = controller.attributedRun(forCharacterRange: range)
                return CachedWord(range: range, text: run?.text ?? "", font: run?.font ?? Self.fallbackFont)
            }
            activatedAt = Date()
            resolvedAt = nil
            removedWords = []
            addedWords = []
            isRunning = true
        case .landing:
            if let resolvedContent { beginLanding(with: resolvedContent) }
        case .idle:
            guard resolvedAt == nil else { return }
            // Either nothing has happened yet (initial mount) or scanning
            // stopped without a resolution ever arriving (e.g. the draft
            // was discarded mid-wait) — nothing to animate, just reset.
            unhideAll()
            isRunning = false
            activatedAt = nil
            beforeWordCache = []
        }
    }

    private func beginLanding(with content: NSAttributedString) {
        guard resolvedAt == nil else { return }
        // SwiftUI may reconstruct this overlay after the model has already
        // resolved. That new instance never saw the scanning phase, so it
        // has no old-document word cache to animate. Treat that as a direct
        // handoff instead of silently leaving the parent's old draft frozen
        // forever waiting for a completion callback that cannot otherwise
        // be produced.
        guard activatedAt != nil else {
            finishLanding()
            return
        }
        let after = content.string
        let completion = Date()
        resolvedAt = completion

        // The old text is still the live text — the parent hasn't applied
        // `content` to the real view yet — so this diffs against the real,
        // unchanged document, not a snapshot.
        let diff = ComposerTextRevisionWordDiff.diff(old: controller.rawText, new: after)
        removedWords = diff.removed.enumerated().compactMap { order, range in
            guard let cached = beforeWordCache.first(where: { $0.range == range }) else { return nil }
            return LandingWord(
                range: range, text: cached.text, font: cached.font,
                order: order, groupCount: diff.removed.count, anchorRange: nil, anchorGroupIndex: 0
            )
        }
        // Consecutive added words with no old word between them (a
        // multi-word insertion) all get the same anchor from the diff —
        // track how many words already claimed each anchor so they can fan
        // out horizontally instead of drawing fully stacked.
        var anchorGroupCounts: [NSRange: Int] = [:]
        addedWords = diff.added.enumerated().map { order, range in
            let run = ComposerRichTextController.attributedRun(forCharacterRange: range, in: content)
            let anchor = diff.addedAnchors[order]
            var groupIndex = 0
            if let anchor {
                groupIndex = anchorGroupCounts[anchor, default: 0]
                anchorGroupCounts[anchor] = groupIndex + 1
            }
            return LandingWord(
                range: range, text: run?.text ?? "", font: run?.font ?? Self.fallbackFont,
                order: order, groupCount: diff.added.count, anchorRange: anchor, anchorGroupIndex: groupIndex
            )
        }

        // Nothing to actually show (a no-op instruction, or an added word
        // with nowhere to anchor because the old body had no words at all)
        // — finish immediately rather than holding the frozen, visually
        // static editor through a full silent cascade.
        guard !removedWords.isEmpty || addedWords.contains(where: { $0.anchorRange != nil }) else {
            finishLanding()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration) {
            guard resolvedAt == completion else { return }
            finishLanding()
        }
    }

    /// Cleanup once the landing cascade finishes settling. Tells the parent
    /// it's safe to apply the real new content now — every replica has
    /// already cooled to its resting look, so the handoff reads as
    /// invisible rather than a jump.
    private func finishLanding() {
        unhideAll()
        isRunning = false
        activatedAt = nil
        resolvedAt = nil
        beforeWordCache = []
        removedWords = []
        addedWords = []
        onLandingComplete()
    }

    // MARK: Draw

    private func draw(_ ctx: inout GraphicsContext, now: Date) {
        guard let activatedAt else { return }
        if let resolvedAt {
            drawLanding(&ctx, elapsed: now.timeIntervalSince(resolvedAt))
        } else {
            drawScanning(&ctx, elapsed: now.timeIntervalSince(activatedAt))
        }
    }

    private func drawScanning(_ ctx: inout GraphicsContext, elapsed: TimeInterval) {
        guard !beforeWordCache.isEmpty else { return }
        var currentlyHidden: Set<NSRange> = []
        if !reduceMotion {
            let origin = controller.visibleOrigin
            for (index, entry) in beforeWordCache.enumerated() {
                guard let pulse = ComposerDraftRevisionTimingMath.scanPulse(elapsed: elapsed, wordIndex: index) else { continue }
                let rects = controller.documentGlyphRects(forCharacterRange: entry.range)
                guard !rects.isEmpty else { continue }
                currentlyHidden.insert(entry.range)
                for rect in rects {
                    drawWord(
                        &ctx, text: entry.text, font: entry.font, rect: rect, origin: origin,
                        scale: pulse.scale, opacity: pulse.opacity, blur: pulse.blur, color: OhiaColors.ohiaYellow
                    )
                }
                drawUnderline(&ctx, rects: rects, origin: origin, opacity: pulse.opacity * 0.6, color: OhiaColors.ohiaYellow)
            }
        }
        reconcileHidden(currentlyHidden)
    }

    private func drawLanding(_ ctx: inout GraphicsContext, elapsed: TimeInterval) {
        let origin = controller.visibleOrigin

        // Removed words stay hidden for the entire cascade, not just while
        // their own exit is still fading — once a word is gone it must not
        // pop back to its real glyph mid-animation just because its own
        // exit finished before the others.
        reconcileHidden(Set(removedWords.map(\.range)))

        for word in removedWords {
            guard let exit = ComposerDraftRevisionTimingMath.removedWordExit(elapsed: elapsed, order: word.order, groupCount: word.groupCount)
            else { continue }
            for rect in controller.documentGlyphRects(forCharacterRange: word.range) {
                drawWord(
                    &ctx, text: word.text, font: word.font, rect: rect, origin: origin,
                    scale: reduceMotion ? 1 : exit.scale, opacity: exit.opacity, blur: 0, color: OhiaColors.ohiaRed
                )
            }
        }

        for word in addedWords {
            guard let entrance = ComposerDraftRevisionTimingMath.addedWordEntrance(elapsed: elapsed, order: word.order, groupCount: word.groupCount)
            else { continue }
            let color = entrance.isLanded ? OhiaColors.ohiaGreen : OhiaColors.ohiaYellow
            for rect in nudgedAnchorRects(for: word) {
                drawWord(
                    &ctx, text: word.text, font: word.font, rect: rect, origin: origin,
                    scale: reduceMotion ? 1 : entrance.scale, opacity: entrance.opacity,
                    blur: reduceMotion ? 0 : entrance.blur, color: color
                )
            }
        }

        let underlineOpacity = max(0, 0.55 * (1 - elapsed / Self.underlineFadeDuration))
        if underlineOpacity > 0.01 {
            for word in addedWords {
                drawUnderline(&ctx, rects: nudgedAnchorRects(for: word), origin: origin, opacity: underlineOpacity, color: OhiaColors.ohiaGreen)
            }
        }
    }

    /// An added word's anchor rects, fanned out horizontally by
    /// `anchorGroupIndex` when other added words share the same anchor
    /// (a multi-word insertion) — otherwise they'd draw fully stacked on
    /// top of each other. The nudge distance is approximate (the anchor's
    /// own rendered width standing in for a word-width unit, since these
    /// are ephemeral ghost replicas, not a real layout pass), but reads as
    /// words arriving in a row rather than on top of one another.
    private func nudgedAnchorRects(for word: LandingWord) -> [CGRect] {
        guard let anchorRange = word.anchorRange else { return [] }
        let rects = controller.documentGlyphRects(forCharacterRange: anchorRange)
        guard word.anchorGroupIndex > 0, let first = rects.first else { return rects }
        let dx = first.width * CGFloat(word.anchorGroupIndex)
        return rects.map { $0.offsetBy(dx: dx, dy: 0) }
    }

    // MARK: Real-glyph hide/unhide bookkeeping

    private func reconcileHidden(_ desired: Set<NSRange>) {
        let current = hiddenTracker.ranges
        guard desired != current else { return }
        for range in current.subtracting(desired) { controller.unhideGlyphs(in: range) }
        for range in desired.subtracting(current) { controller.hideGlyphs(in: range) }
        hiddenTracker.ranges = desired
    }

    private func unhideAll() {
        for range in hiddenTracker.ranges { controller.unhideGlyphs(in: range) }
        hiddenTracker.ranges = []
    }

    // MARK: Drawing primitives

    private func drawWord(
        _ ctx: inout GraphicsContext, text: String, font: Font, rect: CGRect, origin: CGPoint,
        scale: Double, opacity: Double, blur: Double, color: Color
    ) {
        guard opacity > 0.01, !text.isEmpty else { return }
        let center = CGPoint(x: rect.midX - origin.x, y: rect.midY - origin.y)
        let content = Text(text).font(font).foregroundStyle(color)
        ctx.drawLayer { layer in
            if blur > 0.02 { layer.addFilter(.blur(radius: blur)) }
            layer.opacity = opacity
            layer.translateBy(x: center.x, y: center.y)
            if abs(scale - 1) > 0.001 { layer.scaleBy(x: scale, y: scale) }
            layer.draw(content, at: .zero, anchor: .center)
        }
    }

    private func drawUnderline(_ ctx: inout GraphicsContext, rects: [CGRect], origin: CGPoint, opacity: Double, color: Color) {
        guard opacity > 0.01 else { return }
        for rect in rects {
            let local = rect.offsetBy(dx: -origin.x, dy: -origin.y)
            let underline = CGRect(x: local.minX, y: local.maxY - 1, width: local.width, height: 1.5)
            ctx.fill(Path(roundedRect: underline, cornerRadius: 0.75), with: .color(color.opacity(opacity)))
        }
    }
}
