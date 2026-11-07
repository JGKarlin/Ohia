// Packages/Sources/OhiaML/Digest/DigestEntry.swift
import Foundation

public struct DigestEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let headline: String
    public let keyTakeaway: String
    public let sourceCount: Int
    public let timeSpan: String
    public let messageIDs: [UUID]
    public let expandedSummary: String?

    public init(
        id: UUID = UUID(),
        headline: String,
        keyTakeaway: String,
        sourceCount: Int,
        timeSpan: String,
        messageIDs: [UUID],
        expandedSummary: String? = nil
    ) {
        self.id = id
        self.headline = headline
        self.keyTakeaway = keyTakeaway
        self.sourceCount = sourceCount
        self.timeSpan = timeSpan
        self.messageIDs = messageIDs
        self.expandedSummary = expandedSummary
    }
}
