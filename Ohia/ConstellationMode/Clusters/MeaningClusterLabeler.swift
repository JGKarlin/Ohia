import Foundation
import OhiaCore
import OhiaML

/// One cluster's dual-line label: a semantic overview title above the
/// TF-IDF evidence terms that justify it. The title is a cached
/// presentation artifact for visible Meaning clusters, not an ingestion
/// stage and not a built-in classification facet.
struct MeaningClusterLabel: Sendable, Equatable {
    let clusterId: Int64
    let topTerms: [String]
    let weightedTerms: [MeaningClusterEvidenceTerm]
    let semanticTerms: [MeaningClusterEvidenceTerm]
    let semanticTitle: String?
    let titleConfidence: MeaningClusterTitleConfidence?
    let evidenceSignature: String?

    init(
        clusterId: Int64,
        topTerms: [String],
        weightedTerms: [MeaningClusterEvidenceTerm] = [],
        semanticTerms: [MeaningClusterEvidenceTerm] = [],
        semanticTitle: String? = nil,
        titleConfidence: MeaningClusterTitleConfidence? = nil,
        evidenceSignature: String? = nil
    ) {
        self.clusterId = clusterId
        self.topTerms = topTerms
        self.weightedTerms = weightedTerms
        self.semanticTerms = semanticTerms
        self.semanticTitle = semanticTitle
        self.titleConfidence = titleConfidence
        self.evidenceSignature = evidenceSignature
    }

    nonisolated var displayTitle: String? {
        guard let title = Self.cleanTitle(semanticTitle),
              !Self.isGenericPlaceholderTitle(title),
              !Self.matchesRawTerms(title, topTerms: topTerms) else {
            return nil
        }
        return title
    }

    nonisolated var fallbackTitle: String? {
        Self.fallbackTitle(from: topTerms)
    }

    private nonisolated static func cleanTitle(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func isGenericPlaceholderTitle(_ title: String) -> Bool {
        let normalized = comparableTokens(title).joined(separator: " ")
        return [
            "cluster",
            "email cluster",
            "emails cluster",
            "meaning",
            "meaning cluster",
            "message cluster",
            "messages cluster",
            "related email",
            "related emails",
            "related message",
            "related messages",
            "semantic cluster",
            "topic cluster"
        ].contains(normalized)
    }

    nonisolated static func fallbackTitle(from topTerms: [String]) -> String? {
        let terms = normalizedFallbackTerms(topTerms)
        guard !terms.isEmpty else { return nil }

        if let head = terms.first(where: { fallbackSemanticHeads.contains($0.normalized) }),
           let tail = terms.first(where: { fallbackDocumentTails.contains($0.normalized) }),
           head.normalized != tail.normalized {
            return titleCase([head.display, tail.display])
        }

        let selected = terms
            .filter { !fallbackSuppressedTerms.contains($0.normalized) }
            .prefix(3)
            .map(\.display)
        guard !selected.isEmpty else { return titleCase(terms.prefix(3).map(\.display)) }
        return titleCase(Array(selected))
    }

    nonisolated static func persistedLabelTerms(from label: String?) -> [String] {
        let components = label?
            .components(separatedBy: CharacterSet(charactersIn: "·,|"))
            .map { value in
                value
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
            } ?? []
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(components.count)
        for component in components {
            let normalized = comparableTokens(component).joined(separator: " ")
            guard !component.isEmpty,
                  !normalized.isEmpty,
                  !isGenericPlaceholderTitle(component),
                  !fallbackSuppressedTerms.contains(normalized),
                  seen.insert(normalized).inserted else {
                continue
            }
            result.append(component)
        }
        return result
    }

    nonisolated static func matchesRawTerms(_ title: String, topTerms: [String]) -> Bool {
        let titleTokens = comparableTokens(title)
        let rawTokens = topTerms.flatMap(comparableTokens)
        guard !titleTokens.isEmpty, !rawTokens.isEmpty else { return false }
        if titleTokens == rawTokens { return true }
        if titleTokens.count <= rawTokens.count,
           Array(rawTokens.prefix(titleTokens.count)) == titleTokens {
            return true
        }
        return false
    }

    private nonisolated static func comparableTokens(_ value: String) -> [String] {
        value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private struct FallbackTerm {
        let display: String
        let normalized: String
    }

    private nonisolated static let fallbackSemanticHeads: Set<String> = [
        "account",
        "application",
        "benefit",
        "billing",
        "booking",
        "calendar",
        "conference",
        "contract",
        "delivery",
        "expense",
        "finance",
        "flight",
        "health",
        "hotel",
        "insurance",
        "invoice",
        "legal",
        "meeting",
        "payment",
        "payroll",
        "receipt",
        "reservation",
        "security",
        "shipping",
        "subscription",
        "tax",
        "travel",
        "visa"
    ]

    private nonisolated static let fallbackDocumentTails: Set<String> = [
        "application",
        "document",
        "filing",
        "form",
        "invoice",
        "notice",
        "package",
        "receipt",
        "report",
        "statement",
        "summary"
    ]

    private nonisolated static let fallbackSuppressedTerms: Set<String> = [
        "email",
        "emails",
        "message",
        "messages",
        "notification",
        "notifications",
        "update",
        "updates"
    ]

    private nonisolated static let fallbackAcronyms: Set<String> = [
        "api",
        "dmv",
        "id",
        "irs",
        "llc",
        "pdf",
        "w2"
    ]

    private nonisolated static func normalizedFallbackTerms(_ rawTerms: [String]) -> [FallbackTerm] {
        var seen: Set<String> = []
        var terms: [FallbackTerm] = []
        terms.reserveCapacity(rawTerms.count)
        for rawTerm in rawTerms {
            let display = rawTerm
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            let normalized = comparableTokens(display).joined(separator: " ")
            guard !display.isEmpty,
                  !normalized.isEmpty,
                  !seen.contains(normalized) else {
                continue
            }
            seen.insert(normalized)
            terms.append(FallbackTerm(display: display, normalized: normalized))
        }
        return terms
    }

    private nonisolated static func titleCase(_ terms: [String]) -> String? {
        let title = terms
            .map(titleCaseTerm)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private nonisolated static func titleCaseTerm(_ term: String) -> String {
        term
            .split { !$0.isLetter && !$0.isNumber }
            .map { component in
                let lower = component.lowercased()
                if fallbackAcronyms.contains(lower) {
                    return lower.uppercased()
                }
                guard let first = lower.first else { return "" }
                return first.uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}

/// Keeps distinct embedding subregions legible when their generated semantic
/// titles happen to be identical. Evidence terms are presentation qualifiers,
/// not a second clustering rule; a stable ordinal is the last resort when the
/// available evidence cannot distinguish the duplicate titles honestly.
enum MeaningClusterTitleDisambiguator {
    nonisolated static func title(
        for clusterId: Int64,
        labelsByClusterId: [Int64: MeaningClusterLabel]
    ) -> String? {
        guard let label = labelsByClusterId[clusterId],
              let baseTitle = resolvedBaseTitle(for: label) else {
            return nil
        }
        let baseKey = normalized(baseTitle)
        let sameBase = labelsByClusterId.filter { _, candidate in
            resolvedBaseTitle(for: candidate).map(normalized) == baseKey
        }
        return titles(labelsByClusterId: sameBase)[clusterId]
    }

    /// Every titled cluster's disambiguated title in one pass: base titles
    /// resolve once, and qualifier evidence is gathered only inside groups
    /// that share a base title. A roster of N clusters therefore costs one
    /// linear pass instead of N separate scans of the whole roster.
    nonisolated static func titles(
        labelsByClusterId: [Int64: MeaningClusterLabel]
    ) -> [Int64: String] {
        var groups: [String: [(clusterId: Int64, label: MeaningClusterLabel, baseTitle: String)]] = [:]
        for (clusterId, label) in labelsByClusterId {
            guard let baseTitle = resolvedBaseTitle(for: label) else { continue }
            groups[normalized(baseTitle), default: []].append((clusterId, label, baseTitle))
        }

        var titles: [Int64: String] = [:]
        titles.reserveCapacity(labelsByClusterId.count)
        for members in groups.values {
            guard members.count > 1 else {
                if let only = members.first {
                    titles[only.clusterId] = only.baseTitle
                }
                continue
            }
            let duplicates = members.sorted { $0.clusterId < $1.clusterId }
            let qualifiersByMember = duplicates.map { member in
                qualifierCandidates(for: member.label, baseTitle: member.baseTitle)
            }
            var useCountByKey: [String: Int] = [:]
            for qualifiers in qualifiersByMember {
                for key in Set(qualifiers.map(\.key)) {
                    useCountByKey[key, default: 0] += 1
                }
            }
            for (ordinal, member) in duplicates.enumerated() {
                if let unique = qualifiersByMember[ordinal].first(where: { useCountByKey[$0.key] == 1 }) {
                    titles[member.clusterId] = "\(member.baseTitle) · \(unique.display)"
                } else {
                    titles[member.clusterId] = "\(member.baseTitle) · Group \(ordinal + 1)"
                }
            }
        }
        return titles
    }

    private struct Qualifier: Equatable {
        let key: String
        let display: String
    }

    private nonisolated static func resolvedBaseTitle(
        for label: MeaningClusterLabel
    ) -> String? {
        label.displayTitle ?? label.fallbackTitle
    }

    private nonisolated static func qualifierCandidates(
        for label: MeaningClusterLabel,
        baseTitle: String
    ) -> [Qualifier] {
        let baseTokens = Set(tokens(baseTitle))
        let evidence = label.semanticTerms.map(\.term)
            + label.weightedTerms.map(\.term)
            + label.topTerms
        var seen: Set<String> = []
        return evidence.compactMap { term in
            let key = normalized(term)
            let termTokens = Set(tokens(term))
            guard !key.isEmpty,
                  !termTokens.isSubset(of: baseTokens),
                  seen.insert(key).inserted else {
                return nil
            }
            let display = MeaningClusterLabel.fallbackTitle(from: [term]) ?? term
            return Qualifier(key: key, display: display)
        }
    }

    private nonisolated static func normalized(_ value: String) -> String {
        tokens(value).joined(separator: " ")
    }

    private nonisolated static func tokens(_ value: String) -> [String] {
        value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

private nonisolated struct MeaningClusterTitleEvidenceProfile: Codable, Sendable, Equatable {
    enum RefreshDecision: Equatable {
        case retain
        case regenerate
        case replace
    }

    let memberMessageIds: [String]
    let topTerms: [String]
    let semanticTerms: [String]
    let representativeMessageIds: [String]

    init(
        rows: [(messageId: String, row: MessageFilterRow)],
        input: MeaningClusterTitleInput
    ) {
        memberMessageIds = rows.map(\.messageId).sorted()
        topTerms = Self.normalized(input.weightedTerms.map(\.term))
        semanticTerms = Self.normalized(input.semanticTags.map(\.term))
        representativeMessageIds = input.samples.map(\.messageId).sorted()
    }

    private static func normalized(_ values: [String]) -> [String] {
        values
            .map {
                $0.lowercased()
                    .split { !$0.isLetter && !$0.isNumber }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
    }

    func refreshDecision(
        comparedWith previous: MeaningClusterTitleEvidenceProfile
    ) -> RefreshDecision {
        guard self != previous else { return .retain }

        let currentMembers = Set(memberMessageIds)
        let previousMembers = Set(previous.memberMessageIds)
        let membershipOverlap = Self.overlap(currentMembers, previousMembers)
        if !currentMembers.isEmpty,
           !previousMembers.isEmpty,
           membershipOverlap < 0.25 {
            // Cluster ids can be reused after a reset. Never surface a title
            // whose underlying membership no longer identifies this cluster.
            return .replace
        }

        let currentEvidence = Set(topTerms + semanticTerms)
        let previousEvidence = Set(previous.topTerms + previous.semanticTerms)
        let evidenceOverlap = Self.overlap(currentEvidence, previousEvidence)
        if currentMembers == previousMembers, evidenceOverlap < 0.4 {
            // The same messages were reinterpreted into fundamentally
            // different evidence. This is content correction, not ordinary
            // membership churn, so replace the stale title immediately.
            return .replace
        }

        let membershipChurn = currentMembers.symmetricDifference(previousMembers).count
        let membershipThreshold = max(
            5,
            Int(ceil(Double(max(previousMembers.count, 1)) * 0.10))
        )
        guard membershipChurn >= membershipThreshold else {
            return .retain
        }
        if evidenceOverlap < 0.4 {
            return .replace
        }

        let topTermOverlap = Self.overlap(Set(topTerms), Set(previous.topTerms))
        let semanticTermOverlap = Self.overlap(
            Set(semanticTerms),
            Set(previous.semanticTerms)
        )
        let representativeOverlap = Self.overlap(
            Set(representativeMessageIds),
            Set(previous.representativeMessageIds)
        )
        return topTermOverlap < 0.8
            || semanticTermOverlap < 0.75
            || representativeOverlap < 0.75
            ? .regenerate
            : .retain
    }

    private static func overlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        return Double(lhs.intersection(rhs).count) / Double(max(lhs.count, rhs.count))
    }
}

private struct MeaningClusterPersistedTitle: Codable, Sendable {
    let clusterId: Int64
    let title: String
    let confidence: String
    let evidence: MeaningClusterTitleEvidenceProfile
    let generatedAt: Date

    var generatedTitle: MeaningClusterGeneratedTitle? {
        guard let confidence = MeaningClusterTitleConfidence(rawValue: confidence) else {
            return nil
        }
        return MeaningClusterGeneratedTitle(title: title, confidence: confidence)
    }
}

private struct MeaningClusterTitleFailure: Codable, Sendable {
    let clusterId: Int64
    let evidence: MeaningClusterTitleEvidenceProfile
    let retryAfter: Date
}

private struct MeaningClusterTitleCacheDocument: Codable, Sendable {
    let titles: [MeaningClusterPersistedTitle]
    let failures: [MeaningClusterTitleFailure]
}

/// Title evidence for one cluster, derived from the message index off the
/// main actor and applied to the visible labels on it.
private nonisolated struct MeaningClusterEvidenceEntry: Sendable {
    let weightedTerms: [MeaningClusterEvidenceTerm]
    let input: MeaningClusterTitleInput
    let profile: MeaningClusterTitleEvidenceProfile
}

/// One complete evidence pass and the content fingerprint it was computed
/// from. A later request over identical cluster content reuses the pass
/// instead of re-running part-of-speech tagging over the whole corpus.
private nonisolated struct MeaningClusterEvidencePass: Sendable {
    let fingerprint: Int
    let entriesByClusterId: [Int64: MeaningClusterEvidenceEntry]
}

/// MainActor-owned labeler for the Meaning lens. TF-IDF evidence terms come
/// from an evidence pass that the live lens computes on the concurrent
/// executor (`scheduleUpdate`); `update` runs the same pass inline.
/// Qwen-first titles are generated asynchronously, one per visible cluster
/// evidence signature, with Apple Intelligence fallback, and cached so
/// refreshes do not keep asking the models for the same semantic overview.
@MainActor
@Observable
final class MeaningClusterLabeler {

    private static let titleCacheLimit = 256
    private static let failedTitleRetryDelay: TimeInterval = 6 * 60 * 60

    private static func isInReadingLanguage(_ title: String) -> Bool {
        DisplayLanguageGuard.needsResolution([title], targetLanguage: .ohiaPreferred()) == false
    }
    private static let defaultRegenerationDelay: TimeInterval = 5 * 60
    /// Title-model samples per cluster.
    private nonisolated static let representativeSampleLimit = 8
    /// TF-IDF reads the subjects and summaries of at most this many members
    /// per cluster, strongest Leiden attachment first. Core members carry a
    /// community's vocabulary; the bound keeps part-of-speech tagging for a
    /// very large community proportional to its core rather than its size.
    private nonisolated static let evidenceTextMemberLimit = 256

    private(set) var labelsByClusterId: [Int64: MeaningClusterLabel] = [:]

    private var persistedTitlesByClusterId: [Int64: MeaningClusterPersistedTitle] = [:]
    private var failuresByClusterId: [Int64: MeaningClusterTitleFailure] = [:]
    private var currentEvidenceByClusterId: [Int64: MeaningClusterTitleEvidenceProfile] = [:]
    private var titleTasksByClusterId: [Int64: Task<Void, Never>] = [:]
    private var titleTaskTokensByClusterId: [Int64: UUID] = [:]
    private var titleTaskEvidenceByClusterId: [Int64: MeaningClusterTitleEvidenceProfile] = [:]
    @ObservationIgnored private var evidencePass: MeaningClusterEvidencePass?
    @ObservationIgnored private var evidenceTask: Task<Void, Never>?
    @ObservationIgnored private var evidenceTaskToken: UUID?
    @ObservationIgnored private var pendingEvidenceRequest: EvidenceRequest?
    private let titleCacheURL: URL?
    private let regenerationDelay: TimeInterval

    private struct EvidenceRequest {
        let clusters: [ClusterRecord]
        let messageIndex: [String: MessageFilterRow]
        let titleGenerator: (any MeaningClusterTitleGenerating)?
        let titleGenerationClusterIds: Set<Int64>?
    }

    init(appPrivateRoot: URL) {
        titleCacheURL = Self.titleCacheURL(appPrivateRoot: appPrivateRoot)
        regenerationDelay = Self.defaultRegenerationDelay
        loadPersistedTitleCache()
    }

    init(titleCacheURL: URL?, regenerationDelay: TimeInterval = 0) {
        self.titleCacheURL = titleCacheURL
        self.regenerationDelay = max(regenerationDelay, 0)
        loadPersistedTitleCache()
    }

    private func loadPersistedTitleCache() {
        guard let titleCacheURL,
              let data = try? Data(contentsOf: titleCacheURL),
              let document = try? JSONDecoder().decode(
                  MeaningClusterTitleCacheDocument.self,
                  from: data
              ) else {
            return
        }
        for entry in document.titles where entry.generatedTitle != nil {
            persistedTitlesByClusterId[entry.clusterId] = entry
        }
        let now = Date()
        for failure in document.failures where failure.retryAfter > now {
            failuresByClusterId[failure.clusterId] = failure
        }
    }

    /// Reset visible labels. The durable per-cluster title cache intentionally
    /// survives lens switches; evidence drift decides when an entry is stale.
    func clear() {
        cancelEvidenceComputation()
        labelsByClusterId = [:]
        currentEvidenceByClusterId = [:]
        cancelTitleGenerationTasks(keeping: [])
    }

    /// Refresh labels for the given cluster set inline. This is a
    /// presentation update for the active Meaning lens, not part of
    /// ingestion. It supersedes any scheduled off-main refresh.
    func update(
        clusters: [ClusterRecord],
        messageIndex: [String: MessageFilterRow],
        titleGenerator: (any MeaningClusterTitleGenerating)?,
        titleGenerationClusterIds: Set<Int64>? = nil
    ) {
        cancelEvidenceComputation()
        guard let pass = Self.buildEvidencePass(
            clusters: clusters,
            messageIndex: messageIndex,
            reusing: evidencePass,
            checksCancellation: false
        ) else {
            return
        }
        evidencePass = pass
        apply(
            clusters: clusters,
            entries: pass.entriesByClusterId,
            titleGenerator: titleGenerator,
            titleGenerationClusterIds: titleGenerationClusterIds
        )
    }

    /// Off-main form of `update` for the live lens. The evidence pass —
    /// part-of-speech tagging over clustered subjects and summaries — runs
    /// on the concurrent executor, and an unchanged content fingerprint
    /// reuses the previous pass outright. Requests that arrive while a pass
    /// runs coalesce into one follow-up pass over the newest request, so
    /// labels always settle on the latest cluster set.
    func scheduleUpdate(
        clusters: [ClusterRecord],
        messageIndex: [String: MessageFilterRow],
        titleGenerator: (any MeaningClusterTitleGenerating)?,
        titleGenerationClusterIds: Set<Int64>? = nil
    ) {
        pendingEvidenceRequest = EvidenceRequest(
            clusters: clusters,
            messageIndex: messageIndex,
            titleGenerator: titleGenerator,
            titleGenerationClusterIds: titleGenerationClusterIds
        )
        guard evidenceTask == nil else { return }
        startPendingEvidenceComputation()
    }

    private func startPendingEvidenceComputation() {
        guard let request = pendingEvidenceRequest else { return }
        pendingEvidenceRequest = nil
        let token = UUID()
        let previous = evidencePass
        evidenceTaskToken = token
        evidenceTask = Task(priority: .utility) { [weak self] in
            let pass = await MeaningClusterLabeler.concurrentEvidencePass(
                clusters: request.clusters,
                messageIndex: request.messageIndex,
                reusing: previous
            )
            self?.finishEvidenceComputation(pass, request: request, token: token)
        }
    }

    private func finishEvidenceComputation(
        _ pass: MeaningClusterEvidencePass?,
        request: EvidenceRequest,
        token: UUID
    ) {
        guard evidenceTaskToken == token else { return }
        evidenceTask = nil
        evidenceTaskToken = nil
        if let pass {
            evidencePass = pass
            apply(
                clusters: request.clusters,
                entries: pass.entriesByClusterId,
                titleGenerator: request.titleGenerator,
                titleGenerationClusterIds: request.titleGenerationClusterIds
            )
        }
        startPendingEvidenceComputation()
    }

    private func cancelEvidenceComputation() {
        evidenceTask?.cancel()
        evidenceTask = nil
        evidenceTaskToken = nil
        pendingEvidenceRequest = nil
    }

    private func apply(
        clusters: [ClusterRecord],
        entries: [Int64: MeaningClusterEvidenceEntry],
        titleGenerator: (any MeaningClusterTitleGenerating)?,
        titleGenerationClusterIds: Set<Int64>?
    ) {
        var next: [Int64: MeaningClusterLabel] = [:]
        var nextEvidenceByClusterId: [Int64: MeaningClusterTitleEvidenceProfile] = [:]
        var pendingInputs: [(
            clusterId: Int64,
            input: MeaningClusterTitleInput,
            evidence: MeaningClusterTitleEvidenceProfile,
            delay: TimeInterval
        )] = []
        next.reserveCapacity(clusters.count)
        nextEvidenceByClusterId.reserveCapacity(clusters.count)
        pendingInputs.reserveCapacity(clusters.count)

        for cluster in clusters {
            guard let entry = entries[cluster.id] else { continue }
            let weightedTerms = entry.weightedTerms
            let input = entry.input
            let signature = input.evidenceSignature
            let evidence = entry.profile
            nextEvidenceByClusterId[cluster.id] = evidence
            let persistedTitle = persistedTitlesByClusterId[cluster.id]
            let refreshDecision = persistedTitle.map {
                evidence.refreshDecision(comparedWith: $0.evidence)
            }
            // A cached title left in another language than the reader's is
            // replaced, not shown.
            let cachedTitle = refreshDecision == .replace
                || persistedTitle.map({ !Self.isInReadingLanguage($0.title) }) == true
                ? nil
                : persistedTitle?.generatedTitle
            next[cluster.id] = MeaningClusterLabel(
                clusterId: cluster.id,
                topTerms: weightedTerms.map(\.term),
                weightedTerms: weightedTerms,
                semanticTerms: input.semanticTags,
                semanticTitle: cachedTitle?.title,
                titleConfidence: cachedTitle?.confidence,
                evidenceSignature: signature
            )
            let shouldGenerate = cachedTitle == nil || refreshDecision == .regenerate
            var isFailureBackoffActive = false
            if let failure = failuresByClusterId[cluster.id],
               failure.retryAfter > Date() {
                isFailureBackoffActive =
                    evidence.refreshDecision(comparedWith: failure.evidence) == .retain
            }
            if shouldGenerate,
               titleGenerationClusterIds?.contains(cluster.id) != false,
               input.hasGeneratableEvidence,
               !isFailureBackoffActive {
                pendingInputs.append((
                    clusterId: cluster.id,
                    input: input,
                    evidence: evidence,
                    delay: refreshDecision == .regenerate ? regenerationDelay : 0
                ))
            }
        }
        labelsByClusterId = next
        currentEvidenceByClusterId = nextEvidenceByClusterId

        let visibleClusterIds = Set(next.keys)
        if titleGenerator == nil {
            cancelTitleGenerationTasks(keeping: [])
            return
        }

        let eligibleClusterIds = titleGenerationClusterIds.map {
            visibleClusterIds.intersection($0)
        } ?? visibleClusterIds
        cancelTitleGenerationTasks(keeping: eligibleClusterIds)
        guard let titleGenerator else { return }
        for pending in pendingInputs {
            scheduleTitleGeneration(
                clusterId: pending.clusterId,
                input: pending.input,
                evidence: pending.evidence,
                delay: pending.delay,
                titleGenerator: titleGenerator
            )
        }
    }

    // MARK: - Async semantic title dispatch

    private func scheduleTitleGeneration(
        clusterId: Int64,
        input: MeaningClusterTitleInput,
        evidence: MeaningClusterTitleEvidenceProfile,
        delay: TimeInterval,
        titleGenerator: any MeaningClusterTitleGenerating
    ) {
        if let existingEvidence = titleTaskEvidenceByClusterId[clusterId],
           evidence.refreshDecision(comparedWith: existingEvidence) != .retain {
            titleTasksByClusterId[clusterId]?.cancel()
            titleTasksByClusterId[clusterId] = nil
            titleTaskTokensByClusterId[clusterId] = nil
            titleTaskEvidenceByClusterId[clusterId] = nil
        }
        guard titleTasksByClusterId[clusterId] == nil else { return }
        let token = UUID()
        titleTaskTokensByClusterId[clusterId] = token
        titleTaskEvidenceByClusterId[clusterId] = evidence

        let task = Task.detached(priority: .utility) {
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    await MainActor.run {
                        self.discardTitleGeneration(clusterId: clusterId, token: token)
                    }
                    return
                }
            }
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.discardTitleGeneration(clusterId: clusterId, token: token)
                }
                return
            }
            let generatedTitle = try? await titleGenerator.generateTitle(for: input)
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.discardTitleGeneration(clusterId: clusterId, token: token)
                }
                return
            }
            await MainActor.run {
                self.absorbGeneratedTitle(
                    clusterId: clusterId,
                    evidence: evidence,
                    generatedTitle: generatedTitle,
                    token: token
                )
            }
        }
        titleTasksByClusterId[clusterId] = task
    }

    private func absorbGeneratedTitle(
        clusterId: Int64,
        evidence: MeaningClusterTitleEvidenceProfile,
        generatedTitle: MeaningClusterGeneratedTitle?,
        token: UUID
    ) {
        guard titleTaskTokensByClusterId[clusterId] == token else { return }
        titleTasksByClusterId[clusterId] = nil
        titleTaskTokensByClusterId[clusterId] = nil
        titleTaskEvidenceByClusterId[clusterId] = nil
        guard let currentEvidence = currentEvidenceByClusterId[clusterId],
              currentEvidence.refreshDecision(comparedWith: evidence) == .retain else {
            return
        }
        guard let generatedTitle else {
            failuresByClusterId[clusterId] = MeaningClusterTitleFailure(
                clusterId: clusterId,
                evidence: evidence,
                retryAfter: Date().addingTimeInterval(Self.failedTitleRetryDelay)
            )
            persistTitleCache()
            return
        }
        storeCachedTitle(
            generatedTitle,
            clusterId: clusterId,
            evidence: evidence
        )
        failuresByClusterId[clusterId] = nil
        persistTitleCache()

        guard let existing = labelsByClusterId[clusterId] else { return }
        labelsByClusterId[clusterId] = MeaningClusterLabel(
            clusterId: existing.clusterId,
            topTerms: existing.topTerms,
            weightedTerms: existing.weightedTerms,
            semanticTerms: existing.semanticTerms,
            semanticTitle: generatedTitle.title,
            titleConfidence: generatedTitle.confidence,
            evidenceSignature: existing.evidenceSignature
        )
    }

    private func discardTitleGeneration(clusterId: Int64, token: UUID) {
        guard titleTaskTokensByClusterId[clusterId] == token else { return }
        titleTasksByClusterId[clusterId] = nil
        titleTaskTokensByClusterId[clusterId] = nil
        titleTaskEvidenceByClusterId[clusterId] = nil
    }

    private func cancelTitleGenerationTasks(keeping keptClusterIds: Set<Int64>) {
        let staleClusterIds = titleTasksByClusterId.keys.filter {
            !keptClusterIds.contains($0)
        }
        for clusterId in staleClusterIds {
            titleTasksByClusterId[clusterId]?.cancel()
            titleTasksByClusterId[clusterId] = nil
            titleTaskTokensByClusterId[clusterId] = nil
            titleTaskEvidenceByClusterId[clusterId] = nil
        }
    }

    private func storeCachedTitle(
        _ title: MeaningClusterGeneratedTitle,
        clusterId: Int64,
        evidence: MeaningClusterTitleEvidenceProfile
    ) {
        persistedTitlesByClusterId[clusterId] = MeaningClusterPersistedTitle(
            clusterId: clusterId,
            title: title.title,
            confidence: title.confidence.rawValue,
            evidence: evidence,
            generatedAt: Date()
        )
        while persistedTitlesByClusterId.count > Self.titleCacheLimit {
            guard let oldest = persistedTitlesByClusterId.values.min(by: {
                $0.generatedAt < $1.generatedAt
            }) else {
                break
            }
            persistedTitlesByClusterId[oldest.clusterId] = nil
        }
    }

    private func persistTitleCache() {
        guard let titleCacheURL else { return }
        let now = Date()
        failuresByClusterId = failuresByClusterId.filter {
            $0.value.retryAfter > now
        }
        if failuresByClusterId.count > Self.titleCacheLimit {
            let retained = failuresByClusterId
                .sorted { $0.value.retryAfter > $1.value.retryAfter }
                .prefix(Self.titleCacheLimit)
            var bounded: [Int64: MeaningClusterTitleFailure] = [:]
            bounded.reserveCapacity(Self.titleCacheLimit)
            for entry in retained {
                bounded[entry.key] = entry.value
            }
            failuresByClusterId = bounded
        }
        let document = MeaningClusterTitleCacheDocument(
            titles: persistedTitlesByClusterId.values.sorted {
                $0.generatedAt < $1.generatedAt
            },
            failures: Array(failuresByClusterId.values)
        )
        guard let data = try? JSONEncoder().encode(document) else { return }
        let directory = titleCacheURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: titleCacheURL, options: .atomic)
        } catch {
            // This is a disposable presentation cache. A write failure falls
            // back to the in-memory entries without blocking Meaning.
        }
    }

    private static func titleCacheURL(appPrivateRoot: URL) -> URL {
        appPrivateRoot
            .appendingPathComponent("meaning-cluster-titles-v1.json")
    }

    // MARK: - Evidence aggregation

    @concurrent
    private nonisolated static func concurrentEvidencePass(
        clusters: [ClusterRecord],
        messageIndex: [String: MessageFilterRow],
        reusing previous: MeaningClusterEvidencePass?
    ) async -> MeaningClusterEvidencePass? {
        buildEvidencePass(
            clusters: clusters,
            messageIndex: messageIndex,
            reusing: previous,
            checksCancellation: true
        )
    }

    /// Builds every cluster's title evidence. Returns `previous` unchanged
    /// when the cluster records and member content match its fingerprint,
    /// and `nil` only when `checksCancellation` observes a cancelled task.
    private nonisolated static func buildEvidencePass(
        clusters: [ClusterRecord],
        messageIndex: [String: MessageFilterRow],
        reusing previous: MeaningClusterEvidencePass?,
        checksCancellation: Bool
    ) -> MeaningClusterEvidencePass? {
        let rowsByCluster = attachmentOrderedRowsByCluster(
            clusters: clusters,
            messageIndex: messageIndex
        )
        let fingerprint = evidenceFingerprint(clusters: clusters, rowsByCluster: rowsByCluster)
        if let previous, previous.fingerprint == fingerprint {
            return previous
        }
        if checksCancellation, Task.isCancelled { return nil }
        let textPerCluster = buildTextPerCluster(rowsByCluster: rowsByCluster)
        if checksCancellation, Task.isCancelled { return nil }
        let topTermsByCluster = ClusterTopTerms.scoredTopTerms(
            textPerCluster: textPerCluster,
            terms: 5,
            minimumTerms: 3
        )
        if checksCancellation, Task.isCancelled { return nil }

        var entries: [Int64: MeaningClusterEvidenceEntry] = [:]
        entries.reserveCapacity(clusters.count)
        for cluster in clusters {
            let rows = rowsByCluster[cluster.id] ?? []
            let computedTerms = evidenceTerms(from: topTermsByCluster[cluster.id] ?? [])
            let weightedTerms = computedTerms.isEmpty
                ? evidenceTerms(fromPersistedLabel: cluster.label)
                : computedTerms
            let input = MeaningClusterTitleInput(
                memberCount: cluster.memberCount,
                weightedTerms: weightedTerms,
                semanticTags: semanticEvidenceTerms(in: rows.map(\.row)),
                samples: representativeSamples(from: rows, limit: representativeSampleLimit)
            )
            entries[cluster.id] = MeaningClusterEvidenceEntry(
                weightedTerms: weightedTerms,
                input: input,
                profile: MeaningClusterTitleEvidenceProfile(rows: rows, input: input)
            )
        }
        return MeaningClusterEvidencePass(
            fingerprint: fingerprint,
            entriesByClusterId: entries
        )
    }

    /// Clustered rows grouped by cluster, strongest Leiden attachment first.
    /// Rows without a persisted weight count as fully attached, matching the
    /// planner's member-halo convention; ties keep ascending message id, so
    /// the order is deterministic for every input.
    private nonisolated static func attachmentOrderedRowsByCluster(
        clusters: [ClusterRecord],
        messageIndex: [String: MessageFilterRow]
    ) -> [Int64: [(messageId: String, row: MessageFilterRow)]] {
        let validIds = Set(clusters.map(\.id))
        var rowsByCluster: [Int64: [(messageId: String, row: MessageFilterRow)]] = [:]
        rowsByCluster.reserveCapacity(validIds.count)
        for (messageId, row) in messageIndex {
            guard let clusterId = row.clusterId, validIds.contains(clusterId) else {
                continue
            }
            rowsByCluster[clusterId, default: []].append((messageId, row))
        }
        for clusterId in Array(rowsByCluster.keys) {
            rowsByCluster[clusterId]?.sort { lhs, rhs in
                let lhsWeight = lhs.row.clusterWeight ?? 1
                let rhsWeight = rhs.row.clusterWeight ?? 1
                if lhsWeight != rhsWeight { return lhsWeight > rhsWeight }
                return lhs.messageId < rhs.messageId
            }
        }
        return rowsByCluster
    }

    /// Hash of everything an evidence pass reads: cluster identity, size,
    /// and persisted label, plus each member's id, subject, summary,
    /// attachment weight, and canonical tags. Equal fingerprints within one
    /// process mean the pass would reproduce the previous result exactly.
    private nonisolated static func evidenceFingerprint(
        clusters: [ClusterRecord],
        rowsByCluster: [Int64: [(messageId: String, row: MessageFilterRow)]]
    ) -> Int {
        var hasher = Hasher()
        for cluster in clusters.sorted(by: { $0.id < $1.id }) {
            hasher.combine(cluster.id)
            hasher.combine(cluster.memberCount)
            hasher.combine(cluster.label)
            let rows = rowsByCluster[cluster.id] ?? []
            hasher.combine(rows.count)
            for entry in rows {
                hasher.combine(entry.messageId)
                hasher.combine(entry.row.subject)
                hasher.combine(entry.row.bodySummary)
                hasher.combine(entry.row.clusterWeight)
                let tags = entry.row.dimensions?.semanticTags ?? []
                hasher.combine(tags.count)
                for tag in tags {
                    hasher.combine(tag.tagID)
                    hasher.combine(tag.displayName)
                    hasher.combine(tag.weightedScore)
                }
            }
        }
        return hasher.finalize()
    }

    private nonisolated static func buildTextPerCluster(
        rowsByCluster: [Int64: [(messageId: String, row: MessageFilterRow)]]
    ) -> [Int64: String] {
        var result: [Int64: String] = [:]
        result.reserveCapacity(rowsByCluster.count)
        for (clusterId, rows) in rowsByCluster {
            let textRows = rows.prefix(evidenceTextMemberLimit)
            var bucket: [String] = []
            bucket.reserveCapacity(textRows.count * 2)
            for entry in textRows {
                if !entry.row.subject.isEmpty { bucket.append(entry.row.subject) }
                if let summary = entry.row.bodySummary, !summary.isEmpty { bucket.append(summary) }
            }
            result[clusterId] = bucket.joined(separator: "\n")
        }
        return result
    }

    private nonisolated static func evidenceTerms(from terms: [ClusterTopTerm]) -> [MeaningClusterEvidenceTerm] {
        terms
            .map { MeaningClusterEvidenceTerm(term: $0.term, weight: Double($0.normalizedWeight)) }
            .filter { !$0.term.isEmpty }
    }

    private nonisolated static func evidenceTerms(fromPersistedLabel label: String?) -> [MeaningClusterEvidenceTerm] {
        let terms = MeaningClusterLabel.persistedLabelTerms(from: label)
        guard !terms.isEmpty else { return [] }
        return terms.enumerated().map { index, term in
            MeaningClusterEvidenceTerm(
                term: term,
                weight: max(0.35, 1 - Double(index) * 0.15)
            )
        }
    }

    /// Title-model samples from the cluster's core: `rows` arrive strongest
    /// attachment first, and each reply or forward chain contributes once
    /// before any subject repeats, so one long thread cannot occupy every
    /// slot the model reads.
    private nonisolated static func representativeSamples(
        from rows: [(messageId: String, row: MessageFilterRow)],
        limit: Int
    ) -> [MeaningClusterEvidenceSample] {
        var samples: [MeaningClusterEvidenceSample] = []
        samples.reserveCapacity(limit)
        // Rows whose subject repeats an earlier sample's are held back and
        // fill any slots left after every distinct subject is used, so a
        // template-subject cluster (receipts, notices) still yields `limit`
        // samples whose summaries differ.
        var repeatedSubjectSamples: [MeaningClusterEvidenceSample] = []
        var seenSubjectKeys: Set<String> = []
        for entry in rows {
            let subject = entry.row.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = entry.row.bodySummary?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty || !(summary?.isEmpty ?? true) else { continue }
            let sample = MeaningClusterEvidenceSample(
                messageId: entry.messageId,
                subject: subject,
                summary: summary
            )
            let subjectKey = sampleSubjectKey(subject)
            if !subjectKey.isEmpty, !seenSubjectKeys.insert(subjectKey).inserted {
                if repeatedSubjectSamples.count < limit {
                    repeatedSubjectSamples.append(sample)
                }
                continue
            }
            samples.append(sample)
            if samples.count >= limit { break }
        }
        if samples.count < limit {
            samples.append(contentsOf: repeatedSubjectSamples.prefix(limit - samples.count))
        }
        return samples
    }

    /// Case- and punctuation-folded subject with leading reply and forward
    /// markers removed, so `Re: Fwd: Budget` and `Budget` share one key.
    private nonisolated static func sampleSubjectKey(_ subject: String) -> String {
        var tokens = subject
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        while let first = tokens.first, replyForwardMarkers.contains(first) {
            tokens.removeFirst()
        }
        return tokens.joined(separator: " ")
    }

    private nonisolated static let replyForwardMarkers: Set<String> = [
        "aw",
        "fw",
        "fwd",
        "re",
        "sv",
        "tr",
        "wg"
    ]

    private nonisolated static func semanticEvidenceTerms(
        in rows: [MessageFilterRow]
    ) -> [MeaningClusterEvidenceTerm] {
        var scores: [String: (display: String, score: Double)] = [:]
        for row in rows {
            guard let dimensions = row.dimensions else { continue }
            addSemanticTags(dimensions.semanticTags, to: &scores)
        }

        let sorted = scores.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.display < rhs.display
        }
        let topScore = sorted.first?.score ?? 0
        guard topScore > 0 else { return [] }
        return sorted.prefix(8).map { entry in
            MeaningClusterEvidenceTerm(
                term: entry.display,
                weight: entry.score / topScore
            )
        }
    }

    private nonisolated static func addSemanticTags(
        _ tags: [SemanticTagProjection],
        to scores: inout [String: (display: String, score: Double)]
    ) {
        for tag in SemanticTagProjectionPresentation.canonical(tags) {
            let display = tag.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !display.isEmpty,
                  !ignoredSemanticEvidence.contains(display.lowercased()) else {
                continue
            }
            let key = tag.tagID.uuidString.lowercased()
            var entry = scores[key] ?? (display: display, score: 0)
            entry.score += tag.weightedScore
            scores[key] = entry
        }
    }

    private nonisolated static let ignoredSemanticEvidence: Set<String> = [
        "misc",
        "miscellaneous",
        "none",
        "other",
        "unassigned",
        "unknown"
    ]
}
