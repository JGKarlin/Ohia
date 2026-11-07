import Foundation
import OhiaCore

/// Sendable, network-facing IMAP values resolved from a persisted account.
/// Credentials remain transient and are never included in estimates or logs.
public struct IMAPConnectionConfiguration: Sendable {
    public enum Error: Swift.Error, Sendable, Equatable {
        case missingServerConfiguration
    }

    public let host: String
    public let port: Int
    public let security: IMAPSecurity
    public let pinnedCertSHA256: String?
    public let auth: SentAppender.Auth

    public init(
        host: String,
        port: Int,
        security: IMAPSecurity,
        pinnedCertSHA256: String?,
        auth: SentAppender.Auth
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.pinnedCertSHA256 = pinnedCertSHA256
        self.auth = auth
    }

    /// Reads the SwiftData model only on MainActor, then returns a Sendable
    /// value whose OAuth refresh closure captures only Sendable keychain data.
    @MainActor
    public static func from(
        account: Account,
        oauthStore: OAuthTokenStore,
        passwordResolver: any MailPasswordResolving
    ) async throws -> Self {
        guard let host = account.imapHost?.trimmingCharacters(in: .whitespacesAndNewlines),
              host.isEmpty == false,
              let port = account.imapPort,
              let security = account.imapSecurity else {
            throw Error.missingServerConfiguration
        }

        let auth = try await IMAPAuthResolver.resolve(
            account: account,
            oauthStore: oauthStore,
            passwordResolver: passwordResolver
        )
        return Self(
            host: host,
            port: port,
            security: security,
            pinnedCertSHA256: account.pinnedCertSHA256,
            auth: auth
        )
    }

    func authenticate(_ client: any IMAPClienting) async throws {
        switch auth {
        case .password(let username, let password):
            try await client.authenticatePlain(username: username, password: password)
        case .xoauth2(let username, let initialToken, let refresh):
            do {
                try await client.authenticateXOAuth2(username: username, accessToken: initialToken)
            } catch IMAPError.reauthRequired {
                let freshToken = try await refresh()
                try await client.authenticateXOAuth2(username: username, accessToken: freshToken)
            }
        }
    }
}
