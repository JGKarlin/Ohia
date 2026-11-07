import Foundation

// Projects is a SwiftUI/Canvas workspace. The normal Metal scene should not mount for `.projects`.

/// Calendar-aligned tick generation for the Projects time axis.
///
/// Ticks snap to natural boundaries — midnights, week starts, month starts,
/// round hours — instead of interpolating six arbitrary instants across the
/// range. An interpolated boundary like "Jul 9 at 17:11" communicates false
/// precision; "Jul 9" and "Jul 10" are what a Gantt reader actually scans.
/// The header labels and the canvas gridlines both draw from this single
/// source so they always coincide.
enum ProjectsTimeAxisTicks {
    struct Tick: Equatable {
        let date: Date
        let label: String
        /// A tick that starts a larger unit inside a finer step — midnight
        /// inside an hour-stepped axis, the 1st inside a day-stepped axis.
        /// Major ticks carry the fuller label form.
        let isMajor: Bool
    }

    /// The unit the tick sequence steps by. Sub-day steps are fixed
    /// second counts; day/week steps use calendar day math (DST-safe);
    /// months/years use calendar component math.
    enum Step: Equatable {
        case seconds(TimeInterval)
        case days(Int)
        case months(Int)

        var isSubDay: Bool {
            if case .seconds = self { return true }
            return false
        }
    }

    /// Target upper bound for how many ticks a range yields. The ladder is
    /// walked until the span fits within this many steps.
    private static let maximumTickCount = 7

    /// Fixed sub-day/step ladder in seconds, coarsening left to right.
    private static let subDaySteps: [TimeInterval] = [
        15 * 60, 30 * 60, 3_600, 2 * 3_600, 3 * 3_600, 6 * 3_600, 12 * 3_600
    ]
    private static let daySteps: [Int] = [1, 2, 7, 14]
    private static let monthSteps: [Int] = [1, 2, 3, 6, 12, 24]

    static func step(
        for range: ClosedRange<Date>,
        calendar: Calendar = .current
    ) -> Step {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        for seconds in subDaySteps where span / seconds <= Double(maximumTickCount) {
            return .seconds(seconds)
        }
        for days in daySteps where span / (Double(days) * 86_400) <= Double(maximumTickCount) {
            return .days(days)
        }
        let approximateMonth: TimeInterval = 30.44 * 86_400
        for months in monthSteps where span / (Double(months) * approximateMonth) <= Double(maximumTickCount) {
            return .months(months)
        }
        // Beyond the ladder: step whole years, scaled so the count stays bounded.
        let years = max(1, Int((span / (365.25 * 86_400)) / Double(maximumTickCount)) + 1)
        return .months(years * 12)
    }

    /// Boundary-aligned ticks inside `range`, oldest first. The first tick is
    /// the earliest aligned boundary at or after `range.lowerBound`; ticks
    /// then stride by the chosen step until the upper bound.
    static func ticks(
        in range: ClosedRange<Date>,
        calendar: Calendar = .current
    ) -> [Tick] {
        guard range.upperBound > range.lowerBound else { return [] }
        let step = step(for: range, calendar: calendar)
        var dates: [Date] = []
        var cursor = firstAlignedBoundary(atOrAfter: range.lowerBound, step: step, calendar: calendar)
        var safety = 0
        while cursor <= range.upperBound, safety < 64 {
            dates.append(cursor)
            guard let next = advance(cursor, by: step, calendar: calendar) else { break }
            cursor = next
            safety += 1
        }
        return dates.map { date in
            Tick(
                date: date,
                label: label(for: date, step: step, calendar: calendar),
                isMajor: isMajorBoundary(date, step: step, calendar: calendar)
            )
        }
    }

    // MARK: - Alignment

    private static func firstAlignedBoundary(
        atOrAfter date: Date,
        step: Step,
        calendar: Calendar
    ) -> Date {
        switch step {
        case .seconds(let interval):
            let dayStart = calendar.startOfDay(for: date)
            let offset = date.timeIntervalSince(dayStart)
            let steps = (offset / interval).rounded(.up)
            return dayStart.addingTimeInterval(steps * interval)
        case .days(let count):
            let dayStart = calendar.startOfDay(for: date)
            var aligned = dayStart < date
                ? calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                : dayStart
            if count == 7 || count == 14 {
                // Week-stepped axes anchor to the calendar's week start.
                while calendar.component(.weekday, from: aligned) != calendar.firstWeekday {
                    guard let next = calendar.date(byAdding: .day, value: 1, to: aligned) else { break }
                    aligned = next
                }
            }
            return aligned
        case .months(let count):
            var components = calendar.dateComponents([.year, .month], from: date)
            components.day = 1
            var monthStart = calendar.date(from: components) ?? date
            if monthStart < date {
                monthStart = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
            }
            if count >= 12 {
                // Year-scale axes anchor to January.
                while calendar.component(.month, from: monthStart) != 1 {
                    guard let next = calendar.date(byAdding: .month, value: 1, to: monthStart) else { break }
                    monthStart = next
                }
            }
            return monthStart
        }
    }

    private static func advance(_ date: Date, by step: Step, calendar: Calendar) -> Date? {
        switch step {
        case .seconds(let interval):
            return date.addingTimeInterval(interval)
        case .days(let count):
            return calendar.date(byAdding: .day, value: count, to: date)
        case .months(let count):
            return calendar.date(byAdding: .month, value: count, to: date)
        }
    }

    private static func isMajorBoundary(_ date: Date, step: Step, calendar: Calendar) -> Bool {
        switch step {
        case .seconds:
            return date == calendar.startOfDay(for: date)
        case .days:
            return calendar.component(.day, from: date) == 1
        case .months:
            return calendar.component(.month, from: date) == 1
        }
    }

    // MARK: - Labels

    private static func label(for date: Date, step: Step, calendar: Calendar) -> String {
        switch step {
        case .seconds:
            // Midnight ticks carry the date; interior ticks carry the hour.
            if date == calendar.startOfDay(for: date) {
                return dayFormatter.string(from: date)
            }
            return timeFormatter.string(from: date)
        case .days:
            return dayFormatter.string(from: date)
        case .months(let count):
            if count >= 12 {
                return yearFormatter.string(from: date)
            }
            return monthFormatter.string(from: date)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("y")
        return formatter
    }()
}
