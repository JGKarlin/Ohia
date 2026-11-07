import Foundation
import os
import SwiftData
import OhiaCore
import OhiaML

private let logger = Logger(subsystem: "org.jgkarlin.Ohia", category: "deletion-sync")

/// Periodic worker that finalizes or drops `PendingDeletionCandidate`
/// rows whose grace period has expired. Reuses the existing
/// `MessageDeletionApplier` for the cascade — no separate code path.
@MainActor
public final class PendingDeletionReaperWorker {
    public let modelContext: ModelContext
    private let applier: MessageDeletionApplier
    private let status: DeletionSyncStatusPublisher
    private let now: () -> Date
    private let onDeletionApplied: @MainActor ([UUID], Date) -> Void

    public init(
        modelContext: ModelContext,
        applier: MessageDeletionApplier,
        status: DeletionSyncStatusPublisher,
        now: @escaping () -> Date = Date.init,
        onDeletionApplied: @escaping @MainActor ([UUID], Date) -> Void = { _, _ in }
    ) {
        self.modelContext = modelContext
        self.applier = applier
        self.status = status
        self.now = now
        self.onDeletionApplied = onDeletionApplied
    }

    /// One reaper tick. Scans for expired candidates, groups by account,
    /// recomputes `accountMessageIdCounts` per account, and either
    /// cascades (count == 1) or drops the candidate row (count > 1).
    /// Always updates the status publisher's pendingDeletionCount.
    @discardableResult
    public func runOnce() async throws -> [UUID] {
        let nowDate = now()
        let allDescriptor = FetchDescriptor<PendingDeletionCandidate>()
        let all = try modelContext.fetch(allDescriptor)
        let expired = all.filter { $0.gracePeriodEndsAt <= nowDate }
        var deletedMessageIDs: [UUID] = []

        logger.debug("Reaper tick: \(expired.count) expired candidate(s)")
        let grouped = Dictionary(grouping: expired, by: { $0.accountID })
        for (accountID, group) in grouped {
            let counts = try messageIdCounts(accountID: accountID)
            for candidate in group {
                if try retainedTrashExists(messageID: candidate.messageID) {
                    logger.info("Reaper dropping candidate for retained Trash (UID \(candidate.uid) in folder \(candidate.folder))")
                    modelContext.delete(candidate)
                    continue
                }
                let header = candidate.messageIdHeader
                let count = normalizeMessageIDHeader(header).flatMap { counts[$0] } ?? 0
                if count > 1 {
                    // Move detected late: drop candidate only.
                    logger.info("Reaper dropping candidate (move detected late, UID \(candidate.uid) in folder \(candidate.folder))")
                    modelContext.delete(candidate)
                } else {
                    // Still gone: cascade via the existing applier.
                    logger.info("Reaper cascading deferred candidate (UID \(candidate.uid) in folder \(candidate.folder))")
                    let decision: MessageDeletionDecision = .delete(
                        messageID: candidate.messageID,
                        accountID: candidate.accountID,
                        folder: candidate.folder,
                        uid: candidate.uid
                    )
                    let applied = try await applier.apply([decision])
                    deletedMessageIDs.append(contentsOf: applied.appliedMessageIDs)
                    if applied.appliedMessageIDs.isEmpty == false {
                        // Each applier call is an independently committed
                        // deletion. Publish it before later candidates or
                        // candidate-row cleanup can fail.
                        onDeletionApplied(applied.appliedMessageIDs, nowDate)
                    }
                    modelContext.delete(candidate)
                }
            }
        }
        try modelContext.save()
        // Update the status snapshot's pending count. Refetch all (some
        // may still be unexpired and stay).
        let remaining = try modelContext.fetch(FetchDescriptor<PendingDeletionCandidate>())
        status.updatePendingCount(remaining.count)
        return deletedMessageIDs
    }

    private func messageIdCounts(accountID: UUID) throws -> [String: Int] {
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { m in
            m.accountID == accountID || m.account?.id == accountID
        })
        let rows = try modelContext.fetch(descriptor)
        var counts: [String: Int] = [:]
        counts.reserveCapacity(rows.count)
        for r in rows {
            guard let header = normalizeMessageIDHeader(r.messageIdHeader) else { continue }
            counts[header, default: 0] += 1
        }
        return counts
    }

    private func retainedTrashExists(messageID: UUID) throws -> Bool {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.isTrashed == true
    }
}
