import Foundation
import OhiaCore

/// Per-message metadata used to enrich evidence references on account memories.
/// Subject, sender, and summary are displayed in the memory dossier UI and in
/// the markdown export so the user can trace each memory back to its sources.
public struct AccountMemoryMessageReadout: Sendable, Hashable {
    public let messageID: UUID
    public let subject: String
    public let senderAddress: String
    public let senderName: String?
    public let timestamp: Date
    public let summary: String?
    /// Thread this message belongs to, propagated onto evidence references so
    /// retrieval can group evidence by conversation and weigh sent vs received.
    public let threadID: UUID?
    /// Whether the user authored this evidence message (direction signal).
    public let isSentByUser: Bool?

    public init(
        messageID: UUID,
        subject: String,
        senderAddress: String,
        senderName: String? = nil,
        timestamp: Date,
        summary: String? = nil,
        threadID: UUID? = nil,
        isSentByUser: Bool? = nil
    ) {
        self.messageID = messageID
        self.subject = subject
        self.senderAddress = senderAddress
        self.senderName = senderName
        self.timestamp = timestamp
        self.summary = summary
        self.threadID = threadID
        self.isSentByUser = isSentByUser
    }
}

/// Identifies the dossier a distiller pass writes into: the account-wide
/// dossier, or one (correspondent | classification | project) value.
public struct AccountMemoryDimensionTarget: Sendable, Equatable {
    public let kindRaw: String
    public let value: String
    public let displayName: String

    public init(kindRaw: String, value: String, displayName: String) {
        self.kindRaw = kindRaw
        self.value = value
        self.displayName = displayName
    }

    public static let account = AccountMemoryDimensionTarget(
        kindRaw: AccountMemoryDimension.account,
        value: "",
        displayName: ""
    )
}
