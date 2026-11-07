// TranslationLanguages.swift
// The declared-language surface for the translation glossary. "Declared" means
// the languages the user has told Ohia they actually use: the content languages
// from Settings → Languages (the `activeLanguages` default) plus any per-account
// drafting languages. The glossary producers mine pairs only between declared
// languages — never between every language the corpus happens to contain — so
// the dossier list in Settings stays scoped to the user's real working set.

import Foundation
import OhiaCore

public enum TranslationLanguages {
    /// The user's declared language codes, canonicalized to base codes (`ja`,
    /// `en`) and deduplicated, content languages first. Empty when the user has
    /// declared nothing yet. Deliberately broader than the model-supported
    /// set — translation targets any language the user declares — so this
    /// builds on the store's raw layer, not `modelSupportedIDs`.
    public static func declaredCodes(
        activeLanguagesData: Data? = OhiaSharedDefaults.store.data(
            forKey: ContentLanguagesStore.defaultsKey
        ),
        accountDraftLanguages: [String] = []
    ) -> [String] {
        let stored = ContentLanguagesStore.decode(activeLanguagesData)
        var seen = Set<String>()
        var codes: [String] = []
        for raw in stored + accountDraftLanguages {
            let code = EmailLanguageDetector.canonicalBaseCode(raw)
            guard code.isEmpty == false, seen.insert(code).inserted else { continue }
            codes.append(code)
        }
        return codes
    }

    /// Localized label for a base language code, e.g. `ja` → "Japanese". Falls
    /// back to the code itself when the locale has no name for it.
    public static func displayName(forCode code: String) -> String {
        let localized = Locale.current.localizedString(forLanguageCode: code)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (localized?.isEmpty == false) ? localized! : code
    }
}
