import Foundation
import OhiaCore

/// Builds the transient `SentAppender.Auth` for an account's IMAP connection,
/// mirroring the production send path (`SMTPSendExecutor.resolveIMAPAppendAuth`).
///
/// It lives in OhiaMail so any transient IMAP reader — the Withheld drawer today,
/// others later — shares one auth-resolution path instead of re-deriving it.
/// `@MainActor` because it reads the non-Sendable SwiftData `Account`; it captures
/// only `Sendable` values (the keychain ref, provider, and token store) into the
/// refresh closure so nothing non-Sendable crosses the actor hop.
public enum IMAPAuthResolver {
    public enum ResolveError: Error, Sendable {
        case noIMAPAuthMethod
        case noOAuthProvider
        case missingKeychainRef
    }

    @MainActor
    public static func resolve(
        account: Account,
        oauthStore: OAuthTokenStore,
        passwordResolver: any MailPasswordResolving
    ) async throws -> SentAppender.Auth {
        guard let method = account.imapAuthMethod else { throw ResolveError.noIMAPAuthMethod }

        switch method {
        case .password:
            let keychainReference = try IMAPCredentials().keychainReference(for: account)
            let username = account.imapUsername ?? account.emailAddress
            let password = try await passwordResolver.password(
                kind: .imapPassword,
                keychainReference: keychainReference
            )
            return .password(
                username: username,
                password: password
            )

        case .oauth2:
            guard let providerID = oauthProvider(for: account) else {
                throw ResolveError.noOAuthProvider
            }
            let provider: OAuthProvider = providerID == .gmail ? .gmail : .microsoft
            guard let ref = account.imapKeychainRef else {
                throw ResolveError.missingKeychainRef
            }
            let tokenStore = oauthStore
            let initialToken = try await oauthStore.refreshByKeychainRef(
                ref, provider: provider, forceRefresh: false
            )
            return .xoauth2(
                username: account.imapUsername ?? account.emailAddress,
                initialToken: initialToken,
                refresh: { try await tokenStore.refreshByKeychainRef(ref, provider: provider) }
            )
        }
    }

    private static func oauthProvider(for account: Account) -> MailProvider.OAuthProviderID? {
        guard let provider = MailProviderRegistry.lookup(
            email: account.emailAddress,
            smtpHost: account.smtpHost,
            imapHost: account.imapHost
        ) else { return nil }
        if case .oauth2(let id) = provider.authHint { return id }
        return nil
    }
}
