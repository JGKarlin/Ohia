import Foundation
import SwiftData
import OhiaCore
import OhiaMail

/// One-shot migration that seeds a primary `Identity` per `Account`
/// that has none. Applies to existing installs that predate the
/// identity-send feature. Idempotent — the `identities.isEmpty` guard
/// is the authoritative check; the UserDefaults boot flag is only an
/// optimization to avoid a fetch on every launch.
///
/// Also self-heals identity display names that were seeded with the
/// provider label (e.g. "Gmail") rather than a person's name: such a
/// name would render a nonsensical `From:` line ("Gmail <you@gmail.com>"),
/// so it is blanked, falling back to the bare address.
@MainActor
public final class IdentityMigrationApplier {
    private let modelContext: ModelContext
    private let defaults: UserDefaults

    /// One-shot flag for the provider-label repair pass below. Bumping the
    /// version suffix re-arms it if the provider table ever gains a label
    /// that needs sweeping out of existing rows.
    private static let repairFlagKey = "ohia.identity.providerNameRepair.v1"

    public init(modelContext: ModelContext, defaults: UserDefaults = .standard) {
        self.modelContext = modelContext
        self.defaults = defaults
    }

    public func run() throws {
        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
        for account in accounts where account.identities.isEmpty {
            let primary = Identity(
                address: account.emailAddress,
                displayName: Self.sanitizedDisplayName(account.displayName),
                replyTo: nil,
                isPrimary: true
            )
            primary.account = account
            modelContext.insert(primary)
        }

        // One-shot repair of identities seeded (before this fix) with a
        // provider label as the display name. Gated so it runs once: a
        // user is free to later set a display name that happens to match a
        // provider label (e.g. the surname "Yahoo") without it being wiped
        // on the next launch. New accounts are handled by the seed loop's
        // `sanitizedDisplayName`, so this guard only governs legacy repair.
        if !defaults.bool(forKey: Self.repairFlagKey) {
            for identity in try modelContext.fetch(FetchDescriptor<Identity>()) {
                if let name = identity.displayName, MailProviderRegistry.isProviderDisplayName(name) {
                    identity.displayName = nil
                }
            }
            defaults.set(true, forKey: Self.repairFlagKey)
        }

        try modelContext.save()
    }

    /// A provider label ("Gmail") is never a valid `From:` display name;
    /// reduce it (and empty/whitespace) to `nil`.
    static func sanitizedDisplayName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !MailProviderRegistry.isProviderDisplayName(trimmed) else { return nil }
        return trimmed
    }
}
