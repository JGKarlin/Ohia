import Foundation
import CoreGraphics
import OhiaCore

/// Pure value type that maps `Date ↔ CGFloat (x)` and
/// `TimelineMultitrackRow ↔ CGFloat (y)` for the multitrack area. Shared by
/// the Canvas draw pass, hit testing, and gesture handlers so every layer
/// agrees on coordinates.
///
/// `viewportRange` is the visible window in clock time; `viewportPixelsPerDay`
/// is the current zoom. Lanes are addressed by an externally-supplied
/// ordered `TimelineMultitrackRow` array (per-snapshot, stable for the
/// snapshot's lifetime) so projector instances stay cheap to copy.
public struct TimelineProjector: Sendable, Equatable {
    public let viewportRange: ClosedRange<Date>
    public let viewportPixelsPerDay: Double
    public let originX: CGFloat
    public let laneOrder: [TimelineMultitrackRow]
    public let laneHeight: CGFloat
    public let laneTopY: CGFloat

    /// Day-aligned seconds-per-pixel constant. The projector treats one day
    /// as 86_400 seconds — drift across DST boundaries is acceptable for a
    /// visual axis (it never feeds the pipeline date filter, which uses
    /// real timestamps).
    public static let secondsPerDay: TimeInterval = 86_400

    public init(
        viewportRange: ClosedRange<Date>,
        viewportPixelsPerDay: Double,
        originX: CGFloat = 0,
        laneOrder: [TimelineMultitrackRow],
        laneHeight: CGFloat,
        laneTopY: CGFloat = 0
    ) {
        self.viewportRange = viewportRange
        self.viewportPixelsPerDay = viewportPixelsPerDay
        self.originX = originX
        self.laneOrder = laneOrder
        self.laneHeight = laneHeight
        self.laneTopY = laneTopY
    }

    /// Map a `Date` to its x-coordinate. Dates outside the viewport map to
    /// the matching off-screen extrapolation (the caller is responsible for
    /// clipping); the projector remains a pure linear function so tests are
    /// trivial round-trips.
    public func x(for date: Date) -> CGFloat {
        let seconds = date.timeIntervalSince(viewportRange.lowerBound)
        let days = seconds / Self.secondsPerDay
        return originX + CGFloat(days * viewportPixelsPerDay)
    }

    /// Inverse of `x(for:)`.
    public func date(forX x: CGFloat) -> Date {
        let dx = Double(x - originX)
        let days = viewportPixelsPerDay == 0 ? 0 : dx / viewportPixelsPerDay
        return viewportRange.lowerBound.addingTimeInterval(days * Self.secondsPerDay)
    }

    /// Center-y of a row. Returns nil when the row isn't represented
    /// in `laneOrder` (e.g., muted-out by solo).
    public func centerY(for row: TimelineMultitrackRow) -> CGFloat? {
        guard let index = laneOrder.firstIndex(of: row) else { return nil }
        return laneTopY + (CGFloat(index) + 0.5) * laneHeight
    }

    /// Top edge of a row.
    public func topY(for row: TimelineMultitrackRow) -> CGFloat? {
        guard let index = laneOrder.firstIndex(of: row) else { return nil }
        return laneTopY + CGFloat(index) * laneHeight
    }

    /// Approximate inverse of `centerY` — given a y-coordinate, returns the
    /// row the point falls in. Returns nil if outside the lane stack.
    public func row(forY y: CGFloat) -> TimelineMultitrackRow? {
        let local = y - laneTopY
        guard local >= 0 else { return nil }
        let index = Int(local / laneHeight)
        guard index >= 0 && index < laneOrder.count else { return nil }
        return laneOrder[index]
    }

    /// Width in pixels for a given time duration at the current zoom.
    public func width(forDuration duration: TimeInterval) -> CGFloat {
        CGFloat((duration / Self.secondsPerDay) * viewportPixelsPerDay)
    }

    /// Total content width (lower → upper bound).
    public var contentWidth: CGFloat {
        let totalDays = viewportRange.upperBound.timeIntervalSince(viewportRange.lowerBound) / Self.secondsPerDay
        return CGFloat(totalDays * viewportPixelsPerDay)
    }
}
