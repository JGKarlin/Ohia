import Foundation
import OhiaCore

/// Folds persisted `ConversationCurationAction` rows onto an in-memory
/// snapshot. Recomputed claims, issues, decisions, precedents, and tacit
/// rules all flow through here so user verdicts survive recomputation.
public struct ConversationCurationApplier: Sendable {
    public init() {}

    public func apply(
        actions: [ConversationCurationAction],
        claims: [KnowledgeClaim],
        precedents: [Precedent],
        tacitRules: [TacitRule],
        issues: [IssueNode],
        decisions: [DecisionNode]
    ) -> CurationApplyResult {
        // Index actions by their normalized lookup tiers so the
        // fallback ladder runs once per object instead of N times.
        let active = actions.filter(\.isActive)

        let updatedClaims = claims.map { claim in
            let components = curationComponents(for: claim)
            let verdict = ConversationCurationKey.resolve(actions: active, candidate: components)
            return applyVerdict(verdict, to: claim)
        }

        let updatedPrecedents = precedents.map { precedent in
            let components = CurationKeyComponents(
                targetKey: precedent.key,
                normalizedClaimText: ConversationCurationKey.normalize(text: precedent.statement),
                targetKind: .precedent,
                scopeFingerprint: "",
                extractionVersion: DiscourseMemory.qwenVersion,
                supportingFingerprint: ""
            )
            let verdict = ConversationCurationKey.resolve(actions: active, candidate: components)
            return applyVerdict(verdict, to: precedent)
        }

        let updatedTacitRules = tacitRules.map { rule in
            let components = CurationKeyComponents(
                targetKey: rule.key,
                normalizedClaimText: ConversationCurationKey.normalize(text: rule.rule),
                targetKind: .tacitRule,
                scopeFingerprint: ConversationCurationKey.makeScopeFingerprint(rule.scope),
                extractionVersion: DiscourseMemory.qwenVersion,
                supportingFingerprint: ""
            )
            let verdict = ConversationCurationKey.resolve(actions: active, candidate: components)
            return applyVerdict(verdict, to: rule)
        }

        let updatedIssues = issues.map { issue -> IssueNode in
            let components = CurationKeyComponents(
                targetKey: issue.key,
                normalizedClaimText: ConversationCurationKey.normalize(text: issue.title),
                targetKind: .issue,
                scopeFingerprint: "",
                extractionVersion: DiscourseMemory.qwenVersion,
                supportingFingerprint: ""
            )
            let verdict = ConversationCurationKey.resolve(actions: active, candidate: components)
            return applyVerdict(verdict, to: issue)
        }

        let updatedDecisions = decisions.map { decision -> DecisionNode in
            // Decisions don't accept user verdicts directly in v1 (they're
            // already terminal); pass through.
            _ = active
            return decision
        }

        return CurationApplyResult(
            claims: updatedClaims,
            precedents: updatedPrecedents,
            tacitRules: updatedTacitRules,
            issues: updatedIssues,
            decisions: updatedDecisions
        )
    }

    // MARK: - Per-target verdict application

    private func applyVerdict(_ action: ConversationCurationAction?, to claim: KnowledgeClaim) -> KnowledgeClaim {
        guard let action, let actionValue = action.actionValue else { return claim }
        var status = claim.status
        switch actionValue {
        case .confirm:
            status = ClaimStatusBundle(
                extractionConfidence: status.extractionConfidence,
                evidenceStrength: status.evidenceStrength,
                userConfirmation: .confirmed,
                contradictionState: status.contradictionState,
                sensitivityRisk: status.sensitivityRisk
            )
        case .reject:
            status = ClaimStatusBundle(
                extractionConfidence: status.extractionConfidence,
                evidenceStrength: status.evidenceStrength,
                userConfirmation: .rejected,
                contradictionState: status.contradictionState,
                sensitivityRisk: status.sensitivityRisk
            )
        case .weaken:
            status = ClaimStatusBundle(
                extractionConfidence: status.extractionConfidence,
                evidenceStrength: max(0, status.evidenceStrength * 0.6),
                userConfirmation: .weakened,
                contradictionState: status.contradictionState,
                sensitivityRisk: status.sensitivityRisk
            )
        case .markStale, .markObsolete:
            status = ClaimStatusBundle(
                extractionConfidence: status.extractionConfidence,
                evidenceStrength: status.evidenceStrength,
                userConfirmation: .markedStale,
                contradictionState: status.contradictionState,
                sensitivityRisk: status.sensitivityRisk
            )
        case .pin, .merge, .split:
            // Pin / merge / split don't alter the status bundle directly
            // — they're consumed by sort order or the snapshot
            // builder's merge step.
            break
        }
        return KnowledgeClaim(
            id: claim.id,
            key: claim.key,
            text: claim.text,
            status: status,
            weight: claim.weight,
            scope: claim.scope,
            firstSeen: claim.firstSeen,
            lastAffirmed: claim.lastAffirmed,
            evidenceCount: claim.evidenceCount,
            evidenceLinks: claim.evidenceLinks,
            sourceParticipants: claim.sourceParticipants,
            contradictionKeys: claim.contradictionKeys,
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

    private func applyVerdict(_ action: ConversationCurationAction?, to precedent: Precedent) -> Precedent {
        // Precedent applicability adjustments live on the score directly.
        guard let action, let actionValue = action.actionValue else { return precedent }
        let adjusted: Double
        switch actionValue {
        case .confirm: adjusted = min(1.0, precedent.applicabilityScore * 1.2)
        case .reject:  adjusted = 0
        case .weaken:  adjusted = precedent.applicabilityScore * 0.5
        case .markStale, .markObsolete: adjusted = precedent.applicabilityScore * 0.2
        case .pin:     adjusted = min(1.0, precedent.applicabilityScore + 0.2)
        case .merge, .split: adjusted = precedent.applicabilityScore
        }
        return Precedent(
            id: precedent.id,
            key: precedent.key,
            statement: precedent.statement,
            recurrenceCount: precedent.recurrenceCount,
            sourceThreadIDs: precedent.sourceThreadIDs,
            applicabilityScore: adjusted,
            exceptions: precedent.exceptions,
            evidenceLinks: precedent.evidenceLinks,
            sensitivityRisk: precedent.sensitivityRisk
        )
    }

    private func applyVerdict(_ action: ConversationCurationAction?, to rule: TacitRule) -> TacitRule {
        guard let action, let actionValue = action.actionValue else { return rule }
        let confirmation: UserConfirmation
        switch actionValue {
        case .confirm:                  confirmation = .confirmed
        case .reject:                   confirmation = .rejected
        case .weaken:                   confirmation = .weakened
        case .markStale, .markObsolete: confirmation = .markedStale
        case .pin, .merge, .split:      confirmation = rule.confirmationState
        }
        return TacitRule(
            id: rule.id,
            key: rule.key,
            rule: rule.rule,
            pattern: rule.pattern,
            confidence: rule.confidence,
            scope: rule.scope,
            confirmationState: confirmation,
            evidenceLinks: rule.evidenceLinks,
            sensitivityRisk: rule.sensitivityRisk
        )
    }

    private func applyVerdict(_ action: ConversationCurationAction?, to issue: IssueNode) -> IssueNode {
        guard let action, let actionValue = action.actionValue else { return issue }
        let newStatus: IssueStatus
        switch actionValue {
        case .confirm:                  newStatus = .resolved
        case .reject:                   newStatus = .stale
        case .markStale, .markObsolete: newStatus = .stale
        case .weaken, .pin, .merge, .split: newStatus = issue.status
        }
        return IssueNode(
            key: issue.key,
            title: issue.title,
            status: newStatus,
            projectLabels: issue.projectLabels,
            teamLabels: issue.teamLabels,
            firstSeen: issue.firstSeen,
            lastActive: issue.lastActive,
            relatedThreadIDs: issue.relatedThreadIDs,
            evidenceMessageIDs: issue.evidenceMessageIDs
        )
    }

    private func curationComponents(for claim: KnowledgeClaim) -> CurationKeyComponents {
        let scopeFingerprint = ConversationCurationKey.makeDurableClaimScopeFingerprint(
            scope: claim.scope,
            kindRaw: claim.kindRaw,
            subjectText: claim.subjectText,
            conditionsText: claim.conditionsText,
            futureUseText: claim.futureUseText,
            formationBasisRaw: claim.formationBasisRaw,
            usePolicyRaw: claim.usePolicyRaw
        )
        let supportingHashes: [String] = []
        return CurationKeyComponents(
            targetKey: claim.key,
            normalizedClaimText: ConversationCurationKey.normalize(text: claim.text),
            targetKind: .claim,
            scopeFingerprint: scopeFingerprint,
            extractionVersion: DiscourseMemory.qwenVersion,
            supportingFingerprint: ConversationCurationKey.makeSupportingFingerprint(supportingHashes)
        )
    }
}

public struct CurationApplyResult: Sendable {
    public let claims: [KnowledgeClaim]
    public let precedents: [Precedent]
    public let tacitRules: [TacitRule]
    public let issues: [IssueNode]
    public let decisions: [DecisionNode]
}
