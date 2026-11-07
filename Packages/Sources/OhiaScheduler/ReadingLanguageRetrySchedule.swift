import Foundation

/// Bounded background retries for generated text withheld because it could
/// not be written in the reading language (`DisplayLanguageGuard` could not
/// translate a source-language passage). After the first such failure an item
/// waits out each delay in turn; once every delay is spent the background
/// lane stops selecting it, and only an on-demand request generates it.
///
/// Only a failure where the model answered counts: a translation pass that
/// never reached an answer (model unloaded, generation cancelled) is a
/// transient miss the caller retries normally. Each entry remembers the input
/// marker it failed on; a different marker (new evidence, a new summary-input
/// fingerprint) lifts the entry, as does a change of reading language. Only
/// items that failed have entries. The schedule lives in memory, so a restart
/// gives every item a full fresh schedule: one attempt, then every retry.
@MainActor
public final class ReadingLanguageRetrySchedule {
    /// Message body summaries: 15 minutes, 1 hour, then 6 hours.
    public nonisolated static let bodySummaryDelays: [TimeInterval] = [15 * 60, 60 * 60, 6 * 60 * 60]
    /// Attachment-pane summaries: 30 minutes, 2 hours, then 8 hours.
    public nonisolated static let attachmentSummaryDelays: [TimeInterval] = [30 * 60, 2 * 60 * 60, 8 * 60 * 60]

    /// The wait before each background retry.
    public let retryDelays: [TimeInterval]
    private var entries: [UUID: Entry] = [:]

    private struct Entry {
        let failures: Int
        /// Nil once the retries are spent.
        let retryAt: Date?
        let readingLanguage: String
        let inputMarker: String?
    }

    public nonisolated init(retryDelays: [TimeInterval]) {
        self.retryDelays = retryDelays
    }

    /// Records a withheld attempt and returns when the background may try
    /// again, or nil when its retries are spent. A failure on a different
    /// input marker starts the count over.
    @discardableResult
    public func recordFailure(_ id: UUID, readingLanguage: String, inputMarker: String?, now: Date) -> Date? {
        liftDeferrals(notMatching: readingLanguage)
        let previous = entries[id].flatMap { $0.inputMarker == inputMarker ? $0.failures : nil } ?? 0
        let failures = previous + 1
        let retryAt = failures <= retryDelays.count
            ? now.addingTimeInterval(retryDelays[failures - 1])
            : nil
        entries[id] = Entry(failures: failures, retryAt: retryAt, readingLanguage: readingLanguage, inputMarker: inputMarker)
        return retryAt
    }

    /// Forgets an item once it has been written in the reading language.
    public func clear(_ id: UUID) {
        entries[id] = nil
    }

    /// Items with an entry under the current reading language, whose input
    /// markers the caller looks up for `blocked`.
    public func trackedIDs(readingLanguage: String) -> Set<UUID> {
        liftDeferrals(notMatching: readingLanguage)
        return Set(entries.keys)
    }

    /// Items the background must not select now: waiting out a retry, or
    /// with every retry spent. An item whose current input marker differs
    /// from the one it failed on is lifted instead; one the caller has no
    /// marker for keeps its entry.
    public func blocked(
        readingLanguage: String,
        now: Date,
        inputMarker: (UUID) -> String? = { _ in nil }
    ) -> Set<UUID> {
        liftDeferrals(notMatching: readingLanguage)
        var blocked = Set<UUID>()
        for (id, entry) in entries {
            if let current = inputMarker(id), current != entry.inputMarker {
                entries[id] = nil
                continue
            }
            if entry.retryAt.map({ $0 > now }) ?? true { blocked.insert(id) }
        }
        return blocked
    }

    /// Withheld attempts recorded for an item under the current reading
    /// language.
    public func failures(of id: UUID, readingLanguage: String) -> Int {
        liftDeferrals(notMatching: readingLanguage)
        return entries[id]?.failures ?? 0
    }

    private func liftDeferrals(notMatching readingLanguage: String) {
        if entries.values.contains(where: { $0.readingLanguage != readingLanguage }) {
            entries = entries.filter { $0.value.readingLanguage == readingLanguage }
        }
    }
}
