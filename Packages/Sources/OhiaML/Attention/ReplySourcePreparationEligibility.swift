import Foundation
import SwiftData
import OhiaCore

/// One resolved Needs Reply projection shared by background preparation,
/// Composer intake, and the worker's pre/post-compilation checks.
/// All reads remain synchronous on the caller's context-owning executor.
///
/// Preparation follows the conversation's Composer queue item: a
/// conversation's reply targets its newest email that itself calls for one,
/// and only that email is prepared. Earlier emails it covers get no
/// preparation of their own, and a completed one is not kept once a newer
/// email becomes the target.
public enum ReplySourcePreparationEligibility {
    /// Where one email stands in its conversation's reply preparation.
    public struct ConversationState: Sendable, Equatable {
        /// Background preparation should run for this email: it is the
        /// conversation's reply target, a Needs Reply obligation is open in
        /// the conversation, and no other email still holds the
        /// conversation's unsent reply Draft (that Draft moves here instead,
        /// or its send answers the conversation).
        public let isEligible: Bool
        /// A completed preparation for this email may be kept: nothing
        /// settled it, and no other email is the conversation's reply target.
        public let canRetainCompletedPreparation: Bool
        /// A newer email in the conversation is its reply target, so this
        /// email gets no preparation of its own.
        public let isSuperseded: Bool
        /// The email the conversation's reply targets, when there is one.
        public let targetMessageID: UUID?

        static let unavailable = ConversationState(
            isEligible: false,
            canRetainCompletedPreparation: false,
            isSuperseded: false,
            targetMessageID: nil
        )
    }

    /// Completed foreground preparation can be retained without an automatic
    /// reply obligation. Explicit completion, an observed sent reply, and
    /// another email being the conversation's reply target still invalidate
    /// it; Composer queue membership does not.
    public static func canRetainCompletedPreparation(
        _ message: Message,
        context: ModelContext
    ) -> Bool {
        conversationState(for: message, context: context).canRetainCompletedPreparation
    }

    public static func isEligible(
        _ message: Message,
        context: ModelContext
    ) -> Bool {
        conversationState(for: message, context: context).isEligible
    }

    /// The email the conversation's reply targets for preparation, when
    /// there is one: its Composer queue item's target, or without one the
    /// newest open Needs Reply obligation (see `target(for:in:...)`).
    public static func conversationTarget(
        for message: Message,
        context: ModelContext
    ) -> Message? {
        guard let assessment = assess(message, context: context) else { return nil }
        return assessment.target
    }

    public static func conversationState(
        for message: Message,
        context: ModelContext
    ) -> ConversationState {
        guard let assessment = assess(message, context: context) else {
            // A failed action fetch could hide a user resolution or reply.
            // Preparation is speculative background work, so fail closed.
            return .unavailable
        }
        let target = assessment.target
        let isSuperseded = target.map {
            $0.id != message.id && Message.newestPipelineFirst($0, message)
        } ?? false
        let ownState = assessment.attention[message.id]
            ?? MessageAttentionState(messageID: message.id, openKinds: [])
        let actions = assessment.userActions

        // A completed preparation is kept only while the conversation's reply
        // could be this email's: when another email is the reply target, the
        // Composer opens that one, so a preparation here (superseded, or on a
        // later email that asks nothing) is never adopted. An explicit new
        // Needs Reply action can reopen a previously answered conversation.
        // Otherwise the sent-reply evidence remains final.
        let coveredByAnotherTarget = target.map { $0.id != message.id } ?? false
        let canRetain = !message.isTrashed && !message.isSentByUser
            && !actions.resolvedMessageIDs.contains(message.id)
            && !actions.confirmedMessageIDs.contains(message.id)
            && !actions.repliedMessageIDs.contains(message.id)
            && !coveredByAnotherTarget
            && (ownState.needsReply
                || (message.repliedAt == nil && ownState.clearsByMessageID == nil))

        let isEligible = !message.isSentByUser
            && target?.id == message.id
            && assessment.attention.values.contains { $0.needsReply }
            && otherEmailHoldingUnsentReplyDraft(
                for: message,
                members: assessment.members,
                context: context
            ) == nil

        return ConversationState(
            isEligible: isEligible,
            canRetainCompletedPreparation: canRetain,
            isSuperseded: isSuperseded,
            targetMessageID: target?.id
        )
    }

    public static func state(
        for message: Message,
        context: ModelContext
    ) -> MessageAttentionState {
        guard let userActions = userActionState(for: message, in: context) else {
            // A failed action fetch could hide a user resolution or reply.
            // Preparation is speculative background work, so fail closed.
            return MessageAttentionState(messageID: message.id, openKinds: [])
        }

        let inputs = message.composerConversationMembers.map(attentionInput)
        return MessageAttentionResolver.state(
            for: attentionInput(message),
            messages: inputs,
            userActions: userActions
        )
    }

    /// Another inbound email of `message`'s conversation that holds the
    /// conversation's unsent reply Draft (being written, or confirmed and
    /// waiting in the outbox). That Draft is the conversation's reply: it
    /// moves to the reply target (`ComposerThreadChangeReconciler`) — off a
    /// trashed email too — or its send answers the conversation, so no second
    /// Draft or preparation may be created for `message` meanwhile. An
    /// explicitly excluded email's Draft is never moved and blocks nothing.
    /// Store-keyed: the Draft may have been written by another process,
    /// leaving this context's relationship a stale nil.
    public static func otherEmailHoldingUnsentReplyDraft(
        for message: Message,
        context: ModelContext
    ) -> Message? {
        otherEmailHoldingUnsentReplyDraft(
            for: message,
            members: message.composerConversationMembers,
            context: context
        )
    }

    private static func otherEmailHoldingUnsentReplyDraft(
        for message: Message,
        members: [Message],
        context: ModelContext
    ) -> Message? {
        for member in members
        where member.id != message.id
            && !member.isSentByUser
            && member.composerQueueOverride != .exclude
            // A reply Draft is created for an email the Composer opened as
            // its queue item, which qualified itself; one whose relationship
            // already shows a Draft is checked too. This bounds the store
            // reads in long threads to the few emails that can hold one.
            && (member.draft != nil
                || member.composerQueueEmailDecision(automaticTriageQueueingEnabled: true) == .qualifies) {
            let memberID = member.id
            var descriptor = FetchDescriptor<Draft>(
                predicate: #Predicate<Draft> { $0.message?.id == memberID }
            )
            descriptor.fetchLimit = 1
            guard let draft = try? context.fetch(descriptor).first else { continue }
            if Message.isUnsentReply(draft.status) { return member }
        }
        return nil
    }

    private struct Assessment {
        let members: [Message]
        let userActions: MessageAttentionUserActionState
        let attention: [UUID: MessageAttentionState]
        let target: Message?
    }

    private static func assess(
        _ message: Message,
        context: ModelContext
    ) -> Assessment? {
        guard let userActions = userActionState(for: message, in: context) else {
            return nil
        }
        let members = message.composerConversationMembers
        let attention = MessageAttentionResolver.states(
            messages: members.map(attentionInput),
            userActions: userActions
        )
        return Assessment(
            members: members,
            userActions: userActions,
            attention: attention,
            target: target(for: message, in: members, attention: attention, userActions: userActions)
        )
    }

    /// The email the conversation's reply targets for preparation.
    ///
    /// When the conversation has a Composer queue item, preparation follows
    /// its target, so the prepared reply is the one the queue item adopts; a
    /// target the author already settled (resolved, replied, confirmed) is
    /// not prepared. Otherwise (the queue-intake preference keeps Needs Reply
    /// mail out of the queue, or nothing qualifies) the newest open Needs
    /// Reply obligation is the target — an explicit Needs Reply reopens an
    /// answered email, which "Send to Composer" can then open, as it can any
    /// included email. An obligation outranks a Composer exclusion, since
    /// removing an item from the queue keeps its reply obligation, but an
    /// unanswered exclusion on a newer email that is not itself an obligation
    /// leaves the conversation without a target ("No Reply Needed" on it).
    private static func target(
        for message: Message,
        in members: [Message],
        attention: [UUID: MessageAttentionState],
        userActions: MessageAttentionUserActionState
    ) -> Message? {
        func isSettledByUser(_ member: Message) -> Bool {
            userActions.resolvedMessageIDs.contains(member.id)
                || userActions.confirmedMessageIDs.contains(member.id)
                || userActions.repliedMessageIDs.contains(member.id)
        }
        let automaticTriageQueueingEnabled =
            ComposerQueueIntakePreference.automaticTriageQueueingEnabled()
        if let queueTarget = message.composerConversationQueueResolution(
            automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
        ).target {
            return isSettledByUser(queueTarget) ? nil : queueTarget
        }

        let latestReply = Message.composerConversationLatestReplyDate(in: members)
        var newest: Message?
        var newestQualifies = false
        for member in members where !member.isSentByUser && !member.isTrashed && !isSettledByUser(member) {
            let qualifies: Bool
            if attention[member.id]?.needsReply == true {
                qualifies = true
            } else if latestReply.map({ $0 > member.pipelineOrderingDate }) != true,
                      member.composerQueueEmailDecision(
                          automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
                      ) == .excluded {
                qualifies = false
            } else {
                continue
            }
            if let current = newest, !Message.newestPipelineFirst(member, current) { continue }
            newest = member
            newestQualifies = qualifies
        }
        return newestQualifies ? newest : nil
    }

    private static func userActionState(
        for message: Message,
        in context: ModelContext
    ) -> MessageAttentionUserActionState? {
        // The resolver only sees this conversation. Unrelated action history
        // cannot affect its decision and should not be materialized per row.
        let ids = Array(Set(message.composerConversationMembers.map(\.id)))
        let descriptor = FetchDescriptor<ProjectLensAction>(
            predicate: #Predicate<ProjectLensAction> { action in
                action.messageId.flatMap { ids.contains($0) } ?? false
            }
        )
        guard let rows = try? context.fetch(descriptor) else {
            return nil
        }

        var state = MessageAttentionUserActionState()
        for row in rows where row.isActive && row.targetKind == .message {
            guard let messageID = row.messageId else { continue }
            switch row.actionValue {
            case .resolvedByUser:
                state.resolvedMessageIDs.insert(messageID)
            case .replyNeededByUser:
                state.replyNeededMessageIDs.insert(messageID)
            case .repliedByUser:
                state.repliedMessageIDs.insert(messageID)
            case .confirmationNeededByUser:
                state.confirmationNeededMessageIDs.insert(messageID)
            case .confirmedByUser:
                state.confirmedMessageIDs.insert(messageID)
            default:
                continue
            }
        }
        return state
    }

    private static func attentionInput(_ message: Message) -> MessageAttentionInput {
        let triageVerdict: TriageVerdict?
        if message.isLiveInboundTriageEligible,
           let json = message.analysis?.triageVerdictJSON,
           let data = json.data(using: .utf8) {
            triageVerdict = try? JSONDecoder().decode(TriageVerdict.self, from: data)
        } else {
            triageVerdict = nil
        }

        return MessageAttentionInput(
            id: message.id,
            threadID: message.thread?.id,
            date: message.vectorTimeFilterDate ?? message.ingestedAt,
            isSentByUser: message.isSentByUser,
            messageType: message.messageType,
            triageVerdict: triageVerdict,
            messageIDHeader: message.messageIdHeader,
            inReplyTo: message.inReplyTo,
            referencesChain: message.referencesChain,
            repliedAt: message.repliedAt
        )
    }
}
