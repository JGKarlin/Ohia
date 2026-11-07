import Foundation

/// How precisely a deadline resolved in time.
///
/// `.dateOnly` deadlines carry a calendar day with no meaningful clock time
/// ("by Friday", "7月20日", "end of month") — reminders anchor them to a fixed
/// local time and they only read as overdue once the day has fully elapsed.
/// `.dateTime` deadlines carry a specific instant ("within 24 hours",
/// "expires in 10 minutes", "2026-07-20T15:00Z") — the clock time matters and
/// an hourly reminder is meaningful.
public enum DeadlineDateGranularity: String, Codable, Sendable, Equatable {
    case dateOnly
    case dateTime
}

/// A deadline surface phrase resolved to a concrete point in time.
public struct ResolvedDeadlineDate: Sendable, Equatable {
    /// For `.dateTime`, the exact instant. For `.dateOnly`, the start of the
    /// deadline day (00:00 in the resolving calendar's time zone).
    public let date: Date
    public let granularity: DeadlineDateGranularity

    public init(date: Date, granularity: DeadlineDateGranularity) {
        self.date = date
        self.granularity = granularity
    }

    /// The instant at which the deadline has definitively passed. A `.dateOnly`
    /// deadline is not overdue until its day is fully over, so the threshold is
    /// the start of the following day; a `.dateTime` deadline passes at its
    /// own instant.
    public func overdueThreshold(calendar: Calendar) -> Date {
        switch granularity {
        case .dateTime:
            return date
        case .dateOnly:
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
    }
}

/// Resolves an LLM-extracted deadline *surface phrase* into a concrete date,
/// anchored to the email's received date.
///
/// Triage stores deadlines as human surface text in the message's own language
/// ("by Friday", "within 24 hours", "来週金曜", "月末") rather than as ISO dates,
/// so this resolver has to interpret relative and localized expressions. It is
/// deliberately deterministic (no `NSDataDetector`, whose relative parsing is
/// anchored to "now" and cannot be pinned to the email's date) and covers the
/// language families supported by Ohia's local model. Anything it does not
/// recognize returns `nil` — the caller drops the deadline from the dated
/// tracker rather than guess.
public enum DeadlineDateResolver {

    public static func resolve(
        _ surface: String,
        referenceDate: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ResolvedDeadlineDate? {
        let normalized = normalize(surface)
        guard !normalized.isEmpty else { return nil }

        // Ordered most-specific-first; the first resolver to claim the phrase
        // wins. `resolveLocalizedMonthDay`/`resolveCJKAbsolute` (an explicit
        // month + day, e.g. "September 29") run ahead of `resolveWeekday` (a
        // bare weekday name, e.g. "Tuesday") — a phrase like "Tuesday,
        // September 29" contains both, and the weekday alone is a much
        // weaker signal that must not override the explicit date.
        // `resolveWeekday` keeps its position ahead of `resolveWindowEnd` /
        // `resolveDayOfMonth`, which is load-bearing for phrases like "来週
        // 金曜" (next week Friday): `resolveWindowEnd`'s bare "next week"
        // match would otherwise swallow it before the weekday resolver sees
        // the more specific weekday-qualified phrase.
        let resolvers: [(String, Date, Calendar) -> ResolvedDeadlineDate?] = [
            resolveISO,
            resolveDurationWithClock,
            resolveDurationInDays,
            resolveNamedRelativeDay,
            resolveLocalizedMonthDay,
            resolveCJKAbsolute,
            resolveWeekday,
            resolveWindowEnd,
            resolveDayOfMonth
        ]
        for resolver in resolvers {
            if let resolved = resolver(normalized, referenceDate, calendar) {
                return resolved
            }
        }
        return nil
    }

    // MARK: - Normalization

    /// Lowercases (harmless for Japanese), maps full-width digits / colon to
    /// ASCII, and strips the leading/trailing prepositions triage phrases wrap
    /// dates in ("by", "before", "due", "no later than", "until", "まで",
    /// "までに"). Keeps the residue so the core expression is exposed.
    private static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        text = String(text.unicodeScalars.map { scalar -> Character in
            // Full-width digits 0-9.
            if scalar.value >= 0xFF10 && scalar.value <= 0xFF19 {
                return Character(UnicodeScalar(scalar.value - 0xFF10 + 0x30)!)
            }
            // Full-width colon.
            if scalar.value == 0xFF1A { return ":" }
            return Character(scalar)
        })

        // Strip trailing deadline particles first (order matters). Duration
        // markers such as 以内 / 이내 are deliberately NOT stripped — the
        // duration resolvers need them to distinguish spans from calendar days.
        for suffix in ["まで​に", "までに", "까지", "まで"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
            break
        }

        let leadingPrepositions = [
            "no later than ", "not later than ", "on or before ",
            "by the end of ", "by end of ", "by ", "before ", "due by ",
            "due on ", "due ", "until ", "till ", "on ",
            "au plus tard le ", "avant le ", "d'ici le ", "pour le ",
            "spätestens am ", "spätestens bis ", "bis zum ", "bis ",
            "a más tardar el ", "antes del ", "para el ",
            "o mais tardar em ", "até ", "antes de ",
            "non oltre il ", "entro il ", "prima del ",
            "не позднее ", "до ",
            "截止到", "截至", "截止", "之前", "前",
            "마감일은 ", "늦어도 ", "전까지 "
        ]
        for prefix in leadingPrepositions where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - ISO

    private static func resolveISO(_ text: String, _ ref: Date, _ cal: Calendar) -> ResolvedDeadlineDate? {
        let dateTime = ISO8601DateFormatter()
        dateTime.formatOptions = [.withInternetDateTime]
        if let date = dateTime.date(from: text.uppercased()) {
            return ResolvedDeadlineDate(date: date, granularity: .dateTime)
        }
        let fullDate = ISO8601DateFormatter()
        fullDate.formatOptions = [.withFullDate]
        if let date = fullDate.date(from: text) {
            return dateOnly(date, cal)
        }
        // yyyy/MM/dd — unambiguous numeric layout only.
        let slash = DateFormatter()
        slash.locale = Locale(identifier: "en_US_POSIX")
        slash.calendar = Calendar(identifier: .gregorian)
        slash.timeZone = cal.timeZone
        slash.dateFormat = "yyyy/MM/dd"
        if let date = slash.date(from: text) {
            return dateOnly(date, cal)
        }
        return nil
    }

    // MARK: - Durations

    /// Localized future durations such as "within 24 hours", "dans 24 heures",
    /// "24時間以内", or "24시간 이내". Clock-granular: adds the exact interval.
    private static func resolveDurationWithClock(_ text: String, _ ref: Date, _ cal: Calendar) -> ResolvedDeadlineDate? {
        let leads = [
            "within", "in", "after", "dans", "sous", "d'ici",
            "innerhalb", "binnen", "dentro de", "en", "em até", "após",
            "entro", "tra", "fra", "в течение", "через", "не позднее чем через"
        ]
        if let n = firstInt(
            in: text,
            precededByAnyOf: leads,
            unit: ["hour", "hours", "heure", "heures", "stunde", "stunden", "hora", "horas", "ora", "ore", "час", "часа", "часов"]
        ) ?? firstIntBeforeMarked(in: text, unit: "時間", markers: ["以内", "後"])
            ?? firstIntBeforeMarked(in: text, unit: "小时", markers: ["内", "后"])
            ?? firstIntBeforeMarked(in: text, unit: "小時", markers: ["內", "後"])
            ?? firstIntBeforeMarked(in: text, unit: "시간", markers: ["이내", "후"]) {
            let date = cal.date(byAdding: .hour, value: n, to: ref) ?? ref
            return ResolvedDeadlineDate(date: date, granularity: .dateTime)
        }
        if let n = firstInt(
            in: text,
            precededByAnyOf: leads,
            unit: ["minute", "minutes", "min", "mins", "minute", "minuten", "minuto", "minutos", "minuti", "минута", "минуты", "минут"]
        ) ?? firstIntBeforeMarked(in: text, unit: "分", markers: ["以内", "内", "後", "后"])
            ?? firstIntBeforeMarked(in: text, unit: "分钟", markers: ["内", "后"])
            ?? firstIntBeforeMarked(in: text, unit: "分鐘", markers: ["內", "後"])
            ?? firstIntBeforeMarked(in: text, unit: "분", markers: ["이내", "후"]) {
            let date = cal.date(byAdding: .minute, value: n, to: ref) ?? ref
            return ResolvedDeadlineDate(date: date, granularity: .dateTime)
        }
        return nil
    }

    /// "within 3 days", "in 2 weeks", "3日以内", "2週間後". Day-granular: due by
    /// the end of the target day.
    private static func resolveDurationInDays(_ text: String, _ ref: Date, _ cal: Calendar) -> ResolvedDeadlineDate? {
        // Only span-closing markers ("以内" within, "後" after) mark a deadline
        // point; "間" (for a duration) and "以降" (from X onward) do not.
        let leads = [
            "within", "in", "after", "dans", "sous", "d'ici",
            "innerhalb", "binnen", "dentro de", "en", "em até", "após",
            "entro", "tra", "fra", "в течение", "через", "не позднее чем через"
        ]
        if let n = firstInt(
            in: text,
            precededByAnyOf: leads,
            unit: ["day", "days", "jour", "jours", "tag", "tage", "tagen", "día", "días", "dia", "dias", "giorno", "giorni", "день", "дня", "дней"]
        ) ?? firstIntBeforeMarked(in: text, unit: "日", markers: ["以内", "内", "後", "后"])
            ?? firstIntBeforeMarked(in: text, unit: "天", markers: ["内", "內", "后", "後"])
            ?? firstIntBeforeMarked(in: text, unit: "일", markers: ["이내", "후"]) {
            let day = cal.date(byAdding: .day, value: n, to: ref) ?? ref
            return dateOnly(day, cal)
        }
        if let n = firstInt(
            in: text,
            precededByAnyOf: leads,
            unit: ["week", "weeks", "semaine", "semaines", "woche", "wochen", "semana", "semanas", "settimana", "settimane", "неделя", "недели", "недель"]
        ) ?? firstIntBeforeMarked(in: text, unit: "週間", markers: ["以内", "後"])
            ?? firstIntBeforeMarked(in: text, unit: "週", markers: ["以内", "内", "後", "后"])
            ?? firstIntBeforeMarked(in: text, unit: "周", markers: ["内", "后"])
            ?? firstIntBeforeMarked(in: text, unit: "주", markers: ["이내", "후"]) {
            let day = cal.date(byAdding: .day, value: n * 7, to: ref) ?? ref
            return dateOnly(day, cal)
        }
        return nil
    }

    // MARK: - Named relative days

    private static func resolveNamedRelativeDay(_ text: String, _ ref: Date, _ cal: Calendar) -> ResolvedDeadlineDate? {
        var residue = text
        for prefix in ["d’ici ", "d'ici ", "pour ", "para ", "entro "] where residue.hasPrefix(prefix) {
            residue = String(residue.dropFirst(prefix.count))
            break
        }
        for suffix in ["之前", "前"] where residue.hasSuffix(suffix) {
            residue = String(residue.dropLast(suffix.count))
            break
        }
        residue = residue.trimmingCharacters(in: .whitespacesAndNewlines)

        let map: [(tokens: [String], offset: Int)] = [
            (["today", "eod", "end of day", "end of the day", "aujourd'hui", "heute", "hoy", "hoje", "oggi", "сегодня", "今日", "本日", "今日中", "今天", "오늘"], 0),
            (["tomorrow", "demain", "morgen", "mañana", "amanhã", "domani", "завтра", "明日", "明日中", "明天", "내일"], 1),
            (["day after tomorrow", "the day after tomorrow", "après-demain", "übermorgen", "pasado mañana", "depois de amanhã", "dopodomani", "послезавтра", "明後日", "后天", "後天", "모레"], 2)
        ]
        for entry in map where entry.tokens.contains(where: { matchesWhole(residue, $0) }) {
            let day = cal.date(byAdding: .day, value: entry.offset, to: ref) ?? ref
            return dateOnly(day, cal)
        }
        return nil
    }

    // MARK: - Weekday

    private static let weekdayTokens: [(names: [String], weekday: Int)] = [
        (["sunday", "sun", "dimanche", "sonntag", "domingo", "domenica", "воскресенье", "воскресенья", "日曜日", "日曜", "星期日", "星期天", "周日", "週日", "일요일"], 1),
        (["monday", "mon", "lundi", "montag", "lunes", "segunda-feira", "segunda feira", "lunedì", "понедельник", "понедельника", "月曜日", "月曜", "星期一", "周一", "週一", "월요일"], 2),
        (["tuesday", "tues", "tue", "mardi", "dienstag", "martes", "terça-feira", "terça feira", "martedì", "вторник", "вторника", "火曜日", "火曜", "星期二", "周二", "週二", "화요일"], 3),
        (["wednesday", "weds", "wed", "mercredi", "mittwoch", "miércoles", "quarta-feira", "quarta feira", "mercoledì", "среда", "среды", "水曜日", "水曜", "星期三", "周三", "週三", "수요일"], 4),
        (["thursday", "thurs", "thur", "thu", "jeudi", "donnerstag", "jueves", "quinta-feira", "quinta feira", "giovedì", "четверг", "четверга", "木曜日", "木曜", "星期四", "周四", "週四", "목요일"], 5),
        (["friday", "fri", "vendredi", "freitag", "viernes", "sexta-feira", "sexta feira", "venerdì", "пятница", "пятницу", "пятницы", "金曜日", "金曜", "星期五", "周五", "週五", "금요일"], 6),
        (["saturday", "sat", "samedi", "samstag", "sábado", "sabato", "суббота", "субботы", "土曜日", "土曜", "星期六", "周六", "週六", "토요일"], 7)
    ]

    private static func resolveWeekday(_ text: String, _ ref: Date, _ cal: Calendar) -> ResolvedDeadlineDate? {
        let previousWeek = matchesAny(text, [
            "last week", "previous week", "semaine dernière", "letzte woche", "semana pasada",
            "semana passada", "settimana scorsa", "прошлой недели", "прошлая неделя",
            "先週", "上周", "上週", "지난 주", "지난주"
        ])
        let previousOccurrence = matchesAny(text, [
            "last ", "previous ", "dernier", "dernière", "letzten", "letzte",
            "pasado", "pasada", "passado", "passada", "scorso", "scorsa", "прошл", "지난 "
        ])
        let nextWeek = matchesAny(text, [
            "next ", "semaine prochaine", "prochaine semaine", "nächster woche", "nächste woche",
            "próxima semana", "semana que vem", "prossima settimana", "следующей недели",
            "следующая неделя", "来週", "下周", "下週", "다음 주", "다음주"
        ])
        let thisWeek = matchesAny(text, [
            "this ", "cette semaine", "diese woche", "esta semana", "questa settimana",
            "этой недели", "эта неделя", "今週", "本周", "本週", "이번 주", "이번주"
        ])
        for entry in weekdayTokens where entry.names.contains(where: { containsWord(text, $0) }) {
            var anchor = ref
            if previousWeek {
                anchor = cal.date(byAdding: .weekOfYear, value: -1, to: startOfWeek(ref, cal)) ?? ref
            } else if previousOccurrence {
                return dateOnly(previousWeekday(entry.weekday, before: ref, cal), cal)
            } else if nextWeek {
                anchor = cal.date(byAdding: .weekOfYear, value: 1, to: startOfWeek(ref, cal)) ?? ref
            } else if thisWeek {
                anchor = startOfWeek(ref, cal)
            }
            let day = nextWeekday(entry.weekday, onOrAfter: anchor, cal)
            return dateOnly(day, cal)
        }
        return nil
    }

    // MARK: - Window ends

    private static func resolveWindowEnd(_ text: String, _ ref: Date, _ cal: Calendar) -> ResolvedDeadlineDate? {
        // End of month.
        if matchesAny(text, ["end of next month", "fin du mois prochain", "ende nächsten monats", "fin del próximo mes", "fim do próximo mês", "fine del mese prossimo", "конец следующего месяца", "конца следующего месяца", "来月末", "下月底", "다음 달 말"]) {
            let nextMonth = cal.date(byAdding: .month, value: 1, to: ref) ?? ref
            return dateOnly(endOfMonth(nextMonth, cal), cal)
        }
        if matchesAny(text, ["end of month", "end of the month", "eom", "fin du mois", "monatsende", "ende des monats", "fin de mes", "fim do mês", "fine del mese", "конец месяца", "конца месяца", "月末", "今月末", "月底", "本月底", "월말", "이번 달 말"]) {
            return dateOnly(endOfMonth(ref, cal), cal)
        }
        // End of week / weekend.
        if matchesAny(text, ["end of next week", "next weekend", "fin de la semaine prochaine", "ende nächster woche", "fin de la próxima semana", "fim da próxima semana", "fine della prossima settimana", "конец следующей недели", "конца следующей недели", "来週末", "下周末", "下週末", "다음 주말"]) {
            let nextWeek = cal.date(byAdding: .weekOfYear, value: 1, to: startOfWeek(ref, cal)) ?? ref
            return dateOnly(endOfWeek(nextWeek, cal), cal)
        }
        if matchesAny(text, ["end of week", "end of the week", "this week", "eow", "weekend", "fin de semaine", "fin de la semaine", "wochenende", "ende der woche", "fin de semana", "fim da semana", "fine settimana", "fine della settimana", "конец недели", "конца недели", "今週", "今週中", "週末", "本周", "本週", "周末", "週末", "이번 주", "주말"]) {
            return dateOnly(endOfWeek(ref, cal), cal)
        }
        // Bare "next week" with no weekday → end of next week.
        if matchesAny(text, ["next week", "semaine prochaine", "nächste woche", "próxima semana", "semana que vem", "prossima settimana", "следующая неделя", "на следующей неделе", "来週", "下周", "下週", "다음 주", "다음주"]) {
            let nextWeek = cal.date(byAdding: .weekOfYear, value: 1, to: startOfWeek(ref, cal)) ?? ref
            return dateOnly(endOfWeek(nextWeek, cal), cal)
        }
        return nil
    }

    // MARK: - Day of month

    /// "the 20th", "by the 20th", "20日" (bare) → day N of the reference month,
    /// rolled to next month when that day has already passed.
    private static func resolveDayOfMonth(_ text: String, _ ref: Date, _ cal: Calendar) -> ResolvedDeadlineDate? {
        var day: Int?
        // English ordinal "the 20th" / "20th".
        if let n = firstOrdinalDayOfMonth(text) {
            day = n
        } else if let n = firstIntBefore(in: text, unit: ["日"]),
                  // Only treat "N日" as a day-of-month when it is the whole
                  // residue — "3日以内"/"3日後" were already claimed above.
                  matchesWhole(text, "\(n)日") {
            day = n
        }
        guard let target = day, (1...31).contains(target) else { return nil }
        return dateOnly(dayOfMonth(target, onOrAfter: ref, cal), cal)
    }

    // MARK: - Localized month + day

    private struct LocalizedDateFormats {
        let localeIdentifier: String
        let withYear: [String]
        let withoutYear: [String]
    }

    private static let localizedDateFormats: [LocalizedDateFormats] = [
        .init(localeIdentifier: "en_US_POSIX", withYear: ["MMMM d, yyyy", "MMMM d yyyy", "MMM d, yyyy", "MMM d yyyy", "d MMMM yyyy", "d MMM yyyy"], withoutYear: ["MMMM d", "MMM d", "d MMMM", "d MMM"]),
        .init(localeIdentifier: "fr_FR", withYear: ["d MMMM yyyy", "d MMM yyyy"], withoutYear: ["d MMMM", "d MMM"]),
        .init(localeIdentifier: "de_DE", withYear: ["d. MMMM yyyy", "d. MMM yyyy", "d MMMM yyyy"], withoutYear: ["d. MMMM", "d. MMM", "d MMMM"]),
        .init(localeIdentifier: "es_ES", withYear: ["d 'de' MMMM 'de' yyyy", "d MMMM yyyy"], withoutYear: ["d 'de' MMMM", "d MMMM"]),
        .init(localeIdentifier: "pt_PT", withYear: ["d 'de' MMMM 'de' yyyy", "d MMMM yyyy"], withoutYear: ["d 'de' MMMM", "d MMMM"]),
        .init(localeIdentifier: "it_IT", withYear: ["d MMMM yyyy", "d MMM yyyy"], withoutYear: ["d MMMM", "d MMM"]),
        .init(localeIdentifier: "ru_RU", withYear: ["d MMMM yyyy", "d MMM yyyy"], withoutYear: ["d MMMM", "d MMM"])
    ]

    private static func resolveLocalizedMonthDay(_ text: String, _ ref: Date, _ cal: Calendar) -> ResolvedDeadlineDate? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = cal.timeZone
        formatter.isLenient = false

        let cleaned = strippingLeadingWeekday(text).replacingOccurrences(of: "the ", with: "")
        for localized in localizedDateFormats {
            formatter.locale = Locale(identifier: localized.localeIdentifier)
            for format in localized.withYear {
                formatter.dateFormat = format
                if let date = formatter.date(from: cleaned) {
                    return dateOnly(date, cal)
                }
            }
            for format in localized.withoutYear {
                formatter.dateFormat = format
                if let parsed = formatter.date(from: cleaned) {
                    return dateOnly(inferYear(for: parsed, near: ref, cal), cal)
                }
            }
        }
        return nil
    }

    /// Drops a leading weekday name ("tuesday, ", "tue ") from an
    /// already-normalized (lowercased) surface phrase. Email dates are
    /// routinely written "Tuesday, September 29" — the weekday is redundant
    /// once a month and day follow, but left in place it breaks the strict,
    /// anchored `DateFormatter` match in `resolveLocalizedMonthDay`.
    private static func strippingLeadingWeekday(_ text: String) -> String {
        for entry in weekdayTokens {
            for name in entry.names where text.hasPrefix(name) {
                let boundary = text.index(text.startIndex, offsetBy: name.count)
                if boundary < text.endIndex, text[boundary].isLetter {
                    // "tue" is a prefix of "tuesday" — only strip on a real
                    // word boundary so longer names still get their turn.
                    continue
                }
                var rest = text[boundary...].trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix(",") {
                    rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                return rest
            }
        }
        return text
    }

    // MARK: - CJK absolute

    private static func resolveCJKAbsolute(_ text: String, _ ref: Date, _ cal: Calendar) -> ResolvedDeadlineDate? {
        if let korean = resolveKoreanAbsolute(text, ref, cal) {
            return korean
        }

        // (yyyy年)?M月D日(H時(M分)?)? — year optional (inferred), time optional.
        let pattern = #"(?:(\d{4})年)?(\d{1,2})月(\d{1,2})日(?:\s*(?:午前|午後)?(\d{1,2})時(?:(\d{1,2})分)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        func group(_ i: Int) -> Int? {
            guard match.range(at: i).location != NSNotFound,
                  let r = Range(match.range(at: i), in: text) else { return nil }
            return Int(text[r])
        }
        guard let month = group(2), let day = group(3),
              (1...12).contains(month), (1...31).contains(day) else { return nil }

        var comps = DateComponents()
        comps.month = month
        comps.day = day
        comps.year = group(1)
        let isAM = text.contains("午前")
        let isPM = text.contains("午後")

        if let rawHour = group(4) {
            let hour: Int
            if isAM || isPM {
                guard (1...12).contains(rawHour) else { return nil }
                hour = isAM ? (rawHour == 12 ? 0 : rawHour) : (rawHour == 12 ? 12 : rawHour + 12)
            } else {
                guard (0...23).contains(rawHour) else { return nil }
                hour = rawHour
            }
            let minute = group(5) ?? 0
            guard (0...59).contains(minute) else { return nil }
            comps.hour = hour
            comps.minute = minute
            if comps.year == nil {
                comps.year = cal.component(.year, from: ref)
            }
            guard var date = exactDate(from: comps, calendar: cal) else { return nil }
            if group(1) == nil { date = rollForwardYearIfPast(date, near: ref, cal) }
            return ResolvedDeadlineDate(date: date, granularity: .dateTime)
        }

        if comps.year == nil {
            comps.year = cal.component(.year, from: ref)
            guard let date = exactDate(from: comps, calendar: cal) else { return nil }
            return dateOnly(rollForwardYearIfPast(date, near: ref, cal), cal)
        }
        guard let date = exactDate(from: comps, calendar: cal) else { return nil }
        return dateOnly(date, cal)
    }

    private static func resolveKoreanAbsolute(_ text: String, _ ref: Date, _ cal: Calendar) -> ResolvedDeadlineDate? {
        let pattern = #"(?:(\d{4})년\s*)?(\d{1,2})월\s*(\d{1,2})일(?:\s*(오전|오후)?\s*(\d{1,2})시(?:(\d{1,2})분)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        func intGroup(_ i: Int) -> Int? {
            guard match.range(at: i).location != NSNotFound,
                  let range = Range(match.range(at: i), in: text) else { return nil }
            return Int(text[range])
        }
        func textGroup(_ i: Int) -> String? {
            guard match.range(at: i).location != NSNotFound,
                  let range = Range(match.range(at: i), in: text) else { return nil }
            return String(text[range])
        }
        guard let month = intGroup(2), let day = intGroup(3),
              (1...12).contains(month), (1...31).contains(day) else { return nil }

        var components = DateComponents()
        components.year = intGroup(1) ?? cal.component(.year, from: ref)
        components.month = month
        components.day = day
        if let rawHour = intGroup(5) {
            let meridiem = textGroup(4)
            let hour: Int
            if meridiem != nil {
                guard (1...12).contains(rawHour) else { return nil }
                hour = meridiem == "오전"
                    ? (rawHour == 12 ? 0 : rawHour)
                    : (rawHour == 12 ? 12 : rawHour + 12)
            } else {
                guard (0...23).contains(rawHour) else { return nil }
                hour = rawHour
            }
            let minute = intGroup(6) ?? 0
            guard (0...59).contains(minute) else { return nil }
            components.hour = hour
            components.minute = minute
            guard var date = exactDate(from: components, calendar: cal) else { return nil }
            if intGroup(1) == nil { date = rollForwardYearIfPast(date, near: ref, cal) }
            return ResolvedDeadlineDate(date: date, granularity: .dateTime)
        }
        guard var date = exactDate(from: components, calendar: cal) else { return nil }
        if intGroup(1) == nil { date = rollForwardYearIfPast(date, near: ref, cal) }
        return dateOnly(date, cal)
    }

    // MARK: - Calendar helpers

    private static func dateOnly(_ date: Date, _ cal: Calendar) -> ResolvedDeadlineDate {
        ResolvedDeadlineDate(date: cal.startOfDay(for: date), granularity: .dateOnly)
    }

    private static func startOfWeek(_ date: Date, _ cal: Calendar) -> Date {
        cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
    }

    /// The last day of `date`'s week (the day before the next week starts).
    private static func endOfWeek(_ date: Date, _ cal: Calendar) -> Date {
        guard let interval = cal.dateInterval(of: .weekOfYear, for: date) else {
            return cal.startOfDay(for: date)
        }
        return cal.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
    }

    private static func endOfMonth(_ date: Date, _ cal: Calendar) -> Date {
        guard let interval = cal.dateInterval(of: .month, for: date) else {
            return cal.startOfDay(for: date)
        }
        return cal.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
    }

    private static func nextWeekday(_ weekday: Int, onOrAfter date: Date, _ cal: Calendar) -> Date {
        let start = cal.startOfDay(for: date)
        if cal.component(.weekday, from: start) == weekday { return start }
        return cal.nextDate(
            after: start,
            matching: DateComponents(weekday: weekday),
            matchingPolicy: .nextTimePreservingSmallerComponents,
            direction: .forward
        ) ?? start
    }

    private static func previousWeekday(_ weekday: Int, before date: Date, _ cal: Calendar) -> Date {
        let start = cal.startOfDay(for: date)
        for offset in 1...7 {
            let candidate = cal.date(byAdding: .day, value: -offset, to: start) ?? start
            if cal.component(.weekday, from: candidate) == weekday {
                return candidate
            }
        }
        return start
    }

    private static func exactDate(from components: DateComponents, calendar: Calendar) -> Date? {
        guard let expectedYear = components.year,
              let expectedMonth = components.month,
              let expectedDay = components.day,
              let date = calendar.date(from: components) else {
            return nil
        }
        let resolved = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard resolved.year == expectedYear,
              resolved.month == expectedMonth,
              resolved.day == expectedDay else {
            return nil
        }
        if let expectedHour = components.hour, resolved.hour != expectedHour { return nil }
        if let expectedMinute = components.minute, resolved.minute != expectedMinute { return nil }
        return date
    }

    private static func dayOfMonth(_ day: Int, onOrAfter date: Date, _ cal: Calendar) -> Date {
        let start = cal.startOfDay(for: date)
        var comps = cal.dateComponents([.year, .month], from: start)
        comps.day = day
        if let candidate = cal.date(from: comps), candidate >= start {
            return candidate
        }
        // Passed this month → same day next month.
        let nextMonth = cal.date(byAdding: .month, value: 1, to: start) ?? start
        var nextComps = cal.dateComponents([.year, .month], from: nextMonth)
        nextComps.day = day
        return cal.date(from: nextComps) ?? start
    }

    /// Fills an absent year: picks the year that puts the month/day nearest to
    /// the reference, preferring the current year but rolling to next year when
    /// the resulting day would sit more than ~6 months in the past.
    private static func inferYear(for parsed: Date, near ref: Date, _ cal: Calendar) -> Date {
        var comps = cal.dateComponents([.month, .day], from: parsed)
        comps.year = cal.component(.year, from: ref)
        guard let candidate = cal.date(from: comps) else { return parsed }
        return rollForwardYearIfPast(candidate, near: ref, cal)
    }

    private static func rollForwardYearIfPast(_ candidate: Date, near ref: Date, _ cal: Calendar) -> Date {
        // A bare month/day this far in the past almost always means next year:
        // a deadline mentioned today points forward, with a small grace so a
        // recently-overdue date ("July 10" seen on July 15) still reads as this
        // year rather than jumping twelve months ahead.
        let refDay = cal.startOfDay(for: ref)
        guard let graceStart = cal.date(byAdding: .day, value: -45, to: refDay) else {
            return candidate
        }
        if candidate >= graceStart {
            return candidate
        }
        return cal.date(byAdding: .year, value: 1, to: candidate) ?? candidate
    }

    // MARK: - Token matching

    private static func matchesWhole(_ text: String, _ token: String) -> Bool {
        text == token
    }

    /// Word-boundary-aware containment for ASCII tokens (so the abbreviation
    /// "mon" does not match inside "month"), plain containment for Japanese
    /// tokens (which have no regex word boundaries).
    private static func containsWord(_ text: String, _ token: String) -> Bool {
        if token.unicodeScalars.contains(where: { $0.value > 0x7F }) {
            return text.contains(token)
        }
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: token) + #"\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// First integer immediately before a Japanese unit that is followed by a
    /// duration marker, e.g. `3日以内`, `10分後`. The marker is what separates a
    /// span ("3日以内" = within three days) from a calendar reference ("3日" =
    /// the 3rd).
    private static func firstIntBeforeMarked(in text: String, unit: String, markers: [String]) -> Int? {
        let markerAlternation = markers
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = #"(\d{1,4})\s*"#
            + NSRegularExpression.escapedPattern(for: unit)
            + #"\s*(?:"# + markerAlternation + ")"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(match.range(at: 1), in: text),
              let n = Int(text[r]) else { return nil }
        return n
    }

    private static func matchesAny(_ text: String, _ tokens: [String]) -> Bool {
        tokens.contains { text == $0 || text.contains($0) }
    }

    /// First integer that appears with `unit` and one of the given lead words,
    /// e.g. `within 24 hours` for unit `hours`. The tokens cover the bounded
    /// language set supported by the local model.
    private static func firstInt(in text: String, precededByAnyOf leads: [String], unit: [String]) -> Int? {
        for unitToken in unit {
            let boundary = unitToken.unicodeScalars.allSatisfy { $0.value < 0x80 } ? #"\b"# : ""
            let pattern = #"(\d{1,4})\s*"# + NSRegularExpression.escapedPattern(for: unitToken) + boundary
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(match.range(at: 1), in: text),
                  let n = Int(text[r]) else { continue }
            // A future-duration phrase needs a lead word ("within/in/after N
            // days"). Without one, "N days" is too ambiguous (and "N days ago"
            // is a past reference, not a deadline) — leave it unresolved.
            if leads.isEmpty || leads.contains(where: { containsWord(text, $0) }) {
                return n
            }
            return nil
        }
        return nil
    }

    /// First integer immediately before a (Japanese) unit token, e.g. `3日`,
    /// `24時間`, `90分`.
    private static func firstIntBefore(in text: String, unit: [String]) -> Int? {
        for unitToken in unit {
            let pattern = #"(\d{1,4})"# + NSRegularExpression.escapedPattern(for: unitToken)
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(match.range(at: 1), in: text),
                  let n = Int(text[r]) else { continue }
            return n
        }
        return nil
    }

    private static func firstOrdinalDayOfMonth(_ text: String) -> Int? {
        let pattern = #"\b(\d{1,2})(st|nd|rd|th)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }
}
