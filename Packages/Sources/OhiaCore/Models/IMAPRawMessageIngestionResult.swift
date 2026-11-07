import Foundation

public struct IMAPRawMessageIngestionResult: Sendable, Equatable {
    public enum Disposition: String, Sendable, Equatable, Codable {
        case skipped
        case repairedExisting
        case insertedNew
    }

    public let disposition: Disposition
    public let messageId: UUID?
    public let isSentByUser: Bool
    public let hasSummarizableBody: Bool
    public let allowsLiveInboundNotification: Bool

    public init(
        disposition: Disposition,
        messageId: UUID?,
        isSentByUser: Bool = false,
        hasSummarizableBody: Bool = false,
        allowsLiveInboundNotification: Bool = true
    ) {
        self.disposition = disposition
        self.messageId = messageId
        self.isSentByUser = isSentByUser
        self.hasSummarizableBody = hasSummarizableBody
        self.allowsLiveInboundNotification = allowsLiveInboundNotification
    }

    public static let skipped = IMAPRawMessageIngestionResult(
        disposition: .skipped,
        messageId: nil,
        allowsLiveInboundNotification: false
    )

    public var shouldAutomaticallySummarize: Bool {
        disposition == .insertedNew
            && messageId != nil
    }
}
