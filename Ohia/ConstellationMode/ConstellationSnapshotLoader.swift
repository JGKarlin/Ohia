import Foundation
import simd
import OhiaCore
import OhiaML

struct ConstellationSnapshot: Sendable {
    let frame: FrameKey
    let builtAt: Date
    let messageIndex: [String: MessageFilterRow]
    let colorByMessageId: [String: SIMD4<Float>]

    nonisolated static func empty(frame: FrameKey, builtAt: Date = Date.now) -> ConstellationSnapshot {
        ConstellationSnapshot(
            frame: frame,
            builtAt: builtAt,
            messageIndex: [:],
            colorByMessageId: [:]
        )
    }
}

enum ConstellationSnapshotLoader {
    /// `accountColorIndex` maps each account UUID to its `AccountColorPalette`
    /// index. Built on MainActor by `ConstellationModeView` from the live
    /// `Account` rows (SwiftData is main-bound) so this detached load can
    /// resolve hue + saturation without re-entering the store.
    /// `customCategoryCatalogKeys` is the live `CustomMailCategory` key set
    /// (collecting + active), resolved on MainActor by the caller — raw
    /// `custom.*` CSV tokens are intersected against it so keys of removed
    /// categories never reach filtering or chips.
    @concurrent
    nonisolated static func load(
        frame: FrameKey,
        messageStoreURL: URL,
        vectorStore: VectorStore,
        vectorClusterStore: VectorClusterStore,
        vectorNeighborsStore: VectorNeighborsStore? = nil,
        accountColorIndex: [UUID: Int] = [:],
        userActions: MessageAttentionUserActionState = .empty,
        customCategoryCatalogKeys: Set<String> = [],
        arrivalVisibilityGate: NewMailArrivalVisibilityGate? = nil,
        referenceDate: Date = Date.now
    ) async throws -> ConstellationSnapshot {
        try Task.checkCancellation()
        let includesOrbitalStatistics: Bool
        switch frame.spatialLens {
        case .frontPage, .timeline, .projects: includesOrbitalStatistics = false
        default: includesOrbitalStatistics = true
        }
        let allRows = try MessageStoreHotPath.constellationMessageRows(storeURL: messageStoreURL) ?? []
        try Task.checkCancellation()
        let rows = allRows.filter { row in
            guard row.isSentByUser == false else { return true }
            return arrivalVisibilityGate?.isEmbargoed(
                messageID: row.messageId,
                liveDetectedAt: row.liveDetectedAt
            ) != true
        }
        let decoder = JSONDecoder()
        var messageIndex: [String: MessageFilterRow] = [:]
        var colorByMessageId: [String: SIMD4<Float>] = [:]
        messageIndex.reserveCapacity(rows.count)
        colorByMessageId.reserveCapacity(rows.count)

        // Per-message vector and neighbor counts are merged into the snapshot
        // once at build time so the hover never issues SQL on cursor move.
        // Both queries are tolerant of failure: a missing count just renders
        // as zero — the hover degrades gracefully into "no orbital signal."
        // Toolbar metadata for SwiftUI lenses has no orbital readout. Do not
        // scan the neighbor graph (or hold its connection lock) for counts
        // and autocomplete that only consume message fields.
        let vectorBreakdowns: [String: MessageVectorCountBreakdown] = includesOrbitalStatistics
            ? (try? vectorStore.messageVectorCounts()) ?? [:] : [:]
        try Task.checkCancellation()
        let neighborCounts: [String: Int] = includesOrbitalStatistics
            ? (try? vectorNeighborsStore?.messageNeighborCounts()) ?? [:] : [:]
        try Task.checkCancellation()
        let attentionInputs = rows.compactMap { row -> MessageAttentionInput? in
            guard let messageID = UUID(uuidString: row.messageId) else { return nil }
            let messageType = messageType(for: row)
            let timelineDate = messageTimelineDate(
                sentAt: row.sentAt,
                receivedAt: row.receivedAt,
                ingestedAt: row.ingestedAt,
                isSentByUser: row.isSentByUser
            )
            let triageVerdict = row.liveDetectedAt == nil || row.isSentByUser
                ? nil
                : decodeTriageVerdict(row.triageVerdictJSON, decoder: decoder, isSentByUser: row.isSentByUser)
            return MessageAttentionInput(
                id: messageID,
                threadID: row.threadId,
                date: timelineDate,
                isSentByUser: row.isSentByUser,
                messageType: messageType,
                triageVerdict: triageVerdict,
                messageIDHeader: row.messageIdHeader,
                inReplyTo: row.inReplyTo,
                referencesChain: row.referencesChain,
                repliedAt: row.repliedAt
            )
        }
        let attentionByMessageID = MessageAttentionResolver.states(
            messages: attentionInputs,
            userActions: userActions
        )

        for row in rows {
            try Task.checkCancellation()
            let dimensions = decodeDimensions(
                row.dimensionsJSON,
                decoder: decoder,
                scrubTriageActionState: row.liveDetectedAt == nil || row.isSentByUser
            )
            // Subjects and display names received over the wire arrive
            // RFC 2047-encoded when they contain non-ASCII text (Japanese,
            // CJK, Cyrillic, accented Latin, etc.). Existing rows in the
            // store may carry the raw `=?CHARSET?B|Q?...?=` form; decode
            // at the snapshot boundary so every UI surface that reads
            // through MessageFilterRow sees the human-readable string,
            // regardless of charset.
            let subject = MIMEHeaderDecoder.decodeEncodedWords(row.subject)
            let fromName = row.fromName.map(MIMEHeaderDecoder.decodeEncodedWords)
            let decodedDisplayNames = row.toRecipients.map { recipient in
                recipient.displayName.map(MIMEHeaderDecoder.decodeEncodedWords) ?? ""
            }
            let decodedCcDisplayNames = row.ccRecipients.map { recipient in
                recipient.displayName.map(MIMEHeaderDecoder.decodeEncodedWords) ?? ""
            }
            let decodedBccDisplayNames = row.bccRecipients.map { recipient in
                recipient.displayName.map(MIMEHeaderDecoder.decodeEncodedWords) ?? ""
            }
            let timelineDate = messageTimelineDate(
                sentAt: row.sentAt,
                receivedAt: row.receivedAt,
                ingestedAt: row.ingestedAt,
                isSentByUser: row.isSentByUser
            )
            let messageType = messageType(for: row)
            let rowMessageID = UUID(uuidString: row.messageId)
            let attention = rowMessageID.flatMap { attentionByMessageID[$0] }
            let isReplied = rowMessageID.map { messageID in
                if userActions.repliedMessageIDs.contains(messageID) { return true }
                if userActions.replyNeededMessageIDs.contains(messageID) { return false }
                return row.isReplied || attention?.clearsByMessageID != nil
            } ?? row.isReplied
            let isConfirmed = rowMessageID.map { messageID in
                if userActions.confirmedMessageIDs.contains(messageID) { return true }
                if userActions.confirmationNeededMessageIDs.contains(messageID) { return false }
                return false
            } ?? false
            let isResolved = rowMessageID.map(userActions.resolvedMessageIDs.contains) ?? false
            messageIndex[row.messageId] = MessageFilterRow(
                accountId: row.accountId,
                threadId: row.threadId,
                messageType: messageType,
                embeddingStatus: ProcessingStatus(rawValue: row.embeddingStatusRaw) ?? .pending,
                isRead: row.isRead,
                isReplied: isReplied,
                isConfirmed: isConfirmed,
                isResolved: isResolved,
                isSentByUser: row.isSentByUser,
                flagged: row.flagged,
                hasAttachments: row.hasAttachments,
                fromAddress: row.fromAddress,
                fromName: fromName,
                toAddresses: row.toRecipients.map { $0.emailAddress.lowercased() },
                toNames: decodedDisplayNames.map { $0.lowercased() },
                toDisplayNames: decodedDisplayNames,
                ccAddresses: row.ccRecipients.map { $0.emailAddress.lowercased() },
                ccNames: decodedCcDisplayNames.map { $0.lowercased() },
                ccDisplayNames: decodedCcDisplayNames,
                bccAddresses: row.bccRecipients.map { $0.emailAddress.lowercased() },
                bccNames: decodedBccDisplayNames.map { $0.lowercased() },
                bccDisplayNames: decodedBccDisplayNames,
                recipientAddresses: row.recipientAddresses,
                dimensions: dimensions,
                subject: subject,
                receivedAt: timelineDate,
                ingestedAt: row.ingestedAt,
                liveDetectedAt: row.liveDetectedAt,
                bodyTextPath: row.bodyTextPath,
                bodyHtmlPath: row.bodyHtmlPath,
                bodySummary: row.bodySummary,
                bodySummaryInputFingerprint: row.bodySummaryInputFingerprint,
                mailClassificationJSON: row.mailClassificationJSON,
                customCategoryKeys: Set(CustomCategoryKeysJSON.decode(row.customCategoryKeysJSON))
                    .intersection(customCategoryCatalogKeys),
                vectorBreakdown: vectorBreakdowns[row.messageId] ?? MessageVectorCountBreakdown(),
                neighborCount: neighborCounts[row.messageId] ?? 0,
                isActionable: attention?.needsReply ?? false,
                requiresConfirmation: attention?.needsConfirmation ?? false,
                listId: row.listId
            )

            let resolvedColorIndex = row.accountId.flatMap { accountColorIndex[$0] }
            let accountColor = AccountColorPalette.color(forIndex: resolvedColorIndex)
            colorByMessageId[row.messageId] = frame.spatialLens == .meaning
                ? AccountColorPalette.rgb(for: accountColor, brightness: 1.0)
                : timelineColor(date: timelineDate, reference: referenceDate, color: accountColor)
        }

        // Only Meaning has cluster membership.
        let vectorToCluster = frame.spatialLens == .meaning
            ? (try? vectorClusterStore.vectorToClusterWeighted(frame: frame)) ?? [:] : [:]
        try Task.checkCancellation()
        if !vectorToCluster.isEmpty {
            let messageIdByVector = (try? vectorStore.messageIds(for: Array(vectorToCluster.keys))) ?? [:]
            // A message can own several vectors (body chunks, entities,
            // attachments), each carrying its own cluster attachment.
            // Deterministically keep the strongest attachment per message:
            // highest weight wins; ties break to the lowest cluster id, then
            // the lowest vector id — so rebuilds assign identical
            // clusterId/clusterWeight regardless of dictionary iteration
            // order (the previous unweighted path let the last-iterated
            // vector win arbitrarily).
            struct ClusterAttachment {
                var clusterId: Int64
                var weight: Float
                var vectorId: Int64
            }
            var attachmentByMessage: [String: ClusterAttachment] = [:]
            for (vectorId, entry) in vectorToCluster {
                try Task.checkCancellation()
                guard let messageId = messageIdByVector[vectorId] else { continue }
                let candidate = ClusterAttachment(
                    clusterId: entry.clusterId,
                    weight: entry.weight,
                    vectorId: vectorId
                )
                if let current = attachmentByMessage[messageId] {
                    let wins = candidate.weight > current.weight
                        || (candidate.weight == current.weight && candidate.clusterId < current.clusterId)
                        || (candidate.weight == current.weight
                            && candidate.clusterId == current.clusterId
                            && candidate.vectorId < current.vectorId)
                    if wins {
                        attachmentByMessage[messageId] = candidate
                    }
                } else {
                    attachmentByMessage[messageId] = candidate
                }
            }
            for (messageId, attachment) in attachmentByMessage {
                guard var row = messageIndex[messageId] else { continue }
                row.clusterId = attachment.clusterId
                row.clusterWeight = attachment.weight
                messageIndex[messageId] = row
            }
        }

        return ConstellationSnapshot(
            frame: frame,
            // Reference time belongs to date-based interpretation and color.
            // Cache freshness starts when preparation actually completes.
            builtAt: .now,
            messageIndex: messageIndex,
            colorByMessageId: colorByMessageId
        )
    }

    nonisolated static func messageTimelineDate(
        sentAt: Date?,
        receivedAt: Date?,
        ingestedAt: Date,
        isSentByUser: Bool
    ) -> Date {
        if isSentByUser {
            return sentAt ?? receivedAt ?? ingestedAt
        }
        return receivedAt ?? sentAt ?? ingestedAt
    }

    nonisolated private static func decodeDimensions(
        _ json: String?,
        decoder: JSONDecoder,
        scrubTriageActionState: Bool = false
    ) -> MessageDimensions? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        guard let dimensions = try? decoder.decode(MessageDimensions.self, from: data) else {
            return nil
        }
        return scrubTriageActionState ? dimensions.scrubbingTriageActionState() : dimensions
    }

    nonisolated private static func decodeTriageVerdict(
        _ json: String?,
        decoder: JSONDecoder,
        isSentByUser: Bool
    ) -> TriageVerdict? {
        guard let json,
              let data = json.data(using: .utf8),
              let verdict = try? decoder.decode(TriageVerdict.self, from: data) else {
            return nil
        }
        return verdict.normalizingActionability(isSentByUser: isSentByUser)
    }

    nonisolated private static func messageType(for row: MessageStoreConstellationMessageRow) -> MessageType {
        let stored = MessageType(rawValue: row.messageTypeRaw) ?? .unclassified
        guard row.liveDetectedAt == nil,
              row.isSentByUser == false,
              stored == .actionable || stored == .confirmation else {
            return stored
        }
        return .report
    }

    /// Internal (not private) because the live-arrival snapshot patch in
    /// `ConstellationModeView` must bake the identical account-hue/aging
    /// color the canonical rebuild would, or the node would visibly shift
    /// tint when the full snapshot lands seconds later.
    nonisolated static func timelineColor(
        date: Date,
        reference: Date,
        color: AccountColor
    ) -> SIMD4<Float> {
        let age = reference.timeIntervalSince(date)
        let days = max(0, age / 86_400)
        let brightness = max(0.35, 1.0 - (days / 365.0) * 0.65)
        return AccountColorPalette.rgb(for: color, brightness: brightness)
    }
}
