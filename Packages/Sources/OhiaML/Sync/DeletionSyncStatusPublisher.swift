import Foundation
import Observation

@Observable
@MainActor
public final class DeletionSyncStatusPublisher {
    public struct Snapshot: Sendable, Equatable {
        public var lastSyncAt: Date?
        public var lastFolder: String?
        public var lastSyncCapability: Capability
        public var sessionRemovals: Int
        public var lifetimeRemovals: Int
        public var lastUIDs: [UInt32]
        public var aborts: Int
        public var pendingDeletionCount: Int
    }

    public enum Capability: String, Sendable, Equatable {
        case qresync
        case fallbackUIDSearch
        case unknown
    }

    public enum AbortReason: Sendable, Equatable {
        case uidValidityChanged(old: UInt32, new: UInt32)
        case applierFailed(message: String)
    }

    public private(set) var snapshot: Snapshot

    private let userDefaults: UserDefaults
    private static let lifetimeKey = "ohia.deletion-sync.lifetime-removals"
    private static let lastUIDsCap = 8

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let lifetime = userDefaults.integer(forKey: Self.lifetimeKey)
        self.snapshot = Snapshot(
            lastSyncAt: nil,
            lastFolder: nil,
            lastSyncCapability: .unknown,
            sessionRemovals: 0,
            lifetimeRemovals: lifetime,
            lastUIDs: [],
            aborts: 0,
            pendingDeletionCount: 0
        )
    }

    public func recordApplied(folder: String, capability: Capability, uids: [UInt32], at date: Date = Date()) {
        snapshot.lastSyncAt = date
        snapshot.lastFolder = folder
        snapshot.lastSyncCapability = capability
        snapshot.sessionRemovals += uids.count
        snapshot.lifetimeRemovals += uids.count
        let merged = Array(uids.reversed()) + snapshot.lastUIDs
        snapshot.lastUIDs = Array(merged.prefix(Self.lastUIDsCap))
        userDefaults.set(snapshot.lifetimeRemovals, forKey: Self.lifetimeKey)
    }

    public func recordSync(folder: String, capability: Capability, at date: Date = Date()) {
        snapshot.lastSyncAt = date
        snapshot.lastFolder = folder
        snapshot.lastSyncCapability = capability
    }

    public func recordAbort(folder: String, reason: AbortReason, at date: Date = Date()) {
        snapshot.aborts += 1
        snapshot.lastSyncAt = date
        snapshot.lastFolder = folder
    }

    public func updatePendingCount(_ count: Int) {
        snapshot.pendingDeletionCount = count
    }
}
