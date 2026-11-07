import Foundation
import OhiaCore

public struct MailProjectRuleProvenance: Codable, Sendable, Equatable {
    public let matchingGroupID: UUID
    public let matchingConditionIDs: Set<UUID>

    public init(matchingGroupID: UUID, matchingConditionIDs: Set<UUID>) {
        self.matchingGroupID = matchingGroupID
        self.matchingConditionIDs = matchingConditionIDs
    }
}

public enum MailProjectAutomaticEvaluation: Sendable, Equatable {
    case member(MailProjectRuleProvenance)
    case notMember
    case pending(requiredFacets: Set<MailProjectRuleFacet>)
    case invalid(MailProjectValidationReport)
}

public enum ManualProjectRuleEvaluator {
    public static func evaluate(
        configuration: MailProjectConfigurationSnapshot,
        message: MailProjectMessageSnapshot,
        validationReport: MailProjectValidationReport
    ) -> MailProjectAutomaticEvaluation {
        guard isEligible(configuration: configuration, message: message) else {
            return .notMember
        }
        if validationReport.automaticMatchingIsSuspended {
            return .invalid(validationReport)
        }

        let configuredMatchGroups = configuration.groups.filter { group in
            group.kind == .match && group.conditions.contains { condition in
                condition.polarity == .include
                    && condition.values.isEmpty == false
                    && automaticMembershipAnchorFacets.contains(condition.facet)
            }
        }
        guard configuredMatchGroups.isEmpty == false else {
            return .notMember
        }

        let sharedGroup = configuration.groups
            .filter {
                $0.kind == .sharedCriteria
                    && validationReport.invalidGroupIDs.contains($0.id) == false
            }
            .min(by: { $0.id.uuidString < $1.id.uuidString })
        var matchingConditionIDs: Set<UUID> = []
        if let sharedGroup {
            switch evaluate(group: sharedGroup, message: message) {
            case .matches:
                matchingConditionIDs.formUnion(sharedGroup.conditions.map(\.id))
            case .doesNotMatch:
                return .notMember
            case let .pending(facets):
                return .pending(requiredFacets: facets)
            }
        }

        let matchingGroupID: UUID
        let validMatchGroups = configuredMatchGroups.filter {
            validationReport.invalidGroupIDs.contains($0.id) == false
        }
        var matchingGroups: [MailProjectRuleGroupSnapshot] = []
        var pendingMatchFacets: Set<MailProjectRuleFacet> = []
        for group in validMatchGroups {
            switch evaluate(group: group, message: message) {
            case .matches:
                matchingGroups.append(group)
            case .doesNotMatch:
                break
            case let .pending(facets):
                pendingMatchFacets.formUnion(facets)
            }
        }

        guard let selectedGroup = matchingGroups.min(by: { $0.id.uuidString < $1.id.uuidString }) else {
            if validationReport.issues.isEmpty == false {
                return .invalid(validationReport)
            }
            if pendingMatchFacets.isEmpty == false {
                return .pending(requiredFacets: pendingMatchFacets)
            }
            return .notMember
        }
        matchingGroupID = selectedGroup.id
        matchingConditionIDs.formUnion(selectedGroup.conditions.map(\.id))

        var pendingExclusionFacets: Set<MailProjectRuleFacet> = []
        for group in configuration.groups where group.kind == .projectWideExclusion {
            guard validationReport.invalidGroupIDs.contains(group.id) == false else { continue }
            switch evaluate(group: group, message: message) {
            case .matches:
                return .notMember
            case .doesNotMatch:
                break
            case let .pending(facets):
                pendingExclusionFacets.formUnion(facets)
            }
        }
        if pendingExclusionFacets.isEmpty == false {
            return .pending(requiredFacets: pendingExclusionFacets)
        }

        return .member(MailProjectRuleProvenance(
            matchingGroupID: matchingGroupID,
            matchingConditionIDs: matchingConditionIDs
        ))
    }

    private static func isEligible(
        configuration: MailProjectConfigurationSnapshot,
        message: MailProjectMessageSnapshot
    ) -> Bool {
        if configuration.accountIDs.isEmpty == false {
            guard let accountID = message.accountID, configuration.accountIDs.contains(accountID) else {
                return false
            }
        }
        if let boundary = configuration.automaticIntakeStartAt, message.messageDate < boundary {
            return false
        }
        return true
    }

    private static let automaticMembershipAnchorFacets: Set<MailProjectRuleFacet> = [
        .correspondent,
        .mailingList,
        .fixedCategory,
        .customCategory,
    ]

    private static func evaluate(
        group: MailProjectRuleGroupSnapshot,
        message: MailProjectMessageSnapshot
    ) -> ManualProjectRuleMatchEvaluation {
        guard group.conditions.isEmpty == false else { return .doesNotMatch }

        var pendingFacets: Set<MailProjectRuleFacet> = []
        for condition in group.conditions {
            let evaluation = evaluate(condition: condition, message: message)
            switch (condition.polarity, evaluation) {
            case (.include, .doesNotMatch), (.exclude, .matches):
                return .doesNotMatch
            case let (.include, .pending(facets)), let (.exclude, .pending(facets)):
                pendingFacets.formUnion(facets)
            case (.include, .matches), (.exclude, .doesNotMatch):
                break
            }
        }
        return pendingFacets.isEmpty ? .matches : .pending(pendingFacets)
    }

    private static func evaluate(
        condition: MailProjectRuleConditionSnapshot,
        message: MailProjectMessageSnapshot
    ) -> ManualProjectRuleMatchEvaluation {
        guard condition.facet != .invalid else { return .doesNotMatch }
        if keywordFacets.contains(condition.facet) {
            guard let keywordOperator = condition.keywordOperator else { return .doesNotMatch }
            return ManualProjectKeywordMatcher.evaluate(
                values: condition.values,
                quantifier: condition.quantifier,
                scopes: condition.keywordScopes,
                operator: keywordOperator,
                message: message
            )
        }
        if condition.facet != .account,
           message.readinessByFacet[condition.facet] == .pendingForNewMessage {
            return .pending([condition.facet])
        }

        return conditionMatches(condition, message: message) ? .matches : .doesNotMatch
    }

    private static func conditionMatches(
        _ condition: MailProjectRuleConditionSnapshot,
        message: MailProjectMessageSnapshot
    ) -> Bool {
        guard condition.values.isEmpty == false else { return false }

        switch condition.facet {
        case .invalid:
            return false
        case .account:
            return quantify(condition.values, using: condition.quantifier) { value in
                guard let expected = UUID(uuidString: value) else { return false }
                return message.accountID == expected
            }
        case .correspondent:
            guard let role = condition.correspondentRole else { return false }
            let actualIDs: Set<UUID>
            if role == .involves {
                actualIDs = [.from, .to, .cc, .bcc].reduce(into: Set<UUID>()) { ids, role in
                    ids.formUnion(message.correspondentIDsByRole[role] ?? [])
                }
            } else {
                actualIDs = message.correspondentIDsByRole[role] ?? []
            }
            return quantify(condition.values, using: condition.quantifier) { value in
                guard let expected = UUID(uuidString: value) else { return false }
                return actualIDs.contains(expected)
            }
        case .fixedCategory:
            return quantify(condition.values, using: condition.quantifier) { value in
                message.purpose?.rawValue == value
            }
        case .customCategory:
            return quantify(condition.values, using: condition.quantifier) { value in
                message.customCategoryKeys.contains(value)
            }
        case .subject, .body, .attachmentFilename, .attachmentText:
            guard let keywordOperator = condition.keywordOperator else { return false }
            return ManualProjectKeywordMatcher.matches(
                values: condition.values,
                quantifier: condition.quantifier,
                scopes: condition.keywordScopes,
                operator: keywordOperator,
                message: message
            )
        default:
            let actualValues = message.valuesByFacet[condition.facet] ?? []
            return quantify(condition.values, using: condition.quantifier) { actualValues.contains($0) }
        }
    }

    private static func quantify(
        _ values: [String],
        using quantifier: MailProjectValueQuantifier,
        predicate: (String) -> Bool
    ) -> Bool {
        guard values.isEmpty == false else { return false }
        switch quantifier {
        case .any:
            return values.contains(where: predicate)
        case .all:
            return values.allSatisfy(predicate)
        }
    }

    private static let keywordFacets: Set<MailProjectRuleFacet> = [
        .subject,
        .body,
        .attachmentFilename,
        .attachmentText
    ]
}
