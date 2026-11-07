import Foundation
import SwiftData
import OhiaCore

/// One-shot migration that assigns a unique `colorIndex` to every existing
/// `Account` that has none. Walks accounts in `createdAt` order so the
/// oldest account keeps the legacy default (Cygnus Cyan, index 0) and
/// each successive account picks the next unused palette entry.
///
/// Idempotent — accounts that already have `colorIndex` set are left alone.
/// The UserDefaults boot flag in `OhiaApp` is only an optimization; the
/// `colorIndex == nil` guard is the authoritative check.
@MainActor
public final class AccountColorMigrationApplier {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Returns the number of accounts that received a new color assignment.
    @discardableResult
    public func run() throws -> Int {
        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
        let ordered = accounts.sorted { $0.createdAt < $1.createdAt }

        var used: Set<Int> = []
        for account in ordered {
            if let existing = account.colorIndex {
                used.insert(existing)
            }
        }

        var assigned = 0
        for account in ordered where account.colorIndex == nil {
            let index = AccountColorPalette.nextIndex(after: used)
            account.colorIndex = index
            used.insert(index)
            assigned += 1
        }
        if assigned > 0 {
            try modelContext.save()
        }
        return assigned
    }
}
