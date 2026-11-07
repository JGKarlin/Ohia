// TranslationLanguageDownload.swift
// Hosts Apple's in-app translation-language download for a reading surface. When
// the Apple engine reports a pairing is supported but not installed, the control
// shows a Download affordance; tapping it sets `EmailTranslationModel`'s pending
// request, which this modifier turns into a `TranslationSession.Configuration`
// and runs through `prepareTranslation()` (Apple's system download sheet). On
// success it retries the translation; if the in-app path errors, it falls back
// to opening System Settings → Language & Region, where Translation Languages
// are managed.

import SwiftUI
import AppKit
import Translation
import OhiaML

private struct TranslationLanguageDownloadModifier: ViewModifier {
    @Bindable var model: EmailTranslationModel
    let service: TranslationService?

    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: model.languageDownloadRequestID) {
                guard let pair = model.pendingLanguageDownload else { return }
                configuration = TranslationSession.Configuration(
                    source: AppleTranslationAPITranslator.localeLanguage(from: pair.sourceCode),
                    target: AppleTranslationAPITranslator.localeLanguage(from: pair.targetCode)
                )
            }
            .translationTask(configuration) { session in
                guard let service else {
                    configuration = nil
                    model.languageDownloadFailed("Translation is unavailable right now.")
                    return
                }
                do {
                    // Presents Apple's system permission/download sheet, then
                    // resolves once the languages are installed (or were already).
                    try await session.prepareTranslation()
                    configuration = nil
                    model.languageDownloadSucceeded(retryUsing: service)
                } catch is CancellationError {
                    configuration = nil
                    model.languageDownloadFailed("Language download was cancelled.")
                } catch {
                    // In-app download unavailable — fall back to System Settings,
                    // where the user can add the languages manually.
                    configuration = nil
                    model.languageDownloadFailed(
                        "Couldn't download languages here — opening System Settings → Language & Region → Translation Languages."
                    )
                    Self.openLanguageRegionSettings()
                }
            }
    }

    /// Opens System Settings to the Language & Region pane. Translation Languages
    /// live inside it; macOS exposes no deeper public anchor.
    private static func openLanguageRegionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

extension View {
    /// Attaches the in-app translation-language download flow for `model`. Render
    /// nothing extra — this only hosts the hidden `translationTask` that the
    /// Download affordance drives.
    func translationLanguageDownload(
        _ model: EmailTranslationModel,
        service: TranslationService?
    ) -> some View {
        modifier(TranslationLanguageDownloadModifier(model: model, service: service))
    }
}
