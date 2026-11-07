import Foundation
import SwiftData

/// Per-deadline reminder preference and its link to the mirrored Calendar.app
/// event. Keyed by the tracker's stable deadline id (thread- or message-scoped),
/// so the choice and the calendar event survive re-ingestion and snapshot
/// rebuilds. Purely additive to the schema — no migration of existing rows.
@Model
public final class DeadlineReminder {
    /// The `DeadlineEntry.id` this preference belongs to (stable across rebuilds).
    @Attribute(.unique) public var entryID: String
    /// Raw value of `DeadlineReminderLeadTime` (kept as a string so OhiaCore
    /// carries no dependency on the OhiaML enum).
    public var leadTimeRaw: String
    /// `EKEvent.calendarItemIdentifier` of the mirrored Calendar.app event, once
    /// synced. Lets the sync upsert/remove idempotently instead of duplicating.
    public var eventIdentifier: String?
    /// Server-provided EventKit identifier used as a fallback when a full
    /// calendar sync changes `calendarItemIdentifier`.
    public var eventExternalIdentifier: String?
    /// The deadline instant last written to the calendar event, so a shifted
    /// deadline (a later email moved the date) triggers a re-sync.
    public var syncedDeadlineAt: Date?
    /// EventKit's all-day bit from the last successful two-way reconciliation.
    public var syncedIsAllDay: Bool?
    /// Event title from the last successful two-way reconciliation.
    public var syncedEventTitle: String?
    /// Property-list encoded alarm descriptors from the last reconciliation.
    /// Descriptors retain Calendar-authored relative offsets as relative.
    public var syncedAlarmsData: Data?
    /// A Calendar.app date/time edit. The email-derived date remains unchanged;
    /// this explicit user override wins only in deadline scheduling surfaces.
    public var overriddenDeadlineAt: Date?
    /// Raw `DeadlineDateGranularity` paired with `overriddenDeadlineAt`.
    public var overriddenGranularityRaw: String?
    /// A Calendar.app title edit is retained for the calendar event without
    /// rewriting the email subject shown inside Ohia.
    public var calendarTitleOverride: String?
    /// Property-list encoded alarm descriptors for Calendar alarm combinations
    /// that do not map to one of Ohia's named reminder choices.
    public var customAlarmsData: Data?
    /// Non-nil when the user deleted this individual mirrored event in
    /// Calendar.app. The deadline remains in Ohia but is not recreated until
    /// the user explicitly adds it back to Calendar.
    public var calendarSyncSuppressedAt: Date?
    public var updatedAt: Date

    public init(
        entryID: String,
        leadTimeRaw: String,
        eventIdentifier: String? = nil,
        eventExternalIdentifier: String? = nil,
        syncedDeadlineAt: Date? = nil,
        syncedIsAllDay: Bool? = nil,
        syncedEventTitle: String? = nil,
        syncedAlarmsData: Data? = nil,
        overriddenDeadlineAt: Date? = nil,
        overriddenGranularityRaw: String? = nil,
        calendarTitleOverride: String? = nil,
        customAlarmsData: Data? = nil,
        calendarSyncSuppressedAt: Date? = nil,
        updatedAt: Date = .now
    ) {
        self.entryID = entryID
        self.leadTimeRaw = leadTimeRaw
        self.eventIdentifier = eventIdentifier
        self.eventExternalIdentifier = eventExternalIdentifier
        self.syncedDeadlineAt = syncedDeadlineAt
        self.syncedIsAllDay = syncedIsAllDay
        self.syncedEventTitle = syncedEventTitle
        self.syncedAlarmsData = syncedAlarmsData
        self.overriddenDeadlineAt = overriddenDeadlineAt
        self.overriddenGranularityRaw = overriddenGranularityRaw
        self.calendarTitleOverride = calendarTitleOverride
        self.customAlarmsData = customAlarmsData
        self.calendarSyncSuppressedAt = calendarSyncSuppressedAt
        self.updatedAt = updatedAt
    }
}
