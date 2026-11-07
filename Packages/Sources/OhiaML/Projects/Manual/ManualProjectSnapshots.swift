import Foundation
import OhiaCore

public struct MailProjectConfigurationSnapshot: Codable, Sendable, Equatable {
    public let projectID: UUID
    public let existingProjectID: UUID?
    public let displayName: String
    public let accountIDs: Set<UUID>
    public let automaticIntakeStartAt: Date?
    public let baseConfigurationRevision: Int
    public let groups: [MailProjectRuleGroupSnapshot]
    public let manualDecisions: [MailProjectDecisionSnapshot]

    public init(projectID: UUID, existingProjectID: UUID?, displayName: String, accountIDs: Set<UUID>, automaticIntakeStartAt: Date?, baseConfigurationRevision: Int, groups: [MailProjectRuleGroupSnapshot], manualDecisions: [MailProjectDecisionSnapshot]) {
        self.projectID = projectID
        self.existingProjectID = existingProjectID
        self.displayName = displayName
        self.accountIDs = accountIDs
        self.automaticIntakeStartAt = automaticIntakeStartAt
        self.baseConfigurationRevision = baseConfigurationRevision
        self.groups = groups
        self.manualDecisions = manualDecisions
    }
}

public struct MailProjectRuleGroupSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: MailProjectRuleGroupKind
    public let sortIndex: Int
    public let conditions: [MailProjectRuleConditionSnapshot]

    public init(id: UUID, kind: MailProjectRuleGroupKind, sortIndex: Int, conditions: [MailProjectRuleConditionSnapshot]) {
        self.id = id
        self.kind = kind
        self.sortIndex = sortIndex
        self.conditions = conditions
    }
}

public struct MailProjectRuleConditionSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let facet: MailProjectRuleFacet
    public let polarity: MailProjectConditionPolarity
    public let quantifier: MailProjectValueQuantifier
    public let values: [String]
    public let correspondentRole: MailProjectCorrespondentRole?
    public let keywordScopes: Set<MailProjectKeywordScope>
    public let keywordOperator: MailProjectKeywordOperator?
    public let sortIndex: Int

    public init(id: UUID, facet: MailProjectRuleFacet, polarity: MailProjectConditionPolarity, quantifier: MailProjectValueQuantifier, values: [String], correspondentRole: MailProjectCorrespondentRole?, keywordScopes: Set<MailProjectKeywordScope>, keywordOperator: MailProjectKeywordOperator?, sortIndex: Int) {
        self.id = id
        self.facet = facet
        self.polarity = polarity
        self.quantifier = quantifier
        self.values = values
        self.correspondentRole = correspondentRole
        self.keywordScopes = keywordScopes
        self.keywordOperator = keywordOperator
        self.sortIndex = sortIndex
    }
}

public struct MailProjectMessageSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let accountID: UUID?
    public let threadID: UUID?
    public let messageDate: Date
    public let correspondentIDsByRole: [MailProjectCorrespondentRole: Set<UUID>]
    public let addressesByRole: [MailProjectCorrespondentRole: Set<String>]
    public let purpose: MailPurpose?
    public let customCategoryKeys: Set<String>
    public let valuesByFacet: [MailProjectRuleFacet: Set<String>]
    public let subject: String
    public let body: String
    public let attachmentFilenames: [String]
    public let attachmentTexts: [String]
    public let readinessByFacet: [MailProjectRuleFacet: MailProjectMetadataReadiness]
    public let sourceFingerprint: String

    public init(id: UUID, accountID: UUID?, threadID: UUID?, messageDate: Date, correspondentIDsByRole: [MailProjectCorrespondentRole: Set<UUID>], addressesByRole: [MailProjectCorrespondentRole: Set<String>], purpose: MailPurpose?, customCategoryKeys: Set<String>, valuesByFacet: [MailProjectRuleFacet: Set<String>], subject: String, body: String, attachmentFilenames: [String], attachmentTexts: [String], readinessByFacet: [MailProjectRuleFacet: MailProjectMetadataReadiness], sourceFingerprint: String) {
        self.id = id
        self.accountID = accountID
        self.threadID = threadID
        self.messageDate = messageDate
        self.correspondentIDsByRole = correspondentIDsByRole
        self.addressesByRole = addressesByRole
        self.purpose = purpose
        self.customCategoryKeys = customCategoryKeys
        self.valuesByFacet = valuesByFacet
        self.subject = subject
        self.body = body
        self.attachmentFilenames = attachmentFilenames
        self.attachmentTexts = attachmentTexts
        self.readinessByFacet = readinessByFacet
        self.sourceFingerprint = sourceFingerprint
    }
}

public struct MailProjectSemanticTagIdentity: Hashable, Sendable, Identifiable {
    public var id: UUID { tagID }
    public let tagID: UUID

    public init(tagID: UUID) {
        self.tagID = tagID
    }

    public init?(stableKey: String) {
        guard let tagID = UUID(uuidString: stableKey) else { return nil }
        self.tagID = tagID
    }

    public var stableKey: String { tagID.uuidString.lowercased() }
}

public struct MailProjectTagRecommendation: Sendable, Equatable, Identifiable {
    public var id: MailProjectSemanticTagIdentity { tag }
    public let tag: MailProjectSemanticTagIdentity
    public let displayName: String
    public let currentMatchCount: Int
    public let score: Float
    public let cooccurrenceCount: Int
    public let projectTitleSimilarity: Float?
    public let selectedTagSimilarity: Float?
    public let strongestSelectedTag: MailProjectSemanticTagIdentity?

    public init(
        tag: MailProjectSemanticTagIdentity,
        displayName: String,
        currentMatchCount: Int,
        score: Float,
        cooccurrenceCount: Int,
        projectTitleSimilarity: Float?,
        selectedTagSimilarity: Float?,
        strongestSelectedTag: MailProjectSemanticTagIdentity?
    ) {
        self.tag = tag
        self.displayName = displayName
        self.currentMatchCount = currentMatchCount
        self.score = score
        self.cooccurrenceCount = cooccurrenceCount
        self.projectTitleSimilarity = projectTitleSimilarity
        self.selectedTagSimilarity = selectedTagSimilarity
        self.strongestSelectedTag = strongestSelectedTag
    }
}

public struct MailProjectRuleCatalogSnapshot: Sendable, Equatable {
    public let accounts: [MailProjectCatalogValue]
    public let correspondents: [MailProjectCorrespondentCatalogValue]
    public let valuesByFacet: [MailProjectRuleFacet: [MailProjectCatalogValue]]
    public let semanticValuesByCorrespondent: [UUID: [MailProjectRuleFacet: Set<String>]]
    public let semanticTagCooccurrenceCounts: [
        MailProjectSemanticTagIdentity: [MailProjectSemanticTagIdentity: Int]
    ]
    public let validityRevision: String

    public init(
        accounts: [MailProjectCatalogValue],
        correspondents: [MailProjectCorrespondentCatalogValue],
        valuesByFacet: [MailProjectRuleFacet: [MailProjectCatalogValue]],
        semanticValuesByCorrespondent: [UUID: [MailProjectRuleFacet: Set<String>]] = [:],
        semanticTagCooccurrenceCounts: [
            MailProjectSemanticTagIdentity: [MailProjectSemanticTagIdentity: Int]
        ] = [:],
        validityRevision: String
    ) {
        self.accounts = accounts
        self.correspondents = correspondents
        self.valuesByFacet = valuesByFacet
        self.semanticValuesByCorrespondent = semanticValuesByCorrespondent
        self.semanticTagCooccurrenceCounts = semanticTagCooccurrenceCounts
        self.validityRevision = validityRevision
    }
}

public struct MailProjectDependencySet: Sendable, Equatable {
    public let facets: Set<MailProjectRuleFacet>
    public let dependsOnThreadIdentity: Bool

    public init(facets: Set<MailProjectRuleFacet>, dependsOnThreadIdentity: Bool) {
        self.facets = facets
        self.dependsOnThreadIdentity = dependsOnThreadIdentity
    }
}

public struct MailProjectDecisionSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let targetKind: MailProjectDecisionTargetKind
    public let targetID: UUID
    public let decision: MailProjectDecisionValue
    public let updatedAt: Date

    public init(id: UUID, projectID: UUID, targetKind: MailProjectDecisionTargetKind, targetID: UUID, decision: MailProjectDecisionValue, updatedAt: Date) {
        self.id = id
        self.projectID = projectID
        self.targetKind = targetKind
        self.targetID = targetID
        self.decision = decision
        self.updatedAt = updatedAt
    }
}

public enum MailProjectMetadataReadiness: String, Codable, Sendable {
    case committed
    case pendingForNewMessage
    case regeneratingWithCommittedValue
}

public struct MailProjectCatalogValue: Codable, Sendable, Equatable, Identifiable {
    public var id: String { stableKey }
    public let stableKey: String
    public let displayName: String
    public let detail: String?
    public let currentMatchCount: Int
    public let isValid: Bool

    public init(
        stableKey: String,
        displayName: String,
        detail: String? = nil,
        currentMatchCount: Int,
        isValid: Bool
    ) {
        self.stableKey = stableKey
        self.displayName = displayName
        self.detail = detail
        self.currentMatchCount = currentMatchCount
        self.isValid = isValid
    }
}

public struct MailProjectCorrespondentCatalogValue: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let canonicalID: UUID
    public let displayName: String
    public let resolvedAddresses: [String]
    public let currentMatchCount: Int

    public init(
        id: UUID,
        canonicalID: UUID? = nil,
        displayName: String,
        resolvedAddresses: [String],
        currentMatchCount: Int
    ) {
        self.id = id
        self.canonicalID = canonicalID ?? id
        self.displayName = displayName
        self.resolvedAddresses = resolvedAddresses
        self.currentMatchCount = currentMatchCount
    }
}
