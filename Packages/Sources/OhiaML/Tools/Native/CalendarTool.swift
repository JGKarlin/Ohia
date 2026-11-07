import Foundation
import EventKit

public final class CalendarTool: AgentTool, @unchecked Sendable {
    public let name = "calendar"
    public let toolDescription = "Check calendar availability, find events, detect scheduling conflicts"

    private let eventStore = EKEventStore()

    public init() {}

    public func execute(query: String, context: ToolContext) throws -> ToolResult {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            return ToolResult(findings: [Finding(
                text: "Calendar access not granted — enable in System Settings > Privacy & Security > Calendar",
                confidence: 0.0
            )])
        }

        let (startDate, endDate) = parseDateRange(from: query)
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let events = eventStore.events(matching: predicate)

        if events.isEmpty {
            return ToolResult(findings: [Finding(
                text: "No events found between \(formatDate(startDate)) and \(formatDate(endDate))",
                confidence: 0.9
            )])
        }

        let findings = events.map { event -> Finding in
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            var text = "\(df.string(from: event.startDate)) — \(df.string(from: event.endDate)): \(event.title ?? "(no title)")"
            if let location = event.location, !location.isEmpty { text += " @ \(location)" }
            return Finding(text: text, confidence: 0.95)
        }
        return ToolResult(findings: findings)
    }

    private func parseDateRange(from query: String) -> (Date, Date) {
        let lower = query.lowercased()
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)

        if lower.contains("today") { return (start, cal.date(byAdding: .day, value: 1, to: start)!) }
        if lower.contains("tomorrow") {
            let s = cal.date(byAdding: .day, value: 1, to: start)!
            return (s, cal.date(byAdding: .day, value: 1, to: s)!)
        }
        if lower.contains("this week") || lower.contains("week") { return (start, cal.date(byAdding: .day, value: 7, to: start)!) }
        return (start, cal.date(byAdding: .day, value: 7, to: start)!)
    }

    private func formatDate(_ date: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none; return df.string(from: date)
    }
}
