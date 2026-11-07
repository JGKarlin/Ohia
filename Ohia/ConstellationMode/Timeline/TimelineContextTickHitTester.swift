import CoreGraphics
import Foundation

/// Per-frame hit-test index for faded context pips on the multitrack
/// canvas. Written during `drawContextTicks`, read on hover so the pip
/// under the pointer can brighten without re-running the draw filters.
@MainActor
final class TimelineContextTickHitTester {

    struct Key: Hashable {
        let messageID: UUID
        let row: TimelineMultitrackRow
    }

    private var rects: [Key: CGRect] = [:]

    func reset() {
        rects.removeAll(keepingCapacity: true)
    }

    func record(_ rect: CGRect, messageID: UUID, row: TimelineMultitrackRow) {
        rects[Key(messageID: messageID, row: row)] = rect
    }

    func hitTest(_ point: CGPoint) -> Key? {
        for (key, rect) in rects where rect.contains(point) {
            return key
        }
        return nil
    }
}
