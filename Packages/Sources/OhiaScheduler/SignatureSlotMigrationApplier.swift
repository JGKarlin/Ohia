import Foundation
import SwiftData
import OhiaCore

/// One-shot migration that seeds account `SignatureSlot`s from pre-slot
/// installs, where signatures lived as plaintext on each `Identity`
/// (`legacySignature`, formerly `signature`).
///
/// Per account with no slots: every distinct non-empty legacy signature
/// (primary identity first, then by creation date) becomes one plain-text
/// slot; the account's default pointer lands on the primary identity's
/// slot. Seeded identities have their legacy column nilled — this applier
/// is the column's only permitted reader.
///
/// Idempotent — the `signatureSlots.isEmpty` guard is authoritative; the
/// UserDefaults boot flag only skips the fetch on later launches. Runs in
/// the UI process after `IdentityMigrationApplier` (identities must exist).
@MainActor
public final class SignatureSlotMigrationApplier {
    private let modelContext: ModelContext
    private let defaults: UserDefaults

    private static let completedFlagKey = "ohia.signature-slot-migration.v1.completed"

    public init(modelContext: ModelContext, defaults: UserDefaults = .standard) {
        self.modelContext = modelContext
        self.defaults = defaults
    }

    /// Returns the number of slots created.
    @discardableResult
    public func run() throws -> Int {
        guard !defaults.bool(forKey: Self.completedFlagKey) else { return 0 }

        var created = 0
        var touchedIdentities = false
        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
        for account in accounts where account.signatureSlots.isEmpty {
            let seeded = seedSlots(for: account)
            created += seeded.created
            touchedIdentities = touchedIdentities || seeded.clearedLegacy
        }

        if created > 0 || touchedIdentities {
            try modelContext.save()
        }
        defaults.set(true, forKey: Self.completedFlagKey)
        return created
    }

    private func seedSlots(for account: Account) -> (created: Int, clearedLegacy: Bool) {
        // Primary first, then oldest-first: the primary's signature becomes
        // the default slot, and slot order mirrors identity age.
        let ordered = account.identities.sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            return $0.createdAt < $1.createdAt
        }

        var slotBySignature: [String: SignatureSlot] = [:]
        var created = 0
        var clearedLegacy = false
        for identity in ordered {
            guard let legacy = identity.legacySignature else { continue }
            defer {
                identity.legacySignature = nil
                clearedLegacy = true
            }
            let text = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Dedupe on the trimmed form so signatures differing only by
            // surrounding whitespace seed one slot.
            if slotBySignature[text] == nil {
                let slot = SignatureSlot(
                    name: Self.slotName(for: identity),
                    format: .plainText,
                    plainText: text,
                    sortOrder: created
                )
                slot.account = account
                modelContext.insert(slot)
                slotBySignature[text] = slot
                created += 1
            }
            if account.defaultSignatureSlotID == nil, identity.isPrimary {
                account.defaultSignatureSlotID = slotBySignature[text]?.id
            }
        }
        // No signed primary identity: default to the first seeded slot so a
        // migrated account never ends up with slots but no default.
        if account.defaultSignatureSlotID == nil, created > 0 {
            account.defaultSignatureSlotID = account.signatureSlots
                .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
                .first?.id
        }
        return (created, clearedLegacy)
    }

    static func slotName(for identity: Identity) -> String {
        let base = identity.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let base, !base.isEmpty {
            return "Signature — \(base)"
        }
        return "Signature — \(identity.address)"
    }
}
