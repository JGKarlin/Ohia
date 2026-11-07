import Foundation
import SwiftData

@Model
public final class MailProjectRuleGroup {
    public var id: UUID
    public var project: MailProject?
    public var kindRawValue: String
    public var sortIndex: Int

    @Relationship(deleteRule: .cascade, inverse: \MailProjectRuleCondition.group)
    public var conditions: [MailProjectRuleCondition] = []

    public init(
        id: UUID = UUID(),
        kind: MailProjectRuleGroupKind,
        sortIndex: Int
    ) {
        precondition(kind != .invalid, "Invalid rule-group kinds may only represent corrupt persisted data")
        self.id = id
        self.kindRawValue = kind.rawValue
        self.sortIndex = sortIndex
    }

    public var kind: MailProjectRuleGroupKind {
        get { MailProjectRuleGroupKind(rawValue: kindRawValue) ?? .invalid }
        set {
            precondition(newValue != .invalid, "Invalid rule-group kinds may only represent corrupt persisted data")
            kindRawValue = newValue.rawValue
        }
    }
}

@Model
public final class MailProjectRuleCondition {
    public var id: UUID
    public var group: MailProjectRuleGroup?
    public var facetRawValue: String
    public var polarityRawValue: String
    public var quantifierRawValue: String
    public var valuesJSON: String
    public var correspondentRoleRawValue: String?
    public var keywordScopesJSON: String?
    public var keywordOperatorRawValue: String?
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        facet: MailProjectRuleFacet,
        polarity: MailProjectConditionPolarity,
        quantifier: MailProjectValueQuantifier,
        values: [String],
        correspondentRole: MailProjectCorrespondentRole? = nil,
        keywordScopes: [MailProjectKeywordScope] = [],
        keywordOperator: MailProjectKeywordOperator? = nil,
        sortIndex: Int
    ) throws {
        precondition(facet != .invalid, "Invalid rule facets may only represent corrupt persisted data")
        self.id = id
        self.facetRawValue = facet.rawValue
        self.polarityRawValue = polarity.rawValue
        self.quantifierRawValue = quantifier.rawValue
        self.valuesJSON = try MailProjectJSON.encodeConditionValues(values)
        self.correspondentRoleRawValue = correspondentRole?.rawValue
        self.keywordScopesJSON = keywordScopes.isEmpty
            ? nil
            : try MailProjectJSON.encodeKeywordScopes(keywordScopes)
        self.keywordOperatorRawValue = keywordOperator?.rawValue
        self.sortIndex = sortIndex
    }

    public var facet: MailProjectRuleFacet {
        get { MailProjectRuleFacet(rawValue: facetRawValue) ?? .invalid }
        set {
            precondition(newValue != .invalid, "Invalid rule facets may only represent corrupt persisted data")
            facetRawValue = newValue.rawValue
        }
    }

    public var polarity: MailProjectConditionPolarity {
        get { MailProjectConditionPolarity(rawValue: polarityRawValue) ?? .include }
        set { polarityRawValue = newValue.rawValue }
    }

    public var quantifier: MailProjectValueQuantifier {
        get { MailProjectValueQuantifier(rawValue: quantifierRawValue) ?? .any }
        set { quantifierRawValue = newValue.rawValue }
    }

    public func values() throws -> [String] {
        try MailProjectJSON.decodeConditionValues(valuesJSON)
    }

    public func replaceValues(_ values: [String]) throws {
        valuesJSON = try MailProjectJSON.encodeConditionValues(values)
    }

    public var correspondentRole: MailProjectCorrespondentRole? {
        get { correspondentRoleRawValue.flatMap(MailProjectCorrespondentRole.init(rawValue:)) }
        set { correspondentRoleRawValue = newValue?.rawValue }
    }

    public func keywordScopes() throws -> [MailProjectKeywordScope] {
        try MailProjectJSON.decodeKeywordScopes(keywordScopesJSON)
    }

    public func replaceKeywordScopes(_ keywordScopes: [MailProjectKeywordScope]) throws {
        keywordScopesJSON = keywordScopes.isEmpty
            ? nil
            : try MailProjectJSON.encodeKeywordScopes(keywordScopes)
    }

    public var keywordOperator: MailProjectKeywordOperator? {
        get { keywordOperatorRawValue.flatMap(MailProjectKeywordOperator.init(rawValue:)) }
        set { keywordOperatorRawValue = newValue?.rawValue }
    }
}
