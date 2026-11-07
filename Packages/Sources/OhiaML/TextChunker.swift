import Foundation

public struct TextChunk: Sendable, Equatable {
    public let text: String
    public let index: Int
    public let bodyRange: Range<Int>

    public init(text: String, index: Int, bodyRange: Range<Int>) {
        self.text = text
        self.index = index
        self.bodyRange = bodyRange
    }
}

public enum TextChunker {
    public static func chunk(
        _ text: String,
        windowSize: Int = 384,
        overlap: Int = 128
    ) -> [TextChunk] {
        let wordRanges = Self.wordRanges(in: text, within: text.startIndex..<text.endIndex)
        guard !wordRanges.isEmpty else { return [] }

        let windowSize = max(1, windowSize)
        if wordRanges.count <= windowSize {
            let range = wordRanges[0].lowerBound..<wordRanges[wordRanges.count - 1].upperBound
            return [TextChunk(text: String(text[range]), index: 0, bodyRange: utf16Range(range, in: text))]
        }

        let paragraphs = Self.paragraphs(in: text)
        guard paragraphs.count > 1 else {
            return wordWindowChunks(
                in: text,
                wordRanges: wordRanges,
                windowSize: windowSize,
                overlap: overlap,
                startingIndex: 0
            )
        }

        let overlapWords = max(0, overlap)
        var chunks: [TextChunk] = []
        var current: [Paragraph] = []
        var currentWords = 0

        func appendParagraphRange(_ paragraphs: [Paragraph]) {
            guard let first = paragraphs.first, let last = paragraphs.last else { return }
            let range = first.range.lowerBound..<last.range.upperBound
            chunks.append(TextChunk(
                text: String(text[range]),
                index: chunks.count,
                bodyRange: utf16Range(range, in: text)
            ))
        }

        func flushCurrent() {
            appendParagraphRange(current)
        }

        for paragraph in paragraphs {
            if paragraph.wordCount > windowSize {
                flushCurrent()
                current.removeAll()
                currentWords = 0
                chunks.append(contentsOf: wordWindowChunks(
                    in: text,
                    wordRanges: Self.wordRanges(in: text, within: paragraph.range),
                    windowSize: windowSize,
                    overlap: overlap,
                    startingIndex: chunks.count
                ))
                continue
            }

            if currentWords > 0, currentWords + paragraph.wordCount > windowSize {
                flushCurrent()
                current = overlapSuffix(from: current, targetWords: overlapWords)
                currentWords = current.reduce(0) { $0 + $1.wordCount }
            }

            current.append(paragraph)
            currentWords += paragraph.wordCount
        }

        flushCurrent()
        return chunks
    }

    private static func wordWindowChunks(
        in text: String,
        wordRanges: [Range<String.Index>],
        windowSize: Int,
        overlap: Int,
        startingIndex: Int
    ) -> [TextChunk] {
        let stride = max(1, windowSize - max(0, overlap))
        var chunks: [TextChunk] = []
        var start = 0
        var index = startingIndex

        while start < wordRanges.count {
            let end = min(start + windowSize, wordRanges.count)
            let range = wordRanges[start].lowerBound..<wordRanges[end - 1].upperBound
            chunks.append(TextChunk(text: String(text[range]), index: index, bodyRange: utf16Range(range, in: text)))
            index += 1
            start += stride
        }

        return chunks
    }

    private struct Paragraph {
        let range: Range<String.Index>
        let wordCount: Int
    }

    private static func paragraphs(in text: String) -> [Paragraph] {
        let ranges = paragraphRanges(in: text)
        return ranges.compactMap { range in
            let count = wordRanges(in: text, within: range).count
            guard count > 0 else { return nil }
            return Paragraph(range: range, wordCount: count)
        }
    }

    private static func paragraphRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var paragraphStart: String.Index?
        var lastNonWhitespace: String.Index?
        var consecutiveNewlines = 0
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if isNewline(character) {
                consecutiveNewlines += 1
                if consecutiveNewlines >= 2 {
                    if let start = paragraphStart, let last = lastNonWhitespace {
                        ranges.append(start..<text.index(after: last))
                    }
                    paragraphStart = nil
                    lastNonWhitespace = nil
                }
            } else if isWhitespace(character) {
                // Preserve a pending newline run across spaces on blank lines.
            } else {
                if paragraphStart == nil {
                    paragraphStart = index
                }
                lastNonWhitespace = index
                consecutiveNewlines = 0
            }
            index = text.index(after: index)
        }

        if let start = paragraphStart, let last = lastNonWhitespace {
            ranges.append(start..<text.index(after: last))
        }
        return ranges
    }

    private static func overlapSuffix(from paragraphs: [Paragraph], targetWords: Int) -> [Paragraph] {
        guard targetWords > 0 else { return [] }
        var suffix: [Paragraph] = []
        var total = 0
        for paragraph in paragraphs.reversed() {
            suffix.insert(paragraph, at: 0)
            total += paragraph.wordCount
            if total >= targetWords {
                break
            }
        }
        return suffix
    }

    private static func wordRanges(in text: String, within bounds: Range<String.Index>) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = bounds.lowerBound
        while index < bounds.upperBound {
            while index < bounds.upperBound, isWhitespace(text[index]) {
                index = text.index(after: index)
            }
            guard index < bounds.upperBound else { break }
            let start = index
            while index < bounds.upperBound, !isWhitespace(text[index]) {
                index = text.index(after: index)
            }
            ranges.append(start..<index)
        }
        return ranges
    }

    private static func isNewline(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.newlines.contains($0) }
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func utf16Range(_ range: Range<String.Index>, in text: String) -> Range<Int> {
        let lower = range.lowerBound.samePosition(in: text.utf16) ?? text.utf16.startIndex
        let upper = range.upperBound.samePosition(in: text.utf16) ?? text.utf16.endIndex
        let start = text.utf16.distance(from: text.utf16.startIndex, to: lower)
        let end = text.utf16.distance(from: text.utf16.startIndex, to: upper)
        return start..<end
    }
}
