import Foundation
import OhiaCore
import OhiaML
import SwiftData

typealias MailProjectRepositoryError = ManualProjectLifecycleMutationServiceError

struct MailProjectCacheNamespace: Equatable, Sendable {
    let gutterProjectKeyPrefix: String
    let guideDeadlineKeyPrefix: String

    init(projectID: UUID) {
        let id = projectID.uuidString.lowercased()
        gutterProjectKeyPrefix = "manual-project-summary:\(id)"
        guideDeadlineKeyPrefix = "project-guide:manual-project-summary:\(id):"
    }

    var deletionPrefixes: [String] {
        [gutterProjectKeyPrefix, guideDeadlineKeyPrefix]
    }
}

/// Main-actor app facade for the shared OhiaML lifecycle write boundary.
/// The supplied context is used only to obtain its container; every mutation
/// is serialized and committed through a fresh context by the service.
@MainActor
struct MailProjectRepository {
    private let lifecycleService: ManualProjectLifecycleMutationService

    init(
        modelContext: ModelContext,
        notificationCenter: NotificationCenter = .default
    ) {
        self.lifecycleService = ManualProjectLifecycleMutationService(
            container: modelContext.container,
            notificationCenter: notificationCenter
        )
    }

    func rename(projectID: UUID, to name: String) throws {
        try lifecycleService.rename(projectID: projectID, to: name)
    }

    func setPinned(projectID: UUID, _ pinned: Bool) throws {
        try lifecycleService.setPinned(projectID: projectID, pinned)
    }

    func setResolved(projectID: UUID, _ resolved: Bool) throws {
        try lifecycleService.setResolved(projectID: projectID, resolved)
    }

    func delete(projectID: UUID) throws -> MailProjectDeletionSnapshot {
        let snapshot = try lifecycleService.delete(projectID: projectID)
        return MailProjectDeletionSnapshot(
            project: snapshot.project,
            ruleGroups: snapshot.ruleGroups,
            decisions: snapshot.decisions,
            memberships: snapshot.memberships,
            configurationDraft: snapshot.configurationDraft,
            projectCacheKeys: MailProjectCacheNamespace(projectID: projectID).deletionPrefixes,
            projectGuideState: snapshot.projectGuideState
        )
    }

    func delete(
        projectID: UUID,
        invalidatingCachesWith invalidateCaches: (UUID) async -> Void
    ) async throws -> MailProjectDeletionSnapshot {
        let snapshot = try delete(projectID: projectID)
        await invalidateCaches(projectID)
        return snapshot
    }

    func restore(_ snapshot: MailProjectDeletionSnapshot) throws {
        try lifecycleService.restore(snapshot)
    }
}

/// Stable target for the window's native project-deletion Undo chain.
/// A failed restore is re-registered after the Undo event completes so a
/// transient name collision never consumes the user's sole recovery action.
@MainActor
final class MailProjectDeletionUndoTarget {
    typealias Restore = @MainActor (MailProjectDeletionSnapshot) throws -> Void
    typealias Delete = @MainActor (UUID) throws -> MailProjectDeletionSnapshot
    typealias Mutation = @MainActor () -> Void
    typealias Failure = @MainActor (ProjectMutationAction, any Error) -> Void

    private enum Operation {
        case restore(MailProjectDeletionSnapshot)
        case delete(UUID)
    }

    func registerDeletion(
        on undoManager: UndoManager?,
        snapshot: MailProjectDeletionSnapshot,
        restore: @escaping Restore,
        delete: @escaping Delete,
        onMutation: @escaping Mutation,
        onFailure: @escaping Failure
    ) {
        guard let undoManager else { return }
        register(
            operation: .restore(snapshot),
            on: undoManager,
            restore: restore,
            delete: delete,
            onMutation: onMutation,
            onFailure: onFailure
        )
    }

    private func register(
        operation: Operation,
        on undoManager: UndoManager,
        restore: @escaping Restore,
        delete: @escaping Delete,
        onMutation: @escaping Mutation,
        onFailure: @escaping Failure
    ) {
        undoManager.registerUndo(withTarget: self) { [weak undoManager] target in
            guard let undoManager else { return }
            do {
                let inverse: Operation
                switch operation {
                case .restore(let snapshot):
                    try restore(snapshot)
                    inverse = .delete(snapshot.project.id)
                case .delete(let projectID):
                    inverse = .restore(try delete(projectID))
                }
                onMutation()
                target.register(
                    operation: inverse,
                    on: undoManager,
                    restore: restore,
                    delete: delete,
                    onMutation: onMutation,
                    onFailure: onFailure
                )
            } catch {
                let action: ProjectMutationAction
                switch operation {
                case .restore: action = .restore
                case .delete: action = .delete
                }
                onFailure(action, error)
                target.retainFailedOperation(
                    operation,
                    on: undoManager,
                    restore: restore,
                    delete: delete,
                    onMutation: onMutation,
                    onFailure: onFailure
                )
            }
        }
        undoManager.setActionName("Delete Project")
    }

    private func retainFailedOperation(
        _ operation: Operation,
        on undoManager: UndoManager,
        restore: @escaping Restore,
        delete: @escaping Delete,
        onMutation: @escaping Mutation,
        onFailure: @escaping Failure
    ) {
        Task { @MainActor [weak self, weak undoManager] in
            await Task.yield()
            guard let self, let undoManager else { return }
            self.register(
                operation: operation,
                on: undoManager,
                restore: restore,
                delete: delete,
                onMutation: onMutation,
                onFailure: onFailure
            )
        }
    }
}
