import Foundation
import OhiaCore

public struct MailProjectMembershipProvenance: Codable, Sendable, Equatable {
    public let rule: MailProjectRuleProvenance?
    public let decisionID: UUID?
    public let decisionTargetKind: MailProjectDecisionTargetKind?
    public let isExceptionToAutomaticRules: Bool

    public init(
        rule: MailProjectRuleProvenance?,
        decisionID: UUID?,
        decisionTargetKind: MailProjectDecisionTargetKind?,
        isExceptionToAutomaticRules: Bool
    ) {
        self.rule = rule
        self.decisionID = decisionID
        self.decisionTargetKind = decisionTargetKind
        self.isExceptionToAutomaticRules = isExceptionToAutomaticRules
    }
}

public enum MailProjectFinalMembershipDecision: Sendable, Equatable {
    case included(source: MailProjectMembershipSource, provenance: MailProjectMembershipProvenance)
    case excluded(source: MailProjectDecisionTargetKind?)
}

public enum ManualProjectMembershipDecision {
    /// `decisions` must already be scoped to the project being evaluated.
    public static func resolve(
        messageID: UUID,
        threadID: UUID?,
        decisions: [MailProjectDecisionSnapshot],
        automatic: MailProjectAutomaticEvaluation
    ) -> MailProjectFinalMembershipDecision {
        if let decision = winningDecision(kind: .message, targetID: messageID, decisions: decisions) {
            return resolve(decision: decision, source: .messageOverride, automatic: automatic)
        }
        if let threadID,
           let decision = winningDecision(kind: .thread, targetID: threadID, decisions: decisions) {
            return resolve(decision: decision, source: .threadOverride, automatic: automatic)
        }

        switch automatic {
        case let .member(rule):
            return .included(
                source: .rule,
                provenance: MailProjectMembershipProvenance(
                    rule: rule,
                    decisionID: nil,
                    decisionTargetKind: nil,
                    isExceptionToAutomaticRules: false
                )
            )
        case .notMember, .pending, .invalid:
            return .excluded(source: nil)
        }
    }

    private static func winningDecision(
        kind: MailProjectDecisionTargetKind,
        targetID: UUID,
        decisions: [MailProjectDecisionSnapshot]
    ) -> MailProjectDecisionSnapshot? {
        decisions
            .filter { $0.targetKind == kind && $0.targetID == targetID }
            .min { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private static func resolve(
        decision: MailProjectDecisionSnapshot,
        source: MailProjectMembershipSource,
        automatic: MailProjectAutomaticEvaluation
    ) -> MailProjectFinalMembershipDecision {
        switch decision.decision {
        case .exclude:
            return .excluded(source: decision.targetKind)
        case .include:
            let rule: MailProjectRuleProvenance?
            if case let .member(automaticRule) = automatic {
                rule = automaticRule
            } else {
                rule = nil
            }
            return .included(
                source: source,
                provenance: MailProjectMembershipProvenance(
                    rule: rule,
                    decisionID: decision.id,
                    decisionTargetKind: decision.targetKind,
                    isExceptionToAutomaticRules: rule == nil
                )
            )
        }
    }
}
