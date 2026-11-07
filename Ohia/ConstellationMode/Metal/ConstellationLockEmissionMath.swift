import Foundation
import OhiaCore

enum ConstellationLockEmissionMath {
    static func multiplier(lockFocus: Float, fieldDimFactor: Float) -> Float {
        let focus = max(0, min(1, lockFocus))
        return fieldDimFactor + (1 - fieldDimFactor) * focus
    }
}

/// Resolves the global `fieldDimFactor` published into the renderer for
/// each frame based on lock state and active spatial lens. Pulled out of
/// the `ConstellationRenderRequest` call site so the dim policy stays
/// reviewable in one place and so the People-focus isolation step
/// (clicked Saturn → deep dim of everything else) has a single source of
/// truth.
enum ConstellationLockDimFactor {
    /// 1.0 — no dim. Used when no lock is open or when the user disabled
    /// lock-overlay dim in settings.
    static let none: Float = 1.0
    /// Deep-but-legible dim used during a Meanings lock. The locked scene
    /// keeps the full surrounding field (no star removal — see
    /// `renderBudgetForCurrentState`), so this factor alone carries the
    /// isolation: the anchor holds 1.0, graded neighbours interpolate
    /// between this floor and full emission by semantic distance, and the
    /// unrelated field recedes here — present for sense-of-place, quiet
    /// enough that the neighbourhood unambiguously owns the scene.
    static let meaningsLock: Float = 0.32
    /// Deep dim used in the People-focus overlay so the focal Saturn
    /// reads as an isolated portrait while the rest of the people
    /// population stays faintly visible for sense-of-place. Matches the
    /// user-facing spec: "deeply dimmed but other planets faintly
    /// visible."
    static let peopleFocus: Float = 0.18

    static func resolve(
        lockedVectorId: Int64?,
        dimEnabled: Bool,
        spatialLens: FrameKey,
        hasPersonFocus: Bool = false
    ) -> Float {
        guard lockedVectorId != nil, dimEnabled else { return none }
        if spatialLens == .people {
            // When a Saturn is locked, the renderer's `PeopleFrameFocus`
            // already narrows the scene to that one correspondent's hub
            // + rings — the rest of the People galaxy is filtered out at
            // build time. A field dim would only darken the focused
            // Saturn itself (the planet body and its ring bands aren't
            // the `lock.x = 1` vertex), which is exactly what we want
            // to keep bright. So in this mode the dim is off, and the
            // visual isolation comes from the filter, not the dim.
            if hasPersonFocus {
                return none
            }
            return peopleFocus
        }
        return meaningsLock
    }
}
