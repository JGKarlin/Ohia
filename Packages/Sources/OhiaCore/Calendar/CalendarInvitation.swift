import Foundation

/// A timed VEVENT carried by an email's `text/calendar` MIME part.
///
/// Calendar invitations are deterministic source evidence and therefore rank
/// above meeting details inferred from prose. All-day VEVENTs are deliberately
/// excluded because Ohia's meeting sync requires a distinct start time.
public struct CalendarInvitation: Codable, Sendable, Equatable {
    public let uid: String
    public let recurrenceIdentifier: String?
    public let sequence: Int
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let location: String?
    public let onlineMeetingURL: URL?
    public let sourceUpdatedAt: Date
    public let isCancelled: Bool

    public init(
        uid: String,
        recurrenceIdentifier: String? = nil,
        sequence: Int = 0,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        onlineMeetingURL: URL? = nil,
        sourceUpdatedAt: Date = .distantPast,
        isCancelled: Bool
    ) {
        self.uid = uid
        self.recurrenceIdentifier = recurrenceIdentifier
        self.sequence = sequence
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.onlineMeetingURL = onlineMeetingURL
        self.sourceUpdatedAt = sourceUpdatedAt
        self.isCancelled = isCancelled
    }

    public var identity: String {
        if let recurrenceIdentifier, recurrenceIdentifier.isEmpty == false {
            return "\(uid)#\(recurrenceIdentifier)"
        }
        return uid
    }
}

/// Conservative recognition and normalization of URLs used to join online
/// meetings. Ordinary links in a meeting email are intentionally ignored.
public enum OnlineMeetingURL {
    private static let recognizedHosts = [
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
        "gotomeeting.com",
        "meet.goto.com",
        "whereby.com",
        "meet.jit.si",
    ]

    public static func normalized(_ url: URL?) -> URL? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              isRecognizedHost(host) else {
            return nil
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        components?.host = host
        components?.fragment = nil
        return components?.url
    }

    public static func firstRecognized(in text: String) -> URL? {
        let pattern = #"https?://[^\s<>"']+"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let raw = String(text[matchRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)\\"))
            if let normalized = normalized(URL(string: raw)) {
                return normalized
            }
        }
        return nil
    }

    public static func identity(_ url: URL?) -> String? {
        guard let normalized = normalized(url),
              var components = URLComponents(
                  url: normalized,
                  resolvingAgainstBaseURL: false
              ) else {
            return nil
        }
        components.query = nil
        var value = components.string?.lowercased()
        while value?.hasSuffix("/") == true {
            value?.removeLast()
        }
        return value
    }

    private static func isRecognizedHost(_ host: String) -> Bool {
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            return true
        }
        return recognizedHosts.contains { candidate in
            host == candidate || host.hasSuffix(".\(candidate)")
        }
    }
}

public enum CalendarInvitationParser {
    private struct Property {
        let name: String
        let parameters: [String: String]
        let value: String
    }

    public static func parse(
        _ data: Data,
        defaultTimeZone: TimeZone = .autoupdatingCurrent
    ) -> [CalendarInvitation] {
        guard let text = decodedText(data) else { return [] }
        let lines = unfoldedLines(text)
        let calendarMethod = lines
            .compactMap(parseProperty)
            .first(where: { $0.name == "METHOD" })?
            .value
            .uppercased()

        var events: [[Property]] = []
        var current: [Property]?
        for line in lines {
            guard let property = parseProperty(line) else { continue }
            if property.name == "BEGIN", property.value.uppercased() == "VEVENT" {
                current = []
            } else if property.name == "END", property.value.uppercased() == "VEVENT" {
                if let current {
                    events.append(current)
                }
                current = nil
            } else if current != nil {
                current?.append(property)
            }
        }

        return events.compactMap {
            invitation(
                from: $0,
                calendarMethod: calendarMethod,
                defaultTimeZone: defaultTimeZone
            )
        }
    }

    private static func invitation(
        from properties: [Property],
        calendarMethod: String?,
        defaultTimeZone: TimeZone
    ) -> CalendarInvitation? {
        func property(_ name: String) -> Property? {
            properties.first { $0.name == name }
        }

        guard let uid = property("UID").map({ decodedTextValue($0.value) }),
              uid.isEmpty == false,
              let startProperty = property("DTSTART"),
              startProperty.parameters["VALUE"]?.uppercased() != "DATE",
              let startDate = date(
                  from: startProperty,
                  defaultTimeZone: defaultTimeZone
              ) else {
            return nil
        }
        let endDate = property("DTEND")
            .flatMap { date(from: $0, defaultTimeZone: defaultTimeZone) }
            ?? startDate.addingTimeInterval(3_600)
        let title = property("SUMMARY")
            .map { decodedTextValue($0.value) }
            .flatMap(nonEmpty)
            ?? "Meeting"
        let location = property("LOCATION")
            .map { decodedTextValue($0.value) }
            .flatMap(nonEmpty)

        let explicitURL = property("URL")
            .flatMap { OnlineMeetingURL.normalized(URL(string: $0.value)) }
        let onlineURL = explicitURL
            ?? location.flatMap(OnlineMeetingURL.firstRecognized)
            ?? property("DESCRIPTION")
                .map { decodedTextValue($0.value) }
                .flatMap(OnlineMeetingURL.firstRecognized)

        let lastModified = property("LAST-MODIFIED")
            .flatMap { date(from: $0, defaultTimeZone: defaultTimeZone) }
        let dateStamp = property("DTSTAMP")
            .flatMap { date(from: $0, defaultTimeZone: defaultTimeZone) }
        let created = property("CREATED")
            .flatMap { date(from: $0, defaultTimeZone: defaultTimeZone) }
        let status = property("STATUS")?.value.uppercased()
        let recurrenceIdentifier = property("RECURRENCE-ID").map {
            "\($0.parameters.sorted { $0.key < $1.key })|\($0.value)"
        }

        return CalendarInvitation(
            uid: uid,
            recurrenceIdentifier: recurrenceIdentifier,
            sequence: Int(property("SEQUENCE")?.value ?? "") ?? 0,
            title: title,
            startDate: startDate,
            endDate: max(endDate, startDate.addingTimeInterval(60)),
            location: location,
            onlineMeetingURL: onlineURL,
            sourceUpdatedAt: lastModified ?? dateStamp ?? created ?? .distantPast,
            isCancelled: calendarMethod == "CANCEL" || status == "CANCELLED"
        )
    }

    private static func parseProperty(_ line: String) -> Property? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let declaration = line[..<separator]
        let value = String(line[line.index(after: separator)...])
        let parts = declaration.split(separator: ";", omittingEmptySubsequences: false)
        guard let rawName = parts.first else { return nil }

        var parameters: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = part[..<equals].uppercased()
            let value = part[part.index(after: equals)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            parameters[key] = value
        }
        return Property(
            name: rawName.uppercased(),
            parameters: parameters,
            value: value
        )
    }

    private static func date(
        from property: Property,
        defaultTimeZone: TimeZone
    ) -> Date? {
        let raw = property.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUTC = raw.hasSuffix("Z")
        let timeZone: TimeZone = {
            if isUTC {
                return TimeZone(secondsFromGMT: 0)!
            }
            if let identifier = property.parameters["TZID"],
               let zone = TimeZone(identifier: identifier) {
                return zone
            }
            return defaultTimeZone
        }()

        for format in isUTC
            ? ["yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmm'Z'"]
            : ["yyyyMMdd'T'HHmmss", "yyyyMMdd'T'HHmm"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            if let parsed = formatter.date(from: raw) {
                return parsed
            }
        }
        return nil
    }

    private static func unfoldedLines(_ text: String) -> [String] {
        let physical = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var logical: [String] = []
        for line in physical {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if logical.isEmpty == false {
                    logical[logical.count - 1] += line.dropFirst()
                }
            } else {
                logical.append(line)
            }
        }
        return logical
    }

    private static func decodedText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func decodedTextValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
