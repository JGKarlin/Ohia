import Foundation

/// Pure string helpers for the FILES-row secondary line in the locked-node
/// overlay (`LockedAttachmentsList`). Extracted from the view so the
/// i18n-sensitive clause clamp and the locale-formatted word estimate can be
/// unit-tested directly — both are language-agnostic by contract (Japanese
/// summaries terminate on `。`, not `.`; CJK text has no spaces to clamp on).
enum AttachmentReferenceText {
    /// Sentence-ending punctuation across scripts. The brief is clamped to a
    /// single clause, so this must recognize Latin (`.!?`), CJK (`。！？`), and
    /// hard line breaks. No English-only assumptions.
    static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "。", "！", "？", "\n", "\r"
    ]

    /// Approximate characters-per-word for the word estimate. Latin prose runs
    /// ~5.5 chars/word including the trailing space; CJK has no spaces so this
    /// under-counts, which is acceptable for a soft "~N words" hint.
    static let charactersPerWord = 5.5

    /// Upper bound on the brief's length in grapheme clusters before it is
    /// clamped. A first sentence usually fits; a runaway one is cut.
    static let maxBriefCharacters = 110

    /// First clause of a summary — text up to the first sentence terminator,
    /// or a length-clamped prefix when the first sentence runs long. The clamp
    /// backs off to the last word boundary so Latin text never cuts mid-word;
    /// space-free scripts (CJK) keep the grapheme clamp. Returns no trailing
    /// `…`/`...` (banned in displayed text) — the cut is unmarked by design.
    static func firstClause(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var clause = ""
        var reachedTerminator = false
        for character in trimmed {
            if sentenceTerminators.contains(character) {
                reachedTerminator = true
                break
            }
            clause.append(character)
            if clause.count >= maxBriefCharacters { break }
        }

        // Hit the length cap mid-sentence: back off to the last word boundary so
        // the brief never severs a Latin word. If there's no boundary (CJK runs
        // without spaces), keep the grapheme-clamped prefix.
        if !reachedTerminator, clause.count >= maxBriefCharacters,
           let lastBoundary = clause.lastIndex(where: { $0 == " " || $0 == "\u{3000}" }),
           lastBoundary != clause.startIndex {
            clause = String(clause[..<lastBoundary])
        }

        let result = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? trimmed : result
    }

    /// Full catalog description for attachment rows. Collapse layout-hostile
    /// whitespace but never sentence-clamp or length-clamp; the row itself
    /// wraps vertically so the user can read the complete description.
    static func fullDescription(of text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Locale-formatted "~N words" estimate from an extracted character count,
    /// or `nil` when the count is absent or zero.
    static func wordEstimate(fromCharacterCount characterCount: Int?) -> String? {
        guard let characterCount, characterCount > 0 else { return nil }
        let words = max(1, Int((Double(characterCount) / charactersPerWord).rounded()))
        return "~\(words.formatted()) words"
    }
}
