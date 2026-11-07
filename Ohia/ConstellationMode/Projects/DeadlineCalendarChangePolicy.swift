import Foundation
import OhiaML

enum DeadlineCalendarAlarmDescriptor: Codable, Sendable, Equatable {
    case absolute(Date)
    case relative(TimeInterval)

    func resolvedDate(eventStart: Date) -> Date {
        switch self {
        case .absolute(let date):
            return date
        case .relative(let offset):
            return eventStart.addingTimeInterval(offset)
        }
    }

    fileprivate var sortKey: (kind: Int, value: TimeInterval) {
        switch self {
        case .absolute(let date):
            return (0, date.timeIntervalSinceReferenceDate)
        case .relative(let offset):
            return (1, offset)
        }
    }
}

/// Sendable value snapshot of the EventKit fields Ohia owns or imports. Keeping
/// the comparison policy free of EventKit makes two-way behavior deterministic
/// and unit-testable without touching the user's calendars.
struct DeadlineCalendarEventState: Sendable, Equatable {
    let deadlineDate: Date
    let granularity: DeadlineDateGranularity
    let title: String
    let alarms: [DeadlineCalendarAlarmDescriptor]

    var alarmDates: [Date] {
        DeadlineCalendarChangePolicy.normalized(
            alarms.map { $0.resolvedDate(eventStart: deadlineDate) }
        )
    }

    init(
        deadlineDate: Date,
        granularity: DeadlineDateGranularity,
        title: String,
        alarmDates: [Date]
    ) {
        self.deadlineDate = deadlineDate
        self.granularity = granularity
        self.title = title
        alarms = DeadlineCalendarChangePolicy.normalizedAlarms(
            alarmDates.map(DeadlineCalendarAlarmDescriptor.absolute)
        )
    }

    init(
        deadlineDate: Date,
        granularity: DeadlineDateGranularity,
        title: String,
        alarms: [DeadlineCalendarAlarmDescriptor]
    ) {
        self.deadlineDate = deadlineDate
        self.granularity = granularity
        self.title = title
        self.alarms = DeadlineCalendarChangePolicy.normalizedAlarms(alarms)
    }
}

struct DeadlineCalendarSyncBaseline: Sendable, Equatable {
    let emailDeadline: DeadlineDateOverride
    let effectiveDeadline: DeadlineDateOverride
    let emailTitle: String
    let effectiveCalendarTitle: String
    let effectiveAlarms: [DeadlineCalendarAlarmDescriptor]
    let syncedDeadlineAt: Date?
    let syncedIsAllDay: Bool?
    let syncedTitle: String?
    let syncedAlarms: [DeadlineCalendarAlarmDescriptor]?
}

enum DeadlineCalendarDateChange: Sendable, Equatable {
    case unchanged
    case restoreEmailEvidence
    case override(DeadlineDateOverride)
}

enum DeadlineCalendarTitleChange: Sendable, Equatable {
    case unchanged
    case restoreEmailSubject
    case override(String)
}

enum DeadlineCalendarAlarmChange: Sendable, Equatable {
    case unchanged
    case named(DeadlineReminderLeadTime)
    case custom([DeadlineCalendarAlarmDescriptor])
}

struct DeadlineCalendarImportedChange: Sendable, Equatable {
    let date: DeadlineCalendarDateChange
    let title: DeadlineCalendarTitleChange
    let alarms: DeadlineCalendarAlarmChange

    var hasChanges: Bool {
        date != .unchanged || title != .unchanged || alarms != .unchanged
    }
}

enum DeadlineCalendarStoreChangeAction: Sendable, Equatable {
    case disabled
    case needsPermission
    case ignoreWhileReconciling
    case importChanges
}

struct DeadlineCalendarOwnershipCandidate: Sendable, Equatable {
    let calendarIdentifier: String
    let ownedEventCount: Int
}

enum DeadlineCalendarOwnershipPolicy {
    static let eventMarkerPrefix = "[ohia-deadline:"

    /// EventKit silently truncates event predicates longer than four years.
    /// Split the full recovery span into contiguous, non-overlapping windows so
    /// ownership evidence cannot disappear merely because deadline history is
    /// wider than EventKit's per-query limit.
    static func eventQueryWindows(
        recoveryDates: [Date],
        calendar: Calendar
    ) -> [DateInterval] {
        let dates = recoveryDates.isEmpty ? [Date.now] : recoveryDates
        guard let earliest = dates.min(),
              let latest = dates.max() else {
            return []
        }

        let overallStart = calendar.date(byAdding: .year, value: -2, to: earliest)
            ?? earliest.addingTimeInterval(-63_072_000)
        let overallEnd = calendar.date(byAdding: .year, value: 2, to: latest)
            ?? latest.addingTimeInterval(63_072_000)

        var windows: [DateInterval] = []
        var windowStart = overallStart
        while windowStart < overallEnd {
            let maximumEnd = calendar.date(byAdding: .year, value: 4, to: windowStart)
                ?? windowStart.addingTimeInterval(126_144_000)
            let windowEnd = min(maximumEnd, overallEnd)
            guard windowEnd > windowStart else { break }
            windows.append(DateInterval(start: windowStart, end: windowEnd))
            windowStart = windowEnd
        }
        return windows
    }

    /// A title match alone is not ownership proof. Recovery is allowed only
    /// when the calendar contains at least one event carrying Ohia's private
    /// deadline marker. When an older bug left more than one owned calendar,
    /// prefer the one containing the most owned events and break ties stably so
    /// reconciliation never creates a third calendar.
    static func recoverableCalendarIdentifier(
        from candidates: [DeadlineCalendarOwnershipCandidate]
    ) -> String? {
        candidates
            .filter { $0.ownedEventCount > 0 }
            .sorted {
                if $0.ownedEventCount != $1.ownedEventCount {
                    return $0.ownedEventCount > $1.ownedEventCount
                }
                return $0.calendarIdentifier < $1.calendarIdentifier
            }
            .first?
            .calendarIdentifier
    }

    /// Prefer the registered calendar when it already contains the event. If
    /// the only marked copy lives in an older Ohia calendar, choose that copy
    /// deterministically so the caller can reuse it instead of inserting a new
    /// event into the registered calendar.
    static func preferredEventCalendarIdentifier(
        primaryIdentifier: String,
        matchingCalendarIdentifiers: [String]
    ) -> String? {
        if matchingCalendarIdentifiers.contains(primaryIdentifier) {
            return primaryIdentifier
        }
        return matchingCalendarIdentifiers.sorted().first
    }

    static func containsOwnedEventMarker(_ notes: String?) -> Bool {
        guard let notes else { return false }
        return notes.split(whereSeparator: { $0.isNewline }).contains { line in
            (line.hasPrefix(eventMarkerPrefix)
                || line.hasPrefix(MeetingCalendarDuplicatePolicy.markerPrefix))
                && line.hasSuffix("]")
                && line.count > min(
                    eventMarkerPrefix.count,
                    MeetingCalendarDuplicatePolicy.markerPrefix.count
                ) + 1
        }
    }
}

enum DeadlineCalendarNamingPolicy {
    static let currentTitle = "Ohia"
    static let legacyTitle = "Ohia Deadlines"

    static func canonicalTitle(forExistingTitle title: String) -> String? {
        switch title {
        case currentTitle, legacyTitle:
            return currentTitle
        default:
            return nil
        }
    }
}

enum DeadlineCalendarLifecyclePolicy {
    /// Maps an EventKit store-change notification to an explicit UI action.
    /// Permission loss must be handled before the reconciliation guard so a
    /// previously healthy label can never remain stale.
    static func storeChangeAction(
        syncEnabled: Bool,
        hasWriteAccess: Bool,
        isReconciling: Bool
    ) -> DeadlineCalendarStoreChangeAction {
        guard syncEnabled else { return .disabled }
        guard hasWriteAccess else { return .needsPermission }
        guard isReconciling == false else { return .ignoreWhileReconciling }
        return .importChanges
    }
}

enum ManagedCalendarDeletionCoordinator {
    /// The missing-calendar marker remains available for a later lifecycle
    /// retry unless every durable event link has been cleared successfully.
    static func clearLinksAndAcknowledge(
        clearLinks: () throws -> Void,
        acknowledge: () -> Void
    ) throws {
        try clearLinks()
        acknowledge()
    }
}

enum DeadlineCalendarChangePolicy {
    private static let comparisonTolerance: TimeInterval = 1

    static func importedChange(
        event: DeadlineCalendarEventState,
        baseline: DeadlineCalendarSyncBaseline,
        calendar: Calendar = .autoupdatingCurrent,
        reminderHour: Int
    ) -> DeadlineCalendarImportedChange {
        let baselineDeadline = baseline.syncedDeadlineAt ?? baseline.effectiveDeadline.date
        let baselineGranularity: DeadlineDateGranularity = {
            if let syncedIsAllDay = baseline.syncedIsAllDay {
                return syncedIsAllDay ? .dateOnly : .dateTime
            }
            return baseline.effectiveDeadline.granularity
        }()

        let dateChanged = datesEqual(event.deadlineDate, baselineDeadline) == false
            || event.granularity != baselineGranularity
        let dateChange: DeadlineCalendarDateChange
        if dateChanged == false {
            dateChange = .unchanged
        } else if datesEqual(event.deadlineDate, baseline.emailDeadline.date),
                  event.granularity == baseline.emailDeadline.granularity {
            dateChange = .restoreEmailEvidence
        } else {
            dateChange = .override(
                DeadlineDateOverride(date: event.deadlineDate, granularity: event.granularity)
            )
        }

        let baselineTitle = baseline.syncedTitle ?? baseline.effectiveCalendarTitle
        let titleChange: DeadlineCalendarTitleChange
        if event.title == baselineTitle {
            titleChange = .unchanged
        } else if event.title == baseline.emailTitle {
            titleChange = .restoreEmailSubject
        } else {
            titleChange = .override(event.title)
        }

        let baselineAlarms = normalizedAlarms(baseline.syncedAlarms ?? baseline.effectiveAlarms)
        let alarmChange: DeadlineCalendarAlarmChange
        if event.alarms == baselineAlarms {
            alarmChange = .unchanged
        } else if event.alarms.isEmpty {
            alarmChange = .named(.none)
        } else if event.alarms.count == 1,
                  let leadTime = matchingLeadTime(
                    alarmDate: event.alarmDates[0],
                    deadlineDate: event.deadlineDate,
                    granularity: event.granularity,
                    calendar: calendar,
                    reminderHour: reminderHour
                  ) {
            alarmChange = .named(leadTime)
        } else {
            alarmChange = .custom(event.alarms)
        }

        return DeadlineCalendarImportedChange(
            date: dateChange,
            title: titleChange,
            alarms: alarmChange
        )
    }

    static func normalized(_ dates: [Date]) -> [Date] {
        dates.sorted().reduce(into: []) { result, date in
            if let last = result.last, datesEqual(last, date) {
                return
            }
            result.append(date)
        }
    }

    static func normalizedAlarms(
        _ alarms: [DeadlineCalendarAlarmDescriptor]
    ) -> [DeadlineCalendarAlarmDescriptor] {
        alarms.sorted {
            let lhs = $0.sortKey
            let rhs = $1.sortKey
            return lhs.kind == rhs.kind ? lhs.value < rhs.value : lhs.kind < rhs.kind
        }.reduce(into: []) { result, alarm in
            if result.last == alarm { return }
            result.append(alarm)
        }
    }

    private static func matchingLeadTime(
        alarmDate: Date,
        deadlineDate: Date,
        granularity: DeadlineDateGranularity,
        calendar: Calendar,
        reminderHour: Int
    ) -> DeadlineReminderLeadTime? {
        DeadlineReminderLeadTime.choices(hasTimeOfDay: granularity == .dateTime)
            .filter { $0 != .none }
            .first {
                guard let candidate = $0.alarmDate(
                    deadlineDate: deadlineDate,
                    granularity: granularity,
                    calendar: calendar,
                    reminderHour: reminderHour
                ) else {
                    return false
                }
                return datesEqual(candidate, alarmDate)
            }
    }

    private static func datesEqual(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) <= comparisonTolerance
    }
}
