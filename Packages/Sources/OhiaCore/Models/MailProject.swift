import Foundation
import SwiftData

@Model
public final class MailProject {
    @Attribute(.unique) public var id: UUID
    @Attribute(.unique) public private(set) var normalizedName: String
    public private(set) var displayName: String
    public var accountIDsJSON: String
    public var automaticIntakeStartAt: Date?
    public var configurationRevision: Int
    public var isPinned: Bool
    public var pinSortIndex: Int?
    public var lastMembershipUsedAt: Date?
    public var resolvedAt: Date?
    public var healthRawValue: String
    public var lastMembershipError: String?
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \MailProjectRuleGroup.project)
    public var ruleGroups: [MailProjectRuleGroup] = []

    public init(
        id: UUID = UUID(),
        displayName: String,
        accountIDs: [UUID] = [],
        automaticIntakeStartAt: Date? = nil,
        configurationRevision: Int = 1,
        isPinned: Bool = false,
        pinSortIndex: Int? = nil,
        lastMembershipUsedAt: Date? = nil,
        resolvedAt: Date? = nil,
        health: MailProjectHealth = .healthy,
        lastMembershipError: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) throws {
        let name = try Self.displayName(from: displayName)
        self.id = id
        self.displayName = name
        self.normalizedName = try Self.normalizedName(name)
        self.accountIDsJSON = try MailProjectJSON.encodeUUIDs(accountIDs)
        self.automaticIntakeStartAt = automaticIntakeStartAt
        self.configurationRevision = configurationRevision
        self.isPinned = isPinned
        self.pinSortIndex = pinSortIndex
        self.lastMembershipUsedAt = lastMembershipUsedAt
        self.resolvedAt = resolvedAt
        self.healthRawValue = health.rawValue
        self.lastMembershipError = lastMembershipError
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public func accountIDs() throws -> [UUID] {
        try MailProjectJSON.decodeUUIDs(accountIDsJSON)
    }

    public func replaceAccountIDs(_ accountIDs: [UUID]) throws {
        accountIDsJSON = try MailProjectJSON.encodeUUIDs(accountIDs)
    }

    public var health: MailProjectHealth {
        get { MailProjectHealth(rawValue: healthRawValue) ?? .needsAttention }
        set { healthRawValue = newValue.rawValue }
    }

    public func rename(to displayName: String, updatedAt: Date = .now) throws {
        let name = try Self.displayName(from: displayName)
        self.displayName = name
        self.normalizedName = try Self.normalizedName(name)
        self.updatedAt = updatedAt
    }

    public static func normalizedName(_ value: String) throws -> String {
        let name = try displayName(from: value)
        return name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func displayName(from value: String) throws -> String {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.isEmpty == false else { throw MailProjectNameError.emptyName }
        return collapsed
    }
}
