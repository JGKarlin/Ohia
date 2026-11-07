// TranslationEngineKind.swift
// The user-selectable engine that produces on-demand email-body translations
// across the reading lenses. The default is the local Qwen generative model
// (fully offline, full multilingual support, and the engine that also consumes
// the user's curated translation memories); Apple's dedicated Translation
// framework (Apple Intelligence high-fidelity models on macOS 26.4+) is the
// alternative.

import Foundation

public enum TranslationEngineKind: String, CaseIterable, Identifiable, Sendable {
    case qwen
    case appleOnDevice

    /// The engine used when the user has expressed no preference. Single source
    /// of truth for the default — `ModelManager.selectedTranslationEngine()` and
    /// every `@AppStorage` view default resolve to this so they never drift.
    public static let defaultEngine: TranslationEngineKind = .qwen

    public var id: String { rawValue }

    /// Stable tag folded into the translation cache fingerprint so switching
    /// engines never serves another engine's cached output for the same
    /// (message, target language) pair.
    public var cacheTag: String {
        switch self {
        case .qwen:          return "qwen"
        case .appleOnDevice: return "apple-translate-ondevice"
        }
    }

    public var displayName: String {
        switch self {
        case .qwen:          return "Generative Model"
        case .appleOnDevice: return "Apple On-Device"
        }
    }

    public var shortDescription: String {
        switch self {
        case .qwen:
            return "Your downloaded Qwen model. Fully offline, full multilingual support."
        case .appleOnDevice:
            return "Apple's dedicated Translation API. On-device Apple Intelligence, offline when languages are installed."
        }
    }
}
