import Foundation
import NaturalLanguage

/// Canonical language identity shared by the Composer's language picker,
/// style-register stratification, and the generation prompts' output-language
/// directive. IDs are lowercase BCP-47 language families ("en", "ja") — the
/// same vocabulary `NLLanguageRecognizer` writes into
/// `Message.languageDetected` and `LocalModelLanguageSupport` enumerates.
public enum DraftLanguage {

    /// Lowercased language-family token for any identifier ("ja-JP" → "ja",
    /// "cmn" → "zh"), preserved even when the family is outside the local
    /// model's supported set — an unsupported detected language still names
    /// a real language the user can pin a draft to. Nil for nil/empty input.
    public static func familyID(for identifier: String?) -> String? {
        guard let identifier else { return nil }
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        let family = normalized.split(separator: "-").first.map(String.init) ?? normalized
        switch family {
        case "cmn", "yue":
            return "zh"
        default:
            return family
        }
    }

    /// Human-readable name for a language id: the local model's fixed table
    /// first, the user's locale second, the raw family id as a last resort.
    public static func displayName(for identifier: String) -> String {
        if let supported = LocalModelLanguageSupport.displayName(for: identifier) {
            return supported
        }
        let family = familyID(for: identifier) ?? identifier
        if let localized = Locale.current.localizedString(forLanguageCode: family),
           !localized.isEmpty {
            return localized.prefix(1).uppercased() + localized.dropFirst()
        }
        return family
    }

    /// The language a reply draft should be written in: the user's explicit
    /// picker choice first, then the incoming message's detected language.
    /// Nil when neither exists — prompts fall back to the mirror-the-sender
    /// directive and style resolution runs unfiltered.
    public static func resolvedID(for message: Message) -> String? {
        if let chosen = familyID(for: message.draft?.languageID) { return chosen }
        return familyID(for: message.languageDetected)
    }

    /// Confidence-gated language detection for text that has no ingested
    /// `languageDetected` (in-editor completions, migration upgrades). Same
    /// gates as ingestion's detector: a minimum of meaningful letters and a
    /// dominant-language confidence floor — nil rather than a guess.
    public static func detectedFamilyID(ofText text: String) -> String? {
        let sample = String(text.prefix(1_600))
        let meaningful = sample.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) { count += 1 }
        }
        guard meaningful >= 16 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let dominant = recognizer.dominantLanguage,
              dominant != .undetermined,
              (recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0) >= 0.55 else {
            return nil
        }
        return familyID(for: dominant.rawValue)
    }
}
