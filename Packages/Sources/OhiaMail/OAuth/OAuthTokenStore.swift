import Foundation
import OhiaCore

public struct Tokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}

public protocol HTTPClient: Sendable {
    func post(url: URL, formBody: [String: String]) async throws -> Data
}

public struct OAuthTokenHTTPError: Swift.Error, Sendable, Equatable, LocalizedError {
    public let statusCode: Int
    public let responseBody: String?

    public init(statusCode: Int, responseBody: String? = nil) {
        self.statusCode = statusCode
        self.responseBody = responseBody
    }

    public var isAuthorizationFailure: Bool {
        (400...403).contains(statusCode)
    }

    public var errorDescription: String? {
        "OAuth token endpoint rejected the request with HTTP \(statusCode). Reauthorize this account."
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func post(url: URL, formBody: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = Self.formEncodedBody(formBody)
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OAuthTokenHTTPError(
                statusCode: http.statusCode,
                responseBody: String(data: data, encoding: .utf8)
            )
        }
        return data
    }

    static func formEncodedBody(_ values: [String: String]) -> String {
        values
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(Self.formURLEncode(key))=\(Self.formURLEncode(value))"
            }
            .joined(separator: "&")
    }

    static func formURLEncode(_ value: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

public enum OAuthTokenStoreError: Swift.Error {
    case missingKeychainRef
    case noStoredTokens
    case insufficientIMAPScope
    case refreshRejected(String)
}

extension OAuthTokenStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingKeychainRef:
            return "OAuth keychain reference is missing."
        case .noStoredTokens:
            return "No OAuth token is stored."
        case .insufficientIMAPScope:
            return "Stored OAuth token is missing IMAP permission."
        case .refreshRejected(let message):
            return message
        }
    }
}

protocol OAuthTokenPersistence: Sendable {
    func read(service: String, account: String, allowUserInteraction: Bool) throws -> Data?
    func write(data: Data, service: String, account: String, allowUserInteraction: Bool) throws
    func delete(service: String, account: String, allowUserInteraction: Bool) throws
}

struct KeychainOAuthTokenPersistence: OAuthTokenPersistence {
    func read(service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        try KeychainHelpers.get(
            service: service,
            account: account,
            allowUserInteraction: allowUserInteraction
        )
    }

    func write(data: Data, service: String, account: String, allowUserInteraction: Bool) throws {
        try KeychainHelpers.set(
            data: data,
            service: service,
            account: account,
            allowUserInteraction: allowUserInteraction
        )
    }

    func delete(service: String, account: String, allowUserInteraction: Bool) throws {
        try KeychainHelpers.delete(
            service: service,
            account: account,
            allowUserInteraction: allowUserInteraction
        )
    }
}

final class OAuthTokenCacheInvalidation: @unchecked Sendable {
    static let shared = OAuthTokenCacheInvalidation()

    private let lock = NSLock()
    private var generationsByKeychainRef: [String: UInt64] = [:]

    func generation(for keychainRef: String) -> UInt64 {
        lock.withLock {
            generationsByKeychainRef[keychainRef, default: 0]
        }
    }

    @discardableResult
    func bumpGeneration(for keychainRef: String) -> UInt64 {
        lock.withLock {
            let next = generationsByKeychainRef[keychainRef, default: 0] &+ 1
            generationsByKeychainRef[keychainRef] = next
            return next
        }
    }
}

private struct CachedOAuthTokens {
    let tokens: Tokens
    let generation: UInt64
}

public actor OAuthTokenStore {
    public static let service = "com.ohia.oauth"

    private let http: HTTPClient
    private let brokerClient: OAuthTokenBrokerClient?
    private let allowKeychainInteraction: Bool
    private let persistence: OAuthTokenPersistence
    private let cacheInvalidation: OAuthTokenCacheInvalidation
    private let refreshWindow: TimeInterval = 60 // refresh if token expires within 60s
    private var cachedTokensByKeychainRef: [String: CachedOAuthTokens] = [:]

    public init(
        http: HTTPClient = URLSessionHTTPClient(),
        brokerClient: OAuthTokenBrokerClient? = nil,
        allowKeychainInteraction: Bool = KeychainHelpers.allowsUserInteractionByDefault
    ) {
        self.init(
            http: http,
            brokerClient: brokerClient,
            allowKeychainInteraction: allowKeychainInteraction,
            persistence: KeychainOAuthTokenPersistence()
        )
    }

    init(
        http: HTTPClient = URLSessionHTTPClient(),
        brokerClient: OAuthTokenBrokerClient? = nil,
        allowKeychainInteraction: Bool = KeychainHelpers.allowsUserInteractionByDefault,
        persistence: OAuthTokenPersistence,
        cacheInvalidation: OAuthTokenCacheInvalidation = .shared
    ) {
        self.http = http
        self.brokerClient = brokerClient
        self.allowKeychainInteraction = allowKeychainInteraction
        self.persistence = persistence
        self.cacheInvalidation = cacheInvalidation
    }

    // MARK: - Account-keyed convenience API
    //
    // `Account` is a SwiftData `@Model` and not `Sendable`, so it can't cross the
    // actor hop. These `nonisolated` wrappers pull the Keychain ref on the caller's
    // isolation domain and forward only the `String` ref to the actor-isolated
    // implementation.

    public nonisolated func store(tokens: Tokens, for account: Account) async throws {
        guard let ref = account.smtpKeychainRef else {
            throw OAuthTokenStoreError.missingKeychainRef
        }
        try await _store(tokens: tokens, keychainRef: ref)
    }

    public nonisolated func store(tokens: Tokens, keychainRef: String) async throws {
        try await _store(tokens: tokens, keychainRef: keychainRef)
    }

    public nonisolated func invalidate(for account: Account) async throws {
        guard let ref = account.smtpKeychainRef else { return }
        try await _invalidate(keychainRef: ref)
    }

    public nonisolated func invalidate(keychainRef: String) async throws {
        try await _invalidate(keychainRef: keychainRef)
    }

    public nonisolated func currentAccessToken(
        for account: Account,
        provider: OAuthProvider,
        forceRefresh: Bool = false
    ) async throws -> String {
        guard let ref = account.smtpKeychainRef else {
            throw OAuthTokenStoreError.missingKeychainRef
        }
        return try await _currentAccessToken(keychainRef: ref, provider: provider, forceRefresh: forceRefresh)
    }

    /// Keychain-ref-based overload for cross-isolation callers (e.g. XOAUTH2
    /// refresh closures that cannot capture a non-Sendable `Account`).
    public nonisolated func refreshByKeychainRef(
        _ ref: String,
        provider: OAuthProvider,
        forceRefresh: Bool = true
    ) async throws -> String {
        try await _currentAccessToken(keychainRef: ref, provider: provider, forceRefresh: forceRefresh)
    }

    public nonisolated func imapAccessTokenByKeychainRef(
        _ ref: String,
        provider: MailProvider.OAuthProviderID,
        forceRefresh: Bool = false
    ) async throws -> String {
        try await _imapAccessTokenByKeychainRef(
            ref,
            provider: provider,
            forceRefresh: forceRefresh
        )
    }

    // MARK: - Actor-isolated implementation

    private func _store(tokens: Tokens, keychainRef: String) throws {
        guard brokerClient == nil else {
            throw MailCredentialBrokerError.invalidRequest
        }
        let tokensToPersist = try tokensPreservingRefreshTokenIfNeeded(
            tokens,
            keychainRef: keychainRef
        )
        try persist(tokensToPersist, keychainRef: keychainRef)
    }

    private func _invalidate(keychainRef: String) throws {
        guard brokerClient == nil else {
            throw MailCredentialBrokerError.invalidRequest
        }
        try persistence.delete(
            service: Self.service,
            account: keychainRef,
            allowUserInteraction: allowKeychainInteraction
        )
        cacheInvalidation.bumpGeneration(for: keychainRef)
        cachedTokensByKeychainRef[keychainRef] = nil
    }

    private func _currentAccessToken(
        keychainRef: String,
        provider: OAuthProvider,
        forceRefresh: Bool
    ) async throws -> String {
        if let brokerClient {
            return try await brokerClient.requestAccessToken(
                keychainRef: keychainRef,
                provider: provider.id,
                forceRefresh: forceRefresh
            )
        }

        guard var tokens = try loadTokens(keychainRef: keychainRef) else {
            throw OAuthTokenStoreError.noStoredTokens
        }

        if !forceRefresh && tokens.expiresAt.timeIntervalSinceNow > refreshWindow {
            return tokens.accessToken
        }

        // Attempt refresh. On success, persist and return new token.
        // On failure, propagate the error and leave stored tokens untouched.
        let refreshed = try await refresh(tokens: tokens, provider: provider)
        tokens = refreshed
        try persist(tokens, keychainRef: keychainRef)
        return tokens.accessToken
    }

    private func _imapAccessTokenByKeychainRef(
        _ keychainRef: String,
        provider: MailProvider.OAuthProviderID,
        forceRefresh: Bool
    ) async throws -> String {
        if let brokerClient {
            return try await brokerClient.requestIMAPAccessToken(
                keychainRef: keychainRef,
                provider: provider,
                forceRefresh: forceRefresh
            )
        }

        guard var tokens = try loadTokens(keychainRef: keychainRef) else {
            throw OAuthTokenStoreError.noStoredTokens
        }
        guard Self.storedScopeIsSufficientForIMAP(tokens, provider: provider) else {
            throw OAuthTokenStoreError.insufficientIMAPScope
        }

        if !forceRefresh && tokens.expiresAt.timeIntervalSinceNow > refreshWindow {
            return tokens.accessToken
        }

        let refreshed = try await refresh(tokens: tokens, provider: provider.oauthProvider)
        guard Self.storedScopeIsSufficientForIMAP(refreshed, provider: provider) else {
            throw OAuthTokenStoreError.insufficientIMAPScope
        }
        tokens = refreshed
        try persist(tokens, keychainRef: keychainRef)
        return tokens.accessToken
    }

    private func loadTokens(keychainRef: String) throws -> Tokens? {
        let currentGeneration = cacheInvalidation.generation(for: keychainRef)
        if let cached = cachedTokensByKeychainRef[keychainRef],
           cached.generation == currentGeneration {
            return cached.tokens
        }
        cachedTokensByKeychainRef[keychainRef] = nil
        guard let data = try persistence.read(
            service: Self.service,
            account: keychainRef,
            allowUserInteraction: allowKeychainInteraction
        ) else {
            return nil
        }
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        cachedTokensByKeychainRef[keychainRef] = CachedOAuthTokens(
            tokens: tokens,
            generation: currentGeneration
        )
        return tokens
    }

    private func persist(_ tokens: Tokens, keychainRef: String) throws {
        try persistence.write(
            data: try JSONEncoder().encode(tokens),
            service: Self.service,
            account: keychainRef,
            allowUserInteraction: allowKeychainInteraction
        )
        let generation = cacheInvalidation.bumpGeneration(for: keychainRef)
        cachedTokensByKeychainRef[keychainRef] = CachedOAuthTokens(
            tokens: tokens,
            generation: generation
        )
    }

    private func tokensPreservingRefreshTokenIfNeeded(
        _ tokens: Tokens,
        keychainRef: String
    ) throws -> Tokens {
        guard tokens.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return tokens
        }
        guard let existing = try loadTokens(keychainRef: keychainRef),
              !existing.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return tokens
        }
        var merged = tokens
        merged.refreshToken = existing.refreshToken
        return merged
    }

    private func refresh(tokens: Tokens, provider: OAuthProvider) async throws -> Tokens {
        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
        ]
        if let clientID = provider.clientID { body["client_id"] = clientID }

        let data: Data
        do {
            data = try await http.post(url: provider.tokenURL, formBody: body)
        } catch let error as OAuthTokenHTTPError where error.isAuthorizationFailure {
            throw OAuthTokenStoreError.refreshRejected(
                error.errorDescription ?? "OAuth token request was rejected. Reauthorize this account."
            )
        }

        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
            let scope: String?
        }
        let parsed = try JSONDecoder().decode(RefreshResponse.self, from: data)

        return Tokens(
            accessToken: parsed.access_token,
            // Per OAuth2 spec, refresh_token may be absent from response; reuse existing.
            refreshToken: parsed.refresh_token ?? tokens.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(parsed.expires_in)),
            scope: parsed.scope ?? tokens.scope
        )
    }
}

extension OAuthTokenStore {
    /// Pure helper for IMAP's pre-flight check. Returns `true` if the stored
    /// token's server-returned scope covers IMAP access for the given provider.
    /// Nil scope (pre-migration tokens) is treated as insufficient.
    public nonisolated static func storedScopeIsSufficientForIMAP(
        _ stored: Tokens,
        provider: MailProvider.OAuthProviderID
    ) -> Bool {
        guard let scope = stored.scope else { return false }
        switch provider {
        case .gmail:
            return scope.contains("https://mail.google.com/")
        case .microsoft:
            return scope.contains("https://outlook.office.com/IMAP.AccessAsUser.All")
                || scope.contains("IMAP.AccessAsUser.All")
        }
    }

    /// Actor-isolated peek of the stored tokens for a given Keychain ref.
    public func readTokens(keychainRef: String) throws -> Tokens? {
        if brokerClient != nil {
            throw MailCredentialBrokerError.invalidRequest
        }
        return try loadTokens(keychainRef: keychainRef)
    }

    public func storedScopeStatusForIMAP(
        keychainRef: String,
        provider: MailProvider.OAuthProviderID
    ) async throws -> Bool? {
        if let brokerClient {
            return try await brokerClient.storedScopeStatusForIMAP(
                keychainRef: keychainRef,
                provider: provider
            )
        }
        guard let tokens = try readTokens(keychainRef: keychainRef) else {
            return nil
        }
        return Self.storedScopeIsSufficientForIMAP(tokens, provider: provider)
    }
}

private extension MailProvider.OAuthProviderID {
    var oauthProvider: OAuthProvider {
        switch self {
        case .gmail:
            return .gmail
        case .microsoft:
            return .microsoft
        }
    }
}
