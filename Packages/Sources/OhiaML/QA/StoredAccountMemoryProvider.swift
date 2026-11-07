import Foundation
import OSLog
import SwiftData
import OhiaCore

private let askMemoryLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "ask-memory"
)

/// Shared query tokenization for memory retrieval. Latin-script tokens are
/// lowercased words of three or more characters; CJK runs additionally emit
/// character bigrams so Japanese / Chinese queries match memory text without
/// whitespace segmentation.
enum AskMemoryTokenizer {
    static let stopWords: Set<String> = [
        "about", "after", "again", "also", "answer", "anything", "are",
        "ask", "can", "could", "does", "for", "from", "have", "how",
        "into", "model", "our", "please", "should", "that", "the",
        "their", "then", "there", "this", "what", "when", "where", "which",
        "with", "would", "you", "your"
    ]

    static func tokenize(_ text: String, maxTokens: Int = 64) -> Set<String> {
        var tokens = Set<String>()
        let lowered = text.lowercased()
        let runs = lowered.split { character in
            !(character.isLetter || character.isNumber || character == "_" || character == "-")
        }
        for run in runs {
            guard tokens.count < maxTokens else { break }
            if run.contains(where: isCJK) {
                // Keep the full run for exact matches, then emit bigrams so
                // partial clause overlap still scores.
                if run.count >= 2 { tokens.insert(String(run)) }
                let characters = Array(run)
                for index in 0..<(max(0, characters.count - 1)) {
                    guard tokens.count < maxTokens else { break }
                    let bigram = String(characters[index...index + 1])
                    if bigram.contains(where: isCJK) { tokens.insert(bigram) }
                }
            } else if run.count >= 3 {
                tokens.insert(String(run))
            }
        }
        return tokens.subtracting(stopWords)
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)        // Hiragana + Katakana
                || (0x3400...0x4DBF).contains(scalar.value) // CJK ext A
                || (0x4E00...0x9FFF).contains(scalar.value) // CJK unified
                || (0xF900...0xFAFF).contains(scalar.value) // CJK compat
                || (0xAC00...0xD7AF).contains(scalar.value) // Hangul
        }
    }
}

/// `AskMemoryProvider` backed by the SwiftData `AccountMemory` projection —
/// the dreaming pipeline's output across all four dossier dimensions
/// (account, correspondent, classification, project).
///
/// Selection is deliberately selective rather than bulk: a memory enters the
/// prompt only when its dossier dimension is triggered by the query or the
/// active filter scope (a filtered sender matches a correspondent dossier,
/// query terms name a classification facet or project), or when its own text overlaps
/// the query. Account-dimension memories compete on text overlap and weight
/// alone. This keeps Ask grounding to a handful of relevant notes instead of
/// injecting a monolithic memory file.
public struct StoredAccountMemoryProvider: AskMemoryProvider {
    public struct Configuration: Sendable, Equatable {
        public var minimumScore: Double
        public var perSnippetCharacterLimit: Int

        public init(
            minimumScore: Double = 1,
            perSnippetCharacterLimit: Int = 520
        ) {
            self.minimumScore = minimumScore
            self.perSnippetCharacterLimit = perSnippetCharacterLimit
        }

        public static let `default` = Configuration()
    }

    private let container: ModelContainer
    private let configuration: Configuration

    public init(container: ModelContainer, configuration: Configuration = .default) {
        self.container = container
        self.configuration = configuration
    }

    public func context(
        for query: String,
        filter: FilterSpec,
        limit: AskMemoryLimit
    ) throws -> AskMemoryContext {
        try context(for: query, filter: filter, limit: limit, now: Date())
    }

    /// Test-injectable variant: `now` drives the recency decay so staleness
    /// boundary behaviour is deterministic.
    func context(
        for query: String,
        filter: FilterSpec,
        limit: AskMemoryLimit,
        now: Date
    ) throws -> AskMemoryContext {
        guard limit.maxSnippets > 0, limit.maxCharacters > 0 else { return .empty }
        // `allowedMessageIds` is a hard corpus boundary for focused Ask. A
        // durable dossier row may be supported by messages outside that set,
        // and this provider cannot prove otherwise from the filter alone, so
        // focused retrieval must fail closed rather than inject account-wide
        // guidance into a thread- or message-scoped answer.
        guard filter.allowedMessageIds == nil else { return .empty }

        let queryTerms = Self.queryTerms(for: query, filter: filter)
        guard queryTerms.isEmpty == false else { return .empty }
        let filterSenders = Set(filter.senderEmails.map(Self.normalizedAddress))

        let memories: [CandidateMemory]
        do {
            memories = try fetchCandidates(filter: filter, now: now)
        } catch {
            // The Ask flow degrades to an empty memory context on failure;
            // log so a broken store is diagnosable rather than silent.
            askMemoryLogger.warning("account memory fetch failed: \(String(reflecting: type(of: error)), privacy: .public)")
            throw error
        }
        guard memories.isEmpty == false else { return .empty }

        let scored = memories.compactMap { memory -> (memory: CandidateMemory, score: Double)? in
            guard let score = score(
                memory,
                queryTerms: queryTerms,
                filterSenders: filterSenders,
                now: now
            ), score >= configuration.minimumScore else { return nil }
            return (memory, score)
        }
        .sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.memory.text.localizedStandardCompare(right.memory.text) == .orderedAscending
        }

        var snippets: [AskMemorySnippet] = []
        var remaining = limit.maxCharacters
        for item in scored where snippets.count < limit.maxSnippets && remaining > 0 {
            let text = Self.singleLine(item.memory.text, limit: min(configuration.perSnippetCharacterLimit, remaining))
            guard text.isEmpty == false else { continue }
            let snippet = AskMemorySnippet(
                title: item.memory.title,
                text: text,
                source: item.memory.source,
                score: item.score,
                statusRaw: item.memory.statusRaw,
                kindRaw: item.memory.kindRaw,
                formationBasisRaw: item.memory.formationBasisRaw,
                usePolicyRaw: item.memory.usePolicyRaw,
                futureUseText: item.memory.futureUseText
            )
            snippets.append(snippet)
            remaining -= text.count + snippet.title.count + snippet.source.count + 16
        }
        return AskMemoryContext(snippets: snippets)
    }

    // MARK: - Candidates

    /// Value snapshot of an `AccountMemory` row so scoring happens on plain
    /// Sendable data after the ModelContext fetch completes.
    private struct CandidateMemory {
        let dimensionKind: String
        let dimensionValue: String
        let dimensionDisplayName: String
        let text: String
        let scope: [AccountMemoryScopeReference]
        let statusRaw: String
        let originRaw: String
        let kindRaw: String
        let formationBasisRaw: String
        let usePolicyRaw: String
        let futureUseText: String
        let weight: Double
        let lastSeenAt: Date

        var title: String {
            switch dimensionKind {
            case AccountMemoryDimension.correspondent:
                return "Memory — \(dimensionDisplayName)"
            case AccountMemoryDimension.classification:
                return "Memory — \(dimensionDisplayName) mail"
            case AccountMemoryDimension.project:
                return "Memory — \(dimensionDisplayName)"
            default:
                return "Account memory"
            }
        }

        var source: String {
            dimensionValue.isEmpty
                ? "memory:\(dimensionKind)"
                : "memory:\(dimensionKind):\(dimensionValue)"
        }
    }

    private func fetchCandidates(filter: FilterSpec, now: Date) throws -> [CandidateMemory] {
        let context = ModelContext(container)
        let accountIDs = Set(filter.accountIds)
        let rows = try context.fetch(FetchDescriptor<AccountMemory>())
        return rows.compactMap { memory -> CandidateMemory? in
            if accountIDs.isEmpty == false, accountIDs.contains(memory.accountID) == false {
                return nil
            }
            guard memory.isDurablePromptEligible else { return nil }
            guard memory.isSensitiveAndUnaffirmed == false else { return nil }
            // Recency gate: active generated guidance decays; confirmed
            // user-curated guidance remains durable.
            if memory.statusRaw != AccountMemoryProjectedStatus.confirmed,
               AccountMemoryDecay.isStale(lastSeenAt: memory.lastSeenAt, now: now) {
                return nil
            }
            // Temporal expiry: a fact past its stated end no longer grounds an
            // answer, mirroring the draft selector's gate.
            guard memory.isExpired(now: now) == false else { return nil }
            let text = memory.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { return nil }
            return CandidateMemory(
                dimensionKind: memory.dimensionKind,
                dimensionValue: memory.resolvedDimensionValue,
                dimensionDisplayName: memory.resolvedDimensionDisplayName,
                text: text,
                scope: memory.decodedScope(),
                statusRaw: memory.statusRaw,
                originRaw: memory.resolvedOrigin,
                kindRaw: memory.targetKindRaw,
                formationBasisRaw: memory.formationBasisRaw ?? "",
                usePolicyRaw: memory.usePolicyRaw ?? "",
                futureUseText: memory.futureUseText ?? "",
                weight: memory.weight,
                lastSeenAt: memory.lastSeenAt
            )
        }
    }

    // MARK: - Scoring

    /// Returns nil when the memory's dossier dimension is not triggered by
    /// the query or filter scope at all.
    private func score(
        _ memory: CandidateMemory,
        queryTerms: Set<String>,
        filterSenders: Set<String>,
        now: Date
    ) -> Double? {
        guard Self.scopeMatches(memory.scope, queryTerms: queryTerms, filterSenders: filterSenders) else {
            return nil
        }
        let searchText = ([memory.text, memory.dimensionDisplayName] + memory.scope.map(\.value))
            .joined(separator: " ")
            .lowercased()

        var termScore = 0.0
        for term in queryTerms where searchText.contains(term) {
            termScore += term.count >= 8 ? 2.0 : 1.0
        }
        termScore = min(termScore, 6.0)

        let dimensionBoost: Double
        switch memory.dimensionKind {
        case AccountMemoryDimension.correspondent:
            if filterSenders.contains(memory.dimensionValue) {
                dimensionBoost = 3.0
            } else if Self.matchesIdentity(memory: memory, queryTerms: queryTerms) {
                dimensionBoost = 2.0
            } else {
                return nil
            }
        case AccountMemoryDimension.classification:
            if Self.matchesIdentity(memory: memory, queryTerms: queryTerms) {
                dimensionBoost = 2.0
            } else if termScore >= 2 {
                // The memory text itself overlaps the query strongly even
                // though the classification facet wasn't mentioned.
                dimensionBoost = 0.5
            } else {
                return nil
            }
        case AccountMemoryDimension.project:
            if Self.matchesIdentity(memory: memory, queryTerms: queryTerms) {
                dimensionBoost = 2.5
            } else if termScore >= 2 {
                dimensionBoost = 0.5
            } else {
                return nil
            }
        default:
            // Account-wide memories have no dossier trigger; they earn a
            // place only through text overlap with the query. This is what
            // keeps Ask injection selective instead of bulk.
            guard termScore > 0 else { return nil }
            dimensionBoost = 1.0
        }

        var statusMultiplier: Double
        switch memory.statusRaw {
        case AccountMemoryProjectedStatus.confirmed: statusMultiplier = 1.25
        case AccountMemoryProjectedStatus.active: statusMultiplier = 1.0
        default: return nil
        }
        // Explicitly asserted claims (someone stated the fact) outrank inferred
        // ones at the same projected status.
        if memory.originRaw == AccountMemoryOrigin.explicit {
            statusMultiplier *= 1.1
        }

        let weightBlend = 0.5 + min(1, max(0, memory.weight)) / 2
        // Recency decay attenuates generated guidance; confirmed user-curated
        // guidance is exempt.
        let decay = memory.statusRaw == AccountMemoryProjectedStatus.confirmed
            ? 1.0
            : AccountMemoryDecay.factor(lastSeenAt: memory.lastSeenAt, now: now)
        let score = (dimensionBoost + termScore) * statusMultiplier * weightBlend * decay
        return score > 0 ? score : nil
    }

    /// Does the query name this dossier's value — the person, the classification facet,
    /// the project? Matches the dimension value and display-name tokens.
    private static func matchesIdentity(
        memory: CandidateMemory,
        queryTerms: Set<String>
    ) -> Bool {
        var displayTokens = AskMemoryTokenizer.tokenize(memory.dimensionDisplayName)
        var valueTokens = AskMemoryTokenizer.tokenize(memory.dimensionValue)
        if memory.dimensionKind == AccountMemoryDimension.correspondent {
            // Local part of the address ("sarah" in sarah@example.com).
            if let localPart = memory.dimensionValue.split(separator: "@").first,
               localPart.count >= 3 {
                valueTokens.insert(String(localPart))
            }
            displayTokens.formUnion(valueTokens)
            return displayTokens.isEmpty == false
                && displayTokens.isDisjoint(with: queryTerms) == false
        }
        // A project or classification is a complete applicability identity,
        // not a bag of trigger words. Accept either the full display name or
        // the full stored value, but never one shared token from a longer name.
        return [displayTokens, valueTokens].contains { tokens in
            tokens.isEmpty == false && tokens.isSubset(of: queryTerms)
        }
    }

    /// Scope constraints compose with the primary dossier. Correspondent
    /// scopes require an exact address from the caller's filter; project and
    /// classification scopes must be explicitly named by the query/filter.
    private static func scopeMatches(
        _ scope: [AccountMemoryScopeReference],
        queryTerms: Set<String>,
        filterSenders: Set<String>
    ) -> Bool {
        scope.allSatisfy { reference in
            let value = reference.value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch reference.kindRaw {
            case AccountMemoryDimension.account:
                return true
            case AccountMemoryDimension.correspondent:
                return filterSenders.contains(normalizedAddress(value))
            case AccountMemoryDimension.project, AccountMemoryDimension.classification:
                let scopeTerms = AskMemoryTokenizer.tokenize(value)
                return scopeTerms.isEmpty == false && scopeTerms.isSubset(of: queryTerms)
            default:
                return false
            }
        }
    }

    private static func queryTerms(for query: String, filter: FilterSpec) -> Set<String> {
        var terms = AskMemoryTokenizer.tokenize(query)
        for keyword in filter.keywords ?? [] {
            terms.formUnion(AskMemoryTokenizer.tokenize(keyword))
        }
        for sender in filter.senderEmails {
            terms.formUnion(AskMemoryTokenizer.tokenize(sender))
        }
        return terms
    }

    private static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func singleLine(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
