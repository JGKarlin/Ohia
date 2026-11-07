import Foundation
import OhiaCore

public struct MailProjectValidationReport: Codable, Sendable, Equatable {
    public let issues: [MailProjectValidationIssue]
    public let invalidGroupIDs: Set<UUID>
    public let invalidConditionIDs: Set<UUID>
    public let automaticMatchingIsSuspended: Bool

    public var isValid: Bool { issues.isEmpty }

    public init(issues: [MailProjectValidationIssue], invalidGroupIDs: Set<UUID>, invalidConditionIDs: Set<UUID>, automaticMatchingIsSuspended: Bool) {
        self.issues = issues
        self.invalidGroupIDs = invalidGroupIDs
        self.invalidConditionIDs = invalidConditionIDs
        self.automaticMatchingIsSuspended = automaticMatchingIsSuspended
    }
}

public struct MailProjectValidationIssue: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let code: MailProjectValidationIssueCode
    public let groupID: UUID
    public let conditionID: UUID?
    public let invalidValue: String?

    public init(code: MailProjectValidationIssueCode, groupID: UUID, conditionID: UUID?, invalidValue: String?) {
        self.code = code
        self.groupID = groupID
        self.conditionID = conditionID
        self.invalidValue = invalidValue
        self.id = [code.rawValue, groupID.uuidString, conditionID?.uuidString ?? "", invalidValue ?? ""].joined(separator: "|")
    }
}

public enum MailProjectValidationIssueCode: String, Codable, Sendable {
    case invalidGroupKind
    case invalidFacet
    case multipleSharedCriteriaGroups
    case unsupportedSharedCriteriaFacet
    case emptyMatchGroup
    case emptyValues
    case invalidCatalogValue
    case missingCorrespondentRole
    case unexpectedCorrespondentRole
    case missingKeywordScopes
    case missingKeywordOperator
    case unexpectedKeywordConfiguration
}

public enum ManualProjectConfigurationValidator {
    public static func validate(
        configuration: MailProjectConfigurationSnapshot,
        catalog: MailProjectRuleCatalogSnapshot
    ) -> MailProjectValidationReport {
        var issues: [MailProjectValidationIssue] = []
        var invalidGroupIDs: Set<UUID> = []
        var invalidConditionIDs: Set<UUID> = []
        var automaticMatchingIsSuspended = false
        let sortedGroups = configuration.groups.sorted(by: Self.groupOrder)
        let sharedGroups = sortedGroups.filter { $0.kind == .sharedCriteria }

        if sharedGroups.count > 1 {
            for group in sharedGroups {
                record(
                    code: .multipleSharedCriteriaGroups,
                    group: group,
                    condition: nil,
                    invalidValue: nil,
                    issues: &issues,
                    invalidGroupIDs: &invalidGroupIDs,
                    invalidConditionIDs: &invalidConditionIDs,
                    automaticMatchingIsSuspended: &automaticMatchingIsSuspended
                )
            }
        }

        for group in sortedGroups {
            if group.kind == .invalid {
                record(
                    code: .invalidGroupKind,
                    group: group,
                    condition: nil,
                    invalidValue: nil,
                    issues: &issues,
                    invalidGroupIDs: &invalidGroupIDs,
                    invalidConditionIDs: &invalidConditionIDs,
                    automaticMatchingIsSuspended: &automaticMatchingIsSuspended
                )
                continue
            }

            if group.kind == .match || group.kind == .sharedCriteria,
               group.conditions.isEmpty {
                record(
                    code: .emptyMatchGroup,
                    group: group,
                    condition: nil,
                    invalidValue: nil,
                    issues: &issues,
                    invalidGroupIDs: &invalidGroupIDs,
                    invalidConditionIDs: &invalidConditionIDs,
                    automaticMatchingIsSuspended: &automaticMatchingIsSuspended
                )
                continue
            }

            for condition in group.conditions.sorted(by: Self.conditionOrder) {
                validate(
                    condition: condition,
                    in: group,
                    catalog: catalog,
                    issues: &issues,
                    invalidGroupIDs: &invalidGroupIDs,
                    invalidConditionIDs: &invalidConditionIDs,
                    automaticMatchingIsSuspended: &automaticMatchingIsSuspended
                )
            }
        }

        return MailProjectValidationReport(
            issues: issues,
            invalidGroupIDs: invalidGroupIDs,
            invalidConditionIDs: invalidConditionIDs,
            automaticMatchingIsSuspended: automaticMatchingIsSuspended
        )
    }

    private static func validate(
        condition: MailProjectRuleConditionSnapshot,
        in group: MailProjectRuleGroupSnapshot,
        catalog: MailProjectRuleCatalogSnapshot,
        issues: inout [MailProjectValidationIssue],
        invalidGroupIDs: inout Set<UUID>,
        invalidConditionIDs: inout Set<UUID>,
        automaticMatchingIsSuspended: inout Bool
    ) {
        if condition.facet == .invalid {
            record(
                code: .invalidFacet,
                group: group,
                condition: condition,
                invalidValue: nil,
                issues: &issues,
                invalidGroupIDs: &invalidGroupIDs,
                invalidConditionIDs: &invalidConditionIDs,
                automaticMatchingIsSuspended: &automaticMatchingIsSuspended
            )
            return
        }

        if group.kind == .sharedCriteria,
           condition.facet == .account || condition.facet == .correspondent {
            record(
                code: .unsupportedSharedCriteriaFacet,
                group: group,
                condition: condition,
                invalidValue: nil,
                issues: &issues,
                invalidGroupIDs: &invalidGroupIDs,
                invalidConditionIDs: &invalidConditionIDs,
                automaticMatchingIsSuspended: &automaticMatchingIsSuspended
            )
        }

        let valuesAreCanonical = condition.values.isEmpty == false && condition.values.allSatisfy { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty == false && trimmed == value
        }
        if valuesAreCanonical == false {
            record(
                code: .emptyValues,
                group: group,
                condition: condition,
                invalidValue: nil,
                issues: &issues,
                invalidGroupIDs: &invalidGroupIDs,
                invalidConditionIDs: &invalidConditionIDs,
                automaticMatchingIsSuspended: &automaticMatchingIsSuspended
            )
        }

        if condition.facet == .correspondent {
            if condition.correspondentRole == nil {
                record(
                    code: .missingCorrespondentRole,
                    group: group,
                    condition: condition,
                    invalidValue: nil,
                    issues: &issues,
                    invalidGroupIDs: &invalidGroupIDs,
                    invalidConditionIDs: &invalidConditionIDs,
                    automaticMatchingIsSuspended: &automaticMatchingIsSuspended
                )
            }
        } else if condition.correspondentRole != nil {
            record(
                code: .unexpectedCorrespondentRole,
                group: group,
                condition: condition,
                invalidValue: nil,
                issues: &issues,
                invalidGroupIDs: &invalidGroupIDs,
                invalidConditionIDs: &invalidConditionIDs,
                automaticMatchingIsSuspended: &automaticMatchingIsSuspended
            )
        }

        if keywordFacets.contains(condition.facet) {
            if condition.keywordScopes.isEmpty {
                record(
                    code: .missingKeywordScopes,
                    group: group,
                    condition: condition,
                    invalidValue: nil,
                    issues: &issues,
                    invalidGroupIDs: &invalidGroupIDs,
                    invalidConditionIDs: &invalidConditionIDs,
                    automaticMatchingIsSuspended: &automaticMatchingIsSuspended
                )
            }
            if condition.keywordOperator == nil {
                record(
                    code: .missingKeywordOperator,
                    group: group,
                    condition: condition,
                    invalidValue: nil,
                    issues: &issues,
                    invalidGroupIDs: &invalidGroupIDs,
                    invalidConditionIDs: &invalidConditionIDs,
                    automaticMatchingIsSuspended: &automaticMatchingIsSuspended
                )
            }
        } else if condition.keywordScopes.isEmpty == false || condition.keywordOperator != nil {
            record(
                code: .unexpectedKeywordConfiguration,
                group: group,
                condition: condition,
                invalidValue: nil,
                issues: &issues,
                invalidGroupIDs: &invalidGroupIDs,
                invalidConditionIDs: &invalidConditionIDs,
                automaticMatchingIsSuspended: &automaticMatchingIsSuspended
            )
        }

        if valuesAreCanonical {
            for value in Set(condition.values).sorted() where catalogContains(value, for: condition.facet, catalog: catalog) == false {
                record(
                    code: .invalidCatalogValue,
                    group: group,
                    condition: condition,
                    invalidValue: value,
                    issues: &issues,
                    invalidGroupIDs: &invalidGroupIDs,
                    invalidConditionIDs: &invalidConditionIDs,
                    automaticMatchingIsSuspended: &automaticMatchingIsSuspended
                )
            }
        }
    }

    private static let keywordFacets: Set<MailProjectRuleFacet> = [.subject, .body, .attachmentFilename, .attachmentText]

    private static func catalogContains(
        _ value: String,
        for facet: MailProjectRuleFacet,
        catalog: MailProjectRuleCatalogSnapshot
    ) -> Bool {
        switch facet {
        case .invalid:
            return false
        case .account:
            return catalog.accounts.contains { $0.stableKey == value && $0.isValid }
        case .correspondent:
            return catalog.correspondents.contains { $0.id.uuidString == value }
        case .subject, .body, .attachmentFilename, .attachmentText:
            return true
        default:
            return (catalog.valuesByFacet[facet] ?? []).contains { $0.stableKey == value && $0.isValid }
        }
    }

    private static func record(
        code: MailProjectValidationIssueCode,
        group: MailProjectRuleGroupSnapshot,
        condition: MailProjectRuleConditionSnapshot?,
        invalidValue: String?,
        issues: inout [MailProjectValidationIssue],
        invalidGroupIDs: inout Set<UUID>,
        invalidConditionIDs: inout Set<UUID>,
        automaticMatchingIsSuspended: inout Bool
    ) {
        issues.append(MailProjectValidationIssue(code: code, groupID: group.id, conditionID: condition?.id, invalidValue: invalidValue))
        invalidGroupIDs.insert(group.id)
        if let condition { invalidConditionIDs.insert(condition.id) }
        if group.kind == .sharedCriteria
            || group.kind == .projectWideExclusion
            || group.kind == .invalid {
            automaticMatchingIsSuspended = true
        }
    }

    private static func groupOrder(_ lhs: MailProjectRuleGroupSnapshot, _ rhs: MailProjectRuleGroupSnapshot) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private static func conditionOrder(_ lhs: MailProjectRuleConditionSnapshot, _ rhs: MailProjectRuleConditionSnapshot) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }
}
