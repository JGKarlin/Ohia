// AppleTranslationAPITranslator.swift
// Full-fidelity email-body translation via Apple's dedicated Translation framework
// (`TranslationSession`), using the `.highFidelity` strategy on macOS 26.4+ so
// translations run through Apple Intelligence's on-device translation models
// rather than a generic Foundation Model prompt. See Apple's "Translating text
// within your app" and `TranslationSession.Strategy.highFidelity` documentation.
//
// All `TranslationSession` work is on-device; there is no server-side translation
// path in Apple's Translation framework.

import Foundation
import OhiaCore
import Translation

public final class AppleTranslationAPITranslator: Translating, @unchecked Sendable {
    /// Per-chunk character budget for batch translation requests.
    private static let chunkCharacterBudget = 4_000

    /// Safety ceiling on total body characters. `TranslationSession` batches an
    /// arbitrary number of chunks, so unlike the generative path there is no
    /// token budget to respect; this guard only prevents a degenerate
    /// multi-megabyte paste (a pathological quoted history) from fanning out
    /// into thousands of chunks. It sits far above any real email body — long
    /// threads and newsletters translate in full.
    private static let bodyCharacterCeiling = 100_000

    public var cacheTag: String { TranslationEngineKind.appleOnDevice.cacheTag }

    public func translate(
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        detectedSourceLanguageCode: String?
    ) async throws -> TranslationResult? {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        try ensureAppleIntelligenceAvailable()

        guard let sourceCode = detectedSourceLanguageCode ?? EmailLanguageDetector.detectDominantLanguageCode(in: trimmed) else {
            throw TranslationError.underlying("could not determine the message language for translation.")
        }

        let source = Self.localeLanguage(from: sourceCode)
        let target = Self.localeLanguage(from: targetLanguage.identifier)

        try await ensureLanguagePairAvailable(from: source, to: target)

        let bounded = String(trimmed.prefix(Self.bodyCharacterCeiling))
        let chunks = TranslationBodyChunker.chunks(for: bounded, budget: Self.chunkCharacterBudget)
        guard chunks.isEmpty == false else { return nil }

        let session = Self.makeSession(source: source, target: target)
        defer { session.cancel() }

        let requests: [TranslationSession.Request] = chunks.enumerated().map { index, chunk in
            TranslationSession.Request(sourceText: chunk, clientIdentifier: "\(index)")
        }

        let responses: [TranslationSession.Response]
        do {
            try Task.checkCancellation()
            responses = try await session.translations(from: requests)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as Translation.TranslationError {
            throw Self.mapTranslationFrameworkError(error)
        } catch {
            throw TranslationError.underlying(error.localizedDescription)
        }

        guard responses.count == chunks.count else {
            throw TranslationError.underlying("Apple Translation returned an incomplete result.")
        }

        let ordered = responses
            .sorted { lhs, rhs in
                let left = Int(lhs.clientIdentifier ?? "") ?? 0
                let right = Int(rhs.clientIdentifier ?? "") ?? 0
                return left < right
            }
            .map(\.targetText)

        guard ordered.isEmpty == false else { return nil }
        let joined = ordered.joined(separator: "\n\n")
        guard joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }

        return TranslationResult(
            text: joined,
            targetLanguageIdentifier: targetLanguage.identifier,
            detectedSourceLanguageCode: sourceCode
        )
    }

    // MARK: - Session

    private static func makeSession(source: Locale.Language, target: Locale.Language) -> TranslationSession {
        if #available(macOS 26.4, *) {
            return TranslationSession(
                installedSource: source,
                target: target,
                preferredStrategy: .highFidelity
            )
        }
        return TranslationSession(installedSource: source, target: target)
    }

    // MARK: - Availability

    private func ensureAppleIntelligenceAvailable() throws {
        let state = AppleIntelligenceAvailability.current()
        guard state.isAvailable else {
            throw TranslationError.modelUnavailable(Self.onDeviceUnavailableReason(state))
        }
    }

    private func ensureLanguagePairAvailable(
        from source: Locale.Language,
        to target: Locale.Language
    ) async throws {
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .highFidelity)
        } else {
            availability = LanguageAvailability()
        }

        let status = await availability.status(from: source, to: target)

        switch status {
        case .installed:
            return
        case .supported:
            throw TranslationError.languagesNotInstalled(
                "translation languages for this message aren't downloaded yet."
            )
        case .unsupported:
            throw TranslationError.modelUnavailable(
                "Apple Translation does not support this language pairing."
            )
        @unknown default:
            throw TranslationError.modelUnavailable("Apple Translation is unavailable for this language pairing.")
        }
    }

    // MARK: - Mapping

    /// Maps a BCP-47 identifier to a `Locale.Language` for the Translation
    /// framework. Public so the in-app language-download flow can build a
    /// `TranslationSession.Configuration` for the same pairing this translator
    /// would use.
    public static func localeLanguage(from identifier: String) -> Locale.Language {
        Locale.Language(identifier: EmailLanguageDetector.normalizedLanguageIdentifier(identifier))
    }

    private static func mapTranslationFrameworkError(_ error: Translation.TranslationError) -> TranslationError {
        switch error {
        case .notInstalled:
            return .languagesNotInstalled(
                "translation languages for this message aren't downloaded yet."
            )
        case .unsupportedSourceLanguage:
            return .modelUnavailable("Apple Translation does not support the message's source language.")
        case .unsupportedTargetLanguage:
            return .modelUnavailable("Apple Translation does not support the selected target language.")
        case .unsupportedLanguagePairing:
            return .modelUnavailable("Apple Translation does not support this language pairing.")
        case .unableToIdentifyLanguage:
            return .underlying("Apple Translation could not identify the message language.")
        case .nothingToTranslate:
            return .underlying("there is nothing to translate.")
        case .alreadyCancelled:
            return .underlying("translation was cancelled.")
        case .internalError:
            return .underlying("Apple Translation encountered an internal error.")
        default:
            return .underlying(error.localizedDescription)
        }
    }

    private static func onDeviceUnavailableReason(_ state: AppleIntelligenceAvailability.State) -> String {
        switch state {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Enable it in System Settings to use on-device translation."
        case .deviceNotEligible:
            return "this Mac doesn't support Apple Intelligence."
        case .modelNotReady:
            return "the Apple Intelligence model is still preparing. Try again shortly."
        case .available, .unknown:
            return "Apple on-device translation is unavailable."
        }
    }
}
