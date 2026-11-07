import Foundation
import OhiaCore

public enum DraftTone: String, Sendable, Equatable {
    case direct
    case collaborative
    case warm
    case deferential
}

public struct DraftStyleAnalysis: Sendable, Equatable {
    public let formality: ScalarDimension
    public let dominantTone: DraftTone?
    public let toneScore: Double?
    public let toneConfidence: Double?
}

public enum DraftingStyleAnalyzer: Sendable {
    public static func analyze(
        authoredText: String,
        languageID: String?
    ) -> DraftStyleAnalysis? {
        let trimmed = authoredText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let languageFamily = DraftLanguage.familyID(for: languageID)
            ?? DraftLanguage.detectedFamilyID(ofText: trimmed)
        guard languageFamily == "en" else { return nil }

        let tone = dominantTone(in: trimmed)
        return DraftStyleAnalysis(
            formality: FormalityAnalyzer.analyze(trimmed),
            dominantTone: tone?.tone,
            toneScore: tone?.score,
            toneConfidence: tone.map { min($0.score, 0.6) }
        )
    }

    private static func dominantTone(in text: String) -> (tone: DraftTone, score: Double)? {
        let lower = text.lowercased()
        let patternGroups: [(DraftTone, [String], Double)] = [
            (.direct, ["please submit", "need to", "i need", "must", "ensure", "make sure"], 0.2),
            (.collaborative, ["let's", "we could", "together", "shall we", "how about", "what do you think"], 0.2),
            (.warm, ["hope you're", "hope this finds", "thank you so much", "i appreciate", "wonderful", "great to hear", "looking forward"], 0.2),
            (.deferential, ["if you don't mind", "at your convenience", "i'd be grateful", "with your permission", "if it's not too much trouble"], 0.25),
        ]

        var best: (tone: DraftTone, score: Double)?
        for (tone, patterns, increment) in patternGroups {
            let score = min(Double(patterns.count(where: lower.contains)) * increment, 1.0)
            guard score > 0 else { continue }
            if let best, score <= best.score {
                continue
            } else {
                best = (tone, score)
            }
        }
        return best
    }
}
