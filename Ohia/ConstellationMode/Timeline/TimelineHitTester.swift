import Foundation
import CoreGraphics
import OhiaCore

/// Resolves a `(point)` in multitrack-area coordinates to a
/// `TimelineHitTarget`. The new row-based multitrack ignores y for the
/// hit test — every row shares the same time axis, so a click anywhere
/// in the multitrack means "scrub to the nearest message at this x".
/// Only `.event` and `.empty` are emitted; legacy cases remain on the
/// enum for call-site stability.
struct TimelineHitTester {
    let snapshot: TimelineLayoutSnapshot
    let projector: TimelineProjector

    func hit(at point: CGPoint) -> TimelineHitTarget {
        let date = projector.date(forX: point.x)
        // Snap to the nearest event within a small slop window. The
        // threshold derives from 12px (touch slop) at the current zoom,
        // hard-capped at 6 hours so that a year-plus zoom doesn't snap
        // across a 240-day window and pick a message far from the click.
        let pxThreshold: CGFloat = 12
        let pxBasedSeconds = TimeInterval(pxThreshold / max(0.01, projector.viewportPixelsPerDay)) * TimelineProjector.secondsPerDay
        let timeThreshold = min(6 * 3600, pxBasedSeconds)
        let lower = date.addingTimeInterval(-timeThreshold)
        let upper = date.addingTimeInterval(timeThreshold)
        let candidate = snapshot.events
            .filter { $0.date >= lower && $0.date <= upper }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        if let event = candidate {
            return .event(messageID: event.messageID, date: event.date)
        }
        return .empty
    }
}
