import Foundation
import NaturalLanguage

public enum ReplyClassification: Sendable, Equatable {
    case include
    case lowWeight
    case exclude
}

public enum TrivialReplyFilter {
    private static let trivialPatterns: Set<String> = [
        "thanks", "thank you", "thx", "ty",
        "ok", "okay", "k",
        "got it", "noted", "received",
        "sounds good", "sounds great", "perfect",
        "will do", "on it", "done",
        "yes", "no", "yep", "nope", "sure",
        "great", "good", "nice", "cool",
        "acknowledged", "ack",
        "ありがとう", "ありがとうございます", "了解", "了解です", "承知しました",
        "はい", "いいえ", "オッケー",
        "👍", "+1",
    ]

    public static func classify(_ text: String) -> ReplyClassification {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .exclude }

        let normalized = trimmed
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            .trimmingCharacters(in: .whitespaces)

        if trivialPatterns.contains(normalized) {
            return .exclude
        }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed
        let range = trimmed.startIndex..<trimmed.endIndex
        let wordCount = tokenizer.tokens(for: range).count
        let semanticCharacterCount = trimmed.unicodeScalars.reduce(into: 0) { count, scalar in
            guard !CharacterSet.whitespacesAndNewlines.contains(scalar),
                  !CharacterSet.punctuationCharacters.contains(scalar),
                  !CharacterSet.symbols.contains(scalar) else { return }
            count += 1
        }

        // No-space scripts do not reliably map to whitespace words. A real
        // sentence survives on its semantic character count, while terse
        // acknowledgments remain excluded by the explicit patterns/threshold.
        if wordCount <= 2, semanticCharacterCount < 8 { return .exclude }
        if wordCount <= 15 || semanticCharacterCount < 40 { return .lowWeight }
        return .include
    }
}
