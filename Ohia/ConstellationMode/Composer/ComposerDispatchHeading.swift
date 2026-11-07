import AppKit
import CoreGraphics

/// Resolves the direction a send-to-Composer comet should travel: from the
/// Constellation window's center toward the Composer window's center, in screen
/// coordinates, expressed as a **unit vector in view space** (y-down).
///
/// Cocoa screen frames are y-up (origin bottom-left); the comet is drawn in the
/// Constellation view's space (y-down), so the y component is negated.
///
/// The Composer window fronts *after* the comet plays, so `resolve` always aims at
/// its current-best position: the live Composer frame if it's already open, else a
/// last-known center from a previous send, else a fixed trailing fallback (where
/// the Composer/outbox conventionally sits). It never blocks or forces the window
/// open, so the comet always has an immediate, sensible heading.
enum ComposerDispatchHeading {
    private static let persistKeyX = "composerDispatchLastComposerCenterX"
    private static let persistKeyY = "composerDispatchLastComposerCenterY"

    /// Rightward fallback (unit) — the Composer's default side — used only before
    /// its position has ever been recorded.
    private static let rightwardFallback = CGVector(dx: 1, dy: 0)

    @MainActor
    static func resolve() -> CGVector {
        guard let constellation = SceneWindowRegistry.shared.window(for: OhiaWindowID.constellation),
              constellation.frame.width > 0, constellation.frame.height > 0 else {
            return rightwardFallback
        }
        let start = center(of: constellation.frame)
        guard let target = composerCenter() else { return rightwardFallback }
        return viewDirection(from: start, to: target)
    }

    /// The Composer window's center in screen coords: the live window's frame if
    /// it exists (even hidden — a hidden window keeps its last frame), else the
    /// center persisted the last time it was open. nil only before it has ever
    /// been positioned.
    @MainActor
    static func composerCenter() -> CGPoint? {
        if let composer = SceneWindowRegistry.shared.window(for: OhiaWindowID.composer),
           composer.frame.width > 0, composer.frame.height > 0 {
            let target = center(of: composer.frame)
            persist(target)
            return target
        }
        return persistedCenter()
    }

    /// Records the Composer's current center (called just after it fronts) so the
    /// next send aims at it even before it reopens, and across launches.
    @MainActor
    static func captureComposerCenter() {
        guard let composer = SceneWindowRegistry.shared.window(for: OhiaWindowID.composer),
              composer.frame.width > 0, composer.frame.height > 0 else { return }
        persist(center(of: composer.frame))
    }

    private static func persist(_ point: CGPoint) {
        UserDefaults.standard.set(Double(point.x), forKey: persistKeyX)
        UserDefaults.standard.set(Double(point.y), forKey: persistKeyY)
    }

    private static func persistedCenter() -> CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: persistKeyX) != nil,
              defaults.object(forKey: persistKeyY) != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: persistKeyX), y: defaults.double(forKey: persistKeyY))
    }

    private static func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Screen coords are y-up; view space is y-down. Flip y and normalize.
    private static func viewDirection(from a: CGPoint, to b: CGPoint) -> CGVector {
        let dx = b.x - a.x
        let dy = -(b.y - a.y)
        let length = max(0.0001, hypot(dx, dy))
        return CGVector(dx: dx / length, dy: dy / length)
    }
}
