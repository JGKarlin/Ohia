import Foundation

/// Language-keyed lexicon for explicit-norm phrases used by
/// `ContradictionDetector` and `CrossThreadMemoryMiner`.
/// Covers the English defaults from §11 of the design doc plus a
/// Japanese token list for §19 (multilingual extraction beyond English
/// heuristics).
public enum NormLanguageLexicon {
    /// Phrases that signal "this is how we usually do it." Matches are
    /// substring-tested case-insensitively so morphological variation
    /// ("usually" / "we usually" / "usually we") is captured by a single
    /// entry.
    public static func explicitNormPhrases(for language: String?) -> [String] {
        let key = language?.lowercased().prefix(2).description
        switch key {
        case "ja":
            return japaneseNormPhrases + englishNormPhrases
        default:
            return englishNormPhrases
        }
    }

    /// Negation cues used by `ContradictionDetector` when the LLM did not
    /// surface a negation explicitly. Language-keyed so non-English
    /// contradictions are still detected.
    public static func negationCues(for language: String?) -> [String] {
        let key = language?.lowercased().prefix(2).description
        switch key {
        case "ja":
            return japaneseNegationCues + englishNegationCues
        default:
            return englishNegationCues
        }
    }

    /// Determine whether `text` matches any norm phrase in the chosen
    /// language. Substring + case-insensitive — chosen for predictability
    /// over linguistic correctness; the LLM pass refines this when
    /// available.
    public static func containsNormLanguage(_ text: String, language: String?) -> Bool {
        let lowered = text.lowercased()
        for phrase in explicitNormPhrases(for: language) {
            if lowered.contains(phrase.lowercased()) {
                return true
            }
        }
        return false
    }

    public static func containsNegationCue(_ text: String, language: String?) -> Bool {
        let lowered = text.lowercased()
        for cue in negationCues(for: language) {
            if lowered.contains(cue.lowercased()) {
                return true
            }
        }
        return false
    }

    private static let englishNormPhrases: [String] = [
        "usually",
        "as before",
        "standard process",
        "same as last year",
        "as we discussed",
        "per our prior practice",
        "as is our practice",
        "as is customary",
        "by default",
        "we typically",
        "we normally",
        "as a rule",
        "per protocol",
        "per policy",
        "convention is",
        "the convention is",
        "as agreed",
        "as established",
        "as a matter of practice"
    ]

    private static let japaneseNormPhrases: [String] = [
        "いつも",            // usually
        "いつもの",          // the usual
        "通常",              // normal / usual
        "通常通り",          // as usual
        "前回と同じ",        // same as last time
        "毎回",              // every time
        "毎度",              // every time
        "従来通り",          // as conventionally done
        "通例",              // convention
        "原則",              // in principle
        "標準的に",          // by standard
        "去年と同じ"         // same as last year
    ]

    private static let englishNegationCues: [String] = [
        "no longer",
        "instead of",
        "not anymore",
        "this is wrong",
        "that's incorrect",
        "that's not right",
        "this contradicts",
        "scrap that",
        "disregard the prior",
        "replace the earlier",
        "supersedes",
        "supersede",
        "overrides"
    ]

    private static let japaneseNegationCues: [String] = [
        "ではなく",        // not X (but Y)
        "ではない",        // is not
        "誤り",            // error / wrong
        "間違い",          // mistake
        "撤回",            // retract
        "取り消し",        // cancel
        "差し替え"         // replace
    ]
}
