import Foundation
import OhiaCore

/// Writing systems used by Ohia's supported languages.
enum DisplayScriptFamily: Hashable, Sendable {
    case latin
    case kana
    case han
    case hangul
    case cyrillic

    static func of(_ scalar: Unicode.Scalar) -> DisplayScriptFamily? {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF: .latin
        // ・ (U+30FB) and its halfwidth form are punctuation, not kana.
        case 0x3040...0x30FA, 0x30FC...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: .kana
        // 々 〆 〇 are ideographic iteration and numeral marks; radicals and
        // the supplementary ideograph planes occur in extracted PDF text.
        case 0x2E80...0x2EFF, 0x2F00...0x2FDF, 0x3005...0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0x20000...0x323AF: .han
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF,
             0xFFA0...0xFFDC: .hangul
        case 0x0400...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F: .cyrillic
        default: nil
        }
    }

    static func families(in text: String) -> Set<DisplayScriptFamily> {
        Set(text.unicodeScalars.compactMap(of))
    }
}

/// Finds source-language text that generation left untranslated inside
/// reader-facing output. A span is a maximal run of characters written in a
/// script the target language does not use (Japanese in an English summary,
/// kana in a Chinese one), widened over directly attached numerals so a date
/// or count is rendered whole ("3月15日", not "3" + "月15日"). Shared scripts are
/// never residue, and neither is text inside a URL, email address, or file
/// name, which must stay byte-exact to keep working.
public enum DisplayLanguageResidue {
    public struct Span: Sendable, Equatable {
        public let range: Range<String.Index>
        public let text: String
    }

    /// Scripts a reader of `targetLanguage` expects. Nil for an unsupported
    /// target, which disables the guard instead of guessing.
    static func nativeFamilies(forTarget targetLanguage: String) -> Set<DisplayScriptFamily>? {
        switch LocalModelLanguageSupport.canonicalLanguageID(for: targetLanguage) {
        case "ja": [.han, .kana, .latin]
        case "zh": [.han, .latin]
        case "ko": [.hangul, .latin]
        case "ru": [.cyrillic, .latin]
        case "en", "fr", "de", "es", "pt", "it": [.latin]
        default: nil
        }
    }

    public static func containsResidue(_ text: String, targetLanguage: String) -> Bool {
        spans(in: text, targetLanguage: targetLanguage).isEmpty == false
    }

    /// - Parameters:
    ///   - preservingQuoted: keep spans enclosed in quotation marks or corner
    ///     brackets, for surfaces whose quoted source wording is the content
    ///     itself (an Ask answer quoting Japanese, a Composer option offering
    ///     承知しました).
    ///   - keeping: words the reader wrote, kept verbatim wherever they occur,
    ///     even inside a longer run ("総務チーム宛" leaves only 宛).
    public static func spans(
        in text: String,
        targetLanguage: String,
        preservingQuoted: Bool = false,
        keeping readerWords: [String] = []
    ) -> [Span] {
        guard let native = nativeFamilies(forTarget: targetLanguage),
              text.unicodeScalars.contains(where: { isForeign($0, native: native) }) else {
            return []
        }
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var lastForeignEnd: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if isForeign(character, native: native) {
                if start == nil { start = index }
                lastForeignEnd = next
            } else if start != nil, isInteriorJoiner(character) {
                // Held tentatively: a joiner only belongs to the span when a
                // foreign character follows it.
            } else if let open = start, let end = lastForeignEnd {
                ranges.append(open..<end)
                start = nil
                lastForeignEnd = nil
            }
            index = next
        }
        if let open = start, let end = lastForeignEnd {
            ranges.append(open..<end)
        }

        let widened = merged(ranges.map { widenedOverAttachedNumerals($0, in: text) })
        let excluded = merged(
            protectedRanges(in: text, preservingQuoted: preservingQuoted) + occurrences(of: readerWords, in: text)
        )
        return widened
            .flatMap { outside(excluded, of: $0, in: text, native: native) }
            .map { Span(range: $0, text: String(text[$0])) }
    }

    /// The parts of `range` outside every protected range, each trimmed to
    /// its foreign characters: a link or quote keeps its exact text while the
    /// residue around it ("総務 資料.pdf", "https://x.jp/見積 の件") is still
    /// rendered.
    private static func outside(
        _ protected: [Range<String.Index>],
        of range: Range<String.Index>,
        in text: String,
        native: Set<DisplayScriptFamily>
    ) -> [Range<String.Index>] {
        var pieces: [Range<String.Index>] = []
        var cursor = range.lowerBound
        for excluded in protected where excluded.overlaps(range) {
            if cursor < excluded.lowerBound {
                pieces.append(cursor..<min(excluded.lowerBound, range.upperBound))
            }
            cursor = max(cursor, excluded.upperBound)
        }
        if cursor < range.upperBound {
            pieces.append(cursor..<range.upperBound)
        }
        guard pieces != [range] else { return [range] }
        return pieces.compactMap { piece in
            let foreign = text[piece].indices.filter { isForeign(text[$0], native: native) }
            guard let first = foreign.first, let last = foreign.last else { return nil }
            return first..<text.index(after: last)
        }
    }

    /// Whether a span is a name-sized term that may be minted as a glossary
    /// pair. Sentences, inflected clauses, numbered instances ("第7回"), and
    /// two-character common words (会議, 確認) are rendered in place but never
    /// become reusable terminology.
    public static func isTermLike(_ span: String, language: String) -> Bool {
        let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              trimmed.contains(where: \.isNumber) == false else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        switch LocalModelLanguageSupport.canonicalLanguageID(for: language) {
        case "ja":
            let hiragana = trimmed.unicodeScalars.filter { (0x3041...0x309F).contains($0.value) }.count
            return (3...24).contains(trimmed.count) && hiragana <= 1
        case "zh":
            return (3...16).contains(trimmed.count)
        case "ko":
            return words.count <= 4 && (2...24).contains(trimmed.count)
        case "ru":
            return words.count <= 4 && trimmed.count <= 48
                && words.first?.first?.isUppercase == true
        default:
            return false
        }
    }

    /// Whether a span is a clause or sentence rather than a name or term: the
    /// guard translates a line carrying one whole and never romanizes it.
    /// - Japanese: more than 24 letters (past any term `isTermLike` admits);
    ///   hiragana in two or more places (particles and okurigana, as in
    ///   カードの10月分お支払金額 or お知らせ); a hiragana run carrying an
    ///   inflection or auxiliary (届きました, 開催される); or four or more
    ///   hiragana alone (よろしく). Kanji and katakana compounds such as
    ///   情報学環総務チーム and names with one kana run (みずほ銀行) stay terms.
    /// - Chinese: more than 16 characters, or six or more with two grammatical
    ///   characters (将, 于, 在, 的).
    /// - Korean: more than 24 letters, four or more words, or a predicate
    ///   ending (감사합니다, 열립니다).
    /// - Russian: more than 48 letters or five or more words, three or more
    ///   words opening in lowercase (a clause fragment, never a name), or a
    ///   reflexive verb (состоится).
    public static func isPassage(_ span: String, language: String?) -> Bool {
        let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = trimmed.filter(\.isLetter)
        guard letters.isEmpty == false else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        switch language.flatMap(LocalModelLanguageSupport.canonicalLanguageID(for:)) {
        case "ja":
            if letters.count > 24 { return true }
            var runs: [String] = []
            var run = ""
            for character in letters {
                if character.unicodeScalars.allSatisfy({ (0x3041...0x309F).contains($0.value) }) {
                    run.append(character)
                } else if run.isEmpty == false {
                    runs.append(run)
                    run = ""
                }
            }
            if run.isEmpty == false { runs.append(run) }
            let hiragana = runs.reduce(0) { $0 + $1.count }
            if hiragana == letters.count, hiragana >= 4 { return true }
            if runs.count >= 2 { return true }
            return runs.contains { run in japaneseInflections.contains { run.contains($0) } }
        case "zh":
            if letters.count > 16 { return true }
            return letters.count >= 6 && letters.filter(chineseGrammaticalCharacters.contains).count >= 2
        case "ko":
            if letters.count > 24 || words.count >= 4 { return true }
            return koreanPredicateEndings.contains { trimmed.hasSuffix($0) }
        case "ru":
            if letters.count > 48 || words.count >= 5 { return true }
            if words.count >= 3, words.first?.first?.isLowercase == true { return true }
            return words.contains { $0.count >= 7 && ($0.hasSuffix("ся") || $0.hasSuffix("сь")) }
        default:
            return letters.count > 48
        }
    }

    /// Whether a span a translation kept in the source script reads as a name,
    /// the one kind of kept span romanization may stand in for. Stricter than
    /// "not a passage": the span has two or more characters and no digits (a
    /// date or amount no numeric rendering took whole belongs to a clause),
    /// and
    /// - Japanese: is not hiragana alone, and has at most one hiragana run,
    ///   at its start or end (株式会社みずほ, みずほ銀行); a particle between
    ///   two words (書類を提出, 支払が必要) makes a clause;
    /// - Chinese: has at most 16 characters (the `isTermLike` ceiling) and no
    ///   grammatical character (将, 于, 已);
    /// - Korean: has at most four words and 24 letters, and no word ends in a
    ///   case particle that marks a phrase (에서, 으로, 를) or a predicate;
    /// - Russian: has at most four words and 48 letters and opens in
    ///   uppercase, as `isTermLike` requires.
    public static func isNameLike(_ span: String, language: String?) -> Bool {
        let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.contains(where: isDigit) == false else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        switch language.flatMap(LocalModelLanguageSupport.canonicalLanguageID(for:)) {
        case "ja":
            let characters = Array(trimmed)
            let hiragana = characters.map { character in
                character.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
            }
            guard hiragana.contains(false) else { return false }
            var runs: [Range<Int>] = []
            var start: Int?
            for (offset, isHiragana) in hiragana.enumerated() {
                if isHiragana, start == nil { start = offset }
                if isHiragana == false, let open = start {
                    runs.append(open..<offset)
                    start = nil
                }
            }
            if let open = start { runs.append(open..<characters.count) }
            guard runs.count <= 1 else { return false }
            return runs.first.map { $0.lowerBound == 0 || $0.upperBound == characters.count } ?? true
        case "zh":
            return trimmed.count <= 16 && trimmed.contains(where: chineseGrammaticalCharacters.contains) == false
        case "ko":
            return words.count <= 4
                && trimmed.filter(\.isLetter).count <= 24
                && words.contains { word in koreanPhraseParticles.contains { word.hasSuffix($0) } } == false
                && koreanPredicateEndings.contains { trimmed.hasSuffix($0) } == false
        case "ru":
            return words.count <= 4
                && trimmed.filter(\.isLetter).count <= 48
                && words.first?.first?.isUppercase == true
        default:
            return false
        }
    }

    /// Case particles that end a Korean phrase, never a name.
    private static let koreanPhraseParticles = ["를", "에서", "으로", "에게", "께서", "부터", "까지", "에는", "에도"]

    /// Hiragana sequences that only occur in verb, adjective, and copula
    /// endings or auxiliaries, never inside a name.
    private static let japaneseInflections = [
        "ます", "まし", "ませ", "です", "でし", "ている", "ていま", "ており", "される", "された", "され",
        "れる", "れた", "られ", "ない", "った", "って", "んだ", "んで", "した", "して", "する", "しま",
        "せる", "ください", "あり", "ある", "いる", "おり", "なる", "なっ", "なり", "ため", "よう",
    ]
    private static let chineseGrammaticalCharacters: Set<Character> = [
        "的", "了", "在", "是", "将", "于", "请", "已", "被", "把", "着", "过", "吗", "呢", "吧", "您", "并", "但",
    ]
    private static let koreanPredicateEndings = [
        "니다", "니까", "세요", "십시오", "어요", "아요", "해요", "에요", "예요", "었다", "았다", "겠다", "한다", "된다", "이다",
    ]

    /// The language a residue span was written in. Kana, Hangul, and Cyrillic
    /// identify themselves; a Han-only span follows the source message when it
    /// is Japanese or Chinese, and otherwise Japanese only when the source
    /// context carries kana.
    public static func sourceLanguage(
        ofSpan span: String,
        sourceLanguageHint: String?,
        sourceContext: String
    ) -> String? {
        let families = DisplayScriptFamily.families(in: span)
        if families.contains(.kana) { return "ja" }
        if families.contains(.hangul) { return "ko" }
        if families.contains(.cyrillic) { return "ru" }
        guard families.contains(.han) else { return nil }
        if let hint = sourceLanguageHint.flatMap(LocalModelLanguageSupport.canonicalLanguageID(for:)),
           hint == "ja" || hint == "zh" {
            return hint
        }
        return DisplayScriptFamily.families(in: sourceContext).contains(.kana) ? "ja" : "zh"
    }

    /// Maps CJK typography to Western conventions for targets that do not use
    /// it: fullwidth forms fold to ASCII, corner brackets become quotation
    /// marks, ideographic punctuation becomes its Western equivalent. Every
    /// change is local — a space is added only where the mapped mark now
    /// touches a word — so numbers ("10：00" → "10:00"), indentation, and
    /// list markup are untouched. Japanese and Chinese targets keep their
    /// own typography. Idempotent.
    public static func normalizedTypography(_ text: String, targetLanguage: String) -> String {
        guard let native = nativeFamilies(forTarget: targetLanguage),
              native.contains(.han) == false,
              text.unicodeScalars.contains(where: requiresTypographyMapping) else {
            return text
        }
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(characters.count)
        for (offset, character) in characters.enumerated() {
            let next = offset + 1 < characters.count ? characters[offset + 1] : nil
            guard let scalar = character.unicodeScalars.first,
                  character.unicodeScalars.count == 1,
                  requiresTypographyMapping(scalar) else {
                output.append(character)
                continue
            }
            if let mark = sentencePunctuation[scalar.value] {
                // Ideographic 、。 always end a clause; fullwidth ，．： between
                // digits are number punctuation ("1，000", "10：00").
                let previousIsDigit = output.last.map(isNumeral) == true
                let separatesClause = ideographicClausePunctuation.contains(scalar.value)
                output += mark
                if let next, next.isLetter || (isNumeral(next) && (separatesClause || previousIsDigit == false)) {
                    output += " "
                }
            } else if let opener = openingMarks[scalar.value] {
                if let previous = output.last, previous.isLetter || isNumeral(previous) { output += " " }
                output += opener
            } else if let closer = closingMarks[scalar.value] {
                output += closer
                if let next, next.isLetter || isNumeral(next) { output += " " }
            } else if scalar.value == 0x30FB || scalar.value == 0xFF65 {
                let lead = output.isEmpty || output.last?.isWhitespace == true ? "" : " "
                let trail = next.map { $0.isWhitespace } ?? true ? "" : " "
                output += lead + "\u{00B7}" + trail
            } else if scalar.value == 0x301C || scalar.value == 0xFF5E {
                output += "\u{2013}"
            } else {
                // Remaining fullwidth ASCII forms and the ideographic space.
                output += String(character).precomposedStringWithCompatibilityMapping
            }
        }
        return output
    }

    /// A digit, or the ○ that stands for a blank digit in a template
    /// ("Reply by ○/○ (○).").
    private static func isNumeral(_ character: Character) -> Bool {
        character.isNumber || character == "\u{25CB}"
    }

    // MARK: - Span construction

    private static func isForeign(_ scalar: Unicode.Scalar, native: Set<DisplayScriptFamily>) -> Bool {
        DisplayScriptFamily.of(scalar).map { native.contains($0) == false } ?? false
    }

    private static func isForeign(_ character: Character, native: Set<DisplayScriptFamily>) -> Bool {
        character.unicodeScalars.contains { isForeign($0, native: native) }
    }

    private static func isInteriorJoiner(_ character: Character) -> Bool {
        if character.isNumber { return true }
        return [" ", "\u{3000}", "-", "\u{FF0D}", "&", "\u{FF06}", "\u{00B7}", "\u{30FB}", "\u{FF65}"]
            .contains(character)
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isWholeNumber && character.unicodeScalars.allSatisfy {
            (0x30...0x39).contains($0.value) || (0xFF10...0xFF19).contains($0.value)
        }
    }

    private static let numeralSeparators: Set<Character> = [",", ".", ":", "/", "\u{FF0C}", "\u{FF0E}", "\u{FF1A}", "\u{FF0F}"]

    /// Absorbs digits written directly against the span ("3月", "1,000円",
    /// "令和8") unless they belong to a Latin word ("COVID19対策" keeps
    /// "COVID19" intact).
    private static func widenedOverAttachedNumerals(
        _ range: Range<String.Index>,
        in text: String
    ) -> Range<String.Index> {
        var lower = range.lowerBound
        var cursor = lower
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            let character = text[previous]
            if isDigit(character) {
                cursor = previous
                lower = previous
            } else if numeralSeparators.contains(character),
                      previous > text.startIndex,
                      isDigit(text[text.index(before: previous)]),
                      lower != range.lowerBound || isDigit(text[cursor]) {
                cursor = previous
            } else {
                break
            }
        }
        if lower < range.lowerBound, lower > text.startIndex, text[text.index(before: lower)].isLetter {
            lower = range.lowerBound
        }

        var upper = range.upperBound
        cursor = upper
        while cursor < text.endIndex {
            let character = text[cursor]
            let next = text.index(after: cursor)
            if isDigit(character) {
                cursor = next
                upper = next
            } else if numeralSeparators.contains(character),
                      upper != range.upperBound,
                      next < text.endIndex,
                      isDigit(text[next]) {
                cursor = next
            } else {
                break
            }
        }
        if upper > range.upperBound, upper < text.endIndex, text[upper].isLetter {
            upper = range.upperBound
        }
        return lower..<upper
    }

    private static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: - Protected text

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// Scheme URLs, including internationalized hosts and paths the data
    /// detector does not recognize; they end at whitespace or CJK punctuation.
    private static let urlPattern = try? NSRegularExpression(
        pattern: #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s<>"'「」『』（）()、。，]+"#
    )
    /// ASCII local part, any domain labels, ASCII top-level domain.
    private static let emailPattern = try? NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+\-]+@[^\s@<>()\[\]"'「」『』、。，]+?\.[A-Za-z]{2,}(?![A-Za-z])"#
    )
    /// A token ending in a common document, image, archive, or media
    /// extension.
    private static let fileNamePattern = try? NSRegularExpression(
        pattern: #"[^\s"'“”「」『』()（）\[\]【】<>、。，]+\.(?:pdf|docx?|xlsx?|xlsm|pptx?|csv|tsv|txt|rtf|md|json|xml|html?|zip|7z|rar|jpe?g|png|gif|heic|tiff?|webp|key|pages|numbers|eml|ics|mp3|mp4|m4a|mov|wav)(?![A-Za-z0-9])"#,
        options: [.caseInsensitive]
    )
    private static let quotedPatterns: [NSRegularExpression] = [
        #"「[^「」]*」"#, #"『[^『』]*』"#, #"“[^“”]*”"#, #""[^"\n]*""#, #"‘[^‘’]*’"#, #"`[^`\n]*`"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// The links, email addresses, and file names in `text`. A translation of
    /// the text must carry each one byte-exact to keep it working.
    static func protectedTexts(in text: String) -> [String] {
        merged(protectedRanges(in: text, preservingQuoted: false)).map { String(text[$0]) }
    }

    /// The wording inside quotation marks or corner brackets that is written
    /// in a script `targetLanguage` does not use: where quoted source wording
    /// is the content, a translation keeps it verbatim.
    static func quotedResidue(in text: String, targetLanguage: String) -> [String] {
        guard let native = nativeFamilies(forTarget: targetLanguage) else { return [] }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return quotedPatterns
            .flatMap { $0.matches(in: text, range: whole) }
            .compactMap { Range($0.range, in: text) }
            .map { String(text[$0].dropFirst().dropLast()) }
            .filter { $0.unicodeScalars.contains { isForeign($0, native: native) } }
    }

    /// The reader's own source-script words in a text they wrote.
    public static func readerWords(in readerText: String?, targetLanguage: String) -> [String] {
        guard let readerText, readerText.isEmpty == false else { return [] }
        var seen = Set<String>()
        return spans(in: readerText, targetLanguage: targetLanguage)
            .map(\.text)
            .filter { seen.insert($0).inserted }
    }

    private static func occurrences(of words: [String], in text: String) -> [Range<String.Index>] {
        words.filter { $0.isEmpty == false }.flatMap { word -> [Range<String.Index>] in
            var found: [Range<String.Index>] = []
            var searchStart = text.startIndex
            while searchStart < text.endIndex, let range = text.range(of: word, range: searchStart..<text.endIndex) {
                found.append(range)
                searchStart = range.upperBound
            }
            return found
        }
    }

    private static func protectedRanges(in text: String, preservingQuoted: Bool) -> [Range<String.Index>] {
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        var expressions: [NSRegularExpression] = [urlPattern, emailPattern, fileNamePattern].compactMap { $0 }
        if preservingQuoted { expressions += quotedPatterns }
        var ranges = expressions.flatMap { expression in
            expression.matches(in: text, range: whole).compactMap { Range($0.range, in: text) }
        }
        if let linkDetector {
            ranges += linkDetector.matches(in: text, range: whole).compactMap { Range($0.range, in: text) }
        }
        return ranges
    }

    // MARK: - Typography tables

    private static func requiresTypographyMapping(_ scalar: Unicode.Scalar) -> Bool {
        sentencePunctuation[scalar.value] != nil
            || openingMarks[scalar.value] != nil
            || closingMarks[scalar.value] != nil
            || (0xFF01...0xFF5E).contains(scalar.value)
            || [0x3000, 0x30FB, 0xFF65, 0x301C].contains(scalar.value)
    }

    private static let ideographicClausePunctuation: Set<UInt32> = [0x3001, 0x3002, 0xFF61, 0xFF64]
    private static let sentencePunctuation: [UInt32: String] = [
        0x3001: ",", 0x3002: ".", 0xFF0C: ",", 0xFF0E: ".", 0xFF61: ".", 0xFF64: ",",
        0xFF1A: ":", 0xFF1B: ";", 0xFF01: "!", 0xFF1F: "?",
    ]
    private static let openingMarks: [UInt32: String] = [
        0x300C: "\u{201C}", 0x300E: "\u{2018}", 0xFF62: "\u{201C}",
        0x3010: "[", 0x3014: "[", 0x3016: "[", 0xFF3B: "[", 0xFF08: "(",
        0x3008: "\u{2039}", 0x300A: "\u{00AB}",
    ]
    private static let closingMarks: [UInt32: String] = [
        0x300D: "\u{201D}", 0x300F: "\u{2019}", 0xFF63: "\u{201D}",
        0x3011: "]", 0x3015: "]", 0x3017: "]", 0xFF3D: "]", 0xFF09: ")",
        0x3009: "\u{203A}", 0x300B: "\u{00BB}",
    ]
}
