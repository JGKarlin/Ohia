import Foundation

/// Single source of truth for the app-global content-language list
/// (Settings → Languages → Content languages): the defaults key, the JSON
/// codec every reader and writer must share, and the strict canonical
/// reading most consumers want.
///
/// Consumers that deliberately accept a broader language set than the
/// local model's (translation, summarization) build their own
/// normalization on top of `decode(_:)` — the raw layer — instead of
/// re-implementing the storage format.
public enum ContentLanguagesStore {

    /// The `UserDefaults` key `LanguagesSettingsView`'s `@AppStorage`
    /// binds; onboarding writes it and every language surface reads it.
    public static let defaultsKey = "activeLanguages"

    /// Raw stored ids: JSON `[String]`, or empty when the key is missing
    /// or the payload malformed — never an error.
    public static func decode(_ data: Data?) -> [String] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Canonical encoding for writers. Nil only if JSON encoding of a
    /// string array fails, which it cannot in practice.
    public static func encode(_ ids: [String]) -> Data? {
        try? JSONEncoder().encode(ids)
    }

    /// Strict reading: ids canonicalized to the model-supported set,
    /// deduplicated, stored order preserved. Unsupported ids drop.
    public static func modelSupportedIDs(from data: Data?) -> [String] {
        var seen = Set<String>()
        return decode(data)
            .compactMap { LocalModelLanguageSupport.canonicalLanguageID(for: $0) }
            .filter { seen.insert($0).inserted }
    }
}
