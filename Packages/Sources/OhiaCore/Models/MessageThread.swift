import Foundation
import SwiftData

@Model
public final class MessageThread {
    public var id: UUID
    public var subjectRoot: String
    public var messageCount: Int
    public var firstMessageAt: Date?
    public var lastMessageAt: Date?
    public var participantCount: Int

    @Relationship(deleteRule: .nullify, inverse: \Message.thread)
    public var messages: [Message] = []

    public init(subjectRoot: String) {
        self.id = UUID()
        self.subjectRoot = subjectRoot
        self.messageCount = 0
        self.participantCount = 0
    }
}
