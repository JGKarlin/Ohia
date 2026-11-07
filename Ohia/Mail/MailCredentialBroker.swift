import Foundation
import SwiftData
import OhiaCore
import OhiaMail

/// Main-app owner for every mail credential read. Worker processes receive
/// only the request-scoped value returned over their private XPC connection.
final class MailCredentialBroker: MailCredentialRequesting, MailPasswordResolving, @unchecked Sendable {
    typealias RequestAuthorizer = @MainActor @Sendable (MailCredentialRequest) -> Bool

    static let shared = MailCredentialBroker()

    private let oauthStore: OAuthTokenStore
    private let requestAuthorizer: RequestAuthorizer

    init(
        oauthStore: OAuthTokenStore = OAuthTokenStore(brokerClient: nil),
        requestAuthorizer: @escaping RequestAuthorizer = { _ in true }
    ) {
        self.oauthStore = oauthStore
        self.requestAuthorizer = requestAuthorizer
    }

    @MainActor
    convenience init(
        modelContainer: ModelContainer,
        oauthStore: OAuthTokenStore = OAuthTokenStore(brokerClient: nil)
    ) {
        self.init(oauthStore: oauthStore) { request in
            Self.isAuthorized(request, in: ModelContext(modelContainer))
        }
    }

    func resolveMailCredential(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        Task {
            do {
                let request = try JSONDecoder().decode(
                    MailCredentialRequest.self,
                    from: requestData
                )
                let value = try await self.request(request)
                reply(try JSONEncoder().encode(value), nil)
            } catch {
                reply(nil, Self.sanitized(error).nsError)
            }
        }
    }

    func request(_ request: MailCredentialRequest) async throws -> MailCredentialValue {
        try validate(request)
        guard await requestAuthorizer(request) else {
            throw MailCredentialBrokerError.accessDenied
        }

        switch request.kind {
        case .oauthAccessToken:
            let provider = try oauthProvider(for: request)
            let token = try await oauthStore.refreshByKeychainRef(
                request.keychainReference,
                provider: provider,
                forceRefresh: request.forceRefresh
            )
            return .secret(token)

        case .oauthIMAPAccessToken:
            let provider = try providerID(for: request)
            let token = try await oauthStore.imapAccessTokenByKeychainRef(
                request.keychainReference,
                provider: provider,
                forceRefresh: request.forceRefresh
            )
            return .secret(token)

        case .oauthIMAPScopeStatus:
            let provider = try providerID(for: request)
            return .optionalScopeStatus(try await oauthStore.storedScopeStatusForIMAP(
                keychainRef: request.keychainReference,
                provider: provider
            ))

        case .imapPassword, .smtpPassword:
            return .secret(try readPassword(
                kind: request.kind,
                keychainReference: request.keychainReference
            ))
        }
    }

    private func validate(_ request: MailCredentialRequest) throws {
        guard !request.keychainReference.isEmpty else {
            throw MailCredentialBrokerError.invalidRequest
        }
        switch request.kind {
        case .oauthAccessToken, .oauthIMAPAccessToken:
            guard request.providerID != nil else {
                throw MailCredentialBrokerError.invalidRequest
            }
        case .oauthIMAPScopeStatus:
            guard request.providerID != nil, !request.forceRefresh else {
                throw MailCredentialBrokerError.invalidRequest
            }
        case .imapPassword, .smtpPassword:
            guard request.providerID == nil, !request.forceRefresh else {
                throw MailCredentialBrokerError.invalidRequest
            }
        }
    }

    @MainActor
    private static func isAuthorized(
        _ request: MailCredentialRequest,
        in context: ModelContext
    ) -> Bool {
        guard let accounts = try? context.fetch(FetchDescriptor<Account>()) else {
            return false
        }
        return accounts.contains { account in
            switch request.kind {
            case .imapPassword:
                return account.imapAuthMethod == .password
                    && account.imapKeychainRef == request.keychainReference
            case .smtpPassword:
                return account.smtpAuthMethod == .password
                    && account.smtpKeychainRef == request.keychainReference
            case .oauthAccessToken:
                guard account.smtpAuthMethod == .oauth2,
                      account.smtpKeychainRef == request.keychainReference,
                      let requestedProvider = request.providerID,
                      let provider = MailProviderRegistry.lookup(
                        email: account.emailAddress,
                        smtpHost: account.smtpHost,
                        imapHost: account.imapHost
                      ) else {
                    return false
                }
                return provider.authHint == .oauth2(requestedProvider)
            case .oauthIMAPAccessToken, .oauthIMAPScopeStatus:
                guard account.imapAuthMethod == .oauth2,
                      (account.imapKeychainRef ?? account.smtpKeychainRef)
                        == request.keychainReference,
                      let requestedProvider = request.providerID,
                      let provider = MailProviderRegistry.lookup(
                        email: account.emailAddress,
                        smtpHost: account.smtpHost,
                        imapHost: account.imapHost
                      ) else {
                    return false
                }
                return provider.imapAuthHint == .oauth2(requestedProvider)
            }
        }
    }

    func password(
        kind: MailCredentialKind,
        keychainReference: String
    ) async throws -> String {
        guard kind.isPassword else {
            throw MailCredentialBrokerError.invalidRequest
        }
        return try readPassword(kind: kind, keychainReference: keychainReference)
    }

    private func readPassword(
        kind: MailCredentialKind,
        keychainReference: String
    ) throws -> String {
        guard keychainReference.isEmpty == false else {
            throw MailCredentialBrokerError.invalidRequest
        }
        let service: String
        switch kind {
        case .imapPassword:
            service = IMAPCredentials.service
        case .smtpPassword:
            service = SMTPCredentials.service
        default:
            throw MailCredentialBrokerError.invalidRequest
        }
        guard let data = try KeychainHelpers.get(service: service, account: keychainReference),
              let password = String(data: data, encoding: .utf8) else {
            throw MailCredentialBrokerError.missingCredential
        }
        return password
    }

    private func providerID(
        for request: MailCredentialRequest
    ) throws -> MailProvider.OAuthProviderID {
        guard let providerID = request.providerID else {
            throw MailCredentialBrokerError.invalidRequest
        }
        return providerID
    }

    private func oauthProvider(for request: MailCredentialRequest) throws -> OAuthProvider {
        switch try providerID(for: request) {
        case .gmail:
            return .gmail
        case .microsoft:
            return .microsoft
        }
    }

    private static func sanitized(_ error: any Error) -> MailCredentialBrokerError {
        if let brokerError = error as? MailCredentialBrokerError {
            return brokerError
        }
        if KeychainHelpers.isUserDeniedAccess(error) {
            return .accessDenied
        }
        switch error {
        case OAuthTokenStoreError.missingKeychainRef,
             OAuthTokenStoreError.noStoredTokens:
            return .missingCredential
        case OAuthTokenStoreError.insufficientIMAPScope:
            return .insufficientIMAPScope
        case OAuthTokenStoreError.refreshRejected:
            return .refreshRejected
        case let httpError as OAuthTokenHTTPError where httpError.isAuthorizationFailure:
            return .refreshRejected
        default:
            return .unavailable
        }
    }
}
