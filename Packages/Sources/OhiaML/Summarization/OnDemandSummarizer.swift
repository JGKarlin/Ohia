import Foundation
import OhiaCore

public enum OnDemandSummaryScope: Sendable, Equatable {
    case hover
    case lockedContext
    case backgroundPrewarm

    fileprivate var preemptsOlderInteractiveWork: Bool {
        switch self {
        case .hover, .lockedContext:
            return true
        case .backgroundPrewarm:
            return false
        }
    }

    fileprivate var isPreemptible: Bool {
        switch self {
        case .hover, .backgroundPrewarm:
            return true
        case .lockedContext:
            return false
        }
    }

    fileprivate var demandPriority: Int {
        switch self {
        case .backgroundPrewarm:
            return 0
        case .hover:
            return 1
        case .lockedContext:
            return 2
        }
    }

    fileprivate var taskPriority: TaskPriority {
        switch self {
        case .backgroundPrewarm:
            return .utility
        case .hover, .lockedContext:
            return .userInitiated
        }
    }
}

public actor OnDemandSummarizer {
    public typealias PersistSummary = @Sendable @MainActor (UUID, SummarizationResult, Date, String) throws -> Void
    public typealias AvailabilityProvider = @Sendable () -> AppleIntelligenceAvailability.State
    public typealias SummaryLanguageProvider = @Sendable () -> SummarizationTargetLanguage

    private struct RequestKey: Hashable, Sendable {
        let messageID: UUID
        let summaryInputFingerprint: String
    }

    private struct InFlightSummary: Sendable {
        let id: UUID
        let scope: OnDemandSummaryScope
        let task: Task<SummaryAttempt, Never>

        var isPreemptible: Bool {
            scope.isPreemptible
        }
    }

    private struct SummaryAttempt: Sendable {
        let result: SummarizationResult?
        let failureMessage: String?

        static func success(_ result: SummarizationResult) -> SummaryAttempt {
            SummaryAttempt(result: result, failureMessage: nil)
        }

        static func failure(_ message: String) -> SummaryAttempt {
            SummaryAttempt(result: nil, failureMessage: message)
        }

        static let cancelled = SummaryAttempt(result: nil, failureMessage: nil)
    }

    private let appleSummarizer: (any Summarizing)?
    private let mlxSummarizer: any Summarizing
    private let persist: PersistSummary
    private let availabilityProvider: AvailabilityProvider
    private let modelActivityStatusPublisher: ModelActivityStatusPublisher?
    private let translationContextProvider: (any TranslationContextProviding)?
    private let summaryLanguageProvider: SummaryLanguageProvider
    private let displayLanguageGuard: DisplayLanguageGuard?
    private var appleEnabled: Bool

    private var inFlight: [RequestKey: InFlightSummary] = [:]
    private var memoryCache: [RequestKey: SummarizationResult] = [:]
    private var failureMessages: [UUID: String] = [:]
    private var lru: [RequestKey] = []
    private let capacity: Int

    public init(
        apple: (any Summarizing)?,
        mlx: any Summarizing,
        appleEnabled: Bool,
        capacity: Int = 256,
        availabilityProvider: @escaping AvailabilityProvider = { AppleIntelligenceAvailability.current() },
        modelActivityStatusPublisher: ModelActivityStatusPublisher? = nil,
        translationContextProvider: (any TranslationContextProviding)? = nil,
        summaryLanguageProvider: @escaping SummaryLanguageProvider = { .ohiaPreferred() },
        displayLanguageGuard: DisplayLanguageGuard? = nil,
        persist: @escaping PersistSummary
    ) {
        self.appleSummarizer = apple
        self.mlxSummarizer = mlx
        self.appleEnabled = appleEnabled
        self.capacity = max(1, capacity)
        self.availabilityProvider = availabilityProvider
        self.modelActivityStatusPublisher = modelActivityStatusPublisher
        self.translationContextProvider = translationContextProvider
        self.summaryLanguageProvider = summaryLanguageProvider
        self.displayLanguageGuard = displayLanguageGuard
        self.persist = persist
    }

    public func setAppleEnabled(_ enabled: Bool) {
        appleEnabled = enabled
    }

    public func failureMessage(for messageID: UUID) -> String? {
        failureMessages[messageID]
    }

    public func summary(
        for messageID: UUID,
        scope: OnDemandSummaryScope = .hover,
        accountID: UUID? = nil,
        forceRegeneration: Bool = false,
        existingSummary: String? = nil,
        existingSummaryInputFingerprint: String? = nil,
        knownInterpretation: SummaryKnownInterpretation? = nil,
        bodyText: String,
        senderName: String,
        subject: String,
        context: SummarizationContext? = nil
    ) async -> SummarizationResult? {
        let requestScope: OnDemandSummaryScope = forceRegeneration ? .lockedContext : scope
        let prepared = SummarizationTranslationGrounding.applying(
            to: context,
            bodyText: bodyText,
            senderName: senderName,
            subject: subject,
            knownInterpretation: knownInterpretation,
            accountID: accountID,
            targetLanguage: summaryLanguageProvider(),
            provider: translationContextProvider
        )
        let requestKey = RequestKey(
            messageID: messageID,
            summaryInputFingerprint: prepared.summaryInputFingerprint
        )
        if forceRegeneration {
            removeAllState(for: messageID)
        } else {
            cancelStaleFlights(for: requestKey)
            removeStaleMemoryCache(for: requestKey)
            let existing: SummarizationResult? = knownInterpretation.flatMap { knownInterpretation in
                guard existingSummaryInputFingerprint == prepared.summaryInputFingerprint,
                      prepared.isDisplayable(storedSummary: existingSummary) else {
                    return nil
                }
                return SummarizationResult.existing(
                    summary: existingSummary,
                    classification: knownInterpretation.classification,
                    triageVerdict: knownInterpretation.triageVerdict,
                    customCategoryKeys: knownInterpretation.customCategoryKeys,
                    semanticTagCandidates: knownInterpretation.semanticTagCandidates
                )
            }
            if let existing {
                store(requestKey, existing)
                failureMessages[messageID] = nil
                return existing
            }

            if let cached = memoryCache[requestKey] {
                touch(requestKey)
                failureMessages[messageID] = nil
                return cached
            }
        }

        if requestScope.preemptsOlderInteractiveWork {
            cancelPreemptibleInFlight(except: requestKey)
        }

        if let flight = inFlight[requestKey] {
            if requestScope.demandPriority > flight.scope.demandPriority,
               flight.isPreemptible {
                flight.task.cancel()
                inFlight[requestKey] = nil
                failureMessages[messageID] = nil
            } else {
                let attempt = await flight.task.value
                return attempt.result
            }
        }

        let apple = appleSummarizer
        let mlx = mlxSummarizer
        let enabled = appleEnabled
        let availability = availabilityProvider
        let persist = persist
        let activityPublisher = modelActivityStatusPublisher
        let activityAccountID = accountID
        let finalizer = SummaryDisplayFinalizer(
            guardrail: displayLanguageGuard,
            messageID: messageID,
            accountID: accountID
        )
        let flightID = UUID()
        let task = Task<SummaryAttempt, Never>(priority: requestScope.taskPriority) {
            let activityToken = activityPublisher?.begin(
                .summarizing,
                source: "on-demand-summary",
                accountID: activityAccountID,
                subject: subject
            )
            let attempt = await Self.produce(
                messageID: messageID,
                prepared: prepared,
                apple: apple,
                mlx: mlx,
                appleEnabled: enabled,
                availability: availability,
                finalizer: finalizer,
                persist: persist
            )
            if let activityToken {
                activityPublisher?.end(activityToken,
                    outcome: Task.isCancelled ? .cancelled : (attempt.result == nil ? .failed : .finished),
                    detail: attempt.failureMessage)
            }
            return attempt
        }

        inFlight[requestKey] = InFlightSummary(id: flightID, scope: requestScope, task: task)
        let attempt = await task.value
        guard inFlight[requestKey]?.id == flightID else { return nil }
        inFlight[requestKey] = nil
        let result = attempt.result
        if let result {
            store(requestKey, result)
            failureMessages[messageID] = nil
        } else if let failureMessage = attempt.failureMessage {
            failureMessages[messageID] = failureMessage
        }
        return result
    }

    public func clearMemoryCache() {
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        memoryCache.removeAll()
        failureMessages.removeAll()
        lru.removeAll()
    }

    private func cancelPreemptibleInFlight(except requestKey: RequestKey) {
        let keys = inFlight.compactMap { key, flight in
            key != requestKey && flight.isPreemptible ? key : nil
        }
        for key in keys {
            inFlight[key]?.task.cancel()
            inFlight[key] = nil
            failureMessages[key.messageID] = nil
        }
    }

    private func cancelStaleFlights(for requestKey: RequestKey) {
        let keys = inFlight.keys.filter {
            $0.messageID == requestKey.messageID && $0 != requestKey
        }
        for key in keys {
            inFlight[key]?.task.cancel()
            inFlight[key] = nil
        }
    }

    private func removeStaleMemoryCache(for requestKey: RequestKey) {
        let staleKeys = memoryCache.keys.filter {
            $0.messageID == requestKey.messageID && $0 != requestKey
        }
        for key in staleKeys {
            memoryCache[key] = nil
        }
        lru.removeAll {
            $0.messageID == requestKey.messageID && $0 != requestKey
        }
    }

    private func removeAllState(for messageID: UUID) {
        let flightKeys = inFlight.keys.filter { $0.messageID == messageID }
        for key in flightKeys {
            inFlight[key]?.task.cancel()
            inFlight[key] = nil
        }
        let cacheKeys = memoryCache.keys.filter { $0.messageID == messageID }
        for key in cacheKeys {
            memoryCache[key] = nil
        }
        lru.removeAll { $0.messageID == messageID }
        failureMessages[messageID] = nil
    }

    private static func produce(
        messageID: UUID,
        prepared: SummarizationTranslationGrounding.PreparedInputs,
        apple: (any Summarizing)?,
        mlx: any Summarizing,
        appleEnabled: Bool,
        availability: AvailabilityProvider,
        finalizer: SummaryDisplayFinalizer,
        persist: PersistSummary
    ) async -> SummaryAttempt {
        guard !Task.isCancelled else { return .cancelled }
        let bodyHasText = cleaned(prepared.bodyText) != nil
        guard bodyHasText || prepared.context?.hasSummarizableAnchorEvidence == true else {
            return .failure("No summarizable body or attachment evidence is available.")
        }

        if let knownInterpretation = prepared.knownInterpretation {
            return await qwenSummaryOnly(
                messageID: messageID,
                prepared: prepared,
                knownInterpretation: knownInterpretation,
                mlx: mlx,
                finalizer: finalizer,
                persist: persist
            )
        }

        guard !Task.isCancelled else { return .cancelled }
        let qwenOutcome = await qwenPrimary(
            messageID: messageID,
            prepared: prepared,
            mlx: mlx,
            finalizer: finalizer,
            persist: persist
        )
        if case .success(let result) = qwenOutcome {
            return .success(result)
        }
        guard !Task.isCancelled else { return .cancelled }

        guard let apple, appleEnabled, availability().isAvailable else {
            if case .untranslated = qwenOutcome {
                return .failure(prepared.untranslatedSummaryReason)
            }
            return .failure("Qwen did not return a summary, and Apple fallback is unavailable.")
        }
        do {
            if let generated = try await apple.summarize(
                bodyText: prepared.bodyText,
                senderName: prepared.senderName,
                subject: prepared.subject,
                context: prepared.context
            ), let usable = usableResult(generated, prepared: prepared) {
                // Qwen just failed to summarize, so residue resolution stays
                // with the glossary and romanization of names and terms; a
                // source-language passage leaves the summary withheld.
                guard let result = await finalizer.finalize(usable, prepared: prepared, modelAvailable: false) else {
                    return .failure(prepared.untranslatedSummaryReason)
                }
                try Task.checkCancellation()
                try await persistResult(
                    messageID: messageID,
                    result: result,
                    summaryInputFingerprint: prepared.summaryInputFingerprint,
                    persist: persist
                )
                return .success(result)
            }
            return .failure("No summary was generated.")
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure("Summary generation failed: \(cleanFailureDetail(error.localizedDescription))")
        }
    }

    private static func qwenSummaryOnly(
        messageID: UUID,
        prepared: SummarizationTranslationGrounding.PreparedInputs,
        knownInterpretation: SummaryKnownInterpretation,
        mlx: any Summarizing,
        finalizer: SummaryDisplayFinalizer,
        persist: PersistSummary
    ) async -> SummaryAttempt {
        guard !Task.isCancelled else { return .cancelled }
        do {
            if let generated = try await mlx.summarizeOnly(
                bodyText: prepared.bodyText,
                senderName: prepared.senderName,
                subject: prepared.subject,
                knownInterpretation: knownInterpretation,
                context: prepared.context
            ), let usable = usableResult(generated, prepared: prepared) {
                guard let result = await finalizer.finalize(usable, prepared: prepared, modelAvailable: true) else {
                    return .failure(prepared.untranslatedSummaryReason)
                }
                try Task.checkCancellation()
                try await persistResult(
                    messageID: messageID,
                    result: result,
                    summaryInputFingerprint: prepared.summaryInputFingerprint,
                    persist: persist
                )
                return .success(result)
            }
            let fallback = MLXSummarizer.conservativeSummaryOnlyFallback(
                bodyText: prepared.bodyText,
                senderName: prepared.senderName,
                subject: prepared.subject,
                knownInterpretation: knownInterpretation,
                context: prepared.context
            )
            guard let usableFallback = usableResult(fallback, prepared: prepared) else {
                return .failure("Summary generation returned a corrupted glossary marker.")
            }
            // The fallback quotes body sentences; in a source language they
            // are translated whole or the summary is withheld.
            guard let restoredFallback = await finalizer.finalize(
                usableFallback,
                prepared: prepared,
                modelAvailable: true
            ) else {
                return .failure(prepared.untranslatedSummaryReason)
            }
            try Task.checkCancellation()
            try await persistResult(
                messageID: messageID,
                result: restoredFallback,
                summaryInputFingerprint: prepared.summaryInputFingerprint,
                persist: persist
            )
            return .success(restoredFallback)
        } catch is CancellationError {
            return .cancelled
        } catch {
            let message = qwenFailureMessage(error)
            print("[Ohia] Hover summary failed messageID=\(messageID)")
            return .failure(message)
        }
    }

    private enum QwenPrimaryOutcome {
        case success(SummarizationResult)
        /// Qwen wrote a summary that could not be put in the reading language.
        case untranslated
        case unavailable
    }

    private static func qwenPrimary(
        messageID: UUID,
        prepared: SummarizationTranslationGrounding.PreparedInputs,
        mlx: any Summarizing,
        finalizer: SummaryDisplayFinalizer,
        persist: PersistSummary
    ) async -> QwenPrimaryOutcome {
        guard !Task.isCancelled else { return .unavailable }
        do {
            if let generated = try await mlx.summarize(
                bodyText: prepared.bodyText,
                senderName: prepared.senderName,
                subject: prepared.subject,
                context: prepared.context
            ), let usable = usableResult(generated, prepared: prepared) {
                guard let result = await finalizer.finalize(usable, prepared: prepared, modelAvailable: true) else {
                    return .untranslated
                }
                try Task.checkCancellation()
                try await persistResult(
                    messageID: messageID,
                    result: result,
                    summaryInputFingerprint: prepared.summaryInputFingerprint,
                    persist: persist
                )
                return .success(result)
            }
        } catch is CancellationError {
            return .unavailable
        } catch {
            return .unavailable
        }
        return .unavailable
    }

    private static func usableResult(
        _ result: SummarizationResult,
        prepared: SummarizationTranslationGrounding.PreparedInputs
    ) -> SummarizationResult? {
        let restored: SummarizationResult
        do {
            restored = try prepared.restoringSummaryResult(result)
        } catch {
            return nil
        }
        guard let summary = SummaryTextSanitizer.cleaned(restored.summary) else { return nil }
        return restored.replacingSummary(summary)
    }

    private static func qwenFailureMessage(_ error: Error) -> String {
        if let engineError = error as? TrainingEngineError {
            switch engineError {
            case .modelNotLoaded:
                return "Qwen summary unavailable: model is still loading."
            case .modelUnavailable(let detail):
                return "Qwen summary unavailable: \(cleanFailureDetail(detail))"
            case .generationFailed(let detail):
                return "Qwen summary failed: \(cleanFailureDetail(detail))"
            default:
                return "Qwen summary failed: \(cleanFailureDetail(engineError.localizedDescription))"
            }
        }
        if let summarizationError = error as? SummarizationError,
           case .modelUnavailable = summarizationError {
            return "Qwen summary unavailable: model is not available."
        }
        return "Qwen summary failed: \(cleanFailureDetail(error.localizedDescription))"
    }

    /// Collapses an error's text onto one line for the unavailable-reason
    /// surfaces. No length cap: the reason renders in wrapping text areas,
    /// and dots-truncating displayed text is banned house-wide.
    private static func cleanFailureDetail(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    static func persistResult(
        messageID: UUID,
        result: SummarizationResult,
        summaryInputFingerprint: String,
        persist: PersistSummary
    ) throws {
        try Task.checkCancellation()
        try persist(messageID, result, Date(), summaryInputFingerprint)
    }

    private static func cleaned(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private func store(_ key: RequestKey, _ result: SummarizationResult) {
        memoryCache[key] = result
        touch(key)
        while lru.count > capacity {
            let oldest = lru.removeFirst()
            memoryCache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: RequestKey) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }
}

/// Binds the display-language pass to one on-demand request. Nil when the
/// summary could not be put in the reading language.
struct SummaryDisplayFinalizer: Sendable {
    let guardrail: DisplayLanguageGuard?
    let messageID: UUID
    let accountID: UUID?

    func finalize(
        _ result: SummarizationResult,
        prepared: SummarizationTranslationGrounding.PreparedInputs,
        modelAvailable: Bool
    ) async -> SummarizationResult? {
        await prepared.finalizingDisplayLanguage(
            of: result,
            using: modelAvailable ? guardrail : guardrail?.withoutModel(),
            messageID: messageID,
            accountID: accountID
        ).result
    }
}
