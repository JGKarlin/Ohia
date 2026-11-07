import Foundation
import OhiaCore

/// Retained as a source-compatibility shim for callers created under the old
/// claim-ledger contract. Durable-memory admission is now universal; scope
/// never changes the definition gate.
public enum MemoryPromotionStrictness: Sendable, Equatable {
    case standard
    case strict
}

/// End-to-end assembly of a Conversation Memory snapshot from
/// per-message inputs. Pure / synchronous over already-prepared data so
/// the data controller can run it off-main inside a single task. The
/// scheduler invokes this once after the seed stage and again after the
/// LLM pass has produced refined per-message records.
public struct ConversationMemoryAssembler: Sendable {
    public let claimWeighting: ClaimWeightingEngine
    public let contradictionDetector: ContradictionDetector
    public let crossThreadMiner: CrossThreadMemoryMiner
    public let sensitivityGate: SensitivityGate
    public let curationApplier: ConversationCurationApplier
    public let openLoopAssembler: OpenLoopAssembler
    public let ibisGraphBuilder: IBISGraphBuilder
    public let threadAdjacencyAnalyzer: ThreadAdjacencyAnalyzer

    public init(
        claimWeighting: ClaimWeightingEngine = ClaimWeightingEngine(),
        contradictionDetector: ContradictionDetector = ContradictionDetector(),
        crossThreadMiner: CrossThreadMemoryMiner = CrossThreadMemoryMiner(),
        sensitivityGate: SensitivityGate = SensitivityGate(),
        curationApplier: ConversationCurationApplier = ConversationCurationApplier(),
        openLoopAssembler: OpenLoopAssembler = OpenLoopAssembler(),
        ibisGraphBuilder: IBISGraphBuilder = IBISGraphBuilder(),
        threadAdjacencyAnalyzer: ThreadAdjacencyAnalyzer = ThreadAdjacencyAnalyzer(),
        promotionStrictness: MemoryPromotionStrictness = .standard
    ) {
        self.claimWeighting = claimWeighting
        self.contradictionDetector = contradictionDetector
        self.crossThreadMiner = crossThreadMiner
        self.sensitivityGate = sensitivityGate
        _ = promotionStrictness
        self.curationApplier = curationApplier
        self.openLoopAssembler = openLoopAssembler
        self.ibisGraphBuilder = ibisGraphBuilder
        self.threadAdjacencyAnalyzer = threadAdjacencyAnalyzer
    }

    public func assemble(input: ConversationMemoryAssemblyInput) -> ConversationMemoryAssemblyOutput {
        do {
            return try assemble(input: input, shouldCancel: { false })
        } catch {
            preconditionFailure("Unexpected cancellation in non-cancellable assembly")
        }
    }

    public func assemble(
        input: ConversationMemoryAssemblyInput,
        shouldCancel: @Sendable () -> Bool
    ) throws -> ConversationMemoryAssemblyOutput {
        // 1. Bucket messages by thread.
        var threadsByID: [UUID?: [ThreadMessageInput]] = [:]
        for (index, record) in input.records.enumerated() {
            if index.isMultiple(of: 64) { try checkCancellation(shouldCancel) }
            threadsByID[record.event.threadID, default: []].append(
                ThreadMessageInput(event: record.event, memory: record.memory)
            )
        }
        let threadInputs: [ThreadInput] = threadsByID.map { id, msgs in
            ThreadInput(threadID: id, messages: msgs)
        }

        // 2. Thread-level adjacency.
        var threadResults: [ThreadAdjacencyResult] = []
        threadResults.reserveCapacity(threadInputs.count)
        for (index, threadInput) in threadInputs.enumerated() {
            if index.isMultiple(of: 32) { try checkCancellation(shouldCancel) }
            threadResults.append(threadAdjacencyAnalyzer.analyze(threadInput))
        }

        // 3. IBIS graph.
        let graph = try ibisGraphBuilder.build(
            input: IBISGraphInput(threads: threadResults, activeScope: input.activeScope),
            shouldCancel: shouldCancel
        )

        // 4. Memory-card claims synthesized from raw per-message candidates.
        try checkCancellation(shouldCancel)
        let preliminaryClaims = coalesceRedundantClaims(
            aggregateClaims(
                records: input.records,
                activeScope: input.activeScope,
                now: input.now
            )
        )

        // 5. Cross-thread mining (precedent, tacit-rule, supersession).
        try checkCancellation(shouldCancel)
        let crossInput = CrossThreadInput(
            events: input.records.map(\.event),
            messageMemory: Dictionary(uniqueKeysWithValues: input.records.map { ($0.event.messageID, $0.memory) }),
            languageByMessage: input.languageByMessage
        )
        let crossResult = crossThreadMiner.mine(input: crossInput)

        // 6. Contradiction detection on the assembled claims + supersession signals.
        try checkCancellation(shouldCancel)
        let languageByClaim: [String: String?] = Dictionary(
            preliminaryClaims.map { ($0.key, nil) },
            uniquingKeysWith: { first, _ in first }
        )
        let contradictionResult = contradictionDetector.detect(
            claims: preliminaryClaims,
            supersessions: crossResult.supersessions,
            languageByClaim: languageByClaim
        )

        // 7. Fold contradiction state back into claims, then re-weight.
        try checkCancellation(shouldCancel)
        let claimsWithContradictionState = preliminaryClaims.map { claim -> KnowledgeClaim in
            let state = contradictionResult.statesByKey[claim.key] ?? .clean
            return KnowledgeClaim(
                id: claim.id,
                key: claim.key,
                text: claim.text,
                status: ClaimStatusBundle(
                    extractionConfidence: claim.status.extractionConfidence,
                    evidenceStrength: claim.status.evidenceStrength,
                    userConfirmation: claim.status.userConfirmation,
                    contradictionState: state,
                    sensitivityRisk: claim.status.sensitivityRisk
                ),
                weight: claim.weight,
                scope: claim.scope,
                firstSeen: claim.firstSeen,
                lastAffirmed: claim.lastAffirmed,
                evidenceCount: claim.evidenceCount,
                evidenceLinks: claim.evidenceLinks,
                sourceParticipants: claim.sourceParticipants,
                contradictionKeys: contradictionResult.links
                    .filter { $0.olderClaimKey == claim.key || $0.newerClaimKey == claim.key }
                    .map { $0.olderClaimKey == claim.key ? $0.newerClaimKey : $0.olderClaimKey },
                kindRaw: claim.kindRaw,
                subjectText: claim.subjectText,
                assertedBy: claim.assertedBy,
                directionRaw: claim.directionRaw,
                originRaw: claim.originRaw,
                asOf: claim.asOf,
                expiresAt: claim.expiresAt,
                conditionsText: claim.conditionsText,
                futureUseText: claim.futureUseText,
                formationBasisRaw: claim.formationBasisRaw,
                usePolicyRaw: claim.usePolicyRaw
            )
        }

        // 8. Apply user curation verdicts.
        try checkCancellation(shouldCancel)
        let curated = curationApplier.apply(
            actions: input.curationActions,
            claims: claimsWithContradictionState,
            precedents: crossResult.precedents,
            tacitRules: crossResult.tacitRules,
            issues: graph.issues,
            decisions: graph.decisions
        )

        // 9. Open Loops.
        try checkCancellation(shouldCancel)
        let openLoops = openLoopAssembler.assemble(
            input: OpenLoopInput(
                threads: threadResults,
                claims: curated.claims,
                issues: curated.issues,
                arguments: graph.arguments,
                decisions: curated.decisions,
                contradictions: contradictionResult.links
            )
        )

        // 10. Final claim sort by weight.
        try checkCancellation(shouldCancel)
        let rankedClaims = curated.claims.sorted { $0.weight > $1.weight }
        let rankedPrecedents = curated.precedents.sorted { $0.applicabilityScore > $1.applicabilityScore }
        let rankedTacit = curated.tacitRules.sorted { $0.confidence > $1.confidence }

        let evidenceIndex = buildEvidenceIndex(
            claims: rankedClaims,
            precedents: rankedPrecedents,
            tacitRules: rankedTacit,
            issues: curated.issues,
            decisions: curated.decisions
        )

        return ConversationMemoryAssemblyOutput(
            events: input.records.map(\.event),
            issues: curated.issues,
            arguments: graph.arguments,
            decisions: curated.decisions,
            claims: rankedClaims,
            precedents: rankedPrecedents,
            tacitRules: rankedTacit,
            contradictions: contradictionResult.links,
            supersessions: crossResult.supersessions,
            openLoops: openLoops,
            evidenceIndex: evidenceIndex,
            hitCrossThreadBudget: crossResult.hitBudget
        )
    }

    /// Ungated, clustered candidate evidence for the MemoryDistiller. Wraps the
    /// same aggregation `assemble` uses, exposed as `CandidateCluster`s ranked by weight.
    public func candidateClusters(input: ConversationMemoryAssemblyInput) -> [MemoryDistiller.CandidateCluster] {
        Self.buildClusters(from: coalescedRankedClaims(input: input))
    }

    /// Clustered candidate evidence PLUS the deterministic contradiction state
    /// per claim and the supersession edges (older → newer) mined across the same
    /// batch. The durable distiller path uses this so the persisted dossier can
    /// record "newer replaced older" and "this is contested" — not just the live
    /// `.conversations` Ask snapshot, which is the only place those edges survived
    /// before. Same aggregation as `candidateClusters`; additionally runs the
    /// cross-thread miner + contradiction detector that the full `assemble` runs.
    public func candidateClustersWithEdges(
        input: ConversationMemoryAssemblyInput
    ) -> MemoryDistiller.CandidateClustersWithEdges {
        let claims = coalescedRankedClaims(input: input)
        let clusters = Self.buildClusters(from: claims)

        let crossInput = CrossThreadInput(
            events: input.records.map(\.event),
            messageMemory: Dictionary(
                uniqueKeysWithValues: input.records.map { ($0.event.messageID, $0.memory) }
            ),
            languageByMessage: input.languageByMessage
        )
        let crossResult = crossThreadMiner.mine(input: crossInput)
        let languageByClaim: [String: String?] = Dictionary(
            claims.map { ($0.key, nil) },
            uniquingKeysWith: { first, _ in first }
        )
        let contradictionResult = contradictionDetector.detect(
            claims: claims,
            supersessions: crossResult.supersessions,
            languageByClaim: languageByClaim
        )

        let stateByKey = contradictionResult.statesByKey.mapValues { $0.rawValue }
        let claimByKey = Dictionary(claims.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let edges: [MemoryDistiller.SupersessionEdge] = crossResult.supersessions.compactMap { record in
            guard let olderClaim = claimByKey[record.olderClaimKey],
                  let newerClaim = claimByKey[record.newerClaimKey],
                  let olderKind = olderClaim.kindRaw,
                  let newerKind = newerClaim.kindRaw else { return nil }
            let olderNorm = ConversationCurationKey.normalize(text: olderClaim.text)
            let newerNorm = ConversationCurationKey.normalize(text: newerClaim.text)
            guard !olderNorm.isEmpty, !newerNorm.isEmpty, olderNorm != newerNorm else { return nil }
            return MemoryDistiller.SupersessionEdge(
                olderNormalizedText: olderNorm,
                olderKindRaw: olderKind,
                olderScope: olderClaim.scope,
                newerNormalizedText: newerNorm,
                newerKindRaw: newerKind,
                newerScope: newerClaim.scope
            )
        }

        return MemoryDistiller.CandidateClustersWithEdges(
            clusters: clusters,
            contradictionStateByClaimKey: stateByKey,
            supersessionEdges: edges
        )
    }

    private func coalescedRankedClaims(input: ConversationMemoryAssemblyInput) -> [KnowledgeClaim] {
        let coalesced = coalesceRedundantClaims(
            aggregateClaims(records: input.records, activeScope: input.activeScope, now: input.now)
        )
        let curated = curationApplier.apply(
            actions: input.curationActions,
            claims: coalesced,
            precedents: [],
            tacitRules: [],
            issues: [],
            decisions: []
        )
        return curated.claims
            .filter { claim in
                switch claim.status.userConfirmation {
                case .rejected, .weakened, .markedStale:
                    return false
                case .none, .confirmed:
                    return true
                }
            }
            .sorted { $0.weight > $1.weight }
    }

    private static func buildClusters(from claims: [KnowledgeClaim]) -> [MemoryDistiller.CandidateCluster] {
        claims.enumerated().map { idx, claim in
            MemoryDistiller.CandidateCluster(
                index: idx + 1,
                text: claim.text,
                supportingMessageCount: claim.evidenceCount,
                distinctThreadCount: Set(claim.evidenceLinks.map { $0.threadID ?? $0.messageID }).count,
                newestEvidenceAt: claim.lastAffirmed,
                claim: claim)
        }
    }

    private func checkCancellation(_ shouldCancel: @Sendable () -> Bool) throws {
        if shouldCancel() {
            throw CancellationError()
        }
    }

    // MARK: - Claim aggregation

    private func aggregateClaims(
        records: [ConversationMemoryRecord],
        activeScope: [ScopeHint],
        now: Date
    ) -> [KnowledgeClaim] {
        struct ClaimBucket {
            var text: String
            var supportingMessages: [UUID]
            var contentHashes: [String]
            var participants: Set<String>
            var threads: Set<UUID>
            var evidenceLinks: [EvidenceLink]
            var firstSeen: Date
            var lastAffirmed: Date
            var maxConfidence: Double
            var scope: Set<ScopeHint>
            var sensitivity: SensitivityRisk
            var replyApprovals: Int
            var signOffs: Int
            var acknowledgements: Int
            var attachmentEvidence: Int
            var hasRepeatedPatternSupport: Bool
            var hasLLMDirectExtraction: Bool
            var hasEvidenceSpan: Bool
            // Structured-field aggregation (Task 7). Newest-anchor policy for
            // kindRaw/subjectText/asOf/expiresAt/conditionsText: whichever
            // contributing candidate has the newest event timestamp wins.
            var fieldsAnchorTimestamp: Date
            var kindRaw: String?
            var subjectText: String?
            var asOf: Date?
            var expiresAt: Date?
            var conditionsText: String?
            var futureUseText: String?
            var formationBasisRaw: String?
            var usePolicyRaw: String?
            var admissionCandidate: ClaimCandidate
            // originRaw: explicit if ANY contributor is explicitly stated.
            var hasExplicitContributor: Bool
            // directionRaw: sent/received when uniform across contributing
            // events, else mixed.
            var directionFlags: Set<Bool>
            // assertedBy: uniform value across non-nil contributors, else nil.
            var assertedByVotes: Set<String>
        }

        var buckets: [String: ClaimBucket] = [:]

        for record in records {
            let memory = record.memory
            let event = record.event
            for candidate in memory.claimCandidates {
                // Structural pre-filter (language-neutral; replaces retired keyword gate).
                let trimmedText = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedText.isEmpty == false else { continue }
                guard candidate.support.qualifiesAsCandidate else { continue }
                switch candidate.sourceField {
                case .triageAcknowledgementSummary, .triageAcknowledgementFacts:
                    continue
                case .llmDirectExtraction:
                    guard candidate.confidence >= 0.6 else { continue }
                    guard candidate.evidenceSpans.isEmpty == false else { continue }
                default:
                    break
                }
                guard MemoryEvidencePreFilter.isTransactionalAtom(trimmedText) == false else { continue }
                let candidateScope = memory.scopeHints + candidate.scope
                let normalizedText = ConversationCurationKey.normalize(text: candidate.text)
                let scopeFingerprint = ConversationCurationKey.makeScopeFingerprint(candidateScope)
                // Same text about different subjects stays separate — a bucket
                // is keyed on (text, subject, scope), not text+scope alone.
                let bucketKey = [
                    normalizedText,
                    candidate.subjectText ?? "",
                    scopeFingerprint,
                    candidate.kindRaw ?? "",
                    ConversationCurationKey.normalize(text: candidate.conditionsText ?? ""),
                    ConversationCurationKey.normalize(text: candidate.futureUseText ?? ""),
                    candidate.formationBasisRaw ?? "",
                    candidate.usePolicyRaw ?? ""
                ].joined(separator: "\u{1F}")
                let sensitivity = sensitivityGate.evaluate(SensitivityEvidence(
                    claimText: candidate.text,
                    evidenceTexts: candidate.evidenceSpans.map(\.text),
                    triageSignalKind: record.triageVerdict?.acknowledgement?.signalKind,
                    purpose: purpose(from: event.classificationHints),
                    senderAddress: event.fromAddress
                ))

                let links = candidate.evidenceSpans.map { span in
                    EvidenceLink(
                        messageID: event.messageID,
                        threadID: event.threadID,
                        fieldSource: candidate.sourceField,
                        span: span,
                        confidence: candidate.confidence,
                        timestamp: event.timestamp
                    )
                }

                if var existing = buckets[bucketKey] {
                    existing.supportingMessages.append(event.messageID)
                    if let hash = record.contentHash { existing.contentHashes.append(hash) }
                    existing.participants.insert(event.fromAddress)
                    existing.threads.insert(event.threadID ?? event.messageID)
                    existing.evidenceLinks.append(contentsOf: links)
                    existing.firstSeen = min(existing.firstSeen, event.timestamp)
                    existing.lastAffirmed = max(existing.lastAffirmed, event.timestamp)
                    existing.maxConfidence = max(existing.maxConfidence, candidate.confidence)
                    for hint in candidateScope { existing.scope.insert(hint) }
                    if sensitivity.risk.rank > existing.sensitivity.rank {
                        existing.sensitivity = sensitivity.risk
                    }
                    existing.attachmentEvidence += event.attachmentCount > 0 ? 1 : 0
                    if candidate.support == .repeatedPattern {
                        existing.hasRepeatedPatternSupport = true
                    }
                    if candidate.sourceField == .llmDirectExtraction {
                        existing.hasLLMDirectExtraction = true
                    }
                    if candidate.evidenceSpans.isEmpty == false {
                        existing.hasEvidenceSpan = true
                    }
                    if event.timestamp >= existing.fieldsAnchorTimestamp {
                        existing.fieldsAnchorTimestamp = event.timestamp
                        existing.kindRaw = candidate.kindRaw
                        existing.subjectText = candidate.subjectText
                        existing.asOf = candidate.asOf
                        existing.expiresAt = candidate.expiresAt
                        existing.conditionsText = candidate.conditionsText
                        existing.futureUseText = candidate.futureUseText
                        existing.formationBasisRaw = candidate.formationBasisRaw
                        existing.usePolicyRaw = candidate.usePolicyRaw
                        existing.admissionCandidate = candidate
                    }
                    if candidate.support == .explicitlyStated {
                        existing.hasExplicitContributor = true
                    }
                    existing.directionFlags.insert(event.isSentByUser)
                    if let assertedBy = candidate.assertedBy {
                        existing.assertedByVotes.insert(assertedBy)
                    }
                    buckets[bucketKey] = existing
                } else {
                    var bucket = ClaimBucket(
                        text: candidate.text,
                        supportingMessages: [event.messageID],
                        contentHashes: record.contentHash.map { [$0] } ?? [],
                        participants: [event.fromAddress],
                        threads: [event.threadID ?? event.messageID],
                        evidenceLinks: links,
                        firstSeen: event.timestamp,
                        lastAffirmed: event.timestamp,
                        maxConfidence: candidate.confidence,
                        scope: Set(candidateScope),
                        sensitivity: sensitivity.risk,
                        replyApprovals: 0,
                        signOffs: 0,
                        acknowledgements: 0,
                        attachmentEvidence: event.attachmentCount > 0 ? 1 : 0,
                        hasRepeatedPatternSupport: candidate.support == .repeatedPattern,
                        hasLLMDirectExtraction: candidate.sourceField == .llmDirectExtraction,
                        hasEvidenceSpan: candidate.evidenceSpans.isEmpty == false,
                        fieldsAnchorTimestamp: event.timestamp,
                        kindRaw: candidate.kindRaw,
                        subjectText: candidate.subjectText,
                        asOf: candidate.asOf,
                        expiresAt: candidate.expiresAt,
                        conditionsText: candidate.conditionsText,
                        futureUseText: candidate.futureUseText,
                        formationBasisRaw: candidate.formationBasisRaw,
                        usePolicyRaw: candidate.usePolicyRaw,
                        admissionCandidate: candidate,
                        hasExplicitContributor: candidate.support == .explicitlyStated,
                        directionFlags: [event.isSentByUser],
                        assertedByVotes: candidate.assertedBy.map { [$0] } ?? []
                    )
                    // Tally affirmations from the seed moves on the
                    // record so the weighting engine has real signal.
                    for move in memory.discourseMoves {
                        switch move.kind {
                        case .approval:        bucket.replyApprovals += 1
                        case .acknowledgement: bucket.acknowledgements += 1
                        default:               continue
                        }
                    }
                    if record.triageVerdict?.action?.kind == .signOff {
                        bucket.signOffs += 1
                    }
                    buckets[bucketKey] = bucket
                }
            }
        }

        var claims: [KnowledgeClaim] = []
        for (_, bucket) in buckets {
            guard DurableMemoryAdmission.evaluate(
                candidate: bucket.admissionCandidate,
                supportingMessageCount: bucket.supportingMessages.count,
                distinctThreadCount: bucket.threads.count
            ).isAccepted else {
                continue
            }
            let synthesizedText = bucket.text
            let components = ConversationCurationKey.make(
                text: synthesizedText,
                kind: .claim,
                scopeFingerprint: ConversationCurationKey.makeDurableClaimScopeFingerprint(
                    scope: Array(bucket.scope),
                    kindRaw: bucket.kindRaw,
                    subjectText: bucket.subjectText,
                    conditionsText: bucket.conditionsText,
                    futureUseText: bucket.futureUseText,
                    formationBasisRaw: bucket.formationBasisRaw,
                    usePolicyRaw: bucket.usePolicyRaw
                ),
                extractionVersion: DiscourseMemory.qwenVersion,
                supportingMessageContentHashes: bucket.contentHashes
            )
            let key = components.targetKey
            let sensitivityVerdict = SensitivityVerdict(risk: bucket.sensitivity)
            let weight = claimWeighting.weight(
                for: ClaimWeightInput(
                    extractionConfidence: bucket.maxConfidence,
                    lastAffirmed: bucket.lastAffirmed,
                    now: now,
                    replyApprovalCount: bucket.replyApprovals,
                    signOffCount: bucket.signOffs,
                    acknowledgementCount: bucket.acknowledgements,
                    distinctThreadCount: bucket.threads.count,
                    distinctParticipantCount: bucket.participants.count,
                    supportingMessageCount: bucket.supportingMessages.count,
                    attachmentEvidenceCount: bucket.attachmentEvidence,
                    familiarity: 0.5,
                    relationshipScore: 0.5,
                    resolutionState: .open,
                    claimScope: Array(bucket.scope),
                    activeScope: activeScope,
                    contradictionState: .clean,
                    userConfirmation: .none,
                    sensitivity: sensitivityVerdict
                )
            )
            let originRaw = bucket.hasExplicitContributor
                ? AccountMemoryOrigin.explicit
                : AccountMemoryOrigin.inferred
            let directionRaw: String
            if bucket.directionFlags.count == 1, let onlyFlag = bucket.directionFlags.first {
                directionRaw = onlyFlag ? AccountMemoryDirection.sent : AccountMemoryDirection.received
            } else {
                directionRaw = AccountMemoryDirection.mixed
            }
            let assertedBy: String? = bucket.assertedByVotes.count == 1 ? bucket.assertedByVotes.first : nil
            claims.append(
                KnowledgeClaim(
                    key: key,
                    text: synthesizedText,
                    status: weight.status,
                    weight: weight.weight,
                    scope: Array(bucket.scope),
                    firstSeen: bucket.firstSeen,
                    lastAffirmed: bucket.lastAffirmed,
                    evidenceCount: bucket.supportingMessages.count,
                    evidenceLinks: bucket.evidenceLinks,
                    sourceParticipants: Array(bucket.participants),
                    contradictionKeys: [],
                    kindRaw: bucket.kindRaw,
                    subjectText: bucket.subjectText,
                    assertedBy: assertedBy,
                    directionRaw: directionRaw,
                    originRaw: originRaw,
                    asOf: bucket.asOf,
                    expiresAt: bucket.expiresAt,
                    conditionsText: bucket.conditionsText,
                    futureUseText: bucket.futureUseText,
                    formationBasisRaw: bucket.formationBasisRaw,
                    usePolicyRaw: bucket.usePolicyRaw
                )
            )
        }
        return claims
    }

    private func coalesceRedundantClaims(_ claims: [KnowledgeClaim]) -> [KnowledgeClaim] {
        var coalesced: [KnowledgeClaim] = []
        for claim in claims.sorted(by: { $0.weight > $1.weight }) {
            if let index = coalesced.firstIndex(where: { areRedundantMemoryClaims($0, claim) }) {
                coalesced[index] = mergeRedundantMemoryClaims(coalesced[index], claim)
            } else {
                coalesced.append(claim)
            }
        }
        return coalesced
    }

    private func areRedundantMemoryClaims(_ lhs: KnowledgeClaim, _ rhs: KnowledgeClaim) -> Bool {
        guard durableMemoryApplicabilityMatches(lhs, rhs) else { return false }

        // Subject-aware guard: byte-identical (or near-identical) claim text
        // about two DIFFERENT non-nil subjects must never merge, even
        // through the exact-text fast path below — otherwise the
        // subjectText-aware bucket key in `aggregateClaims` gets defeated at
        // the coalesce stage. Both sides missing a subject, one side
        // missing, or equal normalized subjects all fall through unchanged.
        if let lhsSubject = lhs.subjectText, let rhsSubject = rhs.subjectText {
            let lhsNormalizedSubject = ConversationCurationKey.normalize(text: lhsSubject)
            let rhsNormalizedSubject = ConversationCurationKey.normalize(text: rhsSubject)
            if lhsNormalizedSubject.isEmpty == false,
               rhsNormalizedSubject.isEmpty == false,
               lhsNormalizedSubject != rhsNormalizedSubject {
                return false
            }
        }

        let left = canonicalMemoryText(lhs.text)
        let right = canonicalMemoryText(rhs.text)
        guard left.isEmpty == false, right.isEmpty == false else { return false }
        if left == right { return true }

        let leftWords = Set(left.split(separator: " ").map(String.init))
        let rightWords = Set(right.split(separator: " ").map(String.init))
        let intersection = leftWords.intersection(rightWords)
        let overlap = Double(intersection.count) / Double(max(1, min(leftWords.count, rightWords.count)))
        if overlap >= 0.8,
           hasMeaningfulScopeOverlap(lhs.scope, rhs.scope) {
            return true
        }

        if left.contains(right) || right.contains(left) {
            return hasMeaningfulScopeOverlap(lhs.scope, rhs.scope)
        }
        return false
    }

    /// Text similarity is only a dedup signal after the complete durable-memory
    /// applicability contract agrees. Merging across any of these fields would
    /// broaden or silently change when the resulting guidance applies.
    private func durableMemoryApplicabilityMatches(_ lhs: KnowledgeClaim, _ rhs: KnowledgeClaim) -> Bool {
        guard lhs.kindRaw == rhs.kindRaw,
              lhs.formationBasisRaw == rhs.formationBasisRaw,
              lhs.usePolicyRaw == rhs.usePolicyRaw,
              normalizedOptionalMemoryText(lhs.subjectText) == normalizedOptionalMemoryText(rhs.subjectText),
              normalizedOptionalMemoryText(lhs.conditionsText) == normalizedOptionalMemoryText(rhs.conditionsText),
              normalizedOptionalMemoryText(lhs.futureUseText) == normalizedOptionalMemoryText(rhs.futureUseText),
              normalizedScopeComponents(lhs.scope) == normalizedScopeComponents(rhs.scope) else {
            return false
        }
        return true
    }

    private func normalizedOptionalMemoryText(_ text: String?) -> String {
        guard let text else { return "" }
        return ConversationCurationKey.normalize(text: text)
    }

    private func normalizedScopeComponents(_ scope: [ScopeHint]) -> Set<String> {
        Set(scope.map { hint in
            [
                hint.kind.rawValue,
                ConversationCurationKey.normalize(text: hint.value)
            ].joined(separator: "\u{1F}")
        })
    }

    private func mergeRedundantMemoryClaims(_ lhs: KnowledgeClaim, _ rhs: KnowledgeClaim) -> KnowledgeClaim {
        let primary = betterDisplayClaim(lhs, rhs)
        let secondary = primary.id == lhs.id ? rhs : lhs
        let evidenceLinks = uniqueEvidenceLinks(primary.evidenceLinks + secondary.evidenceLinks)
        let sourceParticipants = Array(Set(primary.sourceParticipants + secondary.sourceParticipants)).sorted()
        let scope = Array(Set(primary.scope + secondary.scope)).sorted { left, right in
            if left.kind.rawValue != right.kind.rawValue { return left.kind.rawValue < right.kind.rawValue }
            return left.value < right.value
        }
        let sensitivityRisk = primary.status.sensitivityRisk.rank >= secondary.status.sensitivityRisk.rank
            ? primary.status.sensitivityRisk
            : secondary.status.sensitivityRisk
        return KnowledgeClaim(
            id: primary.id,
            key: primary.key,
            text: primary.text,
            status: ClaimStatusBundle(
                extractionConfidence: primary.status.extractionConfidence,
                evidenceStrength: primary.status.evidenceStrength,
                userConfirmation: primary.status.userConfirmation,
                contradictionState: primary.status.contradictionState,
                sensitivityRisk: sensitivityRisk
            ),
            weight: max(primary.weight, secondary.weight),
            scope: scope,
            firstSeen: min(primary.firstSeen, secondary.firstSeen),
            lastAffirmed: max(primary.lastAffirmed, secondary.lastAffirmed),
            evidenceCount: Set(evidenceLinks.map(\.messageID)).count,
            evidenceLinks: evidenceLinks,
            sourceParticipants: sourceParticipants,
            contradictionKeys: Array(Set(primary.contradictionKeys + secondary.contradictionKeys)).sorted(),
            kindRaw: primary.kindRaw,
            subjectText: primary.subjectText,
            assertedBy: primary.assertedBy,
            directionRaw: mergedDirectionRaw(primary.directionRaw, secondary.directionRaw),
            originRaw: mergedOriginRaw(primary.originRaw, secondary.originRaw),
            asOf: primary.asOf,
            expiresAt: primary.expiresAt,
            conditionsText: primary.conditionsText,
            futureUseText: primary.futureUseText,
            formationBasisRaw: primary.formationBasisRaw,
            usePolicyRaw: primary.usePolicyRaw
        )
    }

    /// Merge policy for `originRaw`: the primary claim's value wins unless
    /// either side is explicitly stated, in which case explicit wins.
    private func mergedOriginRaw(_ primary: String?, _ secondary: String?) -> String? {
        if primary == AccountMemoryOrigin.explicit || secondary == AccountMemoryOrigin.explicit {
            return AccountMemoryOrigin.explicit
        }
        return primary
    }

    /// Merge policy for `directionRaw`: the primary claim's value wins when
    /// both sides agree or only one side has a value; disagreement between
    /// two non-nil values collapses to "mixed".
    private func mergedDirectionRaw(_ primary: String?, _ secondary: String?) -> String? {
        switch (primary, secondary) {
        case let (lhs?, rhs?):
            return lhs == rhs ? lhs : AccountMemoryDirection.mixed
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private func betterDisplayClaim(_ lhs: KnowledgeClaim, _ rhs: KnowledgeClaim) -> KnowledgeClaim {
        // Prefer the claim with more scope hints — it is more specifically contextualized.
        if lhs.scope.count != rhs.scope.count {
            return lhs.scope.count > rhs.scope.count ? lhs : rhs
        }
        // Among equally-scoped variants, prefer the longer (more informative) text.
        let lengthDelta = lhs.text.count - rhs.text.count
        if abs(lengthDelta) >= 12 {
            return lengthDelta > 0 ? lhs : rhs
        }
        if lhs.evidenceCount != rhs.evidenceCount {
            return lhs.evidenceCount > rhs.evidenceCount ? lhs : rhs
        }
        return lhs.text.count >= rhs.text.count ? lhs : rhs
    }

    private func uniqueEvidenceLinks(_ links: [EvidenceLink]) -> [EvidenceLink] {
        var seen = Set<String>()
        var output: [EvidenceLink] = []
        for link in links.sorted(by: { $0.timestamp < $1.timestamp }) {
            let key = [
                link.messageID.uuidString,
                link.fieldSource.rawValue,
                link.span?.text ?? ""
            ].joined(separator: "\u{1F}")
            if seen.insert(key).inserted {
                output.append(link)
            }
        }
        return output
    }

    private func hasMeaningfulScopeOverlap(_ lhs: [ScopeHint], _ rhs: [ScopeHint]) -> Bool {
        let left = Set(lhs.filter { $0.kind != .classification })
        let right = Set(rhs.filter { $0.kind != .classification })
        if left.isEmpty || right.isEmpty { return true }
        return left.isDisjoint(with: right) == false
    }

    private func canonicalMemoryText(_ text: String) -> String {
        ConversationCurationKey.normalize(text: text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    private func buildEvidenceIndex(
        claims: [KnowledgeClaim],
        precedents: [Precedent],
        tacitRules: [TacitRule],
        issues: [IssueNode],
        decisions: [DecisionNode]
    ) -> [String: [EvidenceLink]] {
        var index: [String: [EvidenceLink]] = [:]
        for claim in claims { index[claim.key] = claim.evidenceLinks }
        for precedent in precedents { index[precedent.key] = precedent.evidenceLinks }
        for rule in tacitRules { index[rule.key] = rule.evidenceLinks }
        for issue in issues {
            index[issue.key] = issue.evidenceMessageIDs.map { messageID in
                EvidenceLink(
                    messageID: messageID,
                    fieldSource: .threadContext,
                    span: nil,
                    confidence: 0.6,
                    timestamp: issue.lastActive
                )
            }
        }
        for decision in decisions { index[decision.key] = decision.evidenceLinks }
        return index
    }

    private func purpose(from classificationHints: [String]) -> MailPurpose? {
        classificationHints.lazy.compactMap { hint in
            guard hint.hasPrefix("purpose.") else { return nil }
            return MailPurpose(rawValue: String(hint.dropFirst("purpose.".count)))
        }.first
    }
}

public struct ConversationMemoryRecord: Sendable {
    public let event: ConversationEvent
    public let memory: DiscourseMemory
    public let dimensions: MessageDimensions?
    public let triageVerdict: TriageVerdict?
    public let contentHash: String?
    public let language: String?

    public init(
        event: ConversationEvent,
        memory: DiscourseMemory,
        dimensions: MessageDimensions?,
        triageVerdict: TriageVerdict?,
        contentHash: String?,
        language: String?
    ) {
        self.event = event
        self.memory = memory
        self.dimensions = dimensions
        self.triageVerdict = triageVerdict
        self.contentHash = contentHash
        self.language = language
    }
}

public struct ConversationMemoryAssemblyInput: @unchecked Sendable {
    public let records: [ConversationMemoryRecord]
    // SwiftData @Model class — only ever read on the ModelContext-owning actor.
    public let curationActions: [ConversationCurationAction]
    public let activeScope: [ScopeHint]
    public let languageByMessage: [UUID: String?]
    public let now: Date

    public init(
        records: [ConversationMemoryRecord],
        curationActions: [ConversationCurationAction],
        activeScope: [ScopeHint],
        languageByMessage: [UUID: String?],
        now: Date = .now
    ) {
        self.records = records
        self.curationActions = curationActions
        self.activeScope = activeScope
        self.languageByMessage = languageByMessage
        self.now = now
    }
}

public struct ConversationMemoryAssemblyOutput: Sendable {
    public let events: [ConversationEvent]
    public let issues: [IssueNode]
    public let arguments: [ArgumentNode]
    public let decisions: [DecisionNode]
    public let claims: [KnowledgeClaim]
    public let precedents: [Precedent]
    public let tacitRules: [TacitRule]
    public let contradictions: [ContradictionLink]
    public let supersessions: [SupersessionRecord]
    public let openLoops: [OpenLoopRow]
    public let evidenceIndex: [String: [EvidenceLink]]
    public let hitCrossThreadBudget: Bool
}
