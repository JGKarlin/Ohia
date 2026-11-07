import Foundation

/// Parses a user's Search-tab input into an FTS5 MATCH expression plus the
/// display metadata the tab needs (constituent terms, phrase). The engine is
/// **exact-biased**: it finds literal terms / phrases / substrings, never the
/// semantic blend Ask uses. Language-agnostic — the underlying FTS index uses
/// a trigram tokenizer, so substrings, numbers, symbols, and CJK all match
/// literally (subject to the trigram minimum of 3 characters).
///
/// Modes:
///   - **Phrase** — the input is wrapped in straight double quotes, OR it is
///     a single whitespace-delimited word. The expression is an FTS5 phrase
///     (contiguous trigram sequence ⇒ substring match).
///   - **Terms** — multiple unquoted words. The expression is an `AND` of each
///     word's phrase, so every word must appear (precise literal finder, no
///     OR-fusion, no diversification).
///
/// Words shorter than the trigram minimum are kept for the display breakdown
/// but, if *every* word is too short, the whole input falls back to a single
/// phrase so a short contiguous string ("to do") can still match.
public struct LexicalQuery: Sendable, Equatable {
    /// Minimum characters for a token to be matchable by the trigram tokenizer.
    static let trigramMinimum = 3

    public let raw: String
    public let isPhrase: Bool
    /// Constituent words, in input order, for the per-term breakdown.
    public let displayTerms: [String]
    /// The contiguous phrase to count as a secondary stat in terms-mode
    /// (nil in phrase-mode or for a single term).
    public let phraseText: String?
    /// The assembled, unscoped FTS5 MATCH expression.
    public let ftsExpression: String

    public init?(_ rawInput: String) {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.raw = trimmed

        // Explicit phrase: surrounded by straight double quotes with content.
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            let inner = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !inner.isEmpty else { return nil }
            self.isPhrase = true
            self.displayTerms = Self.words(in: inner)
            self.phraseText = nil
            self.ftsExpression = Self.phraseExpression(inner)
            return
        }

        let words = Self.words(in: trimmed)
        guard !words.isEmpty else {
            // No whitespace-delimited words (e.g. a bare symbol run). Treat the
            // whole input as one literal phrase.
            self.isPhrase = true
            self.displayTerms = [trimmed]
            self.phraseText = nil
            self.ftsExpression = Self.phraseExpression(trimmed)
            return
        }

        if words.count == 1 {
            self.isPhrase = true
            self.displayTerms = words
            self.phraseText = nil
            self.ftsExpression = Self.phraseExpression(words[0])
            return
        }

        // Multiple words. Match on the trigram-viable ones; if none are
        // viable, fall back to a single phrase of the whole input.
        let matchable = words.filter { $0.count >= Self.trigramMinimum }
        self.displayTerms = words
        self.phraseText = trimmed
        if matchable.isEmpty {
            self.isPhrase = true
            self.ftsExpression = Self.phraseExpression(trimmed)
        } else {
            self.isPhrase = false
            self.ftsExpression = matchable
                .map { Self.phraseExpression($0) }
                .joined(separator: " AND ")
        }
    }

    /// Whitespace-delimited words, preserving internal punctuation / symbols so
    /// literal tokens like `¥1,820,000` survive as one term.
    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Wraps a token as an FTS5 phrase (double-quoted, internal quotes doubled).
    public static func phraseExpression(_ token: String) -> String {
        let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
