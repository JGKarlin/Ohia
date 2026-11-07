import Foundation
import SwiftData

@Model
public final class Entity {
    public var id: UUID
    public var kind: EntityKind
    public var key: String
    public var displayName: String
    public var supportCount: Int
    public var supportWeight: Double
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var profileJSON: String?
    public var vectorRowId: Int64?
    public var supportCountAtLastEmbed: Int
    public var roleDistributionAtLastEmbedJSON: String?

    public init(kind: EntityKind, key: String, displayName: String) {
        self.id = UUID()
        self.kind = kind
        self.key = key
        self.displayName = displayName
        self.supportCount = 0
        self.supportWeight = 0
        let now = Date()
        self.firstSeenAt = now
        self.lastSeenAt = now
        self.profileJSON = nil
        self.vectorRowId = nil
        self.supportCountAtLastEmbed = 0
        self.roleDistributionAtLastEmbedJSON = nil
    }
}
