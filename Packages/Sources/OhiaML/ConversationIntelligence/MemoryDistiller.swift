import Foundation
import SwiftData
import OhiaCore

/// LLM synthesis pass that consolidates clustered per-message claims into a
/// specific, evidence-grounded account-memory ledger. Mirrors
/// `DraftingRuleDistiller`: shown the existing memories on a dossier plus new
/// candidate claim clusters, it returns add / reinforce / weaken / delete /
/// split operations over the `AccountMemory` store. Output text preserves the
/// concrete values, names, dates, amounts, and conditions of the underlying
/// claim — it is never a biographical activity summary. The account dimension
/// simply receives claims whose scope is not a single person, project, or
/// classification; nothing is de-specified to fit a dossier.
public enum MemoryDistiller {

    /// Hard ceiling for the per-call, uncached suffix passed to Qwen by the
    /// background memory distiller. The static instruction prefix is cached;
    /// this suffix contains the dossier identity, bounded existing-memory
    /// context, candidate evidence, and the `JSON:` response cue. Keep this
    /// small because cancellation cannot interrupt a single prompt prefill.
    public static let maximumPromptSuffixCharacters = 4_000

    /// Existing rows are context rather than newly mined evidence. Keep a
    /// small, stable slice in each prompt and explicitly abbreviate pathological
    /// user-edited text so it cannot consume the whole candidate budget.
    private static let maximumExistingMemoriesPerPrompt = 16
    private static let maximumExistingMemoryTextCharacters = 512

    public enum PromptBatchingError: Error, Equatable, Sendable {
        case candidateExceedsPromptLimit(index: Int, renderedCharacters: Int, limit: Int)
    }

    public struct PromptBatch {
        public let prompt: PrefixCachedPrompt
        /// Exact rows rendered into this prompt, in the order used by the
        /// model's one-based `memory` indices.
        public let existing: [AccountMemory]
        /// Exact candidate objects rendered into this prompt. Candidate text
        /// is never truncated; each input candidate belongs to one batch.
        public let clusters: [CandidateCluster]

        public init(
            prompt: PrefixCachedPrompt,
            existing: [AccountMemory],
            clusters: [CandidateCluster]
        ) {
            self.prompt = prompt
            self.existing = existing
            self.clusters = clusters
        }
    }

    /// Durable-guidance consolidation contract. Persisted rows use
    /// `AccountMemoryContract.currentVersion`; this version identifies the
    /// model operation schema and invalidates prior claim-ledger output.
    public static let distillVersion = "durable-memory-distill-v4"

    /// Cosine-similarity floor for the embedding-backed dedup backstop on
    /// `apply`'s add / split-insert paths: a candidate whose vector cosines
    /// at or above this against an already-embedded dossier row is treated
    /// as a semantic twin of that row (reinforce, not insert) even when the
    /// normalized-text lexical check misses it (paraphrase, word order,
    /// synonym substitution).
    public static let dedupCosineThreshold: Float = 0.92

    public struct Operation: Decodable, Equatable, Sendable {
        public let op: String            // add | reinforce | weaken | delete | split
        public let memory: Int?          // reinforce/weaken/delete/split target (1-based)
        public let text: String?         // add
        public let kind: String?         // add/split parts — ten-kind taxonomy
        public let from: [Int]?          // add AND reinforce: source cluster indices
        public let subject: String?
        public let assertedBy: String?   // "user" | address | "shared"
        public let direction: String?    // sent | received | mixed
        public let origin: String?       // explicit | inferred
        public let asOf: String?         // yyyy-MM-dd
        public let expires: String?
        public let conditions: String?
        public let futureUse: String?
        public let formationBasis: String?
        public let usePolicy: String?
        public let scopes: [ScopePair]?  // {"kind":"project","value":"<key>"}
        public let into: [SplitPart]?    // split replacement parts

        public struct ScopePair: Decodable, Equatable, Sendable {
            public let kind: String
            public let value: String
            public init(kind: String, value: String) {
                self.kind = kind
                self.value = value
            }
        }

        public struct SplitPart: Decodable, Equatable, Sendable {
            public let text: String
            public let kind: String?
            public let from: [Int]?
            public let subject: String?
            public let conditions: String?
            public let futureUse: String?
            public let formationBasis: String?
            public let usePolicy: String?
            public init(
                text: String,
                kind: String? = nil,
                from: [Int]? = nil,
                subject: String? = nil,
                conditions: String? = nil,
                futureUse: String? = nil,
                formationBasis: String? = nil,
                usePolicy: String? = nil
            ) {
                self.text = text
                self.kind = kind
                self.from = from
                self.subject = subject
                self.conditions = conditions
                self.futureUse = futureUse
                self.formationBasis = formationBasis
                self.usePolicy = usePolicy
            }
        }

        public init(
            op: String,
            memory: Int? = nil,
            text: String? = nil,
            kind: String? = nil,
            from: [Int]? = nil,
            subject: String? = nil,
            assertedBy: String? = nil,
            direction: String? = nil,
            origin: String? = nil,
            asOf: String? = nil,
            expires: String? = nil,
            conditions: String? = nil,
            futureUse: String? = nil,
            formationBasis: String? = nil,
            usePolicy: String? = nil,
            scopes: [ScopePair]? = nil,
            into: [SplitPart]? = nil
        ) {
            self.op = op
            self.memory = memory
            self.text = text
            self.kind = kind
            self.from = from
            self.subject = subject
            self.assertedBy = assertedBy
            self.direction = direction
            self.origin = origin
            self.asOf = asOf
            self.expires = expires
            self.conditions = conditions
            self.futureUse = futureUse
            self.formationBasis = formationBasis
            self.usePolicy = usePolicy
            self.scopes = scopes
            self.into = into
        }
    }

    public struct CandidateCluster: Sendable, Equatable {
        public let index: Int
        public let text: String
        public let supportingMessageCount: Int
        public let distinctThreadCount: Int
        public let newestEvidenceAt: Date
        public let claim: KnowledgeClaim

        public init(index: Int, text: String, supportingMessageCount: Int, distinctThreadCount: Int, newestEvidenceAt: Date, claim: KnowledgeClaim) {
            self.index = index; self.text = text
            self.supportingMessageCount = supportingMessageCount
            self.distinctThreadCount = distinctThreadCount
            self.newestEvidenceAt = newestEvidenceAt
            self.claim = claim
        }
    }

    /// One mined supersession (older guidance → newer guidance), preserving
    /// each endpoint's fine-grained kind and applicability scope. `apply`
    /// resolves these fields through the same durable identity function used
    /// to mint rows, so an edge can never cross into a same-text sibling with
    /// a different kind or scope.
    public struct SupersessionEdge: Sendable, Equatable {
        public let olderNormalizedText: String
        public let olderKindRaw: String
        public let olderScope: [ScopeHint]
        public let newerNormalizedText: String
        public let newerKindRaw: String
        public let newerScope: [ScopeHint]

        public init(
            olderNormalizedText: String,
            olderKindRaw: String,
            olderScope: [ScopeHint],
            newerNormalizedText: String,
            newerKindRaw: String,
            newerScope: [ScopeHint]
        ) {
            self.olderNormalizedText = olderNormalizedText
            self.olderKindRaw = olderKindRaw
            self.olderScope = olderScope
            self.newerNormalizedText = newerNormalizedText
            self.newerKindRaw = newerKindRaw
            self.newerScope = newerScope
        }
    }

    /// Candidate clusters plus the deterministic contradiction/supersession
    /// edges produced by the cross-thread miner + contradiction detector on the
    /// durable distiller path. Carries the edges the live-only Ask snapshot used
    /// to be the sole holder of, so `apply` can persist them on the dossier.
    public struct CandidateClustersWithEdges: Sendable, Equatable {
        public let clusters: [CandidateCluster]
        /// `KnowledgeClaim.key` → `ContradictionState.rawValue` for the claim.
        public let contradictionStateByClaimKey: [String: String]
        public let supersessionEdges: [SupersessionEdge]

        public init(
            clusters: [CandidateCluster],
            contradictionStateByClaimKey: [String: String],
            supersessionEdges: [SupersessionEdge]
        ) {
            self.clusters = clusters
            self.contradictionStateByClaimKey = contradictionStateByClaimKey
            self.supersessionEdges = supersessionEdges
        }
    }

    /// Ordering for picking the most-severe contradiction state across a memory's
    /// source clusters: clean < scopeNarrowed < contested < superseded.
    static func contradictionSeverity(_ state: ContradictionState) -> Int {
        switch state {
        case .clean: return 0
        case .scopeNarrowed: return 1
        case .contested: return 2
        case .superseded: return 3
        }
    }

    /// Static instruction stem — identical across calls for KV prefix caching.
    /// The per-call dimension is named in the suffix, not here.
    ///
    /// The prompt text is a primary quality deliverable (Memory Claim Ledger
    /// design §3): the counterfactual admission test, PRESERVE SPECIFICITY, the
    /// spec's eleven rejection rules, and the dimension-discipline inversion are
    /// verbatim. It is language-neutral — the example activity verbs are
    /// illustrations in any language, not an English keyword list.
    static let promptPrefix = """
    You consolidate durable, evidence-grounded guidance learned from one user's \
    sent and received email. Email is evidence, not the memory unit. Return a \
    JSON array only — no prose and no code fences.

    Most candidate batches should add nothing. Empty output is normal. Never \
    create activity coverage merely because a message or dossier exists.

    Operations:
    [{"op":"add","kind":"preference","text":"<reusable guidance>","futureUse":"<how this changes future handling>","formationBasis":"explicitStanding","usePolicy":"draftingGuidance","from":[1],"conditions":"<when it applies>","scopes":[{"kind":"correspondent","value":"<address>"}]},
     {"op":"reinforce","memory":1,"from":[2]},
     {"op":"weaken","memory":2},
     {"op":"delete","memory":3},
     {"op":"split","memory":4,"into":[{"text":"<one reusable guidance item>","kind":"procedure","futureUse":"<future handling>","formationBasis":"explicitStanding","usePolicy":"internalGuidance","from":[3]}]}]

    Every add and split part requires all of: text, kind, futureUse, \
    formationBasis, usePolicy, and a non-empty from list citing its exact candidate \
    provenance. Each split part cites only evidence supporting that part. Kinds are preference | \
    relationship | roleResponsibility | norm | ruleConstraint | procedure | \
    convention | orientation | learnedLesson. Formation basis is explicitStanding | \
    explicitCorrection | repeatedPattern. `userCurated` is assigned only by direct \
    user editing and must never appear in generated operations. Use policy is \
    internalGuidance | draftingGuidance | contextualOrientation | assertableKnowledge.

    Add only guidance likely to matter in future sessions, durable rather than \
    momentary, specific and actionable, expensive or error-prone to rediscover, \
    supported by provenance, and free of secrets or unnecessary personal data.

    Reject calendar events, deadlines, appointments, completions, current project \
    state, temporary status, email objectives, thread summaries, contextless \
    fragments, one-off approvals or exceptions, and raw transcripts. A date never \
    converts an event into memory. Never create activity coverage.

    One email is sufficient only when it explicitly establishes an enduring \
    preference, correction, rule, role, relationship, procedure, convention, or \
    orientation. An inferred repeatedPattern requires evidence from at least two \
    independent threads. Never generalize a one-off episode into a rule.

    The same definition applies to account, correspondent, classification, \
    project, and language dossiers. Dossier identity changes scope and ranking, \
    not admission. Keep scope narrow and do not strip names or conditions merely \
    to fit a broader dossier.

    Prefer reinforce over a near-duplicate add. Preserve user-edited wording. \
    Weaken, contest, supersede, split, or reject only when cited evidence supports \
    that operation. At most 5 adds per call.

    """

    public static func buildPrompt(
        dimension: AccountMemoryDimensionTarget,
        existing: [AccountMemory],
        clusters: [CandidateCluster]
    ) -> PrefixCachedPrompt {
        renderPrompt(
            dimension: dimension,
            existing: existing,
            clusters: clusters,
            omittedExistingCount: 0,
            abbreviateExistingText: false
        )
    }

    /// Splits candidate evidence into deterministic, suffix-bounded model
    /// calls. Candidate order and original one-based indices are preserved,
    /// and every candidate appears in exactly one returned batch. Candidate
    /// text is indivisible: if one malformed stored claim cannot fit by itself,
    /// return a typed error instead of silently truncating evidence or sending
    /// an oversized prompt.
    public static func buildPromptBatches(
        dimension: AccountMemoryDimensionTarget,
        existing: [AccountMemory],
        clusters: [CandidateCluster],
        maximumSuffixCharacters: Int = maximumPromptSuffixCharacters
    ) throws -> [PromptBatch] {
        guard clusters.isEmpty == false else { return [] }

        let limit = max(1, maximumSuffixCharacters)
        var remainingStart = 0
        var batches: [PromptBatch] = []

        while remainingStart < clusters.count {
            let remaining = Array(clusters[remainingStart...])
            guard let batch = try buildNextPromptBatch(
                dimension: dimension,
                existing: existing,
                clusters: remaining,
                maximumSuffixCharacters: limit
            ) else { break }
            batches.append(batch)
            remainingStart += batch.clusters.count
        }

        return batches
    }

    /// Builds only the next bounded batch from `clusters`. The worker uses
    /// this form so it can re-fetch current dossier rows between calls without
    /// pre-rendering every later batch against stale memory indices.
    public static func buildNextPromptBatch(
        dimension: AccountMemoryDimensionTarget,
        existing: [AccountMemory],
        clusters: [CandidateCluster],
        outputLanguage: SummarizationTargetLanguage? = nil,
        maximumSuffixCharacters: Int = maximumPromptSuffixCharacters
    ) throws -> PromptBatch? {
        guard let firstCandidate = clusters.first else { return nil }
        let limit = max(1, maximumSuffixCharacters)
        var selectedExisting = Array(
            candidateRelevantExistingMemories(existing, for: firstCandidate)
                .prefix(maximumExistingMemoriesPerPrompt)
        )
        var firstPrompt = renderPrompt(
            dimension: dimension,
            existing: selectedExisting,
            clusters: [firstCandidate],
            omittedExistingCount: max(0, existing.count - selectedExisting.count),
            abbreviateExistingText: true,
            outputLanguage: outputLanguage
        )
        while firstPrompt.suffix.count > limit, selectedExisting.isEmpty == false {
            selectedExisting.removeLast()
            firstPrompt = renderPrompt(
                dimension: dimension,
                existing: selectedExisting,
                clusters: [firstCandidate],
                omittedExistingCount: max(0, existing.count - selectedExisting.count),
                abbreviateExistingText: true,
                outputLanguage: outputLanguage
            )
        }
        guard firstPrompt.suffix.count <= limit else {
            throw PromptBatchingError.candidateExceedsPromptLimit(
                index: firstCandidate.index,
                renderedCharacters: firstPrompt.suffix.count,
                limit: limit
            )
        }

        return PromptBatch(
            prompt: firstPrompt,
            existing: selectedExisting,
            clusters: [firstCandidate]
        )
    }

    /// Keeps the prompt small without making rows after a stable prefix
    /// permanently invisible. Memories sharing concrete terms with the next
    /// candidate rank first; ties preserve the caller's stable order so model
    /// indices remain deterministic across identical runs.
    private static func candidateRelevantExistingMemories(
        _ existing: [AccountMemory],
        for candidate: CandidateCluster
    ) -> [AccountMemory] {
        let candidateTokens = selectionTokens(candidate.text)
        return existing.enumerated()
            .map { offset, memory in
                (
                    offset: offset,
                    memory: memory,
                    overlap: candidateTokens.intersection(selectionTokens(memory.displayText)).count
                )
            }
            .sorted { left, right in
                if left.overlap != right.overlap { return left.overlap > right.overlap }
                return left.offset < right.offset
            }
            .map(\.memory)
    }

    private static func selectionTokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { $0.isLetter == false && $0.isNumber == false })
                .filter { $0.count >= 3 }
                .map(String.init)
        )
    }

    private static func renderPrompt(
        dimension: AccountMemoryDimensionTarget,
        existing: [AccountMemory],
        clusters: [CandidateCluster],
        omittedExistingCount: Int,
        abbreviateExistingText: Bool,
        outputLanguage: SummarizationTargetLanguage? = nil
    ) -> PrefixCachedPrompt {
        let dateFormatter = makeLedgerDateFormatter()

        var lines: [String] = []
        lines.append("[DIMENSION] \(dimensionDescriptor(dimension))")
        if let outputLanguage {
            // Memories are read in Settings and Composer; their reader-facing
            // fields follow the reading language whatever the evidence's.
            lines.append("[OUTPUT LANGUAGE] Write text, futureUse, and conditions in \(outputLanguage.promptDescription), translating source-language names and terms.")
        }

        if existing.isEmpty {
            lines.append("[EXISTING MEMORIES]\n(none yet)")
        } else {
            var ex = ["[EXISTING MEMORIES]"]
            for (idx, memory) in existing.enumerated() {
                let displayText = abbreviateExistingText
                    ? boundedExistingMemoryText(memory.displayText)
                    : memory.displayText
                ex.append("\(idx + 1). (\(memory.targetKindRaw), \(memory.resolvedOrigin), \(memory.statusRaw)) \(displayText)")
            }
            if omittedExistingCount > 0 {
                ex.append("[\(omittedExistingCount) additional existing memories omitted from this bounded background call]")
            }
            lines.append(ex.joined(separator: "\n"))
        }

        var ev = ["[CANDIDATE EVIDENCE]"]
        for cluster in clusters {
            let prefix = "\(cluster.index). [seen ×\(cluster.supportingMessageCount) in \(cluster.distinctThreadCount) threads]"
            let annotation = clusterStructuredAnnotation(cluster.claim, dateFormatter: dateFormatter)
            ev.append("\(prefix)\(annotation) \(cluster.text)")
        }
        lines.append(ev.joined(separator: "\n"))
        lines.append("JSON:")

        return PrefixCachedPrompt(
            cacheKey: distillVersion,
            prefix: promptPrefix,
            suffix: lines.joined(separator: "\n\n")
        )
    }

    private static func boundedExistingMemoryText(_ text: String) -> String {
        guard text.count > maximumExistingMemoryTextCharacters else { return text }
        return String(text.prefix(maximumExistingMemoryTextCharacters))
            + " [remaining text omitted from bounded background context]"
    }

    private static func dimensionDescriptor(_ dimension: AccountMemoryDimensionTarget) -> String {
        switch dimension.kindRaw {
        case AccountMemoryDimension.account:
            return "account"
        case AccountMemoryDimension.correspondent:
            return "correspondent (\(dimension.displayName))"
        case AccountMemoryDimension.classification:
            return "classification facet (\(dimension.displayName))"
        case AccountMemoryDimension.project:
            return "project (\(dimension.displayName))"
        case AccountMemoryDimension.translation:
            return "translation (\(dimension.displayName))"
        default:
            return dimension.kindRaw
        }
    }

    /// A fresh `yyyy-MM-dd` formatter (en_US_POSIX / UTC). Instantiated per call
    /// site rather than shared, since `DateFormatter` is not thread-safe and
    /// `apply`/`buildPrompt` may run on different actors concurrently.
    static func makeLedgerDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// Structured `[kind | subject | assertedBy | asOf | conditions]` annotation
    /// for a candidate cluster's claim, omitting empty segments (no empty pipes).
    /// Returns a leading-space-prefixed bracket, or an empty string when the
    /// claim carries no structured fields.
    private static func clusterStructuredAnnotation(
        _ claim: KnowledgeClaim,
        dateFormatter: DateFormatter
    ) -> String {
        var segments: [String] = []
        if let kind = trimmedNonEmpty(claim.kindRaw) { segments.append(kind) }
        if let subject = trimmedNonEmpty(claim.subjectText) { segments.append(subject) }
        if let assertedBy = trimmedNonEmpty(claim.assertedBy) { segments.append(assertedBy) }
        if let asOf = claim.asOf { segments.append(dateFormatter.string(from: asOf)) }
        if let conditions = trimmedNonEmpty(claim.conditionsText) { segments.append(conditions) }
        if let futureUse = trimmedNonEmpty(claim.futureUseText) { segments.append("future: \(futureUse)") }
        if let basis = trimmedNonEmpty(claim.formationBasisRaw) { segments.append("basis: \(basis)") }
        if let policy = trimmedNonEmpty(claim.usePolicyRaw) { segments.append("policy: \(policy)") }
        guard segments.isEmpty == false else { return "" }
        return " [\(segments.joined(separator: " | "))]"
    }

    /// Extracts the first JSON array from the model output. Tolerant of code
    /// fences and surrounding prose; returns [] when unparseable.
    public static func parseOperations(_ raw: String) -> [Operation] {
        let stripped = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let start = stripped.firstIndex(of: "["),
              let end = stripped.lastIndex(of: "]"),
              start < end,
              let data = String(stripped[start...end]).data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([Operation].self, from: data)) ?? []
    }
}

extension MemoryDistiller.PromptBatchingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .candidateExceedsPromptLimit(let index, let renderedCharacters, let limit):
            return "Memory candidate \(index) needs \(renderedCharacters) prompt characters, exceeding the bounded background limit of \(limit)."
        }
    }
}

// MARK: - Apply

public extension MemoryDistiller {

    /// Applies a set of LLM-returned operations to the SwiftData store.
    ///
    /// Must be called from the same actor / thread that owns `modelContext`
    /// (typically `@MainActor`). The caller is responsible for actor isolation.
    ///
    /// - Parameters:
    ///   - ops: Parsed operations from `parseOperations(_:)`.
    ///   - clusters: The candidate clusters passed to `buildPrompt`. The
    ///     `from` indices in `add` operations reference `cluster.index` values
    ///     within this array (1-based, matching the prompt numbering).
    ///   - existing: The `AccountMemory` rows that were listed in the prompt,
    ///     in the same order. The `memory` index in `reinforce` / `weaken` /
    ///     `delete` operations is 1-based into this array.
    ///   - visibleRows: All non-hidden rows currently in this dossier. Bounded
    ///     prompts may list only a slice in `existing`; this full collection
    ///     keeps deterministic lexical/semantic dedup and supersession stamping
    ///     correct without changing the model's one-based memory indices. Nil
    ///     preserves the standalone-call behavior of using `existing`.
    ///   - accountID: The account this dossier belongs to.
    ///   - dimension: The dossier dimension (account / correspondent / classification
    ///     / project) these memories belong to.
    ///   - messageReadouts: Per-message metadata (subject / sender / summary)
    ///     keyed by message id, used to enrich the evidence references built
    ///     from each source cluster's `claim.evidenceLinks`.
    ///   - hiddenRows: Rows for this dossier that are hidden by curation
    ///     (`isHiddenByDefault == true`). When `nil` (the default), `apply`
    ///     performs a targeted fetch internally so standalone callers (tests,
    ///     one-off invocations) don't need to pre-fetch. When non-nil the
    ///     caller-supplied slice is used directly and no fetch is performed —
    ///     this is the hot path for `AccountMemoryRefreshWorker`, which
    ///     pre-fetches all rows once and slices per dossier.
    ///   - modelContext: A `ModelContext` owned by the calling actor.
    ///   - embedder: Optional embedding provider powering the semantic-dedup
    ///     backstop: on `add` / `split` insert candidates that survive the
    ///     lexical (normalized-text) twin check, a vector is computed and
    ///     compared against every already-embedded row in the dossier. A
    ///     best match at or above `dedupCosineThreshold` collapses into a
    ///     reinforce instead of minting a near-duplicate row. Nil disables
    ///     the backstop entirely — the pass behaves exactly as before.
    ///   - now: Logical clock for timestamp fields (injectable for tests).
    static func apply(
        ops: [Operation],
        clusters: [CandidateCluster],
        existing: [AccountMemory],
        accountID: UUID,
        dimension: AccountMemoryDimensionTarget,
        modelContext: ModelContext,
        messageReadouts: [UUID: AccountMemoryMessageReadout] = [:],
        visibleRows: [AccountMemory]? = nil,
        hiddenRows: [AccountMemory]? = nil,
        contradictionStateByClaimKey: [String: String] = [:],
        supersessionEdges: [SupersessionEdge] = [],
        embedder: (any EmbeddingProvider)? = nil,
        saveChanges: Bool = true,
        now: Date = .now
    ) throws {
        // Build a lookup from cluster.index → CandidateCluster for O(1) resolution.
        let clusterByIndex: [Int: CandidateCluster] = Dictionary(
            uniqueKeysWithValues: clusters.map { ($0.index, $0) }
        )

        let dateFormatter = makeLedgerDateFormatter()

        // Dedup against every visible current-contract row, including
        // needsReview / contested lifecycle states that are intentionally
        // absent from the model prompt. Reinforcement preserves lifecycle, so
        // this cannot reactivate a row; it only prevents a duplicate active add.
        // Legacy quarantined rows remain excluded because they predate durable
        // identity and must not absorb current-contract evidence.
        var dedupRows = (visibleRows ?? existing).filter { row in
            row.isCurrentContract && row.isHiddenByDefault == false
        }

        // Suppression set: normalized texts of user-rejected or user-deleted
        // memories for this dossier. These rows are intentionally excluded from
        // `existing` (the prompt list) because `isHiddenByDefault == true`, but
        // they live in the store and their memoryKey is derived deterministically
        // from the same text. Re-inserting them would silently resurrect a
        // user's curation decision and create a duplicate memoryKey collision.
        //
        // When the caller supplies `hiddenRows` (the worker's pre-fetched slice),
        // use it directly — no additional fetch. When nil, fetch internally so
        // standalone callers remain correct without pre-fetching.
        //
        // SwiftData `#Predicate` cannot filter on computed properties like
        // `dimensionKind` or `resolvedDimensionValue`, and custom-enum string
        // constants break predicate translation — fetch all rows for this account
        // and filter in-memory (matches the batch-fetch pattern used elsewhere).
        let resolvedHiddenRows: [AccountMemory] = hiddenRows ?? {
            let allForAccount = (try? modelContext.fetch(
                FetchDescriptor<AccountMemory>(
                    predicate: #Predicate<AccountMemory> { $0.accountID == accountID }
                )
            )) ?? []
            return allForAccount.filter { $0.isHiddenByDefault }
        }()
        let dossierHiddenRows = resolvedHiddenRows.filter { memory in
            memory.dimensionKind == dimension.kindRaw
                && memory.resolvedDimensionValue == dimension.value
        }
        let suppressedMemoryKeys = Set(
            dossierHiddenRows.filter(\.isCurrentContract).map(\.memoryKey).filter { !$0.isEmpty }
        )
        // Legacy tombstones predate scoped durable identity. Preserve their
        // no-resurrection guarantee conservatively within this dossier.
        let legacySuppressedNormalizedTexts = Set(
            dossierHiddenRows.filter { !$0.isCurrentContract }.map(\.normalizedText).filter { !$0.isEmpty }
        )

        var mutated = false
        // memoryKeys of rows deleted this pass, so dangling supersededBy
        // pointers to them can be cleared in the post-pass.
        var deletedMemoryKeys: Set<String> = []

        for op in ops {
            switch op.op {

            // ----------------------------------------------------------------
            case "add":
                // Every cited index must resolve. Partial provenance is not
                // accepted because it lets the model silently drop contrary
                // or scope-defining evidence.
                guard let fromIndices = op.from, !fromIndices.isEmpty else { continue }
                let uniqueFromIndices = Array(Set(fromIndices)).sorted()
                let sourceClusters = uniqueFromIndices.compactMap { clusterByIndex[$0] }
                guard sourceClusters.count == uniqueFromIndices.count else { continue }

                guard let text = op.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let normalizedText = ConversationCurationKey.normalize(text: text)
                guard let targetKindRaw = trimmedNonEmpty(op.kind),
                      AccountMemoryKind.all.contains(targetKindRaw),
                      let futureUseText = trimmedNonEmpty(op.futureUse),
                      ConversationCurationKey.normalize(text: futureUseText) != normalizedText,
                      let formationBasisRaw = trimmedNonEmpty(op.formationBasis),
                      AccountMemoryFormationBasis.generated.contains(formationBasisRaw),
                      let usePolicyRaw = trimmedNonEmpty(op.usePolicy),
                      AccountMemoryUsePolicy.all.contains(usePolicyRaw),
                      sourceClusters.allSatisfy({ cluster in
                          cluster.claim.kindRaw == targetKindRaw
                              && cluster.claim.usePolicyRaw == usePolicyRaw
                              && cluster.claim.formationBasisRaw == formationBasisRaw
                              && cluster.claim.evidenceLinks.contains(where: { link in
                                  guard let span = link.span else { return false }
                                  return !span.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              })
                      }) else { continue }

                if formationBasisRaw == AccountMemoryFormationBasis.repeatedPattern {
                    let messageCount = sourceClusters.reduce(0) { $0 + $1.supportingMessageCount }
                    let threadCount = Set(sourceClusters.flatMap {
                        $0.claim.evidenceLinks.map { $0.threadID ?? $0.messageID }
                    }).count
                    guard messageCount >= 2, threadCount >= 2 else { continue }
                }

                // Build evidence references from the source clusters, enriched
                // via the per-message readouts.
                let newEvidence = evidenceReferences(
                    sourceClusters.flatMap { $0.claim.evidenceLinks },
                    messageReadouts: messageReadouts
                )

                // Resolve the full applicability contract before dedup. Text
                // similarity alone is never enough to merge memories.
                let subjectText = trimmedNonEmpty(op.subject)
                    ?? firstNonNilClaimString(sourceClusters, \.subjectText)
                let assertedByAddress: String? = {
                    if let asserted = trimmedNonEmpty(op.assertedBy) {
                        return asserted.lowercased() == "shared" ? nil : asserted
                    }
                    return firstNonNilClaimString(sourceClusters, \.assertedBy)
                }()
                let directionRaw = trimmedNonEmpty(op.direction)
                    ?? firstNonNilClaimString(sourceClusters, \.directionRaw)
                let originRaw = trimmedNonEmpty(op.origin)
                    ?? firstNonNilClaimString(sourceClusters, \.originRaw)
                let asOf = parseLedgerDate(op.asOf, using: dateFormatter)
                    ?? sourceClusters.compactMap { $0.claim.asOf }.first
                let expiresAt = parseLedgerDate(op.expires, using: dateFormatter)
                    ?? sourceClusters.compactMap { $0.claim.expiresAt }.first
                let conditionsText = trimmedNonEmpty(op.conditions)
                    ?? firstNonNilClaimString(sourceClusters, \.conditionsText)
                let scopeRefs = resolveScopeReferences(op.scopes, sourceClusters: sourceClusters)
                let scopeJSON = scopeRefs.isEmpty ? "[]" : AccountMemory.encodeScope(scopeRefs)
                guard scopesAreSupported(scopeRefs, by: sourceClusters) else { continue }

                let memoryKey = durableMemoryKey(
                    text: text,
                    kindRaw: targetKindRaw,
                    scope: scopeRefs,
                    dimension: dimension,
                    subjectText: subjectText,
                    conditionsText: conditionsText,
                    futureUseText: futureUseText,
                    formationBasisRaw: formationBasisRaw,
                    usePolicyRaw: usePolicyRaw
                )

                // Respect curation: never resurrect a rejected or deleted memory.
                if suppressedMemoryKeys.contains(memoryKey)
                    || legacySuppressedNormalizedTexts.contains(normalizedText) { continue }

                // Dedup: if an existing row (or one inserted earlier in this
                // call) has the same normalized text, treat as reinforce —
                // merging the freshly-derived evidence into the stored set.
                if let twin = dedupRows.first(where: {
                    $0.normalizedText == normalizedText
                        && dedupCompatible(
                            $0,
                            kindRaw: targetKindRaw,
                            scope: scopeRefs,
                            conditionsText: conditionsText,
                            formationBasisRaw: formationBasisRaw,
                            usePolicyRaw: usePolicyRaw,
                            futureUseText: futureUseText
                        )
                }) {
                    reinforce(twin, mergingEvidence: newEvidence, now: now, embedder: embedder)
                    mutated = true
                    continue
                }

                // Semantic dedup backstop: the lexical check missed a twin
                // (paraphrase, word order, synonym). When an embedder is
                // wired, compute the candidate's vector and compare against
                // every already-embedded row in this dossier; a best match
                // at or above `dedupCosineThreshold` collapses into the same
                // reinforce-not-insert treatment as a lexical twin. The
                // vector is reused below to embed the row on insert when no
                // twin is found, so this costs exactly one `embed` call.
                let candidateVector = embedder?.embed(text)
                if let candidateVector, let embedder,
                   let semanticTwinRow = semanticTwin(
                       for: candidateVector,
                       embedder: embedder,
                       among: dedupRows.filter {
                           dedupCompatible(
                               $0,
                               kindRaw: targetKindRaw,
                               scope: scopeRefs,
                               conditionsText: conditionsText,
                               formationBasisRaw: formationBasisRaw,
                               usePolicyRaw: usePolicyRaw,
                               futureUseText: futureUseText
                           )
                       }
                   ) {
                    reinforce(semanticTwinRow, mergingEvidence: newEvidence, now: now, embedder: embedder)
                    mutated = true
                    continue
                }

                // Derive weight and evidence strength from the source clusters.
                let weight = sourceClusters.map { $0.claim.weight }.max() ?? 0.5
                let evidenceStrength = min(1.0,
                    Double(sourceClusters.map { $0.supportingMessageCount }.reduce(0, +)) / 3.0
                )
                let newestEvidence = sourceClusters.map { $0.newestEvidenceAt }.max() ?? now
                let oldestEvidence = sourceClusters.map { $0.claim.firstSeen }.min() ?? now
                let sensitivityRisk = sourceClusters
                    .map(\.claim.status.sensitivityRisk)
                    .max { $0.rank < $1.rank }
                    ?? .none

                // Persist the most-severe contradiction state the detector found
                // across the source clusters (deterministic, not LLM-decided), so
                // the durable row carries the same epistemic signal the live Ask
                // snapshot does. Empty signal → clean (the prior behaviour).
                let addState = sourceClusters
                    .compactMap { contradictionStateByClaimKey[$0.claim.key] }
                    .compactMap(ContradictionState.init(rawValue:))
                    .max { contradictionSeverity($0) < contradictionSeverity($1) }
                    ?? .clean

                let memory = AccountMemory(
                    accountID: accountID,
                    memoryKey: memoryKey,
                    targetKindRaw: targetKindRaw,
                    dimensionKindRaw: dimension.kindRaw,
                    dimensionValue: dimension.value,
                    dimensionDisplayName: dimension.displayName,
                    normalizedText: normalizedText,
                    generatedText: text,
                    statusRaw: AccountMemoryProjectedStatus.active,
                    weight: weight,
                    extractionConfidence: sourceClusters.map { $0.claim.status.extractionConfidence }.max() ?? 0.5,
                    evidenceStrength: evidenceStrength,
                    sensitivityRiskRaw: sensitivityRisk.rawValue,
                    contradictionStateRaw: addState.rawValue,
                    scopeJSON: scopeJSON,
                    evidenceJSON: AccountMemory.encodeEvidence(newEvidence),
                    firstSeenAt: oldestEvidence,
                    lastSeenAt: newestEvidence,
                    lastAffirmedAt: nil,
                    extractionVersion: AccountMemoryContract.currentVersion,
                    supportingFingerprint: "",
                    projectedAt: now,
                    createdAt: now,
                    updatedAt: now,
                    originRaw: originRaw,
                    assertedByAddress: assertedByAddress,
                    directionRaw: directionRaw,
                    asOf: asOf,
                    expiresAt: expiresAt,
                    conditionsText: conditionsText,
                    futureUseText: futureUseText,
                    formationBasisRaw: formationBasisRaw,
                    usePolicyRaw: usePolicyRaw,
                    subjectText: subjectText,
                    embeddingBlob: candidateVector.map(AccountMemoryEmbeddingCodec.encode),
                    memoryEmbeddingVersion: candidateVector != nil ? embedder?.embeddingVersion : nil
                )
                modelContext.insert(memory)
                dedupRows.append(memory)
                mutated = true

            // ----------------------------------------------------------------
            case "reinforce":
                guard let idx = op.memory, idx >= 1, idx <= existing.count else { continue }
                let memory = existing[idx - 1]
                guard memory.isDurablePromptEligible,
                      let fromIndices = op.from,
                      fromIndices.isEmpty == false else { continue }
                let uniqueFromIndices = Array(Set(fromIndices)).sorted()
                let cited = uniqueFromIndices.compactMap { clusterByIndex[$0] }
                guard cited.count == uniqueFromIndices.count,
                      cited.allSatisfy({ cluster in
                          dedupCompatible(
                              memory,
                              kindRaw: cluster.claim.kindRaw,
                              scope: cluster.claim.scope.map {
                                  AccountMemoryScopeReference(kindRaw: $0.kind.rawValue, value: $0.value)
                              },
                              conditionsText: cluster.claim.conditionsText,
                              formationBasisRaw: cluster.claim.formationBasisRaw,
                              usePolicyRaw: cluster.claim.usePolicyRaw,
                              futureUseText: cluster.claim.futureUseText
                          )
                      }) else { continue }
                let citedEvidence = evidenceReferences(
                    cited.flatMap { $0.claim.evidenceLinks },
                    messageReadouts: messageReadouts
                )
                reinforce(memory, mergingEvidence: citedEvidence, now: now, embedder: embedder)
                mutated = true

            // ----------------------------------------------------------------
            case "weaken":
                guard let idx = op.memory, idx >= 1, idx <= existing.count else { continue }
                let memory = existing[idx - 1]
                if memory.lastAffirmedAt != nil {
                    // Never demote a user-affirmed row: record the contest only,
                    // leaving status and weight intact.
                    memory.contradictionStateRaw = ContradictionState.contested.rawValue
                    memory.updatedAt = now
                } else {
                    memory.statusRaw = AccountMemoryProjectedStatus.weakened
                    memory.weight = max(0, memory.weight / 2.0)
                    // Newer evidence superseded this memory — record the epistemic
                    // reason alongside the weight downgrade so selectors can see it.
                    memory.contradictionStateRaw = ContradictionState.superseded.rawValue
                    memory.updatedAt = now
                }
                mutated = true

            // ----------------------------------------------------------------
            case "delete":
                guard let idx = op.memory, idx >= 1, idx <= existing.count else { continue }
                let doomed = existing[idx - 1]
                // Never delete an affirmed or user-edited row — those carry
                // curation history the LLM must not override. Silently skip
                // (this enum has no logger and adding one is out of scope).
                if doomed.lastAffirmedAt != nil || doomed.userEditedText != nil { continue }
                if !doomed.memoryKey.isEmpty { deletedMemoryKeys.insert(doomed.memoryKey) }
                modelContext.delete(doomed)
                mutated = true

            // ----------------------------------------------------------------
            case "split":
                guard let idx = op.memory, idx >= 1, idx <= existing.count else { continue }
                let source = existing[idx - 1]
                // Split only decomposes distiller-managed rows: never an
                // affirmed, user-edited, or curation-hidden row.
                if source.lastAffirmedAt != nil
                    || source.userEditedText != nil
                    || source.isHiddenByDefault { continue }
                guard source.isDurablePromptEligible,
                      let parts = op.into,
                      parts.isEmpty == false else { continue }

                let sourceScope = source.decodedScope()
                let validatedParts = parts.compactMap { part -> (
                    part: Operation.SplitPart,
                    kind: String,
                    futureUse: String,
                    formationBasis: String,
                    usePolicy: String,
                    clusters: [CandidateCluster],
                    evidence: [AccountMemoryEvidenceReference]
                )? in
                    guard !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let partKind = trimmedNonEmpty(part.kind),
                          AccountMemoryKind.all.contains(partKind),
                          let partFutureUse = trimmedNonEmpty(part.futureUse),
                          ConversationCurationKey.normalize(text: partFutureUse)
                            != ConversationCurationKey.normalize(text: part.text),
                          let partFormationBasis = trimmedNonEmpty(part.formationBasis),
                          AccountMemoryFormationBasis.generated.contains(partFormationBasis),
                          let partUsePolicy = trimmedNonEmpty(part.usePolicy),
                          AccountMemoryUsePolicy.all.contains(partUsePolicy),
                          let fromIndices = part.from,
                          fromIndices.isEmpty == false else { return nil }

                    let uniqueFromIndices = Array(Set(fromIndices)).sorted()
                    let sourceClusters = uniqueFromIndices.compactMap { clusterByIndex[$0] }
                    guard sourceClusters.count == uniqueFromIndices.count,
                          sourceClusters.allSatisfy({ cluster in
                              cluster.claim.kindRaw == partKind
                                && cluster.claim.formationBasisRaw == partFormationBasis
                                && cluster.claim.usePolicyRaw == partUsePolicy
                                && cluster.claim.evidenceLinks.contains(where: { link in
                                    guard let span = link.span else { return false }
                                    return span.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                })
                          }),
                          scopesAreSupported(sourceScope, by: sourceClusters) else { return nil }

                    if partFormationBasis == AccountMemoryFormationBasis.repeatedPattern {
                        let messageCount = sourceClusters.reduce(0) { $0 + $1.supportingMessageCount }
                        let threadCount = Set(sourceClusters.flatMap {
                            $0.claim.evidenceLinks.map { $0.threadID ?? $0.messageID }
                        }).count
                        guard messageCount >= 2, threadCount >= 2 else { return nil }
                    }

                    let citedEvidence = evidenceReferences(
                        sourceClusters.flatMap { $0.claim.evidenceLinks },
                        messageReadouts: messageReadouts
                    )
                    guard citedEvidence.isEmpty == false else { return nil }
                    return (
                        part,
                        partKind,
                        partFutureUse,
                        partFormationBasis,
                        partUsePolicy,
                        sourceClusters,
                        citedEvidence
                    )
                }
                guard validatedParts.count == parts.count else { continue }

                for validated in validatedParts {
                    let part = validated.part
                    let partKind = validated.kind
                    let partFutureUse = validated.futureUse
                    let partFormationBasis = validated.formationBasis
                    let partUsePolicy = validated.usePolicy
                    let partClusters = validated.clusters
                    let citedEvidence = validated.evidence
                    let partNormalized = ConversationCurationKey.normalize(text: part.text)
                    let partSubject = trimmedNonEmpty(part.subject)
                        ?? firstNonNilClaimString(partClusters, \.subjectText)
                    let partConditions = trimmedNonEmpty(part.conditions)
                        ?? firstNonNilClaimString(partClusters, \.conditionsText)
                    let partAssertedByAddress = firstNonNilClaimString(partClusters, \.assertedBy)
                        .flatMap { $0.lowercased() == "shared" ? nil : $0 }
                    let partDirectionRaw = firstNonNilClaimString(partClusters, \.directionRaw)
                    let partOriginRaw = firstNonNilClaimString(partClusters, \.originRaw)
                    let partAsOf = partClusters.compactMap { $0.claim.asOf }.first
                    let partExpiresAt = partClusters.compactMap { $0.claim.expiresAt }.first
                    let partKey = durableMemoryKey(
                        text: part.text,
                        kindRaw: partKind,
                        scope: source.decodedScope(),
                        dimension: dimension,
                        subjectText: partSubject,
                        conditionsText: partConditions,
                        futureUseText: partFutureUse,
                        formationBasisRaw: partFormationBasis,
                        usePolicyRaw: partUsePolicy
                    )

                    // Same tombstone-suppression and normalized-text dedup as add.
                    if suppressedMemoryKeys.contains(partKey)
                        || legacySuppressedNormalizedTexts.contains(partNormalized) { continue }
                    if let twin = dedupRows.first(where: {
                        $0.id != source.id
                            && $0.normalizedText == partNormalized
                            && dedupCompatible(
                                $0,
                                kindRaw: partKind,
                                scope: source.decodedScope(),
                                conditionsText: partConditions,
                                formationBasisRaw: partFormationBasis,
                                usePolicyRaw: partUsePolicy,
                                futureUseText: partFutureUse
                            )
                    }) {
                        reinforce(twin, mergingEvidence: citedEvidence, now: now, embedder: embedder)
                        mutated = true
                        continue
                    }

                    // Semantic dedup backstop, mirroring the add path: no
                    // lexical twin, but the part's vector cosines above
                    // `dedupCosineThreshold` against an already-embedded
                    // dossier row → reinforce that row instead of minting a
                    // near-duplicate atomic claim.
                    let partVector = embedder?.embed(part.text)
                    if let partVector, let embedder,
                       let semanticTwinRow = semanticTwin(
                           for: partVector,
                           embedder: embedder,
                           among: dedupRows.filter {
                               $0.id != source.id
                                   && dedupCompatible(
                                   $0,
                                   kindRaw: partKind,
                                   scope: source.decodedScope(),
                                   conditionsText: partConditions,
                                   formationBasisRaw: partFormationBasis,
                                   usePolicyRaw: partUsePolicy,
                                   futureUseText: partFutureUse
                               )
                           }
                    ) {
                        reinforce(semanticTwinRow, mergingEvidence: citedEvidence, now: now, embedder: embedder)
                        mutated = true
                        continue
                    }

                    let newestEvidence = partClusters.map(\.newestEvidenceAt).max() ?? now
                    let oldestEvidence = partClusters.map { $0.claim.firstSeen }.min() ?? newestEvidence
                    let sensitivityRisk = partClusters
                        .map(\.claim.status.sensitivityRisk)
                        .max { $0.rank < $1.rank }
                        ?? .none

                    let partMemory = AccountMemory(
                        accountID: accountID,
                        memoryKey: partKey,
                        targetKindRaw: partKind,
                        dimensionKindRaw: source.dimensionKind,
                        dimensionValue: source.resolvedDimensionValue,
                        dimensionDisplayName: source.resolvedDimensionDisplayName,
                        normalizedText: partNormalized,
                        generatedText: part.text,
                        statusRaw: AccountMemoryProjectedStatus.active,
                        weight: partClusters.map { $0.claim.weight }.max() ?? source.weight,
                        extractionConfidence: partClusters
                            .map { $0.claim.status.extractionConfidence }
                            .max() ?? source.extractionConfidence,
                        evidenceStrength: min(1.0, Double(citedEvidence.count) / 3.0),
                        sensitivityRiskRaw: sensitivityRisk.rawValue,
                        contradictionStateRaw: ContradictionState.clean.rawValue,
                        scopeJSON: source.scopeJSON,
                        evidenceJSON: AccountMemory.encodeEvidence(citedEvidence),
                        firstSeenAt: oldestEvidence,
                        lastSeenAt: newestEvidence,
                        lastAffirmedAt: nil,
                        extractionVersion: AccountMemoryContract.currentVersion,
                        supportingFingerprint: "",
                        projectedAt: now,
                        createdAt: now,
                        updatedAt: now,
                        originRaw: partOriginRaw,
                        assertedByAddress: partAssertedByAddress,
                        directionRaw: partDirectionRaw,
                        asOf: partAsOf,
                        expiresAt: partExpiresAt,
                        conditionsText: partConditions,
                        futureUseText: partFutureUse,
                        formationBasisRaw: partFormationBasis,
                        usePolicyRaw: partUsePolicy,
                        subjectText: partSubject,
                        embeddingBlob: partVector.map(AccountMemoryEmbeddingCodec.encode),
                        memoryEmbeddingVersion: partVector != nil ? embedder?.embeddingVersion : nil
                    )
                    modelContext.insert(partMemory)
                    dedupRows.append(partMemory)
                    mutated = true
                }

                // Retire the compound original; the parts replace it.
                if !source.memoryKey.isEmpty { deletedMemoryKeys.insert(source.memoryKey) }
                dedupRows.removeAll { $0.id == source.id }
                modelContext.delete(source)
                mutated = true

            default:
                break
            }
        }

        // Supersession edges predate the full applicability contract. Resolve
        // an endpoint only when text + kind + complete scope identify exactly
        // one surviving row; multiple applicability variants are ambiguous and
        // therefore fail closed instead of cross-stamping sibling guidance.
        for edge in supersessionEdges {
            func matchingRows(text: String, kindRaw: String, scope: [ScopeHint]) -> [AccountMemory] {
                let normalizedText = ConversationCurationKey.normalize(text: text)
                let scopeSet = normalizedScopeSet(scope.map {
                    AccountMemoryScopeReference(kindRaw: $0.kind.rawValue, value: $0.value)
                })
                return dedupRows.filter { row in
                    deletedMemoryKeys.contains(row.memoryKey) == false
                        && row.dimensionKind == dimension.kindRaw
                        && row.resolvedDimensionValue == dimension.value
                        && row.normalizedText == normalizedText
                        && row.targetKindRaw == kindRaw
                        && normalizedScopeSet(row.decodedScope()) == scopeSet
                }
            }
            let olderMatches = matchingRows(
                text: edge.olderNormalizedText,
                kindRaw: edge.olderKindRaw,
                scope: edge.olderScope
            )
            let newerMatches = matchingRows(
                text: edge.newerNormalizedText,
                kindRaw: edge.newerKindRaw,
                scope: edge.newerScope
            )
            guard olderMatches.count == 1,
                  newerMatches.count == 1,
                  let olderRow = olderMatches.first,
                  let newerRow = newerMatches.first,
                  olderRow !== newerRow,
                  !newerRow.memoryKey.isEmpty
            else { continue }
            if olderRow.supersededByMemoryKey != newerRow.memoryKey
                || olderRow.contradictionStateRaw != ContradictionState.superseded.rawValue {
                olderRow.supersededByMemoryKey = newerRow.memoryKey
                olderRow.contradictionStateRaw = ContradictionState.superseded.rawValue
                olderRow.updatedAt = now
                mutated = true
            }
        }

        // Clear supersededBy pointers that referenced a row deleted this pass, so
        // a selector never hides a row behind a superseding fact that no longer
        // exists.
        if !deletedMemoryKeys.isEmpty {
            // Include quarantined legacy rows as well as current dedup rows:
            // legacy rows are intentionally absent from prompt-eligible rows,
            // but their audit history must not retain a dangling pointer.
            for row in (visibleRows ?? existing) + dedupRows {
                guard !deletedMemoryKeys.contains(row.memoryKey) else { continue }
                if let key = row.supersededByMemoryKey, deletedMemoryKeys.contains(key) {
                    row.supersededByMemoryKey = nil
                    row.updatedAt = now
                    mutated = true
                }
            }
        }

        if mutated && saveChanges {
            try modelContext.save()
        }
    }

    // MARK: - Post-distill supersession

    /// Quarantines pre-contract generated rows on one dossier after a distill
    /// pass. Legacy rows remain stored for audit but cannot enter prompts;
    /// current-contract rows, material user edits, and curation tombstones are
    /// preserved. The historical name remains for source compatibility.
    ///
    /// - Returns: The count of rows newly quarantined.
    @discardableResult
    static func supersedeStaleVersionRows(
        accountID: UUID,
        dimension: AccountMemoryDimensionTarget,
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> Int {
        // Fetch all rows for this account (predicate limitation: cannot filter
        // on computed properties like dimensionKind / resolvedDimensionValue or
        // string-constant enum comparisons in #Predicate — filter in memory).
        let allForAccount = try modelContext.fetch(
            FetchDescriptor<AccountMemory>(
                predicate: #Predicate<AccountMemory> { $0.accountID == accountID }
            )
        )

        let stale = allForAccount.filter { m in
            m.dimensionKind == dimension.kindRaw
                && m.resolvedDimensionValue == dimension.value
                && m.extractionVersion != AccountMemoryContract.currentVersion
                && m.userEditedText == nil
                && m.isHiddenByDefault == false
                && m.statusRaw != AccountMemoryProjectedStatus.needsReview
        }
        guard stale.isEmpty == false else { return 0 }
        for row in stale {
            row.statusRaw = AccountMemoryProjectedStatus.needsReview
            row.updatedAt = now
        }
        try modelContext.save()
        return stale.count
    }

    // MARK: - Private helpers

    /// - Parameter embedder: When supplied, backfills / refreshes
    ///   `embeddingBlob` / `memoryEmbeddingVersion` from `memory.displayText`
    ///   whenever the row has no stored embedding yet OR its stored embedding
    ///   is stamped at a different version than the embedder's current one. So
    ///   a row that predates the embedder, was minted by a nil-embedder call,
    ///   or carries a blob from a superseded embedder version converges to a
    ///   version-current vector the next time it's touched — the same cheap
    ///   embed call this reinforce is already paying for evidence merging.
    ///   Never alters the row's wording (`generatedText` / `userEditedText`),
    ///   so confirmed and user-edited rows are as safe to re-embed as any other.
    private static func reinforce(
        _ memory: AccountMemory,
        mergingEvidence newEvidence: [AccountMemoryEvidenceReference],
        now: Date,
        embedder: (any EmbeddingProvider)? = nil
    ) {
        if let newestEvidenceTimestamp = newEvidence.map(\.timestamp).max() {
            memory.lastSeenAt = max(memory.lastSeenAt, newestEvidenceTimestamp)
        }
        if newEvidence.isEmpty == false {
            let merged = mergeEvidence(existing: memory.decodedEvidence(), incoming: newEvidence)
            memory.evidenceJSON = AccountMemory.encodeEvidence(merged)
        }
        if let embedder,
           memory.embeddingBlob == nil || memory.memoryEmbeddingVersion != embedder.embeddingVersion,
           let vector = embedder.embed(memory.displayText) {
            memory.embeddingBlob = AccountMemoryEmbeddingCodec.encode(vector)
            memory.memoryEmbeddingVersion = embedder.embeddingVersion
        }
        memory.updatedAt = now
    }

    /// Best embedding match for `vector` among `candidates` (the dossier's
    /// rows, existing plus any inserted earlier in this `apply` call) whose
    /// stored embedding is at the embedder's current version — a
    /// version-mismatched blob is silently skipped rather than compared, so
    /// a stale vector can never wrongly collapse a fresh candidate into it
    /// (it converges on that row's next reinforce backfill instead). Returns
    /// nil when no candidate's cosine similarity clears `dedupCosineThreshold`.
    private static func semanticTwin(
        for vector: [Float],
        embedder: any EmbeddingProvider,
        among candidates: some Sequence<AccountMemory>
    ) -> AccountMemory? {
        var best: (row: AccountMemory, similarity: Float)?
        for candidate in candidates {
            guard let blob = candidate.embeddingBlob,
                  candidate.memoryEmbeddingVersion == embedder.embeddingVersion else { continue }
            let candidateVector = AccountMemoryEmbeddingCodec.decode(blob)
            let similarity = VectorStore.cosineSimilarity(vector, candidateVector)
            if best == nil || similarity > best!.similarity {
                best = (candidate, similarity)
            }
        }
        guard let best, best.similarity >= dedupCosineThreshold else { return nil }
        return best.row
    }

    /// Builds evidence references from raw `EvidenceLink`s, enriched with the
    /// per-message readout.
    private static func evidenceReferences(
        _ links: [EvidenceLink],
        messageReadouts: [UUID: AccountMemoryMessageReadout]
    ) -> [AccountMemoryEvidenceReference] {
        let references = links.map { link -> AccountMemoryEvidenceReference in
            let readout = messageReadouts[link.messageID]
            return AccountMemoryEvidenceReference(
                messageID: link.messageID,
                subject: readout?.subject ?? "(unknown subject)",
                senderAddress: readout?.senderAddress ?? "",
                senderName: readout?.senderName,
                timestamp: link.timestamp,
                fieldSourceRaw: link.fieldSource.rawValue,
                spanText: link.span?.text,
                summary: readout?.summary,
                confidence: link.confidence,
                threadID: readout?.threadID ?? link.threadID,
                isSentByUser: readout?.isSentByUser
            )
        }
        return dedupedEvidence(references)
    }

    // MARK: - Structured-field resolution helpers

    /// Coarse curation `TargetKind` for a ten-kind memory raw. Curation verdicts
    /// bucket into five kinds; the fine-grained ten-kind taxonomy lives in
    /// `targetKindRaw`. Only `decision` has a dedicated verdict bucket; every
    /// other kind keys off `.claim`.
    static func curationTargetKind(forMemoryKind kind: String) -> ConversationCurationAction.TargetKind {
        switch kind {
        case AccountMemoryKind.decision: return .decision
        default: return .claim
        }
    }

    /// Stable identity for one durable memory contract. Fine-grained memory
    /// kind, dossier, and applicability scope all participate so equal wording
    /// in different contexts cannot share curation or supersession state.
    static func durableMemoryKey(
        text: String,
        kindRaw: String,
        scope: [AccountMemoryScopeReference],
        dimension: AccountMemoryDimensionTarget,
        subjectText: String?,
        conditionsText: String?,
        futureUseText: String?,
        formationBasisRaw: String?,
        usePolicyRaw: String?
    ) -> String {
        var identityParts = [
            "memory-kind:\(kindRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())",
            "dossier:\(dimension.kindRaw.lowercased()):\(dimension.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())",
            "subject:\(ConversationCurationKey.normalize(text: subjectText ?? ""))",
            "conditions:\(ConversationCurationKey.normalize(text: conditionsText ?? ""))",
            "future-use:\(ConversationCurationKey.normalize(text: futureUseText ?? ""))",
            "formation:\(ConversationCurationKey.normalize(text: formationBasisRaw ?? ""))",
            "use-policy:\(ConversationCurationKey.normalize(text: usePolicyRaw ?? ""))"
        ]
        identityParts.append(contentsOf: scope.compactMap { reference in
            guard let kind = trimmedNonEmpty(reference.kindRaw),
                  let value = trimmedNonEmpty(reference.value) else { return nil }
            return "scope:\(kind.lowercased()):\(value.lowercased())"
        })
        let identityFingerprint = identityParts.sorted().joined(separator: "|")
        return ConversationCurationKey.make(
            text: text,
            kind: curationTargetKind(forMemoryKind: kindRaw),
            scopeFingerprint: identityFingerprint,
            extractionVersion: AccountMemoryContract.currentVersion,
            supportingMessageContentHashes: []
        ).targetKey
    }

    /// Trimmed, non-empty form of an optional string, else nil.
    static func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    /// Parse a `yyyy-MM-dd` string using the supplied formatter, else nil.
    static func parseLedgerDate(_ raw: String?, using formatter: DateFormatter) -> Date? {
        guard let trimmed = trimmedNonEmpty(raw) else { return nil }
        return formatter.date(from: trimmed)
    }

    /// First non-nil, non-empty value of a `KnowledgeClaim` string field across
    /// the source clusters (the op-omitted-field fallback).
    private static func firstNonNilClaimString(
        _ clusters: [CandidateCluster],
        _ keyPath: KeyPath<KnowledgeClaim, String?>
    ) -> String? {
        for cluster in clusters {
            if let value = trimmedNonEmpty(cluster.claim[keyPath: keyPath]) { return value }
        }
        return nil
    }

    /// Resolve the op's scope pairs into `AccountMemoryScopeReference`s, falling
    /// back to the first source cluster carrying scope hints when the op omits
    /// them.
    private static func resolveScopeReferences(
        _ scopes: [Operation.ScopePair]?,
        sourceClusters: [CandidateCluster]
    ) -> [AccountMemoryScopeReference] {
        if let scopes, scopes.isEmpty == false {
            return scopes.map { AccountMemoryScopeReference(kindRaw: $0.kind, value: $0.value) }
        }
        if let hints = sourceClusters.map({ $0.claim.scope }).first(where: { $0.isEmpty == false }) {
            return hints.map { AccountMemoryScopeReference(kindRaw: $0.kind.rawValue, value: $0.value) }
        }
        return []
    }

    /// The consolidator may preserve or narrow only scope carried by every
    /// cited cluster. It may never invent a new applicability boundary or
    /// silently broaden differently scoped guidance into one memory.
    private static func scopesAreSupported(
        _ resolved: [AccountMemoryScopeReference],
        by sourceClusters: [CandidateCluster]
    ) -> Bool {
        let resolvedSet = normalizedScopeSet(resolved)
        return sourceClusters.allSatisfy { cluster in
            let sourceSet = normalizedScopeSet(cluster.claim.scope.map {
                AccountMemoryScopeReference(kindRaw: $0.kind.rawValue, value: $0.value)
            })
            return sourceSet == resolvedSet
        }
    }

    private static func dedupCompatible(
        _ memory: AccountMemory,
        kindRaw: String?,
        scope: [AccountMemoryScopeReference],
        conditionsText: String?,
        formationBasisRaw: String?,
        usePolicyRaw: String?,
        futureUseText: String?
    ) -> Bool {
        guard memory.isCurrentContract,
              memory.isHiddenByDefault == false,
              memory.targetKindRaw == kindRaw,
              memory.formationBasisRaw == formationBasisRaw,
              memory.usePolicyRaw == usePolicyRaw,
              normalizedOptionalText(memory.conditionsText) == normalizedOptionalText(conditionsText),
              normalizedOptionalText(memory.futureUseText) == normalizedOptionalText(futureUseText)
        else { return false }
        return normalizedScopeSet(memory.decodedScope()) == normalizedScopeSet(scope)
    }

    private static func normalizedScopeSet(
        _ scope: [AccountMemoryScopeReference]
    ) -> Set<AccountMemoryScopeReference> {
        Set(scope.compactMap { reference in
            guard let kind = trimmedNonEmpty(reference.kindRaw),
                  let value = trimmedNonEmpty(reference.value) else { return nil }
            return AccountMemoryScopeReference(kindRaw: kind, value: value)
        })
    }

    private static func normalizedOptionalText(_ value: String?) -> String? {
        guard let value = trimmedNonEmpty(value) else { return nil }
        return ConversationCurationKey.normalize(text: value)
    }

    /// Merges existing and incoming evidence, deduping by
    /// messageID + fieldSource + span text and keeping the higher-confidence
    /// reference when duplicates collide.
    private static func mergeEvidence(
        existing: [AccountMemoryEvidenceReference],
        incoming: [AccountMemoryEvidenceReference]
    ) -> [AccountMemoryEvidenceReference] {
        dedupedEvidence(existing + incoming)
    }

    private static func evidenceDedupKey(_ reference: AccountMemoryEvidenceReference) -> String {
        [
            reference.messageID.uuidString,
            reference.fieldSourceRaw,
            reference.spanText ?? ""
        ].joined(separator: "\u{1F}")
    }

    private static func dedupedEvidence(
        _ references: [AccountMemoryEvidenceReference]
    ) -> [AccountMemoryEvidenceReference] {
        var byKey: [String: AccountMemoryEvidenceReference] = [:]
        var order: [String] = []
        for reference in references {
            let key = evidenceDedupKey(reference)
            if let kept = byKey[key] {
                // Keep the richer / higher-confidence reference on collision.
                if reference.confidence > kept.confidence {
                    byKey[key] = reference
                }
            } else {
                byKey[key] = reference
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }
    }
}
