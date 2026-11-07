import Foundation
import SwiftData
import OhiaCore

@MainActor
public enum ComposerDraftSyncScheduler {
    public static let priority = 2

    public static func enqueueIfNeeded(context: ModelContext) throws {
        guard ComposerDraftSyncWorker.hasPendingWork(context: context) else { return }
        if try hasActiveJob(context: context) { return }
        try JobQueue().enqueue(type: .syncComposerDrafts, priority: priority, context: context)
    }

    public static func enqueueDraftSync(draft: Draft?, context: ModelContext) throws {
        guard ComposerDraftSyncWorker.hasPendingWork(for: draft, context: context) else { return }
        if try hasActiveJob(context: context) { return }
        try JobQueue().enqueue(type: .syncComposerDrafts, priority: priority, context: context)
        publishQueuedActivity(for: draft)
    }

    /// Stage a draft-sync job without saving so callers can commit the job and
    /// the draft mutation atomically in one `ModelContext.save()`.
    public static func stageDraftSync(draft: Draft?, context: ModelContext) throws {
        guard ComposerDraftSyncWorker.hasPendingWork(for: draft, context: context) else { return }
        if try hasActiveJob(context: context) { return }
        JobQueue().stage(type: .syncComposerDrafts, priority: priority, context: context)
        publishQueuedActivity(for: draft)
    }

    private static func hasActiveJob(context: ModelContext) throws -> Bool {
        try JobFetch.activeJobExists(type: .syncComposerDrafts, context: context)
    }

    private static func publishQueuedActivity(for draft: Draft?) {
        guard let draft else { return }
        NotificationCenter.default.post(
            name: .ohiaIMAPActivityQueued,
            object: WorkerIMAPActivitySnapshot(
                kind: .pending,
                accountID: draft.mailboxDraftAccountID ?? draft.composeFromAccountID,
                folder: draft.mailboxDraftFolderPath
            )
        )
    }

}
