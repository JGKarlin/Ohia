import Foundation

public struct IMAPDraftRemoteLocation: Sendable, Equatable {
    public let folder: String
    public let uid: UInt32?
    public let uidValidity: UInt32?
    public let messageIDHeader: String
    public let cleanupErrorDescription: String?

    public init(
        folder: String,
        uid: UInt32?,
        uidValidity: UInt32?,
        messageIDHeader: String,
        cleanupErrorDescription: String? = nil
    ) {
        self.folder = folder
        self.uid = uid
        self.uidValidity = uidValidity
        self.messageIDHeader = messageIDHeader
        self.cleanupErrorDescription = cleanupErrorDescription
    }
}
