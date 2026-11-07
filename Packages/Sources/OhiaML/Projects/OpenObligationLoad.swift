import Foundation

public struct OpenObligationLoad: Codable, Sendable, Equatable, Hashable {
    public let pendingReplyCount: Int
    public let confirmationCount: Int
    public let rawOpenCount: Int
    public let openMessageCount: Int
    public let visibleOpenCount: Int

    public init(
        pendingReplyCount: Int,
        confirmationCount: Int,
        resolvedByUser: Bool,
        openMessageCount: Int? = nil
    ) {
        self.pendingReplyCount = max(0, pendingReplyCount)
        self.confirmationCount = max(0, confirmationCount)
        self.rawOpenCount = self.pendingReplyCount + self.confirmationCount
        self.openMessageCount = max(0, openMessageCount ?? self.rawOpenCount)
        self.visibleOpenCount = resolvedByUser ? 0 : self.openMessageCount
    }

    public var hasVisibleObligations: Bool {
        visibleOpenCount > 0
    }
}
