import Foundation
import NaturalLanguage

/// Splits text into windows that fit an embedding model's input, measured with
/// the model's own tokenizer rather than words or characters, so text in any
/// script is covered in full instead of being cut off at the model's limit.
///
/// A window breaks at the largest boundary that fits: paragraph, then
/// sentence, then word, then character. Sentence and word boundaries come from
/// `NLTokenizer`, which also segments languages written without spaces. Every
/// window is measured as a whole before it is returned, so it never exceeds
/// its capacity even where tokenization across a boundary differs from the sum
/// of its parts.
public enum EmbeddingChunker {

    /// A span longer than `capacity × this` characters is split before it is
    /// measured. The tokenizer's cost grows with the square of an unbroken
    /// run's length. Japanese and Chinese run about one to one and a half
    /// characters per token, so a longer span would be measured only to be
    /// split anyway; an English span this long that would have fitted is
    /// split into sentences and packed back into the same window.
    static let directMeasurementCharactersPerToken = 2

    /// Splits `text` into windows of at most `capacity` content tokens.
    /// Consecutive windows share up to `overlap` tokens of whole segments so a
    /// passage that straddles a boundary is still embedded together somewhere.
    /// Each chunk's `bodyRange` is its UTF-16 range in `text`.
    public static func chunk(
        _ text: String,
        capacity: Int,
        overlap: Int,
        tokenizer: any EmbeddingDocumentTokenizing
    ) -> [TextChunk] {
        guard capacity > 0 else { return [] }
        let segmenter = Segmenter(text: text, capacity: capacity, tokenizer: tokenizer, stopAfterTokens: nil)
        let windows: [Range<String.Index>]
        if let whole = segmenter.wholeTextIfItFits() {
            windows = [whole]
        } else {
            windows = pack(
                segmenter.segments(),
                in: text,
                capacity: capacity,
                overlap: overlap,
                tokenizer: tokenizer,
                firstWindowOnly: false
            )
        }
        return windows.enumerated().map { index, range in
            TextChunk(
                text: String(text[range]),
                index: index,
                bodyRange: TextChunker.utf16Range(range, in: text)
            )
        }
    }

    /// The longest leading part of `text`, ending on the largest boundary that
    /// fits, whose content tokens are at most `capacity`. Returns the whole
    /// text, trimmed, when it fits.
    public static func prefix(
        of text: String,
        fitting capacity: Int,
        tokenizer: any EmbeddingDocumentTokenizing
    ) -> String {
        guard capacity > 0 else { return "" }
        let segmenter = Segmenter(text: text, capacity: capacity, tokenizer: tokenizer, stopAfterTokens: capacity)
        if let whole = segmenter.wholeTextIfItFits() {
            return String(text[whole])
        }
        let windows = pack(
            segmenter.segments(),
            in: text,
            capacity: capacity,
            overlap: 0,
            tokenizer: tokenizer,
            firstWindowOnly: true
        )
        guard let first = windows.first else { return "" }
        return String(text[first])
    }

    // MARK: - Packing

    private static func pack(
        _ segments: [Segment],
        in text: String,
        capacity: Int,
        overlap: Int,
        tokenizer: any EmbeddingDocumentTokenizing,
        firstWindowOnly: Bool
    ) -> [Range<String.Index>] {
        var windows: [Range<String.Index>] = []
        let overlap = min(max(0, overlap), capacity / 2)
        var start = 0
        while start < segments.count {
            var end = start
            var estimatedTokens = 0
            while end < segments.count, estimatedTokens + segments[end].tokens <= capacity {
                estimatedTokens += segments[end].tokens
                end += 1
            }
            // Only a single character that alone exceeds the capacity can be
            // larger than a window; emit it on its own rather than stall.
            if end == start {
                end = start + 1
            }
            while end - start > 1,
                  tokenizer.contentTokenCount(
                      String(text[segments[start].range.lowerBound..<segments[end - 1].range.upperBound])
                  ) > capacity {
                end -= 1
            }
            windows.append(segments[start].range.lowerBound..<segments[end - 1].range.upperBound)
            if firstWindowOnly || end >= segments.count {
                break
            }

            // Carry trailing whole segments into the next window, never
            // reaching back to this window's first segment, so every window
            // advances.
            var next = end
            var carriedTokens = 0
            while next - 1 > start, carriedTokens + segments[next - 1].tokens <= overlap {
                next -= 1
                carriedTokens += segments[next].tokens
            }
            start = next
        }
        return windows
    }

    // MARK: - Segmentation

    private struct Segment {
        let range: Range<String.Index>
        let tokens: Int
    }

    /// How to split a span that does not fit.
    private enum SplitLevel {
        case sentences
        case words
        case characters
    }

    /// Breaks text into consecutive measured segments, each at most `capacity`
    /// tokens, in reading order.
    private final class Segmenter {
        let text: String
        let capacity: Int
        let tokenizer: any EmbeddingDocumentTokenizing
        let stopAfterTokens: Int?

        private var collected: [Segment] = []
        private var collectedTokens = 0
        private var sentenceTokenizer: NLTokenizer?
        private var wordTokenizer: NLTokenizer?

        init(
            text: String,
            capacity: Int,
            tokenizer: any EmbeddingDocumentTokenizing,
            stopAfterTokens: Int?
        ) {
            self.text = text
            self.capacity = capacity
            self.tokenizer = tokenizer
            self.stopAfterTokens = stopAfterTokens
        }

        private var directMeasurementLimit: Int {
            capacity * EmbeddingChunker.directMeasurementCharactersPerToken
        }

        /// A prefix only needs segments up to the first window.
        private var isFull: Bool {
            guard let stopAfterTokens else { return false }
            return collectedTokens > stopAfterTokens
        }

        func wholeTextIfItFits() -> Range<String.Index>? {
            guard let whole = trimmed(text.startIndex..<text.endIndex),
                  isShortEnoughToMeasure(whole) else {
                return nil
            }
            return tokenizer.contentTokenCount(String(text[whole])) <= capacity ? whole : nil
        }

        func segments() -> [Segment] {
            for paragraph in TextChunker.paragraphRanges(in: text) {
                guard !isFull else { break }
                append(paragraph, ifTooLarge: .sentences, knownTooLarge: false)
            }
            return collected
        }

        private func append(_ range: Range<String.Index>, ifTooLarge level: SplitLevel, knownTooLarge: Bool) {
            guard !isFull, let range = trimmed(range) else { return }
            if !knownTooLarge, isShortEnoughToMeasure(range) {
                let tokens = tokenizer.contentTokenCount(String(text[range]))
                if tokens <= capacity {
                    add(Segment(range: range, tokens: tokens))
                    return
                }
            }
            switch level {
            case .sentences:
                split(range, at: boundaries(in: range, unit: .sentence), ifPiecesTooLarge: .words)
            case .words:
                split(range, at: boundaries(in: range, unit: .word), ifPiecesTooLarge: .characters)
            case .characters:
                appendCharacterPieces(range)
            }
        }

        private func split(
            _ range: Range<String.Index>,
            at boundaries: [String.Index],
            ifPiecesTooLarge nextLevel: SplitLevel
        ) {
            guard !boundaries.isEmpty else {
                // No boundary of this kind inside the span; it is already
                // known not to fit, so go straight to the finer level.
                append(range, ifTooLarge: nextLevel, knownTooLarge: true)
                return
            }
            var lower = range.lowerBound
            for upper in boundaries + [range.upperBound] {
                guard !isFull else { return }
                append(lower..<upper, ifTooLarge: nextLevel, knownTooLarge: false)
                lower = upper
            }
        }

        /// Interior positions where a sentence or word starts. The span is
        /// tokenized on its own so its own language is recognized: see
        /// `TextBoundaries`.
        private func boundaries(in range: Range<String.Index>, unit: NLTokenUnit) -> [String.Index] {
            TextBoundaries.interiorStarts(in: text, range: range, using: nlTokenizer(for: unit))
        }

        private func nlTokenizer(for unit: NLTokenUnit) -> NLTokenizer {
            switch unit {
            case .sentence:
                if let sentenceTokenizer { return sentenceTokenizer }
                let made = NLTokenizer(unit: .sentence)
                sentenceTokenizer = made
                return made
            default:
                if let wordTokenizer { return wordTokenizer }
                let made = NLTokenizer(unit: .word)
                wordTokenizer = made
                return made
            }
        }

        /// Last resort for an unbroken run longer than a window, such as an
        /// encoded blob or a very long URL: the largest piece that fits,
        /// halving from `capacity` characters.
        private func appendCharacterPieces(_ range: Range<String.Index>) {
            var lower = range.lowerBound
            while lower < range.upperBound, !isFull {
                var length = capacity
                while true {
                    let upper = text.index(lower, offsetBy: length, limitedBy: range.upperBound) ?? range.upperBound
                    let tokens = tokenizer.contentTokenCount(String(text[lower..<upper]))
                    if tokens <= capacity || length == 1 {
                        add(Segment(range: lower..<upper, tokens: tokens))
                        lower = upper
                        break
                    }
                    length = max(1, length / 2)
                }
            }
        }

        private func add(_ segment: Segment) {
            collected.append(segment)
            collectedTokens += segment.tokens
        }

        private func isShortEnoughToMeasure(_ range: Range<String.Index>) -> Bool {
            guard let limitIndex = text.index(
                range.lowerBound,
                offsetBy: directMeasurementLimit,
                limitedBy: range.upperBound
            ) else {
                return true
            }
            return limitIndex == range.upperBound
        }

        private func trimmed(_ range: Range<String.Index>) -> Range<String.Index>? {
            var lower = range.lowerBound
            var upper = range.upperBound
            while lower < upper, text[lower].isWhitespace {
                lower = text.index(after: lower)
            }
            while upper > lower, text[text.index(before: upper)].isWhitespace {
                upper = text.index(before: upper)
            }
            return lower < upper ? lower..<upper : nil
        }
    }
}
