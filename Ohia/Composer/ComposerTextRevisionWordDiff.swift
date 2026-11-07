// Ohia/Composer/ComposerTextRevisionWordDiff.swift
// Word-level diff between a draft body's text before and after a Revise
// instruction lands, used by ComposerDraftRevisionOverlay to find which
// real words to flash red (left) / green (arrived). Word boundaries come
// from NLTokenizer (Unicode/ICU-based), so an unspaced Japanese sentence
// segments the same way an English one does — naive whitespace-splitting
// would collapse it into one token and make any single-word edit read as a
// whole-sentence rewrite.

import Foundation
import NaturalLanguage

enum ComposerTextRevisionWordDiff {
    struct Diff {
        /// NSRanges (UTF-16, matching `NSTextStorage`/`NSLayoutManager`) of
        /// words present in `old` but not `new`.
        let removed: [NSRange]
        /// NSRanges of words present in `new` but not `old`, in document
        /// order.
        let added: [NSRange]
        /// For each `added[i]`, the range **within `old`** to visually
        /// anchor that word's position to. The overlay draws added words
        /// before the real content ever swaps to `new`, so an added word
        /// has no real position of its own yet — it borrows the live
        /// position of the old-document word it's replacing (a
        /// substitution), or the word immediately before the insertion
        /// point (a pure insertion). `nil` only when `old` has no words at
        /// all before this point (an insertion at the very start of an
        /// otherwise-empty document).
        let addedAnchors: [NSRange?]
    }

    /// Word-level diff between `old` and `new`.
    static func diff(old: String, new: String) -> Diff {
        let oldWords = wordRanges(in: old).map { (text: (old as NSString).substring(with: $0), range: $0) }
        let newWords = wordRanges(in: new).map { (text: (new as NSString).substring(with: $0), range: $0) }
        let ops = lcsDiff(oldWords.map(\.text), newWords.map(\.text))

        var removed: [NSRange] = []
        var added: [NSRange] = []
        var addedAnchors: [NSRange?] = []
        // The old-document range most recently walked past (via `.equal` or
        // `.removed`) — an added word anchors to this, not to whatever's
        // still ahead. A substitution's ops are [.removed, .added]: by the
        // time `.added` runs, `oi` has already stepped past the very word
        // being replaced, so reading `oldWords[oi]` there would anchor to
        // the *next surviving* old word instead of the one leaving — wrong
        // side of the edit for what's easily the most common Revise shape
        // ("change X to Y"). Tracking the last-consumed range instead
        // anchors correctly for both a substitution (anchors to the just-
        // removed word) and a pure insertion (anchors to whatever
        // immediately precedes the insertion point).
        var lastConsumedOldRange: NSRange?
        var oi = 0, ni = 0
        for op in ops {
            switch op {
            case .equal:
                lastConsumedOldRange = oldWords[oi].range
                oi += 1
                ni += 1
            case .removed:
                let range = oldWords[oi].range
                removed.append(range)
                lastConsumedOldRange = range
                oi += 1
            case .added:
                added.append(newWords[ni].range)
                addedAnchors.append(lastConsumedOldRange ?? oldWords.first?.range)
                ni += 1
            }
        }
        return Diff(removed: removed, added: added, addedAnchors: addedAnchors)
    }

    /// All word ranges (UTF-16 `NSRange`) in `text`, in body order.
    static func wordRanges(in text: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(NSRange(range, in: text))
            return true
        }
        return ranges
    }

    private enum Op { case equal, removed, added }

    /// Classic O(n·m) LCS diff over word-text arrays. Email-body-sized
    /// inputs (tens to low hundreds of words) keep this well within budget.
    private static func lcsDiff(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        guard n > 0 || m > 0 else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                ops.append(.equal); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                ops.append(.removed); i += 1
            } else {
                ops.append(.added); j += 1
            }
        }
        while i < n { ops.append(.removed); i += 1 }
        while j < m { ops.append(.added); j += 1 }
        return ops
    }
}
