import Foundation
import OhiaML

/// `@AppStorage` keys and defaults for the deadline reminder / Calendar.app sync
/// preferences, shared by the Deadlines view and General Settings.
enum DeadlineReminderSettings {
    static let syncEnabledKey = "deadline.calendarSyncEnabled"
    static let meetingSyncEnabledKey = "meeting.calendarSyncEnabled"
    static let defaultLeadTimeKey = "deadline.defaultReminderLeadTime"
    static let reminderHourKey = "deadline.reminderHour"

    static let defaultSyncEnabled = false
    static let defaultMeetingSyncEnabled = false
    static let defaultLeadTime = DeadlineReminderLeadTime.none
    static let defaultReminderHour = 9
}
