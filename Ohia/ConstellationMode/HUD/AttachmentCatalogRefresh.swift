import Foundation
import OhiaCore

/// When an open attachment catalog (the Front Page reader's Attachments,
/// a locked node's list) re-reads its attachments, and whether it takes
/// what it read.
enum AttachmentCatalogRefresh {
    /// The background jobs that change what a catalog shows: an extraction
    /// (a "queued" or "will retry" badge, a description), a photo's capture
    /// time and place, an attachment summary.
    static let jobs: Set<JobType> = [
        .extractAttachments, .extractVisualAttachments, .extractCaptureMetadata, .summarizeAttachments,
    ]

    /// Whether `event` may have changed a catalog's attachments: one of
    /// `jobs`, or the broad reconciliation the app sends in place of
    /// completions that fell out of a worker's bounded status history
    /// (`JobCompletionEvent.fullReconciliation`), any of which may have been
    /// one of them.
    static func requiresReload(after event: JobCompletionEvent) -> Bool {
        jobs.contains(event.type) || event.isFullReconciliation
    }

    /// Whether the catalog takes a re-read: only when it changed, so an
    /// unchanged one leaves the view alone, and never an empty one, which
    /// is a cancelled or failed read (attachments are not removed from an
    /// open message, and a catalog that opened empty stays so rather than
    /// re-laying out the reader around a new section).
    static func accepts(_ latest: [LockedAttachmentSummary], over current: [LockedAttachmentSummary]) -> Bool {
        !latest.isEmpty && latest != current
    }
}

extension JobCompletionEvent {
    /// The one broad data-change event the app sends when a completion
    /// interval fell out of a worker's bounded status history before the app
    /// observed it, so every view reconciles from the store.
    static func fullReconciliation(completedAt: Date) -> JobCompletionEvent {
        JobCompletionEvent(
            type: .imapPollFolder,
            payload: nil,
            completedAt: completedAt,
            messageMutations: fullReconciliationMutations
        )
    }

    /// Whether this is `fullReconciliation`'s event.
    var isFullReconciliation: Bool {
        type == .imapPollFolder && payload == nil && messageMutations == Self.fullReconciliationMutations
    }

    private static let fullReconciliationMutations = [
        PipelineMessageMutation(messageIDs: [], facets: [.visibility]),
    ]
}
