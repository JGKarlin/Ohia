import Foundation
import SwiftData
import OhiaCore
import OhiaMail

/// Applies one-time Plan-2 migration decisions to the real SwiftData
/// store + IMAP keychain. Main-actor-bound because ModelContext is.
///
/// The pure decision layer lives in OhiaCore; this applier is the
/// main-actor wrapper that (a) snapshots accounts into
/// AccountMigrationInput, (b) runs the pure decider, (c) mutates the
/// store + keychain for .silentReuse decisions, and (d) leaves
/// .needsAttention accounts for the Settings banner to handle.
@MainActor
public final class AccountMigrationApplier {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Runs the full migration pass. Idempotent — accounts already
    /// migrated (imapHost != nil) short-circuit to .noOp inside the
    /// decider.
    @discardableResult
    public func run() throws -> Int {
        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
        let inputs = accounts.map { account in
            let inferredSMTPAuthMethod: SMTPAuthMethod? = account.smtpAuthMethod
                ?? (account.smtpKeychainRef?.hasPrefix("smtp-oauth-") == true ? SMTPAuthMethod.oauth2 : nil)
            return AccountMigrationInput(
                id: account.id,
                emailAddress: account.emailAddress,
                hasImapHost: account.imapHost != nil,
                smtpAuthMethod: inferredSMTPAuthMethod,
                hasSmtpKeychainRef: account.smtpKeychainRef != nil
            )
        }
        let decisions = AccountMigrationDecider.decideMigrations(
            inputs,
            lookup: MailProviderRegistryLookup()
        )
        var migrated = 0
        for decision in decisions {
            guard case .silentReuse(let id) = decision else { continue }
            guard let account = accounts.first(where: { $0.id == id }) else { continue }
            guard let provider = MailProviderRegistry.lookup(
                email: account.emailAddress,
                smtpHost: account.smtpHost,
                imapHost: account.imapHost
            ) else { continue }

            account.imapHost = provider.imapHost
            account.imapPort = provider.imapPort
            account.imapSecurity = provider.imapSecurity
            account.imapUsername = account.smtpUsername ?? account.emailAddress
            account.imapAuthMethod = IMAPAuthMethod.oauth2
            account.imapKeychainRef = account.smtpKeychainRef
            account.smtpAuthMethod = account.smtpAuthMethod ?? SMTPAuthMethod.oauth2
            account.needsImapReauth = false
            migrated += 1
        }
        if migrated > 0 {
            try modelContext.save()
        }
        return migrated
    }
}
