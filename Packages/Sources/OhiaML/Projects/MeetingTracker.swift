import Foundation
import OhiaCore

public struct ResolvedMeetingDate: Sendable, Equatable {
    public let startDate: Date
    public let endDate: Date

    public init(startDate: Date, endDate: Date) {
        self.startDate = startDate
        self.endDate = endDate
    }
}

/// Deterministically resolves only phrases that include a concrete clock
/// time. A meeting without a resolvable start is not calendar-safe and is
/// omitted rather than guessed.
public enum MeetingDateResolver {
    public static func resolve(
        _ candidate: MeetingCandidate,
        referenceDate: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ResolvedMeetingDate? {
        var resolvingCalendar = calendar
        if let identifier = candidate.timeZoneIdentifier,
           let timeZone = TimeZone(identifier: identifier)
                ?? TimeZone(abbreviation: identifier.uppercased()) {
            resolvingCalendar.timeZone = timeZone
        }
        guard let start = resolveDateTime(
            candidate.startText,
            referenceDate: referenceDate,
            calendar: resolvingCalendar
        ) else {
            return nil
        }

        let end: Date
        if let endText = candidate.endText,
           let resolvedEnd = resolveDateTime(
               endText,
               referenceDate: start,
               calendar: resolvingCalendar,
               timeOnlyBase: start
           ) {
            end = resolvedEnd > start
                ? resolvedEnd
                : resolvingCalendar.date(byAdding: .day, value: 1, to: resolvedEnd)
                    ?? start.addingTimeInterval(3_600)
        } else {
            end = start.addingTimeInterval(3_600)
        }
        return ResolvedMeetingDate(startDate: start, endDate: end)
    }

    private static func resolveDateTime(
        _ raw: String,
        referenceDate: Date,
        calendar: Calendar,
        timeOnlyBase: Date? = nil
    ) -> Date? {
        let text = normalized(raw)
        guard text.isEmpty == false else { return nil }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) {
            return date
        }

        let formats = [
            "MMMM d, yyyy 'at' h:mm a",
            "MMMM d, yyyy h:mm a",
            "MMM d, yyyy 'at' h:mm a",
            "MMM d, yyyy h:mm a",
            "yyyy-MM-dd 'at' h:mm a",
            "yyyy-MM-dd h:mm a",
            "yyyy-MM-dd HH:mm",
            "M/d/yyyy h:mm a",
            "M/d/yyyy HH:mm",
            "yyyy/M/d H:mm",
            "yyyy年M月d日 H:mm",
            "yyyy年M月d日 a h:mm",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }

        guard let clock = clockComponents(in: text) else { return nil }
        let datePart = datePart(before: clock.range, in: text)
        let day: Date
        if datePart.isEmpty, let timeOnlyBase {
            day = timeOnlyBase
        } else if let resolvedDay = DeadlineDateResolver.resolve(
            datePart,
            referenceDate: referenceDate,
            calendar: calendar
        ) {
            day = resolvedDay.date
        } else {
            return nil
        }
        return calendar.date(
            bySettingHour: clock.hour,
            minute: clock.minute,
            second: 0,
            of: day
        )
    }

    /// Matches a time range such as "4:00-6:00 pm" or "11:00 am - 1:00 pm",
    /// where a meridiem marker can sit on either end. A range's start wins
    /// when it carries its own inline marker (an "11 am - 1 pm" meeting
    /// straddles noon, so the end's "pm" must not leak backward); only when
    /// the start has no marker of its own does a shared trailing one apply —
    /// the common "4:00-6:00 pm" shorthand, where the single "pm" governs
    /// the whole range. Without this, the plain single-time scan below stops
    /// at the range's first number and never learns that a trailing "pm"
    /// was meant to cover it too.
    ///
    /// A shared trailing marker is genuinely ambiguous for the start,
    /// though: "11:00-1:00 pm" and "4:00-6:00 pm" both put the *later*
    /// number's period on the end, but only the second means the start
    /// shares it — the first means the start is 11 AM, twelve hours off from
    /// a literal "apply pm to both" reading. `inferredStartHour24` resolves
    /// that ambiguity the way a reader would: pick whichever period puts the
    /// start just before the end, rather than after it.
    private static func rangedClockComponents(
        in text: String
    ) -> (hour: Int, minute: Int, range: Range<String.Index>)? {
        let pattern = #"(?i)(午前|午後)?\s*([01]?\d|2[0-3])(?::([0-5]\d))?\s*(午前|午後|am|pm|a\.m\.|p\.m\.)?\s*[-–—]\s*([01]?\d|2[0-3])(?::[0-5]\d)?\s*(午前|午後|am|pm|a\.m\.|p\.m\.)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
        for match in matches {
            guard let wholeRange = Range(match.range(at: 0), in: text),
                  let startHourRange = Range(match.range(at: 2), in: text),
                  let startHour = Int(text[startHourRange]) else {
                continue
            }
            let minute = Range(match.range(at: 3), in: text).flatMap { Int(text[$0]) } ?? 0
            func markerText(_ group: Int) -> String? {
                Range(match.range(at: group), in: text).map {
                    text[$0].lowercased().replacingOccurrences(of: ".", with: "")
                }
            }
            func isPM(_ marker: String) -> Bool { marker == "pm" || marker == "午後" }
            func isAM(_ marker: String) -> Bool { marker == "am" || marker == "午前" }

            // A marker attached to the start itself — leading CJK prefix or
            // an inline marker right after the start time — is authoritative
            // and needs no inference.
            if let marker = markerText(1) ?? markerText(4) {
                var hour = startHour
                if isPM(marker), hour < 12 { hour += 12 }
                else if isAM(marker), hour == 12 { hour = 0 }
                return (hour, minute, wholeRange)
            }
            guard let trailingMarker = markerText(6),
                  let endHourRange = Range(match.range(at: 5), in: text),
                  let endHour = Int(text[endHourRange]) else {
                continue
            }
            let hour = inferredStartHour24(
                startHour12: startHour,
                endHour12: endHour,
                trailingMarkerIsPM: isPM(trailingMarker)
            )
            return (hour, minute, wholeRange)
        }
        return nil
    }

    /// Infers which 12-hour period an unmarked range start falls in by
    /// choosing whichever reading puts it just before the end — the PM
    /// candidate for "4:00-6:00 pm" (4 PM precedes 6 PM by 2 hours), the AM
    /// candidate for "11:00-1:00 pm" (11 PM would follow 1 PM, not precede
    /// it, so only 11 AM is a sensible same-day start). The PM candidate is
    /// always exactly 12 hours later than the AM one, so whenever it still
    /// precedes the end it's also the closer reading — there's no case
    /// where AM wins while PM also qualifies. "Neither precedes" (malformed
    /// or overnight input) falls back to applying the trailing marker
    /// directly, same as the pre-range behavior this replaces.
    private static func inferredStartHour24(
        startHour12: Int,
        endHour12: Int,
        trailingMarkerIsPM: Bool
    ) -> Int {
        let endHour24 = to24Hour(endHour12, isPM: trailingMarkerIsPM)
        let amCandidate = to24Hour(startHour12, isPM: false)
        let pmCandidate = to24Hour(startHour12, isPM: true)
        func precedes(_ candidate: Int) -> Bool { candidate <= endHour24 }

        if precedes(pmCandidate) {
            return pmCandidate
        } else if precedes(amCandidate) {
            return amCandidate
        }
        return trailingMarkerIsPM ? pmCandidate : amCandidate
    }

    /// Converts a bare 1-12 hour to 24-hour form for the given period.
    /// Values already outside 1-12 (a raw 13-23 hour written directly, e.g.
    /// "22:00") are passed through unchanged — they're already unambiguous
    /// and aren't a 12-hour-clock reading to begin with.
    private static func to24Hour(_ hour12: Int, isPM: Bool) -> Int {
        guard (1...12).contains(hour12) else { return hour12 }
        if isPM {
            return hour12 == 12 ? 12 : hour12 + 12
        }
        return hour12 == 12 ? 0 : hour12
    }

    private static func clockComponents(
        in text: String
    ) -> (hour: Int, minute: Int, range: Range<String.Index>)? {
        if let ranged = rangedClockComponents(in: text) {
            return ranged
        }
        if let cjk = unitMarkedClockComponents(
            in: text,
            pattern: #"(?:(午前|午後|上午|下午)\s*)?([01]?\d|2[0-3])\s*[時时]\s*(?:([0-5]?\d)\s*分)?"#,
            amMarkers: ["午前", "上午"],
            pmMarkers: ["午後", "下午"]
        ) {
            return cjk
        }
        if let korean = unitMarkedClockComponents(
            in: text,
            pattern: #"(?:(오전|오후)\s*)?([01]?\d|2[0-3])\s*시\s*(?:([0-5]?\d)\s*분)?"#,
            amMarkers: ["오전"],
            pmMarkers: ["오후"]
        ) {
            return korean
        }
        if let hourMarked = hourMarkedClockComponents(in: text) {
            return hourMarked
        }
        let pattern = #"(?i)(?:午前|午後)?\s*([01]?\d|2[0-3])(?::([0-5]\d))?\s*(am|pm|a\.m\.|p\.m\.)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
        for match in matches {
            guard let wholeRange = Range(match.range(at: 0), in: text),
                  let hourRange = Range(match.range(at: 1), in: text),
                  var hour = Int(text[hourRange]) else {
                continue
            }
            let minuteRange = Range(match.range(at: 2), in: text)
            let minute = minuteRange.flatMap { Int(text[$0]) } ?? 0
            let marker = Range(match.range(at: 3), in: text)
                .map { text[$0].lowercased().replacingOccurrences(of: ".", with: "") }
            let whole = String(text[wholeRange])
            let isJapanesePM = whole.contains("午後")
            let isJapaneseAM = whole.contains("午前")
            guard minuteRange != nil || marker != nil || isJapanesePM || isJapaneseAM else {
                // Bare date components such as the "20" in "2026" are not
                // evidence that a concrete meeting time was supplied.
                continue
            }
            if (marker == "pm" || isJapanesePM), hour < 12 {
                hour += 12
            } else if (marker == "am" || isJapaneseAM), hour == 12 {
                hour = 0
            }
            return (hour, minute, wholeRange)
        }
        return nil
    }

    private static func unitMarkedClockComponents(
        in text: String,
        pattern: String,
        amMarkers: Set<String>,
        pmMarkers: Set<String>
    ) -> (hour: Int, minute: Int, range: Range<String.Index>)? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        for match in expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) {
            guard let wholeRange = Range(match.range(at: 0), in: text),
                  let hourRange = Range(match.range(at: 2), in: text),
                  var hour = Int(text[hourRange]) else {
                continue
            }
            let minute = Range(match.range(at: 3), in: text)
                .flatMap { Int(text[$0]) } ?? 0
            let marker = Range(match.range(at: 1), in: text).map { String(text[$0]) }
            if let marker {
                guard (1...12).contains(hour) else { continue }
                if pmMarkers.contains(marker), hour < 12 {
                    hour += 12
                } else if amMarkers.contains(marker), hour == 12 {
                    hour = 0
                }
            }
            return (hour, minute, wholeRange)
        }
        return nil
    }

    private static func hourMarkedClockComponents(
        in text: String
    ) -> (hour: Int, minute: Int, range: Range<String.Index>)? {
        let pattern = #"(?i)([01]?\d|2[0-3])\s*h\s*([0-5]?\d)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        for match in expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) {
            guard let wholeRange = Range(match.range(at: 0), in: text),
                  let hourRange = Range(match.range(at: 1), in: text),
                  let minuteRange = Range(match.range(at: 2), in: text),
                  let hour = Int(text[hourRange]),
                  let minute = Int(text[minuteRange]) else {
                continue
            }
            return (hour, minute, wholeRange)
        }
        return nil
    }

    private static func datePart(
        before clockRange: Range<String.Index>,
        in text: String
    ) -> String {
        var prefix = String(text[..<clockRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localizedConnectors = [
            "alle ore", "a las", "from", "alle", "at", "um", "às", "à", "в",
        ]
        let lowercasePrefix = prefix.lowercased()
        for connector in localizedConnectors where lowercasePrefix.hasSuffix(connector) {
            let connectorStart = prefix.index(prefix.endIndex, offsetBy: -connector.count)
            guard connectorStart == prefix.startIndex
                    || prefix[prefix.index(before: connectorStart)].isWhitespace else {
                continue
            }
            prefix = String(prefix[..<connectorStart])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if prefix.lowercased().hasSuffix(" г.") {
            prefix.removeLast(3)
        }
        return prefix.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",-"))
        )
    }

    private static func normalized(_ raw: String) -> String {
        String(raw.unicodeScalars.map { scalar -> Character in
            if scalar.value >= 0xFF10 && scalar.value <= 0xFF19 {
                return Character(UnicodeScalar(scalar.value - 0xFF10 + 0x30)!)
            }
            if scalar.value == 0xFF1A { return ":" }
            return Character(scalar)
        })
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum MeetingSource: String, Codable, Sendable, Equatable {
    case parsedBody
    case calendarInvitation
}

public struct MeetingObservation: Sendable, Equatable {
    public let messageID: UUID
    public let threadID: String?
    public let messageDate: Date
    public let subject: String
    public let bodyCandidate: MeetingCandidate?
    public let invitations: [CalendarInvitation]

    public init(
        messageID: UUID,
        threadID: String? = nil,
        messageDate: Date,
        subject: String,
        bodyCandidate: MeetingCandidate?,
        invitations: [CalendarInvitation]
    ) {
        self.messageID = messageID
        self.threadID = threadID
        self.messageDate = messageDate
        self.subject = subject
        self.bodyCandidate = bodyCandidate
        self.invitations = invitations
    }
}

public struct MeetingEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let threadID: String?
    /// The specific email that produced this entry (the invitation carrier
    /// or the body-parsed message) — distinct from `threadID`, which only
    /// identifies the conversation. Lets a consumer deep-link to the exact
    /// source message rather than just its thread.
    public let sourceMessageID: UUID
    public let externalIdentifier: String?
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let location: String?
    public let onlineMeetingURL: URL?
    public let sourceUpdatedAt: Date
    public let source: MeetingSource
    public let isCancelled: Bool
    public let isRecurrenceInstance: Bool

    public init(
        id: String,
        threadID: String? = nil,
        sourceMessageID: UUID,
        externalIdentifier: String?,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        onlineMeetingURL: URL?,
        sourceUpdatedAt: Date,
        source: MeetingSource,
        isCancelled: Bool,
        isRecurrenceInstance: Bool = false
    ) {
        self.id = id
        self.threadID = threadID
        self.sourceMessageID = sourceMessageID
        self.externalIdentifier = externalIdentifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.onlineMeetingURL = onlineMeetingURL
        self.sourceUpdatedAt = sourceUpdatedAt
        self.source = source
        self.isCancelled = isCancelled
        self.isRecurrenceInstance = isRecurrenceInstance
    }
}

public enum MeetingTracker {
    public static func build(
        observations: [MeetingObservation],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MeetingEntry] {
        var candidates: [
            (identity: String, sequence: Int, threadID: String?, entry: MeetingEntry)
        ] = []

        for observation in observations {
            let body = observation.bodyCandidate.flatMap {
                resolvedBodyEntry(
                    $0,
                    observation: observation,
                    calendar: calendar
                )
            }
            if observation.invitations.isEmpty {
                if let body {
                    candidates.append((body.id, 0, observation.threadID, body))
                }
                continue
            }

            for invitation in observation.invitations {
                let identity = "invite:\(invitation.identity.lowercased())"
                let sourceDate = invitation.sourceUpdatedAt == .distantPast
                    ? observation.messageDate
                    : invitation.sourceUpdatedAt
                let entry = MeetingEntry(
                    id: stableID(identity),
                    threadID: observation.threadID,
                    sourceMessageID: observation.messageID,
                    externalIdentifier: invitation.uid,
                    title: invitation.title.isEmpty
                        ? (body?.title ?? observation.subject)
                        : invitation.title,
                    startDate: invitation.startDate,
                    endDate: invitation.endDate,
                    location: meaningfulLocation(invitation.location ?? body?.location),
                    onlineMeetingURL: invitation.onlineMeetingURL ?? body?.onlineMeetingURL,
                    sourceUpdatedAt: sourceDate,
                    source: .calendarInvitation,
                    isCancelled: invitation.isCancelled,
                    isRecurrenceInstance: invitation.recurrenceIdentifier != nil
                )
                candidates.append(
                    (identity, invitation.sequence, observation.threadID, entry)
                )
            }
        }

        let grouped = Dictionary(grouping: candidates, by: \.identity)
        let winners = grouped.compactMap { _, members in
            members.max { lhs, rhs in
                let lhsRank = lhs.entry.source == .calendarInvitation ? 1 : 0
                let rhsRank = rhs.entry.source == .calendarInvitation ? 1 : 0
                return (lhsRank, lhs.sequence, lhs.entry.sourceUpdatedAt, lhs.entry.id)
                    < (rhsRank, rhs.sequence, rhs.entry.sourceUpdatedAt, rhs.entry.id)
            }
        }
        let invitationThreadIDs = Set(
            winners.compactMap {
                $0.entry.source == .calendarInvitation ? $0.threadID : nil
            }
        )
        return winners
            .filter {
                $0.entry.source == .calendarInvitation
                    || $0.threadID == nil
                    || invitationThreadIDs.contains($0.threadID!) == false
            }
            .map(\.entry)
        .sorted { ($0.startDate, $0.id) < ($1.startDate, $1.id) }
    }

    private static func resolvedBodyEntry(
        _ candidate: MeetingCandidate,
        observation: MeetingObservation,
        calendar: Calendar
    ) -> MeetingEntry? {
        guard let dates = MeetingDateResolver.resolve(
            candidate,
            referenceDate: observation.messageDate,
            calendar: calendar
        ) else {
            return nil
        }
        let url = OnlineMeetingURL.normalized(
            candidate.onlineMeetingURL.flatMap(URL.init(string:))
        )
        let title = candidate.title.isEmpty ? observation.subject : candidate.title
        let startBucket = String(Int(dates.startDate.timeIntervalSince1970 / 900))
        let identity: String
        if let urlIdentity = OnlineMeetingURL.identity(url) {
            // A standing room can host many distinct meetings. Time is part
            // of the identity so recurring uses of one join link survive.
            identity = "url:\(urlIdentity)|\(startBucket)"
        } else {
            identity = [
                normalizedTitle(title),
                startBucket,
            ].joined(separator: "|")
        }
        return MeetingEntry(
            id: stableID(identity),
            threadID: observation.threadID,
            sourceMessageID: observation.messageID,
            externalIdentifier: nil,
            title: title,
            startDate: dates.startDate,
            endDate: dates.endDate,
            location: meaningfulLocation(candidate.location),
            onlineMeetingURL: url,
            sourceUpdatedAt: observation.messageDate,
            source: .parsedBody,
            isCancelled: false
        )
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .joined(separator: " ")
    }

    /// Location phrases so generic they carry no navigable meaning on a
    /// calendar — "campus", "the office", "online" — say where in only the
    /// broadest sense and give the user nothing to act on. Room numbers,
    /// addresses, and building/place names (even single-word ones, like a
    /// city or a named venue) are left untouched; this only drops the small,
    /// explicit set of filler terms below.
    private static let vagueLocationTerms: Set<String> = [
        "campus", "on campus", "on-campus",
        "office", "the office", "my office", "our office",
        "online", "virtual", "remote",
        "onsite", "on-site", "on site",
        "here", "there", "home",
        "tbd", "tba", "to be determined", "to be confirmed"
    ]

    private static func meaningfulLocation(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              vagueLocationTerms.contains(trimmed.lowercased()) == false else {
            return nil
        }
        return trimmed
    }

    private static func stableID(_ identity: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "meeting-\(String(hash, radix: 16))"
    }
}
