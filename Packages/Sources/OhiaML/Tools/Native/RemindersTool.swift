import Foundation
import EventKit

public final class RemindersTool: AgentTool, @unchecked Sendable {
    public let name = "reminders"
    public let toolDescription = "Create follow-up reminders from email tasks with optional due dates"

    private let eventStore = EKEventStore()

    public init() {}

    public func execute(query: String, context: ToolContext) throws -> ToolResult {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .fullAccess || status == .writeOnly else {
            return ToolResult(findings: [Finding(
                text: "Reminders access not granted — enable in System Settings > Privacy & Security > Reminders",
                confidence: 0.0
            )])
        }

        guard let defaultCalendar = eventStore.defaultCalendarForNewReminders() else {
            return ToolResult(findings: [Finding(text: "No default reminder list available", confidence: 0.0)])
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = query
        reminder.calendar = defaultCalendar

        if let dueDate = extractDueDate(from: query) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        }

        do {
            try eventStore.save(reminder, commit: true)
            var text = "Reminder created: \(query)"
            if let due = reminder.dueDateComponents, let month = due.month, let day = due.day {
                text += " (due: \(month)/\(day))"
            }
            return ToolResult(findings: [Finding(text: text, confidence: 1.0)])
        } catch {
            return ToolResult(findings: [Finding(text: "Failed to create reminder: \(error.localizedDescription)", confidence: 0.0)])
        }
    }

    private func extractDueDate(from query: String) -> Date? {
        let lower = query.lowercased()
        let now = Date()
        let cal = Calendar.current

        if lower.contains("tomorrow") { return cal.date(byAdding: .day, value: 1, to: now) }
        if lower.contains("next week") { return cal.date(byAdding: .day, value: 7, to: now) }
        if lower.contains("friday") { return nextWeekday(6, from: now) }
        if lower.contains("monday") { return nextWeekday(2, from: now) }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        if let match = detector?.firstMatch(in: lower, range: range), let date = match.date { return date }
        return nil
    }

    private func nextWeekday(_ weekday: Int, from date: Date) -> Date? {
        Calendar.current.nextDate(after: date, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime)
    }
}
