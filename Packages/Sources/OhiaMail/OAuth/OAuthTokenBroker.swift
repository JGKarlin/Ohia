import Foundation

/// OAuth-specific convenience API over the live mail-credential request
/// boundary. The client has no environment constructor and no durable
/// transport: callers must inject an active in-memory requester.
public struct OAuthTokenBrokerClient: Sendable {
    private let requester: any MailCredentialRequesting

    public init(requester: any MailCredentialRequesting) {
        self.requester = requester
    }

    public func requestAccessToken(
        keychainRef: String,
        provider: MailProvider.OAuthProviderID,
        forceRefresh: Bool
    ) async throws -> String {
        try await requestSecret(MailCredentialRequest(
            kind: .oauthAccessToken,
            keychainReference: keychainRef,
            providerID: provider,
            forceRefresh: forceRefresh
        ))
    }

    public func requestIMAPAccessToken(
        keychainRef: String,
        provider: MailProvider.OAuthProviderID,
        forceRefresh: Bool
    ) async throws -> String {
        try await requestSecret(MailCredentialRequest(
            kind: .oauthIMAPAccessToken,
            keychainReference: keychainRef,
            providerID: provider,
            forceRefresh: forceRefresh
        ))
    }

    public func storedScopeStatusForIMAP(
        keychainRef: String,
        provider: MailProvider.OAuthProviderID
    ) async throws -> Bool? {
        let value = try await requester.request(MailCredentialRequest(
            kind: .oauthIMAPScopeStatus,
            keychainReference: keychainRef,
            providerID: provider
        ))
        guard case .optionalScopeStatus(let status) = value else {
            throw MailCredentialBrokerError.incompatibleResponse
        }
        return status
    }

    private func requestSecret(_ request: MailCredentialRequest) async throws -> String {
        let value = try await requester.request(request)
        guard case .secret(let token) = value else {
            throw MailCredentialBrokerError.incompatibleResponse
        }
        return token
    }
}
