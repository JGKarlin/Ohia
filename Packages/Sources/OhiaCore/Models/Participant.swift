import Foundation
import SwiftData

@Model
public final class Participant {
    public var id: UUID
    public var emailAddress: String
    public var displayName: String?
    public var correspondent: Correspondent?

    public init(emailAddress: String, displayName: String? = nil) {
        self.id = UUID()
        self.emailAddress = emailAddress.lowercased()
        self.displayName = displayName
    }
}

@Model
public final class MessageParticipant {
    public var id: UUID
    public var message: Message?
    public var participant: Participant?
    public var role: ParticipantRole
    /// Zero-based order within the source header for this role. Optional for
    /// lightweight migration; reply-all falls back to relationship order for
    /// legacy rows until reset and re-ingestion.
    public var headerPosition: Int?

    public init(message: Message, participant: Participant, role: ParticipantRole) {
        self.id = UUID()
        self.message = message
        self.participant = participant
        self.role = role
        self.headerPosition = nil
    }

    public init(
        message: Message,
        participant: Participant,
        role: ParticipantRole,
        headerPosition: Int?
    ) {
        self.id = UUID()
        self.message = message
        self.participant = participant
        self.role = role
        self.headerPosition = headerPosition
    }
}
