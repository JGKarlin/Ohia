import Foundation
import OSLog
import SwiftData
import OhiaCore
import OhiaML

private let accountMemoryLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "account-memory"
)

private let maximumStoredDiscourseMemoryJSONBytes = 1_000_000

private actor AccountMemoryExtractionCancellation {
    private var cancelledForYield = false

    func markYieldCancellation() {
        cancelledForYield = true
    }

    func wasCancelledForYield() -> Bool {
        cancelledForYield
    }
}

@MainActor
public final class AccountMemoryRefreshWorker {
    public struct Outcome: Sendable {
        public let messagesVisited: Int
        public let memoriesProjected: Int
        public let deferred: Bool
    }

    public struct Pacing: Sendable {
        public var maxExtractionsPerInvocation: Int
        /// Higher extraction budget used during the one-time newest→oldest
        /// full-history backfill. Defaults to 8 so the backfill drains the
        /// corpus faster without blocking the main thread (all yield checks
        /// remain active; only the per-invocation count rises).
        public var maxExtractionsPerInvocationBackfill: Int
        public var interExtractionDelayNanoseconds: UInt64
        public var generationTaskPriority: TaskPriority

        public init(
            maxExtractionsPerInvocation: Int = 2,
            maxExtractionsPerInvocationBackfill: Int = 8,
            interExtractionDelayNanoseconds: UInt64 = 250_000_000,
            generationTaskPriority: TaskPriority = .background
        ) {
            self.maxExtractionsPerInvocation = max(1, maxExtractionsPerInvocation)
            self.maxExtractionsPerInvocationBackfill = max(1, maxExtractionsPerInvocationBackfill)
            self.interExtractionDelayNanoseconds = interExtractionDelayNanoseconds
            self.generationTaskPriority = generationTaskPriority
        }
    }

    private struct MemoryProjectionOutcome {
        let projected: Int
        let deferred: Bool
        let deferralError: String?

        static let noWork = MemoryProjectionOutcome(
            projected: 0,
            deferred: false,
            deferralError: nil
        )
    }

    private struct MemoryDistillationResumeProgress: Codable, Sendable {
        var processedClaimKeysByDossier: [String: [String]]
        var appliedDossierKeys: [String]

        static let empty = MemoryDistillationResumeProgress(
            processedClaimKeysByDossier: [:],
            appliedDossierKeys: []
        )
    }

    private let engine: any TrainingEngine
    private let messageStoreURL: URL?
    private let shouldYield: @MainActor (ModelContext) -> Bool
    private let pacing: Pacing
    /// Optional translation-memory dreaming producer. When present, each
    /// successful per-account projection also distills translation style rules
    /// and consolidates the translation dossiers for the languages the account
    /// corresponds in (each dossier is consumed when translating INTO that
    /// language). Nil (the default) disables the pass entirely, so test and
    /// bootstrap callers see no behavior change.
    private let translationDreamer: (any TranslationMemoryDreaming)?
    /// Optional embedding provider passed straight through to every
    /// `MemoryDistiller.apply` call: powers the embedding-backed semantic
    /// dedup backstop on the distiller's add / split-insert paths. Nil
    /// (the default) disables the backstop — `apply` falls back to its
    /// lexical-only dedup, matching prior behavior exactly.
    private let memoryEmbedder: (any EmbeddingProvider)?

    /// Minimum messages in a language before its dossier is dreamed.
    static let translationDreamMinimumMessages = 5
    /// Dossiers dreamed per account per cycle. Bounded to cap background
    /// generation cost; coverage rotates by dossier staleness so low-volume
    /// languages are not starved by a few high-volume ones.
    static let translationDreamLanguagesPerCycle = 2
    private let seedExtractor = SeedFromMetadata()
    private let assembler = ConversationMemoryAssembler()
    public init(
        engine: any TrainingEngine,
        messageStoreURL: URL? = nil,
        shouldYield: @escaping @MainActor (ModelContext) -> Bool = { _ in false },
        pacing: Pacing = Pacing(),
        translationDreamer: (any TranslationMemoryDreaming)? = nil,
        memoryEmbedder: (any EmbeddingProvider)? = nil
    ) {
        self.engine = engine
        self.messageStoreURL = messageStoreURL
        self.shouldYield = shouldYield
        self.pacing = pacing
        self.translationDreamer = translationDreamer
        self.memoryEmbedder = memoryEmbedder
    }

    public func run(
        context: ModelContext,
        batchSize: Int,
        now: Date = .now
    ) async throws -> Outcome {
        // Worker-only processes can reach this seam without OhiaApp startup.
        // Re-running after a completed migration is a no-op.
        _ = try TranslationGlossaryCutoverApplier(modelContext: context).run()
        let accounts = try context.fetch(FetchDescriptor<Account>())
            .sorted { left, right in
                left.emailAddress.localizedStandardCompare(right.emailAddress) == .orderedAscending
            }
        var totalVisited = 0
        var totalProjected = 0
        var didDefer = false

        for account in accounts {
            let state = try fetchOrCreateState(accountID: account.id, context: context)
            let counts = try countsForAccount(account, context: context)
            let trigger = state.extractionContractVersionRaw != DiscourseMemory.threadVersion
                ? "contractMismatch"
                : AccountMemoryRefreshEligibility.triggerReason(
                    state: state,
                    counts: counts,
                    now: now
                )
            guard let trigger else {
                continue
            }
            if shouldYield(context) {
                let projected = try await bootstrapProject(
                    account: account,
                    state: state,
                    counts: counts,
                    context: context
                )
                totalProjected += projected
                try markDeferred(
                    state: state,
                    counts: counts,
                    triggerReason: trigger,
                    now: now,
                    context: context
                )
                didDefer = true
                break
            }

            do {
                let outcome = try await refresh(
                    account: account,
                    state: state,
                    counts: counts,
                    triggerReason: trigger,
                    context: context,
                    batchSize: batchSize,
                    now: now
                )
                totalVisited += outcome.messagesVisited
                totalProjected += outcome.memoriesProjected
                didDefer = didDefer || outcome.deferred
                if outcome.deferred {
                    break
                }
            } catch {
                state.lastRunCompletedAt = Date()
                state.lastStatusRaw = AccountMemoryRefreshStatus.failed
                state.lastError = error.localizedDescription
                state.updatedAt = Date()
                try context.save()
                throw error
            }
        }

        return Outcome(
            messagesVisited: totalVisited,
            memoriesProjected: totalProjected,
            deferred: didDefer
        )
    }

    private func markDeferred(
        state: AccountMemoryRefreshState,
        counts: AccountMemoryMessageCounts,
        triggerReason: String,
        now: Date,
        context: ModelContext
    ) throws {
        state.lastRunStartedAt = now
        state.lastRunCompletedAt = now
        state.lastEligibleMessageCount = counts.eligibleMessages
        state.lastSentMessageCount = counts.sentMessages
        state.lastReceivedMessageCount = counts.receivedMessages
        state.lastStatusRaw = AccountMemoryRefreshStatus.deferred
        state.lastError = nil
        state.lastTriggerReasonRaw = triggerReason
        state.updatedAt = now
        try context.save()
    }

    private func refresh(
        account: Account,
        state: AccountMemoryRefreshState,
        counts: AccountMemoryMessageCounts,
        triggerReason: String,
        context: ModelContext,
        batchSize: Int,
        now: Date
    ) async throws -> Outcome {
        state.lastRunStartedAt = now
        state.lastStatusRaw = AccountMemoryRefreshStatus.running
        state.lastError = nil
        state.lastTriggerReasonRaw = triggerReason
        state.lastEligibleMessageCount = counts.eligibleMessages
        state.lastSentMessageCount = counts.sentMessages
        state.lastReceivedMessageCount = counts.receivedMessages
        state.updatedAt = now
        try context.save()

        // Extraction contract change (e.g. a `DiscourseMemory.threadVersion`
        // bump): every stored thread memory is now stale corpus-wide. Re-enter
        // newest-first backfill so the highest-value (most recent) memories are
        // re-extracted first at the faster backfill budget, instead of drifting
        // through the mailbox oldest-first at the slow incremental budget. The
        // existing machinery does the rest: `processingOrder` reverses on
        // `backfillCompleted == false`, the backfill budget applies, and a
        // clean full drain flips `backfillCompleted` back to `true` below.
        if state.extractionContractVersionRaw != DiscourseMemory.threadVersion {
            let accountID = account.id
            let legacyRows = try context.fetch(FetchDescriptor<AccountMemory>(
                predicate: #Predicate<AccountMemory> { $0.accountID == accountID }
            ))
            AccountMemoryContractCutover.apply(to: legacyRows, now: now)
            state.backfillCompleted = false
            state.cursorDate = nil
            state.cursorMessageID = nil
            state.cursorProcessedMessageCount = 0
            state.extractionContractVersionRaw = DiscourseMemory.threadVersion
            state.distillationResumeJSON = nil
            state.updatedAt = now
            try context.save()
        }

        let messages = try eligibleMessages(accountID: account.id, context: context)
        var projected = 0
        // No pre-extraction projection: account memories are now produced by
        // the LLM distiller in the single post-extraction pass below, so there
        // is no cheap seed-only projection to run before the extraction loop.

        if shouldYield(context) || !engine.isModelLoaded {
            state.lastRunCompletedAt = Date()
            state.lastStatusRaw = AccountMemoryRefreshStatus.deferred
            state.updatedAt = Date()
            try context.save()
            return Outcome(messagesVisited: 0, memoriesProjected: projected, deferred: true)
        }

        let extractionsPerInvocation = state.backfillCompleted
            ? pacing.maxExtractionsPerInvocation
            : pacing.maxExtractionsPerInvocationBackfill
        // Budget is the sole throttle now: one generation per stale THREAD
        // group. The old `perBatchLimit` (min of the invocation budget and
        // `batchSize / 16`) sized a per-message inner batch; thread-unit
        // extraction has no inner batch, so the invocation budget alone
        // governs how many groups one pass extracts.
        var extractionBudget = extractionsPerInvocation
        var visited = 0
        var deferred = false
        let activeCustomCategoryKeys = Set(
            CustomMailCategoryCatalog.activeDescriptors(in: context).map(\.key)
        )
        // Side-attribution addresses for the thread prompt: the account address
        // plus every send-only identity address, normalized (mirrors the
        // `ownAddresses` construction in `dimensionGroups`).
        let ownAddresses = Set(
            ([account.emailAddress] + account.identities.map(\.address))
                .map(Self.normalizedAddress)
                .filter { $0.isEmpty == false }
        )
        // Group the eligible corpus into thread units once. Nil-thread messages
        // form singleton groups keyed by their own id. `messages` is
        // oldest→newest, so each members list is already chronological.
        var membersByGroupKey: [UUID: [Message]] = [:]
        for message in messages {
            membersByGroupKey[Self.groupKey(for: message), default: []].append(message)
        }

        let extractor = ThreadDiscourseExtractor(
            engine: engine,
            generationTaskPriority: pacing.generationTaskPriority
        )
        // A group is extracted at most once per invocation. The guard also
        // makes the nil-result path safe: a nil result leaves members stale, so
        // without it the walk would re-hit the same group's later members and
        // re-extract; with it, those members only advance the cursor.
        var processedGroupKeys = Set<UUID>()

        for message in processingOrder(messages, backfillCompleted: state.backfillCompleted)
        where isAfterCursor(message, state: state) {
            if shouldYield(context) {
                deferred = true
                break
            }
            let key = Self.groupKey(for: message)
            if processedGroupKeys.contains(key) {
                // A later member of an already-processed group: the extraction
                // (or nil skip) happened when the walk first reached this
                // group; here we only advance the cursor over the member so the
                // persisted cursor stays consistent with the old per-message
                // advance semantics (one advance per member).
                advanceCursor(to: message, state: state)
                visited += 1
                continue
            }
            let members = membersByGroupKey[key] ?? [message]
            let fingerprint = ThreadExtractionPacketBuilder.fingerprint(
                memberIDs: members.map(\.id),
                version: DiscourseMemory.threadVersion
            )
            guard isThreadGroupStale(members: members, fingerprint: fingerprint) else {
                // Non-stale group: fast-skip exactly like the old version gate.
                processedGroupKeys.insert(key)
                advanceCursor(to: message, state: state)
                visited += 1
                continue
            }
            guard extractionBudget > 0 else {
                deferred = true
                break
            }

            let packet = buildThreadPacket(members: members, now: now)
            let language = majorityLanguage(members: members)
            let extraction = try await extractThreadRefinement(
                extractor: extractor,
                packet: packet,
                userAddresses: ownAddresses,
                language: language,
                context: context
            )
            if extraction.yielded {
                // Yield cancelled the generation: defer WITHOUT advancing the
                // cursor or marking the group processed, so the whole group
                // retries on the next pass (matches the old `extractRefinement`
                // yielded case).
                deferred = true
                break
            }
            try persistThreadGroup(
                members: members,
                returned: extraction.memories,
                fingerprint: fingerprint,
                activeCustomCategoryKeys: activeCustomCategoryKeys,
                context: context
            )
            extractionBudget -= 1
            processedGroupKeys.insert(key)
            advanceCursor(to: message, state: state)
            visited += 1
            if pacing.interExtractionDelayNanoseconds > 0,
               extractionBudget > 0 {
                try await Task.sleep(nanoseconds: pacing.interExtractionDelayNanoseconds)
            }
        }

        let messagesForAssembly = deferred
            ? processedMessages(messages: messages, state: state)
            : messages
        // The projection pass is now an LLM distiller pass — only run it when
        // the worker is NOT being asked to yield and the model is loaded.
        // Under yield we defer without projecting; the next idle run re-derives
        // both account and dimension dossiers.
        if !shouldYield(context),
           engine.isModelLoaded,
           messagesForAssembly.isEmpty == false || !deferred {
            let projection = try await assembleProject(
                account: account,
                messages: messagesForAssembly,
                gateMessages: messages,
                state: state,
                counts: counts,
                context: context,
                now: Date()
            )
            projected += projection.projected
            deferred = deferred || projection.deferred
            if let deferralError = projection.deferralError {
                state.lastError = deferralError
            }
            if deferred == false {
                // Translation dreaming runs after the dossier projection on a
                // full, non-deferred pass. No-op unless a dreamer is injected.
                deferred = try await dreamTranslations(
                    account: account,
                    messages: messages,
                    context: context,
                    now: Date()
                )
            }
        } else if deferred == false {
            // Yield arrived after the extraction loop completed cleanly; treat
            // the run as deferred so the projection happens on the next pass.
            deferred = true
        }

        if deferred {
            state.lastRunCompletedAt = Date()
            state.lastStatusRaw = AccountMemoryRefreshStatus.deferred
            state.updatedAt = Date()
            try context.save()
        } else {
            state.cursorDate = nil
            state.cursorMessageID = nil
            state.cursorProcessedMessageCount = 0
            state.distillationResumeJSON = nil
            // One-time backfill completion: once the cursor drains the whole
            // corpus in a successful run, mark it done so subsequent runs use
            // the normal oldest→newest incremental order and normal pacing.
            if state.backfillCompleted == false {
                state.backfillCompleted = true
            }
            state.lastEligibleMessageCount = counts.eligibleMessages
            state.lastSentMessageCount = counts.sentMessages
            state.lastReceivedMessageCount = counts.receivedMessages
            state.lastRunCompletedAt = Date()
            state.lastSuccessfulRunAt = state.lastRunCompletedAt
            state.lastStatusRaw = AccountMemoryRefreshStatus.succeeded
            state.updatedAt = Date()
            try context.save()
        }

        return Outcome(messagesVisited: visited, memoriesProjected: projected, deferred: deferred)
    }

    private func bootstrapProject(
        account: Account,
        state: AccountMemoryRefreshState,
        counts: AccountMemoryMessageCounts,
        context: ModelContext
    ) async throws -> Int {
        // Bootstrap runs while the worker is already being asked to yield.
        // Memory projection is now an LLM distiller pass, so under yield we do
        // no model work at all — mark deferred (handled by the caller) and let
        // the next idle run produce both account and dimension dossiers.
        _ = (account, state, counts, context)
        return 0
    }

    /// Dreams translation memories for the languages the account corresponds in.
    /// For each selected language it distills durable translation style rules and
    /// consolidates the dossier (reinforce / weaken / delete). Bounded to a few
    /// dossiers per cycle, rotated by staleness so coverage spreads across
    /// languages over time, and gated on yield so it never preempts foreground
    /// work. No-op unless a dreamer is injected.
    private func dreamTranslations(
        account: Account,
        messages: [Message],
        context: ModelContext,
        now: Date
    ) async throws -> Bool {
        guard let translationDreamer, engine.isModelLoaded else { return false }
        guard shouldYield(context) == false else { return true }

        let counts = Self.messageLanguageCounts(messages: messages)
        guard counts.isEmpty == false else { return false }

        let languages = Self.selectDreamLanguages(
            messageLanguageCounts: counts,
            dossierFreshnessByCode: translationDossierFreshness(accountID: account.id, context: context),
            minimumMessages: Self.translationDreamMinimumMessages,
            limit: Self.translationDreamLanguagesPerCycle
        )

        for code in languages {
            if shouldYield(context) { return true }
            if engine.isModelLoaded == false { return false }
            let yielded = try await runYieldMonitoredDream(context: context) {
                await translationDreamer.dream(
                    accountID: account.id,
                    targetLanguageCode: code,
                    displayName: Self.languageDisplayName(for: code),
                    modelContext: context,
                    now: now
                )
            }
            if yielded { return true }
        }
        return false
    }

    /// Polls the scheduler's foreground-yield signal while a translation-style
    /// distillation pass is in flight. Cancelling the outer dream task reaches the
    /// producer's generation cancellation handler and interrupts Qwen.
    private func runYieldMonitoredDream(
        context: ModelContext,
        operation: @escaping @MainActor () async -> Int
    ) async throws -> Bool {
        let yieldCancellation = AccountMemoryExtractionCancellation()
        let dreamTask = Task { @MainActor in await operation() }
        let monitorTask = Task { @MainActor in
            while Task.isCancelled == false {
                if shouldYield(context) {
                    await yieldCancellation.markYieldCancellation()
                    dreamTask.cancel()
                    return
                }
                await Task.yield()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        return try await withTaskCancellationHandler {
            defer { monitorTask.cancel() }
            _ = await dreamTask.value
            try Task.checkCancellation()
            return await yieldCancellation.wasCancelledForYield()
        } onCancel: {
            dreamTask.cancel()
            monitorTask.cancel()
        }
    }

    /// Canonical base-code counts of `languageDetected` across the account's
    /// eligible messages. Used by the translation-style distillation pass.
    static func messageLanguageCounts(messages: [Message]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for message in messages {
            guard let raw = message.languageDetected, raw.isEmpty == false else { continue }
            let code = EmailLanguageDetector.canonicalBaseCode(raw)
            guard code.isEmpty == false else { continue }
            counts[code, default: 0] += 1
        }
        return counts
    }

    /// Newest `updatedAt` per translation-dossier language code for an account.
    /// Languages absent from the result have never been dreamed.
    private func translationDossierFreshness(accountID: UUID, context: ModelContext) -> [String: Date] {
        let rows = (try? context.fetch(
            FetchDescriptor<AccountMemory>(predicate: #Predicate { $0.accountID == accountID })
        )) ?? []
        var freshness: [String: Date] = [:]
        for row in rows where row.dimensionKind == AccountMemoryDimension.translation {
            let code = row.resolvedDimensionValue
            guard code.isEmpty == false else { continue }
            freshness[code] = freshness[code].map { max($0, row.updatedAt) } ?? row.updatedAt
        }
        return freshness
    }

    /// Selects which language dossiers to dream this cycle. Qualifying languages
    /// (≥ `minimumMessages`) are ordered never-dreamed first, then stalest
    /// dossier first, then by message volume — so a few high-volume languages
    /// can't permanently starve lower-volume ones. Pure for unit testing.
    static func selectDreamLanguages(
        messageLanguageCounts: [String: Int],
        dossierFreshnessByCode: [String: Date],
        minimumMessages: Int,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        let qualifying = messageLanguageCounts.filter { $0.value >= minimumMessages }
        let ordered = qualifying.keys.sorted { lhs, rhs in
            switch (dossierFreshnessByCode[lhs], dossierFreshnessByCode[rhs]) {
            case (nil, .some): return true            // never-dreamed first
            case (.some, nil): return false
            case let (.some(l), .some(r)) where l != r: return l < r  // stalest first
            default: break
            }
            let lc = messageLanguageCounts[lhs] ?? 0
            let rc = messageLanguageCounts[rhs] ?? 0
            if lc != rc { return lc > rc }            // then highest volume
            return lhs < rhs                          // stable tiebreak
        }
        return Array(ordered.prefix(limit))
    }

    /// Localized label for a base language code, e.g. `ja` → "Japanese". Used as
    /// the translation dossier's display name; the dossier is keyed by the code.
    private static func languageDisplayName(for code: String) -> String {
        let localized = Locale.current.localizedString(forLanguageCode: code)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (localized?.isEmpty == false ? localized! : code)
    }

    /// Runs one thread-unit extraction under the yield monitor. Mirrors the
    /// retired per-message `extractRefinement`: the generation runs in a child
    /// task while a MainActor monitor polls `shouldYield` and cancels it; a
    /// yield-driven cancellation is reported as `yielded == true` so the caller
    /// defers the whole group. `ThreadDiscourseExtractor.extract` already maps a
    /// soft cancellation / parse failure / unloaded engine to `nil`, so a nil
    /// return with `yielded == false` is the "no refinement this pass" signal.
    private func extractThreadRefinement(
        extractor: ThreadDiscourseExtractor,
        packet: ThreadExtractionPacket,
        userAddresses: Set<String>,
        language: String?,
        context: ModelContext
    ) async throws -> (memories: [UUID: DiscourseMemory]?, yielded: Bool) {
        let cancellation = AccountMemoryExtractionCancellation()
        let extractionTask = Task {
            try await extractor.extract(
                packet: packet,
                userAddresses: userAddresses,
                language: language
            )
        }
        let monitorTask = Task { @MainActor in
            while Task.isCancelled == false {
                if shouldYield(context) {
                    await cancellation.markYieldCancellation()
                    extractionTask.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { monitorTask.cancel() }

        do {
            let memories = try await extractionTask.value
            return (memories, await cancellation.wasCancelledForYield())
        } catch is CancellationError {
            if await cancellation.wasCancelledForYield() {
                return (nil, true)
            }
            throw CancellationError()
        }
    }

    private func fetchOrCreateState(
        accountID: UUID,
        context: ModelContext
    ) throws -> AccountMemoryRefreshState {
        var descriptor = FetchDescriptor<AccountMemoryRefreshState>(
            predicate: #Predicate<AccountMemoryRefreshState> { state in
                state.accountID == accountID
            }
        )
        descriptor.fetchLimit = 1
        if let state = try context.fetch(descriptor).first {
            return state
        }
        let state = AccountMemoryRefreshState(accountID: accountID)
        context.insert(state)
        try context.save()
        return state
    }

    private func countsForAccount(
        _ account: Account,
        context: ModelContext
    ) throws -> AccountMemoryMessageCounts {
        if let messageStoreURL,
           let counts = try? MessageStoreHotPath.accountMemoryMessageCounts(
            accountID: account.id,
            storeURL: messageStoreURL
           ) {
            return counts
        }
        let messages = try eligibleMessages(accountID: account.id, context: context)
        let sent = messages.filter(\.isSentByUser).count
        return AccountMemoryMessageCounts(
            eligibleMessages: messages.count,
            sentMessages: sent,
            receivedMessages: max(0, messages.count - sent)
        )
    }

    private func eligibleMessages(
        accountID: UUID,
        context: ModelContext
    ) throws -> [Message] {
        // Account scoping happens in the store so a multi-account mailbox
        // never materializes other accounts' messages. Summary availability
        // stays in memory because relationship-derived optional text is not a
        // reliable SwiftData predicate boundary.
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.accountID == accountID || message.account?.id == accountID
            }
        )
        return try context.fetch(descriptor)
            .filter { message in
                message.analysis?.bodySummary?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty == false
                    && message.vectorTimeFilterDate != nil
            }
            .sorted { left, right in
                let leftDate = left.vectorTimeFilterDate ?? .distantPast
                let rightDate = right.vectorTimeFilterDate ?? .distantPast
                if leftDate != rightDate { return leftDate < rightDate }
                return left.id.uuidString < right.id.uuidString
            }
    }

    /// Returns `messages` in the order the worker should visit them for
    /// extraction. During backfill (`backfillCompleted == false`) the list is
    /// reversed so the newest messages are processed first. After backfill the
    /// original oldest→newest order is used for incremental updates.
    private func processingOrder(
        _ messages: [Message],
        backfillCompleted: Bool
    ) -> [Message] {
        backfillCompleted ? messages : messages.reversed()
    }

    /// Thread grouping key: the thread id, or the message's own id for a
    /// nil-thread message (a singleton group).
    static func groupKey(for message: Message) -> UUID {
        message.thread?.id ?? message.id
    }

    /// A thread group is stale when ANY member's stored discourse memory is
    /// missing / undecodable, at a different extraction version, or carries a
    /// fingerprint that does not match the group's current membership. A
    /// non-stale group is fast-skipped without an extraction (the fast-skip
    /// that replaces the old per-message version gate).
    private func isThreadGroupStale(members: [Message], fingerprint: String) -> Bool {
        for member in members {
            guard let memory = decodeDiscourseMemory(member.analysis?.discourseMemoryJSON) else {
                return true
            }
            if memory.extractionVersion != DiscourseMemory.threadVersion { return true }
            if memory.threadFingerprint != fingerprint { return true }
        }
        return false
    }

    /// Renders a thread group into a deterministic extraction packet. Per
    /// member: load the on-disk body (`bodyTextPath`), falling back to the
    /// analyzer's `bodySummary`; clean it (`OriginalMessageText.cleaned`,
    /// falling back to the raw string when cleaning collapses to nil), then
    /// strip any trailing quoted-history block. The packet builder clips and
    /// budget-elides, so no character limit is imposed here.
    private func buildThreadPacket(members: [Message], now: Date) -> ThreadExtractionPacket {
        let packetMessages = members.map { message -> ThreadPacketMessage in
            let rawBody: String
            if let path = message.bodyTextPath,
               let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                rawBody = contents
            } else {
                rawBody = message.analysis?.bodySummary ?? ""
            }
            let cleaned = OriginalMessageText.cleaned(from: rawBody, characterLimit: nil) ?? rawBody
            let body = QuotedHistoryTail.strippingTrailingQuotedBlock(from: cleaned)

            let recipients = message.participants.compactMap { link -> String? in
                guard let participant = link.participant else { return nil }
                switch link.role {
                case .to, .cc: return participant.emailAddress
                case .bcc, .from: return nil
                }
            }
            let attachmentNotes = message.attachments.map { attachment -> String in
                let type = attachment.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
                return type.isEmpty ? attachment.filename : "\(attachment.filename) (\(type))"
            }
            return ThreadPacketMessage(
                messageID: message.id,
                isSentByUser: message.isSentByUser,
                fromName: message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords),
                fromAddress: message.fromAddress,
                recipients: recipients,
                timestamp: message.vectorTimeFilterDate ?? .distantPast,
                attachmentNotes: attachmentNotes,
                bodyText: body
            )
        }
        return ThreadExtractionPacketBuilder.make(
            subject: threadSubject(members: members),
            messages: packetMessages,
            now: now
        )
    }

    /// Subject for the packet: the newest member's decoded subject (members
    /// arrive oldest→newest, so `.last` is newest).
    private func threadSubject(members: [Message]) -> String {
        guard let newest = members.last else { return "" }
        return MIMEHeaderDecoder.decodeEncodedWords(newest.subject)
    }

    /// The majority detected language across the group's members (nil when no
    /// member carries a detected language). Ties break lexicographically for
    /// determinism.
    private func majorityLanguage(members: [Message]) -> String? {
        var counts: [String: Int] = [:]
        for member in members {
            guard let raw = member.languageDetected?.trimmingCharacters(in: .whitespacesAndNewlines),
                  raw.isEmpty == false else { continue }
            counts[raw, default: 0] += 1
        }
        return counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.first?.key
    }

    /// Persists the outcome of a thread extraction across every group member.
    ///
    /// `returned == nil` (engine unloaded mid-run / parse failure /
    /// cancellation) leaves every member's JSON untouched so the group stays
    /// stale and retries on a later pass; the caller still consumes the budget
    /// and advances the cursor.
    ///
    /// On a non-nil result (including an empty dictionary): each member with a
    /// returned memory is merged against its deterministic seed; each member
    /// with none reuses its existing memory only when that memory is already a
    /// thread-era extraction, otherwise it falls back to a bare seed (a
    /// pre-ledger per-message-era memory is not grandfathered under the thread
    /// stamp). Every member is stamped with `threadVersion` + the group
    /// `fingerprint` so staleness
    /// converges — `DiscourseExtractor.merge` carries `refined.extractionVersion`
    /// but drops `threadFingerprint`, so both fields are set after merging.
    private func persistThreadGroup(
        members: [Message],
        returned: [UUID: DiscourseMemory]?,
        fingerprint: String,
        activeCustomCategoryKeys: Set<String>,
        context: ModelContext
    ) throws {
        guard let returned else { return }
        for member in members {
            let seedInput = makeSeedInput(
                message: member,
                activeCustomCategoryKeys: activeCustomCategoryKeys
            )
            var stamped: DiscourseMemory
            if let refined = returned[member.id] {
                if let seedInput {
                    stamped = DiscourseExtractor.merge(
                        seed: seedExtractor.seed(input: seedInput),
                        refined: refined
                    )
                } else {
                    stamped = refined
                }
            } else {
                // Reuse the member's stored memory ONLY when it is already a
                // thread-era extraction; a pre-ledger (per-message-era) memory is
                // dropped in favor of its bare seed so stale per-message claims
                // are not grandfathered under the thread stamp.
                let existing = decodeDiscourseMemory(member.analysis?.discourseMemoryJSON)
                if let existing, existing.extractionVersion == DiscourseMemory.threadVersion {
                    stamped = existing
                } else {
                    stamped = seedInput.map { seedExtractor.seed(input: $0) }
                        ?? DiscourseMemory(extractionVersion: DiscourseMemory.threadVersion)
                }
            }
            stamped.extractionVersion = DiscourseMemory.threadVersion
            stamped.threadFingerprint = fingerprint
            try persist(stamped, for: member, context: context)
        }
    }

    private func isAfterCursor(
        _ message: Message,
        state: AccountMemoryRefreshState
    ) -> Bool {
        guard let cursorDate = state.cursorDate else { return true }
        let date = message.vectorTimeFilterDate ?? .distantPast
        // During backfill the walk goes newest→oldest, so "after the cursor"
        // means OLDER than the cursor (i.e. not yet visited). After backfill
        // the walk is oldest→newest, so "after the cursor" means NEWER.
        let forward = state.backfillCompleted
        if date != cursorDate {
            return forward ? date > cursorDate : date < cursorDate
        }
        guard let cursorMessageID = state.cursorMessageID else { return true }
        return forward
            ? message.id.uuidString > cursorMessageID.uuidString
            : message.id.uuidString < cursorMessageID.uuidString
    }

    private func processedMessages(
        messages: [Message],
        state: AccountMemoryRefreshState
    ) -> [Message] {
        guard state.cursorDate != nil else { return [] }
        return messages.filter { isAfterCursor($0, state: state) == false }
    }

    private func advanceCursor(
        to message: Message,
        state: AccountMemoryRefreshState
    ) {
        state.cursorDate = message.vectorTimeFilterDate
        state.cursorMessageID = message.id
        state.cursorProcessedMessageCount += 1
        state.updatedAt = Date()
    }

    private func persist(
        _ memory: DiscourseMemory,
        for message: Message,
        context: ModelContext
    ) throws {
        guard let analysis = message.analysis else { return }
        let encoded = try memory.encodedJSON()
        if analysis.discourseMemoryJSON != encoded {
            analysis.discourseMemoryJSON = encoded
            try context.save()
        }
    }

    @discardableResult
    private func assembleProject(
        account: Account,
        messages: [Message],
        gateMessages: [Message],
        state: AccountMemoryRefreshState,
        counts: AccountMemoryMessageCounts,
        context: ModelContext,
        now: Date
    ) async throws -> MemoryProjectionOutcome {
        let curationActions = try activeCurationActions(context: context)
        let customCategories = CustomMailCategoryCatalog.activeDescriptors(in: context)
        let activeCustomCategoryKeys = Set(customCategories.map(\.key))
        var recordByMessageID: [UUID: ConversationMemoryRecord] = [:]
        var orderedRecords: [ConversationMemoryRecord] = []
        orderedRecords.reserveCapacity(messages.count)
        for message in messages {
            guard let seedInput = makeSeedInput(
                message: message,
                activeCustomCategoryKeys: activeCustomCategoryKeys
            ) else { continue }
            let decodedMemory = decodeDiscourseMemory(message.analysis?.discourseMemoryJSON)
            let memory = scrubTriageActionMemoryIfNeeded(
                decodedMemory ?? seedExtractor.seed(input: seedInput),
                for: message
            )
            guard let event = makeEvent(
                message: message,
                activeCustomCategoryKeys: activeCustomCategoryKeys
            ) else { continue }
            let record = ConversationMemoryRecord(
                event: event,
                memory: memory,
                dimensions: decodeDimensions(
                    message.analysis?.dimensionsJSON,
                    scrubTriageActionState: !message.isLiveInboundTriageEligible
                ),
                triageVerdict: message.isLiveInboundTriageEligible
                    ? decodeTriageVerdict(message.analysis?.triageVerdictJSON, isSentByUser: message.isSentByUser)
                    : nil,
                contentHash: message.contentHash,
                language: message.languageDetected
            )
            recordByMessageID[message.id] = record
            orderedRecords.append(record)
        }
        let readouts = Dictionary(uniqueKeysWithValues: messages.compactMap { message -> (UUID, AccountMemoryMessageReadout)? in
            guard let event = makeEvent(
                message: message,
                activeCustomCategoryKeys: activeCustomCategoryKeys
            ) else { return nil }
            return (message.id, AccountMemoryMessageReadout(
                messageID: message.id,
                subject: event.subject,
                senderAddress: message.fromAddress,
                senderName: message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords),
                timestamp: event.timestamp,
                summary: message.analysis?.bodySummary,
                threadID: message.thread?.id,
                isSentByUser: message.isSentByUser
            ))
        })

        // Fetch all AccountMemory rows for this account once. Each per-dossier
        // call slices this collection rather than re-querying. This turns the
        // previous O(dossiers × memories) fetch pattern into a single O(1) scan.
        // `#Predicate` cannot filter on computed properties, so we fetch by
        // accountID and narrow in-memory (consistent with the batch-fetch
        // pattern used throughout the codebase).
        let accountIDForFetch = account.id
        let allAccountMemories = try context.fetch(FetchDescriptor<AccountMemory>(
            predicate: #Predicate<AccountMemory> { $0.accountID == accountIDForFetch }
        ))

        // Build a lookup: "\(dimensionKind)\u{1F}\(resolvedDimensionValue)" → rows.
        // The separator is a Unicode INFORMATION SEPARATOR ONE (U+001F), which
        // cannot appear in normal dimension values and avoids collisions between
        // e.g. kind="account", value="foo" and kind="accountfoo", value="".
        //
        // PRECONDITION: each AccountMemoryDimensionTarget key is visited exactly
        // once across the account call + group loop below. The pre-fetched slices
        // are stale with respect to mutations made by a previous assembleAndProject
        // call within the same run. If a future refactor ever processes the same
        // dossier dimension twice, re-fetch allAccountMemories after each pass or
        // switch assembleAndProject back to a per-call fetch.
        var memoriesByDossierKey: [String: [AccountMemory]] = [:]
        for row in allAccountMemories {
            let key = "\(row.dimensionKind)\u{1F}\(row.resolvedDimensionValue)"
            memoriesByDossierKey[key, default: []].append(row)
        }

        // Returns (visible, hidden) slices for a given dimension target.
        func dossierSlices(for dimension: AccountMemoryDimensionTarget) -> (visible: [AccountMemory], hidden: [AccountMemory]) {
            let key = "\(dimension.kindRaw)\u{1F}\(dimension.value)"
            let rows = memoriesByDossierKey[key] ?? []
            let visible = rows.filter { !$0.isHiddenByDefault }
            let hidden  = rows.filter { $0.isHiddenByDefault }
            return (visible, hidden)
        }

        let (accountVisible, accountHidden) = dossierSlices(for: .account)
        let accountProjection = try await assembleAndProject(
            records: orderedRecords,
            dimension: .account,
            activeScope: [],
            account: account,
            readouts: readouts,
            curationActions: curationActions,
            dossierVisible: accountVisible,
            dossierHidden: accountHidden,
            state: state,
            context: context,
            now: now
        )
        var projected = accountProjection.projected
        if accountProjection.deferred {
            return accountProjection
        }

        let groups = await dimensionGroups(
            account: account,
            assemblyMessages: messages,
            gateMessages: gateMessages,
            customCategories: customCategories
        )
        for group in groups {
            // Dimension dossiers are incremental refinement — stop
            // cleanly under yield pressure; the next run re-projects.
            // The Task.yield keeps MainActor responsive between the
            // per-dossier distiller assemblies.
            await Task.yield()
            if shouldYield(context) {
                return MemoryProjectionOutcome(
                    projected: projected,
                    deferred: true,
                    deferralError: nil
                )
            }
            let groupRecords = group.messageIDs.compactMap { recordByMessageID[$0] }
            guard groupRecords.isEmpty == false else { continue }
            let (groupVisible, groupHidden) = dossierSlices(for: group.target)
            let groupProjection = try await assembleAndProject(
                records: groupRecords,
                dimension: group.target,
                activeScope: group.activeScope,
                account: account,
                readouts: readouts,
                curationActions: curationActions,
                dossierVisible: groupVisible,
                dossierHidden: groupHidden,
                state: state,
                context: context,
                now: now
            )
            projected += groupProjection.projected
            if groupProjection.deferred {
                return MemoryProjectionOutcome(
                    projected: projected,
                    deferred: true,
                    deferralError: groupProjection.deferralError
                )
            }
        }

        state.lastEligibleMessageCount = counts.eligibleMessages
        state.lastSentMessageCount = counts.sentMessages
        state.lastReceivedMessageCount = counts.receivedMessages
        state.updatedAt = now
        try context.save()
        accountMemoryLogger.info("projected account memories projected=\(projected, privacy: .public)")
        return MemoryProjectionOutcome(
            projected: projected,
            deferred: false,
            deferralError: nil
        )
    }

    struct MemoryDimensionGroup {
        let target: AccountMemoryDimensionTarget
        let messageIDs: [UUID]
        let activeScope: [ScopeHint]
    }

    /// Builds the correspondent / classification / project dossier groups for one
    /// account. Relationship gates are computed over `gateMessages` (the full
    /// eligible corpus) so a deferred run assembling a subset never
    /// under-counts a correspondent out of their dossier; group membership is
    /// then taken from `assemblyMessages`.
    func dimensionGroups(
        account: Account,
        assemblyMessages: [Message],
        gateMessages: [Message],
        customCategories: [CustomMailCategoryDescriptor] = []
    ) async -> [MemoryDimensionGroup] {
        let activeCustomCategoryKeys = Set(customCategories.map(\.key))
        var customCategoryNames: [String: String] = [:]
        for descriptor in customCategories {
            customCategoryNames[descriptor.key] = descriptor.displayName
        }
        let ownAddresses = Set(
            ([account.emailAddress] + account.identities.map(\.address))
                .map(Self.normalizedAddress)
                .filter { $0.isEmpty == false }
        )

        // Determine which counterparts have at least one authored message or
        // one substantive inbound message. Dossier creation has no volume
        // threshold: a single explicit standing instruction may be durable,
        // while the shared admission gate still rejects episodic mail.
        var qualifyingCorrespondents = Set<String>()
        for (index, message) in gateMessages.enumerated() {
            if index.isMultiple(of: 512), index > 0 { await Task.yield() }
            for address in counterpartAddresses(of: message, ownAddresses: ownAddresses) {
                if message.isSentByUser {
                    qualifyingCorrespondents.insert(address)
                } else if isBroadcastShaped(message) == false {
                    qualifyingCorrespondents.insert(address)
                }
            }
        }

        // --- Group membership over the assembly subset.
        var correspondentMessages: [String: [UUID]] = [:]
        var correspondentNames: [String: (name: String, timestamp: Date)] = [:]
        var classificationFacetMessages: [String: [UUID]] = [:]
        var tagMessages: [String: [UUID]] = [:]
        var tagLabels: [String: String] = [:]

        for (index, message) in assemblyMessages.enumerated() {
            // The per-message dimensions JSON decode makes this the heavy
            // scan; yield periodically so MainActor stays responsive.
            if index.isMultiple(of: 256), index > 0 { await Task.yield() }
            for address in counterpartAddresses(of: message, ownAddresses: ownAddresses)
            where qualifyingCorrespondents.contains(address) {
                correspondentMessages[address, default: []].append(message.id)
                if message.isSentByUser == false,
                   let name = message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords)?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   name.isEmpty == false {
                    let timestamp = message.vectorTimeFilterDate ?? .distantPast
                    if let existing = correspondentNames[address], existing.timestamp >= timestamp {
                        // keep the newer display name
                    } else {
                        correspondentNames[address] = (name, timestamp)
                    }
                }
            }

            for key in draftingMemoryFacets(
                for: message,
                knownCustomCategoryKeys: activeCustomCategoryKeys
            ).memoryKeys {
                classificationFacetMessages[key, default: []].append(message.id)
            }

            let dimensions = decodeDimensions(
                message.analysis?.dimensionsJSON,
                scrubTriageActionState: !message.isLiveInboundTriageEligible
            )
            for tag in SemanticTagProjectionPresentation.canonical(dimensions?.semanticTags ?? []) {
                let key = tag.tagID.uuidString.lowercased()
                tagMessages[key, default: []].append(message.id)
                if tagLabels[key] == nil {
                    tagLabels[key] = tag.displayName
                }
            }
        }

        var groups: [MemoryDimensionGroup] = []

        for (address, messageIDs) in correspondentMessages.sorted(by: { $0.key < $1.key }) {
            groups.append(MemoryDimensionGroup(
                target: AccountMemoryDimensionTarget(
                    kindRaw: AccountMemoryDimension.correspondent,
                    value: address,
                    displayName: correspondentNames[address]?.name ?? address
                ),
                messageIDs: messageIDs,
                activeScope: []
            ))
        }

        for (key, messageIDs) in classificationFacetMessages.sorted(by: { $0.key < $1.key }) {
            let displayName = customCategoryNames[key]
                ?? DraftingMemoryFacets.displayName(for: key)
            groups.append(MemoryDimensionGroup(
                target: AccountMemoryDimensionTarget(
                    kindRaw: AccountMemoryDimension.classification,
                    value: key,
                    displayName: displayName
                ),
                messageIDs: messageIDs,
                activeScope: [ScopeHint(kind: .classification, value: key)]
            ))
        }

        for (key, messageIDs) in tagMessages.sorted(by: { $0.key < $1.key }) {
            let displayLabel = tagLabels[key] ?? key
            groups.append(MemoryDimensionGroup(
                target: AccountMemoryDimensionTarget(
                    kindRaw: AccountMemoryDimension.project,
                    value: key,
                    displayName: displayLabel
                ),
                messageIDs: messageIDs,
                activeScope: [ScopeHint(kind: .semanticTag, value: displayLabel)]
            ))
        }

        return groups
    }

    /// The people on the other side of a message: the sender for received
    /// mail, the to/cc/bcc recipients for sent mail. The account's own
    /// addresses are never counterparts.
    private func counterpartAddresses(
        of message: Message,
        ownAddresses: Set<String>
    ) -> [String] {
        if message.isSentByUser {
            var seen = Set<String>()
            var addresses: [String] = []
            for link in message.participants {
                guard let participant = link.participant else { continue }
                switch link.role {
                case .to, .cc, .bcc:
                    let normalized = Self.normalizedAddress(participant.emailAddress)
                    guard normalized.isEmpty == false,
                          ownAddresses.contains(normalized) == false,
                          seen.insert(normalized).inserted else { continue }
                    addresses.append(normalized)
                case .from:
                    continue
                }
            }
            return addresses
        }
        let sender = Self.normalizedAddress(message.fromAddress)
        guard sender.isEmpty == false, ownAddresses.contains(sender) == false else {
            return []
        }
        return [sender]
    }

    /// Delivery is not a memory facet. Its only memory-policy role is keeping
    /// broadcast or automated inbound mail out of the two-way correspondent
    /// dossier gate.
    private func isBroadcastShaped(_ message: Message) -> Bool {
        draftingMemoryFacets(
            for: message,
            knownCustomCategoryKeys: []
        ).excludesCorrespondentMemory
    }

    static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Synthesizes one dossier via the LLM distiller. Builds candidate
    /// evidence clusters from the per-message records, asks the model to update
    /// the dossier against the memories already stored (those not hidden by
    /// curation, so user-rejected rows survive and are never re-shown), then
    /// applies the returned operations.
    ///
    /// `@MainActor`-isolated for ModelContext access; only the model
    /// generation hops off-main via `Task.detached`. Candidate evidence is sent
    /// in bounded calls, with current dossier rows re-fetched between calls so
    /// memory indices stay valid. A generation/prompt failure defers the refresh
    /// with an actionable error instead of falsely marking partial work complete.
    private func assembleAndProject(
        records: [ConversationMemoryRecord],
        dimension: AccountMemoryDimensionTarget,
        activeScope: [ScopeHint],
        account: Account,
        readouts: [UUID: AccountMemoryMessageReadout],
        curationActions: [ConversationCurationAction],
        /// Non-hidden rows for this dossier only (pre-fetched by the caller).
        dossierVisible: [AccountMemory],
        /// Hidden (curation-tombstoned) rows for this dossier (pre-fetched by caller).
        dossierHidden: [AccountMemory],
        state: AccountMemoryRefreshState,
        context: ModelContext,
        now: Date
    ) async throws -> MemoryProjectionOutcome {
        let clustersWithEdges = assembler.candidateClustersWithEdges(
            input: ConversationMemoryAssemblyInput(
                records: records,
                curationActions: curationActions,
                activeScope: activeScope,
                languageByMessage: Dictionary(uniqueKeysWithValues: records.map { ($0.event.messageID, $0.language) }),
                now: now
            )
        )
        let clusters = clustersWithEdges.clusters
        guard clusters.isEmpty == false else { return .noWork }

        let dossierKey = memoryDistillationDossierKey(dimension)
        let readingLanguage = SummarizationTargetLanguage.ohiaPreferred()
        var resumeProgress = memoryDistillationResumeProgress(state: state)
        var processedClaimKeys = Set(
            resumeProgress.processedClaimKeysByDossier[dossierKey] ?? []
        )
        var remainingClusters = clusters.filter {
            processedClaimKeys.contains($0.claim.key) == false
        }
        var currentVisible = stableMemoryOrder(dossierVisible)
        var currentHidden = dossierHidden
        var projected = 0
        var appliedAnyOperations = resumeProgress.appliedDossierKeys.contains(dossierKey)

        while remainingClusters.isEmpty == false {
            await Task.yield()
            if shouldYield(context) {
                return MemoryProjectionOutcome(
                    projected: projected,
                    deferred: true,
                    deferralError: nil
                )
            }

            let batch: MemoryDistiller.PromptBatch
            do {
                guard let nextBatch = try MemoryDistiller.buildNextPromptBatch(
                    dimension: dimension,
                    existing: currentVisible,
                    clusters: remainingClusters,
                    outputLanguage: readingLanguage
                ) else { return .noWork }
                batch = nextBatch
            } catch let error as MemoryDistiller.PromptBatchingError {
                let message = error.localizedDescription
                accountMemoryLogger.error(
                    "memory distill prompt rejected dimension=\(dimension.kindRaw, privacy: .public) errorKind=\(String(reflecting: type(of: error)), privacy: .public)"
                )
                return MemoryProjectionOutcome(
                    projected: projected,
                    deferred: true,
                    deferralError: message
                )
            }

            let generation: (raw: String?, yielded: Bool)
            do {
                generation = try await generateMemoryDistillation(
                    prompt: batch.prompt,
                    context: context
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let message = error.localizedDescription
                accountMemoryLogger.error(
                    "memory distill generation failed dimension=\(dimension.kindRaw, privacy: .public) errorKind=\(String(reflecting: type(of: error)), privacy: .public)"
                )
                return MemoryProjectionOutcome(
                    projected: projected,
                    deferred: true,
                    deferralError: message
                )
            }
            if generation.yielded || shouldYield(context) {
                return MemoryProjectionOutcome(
                    projected: projected,
                    deferred: true,
                    deferralError: nil
                )
            }

            if let raw = generation.raw {
                let ops = await MemoryDistiller.displayingLanguage(
                    MemoryDistiller.parseOperations(raw),
                    clusters: batch.clusters,
                    using: DisplayLanguageGuard(container: context.container, engine: engine),
                    targetLanguage: readingLanguage,
                    source: DisplayLanguageGuard.Source(
                        languageHint: nil,
                        context: String(batch.clusters.map(\.text).joined(separator: "\n").prefix(1_200)),
                        messageID: nil,
                        accountID: account.id
                    )
                )
                if ops.isEmpty == false {
                    let before = existingMemoryCount(accountID: account.id, context: context)
                    try MemoryDistiller.apply(
                        ops: ops,
                        clusters: batch.clusters,
                        existing: batch.existing,
                        accountID: account.id,
                        dimension: dimension,
                        modelContext: context,
                        messageReadouts: readouts,
                        visibleRows: currentVisible,
                        hiddenRows: currentHidden,
                        contradictionStateByClaimKey: clustersWithEdges.contradictionStateByClaimKey,
                        supersessionEdges: clustersWithEdges.supersessionEdges,
                        embedder: memoryEmbedder,
                        saveChanges: false,
                        now: now
                    )
                    let after = existingMemoryCount(accountID: account.id, context: context)
                    projected += max(
                        0,
                        min(ops.count, abs(after - before) + mutatingOpCount(ops))
                    )
                    appliedAnyOperations = true
                }
            }

            processedClaimKeys.formUnion(batch.clusters.map(\.claim.key))
            resumeProgress.processedClaimKeysByDossier[dossierKey] = processedClaimKeys.sorted()
            if appliedAnyOperations,
               resumeProgress.appliedDossierKeys.contains(dossierKey) == false {
                resumeProgress.appliedDossierKeys.append(dossierKey)
                resumeProgress.appliedDossierKeys.sort()
            }
            state.distillationResumeJSON = try encodeMemoryDistillationResumeProgress(
                resumeProgress
            )
            // `MemoryDistiller.apply(saveChanges: false)` leaves its mutations
            // in this context so the row updates and completed-cluster marker
            // commit atomically. A crash can therefore replay neither alone.
            try context.save()

            remainingClusters.removeFirst(batch.clusters.count)
            if remainingClusters.isEmpty == false {
                let slices = try currentDossierSlices(
                    accountID: account.id,
                    dimension: dimension,
                    context: context
                )
                currentVisible = slices.visible
                currentHidden = slices.hidden
            }
        }

        if appliedAnyOperations {
            // Prune old-version rows only after every bounded candidate batch
            // completes. If activity interrupts the sequence, the refresh stays
            // deferred and a later idle pass safely replays from durable rows.
            try MemoryDistiller.supersedeStaleVersionRows(
                accountID: account.id,
                dimension: dimension,
                modelContext: context,
                now: now
            )
        }
        return MemoryProjectionOutcome(
            projected: projected,
            deferred: false,
            deferralError: nil
        )
    }

    private func generateMemoryDistillation(
        prompt: PrefixCachedPrompt,
        context: ModelContext
    ) async throws -> (raw: String?, yielded: Bool) {
        let yieldCancellation = AccountMemoryExtractionCancellation()
        let generationCancellation = GenerationCancellation()
        let engineRef = engine
        let generationTask = Task.detached(priority: pacing.generationTaskPriority) {
            try PrefixCachedGeneration.generate(
                engine: engineRef,
                prompt: prompt,
                maxTokens: 700,
                cancellation: generationCancellation
            )
        }
        let monitorTask = Task { @MainActor in
            while Task.isCancelled == false {
                if shouldYield(context) {
                    await yieldCancellation.markYieldCancellation()
                    generationCancellation.cancel()
                    generationTask.cancel()
                    return
                }
                await Task.yield()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        return try await withTaskCancellationHandler {
            defer { monitorTask.cancel() }
            do {
                let raw = try await generationTask.value
                return (raw, await yieldCancellation.wasCancelledForYield())
            } catch is CancellationError {
                if await yieldCancellation.wasCancelledForYield() {
                    return (nil, true)
                }
                throw CancellationError()
            }
        } onCancel: {
            generationCancellation.cancel()
            generationTask.cancel()
            monitorTask.cancel()
        }
    }

    private func currentDossierSlices(
        accountID: UUID,
        dimension: AccountMemoryDimensionTarget,
        context: ModelContext
    ) throws -> (visible: [AccountMemory], hidden: [AccountMemory]) {
        let rows = try context.fetch(FetchDescriptor<AccountMemory>(
            predicate: #Predicate<AccountMemory> { $0.accountID == accountID }
        )).filter {
            $0.dimensionKind == dimension.kindRaw
                && $0.resolvedDimensionValue == dimension.value
        }
        return (
            stableMemoryOrder(rows.filter { $0.isHiddenByDefault == false }),
            stableMemoryOrder(rows.filter(\.isHiddenByDefault))
        )
    }

    private func memoryDistillationDossierKey(
        _ dimension: AccountMemoryDimensionTarget
    ) -> String {
        "\(dimension.kindRaw)\u{1F}\(dimension.value)"
    }

    private func memoryDistillationResumeProgress(
        state: AccountMemoryRefreshState
    ) -> MemoryDistillationResumeProgress {
        guard let json = state.distillationResumeJSON,
              let data = json.data(using: .utf8),
              let progress = try? JSONDecoder().decode(
                  MemoryDistillationResumeProgress.self,
                  from: data
              ) else {
            return .empty
        }
        return progress
    }

    private func encodeMemoryDistillationResumeProgress(
        _ progress: MemoryDistillationResumeProgress
    ) throws -> String {
        String(decoding: try JSONEncoder().encode(progress), as: UTF8.self)
    }

    private func stableMemoryOrder(_ memories: [AccountMemory]) -> [AccountMemory] {
        memories.sorted { left, right in
            if left.memoryKey != right.memoryKey {
                return left.memoryKey < right.memoryKey
            }
            return left.id.uuidString < right.id.uuidString
        }
    }

    private func existingMemoryCount(accountID: UUID, context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<AccountMemory>(
            predicate: #Predicate<AccountMemory> { memory in
                memory.accountID == accountID
            }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Ops that mutate an existing row in place (reinforce / weaken) without
    /// changing the row count — used so the projected total reflects them.
    private func mutatingOpCount(_ ops: [MemoryDistiller.Operation]) -> Int {
        ops.filter { $0.op == "reinforce" || $0.op == "weaken" }.count
    }

    private func activeCurationActions(context: ModelContext) throws -> [ConversationCurationAction] {
        try context.fetch(FetchDescriptor<ConversationCurationAction>())
            .filter(\.isActive)
    }

    private func makeSeedInput(
        message: Message,
        activeCustomCategoryKeys: Set<String> = []
    ) -> SeedFromMetadata.SeedInput? {
        let classificationLabels = draftingMemoryFacets(
            for: message,
            knownCustomCategoryKeys: activeCustomCategoryKeys
        ).memoryKeys
        let dimensions = decodeDimensions(
            message.analysis?.dimensionsJSON,
            scrubTriageActionState: !message.isLiveInboundTriageEligible
        )
        let triage = message.isLiveInboundTriageEligible
            ? decodeTriageVerdict(message.analysis?.triageVerdictJSON, isSentByUser: message.isSentByUser)
            : nil
        let tags = SemanticTagProjectionPresentation.canonical(dimensions?.semanticTags ?? []).map(\.displayName)
        return SeedFromMetadata.SeedInput(
            messageID: message.id,
            isSentByUser: message.isSentByUser,
            fromAddress: message.fromAddress,
            classificationHints: classificationLabels,
            semanticTagLabels: tags,
            bodySummary: message.analysis?.bodySummary,
            dimensions: dimensions,
            triageVerdict: triage
        )
    }

    private func makeEvent(
        message: Message,
        activeCustomCategoryKeys: Set<String>
    ) -> ConversationEvent? {
        guard let timestamp = message.vectorTimeFilterDate else { return nil }
        let recipients = message.participants.compactMap { link -> String? in
            guard let participant = link.participant else { return nil }
            switch link.role {
            case .to, .cc, .bcc: return participant.emailAddress
            case .from: return nil
            }
        }
        let classificationHints = draftingMemoryFacets(
            for: message,
            knownCustomCategoryKeys: activeCustomCategoryKeys
        ).memoryKeys
        return ConversationEvent(
            messageID: message.id,
            threadID: message.thread?.id,
            isSentByUser: message.isSentByUser,
            fromAddress: message.fromAddress,
            recipients: recipients,
            subject: MIMEHeaderDecoder.decodeEncodedWords(message.subject),
            timestamp: timestamp,
            classificationHints: classificationHints,
            summary: message.analysis?.bodySummary,
            vectorRowID: nil,
            attachmentCount: message.attachments.count
        )
    }

    private func decodeTriageVerdict(
        _ json: String?,
        isSentByUser: Bool
    ) -> TriageVerdict? {
        guard let json,
              let data = json.data(using: .utf8),
              let verdict = try? JSONDecoder().decode(TriageVerdict.self, from: data) else {
            return nil
        }
        return verdict.normalizingActionability(isSentByUser: isSentByUser)
    }

    private func decodeDimensions(
        _ json: String?,
        scrubTriageActionState: Bool = false
    ) -> MessageDimensions? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        guard let dimensions = try? JSONDecoder().decode(MessageDimensions.self, from: data) else {
            return nil
        }
        return scrubTriageActionState ? dimensions.scrubbingTriageActionState() : dimensions
    }

    private func decodeDiscourseMemory(_ json: String?) -> DiscourseMemory? {
        guard let json,
              json.utf8.count <= maximumStoredDiscourseMemoryJSONBytes,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(DiscourseMemory.self, from: data)
    }

    private func scrubTriageActionMemoryIfNeeded(
        _ memory: DiscourseMemory,
        for message: Message
    ) -> DiscourseMemory {
        guard !message.isLiveInboundTriageEligible else { return memory }
        var scrubbed = memory
        scrubbed.ibisRoles.removeAll { $0.role == .constraint }
        return scrubbed
    }
}
