import Foundation

public struct IMAPSelectState: Sendable, Equatable {
    public let uidValidity: UInt32
    public var exists: Int
    public var uidNext: UInt32
    public var recent: Int

    public init(uidValidity: UInt32, exists: Int, uidNext: UInt32, recent: Int) {
        self.uidValidity = uidValidity
        self.exists = exists
        self.uidNext = uidNext
        self.recent = recent
    }
}

public struct IMAPFlagSnapshot: Sendable, Equatable {
    public let uid: UInt32
    public let isSeen: Bool

    public init(uid: UInt32, isSeen: Bool) {
        self.uid = uid
        self.isSeen = isSeen
    }

    public init(uid: UInt32, flags: Set<String>) {
        self.uid = uid
        self.isSeen = flags.contains { flag in
            flag.caseInsensitiveCompare("\\Seen") == .orderedSame
        }
    }
}

public struct IMAPSelectQRESYNCResult: Sendable, Equatable {
    public let select: IMAPSelectState
    public let highestModSeq: UInt64?
    public let vanishedUIDs: [UInt32]
    public let flagSnapshots: [IMAPFlagSnapshot]

    public init(
        select: IMAPSelectState,
        highestModSeq: UInt64?,
        vanishedUIDs: [UInt32],
        flagSnapshots: [IMAPFlagSnapshot] = []
    ) {
        self.select = select
        self.highestModSeq = highestModSeq
        self.vanishedUIDs = vanishedUIDs
        self.flagSnapshots = flagSnapshots
    }
}
