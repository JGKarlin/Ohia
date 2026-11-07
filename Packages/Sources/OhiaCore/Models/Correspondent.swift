import Foundation
import SwiftData

@Model
public final class Correspondent {
    public var id: UUID
    public var primaryName: String
    public var primaryEmail: String
    public var organization: String?
    public var domain: String?
    public var messageCount: Int
    public var firstSeenAt: Date?
    public var lastSeenAt: Date?
    public var familiarityScore: Double
    public var profileJSON: String?

    @Relationship(deleteRule: .nullify, inverse: \Participant.correspondent)
    public var linkedParticipants: [Participant] = []

    public init(primaryName: String, primaryEmail: String) {
        self.id = UUID()
        self.primaryName = primaryName
        self.primaryEmail = primaryEmail.lowercased()
        self.messageCount = 0
        self.familiarityScore = 0.0
    }
}
