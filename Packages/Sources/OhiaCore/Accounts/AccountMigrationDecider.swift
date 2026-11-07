import Foundation

public enum AccountMigrationDecider {
    /// Pure function. Given a snapshot of accounts + a provider-lookup
    /// surface, returns one `MigrationDecision` per input.
    ///
    /// Rules:
    /// - Already has IMAP host configured → .noOp
    /// - Email doesn't match a known provider → .noOp
    /// - Provider is Gmail or Microsoft AND account has OAuth SMTP token
    ///   → .silentReuse (Plan-1 widening guarantees the token covers IMAP)
    /// - Provider is in registry but we can't silently reuse credentials
    ///   (password, or OAuth but no smtpKeychainRef) → .needsAttention
    public static func decideMigrations(
        _ inputs: [AccountMigrationInput],
        lookup: any MigrationProviderLookup
    ) -> [MigrationDecision] {
        inputs.map { input in
            if input.hasImapHost {
                return .noOp(accountID: input.id)
            }
            guard let authKind = lookup.authKindForEmail(input.emailAddress) else {
                return .noOp(accountID: input.id)
            }
            switch authKind {
            case .oauth2Gmail, .oauth2Microsoft:
                if input.smtpAuthMethod == .oauth2, input.hasSmtpKeychainRef {
                    return .silentReuse(accountID: input.id)
                }
                return .needsAttention(accountID: input.id)
            case .password:
                return .needsAttention(accountID: input.id)
            }
        }
    }
}
