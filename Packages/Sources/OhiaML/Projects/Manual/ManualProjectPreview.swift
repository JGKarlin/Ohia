import Foundation
import OhiaCore

public enum MailProjectPreviewRuleConfiguration: String, Codable, Sendable, Equatable {
    case proposed
    case committed
}

public enum MailProjectPreviewRuleSharedKind: String, Codable, Sendable, Equatable {
    case none
    case matched
    case unavailable
}

public enum MailProjectPreviewRulePathKind: String, Codable, Sendable, Equatable {
    case matchedGroup
    case accountWide
    case unavailable
}

public struct MailProjectPreviewRuleDetails: Codable, Sendable, Equatable {
    public let configuration: MailProjectPreviewRuleConfiguration
    public let sharedKind: MailProjectPreviewRuleSharedKind
    public let sharedConditions: [MailProjectRuleConditionSnapshot]
    public let pathKind: MailProjectPreviewRulePathKind
    public let pathConditions: [MailProjectRuleConditionSnapshot]

    public init(
        configuration: MailProjectPreviewRuleConfiguration,
        sharedKind: MailProjectPreviewRuleSharedKind,
        sharedConditions: [MailProjectRuleConditionSnapshot],
        pathKind: MailProjectPreviewRulePathKind,
        pathConditions: [MailProjectRuleConditionSnapshot]
    ) {
        self.configuration = configuration
        self.sharedKind = sharedKind
        self.sharedConditions = sharedConditions
        self.pathKind = pathKind
        self.pathConditions = pathConditions
    }
}

public struct MailProjectPreviewMembership: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { messageID }
    public let messageID: UUID
    public let source: MailProjectMembershipSource
    public let provenance: MailProjectMembershipProvenance
    public let ruleDetails: MailProjectPreviewRuleDetails?

    public init(
        messageID: UUID,
        source: MailProjectMembershipSource,
        provenance: MailProjectMembershipProvenance,
        ruleDetails: MailProjectPreviewRuleDetails? = nil
    ) {
        self.messageID = messageID
        self.source = source
        self.provenance = provenance
        self.ruleDetails = ruleDetails
    }
}

public enum MailProjectBroadRuleReason: String, Codable, Sendable, Equatable, CaseIterable {
    case exclusionOnlyGroup
    case singlePositiveCondition
    case matchesAllEligibleMessages
}

public struct MailProjectBroadRuleWarning: Codable, Sendable, Equatable {
    public let reasons: [MailProjectBroadRuleReason]
    public let exactMatchCount: Int
    public let eligibleMessageCount: Int

    public init(
        reasons: [MailProjectBroadRuleReason],
        exactMatchCount: Int,
        eligibleMessageCount: Int
    ) {
        self.reasons = Array(Set(reasons)).sorted { lhs, rhs in
            let order = Dictionary(
                uniqueKeysWithValues: MailProjectBroadRuleReason.allCases.enumerated().map { ($1, $0) }
            )
            return order[lhs, default: 0] < order[rhs, default: 0]
        }
        self.exactMatchCount = exactMatchCount
        self.eligibleMessageCount = eligibleMessageCount
    }
}

public struct MailProjectPreview: Codable, Sendable, Equatable {
    public let projectID: UUID
    public let candidateRevision: Int
    public let fingerprint: String
    public let willBeAdded: [MailProjectPreviewMembership]
    public let willBeRemoved: [MailProjectPreviewMembership]
    public let unchangedExceptions: [MailProjectPreviewMembership]
    public let exactMatchCount: Int
    public let broadRuleWarning: MailProjectBroadRuleWarning?
    public let health: MailProjectHealth

    public init(
        projectID: UUID,
        candidateRevision: Int,
        fingerprint: String,
        willBeAdded: [MailProjectPreviewMembership],
        willBeRemoved: [MailProjectPreviewMembership],
        unchangedExceptions: [MailProjectPreviewMembership],
        exactMatchCount: Int,
        broadRuleWarning: MailProjectBroadRuleWarning?,
        health: MailProjectHealth
    ) {
        self.projectID = projectID
        self.candidateRevision = candidateRevision
        self.fingerprint = fingerprint
        self.willBeAdded = willBeAdded.sorted(by: Self.membershipOrder)
        self.willBeRemoved = willBeRemoved.sorted(by: Self.membershipOrder)
        self.unchangedExceptions = unchangedExceptions.sorted(by: Self.membershipOrder)
        self.exactMatchCount = exactMatchCount
        self.broadRuleWarning = broadRuleWarning
        self.health = health
    }

    private static func membershipOrder(
        _ lhs: MailProjectPreviewMembership,
        _ rhs: MailProjectPreviewMembership
    ) -> Bool {
        lhs.messageID.uuidString < rhs.messageID.uuidString
    }
}

public enum MailProjectSaveOutcome: Sendable, Equatable {
    case saved(projectID: UUID, configurationRevision: Int)
    case reviewRequired(MailProjectPreview)
}

extension MailProjectSaveOutcome: Codable {
    private enum Kind: String, Codable {
        case saved
        case reviewRequired
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case projectID
        case configurationRevision
        case preview
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .saved:
            guard container.contains(.preview) == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .preview,
                    in: container,
                    debugDescription: "A saved outcome cannot carry a review preview."
                )
            }
            self = .saved(
                projectID: try container.decode(UUID.self, forKey: .projectID),
                configurationRevision: try container.decode(Int.self, forKey: .configurationRevision)
            )
        case .reviewRequired:
            guard container.contains(.projectID) == false,
                  container.contains(.configurationRevision) == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "A review-required outcome cannot carry committed identity fields."
                )
            }
            self = .reviewRequired(
                try container.decode(MailProjectPreview.self, forKey: .preview)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .saved(projectID, configurationRevision):
            try container.encode(Kind.saved, forKey: .kind)
            try container.encode(projectID, forKey: .projectID)
            try container.encode(configurationRevision, forKey: .configurationRevision)
        case let .reviewRequired(preview):
            try container.encode(Kind.reviewRequired, forKey: .kind)
            try container.encode(preview, forKey: .preview)
        }
    }
}
