import Foundation

/// Shared constants for Composer-initiated draft work in the job queue.
///
/// The Composer enqueues `.generateDraft` at `userInitiatedPriority` when the
/// user selects a queued message, clicks Generate, types an instruction, or
/// requests a regeneration. `BackgroundScheduler` claims jobs at or above
/// this priority through a dedicated lane that runs ahead of live-inbound
/// freshness work; background intake reseeds at priority 6 and never enters
/// that lane.
public enum ComposerDraftScheduling {
    public static let userInitiatedPriority = 3
}
