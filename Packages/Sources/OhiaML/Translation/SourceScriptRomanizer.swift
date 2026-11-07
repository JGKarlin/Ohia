import Foundation
import OhiaCore

/// Deterministic romanization for residue that could not be translated.
/// Japanese uses Apple's tokenizer readings converted to modified Hepburn with
/// macrons (総務チーム → Sōmu Chīmu); Chinese uses Hanyu Pinyin with tone
/// marks; Korean and Russian use the system Latin transliteration. A Japanese
/// span is never given a Mandarin reading: a kanji the Japanese reader cannot
/// read leaves the whole span without a romanization (nil). In Japanese and
/// Chinese, positional kanji numerals read as digits (二〇二六 → 2026), and any
/// other run of 〇 is a placeholder shown as ○ (〇〇部長 → ○○ Buchō). Numbers
/// keep their written digits and separators ("8/20,8/27", "1,000"), the words
/// around them are read in the context of the whole span (5日前 → 5 Ka Mae,
/// 第43回文化 → Dai 43 Kai Bunka), and in Japanese a counter the tokenizer
/// cuts out right after a number or placeholder takes its counter reading
/// (1000人 → 1000 Nin, 〇〇月 → ○○ Gatsu). 〆 attached to a following word
/// reads as 締 (〆切 → Shimekiri), and a 〆 standing alone is dropped.
public enum SourceScriptRomanizer {
    /// Title Case applies up to this many words; longer runs are clauses and
    /// take sentence case instead.
    static let titleCaseWordLimit = 6

    public static func romanize(_ text: String, language: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              isReadinglessMark(trimmed) == false,
              let language = LocalModelLanguageSupport.canonicalLanguageID(for: language) else {
            return nil
        }
        var cleaned: [String] = []
        let casing: Bool
        switch language {
        case "ja", "zh":
            let japanese = language == "ja"
            let prepared = (japanese ? withAttachedShimeAsShime(trimmed) : trimmed)
                .precomposedStringWithCompatibilityMapping
            guard let words = readingsInContext(of: prepared, japanese: japanese) else { return nil }
            cleaned = words
            casing = true
        case "ko":
            cleaned = latinTransliteration(trimmed).split(whereSeparator: \.isWhitespace)
                .map { String($0).trimmedRomanization }
                .filter { $0.isEmpty == false }
            casing = true
        case "ru":
            cleaned = latinTransliteration(trimmed).split(whereSeparator: \.isWhitespace)
                .map { String($0).trimmedRomanization }
                .filter { $0.isEmpty == false }
            casing = false
        default:
            return nil
        }
        guard cleaned.isEmpty == false else { return nil }
        let cased: [String]
        if casing == false {
            cased = cleaned
        } else if cleaned.count <= titleCaseWordLimit {
            cased = cleaned.map(uppercasedFirst)
        } else {
            cased = [uppercasedFirst(cleaned[0])] + cleaned.dropFirst()
        }
        let result = cased.joined(separator: " ")
        // A romanization that still carries source script is not one.
        guard DisplayScriptFamily.families(in: result).isSubset(of: [.latin]) else { return nil }
        return result
    }

    /// Iteration and abbreviation marks that have no reading of their own
    /// (々 〆 ゝ ゞ ヽ ヾ 〻): alone they are dropped rather than read.
    static func isReadinglessMark(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty == false && trimmed.allSatisfy(readinglessMarks.contains)
    }

    /// A span whose only source-script characters are marks with no reading,
    /// without those marks ("6/17〆" → "6/17", "々" → ""); nil when the span
    /// holds anything else to read.
    static func withoutReadinglessMarks(_ span: String) -> String? {
        let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceScript = trimmed.filter { character in
            character.unicodeScalars.contains { scalar in
                switch DisplayScriptFamily.of(scalar) {
                case .han, .kana, .hangul, .cyrillic: true
                case .latin, nil: false
                }
            }
        }
        guard sourceScript.isEmpty == false, sourceScript.allSatisfy(readinglessMarks.contains) else { return nil }
        return trimmed.filter { readinglessMarks.contains($0) == false }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let readinglessMarks: Set<Character> = Set("々〆ゝゞヽヾ〻")

    /// 締 for a 〆 written in place of it, directly before the rest of a word
    /// (〆切, 〆切り, 〆日); a 〆 elsewhere stays a mark.
    private static func withAttachedShimeAsShime(_ text: String) -> String {
        text.replacingOccurrences(of: #"〆(?=[\p{Han}\p{Hiragana}\p{Katakana}])"#, with: "締", options: .regularExpression)
    }

    private enum Piece {
        case number(String)
        case placeholder(String)
        case text(String)
    }

    /// The span cut into numbers (positional numerals as digits, written
    /// digits with their separators kept), 〇 placeholders as ○, and text to
    /// read.
    private static func pieces(of text: String) -> [Piece] {
        var pieces: [Piece] = []
        var buffer = ""
        func flush() {
            guard buffer.isEmpty == false else { return }
            let whole = NSRange(buffer.startIndex..<buffer.endIndex, in: buffer)
            var cursor = buffer.startIndex
            for match in writtenNumber?.matches(in: buffer, range: whole) ?? [] {
                guard let range = Range(match.range, in: buffer) else { continue }
                if cursor < range.lowerBound { pieces.append(.text(String(buffer[cursor..<range.lowerBound]))) }
                pieces.append(.number(String(buffer[range])))
                cursor = range.upperBound
            }
            if cursor < buffer.endIndex { pieces.append(.text(String(buffer[cursor...]))) }
            buffer = ""
        }
        for segment in IdeographicZeroRuns.segments(of: text) {
            if segment.isPlaceholder, let rendering = segment.rendering {
                flush()
                pieces.append(.placeholder(rendering))
            } else {
                buffer += segment.rendering ?? segment.text
            }
        }
        flush()
        return pieces
    }

    /// Digits with the separators written between them: 1,000 · 3.5 ·
    /// 8/20,8/27 · 10:30. The span is compatibility-mapped first, so
    /// fullwidth digits and separators are ASCII here.
    private static let writtenNumber = try? NSRegularExpression(
        pattern: #"[0-9]+(?:[,./:\-][0-9]+)*"#
    )

    /// Readings for a Japanese or Chinese span, read in the context of the
    /// whole span. It is tokenized once, each number as its digits and each
    /// 〇 blank as a digit run of its length, so the words beside them are cut
    /// as they are beside a number (5日前 → 日 | 前, not 日前 hinokuma; 〇〇人目
    /// → 人 | 目, not 人目 hitome). Numbers then keep their written text and
    /// blanks show as ○, and the words come back cleaned of tokenizer
    /// artifacts. In Japanese:
    /// - a counter the tokenizer cut out as its own word right after a number
    ///   or blank takes its counter reading: after a number the one that
    ///   number's sound calls for (`numberedCounterReading`: 3本 → bon, 5日 →
    ///   ka, 365日 → nichi), else the counter's general one (1人 → nin); after a
    ///   blank, which has no value, the general one (〇〇日 → nichi);
    /// - 分 between a number and の with a number after it is the fraction bar,
    ///   read bun (3分の1 → 3 Bun No 1), not the minute counter;
    /// - a word right after a blank that the tokenizer cut in two, taking the
    ///   blank for a number (〇〇部長 → 部 | 長), is one word again when its two
    ///   kanji pieces, neither a counter, read alone as one word (部長 buchou).
    /// Nil when a Japanese word with kanji has no Japanese reading.
    private static func readingsInContext(of text: String, japanese: Bool) -> [String]? {
        let pieces = pieces(of: text)
        var joined = ""
        var ranges: [NSRange] = []
        for piece in pieces {
            let standIn: String
            switch piece {
            case .number(let written): standIn = written
            case .placeholder(let written): standIn = String(repeating: "0", count: written.count)
            case .text(let text): standIn = text
            }
            ranges.append(NSRange(location: (joined as NSString).length, length: (standIn as NSString).length))
            joined += standIn
        }
        let locale = japanese ? "ja" : "zh-Hans"
        let all = wordTokens(of: joined, locale: locale)
        var words: [String] = []
        for (index, (piece, range)) in zip(pieces, ranges).enumerated() {
            switch piece {
            case .number(let written), .placeholder(let written):
                words.append(written)
            case .text:
                var tokens: [Token] = []
                for token in all {
                    let inside = NSIntersectionRange(token.range, range)
                    guard inside.length > 0 else { continue }
                    guard inside != token.range else {
                        tokens.append(token)
                        continue
                    }
                    // A token run across a number (1人 read as one Mandarin
                    // word): its part in this text is read alone.
                    let part = (joined as NSString).substring(with: inside)
                    tokens += wordTokens(of: part, locale: locale).map {
                        Token(
                            surface: $0.surface,
                            range: NSRange(location: inside.location + $0.range.location, length: $0.range.length),
                            reading: $0.reading
                        )
                    }
                }
                if japanese, index > 0 {
                    tokens = counted(
                        tokens,
                        in: range,
                        after: pieces[index - 1],
                        before: index + 1 < pieces.count ? pieces[index + 1] : nil
                    )
                }
                var read: [(surface: String, reading: String)] = []
                for token in tokens {
                    guard let reading = acceptedReading(of: token, japanese: japanese) else { return nil }
                    read.append((token.surface, reading))
                }
                words += (japanese ? geminated(read).map(hepburn) : read.map(\.reading))
                    .map(\.trimmedRomanization)
                    .filter { $0.isEmpty == false }
            }
        }
        return words
    }

    /// The text's tokens with a counter, a fraction bar, or a word cut after
    /// a blank read as described for `readingsInContext`. Only the first
    /// token is decided, and only when it starts the text right after a
    /// number or blank.
    private static func counted(_ tokens: [Token], in range: NSRange, after previous: Piece, before next: Piece?) -> [Token] {
        let afterNumber: Bool
        let number: Int?
        switch previous {
        case .number(let written):
            afterNumber = true
            number = spokenValue(of: written)
        case .placeholder:
            afterNumber = false
            number = nil
        case .text:
            return tokens
        }
        guard let first = tokens.first, first.range.location == range.location else { return tokens }
        var tokens = tokens
        if first.surface == "分", isFractionBar(tokens, endingAt: NSMaxRange(range), before: next) {
            tokens[0] = Token(surface: first.surface, range: first.range, reading: "bun")
        } else if let general = counterReadings[first.surface] {
            let reading = number.flatMap { numberedCounterReading(first.surface, after: $0) } ?? general
            tokens[0] = Token(surface: first.surface, range: first.range, reading: reading)
        } else if afterNumber == false, tokens.count >= 2,
                  NSMaxRange(first.range) == tokens[1].range.location,
                  counterReadings[tokens[1].surface] == nil,
                  (first.surface + tokens[1].surface).unicodeScalars.allSatisfy({ DisplayScriptFamily.of($0) == .han }) {
            let second = tokens[1]
            let surface = first.surface + second.surface
            let alone = wordTokens(of: surface, locale: "ja")
            if alone.count == 1, let word = alone.first, word.surface == surface {
                tokens.replaceSubrange(0...1, with: [
                    Token(surface: surface, range: NSUnionRange(first.range, second.range), reading: word.reading),
                ])
            }
        }
        return tokens
    }

    /// Whether the leading 分 is followed by の and then a number: written
    /// digits or a blank right after the text, or a kanji numeral (3分の一).
    private static func isFractionBar(_ tokens: [Token], endingAt end: Int, before next: Piece?) -> Bool {
        guard tokens.count >= 2, tokens[1].surface == "の",
              NSMaxRange(tokens[0].range) == tokens[1].range.location else { return false }
        if tokens.count >= 3 {
            return tokens[2].range.location == NSMaxRange(tokens[1].range)
                && tokens[2].surface.allSatisfy(kanjiNumerals.contains)
        }
        switch next {
        case .number, .placeholder: return NSMaxRange(tokens[1].range) == end
        case .text, nil: return false
        }
    }

    private static let kanjiNumerals: Set<Character> = Set("〇一二三四五六七八九十百千万")

    /// The whole number a written number ends in, as it is spoken before a
    /// counter: grouping commas dropped (1,000 → 1000), and only the last
    /// part after a decimal point, slash, or colon (3.5 → 5). Nil past 18
    /// digits.
    private static func spokenValue(of written: String) -> Int? {
        guard let match = try? #/[0-9]+(?:,[0-9]{3})*$/#.firstMatch(in: written) else { return nil }
        let digits = match.output.filter(\.isWholeNumber)
        return digits.count <= 18 ? Int(digits) : nil
    }

    /// The sound a whole number ends in when read in Japanese, which is what
    /// a counter's sound change follows. The ones digit when it is not 0
    /// (365 sanbyaku rokujū go → go); otherwise the lowest place that is not
    /// 0, read by its place word: 十 jū (10, 20, 1010), 百 hyaku (100;
    /// 300 sanbyaku and 600 roppyaku end in the same sound), 千 sen (1000;
    /// 3000 sanzen), 万 man, 億 oku, 兆 chō.
    private enum SpokenEnding {
        case ichi, ni, san, yon, go, roku, nana, hachi, kyuu, juu, hyaku, sen, man, oku, chou

        init?(_ value: Int) {
            guard value > 0 else { return nil }
            let ones: [SpokenEnding] = [.ichi, .ni, .san, .yon, .go, .roku, .nana, .hachi, .kyuu]
            if value % 10 != 0 {
                self = ones[value % 10 - 1]
            } else if value % 100 != 0 {
                self = .juu
            } else if value % 1_000 != 0 {
                self = .hyaku
            } else if value % 10_000 != 0 {
                self = .sen
            } else if value % 100_000_000 != 0 {
                self = .man
            } else if value % 1_000_000_000_000 != 0 {
                self = .oku
            } else {
                self = .chou
            }
        }

        /// Ends in a sound that doubles the next consonant: ichi → ip-, roku
        /// → rop-, hachi → hap-, jū → jup-, hyaku → hyap-.
        var geminates: Bool { [.ichi, .roku, .hachi, .juu, .hyaku].contains(self) }
        /// Ends in the moraic n that voices an h- counter (san, sen, man;
        /// 4 yon is the conventional exception: yonhon, yonhiki).
        var voices: Bool { [.san, .sen, .man].contains(self) }
    }

    /// The reading a counter takes after a given number, where the counter's
    /// sound changes with the number's last spoken sound; nil for a counter
    /// that does not change (the general reading stands).
    /// - h- counters 本 hon, 匹 hiki, 杯 hai: p after a doubling ending (1, 6,
    ///   8, 10, 100: ippon, roppon, happon, juppon, hyappon), b after a voicing
    ///   one (3, 1000, 10000: sanbon, senbon, manbon), else h (2, 4, 5, 7, 9).
    /// - 分 fun, 分間 funkan: p after a doubling ending or a moraic n (1, 3, 4,
    ///   6, 8, 10, 100, 1000: ippun, sanpun, yonpun, roppun, happun, juppun),
    ///   else f (2, 5, 7, 9: nifun, gofun, nanafun, kyūfun).
    /// - 階 kai: gai after 3 (sangai, jūsangai), else kai.
    /// - 日 as a day count or date: ka for the native day words 2–10, 14, 20,
    ///   and 24 (futsuka … tōka, jūyokka, hatsuka, nijūyokka), else nichi
    ///   (1 ichinichi, 11 jūichinichi, 365 sanbyaku rokujū go nichi).
    private static func numberedCounterReading(_ counter: String, after value: Int) -> String? {
        if counter == "日" {
            return (2...10).contains(value) || [14, 20, 24].contains(value) ? "ka" : "nichi"
        }
        guard let ending = SpokenEnding(value) else { return nil }
        switch counter {
        case "本", "匹", "杯":
            let stem = counter == "本" ? "on" : counter == "匹" ? "iki" : "ai"
            return (ending.geminates ? "p" : ending.voices ? "b" : "h") + stem
        case "分", "分間":
            let doubled = ending.geminates || ending.voices || ending == .yon
            return (doubled ? "pun" : "fun") + (counter == "分間" ? "kan" : "")
        case "階":
            return ending == .san ? "gai" : "kai"
        default:
            return nil
        }
    }

    /// Wāpuro counter readings after a number or placeholder, where the
    /// tokenizer would read the character as a word of its own (人 hito, 月
    /// tsuki, 日 hi, 名 na, 分 bun), and honorifics after a placeholder name
    /// (様 sama, not yō; 殿 dono, not tono). The general reading; a counter
    /// whose sound follows the number takes `numberedCounterReading` after a
    /// number instead.
    private static let counterReadings: [String: String] = [
        "人": "nin", "名": "mei", "分": "fun", "分間": "funkan", "日": "nichi", "月": "gatsu",
        "時": "ji", "時間": "jikan", "年": "nen", "円": "en", "回": "kai", "件": "ken", "個": "ko",
        "枚": "mai", "歳": "sai", "才": "sai", "本": "hon", "匹": "hiki", "杯": "hai", "台": "dai",
        "冊": "satsu", "階": "kai", "号": "gou", "番": "ban", "週": "shuu", "度": "do", "秒": "byou",
        "点": "ten", "社": "sha", "校": "kou", "万": "man", "億": "oku", "兆": "chou", "割": "wari",
        "倍": "bai", "様": "sama", "殿": "dono",
    ]

    private struct Token {
        let surface: String
        let range: NSRange
        let reading: String?
    }

    /// The word tokens of `text` with their ranges and the tokenizer's Latin
    /// transcription. Punctuation, spaces, and marks with no reading separate
    /// words and are left out.
    private static func wordTokens(of text: String, locale: String) -> [Token] {
        let cfString = text as CFString
        guard let tokenizer = CFStringTokenizerCreate(
            nil,
            cfString,
            CFRangeMake(0, CFStringGetLength(cfString)),
            kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: locale) as CFLocale
        ) else { return [] }
        let nsString = text as NSString
        var tokens: [Token] = []
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType != [] {
            let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let range = NSRange(location: cfRange.location, length: cfRange.length)
            let surface = nsString.substring(with: range)
            if surface.contains(where: { $0.isLetter || $0.isNumber }), isReadinglessMark(surface) == false {
                let reading = CFStringTokenizerCopyCurrentTokenAttribute(
                    tokenizer,
                    kCFStringTokenizerAttributeLatinTranscription
                ) as? String
                tokens.append(Token(surface: surface, range: range, reading: reading))
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return tokens
    }

    /// The Latin reading kept for a token. A Chinese token, or a Japanese one
    /// without kanji, that has no dictionary reading falls back to the system
    /// transliteration. The tokenizer falls back to Mandarin for a kanji its
    /// Japanese dictionary lacks (〇 → líng), and the system transliteration
    /// of a kanji is pinyin too; neither is a Japanese reading, so a Japanese
    /// token with kanji and no Japanese reading has none (nil).
    private static func acceptedReading(of token: Token, japanese: Bool) -> String? {
        if japanese, let fixed = japaneseWholeTokenReadings[token.surface] { return fixed }
        let hasKanji = token.surface.unicodeScalars.contains { DisplayScriptFamily.of($0) == .han }
        if let reading = token.reading,
           DisplayScriptFamily.families(in: reading).isSubset(of: [.latin]),
           japanese == false || isJapaneseReading(reading, ofKanji: hasKanji) {
            return reading
        }
        if japanese, hasKanji { return nil }
        return latinTransliteration(token.surface)
    }

    /// Whether the Japanese tokenizer's reading is a Japanese one. Pinyin
    /// carries tone marks no wāpuro reading uses. A kanji reading also must
    /// not show pinyin spelling Hepburn never has (q, x, zh, a c outside
    /// ch); a macron long vowel (珈琲 kōhī) is Japanese.
    static func isJapaneseReading(_ reading: String, ofKanji hasKanji: Bool) -> Bool {
        guard reading.isEmpty == false,
              reading.unicodeScalars.contains(where: pinyinToneMarks.contains) == false else {
            return false
        }
        guard hasKanji else { return true }
        let lowered = reading.lowercased()
        guard lowered.contains("q") == false, lowered.contains("x") == false, lowered.contains("zh") == false else {
            return false
        }
        return lowered
            .replacingOccurrences(of: "cch", with: "")
            .replacingOccurrences(of: "ch", with: "")
            .contains("c") == false
    }

    /// Tone marks only Hanyu Pinyin uses: acute, caron, and grave vowels, and ü.
    private static let pinyinToneMarks: Set<Unicode.Scalar> = Set(
        "áéíóúǎěǐǒǔàèìòùǘǚǜǖüÁÉÍÓÚǍĚǏǑǓÀÈÌÒÙǗǙǛǕÜ".unicodeScalars
    )

    /// A token ending in small っ/ッ is read "tsu" by the tokenizer, but the
    /// sound doubles the next consonant: なっ + て → natte, まっ + ち → matchi.
    private static func geminated(_ tokens: [(surface: String, reading: String)]) -> [String] {
        var words: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let reading = token.reading.lowercased()
            guard token.surface.hasSuffix("っ") || token.surface.hasSuffix("ッ"),
                  reading.hasSuffix("tsu") else {
                words.append(token.reading)
                index += 1
                continue
            }
            let stem = String(token.reading.dropLast(3))
            if index + 1 < tokens.count,
               let first = tokens[index + 1].reading.lowercased().first,
               "bcdfghjkmprstvwz".contains(first) {
                let doubled = tokens[index + 1].reading.lowercased().hasPrefix("ch") ? "t" : String(first)
                words.append(stem + doubled + tokens[index + 1].reading)
                index += 2
            } else {
                if stem.isEmpty == false { words.append(stem) }
                index += 1
            }
        }
        return words
    }

    private static func latinTransliteration(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        return mutable as String
    }

    /// Converts a tokenizer reading (wāpuro-style) into modified Hepburn
    /// with macrons: long vowels take a macron, syllabic n keeps an
    /// apostrophe only before a vowel or y, and small-kana markers fold into
    /// the preceding consonant (ヴァ → va, ティ → ti).
    static func hepburn(_ reading: String) -> String {
        var value = reading.lowercased()
        value = value.replacingOccurrences(
            of: #"([bcdfghjklmnprstvwz]+)[aeiou]~([aeiou])"#,
            with: "$1$2",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: #"^u~([aeio])"#, with: "w$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "~", with: "")
        value = value.replacingOccurrences(of: #"n'([^aeiouyāēīōū])"#, with: "n$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "cch", with: "tch")
        for (long, macron) in [("ou", "ō"), ("oo", "ō"), ("uu", "ū"), ("aa", "ā"), ("ee", "ē")] {
            value = value.replacingOccurrences(of: long, with: macron)
        }
        return value
    }

    private static func uppercasedFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    /// Particles, and greetings that end in one, read by function in
    /// Hepburn rather than by kana.
    private static let japaneseWholeTokenReadings: [String: String] = [
        "を": "o", "は": "wa", "へ": "e", "こんにちは": "konnichiwa", "こんばんは": "konbanwa",
    ]
}

private extension String {
    /// Keeps letters, digits, apostrophes, hyphens, and the placeholder ○;
    /// drops tokenizer artifacts such as enclosed numerals and stray symbols.
    var trimmedRomanization: String {
        String(unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
                || scalar == "'" || scalar == "-" || scalar == "\u{25CB}"
        })
    }
}
