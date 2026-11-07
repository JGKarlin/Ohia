import Foundation
import OhiaCore

struct SurveyTelemetryThreadReport: Sendable, Equatable {
    enum Style: Sendable, Equatable {
        case conversation
        case similarSeries
        /// People-layer aggregate across the user's *entire* correspondence
        /// with the focused contact, independent of the current ring/tab
        /// filter scope and not just the single thread the locked message
        /// happens to sit in. `totalCount` carries the received total,
        /// `includedCount`
        /// carries third-party messages that include the focused contact,
        /// `userReplyCount` carries the sent total, `threadCount` the
        /// distinct conversation count, and `firstMessageAt` / `lastMessageAt`
        /// bracket the time window.
        case people
    }

    let style: Style
    let totalCount: Int
    let includedCount: Int
    let userReplyCount: Int
    let startDate: Date?
    let endDate: Date?
    let firstMessageAt: Date?
    let lastUserReplyAt: Date?
    let lastMessageAt: Date?
    let threadCount: Int?

    static func conversation(
        messagesFromOthers: Int,
        userReplyCount: Int,
        firstMessageAt: Date? = nil,
        lastUserReplyAt: Date? = nil
    ) -> SurveyTelemetryThreadReport {
        SurveyTelemetryThreadReport(
            style: .conversation,
            totalCount: max(0, messagesFromOthers),
            includedCount: 0,
            userReplyCount: max(0, userReplyCount),
            startDate: nil,
            endDate: nil,
            firstMessageAt: firstMessageAt,
            lastUserReplyAt: lastUserReplyAt,
            lastMessageAt: nil,
            threadCount: nil
        )
    }

    static func similarSeries(totalCount: Int, startDate: Date?, endDate: Date?) -> SurveyTelemetryThreadReport {
        SurveyTelemetryThreadReport(
            style: .similarSeries,
            totalCount: max(1, totalCount),
            includedCount: 0,
            userReplyCount: 0,
            startDate: startDate,
            endDate: endDate,
            firstMessageAt: nil,
            lastUserReplyAt: nil,
            lastMessageAt: nil,
            threadCount: nil
        )
    }

    static func people(
        sentCount: Int,
        receivedCount: Int,
        includedCount: Int,
        threadCount: Int,
        firstMessageAt: Date?,
        lastMessageAt: Date?
    ) -> SurveyTelemetryThreadReport {
        SurveyTelemetryThreadReport(
            style: .people,
            totalCount: max(0, receivedCount),
            includedCount: max(0, includedCount),
            userReplyCount: max(0, sentCount),
            startDate: nil,
            endDate: nil,
            firstMessageAt: firstMessageAt,
            lastUserReplyAt: nil,
            lastMessageAt: lastMessageAt,
            threadCount: max(0, threadCount)
        )
    }

    var rowLabel: String {
        switch style {
        case .conversation: return "thread"
        case .similarSeries: return "series"
        case .people: return "messages"
        }
    }

    var valueLabel: String {
        switch style {
        case .conversation:
            return "\(totalCount) \(Self.messageNoun(totalCount)) · \(userReplyCount) \(Self.replyNoun(userReplyCount)) from me"
        case .similarSeries:
            return "\(totalCount) similar · \(dateRangeLabel)"
        case .people:
            var parts = [
                "\(totalCount) received"
            ]
            if includedCount > 0 {
                parts.append("\(includedCount) cc'd")
            }
            parts.append("\(userReplyCount) sent")
            return parts.joined(separator: " · ")
        }
    }

    var startedValueLabel: String? {
        switch style {
        case .conversation, .people:
            guard let date = firstMessageAt else { return nil }
            return Self.dateTimeLabel(date)
        case .similarSeries:
            return nil
        }
    }

    var lastReplyValueLabel: String? {
        guard style == .conversation, let date = lastUserReplyAt else { return nil }
        return Self.dateTimeLabel(date)
    }

    /// Threads count exposed only in the People style — distinct
    /// correspondence groupings across the all-time relationship scope.
    var threadsValueLabel: String? {
        guard style == .people, let count = threadCount else { return nil }
        return "\(count)"
    }

    /// People-style correspondence window from earliest to most recent
    /// relevant message in the all-time relationship scope.
    var periodRangeValueLabel: String? {
        guard style == .people, let start = firstMessageAt else { return nil }
        guard let end = lastMessageAt, end != start else {
            return Self.dateTimeLabel(start)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        if calendar.isDate(start, inSameDayAs: end) {
            return "\(Self.dateTimeLabel(start)) → \(Self.timeLabel(end))"
        }
        return "\(Self.dateTimeLabel(start)) → \(Self.dateTimeLabel(end))"
    }

    /// Start of the People-style correspondence window — kept for callers
    /// that still need the separate boundary value.
    var periodStartValueLabel: String? {
        guard style == .people, let start = firstMessageAt else { return nil }
        return Self.dateLabel(start)
    }

    /// End of the People-style correspondence window — the most recent
    /// relevant message involving the focused contact. Nil when it would
    /// duplicate `periodStartValueLabel` (single-day window) so
    /// the strip doesn't render two identical rows.
    var periodEndValueLabel: String? {
        guard style == .people, let end = lastMessageAt else { return nil }
        if let start = firstMessageAt,
           Calendar.current.isDate(start, inSameDayAs: end) {
            return nil
        }
        return Self.dateLabel(end)
    }

    private var dateRangeLabel: String {
        guard let startDate else { return "date n/a" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let endDate, !calendar.isDate(startDate, inSameDayAs: endDate) else {
            return Self.dateLabel(startDate)
        }
        return "\(Self.dateLabel(startDate)) → \(Self.dateLabel(endDate))"
    }

    private static func messageNoun(_ count: Int) -> String {
        count == 1 ? "message" : "messages"
    }

    private static func replyNoun(_ count: Int) -> String {
        count == 1 ? "reply" : "replies"
    }

    // Shared formatters reused across every `body` rebuild (the locked overlay
    // re-evaluates at 60 Hz inside a TimelineView, so allocating a fresh
    // DateFormatter on every call was a hot path).
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .gmt
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .gmt
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .gmt
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func dateLabel(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static func dateTimeLabel(_ date: Date) -> String {
        dayTimeFormatter.string(from: date)
    }

    private static func timeLabel(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

struct SurveyTelemetry: Sendable, Equatable {
    /// Count of high-confidence neighbours selected as evidence for the
    /// locked CONTEXT narrative.
    let contextNeighborCount: Int
    let threadReport: SurveyTelemetryThreadReport

    init(
        contextNeighborCount: Int,
        threadReport: SurveyTelemetryThreadReport
    ) {
        self.contextNeighborCount = contextNeighborCount
        self.threadReport = threadReport
    }

    var threadReportRowLabel: String {
        threadReport.rowLabel
    }

    var threadReportValueLabel: String {
        threadReport.valueLabel
    }

    var threadStartedValueLabel: String? {
        threadReport.startedValueLabel
    }

    var threadLastReplyValueLabel: String? {
        threadReport.lastReplyValueLabel
    }

    var threadsValueLabel: String? {
        threadReport.threadsValueLabel
    }

    var periodRangeValueLabel: String? {
        threadReport.periodRangeValueLabel
    }

    var periodStartValueLabel: String? {
        threadReport.periodStartValueLabel
    }

    var periodEndValueLabel: String? {
        threadReport.periodEndValueLabel
    }

}
