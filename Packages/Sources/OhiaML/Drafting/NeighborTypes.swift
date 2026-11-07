// Packages/Sources/OhiaML/Drafting/NeighborTypes.swift
import Foundation

public struct NeighborData: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let senderName: String
    public let subject: String
    public let similarityScore: Double
    public let relationshipLabel: String
    public let excerpt: String
    public let messageID: UUID?

    public init(
        id: UUID = UUID(),
        senderName: String,
        subject: String,
        similarityScore: Double,
        relationshipLabel: String,
        excerpt: String,
        messageID: UUID? = nil
    ) {
        self.id = id
        self.senderName = senderName
        self.subject = subject
        self.similarityScore = similarityScore
        self.relationshipLabel = relationshipLabel
        self.excerpt = excerpt
        self.messageID = messageID
    }
}

public struct FocusNeighborSet: Sendable {
    public let sourceNeighbors: [NeighborData]

    public init(sourceNeighbors: [NeighborData]) {
        self.sourceNeighbors = sourceNeighbors
    }
}
