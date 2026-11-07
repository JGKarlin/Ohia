import Foundation

public struct ProjectOpenObligation: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case pendingReply
        case confirmation
    }

    public let id: UUID
    public let messageID: UUID
    public let projectID: UUID
    public let kind: Kind
    public let openedAt: Date
    public let summary: String?
    public let clearsByMessageID: UUID?

    public init(
        messageID: UUID,
        projectID: UUID,
        kind: Kind,
        openedAt: Date,
        summary: String?,
        clearsByMessageID: UUID?
    ) {
        self.id = messageID
        self.messageID = messageID
        self.projectID = projectID
        self.kind = kind
        self.openedAt = openedAt
        self.summary = summary
        self.clearsByMessageID = clearsByMessageID
    }

    public var projectKey: String { projectID.uuidString.lowercased() }
}

public enum PendingReplyResolver {
    public static func openObligations(
        messages: [ProjectMessageInput],
        membershipByMessageID: [UUID: Set<UUID>],
        sharedMessageActions: ProjectLensSharedMessageActionState
    ) -> [ProjectOpenObligation] {
        let sortedMessages = messages.sorted(by: projectMessageSort)
        let attentionInputs = sortedMessages.map(MessageAttentionInput.init(projectMessage:))
        let attentionByMessageID = MessageAttentionResolver.states(
            messages: attentionInputs,
            userActions: MessageAttentionUserActionState(
                resolvedMessageIDs: sharedMessageActions.resolvedMessageIDs,
                replyNeededMessageIDs: sharedMessageActions.replyNeededMessageIDs,
                repliedMessageIDs: sharedMessageActions.repliedMessageIDs,
                confirmationNeededMessageIDs: sharedMessageActions.confirmationNeededMessageIDs,
                confirmedMessageIDs: sharedMessageActions.confirmedMessageIDs
            )
        )
        var obligations: [ProjectOpenObligation] = []
        for message in sortedMessages {
            guard let attention = attentionByMessageID[message.id],
                  let memberships = membershipByMessageID[message.id],
                  !memberships.isEmpty else {
                continue
            }
            for projectID in memberships.sorted(by: { $0.uuidString < $1.uuidString }) {
                if attention.needsReply {
                    obligations.append(
                        ProjectOpenObligation(
                            messageID: message.id,
                            projectID: projectID,
                            kind: .pendingReply,
                            openedAt: message.date,
                            summary: message.triageVerdict?.action?.summary ?? message.bodySummary,
                            clearsByMessageID: attention.clearsByMessageID
                        )
                    )
                }
                if attention.needsConfirmation {
                    obligations.append(
                        ProjectOpenObligation(
                            messageID: message.id,
                            projectID: projectID,
                            kind: .confirmation,
                            openedAt: message.date,
                            summary: message.triageVerdict?.acknowledgement?.summary ?? message.bodySummary,
                            clearsByMessageID: attention.clearsByMessageID
                        )
                    )
                }
            }
        }
        return obligations
    }

    public static func unresolvedInboundActions(
        messages: [ProjectMessageInput],
        membershipByMessageID: [UUID: Set<UUID>],
        resolvedMessageIDs: Set<UUID>
    ) -> [ProjectOpenObligation] {
        openObligations(
            messages: messages,
            membershipByMessageID: membershipByMessageID,
            sharedMessageActions: ProjectLensSharedMessageActionState(resolvedMessageIDs: resolvedMessageIDs)
        )
        .filter { $0.kind == .pendingReply }
    }

    public static func confirmationObligations(
        messages: [ProjectMessageInput],
        membershipByMessageID: [UUID: Set<UUID>],
        resolvedMessageIDs: Set<UUID>
    ) -> [ProjectOpenObligation] {
        openObligations(
            messages: messages,
            membershipByMessageID: membershipByMessageID,
            sharedMessageActions: ProjectLensSharedMessageActionState(resolvedMessageIDs: resolvedMessageIDs)
        )
        .filter { $0.kind == .confirmation }
    }

    nonisolated static func projectMessageSort(_ lhs: ProjectMessageInput, _ rhs: ProjectMessageInput) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
