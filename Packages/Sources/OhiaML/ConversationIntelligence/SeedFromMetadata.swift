import Foundation
import OhiaCore

/// Deterministic synchronous extractor — runs *before* the LLM pass and
/// produces baseline `DiscourseMemory` records from the existing analyzer
/// outputs (`TriageVerdict`, `MessageDimensions`, summaries). The whole
/// pipeline starts here so the Conversation Memory workspace renders
/// non-empty memory on cold cache, with the LLM pass refining the result
/// asynchronously per §4 of the implementation plan.
///
/// Inputs are values, not models — keeps this trivially testable and
/// safely call-from-anywhere.
public struct SeedFromMetadata: Sendable {
    public init() {}

    public func seed(input: SeedInput) -> DiscourseMemory {
        var moves: [DiscourseMove] = []
        var ibis: [IBISRoleAssignment] = []
        var claims: [ClaimCandidate] = []
        var decisions: [DecisionCandidate] = []
        let precedents: [PrecedentSignal] = []
        var tacitRules: [TacitRuleSignal] = []
        let contradictions: [ContradictionSignal] = []
        let supersessions: [SupersessionSignal] = []
        var scope: [ScopeHint] = []
        var uncertainties: [Uncertainty] = []

        scope.append(contentsOf: scopeHints(from: input))

        if let verdict = input.triageVerdict {
            ingestTriage(
                verdict: verdict,
                speaker: input.fromAddress,
                isSentByUser: input.isSentByUser,
                moves: &moves,
                ibis: &ibis,
                claims: &claims,
                decisions: &decisions,
                uncertainties: &uncertainties,
                scope: scope
            )
        }

        if let dimensions = input.dimensions {
            ingestDimensions(
                dimensions: dimensions,
                speaker: input.fromAddress,
                isSentByUser: input.isSentByUser,
                moves: &moves,
                ibis: &ibis,
                tacitRules: &tacitRules,
                scope: scope
            )
        }

        if let summary = input.bodySummary, !summary.isEmpty {
            // Sent-mail summaries often contain durable account-owner
            // preferences before the LLM pass has refined the message. Seed
            // those as conservative, evidenced candidates so Settings is not
            // blank on first run; the Qwen dream pass can amend them later.
            if claims.isEmpty && decisions.isEmpty {
                if input.isSentByUser, isDurableAccountOwnerSummary(summary) {
                    claims.append(
                        ClaimCandidate(
                            text: summary,
                            support: .stronglyImplied,
                            confidence: 0.64,
                            evidenceSpans: [
                                DiscourseEvidenceSpan(
                                    start: 0,
                                    end: summary.count,
                                    text: summary
                                )
                            ],
                            scope: scope,
                            sourceField: .bodySummary
                        )
                    )
                } else {
                    uncertainties.append(
                        Uncertainty(
                            question: "Does this summary contain a durable claim?",
                            candidate: summary,
                            sourceField: .bodySummary
                        )
                    )
                }
            }
        }

        return DiscourseMemory(
            discourseMoves: moves,
            ibisRoles: ibis,
            claimCandidates: claims,
            decisionCandidates: decisions,
            precedentSignals: precedents,
            tacitRuleSignals: tacitRules,
            contradictionSignals: contradictions,
            supersessionSignals: supersessions,
            scopeHints: scope,
            uncertainties: uncertainties,
            extractionVersion: DiscourseMemory.seedVersion
        )
    }

    // MARK: - Inputs

    public struct SeedInput: Sendable {
        public let messageID: UUID
        public let isSentByUser: Bool
        public let fromAddress: String
        public let classificationHints: [String]
        public let semanticTagLabels: [String]
        public let bodySummary: String?
        public let dimensions: MessageDimensions?
        public let triageVerdict: TriageVerdict?

        public init(
            messageID: UUID,
            isSentByUser: Bool,
            fromAddress: String,
            classificationHints: [String],
            semanticTagLabels: [String],
            bodySummary: String?,
            dimensions: MessageDimensions?,
            triageVerdict: TriageVerdict?
        ) {
            self.messageID = messageID
            self.isSentByUser = isSentByUser
            self.fromAddress = fromAddress
            self.classificationHints = classificationHints
            self.semanticTagLabels = semanticTagLabels
            self.bodySummary = bodySummary
            self.dimensions = dimensions
            self.triageVerdict = triageVerdict
        }
    }

    // MARK: - Triage ingest

    private func ingestTriage(
        verdict: TriageVerdict,
        speaker: String,
        isSentByUser: Bool,
        moves: inout [DiscourseMove],
        ibis: inout [IBISRoleAssignment],
        claims: inout [ClaimCandidate],
        decisions: inout [DecisionCandidate],
        uncertainties: inout [Uncertainty],
        scope: [ScopeHint]
    ) {
        let confidence = max(0.4, verdict.confidence)

        if verdict.isActionable, let action = verdict.action {
            let kind: SpeechActKind
            switch action.kind {
            case .makeDecision:
                kind = .question // a decision request opens an issue
            case .signOff:
                kind = .request
            case .provideInformation:
                kind = .request
            case .reply:
                kind = .request
            case .scheduleMeeting:
                kind = .request
            case .review:
                kind = .request
            case .other:
                kind = .request
            }

            moves.append(
                DiscourseMove(
                    kind: kind,
                    speaker: speaker,
                    target: targetLabel(for: action.directedAt),
                    support: .explicitlyStated,
                    confidence: confidence,
                    sourceField: .triageActionSummary
                )
            )

            switch action.kind {
            case .makeDecision, .signOff:
                ibis.append(
                    IBISRoleAssignment(
                        role: .issue,
                        text: action.summary,
                        support: .explicitlyStated,
                        confidence: confidence
                    )
                )
                if action.kind == .signOff {
                    // A sign-off request anchors a forthcoming decision —
                    // promote it to a decision candidate seeded from the
                    // request itself.
                    decisions.append(
                        DecisionCandidate(
                            text: action.summary,
                            decider: targetLabel(for: action.directedAt),
                            support: .stronglyImplied,
                            confidence: confidence,
                            resolvedIssueText: action.summary,
                            sourceField: .triageActionSummary
                        )
                    )
                }
            default:
                ibis.append(
                    IBISRoleAssignment(
                        role: .position,
                        text: action.summary,
                        support: .stronglyImplied,
                        confidence: confidence
                    )
                )
            }

            for input in action.decisionInputs {
                ibis.append(
                    IBISRoleAssignment(
                        role: .unresolvedQuestion,
                        text: input,
                        support: .explicitlyStated,
                        confidence: confidence
                    )
                )
                uncertainties.append(
                    Uncertainty(
                        question: input,
                        candidate: action.summary,
                        sourceField: .triageActionInputs
                    )
                )
            }
        }

        if verdict.requiresConfirmation, let ack = verdict.acknowledgement {
            moves.append(
                DiscourseMove(
                    kind: .acknowledgement,
                    speaker: speaker,
                    evidenceSpan: ack.evidenceSpans.first.map(DiscourseEvidenceSpan.init(from:)),
                    support: .explicitlyStated,
                    confidence: confidence,
                    sourceField: .triageAcknowledgementSummary
                )
            )
        }

        // Sent-by-user adjustments — when the user is the speaker, an
        // actionable verdict means *they* committed; treat it as a
        // commitment move from the user toward the recipient.
        if isSentByUser, verdict.isActionable, let action = verdict.action {
            moves.append(
                DiscourseMove(
                    kind: .commitment,
                    speaker: speaker,
                    target: targetLabel(for: action.directedAt),
                    support: .stronglyImplied,
                    confidence: confidence,
                    sourceField: .triageActionSummary
                )
            )
        }
    }

    // MARK: - Dimensions ingest

    private func ingestDimensions(
        dimensions: MessageDimensions,
        speaker: String,
        isSentByUser: Bool,
        moves: inout [DiscourseMove],
        ibis: inout [IBISRoleAssignment],
        tacitRules: inout [TacitRuleSignal],
        scope: [ScopeHint]
    ) {
        for task in dimensions.tasks {
            ibis.append(
                IBISRoleAssignment(
                    role: .dependency,
                    text: task.actionObject ?? task.taskType,
                    evidenceSpan: task.evidenceSpans.first.map(DiscourseEvidenceSpan.init(from:)),
                    support: .stronglyImplied,
                    confidence: task.confidence
                )
            )
        }

        for deadline in dimensions.deadlines {
            ibis.append(
                IBISRoleAssignment(
                    role: .constraint,
                    text: deadline.dateString,
                    evidenceSpan: deadline.evidenceSpan.map(DiscourseEvidenceSpan.init(from:)),
                    support: .explicitlyStated,
                    confidence: deadline.confidence
                )
            )
        }

        // Explicit norm language carried via tone/register/canonical tags is
        // detected later by `CrossThreadMemoryMiner`; here we only seed the
        // obvious case where interpretation emits a norm-tagged value.
        // Suppressed when the message is sent by
        // the user (we don't auto-induce tacit rules from the user's
        // own outgoing language).
        if !isSentByUser {
            for tag in dimensions.semanticTags where tag.displayName.lowercased().contains("usually") {
                tacitRules.append(
                    TacitRuleSignal(
                        rule: tag.displayName,
                        pattern: .explicitNormLanguage,
                        support: .stronglyImplied,
                        confidence: tag.confidence,
                        evidenceSpans: [],
                        sourceField: .dimensionsTone
                    )
                )
            }
        }
    }

    private func isDurableAccountOwnerSummary(_ summary: String) -> Bool {
        let folded = summary
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let durableTerms = [
            "prefers", "preference", "likes", "dislikes", "wants to proceed",
            "wants", "chooses", "chose", "selected", "modern", "style",
            "writing", "concise", "direct", "clear next steps"
        ]
        let ephemeralTerms = [
            "order #", "receipt", "invoice", "tracking", "delivered",
            "shipped", "subscription", "verification code"
        ]
        return durableTerms.contains { folded.contains($0) }
            && ephemeralTerms.contains { folded.contains($0) } == false
    }

    // MARK: - Scope hints

    private func scopeHints(from input: SeedInput) -> [ScopeHint] {
        var hints: [ScopeHint] = []
        for tag in input.semanticTagLabels where !tag.isEmpty {
            hints.append(ScopeHint(kind: .semanticTag, value: tag))
        }
        for classification in input.classificationHints where !classification.isEmpty {
            hints.append(ScopeHint(kind: .classification, value: classification))
        }
        return hints
    }

    private func targetLabel(for assignee: Assignee) -> String? {
        switch assignee {
        case .user:        return "user"
        case .userTeam:    return "team"
        case .thirdParty:  return "third_party"
        case .ambiguous:   return nil
        }
    }
}
