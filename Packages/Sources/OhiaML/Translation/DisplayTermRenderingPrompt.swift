import Foundation
import OhiaCore

/// One bounded generation that renders untranslated residue into the
/// reader's language: name- and term-sized spans, and whole lines that carry
/// a source-language passage. The model sees the displayed text (where each
/// item sits), the original source for meaning, and established glossary
/// renderings it must reuse.
public enum DisplayTermRenderingPrompt {
    public struct Span: Sendable, Equatable {
        public let text: String
        public let language: String?
        /// A whole displayed line to translate, not a term to render.
        public let isPassage: Bool

        public init(text: String, language: String?, isPassage: Bool = false) {
            self.text = text
            self.language = language
            self.isPassage = isPassage
        }
    }

    public struct EstablishedRendering: Sendable, Equatable {
        public let sourceTerm: String
        public let rendering: String

        public init(sourceTerm: String, rendering: String) {
            self.sourceTerm = sourceTerm
            self.rendering = rendering
        }
    }

    static let cacheKey = "display-term-rendering-v3"
    static let maximumSpans = 24
    static let maximumEstablished = 16
    static let maximumDisplayedCharacters = 1_600
    static let maximumSourceCharacters = 1_600
    static let maximumSpanCharacters = 240
    /// A passage line is translated whole or not at all, so it is never
    /// shortened to fit; a longer line stays untranslated.
    static let maximumPassageCharacters = 1_600
    static let maximumVerbatim = 16

    static let prefix = """
    You fix text shown to a reader: some spans were left in their original \
    language and script instead of the reader's TARGET LANGUAGE. For each \
    numbered SPAN, write what should replace it in the DISPLAYED TEXT.

    Rules:
    - Organizations, departments, teams, committees, offices, roles, titles, \
    events, meetings, documents, and other common terms: give the natural, \
    established TARGET LANGUAGE translation (for example, 人事課 => Personnel \
    Section; 教授会 => Faculty Meeting).
    - Personal names and place names: use the conventional TARGET LANGUAGE \
    form. When none exists, romanize: Japanese in modified Hepburn with \
    macrons, Chinese in Hanyu Pinyin, Korean in Revised Romanization. Render \
    an attached honorific as a title when that is natural (山田先生 => \
    Professor Yamada).
    - Phrases and sentences: translate them fully and faithfully.
    - A span may be a whole sentence or paragraph, partly in the TARGET \
    LANGUAGE already: translate it into one TARGET LANGUAGE line that keeps \
    every fact, number, date, name, link, and address. Text already in the \
    TARGET LANGUAGE stays unchanged.
    - When an ESTABLISHED RENDERING's source term occurs inside a span, use \
    that rendering exactly.
    - Text listed under KEEP VERBATIM stays exactly as written wherever it \
    occurs in a span.
    - For a name or term, give its dictionary form: the rendering a glossary \
    would list, without articles, particles, or words from around the span \
    (教授会 => Faculty Meeting, never "the Faculty Meeting").
    - Apart from KEEP VERBATIM text, a replacement must contain no character \
    of the span's original script, and it must not explain itself.
    - If you cannot render a span, write ? for it.

    Return exactly one line per span, in order, formatted as `N => replacement`, \
    and nothing else.


    """

    /// - Parameter verbatim: text inside the listed spans that must survive
    ///   unchanged: links, addresses, and file names, and on surfaces where
    ///   quoted source wording or the reader's own words are the content,
    ///   those too.
    public static func build(
        spans: [Span],
        targetLanguage: SummarizationTargetLanguage,
        displayedText: String,
        sourceContext: String,
        established: [EstablishedRendering],
        verbatim: [String] = []
    ) -> PrefixCachedPrompt {
        var lines: [String] = []
        lines.append("TARGET LANGUAGE: \(sanitize(targetLanguage.promptDescription))")

        let source = bounded(sourceContext, limit: maximumSourceCharacters)
        if source.isEmpty == false {
            lines.append("SOURCE (original text, for meaning only):\n\(source)")
        }
        lines.append("DISPLAYED TEXT:\n\(bounded(displayedText, limit: maximumDisplayedCharacters))")

        let establishedLines = established.prefix(maximumEstablished).compactMap { entry -> String? in
            let term = sanitize(entry.sourceTerm)
            let rendering = sanitize(entry.rendering)
            guard term.isEmpty == false, rendering.isEmpty == false else { return nil }
            return "- \(term) => \(rendering)"
        }
        if establishedLines.isEmpty == false {
            lines.append((["ESTABLISHED RENDERINGS:"] + establishedLines).joined(separator: "\n"))
        }

        let verbatimLines = verbatim.prefix(maximumVerbatim).compactMap { text -> String? in
            let value = bounded(text, limit: maximumSpanCharacters)
            return value.isEmpty ? nil : "- \(value)"
        }
        if verbatimLines.isEmpty == false {
            lines.append((["KEEP VERBATIM:"] + verbatimLines).joined(separator: "\n"))
        }

        var spanLines = ["SPANS:"]
        for (index, span) in spans.prefix(maximumSpans).enumerated() {
            let language = span.language
                .flatMap(LocalModelLanguageSupport.displayName(for:))
                .map { "(\($0)) " } ?? ""
            let limit = span.isPassage ? maximumPassageCharacters : maximumSpanCharacters
            spanLines.append("\(index + 1). \(language)\(bounded(span.text, limit: limit))")
        }
        lines.append(spanLines.joined(separator: "\n"))
        lines.append("/no_think")

        return PrefixCachedPrompt(
            cacheKey: cacheKey,
            prefix: prefix,
            suffix: lines.joined(separator: "\n\n")
        )
    }

    /// Generous enough for full sentence translations, and for a passage
    /// line about twice its characters, which covers a CJK paragraph
    /// expanding into English; generation stops at the end token, so an
    /// unreached ceiling costs nothing.
    public static func maxTokens(for spans: [Span]) -> Int {
        let bounded = spans.prefix(maximumSpans)
        let perSpan = bounded.reduce(0) { total, span in
            total + (span.isPassage
                ? min(1_024, max(64, span.text.count * 2))
                : min(200, max(24, span.text.count * 4)))
        }
        return min(bounded.contains(where: \.isPassage) ? 3_072 : 1_536, 32 + perSpan)
    }

    /// Parses `N => replacement` lines into 0-based span indexes. Lines that
    /// echo the span before the arrow, number formatting variants, and
    /// wrapping quotes are tolerated; `?`, empty, and duplicate answers are not.
    public static func parse(_ raw: String, spanCount: Int) -> [Int: String] {
        parseAnswers(raw, spanCount: spanCount).renderings
    }

    /// `parse`, plus the indexes whose answer ran on over further unnumbered
    /// lines: such an answer is only the first line of what the model wrote,
    /// so it cannot stand in for a whole passage.
    static func parseAnswers(_ raw: String, spanCount: Int) -> (renderings: [Int: String], continued: Set<Int>) {
        var renderings: [Int: String] = [:]
        var continued = Set<Int>()
        var lastAnswered: Int?
        let cleaned = raw
            .replacingOccurrences(of: #"(?s)<think(?:ing)?>.*?</think(?:ing)?>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in cleaned.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false else { continue }
            guard let arrow = line.range(of: "=>", options: .backwards),
                  let numberMatch = line.range(of: #"^[-*\s]*(\d{1,3})"#, options: .regularExpression),
                  let number = Int(line[numberMatch].filter(\.isNumber)), number >= 1, number <= spanCount else {
                if let lastAnswered { continued.insert(lastAnswered) }
                continue
            }
            lastAnswered = nil
            guard renderings[number - 1] == nil else { continue }
            var value = line[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            for (open, close) in [("\"", "\""), ("`", "`"), ("\u{201C}", "\u{201D}"), ("'", "'")] {
                if value.count > 2, value.hasPrefix(open), value.hasSuffix(close) {
                    value = String(value.dropFirst().dropLast())
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            guard value.isEmpty == false, value != "?" else { continue }
            renderings[number - 1] = value
            lastAnswered = number - 1
        }
        return (renderings, continued)
    }

    /// Whether a parsed replacement is fit to display in the target language.
    static func isAcceptable(_ rendering: String, for span: String, targetLanguage: String) -> Bool {
        let trimmed = rendering.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              trimmed != span,
              trimmed.count <= min(800, max(80, span.count * 10)),
              trimmed.rangeOfCharacter(from: .newlines) == nil,
              trimmed.contains("=>") == false,
              trimmed.uppercased().contains("[[OHIA") == false,
              DisplayLanguageResidue.containsResidue(trimmed, targetLanguage: targetLanguage) == false else {
            return false
        }
        return true
    }

    /// Whether a parsed translation is fit to replace a whole passage line:
    /// one line, not the original, and between a quarter and four times its
    /// width, counted so a Han, kana, or Hangul character weighs two Latin
    /// letters. A truncated or runaway answer fails; the caller checks the
    /// rest for residue.
    static func isAcceptableTranslation(_ translation: String, of passage: String) -> Bool {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceWidth = width(of: source)
        let translationWidth = width(of: trimmed)
        guard trimmed.isEmpty == false,
              trimmed != source,
              translationWidth >= max(1, sourceWidth / 4),
              translationWidth <= max(160, sourceWidth * 4),
              trimmed.rangeOfCharacter(from: .newlines) == nil,
              trimmed.contains("=>") == false,
              trimmed.uppercased().contains("[[OHIA") == false else {
            return false
        }
        return true
    }

    /// Length in Latin-letter units: a Han, kana, or Hangul character
    /// weighs two.
    static func width(of text: String) -> Int {
        text.reduce(0) { total, character in
            let wide = character.unicodeScalars.contains { scalar in
                switch DisplayScriptFamily.of(scalar) {
                case .han, .kana, .hangul: true
                case .latin, .cyrillic, nil: false
                }
            }
            return total + (wide ? 2 : 1)
        }
    }

    /// A rendering fit to become reusable terminology: a short name-like
    /// phrase. Digits, links, addresses, and paths are refused so a crafted
    /// message cannot plant one through the rendering pass.
    static func isMintable(_ rendering: String) -> Bool {
        let trimmed = rendering.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard (1...8).contains(words.count),
              trimmed.count <= TranslationGlossaryCandidateValidator.maximumTermLength,
              trimmed.contains(where: \.isNumber) == false,
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:@<>[]{}|=#?&%")) == nil,
              trimmed.range(of: #"[A-Za-z]\.[A-Za-z]"#, options: .regularExpression) == nil else {
            return false
        }
        return true
    }

    private static func bounded(_ text: String, limit: Int) -> String {
        let value = sanitize(text)
        guard value.count > limit else { return value }
        return String(value.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitize(_ text: String) -> String {
        TranslationPromptBuilder.neutralizeControlTokens(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
