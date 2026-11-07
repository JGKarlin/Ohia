import Foundation
import OhiaCore

/// Deterministic renderings of Chinese/Japanese date, time, currency, and
/// fraction expressions in the target locale's own conventions ("3月15日" →
/// "March 15" in English, "15 mars" in French, "3월 15일" in Korean; 3分の1 →
/// "1/3"), with positional
/// kanji numerals read as digits ("二〇二六年" → "2026", "一〇〇万円" →
/// "¥1,000,000"). A template blank written with 〇 stays a blank in the
/// target's own format, never an invented value: "〇円" → "¥○", "〇〇万円" →
/// "¥○○0,000", "〇時〇分" → "○:○", "〇月〇日" → "○/○". Exact, free, and never
/// sent to the model or minted into the glossary.
enum DisplayNumericExpressions {
    static func rendering(of span: String, sourceLanguage: String?, targetLanguage: String) -> String? {
        guard let source = sourceLanguage.flatMap(LocalModelLanguageSupport.canonicalLanguageID(for:)) else {
            return dashRendering(span)
        }
        let trimmed = span.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let dash = dashRendering(trimmed) { return dash }
        if let placeholder = IdeographicZeroRuns.placeholderRendering(trimmed) { return placeholder }
        let value = IdeographicZeroRuns.withNumeralsAsDigits(trimmed)
        let locale = Locale(identifier: targetLanguage)
        if let currency = currencyRendering(value, source: source, locale: locale) { return currency }
        guard source == "ja" || source == "zh" else { return nil }
        if let fraction = fractionRendering(value, locale: locale) { return fraction }
        if let template = placeholderDateRendering(value, locale: locale)
            ?? placeholderTimeRendering(value, locale: locale) {
            return template
        }
        if let range = timeRangeRendering(value) { return range }
        if let date = dateRendering(value, locale: locale) { return date }
        if let time = timeRendering(value, locale: locale) { return time }
        return weekdayRendering(value, locale: locale, abbreviated: false, requireSuffix: true)
    }

    /// A bare weekday character is ambiguous (金 is also "gold"); it is read
    /// as a weekday only where the caller sees it parenthesized after a date.
    static func parenthesizedWeekdayRendering(_ span: String, targetLanguage: String) -> String? {
        weekdayRendering(span, locale: Locale(identifier: targetLanguage), abbreviated: true, requireSuffix: false)
    }

    // MARK: - Patterns

    private static func dashRendering(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              trimmed.allSatisfy({ "ー〜～-".contains($0) }) else { return nil }
        return "\u{2013}"
    }

    /// A fraction N分のM (Chinese N分之M) as the target's plain M/N: 3分の1 →
    /// "1/3", 三分の一 → "1/3", 一〇分の一 → "1/10". Both parts must be
    /// numbers, so 何分の一 ("some fraction") is not one.
    private static func fractionRendering(_ value: String, locale: Locale) -> String? {
        let part = "([0-9,一二三四五六七八九十百千万億]+)"
        guard let match = firstMatch("^\(part)分[の之]\(part)$", in: value),
              let denominator = numeralValue(match[1]), denominator > 0,
              let numerator = numeralValue(match[2]) else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .none
        guard let top = formatter.string(from: numerator as NSNumber),
              let bottom = formatter.string(from: denominator as NSNumber) else { return nil }
        return "\(top)/\(bottom)"
    }

    /// A whole number in digits (grouping commas allowed: 1,000), or in kanji
    /// numerals with place words in descending order (三 3, 十 10, 二十五 25,
    /// 三百 300, 千 1000, 一万二千 12000); nil for anything else.
    private static func numeralValue(_ text: String) -> Int? {
        if text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ",") }) {
            guard text.wholeMatch(of: #/[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+/#) != nil else { return nil }
            let digits = text.filter(\.isNumber)
            return digits.count <= 18 ? Int(digits) : nil
        }
        let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let places: [Character: Int] = ["十": 10, "百": 100, "千": 1_000]
        let groups: [Character: Int] = ["万": 10_000, "億": 100_000_000]
        var total = 0
        var section = 0
        var digit: Int?
        var lastPlace = Int.max
        var lastGroup = Int.max
        for character in text {
            if let value = digits[character] {
                guard digit == nil else { return nil }
                digit = value
            } else if let place = places[character] {
                guard place < lastPlace else { return nil }
                section += (digit ?? 1) * place
                digit = nil
                lastPlace = place
            } else if let group = groups[character] {
                let amount = section + (digit ?? 0)
                guard group < lastGroup, amount > 0 else { return nil }
                total += amount * group
                section = 0
                digit = nil
                lastPlace = Int.max
                lastGroup = group
            } else {
                return nil
            }
        }
        return total + section + (digit ?? 0)
    }

    /// A date with a 〇 blank, in the target's numeric order with each blank
    /// kept: 〇月〇日 → "○/○" (en) or "○/○" day first (fr), 2026年〇月 →
    /// "○/2026", 2023年〇月〇日 → "○/○/2023". Month names are not used, since a
    /// blank month has none. Nil when a written month or day cannot be one
    /// (13月〇日, 〇月32日).
    private static func placeholderDateRendering(_ value: String, locale: Locale) -> String? {
        let part = #"(\d{1,4}|〇{1,4})"#
        let shapes: [(pattern: String, template: String, fields: [Character])] = [
            (#"^\#(part)年\#(part)月\#(part)日$"#, "yMd", ["y", "M", "d"]),
            (#"^\#(part)年\#(part)月$"#, "yM", ["y", "M"]),
            (#"^\#(part)月\#(part)日$"#, "Md", ["M", "d"]),
        ]
        for shape in shapes {
            guard let match = firstMatch(shape.pattern, in: value),
                  match.dropFirst().contains(where: { $0.contains("〇") }) else { continue }
            let values = Dictionary(uniqueKeysWithValues: zip(shape.fields, match.dropFirst()))
            guard isBlankOrValue(values["M"], in: 1...12), isBlankOrValue(values["d"], in: 1...31) else { return nil }
            return filledPattern(template: shape.template, values: values, locale: locale)
        }
        return nil
    }

    /// A clock time with a 〇 blank, in the target's own format: 〇時 → "○:00",
    /// 〇時〇分 → "○:○", 10時〇分 → "10:○". Nil for an hour past 24 or a
    /// minute past 59.
    private static func placeholderTimeRendering(_ value: String, locale: Locale) -> String? {
        guard let match = firstMatch(#"^(\d{1,2}|〇{1,2})時(?:(\d{1,2}|〇{1,2})分)?$"#, in: value),
              match.dropFirst().contains(where: { $0.contains("〇") }) else { return nil }
        let minutes = match[2].isEmpty ? "00" : match[2]
        guard isBlankOrValue(match[1], in: 0...24), isBlankOrValue(minutes, in: 0...59) else { return nil }
        return filledPattern(template: "Hm", values: ["H": match[1], "m": minutes], locale: locale)
    }

    /// Whether a template part is a 〇 blank, absent, or a number in `range`.
    private static func isBlankOrValue(_ part: String?, in range: ClosedRange<Int>) -> Bool {
        guard let part, part.contains("〇") == false else { return true }
        return Int(part).map(range.contains) == true
    }

    /// The target locale's own pattern for `template` with each field
    /// written from `values` (keyed y, M, d, H, m): a 〇 blank as one ○ per 〇,
    /// a number padded to the field's width (dd → 05; yy → its last two
    /// digits). The pattern's fields are filled where they stand, so a value
    /// can never be mistaken for a sample digit elsewhere in the text. Nil
    /// when the pattern holds a field with no value (an era, a month name, a
    /// day period), so an unfamiliar format falls back to romanization.
    private static func filledPattern(template: String, values: [Character: String], locale: Locale) -> String? {
        guard let pattern = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) else { return nil }
        let fields: [Character: Character] = ["y": "y", "u": "y", "M": "M", "L": "M", "d": "d", "H": "H", "k": "H", "m": "m"]
        var output = ""
        var rest = Substring(pattern)
        while let character = rest.first {
            if character == "'" {
                // A quoted literal; '' is a quote mark.
                rest = rest.dropFirst()
                guard rest.first != "'" else {
                    output.append("'")
                    rest = rest.dropFirst()
                    continue
                }
                while let literal = rest.first {
                    rest = rest.dropFirst()
                    guard literal == "'" else {
                        output.append(literal)
                        continue
                    }
                    guard rest.first == "'" else { break }
                    output.append("'")
                    rest = rest.dropFirst()
                }
            } else if character.isASCII, character.isLetter {
                let width = rest.prefix { $0 == character }.count
                rest = rest.dropFirst(width)
                guard let field = fields[character], let value = values[field],
                      field != "M" || width <= 2 else { return nil }
                if value.contains("〇") {
                    output += String(repeating: "\u{25CB}", count: value.count)
                } else {
                    let digits = field == "y" && width == 2 ? String(value.suffix(2)) : value
                    output += String(repeating: "0", count: max(0, width - digits.count)) + digits
                }
            } else {
                output.append(character)
                rest = rest.dropFirst()
            }
        }
        return output
    }

    private static func timeRangeRendering(_ value: String) -> String? {
        guard let match = firstMatch(#"^(\d{1,2}(?::\d{2})?)\s*[ー〜～\-]\s*(\d{1,2}(?::\d{2})?)$"#, in: value) else {
            return nil
        }
        return "\(match[1])\u{2013}\(match[2])"
    }

    private static func dateRendering(_ value: String, locale: Locale) -> String? {
        if let match = firstMatch(#"^(\d{4})年(\d{1,2})月(\d{1,2})日$"#, in: value) {
            return formatted(year: Int(match[1]), month: Int(match[2]), day: Int(match[3]), template: "yMMMMd", locale: locale)
        }
        if let match = firstMatch(#"^(\d{1,2})月(\d{1,2})日$"#, in: value) {
            return formatted(year: 2000, month: Int(match[1]), day: Int(match[2]), template: "MMMMd", locale: locale)
        }
        if let match = firstMatch(#"^(\d{4})年(\d{1,2})月$"#, in: value) {
            return formatted(year: Int(match[1]), month: Int(match[2]), day: 1, template: "yMMMM", locale: locale)
        }
        if let match = firstMatch(#"^(\d{1,2})月$"#, in: value),
           let month = Int(match[1]), (1...12).contains(month) {
            let formatter = DateFormatter()
            formatter.locale = locale
            return formatter.standaloneMonthSymbols[month - 1]
        }
        if let match = firstMatch(#"^(\d{4})年$"#, in: value) {
            return match[1]
        }
        return nil
    }

    private static func timeRendering(_ value: String, locale: Locale) -> String? {
        var clock = value
        var halfDay: String?
        for prefix in ["午前", "午後"] where clock.hasPrefix(prefix) {
            halfDay = prefix
            clock = String(clock.dropFirst(prefix.count))
        }
        var hour: Int?
        let minute: Int?
        if let match = firstMatch(#"^(\d{1,2})時(\d{1,2})分$"#, in: clock) {
            hour = Int(match[1]); minute = Int(match[2])
        } else if let match = firstMatch(#"^(\d{1,2})時半$"#, in: clock) {
            hour = Int(match[1]); minute = 30
        } else if let match = firstMatch(#"^(\d{1,2})時$"#, in: clock) {
            hour = Int(match[1]); minute = 0
        } else {
            return nil
        }
        if let halfDay, let reading = hour {
            guard (0...12).contains(reading) else { return nil }
            hour = halfDay == "午後" ? reading % 12 + 12 : reading % 12
        }
        guard let hour, let minute, (0...24).contains(hour), (0...59).contains(minute) else { return nil }
        guard let date = gregorian.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour % 24, minute: minute)) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = gregorian.timeZone
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter.string(from: date)
    }

    /// The power of ten each multiplier kanji stands for.
    private static let multiplierExponents: [String: Int] = ["万": 4, "億": 8, "兆": 12]

    private static func currencyRendering(_ value: String, source: String, locale: Locale) -> String? {
        let currencies: [(suffix: String, code: String, languages: Set<String>)] = [
            ("円", "JPY", ["ja"]), ("元", "CNY", ["zh"]), ("원", "KRW", ["ko"]),
        ]
        for currency in currencies where currency.languages.contains(source) {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .currency
            formatter.currencyCode = currency.code
            // An amount written as a placeholder keeps its currency and the
            // zeros of its multiplier, each 〇 a blank digit: 〇〇円 → ¥○○,
            // 〇〇万円 → ¥○○0,000, 〇〇億円 → ¥○,○00,000,000.
            if let match = firstMatch(#"^(〇+)([万億兆])?\#(currency.suffix)$"#, in: value) {
                formatter.maximumFractionDigits = 0
                return blankAmount(blanks: match[1].count, zeros: multiplierExponents[match[2]] ?? 0, formatter: formatter)
            }
            guard let match = firstMatch(#"^([\d,]+(?:\.\d+)?)([万億兆])?\#(currency.suffix)$"#, in: value),
                  var amount = Decimal(string: match[1].replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")) else {
                continue
            }
            if let exponent = multiplierExponents[match[2]] { amount *= pow(10, exponent) }
            return formatter.string(from: amount as NSDecimalNumber)
        }
        return nil
    }

    /// An amount of `blanks` blank digits followed by `zeros` zeros, grouped,
    /// spaced, and symbolled by the target formatter. The formatter writes an
    /// amount with the same number of digits (1 and then zeros), and the
    /// blanks take the places of its leading digits, counted by position, so
    /// the locale's grouping separator, group sizes, and minimum grouping
    /// (es 1000, not 1.000) and its spacing between symbol and digits
    /// (ja 元 100,000) all hold.
    private static func blankAmount(blanks: Int, zeros: Int, formatter: NumberFormatter) -> String? {
        let digitCount = blanks + zeros
        guard blanks > 0, digitCount <= 30,
              let formatted = formatter.string(from: pow(Decimal(10), digitCount - 1) as NSDecimalNumber) else {
            return nil
        }
        var remaining = blanks
        var output = ""
        for character in formatted {
            if remaining > 0, character.isWholeNumber {
                output.append("\u{25CB}")
                remaining -= 1
            } else {
                output.append(character)
            }
        }
        return remaining == 0 ? output : nil
    }

    private static func weekdayRendering(
        _ value: String,
        locale: Locale,
        abbreviated: Bool,
        requireSuffix: Bool
    ) -> String? {
        let pattern = requireSuffix ? #"^([日月火水木金土])曜日?$"# : #"^([日月火水木金土])(?:曜日?)?$"#
        guard let match = firstMatch(pattern, in: value),
              let index = Array("日月火水木金土").firstIndex(of: Character(match[1])) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        let symbols = abbreviated ? formatter.shortStandaloneWeekdaySymbols : formatter.standaloneWeekdaySymbols
        return symbols?[index]
    }

    // MARK: - Helpers

    private static let gregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static func formatted(year: Int?, month: Int?, day: Int?, template: String, locale: Locale) -> String? {
        guard let year, let month, let day,
              (1...12).contains(month), (1...31).contains(day),
              let date = gregorian.date(from: DateComponents(year: year, month: month, day: day)),
              gregorian.component(.day, from: date) == day else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = gregorian.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private static func firstMatch(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: value).map { String(value[$0]) } ?? ""
        }
    }
}

/// The ideographic zero 〇 and the kanji digits around it, decided per run of
/// the text as written.
/// - A positional numeral starts with a digit 一–九 and holds a 〇 (二〇二六,
///   一〇〇): it reads as Arabic digits. 十 百 千 beside it mark a unit-style
///   number, which stays as written; 万 億 兆 do not (一〇〇万 → 100万).
/// - In a date expression with such a numeral, the other digit-only parts
///   read as digits too (二〇二六年一〇月五日 → 2026年10月5日); 一日 or 三日間
///   alone stay as written.
/// - A lone 〇 directly after 午前 or 午後 is zero (午前〇時 → 午前0時).
/// - Any other run of 〇 not following a digit is a placeholder, including
///   before a counter (〇〇部長, 第〇〇回, 〇〇一同, 〇時, 〇円): Japanese
///   writes a blank in a template this way and midnight as 0時. It is shown
///   as ○ (U+25CB WHITE CIRCLE, not a residue script) rather than read aloud
///   as "rei" or "líng".
enum IdeographicZeroRuns {
    struct Segment: Equatable {
        let text: String
        /// Set for a numeral, zero, or placeholder run; nil for text to read.
        let rendering: String?
        var isPlaceholder: Bool { rendering?.first == "\u{25CB}" }
    }

    private static let positionalDigits: [Character: Character] = [
        "〇": "0", "一": "1", "二": "2", "三": "3", "四": "4",
        "五": "5", "六": "6", "七": "7", "八": "8", "九": "9",
    ]
    private static let unitNumerals: Set<Character> = Set("十百千")
    private static let placeholder: Character = "\u{25CB}"

    /// "○" × n when the whole text is a placeholder run of 〇.
    static func placeholderRendering(_ text: String) -> String? {
        let parts = segments(of: text)
        guard parts.count == 1, let only = parts.first, only.isPlaceholder else { return nil }
        return only.rendering
    }

    /// The text with every numeral and zero run read as digits; placeholder
    /// runs stay as written.
    static func withNumeralsAsDigits(_ text: String) -> String {
        segments(of: text).map { segment in
            segment.isPlaceholder ? segment.text : segment.rendering ?? segment.text
        }.joined()
    }

    static func segments(of text: String) -> [Segment] {
        let characters = Array(withDateNumeralsAsDigits(text))
        var segments: [Segment] = []
        var plain = ""
        func flush() {
            if plain.isEmpty == false { segments.append(Segment(text: plain, rendering: nil)) }
            plain = ""
        }
        var index = 0
        while index < characters.count {
            guard positionalDigits[characters[index]] != nil else {
                plain.append(characters[index])
                index += 1
                continue
            }
            var end = index
            while end < characters.count, positionalDigits[characters[end]] != nil { end += 1 }
            let before = index > 0 ? characters[index - 1] : nil
            let after = end < characters.count ? characters[end] : nil
            let followsDigit = before.map { isDigit($0) || unitNumerals.contains($0) } == true
            var cursor = index
            // Leading 〇: zero right after 午前/午後, else a placeholder.
            if followsDigit == false, characters[cursor] == "〇" {
                var zeros = cursor
                while zeros < end, characters[zeros] == "〇" { zeros += 1 }
                let halfDay = cursor >= 2 ? String(characters[(cursor - 2)..<cursor]) : ""
                flush()
                if zeros - cursor == 1, halfDay == "午前" || halfDay == "午後" {
                    segments.append(Segment(text: "〇", rendering: "0"))
                } else {
                    segments.append(Segment(
                        text: String(characters[cursor..<zeros]),
                        rendering: String(repeating: placeholder, count: zeros - cursor)
                    ))
                }
                cursor = zeros
            }
            // The rest starts with a digit 一–九 (or follows one): a
            // positional numeral when it holds a 〇 and no unit numeral is
            // beside it.
            let rest = characters[cursor..<end]
            let restBefore = cursor > 0 ? characters[cursor - 1] : nil
            if rest.count >= 2, rest.first != "〇", rest.contains("〇"),
               restBefore.map(unitNumerals.contains) != true, after.map(unitNumerals.contains) != true {
                flush()
                segments.append(Segment(text: String(rest), rendering: String(rest.compactMap { positionalDigits[$0] })))
            } else {
                plain += String(rest)
            }
            index = end
        }
        flush()
        return segments
    }

    private static func isDigit(_ character: Character) -> Bool {
        positionalDigits[character] != nil || character.isASCII && character.isNumber
    }

    /// Year–month(–day) and month–day expressions holding a positional
    /// numeral, with every digit-only part as Arabic digits.
    private static func withDateNumeralsAsDigits(_ text: String) -> String {
        guard text.contains("〇") else { return text }
        var output = text
        for pattern in datePatterns {
            let whole = NSRange(output.startIndex..<output.endIndex, in: output)
            for match in pattern.matches(in: output, range: whole).reversed() {
                let parts = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: output) }
                guard parts.contains(where: { isPositional(output[$0]) }) else { continue }
                for part in parts.reversed() {
                    let digits = String(output[part].map { positionalDigits[$0] ?? $0 })
                    output.replaceSubrange(part, with: digits)
                }
            }
        }
        return output
    }

    private static func isPositional(_ part: Substring) -> Bool {
        part.count >= 2 && part.first != "〇" && part.first.map { positionalDigits[$0] != nil } == true
            && part.contains("〇")
    }

    private static let datePatterns: [NSRegularExpression] = [
        #"(?<![0-9〇一二三四五六七八九十百千])([0-9〇一二三四五六七八九]{4})年([0-9〇一二三四五六七八九]{1,2})月(?:([0-9〇一二三四五六七八九]{1,2})日)?"#,
        #"(?<![0-9〇一二三四五六七八九十百千年])([0-9〇一二三四五六七八九]{1,2})月([0-9〇一二三四五六七八九]{1,2})日"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}
