// RoutingTranslator.swift
// A `Translating` that delegates each request to the engine the user selected
// in Settings (read live per call, so a switch takes effect on the next
// translation without rebuilding the service). Its `cacheTag` reflects the
// active engine so `TranslationService` fingerprints — and therefore the cache
// — never bleed across engines.

import Foundation
import OhiaCore

public final class RoutingTranslator: Translating, @unchecked Sendable {
    private let qwen: any Translating
    private let appleOnDevice: any Translating
    private let selection: @Sendable () -> TranslationEngineKind

    public init(
        qwen: any Translating,
        appleOnDevice: any Translating,
        selection: @escaping @Sendable () -> TranslationEngineKind
    ) {
        self.qwen = qwen
        self.appleOnDevice = appleOnDevice
        self.selection = selection
    }

    public var cacheTag: String { selection().cacheTag }

    /// Reads Settings exactly once and returns the backend that owns the whole
    /// request, including context compilation, cache identity, and dispatch.
    public func requestSnapshot() -> any Translating {
        backend(for: selection()).requestSnapshot()
    }

    /// Reflects the engine that will actually run this request, so the service
    /// only compiles context when the live selection is a context-aware engine.
    public var usesContext: Bool { backend(for: selection()).usesContext }

    public func translate(
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        detectedSourceLanguageCode: String?
    ) async throws -> TranslationResult? {
        try await backend(for: selection()).translate(
            bodyText: bodyText,
            targetLanguage: targetLanguage,
            detectedSourceLanguageCode: detectedSourceLanguageCode
        )
    }

    public func translate(
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        detectedSourceLanguageCode: String?,
        context: TranslationContext?
    ) async throws -> TranslationResult? {
        try await backend(for: selection()).translate(
            bodyText: bodyText,
            targetLanguage: targetLanguage,
            detectedSourceLanguageCode: detectedSourceLanguageCode,
            context: context
        )
    }

    private func backend(for kind: TranslationEngineKind) -> any Translating {
        switch kind {
        case .qwen:          return qwen
        case .appleOnDevice: return appleOnDevice
        }
    }
}
