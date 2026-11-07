import Foundation
import SwiftData

/// Persisted cross-lens actions for individual messages.
///
/// First-class `MailProject` records own project naming, ordering, pinning,
/// resolution, rules, and membership. This ledger intentionally has no
/// project identifier or project-level action.
@Model
public final class ProjectLensAction {
    public var id: UUID
    public var targetKindRaw: String
    public var messageId: UUID?
    public var accountScopeKey: String?
    public var actionRawValue: String
    public var appliedAt: Date
    public var revokedAt: Date?

    public init(
        id: UUID = UUID(),
        targetKindRaw: String = TargetKind.message.rawValue,
        messageId: UUID? = nil,
        accountScopeKey: String? = nil,
        actionRawValue: String,
        appliedAt: Date = .now,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.targetKindRaw = targetKindRaw
        self.messageId = messageId
        self.accountScopeKey = Self.normalizedScopeKey(accountScopeKey)
        self.actionRawValue = actionRawValue
        self.appliedAt = appliedAt
        self.revokedAt = revokedAt
    }
}

/// Value-only capture of the active, cross-lens message actions that may be
/// changed by a single user command. Undo stores this before the command and
/// restores it verbatim, including mutually-exclusive actions revoked as a
/// side effect.
public struct ProjectLensSharedMessageActionSnapshot: Sendable, Equatable {
    public let activeActionsByMessageID: [UUID: Set<ProjectLensAction.ActionValue>]

    public init(
        activeActionsByMessageID: [UUID: Set<ProjectLensAction.ActionValue>]
    ) {
        self.activeActionsByMessageID = activeActionsByMessageID
    }
}

public extension ProjectLensAction {
    enum TargetKind: String, Sendable, Codable, CaseIterable {
        case message
    }

    enum ActionValue: String, Sendable, Codable, CaseIterable {
        case resolvedByUser
        case replyNeededByUser
        case repliedByUser
        case confirmationNeededByUser
        case confirmedByUser
    }

    private static let sharedMessageActionValues = Set(ActionValue.allCases)

    var targetKind: TargetKind? {
        TargetKind(rawValue: targetKindRaw)
    }

    var actionValue: ActionValue? {
        ActionValue(rawValue: actionRawValue)
    }

    var isActive: Bool {
        revokedAt == nil
    }

    func revoke(at date: Date = .now) {
        revokedAt = date
    }

    @discardableResult
    static func setMessageResolved(
        _ resolved: Bool,
        messageID: UUID,
        accountScopeKey: String?,
        in context: ModelContext,
        now: Date = .now
    ) -> Bool {
        setAction(
            resolved,
            action: .resolvedByUser,
            messageID: messageID,
            accountScopeKey: accountScopeKey,
            in: context,
            now: now,
            revokingWhenEnabled: [.repliedByUser, .confirmationNeededByUser]
        )
    }

    @discardableResult
    static func setMessageReplyNeeded(
        _ replyNeeded: Bool,
        messageID: UUID,
        accountScopeKey: String?,
        in context: ModelContext,
        now: Date = .now
    ) -> Bool {
        setAction(
            replyNeeded,
            action: .replyNeededByUser,
            messageID: messageID,
            accountScopeKey: accountScopeKey,
            in: context,
            now: now,
            revokingWhenEnabled: [.repliedByUser, .confirmationNeededByUser, .confirmedByUser]
        )
    }

    @discardableResult
    static func setMessageReplied(
        _ replied: Bool,
        messageID: UUID,
        accountScopeKey: String?,
        in context: ModelContext,
        now: Date = .now
    ) -> Bool {
        setAction(
            replied,
            action: .repliedByUser,
            messageID: messageID,
            accountScopeKey: accountScopeKey,
            in: context,
            now: now,
            revokingWhenEnabled: [.replyNeededByUser, .confirmationNeededByUser]
        )
    }

    @discardableResult
    static func setMessageConfirmationNeeded(
        _ confirmationNeeded: Bool,
        messageID: UUID,
        accountScopeKey: String?,
        in context: ModelContext,
        now: Date = .now
    ) -> Bool {
        setAction(
            confirmationNeeded,
            action: .confirmationNeededByUser,
            messageID: messageID,
            accountScopeKey: accountScopeKey,
            in: context,
            now: now,
            revokingWhenEnabled: [.replyNeededByUser, .repliedByUser, .confirmedByUser]
        )
    }

    @discardableResult
    static func setMessageConfirmed(
        _ confirmed: Bool,
        messageID: UUID,
        accountScopeKey: String?,
        in context: ModelContext,
        now: Date = .now
    ) -> Bool {
        setAction(
            confirmed,
            action: .confirmedByUser,
            messageID: messageID,
            accountScopeKey: accountScopeKey,
            in: context,
            now: now,
            revokingWhenEnabled: [.replyNeededByUser, .confirmationNeededByUser]
        )
    }

    static func activeActions(in context: ModelContext) -> [ProjectLensAction] {
        let rows = (try? context.fetch(FetchDescriptor<ProjectLensAction>())) ?? []
        return rows.filter(\.isActive)
    }

    static func snapshotSharedMessageActions(
        messageIDs: Set<UUID>,
        in context: ModelContext
    ) -> ProjectLensSharedMessageActionSnapshot {
        var actionsByMessageID = Dictionary(
            uniqueKeysWithValues: messageIDs.map { ($0, Set<ActionValue>()) }
        )
        guard messageIDs.isEmpty == false else {
            return ProjectLensSharedMessageActionSnapshot(
                activeActionsByMessageID: actionsByMessageID
            )
        }

        for row in activeActions(in: context) {
            guard row.targetKind == .message,
                  let messageID = row.messageId,
                  messageIDs.contains(messageID),
                  let action = row.actionValue,
                  sharedMessageActionValues.contains(action) else {
                continue
            }
            actionsByMessageID[messageID, default: []].insert(action)
        }
        return ProjectLensSharedMessageActionSnapshot(
            activeActionsByMessageID: actionsByMessageID
        )
    }

    /// Restores the active shared-message action set without rewriting or
    /// reactivating historical rows. Current rows are revoked and fresh ledger
    /// rows are appended for the desired state, preserving the audit trail.
    /// Returns exactly the message IDs whose visible state changed.
    @discardableResult
    static func restoreSharedMessageActions(
        _ snapshot: ProjectLensSharedMessageActionSnapshot,
        in context: ModelContext,
        now: Date = .now,
        saveContext: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> Set<UUID> {
        let messageIDs = Set(snapshot.activeActionsByMessageID.keys)
        guard messageIDs.isEmpty == false else { return [] }

        let activeRows = activeActions(in: context).filter { row in
            row.targetKind == .message
                && row.messageId.map(messageIDs.contains) == true
                && row.actionValue.map(sharedMessageActionValues.contains) == true
        }
        var currentByMessageID: [UUID: Set<ActionValue>] = [:]
        for row in activeRows {
            guard let messageID = row.messageId, let action = row.actionValue else {
                continue
            }
            currentByMessageID[messageID, default: []].insert(action)
        }

        let changedMessageIDs = Set(messageIDs.filter { messageID in
            currentByMessageID[messageID, default: []]
                != snapshot.activeActionsByMessageID[messageID, default: []]
        })
        guard changedMessageIDs.isEmpty == false else { return [] }

        for row in activeRows where row.messageId.map(changedMessageIDs.contains) == true {
            row.revoke(at: now)
        }
        for messageID in changedMessageIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let desired = snapshot.activeActionsByMessageID[messageID, default: []]
            for action in desired.sorted(by: { $0.rawValue < $1.rawValue }) {
                context.insert(ProjectLensAction(
                    messageId: messageID,
                    accountScopeKey: "all",
                    actionRawValue: action.rawValue,
                    appliedAt: now
                ))
            }
        }
        do {
            try saveContext(context)
        } catch {
            context.rollback()
            throw error
        }
        return changedMessageIDs
    }

    static func normalizedScopeKey(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed?.lowercased() : nil
    }

    private static func setAction(
        _ enabled: Bool,
        action: ActionValue,
        messageID: UUID,
        accountScopeKey: String?,
        in context: ModelContext,
        now: Date,
        revokingWhenEnabled: [ActionValue] = []
    ) -> Bool {
        let normalizedScope = normalizedScopeKey(accountScopeKey)
        let matching = matchingRows(
            action: action,
            messageID: messageID,
            accountScopeKey: normalizedScope,
            in: context
        )
        let active = matching.filter(\.isActive)

        if enabled {
            if let first = active.first {
                first.appliedAt = now
                for duplicate in active.dropFirst() {
                    duplicate.revoke(at: now)
                }
            } else {
                context.insert(ProjectLensAction(
                    messageId: messageID,
                    accountScopeKey: normalizedScope,
                    actionRawValue: action.rawValue,
                    appliedAt: now
                ))
            }
            revokeConflictingActions(
                revokingWhenEnabled.filter { $0 != action },
                messageID: messageID,
                accountScopeKey: normalizedScope,
                in: context,
                now: now
            )
        } else {
            for row in active {
                row.revoke(at: now)
            }
        }

        try? context.save()
        return enabled
    }

    private static func revokeConflictingActions(
        _ actions: [ActionValue],
        messageID: UUID,
        accountScopeKey: String?,
        in context: ModelContext,
        now: Date
    ) {
        guard actions.isEmpty == false else { return }
        let actionSet = Set(actions.map(\.rawValue))
        let rows = (try? context.fetch(FetchDescriptor<ProjectLensAction>())) ?? []
        for row in rows where row.isActive
            && row.targetKind == .message
            && actionSet.contains(row.actionRawValue)
            && row.messageId == messageID
            && row.accountScopeKey == accountScopeKey {
            row.revoke(at: now)
        }
    }

    private static func matchingRows(
        action: ActionValue,
        messageID: UUID,
        accountScopeKey: String?,
        in context: ModelContext
    ) -> [ProjectLensAction] {
        let actionRaw = action.rawValue
        let rows = (try? context.fetch(FetchDescriptor<ProjectLensAction>())) ?? []
        return rows.filter { row in
            row.targetKind == .message
                && row.actionRawValue == actionRaw
                && row.messageId == messageID
                && row.accountScopeKey == accountScopeKey
        }
    }
}
