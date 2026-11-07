import CoreGraphics
import Foundation

/// Mutable hit-test record for the multitrack canvas's chip overlay.
/// The Canvas draw closure can't trigger SwiftUI state updates without
/// risking a re-render loop, so the per-frame chip rects live on this
/// class — the canvas writes into it during each draw, and the tap
/// gesture reads from it on click to figure out which chip the user
/// tapped (if any).
///
/// Identity is `(row, value)` — the row defines the chip's semantic
/// space (sender / receiver / Purpose / etc.) and the value is a
/// row-specific identifier (sender email, recipient email, attachment
/// UUID, Purpose rawValue, …). The same identifier is the key in
/// `TimelineWorkspaceState.activeRowChips`, so a hit becomes a
/// `toggleRowChip(row:value:)` call without any translation.
@MainActor
final class TimelineChipHitTester {

    struct Key: Hashable {
        let row: TimelineMultitrackRow
        let value: String
    }

    private var rects: [Key: CGRect] = [:]

    /// Called at the start of each Canvas draw pass to discard the
    /// previous frame's rects — chip positions move with the playhead.
    func reset() {
        rects.removeAll(keepingCapacity: true)
    }

    /// Record a chip's painted rect so the gesture handler can hit-test
    /// against it. Repeated calls for the same key (e.g., the same
    /// stacked chip drawn in a new frame after a scroll) overwrite the
    /// previous rect.
    func record(_ rect: CGRect, for key: Key) {
        rects[key] = rect
    }

    /// Returns the (row, value) of the chip whose rect contains the
    /// click point, or nil if the click missed every chip. When two
    /// chips overlap (shouldn't happen in current layout but defensive
    /// against future stacked-chip changes), the first match wins;
    /// dictionary order is undefined but stable enough for hit testing.
    func hitTest(_ point: CGPoint) -> Key? {
        for (key, rect) in rects where rect.contains(point) {
            return key
        }
        return nil
    }
}
