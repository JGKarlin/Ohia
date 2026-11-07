import Foundation

public enum WithheldAutoDeleteSchedule: String, CaseIterable, Identifiable, Sendable, Codable {
    case off
    case sevenDays
    case thirtyDays
    case ninetyDays
    case oneYear

    public var id: String { rawValue }

    public static let defaultSchedule: WithheldAutoDeleteSchedule = .off
    public static let runCadence: TimeInterval = 24 * 60 * 60

    public var title: String {
        switch self {
        case .off: return "Never"
        case .sevenDays: return "After 7 days"
        case .thirtyDays: return "After 30 days"
        case .ninetyDays: return "After 90 days"
        case .oneYear: return "After 1 year"
        }
    }

    public var retentionDays: Int? {
        switch self {
        case .off: return nil
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        case .oneYear: return 365
        }
    }

    public func cutoffDate(
        anchoredAt anchor: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let retentionDays else { return nil }
        return calendar.date(byAdding: .day, value: -retentionDays, to: anchor)
    }

    public func isDue(lastRunAt: Date?, now: Date) -> Bool {
        guard self != .off else { return false }
        guard let lastRunAt else { return true }
        return now.timeIntervalSince(lastRunAt) >= Self.runCadence
    }
}
