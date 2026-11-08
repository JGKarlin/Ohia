import Foundation
import NaturalLanguage

/// Where sentences and words start inside part of a text, from `NLTokenizer`.
///
/// Each part is tokenized on its own so NLTokenizer judges the part's own
/// language. Given a whole text, it applies the language of the text's
/// opening to everything after it, so an English opening leaves later
/// Japanese or Chinese without sentence or word breaks.
enum TextBoundaries {
    /// Positions strictly inside `range` where a `unit` starts, ascending.
    /// `tokenizer` must have been made for `unit`; its string is replaced.
    static func interiorStarts(
        in text: String,
        range: Range<String.Index>,
        using tokenizer: NLTokenizer
    ) -> [String.Index] {
        guard range.isEmpty == false else { return [] }
        let local = String(text[range])
        tokenizer.string = local
        var starts: [String.Index] = []
        // The local copy has exactly the scalars of `text[range]`, so a
        // position maps across by its scalar offset. Tokens arrive in order,
        // so both cursors only move forward.
        var localCursor = local.startIndex
        var globalCursor = range.lowerBound
        tokenizer.enumerateTokens(in: local.startIndex..<local.endIndex) { tokenRange, _ in
            let localStart = tokenRange.lowerBound
            guard localStart > localCursor else { return true }
            let scalarOffset = local.unicodeScalars.distance(from: localCursor, to: localStart)
            globalCursor = text.unicodeScalars.index(globalCursor, offsetBy: scalarOffset)
            localCursor = localStart
            let isInterior = globalCursor > range.lowerBound && range.upperBound > globalCursor
            if isInterior, globalCursor > (starts.last ?? range.lowerBound) {
                starts.append(globalCursor)
            }
            return true
        }
        return starts
    }

    /// Whether `characters` include a script written without spaces between
    /// words: Chinese characters, Japanese kana, Thai, Lao, Khmer, Myanmar,
    /// Tibetan. Korean separates words with spaces and is not included.
    static func containsScriptWithoutWordSpaces(_ characters: Substring) -> Bool {
        characters.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0EFF,     // Thai, Lao
                 0x0F00...0x0FFF,     // Tibetan
                 0x1000...0x109F,     // Myanmar
                 0x1780...0x17FF,     // Khmer
                 0x3040...0x30FF,     // Hiragana, Katakana
                 0x31F0...0x31FF,     // Katakana phonetic extensions
                 0x3400...0x4DBF,     // CJK extension A
                 0x4E00...0x9FFF,     // CJK unified ideographs
                 0xF900...0xFAFF,     // CJK compatibility ideographs
                 0xFF66...0xFF9F,     // Halfwidth katakana
                 0x20000...0x323AF:   // CJK extensions B and later
                return true
            default:
                return false
            }
        }
    }
}
