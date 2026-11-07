import Foundation

/// Pure helper that resolves the playhead `Date` to a single message ID.
/// Two scopes are supported:
/// - `.global(eligible:)`: chronological mode. Searches the full eligible
///   set (post `state.filter ∩ viewportRange ∩ bracketedRange`).
/// - `.chapter(_)`: conversation mode. Searches only the active chapter's
///   `messageIDs`.
///
/// Tie-break is deterministic: earlier-in-time wins; if two messages share
/// the exact same `vectorTimeFilterDate`, the lower-UUID wins. This keeps
/// keyboard stepping reproducible across runs.
public enum TimelinePlayheadResolver {

    /// A single entry in the playhead resolver's search index. Carrying the
    /// `id` + `date` as a value type lets the resolver run off-main without
    /// SwiftData crossings.
    public struct MessageIndexEntry: Sendable, Hashable {
        public let id: UUID
        public let date: Date
        public nonisolated init(id: UUID, date: Date) {
            self.id = id
            self.date = date
        }
    }

    public enum ResolveScope: Sendable {
        /// Sorted ascending by `date`. The caller (snapshot builder) is
        /// responsible for sortedness — the resolver doesn't re-sort.
        case global(eligible: [MessageIndexEntry])
        case chapter(TimelineChapter, dateLookup: [UUID: Date])
    }

    /// Returns the message whose `date` is nearest to `playhead`.
    /// Returns nil when the scope is empty.
    ///
    /// `.global` requires its eligible array to be sorted ascending by
    /// date (the snapshot builder guarantees this). `.chapter` re-sorts
    /// defensively before searching — the chapter's `messageIDs` happen
    /// to be sorted in production, but the resolver does not rely on a
    /// caller-side invariant it can't verify.
    public static func nearestMessage(
        playhead: Date,
        scope: ResolveScope
    ) -> UUID? {
        switch scope {
        case .global(let eligible):
            return nearestInSorted(playhead: playhead, entries: eligible)
        case .chapter(let chapter, let dateLookup):
            let entries: [MessageIndexEntry] = chapter.messageIDs
                .compactMap { id -> MessageIndexEntry? in
                    guard let date = dateLookup[id] else { return nil }
                    return MessageIndexEntry(id: id, date: date)
                }
                .sorted { lhs, rhs in
                    if lhs.date != rhs.date { return lhs.date < rhs.date }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            return nearestInSorted(playhead: playhead, entries: entries)
        }
    }

    /// Binary-search nearest-neighbor with deterministic tie-break.
    private static func nearestInSorted(
        playhead: Date,
        entries: [MessageIndexEntry]
    ) -> UUID? {
        guard entries.isEmpty == false else { return nil }
        if entries.count == 1 { return entries[0].id }

        var lo = 0
        var hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].date < playhead {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        let upperIndex = lo
        let lowerIndex = lo - 1

        switch (lowerIndex >= 0, upperIndex < entries.count) {
        case (false, true):
            return entries[upperIndex].id
        case (true, false):
            return entries[lowerIndex].id
        case (true, true):
            let lower = entries[lowerIndex]
            let upper = entries[upperIndex]
            let lowerDistance = abs(playhead.timeIntervalSince(lower.date))
            let upperDistance = abs(playhead.timeIntervalSince(upper.date))
            if lowerDistance == upperDistance {
                // Earlier-in-time wins; sorted-by-date construction guarantees
                // `lower.date <= upper.date`. Only fall through to UUID
                // tie-break when both entries share the exact same date.
                if lower.date < upper.date { return lower.id }
                return lower.id.uuidString < upper.id.uuidString ? lower.id : upper.id
            }
            return lowerDistance <= upperDistance ? lower.id : upper.id
        case (false, false):
            return nil
        }
    }
}
