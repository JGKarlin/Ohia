import Foundation
import SwiftData

@Model
public final class MailProjectConfigurationDraft {
    public static let singletonKeyValue = "manual-project-configuration"

    public var id: UUID
    @Attribute(.unique) public private(set) var singletonKey: String
    public var targetProjectID: UUID?
    public var baseRevision: Int
    public var payloadVersion: Int
    public var payloadJSON: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        targetProjectID: UUID? = nil,
        baseRevision: Int,
        payloadVersion: Int,
        payloadJSON: String,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.singletonKey = Self.singletonKeyValue
        self.targetProjectID = targetProjectID
        self.baseRevision = baseRevision
        self.payloadVersion = payloadVersion
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}
