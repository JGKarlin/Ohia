import Foundation
import OhiaCore

/// `@MainActor` snapshot cache keyed by signature, mirroring the pattern
/// in `ConstellationSnapshotCache`. `maxAge` eviction; explicit invalidation
/// on live-refresh events.
@MainActor
final class TimelineLayoutSnapshotCache {
    private var snapshotsBySignature: [TimelineLayoutSignature: TimelineLayoutSnapshot] = [:]

    func snapshot(
        for signature: TimelineLayoutSignature,
        maxAge: TimeInterval,
        now: Date = .now
    ) -> TimelineLayoutSnapshot? {
        guard let snapshot = snapshotsBySignature[signature] else { return nil }
        guard now.timeIntervalSince(snapshot.builtAt) <= maxAge else { return nil }
        return snapshot
    }

    func store(_ snapshot: TimelineLayoutSnapshot) {
        snapshotsBySignature[snapshot.signature] = snapshot
    }

    /// Drop any snapshot whose viewport window covers `date`. Used when a
    /// new message lands at `date` or an existing message at `date` is
    /// mutated.
    func invalidate(coveringDate date: Date) {
        for (signature, snapshot) in snapshotsBySignature {
            if snapshot.viewportRange.contains(date) {
                snapshotsBySignature.removeValue(forKey: signature)
            }
        }
    }

    /// Drop snapshots that reference any of the supplied message IDs.
    /// Cheaper than rebuilding from the SwiftData fetch when a small batch
    /// of deletions arrives — but only worthwhile when the message-id set
    /// is small relative to the cache.
    func invalidate(messageIDs: Set<UUID>) {
        guard messageIDs.isEmpty == false else { return }
        for (signature, snapshot) in snapshotsBySignature {
            let touches = snapshot.events.contains { messageIDs.contains($0.messageID) }
            if touches {
                snapshotsBySignature.removeValue(forKey: signature)
            }
        }
    }

    func clearAll() {
        snapshotsBySignature.removeAll()
    }
}
