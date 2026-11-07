// TranslationService.swift
// On-demand, cached coordinator for email-body translation. An in-memory LRU
// over a durable, bounded JSON cache, with per-request coalescing so a
// double-tap or a re-show can't fan out into multiple generations. Translation
// is always user-initiated, so requests run at interactive priority inside the
// active translator (`AppleTranslationAPITranslator` or `MLXTranslator`); this
// actor only decides whether a generation is needed and remembers the answer.
// When every caller awaiting a given generation cancels (e.g. the reader moves
// to another message), the underlying engine work is cancelled too.

import Foundation
import OSLog
import OhiaCore

private let translationLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "translation"
)

public actor TranslationService {
    private let translator: any Translating
    private let contextProvider: (any TranslationContextProviding)?
    private let modelActivityStatusPublisher: ModelActivityStatusPublisher?
    private let persistentCacheURL: URL?

    private var inFlight: [String: InFlightGeneration] = [:]
    private var generationEpochs: [String: UInt64] = [:]
    private var nextGenerationEpoch: UInt64 = 0
    /// The callers currently awaiting each in-flight generation, by key. When the
    /// set empties the generation is cancelled and removed, so a translation the
    /// user has navigated away from stops consuming the engine.
    private var waiters: [String: Set<UUID>] = [:]
    private var memoryCache: [String: TranslationResult] = [:]
    private var persistentCache: [String: PersistentCacheEntry] = [:]
    private var failures: [String: TranslationFailure] = [:]
    /// Resolves the public request-shaped failure lookup to the frozen engine
    /// identity that actually produced the most recent failure.
    private var latestFailureKeyByRequest: [String: String] = [:]
    /// Insertion order of failure keys, so the failure map can be FIFO-bounded
    /// independently of the success LRU (failures never enter `lru`).
    private var failureOrder: [String] = []
    private var lru: [String] = []
    private let capacity: Int
    private let persistentCapacity: Int

    public init(
        translator: any Translating,
        contextProvider: (any TranslationContextProviding)? = nil,
        modelActivityStatusPublisher: ModelActivityStatusPublisher? = nil,
        capacity: Int = 128,
        persistentCapacity: Int = 512,
        persistentCacheURL: URL? = nil
    ) {
        self.translator = translator
        self.contextProvider = contextProvider
        self.modelActivityStatusPublisher = modelActivityStatusPublisher
        self.capacity = max(1, capacity)
        self.persistentCapacity = max(capacity, persistentCapacity)
        self.persistentCacheURL = persistentCacheURL
        self.persistentCache = Self.loadPersistentCache(
            from: persistentCacheURL,
            capacity: max(capacity, persistentCapacity)
        )
    }

    /// Returns the cached translation for `(messageID, bodyText, targetLanguage)`
    /// or generates it. Coalesces concurrent requests for the same key. Returns
    /// `nil` when the body is empty or generation produced/threw nothing usable;
    /// in the failure case `failure(for:bodyText:targetLanguage:)` holds the reason.
    public func translation(
        for messageID: UUID,
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        detectedSourceLanguageCode: String? = nil,
        forceRefresh: Bool = false
    ) async -> TranslationResult? {
        guard !AccountDisconnectionRequest.isPending else { return nil }
        guard bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        let requestTranslator = translator.requestSnapshot()
        // Context is part of translation identity, so compile it before any
        // memory or durable-cache lookup. A Confirm/Edit/Delete or inferred
        // revision therefore changes the key immediately.
        let context = await compiledContext(
            messageID: messageID,
            bodyText: bodyText,
            targetLanguage: targetLanguage,
            detectedSourceLanguageCode: detectedSourceLanguageCode
        )
        guard !AccountDisconnectionRequest.isPending else { return nil }
        let engineTag = requestTranslator.cacheTag
        let fingerprint = Self.fingerprint(
            engineTag: engineTag,
            bodyText: bodyText,
            targetLanguageIdentifier: targetLanguage.identifier,
            contextFingerprint: context?.fingerprint
        )
        let cacheKey = Self.cacheKey(messageID: messageID, fingerprint: fingerprint)
        let failureLookupKey = Self.failureLookupKey(
            messageID: messageID,
            engineTag: engineTag,
            bodyText: bodyText,
            targetLanguageIdentifier: targetLanguage.identifier
        )
        let failureRequestKey = Self.failureRequestKey(
            messageID: messageID,
            bodyText: bodyText,
            targetLanguageIdentifier: targetLanguage.identifier
        )

        if forceRefresh {
            cancelInFlightAndInvalidate(cacheKey)
        } else if let cached = memoryCache[cacheKey] {
            touch(cacheKey)
            clearFailure(forRequestKey: failureRequestKey)
            return cached
        } else if let entry = persistentCache[cacheKey] {
            let result = TranslationResult(
                text: entry.text,
                targetLanguageIdentifier: entry.targetLanguageIdentifier,
                detectedSourceLanguageCode: entry.detectedSourceLanguageCode
            )
            storeInMemory(cacheKey, result)
            clearFailure(forRequestKey: failureRequestKey)
            return result
        }
        // Join an existing generation for this key, or start one. Either way the
        // caller is registered as a waiter so the work can be cancelled once the
        // last interested caller goes away.
        let generation: InFlightGeneration
        if let existing = inFlight[cacheKey] {
            generation = existing
        } else {
            let translator = requestTranslator
            let activityPublisher = self.modelActivityStatusPublisher
            let epoch = bumpGenerationEpoch(for: cacheKey)
            // The task is registered synchronously (no await before this point),
            // so coalescing/cancellation accounting stays race-free. Context was
            // compiled before lookup because its fingerprint is part of this
            // generation key.
            let task = Task<Outcome, Never> {
                let activityToken = activityPublisher?.begin(.translating, source: "translation")
                defer {
                    if let activityToken {
                        activityPublisher?.end(activityToken)
                    }
                }
                let outcome = await Self.produce(
                    translator: translator,
                    bodyText: bodyText,
                    targetLanguage: targetLanguage,
                    detectedSourceLanguageCode: detectedSourceLanguageCode,
                    context: context
                )
                return outcome
            }
            generation = InFlightGeneration(epoch: epoch, task: task)
            inFlight[cacheKey] = generation
        }

        let waiterID = UUID()
        waiters[cacheKey, default: []].insert(waiterID)

        let outcome = await withTaskCancellationHandler {
            await generation.task.value
        } onCancel: {
            Task { await self.waiterDidCancel(cacheKey, waiterID) }
        }

        releaseWaiter(cacheKey, waiterID)
        return apply(
            outcome,
            cacheKey: cacheKey,
            messageID: messageID,
            fingerprint: fingerprint,
            targetLanguageIdentifier: targetLanguage.identifier,
            failureLookupKey: failureLookupKey,
            failureRequestKey: failureRequestKey,
            epoch: generation.epoch
        )
    }

    /// A caller's surrounding task was cancelled — drop it and, if it was the last
    /// waiter, cancel the shared engine work.
    private func waiterDidCancel(_ key: String, _ id: UUID) {
        removeWaiter(key, id, cancelTaskIfLast: true)
    }

    /// A caller finished awaiting (normally or because the task was cancelled).
    /// Idempotent with `waiterDidCancel`.
    private func releaseWaiter(_ key: String, _ id: UUID) {
        removeWaiter(key, id, cancelTaskIfLast: false)
    }

    /// Removes one waiter. The in-flight task lives exactly as long as ≥1 caller
    /// awaits it: when the last waiter for a key leaves, the task is dropped (and
    /// cancelled, if that leave was itself a cancellation) so a later request
    /// starts a fresh generation rather than joining a dying one. Dropping `id`
    /// only when it was actually present makes this idempotent and race-free — a
    /// caller already removed by `waiterDidCancel` no-ops here and never clobbers
    /// a task a newer caller has since started under the same key.
    private func removeWaiter(_ key: String, _ id: UUID, cancelTaskIfLast: Bool) {
        guard waiters[key]?.remove(id) != nil else { return }
        guard waiters[key]?.isEmpty != false else { return }
        waiters[key] = nil
        if cancelTaskIfLast { inFlight[key]?.task.cancel() }
        inFlight[key] = nil
    }

    /// Commits an outcome to the caches/failure map and returns the displayable
    /// result. Actor-isolated and idempotent, so a coalesced caller awaiting the
    /// same in-flight task can run it again without harm.
    private func apply(
        _ outcome: Outcome,
        cacheKey: String,
        messageID: UUID,
        fingerprint: String,
        targetLanguageIdentifier: String,
        failureLookupKey: String,
        failureRequestKey: String,
        epoch: UInt64
    ) -> TranslationResult? {
        guard generationEpochs[cacheKey] == epoch else { return nil }
        switch outcome {
        case .success(let result):
            store(
                cacheKey,
                messageID: messageID,
                fingerprint: fingerprint,
                targetLanguageIdentifier: targetLanguageIdentifier,
                result
            )
            clearFailure(forRequestKey: failureRequestKey)
            return result
        case .failure(let failure):
            recordFailure(failureLookupKey, requestKey: failureRequestKey, failure: failure)
            return nil
        case .cancelled, .empty:
            return nil
        }
    }

    private func recordFailure(
        _ key: String,
        requestKey: String,
        failure: TranslationFailure
    ) {
        if let previous = latestFailureKeyByRequest.updateValue(key, forKey: requestKey),
           previous != key {
            failures.removeValue(forKey: previous)
            failureOrder.removeAll { $0 == previous }
        }
        if failures[key] == nil {
            failureOrder.append(key)
        }
        failures[key] = failure
        while failureOrder.count > capacity {
            let oldest = failureOrder.removeFirst()
            failures.removeValue(forKey: oldest)
            latestFailureKeyByRequest = latestFailureKeyByRequest.filter { $0.value != oldest }
        }
    }

    private func clearFailure(forRequestKey requestKey: String) {
        guard let key = latestFailureKeyByRequest.removeValue(forKey: requestKey) else { return }
        guard failures.removeValue(forKey: key) != nil else { return }
        failureOrder.removeAll { $0 == key }
    }

    /// The most recent failure for this visible request shape, including the
    /// frozen engine identity that actually ran it. A Settings change during
    /// the request therefore cannot make the completed failure undiscoverable.
    public func failure(
        for messageID: UUID,
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage
    ) -> TranslationFailure? {
        let requestKey = Self.failureRequestKey(
            messageID: messageID,
            bodyText: bodyText,
            targetLanguageIdentifier: targetLanguage.identifier
        )
        guard let failureKey = latestFailureKeyByRequest[requestKey] else { return nil }
        return failures[failureKey]
    }

    private func compiledContext(
        messageID: UUID,
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        detectedSourceLanguageCode: String?
    ) async -> TranslationContext? {
        guard let contextProvider else { return nil }
        return await contextProvider.translationContext(
            forMessage: messageID,
            bodyText: bodyText,
            targetLanguage: targetLanguage,
            sourceLanguageCode: detectedSourceLanguageCode
        )
    }

    public func clearCache() {
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        waiters.removeAll()
        memoryCache.removeAll()
        persistentCache.removeAll()
        failures.removeAll()
        latestFailureKeyByRequest.removeAll()
        failureOrder.removeAll()
        lru.removeAll()
        generationEpochs.removeAll()
        try? persistCache()
    }

    private func cancelInFlightAndInvalidate(_ key: String) {
        inFlight[key]?.task.cancel()
        inFlight[key] = nil
        waiters[key] = nil
        _ = bumpGenerationEpoch(for: key)
    }

    private func bumpGenerationEpoch(for key: String) -> UInt64 {
        nextGenerationEpoch &+= 1
        generationEpochs[key] = nextGenerationEpoch
        return nextGenerationEpoch
    }

    // MARK: - Generation

    private struct InFlightGeneration {
        let epoch: UInt64
        let task: Task<Outcome, Never>
    }

    private enum Outcome: Sendable {
        case success(TranslationResult)
        case failure(TranslationFailure)
        case cancelled
        case empty
    }

    private static func produce(
        translator: any Translating,
        bodyText: String,
        targetLanguage: SummarizationTargetLanguage,
        detectedSourceLanguageCode: String?,
        context: TranslationContext?
    ) async -> Outcome {
        do {
            let protection: PreparedTranslationGlossaryProtection?
            if translator.usesContext {
                protection = nil
            } else {
                let prepared = TranslationGlossaryProtection().prepare(
                    bodyText: bodyText,
                    exactGlossary: context?.exactGlossary ?? []
                )
                protection = prepared.mappings.isEmpty ? nil : prepared
            }
            guard let result = try await translator.translate(
                bodyText: protection?.protectedText ?? bodyText,
                targetLanguage: targetLanguage,
                detectedSourceLanguageCode: detectedSourceLanguageCode,
                context: context
            ) else {
                return .empty
            }
            let protectedResult: TranslationResult
            if let protection {
                protectedResult = TranslationResult(
                    text: try protection.restore(in: result.text, requireAll: true),
                    targetLanguageIdentifier: result.targetLanguageIdentifier,
                    detectedSourceLanguageCode: result.detectedSourceLanguageCode
                )
            } else {
                protectedResult = result
            }
            translationLogger.info("Translation generated into \(targetLanguage.identifier, privacy: .public)")
            return .success(protectedResult)
        } catch is CancellationError {
            return .cancelled
        } catch let error as TranslationError {
            return .failure(failure(for: error))
        } catch {
            return .failure(TranslationFailure(
                message: "Translation failed: \(cleanDetail(error.localizedDescription))",
                requiresLanguageDownload: false
            ))
        }
    }

    private static func failure(for error: TranslationError) -> TranslationFailure {
        switch error {
        case .empty:
            return TranslationFailure(
                message: "The model returned no translation.",
                requiresLanguageDownload: false
            )
        case .modelUnavailable(let detail):
            return TranslationFailure(
                message: "Translation unavailable: \(cleanDetail(detail))",
                requiresLanguageDownload: false
            )
        case .languagesNotInstalled(let detail):
            return TranslationFailure(
                message: "Translation unavailable: \(cleanDetail(detail))",
                requiresLanguageDownload: true
            )
        case .glossaryProtectionFailed:
            return TranslationFailure(
                message: "Translation failed because an exact glossary rendering could not be preserved.",
                requiresLanguageDownload: false
            )
        case .underlying(let detail):
            return TranslationFailure(
                message: "Translation failed: \(cleanDetail(detail))",
                requiresLanguageDownload: false
            )
        }
    }

    private static func cleanDetail(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 180 else { return collapsed }
        return String(collapsed.prefix(179)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cache

    private func store(
        _ key: String,
        messageID: UUID,
        fingerprint: String,
        targetLanguageIdentifier: String,
        _ result: TranslationResult
    ) {
        persistentCache[key] = PersistentCacheEntry(
            messageID: messageID,
            fingerprint: fingerprint,
            text: result.text,
            targetLanguageIdentifier: targetLanguageIdentifier,
            detectedSourceLanguageCode: result.detectedSourceLanguageCode,
            updatedAt: Date()
        )
        prunePersistentCache()
        storeInMemory(key, result)
        try? persistCache()
    }

    /// Evicts the oldest persistent entries (by `updatedAt`) once the on-disk
    /// cache exceeds its capacity. Without this the durable JSON would grow
    /// without bound as the user translates more bodies, and every write would
    /// re-encode an ever-larger file. Translation bodies are large, so the
    /// persistent cache is bounded independently of the in-memory LRU.
    private func prunePersistentCache() {
        guard persistentCache.count > persistentCapacity else { return }
        let ordered = persistentCache.sorted { $0.value.updatedAt < $1.value.updatedAt }
        let overflow = persistentCache.count - persistentCapacity
        for (key, _) in ordered.prefix(overflow) {
            persistentCache.removeValue(forKey: key)
        }
    }

    private func storeInMemory(_ key: String, _ result: TranslationResult) {
        memoryCache[key] = result
        touch(key)
        while lru.count > capacity {
            let oldest = lru.removeFirst()
            memoryCache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: String) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    private func persistCache() throws {
        guard let persistentCacheURL else { return }
        let container = PersistentCacheContainer(entries: persistentCache)
        let data = try JSONEncoder().encode(container)
        try FileManager.default.createDirectory(
            at: persistentCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistentCacheURL, options: .atomic)
    }

    private static func loadPersistentCache(
        from url: URL?,
        capacity: Int
    ) -> [String: PersistentCacheEntry] {
        guard let url,
              let data = try? Data(contentsOf: url),
              let container = try? JSONDecoder().decode(PersistentCacheContainer.self, from: data) else {
            return [:]
        }
        let usable = container.entries.filter { _, entry in
            entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        guard usable.count > capacity else { return usable }
        // A cache persisted before bounding (or with a larger capacity) can
        // exceed the limit on load — keep the most recently updated entries.
        let newestFirst = usable.sorted { $0.value.updatedAt > $1.value.updatedAt }
        return Dictionary(uniqueKeysWithValues: newestFirst.prefix(capacity).map { ($0.key, $0.value) })
    }

    static func cacheKey(messageID: UUID, fingerprint: String) -> String {
        "\(messageID.uuidString):\(fingerprint)"
    }

    private static func failureLookupKey(
        messageID: UUID,
        engineTag: String,
        bodyText: String,
        targetLanguageIdentifier: String
    ) -> String {
        let fingerprint = stableHash([
            engineTag,
            targetLanguageIdentifier,
            bodyText
        ].joined(separator: "\u{1F}"))
        return cacheKey(messageID: messageID, fingerprint: fingerprint)
    }

    private static func failureRequestKey(
        messageID: UUID,
        bodyText: String,
        targetLanguageIdentifier: String
    ) -> String {
        let fingerprint = stableHash([
            targetLanguageIdentifier,
            bodyText
        ].joined(separator: "\u{1F}"))
        return cacheKey(messageID: messageID, fingerprint: fingerprint)
    }

    /// Stable hash over the engine, exact source text, and target language, so
    /// any edit to the body, a language switch, or an engine switch produces a
    /// fresh key (and regeneration) rather than serving another engine's output.
    static func fingerprint(
        engineTag: String,
        bodyText: String,
        targetLanguageIdentifier: String,
        contextFingerprint: String?
    ) -> String {
        stableHash([
            engineTag,
            targetLanguageIdentifier,
            bodyText,
            contextFingerprint ?? ""
        ].joined(separator: "\u{1F}"))
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

private struct PersistentCacheContainer: Codable {
    var entries: [String: PersistentCacheEntry]
}

private struct PersistentCacheEntry: Codable {
    var messageID: UUID
    var fingerprint: String
    var text: String
    var targetLanguageIdentifier: String
    var detectedSourceLanguageCode: String?
    var updatedAt: Date
}
