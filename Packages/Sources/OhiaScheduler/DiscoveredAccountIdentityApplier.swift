import Foundation
import SwiftData
import OhiaCore
import OhiaIngest
import OhiaMail

/// Seeds `Identity` rows from account discovery metadata. Discovery sources
/// can report multiple addresses for one mailbox; those are send-as aliases,
/// not separate accounts, and must participate in sent-mail detection.
@MainActor
public enum DiscoveredAccountIdentityApplier {
    @discardableResult
    public static func apply(
        discovered: DiscoveredAccount,
        to account: Account,
        in context: ModelContext
    ) throws -> Int {
        let addresses = DiscoveredAccount.normalizedIdentityEmailAddresses(
            primaryEmailAddress: account.emailAddress,
            identityEmailAddresses: discovered.identityEmailAddresses
        )
        let identityDisplayName: String?
        if let discoveredIdentityDisplayName = discovered.identityDisplayName {
            identityDisplayName = discoveredIdentityDisplayName
        } else if discovered.source == .manual {
            identityDisplayName = discovered.displayName
        } else {
            identityDisplayName = nil
        }
        return try apply(
            identityEmailAddresses: addresses,
            displayName: identityDisplayName,
            to: account,
            in: context
        )
    }

    @discardableResult
    public static func apply(
        identityEmailAddresses: [String],
        displayName: String?,
        to account: Account,
        in context: ModelContext,
        replaceBlankDisplayNames: Bool = true
    ) throws -> Int {
        let addresses = normalizedAddresses(
            primaryEmailAddress: account.emailAddress,
            identityEmailAddresses: identityEmailAddresses
        )
        guard !addresses.isEmpty else { return 0 }

        var existing = Set(account.identities.map { $0.address.lowercased() })
        var inserted = 0
        var changed = false
        let sanitizedDisplayName = displayName.flatMap(IdentityMigrationApplier.sanitizedDisplayName)
        let normalizedPrimary = normalize(account.emailAddress)
        var hasPrimary = account.identities.contains(where: \.isPrimary)

        for address in addresses {
            if existing.contains(address) {
                if let identity = account.identities.first(where: { normalize($0.address) == address }),
                   let sanitizedDisplayName,
                   shouldReplaceDisplayName(
                       identity.displayName,
                       with: sanitizedDisplayName,
                       accountDisplayName: account.displayName,
                       replaceBlankDisplayNames: replaceBlankDisplayNames
                   ) {
                    identity.displayName = sanitizedDisplayName
                    changed = true
                }
                continue
            }

            let shouldBePrimary = !hasPrimary && address == normalizedPrimary
            let identity = Identity(
                address: address,
                displayName: sanitizedDisplayName,
                replyTo: nil,
                isPrimary: shouldBePrimary
            )
            identity.account = account
            context.insert(identity)
            existing.insert(address)
            inserted += 1
            changed = true
            hasPrimary = hasPrimary || shouldBePrimary
        }

        if !hasPrimary,
           let primaryIdentity = account.identities.first(where: { $0.address == normalizedPrimary }) {
            account.setPrimaryIdentity(primaryIdentity)
            changed = true
        }

        if changed {
            try context.save()
        }
        return inserted
    }

    private static func normalizedAddresses(
        primaryEmailAddress: String,
        identityEmailAddresses: [String]
    ) -> [String] {
        DiscoveredAccount.normalizedIdentityEmailAddresses(
            primaryEmailAddress: primaryEmailAddress,
            identityEmailAddresses: identityEmailAddresses
        )
    }

    private static func normalize(_ address: String) -> String {
        address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func shouldReplaceDisplayName(
        _ current: String?,
        with replacement: String,
        accountDisplayName: String,
        replaceBlankDisplayNames: Bool
    ) -> Bool {
        let current = current?.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == replacement {
            return false
        }
        if current?.isEmpty ?? true {
            return replaceBlankDisplayNames
        }
        guard let current else { return replaceBlankDisplayNames }
        if MailProviderRegistry.isProviderDisplayName(current) {
            return true
        }
        let accountName = accountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !accountName.isEmpty && current == accountName
    }
}
