import Foundation

/// Heuristic analyzer that scores email formality on a 0.0 (casual) to 1.0 (formal) scale.
public enum FormalityAnalyzer {

    public static func analyze(_ text: String) -> ScalarDimension {
        guard !text.isEmpty else {
            return ScalarDimension(value: 0.5, confidence: 0.0)
        }

        let lower = text.lowercased()
        var signals: [Double] = []
        var evidenceSpans: [EvidenceSpan] = []

        // --- 1. Salutations ---
        let salutations: [(String, Double)] = [
            ("dear ", 0.9),
            ("hey ", 0.15),
            ("hi ", 0.5),
        ]
        for (phrase, score) in salutations {
            if let range = lower.range(of: phrase) {
                signals.append(score)
                let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let end = lower.distance(from: lower.startIndex, to: range.upperBound)
                // Use actual casing from source for evidence
                let sourceRange = text.index(text.startIndex, offsetBy: start) ..<
                                  text.index(text.startIndex, offsetBy: end)
                evidenceSpans.append(EvidenceSpan(start: start, end: end, text: String(text[sourceRange])))
                break  // only the first salutation match counts
            }
        }

        // --- 2. Closings ---
        let closings: [(String, Double)] = [
            ("with kind regards", 0.85),
            ("sincerely", 0.85),
            ("cheers", 0.2),
            ("thx", 0.2),
            ("thanks", 0.5),
        ]
        for (phrase, score) in closings {
            if lower.contains(phrase) {
                signals.append(score)
                break  // only the first closing match counts
            }
        }

        // --- 3. Average sentence length ---
        let sentenceScore = averageSentenceLengthScore(text)
        signals.append(sentenceScore)

        // --- 4. Contraction density ---
        let contractionScore = contractionDensityScore(lower)
        signals.append(contractionScore)

        // --- 5. Lowercase shortcuts ---
        let shortcuts = ["lmk", "thx", "pls", "fyi", "btw"]
        for shortcut in shortcuts {
            // Match as whole word to avoid partial matches
            let pattern = "\\b\(shortcut)\\b"
            if let _ = lower.range(of: pattern, options: .regularExpression) {
                signals.append(0.1)
                break  // one strong casual signal is enough
            }
        }

        // --- Average and clamp ---
        let rawValue = signals.reduce(0.0, +) / Double(signals.count)
        let clamped = max(0.0, min(1.0, rawValue))

        // Confidence scales with signal count; max ~0.7 at 5 signals
        let confidence = min(0.7, Double(signals.count) / 5.0 * 0.7)

        return ScalarDimension(value: clamped, confidence: confidence, evidenceSpans: evidenceSpans)
    }

    // MARK: - Private helpers

    private static func averageSentenceLengthScore(_ text: String) -> Double {
        // Split on sentence-ending punctuation
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !sentences.isEmpty else { return 0.45 }

        let totalWords = sentences.reduce(0) { $0 + wordCount($1) }
        let avgLength = Double(totalWords) / Double(sentences.count)

        switch avgLength {
        case let l where l > 18: return 0.8
        case let l where l > 12: return 0.6
        case let l where l > 7:  return 0.45
        default:                  return 0.25
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .count
    }

    private static func contractionDensityScore(_ lower: String) -> Double {
        // Common English contractions
        let contractions = [
            "n't", "'re", "'ve", "'ll", "'d", "'m", "'s",
            "i'm", "you're", "we're", "they're",
            "i've", "you've", "we've", "they've",
            "i'll", "you'll", "we'll", "they'll",
            "i'd", "you'd", "we'd", "they'd",
            "isn't", "aren't", "wasn't", "weren't",
            "don't", "doesn't", "didn't",
            "can't", "couldn't", "won't", "wouldn't",
            "it's", "that's", "there's", "here's",
        ]

        let words = lower.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return 0.65 }

        var contractionCount = 0
        for contraction in contractions {
            // Count occurrences of each contraction
            var searchRange = lower.startIndex ..< lower.endIndex
            while let found = lower.range(of: contraction, range: searchRange) {
                contractionCount += 1
                searchRange = found.upperBound ..< lower.endIndex
            }
        }

        let rate = Double(contractionCount) / Double(words.count)

        switch rate {
        case let r where r > 0.05: return 0.2
        case let r where r > 0.02: return 0.4
        default:                    return 0.65
        }
    }
}
