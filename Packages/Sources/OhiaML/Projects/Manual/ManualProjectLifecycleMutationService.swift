import Foundation
import OhiaCore
import SwiftData

public enum ManualProjectLifecycleMutationServiceError: Error, Equatable, Sendable {
    case projectNotFound(UUID)
    case nameAlreadyExists(String)
    case configurationDraftAlreadyExists
}

/// The sole cross-context write boundary for project-owned lifecycle state.
/// Every command acquires the same authority as configuration and membership
/// writes, then creates and commits through a fresh context.
@MainActor
public struct ManualProjectLifecycleMutationService {
    private let container: ModelContainer
    private let notificationCenter: NotificationCenter
    private let now: @MainActor () -> Date
    private let postMessageAttentionChanged: @MainActor (Set<UUID>) -> Void
    private let beforeTransactionPersist: @MainActor () throws -> Void

    public init(
        container: ModelContainer,
        notificationCenter: NotificationCenter = .default
    ) {
        self.container = container
        self.notificationCenter = notificationCenter
        self.now = { .now }
        self.postMessageAttentionChanged = { messageIDs in
            notificationCenter.post(
                name: .ohiaMessageAttentionChanged,
                object: nil,
                userInfo: MessageAttentionNotificationCoding.userInfo(messageIDs: messageIDs)
            )
        }
        self.beforeTransactionPersist = {}
    }

    init(
        container: ModelContainer,
        notificationCenter: NotificationCenter = .default,
        now: @escaping @MainActor () -> Date = { .now },
        postMessageAttentionChanged: (@MainActor (Set<UUID>) -> Void)? = nil,
        _testBeforeTransactionPersist: @escaping @MainActor () throws -> Void = {}
    ) {
        self.container = container
        self.notificationCenter = notificationCenter
        self.now = now
        self.postMessageAttentionChanged = postMessageAttentionChanged ?? { messageIDs in
            notificationCenter.post(
                name: .ohiaMessageAttentionChanged,
                object: nil,
                userInfo: MessageAttentionNotificationCoding.userInfo(messageIDs: messageIDs)
            )
        }
        self.beforeTransactionPersist = _testBeforeTransactionPersist
    }

    public func rename(projectID: UUID, to name: String) throws {
        let normalizedName = try MailProject.normalizedName(name)
        try withFreshTransaction { context in
            let project = try requireProject(projectID, in: context)
            let conflicts = try context.fetch(FetchDescriptor<MailProject>(
                predicate: #Predicate { $0.normalizedName == normalizedName }
            ))
            guard conflicts.contains(where: { $0.id != projectID }) == false else {
                throw ManualProjectLifecycleMutationServiceError.nameAlreadyExists(normalizedName)
            }
            try project.rename(to: name, updatedAt: now())
        }
    }

    public func setPinned(projectID: UUID, _ pinned: Bool) throws {
        try withFreshTransaction { context in
            let project = try requireProject(projectID, in: context)
            guard project.isPinned != pinned else { return }
            project.isPinned = pinned
            if pinned {
                let projects = try context.fetch(FetchDescriptor<MailProject>())
                project.pinSortIndex = (projects.compactMap { candidate in
                    candidate.id == projectID ? nil : candidate.pinSortIndex
                }.max() ?? -1) + 1
            } else {
                project.pinSortIndex = nil
            }
            project.updatedAt = now()
        }
    }

    public func setResolved(projectID: UUID, _ resolved: Bool) throws {
        let affectedMessageIDs = try withFreshTransaction { context -> Set<UUID> in
            let project = try requireProject(projectID, in: context)
            let actionRows: [ProjectLensAction]
            if resolved {
                actionRows = []
            } else {
                let memberIDs = Set(try projectMemberships(projectID, in: context).map(\.messageID))
                actionRows = ProjectLensAction.activeActions(in: context).filter { row in
                    row.targetKind == .message
                        && row.messageId.map(memberIDs.contains) == true
                        && (row.actionValue == .resolvedByUser || row.actionValue == .confirmedByUser)
                }
            }
            let timestamp = now()
            project.resolvedAt = resolved ? timestamp : nil
            project.updatedAt = timestamp
            for row in actionRows { row.revoke(at: timestamp) }
            return Set(actionRows.compactMap(\.messageId))
        }

        if affectedMessageIDs.isEmpty == false {
            postMessageAttentionChanged(affectedMessageIDs)
        }
    }

    public func delete(projectID: UUID) throws -> MailProjectDeletionSnapshot {
        let context = freshContext()
        return try ManualProjectMembershipRepository(
            modelContext: context,
            notificationCenter: notificationCenter,
            now: now,
            beforeSave: beforeTransactionPersist
        ).deleteProjectOwnedState(projectID: projectID)
    }

    public func restore(_ snapshot: MailProjectDeletionSnapshot) throws {
        try withFreshTransaction { context in
            if try project(snapshot.project.id, in: context) != nil {
                throw ManualProjectLifecycleMutationServiceError.nameAlreadyExists(
                    snapshot.project.normalizedName
                )
            }
            let normalizedName = snapshot.project.normalizedName
            let conflicts = try context.fetch(FetchDescriptor<MailProject>(
                predicate: #Predicate { $0.normalizedName == normalizedName }
            ))
            guard conflicts.isEmpty else {
                throw ManualProjectLifecycleMutationServiceError.nameAlreadyExists(normalizedName)
            }
            if snapshot.configurationDraft != nil,
               try context.fetchCount(FetchDescriptor<MailProjectConfigurationDraft>()) > 0 {
                throw ManualProjectLifecycleMutationServiceError.configurationDraftAlreadyExists
            }

            let project = try MailProject(
                id: snapshot.project.id,
                displayName: snapshot.project.displayName,
                accountIDs: Array(snapshot.project.accountIDs),
                automaticIntakeStartAt: snapshot.project.automaticIntakeStartAt,
                configurationRevision: snapshot.project.configurationRevision,
                isPinned: snapshot.project.isPinned,
                pinSortIndex: snapshot.project.pinSortIndex,
                lastMembershipUsedAt: snapshot.project.lastMembershipUsedAt,
                resolvedAt: snapshot.project.resolvedAt,
                health: snapshot.project.health,
                lastMembershipError: snapshot.project.lastMembershipError,
                createdAt: snapshot.project.createdAt,
                updatedAt: snapshot.project.updatedAt
            )
            context.insert(project)

            for groupSnapshot in snapshot.ruleGroups {
                let group = MailProjectRuleGroup(
                    id: groupSnapshot.id,
                    kind: groupSnapshot.kind,
                    sortIndex: groupSnapshot.sortIndex
                )
                group.project = project
                for conditionSnapshot in groupSnapshot.conditions {
                    let condition = try MailProjectRuleCondition(
                        id: conditionSnapshot.id,
                        facet: conditionSnapshot.facet,
                        polarity: conditionSnapshot.polarity,
                        quantifier: conditionSnapshot.quantifier,
                        values: conditionSnapshot.values,
                        correspondentRole: conditionSnapshot.correspondentRole,
                        keywordScopes: conditionSnapshot.keywordScopes,
                        keywordOperator: conditionSnapshot.keywordOperator,
                        sortIndex: conditionSnapshot.sortIndex
                    )
                    condition.group = group
                }
            }

            for decision in snapshot.decisions {
                context.insert(MailProjectDecision(
                    id: decision.id,
                    projectID: decision.projectID,
                    targetKind: decision.targetKind,
                    targetID: decision.targetID,
                    decision: decision.decision,
                    createdAt: decision.createdAt,
                    updatedAt: decision.updatedAt
                ))
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for membership in snapshot.memberships {
                context.insert(try MailProjectMembership(
                    id: membership.id,
                    projectID: membership.projectID,
                    messageID: membership.messageID,
                    configurationRevision: membership.configurationRevision,
                    source: membership.source,
                    matchingGroupID: membership.matchingGroupID,
                    matchingConditionIDs: membership.matchingConditionIDs,
                    provenanceJSON: String(
                        decoding: try encoder.encode(membership.provenance),
                        as: UTF8.self
                    ),
                    sourceFingerprint: membership.sourceFingerprint,
                    evaluatedAt: membership.evaluatedAt
                ))
            }

            if let draft = snapshot.configurationDraft {
                context.insert(MailProjectConfigurationDraft(
                    id: draft.id,
                    targetProjectID: draft.targetProjectID,
                    baseRevision: draft.baseRevision,
                    payloadVersion: draft.payloadVersion,
                    payloadJSON: draft.payloadJSON,
                    createdAt: draft.createdAt,
                    updatedAt: draft.updatedAt
                ))
            }

            if let guideState = snapshot.projectGuideState {
                context.insert(DeadlineGuideState(
                    entryID: guideState.entryID,
                    completedStepIDsJSON: guideState.completedStepIDsJSON,
                    guideLastReadAt: guideState.guideLastReadAt,
                    guideLastReadReason: guideState.guideLastReadReason,
                    updatedAt: guideState.updatedAt
                ))
            }
        }

        notificationCenter.post(
            name: .ohiaManualProjectMembershipDidChange,
            object: nil,
            userInfo: ManualProjectMembershipNotificationCoding.userInfo(
                projectIDs: [snapshot.project.id],
                messageIDs: Set(snapshot.memberships.map(\.messageID)),
                configurationRevision: snapshot.project.configurationRevision
            )
        )
    }

    private func withFreshTransaction<Result>(
        _ body: (ModelContext) throws -> Result
    ) throws -> Result {
        return try ManualProjectWriteAuthority.withLock {
            let context = freshContext()
            var committed = false
            defer {
                if committed == false { context.rollback() }
            }
            var result: Result?
            try context.transaction {
                result = try body(context)
                try beforeTransactionPersist()
            }
            committed = true
            guard let result else {
                preconditionFailure("A lifecycle transaction must produce a result.")
            }
            return result
        }
    }

    private func freshContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func requireProject(_ projectID: UUID, in context: ModelContext) throws -> MailProject {
        guard let project = try project(projectID, in: context) else {
            throw ManualProjectLifecycleMutationServiceError.projectNotFound(projectID)
        }
        return project
    }

    private func project(_ projectID: UUID, in context: ModelContext) throws -> MailProject? {
        let id = projectID
        return try context.fetch(FetchDescriptor<MailProject>(
            predicate: #Predicate { $0.id == id }
        )).first
    }

    private func projectMemberships(
        _ projectID: UUID,
        in context: ModelContext
    ) throws -> [MailProjectMembership] {
        let id = projectID
        return try context.fetch(FetchDescriptor<MailProjectMembership>(
            predicate: #Predicate { $0.projectID == id }
        ))
    }
}
