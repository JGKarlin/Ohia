import Foundation
import EventKit

public enum ComposerCalendarAvailabilityStatus: String, Sendable, Equatable {
    case busy
    case free
    case tentative
    case unavailable
}

public struct ComposerCalendarAvailabilityEvent: Sendable, Equatable {
    public let title: String
    public let calendarTitle: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let location: String?
    public let availability: ComposerCalendarAvailabilityStatus

    public init(
        title: String,
        calendarTitle: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        availability: ComposerCalendarAvailabilityStatus = .busy
    ) {
        self.title = title
        self.calendarTitle = calendarTitle
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.availability = availability
    }
}

public enum ComposerCalendarAvailabilitySnapshot: Sendable, Equatable {
    case available(events: [ComposerCalendarAvailabilityEvent])
    case unavailable(reason: String)
}

public typealias ComposerCalendarAvailabilityProvider = @MainActor (
    _ interval: DateInterval,
    _ limit: Int
) -> ComposerCalendarAvailabilitySnapshot

@MainActor
enum ComposerEventKitCalendarAvailabilityProvider {
    static func snapshot(
        interval: DateInterval,
        limit: Int
    ) -> ComposerCalendarAvailabilitySnapshot {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            return .unavailable(reason: reason(for: status))
        }

        let store = EKEventStore()
        let predicate = store.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: nil
        )
        let events = store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .compactMap(event(from:))
            .prefix(max(0, limit))
        return .available(events: Array(events))
    }

    private static func event(from event: EKEvent) -> ComposerCalendarAvailabilityEvent? {
        guard let start = event.startDate else { return nil }
        guard let availability = availability(from: event) else { return nil }
        let end = event.endDate ?? start
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ComposerCalendarAvailabilityEvent(
            title: title?.isEmpty == false ? title! : "(no title)",
            calendarTitle: event.calendar?.title ?? "Calendar",
            startDate: start,
            endDate: end,
            isAllDay: event.isAllDay,
            location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            availability: availability
        )
    }

    private static func availability(from event: EKEvent) -> ComposerCalendarAvailabilityStatus? {
        switch event.availability {
        case .free:
            return nil
        case .busy, .notSupported:
            return .busy
        case .tentative:
            return .tentative
        case .unavailable:
            return .unavailable
        @unknown default:
            return .busy
        }
    }

    private static func reason(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "Calendar access has not been granted yet."
        case .restricted:
            return "Calendar access is restricted on this Mac."
        case .denied:
            return "Calendar access is denied in System Settings."
        case .writeOnly:
            return "Ohia only has write-only calendar access, so it cannot read availability."
        case .authorized:
            return "Calendar access is not full-access EventKit authorization."
        case .fullAccess:
            return ""
        @unknown default:
            return "Calendar access is unavailable."
        }
    }
}
