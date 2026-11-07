import Foundation
import SwiftData

@Model
public final class MailProjectDecision {
    public var id: UUID
    public private(set) var projectID: UUID
    public private(set) var targetKindRawValue: String
    public private(set) var targetID: UUID
    public var decisionRawValue: String
    public var createdAt: Date
    public var updatedAt: Date
    @Attribute(.unique) public private(set) var decisionKey: String

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        targetKind: MailProjectDecisionTargetKind,
        targetID: UUID,
        decision: MailProjectDecisionValue,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.targetKindRawValue = targetKind.rawValue
        self.targetID = targetID
        self.decisionRawValue = decision.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.decisionKey = Self.key(projectID: projectID, targetKind: targetKind, targetID: targetID)
    }

    public private(set) var targetKind: MailProjectDecisionTargetKind {
        get { MailProjectDecisionTargetKind(rawValue: targetKindRawValue) ?? .message }
        set {
            targetKindRawValue = newValue.rawValue
            decisionKey = Self.key(projectID: projectID, targetKind: newValue, targetID: targetID)
        }
    }

    public var decision: MailProjectDecisionValue {
        get { MailProjectDecisionValue(rawValue: decisionRawValue) ?? .exclude }
        set { decisionRawValue = newValue.rawValue }
    }

    public static func key(
        projectID: UUID,
        targetKind: MailProjectDecisionTargetKind,
        targetID: UUID
    ) -> String {
        "\(projectID.uuidString)|\(targetKind.rawValue)|\(targetID.uuidString)"
    }
}

@Model
public final class MailProjectMembership {
    public var id: UUID
    public private(set) var projectID: UUID
    public private(set) var messageID: UUID
    public var configurationRevision: Int
    public var sourceRawValue: String
    public var matchingGroupID: UUID?
    public var matchingConditionIDsJSON: String
    public var provenanceJSON: String
    public var sourceFingerprint: String
    public var evaluatedAt: Date
    @Attribute(.unique) public private(set) var membershipKey: String

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        messageID: UUID,
        configurationRevision: Int,
        source: MailProjectMembershipSource,
        matchingGroupID: UUID? = nil,
        matchingConditionIDs: [UUID],
        provenanceJSON: String = "{}",
        sourceFingerprint: String = "",
        evaluatedAt: Date = .now
    ) throws {
        self.id = id
        self.projectID = projectID
        self.messageID = messageID
        self.configurationRevision = configurationRevision
        self.sourceRawValue = source.rawValue
        self.matchingGroupID = matchingGroupID
        self.matchingConditionIDsJSON = try MailProjectJSON.encodeUUIDs(matchingConditionIDs)
        self.provenanceJSON = provenanceJSON
        self.sourceFingerprint = sourceFingerprint
        self.evaluatedAt = evaluatedAt
        self.membershipKey = Self.key(projectID: projectID, messageID: messageID)
    }

    public var source: MailProjectMembershipSource {
        get { MailProjectMembershipSource(rawValue: sourceRawValue) ?? .rule }
        set { sourceRawValue = newValue.rawValue }
    }

    public func matchingConditionIDs() throws -> [UUID] {
        try MailProjectJSON.decodeUUIDs(matchingConditionIDsJSON)
    }

    public func replaceMatchingConditionIDs(_ conditionIDs: [UUID]) throws {
        matchingConditionIDsJSON = try MailProjectJSON.encodeUUIDs(conditionIDs)
    }

    public static func key(projectID: UUID, messageID: UUID) -> String {
        "\(projectID.uuidString)|\(messageID.uuidString)"
    }
}
