// TranslationBodyChunker.swift
// Splits long email bodies into translation-sized segments, preferring paragraph
// boundaries and falling back to whitespace-aware hard splits (e.g. CJK). Used by
// the Apple Translation API translator, which batches every chunk through one
// `TranslationSession` so the whole body is translated in a single pass.

import Foundation

enum TranslationBodyChunker {
    /// Splits a body into translation chunks that each fit within `budget`
    /// characters, preferring paragraph boundaries and falling back to a
    /// whitespace-aware hard split for paragraphs that exceed the budget on
    /// their own (e.g. CJK text with no spaces). Pure and deterministic so it
    /// can be unit-tested without a model.
    static func chunks(for body: String, budget: Int) -> [String] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        let safeBudget = max(200, budget)
        if trimmed.count <= safeBudget { return [trimmed] }

        var units: [String] = []
        for paragraph in trimmed.components(separatedBy: "\n\n") {
            var rest = paragraph
            while rest.count > safeBudget {
                let splitIndex = bestSplitIndex(in: rest, limit: safeBudget)
                let head = String(rest[..<splitIndex]).trimmingCharacters(in: .whitespaces)
                if head.isEmpty == false { units.append(head) }
                rest = String(rest[splitIndex...])
            }
            let tail = rest.trimmingCharacters(in: .whitespaces)
            if tail.isEmpty == false { units.append(tail) }
        }

        var chunks: [String] = []
        var current = ""
        for unit in units {
            if current.isEmpty {
                current = unit
            } else if current.count + 2 + unit.count <= safeBudget {
                current += "\n\n" + unit
            } else {
                chunks.append(current)
                current = unit
            }
        }
        if current.isEmpty == false { chunks.append(current) }
        return chunks
    }

    /// Returns an index at or before `limit` that falls on a whitespace/newline
    /// boundary when possible, so a hard split doesn't cut mid-word. Falls back
    /// to the hard character limit (e.g. for scripts without spaces). Always
    /// makes forward progress (never returns `startIndex` for a non-empty input).
    static func bestSplitIndex(in text: String, limit: Int) -> String.Index {
        let clampedLimit = min(max(limit, 1), text.count)
        let hardLimit = text.index(text.startIndex, offsetBy: clampedLimit)
        let window = text[text.startIndex..<hardLimit]
        if let separator = window.range(
            of: "\\s",
            options: [.regularExpression, .backwards]
        ), separator.upperBound > text.startIndex {
            return separator.upperBound
        }
        return hardLimit
    }
}
