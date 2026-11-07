import Foundation
import SwiftData

/// Ohia's durable link to a meeting event it created in Calendar.app.
///
/// The synced fields are the last state Ohia observed in EventKit. Override
/// fields hold user edits imported from Calendar without rewriting the email
/// evidence that produced the meeting.
@Model
public final class MeetingCalendarRecord {
    @Attribute(.unique) public var entryID: String
    public var eventIdentifier: String?
    public var eventExternalIdentifier: String?

    public var syncedTitle: String?
    public var syncedStartAt: Date?
    public var syncedEndAt: Date?
    public var syncedLocation: String?
    public var syncedOnlineMeetingURLString: String?
    public var syncedAlarmsData: Data?

    /// Non-nil means Calendar supplied an authoritative override. This marker
    /// distinguishes an intentionally cleared optional field from no override.
    public var calendarOverrideImportedAt: Date?
    public var overrideTitle: String?
    public var overrideStartAt: Date?
    public var overrideEndAt: Date?
    public var overrideLocation: String?
    public var overrideOnlineMeetingURLString: String?
    public var overrideAlarmsData: Data?

    public var calendarSyncSuppressedAt: Date?
    public var sourceUpdatedAt: Date?
    public var updatedAt: Date

    public init(
        entryID: String,
        eventIdentifier: String? = nil,
        eventExternalIdentifier: String? = nil,
        syncedTitle: String? = nil,
        syncedStartAt: Date? = nil,
        syncedEndAt: Date? = nil,
        syncedLocation: String? = nil,
        syncedOnlineMeetingURLString: String? = nil,
        syncedAlarmsData: Data? = nil,
        calendarOverrideImportedAt: Date? = nil,
        overrideTitle: String? = nil,
        overrideStartAt: Date? = nil,
        overrideEndAt: Date? = nil,
        overrideLocation: String? = nil,
        overrideOnlineMeetingURLString: String? = nil,
        overrideAlarmsData: Data? = nil,
        calendarSyncSuppressedAt: Date? = nil,
        sourceUpdatedAt: Date? = nil,
        updatedAt: Date = .now
    ) {
        self.entryID = entryID
        self.eventIdentifier = eventIdentifier
        self.eventExternalIdentifier = eventExternalIdentifier
        self.syncedTitle = syncedTitle
        self.syncedStartAt = syncedStartAt
        self.syncedEndAt = syncedEndAt
        self.syncedLocation = syncedLocation
        self.syncedOnlineMeetingURLString = syncedOnlineMeetingURLString
        self.syncedAlarmsData = syncedAlarmsData
        self.calendarOverrideImportedAt = calendarOverrideImportedAt
        self.overrideTitle = overrideTitle
        self.overrideStartAt = overrideStartAt
        self.overrideEndAt = overrideEndAt
        self.overrideLocation = overrideLocation
        self.overrideOnlineMeetingURLString = overrideOnlineMeetingURLString
        self.overrideAlarmsData = overrideAlarmsData
        self.calendarSyncSuppressedAt = calendarSyncSuppressedAt
        self.sourceUpdatedAt = sourceUpdatedAt
        self.updatedAt = updatedAt
    }
}
