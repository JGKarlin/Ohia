// Ohia/Shell/OutboxActivitySnapshotStore.swift
import Foundation
import Observation
import OhiaCore

@Observable
@MainActor
final class OutboxActivitySnapshotStore {
    static let shared = OutboxActivitySnapshotStore()

    var recentItems: [OutboxItemSnapshot] = []
    var breakdown: OutboxStatusBreakdown = OutboxStatusBreakdown(
        queued: 0, sending: 0, sent: 0, sentToday: 0, failed: 0, cancelled: 0
    )

    struct OutboxItemSnapshot: Identifiable, Sendable {
        let id: UUID
        let status: OutboxStatus
        let createdAt: Date
    }

    /// Called by `ActivityStripView` after its @Query refreshes. We copy the
    /// 5 most-recent-created items into Sendable snapshots so the chip can
    /// render without holding live @Model references (which would require
    /// a modelContext observer).
    func update(from items: [OutboxItem]) {
        breakdown = OutboxStatusBreakdown.summarize(items)
        let top5 = items
            .sorted(by: { $0.createdAt > $1.createdAt })
            .prefix(5)
            .map { OutboxItemSnapshot(id: $0.id, status: $0.status, createdAt: $0.createdAt) }
        recentItems = Array(top5)
    }
}
