import Foundation
import SwiftData
import OhiaCore

/// Selects the dreamed `AccountMemory` rows that apply to a draft reply and
/// shapes them into prompt-ready `MemoryNote`s.
///
/// Matching is dimension-driven, mirroring how the dossiers were built:
/// the correspondent dossier of the incoming sender, the classification dossiers
/// of the message's classification facets, the project dossiers of its semantic
/// project labels, and the account-wide dossier. Within each dimension the
/// strongest memories win (affirmed before inferred, then weight), with a
/// global cap and cross-dimension dedupe so the prompt stays small even when
/// the same knowledge was dreamed into several dossiers.
public enum AccountMemoryDraftSelector {
    public struct Limits: Sendable, Equatable {
        public var maxCorrespondentNotes: Int
        public var maxClassificationNotes: Int
        public var maxProjectNotes: Int
        public var maxAccountNotes: Int
        public var maxTotalNotes: Int
        public var maxCharacters: Int

        public init(
            maxCorrespondentNotes: Int = 3,
            maxClassificationNotes: Int = 2,
            maxProjectNotes: Int = 2,
            maxAccountNotes: Int = 2,
            maxTotalNotes: Int = 8,
            maxCharacters: Int = 1_600
        ) {
            self.maxCorrespondentNotes = maxCorrespondentNotes
            self.maxClassificationNotes = maxClassificationNotes
            self.maxProjectNotes = maxProjectNotes
            self.maxAccountNotes = maxAccountNotes
            self.maxTotalNotes = maxTotalNotes
            self.maxCharacters = maxCharacters
        }

        public static let `default` = Limits()
    }

    @MainActor
    public static func memoryNotes(
        for message: Message,
        context: ModelContext,
        limits: Limits = .default,
        now: Date = Date(),
        embedder: (any EmbeddingProvider)? = nil
    ) -> [MemoryNote] {
        guard let accountID = message.accountID ?? message.account?.id else { return [] }
        let memories = fetchMemories(accountID: accountID, context: context)
        guard memories.isEmpty == false else { return [] }

        let senderAddress = message.fromAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let knownCustomCategoryKeys = CustomMailCategoryCatalog.allKeys(in: context)
        let classificationValues = Set(draftingMemoryFacets(
            for: message,
            knownCustomCategoryKeys: knownCustomCategoryKeys
        ).memoryKeys)
        let projectKeys = Set(projectKeys(of: message))
        let relevanceTerms = ComposerSourceRelevance.relevanceTerms(
            for: message,
            knownCustomCategoryKeys: knownCustomCategoryKeys
        )
        let ignoredTerms = accountIdentityTerms(accountID: accountID, message: message, context: context)

        let selection = SelectionContext(
            correspondentAddress: senderAddress,
            classificationValues: classificationValues,
            projectKeys: projectKeys,
            relevanceTerms: relevanceTerms,
            ignoredTerms: ignoredTerms,
            contextText: replyContextText(for: message)
        )
        return selectNotes(selection, memories: memories, limits: limits, now: now, embedder: embedder)
    }

    /// Compose variant: a brand-new outbound email has no incoming message,
    /// so there are no classification or project dimensions to match — only the
    /// recipient's correspondent dossier and the account-wide dossier apply.
    /// Mirrors `memoryNotes(for:)`'s promptable filter, ranking, dedupe, and
    /// global caps so the compose lane injects memory the same way the reply
    /// lane does.
    @MainActor
    public static func memoryNotesForCompose(
        accountID: UUID?,
        recipientAddress: String,
        context: ModelContext,
        limits: Limits = .default,
        now: Date = Date(),
        embedder: (any EmbeddingProvider)? = nil
    ) -> [MemoryNote] {
        guard let accountID else { return [] }
        let memories = fetchMemories(accountID: accountID, context: context)
        guard memories.isEmpty == false else { return [] }

        let recipient = recipientAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let relevanceTerms = ComposerSourceRelevance.tokens(recipientAddress, maxTokens: 40)
        let ignoredTerms = accountIdentityTerms(accountID: accountID, message: nil, context: context)

        // A brand-new outbound email has no incoming message, so there are no
        // classification or project dimensions to match — only the recipient's
        // correspondent dossier and the account-wide dossier apply. The shared
        // core runs the empty classification/project buckets as no-ops.
        let selection = SelectionContext(
            correspondentAddress: recipient,
            classificationValues: [],
            projectKeys: [],
            relevanceTerms: relevanceTerms,
            ignoredTerms: ignoredTerms,
            contextText: composeContextText(recipient: recipient, accountID: accountID, context: context)
        )
        return selectNotes(selection, memories: memories, limits: limits, now: now, embedder: embedder)
    }

    // MARK: - Shared selection core

    /// Draft-context inputs the reply and compose lanes resolve differently but
    /// the selection core consumes identically.
    private struct SelectionContext {
        let correspondentAddress: String
        let classificationValues: Set<String>
        let projectKeys: Set<String>
        let relevanceTerms: Set<String>
        let ignoredTerms: Set<String>
        /// Text embedded once per call to rank memories by semantic relevance.
        let contextText: String
    }

    /// Account-dimension memories clear a higher bar than dossier-scoped rows:
    /// broad same-account knowledge must not ride along on account match alone.
    private static let accountRelevanceFloor: Float = 0.30

    @MainActor
    private static func selectNotes(
        _ selection: SelectionContext,
        memories: [AccountMemory],
        limits: Limits,
        now: Date,
        embedder: (any EmbeddingProvider)?
    ) -> [MemoryNote] {
        // Contract-level admission is fail closed: legacy, incomplete,
        // contested, superseded, and review-only rows never enter a model
        // prompt. Scope composition below applies independently.
        let promptable = memories.filter { memory in
            memory.isDurablePromptEligible
                && memory.isSensitiveAndUnaffirmed == false
                && isPromptableByRecency(memory, now: now)
                && memory.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && memory.isExpired(now: now) == false
                && scopeCompatible(memory, selection: selection)
        }

        // One context embedding per call, computed lazily on first need. A nil
        // value (no embedder, or the context could not be embedded) forces the
        // keyword-rank fallback for every bucket.
        var contextVectorComputed = false
        var contextVectorValue: [Float]?
        func contextVector() -> [Float]? {
            if contextVectorComputed { return contextVectorValue }
            contextVectorComputed = true
            contextVectorValue = embedder?.embed(selection.contextText)
            return contextVectorValue
        }

        // Relevance is nil when the memory has no version-matching stored vector,
        // there is no embedder, or the context itself could not be embedded.
        func relevance(of memory: AccountMemory) -> Float? {
            guard let embedder,
                  let blob = memory.embeddingBlob,
                  memory.memoryEmbeddingVersion == embedder.embeddingVersion,
                  let context = contextVector() else { return nil }
            let stored = AccountMemoryEmbeddingCodec.decode(blob)
            guard stored.isEmpty == false, stored.count == context.count else { return nil }
            return VectorStore.cosineSimilarity(context, stored)
        }

        func score(of memory: AccountMemory, relevance: Float) -> Double {
            let statusMultiplier: Double
            switch memory.statusRaw {
            case AccountMemoryProjectedStatus.confirmed: statusMultiplier = 1.25
            default: statusMultiplier = 1.0
            }
            let originMultiplier = memory.resolvedOrigin == AccountMemoryOrigin.explicit ? 1.15 : 1.0
            let weightBlend = 0.5 + min(1, max(0, liveWeight(memory, now: now))) / 2
            return (0.5 + Double(relevance)) * statusMultiplier * originMultiplier * weightBlend
        }

        // Dimension priority: the person beats the project beats the classification
        // beats the account when the same knowledge appears twice.
        var selected: [MemoryNote] = []
        var seenTexts = Set<String>()

        func take(
            matching: (AccountMemory) -> Bool,
            admit: (AccountMemory, Float?) -> Bool = { _, _ in true },
            cap: Int
        ) {
            let candidates = promptable.filter(matching)
            var scored: [(memory: AccountMemory, score: Double)] = []
            var unscored: [AccountMemory] = []
            for memory in candidates {
                let rel = relevance(of: memory)
                guard admit(memory, rel) else { continue }
                if let rel {
                    scored.append((memory, score(of: memory, relevance: rel)))
                } else {
                    unscored.append(memory)
                }
            }
            // Embedding-scored memories rank by relevance-blended score; those
            // without a usable vector fall back to the decay/status ordering and
            // sit after every scored memory in the bucket. Exact score ties break
            // on the same decay/status ordering so selection stays deterministic
            // (Swift's sort is not stable).
            scored.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return rankedHigher(lhs.memory, rhs.memory, now: now)
            }
            unscored.sort { rankedHigher($0, $1, now: now) }
            let ordered = scored.map(\.memory) + unscored
            for memory in ordered.prefix(cap) {
                let normalized = memory.normalizedText
                guard seenTexts.insert(normalized).inserted else { continue }
                selected.append(note(from: memory))
            }
        }

        take(
            matching: { correspondentMatch($0, address: selection.correspondentAddress) },
            cap: limits.maxCorrespondentNotes
        )
        take(
            matching: { projectMatch($0, keys: selection.projectKeys) },
            cap: limits.maxProjectNotes
        )
        take(
            matching: { classificationMatch($0, values: selection.classificationValues) },
            cap: limits.maxClassificationNotes
        )
        take(
            matching: { $0.dimensionKind == AccountMemoryDimension.account },
            admit: { memory, rel in
                // With a usable embedding, clear the relevance floor; otherwise
                // fall back to the raised (≥3-token) keyword overlap bar.
                if embedder != nil, let rel { return rel >= accountRelevanceFloor }
                return accountMemoryMatchesContext(
                    memory,
                    relevanceTerms: selection.relevanceTerms,
                    ignoredTerms: selection.ignoredTerms
                )
            },
            cap: limits.maxAccountNotes
        )

        // Global caps: count, then characters.
        var notes: [MemoryNote] = []
        var remaining = limits.maxCharacters
        for note in selected.prefix(limits.maxTotalNotes) {
            let cost = note.text.count + note.dimensionLabel.count + 8
            guard cost <= remaining else { continue }
            notes.append(note)
            remaining -= cost
        }
        return notes
    }

    @MainActor
    private static func fetchMemories(accountID: UUID, context: ModelContext) -> [AccountMemory] {
        do {
            return try context.fetch(FetchDescriptor<AccountMemory>(
                predicate: #Predicate<AccountMemory> { memory in
                    memory.accountID == accountID
                }
            ))
        } catch {
            return []
        }
    }

    private static func note(from memory: AccountMemory) -> MemoryNote {
        let contradiction = memory.contradictionStateRaw == "clean" ? nil : memory.contradictionStateRaw
        return MemoryNote(
            dimensionLabel: dimensionLabel(for: memory),
            text: memory.displayText,
            status: memory.statusRaw,
            weight: memory.weight,
            originRaw: memory.resolvedOrigin,
            assertedBy: memory.assertedByAddress,
            asOf: memory.asOf,
            expiresAt: memory.expiresAt,
            kindRaw: memory.targetKindRaw,
            conditionsText: memory.conditionsText,
            formationBasisRaw: memory.formationBasisRaw,
            usePolicyRaw: memory.usePolicyRaw,
            futureUseText: memory.futureUseText,
            contradictionRaw: contradiction
        )
    }

    // MARK: - Scope-composed bucket matching

    /// Primary dossier matching never substitutes for explicit scope. A
    /// project memory scoped to a person must match both the project and person;
    /// the person alone cannot pull it into the correspondent bucket.
    private static func correspondentMatch(_ memory: AccountMemory, address: String) -> Bool {
        guard address.isEmpty == false else { return false }
        return memory.dimensionKind == AccountMemoryDimension.correspondent
            && normalizedAddress(memory.resolvedDimensionValue) == address
    }

    private static func projectMatch(_ memory: AccountMemory, keys: Set<String>) -> Bool {
        guard keys.isEmpty == false else { return false }
        return memory.dimensionKind == AccountMemoryDimension.project
            && keys.contains(ProjectKeyNormalizer.canonicalKey(memory.resolvedDimensionValue))
    }

    private static func classificationMatch(_ memory: AccountMemory, values: Set<String>) -> Bool {
        guard values.isEmpty == false else { return false }
        return memory.dimensionKind == AccountMemoryDimension.classification
            && values.contains(memory.resolvedDimensionValue)
    }

    /// Every explicit scope constraint must match the draft context. Unknown or
    /// unsupported scope kinds fail closed rather than broadening applicability.
    private static func scopeCompatible(_ memory: AccountMemory, selection: SelectionContext) -> Bool {
        memory.decodedScope().allSatisfy { reference in
            let value = reference.value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch reference.kindRaw {
            case AccountMemoryDimension.account:
                return true
            case AccountMemoryDimension.correspondent:
                return selection.correspondentAddress.isEmpty == false
                    && normalizedAddress(value) == selection.correspondentAddress
            case AccountMemoryDimension.project:
                return selection.projectKeys.contains(ProjectKeyNormalizer.canonicalKey(value))
            case AccountMemoryDimension.classification:
                return selection.classificationValues.contains(value)
            default:
                return false
            }
        }
    }

    private static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Reply context: the incoming subject plus the head of its body summary.
    @MainActor
    private static func replyContextText(for message: Message) -> String {
        let summary = String((message.analysis?.bodySummary ?? "").prefix(500))
        return [message.subject, summary]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }

    /// Compose context: the recipient address plus the sending account's display
    /// name (a new outbound email carries no incoming body to anchor on).
    @MainActor
    private static func composeContextText(
        recipient: String,
        accountID: UUID,
        context: ModelContext
    ) -> String {
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { account in
                account.id == accountID
            }
        )
        descriptor.fetchLimit = 1
        let displayName = (try? context.fetch(descriptor))?.first?.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [recipient, displayName]
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }

    private static func rankedHigher(_ left: AccountMemory, _ right: AccountMemory, now: Date) -> Bool {
        let leftRank = statusRank(left)
        let rightRank = statusRank(right)
        if leftRank != rightRank { return leftRank < rightRank }
        let leftWeight = liveWeight(left, now: now)
        let rightWeight = liveWeight(right, now: now)
        if leftWeight != rightWeight { return leftWeight > rightWeight }
        return left.lastSeenAt > right.lastSeenAt
    }

    /// Confirmed user-curated guidance outranks active generated guidance.
    private static func statusRank(_ memory: AccountMemory) -> Int {
        memory.statusRaw == AccountMemoryProjectedStatus.confirmed ? 0 : 1
    }

    /// Live weight after recency decay. Confirmed rows are user-verified durable
    /// guidance and never decay; an active row loses weight on the
    /// 90-day half-life so a months-stale fact no longer grounds a draft at full
    /// strength. Mirrors how Settings → Memories already ages the same rows.
    private static func liveWeight(_ memory: AccountMemory, now: Date) -> Double {
        guard memory.statusRaw != AccountMemoryProjectedStatus.confirmed else { return memory.weight }
        return memory.weight * AccountMemoryDecay.factor(lastSeenAt: memory.lastSeenAt, now: now)
    }

    /// A long-unconfirmed memory is too stale to ground a new draft; confirmed
    /// rows are always promptable.
    private static func isPromptableByRecency(_ memory: AccountMemory, now: Date) -> Bool {
        memory.statusRaw == AccountMemoryProjectedStatus.confirmed
            || AccountMemoryDecay.isStale(lastSeenAt: memory.lastSeenAt, now: now) == false
    }

    @MainActor
    private static func accountMemoryMatchesContext(
        _ memory: AccountMemory,
        relevanceTerms: Set<String>,
        ignoredTerms: Set<String> = []
    ) -> Bool {
        guard relevanceTerms.isEmpty == false else { return false }
        let ignored = Set(ignoredTerms.filter(isSubstantiveContextToken))
        let contextTerms = Set(relevanceTerms.filter(isSubstantiveContextToken))
            .subtracting(ignored)
        guard contextTerms.isEmpty == false else { return false }

        var memoryTerms = ComposerSourceRelevance.tokens(memory.displayText, maxTokens: 96)
        memoryTerms.formUnion(ComposerSourceRelevance.tokens(memory.resolvedDimensionDisplayName, maxTokens: 24))
        memoryTerms.formUnion(ComposerSourceRelevance.tokens(memory.resolvedDimensionValue, maxTokens: 24))
        memoryTerms = Set(memoryTerms.filter(isSubstantiveContextToken))
            .subtracting(ignored)
        let overlap = memoryTerms.intersection(contextTerms)
        // Account-wide knowledge (no dossier value to gate on) needs a stronger
        // keyword signal than a dossier-scoped row: three overlapping tokens,
        // not two, so broad same-account notes do not ride along on a weak match.
        return overlap.count >= 3
    }

    @MainActor
    private static func accountIdentityTerms(
        accountID: UUID,
        message: Message?,
        context: ModelContext
    ) -> Set<String> {
        let account: Account?
        if let messageAccount = message?.account, messageAccount.id == accountID {
            account = messageAccount
        } else {
            var descriptor = FetchDescriptor<Account>(
                predicate: #Predicate<Account> { account in
                    account.id == accountID
                }
            )
            descriptor.fetchLimit = 1
            account = try? context.fetch(descriptor).first
        }

        guard let account else { return [] }
        var parts = [
            account.displayName,
            account.emailAddress
        ]
        for identity in account.identities {
            parts.append(identity.displayName ?? "")
            parts.append(identity.address)
            parts.append(identity.replyTo ?? "")
        }
        return Set(
            ComposerSourceRelevance
                .tokens(parts.joined(separator: "\n"), maxTokens: 96)
                .filter(isSubstantiveContextToken)
        )
    }

    private static func isSubstantiveContextToken(_ token: String) -> Bool {
        token.count >= 4 || token.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    private static func dimensionLabel(for memory: AccountMemory) -> String {
        switch memory.dimensionKind {
        case AccountMemoryDimension.correspondent:
            return "Person — \(memory.resolvedDimensionDisplayName)"
        case AccountMemoryDimension.classification:
            return "Classification — \(memory.resolvedDimensionDisplayName)"
        case AccountMemoryDimension.project:
            return "Project — \(memory.resolvedDimensionDisplayName)"
        default:
            return "Account"
        }
    }

    @MainActor
    private static func projectKeys(of message: Message) -> [String] {
        Array(ComposerSourceRelevance.semanticAffinityKeys(of: message).tags)
    }
}
