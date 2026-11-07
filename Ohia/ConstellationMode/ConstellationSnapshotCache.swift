import Foundation
import simd
import OhiaCore
import OhiaML

/// The arrival-gated message index of one frame's cached snapshot, reused
/// between reads. The gated index depends only on that snapshot and on the
/// arrival ledger's visibility gate, so a read that finds both unchanged
/// returns the previous result instead of filtering every row into a new
/// dictionary. When the gate removes nothing, the snapshot's own index is
/// returned, so the memo holds no second copy of it.
@MainActor
final class GatedMessageIndexMemo {
    private struct Key: Equatable {
        let frame: FrameKey
        let contentRevision: UInt64
        let gate: NewMailArrivalVisibilityGate
    }

    private var key: Key?
    private var value: [String: MessageFilterRow] = [:]

    func messageIndex(
        frame: FrameKey,
        contentRevision: UInt64,
        gate: NewMailArrivalVisibilityGate,
        source: () -> [String: MessageFilterRow],
        filter: ([String: MessageFilterRow]) -> [String: MessageFilterRow]
    ) -> [String: MessageFilterRow] {
        let key = Key(frame: frame, contentRevision: contentRevision, gate: gate)
        if self.key == key {
            return value
        }
        let unfiltered = source()
        let filtered = filter(unfiltered)
        value = filtered.count == unfiltered.count ? unfiltered : filtered
        self.key = key
        return value
    }
}

@MainActor
final class ConstellationSnapshotCache {
    private var snapshotsByFrame: [FrameKey: ConstellationSnapshot] = [:] {
        didSet { contentRevision &+= 1 }
    }
    /// Advances on every change to any cached snapshot, so a value derived
    /// from a snapshot can be reused until this changes.
    private(set) var contentRevision: UInt64 = 0
    private var sourceVersions: [FrameKey: TimeInterval] = [:]
    private var revision: UInt64 = 0
    private var inFlight: Load?

    private struct Load {
        let id: UUID
        let frame: FrameKey
        let revision: UInt64
        let sourceVersion: TimeInterval?
        let task: Task<ConstellationSnapshot, Error>
        var consumers: Set<UUID>
    }

    /// One preparation can run at a time, including across lens switches.
    /// Equivalent toolbar consumers share it. A new source version waits for
    /// the current operation to unwind, rather than queuing more SQL behind
    /// the same connection lock. The loader captures current inputs afresh
    /// whenever a mutation invalidates a pending result.
    func load(
        for frame: FrameKey,
        maxAge: TimeInterval = .greatestFiniteMagnitude,
        forceRefresh: Bool = false,
        sourceVersion: TimeInterval? = nil,
        loader: @escaping @MainActor () async throws -> ConstellationSnapshot
    ) async throws -> ConstellationSnapshot {
        let consumer = UUID()
        while true {
            try Task.checkCancellation()
            let versionMatches = sourceVersion == nil || sourceVersions[frame] == sourceVersion
            if !forceRefresh, versionMatches,
               let cached = snapshot(for: frame, maxAge: maxAge) {
                return cached
            }
            if inFlight == nil {
                inFlight = Load(
                    id: UUID(), frame: frame, revision: revision,
                    sourceVersion: sourceVersion,
                    task: Task { try await loader() }, consumers: []
                )
            }
            guard let active = inFlight else { continue }
            let matches = active.frame == frame
                && active.revision == revision
                && active.sourceVersion == sourceVersion
            if matches { inFlight?.consumers.insert(consumer) }

            let result = await withTaskCancellationHandler {
                await active.task.result
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.releaseConsumer(consumer, loadID: active.id)
                }
            }
            releaseConsumer(consumer, loadID: active.id, cancelIfUnused: false)
            if inFlight?.id == active.id {
                inFlight = nil
                if active.revision == revision, !active.task.isCancelled,
                   case .success(let snapshot) = result {
                    snapshotsByFrame[active.frame] = snapshot
                    sourceVersions[active.frame] = active.sourceVersion
                }
            }
            try Task.checkCancellation()
            guard matches, active.revision == revision, !active.task.isCancelled else { continue }
            return try result.get()
        }
    }

    private func releaseConsumer(_ consumer: UUID, loadID: UUID, cancelIfUnused: Bool = true) {
        guard inFlight?.id == loadID,
              inFlight?.consumers.remove(consumer) != nil else { return }
        if cancelIfUnused, inFlight?.consumers.isEmpty == true {
            inFlight?.task.cancel()
        }
    }

    private func invalidatePendingLoad() {
        revision &+= 1
        inFlight?.task.cancel()
    }

    func snapshot(for frame: FrameKey, maxAge: TimeInterval, now: Date = .now) -> ConstellationSnapshot? {
        guard let snapshot = snapshotsByFrame[frame],
              now.timeIntervalSince(snapshot.builtAt) <= maxAge else {
            return nil
        }
        return snapshot
    }

    func store(_ snapshot: ConstellationSnapshot) {
        invalidatePendingLoad()
        snapshotsByFrame[snapshot.frame] = snapshot
        sourceVersions.removeValue(forKey: snapshot.frame)
    }

    /// Inserts (or replaces) freshly-announced live arrivals in every cached
    /// frame snapshot. The unified arrival moment patches the cache
    /// synchronously in the announce turn so the very next packet build —
    /// and the starburst navigation guard — see the message immediately,
    /// instead of waiting the seconds a full snapshot rebuild takes. The
    /// canonical rebuild that follows replaces the patched snapshot with
    /// store truth (cluster ids, vector counts). Frames with no cached
    /// snapshot are left untouched: a one-row snapshot must never
    /// masquerade as a whole scene.
    func upsertArrivals(
        rows: [String: MessageFilterRow],
        colors: [String: SIMD4<Float>],
        meaningColors: [String: SIMD4<Float>]? = nil
    ) {
        guard rows.isEmpty == false else { return }
        invalidatePendingLoad()
        for (frame, snapshot) in snapshotsByFrame {
            var messageIndex = snapshot.messageIndex
            var colorByMessageId = snapshot.colorByMessageId
            for (messageId, row) in rows {
                messageIndex[messageId] = row
                let color = frame.spatialLens == .meaning
                    ? (meaningColors ?? colors)[messageId] : colors[messageId]
                if let color {
                    colorByMessageId[messageId] = color
                }
            }
            snapshotsByFrame[frame] = ConstellationSnapshot(
                frame: snapshot.frame,
                builtAt: snapshot.builtAt,
                messageIndex: messageIndex,
                colorByMessageId: colorByMessageId
            )
        }
    }

    func removeMessages(_ messageIds: Set<String>) {
        guard !messageIds.isEmpty else { return }
        invalidatePendingLoad()
        for (frame, snapshot) in snapshotsByFrame {
            var messageIndex = snapshot.messageIndex
            var colorByMessageId = snapshot.colorByMessageId
            for messageId in messageIds {
                messageIndex.removeValue(forKey: messageId)
                colorByMessageId.removeValue(forKey: messageId)
            }
            snapshotsByFrame[frame] = ConstellationSnapshot(
                frame: snapshot.frame,
                builtAt: snapshot.builtAt,
                messageIndex: messageIndex,
                colorByMessageId: colorByMessageId
            )
        }
    }

    func updateClassification(
        messageId: String,
        classificationJSON: String?,
        customCategoryKeys: Set<String>
    ) {
        invalidatePendingLoad()
        for (frame, snapshot) in snapshotsByFrame {
            guard let row = snapshot.messageIndex[messageId] else { continue }
            var messageIndex = snapshot.messageIndex
            messageIndex[messageId] = Self.rowByUpdatingClassification(
                row,
                classificationJSON: classificationJSON,
                customCategoryKeys: customCategoryKeys
            )
            snapshotsByFrame[frame] = ConstellationSnapshot(
                frame: snapshot.frame,
                builtAt: snapshot.builtAt,
                messageIndex: messageIndex,
                colorByMessageId: snapshot.colorByMessageId
            )
        }
    }

    /// Drop every cached snapshot. Used when an account's color (and
    /// therefore every per-message color in the renderer) changes, since
    /// every existing snapshot's `colorByMessageId` is now stale.
    func clearAll() {
        invalidatePendingLoad()
        snapshotsByFrame.removeAll()
        sourceVersions.removeAll()
    }

    func clearStoredSummaries() {
        invalidatePendingLoad()
        for (frame, snapshot) in snapshotsByFrame {
            var messageIndex = snapshot.messageIndex
            for messageId in Array(messageIndex.keys) {
                guard let row = messageIndex[messageId],
                      row.bodySummary != nil
                        || row.bodySummaryInputFingerprint != nil
                        || row.mailClassification != nil
                        || row.isActionable != nil
                        || row.requiresConfirmation != nil else {
                    continue
                }
                messageIndex[messageId] = Self.rowByClearingSummary(row)
            }
            snapshotsByFrame[frame] = ConstellationSnapshot(
                frame: snapshot.frame,
                builtAt: snapshot.builtAt,
                messageIndex: messageIndex,
                colorByMessageId: snapshot.colorByMessageId
            )
        }
    }

    private static func rowByClearingSummary(_ row: MessageFilterRow) -> MessageFilterRow {
        MessageFilterRow(
            accountId: row.accountId,
            threadId: row.threadId,
            messageType: row.messageType,
            embeddingStatus: row.embeddingStatus,
            isRead: row.isRead,
            isReplied: row.isReplied,
            isConfirmed: row.isConfirmed,
            isResolved: row.isResolved,
            isSentByUser: row.isSentByUser,
            flagged: row.flagged,
            hasAttachments: row.hasAttachments,
            fromAddress: row.fromAddress,
            fromName: row.fromName,
            toAddresses: row.toAddresses,
            toNames: row.toNames,
            toDisplayNames: row.toDisplayNames,
            ccAddresses: row.ccAddresses,
            ccNames: row.ccNames,
            ccDisplayNames: row.ccDisplayNames,
            bccAddresses: row.bccAddresses,
            bccNames: row.bccNames,
            bccDisplayNames: row.bccDisplayNames,
            recipientAddresses: row.recipientAddresses,
            clusterId: row.clusterId,
            dimensions: row.dimensions,
            subject: row.subject,
            receivedAt: row.receivedAt,
            ingestedAt: row.ingestedAt,
            liveDetectedAt: row.liveDetectedAt,
            bodyTextPath: row.bodyTextPath,
            bodyHtmlPath: row.bodyHtmlPath,
            bodySummary: nil,
            bodySummaryInputFingerprint: nil,
            mailClassificationJSON: nil,
            // User-tagged custom keys are not generated text; they survive
            // a summary invalidation.
            customCategoryKeys: row.customCategoryKeys,
            vectorBreakdown: row.vectorBreakdown,
            neighborCount: row.neighborCount,
            isActionable: nil,
            requiresConfirmation: nil,
            listId: row.listId
        )
    }

    private static func rowByUpdatingClassification(
        _ row: MessageFilterRow,
        classificationJSON: String?,
        customCategoryKeys: Set<String>
    ) -> MessageFilterRow {
        MessageFilterRow(
            accountId: row.accountId,
            threadId: row.threadId,
            messageType: row.messageType,
            embeddingStatus: row.embeddingStatus,
            isRead: row.isRead,
            isReplied: row.isReplied,
            isConfirmed: row.isConfirmed,
            isResolved: row.isResolved,
            isSentByUser: row.isSentByUser,
            flagged: row.flagged,
            hasAttachments: row.hasAttachments,
            fromAddress: row.fromAddress,
            fromName: row.fromName,
            toAddresses: row.toAddresses,
            toNames: row.toNames,
            toDisplayNames: row.toDisplayNames,
            ccAddresses: row.ccAddresses,
            ccNames: row.ccNames,
            ccDisplayNames: row.ccDisplayNames,
            bccAddresses: row.bccAddresses,
            bccNames: row.bccNames,
            bccDisplayNames: row.bccDisplayNames,
            recipientAddresses: row.recipientAddresses,
            clusterId: row.clusterId,
            dimensions: row.dimensions,
            subject: row.subject,
            receivedAt: row.receivedAt,
            ingestedAt: row.ingestedAt,
            liveDetectedAt: row.liveDetectedAt,
            bodyTextPath: row.bodyTextPath,
            bodyHtmlPath: row.bodyHtmlPath,
            bodySummary: row.bodySummary,
            bodySummaryInputFingerprint: row.bodySummaryInputFingerprint,
            mailClassificationJSON: classificationJSON,
            customCategoryKeys: customCategoryKeys,
            vectorBreakdown: row.vectorBreakdown,
            neighborCount: row.neighborCount,
            isActionable: row.isActionable,
            requiresConfirmation: row.requiresConfirmation,
            listId: row.listId
        )
    }
}
