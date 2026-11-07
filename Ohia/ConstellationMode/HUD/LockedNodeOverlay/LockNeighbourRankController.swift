import Foundation
import SwiftUI

/// Drives the "step through neighbours by affinity" mode for the locked-node
/// overlay. Owned by `ConstellationModeView` (so the outer key handler can
/// trigger steps) and observed by `LockedNodeOverlay` (which warps the camera
/// to the focused neighbour and opens its popup).
///
/// Source of truth for `currentIndex`. `rankedCount` is published by the
/// overlay each time the locked-node context loads, so step bounds always
/// reflect the loaded neighbour set, not a stale snapshot.
@MainActor
@Observable
final class LockNeighbourRankController {
    /// Index into the lock overlay's affinity-sorted neighbour array.
    /// `nil` means rank-step is not active and the leader / popup
    /// behaviour should fall back to the default.
    private(set) var currentIndex: Int?

    /// Number of ranked neighbours available. Updated by the overlay
    /// whenever the lock context loads. `step(by:)` is a no-op when this
    /// is zero.
    private(set) var rankedCount: Int = 0

    /// Bumped each time `step(by:)` lands on a neighbour, including when
    /// the index doesn't change (e.g. user presses `n` again on the only
    /// neighbour). The overlay observes this counter so it can re-warp /
    /// re-open even if the index value is unchanged from a single-element
    /// loop or a wrap-around back to the same rank.
    private(set) var stepTick: UInt64 = 0

    /// Bumped whenever the user requests "expand the focused rank's
    /// summary" via the space key, or its message text via Shift-Space.
    /// The overlay observes this counter and flips the focused popup's
    /// expanded state — same effect as clicking the popup's chevron, but
    /// keyboard-driven so the user never has to move their hand from
    /// `n`/`p` while skimming related emails.
    private(set) var expansionToggleTick: UInt64 = 0
    private(set) var expansionContentMode: AnnotationExpandedContentMode = .summary

    /// Bumped each time the user requests a chronological step (Option+Tab
    /// / Option+Shift+Tab) in the People-focus overlay. The overlay owns
    /// the chronological ↔ bucketed index mapping (only it knows the
    /// `AnnotationItem` ordering), so the controller just records the
    /// direction and lets the overlay resolve and route to `setIndex`.
    /// `+1` = oldest → newer (forward in time), `-1` = newer → oldest.
    private(set) var chronologicalStepTick: UInt64 = 0
    private(set) var chronologicalStepDirection: Int = 0

    /// Ask the overlay to perform a chronological step. The overlay
    /// observes `chronologicalStepTick`; the actual index update happens
    /// inside its handler.
    func requestChronologicalStep(direction: Int) {
        guard direction != 0 else { return }
        chronologicalStepDirection = direction
        chronologicalStepTick &+= 1
    }

    /// Reset rank state. Called by the overlay when the locked vector
    /// changes or the loaded neighbour set is rebuilt.
    ///
    /// `preselectIndex` lets the caller seed `currentIndex` so the chip
    /// strip opens with a pane already highlighted — used at lock-entry
    /// time so the locked email's main-email chip reads as selected the
    /// moment the overlay appears, instead of requiring a Tab press first
    /// to enter rank-step mode. Setting it here intentionally does NOT
    /// bump `stepTick`: lock entry has
    /// already centered the camera on the locked node and opened no
    /// annotation pane, so we don't want the rank-focus reaction to fire
    /// a redundant warp + close cascade.
    func reset(rankedCount: Int, preselectIndex: Int? = nil) {
        self.rankedCount = rankedCount
        let resolved: Int? = {
            guard let preselectIndex,
                  preselectIndex >= 0,
                  preselectIndex < rankedCount else {
                return nil
            }
            return preselectIndex
        }()
        if currentIndex != resolved {
            currentIndex = resolved
        }
    }

    /// Advance / regress the focused rank by `delta`. Wraps modulo
    /// `rankedCount`. First step from a `nil` state lands on rank 0
    /// (highest similarity) for `delta > 0`, or the lowest-similarity
    /// neighbour for `delta < 0`.
    @discardableResult
    func step(by delta: Int) -> Int? {
        guard rankedCount > 0, delta != 0 else { return currentIndex }
        let next: Int
        if let current = currentIndex {
            // Modulo on signed Ints needs the +N+%N pattern to handle negatives.
            next = ((current + delta) % rankedCount + rankedCount) % rankedCount
        } else {
            next = delta > 0 ? 0 : rankedCount - 1
        }
        currentIndex = next
        stepTick &+= 1
        return next
    }

    /// Jump directly to a specific rank index. Used by the kind-chip strip
    /// when the user clicks a target instead of stepping with Tab. No-op
    /// when `index` is out of range for the current `rankedCount`.
    @discardableResult
    func setIndex(_ index: Int) -> Int? {
        guard rankedCount > 0, index >= 0, index < rankedCount else {
            return currentIndex
        }
        currentIndex = index
        stepTick &+= 1
        return index
    }

    /// Move the focus cursor to `index` WITHOUT bumping `stepTick`.
    ///
    /// Used when a pointer click on a ring satellite (People focus) already
    /// drives its own selection chrome — the highlight ring, the pinned dial
    /// card, the edge action column — and the camera is intentionally held
    /// still ("click selects, no camera move"). Syncing the rank cursor here
    /// keeps the chip strip highlight and the Tab origin in agreement with the
    /// click, but because `stepTick` is left untouched, the overlay's
    /// `.onChange(of: stepTick)` warp/auto-open orchestration does NOT fire.
    /// A subsequent `step(by:)` then advances relative to the clicked node.
    ///
    /// No-op when `index` is out of range for the current `rankedCount`, or
    /// when the cursor is already at `index` (so a redundant re-click doesn't
    /// perturb `@Observable` tracking).
    func silentlyFocus(index: Int) {
        guard rankedCount > 0, index >= 0, index < rankedCount else { return }
        if currentIndex != index {
            currentIndex = index
        }
    }

    /// Exit rank-step mode. Returns `true` if there was an active step
    /// to exit (so the caller can decide whether to also fall through
    /// to the next default behaviour, e.g. releasing the lock on Esc).
    @discardableResult
    func exit() -> Bool {
        guard currentIndex != nil else { return false }
        currentIndex = nil
        return true
    }

    /// Request a chevron toggle on the focused rank's popup. No-op when
    /// rank-step is idle so a stray space-press outside of Tab / Shift+Tab
    /// navigation doesn't fire phantom toggles. Returns `true` when the
    /// request was dispatched so the caller can claim the keystroke.
    @discardableResult
    func requestExpansionToggle(mode: AnnotationExpandedContentMode = .summary) -> Bool {
        guard currentIndex != nil else { return false }
        expansionContentMode = mode
        expansionToggleTick &+= 1
        return true
    }

    /// `true` while a neighbour is rank-focused.
    var isActive: Bool { currentIndex != nil }
}
