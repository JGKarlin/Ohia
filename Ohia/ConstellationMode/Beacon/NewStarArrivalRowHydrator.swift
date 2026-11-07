// NewStarArrivalRowHydrator.swift
// Builds the canonical `MessageFilterRow` for a live arrival directly from
// its SwiftData `Message`, without waiting for the full snapshot rebuild.
//
// This is the row the unified arrival moment patches into the snapshot
// cache (and the row new-star tracking hydrates for messages the cached
// snapshot has not caught up to), so it must stay field-for-field
// equivalent to what `ConstellationSnapshotLoader.load` produces for the
// same message — any drift changes how the arrival filters, renders, or
// badges until the canonical rebuild lands. `NewStarArrivalRowHydratorTests`
// pins that contract; when `MessageFilterRow` gains a field, add it here
// and to the test in the same change.

import Foundation
import OhiaCore
import OhiaML

enum NewStarArrivalRowHydrator {
    /// `userActions` mirrors the loader's `MessageAttentionUserActionState`
    /// overlay: hydration can run minutes after the arrival (starburst
    /// hydrate-on-miss, mid-load re-patch), by which time the user may have
    /// confirmed or marked the message from another surface. Thread-level
    /// reply subsumption (the resolver's `clearsByMessageID`) needs the
    /// whole thread and is deliberately approximated by `repliedAt` here —
    /// same as every hydrated new-star row before this seam existed.
    @MainActor
    static func messageFilterRow(
        from message: Message,
        customCategoryCatalogKeys: Set<String> = [],
        userActions: MessageAttentionUserActionState = .empty
    ) -> MessageFilterRow {
        let decodedTriage = decodeTriageVerdict(
            message.analysis?.triageVerdictJSON,
            isSentByUser: message.isSentByUser
        )
        let triage = message.isLiveInboundTriageEligible ? decodedTriage : nil
        let isReplied: Bool = {
            if userActions.repliedMessageIDs.contains(message.id) { return true }
            if userActions.replyNeededMessageIDs.contains(message.id) { return false }
            return message.repliedAt != nil
        }()
        let isConfirmed: Bool = {
            if userActions.confirmedMessageIDs.contains(message.id) { return true }
            return false
        }()
        let isResolved = userActions.resolvedMessageIDs.contains(message.id)
        var isActionable = MessageFilterRow.currentReplyNeededFromRawTriage(
            triage?.isActionable,
            isReplied: isReplied,
            isSentByUser: message.isSentByUser
        )
        var requiresConfirmation = MessageFilterRow.currentConfirmationNeededFromRawTriage(
            triage?.requiresConfirmation,
            isReplied: isReplied,
            isSentByUser: message.isSentByUser
        )
        if userActions.replyNeededMessageIDs.contains(message.id) {
            isActionable = true
        }
        if userActions.confirmationNeededMessageIDs.contains(message.id) {
            requiresConfirmation = true
        }
        if isConfirmed {
            requiresConfirmation = false
        }
        let date = ConstellationSnapshotLoader.messageTimelineDate(
            sentAt: message.sentAt,
            receivedAt: message.receivedAt,
            ingestedAt: message.ingestedAt,
            isSentByUser: message.isSentByUser
        )
        var toAddresses: [String] = []
        var toNames: [String] = []
        var toDisplayNames: [String] = []
        var ccAddresses: [String] = []
        var ccNames: [String] = []
        var ccDisplayNames: [String] = []
        var bccAddresses: [String] = []
        var bccNames: [String] = []
        var bccDisplayNames: [String] = []
        var recipientAddresses: [String] = []
        for link in message.participants {
            guard let participant = link.participant else { continue }
            let email = participant.emailAddress.lowercased()
            guard email.isEmpty == false else { continue }
            let decodedName = participant.displayName.map(MIMEHeaderDecoder.decodeEncodedWords) ?? ""
            switch link.role {
            case .from:
                continue
            case .to:
                toAddresses.append(email)
                toNames.append(decodedName.lowercased())
                toDisplayNames.append(decodedName)
                recipientAddresses.append(email)
            case .cc:
                ccAddresses.append(email)
                ccNames.append(decodedName.lowercased())
                ccDisplayNames.append(decodedName)
                recipientAddresses.append(email)
            case .bcc:
                bccAddresses.append(email)
                bccNames.append(decodedName.lowercased())
                bccDisplayNames.append(decodedName)
                recipientAddresses.append(email)
            }
        }
        return MessageFilterRow(
            accountId: message.accountID,
            threadId: message.thread?.id,
            messageType: messageType(for: message),
            embeddingStatus: message.embeddingStatus,
            isRead: message.isReadOrFalse,
            isReplied: isReplied,
            isConfirmed: isConfirmed,
            isResolved: isResolved,
            isSentByUser: message.isSentByUser,
            flagged: message.flaggedOrFalse,
            hasAttachments: message.hasAttachments,
            fromAddress: message.fromAddress,
            fromName: message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords),
            toAddresses: toAddresses,
            toNames: toNames,
            toDisplayNames: toDisplayNames,
            ccAddresses: ccAddresses,
            ccNames: ccNames,
            ccDisplayNames: ccDisplayNames,
            bccAddresses: bccAddresses,
            bccNames: bccNames,
            bccDisplayNames: bccDisplayNames,
            recipientAddresses: recipientAddresses,
            dimensions: dimensions(for: message),
            subject: MIMEHeaderDecoder.decodeEncodedWords(message.subject),
            receivedAt: date,
            ingestedAt: message.ingestedAt,
            liveDetectedAt: message.liveDetectedAt,
            bodyTextPath: message.bodyTextPath,
            bodyHtmlPath: message.bodyHtmlPath,
            bodySummary: message.analysis?.bodySummary,
            bodySummaryInputFingerprint: message.analysis?.bodySummaryInputFingerprint,
            mailClassificationJSON: message.analysis?.mailClassificationJSON,
            customCategoryKeys: Set(CustomCategoryKeysJSON.decode(message.analysis?.customCategoryKeysJSON))
                .intersection(customCategoryCatalogKeys),
            isActionable: isActionable,
            requiresConfirmation: requiresConfirmation,
            listId: message.listId
        )
    }

    /// Mirrors `ConstellationSnapshotLoader`'s dimensions decode, including
    /// the triage-action-state scrub for rows that are not live inbound, so
    /// a hydrated arrival row filters and renders exactly as the canonical
    /// snapshot row will.
    @MainActor
    static func dimensions(for message: Message) -> MessageDimensions? {
        guard let json = message.analysis?.dimensionsJSON,
              let data = json.data(using: .utf8),
              let dimensions = try? JSONDecoder().decode(MessageDimensions.self, from: data) else {
            return nil
        }
        let scrubTriageActionState = message.liveDetectedAt == nil || message.isSentByUser
        return scrubTriageActionState ? dimensions.scrubbingTriageActionState() : dimensions
    }

    /// Mirrors the loader's live-inbound type demotion: a stored
    /// actionable/confirmation type only survives for triage-eligible rows.
    @MainActor
    static func messageType(for message: Message) -> MessageType {
        guard !message.isLiveInboundTriageEligible,
              !message.isSentByUser,
              message.messageType == .actionable || message.messageType == .confirmation else {
            return message.messageType
        }
        return .report
    }

    @MainActor
    private static func decodeTriageVerdict(
        _ json: String?,
        isSentByUser: Bool
    ) -> TriageVerdict? {
        guard let json,
              let data = json.data(using: .utf8),
              let verdict = try? JSONDecoder().decode(TriageVerdict.self, from: data) else {
            return nil
        }
        return verdict.normalizingActionability(isSentByUser: isSentByUser)
    }
}
