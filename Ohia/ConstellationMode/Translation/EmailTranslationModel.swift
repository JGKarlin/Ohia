import SwiftUI
import OhiaML

/// Drives the on-demand translation affordance for a single displayed email
/// across every reading surface (Front Page reader, Timeline viewport, locked
/// pane lenses). One instance is held as view state per surface; the host calls
/// `configure` whenever the displayed message or its body changes, then renders
/// the control + content from `phase` / `isShowingTranslation`.
///
/// The heavy work (language detection, generation, caching) lives in OhiaML —
/// this type is purely the per-view state machine that decides whether to offer
/// the control, kicks off a generation, and remembers the result so toggling
/// between original and translation is instant.
@MainActor
@Observable
final class EmailTranslationModel {
    enum Phase: Equatable {
        case idle
        case translating
        case translated(TranslationResult)
        case failed(String)
        /// The Apple engine supports this pairing but the languages aren't
        /// downloaded. Carries the reason; the control offers an in-app download.
        case needsDownload(String)
        /// The in-app language download is running (Apple's system download
        /// sheet is up); the translation retries automatically when it finishes.
        case preparingLanguages
    }

    /// A source→target pairing the user has asked to download in-app, consumed by
    /// the host's download modifier to build a `TranslationSession.Configuration`.
    struct LanguagePair: Equatable {
        let sourceCode: String
        let targetCode: String
    }

    private(set) var phase: Phase = .idle
    /// Whether the translation (rather than the original) is the visible side.
    /// Meaningful once `phase == .translated`: in pane lenses it flips the pane
    /// between original and translation; in two-column surfaces it shows/hides
    /// the translation column.
    var isShowingTranslation = true

    /// True when the loaded body's language differs from the active target, so
    /// the Translate control should appear.
    private(set) var canOffer = false
    private(set) var sourceLanguageCode: String?
    private(set) var targetLanguage = SummarizationTargetLanguage(identifier: "en", displayName: "English")

    private var messageID: UUID?
    private var bodyText = ""
    private var fingerprint: String?
    /// Invalidates in-flight generations whose message/target/body no longer
    /// match what is displayed, so a slow translation can never land on the
    /// wrong message.
    private var generationToken = UUID()
    /// The currently running generation, retained so a message switch (or a new
    /// run) can cancel it. Cancellation propagates through `TranslationService`
    /// to the engine, so an abandoned translation stops consuming the model.
    private var generationTask: Task<Void, Never>?

    /// The pairing the user asked to download, set by `requestLanguageDownload()`
    /// and read by the host's download modifier. `languageDownloadRequestID`
    /// changes on every request so the modifier re-fires even for a repeat of
    /// the same pairing (e.g. retry after a cancelled download).
    private(set) var pendingLanguageDownload: LanguagePair?
    private(set) var languageDownloadRequestID = UUID()

    // MARK: - Configuration

    /// Re-points the model at the currently displayed message. Cheap to call on
    /// every body change: it no-ops when nothing relevant changed, and resets
    /// translation state when the message, target language, or body text does.
    func configure(
        messageID: UUID,
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage
    ) {
        let newFingerprint = Self.fingerprint(
            messageID: messageID,
            bodyText: bodyText,
            targetIdentifier: targetLanguage.identifier,
            engineTag: ModelManager.selectedTranslationEngine().cacheTag
        )
        guard newFingerprint != fingerprint else { return }
        fingerprint = newFingerprint

        self.messageID = messageID
        self.bodyText = bodyText
        self.targetLanguage = targetLanguage
        // The displayed message changed — abandon any translation still running
        // for the previous one so the engine isn't held by work nobody wants.
        generationTask?.cancel()
        generationTask = nil
        pendingLanguageDownload = nil
        withAnimation(Self.transition) {
            phase = .idle
        }
        isShowingTranslation = true
        generationToken = UUID()

        let offer = EmailLanguageDetector.evaluate(
            bodyText: bodyText,
            targetLanguageIdentifier: targetLanguage.identifier
        )
        canOffer = offer.shouldOffer
        sourceLanguageCode = offer.detectedLanguageCode
    }

    // MARK: - Actions

    /// Starts (or restarts after a failure) generation through the cached
    /// service. The displayed side immediately becomes the translation so the
    /// loading animation shows where the result will land.
    func translate(using service: TranslationService) {
        startTranslation(using: service, forceRefresh: false)
    }

    /// Starts a fresh generation for the current message, bypassing the cached
    /// translation for this message/body/target-language key.
    func regenerate(using service: TranslationService) {
        startTranslation(using: service, forceRefresh: true)
    }

    private func startTranslation(using service: TranslationService, forceRefresh: Bool) {
        guard canOffer, let messageID else { return }
        if forceRefresh == false {
            switch phase {
            case .translating, .translated, .preparingLanguages:
                return
            case .idle, .failed, .needsDownload:
                break
            }
        } else if case .preparingLanguages = phase {
            return
        }

        let priorTranslatedResult: TranslationResult? = {
            guard case .translated(let result) = phase else { return nil }
            return result
        }()
        generationToken = UUID()
        withAnimation(Self.transition) {
            phase = .translating
        }
        isShowingTranslation = true
        let token = generationToken
        let body = bodyText
        let target = targetLanguage
        let source = sourceLanguageCode

        generationTask?.cancel()
        generationTask = Task {
            let result = await service.translation(
                for: messageID,
                bodyText: body,
                targetLanguage: target,
                detectedSourceLanguageCode: source,
                forceRefresh: forceRefresh
            )
            guard token == generationToken else { return }
            if let result {
                withAnimation(Self.transition) {
                    phase = .translated(result)
                }
                isShowingTranslation = true
            } else {
                let failure = await service.failure(
                    for: messageID,
                    bodyText: body,
                    targetLanguage: target
                )
                withAnimation(Self.transition) {
                    if let failure, failure.requiresLanguageDownload {
                        phase = .needsDownload(failure.message)
                    } else if forceRefresh, let priorTranslatedResult {
                        phase = .translated(priorTranslatedResult)
                        isShowingTranslation = true
                    } else {
                        phase = .failed(failure?.message ?? "Translation could not be generated.")
                    }
                }
            }
        }
    }

    // MARK: - Language download

    /// True when the current failure is a missing on-device language pairing that
    /// an in-app download can resolve, and the detected source is known.
    var canDownloadLanguages: Bool {
        if case .needsDownload = phase, sourceLanguageCode != nil { return true }
        return false
    }

    /// The user asked to download the missing pairing. Publishes the request for
    /// the host's download modifier and shows the preparing state; the modifier
    /// runs Apple's `prepareTranslation()` and reports back.
    func requestLanguageDownload() {
        guard case .needsDownload = phase,
              let sourceCode = sourceLanguageCode else { return }
        pendingLanguageDownload = LanguagePair(
            sourceCode: sourceCode,
            targetCode: targetLanguage.identifier
        )
        languageDownloadRequestID = UUID()
        withAnimation(Self.transition) {
            phase = .preparingLanguages
        }
        isShowingTranslation = true
    }

    /// The download finished — clear the request and translate, now that the
    /// languages are installed. If the languages were still mid-download (Apple's
    /// `prepareTranslation()` returns once a download is *in progress*, not only
    /// when installed), the retry may re-report `.needsDownload`; the user taps
    /// Download again once it completes, rather than being stuck on a spinner.
    func languageDownloadSucceeded(retryUsing service: TranslationService) {
        pendingLanguageDownload = nil
        guard case .preparingLanguages = phase else { return }
        // Drop back to idle so `translate` will run (it no-ops on non-idle).
        phase = .idle
        translate(using: service)
    }

    /// The download was declined or failed; surface a recoverable failure so the
    /// user can retry or use the System Settings fallback the host opened. Guarded
    /// on `.preparingLanguages` so a download that resolves *after* the reader has
    /// moved to another message can't stamp a stale "needs download" onto it.
    func languageDownloadFailed(_ message: String) {
        pendingLanguageDownload = nil
        guard case .preparingLanguages = phase else { return }
        withAnimation(Self.transition) {
            phase = .needsDownload(message)
        }
    }

    /// Flips between original and translation. Only acts once translated; the
    /// cached result makes this instant.
    func toggle() {
        guard case .translated = phase else { return }
        withAnimation(Self.transition) {
            isShowingTranslation.toggle()
        }
    }

    static let transition = Animation.easeInOut(duration: 0.18)

    // MARK: - Derived

    var isTranslating: Bool {
        switch phase {
        case .translating, .preparingLanguages:
            // Preparing (downloading languages) shows the same loader so the
            // translation column animates continuously into the result.
            return true
        default:
            return false
        }
    }

    var translatedText: String? {
        if case .translated(let result) = phase { return result.text }
        return nil
    }

    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Whether the translation should be the visible content right now (the
    /// loader counts as "translation showing" so it replaces the original).
    var translationVisible: Bool {
        switch phase {
        case .translating, .preparingLanguages:
            return isShowingTranslation
        case .translated:
            return isShowingTranslation
        case .idle, .failed, .needsDownload:
            return false
        }
    }

    /// The explanatory message when a language download is needed, for the
    /// control's help text.
    var needsDownloadMessage: String? {
        if case .needsDownload(let message) = phase { return message }
        return nil
    }

    var sourceLanguageAutonym: String? {
        guard let code = sourceLanguageCode else { return nil }
        return LanguageAutonym.name(forCode: code)
    }

    var targetLanguageAutonym: String {
        LanguageAutonym.name(forCode: targetLanguage.identifier)
    }

    private static func fingerprint(
        messageID: UUID,
        bodyText: String,
        targetIdentifier: String,
        engineTag: String
    ) -> String {
        // A process-stable FNV-1a hash (not `String.hashValue`, which is salted
        // per launch) so the no-op guard is deterministic and a body change for
        // the same message+target — or an engine switch in Settings — is always
        // detected, dropping the affordance back to "Translate" for a fresh run.
        "\(messageID.uuidString)|\(targetIdentifier)|\(engineTag)|\(stableHash(bodyText))"
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// Renders a language's name in its own language (autonym), for the column
/// headers and toggle labels — "日本語", "Français", "English". Falls back to
/// the uppercased base code when the system can't localize it.
enum LanguageAutonym {
    static func name(forCode code: String) -> String {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        let locale = Locale(identifier: code)
        if let autonym = locale.localizedString(forLanguageCode: base),
           autonym.isEmpty == false {
            return autonym.prefix(1).uppercased() + autonym.dropFirst()
        }
        return base.uppercased()
    }
}
