import Foundation

/// Heuristic analyzer that scores email urgency on a 0.0 (not urgent) to 1.0 (very urgent) scale.
public enum UrgencyAnalyzer {

    public static func analyze(_ text: String) -> ScalarDimension {
        guard !text.isEmpty else {
            return ScalarDimension(value: 0.0, confidence: 0.0)
        }

        let lower = text.lowercased()
        var score = 0.0
        var evidenceSpans: [EvidenceSpan] = []
        var evidenceCount = 0

        // --- 1. High-urgency keywords ---
        let urgentKeywords: [(String, Double)] = [
            ("emergency", 0.35),
            ("urgent", 0.3),
            ("immediately", 0.3),
            ("asap", 0.25),
            ("critical", 0.25),
            ("cannot wait", 0.2),
            ("can't wait", 0.2),
            ("time sensitive", 0.2),
            ("time-sensitive", 0.2),
            ("right away", 0.2),
            ("at once", 0.15),
            ("as soon as possible", 0.25),
            ("top priority", 0.2),
            ("high priority", 0.2),
        ]
        for (phrase, boost) in urgentKeywords {
            if let range = lower.range(of: phrase) {
                score += boost
                let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let end = lower.distance(from: lower.startIndex, to: range.upperBound)
                let sourceRange = text.index(text.startIndex, offsetBy: start) ..<
                                  text.index(text.startIndex, offsetBy: end)
                evidenceSpans.append(EvidenceSpan(start: start, end: end, text: String(text[sourceRange])))
                evidenceCount += 1
            }
        }

        // --- 2. Deadline language ---
        let deadlinePhrases: [(String, Double)] = [
            ("due by", 0.2),
            ("deadline", 0.2),
            ("by end of day", 0.2),
            ("by eod", 0.2),
            ("must be submitted", 0.2),
            ("must submit", 0.2),
            ("by tomorrow", 0.2),
            ("before end of day", 0.2),
            ("before the deadline", 0.15),
            ("by friday", 0.15),
            ("by monday", 0.15),
            ("by tuesday", 0.15),
            ("by wednesday", 0.15),
            ("by thursday", 0.15),
            ("by saturday", 0.15),
            ("by sunday", 0.15),
            ("is due", 0.15),
            ("must be completed", 0.2),
        ]
        for (phrase, boost) in deadlinePhrases {
            if let range = lower.range(of: phrase) {
                score += boost
                let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let end = lower.distance(from: lower.startIndex, to: range.upperBound)
                let sourceRange = text.index(text.startIndex, offsetBy: start) ..<
                                  text.index(text.startIndex, offsetBy: end)
                evidenceSpans.append(EvidenceSpan(start: start, end: end, text: String(text[sourceRange])))
                evidenceCount += 1
            }
        }

        // --- 3. Imperative language ---
        let imperativePhrases: [(String, Double)] = [
            ("please submit", 0.1),
            ("need to", 0.1),
            ("must complete", 0.1),
            ("make sure to", 0.1),
            ("ensure that", 0.1),
            ("please make sure", 0.1),
            ("you must", 0.1),
            ("required to", 0.1),
            ("have to", 0.1),
            ("needs to be", 0.1),
        ]
        for (phrase, boost) in imperativePhrases {
            if let range = lower.range(of: phrase) {
                score += boost
                let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let end = lower.distance(from: lower.startIndex, to: range.upperBound)
                let sourceRange = text.index(text.startIndex, offsetBy: start) ..<
                                  text.index(text.startIndex, offsetBy: end)
                evidenceSpans.append(EvidenceSpan(start: start, end: end, text: String(text[sourceRange])))
                evidenceCount += 1
            }
        }

        // --- 4. ALL CAPS words (excluding common acronyms) ---
        let commonAcronyms: Set<String> = ["FYI", "PDF", "HR", "CEO", "CFO", "CTO", "COO", "VP",
                                            "USA", "UK", "EU", "UN", "FBI", "CIA", "NASA", "NATO",
                                            "ID", "OK", "TV", "IT", "AI", "ML", "API", "URL", "DNS"]
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
            .filter { !$0.isEmpty }

        var capsCount = 0
        for word in words {
            // Must be at least 2 characters, all uppercase letters, not a known acronym
            guard word.count >= 2,
                  word == word.uppercased(),
                  word.allSatisfy({ $0.isLetter }),
                  !commonAcronyms.contains(word) else {
                continue
            }
            if capsCount < 3 {
                score += 0.05
                // Find position in original text for evidence
                if let range = text.range(of: word) {
                    let start = text.distance(from: text.startIndex, to: range.lowerBound)
                    let end = text.distance(from: text.startIndex, to: range.upperBound)
                    evidenceSpans.append(EvidenceSpan(start: start, end: end, text: word))
                    evidenceCount += 1
                }
            }
            capsCount += 1
        }

        // --- 5. Anti-urgency signals ---
        let antiUrgencyPhrases: [(String, Double)] = [
            ("no rush", -0.3),
            ("whenever you get a chance", -0.3),
            ("whenever you can", -0.3),
            ("no hurry", -0.3),
            ("take your time", -0.3),
            ("when you get a chance", -0.3),
            ("at your leisure", -0.3),
            ("no urgency", -0.3),
            ("not urgent", -0.3),
        ]
        for (phrase, penalty) in antiUrgencyPhrases {
            if lower.contains(phrase) {
                score += penalty
                evidenceCount += 1
            }
        }

        // --- Clamp and build result ---
        let clamped = max(0.0, min(1.0, score))

        // Confidence scales with evidence count; cap at ~0.85 for 5+ pieces of evidence
        let confidence = min(0.85, Double(evidenceCount) / 5.0 * 0.85)

        return ScalarDimension(value: clamped, confidence: confidence, evidenceSpans: evidenceSpans)
    }
}
