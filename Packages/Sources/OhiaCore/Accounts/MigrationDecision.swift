import Foundation

/// One-time Plan-2 migration decision for an existing account that
/// predates Plan-2 (i.e. has no imapHost populated).
///
/// Computed by `AccountMigrationDecider.decideMigrations` as a pure
/// function of the account's current state + provider registry entry.
/// The main-actor applier then reads the decision and mutates the
/// `Account` + IMAP keychain accordingly.
public enum MigrationDecision: Sendable, Equatable {
    /// Provider is Gmail or Microsoft AND the account has an OAuth SMTP
    /// token whose scope already covers IMAP (Plan-1 scope widening
    /// guarantees this for tokens minted post-Plan-1; older tokens
    /// fall through to needsAttention via the scope pre-flight check).
    /// The applier populates imapHost/Port/Security/AuthMethod/Username
    /// from the registry and sets imapKeychainRef = smtpKeychainRef.
    /// No user interaction required.
    case silentReuse(accountID: UUID)

    /// Provider is in the registry but we can't silently reuse credentials
    /// (password provider, or OAuth provider whose stored scope doesn't
    /// cover IMAP). The applier populates host/Port/Security/AuthMethod/
    /// Username but leaves imapKeychainRef nil. Settings → Accounts shows
    /// a "Needs attention · Set up IMAP…" banner for this account.
    case needsAttention(accountID: UUID)

    /// Either the account already has imapHost populated (nothing to do)
    /// OR the provider isn't in MailProviderRegistry (we don't know how
    /// to configure IMAP automatically; user must use "Connect manually"
    /// in Settings → Add another account).
    case noOp(accountID: UUID)

    public var accountID: UUID {
        switch self {
        case .silentReuse(let id), .needsAttention(let id), .noOp(let id):
            return id
        }
    }
}

/// Minimal snapshot of an Account's migration-relevant state, passed to
/// `decideMigrations`. Keeps the pure function independent of SwiftData.
public struct AccountMigrationInput: Sendable, Equatable {
    public let id: UUID
    public let emailAddress: String
    public let hasImapHost: Bool
    public let smtpAuthMethod: SMTPAuthMethod?
    public let hasSmtpKeychainRef: Bool

    public init(
        id: UUID,
        emailAddress: String,
        hasImapHost: Bool,
        smtpAuthMethod: SMTPAuthMethod?,
        hasSmtpKeychainRef: Bool
    ) {
        self.id = id
        self.emailAddress = emailAddress
        self.hasImapHost = hasImapHost
        self.smtpAuthMethod = smtpAuthMethod
        self.hasSmtpKeychainRef = hasSmtpKeychainRef
    }
}

/// Minimal registry surface `decideMigrations` needs. Defined as a
/// protocol so tests can pass a fake without importing OhiaMail.
public protocol MigrationProviderLookup: Sendable {
    /// Returns `.oauth2Gmail` / `.oauth2Microsoft` when the provider uses
    /// OAuth, `.password` when the provider uses password/app-password,
    /// or nil when the email address doesn't match a known provider.
    func authKindForEmail(_ email: String) -> MigrationProviderAuthKind?
}

public enum MigrationProviderAuthKind: Sendable, Equatable {
    case oauth2Gmail
    case oauth2Microsoft
    case password
}
