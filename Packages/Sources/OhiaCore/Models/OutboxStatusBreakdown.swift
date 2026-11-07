import Foundation

/// Pure value-type summary of an outbox. Reused by the Activity-strip chip
/// and the Outbox settings tab. Centralized here so its counting rules
/// (e.g. "sentToday" = sent items with `createdAt` ≥ today start) live
/// alongside the `OutboxStatus` enum and remain unit-testable without the
/// SwiftUI app target.
public struct OutboxStatusBreakdown: Sendable, Equatable {
    public let queued: Int
    public let sending: Int
    public let sent: Int
    public let sentToday: Int
    public let failed: Int
    public let cancelled: Int

    public var total: Int {
        queued + sending + sent + failed + cancelled
    }

    public init(
        queued: Int, sending: Int, sent: Int,
        sentToday: Int, failed: Int, cancelled: Int
    ) {
        self.queued = queued
        self.sending = sending
        self.sent = sent
        self.sentToday = sentToday
        self.failed = failed
        self.cancelled = cancelled
    }

    /// Aggregates an array of `OutboxItem`. "Today" is the local-calendar
    /// day containing `now`. `OutboxItem.createdAt` is the reference point —
    /// the spec ties `sentToday` to the enqueue day, not the successful-send
    /// timestamp, because that's what the user actually asked for.
    public static func summarize(
        _ items: [OutboxItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> OutboxStatusBreakdown {
        let todayStart = calendar.startOfDay(for: now)

        var q = 0, s = 0, snt = 0, today = 0, f = 0, c = 0
        for item in items {
            switch item.status {
            case .queued:    q += 1
            case .sending:   s += 1
            case .sent:
                snt += 1
                if item.createdAt >= todayStart { today += 1 }
            case .failed:    f += 1
            case .cancelled: c += 1
            }
        }
        return OutboxStatusBreakdown(
            queued: q, sending: s, sent: snt,
            sentToday: today, failed: f, cancelled: c
        )
    }
}
