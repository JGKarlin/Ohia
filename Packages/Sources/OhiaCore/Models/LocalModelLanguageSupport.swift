import Foundation

public enum LocalModelLanguageSupport {
    /// Language IDs supported by Ohia's current local generative model family
    /// and the default BGE-M3 retrieval model. Keep onboarding and settings
    /// language pickers inside this list.
    public static let supportedLanguageIDs: [String] = [
        "en", "zh", "ja", "ko", "fr", "de", "es", "pt", "it", "ru",
    ]

    public static func canonicalLanguageID(for identifier: String) -> String? {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard normalized.isEmpty == false else { return nil }

        let family = normalized.split(separator: "-").first.map(String.init) ?? normalized
        let canonical: String
        switch family {
        case "cmn", "yue", "zh":
            canonical = "zh"
        default:
            canonical = family
        }

        return supportedLanguageIDs.contains(canonical) ? canonical : nil
    }

    public static func displayName(for identifier: String) -> String? {
        guard let canonical = canonicalLanguageID(for: identifier) else { return nil }
        switch canonical {
        case "en": return "English"
        case "zh": return "Chinese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        case "pt": return "Portuguese"
        case "it": return "Italian"
        case "ru": return "Russian"
        default: return canonical
        }
    }
}
