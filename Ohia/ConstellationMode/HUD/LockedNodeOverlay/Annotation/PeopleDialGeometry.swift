import CoreGraphics
import Foundation

/// Pure geometry helpers backing the People-lens dial wedge. Extracted
/// from `LockedNodeOverlay` so each function can be unit-tested without
/// instantiating a SwiftUI view, a `LockedNodeContext`, or a Metal scene.
///
/// Every function in this namespace is `nonisolated` and side-effect-free.
enum PeopleDialGeometry {
    /// Shortest signed angular delta in (-π, π] that takes `from` to `to`.
    /// Used by the dial's phase-2 sweep so it always travels the natural
    /// direction (no >π detours). `to - from` truncated into 2π, then
    /// pulled into (-π, π] by adding or subtracting one full turn.
    static func shortestArcDelta(from: CGFloat, to: CGFloat) -> CGFloat {
        let delta = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { return delta - 2 * .pi }
        if delta <= -.pi { return delta + 2 * .pi }
        return delta
    }

    /// Angle (radians, SwiftUI y-down convention) and screen-space
    /// distance from `hub` to `point`. Used by the dial's anchor
    /// resolution so the wedge tracks the focused satellite's live
    /// position. Returns a strictly positive `rx` (clamped to 1) so
    /// downstream arithmetic — including `cos(angle) * rx` reverse
    /// projection — never divides by zero when the hub and point
    /// coincide (e.g., the focal satellite at lock entry).
    static func polarCoords(
        of point: CGPoint,
        relativeTo hub: CGPoint
    ) -> (angle: CGFloat, rx: CGFloat) {
        let dx = point.x - hub.x
        let dy = point.y - hub.y
        let rx = max(1, hypot(dx, dy))
        let angle = atan2(dy, dx)
        return (angle, rx)
    }

    /// Screen-space radius of the wedge's inner arc — sits just outside
    /// the outermost satellite at the current camera pose. Takes the max
    /// distance from `hub` to any anchor, then adds `inset`. Falls back to
    /// `fallback` (default 220pt) when `satelliteAnchors` is empty so the
    /// caller can still render something during the brief window between
    /// lock entry and the first projected annotation pass.
    static func dialInnerRadius(
        hub: CGPoint,
        satelliteAnchors: [CGPoint],
        inset: CGFloat,
        fallback: CGFloat = 220
    ) -> CGFloat {
        let radii = satelliteAnchors.map { hypot($0.x - hub.x, $0.y - hub.y) }
        let outer = radii.max() ?? fallback
        return outer + inset
    }

    /// Canonicalize an angle to (-π, π]. Used after each dial transition
    /// settles so the committed @State value doesn't accumulate 2π drift
    /// over many transitions — cos/sin are 2π-periodic, so the visual
    /// position is invariant.
    static func canonicalAngle(_ angle: CGFloat) -> CGFloat {
        let twoPi = CGFloat.pi * 2
        var normalized = angle.truncatingRemainder(dividingBy: twoPi)
        if normalized > .pi { normalized -= twoPi }
        if normalized <= -.pi { normalized += twoPi }
        return normalized
    }

    /// Sinusoidal ease-in-out curve (`0.5 - 0.5 * cos(π * t)`). Used as a
    /// close approximation of SwiftUI's `.easeInOut` curve when
    /// estimating the visual angle of a phase-2 dial sweep that's been
    /// superseded mid-flight. SwiftUI's exact timing curve is private,
    /// but cosine ease-in-out tracks it within ~3% across the full unit
    /// interval — well within the accuracy needed to pick the
    /// shortest-arc sweep direction for the superseding transition.
    /// Inputs are clamped to [0, 1] so out-of-range elapsed times
    /// (clock skew, paused tabs) still produce a sane result.
    static func easeInOut(_ t: Double) -> Double {
        let clamped = max(0, min(1, t))
        return 0.5 - 0.5 * cos(.pi * clamped)
    }

    /// Eased linear interpolation between two angles. Used to estimate
    /// the visual angle of an in-flight phase-2 sweep so a superseding
    /// transition can compute its shortest-arc delta from the actual
    /// visual position rather than the committed end-of-animation
    /// `dialAnchorAngle` (which the previous `withAnimation` already
    /// jumped to but the render thread hasn't reached). Returns
    /// `targetAngle` for non-positive durations and clamps `elapsed` to
    /// `[0, duration]`.
    static func interpolatedAngle(
        from startAngle: CGFloat,
        to targetAngle: CGFloat,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> CGFloat {
        guard duration > 0 else { return targetAngle }
        let t = max(0, min(1, elapsed / duration))
        let eased = easeInOut(t)
        return startAngle + (targetAngle - startAngle) * CGFloat(eased)
    }

    /// Returns true when the active dial item is the explicitly selected
    /// satellite. Selection is a pinned affordance (keyboard Tab / click),
    /// so the overlay uses it to drive leader collapse/grow choreography
    /// while the pane still takes the normal orbital travel path.
    static func isSelectedDialActive(activeID: String?, selectedID: String?) -> Bool {
        guard let activeID, let selectedID else { return false }
        return activeID == selectedID
    }

    /// Polar coords of the satellite matching `itemID` in `anchors`,
    /// relative to `hub`. Returns `nil` when no anchor carries that id —
    /// the caller dismisses the wedge in that case. Pure helper extracted
    /// so the resolution can be unit-tested without instantiating a
    /// `LockedNodeOverlay` (the production wrapper in the overlay reads
    /// from `cameraController.state` and `lockedWorldResolution`, which
    /// are view-coupled).
    static func satellitePolar(
        itemID: String,
        in anchors: [(id: String, anchor: CGPoint)],
        hub: CGPoint
    ) -> (angle: CGFloat, rx: CGFloat)? {
        guard let anchor = anchors.first(where: { $0.id == itemID })?.anchor else {
            return nil
        }
        return polarCoords(of: anchor, relativeTo: hub)
    }

    /// Number of evenly-spaced 3D samples taken on the outermost ring
    /// before projecting to screen. 64 is enough to keep the maximum
    /// chord-to-arc error well below a pixel at the typical Saturn
    /// portrait camera distance (the ring projects to ~400pt of screen,
    /// so each segment is ~6° → chord error < 0.5pt) while keeping the
    /// per-frame projection cost trivial.
    static let ringPolylineSampleCount: Int = 64

    /// Linearly interpolates the polyline's screen point at `angle`
    /// (radians from `hub`, SwiftUI y-down convention). The polyline is
    /// expected to be a closed, parametrically-ordered loop around
    /// `hub` (e.g., the outermost ring sampled in 3D and projected to
    /// screen by `LockedNodeOverlay.peopleRingPolyline()`). Each vertex
    /// contributes its (angle, screen point) tuple; the function finds
    /// the consecutive pair whose angles bracket `angle` and
    /// interpolates linearly in screen space.
    ///
    /// Returns `nil` when:
    ///   - The polyline has fewer than 3 vertices (under-sampled — the
    ///     caller must fall back to a circular arc),
    ///   - The vertex angles collapse to a single point (degenerate
    ///     projection — same fallback applies).
    ///
    /// The angle search is O(n) which is fine for n ≈ 64; if the
    /// sample count grows, a sorted binary search keyed by canonical
    /// angle would drop this to O(log n).
    static func interpolatePolylinePoint(
        atAngle angle: CGFloat,
        polyline: [CGPoint],
        hub: CGPoint
    ) -> CGPoint? {
        guard polyline.count >= 3 else { return nil }
        let target = canonicalAngle(angle)
        // Pre-compute polar coords for every vertex so the bracket
        // search and the interpolation both work in the same space.
        let polar: [(angle: CGFloat, point: CGPoint)] = polyline.map {
            let coords = polarCoords(of: $0, relativeTo: hub)
            return (canonicalAngle(coords.angle), $0)
        }
        // Find the segment whose `shortestArcDelta(from: a, to: target)`
        // and `shortestArcDelta(from: target, to: b)` are both
        // non-negative — i.e., the target sits inside the directed
        // angular interval from `a` to `b` along the shortest path.
        let count = polar.count
        for i in 0..<count {
            let a = polar[i]
            let b = polar[(i + 1) % count]
            let abDelta = shortestArcDelta(from: a.angle, to: b.angle)
            // Pick the shorter signed direction from a → b; the
            // bracket test is then whether `target` falls on the
            // same side of `a` as `b` and not past `b`.
            let atDelta = shortestArcDelta(from: a.angle, to: target)
            let inOrder = (abDelta >= 0 && atDelta >= 0 && atDelta <= abDelta) ||
                          (abDelta <= 0 && atDelta <= 0 && atDelta >= abDelta)
            if inOrder {
                let t: CGFloat = abs(abDelta) < 1e-6 ? 0 : atDelta / abDelta
                return CGPoint(
                    x: a.point.x + (b.point.x - a.point.x) * t,
                    y: a.point.y + (b.point.y - a.point.y) * t
                )
            }
        }
        // Fallback: pick the vertex whose angle is closest to `target`.
        // This handles degenerate orderings (e.g., a tiny perspective
        // glitch that puts two adjacent vertices on the same side of
        // `target`) without dropping the wedge entirely.
        var bestIndex = 0
        var bestAbsDelta: CGFloat = .infinity
        for i in 0..<count {
            let absDelta = abs(shortestArcDelta(from: polar[i].angle, to: target))
            if absDelta < bestAbsDelta {
                bestAbsDelta = absDelta
                bestIndex = i
            }
        }
        return polar[bestIndex].point
    }

    /// Maximum screen-space distance from `hub` to any polyline vertex.
    /// Used by the dial wedge to pick a card-centre distance that
    /// guarantees the card stays outside the projected ring regardless
    /// of which point on the polyline the spoke lands on. Returns 0
    /// when the polyline is empty so the caller falls back to its
    /// circular dial-inner-radius math.
    static func polylineMaxRadius(
        polyline: [CGPoint],
        hub: CGPoint
    ) -> CGFloat {
        polyline.map { hypot($0.x - hub.x, $0.y - hub.y) }.max() ?? 0
    }

    /// First point where a ray from `origin` at `angle` enters `rect`.
    /// Used by `PeopleDialWedge` to extend its radial leader from the
    /// ring-edge arc to the popup's near edge without drawing under the
    /// popup itself. `minimumDistance` lets the caller require that the
    /// rectangle edge sits beyond another radial landmark (the ring edge,
    /// for example) so cramped/clamped layouts do not draw the extension
    /// inward. Returns `nil` when the ray misses the rectangle.
    static func radialRectEdgePoint(
        origin: CGPoint,
        angle: CGFloat,
        rect: CGRect,
        minimumDistance: CGFloat = 0
    ) -> CGPoint? {
        guard !rect.isNull, !rect.isEmpty else { return nil }
        let dx = cos(angle)
        let dy = sin(angle)
        let epsilon: CGFloat = 1e-6
        guard abs(dx) > epsilon || abs(dy) > epsilon else { return nil }

        var candidates: [(distance: CGFloat, point: CGPoint)] = []

        if abs(dx) > epsilon {
            for x in [rect.minX, rect.maxX] {
                let t = (x - origin.x) / dx
                guard t >= 0 else { continue }
                let y = origin.y + t * dy
                if y >= rect.minY - epsilon, y <= rect.maxY + epsilon {
                    candidates.append((t, CGPoint(x: x, y: y)))
                }
            }
        }

        if abs(dy) > epsilon {
            for y in [rect.minY, rect.maxY] {
                let t = (y - origin.y) / dy
                guard t >= 0 else { continue }
                let x = origin.x + t * dx
                if x >= rect.minX - epsilon, x <= rect.maxX + epsilon {
                    candidates.append((t, CGPoint(x: x, y: y)))
                }
            }
        }

        guard let nearest = candidates
            .filter({ $0.distance >= 0 })
            .min(by: { $0.distance < $1.distance }),
            nearest.distance >= max(0, minimumDistance) else {
            return nil
        }
        return nearest.point
    }
}
