import Foundation
import OhiaCore

/// How far ahead of a deadline its Calendar.app alarm should fire. The alarm is
/// the whole notification mechanism — Calendar.app owns the firing — so this is
/// simply the offset the sync turns into an `EKAlarm`.
public enum DeadlineReminderLeadTime: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case morningOf
    case oneHourBefore
    case oneDayBefore
    case threeDaysBefore
    case oneWeekBefore
    /// One or more alarm dates authored in Calendar.app that do not map to a
    /// named Ohia choice. Never offered as a menu choice; the sync layer stores
    /// the concrete alarm dates alongside this marker.
    case calendarCustom

    public var id: String { rawValue }

    /// The factory default before the user sets one in General Settings.
    public static let factoryDefault: DeadlineReminderLeadTime = .none

    /// The choices offered for a given deadline. `oneHourBefore` only makes
    /// sense when the deadline carries a specific time.
    public static func choices(hasTimeOfDay: Bool) -> [DeadlineReminderLeadTime] {
        let namedChoices: [DeadlineReminderLeadTime] = [
            .none,
            .morningOf,
            .oneHourBefore,
            .oneDayBefore,
            .threeDaysBefore,
            .oneWeekBefore,
        ]
        return namedChoices.filter { hasTimeOfDay || !$0.requiresTimeOfDay }
    }

    public var requiresTimeOfDay: Bool { self == .oneHourBefore }

    public var title: String {
        switch self {
        case .none: return "No reminder"
        case .morningOf: return "Morning of"
        case .oneHourBefore: return "1 hour before"
        case .oneDayBefore: return "1 day before"
        case .threeDaysBefore: return "3 days before"
        case .oneWeekBefore: return "1 week before"
        case .calendarCustom: return "Calendar custom"
        }
    }

    /// Compact label for the row chip.
    public var shortTitle: String {
        switch self {
        case .none: return "Off"
        case .morningOf: return "Morning of"
        case .oneHourBefore: return "1h before"
        case .oneDayBefore: return "1d before"
        case .threeDaysBefore: return "3d before"
        case .oneWeekBefore: return "1w before"
        case .calendarCustom: return "Custom"
        }
    }

    /// True when this lead time schedules an actual alarm.
    public var schedulesAlarm: Bool { self != .none }

    /// The absolute instant the alarm should fire, or `nil` when there is no
    /// reminder (or an hour-based reminder was chosen for a date-only deadline).
    ///
    /// - `reminderHour`: the local hour date-only deadlines anchor to (the
    ///   General Settings "remind at" hour, default 9am).
    public func alarmDate(
        deadlineDate: Date,
        granularity: DeadlineDateGranularity,
        calendar: Calendar = .autoupdatingCurrent,
        reminderHour: Int = 9
    ) -> Date? {
        switch self {
        case .none:
            return nil
        case .calendarCustom:
            return nil
        case .oneHourBefore:
            guard granularity == .dateTime else { return nil }
            return calendar.date(byAdding: .hour, value: -1, to: deadlineDate)
        case .morningOf:
            return Self.at(hour: reminderHour, onDayOf: deadlineDate, calendar)
        case .oneDayBefore:
            return offset(days: 1, deadlineDate: deadlineDate, granularity: granularity, calendar: calendar, reminderHour: reminderHour)
        case .threeDaysBefore:
            return offset(days: 3, deadlineDate: deadlineDate, granularity: granularity, calendar: calendar, reminderHour: reminderHour)
        case .oneWeekBefore:
            return offset(days: 7, deadlineDate: deadlineDate, granularity: granularity, calendar: calendar, reminderHour: reminderHour)
        }
    }

    private func offset(
        days: Int,
        deadlineDate: Date,
        granularity: DeadlineDateGranularity,
        calendar: Calendar,
        reminderHour: Int
    ) -> Date? {
        guard let earlier = calendar.date(byAdding: .day, value: -days, to: deadlineDate) else { return nil }
        // A timed deadline keeps its own clock time N days earlier; a date-only
        // deadline anchors to the reminder hour on the earlier day.
        return granularity == .dateTime ? earlier : Self.at(hour: reminderHour, onDayOf: earlier, calendar)
    }

    private static func at(hour: Int, onDayOf date: Date, _ calendar: Calendar) -> Date? {
        // Set the hour via components (not by adding N hours to midnight) so a
        // DST transition day still lands on the intended wall-clock hour.
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: calendar.startOfDay(for: date))
    }
}

public extension DeadlineReminder {
    var leadTime: DeadlineReminderLeadTime {
        get { DeadlineReminderLeadTime(rawValue: leadTimeRaw) ?? .none }
        set { leadTimeRaw = newValue.rawValue }
    }
}
