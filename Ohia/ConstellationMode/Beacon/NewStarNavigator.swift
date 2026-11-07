// NewStarNavigator.swift
// Tracks newly-arrived message stars while Constellation is open. The queue
// is message-level, not vector-level: a four-moon message still counts as one
// new star.

import Foundation
import Observation
import simd
import OhiaCore

struct NewStarCandidate: Sendable {
    let messageId: String
    let vectorId: Int64
    let world: SIMD3<Float>
    let record: VectorRecord
    let receivedAt: Date

    /// Reconstructs the focus target for an arrival the canonical ledger has
    /// already announced. The ledger's announcement gate has independently
    /// verified pipeline readiness and placement; this factory deliberately
    /// does not repeat the navigator's `MessageFilterRow` readiness checks,
    /// because a long-lived SwiftData context can briefly hold an older row
    /// snapshot after the worker has committed the ready state.
    static func announcedArrival(
        messageId: String,
        record: VectorRecord,
        row: MessageFilterRow
    ) -> NewStarCandidate? {
        guard record.messageId == messageId,
              let x = record.layoutX,
              let y = record.layoutY,
              let z = record.layoutZ else {
            return nil
        }
        return NewStarCandidate(
            messageId: messageId,
            vectorId: record.vectorId,
            world: SIMD3<Float>(x, y, z),
            record: record,
            receivedAt: row.receivedAt ?? row.ingestedAt
        )
    }
}

@Observable @MainActor
final class NewStarNavigator {
    private(set) var pending: [NewStarCandidate] = []
    private(set) var formingMessageIds: Set<String> = []

    private var liveInboundMessageIds: Set<String> = []
    private var baselineEstablished = false
    private var knownMessageIds: Set<String> = []
    private let sessionStartedAt: Date
    private let baselineGrace: TimeInterval

    init(
        sessionStartedAt: Date = Date.now,
        baselineGrace: TimeInterval = 30
    ) {
        self.sessionStartedAt = sessionStartedAt
        self.baselineGrace = baselineGrace
    }

    // No badge count here: the badge number is the arrival ledger's
    // `unvisitedCount` — the navigator is only the spatial navigation queue,
    // and its pending entries can be scope-dropped and re-promoted without
    // the user-facing count ever changing.
    var pendingCount: Int { pending.count + formingMessageIds.count }
    var formingCount: Int { formingMessageIds.count }
    var readyCount: Int { pending.count }
    var pendingVectorIds: Set<Int64> { Set(pending.map(\.vectorId)) }
    var trackedMessageIds: [String] {
        Array(liveInboundMessageIds.union(formingMessageIds)).sorted()
    }

    /// Returns the exact ready arrival requested by an external navigation
    /// command. Notification clicks must not fall back to `pending.first`:
    /// grouped notifications target their primary message, while this queue
    /// remains intentionally oldest-first for repeated beacon navigation.
    func candidate(messageId: String) -> NewStarCandidate? {
        pending.first { $0.messageId == messageId }
    }

    var formationNoticeText: String? {
        guard formingCount > 0 else { return nil }
        return formingCount == 1
            ? "A new node is forming!"
            : "\(formingCount) new nodes are forming!"
    }

    func noteInboundMessageIDs(_ messageIds: [String]) {
        let ids = Set(messageIds.filter { !$0.isEmpty })
        guard ids.isEmpty == false else { return }
        liveInboundMessageIds.formUnion(ids)
    }

    func candidateMessageIdsNeedingRecords(
        messageIndex: [String: MessageFilterRow],
        availableRecords: [VectorRecord]
    ) -> [String] {
        let unresolved = trackedMessageIdsNeedingRecords(
            messageIndex: messageIndex,
            availableRecords: availableRecords
        )
        guard baselineEstablished else { return unresolved }
        let availableMessageIds = availableMessageIds(from: availableRecords)
        let newlyArrived = messageIndex.keys.filter { messageId in
            guard knownMessageIds.contains(messageId) == false,
                  availableMessageIds.contains(messageId) == false,
                  let row = messageIndex[messageId] else {
                return false
            }
            return shouldNotify(row: row) && isReadyForUserAlert(row: row)
        }
        return Array(Set(unresolved).union(newlyArrived)).sorted()
    }

    func trackedMessageIdsNeedingRecords(
        messageIndex: [String: MessageFilterRow],
        availableRecords: [VectorRecord]
    ) -> [String] {
        let availableMessageIds = availableMessageIds(from: availableRecords)
        let tracked = formingMessageIds.union(liveInboundMessageIds).filter { messageId in
            guard let row = messageIndex[messageId] else {
                return false
            }
            return isReadyForUserAlert(row: row)
                && availableMessageIds.contains(messageId) == false
        }
        return Array(tracked).sorted()
    }

    func sync(
        records: [VectorRecord],
        messageIndex: [String: MessageFilterRow]
    ) {
        sync(records: records, messageIndex: messageIndex, includesUntrackedArrivals: true)
    }

    func syncTrackedLiveInbound(
        records: [VectorRecord],
        messageIndex: [String: MessageFilterRow]
    ) {
        sync(records: records, messageIndex: messageIndex, includesUntrackedArrivals: false)
    }

    private func sync(
        records: [VectorRecord],
        messageIndex: [String: MessageFilterRow],
        includesUntrackedArrivals: Bool
    ) {
        if baselineEstablished == false {
            knownMessageIds = Set(messageIndex.keys)
            baselineEstablished = true
            pending.removeAll()
        }

        let recordByMessageId = representativeRecords(from: records)
        let existingIds = Set(messageIndex.keys)
        pending.removeAll { existingIds.contains($0.messageId) == false }
        // Live IMAP can notify before summarization, embedding, and placement
        // have all caught up. Keep those IDs quiet until the pipeline is
        // ready for a user-visible alert, then show forming only while waiting
        // for a placed vector.

        for messageId in liveInboundMessageIds.union(formingMessageIds).sorted() {
            guard let row = messageIndex[messageId],
                  isReadyForUserAlert(row: row) else {
                continue
            }
            guard let ready = readyCandidate(
                messageId: messageId,
                recordByMessageId: recordByMessageId
            ) else {
                liveInboundMessageIds.remove(messageId)
                formingMessageIds.insert(messageId)
                knownMessageIds.insert(messageId)
                continue
            }
            enqueueCandidate(messageId: messageId, record: ready.record, world: ready.world, row: row)
            liveInboundMessageIds.remove(messageId)
            formingMessageIds.remove(messageId)
            knownMessageIds.insert(messageId)
        }

        if includesUntrackedArrivals {
            for messageId in existingIds.sorted() where knownMessageIds.contains(messageId) == false {
                guard let row = messageIndex[messageId] else { continue }
                guard shouldNotify(row: row) else {
                    knownMessageIds.insert(messageId)
                    continue
                }
                guard isReadyForUserAlert(row: row) else {
                    continue
                }
                guard let ready = readyCandidate(
                    messageId: messageId,
                    recordByMessageId: recordByMessageId
                ) else {
                    // The row may arrive before vector placement has completed.
                    // Leave it in the forming queue so the sunburst can wake
                    // immediately, then promote it as soon as a placed vector
                    // exists.
                    formingMessageIds.insert(messageId)
                    knownMessageIds.insert(messageId)
                    continue
                }
                enqueueCandidate(messageId: messageId, record: ready.record, world: ready.world, row: row)
                knownMessageIds.insert(messageId)
            }
        }

        pending.sort {
            if $0.receivedAt != $1.receivedAt { return $0.receivedAt < $1.receivedAt }
            return $0.vectorId < $1.vectorId
        }
    }

    func consumeNext() -> NewStarCandidate? {
        guard pending.isEmpty == false else { return nil }
        return pending.removeFirst()
    }

    func markVisited(messageId: String) {
        pending.removeAll { $0.messageId == messageId }
        formingMessageIds.remove(messageId)
        liveInboundMessageIds.remove(messageId)
        knownMessageIds.insert(messageId)
    }

    func remove(vectorIds: Set<Int64>, messageIds: Set<String>) {
        guard vectorIds.isEmpty == false || messageIds.isEmpty == false else { return }
        pending.removeAll { vectorIds.contains($0.vectorId) || messageIds.contains($0.messageId) }
        formingMessageIds.subtract(messageIds)
        liveInboundMessageIds.subtract(messageIds)
        knownMessageIds.subtract(messageIds)
    }

    private func enqueueCandidate(
        messageId: String,
        record: VectorRecord,
        world: SIMD3<Float>,
        row: MessageFilterRow
    ) {
        guard pending.contains(where: { $0.messageId == messageId }) == false else { return }
        pending.append(NewStarCandidate(
            messageId: messageId,
            vectorId: record.vectorId,
            world: world,
            record: record,
            receivedAt: row.receivedAt ?? row.ingestedAt
        ))
    }

    private func shouldNotify(row: MessageFilterRow) -> Bool {
        guard row.isSentByUser == false else { return false }
        let meaningfulDate = row.receivedAt ?? row.ingestedAt
        return meaningfulDate >= sessionStartedAt.addingTimeInterval(-baselineGrace)
    }

    private func isReadyForUserAlert(row: MessageFilterRow) -> Bool {
        guard row.isSentByUser == false,
              row.embeddingStatus == .completed,
              row.bodySummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              row.mailClassification != nil,
              row.isActionable != nil,
              row.requiresConfirmation != nil else {
            return false
        }
        return true
    }

    private func readyCandidate(
        messageId: String,
        recordByMessageId: [String: VectorRecord]
    ) -> (record: VectorRecord, world: SIMD3<Float>)? {
        guard let record = recordByMessageId[messageId],
              let world = Self.worldPosition(for: record) else {
            return nil
        }
        return (record, world)
    }

    private func availableMessageIds(from records: [VectorRecord]) -> Set<String> {
        Set(records.compactMap { record in
            Self.worldPosition(for: record) == nil ? nil : record.messageId
        })
    }

    private func representativeRecords(from records: [VectorRecord]) -> [String: VectorRecord] {
        var byMessageId: [String: VectorRecord] = [:]
        for record in records where Self.worldPosition(for: record) != nil {
            guard let current = byMessageId[record.messageId] else {
                byMessageId[record.messageId] = record
                continue
            }
            if shouldPrefer(record, over: current) {
                byMessageId[record.messageId] = record
            }
        }
        return byMessageId
    }

    private func shouldPrefer(_ candidate: VectorRecord, over current: VectorRecord) -> Bool {
        let candidateRank = collectionRank(candidate.collection)
        let currentRank = collectionRank(current.collection)
        if candidateRank != currentRank { return candidateRank < currentRank }
        if candidate.chunkIndex != current.chunkIndex { return candidate.chunkIndex < current.chunkIndex }
        return candidate.vectorId < current.vectorId
    }

    private func collectionRank(_ collection: VectorCollection) -> Int {
        switch collection {
        case .context: return 0
        case .attachment: return 1
        case .entity: return 2
        case .style: return 3
        }
    }

    private static func worldPosition(for record: VectorRecord) -> SIMD3<Float>? {
        guard let x = record.layoutX, let y = record.layoutY, let z = record.layoutZ else {
            return nil
        }
        return SIMD3<Float>(x, y, z)
    }
}
