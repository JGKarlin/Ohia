// Packages/Sources/OhiaML/Digest/DigestBuilder.swift
import Foundation

public struct DigestInput: Sendable {
    public let messageID: UUID
    public let subject: String
    public let receivedAt: Date
    public let threadID: String?

    public init(messageID: UUID, subject: String, receivedAt: Date, threadID: String?) {
        self.messageID = messageID
        self.subject = subject
        self.receivedAt = receivedAt
        self.threadID = threadID
    }
}

public protocol DigestBuilding: Sendable {
    func buildDigest(messages: [DigestInput]) -> [DigestEntry]
}
