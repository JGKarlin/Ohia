import Foundation
import OhiaCore

/// Deterministically retains the most relevant authored passages from a long
/// message. Selection is lexical and stable; it never invokes a model.
public struct ComposerPassageSelector: Sendable {
    public static let omissionMarker = "[unrelated passage omitted]"

    private let windowSize: Int
    private let overlap: Int
    private let maximumSelectedChunks: Int

    public init(
        windowSize: Int = 384,
        overlap: Int = 128,
        maximumSelectedChunks: Int = 3
    ) {
        self.windowSize = max(1, windowSize)
        self.overlap = max(0, overlap)
        self.maximumSelectedChunks = max(1, maximumSelectedChunks)
    }

    public func select(
        from fullText: String,
        anchorTerms: [String],
        preservingBoundaryChunks: Bool = false
    ) -> String {
        select(
            from: fullText,
            anchorTerms: anchorTerms,
            maximumTokenCount: .max,
            preservingBoundaryChunks: preservingBoundaryChunks,
            tokenCounter: { _ in 0 }
        )
    }

    func cleanedText(from fullText: String) -> String {
        OriginalMessageText.cleaned(from: fullText) ?? ""
    }

    func select(
        from fullText: String,
        anchorTerms: [String],
        maximumTokenCount: Int,
        preservingBoundaryChunks: Bool,
        tokenCounter: @Sendable (String) -> Int
    ) -> String {
        guard maximumTokenCount > 0 else { return "" }
        let cleaned = cleanedText(from: fullText)
        guard cleaned.isEmpty == false else { return "" }

        let chunks = TextChunker.chunk(
            cleaned,
            windowSize: windowSize,
            overlap: overlap
        )
        guard chunks.isEmpty == false else { return "" }

        if chunks.count <= maximumSelectedChunks,
           tokenCounter(cleaned) <= maximumTokenCount {
            return cleaned
        }

        let normalizedAnchorTerms = AskMemoryTokenizer.tokenize(
            anchorTerms.joined(separator: "\n"),
            maxTokens: 256
        )
        let identifiers = distinctiveIdentifiers(in: normalizedAnchorTerms)
        let ranked = chunks.sorted {
            let left = score(
                $0,
                chunkCount: chunks.count,
                anchorTerms: normalizedAnchorTerms,
                identifiers: identifiers
            )
            let right = score(
                $1,
                chunkCount: chunks.count,
                anchorTerms: normalizedAnchorTerms,
                identifiers: identifiers
            )
            if left.identifierMatches != right.identifierMatches {
                return left.identifierMatches > right.identifierMatches
            }
            if left.termCoverage != right.termCoverage {
                return left.termCoverage > right.termCoverage
            }
            if left.boundaryBonus != right.boundaryBonus {
                return left.boundaryBonus > right.boundaryBonus
            }
            return $0.index < $1.index
        }

        var preferred: [TextChunk] = []
        if preservingBoundaryChunks {
            if let first = chunks.first {
                preferred.append(first)
            }
            if let last = chunks.last, last.bodyRange != chunks.first?.bodyRange {
                preferred.append(last)
            }
        }
        preferred.append(contentsOf: ranked)

        var retained: [TextChunk] = []
        for chunk in preferred {
            guard retained.count < maximumSelectedChunks else { break }
            guard retained.contains(where: { $0.bodyRange == chunk.bodyRange }) == false else {
                continue
            }
            let candidate = render(retained + [chunk], from: cleaned)
            guard tokenCounter(candidate) <= maximumTokenCount else { continue }
            retained.append(chunk)
        }

        if retained.isEmpty, let best = preferred.first {
            let passage = render([best], from: cleaned)
            return Self.prefix(
                of: passage,
                fitting: maximumTokenCount,
                tokenCounter: tokenCounter
            )
        }
        return render(retained, from: cleaned)
    }

    private struct Score {
        let identifierMatches: Int
        let termCoverage: Int
        let boundaryBonus: Int
    }

    private func score(
        _ chunk: TextChunk,
        chunkCount: Int,
        anchorTerms: Set<String>,
        identifiers: Set<String>
    ) -> Score {
        let chunkTerms = AskMemoryTokenizer.tokenize(chunk.text, maxTokens: 512)
        return Score(
            identifierMatches: chunkTerms.intersection(identifiers).count,
            termCoverage: chunkTerms.intersection(anchorTerms).count,
            boundaryBonus: (chunk.index == 0 || chunk.index == chunkCount - 1) ? 1 : 0
        )
    }

    private func distinctiveIdentifiers(in terms: Set<String>) -> Set<String> {
        Set(terms.filter { token in
            let scalars = token.unicodeScalars
            let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
            let hasLetter = scalars.contains { CharacterSet.letters.contains($0) }
            return hasDigit && hasLetter && token.count >= 4
        })
    }

    private func render(_ chunks: [TextChunk], from text: String) -> String {
        let sortedRanges = chunks
            .map(\.bodyRange)
            .sorted { left, right in
                if left.lowerBound != right.lowerBound {
                    return left.lowerBound < right.lowerBound
                }
                return left.upperBound < right.upperBound
            }
        guard sortedRanges.isEmpty == false else { return "" }

        var merged: [Range<Int>] = []
        for range in sortedRanges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }

        return merged.compactMap { substring(in: text, utf16Range: $0) }
            .joined(separator: "\n\n\(Self.omissionMarker)\n\n")
    }

    private func substring(in text: String, utf16Range: Range<Int>) -> String? {
        guard let lowerUTF16 = text.utf16.index(
            text.utf16.startIndex,
            offsetBy: utf16Range.lowerBound,
            limitedBy: text.utf16.endIndex
        ),
        let upperUTF16 = text.utf16.index(
            text.utf16.startIndex,
            offsetBy: utf16Range.upperBound,
            limitedBy: text.utf16.endIndex
        ),
        let lower = String.Index(lowerUTF16, within: text),
        let upper = String.Index(upperUTF16, within: text) else {
            return nil
        }
        return String(text[lower..<upper])
    }

    static func prefix(
        of text: String,
        fitting maximumTokens: Int,
        tokenCounter: @Sendable (String) -> Int
    ) -> String {
        guard maximumTokens > 0, text.isEmpty == false else { return "" }
        if tokenCounter(text) <= maximumTokens { return text }

        let scalars = text.unicodeScalars
        var lower = 0
        var upper = scalars.count
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            let candidate = String(scalars.prefix(middle))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if tokenCounter(candidate) <= maximumTokens {
                lower = middle
            } else {
                upper = middle - 1
            }
        }
        return String(scalars.prefix(lower))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
