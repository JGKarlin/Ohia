import Foundation
import SwiftData
import OhiaCore

/// Durable consume-and-clear for sent-mail confirmations.
///
/// The OutboxWorker marks an `OutboxItem` `sentConfirmationPendingPlayback = true`
/// when the SMTP server accepts it; the distributed notification that follows is
/// only a wake-up hint naming the row's opaque id. This is the single source of
/// truth that turns that durable flag into exactly one sound per send:
///
/// - **Duplicate hint** → the flag is already cleared, so the row is filtered out
///   and nothing plays twice.
/// - **Spoofed hint** → the named id matches no `.sent`+pending row, so nothing
///   plays and no metadata was ever on the wire to begin with.
/// - **Dropped hint** → the flag stays set until the launch sweep consumes it.
///
/// Consumption is atomic: each matching row's flag is cleared and the context is
/// saved in the same pass that reports the row for playback.
@MainActor
enum SentConfirmationConsumer {
    /// Fetch `.sent` rows still pending playback, narrow to `predicate`, clear
    /// their flag, and save. Returns the consumed rows so the caller can play the
    /// chime once per row. An empty result means nothing was owed (or it was
    /// already consumed).
    @discardableResult
    static func consumePending(
        in context: ModelContext,
        matching predicate: (OutboxItem) -> Bool
    ) -> [OutboxItem] {
        let candidates = ((try? context.fetch(FetchDescriptor<OutboxItem>())) ?? [])
            .filter { $0.status == .sent && $0.sentConfirmationPendingPlayback }
            .filter(predicate)
        guard !candidates.isEmpty else { return [] }
        for item in candidates {
            item.sentConfirmationPendingPlayback = false
        }
        try? context.save()
        return candidates
    }
}
