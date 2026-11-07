import AppKit
import EventKit
import Foundation
import OSLog
import SwiftData
import OhiaCore
import OhiaML

enum DeadlineCalendarSyncStatus: Equatable {
    case disabled
    case needsPermission
    case syncing
    case synced
    case failed(String)

    var isSynced: Bool { self == .synced }
}

struct DeadlineCalendarPreferenceState: Equatable {
    let leadTime: DeadlineReminderLeadTime
    let dateOverride: DeadlineDateOverride?
    let isCalendarSyncSuppressed: Bool
}

struct ManagedCalendarConflict: Sendable, Equatable {
    let calendarCount: Int
}

enum ManagedCalendarPreparationOutcome: Sendable, Equatable {
    case ready
    case needsResolution(ManagedCalendarConflict)
}

enum ManagedCalendarConflictResolution: Sendable, Hashable {
    case merge
    case replace
}

struct ManagedCalendarMergeEvent: Sendable, Equatable {
    let eventIdentifier: String
    let ownershipMarker: String?
    let lastModifiedAt: Date?
}

struct ManagedCalendarMergeCandidate: Sendable, Equatable {
    let calendarIdentifier: String
    let events: [ManagedCalendarMergeEvent]
}

struct ManagedCalendarMergePlan: Sendable, Equatable {
    let targetCalendarIdentifier: String
    let eventIdentifiersToMove: [String]
    let eventIdentifiersToRemove: [String]
    let calendarIdentifiersToRemove: [String]
}

enum ManagedCalendarMergePolicy {
    /// EventKit limits event predicates to four-year spans. Cover Foundation's
    /// complete representable date domain so deleting a redundant calendar
    /// cannot discard an event merely because it falls outside a typical
    /// human-calendar range.
    static func eventQueryWindows(
        calendar: Foundation.Calendar
    ) -> [DateInterval] {
        let rangeEnd = Date.distantFuture
        var windows: [DateInterval] = []
        var windowStart = Date.distantPast

        while windowStart < rangeEnd {
            let boundedEnd = calendar.date(
                byAdding: .year,
                value: 4,
                to: windowStart
            ) ?? rangeEnd
            let windowEnd = min(boundedEnd, rangeEnd)
            guard windowEnd > windowStart else { break }
            windows.append(DateInterval(start: windowStart, end: windowEnd))
            windowStart = windowEnd
        }
        return windows
    }

    static func plan(
        registeredCalendarIdentifier: String?,
        calendars: [ManagedCalendarMergeCandidate]
    ) -> ManagedCalendarMergePlan? {
        guard let target = targetCalendar(
            registeredCalendarIdentifier: registeredCalendarIdentifier,
            calendars: calendars
        ) else {
            return nil
        }

        let flattenedEvents = calendars.flatMap { calendar in
            calendar.events.map { event in
                (
                    calendarIdentifier: calendar.calendarIdentifier,
                    event: event
                )
            }
        }
        let markedEvents = Dictionary(grouping: flattenedEvents) {
            $0.event.ownershipMarker
        }

        var moveIdentifiers: Set<String> = []
        var removeIdentifiers: Set<String> = []

        for candidate in flattenedEvents where candidate.event.ownershipMarker == nil {
            if candidate.calendarIdentifier != target.calendarIdentifier {
                moveIdentifiers.insert(candidate.event.eventIdentifier)
            }
        }

        for (marker, candidates) in markedEvents {
            guard marker != nil,
                  let winner = candidates.sorted(by: {
                      shouldPrefer(
                          $0,
                          over: $1,
                          targetCalendarIdentifier: target.calendarIdentifier
                      )
                  }).first else {
                continue
            }

            if winner.calendarIdentifier != target.calendarIdentifier {
                moveIdentifiers.insert(winner.event.eventIdentifier)
            }
            for candidate in candidates
            where candidate.event.eventIdentifier != winner.event.eventIdentifier {
                removeIdentifiers.insert(candidate.event.eventIdentifier)
            }
        }

        return ManagedCalendarMergePlan(
            targetCalendarIdentifier: target.calendarIdentifier,
            eventIdentifiersToMove: moveIdentifiers.sorted(),
            eventIdentifiersToRemove: removeIdentifiers.sorted(),
            calendarIdentifiersToRemove: calendars
                .map(\.calendarIdentifier)
                .filter { $0 != target.calendarIdentifier }
                .sorted()
        )
    }

    private static func targetCalendar(
        registeredCalendarIdentifier: String?,
        calendars: [ManagedCalendarMergeCandidate]
    ) -> ManagedCalendarMergeCandidate? {
        if let registeredCalendarIdentifier,
           let registered = calendars.first(where: {
               $0.calendarIdentifier == registeredCalendarIdentifier
           }) {
            return registered
        }

        return calendars.sorted {
            let lhsOwnedCount = $0.events.count { $0.ownershipMarker != nil }
            let rhsOwnedCount = $1.events.count { $0.ownershipMarker != nil }
            if lhsOwnedCount != rhsOwnedCount {
                return lhsOwnedCount > rhsOwnedCount
            }
            if $0.events.count != $1.events.count {
                return $0.events.count > $1.events.count
            }
            return $0.calendarIdentifier < $1.calendarIdentifier
        }.first
    }

    private static func shouldPrefer(
        _ lhs: (calendarIdentifier: String, event: ManagedCalendarMergeEvent),
        over rhs: (calendarIdentifier: String, event: ManagedCalendarMergeEvent),
        targetCalendarIdentifier: String
    ) -> Bool {
        let lhsModifiedAt = lhs.event.lastModifiedAt ?? .distantPast
        let rhsModifiedAt = rhs.event.lastModifiedAt ?? .distantPast
        if lhsModifiedAt != rhsModifiedAt {
            return lhsModifiedAt > rhsModifiedAt
        }
        if lhs.calendarIdentifier != rhs.calendarIdentifier {
            if lhs.calendarIdentifier == targetCalendarIdentifier { return true }
            if rhs.calendarIdentifier == targetCalendarIdentifier { return false }
        }
        return lhs.event.eventIdentifier < rhs.event.eventIdentifier
    }
}

enum ManagedCalendarReplacementCoordinator {
    /// EventKit applies all staged saves and removals through one `commit()`.
    /// Staging the replacement first guarantees that a creation failure cannot
    /// delete the user's existing Ohia calendars.
    static func perform<Replacement>(
        stageReplacement: () throws -> Replacement,
        stageCalendarRemoval: () throws -> Void,
        commit: () throws -> Void,
        rollback: () -> Void
    ) throws -> Replacement {
        do {
            let replacement = try stageReplacement()
            try stageCalendarRemoval()
            try commit()
            return replacement
        } catch {
            rollback()
            throw error
        }
    }
}

enum DeadlineCalendarSyncError: LocalizedError, Equatable {
    case permissionRequired
    case calendarDeleted
    case calendarReadOnly
    case noWritableSource
    case calendarSaveFailed(String)
    case eventSaveFailed(String)
    case eventRemoveFailed(String)
    case persistenceFailed(String)
    case postCommitCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Calendar access is required."
        case .calendarDeleted:
            return "The Ohia calendar was deleted in Calendar.app."
        case .calendarReadOnly:
            return "The existing Ohia calendar is read-only."
        case .noWritableSource:
            return "No Calendar account accepted a new Ohia calendar."
        case .calendarSaveFailed(let message):
            return "The Ohia calendar could not be saved: \(message)"
        case .eventSaveFailed(let message):
            return "A deadline event could not be saved: \(message)"
        case .eventRemoveFailed(let message):
            return "A deadline event could not be removed: \(message)"
        case .persistenceFailed(let message):
            return "Ohia could not save the Calendar sync state: \(message)"
        case .postCommitCleanupFailed(let message):
            return "The Ohia calendar was updated, but saved event links could not be refreshed: \(message)"
        }
    }
}

/// Two-way reconciliation for the dedicated "Ohia" calendar.
///
/// Ohia remains the owner of email-derived evidence. Calendar.app may override
/// a deadline's date/time, event title, and alarms; those edits are imported as
/// explicit user preferences without rewriting the source email interpretation.
/// Deleting one event suppresses only that deadline's mirror. Deleting the
/// entire managed calendar is a global opt-out handled by the settings toggle.
///
/// `@MainActor` is required because `ModelContext`, `EKEventStore`, and all
/// EventKit objects used here are non-Sendable shared state.
@MainActor
final class DeadlineCalendarSync {
    static let calendarTitle = DeadlineCalendarNamingPolicy.currentTitle
    static let calendarStoreDidChangeNotification = Notification.Name.EKEventStoreChanged

    private static let calendarIdentifierKey = "ohia.deadline.calendarIdentifier"
    private static let logger = Logger(
        subsystem: "org.jgkarlin.Ohia",
        category: "DeadlineCalendarSync"
    )

    private let store: EKEventStore
    private let modelContext: ModelContext

    init(modelContext: ModelContext, store: EKEventStore = EKEventStore()) {
        self.modelContext = modelContext
        self.store = store
    }

    // MARK: - Access and managed-calendar lifecycle

    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    static var hasWriteAccess: Bool {
        authorizationStatus == .fullAccess
    }

    static var hasManagedCalendarRegistration: Bool {
        UserDefaults.standard.string(forKey: calendarIdentifierKey) != nil
    }

    func ensureAccess() async -> Bool {
        switch Self.authorizationStatus {
        case .fullAccess:
            return true
        case .notDetermined:
            return (try? await store.requestFullAccessToEvents()) ?? false
        default:
            return false
        }
    }

    /// Makes the persisted Settings selection and the EventKit resource agree.
    /// A registered, writable calendar is ready immediately. Any unregistered
    /// or duplicate calendar bearing Ohia's current or legacy title requires an
    /// explicit merge/replace decision before Ohia changes Calendar.app.
    func prepareManagedCalendar() throws -> ManagedCalendarPreparationOutcome {
        guard Self.hasWriteAccess else { throw DeadlineCalendarSyncError.permissionRequired }
        let candidates = managedCalendarCandidates()
        let registeredIdentifier = UserDefaults.standard.string(
            forKey: Self.calendarIdentifierKey
        )

        if candidates.isEmpty {
            if registeredIdentifier != nil {
                try clearEventLinksAfterManagedCalendarDeletion()
                Self.acknowledgeManagedCalendarDeletion()
            }
            _ = try createCalendar()
            return .ready
        }

        if candidates.count == 1,
           candidates[0].calendarIdentifier == registeredIdentifier {
            guard candidates[0].allowsContentModifications else {
                throw DeadlineCalendarSyncError.calendarReadOnly
            }
            try normalizeManagedCalendarTitle(candidates[0])
            return .ready
        }

        return .needsResolution(
            ManagedCalendarConflict(calendarCount: candidates.count)
        )
    }

    func resolveManagedCalendarConflict(
        _ resolution: ManagedCalendarConflictResolution
    ) async throws {
        guard Self.hasWriteAccess else { throw DeadlineCalendarSyncError.permissionRequired }
        switch resolution {
        case .merge:
            try await mergeManagedCalendars()
        case .replace:
            try replaceManagedCalendars()
        }
    }

    /// True only when Ohia previously created its managed calendar and
    /// that calendar can no longer be found. A first launch with no identifier
    /// is not treated as a deletion.
    static func managedCalendarWasDeleted() -> Bool {
        guard hasWriteAccess,
              UserDefaults.standard.string(forKey: calendarIdentifierKey) != nil else {
            return false
        }
        let eventStore = EKEventStore()
        if managedCalendar(in: eventStore) != nil {
            return false
        }
        return true
    }

    static func acknowledgeManagedCalendarDeletion() {
        UserDefaults.standard.removeObject(forKey: calendarIdentifierKey)
    }

    /// Deletes the whole managed calendar after the Settings UI has obtained
    /// explicit confirmation. The caller owns changing the persisted toggle.
    static func deleteManagedCalendar() throws {
        // A user may turn the default-on preference off before ever granting
        // Calendar access. With no registered managed calendar there is
        // nothing to delete, so disabling must still succeed.
        guard hasManagedCalendarRegistration else { return }
        guard hasWriteAccess else { throw DeadlineCalendarSyncError.permissionRequired }
        let eventStore = EKEventStore()
        guard let calendar = managedCalendar(in: eventStore) else {
            return
        }
        do {
            try eventStore.removeCalendar(calendar, commit: true)
            logger.notice("Deleted managed Ohia calendar")
        } catch {
            logger.error("Calendar deletion failed: \(String(reflecting: type(of: error)), privacy: .public)")
            throw DeadlineCalendarSyncError.calendarSaveFailed(error.localizedDescription)
        }
    }

    /// Clears only EventKit links after the whole calendar disappears. User
    /// date/alarm overrides remain available if syncing is enabled again later.
    func clearEventLinksAfterManagedCalendarDeletion() throws {
        for reminder in try fetchReminders() {
            clearEventLink(reminder)
        }
        for record in try fetchMeetingRecords() {
            clearMeetingEventLink(record)
        }
        try saveModelContext()
    }

    // MARK: - Outbound reconciliation

    /// Reconciles active entries into Calendar.app. This method succeeds only
    /// after the calendar exists, every in-scope event write/remove succeeds,
    /// and SwiftData records the resulting fingerprints. Callers may display
    /// "Calendar synced" only after it returns without throwing.
    func reconcile(
        entries: [DeadlineEntry],
        defaultLeadTime: DeadlineReminderLeadTime,
        reminderHour: Int
    ) throws {
        guard Self.hasWriteAccess else { throw DeadlineCalendarSyncError.permissionRequired }
        let reminders = try fetchReminders()
        let calendar = try ensureCalendar(
            recoveryDates: calendarRecoveryDates(entries: entries, reminders: reminders)
        )
        let remindersByID = Dictionary(uniqueKeysWithValues: reminders.map { ($0.entryID, $0) })

        for entry in entries where entry.status != .resolved {
            let reminder = remindersByID[entry.id]
                ?? makeReminder(entryID: entry.id, leadTime: defaultLeadTime)
            guard reminder.calendarSyncSuppressedAt == nil else { continue }
            try upsertEvent(
                for: entry,
                reminder: reminder,
                calendar: calendar,
                reminderHour: reminderHour
            )
        }

        for entry in entries where entry.status == .resolved {
            guard let reminder = remindersByID[entry.id],
                  reminder.eventIdentifier != nil || reminder.eventExternalIdentifier != nil else {
                continue
            }
            try removeEvent(for: reminder, calendar: calendar)
        }

        try saveModelContext()
    }

    /// Reconciles timed meetings without changing message classification.
    ///
    /// Calendar edits to Ohia-owned events are imported first and then become
    /// authoritative overrides. Duplicate detection spans every calendar; an
    /// unrelated provider event is never linked, edited, or deleted by Ohia.
    func reconcileMeetings(
        entries: [MeetingEntry],
        defaultLeadTime: DeadlineReminderLeadTime,
        reminderHour: Int
    ) throws {
        guard Self.hasWriteAccess else { throw DeadlineCalendarSyncError.permissionRequired }
        let records = try fetchMeetingRecords()
        guard entries.isEmpty == false || records.isEmpty == false else { return }

        let recoveryDates = entries.map(\.startDate)
            + records.compactMap(\.syncedStartAt)
            + records.compactMap(\.overrideStartAt)
        let calendar = try ensureCalendar(recoveryDates: recoveryDates)
        var candidateEvents = meetingEventCandidates(
            for: entries,
            recoveryDates: recoveryDates
        )
        var recordsByID = Dictionary(
            uniqueKeysWithValues: records.map { ($0.entryID, $0) }
        )
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

        try importMeetingCalendarChanges(
            entriesByID: entriesByID,
            records: records,
            candidateEvents: candidateEvents,
            calendar: calendar,
            defaultLeadTime: defaultLeadTime,
            reminderHour: reminderHour
        )

        for entry in entries {
            var record = recordsByID[entry.id]
            if let record,
               record.calendarSyncSuppressedAt != nil {
                let invitationIsNewer = entry.source == .calendarInvitation
                    && entry.sourceUpdatedAt > (record.sourceUpdatedAt ?? .distantPast)
                guard invitationIsNewer else { continue }
                record.calendarSyncSuppressedAt = nil
                record.updatedAt = .now
            }

            let key = MeetingCalendarMatchKey(
                entryID: entry.id,
                externalIdentifier: entry.externalIdentifier,
                title: entry.title,
                startDate: entry.startDate,
                onlineMeetingURL: entry.onlineMeetingURL,
                isRecurrenceInstance: entry.isRecurrenceInstance,
                threadID: entry.threadID,
                isCalendarInvitation: entry.source == .calendarInvitation
            )
            let canonical = MeetingCalendarDuplicatePolicy.canonicalEvent(
                for: key,
                candidates: candidateEvents.map(meetingEventCandidate)
            )

            if entry.isCancelled {
                if let canonical,
                   canonical.calendarIdentifier == calendar.calendarIdentifier,
                   let event = candidateEvents.first(where: {
                       $0.calendarItemIdentifier == canonical.identifier
                   }),
                   let ownedEntryID = MeetingCalendarDuplicatePolicy.markerValue(
                       prefix: MeetingCalendarDuplicatePolicy.markerPrefix,
                       notes: event.notes
                   ),
                   (ownedEntryID == entry.id || entry.source == .calendarInvitation),
                   isUntouchedOwnedMeeting(event, entryID: ownedEntryID) {
                    try removeMeetingEvent(event, entryID: entry.id)
                    candidateEvents.removeAll {
                        $0.calendarItemIdentifier == canonical.identifier
                    }
                    if let ownedRecord = recordsByID[ownedEntryID] {
                        clearMeetingEventLink(ownedRecord)
                        ownedRecord.sourceUpdatedAt = entry.sourceUpdatedAt
                        ownedRecord.updatedAt = .now
                    }
                }
                continue
            }

            guard let canonical else {
                record = record ?? makeMeetingRecord(entryID: entry.id)
                recordsByID[entry.id] = record
                let state = effectiveMeetingState(
                    for: entry,
                    record: record,
                    defaultLeadTime: defaultLeadTime,
                    reminderHour: reminderHour
                )
                let event = try saveNewMeetingEvent(
                    entry,
                    state: state,
                    record: record!,
                    calendar: calendar
                )
                candidateEvents.append(event)
                continue
            }

            guard canonical.calendarIdentifier == calendar.calendarIdentifier,
                  let event = candidateEvents.first(where: {
                      $0.calendarItemIdentifier == canonical.identifier
                  }) else {
                // The newest unrelated Calendar/provider event wins. Retire
                // any Ohia copy so the result is not a visible duplicate,
                // while never mutating the external event.
                if let owned = ownedMeetingEvent(
                    matching: entry,
                    record: record,
                    candidates: candidateEvents,
                    calendar: calendar
                ),
                let ownedEntryID = MeetingCalendarDuplicatePolicy.markerValue(
                    prefix: MeetingCalendarDuplicatePolicy.markerPrefix,
                    notes: owned.notes
                ) {
                    let ownedIsUntouched = isUntouchedOwnedMeeting(
                        owned,
                        entryID: ownedEntryID
                    )
                    let action = MeetingCalendarDuplicatePolicy.ownedDuplicateAction(
                        canonicalCalendarIdentifier: canonical.calendarIdentifier,
                        managedCalendarIdentifier: calendar.calendarIdentifier,
                        hasOwnedCopy: true,
                        ownedCopyMatchesManagedFingerprint: ownedIsUntouched
                    )
                    guard case .retire(let preserveOverride) = action else {
                        continue
                    }
                    if ownedEntryID != entry.id {
                        record = transferMeetingRecord(
                            recordsByID[ownedEntryID],
                            existingTarget: record,
                            toEntryID: entry.id
                        )
                        recordsByID.removeValue(forKey: ownedEntryID)
                        recordsByID[entry.id] = record
                    } else if record == nil {
                        record = makeMeetingRecord(entryID: entry.id)
                        recordsByID[entry.id] = record
                    }
                    if preserveOverride,
                       let record {
                        applyMeetingImport(
                            .override(meetingCalendarEventState(owned)),
                            to: record
                        )
                    }
                    try removeMeetingEvent(owned, entryID: entry.id)
                    candidateEvents.removeAll {
                        $0.calendarItemIdentifier == owned.calendarItemIdentifier
                    }
                    if let record {
                        clearMeetingEventLink(record)
                        record.calendarSyncSuppressedAt = .now
                        record.updatedAt = .now
                    }
                }
                continue
            }

            if event.notes?.contains(
                MeetingCalendarDuplicatePolicy.marker(entryID: entry.id)
            ) == true {
                if record == nil {
                    let newRecord = makeMeetingRecord(entryID: entry.id)
                    if isUntouchedOwnedMeeting(event, entryID: entry.id) == false {
                        applyMeetingImport(
                            .override(meetingCalendarEventState(event)),
                            to: newRecord
                        )
                    }
                    record = newRecord
                }
                recordsByID[entry.id] = record
                try updateOwnedMeetingEventIfNeeded(
                    event,
                    from: entry,
                    record: record!,
                    defaultLeadTime: defaultLeadTime,
                    reminderHour: reminderHour
                )
            } else if entry.source == .calendarInvitation {
                guard let previousEntryID = MeetingCalendarDuplicatePolicy.markerValue(
                    prefix: MeetingCalendarDuplicatePolicy.markerPrefix,
                    notes: event.notes
                ) else {
                    continue
                }
                let previousRecord = recordsByID[previousEntryID]
                let invitationRecord = transferMeetingRecord(
                    previousRecord,
                    existingTarget: record,
                    toEntryID: entry.id
                )
                recordsByID.removeValue(forKey: previousEntryID)
                recordsByID[entry.id] = invitationRecord
                if isUntouchedOwnedMeeting(event, entryID: previousEntryID) {
                    try updateOwnedMeetingEventIfNeeded(
                        event,
                        from: entry,
                        record: invitationRecord,
                        defaultLeadTime: defaultLeadTime,
                        reminderHour: reminderHour,
                        force: true
                    )
                } else {
                    let eventState = meetingCalendarEventState(event)
                    applyMeetingImport(.override(eventState), to: invitationRecord)
                    recordMeetingSyncedState(
                        eventState,
                        event: event,
                        sourceUpdatedAt: entry.sourceUpdatedAt,
                        record: invitationRecord
                    )
                }
            }
        }
        try saveModelContext()
    }

    @discardableResult
    func setLeadTime(
        _ leadTime: DeadlineReminderLeadTime,
        for entry: DeadlineEntry,
        enabled: Bool,
        reminderHour: Int
    ) throws -> DeadlineReminderLeadTime {
        let reminder = try fetchReminder(entryID: entry.id)
            ?? makeReminder(entryID: entry.id, leadTime: leadTime)
        reminder.leadTime = leadTime
        reminder.customAlarmsData = nil
        reminder.updatedAt = .now
        if enabled,
           reminder.calendarSyncSuppressedAt == nil {
            let calendar = try ensureCalendar(
                recoveryDates: calendarRecoveryDates(entries: [entry], reminders: [reminder])
            )
            try upsertEvent(
                for: entry,
                reminder: reminder,
                calendar: calendar,
                reminderHour: reminderHour
            )
        }
        try saveModelContext()
        return leadTime
    }

    func restoreEmailDate(
        for baseEntry: DeadlineEntry,
        enabled: Bool,
        reminderHour: Int
    ) throws {
        guard let reminder = try fetchReminder(entryID: baseEntry.id) else { return }
        reminder.overriddenDeadlineAt = nil
        reminder.overriddenGranularityRaw = nil
        reminder.updatedAt = .now
        if enabled,
           reminder.calendarSyncSuppressedAt == nil {
            let calendar = try ensureCalendar(
                recoveryDates: calendarRecoveryDates(entries: [baseEntry], reminders: [reminder])
            )
            try upsertEvent(
                for: baseEntry,
                reminder: reminder,
                calendar: calendar,
                reminderHour: reminderHour
            )
        }
        try saveModelContext()
    }

    func restoreCalendarEvent(
        for entry: DeadlineEntry,
        reminderHour: Int
    ) throws {
        let reminder = try fetchReminder(entryID: entry.id)
            ?? makeReminder(entryID: entry.id, leadTime: .none)
        reminder.calendarSyncSuppressedAt = nil
        reminder.updatedAt = .now
        let calendar = try ensureCalendar(
            recoveryDates: calendarRecoveryDates(entries: [entry], reminders: [reminder])
        )
        try upsertEvent(
            for: entry,
            reminder: reminder,
            calendar: calendar,
            reminderHour: reminderHour
        )
        try saveModelContext()
    }

    // MARK: - Inbound reconciliation

    /// Imports Calendar.app edits for known Ohia events. Unmarked events are
    /// ignored. An event missing after identifier, external-identifier, and
    /// marker recovery is treated as an intentional per-deadline deletion.
    @discardableResult
    func importCalendarChanges(
        baseEntries: [DeadlineEntry],
        reminderHour: Int
    ) throws -> Bool {
        guard Self.hasWriteAccess else { throw DeadlineCalendarSyncError.permissionRequired }
        let calendar = try existingCalendarOrDeletionError()
        let baseEntriesByID = Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.id, $0) })
        var changed = false

        for reminder in try fetchReminders() {
            guard reminder.calendarSyncSuppressedAt == nil,
                  reminder.eventIdentifier != nil || reminder.eventExternalIdentifier != nil,
                  let baseEntry = baseEntriesByID[reminder.entryID] else {
                continue
            }

            guard let event = findOwnedEvent(
                for: reminder,
                calendar: calendar,
                expectedDate: reminder.overriddenDeadlineAt ?? baseEntry.deadlineDate
            ) else {
                reminder.calendarSyncSuppressedAt = .now
                clearEventLink(reminder)
                reminder.updatedAt = .now
                changed = true
                continue
            }

            let eventState = calendarEventState(event)
            let effectiveDeadline = deadlineOverride(for: reminder)
                ?? DeadlineDateOverride(date: baseEntry.deadlineDate, granularity: baseEntry.granularity)
            let expectedAlarms = alarmDescriptors(
                for: reminder,
                deadlineDate: effectiveDeadline.date,
                granularity: effectiveDeadline.granularity,
                reminderHour: reminderHour
            )
            let baseline = DeadlineCalendarSyncBaseline(
                emailDeadline: DeadlineDateOverride(
                    date: baseEntry.deadlineDate,
                    granularity: baseEntry.granularity
                ),
                effectiveDeadline: effectiveDeadline,
                emailTitle: baseEntry.title.isEmpty ? "Deadline" : baseEntry.title,
                effectiveCalendarTitle: reminder.calendarTitleOverride
                    ?? (baseEntry.title.isEmpty ? "Deadline" : baseEntry.title),
                effectiveAlarms: expectedAlarms,
                syncedDeadlineAt: reminder.syncedDeadlineAt,
                syncedIsAllDay: reminder.syncedIsAllDay,
                syncedTitle: reminder.syncedEventTitle,
                syncedAlarms: decodeAlarms(reminder.syncedAlarmsData)
            )
            let imported = DeadlineCalendarChangePolicy.importedChange(
                event: eventState,
                baseline: baseline,
                reminderHour: reminderHour
            )

            apply(imported, to: reminder)
            recordSyncedState(eventState, event: event, reminder: reminder)
            reminder.updatedAt = .now
            changed = changed || imported.hasChanges
        }

        try saveModelContext()
        return changed
    }

    // MARK: - Preference reads

    func preferences(
        forEntryIDs ids: [String]
    ) throws -> [String: DeadlineCalendarPreferenceState] {
        guard ids.isEmpty == false else { return [:] }
        let idSet = Set(ids)
        return Dictionary(uniqueKeysWithValues: try fetchReminders()
            .filter { idSet.contains($0.entryID) }
            .map { reminder in
                (
                    reminder.entryID,
                    DeadlineCalendarPreferenceState(
                        leadTime: reminder.leadTime,
                        dateOverride: deadlineOverride(for: reminder),
                        isCalendarSyncSuppressed: reminder.calendarSyncSuppressedAt != nil
                    )
                )
            })
    }

    // MARK: - Events

    private func upsertEvent(
        for entry: DeadlineEntry,
        reminder: DeadlineReminder,
        calendar: EKCalendar,
        reminderHour: Int
    ) throws {
        let event = findOwnedEvent(
            for: reminder,
            calendar: calendar,
            expectedDate: entry.deadlineDate
        ) ?? EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = reminder.calendarTitleOverride
            ?? (entry.title.isEmpty ? "Deadline" : entry.title)
        event.notes = eventNotes(for: entry)

        if entry.granularity == .dateOnly {
            let start = Foundation.Calendar.autoupdatingCurrent.startOfDay(for: entry.deadlineDate)
            event.isAllDay = true
            event.startDate = start
            event.endDate = Foundation.Calendar.autoupdatingCurrent.date(
                byAdding: .day,
                value: 1,
                to: start
            ) ?? start.addingTimeInterval(86_400)
        } else {
            event.isAllDay = false
            event.startDate = entry.deadlineDate
            event.endDate = entry.deadlineDate.addingTimeInterval(3_600)
        }

        let desiredAlarms = alarmDescriptors(
            for: reminder,
            deadlineDate: event.startDate,
            granularity: event.isAllDay ? .dateOnly : .dateTime,
            reminderHour: reminderHour
        )
        event.alarms = desiredAlarms.map(eventKitAlarm)

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            Self.logger.error("Event save failed for \(entry.id, privacy: .private): \(String(reflecting: type(of: error)), privacy: .public)")
            throw DeadlineCalendarSyncError.eventSaveFailed(error.localizedDescription)
        }

        reminder.calendarSyncSuppressedAt = nil
        recordSyncedState(calendarEventState(event), event: event, reminder: reminder)
        reminder.updatedAt = .now
    }

    private func removeEvent(for reminder: DeadlineReminder, calendar: EKCalendar) throws {
        if let event = findOwnedEvent(
            for: reminder,
            calendar: calendar,
            expectedDate: reminder.syncedDeadlineAt ?? .now
        ) {
            do {
                try store.remove(event, span: .thisEvent, commit: true)
            } catch {
                Self.logger.error("Event removal failed: \(String(reflecting: type(of: error)), privacy: .public)")
                throw DeadlineCalendarSyncError.eventRemoveFailed(error.localizedDescription)
            }
        }
        clearEventLink(reminder)
        reminder.updatedAt = .now
    }

    private func saveNewMeetingEvent(
        _ entry: MeetingEntry,
        state: MeetingCalendarEventState,
        record: MeetingCalendarRecord,
        calendar: EKCalendar
    ) throws -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        applyMeetingFields(state, to: event)
        event.notes = meetingEventNotes(for: entry, state: state)
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            Self.logger.error(
                "Meeting save failed for \(entry.id, privacy: .private): \(String(reflecting: type(of: error)), privacy: .public)"
            )
            throw DeadlineCalendarSyncError.eventSaveFailed(error.localizedDescription)
        }
        recordMeetingSyncedState(
            state,
            event: event,
            sourceUpdatedAt: entry.sourceUpdatedAt,
            record: record
        )
        return event
    }

    private func updateOwnedMeetingEventIfNeeded(
        _ event: EKEvent,
        from entry: MeetingEntry,
        record: MeetingCalendarRecord,
        defaultLeadTime: DeadlineReminderLeadTime,
        reminderHour: Int,
        force: Bool = false
    ) throws {
        let state = effectiveMeetingState(
            for: entry,
            record: record,
            defaultLeadTime: defaultLeadTime,
            reminderHour: reminderHour
        )
        if force == false,
           record.calendarOverrideImportedAt != nil {
            recordMeetingSyncedState(
                meetingCalendarEventState(event),
                event: event,
                sourceUpdatedAt: entry.sourceUpdatedAt,
                record: record
            )
            return
        }

        let currentState = meetingCalendarEventState(event)
        let currentEntryID = MeetingCalendarDuplicatePolicy.markerValue(
            prefix: MeetingCalendarDuplicatePolicy.markerPrefix,
            notes: event.notes
        )
        guard force
            || currentState != state
            || currentEntryID != entry.id
            || record.sourceUpdatedAt != entry.sourceUpdatedAt else {
            recordMeetingSyncedState(
                currentState,
                event: event,
                sourceUpdatedAt: entry.sourceUpdatedAt,
                record: record
            )
            return
        }

        applyMeetingFields(state, to: event)
        event.notes = meetingEventNotes(for: entry, state: state)
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            Self.logger.error(
                "Meeting update failed for \(entry.id, privacy: .private): \(String(reflecting: type(of: error)), privacy: .public)"
            )
            throw DeadlineCalendarSyncError.eventSaveFailed(error.localizedDescription)
        }
        recordMeetingSyncedState(
            state,
            event: event,
            sourceUpdatedAt: entry.sourceUpdatedAt,
            record: record
        )
    }

    private func applyMeetingFields(
        _ state: MeetingCalendarEventState,
        to event: EKEvent
    ) {
        event.title = state.title
        event.isAllDay = false
        event.startDate = state.startDate
        event.endDate = state.endDate
        event.location = state.location
        event.url = state.onlineMeetingURL
        event.alarms = state.alarms.map(eventKitAlarm)
    }

    private func meetingEventNotes(
        for entry: MeetingEntry,
        state: MeetingCalendarEventState
    ) -> String {
        let prose = meetingEventProseNotes(for: entry)
        let fingerprint = MeetingCalendarDuplicatePolicy.eventFingerprint(
            title: state.title,
            startDate: state.startDate,
            endDate: state.endDate,
            location: state.location,
            onlineMeetingURL: state.onlineMeetingURL,
            alarms: state.alarms,
            notes: prose
        )
        var lines = prose.components(separatedBy: "\n")
        lines.append(contentsOf: [
            MeetingCalendarDuplicatePolicy.marker(entryID: entry.id),
            "\(MeetingCalendarDuplicatePolicy.sourceUpdatedPrefix)\(entry.sourceUpdatedAt.timeIntervalSince1970)]",
            "\(MeetingCalendarDuplicatePolicy.fingerprintPrefix)\(fingerprint)]",
            "\(MeetingCalendarDuplicatePolicy.kindPrefix)\(entry.source == .calendarInvitation ? "invitation" : "body")]",
        ])
        if let threadID = entry.threadID {
            lines.append(
                MeetingCalendarDuplicatePolicy.threadMarker(threadID: threadID)
            )
        }
        return lines.joined(separator: "\n")
    }

    /// The human-readable block at the top of a managed meeting event's
    /// notes — everything before the `[ohia-meeting-*]` machine tags. This
    /// exact text must also be what gets fed into `eventFingerprint(notes:)`
    /// above (and in `isUntouchedOwnedMeeting` below, when re-reading a live
    /// event back): `normalizedUserNotes` strips tag lines from whatever it's
    /// given, so both sides only agree on "untouched" if the surviving prose
    /// is identical on each side. Add a line here — and only here — rather
    /// than inlining it, or a future edit will silently desync the two and
    /// every sync will start mistaking this text for a user edit.
    private func meetingEventProseNotes(for entry: MeetingEntry) -> String {
        var lines = ["Tracked by Ohia."]
        if let summary = existingBodySummary(for: entry.sourceMessageID) {
            lines.append("Summary: \(summary)")
        }
        lines.append(
            "Open in Ohia: \(OhiaDeepLink.messageURL(entry.sourceMessageID).absoluteString)"
        )
        return lines.joined(separator: "\n")
    }

    /// The message's existing LLM-generated body summary, if one has already
    /// been produced (hover-on-demand or automatic new-mail summarization).
    /// Never generates one here — a missing summary simply means the note
    /// omits that line. Embedded newlines are collapsed to spaces: this text
    /// becomes a single line in a managed event's notes, and callers rely on
    /// each note line either being ordinary prose or one of the bracketed
    /// `[ohia-meeting-*]` / `[ohia-deadline:*]` machine tags — a multi-line
    /// summary could otherwise inject a spurious line into that scan (e.g.
    /// `MeetingCalendarDuplicatePolicy.markerValue`, which reads tag values
    /// by line prefix/suffix regardless of source).
    private func existingBodySummary(for messageID: UUID) -> String? {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == messageID })
        descriptor.fetchLimit = 1
        guard let summary = (try? modelContext.fetch(descriptor))?.first?.analysis?.bodySummary else {
            return nil
        }
        let collapsed = summary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private func meetingSourceState(
        for entry: MeetingEntry,
        defaultLeadTime: DeadlineReminderLeadTime,
        reminderHour: Int
    ) -> MeetingCalendarEventState {
        let start = entry.startDate
        let alarms = defaultLeadTime.alarmDate(
            deadlineDate: start,
            granularity: .dateTime,
            reminderHour: reminderHour
        ).map { [DeadlineCalendarAlarmDescriptor.absolute($0)] } ?? []
        return MeetingCalendarEventState(
            title: entry.title.isEmpty ? "Meeting" : entry.title,
            startDate: start,
            endDate: max(entry.endDate, start.addingTimeInterval(60)),
            location: entry.location,
            onlineMeetingURL: entry.onlineMeetingURL,
            alarms: alarms
        )
    }

    private func effectiveMeetingState(
        for entry: MeetingEntry,
        record: MeetingCalendarRecord?,
        defaultLeadTime: DeadlineReminderLeadTime,
        reminderHour: Int
    ) -> MeetingCalendarEventState {
        if let record,
           record.calendarOverrideImportedAt != nil,
           let title = record.overrideTitle,
           let start = record.overrideStartAt,
           let end = record.overrideEndAt {
            return MeetingCalendarEventState(
                title: title,
                startDate: start,
                endDate: end,
                location: record.overrideLocation,
                onlineMeetingURL: record.overrideOnlineMeetingURLString.flatMap(URL.init(string:)),
                alarms: decodeAlarms(record.overrideAlarmsData) ?? []
            )
        }
        return meetingSourceState(
            for: entry,
            defaultLeadTime: defaultLeadTime,
            reminderHour: reminderHour
        )
    }

    private func meetingCalendarEventState(
        _ event: EKEvent
    ) -> MeetingCalendarEventState {
        let start = event.startDate ?? .distantPast
        return MeetingCalendarEventState(
            title: event.title ?? "",
            startDate: start,
            endDate: max(
                event.endDate ?? start,
                start.addingTimeInterval(60)
            ),
            location: event.location,
            onlineMeetingURL: OnlineMeetingURL.normalized(event.url),
            alarms: (event.alarms ?? []).map { alarm in
                if let absoluteDate = alarm.absoluteDate {
                    return .absolute(absoluteDate)
                }
                return .relative(alarm.relativeOffset)
            }
        )
    }

    private func importMeetingCalendarChanges(
        entriesByID: [String: MeetingEntry],
        records: [MeetingCalendarRecord],
        candidateEvents: [EKEvent],
        calendar: EKCalendar,
        defaultLeadTime: DeadlineReminderLeadTime,
        reminderHour: Int
    ) throws {
        for record in records where record.calendarSyncSuppressedAt == nil {
            guard record.eventIdentifier != nil
                    || record.eventExternalIdentifier != nil else {
                continue
            }
            let entry = entriesByID[record.entryID]
            guard let event = findOwnedMeetingEvent(
                for: record,
                candidates: candidateEvents,
                calendar: calendar
            ) else {
                record.calendarSyncSuppressedAt = .now
                clearMeetingEventLink(record)
                record.updatedAt = .now
                continue
            }

            let eventState = meetingCalendarEventState(event)
            let untouched = isUntouchedOwnedMeeting(
                event,
                entryID: record.entryID
            )
            let action: MeetingCalendarImportAction
            if let entry {
                let sourceState = meetingSourceState(
                    for: entry,
                    defaultLeadTime: defaultLeadTime,
                    reminderHour: reminderHour
                )
                let baseline = meetingBaselineState(record) ?? sourceState
                if meetingBaselineState(record) == nil {
                    action = eventState == sourceState && untouched
                        ? .unchanged
                        : .override(eventState)
                } else {
                    action = MeetingCalendarChangePolicy.importedChange(
                        event: eventState,
                        baseline: baseline,
                        source: sourceState,
                        eventMatchesManagedFingerprint: untouched,
                        hasCalendarOverride: record.calendarOverrideImportedAt != nil
                    )
                }
            } else if let baseline = meetingBaselineState(record) {
                action = MeetingCalendarChangePolicy.importedChangeWithoutSource(
                    event: eventState,
                    baseline: baseline,
                    eventMatchesManagedFingerprint: untouched
                )
            } else {
                action = untouched ? .unchanged : .override(eventState)
            }
            applyMeetingImport(action, to: record)
            recordMeetingSyncedState(
                eventState,
                event: event,
                sourceUpdatedAt: entry?.sourceUpdatedAt
                    ?? record.sourceUpdatedAt
                    ?? .distantPast,
                record: record
            )
        }
    }

    private func meetingBaselineState(
        _ record: MeetingCalendarRecord
    ) -> MeetingCalendarEventState? {
        guard let title = record.syncedTitle,
              let start = record.syncedStartAt,
              let end = record.syncedEndAt else {
            return nil
        }
        return MeetingCalendarEventState(
            title: title,
            startDate: start,
            endDate: end,
            location: record.syncedLocation,
            onlineMeetingURL: record.syncedOnlineMeetingURLString.flatMap(URL.init(string:)),
            alarms: decodeAlarms(record.syncedAlarmsData) ?? []
        )
    }

    private func applyMeetingImport(
        _ action: MeetingCalendarImportAction,
        to record: MeetingCalendarRecord
    ) {
        switch action {
        case .unchanged:
            break
        case .restoreEmailEvidence:
            clearMeetingOverride(record)
        case .override(let state):
            record.calendarOverrideImportedAt = .now
            record.overrideTitle = state.title
            record.overrideStartAt = state.startDate
            record.overrideEndAt = state.endDate
            record.overrideLocation = state.location
            record.overrideOnlineMeetingURLString = state.onlineMeetingURL?.absoluteString
            record.overrideAlarmsData = encodeAlarms(state.alarms)
        }
        record.updatedAt = .now
    }

    private func clearMeetingOverride(_ record: MeetingCalendarRecord) {
        record.calendarOverrideImportedAt = nil
        record.overrideTitle = nil
        record.overrideStartAt = nil
        record.overrideEndAt = nil
        record.overrideLocation = nil
        record.overrideOnlineMeetingURLString = nil
        record.overrideAlarmsData = nil
    }

    private func recordMeetingSyncedState(
        _ state: MeetingCalendarEventState,
        event: EKEvent,
        sourceUpdatedAt: Date,
        record: MeetingCalendarRecord
    ) {
        record.eventIdentifier = event.calendarItemIdentifier
        record.eventExternalIdentifier = event.calendarItemExternalIdentifier
        record.syncedTitle = state.title
        record.syncedStartAt = state.startDate
        record.syncedEndAt = state.endDate
        record.syncedLocation = state.location
        record.syncedOnlineMeetingURLString = state.onlineMeetingURL?.absoluteString
        record.syncedAlarmsData = encodeAlarms(state.alarms)
        record.sourceUpdatedAt = sourceUpdatedAt
        record.calendarSyncSuppressedAt = nil
        record.updatedAt = .now
    }

    private func isUntouchedOwnedMeeting(
        _ event: EKEvent,
        entryID: String
    ) -> Bool {
        guard event.notes?.contains(
            MeetingCalendarDuplicatePolicy.marker(entryID: entryID)
        ) == true,
        let syncedFingerprint = MeetingCalendarDuplicatePolicy.markerValue(
            prefix: MeetingCalendarDuplicatePolicy.fingerprintPrefix,
            notes: event.notes
        ) else {
            return false
        }
        let currentFingerprint = MeetingCalendarDuplicatePolicy.eventFingerprint(
            title: event.title ?? "",
            startDate: event.startDate ?? .distantPast,
            endDate: event.endDate ?? .distantPast,
            location: event.location,
            onlineMeetingURL: event.url,
            alarms: (event.alarms ?? []).map { alarm in
                if let absoluteDate = alarm.absoluteDate {
                    return .absolute(absoluteDate)
                }
                return .relative(alarm.relativeOffset)
            },
            notes: event.notes
        )
        return currentFingerprint == syncedFingerprint
    }

    private func removeMeetingEvent(_ event: EKEvent, entryID: String) throws {
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            Self.logger.error(
                "Meeting cancellation failed for \(entryID, privacy: .private): \(String(reflecting: type(of: error)), privacy: .public)"
            )
            throw DeadlineCalendarSyncError.eventRemoveFailed(error.localizedDescription)
        }
    }

    private func meetingEventCandidates(
        for entries: [MeetingEntry],
        recoveryDates: [Date]
    ) -> [EKEvent] {
        var byIdentifier: [String: EKEvent] = [:]
        func include(_ event: EKEvent) {
            byIdentifier[event.calendarItemIdentifier] = event
        }

        for externalIdentifier in Set(entries.compactMap(\.externalIdentifier)) {
            store.calendarItems(withExternalIdentifier: externalIdentifier)
                .compactMap { $0 as? EKEvent }
                .forEach(include)
        }

        let systemCalendar = Foundation.Calendar.autoupdatingCurrent
        let queryWindows = DeadlineCalendarOwnershipPolicy.eventQueryWindows(
            recoveryDates: recoveryDates,
            calendar: systemCalendar
        )
        for window in queryWindows {
            let predicate = store.predicateForEvents(
                withStart: window.start,
                end: window.end,
                calendars: nil
            )
            store.events(matching: predicate).forEach(include)
        }
        return Array(byIdentifier.values)
    }

    private func ownedMeetingEvent(
        matching entry: MeetingEntry,
        record: MeetingCalendarRecord?,
        candidates: [EKEvent],
        calendar: EKCalendar
    ) -> EKEvent? {
        if let record,
           let event = findOwnedMeetingEvent(
               for: record,
               candidates: candidates,
               calendar: calendar
           ) {
            return event
        }
        let exactMarker = MeetingCalendarDuplicatePolicy.marker(entryID: entry.id)
        if let event = candidates.first(where: {
            $0.calendar.calendarIdentifier == calendar.calendarIdentifier
                && $0.notes?.contains(exactMarker) == true
        }) {
            return event
        }
        guard entry.source == .calendarInvitation,
              let threadID = entry.threadID else {
            return nil
        }
        let threadMarker = MeetingCalendarDuplicatePolicy.threadMarker(threadID: threadID)
        return candidates.first {
            $0.calendar.calendarIdentifier == calendar.calendarIdentifier
                && $0.notes?.contains(threadMarker) == true
                && MeetingCalendarDuplicatePolicy.markerValue(
                    prefix: MeetingCalendarDuplicatePolicy.kindPrefix,
                    notes: $0.notes
                ) == "body"
        }
    }

    private func findOwnedMeetingEvent(
        for record: MeetingCalendarRecord,
        candidates: [EKEvent],
        calendar: EKCalendar
    ) -> EKEvent? {
        if let identifier = record.eventIdentifier,
           let event = (store.calendarItem(withIdentifier: identifier) as? EKEvent)
                ?? store.event(withIdentifier: identifier),
           event.calendar.calendarIdentifier == calendar.calendarIdentifier {
            return event
        }
        if let externalIdentifier = record.eventExternalIdentifier,
           let event = store.calendarItems(withExternalIdentifier: externalIdentifier)
                .compactMap({ $0 as? EKEvent })
                .first(where: {
                    $0.calendar.calendarIdentifier == calendar.calendarIdentifier
                }) {
            return event
        }
        let marker = MeetingCalendarDuplicatePolicy.marker(entryID: record.entryID)
        return candidates.first {
            $0.calendar.calendarIdentifier == calendar.calendarIdentifier
                && $0.notes?.contains(marker) == true
        }
    }

    private func meetingEventCandidate(_ event: EKEvent) -> MeetingCalendarEventCandidate {
        let textURL = event.notes.flatMap(OnlineMeetingURL.firstRecognized)
            ?? event.location.flatMap(OnlineMeetingURL.firstRecognized)
        return MeetingCalendarEventCandidate(
            identifier: event.calendarItemIdentifier,
            externalIdentifier: event.calendarItemExternalIdentifier,
            calendarIdentifier: event.calendar.calendarIdentifier,
            lastModifiedAt: event.lastModifiedDate ?? event.creationDate ?? .distantPast,
            title: event.title ?? "",
            startDate: event.startDate ?? .distantPast,
            endDate: event.endDate ?? event.startDate ?? .distantPast,
            location: event.location,
            onlineMeetingURL: OnlineMeetingURL.normalized(event.url) ?? textURL,
            notes: event.notes
        )
    }

    private func findOwnedEvent(
        for reminder: DeadlineReminder,
        calendar: EKCalendar,
        expectedDate: Date
    ) -> EKEvent? {
        if let id = reminder.eventIdentifier,
           let event = (store.calendarItem(withIdentifier: id) as? EKEvent)
                ?? store.event(withIdentifier: id),
           event.calendar.calendarIdentifier == calendar.calendarIdentifier {
            return event
        }

        if let externalID = reminder.eventExternalIdentifier,
           let event = store.calendarItems(withExternalIdentifier: externalID)
                .compactMap({ $0 as? EKEvent })
                .first(where: { $0.calendar.calendarIdentifier == calendar.calendarIdentifier }) {
            return event
        }

        let systemCalendar = Foundation.Calendar.autoupdatingCurrent
        let start = systemCalendar.date(byAdding: .year, value: -2, to: expectedDate)
            ?? expectedDate.addingTimeInterval(-63_072_000)
        let end = systemCalendar.date(byAdding: .year, value: 2, to: expectedDate)
            ?? expectedDate.addingTimeInterval(63_072_000)
        let searchCalendars = ownedEventSearchCalendars(primary: calendar)
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: searchCalendars
        )
        let marker = deadlineMarker(entryID: reminder.entryID)
        let matches = store.events(matching: predicate).filter {
            $0.notes?.contains(marker) == true
        }
        guard let preferredCalendarIdentifier = DeadlineCalendarOwnershipPolicy
            .preferredEventCalendarIdentifier(
                primaryIdentifier: calendar.calendarIdentifier,
                matchingCalendarIdentifiers: matches.map(\.calendar.calendarIdentifier)
            ) else {
            return nil
        }
        return matches.first {
            $0.calendar.calendarIdentifier == preferredCalendarIdentifier
        }
    }

    private func ownedEventSearchCalendars(primary calendar: EKCalendar) -> [EKCalendar] {
        let alternates = store.calendars(for: .event)
            .filter {
                $0.calendarIdentifier != calendar.calendarIdentifier
                    && DeadlineCalendarNamingPolicy.canonicalTitle(
                        forExistingTitle: $0.title
                    ) != nil
                    && $0.allowsContentModifications
            }
            .sorted { $0.calendarIdentifier < $1.calendarIdentifier }
        return [calendar] + alternates
    }

    private func calendarEventState(_ event: EKEvent) -> DeadlineCalendarEventState {
        let start = event.startDate ?? .distantPast
        return DeadlineCalendarEventState(
            deadlineDate: event.isAllDay
                ? Foundation.Calendar.autoupdatingCurrent.startOfDay(for: start)
                : start,
            granularity: event.isAllDay ? .dateOnly : .dateTime,
            title: event.title ?? "",
            alarms: (event.alarms ?? []).map { alarm in
                if let absoluteDate = alarm.absoluteDate {
                    return .absolute(absoluteDate)
                }
                return .relative(alarm.relativeOffset)
            }
        )
    }

    private func alarmDescriptors(
        for reminder: DeadlineReminder,
        deadlineDate: Date,
        granularity: DeadlineDateGranularity,
        reminderHour: Int
    ) -> [DeadlineCalendarAlarmDescriptor] {
        if reminder.leadTime == .calendarCustom {
            return DeadlineCalendarChangePolicy.normalizedAlarms(
                decodeAlarms(reminder.customAlarmsData) ?? []
            )
        }
        guard let alarmDate = reminder.leadTime.alarmDate(
            deadlineDate: deadlineDate,
            granularity: granularity,
            reminderHour: reminderHour
        ) else {
            return []
        }
        return [.absolute(alarmDate)]
    }

    private func eventKitAlarm(
        _ descriptor: DeadlineCalendarAlarmDescriptor
    ) -> EKAlarm {
        switch descriptor {
        case .absolute(let date):
            return EKAlarm(absoluteDate: date)
        case .relative(let offset):
            return EKAlarm(relativeOffset: offset)
        }
    }

    private func apply(
        _ imported: DeadlineCalendarImportedChange,
        to reminder: DeadlineReminder
    ) {
        switch imported.date {
        case .unchanged:
            break
        case .restoreEmailEvidence:
            reminder.overriddenDeadlineAt = nil
            reminder.overriddenGranularityRaw = nil
        case .override(let dateOverride):
            reminder.overriddenDeadlineAt = dateOverride.date
            reminder.overriddenGranularityRaw = dateOverride.granularity.rawValue
        }

        switch imported.title {
        case .unchanged:
            break
        case .restoreEmailSubject:
            reminder.calendarTitleOverride = nil
        case .override(let title):
            reminder.calendarTitleOverride = title
        }

        switch imported.alarms {
        case .unchanged:
            break
        case .named(let leadTime):
            reminder.leadTime = leadTime
            reminder.customAlarmsData = nil
        case .custom(let alarms):
            reminder.leadTime = .calendarCustom
            reminder.customAlarmsData = encodeAlarms(alarms)
        }
    }

    private func recordSyncedState(
        _ state: DeadlineCalendarEventState,
        event: EKEvent,
        reminder: DeadlineReminder
    ) {
        reminder.eventIdentifier = event.calendarItemIdentifier
        reminder.eventExternalIdentifier = event.calendarItemExternalIdentifier
        reminder.syncedDeadlineAt = state.deadlineDate
        reminder.syncedIsAllDay = state.granularity == .dateOnly
        reminder.syncedEventTitle = state.title
        reminder.syncedAlarmsData = encodeAlarms(state.alarms)
    }

    private func clearEventLink(_ reminder: DeadlineReminder) {
        reminder.eventIdentifier = nil
        reminder.eventExternalIdentifier = nil
        reminder.syncedDeadlineAt = nil
        reminder.syncedIsAllDay = nil
        reminder.syncedEventTitle = nil
        reminder.syncedAlarmsData = nil
    }

    private func eventNotes(for entry: DeadlineEntry) -> String {
        var lines = ["Tracked by Ohia."]
        if let summary = existingBodySummary(for: entry.representativeMessageID) {
            lines.append("Summary: \(summary)")
        }
        lines.append(
            "Open in Ohia: \(OhiaDeepLink.messageURL(entry.representativeMessageID).absoluteString)"
        )
        let people = entry.correspondents.prefix(4).compactMap {
            $0.displayName ?? ($0.email.isEmpty ? nil : $0.email)
        }
        if people.isEmpty == false {
            lines.append("With: " + people.joined(separator: ", "))
        }
        if entry.surfaceText.isEmpty == false {
            lines.append("Stated as: \(entry.surfaceText)")
        }
        lines.append(deadlineMarker(entryID: entry.id))
        return lines.joined(separator: "\n")
    }

    private func deadlineMarker(entryID: String) -> String {
        "\(DeadlineCalendarOwnershipPolicy.eventMarkerPrefix)\(entryID)]"
    }

    // MARK: - Calendar creation and deletion detection

    private func mergeManagedCalendars() async throws {
        let calendars = managedCalendarCandidates()
        guard calendars.isEmpty == false else {
            _ = try createCalendar()
            return
        }
        guard calendars.allSatisfy(\.allowsContentModifications) else {
            throw DeadlineCalendarSyncError.calendarReadOnly
        }

        let eventsByCalendar = try await managedCalendarEvents(in: calendars)
        let candidates = calendars.map { calendar in
            ManagedCalendarMergeCandidate(
                calendarIdentifier: calendar.calendarIdentifier,
                events: (eventsByCalendar[calendar.calendarIdentifier] ?? [:])
                    .values
                    .map { event in
                        ManagedCalendarMergeEvent(
                            eventIdentifier: event.calendarItemIdentifier,
                            ownershipMarker: managedOwnershipMarker(in: event.notes),
                            lastModifiedAt: event.lastModifiedDate
                        )
                    }
            )
        }
        guard let plan = ManagedCalendarMergePolicy.plan(
            registeredCalendarIdentifier: UserDefaults.standard.string(
                forKey: Self.calendarIdentifierKey
            ),
            calendars: candidates
        ),
        let targetCalendar = calendars.first(where: {
            $0.calendarIdentifier == plan.targetCalendarIdentifier
        }) else {
            throw DeadlineCalendarSyncError.noWritableSource
        }

        let eventsByIdentifier = eventsByCalendar.values.reduce(into: [String: EKEvent]()) {
            partialResult,
            calendarEvents in
            for (identifier, event) in calendarEvents {
                partialResult[identifier] = event
            }
        }

        do {
            for identifier in plan.eventIdentifiersToRemove {
                guard let event = eventsByIdentifier[identifier] else { continue }
                try store.remove(
                    event,
                    span: event.recurrenceRules?.isEmpty == false ? .futureEvents : .thisEvent,
                    commit: false
                )
            }
            for identifier in plan.eventIdentifiersToMove {
                guard let event = eventsByIdentifier[identifier] else { continue }
                event.calendar = targetCalendar
                try store.save(
                    event,
                    span: event.recurrenceRules?.isEmpty == false ? .futureEvents : .thisEvent,
                    commit: false
                )
            }

            targetCalendar.title = Self.calendarTitle
            try store.saveCalendar(targetCalendar, commit: false)
            for identifier in plan.calendarIdentifiersToRemove {
                guard let calendar = calendars.first(where: {
                    $0.calendarIdentifier == identifier
                }) else {
                    continue
                }
                try store.removeCalendar(calendar, commit: false)
            }
            try store.commit()
        } catch {
            store.reset()
            throw DeadlineCalendarSyncError.calendarSaveFailed(
                error.localizedDescription
            )
        }

        UserDefaults.standard.set(
            plan.targetCalendarIdentifier,
            forKey: Self.calendarIdentifierKey
        )
        do {
            try clearEventLinksAfterManagedCalendarDeletion()
        } catch {
            throw DeadlineCalendarSyncError.postCommitCleanupFailed(
                error.localizedDescription
            )
        }
        Self.logger.notice(
            "Merged \(calendars.count) detected Ohia calendars into one"
        )
    }

    private func replaceManagedCalendars() throws {
        let calendars = managedCalendarCandidates()
        guard calendars.allSatisfy(\.allowsContentModifications) else {
            throw DeadlineCalendarSyncError.calendarReadOnly
        }

        let calendarIdentifiers = calendars.map(\.calendarIdentifier)
        let replacement: EKCalendar

        do {
            replacement = try ManagedCalendarReplacementCoordinator.perform(
                stageReplacement: {
                    try stageCalendarCreation()
                },
                stageCalendarRemoval: {
                    for identifier in calendarIdentifiers {
                        guard let calendar = store.calendar(withIdentifier: identifier) else {
                            continue
                        }
                        try store.removeCalendar(calendar, commit: false)
                    }
                },
                commit: {
                    try store.commit()
                },
                rollback: {
                    store.reset()
                }
            )
        } catch let error as DeadlineCalendarSyncError {
            throw error
        } catch {
            throw DeadlineCalendarSyncError.calendarSaveFailed(
                error.localizedDescription
            )
        }

        UserDefaults.standard.set(
            replacement.calendarIdentifier,
            forKey: Self.calendarIdentifierKey
        )
        do {
            try clearEventLinksAfterManagedCalendarDeletion()
        } catch {
            throw DeadlineCalendarSyncError.postCommitCleanupFailed(
                error.localizedDescription
            )
        }
        Self.logger.notice(
            "Replaced \(calendars.count) detected Ohia calendars with a fresh calendar"
        )
    }

    private func managedCalendarCandidates() -> [EKCalendar] {
        let registeredIdentifier = UserDefaults.standard.string(
            forKey: Self.calendarIdentifierKey
        )
        return store.calendars(for: .event)
            .filter { calendar in
                calendar.calendarIdentifier == registeredIdentifier
                    || DeadlineCalendarNamingPolicy.canonicalTitle(
                        forExistingTitle: calendar.title
                    ) != nil
            }
            .sorted { $0.calendarIdentifier < $1.calendarIdentifier }
    }

    /// Calendar.app can contain user-added events inside the dedicated Ohia
    /// calendar. Merge therefore moves every EventKit event in Foundation's
    /// complete date domain, while only deduplicating events carrying Ohia's
    /// private ownership markers. Four-year windows respect EventKit's query
    /// limit and preserve recurring series by retaining their earliest fetched
    /// occurrence for a future-events move.
    private func managedCalendarEvents(
        in calendars: [EKCalendar]
    ) async throws -> [String: [String: EKEvent]] {
        var eventsByCalendar: [String: [String: EKEvent]] = [:]
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .autoupdatingCurrent
        for window in ManagedCalendarMergePolicy.eventQueryWindows(
            calendar: calendar
        ) {
            try Task.checkCancellation()
            let predicate = store.predicateForEvents(
                withStart: window.start,
                end: window.end,
                calendars: calendars
            )
            for event in store.events(matching: predicate) {
                let calendarIdentifier = event.calendar.calendarIdentifier
                let eventIdentifier = event.calendarItemIdentifier
                if let existing = eventsByCalendar[calendarIdentifier]?[eventIdentifier],
                   event.startDate >= existing.startDate {
                    continue
                } else {
                    eventsByCalendar[calendarIdentifier, default: [:]][eventIdentifier] = event
                }
            }
            await Task.yield()
        }
        return eventsByCalendar
    }

    private func managedOwnershipMarker(in notes: String?) -> String? {
        guard let notes else { return nil }
        for line in notes.split(whereSeparator: \.isNewline) {
            let marker = String(line)
            let hasOwnedPrefix = marker.hasPrefix(
                DeadlineCalendarOwnershipPolicy.eventMarkerPrefix
            ) || marker.hasPrefix(MeetingCalendarDuplicatePolicy.markerPrefix)
            if marker.hasSuffix("]"), hasOwnedPrefix {
                return marker
            }
        }
        return nil
    }

    private func ensureCalendar(recoveryDates: [Date]) throws -> EKCalendar {
        guard Self.hasWriteAccess else { throw DeadlineCalendarSyncError.permissionRequired }
        if let calendar = Self.managedCalendar(in: store) {
            guard calendar.allowsContentModifications else {
                throw DeadlineCalendarSyncError.calendarReadOnly
            }
            try normalizeManagedCalendarTitle(calendar)
            return calendar
        }
        if UserDefaults.standard.string(forKey: Self.calendarIdentifierKey) != nil {
            throw DeadlineCalendarSyncError.calendarDeleted
        }
        if let calendar = try recoverManagedCalendar(recoveryDates: recoveryDates) {
            return calendar
        }
        return try createCalendar()
    }

    /// Recovers the calendar registration after app preferences were reset.
    /// Matching by title alone could take over a user's unrelated calendar, so
    /// every candidate must prove ownership with an Ohia marker on an event.
    /// The bounded EventKit query covers the known email and last-synced dates,
    /// plus the same two-year edit allowance used by per-event recovery.
    private func recoverManagedCalendar(recoveryDates: [Date]) throws -> EKCalendar? {
        let candidates = store.calendars(for: .event).filter {
            DeadlineCalendarNamingPolicy.canonicalTitle(
                forExistingTitle: $0.title
            ) != nil && $0.allowsContentModifications
        }
        guard candidates.isEmpty == false else { return nil }

        let systemCalendar = Foundation.Calendar.autoupdatingCurrent
        let queryWindows = DeadlineCalendarOwnershipPolicy.eventQueryWindows(
            recoveryDates: recoveryDates,
            calendar: systemCalendar
        )

        let evidence = candidates.map { calendar in
            let ownedEventIdentifiers = queryWindows.reduce(into: Set<String>()) { identifiers, window in
                let predicate = store.predicateForEvents(
                    withStart: window.start,
                    end: window.end,
                    calendars: [calendar]
                )
                for event in store.events(matching: predicate)
                where DeadlineCalendarOwnershipPolicy.containsOwnedEventMarker(event.notes) {
                    identifiers.insert(event.calendarItemIdentifier)
                }
            }
            return DeadlineCalendarOwnershipCandidate(
                calendarIdentifier: calendar.calendarIdentifier,
                ownedEventCount: ownedEventIdentifiers.count
            )
        }
        guard let identifier = DeadlineCalendarOwnershipPolicy
            .recoverableCalendarIdentifier(from: evidence),
              let calendar = candidates.first(where: {
                  $0.calendarIdentifier == identifier
              }) else {
            return nil
        }

        UserDefaults.standard.set(identifier, forKey: Self.calendarIdentifierKey)
        try normalizeManagedCalendarTitle(calendar)
        Self.logger.notice("Recovered managed Ohia calendar registration")
        return calendar
    }

    private func existingCalendarOrDeletionError() throws -> EKCalendar {
        guard Self.hasWriteAccess else { throw DeadlineCalendarSyncError.permissionRequired }
        if let calendar = Self.managedCalendar(in: store) {
            guard calendar.allowsContentModifications else {
                throw DeadlineCalendarSyncError.calendarReadOnly
            }
            try normalizeManagedCalendarTitle(calendar)
            return calendar
        }
        if UserDefaults.standard.string(forKey: Self.calendarIdentifierKey) != nil {
            throw DeadlineCalendarSyncError.calendarDeleted
        }
        throw DeadlineCalendarSyncError.noWritableSource
    }

    /// Normal ownership lookup remains exact-identifier only. The guarded
    /// recovery path above is used only when no registration exists and proves
    /// ownership from an Ohia marker before persisting a replacement identifier.
    private static func managedCalendar(in eventStore: EKEventStore) -> EKCalendar? {
        guard let stored = UserDefaults.standard.string(forKey: calendarIdentifierKey) else {
            return nil
        }
        return eventStore.calendar(withIdentifier: stored)
    }

    private func createCalendar() throws -> EKCalendar {
        let sources = candidateSources()
        guard sources.isEmpty == false else {
            throw DeadlineCalendarSyncError.noWritableSource
        }

        var lastError: Error?
        for source in sources {
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = Self.calendarTitle
            calendar.cgColor = NSColor(
                srgbRed: 0x70 / 255.0,
                green: 0xB8 / 255.0,
                blue: 0x18 / 255.0,
                alpha: 1
            ).cgColor
            calendar.source = source
            do {
                try store.saveCalendar(calendar, commit: true)
                UserDefaults.standard.set(
                    calendar.calendarIdentifier,
                    forKey: Self.calendarIdentifierKey
                )
                Self.logger.notice("Created Ohia calendar in source \(source.title, privacy: .private)")
                return calendar
            } catch {
                lastError = error
                Self.logger.warning("Calendar source rejected creation: \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }

        if let lastError {
            throw DeadlineCalendarSyncError.calendarSaveFailed(lastError.localizedDescription)
        }
        throw DeadlineCalendarSyncError.noWritableSource
    }

    /// Stages a fresh calendar without committing so Replace can atomically
    /// create the replacement and remove all prior Ohia calendars. A failed
    /// source attempt is reset before the next source is fetched because
    /// `EKEventStore.reset()` invalidates previously returned EventKit objects.
    private func stageCalendarCreation() throws -> EKCalendar {
        let sourceIdentifiers = candidateSources().map(\.sourceIdentifier)
        guard sourceIdentifiers.isEmpty == false else {
            throw DeadlineCalendarSyncError.noWritableSource
        }

        var lastError: Error?
        for sourceIdentifier in sourceIdentifiers {
            guard let source = store.sources.first(where: {
                $0.sourceIdentifier == sourceIdentifier
            }) else {
                continue
            }
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = Self.calendarTitle
            calendar.cgColor = NSColor(
                srgbRed: 0x70 / 255.0,
                green: 0xB8 / 255.0,
                blue: 0x18 / 255.0,
                alpha: 1
            ).cgColor
            calendar.source = source
            do {
                try store.saveCalendar(calendar, commit: false)
                return calendar
            } catch {
                lastError = error
                store.reset()
                Self.logger.warning(
                    "Calendar source rejected staged creation: \(String(reflecting: type(of: error)), privacy: .public)"
                )
            }
        }

        if let lastError {
            throw DeadlineCalendarSyncError.calendarSaveFailed(
                lastError.localizedDescription
            )
        }
        throw DeadlineCalendarSyncError.noWritableSource
    }

    private func normalizeManagedCalendarTitle(_ calendar: EKCalendar) throws {
        guard calendar.title != Self.calendarTitle else { return }
        calendar.title = Self.calendarTitle
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            Self.logger.error(
                "Calendar rename failed: \(String(reflecting: type(of: error)), privacy: .public)"
            )
            throw DeadlineCalendarSyncError.calendarSaveFailed(
                error.localizedDescription
            )
        }
    }

    /// EventKit exposes no "can create calendars" flag on `EKSource`. Try the
    /// user's default event source first, then each plausible writable account,
    /// skipping subscribed, birthday, and delegated sources. A rejected source
    /// is not fatal while another candidate remains.
    private func candidateSources() -> [EKSource] {
        let defaultSource = store.defaultCalendarForNewEvents?.source
        let candidates = [defaultSource].compactMap { $0 } + store.sources.filter {
            $0.isDelegate == false
                && $0.sourceType != .subscribed
                && $0.sourceType != .birthdays
        }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.sourceIdentifier).inserted }
    }

    private func calendarRecoveryDates(
        entries: [DeadlineEntry],
        reminders: [DeadlineReminder]
    ) -> [Date] {
        entries.map(\.deadlineDate)
            + reminders.compactMap(\.syncedDeadlineAt)
            + reminders.compactMap(\.overriddenDeadlineAt)
    }

    // MARK: - Store access

    private func fetchReminders() throws -> [DeadlineReminder] {
        do {
            return try modelContext.fetch(FetchDescriptor<DeadlineReminder>())
        } catch {
            throw DeadlineCalendarSyncError.persistenceFailed(error.localizedDescription)
        }
    }

    private func fetchReminder(entryID: String) throws -> DeadlineReminder? {
        var descriptor = FetchDescriptor<DeadlineReminder>(
            predicate: #Predicate { $0.entryID == entryID }
        )
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            throw DeadlineCalendarSyncError.persistenceFailed(error.localizedDescription)
        }
    }

    private func makeReminder(
        entryID: String,
        leadTime: DeadlineReminderLeadTime
    ) -> DeadlineReminder {
        let reminder = DeadlineReminder(entryID: entryID, leadTimeRaw: leadTime.rawValue)
        modelContext.insert(reminder)
        return reminder
    }

    private func fetchMeetingRecords() throws -> [MeetingCalendarRecord] {
        do {
            return try modelContext.fetch(FetchDescriptor<MeetingCalendarRecord>())
        } catch {
            throw DeadlineCalendarSyncError.persistenceFailed(error.localizedDescription)
        }
    }

    private func makeMeetingRecord(entryID: String) -> MeetingCalendarRecord {
        let record = MeetingCalendarRecord(entryID: entryID)
        modelContext.insert(record)
        return record
    }

    private func transferMeetingRecord(
        _ previous: MeetingCalendarRecord?,
        existingTarget: MeetingCalendarRecord?,
        toEntryID entryID: String
    ) -> MeetingCalendarRecord {
        if let existingTarget {
            if let previous,
               previous !== existingTarget {
                clearMeetingEventLink(previous)
                modelContext.delete(previous)
            }
            return existingTarget
        }
        if let previous {
            previous.entryID = entryID
            previous.updatedAt = .now
            return previous
        }
        return makeMeetingRecord(entryID: entryID)
    }

    private func clearMeetingEventLink(_ record: MeetingCalendarRecord) {
        record.eventIdentifier = nil
        record.eventExternalIdentifier = nil
        record.syncedTitle = nil
        record.syncedStartAt = nil
        record.syncedEndAt = nil
        record.syncedLocation = nil
        record.syncedOnlineMeetingURLString = nil
        record.syncedAlarmsData = nil
    }

    private func deadlineOverride(for reminder: DeadlineReminder) -> DeadlineDateOverride? {
        guard let date = reminder.overriddenDeadlineAt,
              let raw = reminder.overriddenGranularityRaw,
              let granularity = DeadlineDateGranularity(rawValue: raw) else {
            return nil
        }
        return DeadlineDateOverride(date: date, granularity: granularity)
    }

    private func saveModelContext() throws {
        do {
            try modelContext.save()
        } catch {
            throw DeadlineCalendarSyncError.persistenceFailed(error.localizedDescription)
        }
    }

    private func encodeAlarms(_ alarms: [DeadlineCalendarAlarmDescriptor]) -> Data? {
        try? PropertyListEncoder().encode(
            DeadlineCalendarChangePolicy.normalizedAlarms(alarms)
        )
    }

    private func decodeAlarms(_ data: Data?) -> [DeadlineCalendarAlarmDescriptor]? {
        guard let data else { return nil }
        return try? PropertyListDecoder().decode(
            [DeadlineCalendarAlarmDescriptor].self,
            from: data
        )
    }
}
