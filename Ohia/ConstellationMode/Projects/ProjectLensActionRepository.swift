import Foundation
import OhiaCore
import OhiaML
import OhiaScheduler
import SwiftData

/// Persistence boundary for the shared message actions used by Projects,
/// Front Page, Timeline, and other message surfaces. Project lifecycle belongs
/// to `MailProjectRepository` and is intentionally absent here.
nonisolated struct ProjectLensActionRepository {
    let modelContext: ModelContext
    private let saveContext: (ModelContext) throws -> Void
    private let postMessageAttentionChanged: (Set<UUID>) -> Void

    init(
        modelContext: ModelContext,
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() },
        postMessageAttentionChanged: @escaping (Set<UUID>) -> Void = { messageIDs in
            NotificationCenter.default.post(
                name: .ohiaMessageAttentionChanged,
                object: nil,
                userInfo: MessageAttentionNotificationCoding.userInfo(messageIDs: messageIDs)
            )
        }
    ) {
        self.modelContext = modelContext
        self.saveContext = saveContext
        self.postMessageAttentionChanged = postMessageAttentionChanged
    }

    func sharedMessageActionState() -> ProjectLensSharedMessageActionState {
        var resolvedMessages: Set<UUID> = []
        var replyNeededMessages: Set<UUID> = []
        var repliedMessages: Set<UUID> = []
        var confirmationNeededMessages: Set<UUID> = []
        var confirmedMessages: Set<UUID> = []

        for row in ProjectLensAction.activeActions(in: modelContext) {
            guard row.targetKind == .message, let messageID = row.messageId else {
                continue
            }
            switch row.actionValue {
            case .resolvedByUser:
                resolvedMessages.insert(messageID)
            case .replyNeededByUser:
                replyNeededMessages.insert(messageID)
            case .repliedByUser:
                repliedMessages.insert(messageID)
            case .confirmationNeededByUser:
                confirmationNeededMessages.insert(messageID)
            case .confirmedByUser:
                confirmedMessages.insert(messageID)
            case nil:
                continue
            }
        }

        return ProjectLensSharedMessageActionState(
            resolvedMessageIDs: resolvedMessages,
            replyNeededMessageIDs: replyNeededMessages,
            repliedMessageIDs: repliedMessages,
            confirmationNeededMessageIDs: confirmationNeededMessages,
            confirmedMessageIDs: confirmedMessages
        )
    }

    /// Cross-lens call-site adapter. Message actions are globally shared, so
    /// the former project-scope argument is deliberately ignored.
    func actionState(accountScopeKey: String) -> ProjectLensSharedMessageActionState {
        sharedMessageActionState()
    }

    func setMessageResolved(
        _ resolved: Bool,
        messageID: UUID,
        accountScopeKey: String
    ) -> Bool {
        setSharedMessageAction(
            resolved,
            messageID: messageID,
            action: .resolvedByUser,
            revokingWhenEnabled: [.repliedByUser, .confirmationNeededByUser]
        )
    }

    func setMessageReplied(
        _ replied: Bool,
        messageID: UUID,
        accountScopeKey: String
    ) -> Bool {
        setSharedMessageAction(
            replied,
            messageID: messageID,
            action: .repliedByUser,
            revokingWhenEnabled: [.replyNeededByUser, .confirmationNeededByUser]
        )
    }

    @MainActor
    func setMessageReplyNeeded(
        _ replyNeeded: Bool,
        messageID: UUID,
        accountScopeKey: String
    ) -> Bool {
        let changed = setSharedMessageAction(
            replyNeeded,
            messageID: messageID,
            action: .replyNeededByUser,
            revokingWhenEnabled: [.repliedByUser, .confirmationNeededByUser, .confirmedByUser]
        )
        guard changed else { return false }

        // Needs Reply authorizes source compilation and question formulation,
        // NOT Composer admission. Preserve the queue override (including an
        // earlier exclusion); only Send to Composer may explicitly include it.
        // Coupling these actions hides the message from Front Page prematurely.
        do {
            try ReplySourcePreparationCoordinator().reconcile(
                messageIDs: [messageID],
                origin: .alreadyVisibleManualAction,
                context: modelContext
            )
        } catch {
            print(
                "[Ohia] Manual Needs Reply preparation failed: "
                    + String(reflecting: type(of: error))
            )
        }
        return true
    }

    func setMessageConfirmed(
        _ confirmed: Bool,
        messageID: UUID,
        accountScopeKey: String
    ) -> Bool {
        setSharedMessageAction(
            confirmed,
            messageID: messageID,
            action: .confirmedByUser,
            revokingWhenEnabled: [.replyNeededByUser, .confirmationNeededByUser]
        )
    }

    func setMessageConfirmationNeeded(
        _ confirmationNeeded: Bool,
        messageID: UUID,
        accountScopeKey: String
    ) -> Bool {
        setSharedMessageAction(
            confirmationNeeded,
            messageID: messageID,
            action: .confirmationNeededByUser,
            revokingWhenEnabled: [.replyNeededByUser, .repliedByUser, .confirmedByUser]
        )
    }

    func restoreSharedMessageActions(
        _ snapshot: ProjectLensSharedMessageActionSnapshot
    ) -> Bool {
        do {
            let changed = try ProjectLensAction.restoreSharedMessageActions(
                snapshot,
                in: modelContext,
                saveContext: saveContext
            )
            guard changed.isEmpty == false else { return false }
            postMessageAttentionChanged(changed)
            return true
        } catch {
            modelContext.rollback()
            return false
        }
    }

    private func setSharedMessageAction(
        _ enabled: Bool,
        messageID: UUID,
        action: ProjectLensAction.ActionValue,
        revokingWhenEnabled revokedActions: [ProjectLensAction.ActionValue] = [],
        now: Date = .now
    ) -> Bool {
        if enabled {
            revokeSharedMessageActions(revokedActions, messageID: messageID, now: now)
        }

        let active = ProjectLensAction.activeActions(in: modelContext).filter { row in
            row.targetKind == .message
                && row.actionValue == action
                && row.messageId == messageID
        }

        if enabled {
            if let keeper = active.first(where: { $0.accountScopeKey == "all" }) ?? active.first {
                keeper.accountScopeKey = "all"
                keeper.appliedAt = now
                for duplicate in active where duplicate.id != keeper.id {
                    duplicate.revoke(at: now)
                }
            } else {
                modelContext.insert(ProjectLensAction(
                    messageId: messageID,
                    accountScopeKey: "all",
                    actionRawValue: action.rawValue,
                    appliedAt: now
                ))
            }
        } else {
            for row in active {
                row.revoke(at: now)
            }
        }

        return saveAndPostMessageAttentionChange(messageIDs: [messageID])
    }

    private func revokeSharedMessageActions(
        _ actions: [ProjectLensAction.ActionValue],
        messageID: UUID,
        now: Date
    ) {
        guard actions.isEmpty == false else { return }
        let actionSet = Set(actions)
        let active = ProjectLensAction.activeActions(in: modelContext).filter { row in
            row.targetKind == .message
                && row.messageId == messageID
                && row.actionValue.map(actionSet.contains) == true
        }
        for row in active {
            row.revoke(at: now)
        }
    }

    @discardableResult
    private func saveAndPostMessageAttentionChange(messageIDs: Set<UUID>) -> Bool {
        guard messageIDs.isEmpty == false else { return false }
        do {
            try saveContext(modelContext)
        } catch {
            modelContext.rollback()
            return false
        }
        postMessageAttentionChanged(messageIDs)
        return true
    }
}
