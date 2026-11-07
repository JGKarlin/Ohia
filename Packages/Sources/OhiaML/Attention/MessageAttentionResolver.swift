import Foundation
import OhiaCore

/// Shared message-level attention state used by every lens that needs to ask
/// "is something still owed for this email?" Project lifecycle/resolution is
/// intentionally not represented here; that remains Projects-only.
public enum MessageAttentionKind: String, Codable, Sendable, Hashable, CaseIterable {
    case pendingReply
    case confirmation
}

public struct MessageAttentionUserActionState: Sendable, Hashable {
    public var resolvedMessageIDs: Set<UUID>
    public var replyNeededMessageIDs: Set<UUID>
    public var repliedMessageIDs: Set<UUID>
    public var confirmationNeededMessageIDs: Set<UUID>
    public var confirmedMessageIDs: Set<UUID>

    public init(
        resolvedMessageIDs: Set<UUID> = [],
        replyNeededMessageIDs: Set<UUID> = [],
        repliedMessageIDs: Set<UUID> = [],
        confirmationNeededMessageIDs: Set<UUID> = [],
        confirmedMessageIDs: Set<UUID> = []
    ) {
        self.resolvedMessageIDs = resolvedMessageIDs
        self.replyNeededMessageIDs = replyNeededMessageIDs
        self.repliedMessageIDs = repliedMessageIDs
        self.confirmationNeededMessageIDs = confirmationNeededMessageIDs
        self.confirmedMessageIDs = confirmedMessageIDs
    }

    public init(projectActions: ProjectLensUserActionState) {
        self.init(
            resolvedMessageIDs: projectActions.resolvedMessageIDs,
            replyNeededMessageIDs: projectActions.replyNeededMessageIDs,
            repliedMessageIDs: projectActions.repliedMessageIDs,
            confirmationNeededMessageIDs: projectActions.confirmationNeededMessageIDs,
            confirmedMessageIDs: projectActions.confirmedMessageIDs
        )
    }

    public static let empty = MessageAttentionUserActionState()

    public var fingerprint: String {
        [
            "resolved=\(Self.uuidFingerprint(resolvedMessageIDs))",
            "replyNeeded=\(Self.uuidFingerprint(replyNeededMessageIDs))",
            "replied=\(Self.uuidFingerprint(repliedMessageIDs))",
            "confirmationNeeded=\(Self.uuidFingerprint(confirmationNeededMessageIDs))",
            "confirmed=\(Self.uuidFingerprint(confirmedMessageIDs))"
        ].joined(separator: "|")
    }

    private static func uuidFingerprint(_ ids: Set<UUID>) -> String {
        ids.map(\.uuidString).sorted().joined(separator: ",")
    }
}

/// Minimal per-message input for cross-lens attention resolution. App layers can
/// construct this from SwiftData `Message`; Projects can construct it from
/// `ProjectMessageInput`.
public struct MessageAttentionInput: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let threadID: UUID?
    public let date: Date
    public let isSentByUser: Bool
    public let messageType: MessageType
    public let triageVerdict: TriageVerdict?
    public let messageIDHeader: String?
    public let inReplyTo: String?
    public let referencesChain: String?
    public let repliedAt: Date?

    public init(
        id: UUID,
        threadID: UUID?,
        date: Date,
        isSentByUser: Bool,
        messageType: MessageType,
        triageVerdict: TriageVerdict?,
        messageIDHeader: String? = nil,
        inReplyTo: String? = nil,
        referencesChain: String? = nil,
        repliedAt: Date? = nil
    ) {
        self.id = id
        self.threadID = threadID
        self.date = date
        self.isSentByUser = isSentByUser
        self.messageType = messageType
        self.triageVerdict = triageVerdict?.normalizingActionability(isSentByUser: isSentByUser)
        self.messageIDHeader = Self.normalizedHeader(messageIDHeader)
        self.inReplyTo = Self.normalizedHeader(inReplyTo)
        self.referencesChain = referencesChain
        self.repliedAt = repliedAt
    }

    public init(projectMessage: ProjectMessageInput) {
        self.init(
            id: projectMessage.id,
            threadID: projectMessage.threadID,
            date: projectMessage.date,
            isSentByUser: projectMessage.isSentByUser,
            messageType: projectMessage.messageType,
            triageVerdict: projectMessage.isLiveInbound ? projectMessage.triageVerdict : nil,
            messageIDHeader: projectMessage.messageIDHeader,
            inReplyTo: projectMessage.inReplyTo,
            referencesChain: projectMessage.referencesChain,
            repliedAt: projectMessage.repliedAt
        )
    }

    public var referencesHeaders: Set<String> {
        var values: Set<String> = []
        if let inReplyTo { values.insert(inReplyTo) }
        if let referencesChain {
            for token in referencesChain.split(whereSeparator: \.isWhitespace) {
                if let normalized = Self.normalizedHeader(String(token)) {
                    values.insert(normalized)
                }
            }
        }
        return values
    }

    private static func normalizedHeader(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct MessageAttentionState: Sendable, Equatable {
    public let messageID: UUID
    public let openKinds: Set<MessageAttentionKind>
    public let clearsByMessageID: UUID?

    public init(
        messageID: UUID,
        openKinds: Set<MessageAttentionKind>,
        clearsByMessageID: UUID? = nil
    ) {
        self.messageID = messageID
        self.openKinds = openKinds
        self.clearsByMessageID = clearsByMessageID
    }

    public var needsReply: Bool { openKinds.contains(.pendingReply) }
    public var needsConfirmation: Bool { openKinds.contains(.confirmation) }
    public var hasOpenAttention: Bool { openKinds.isEmpty == false }
}

public enum MessageAttentionResolver {
    public static func states(
        messages rawMessages: [MessageAttentionInput],
        userActions: MessageAttentionUserActionState = .empty
    ) -> [UUID: MessageAttentionState] {
        let messages = rawMessages.sorted(by: messageSort)
        let replyIndex = ReplyClearanceIndex(messages: messages)
        var resolved: [UUID: MessageAttentionState] = [:]

        for message in messages {
            let state = state(for: message, replyIndex: replyIndex, userActions: userActions)
            resolved[message.id] = state
        }
        return resolved
    }

    public static func state(
        for message: MessageAttentionInput,
        messages: [MessageAttentionInput],
        userActions: MessageAttentionUserActionState = .empty
    ) -> MessageAttentionState {
        let replyIndex = ReplyClearanceIndex(messages: messages)
        return state(for: message, replyIndex: replyIndex, userActions: userActions)
    }

    nonisolated public static func messageSort(_ lhs: MessageAttentionInput, _ rhs: MessageAttentionInput) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func state(
        for message: MessageAttentionInput,
        replyIndex: ReplyClearanceIndex,
        userActions: MessageAttentionUserActionState
    ) -> MessageAttentionState {
        guard !message.isSentByUser,
              !userActions.resolvedMessageIDs.contains(message.id),
              !userActions.confirmedMessageIDs.contains(message.id) else {
            return MessageAttentionState(messageID: message.id, openKinds: [])
        }

        let replyNeededByUser = userActions.replyNeededMessageIDs.contains(message.id)
            && !userActions.repliedMessageIDs.contains(message.id)
        let confirmationNeededByUser = userActions.confirmationNeededMessageIDs.contains(message.id)
            && !userActions.confirmedMessageIDs.contains(message.id)
        let clearingReply = firstClearingReply(for: message, in: replyIndex)
        let replyClearedAutomatically = message.repliedAt != nil || clearingReply != nil
        let replyAlreadySatisfied = userActions.repliedMessageIDs.contains(message.id)
            || replyClearedAutomatically
        var kinds: Set<MessageAttentionKind> = []
        if replyNeededByUser {
            kinds.insert(.pendingReply)
        } else if !replyClearedAutomatically,
                  message.triageVerdict?.isActionable == true,
                  !userActions.repliedMessageIDs.contains(message.id),
                  !isWeakUnevidencedOtherAction(message),
                  !isOptionalBroadcastAction(message) {
            kinds.insert(.pendingReply)
        }
        if confirmationNeededByUser, !replyAlreadySatisfied {
            kinds.insert(.confirmation)
        } else if message.triageVerdict?.requiresConfirmation == true,
                  !userActions.confirmedMessageIDs.contains(message.id),
                  !replyAlreadySatisfied {
            kinds.insert(.confirmation)
        }
        // Binary obligation invariant: a message needs a reply XOR a
        // confirmation, never both. The verdict is already collapsed upstream
        // by `TriageVerdict.enforcingBinaryObligation()`; this guards the case
        // where an explicit user action contributes the opposite axis. A
        // pending reply subsumes acknowledgement — sending the reply
        // demonstrates awareness — so reply wins.
        if kinds.contains(.pendingReply) {
            kinds.remove(.confirmation)
        }
        let clearsByMessageID = replyNeededByUser ? nil : clearingReply?.id
        return MessageAttentionState(messageID: message.id, openKinds: kinds, clearsByMessageID: clearsByMessageID)
    }

    /// Broadcast confirmations often include optional self-service CTAs ("modify
    /// or cancel", "review your reservation"). Those are useful facts to absorb,
    /// not reply obligations. Keep genuine asks (reply, provide information,
    /// schedule, sign-off) as pending replies.
    private static func isOptionalBroadcastAction(_ message: MessageAttentionInput) -> Bool {
        guard let verdict = message.triageVerdict,
              verdict.isActionable,
              let action = verdict.action else {
            return false
        }

        if verdict.requiresConfirmation,
           let acknowledgement = verdict.acknowledgement,
           isBroadcastConfirmation(acknowledgement) {
            switch action.kind {
            case .reply, .provideInformation, .scheduleMeeting, .signOff:
                return false
            case .makeDecision, .review, .other:
                return actionLooksLikeOptionalSelfService(action)
                    || actionLooksLikeReadOnlyConfirmation(action)
            }
        }

        switch action.kind {
        case .other:
            return actionLooksLikePromotionalSelfService(action)
        case .reply, .provideInformation, .scheduleMeeting, .signOff, .makeDecision, .review:
            return false
        }
    }

    private static func isWeakUnevidencedOtherAction(_ message: MessageAttentionInput) -> Bool {
        guard let verdict = message.triageVerdict,
              verdict.confidence <= 0.55,
              let action = verdict.action,
              action.kind == .other,
              action.deadline == nil,
              action.evidenceSpans.isEmpty else {
            return false
        }
        return true
    }

    private static func isBroadcastConfirmation(_ acknowledgement: AcknowledgementSpec) -> Bool {
        switch acknowledgement.signalKind {
        case .bookingConfirmation, .deliveryConfirmation, .shippingMilestone:
            return true
        default:
            return false
        }
    }

    private static func actionLooksLikeOptionalSelfService(_ action: ActionSpec) -> Bool {
        let haystack = ([action.summary] + action.decisionInputs)
            .joined(separator: " ")
            .lowercased()
        let optionalPhrases = [
            "modify or cancel",
            "change or cancel",
            "view or modify",
            "manage your booking",
            "manage your reservation",
            "review your reservation",
            "review the reservation",
            "review the rental",
            "review the rental details",
            "confirm your reservation",
            "confirm your booking",
            "confirm your flight",
            "confirm your flight booking",
            "confirm your flight reservation",
            "bring your",
            "necessary identification",
            "pickup",
            "pick-up",
            "drop-off",
            "drop off"
        ]
        return optionalPhrases.contains { haystack.contains($0) }
    }

    private static func actionLooksLikeReadOnlyConfirmation(_ action: ActionSpec) -> Bool {
        let haystack = ([action.summary] + action.decisionInputs)
            .joined(separator: " ")
            .lowercased()
        let readOnlyPhrases = [
            "is confirmed",
            "are confirmed",
            "reservation confirmed",
            "reservation confirmation",
            "your reservation for",
            "flight booking",
            "flight reservation",
            "seat availability",
            "booking reference",
            "reservation number",
            "confirmation number"
        ]
        return readOnlyPhrases.contains { haystack.contains($0) }
    }

    private static func actionLooksLikePromotionalSelfService(_ action: ActionSpec) -> Bool {
        let haystack = ([action.summary] + action.decisionInputs)
            .joined(separator: " ")
            .lowercased()
        let promotionalPhrases = [
            "subscribe",
            "subscription offer",
            "offer ends",
            "claim the offer",
            "discount",
            "sale",
            "limited-time",
            "limited time",
            "renew your subscription",
            "upgrade your plan"
        ]
        return promotionalPhrases.contains { haystack.contains($0) }
    }

    private struct ReplyClearanceIndex {
        let byThread: [UUID: [MessageAttentionInput]]
        let sentByInReplyTo: [String: [MessageAttentionInput]]
        let sentByReferencedHeader: [String: [MessageAttentionInput]]

        init(messages: [MessageAttentionInput]) {
            byThread = Dictionary(grouping: messages.filter { $0.threadID != nil }) { $0.threadID! }

            var byInReplyTo: [String: [MessageAttentionInput]] = [:]
            var byReferencedHeader: [String: [MessageAttentionInput]] = [:]
            for message in messages
            where message.isSentByUser
                && !isOhiaComposerMailboxDraftMessageID(message.messageIDHeader) {
                if let target = message.inReplyTo {
                    byInReplyTo[target, default: []].append(message)
                }
                for header in message.referencesHeaders {
                    byReferencedHeader[header, default: []].append(message)
                }
            }
            sentByInReplyTo = byInReplyTo
            sentByReferencedHeader = byReferencedHeader
        }
    }

    private static func firstClearingReply(
        for inbound: MessageAttentionInput,
        in index: ReplyClearanceIndex
    ) -> MessageAttentionInput? {
        var candidates: [MessageAttentionInput] = []
        if let threadID = inbound.threadID, let bucket = index.byThread[threadID] {
            candidates.append(contentsOf: bucket.filter {
                $0.isSentByUser
                    && !isOhiaComposerMailboxDraftMessageID($0.messageIDHeader)
                    && $0.date > inbound.date
            })
        }
        if let header = inbound.messageIDHeader {
            if let matches = index.sentByInReplyTo[header] {
                candidates.append(contentsOf: matches.filter { $0.date > inbound.date })
            }
            if let matches = index.sentByReferencedHeader[header] {
                candidates.append(contentsOf: matches.filter { $0.date > inbound.date })
            }
        }
        return candidates.sorted(by: messageSort).first
    }

}
