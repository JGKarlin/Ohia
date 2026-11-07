import Foundation

/// Parses LLM-extracted deadline strings into concrete `Date` values.
///
/// Locale-neutral by design: only ISO 8601 full-date strings (e.g.
/// `"2026-05-21"` or `"2026-05-21T15:00:00Z"`) and ISO-equivalent numeric
/// variants are accepted. Named-month formats (`MMM d yyyy`) and
/// region-ambiguous numeric layouts (`MM/dd/yyyy` vs `dd/MM/yyyy`) are
/// deliberately rejected — they fail silently for non-English mail, and
/// the plan's deadline-tick policy requires a parseable concrete date.
public enum ProjectDeadlineDateParser {
    private static let isoNumericFormats = [
        "yyyy-MM-dd",
        "yyyy/MM/dd"
    ]

    public static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isoFullDate = ISO8601DateFormatter()
        isoFullDate.formatOptions = [.withFullDate]
        if let date = isoFullDate.date(from: trimmed) { return date }

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime]
        if let date = isoFull.date(from: trimmed) { return date }

        for format in isoNumericFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}
