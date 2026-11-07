import Foundation

public enum HistoryIngestionPreset: String, CaseIterable, Identifiable, Sendable {
    case oneWeek = "oneWeek"
    case oneMonth = "oneMonth"
    case ninetyDays = "ninetyDays"
    case sixMonths = "sixMonths"
    case oneYear = "oneYear"
    case twoYears = "twoYears"
    case threeYears = "threeYears"
    case fiveYears = "fiveYears"
    case allTime = "allTime"

    public var id: String { rawValue }

    public static let defaultPreset: HistoryIngestionPreset = .ninetyDays

    public var title: String {
        switch self {
        case .oneWeek: return "1 week"
        case .oneMonth: return "1 month"
        case .ninetyDays: return "90 days"
        case .sixMonths: return "6 months"
        case .oneYear: return "1 year"
        case .twoYears: return "2 years"
        case .threeYears: return "3 years"
        case .fiveYears: return "5 years"
        case .allTime: return "All time"
        }
    }

    public func lowerBound(
        anchoredAt anchor: Date,
        calendar: Calendar = .current
    ) -> Date? {
        switch self {
        case .oneWeek:
            return calendar.date(byAdding: .day, value: -7, to: anchor)
        case .oneMonth:
            return calendar.date(byAdding: .month, value: -1, to: anchor)
        case .ninetyDays:
            return calendar.date(byAdding: .day, value: -90, to: anchor)
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: anchor)
        case .oneYear:
            return calendar.date(byAdding: .year, value: -1, to: anchor)
        case .twoYears:
            return calendar.date(byAdding: .year, value: -2, to: anchor)
        case .threeYears:
            return calendar.date(byAdding: .year, value: -3, to: anchor)
        case .fiveYears:
            return calendar.date(byAdding: .year, value: -5, to: anchor)
        case .allTime:
            return nil
        }
    }
}
