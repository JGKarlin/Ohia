import Foundation

/// The date span line shared by the Meaning cluster and Correspondent hover
/// cards: day precision inside one calendar year ("Mar 3 → Sep 28, 2026"),
/// month precision across years ("Mar 2019 → Sep 2026"), and a single date
/// when both ends fall on the same day.
enum HoverReadoutDateSpan {
    static func text(from first: Date, to last: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(first, inSameDayAs: last) {
            return singleDay(first)
        }
        if calendar.isDate(first, equalTo: last, toGranularity: .year) {
            let start = first.formatted(.dateTime.month(.abbreviated).day())
            let end = last.formatted(.dateTime.month(.abbreviated).day().year())
            return "\(start) → \(end)"
        }
        let start = first.formatted(.dateTime.month(.abbreviated).year())
        let end = last.formatted(.dateTime.month(.abbreviated).year())
        return "\(start) → \(end)"
    }

    static func singleDay(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
