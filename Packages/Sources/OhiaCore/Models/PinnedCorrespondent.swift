import Foundation
import SwiftData

/// User-pinned correspondent — a one-row pin keyed by lowercased primary
/// email address. Pinned addresses are forced into Constellation Mode's
/// "major correspondent" set regardless of recency-weighted message count,
/// so the user can keep a small set of important relationships permanently
/// salient even when the algorithm would otherwise demote them (low recent
/// volume, long-dormant exchange, etc.).
///
/// Stored as a separate model rather than a boolean flag on `Correspondent`
/// so the migration risk is zero — adding a new model is a clean schema
/// extension, while adding a non-optional column to an existing `@Model`
/// has burned this codebase before (see the SwiftData enum-migration note
/// in user memory). Sparse table: typical users will have only a handful
/// of pins, so a separate table is also cheaper to scan.
@Model
public final class PinnedCorrespondent {
    /// Lowercased primary email of the pinned correspondent. The unique
    /// constraint means we can't accidentally write duplicate pins for
    /// the same address — toggling pin twice produces zero rows, not two.
    @Attribute(.unique) public var primaryEmail: String
    /// Display name captured at pin time. Used by the settings list to
    /// label each pin without a join back to `Correspondent`. May be `nil`
    /// when the user pinned an address that has no display-name match in
    /// the messages corpus yet.
    public var displayName: String?
    /// Wall-clock time of the pin. Drives the default sort order in the
    /// settings list (most-recently-pinned first) so the user can find
    /// their newest additions without scrolling.
    public var pinnedAt: Date

    public init(primaryEmail: String, displayName: String? = nil, pinnedAt: Date = .now) {
        self.primaryEmail = primaryEmail.lowercased()
        self.displayName = displayName
        self.pinnedAt = pinnedAt
    }

    /// Idempotent setter — converges the store onto `pinned == true/false`
    /// for a given address in one transaction. Used by both the locked
    /// overlay's context menu and the settings unpin button so neither path
    /// can produce duplicate rows even if the two windows race against the
    /// same address. Cleans up any pre-existing duplicates (which shouldn't
    /// happen given the unique constraint, but settles any prior corruption
    /// from a crash mid-transaction) by keeping only the first row.
    ///
    /// Lowercases the email and rejects empty/whitespace-only addresses so
    /// the caller can pass `row.fromAddress` straight through without a
    /// separate guard at every call site.
    ///
    /// Returns the resolved pinned state — `true` if the address ends the
    /// transaction with a row in the table, `false` if not. Useful for
    /// optimistic UI updates that need the post-transaction state without
    /// re-fetching.
    @MainActor
    @discardableResult
    public static func setPinned(
        _ pinned: Bool,
        for email: String,
        displayName: String? = nil,
        in context: ModelContext
    ) -> Bool {
        let normalized = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let descriptor = FetchDescriptor<PinnedCorrespondent>(
            predicate: #Predicate<PinnedCorrespondent> { $0.primaryEmail == normalized }
        )
        let existing = (try? context.fetch(descriptor)) ?? []

        switch (pinned, existing.first) {
        case (true, nil):
            let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let pin = PinnedCorrespondent(
                primaryEmail: normalized,
                displayName: (trimmedName?.isEmpty == false) ? trimmedName : nil
            )
            context.insert(pin)
        case (true, .some):
            // Already pinned; no insert needed. Fall through to dedup pass.
            break
        case (false, .some(let row)):
            context.delete(row)
        case (false, nil):
            // Already unpinned; nothing to do.
            return false
        }

        // Drop any stray duplicates beyond the first row — shouldn't happen
        // given `@Attribute(.unique)` on `primaryEmail`, but a defensive
        // cleanup costs nothing and protects against a half-applied prior
        // transaction surviving an app crash.
        for duplicate in existing.dropFirst() {
            context.delete(duplicate)
        }

        try? context.save()
        return pinned
    }
}
