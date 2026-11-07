import Foundation

public struct EntityPromotionWork: Sendable, Equatable {
    public var embedIds: [UUID]
    public var refreshIds: [UUID]

    public init(embedIds: [UUID] = [], refreshIds: [UUID] = []) {
        self.embedIds = embedIds
        self.refreshIds = refreshIds
    }

    public var isEmpty: Bool {
        embedIds.isEmpty && refreshIds.isEmpty
    }

    public var count: Int {
        embedIds.count + refreshIds.count
    }
}
