import Foundation
import OhiaCore

/// §10 multiplicative claim-weight engine. Returns a full
/// `ClaimStatusBundle` (multi-axis status) rather than a single scalar so
/// the UI can surface extraction confidence, evidence strength, user
/// confirmation, contradiction state, and sensitivity risk independently.
/// The derived `weight` field is used for sort order in Memory Cards.
public struct ClaimWeightingEngine: Sendable {
    public init() {}

    /// Pure factor calculations + multiplicative combination.
    public func weight(for input: ClaimWeightInput) -> ClaimWeightingOutput {
        let extractionConfidence = clamp01(input.extractionConfidence)
        let recency = recencyFactor(
            lastAffirmed: input.lastAffirmed,
            now: input.now
        )
        let affirmation = affirmationFactor(
            replyApprovalCount: input.replyApprovalCount,
            signOffCount: input.signOffCount,
            acknowledgementCount: input.acknowledgementCount
        )
        let repetition = repetitionFactor(distinctThreadCount: input.distinctThreadCount)
        let evidenceDiversity = diversityFactor(
            distinctParticipants: input.distinctParticipantCount,
            attachmentEvidenceCount: input.attachmentEvidenceCount
        )
        let sourceContext = sourceContextFactor(
            familiarity: input.familiarity,
            relationshipScore: input.relationshipScore
        )
        let resolutionState = resolutionStateFactor(input.resolutionState)
        let scopeFit = scopeFitFactor(
            claimScope: input.claimScope,
            activeScope: input.activeScope
        )
        let conflictPenalty = conflictPenaltyFactor(
            contradictionState: input.contradictionState,
            sensitivityMultiplier: input.sensitivity.conflictPenaltyMultiplier
        )

        let evidenceStrength = clamp01(
            recency * affirmation * repetition * evidenceDiversity * sourceContext
        )
        let scoredWeight = clamp01(
            extractionConfidence
                * evidenceStrength
                * resolutionState
                * scopeFit
                * conflictPenalty
        )

        // Apply the sensitivity floor — sensitive claims need stronger
        // evidence to clear the memory-card eligibility threshold.
        let clearsSensitivityFloor =
            input.supportingMessageCount >= input.sensitivity.minSupportingMessageCount
            && input.distinctParticipantCount >= input.sensitivity.minDistinctParticipantCount

        let userConfirmation = input.userConfirmation
        let effectiveWeight: Double
        if !clearsSensitivityFloor && userConfirmation != .confirmed {
            // Sensitive + under-supported + unconfirmed → suppress weight
            // so the card sits low in the ranking but still appears as a
            // muted entry.
            effectiveWeight = scoredWeight * 0.25
        } else {
            effectiveWeight = scoredWeight
        }

        let status = ClaimStatusBundle(
            extractionConfidence: extractionConfidence,
            evidenceStrength: evidenceStrength,
            userConfirmation: userConfirmation,
            contradictionState: input.contradictionState,
            sensitivityRisk: input.sensitivity.risk
        )

        return ClaimWeightingOutput(
            weight: effectiveWeight,
            status: status,
            clearsSensitivityFloor: clearsSensitivityFloor,
            factors: ClaimWeightingFactors(
                extractionConfidence: extractionConfidence,
                recency: recency,
                affirmation: affirmation,
                repetition: repetition,
                evidenceDiversity: evidenceDiversity,
                sourceContext: sourceContext,
                resolutionState: resolutionState,
                scopeFit: scopeFit,
                conflictPenalty: conflictPenalty
            )
        )
    }

    // MARK: - Factors

    private func recencyFactor(lastAffirmed: Date, now: Date) -> Double {
        let ageSeconds = max(0, now.timeIntervalSince(lastAffirmed))
        let halfLifeDays: Double = 90
        let halfLifeSeconds = halfLifeDays * 86_400
        return pow(0.5, ageSeconds / halfLifeSeconds)
    }

    private func affirmationFactor(
        replyApprovalCount: Int,
        signOffCount: Int,
        acknowledgementCount: Int
    ) -> Double {
        let weighted = Double(replyApprovalCount) * 0.6
            + Double(signOffCount) * 1.0
            + Double(acknowledgementCount) * 0.3
        return min(1.0, 0.4 + weighted * 0.15)
    }

    private func repetitionFactor(distinctThreadCount: Int) -> Double {
        if distinctThreadCount <= 1 { return 0.6 }
        if distinctThreadCount == 2 { return 0.8 }
        return min(1.0, 0.8 + Double(distinctThreadCount - 2) * 0.05)
    }

    private func diversityFactor(distinctParticipants: Int, attachmentEvidenceCount: Int) -> Double {
        let base = min(1.0, 0.5 + Double(distinctParticipants - 1) * 0.15)
        let bonus = min(0.2, Double(attachmentEvidenceCount) * 0.05)
        return min(1.0, base + bonus)
    }

    private func sourceContextFactor(familiarity: Double, relationshipScore: Double) -> Double {
        let f = clamp01(familiarity)
        let r = clamp01(relationshipScore)
        return clamp01(0.5 + 0.3 * f + 0.2 * r)
    }

    private func resolutionStateFactor(_ state: ClaimResolutionState) -> Double {
        switch state {
        case .decision:    return 1.0
        case .closed:      return 0.95
        case .open:        return 0.7
        case .proposal:    return 0.55
        case .speculative: return 0.4
        }
    }

    private func scopeFitFactor(
        claimScope: [ScopeHint],
        activeScope: [ScopeHint]
    ) -> Double {
        guard !activeScope.isEmpty else { return 1.0 }
        guard !claimScope.isEmpty else { return 0.7 }
        let claimSet = Set(claimScope)
        let activeSet = Set(activeScope)
        let intersection = claimSet.intersection(activeSet).count
        if intersection == 0 { return 0.4 }
        let coverage = Double(intersection) / Double(activeSet.count)
        return clamp01(0.5 + 0.5 * coverage)
    }

    private func conflictPenaltyFactor(
        contradictionState: ContradictionState,
        sensitivityMultiplier: Double
    ) -> Double {
        let baseline: Double
        switch contradictionState {
        case .clean:         baseline = 1.0
        case .contested:     baseline = 0.7
        case .scopeNarrowed: baseline = 0.85
        case .superseded:    baseline = 0.3
        }
        // The sensitivity multiplier amplifies the *penalty* — i.e. it
        // reduces the factor more aggressively for sensitive claims.
        // multiplier=1.0 → unchanged. multiplier>1.0 → larger penalty.
        if baseline >= 1.0 { return 1.0 }
        let penalty = 1.0 - baseline
        let amplified = penalty * sensitivityMultiplier
        return max(0.0, 1.0 - amplified)
    }

    private func clamp01(_ x: Double) -> Double { min(1.0, max(0.0, x)) }
}

public enum ClaimResolutionState: Sendable, Equatable {
    case decision
    case closed
    case open
    case proposal
    case speculative
}

public struct ClaimWeightInput: Sendable {
    public let extractionConfidence: Double
    public let lastAffirmed: Date
    public let now: Date
    public let replyApprovalCount: Int
    public let signOffCount: Int
    public let acknowledgementCount: Int
    public let distinctThreadCount: Int
    public let distinctParticipantCount: Int
    public let supportingMessageCount: Int
    public let attachmentEvidenceCount: Int
    public let familiarity: Double
    public let relationshipScore: Double
    public let resolutionState: ClaimResolutionState
    public let claimScope: [ScopeHint]
    public let activeScope: [ScopeHint]
    public let contradictionState: ContradictionState
    public let userConfirmation: UserConfirmation
    public let sensitivity: SensitivityVerdict

    public init(
        extractionConfidence: Double,
        lastAffirmed: Date,
        now: Date,
        replyApprovalCount: Int,
        signOffCount: Int,
        acknowledgementCount: Int,
        distinctThreadCount: Int,
        distinctParticipantCount: Int,
        supportingMessageCount: Int,
        attachmentEvidenceCount: Int,
        familiarity: Double,
        relationshipScore: Double,
        resolutionState: ClaimResolutionState,
        claimScope: [ScopeHint],
        activeScope: [ScopeHint],
        contradictionState: ContradictionState,
        userConfirmation: UserConfirmation,
        sensitivity: SensitivityVerdict
    ) {
        self.extractionConfidence = extractionConfidence
        self.lastAffirmed = lastAffirmed
        self.now = now
        self.replyApprovalCount = replyApprovalCount
        self.signOffCount = signOffCount
        self.acknowledgementCount = acknowledgementCount
        self.distinctThreadCount = distinctThreadCount
        self.distinctParticipantCount = distinctParticipantCount
        self.supportingMessageCount = supportingMessageCount
        self.attachmentEvidenceCount = attachmentEvidenceCount
        self.familiarity = familiarity
        self.relationshipScore = relationshipScore
        self.resolutionState = resolutionState
        self.claimScope = claimScope
        self.activeScope = activeScope
        self.contradictionState = contradictionState
        self.userConfirmation = userConfirmation
        self.sensitivity = sensitivity
    }
}

public struct ClaimWeightingFactors: Sendable, Equatable {
    public let extractionConfidence: Double
    public let recency: Double
    public let affirmation: Double
    public let repetition: Double
    public let evidenceDiversity: Double
    public let sourceContext: Double
    public let resolutionState: Double
    public let scopeFit: Double
    public let conflictPenalty: Double
}

public struct ClaimWeightingOutput: Sendable, Equatable {
    public let weight: Double
    public let status: ClaimStatusBundle
    public let clearsSensitivityFloor: Bool
    public let factors: ClaimWeightingFactors
}
