// HostedMCPAuth.swift
// Browser OAuth for Ohia's hosted MCP connectors.
//
// Firecrawl and Notion dynamically register public clients. Slack requires a
// fixed, Ohia-owned client id and a registered fixed loopback redirect, but
// uses the same authorization-code + PKCE and rotating-token lifecycle.
//
// The main app owns browser interaction and all renewable state. Access
// tokens are staged with refresh tokens in an app-only Keychain item until
// the editor saves. Saving publishes only the access token into the server's
// injectable Keychain item; workers never receive refresh tokens, expiry, or
// OAuth client identifiers.

import CryptoKit
import Foundation
import Network
import OhiaCore
import Synchronization
#if canImport(AppKit)
import AppKit
#endif

protocol HostedMCPAppOnlySecretsStoring: Sendable {
    func secrets(for serverID: UUID) throws -> HostedMCPAuth.AppOnlySecrets?
    func setSecrets(_ secrets: HostedMCPAuth.AppOnlySecrets, for serverID: UUID) throws
    func deleteSecrets(for serverID: UUID) throws
}

struct KeychainHostedMCPAppOnlySecretsStore: HostedMCPAppOnlySecretsStoring {
    func secrets(for serverID: UUID) throws -> HostedMCPAuth.AppOnlySecrets? {
        guard let data = try KeychainHelpers.get(
            service: HostedMCPAuth.appOnlySecretsService,
            account: serverID.uuidString
        ) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HostedMCPAuth.AppOnlySecrets.self, from: data)
    }

    func setSecrets(
        _ secrets: HostedMCPAuth.AppOnlySecrets,
        for serverID: UUID
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try KeychainHelpers.set(
            data: try encoder.encode(secrets),
            service: HostedMCPAuth.appOnlySecretsService,
            account: serverID.uuidString
        )
    }

    func deleteSecrets(for serverID: UUID) throws {
        try KeychainHelpers.delete(
            service: HostedMCPAuth.appOnlySecretsService,
            account: serverID.uuidString
        )
    }
}

// MARK: - Errors

public enum HostedMCPAuthError: Error, LocalizedError, Equatable {
    case unsupportedService(String)
    case busy
    case missingClientID(String)
    case metadataUnavailable(String, String)
    case registrationFailed(String, String)
    case browserOpenFailed(String)
    case timedOut(String)
    case consentDenied(String)
    case stateMismatch(String)
    case missingCode(String)
    case tokenExchangeFailed(String, String)
    case notConnected(String)
    case refreshFailed(String, String)
    case reconnectRequired(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedService(let name):
            return "\(name) does not support Ohia's hosted OAuth connection."
        case .busy:
            return "Another connector sign-in is already in progress."
        case .missingClientID(let name):
            return "\(name) sign-in is not configured in this build."
        case .metadataUnavailable(let name, let detail):
            return "Could not reach \(name) to start sign-in: \(detail)"
        case .registrationFailed(let name, let detail):
            return "\(name) rejected the sign-in registration: \(detail)"
        case .browserOpenFailed(let name):
            return "Could not open the browser for \(name) sign-in."
        case .timedOut(let name):
            return "\(name) sign-in timed out. Click Connect to try again."
        case .consentDenied(let name):
            return "\(name) access was declined. Click Connect and choose Allow to finish."
        case .stateMismatch(let name):
            return "The \(name) sign-in response did not match this request. Click Connect to try again."
        case .missingCode(let name):
            return "\(name) returned no authorization code. Click Connect to try again."
        case .tokenExchangeFailed(let name, let detail):
            return "Completing \(name) sign-in failed: \(detail)"
        case .notConnected(let name):
            return "Not connected to \(name)."
        case .refreshFailed(let name, let detail):
            return "Renewing the \(name) connection failed: \(detail)"
        case .reconnectRequired(let name):
            return "The \(name) connection expired. Open the server editor and connect again."
        }
    }
}

// MARK: - HostedMCPAuth

@MainActor
public enum HostedMCPAuth {
    public enum ClientRegistration: Equatable, Sendable {
        case dynamic
        case configured(infoPlistKey: String)
    }

    public struct Profile: Equatable, Sendable {
        public let service: MCPConfiguredServer.Service
        public let endpoint: URL
        public let accessTokenEnvironmentKey: String
        public let protectedResourceMetadataURL: URL?
        public let authorizationServerMetadataURL: URL?
        public let clientRegistration: ClientRegistration
        public let scopes: [String]
        public let resource: String?
        public let callbackHost: String
        public let callbackPort: UInt16?
        public let requestsConsentPrompt: Bool

        public var displayName: String { service.displayName }
    }

    public enum ConnectionState: Equatable, Sendable {
        case unavailable
        case disconnected
        case connected
        case publicationPending
        case reconnectRequired
    }

    nonisolated static let callbackPath = "/oauth/callback"
    nonisolated static let connectTimeout: Duration = .seconds(300)
    nonisolated static let refreshLeeway: TimeInterval = 60
    nonisolated static let keepFreshLeeway: TimeInterval = 300
    nonisolated static let defaultTokenLifetime: TimeInterval = 3600

    /// OAuth metadata, registration, and token responses may contain client
    /// or credential material. Keep them out of the shared URL cache and
    /// persistent cookie store; durable state belongs only in Keychain.
    private nonisolated static let networkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// App-only renewable OAuth state, deliberately separate from the
    /// injectable per-server access-token item.
    public nonisolated static let appOnlySecretsService = "ohia-mcp-hosted-oauth"

    private nonisolated static let credentialPersistence = CredentialPersistence(
        appOnlyStore: KeychainHostedMCPAppOnlySecretsStore(),
        injectableStore: KeychainMCPServerSecretsStore()
    )
    private nonisolated static let forcedReconnectServerIDs = Mutex(Set<UUID>())

    private static var activeConnectTask: Task<Void, any Error>?
    private static var refreshTasks: [UUID: Task<String, any Error>] = [:]
    private static var keepFreshTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: Provider profiles

    public nonisolated static func profile(
        for service: MCPConfiguredServer.Service
    ) -> Profile? {
        switch service {
        case .firecrawl:
            return Profile(
                service: .firecrawl,
                endpoint: URL(string: "https://mcp.firecrawl.dev/v2/mcp")!,
                accessTokenEnvironmentKey: "FIRECRAWL_OAUTH_TOKEN",
                protectedResourceMetadataURL: nil,
                authorizationServerMetadataURL: URL(
                    string: "https://www.firecrawl.dev/.well-known/oauth-authorization-server"
                ),
                clientRegistration: .dynamic,
                scopes: ["firecrawl:global"],
                resource: "https://mcp.firecrawl.dev/v2/mcp",
                callbackHost: "127.0.0.1",
                callbackPort: nil,
                requestsConsentPrompt: false
            )
        case .notion:
            return Profile(
                service: .notion,
                endpoint: URL(string: "https://mcp.notion.com/mcp")!,
                accessTokenEnvironmentKey: "NOTION_OAUTH_TOKEN",
                protectedResourceMetadataURL: URL(
                    string: "https://mcp.notion.com/.well-known/oauth-protected-resource/mcp"
                ),
                authorizationServerMetadataURL: nil,
                clientRegistration: .dynamic,
                scopes: [],
                resource: nil,
                callbackHost: "127.0.0.1",
                callbackPort: nil,
                requestsConsentPrompt: true
            )
        case .slack:
            return Profile(
                service: .slack,
                endpoint: URL(string: "https://mcp.slack.com/mcp")!,
                accessTokenEnvironmentKey: "SLACK_OAUTH_TOKEN",
                protectedResourceMetadataURL: nil,
                authorizationServerMetadataURL: URL(
                    string: "https://mcp.slack.com/.well-known/oauth-authorization-server"
                ),
                clientRegistration: .configured(infoPlistKey: "OHIA_SLACK_MCP_CLIENT_ID"),
                scopes: [
                    "canvases:read",
                    "channels:history",
                    "channels:read",
                    "emoji:read",
                    "files:read",
                    "groups:history",
                    "groups:read",
                    "im:history",
                    "im:read",
                    "mpim:history",
                    "mpim:read",
                    "reactions:read",
                    "search:read.files",
                    "search:read.im",
                    "search:read.mpim",
                    "search:read.private",
                    "search:read.public",
                    "search:read.users",
                    "users:read",
                    "users:read.email",
                ],
                resource: nil,
                callbackHost: "localhost",
                callbackPort: 49_218,
                requestsConsentPrompt: false
            )
        case .github, .custom:
            return nil
        }
    }

    public nonisolated static func isServiceAvailable(
        _ service: MCPConfiguredServer.Service,
        configuredClientID: String?
    ) -> Bool {
        guard let profile = profile(for: service) else { return true }
        switch profile.clientRegistration {
        case .dynamic:
            return true
        case .configured:
            return configuredClientID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    public nonisolated static func isServiceAvailable(
        _ service: MCPConfiguredServer.Service
    ) -> Bool {
        guard let profile = profile(for: service) else { return true }
        switch profile.clientRegistration {
        case .dynamic:
            return true
        case .configured(let infoPlistKey):
            return isServiceAvailable(
                service,
                configuredClientID: configuredClientID(infoPlistKey: infoPlistKey)
            )
        }
    }

    // MARK: Public lifecycle

    public static func connect(
        serverID: UUID,
        service: MCPConfiguredServer.Service
    ) async throws {
        guard let profile = profile(for: service) else {
            throw HostedMCPAuthError.unsupportedService(service.displayName)
        }
        guard activeConnectTask == nil else { throw HostedMCPAuthError.busy }
        let task = Task { try await performConnect(serverID: serverID, profile: profile) }
        activeConnectTask = task
        defer { activeConnectTask = nil }
        try await task.value
    }

    public static func cancelConnect() {
        activeConnectTask?.cancel()
    }

    private static func performConnect(serverID: UUID, profile: Profile) async throws {
        let metadata = try await discoverMetadata(profile: profile)
        let state = randomToken()
        let callbackServer = try LoopbackCallbackServer(
            port: profile.callbackPort,
            expectedState: state,
            completionDisplayName: profile.displayName
        )
        defer { callbackServer.stop() }
        let port = try await callbackServer.start()
        let redirectURI = "http://\(profile.callbackHost):\(port)\(callbackPath)"

        let clientID: String
        switch profile.clientRegistration {
        case .dynamic:
            guard let endpoint = metadata.registrationEndpoint else {
                throw HostedMCPAuthError.registrationFailed(
                    profile.displayName,
                    "the server offers no dynamic registration endpoint"
                )
            }
            clientID = try await register(
                profile: profile,
                endpoint: endpoint,
                redirectURI: redirectURI
            )
        case .configured(let infoPlistKey):
            guard let configured = configuredClientID(infoPlistKey: infoPlistKey) else {
                throw HostedMCPAuthError.missingClientID(profile.displayName)
            }
            clientID = configured
        }

        let pkce = pkce()
        let url = authorizeURL(
            profile: profile,
            metadata: metadata,
            clientID: clientID,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: pkce.challenge
        )
        #if canImport(AppKit)
        guard NSWorkspace.shared.open(url) else {
            throw HostedMCPAuthError.browserOpenFailed(profile.displayName)
        }
        #else
        throw HostedMCPAuthError.browserOpenFailed(profile.displayName)
        #endif

        let target = try await withConnectTimeout(profile: profile) {
            try await callbackServer.awaitCallback()
        }
        let code = try parseCallback(
            target: target,
            expectedState: state,
            displayName: profile.displayName
        )
        let token = try await performTokenRequest(
            tokenExchangeRequest(
                profile: profile,
                tokenEndpoint: metadata.tokenEndpoint,
                clientID: clientID,
                code: code,
                redirectURI: redirectURI,
                codeVerifier: pkce.verifier
            ),
            profile: profile,
            refresh: false
        )
        try Task.checkCancellation()
        try persistAppOnly(
            token: token,
            clientID: clientID,
            serverID: serverID,
            service: profile.service
        )
        _ = forcedReconnectServerIDs.withLock { $0.remove(serverID) }
        armKeepFresh(serverID: serverID)
    }

    public static func injectableOAuthEnvironment(
        serverID: UUID,
        service: MCPConfiguredServer.Service
    ) throws -> [String: String] {
        guard let profile = profile(for: service) else {
            throw HostedMCPAuthError.unsupportedService(service.displayName)
        }
        guard !isForcedReconnect(serverID: serverID) else {
            throw HostedMCPAuthError.reconnectRequired(profile.displayName)
        }
        guard let state = loadAppOnlySecrets(serverID: serverID, service: service),
              state.status == .connected,
              !state.publicationPending,
              !state.accessToken.isEmpty else {
            throw HostedMCPAuthError.notConnected(profile.displayName)
        }
        return [profile.accessTokenEnvironmentKey: state.accessToken]
    }

    public static func disconnect(
        serverID: UUID,
        service: MCPConfiguredServer.Service
    ) throws {
        guard let profile = profile(for: service) else {
            throw HostedMCPAuthError.unsupportedService(service.displayName)
        }
        if let stored = loadAppOnlySecrets(serverID: serverID) {
            try requireMatchingService(stored, requestedService: service)
        }
        keepFreshTasks[serverID]?.cancel()
        keepFreshTasks[serverID] = nil
        refreshTasks[serverID]?.cancel()
        refreshTasks[serverID] = nil
        _ = forcedReconnectServerIDs.withLock { $0.insert(serverID) }
        try credentialPersistence.appOnlyStore.deleteSecrets(for: serverID)
        let store = KeychainMCPServerSecretsStore()
        var environment = (try? store.environment(for: serverID)) ?? [:]
        if environment.removeValue(forKey: profile.accessTokenEnvironmentKey) != nil
            || environment.isEmpty {
            try store.setEnvironment(environment, for: serverID)
            postInjectableEnvironmentDidChange(serverID: serverID)
        }
        _ = forcedReconnectServerIDs.withLock { $0.remove(serverID) }
    }

    public static func clearAppOnlyMaterial(serverID: UUID) {
        keepFreshTasks[serverID]?.cancel()
        keepFreshTasks[serverID] = nil
        refreshTasks[serverID]?.cancel()
        refreshTasks[serverID] = nil
        do {
            try credentialPersistence.appOnlyStore.deleteSecrets(for: serverID)
            _ = forcedReconnectServerIDs.withLock { $0.remove(serverID) }
        } catch {
            // Do not let a stale app-only token become reusable if Keychain
            // deletion fails while switching away from browser OAuth.
            _ = forcedReconnectServerIDs.withLock { $0.insert(serverID) }
        }
    }

    public static func suspendKeepFresh(serverID: UUID) {
        keepFreshTasks[serverID]?.cancel()
        keepFreshTasks[serverID] = nil
    }

    public nonisolated static func connectionState(
        serverID: UUID,
        service: MCPConfiguredServer.Service
    ) -> ConnectionState {
        guard isServiceAvailable(service) else { return .unavailable }
        if isForcedReconnect(serverID: serverID) { return .reconnectRequired }
        guard let state = loadAppOnlySecrets(serverID: serverID, service: service),
              !state.accessToken.isEmpty || state.status == .reconnectRequired else {
            return .disconnected
        }
        if state.status == .reconnectRequired { return .reconnectRequired }
        if state.publicationPending { return .publicationPending }
        if let expiresAt = state.expiresAt,
           expiresAt.timeIntervalSinceNow > refreshLeeway {
            return .connected
        }
        return state.refreshToken == nil ? .reconnectRequired : .connected
    }

    public nonisolated static func isConnected(
        serverID: UUID,
        service: MCPConfiguredServer.Service
    ) -> Bool {
        connectionState(serverID: serverID, service: service) == .connected
    }

    public static func resolvedMCPEnvironment(
        serverID: UUID,
        service: MCPConfiguredServer.Service
    ) async throws -> [String: String] {
        guard let profile = profile(for: service) else {
            throw HostedMCPAuthError.unsupportedService(service.displayName)
        }
        let token = try await freshAccessToken(
            serverID: serverID,
            requestedService: service,
            force: false
        )
        return [profile.accessTokenEnvironmentKey: token]
    }

    public static func ensureKeepFreshForConfiguredServers(
        recordsFileURL: URL = MCPServerStore.defaultFileURL()
    ) {
        for record in MCPServerStore.loadRecords(fileURL: recordsFileURL)
        where record.isEnabled && record.usesHostedOAuth {
            armKeepFresh(serverID: record.id, replaceExisting: false)
        }
    }

    // MARK: Refresh

    private static func freshAccessToken(
        serverID: UUID,
        requestedService: MCPConfiguredServer.Service,
        force: Bool
    ) async throws -> String {
        if isForcedReconnect(serverID: serverID) {
            throw HostedMCPAuthError.reconnectRequired(requestedService.displayName)
        }
        guard var stored = loadAppOnlySecrets(serverID: serverID) else {
            throw HostedMCPAuthError.notConnected(requestedService.displayName)
        }
        try requireMatchingService(stored, requestedService: requestedService)
        if let inFlight = refreshTasks[serverID] {
            return try await inFlight.value
        }
        guard let profile = profile(for: requestedService) else {
            throw HostedMCPAuthError.notConnected(requestedService.displayName)
        }
        if stored.publicationPending {
            do {
                stored = try await recoverPendingPublication(
                    serverID: serverID,
                    accessTokenKey: profile.accessTokenEnvironmentKey,
                    persistence: credentialPersistence,
                    sessions: .shared
                ) ?? stored
            } catch {
                throw HostedMCPAuthError.refreshFailed(
                    profile.displayName,
                    "publishing the refreshed credential failed: \(error.localizedDescription)"
                )
            }
        }
        guard stored.status != .reconnectRequired else {
            throw HostedMCPAuthError.reconnectRequired(profile.displayName)
        }
        guard !stored.accessToken.isEmpty else {
            throw HostedMCPAuthError.notConnected(requestedService.displayName)
        }
        let nearExpiry = (stored.expiresAt?.timeIntervalSinceNow ?? .infinity) < refreshLeeway
        guard force || nearExpiry else { return stored.accessToken }
        guard let refreshToken = stored.refreshToken else {
            if nearExpiry {
                throw await handleRefreshFailure(
                    .reconnectRequired(profile.displayName),
                    serverID: serverID,
                    service: profile.service,
                    accessTokenKey: profile.accessTokenEnvironmentKey,
                    persistence: credentialPersistence
                )
            }
            return stored.accessToken
        }

        let task = Task<String, any Error> { @MainActor in
            let metadata = try await discoverMetadata(profile: profile)
            let token: TokenResponse
            do {
                token = try await performTokenRequest(
                    refreshRequest(
                        profile: profile,
                        tokenEndpoint: metadata.tokenEndpoint,
                        clientID: stored.clientID,
                        refreshToken: refreshToken
                    ),
                    profile: profile,
                    refresh: true
                )
            } catch let error as HostedMCPAuthError {
                if refreshRequiresReconnect(error) {
                    throw await handleRefreshFailure(
                        error,
                        serverID: serverID,
                        service: profile.service,
                        accessTokenKey: profile.accessTokenEnvironmentKey,
                        persistence: credentialPersistence
                    )
                }
                throw error
            }
            try Task.checkCancellation()
            guard let current = loadAppOnlySecrets(serverID: serverID),
                  current == stored else {
                throw HostedMCPAuthError.notConnected(profile.displayName)
            }
            _ = try await completeRefresh(
                token: token,
                previous: stored,
                serverID: serverID,
                accessTokenKey: profile.accessTokenEnvironmentKey,
                persistence: credentialPersistence,
                sessions: .shared
            )
            return token.accessToken
        }
        refreshTasks[serverID] = task
        defer { refreshTasks[serverID] = nil }
        return try await task.value
    }

    private nonisolated static func refreshRequiresReconnect(
        _ error: HostedMCPAuthError
    ) -> Bool {
        let detail: String
        switch error {
        case .reconnectRequired:
            return true
        case .refreshFailed(_, let value), .tokenExchangeFailed(_, let value):
            detail = value
        default:
            return false
        }
        return detail.contains("invalid_grant")
            || detail.contains("invalid_refresh_token")
            || detail.hasPrefix("HTTP 400")
            || detail.hasPrefix("HTTP 401")
    }

    static func handleRefreshFailure(
        _ error: HostedMCPAuthError,
        serverID: UUID,
        service: MCPConfiguredServer.Service,
        accessTokenKey: String,
        persistence: CredentialPersistence = credentialPersistence,
        sessions: MCPSessionManager = .shared
    ) async -> HostedMCPAuthError {
        guard refreshRequiresReconnect(error) else { return error }
        keepFreshTasks[serverID]?.cancel()
        keepFreshTasks[serverID] = nil
        refreshTasks[serverID]?.cancel()
        refreshTasks[serverID] = nil
        _ = forcedReconnectServerIDs.withLock { $0.insert(serverID) }
        // The marker is written first. If clearing the injectable half fails,
        // the marker still blocks every current request and records an
        // idempotent cleanup for the next recovery attempt.
        var publicationFailure: (any Error)?
        do {
            try persistence.markReconnectRequired(
                serverID: serverID,
                service: service,
                accessTokenKey: accessTokenKey
            )
        } catch {
            publicationFailure = error
        }
        if publicationFailure != nil {
            let recovered = try? persistence.recoverPendingPublication(
                serverID: serverID,
                accessTokenKey: accessTokenKey
            )
            if recovered?.status == .reconnectRequired {
                if recovered?.publicationPending == true {
                    armKeepFresh(serverID: serverID)
                }
            } else {
                do {
                    try persistence.clearAfterMarkerWriteFailure(
                        serverID: serverID,
                        accessTokenKey: accessTokenKey
                    )
                } catch {
                    print("[Ohia] hosted MCP credential cleanup remains pending for \(service.displayName)")
                }
                print("[Ohia] hosted MCP reconnect marker write failed for \(service.displayName)")
            }
        }
        await sessions.invalidate(id: serverID)
        postInjectableEnvironmentDidChange(serverID: serverID)
        return .reconnectRequired(service.displayName)
    }

    private static func armKeepFresh(serverID: UUID, replaceExisting: Bool = true) {
        if !replaceExisting, keepFreshTasks[serverID] != nil { return }
        keepFreshTasks[serverID]?.cancel()
        keepFreshTasks[serverID] = Task { @MainActor in
            var isFirstIteration = true
            while !Task.isCancelled {
                guard let stored = loadAppOnlySecrets(serverID: serverID),
                      let profile = profile(for: stored.service) else { return }
                if stored.publicationPending {
                    do {
                        _ = try await recoverPendingPublication(
                            serverID: serverID,
                            accessTokenKey: profile.accessTokenEnvironmentKey,
                            persistence: credentialPersistence,
                            sessions: .shared
                        )
                        continue
                    } catch {
                        try? await Task.sleep(for: .seconds(120))
                        continue
                    }
                }
                guard stored.status == .connected,
                      stored.refreshToken != nil else { return }
                let untilRefresh = (stored.expiresAt?.timeIntervalSinceNow ?? defaultTokenLifetime)
                    - keepFreshLeeway
                let wait = (isFirstIteration && untilRefresh <= 0) ? 0 : max(untilRefresh, 30)
                isFirstIteration = false
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if Task.isCancelled { return }
                do {
                    _ = try await freshAccessToken(
                        serverID: serverID,
                        requestedService: profile.service,
                        force: true
                    )
                } catch let error as HostedMCPAuthError {
                    let state = connectionState(serverID: serverID, service: profile.service)
                    if error == .reconnectRequired(profile.displayName)
                        || state == .reconnectRequired
                        || state == .disconnected
                        || state == .unavailable {
                        return
                    }
                    try? await Task.sleep(for: .seconds(120))
                } catch {
                    try? await Task.sleep(for: .seconds(120))
                }
            }
        }
    }

    private static func postInjectableEnvironmentDidChange(serverID: UUID) {
        NotificationCenter.default.post(
            name: .ohiaMCPServerInjectableEnvironmentDidChange,
            object: serverID
        )
    }

    static func completeRefresh(
        token: TokenResponse,
        previous: AppOnlySecrets,
        serverID: UUID,
        accessTokenKey: String,
        persistence: CredentialPersistence = credentialPersistence,
        sessions: MCPSessionManager = .shared
    ) async throws -> AppOnlySecrets {
        let pending = try persistence.stageRefresh(
            token: token,
            previous: previous,
            serverID: serverID
        )
        return try await recoverPendingPublication(
            serverID: serverID,
            accessTokenKey: accessTokenKey,
            persistence: persistence,
            sessions: sessions
        ) ?? pending
    }

    @discardableResult
    static func recoverPendingPublication(
        serverID: UUID,
        accessTokenKey: String,
        persistence: CredentialPersistence = credentialPersistence,
        sessions: MCPSessionManager = .shared
    ) async throws -> AppOnlySecrets? {
        do {
            let recovered = try persistence.recoverPendingPublication(
                serverID: serverID,
                accessTokenKey: accessTokenKey
            )
            postInjectableEnvironmentDidChange(serverID: serverID)
            return recovered
        } catch {
            // A durable pending marker excludes this credential from new
            // snapshots. Retire any session that still holds the old token,
            // then make app observers recompute immediately.
            await sessions.invalidate(id: serverID)
            postInjectableEnvironmentDidChange(serverID: serverID)
            throw error
        }
    }

    private nonisolated static func isForcedReconnect(serverID: UUID) -> Bool {
        forcedReconnectServerIDs.withLock { $0.contains(serverID) }
    }

    // MARK: Persistence

    struct AppOnlySecrets: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable {
            case connected
            case reconnectRequired
        }

        var service: MCPConfiguredServer.Service
        var clientID: String
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var status: Status
        /// An outbox bit for the second Keychain item. A refresh or terminal
        /// revocation is not complete until this becomes false.
        var publicationPending: Bool
    }

    struct CredentialPersistence: Sendable {
        let appOnlyStore: any HostedMCPAppOnlySecretsStoring
        let injectableStore: any MCPServerSecretsStoring

        func connectionState(serverID: UUID) -> ConnectionState {
            guard let stored = try? appOnlyStore.secrets(for: serverID) else {
                return .disconnected
            }
            if stored.status == .reconnectRequired { return .reconnectRequired }
            if stored.publicationPending { return .publicationPending }
            return stored.accessToken.isEmpty ? .disconnected : .connected
        }

        func stageRefresh(
            token: TokenResponse,
            previous: AppOnlySecrets,
            serverID: UUID
        ) throws -> AppOnlySecrets {
            let pending = AppOnlySecrets(
                service: previous.service,
                clientID: previous.clientID,
                accessToken: token.accessToken,
                refreshToken: token.refreshToken ?? previous.refreshToken,
                expiresAt: Date().addingTimeInterval(token.expiresIn ?? defaultTokenLifetime),
                status: .connected,
                publicationPending: true
            )
            // The latest rotated refresh token is durable before touching the
            // worker/manual access-token item.
            try appOnlyStore.setSecrets(pending, for: serverID)
            return pending
        }

        @discardableResult
        func markReconnectRequired(
            serverID: UUID,
            service: MCPConfiguredServer.Service,
            accessTokenKey: String
        ) throws -> AppOnlySecrets {
            let marker = AppOnlySecrets(
                service: service,
                clientID: "",
                accessToken: "",
                refreshToken: nil,
                expiresAt: nil,
                status: .reconnectRequired,
                publicationPending: true
            )
            // Replaces every app-only OAuth value before removing the token
            // visible to live MCP requests.
            try appOnlyStore.setSecrets(marker, for: serverID)
            return try recoverPendingPublication(
                serverID: serverID,
                accessTokenKey: accessTokenKey
            ) ?? marker
        }

        @discardableResult
        func recoverPendingPublication(
            serverID: UUID,
            accessTokenKey: String
        ) throws -> AppOnlySecrets? {
            guard var stored = try appOnlyStore.secrets(for: serverID),
                  stored.publicationPending else {
                return try appOnlyStore.secrets(for: serverID)
            }
            var environment = try injectableStore.environment(for: serverID)
            switch stored.status {
            case .connected:
                guard environment[accessTokenKey] != nil else {
                    throw HostedMCPAuthError.refreshFailed(
                        stored.service.displayName,
                        "the saved connector credential is unavailable"
                    )
                }
                environment[accessTokenKey] = stored.accessToken
            case .reconnectRequired:
                environment[accessTokenKey] = nil
            }
            try injectableStore.setEnvironment(environment, for: serverID)
            stored.publicationPending = false
            // If this final acknowledgement write fails, the outbox remains
            // pending and the same idempotent publication is retried later.
            try appOnlyStore.setSecrets(stored, for: serverID)
            return stored
        }

        func clearAfterMarkerWriteFailure(
            serverID: UUID,
            accessTokenKey: String
        ) throws {
            var firstError: (any Error)?
            do {
                try appOnlyStore.deleteSecrets(for: serverID)
            } catch {
                firstError = error
            }
            do {
                var environment = try injectableStore.environment(for: serverID)
                environment[accessTokenKey] = nil
                try injectableStore.setEnvironment(environment, for: serverID)
            } catch {
                if firstError == nil { firstError = error }
            }
            if let firstError { throw firstError }
        }
    }

    nonisolated static func loadAppOnlySecrets(serverID: UUID) -> AppOnlySecrets? {
        try? credentialPersistence.appOnlyStore.secrets(for: serverID)
    }

    nonisolated static func loadAppOnlySecrets(
        serverID: UUID,
        service: MCPConfiguredServer.Service
    ) -> AppOnlySecrets? {
        guard let stored = loadAppOnlySecrets(serverID: serverID),
              stored.service == service else { return nil }
        return stored
    }

    nonisolated static func requireMatchingService(
        _ stored: AppOnlySecrets,
        requestedService: MCPConfiguredServer.Service
    ) throws {
        guard stored.service == requestedService else {
            throw HostedMCPAuthError.notConnected(requestedService.displayName)
        }
    }

    private static func persistAppOnly(
        token: TokenResponse,
        clientID: String,
        serverID: UUID,
        service: MCPConfiguredServer.Service,
        previousRefreshToken: String? = nil
    ) throws {
        let secrets = AppOnlySecrets(
            service: service,
            clientID: clientID,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? previousRefreshToken,
            expiresAt: Date().addingTimeInterval(token.expiresIn ?? defaultTokenLifetime),
            status: .connected,
            publicationPending: false
        )
        try credentialPersistence.appOnlyStore.setSecrets(secrets, for: serverID)
    }

    // MARK: Wire types

    struct ProtectedResourceMetadata: Decodable, Sendable {
        let authorizationServers: [URL]

        enum CodingKeys: String, CodingKey {
            case authorizationServers = "authorization_servers"
        }
    }

    struct AuthorizationServerMetadata: Decodable, Sendable {
        let issuer: String
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let registrationEndpoint: URL?

        enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case registrationEndpoint = "registration_endpoint"
        }
    }

    struct TokenResponse: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct TokenEnvelope: Decodable {
        let ok: Bool?
        let error: String?
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case ok, error
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct RegistrationResponse: Decodable, Sendable {
        let clientID: String

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
        }
    }

    private struct RegistrationRequestBody: Encodable {
        var clientName = "Ohia"
        var redirectUris: [String]
        var grantTypes = ["authorization_code", "refresh_token"]
        var responseTypes = ["code"]
        var tokenEndpointAuthMethod = "none"
        var scope: String?

        enum CodingKeys: String, CodingKey {
            case clientName = "client_name"
            case redirectUris = "redirect_uris"
            case grantTypes = "grant_types"
            case responseTypes = "response_types"
            case tokenEndpointAuthMethod = "token_endpoint_auth_method"
            case scope
        }
    }

    // MARK: Pure request builders

    nonisolated static func parseProtectedResourceMetadata(
        _ data: Data
    ) throws -> ProtectedResourceMetadata {
        do {
            let metadata = try JSONDecoder().decode(ProtectedResourceMetadata.self, from: data)
            guard !metadata.authorizationServers.isEmpty,
                  metadata.authorizationServers.allSatisfy(isSecureOAuthURL) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "invalid authorization servers")
                )
            }
            return metadata
        } catch {
            throw HostedMCPAuthError.metadataUnavailable(
                "the hosted service",
                "unexpected protected-resource metadata"
            )
        }
    }

    nonisolated static func parseAuthorizationServerMetadata(
        _ data: Data
    ) throws -> AuthorizationServerMetadata {
        do {
            let metadata = try JSONDecoder().decode(AuthorizationServerMetadata.self, from: data)
            guard let issuer = URL(string: metadata.issuer),
                  isSecureOAuthURL(issuer),
                  isSecureOAuthURL(metadata.authorizationEndpoint),
                  isSecureOAuthURL(metadata.tokenEndpoint),
                  metadata.registrationEndpoint.map(isSecureOAuthURL) ?? true else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "insecure authorization metadata")
                )
            }
            return metadata
        } catch {
            throw HostedMCPAuthError.metadataUnavailable(
                "the hosted service",
                "unexpected authorization-server metadata"
            )
        }
    }

    private nonisolated static func isSecureOAuthURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.host?.isEmpty == false
            && components.user == nil
            && components.password == nil
            && components.fragment == nil
    }

    nonisolated static func authorizationServerMetadataURL(for issuer: URL) -> URL {
        var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        components.path = "/.well-known/oauth-authorization-server"
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    nonisolated static func authorizeURL(
        profile: Profile,
        metadata: AuthorizationServerMetadata,
        clientID: String,
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(
            url: metadata.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )!
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if !profile.scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: profile.scopes.joined(separator: " ")))
        }
        if let resource = profile.resource {
            items.append(URLQueryItem(name: "resource", value: resource))
        }
        if profile.requestsConsentPrompt {
            items.append(URLQueryItem(name: "prompt", value: "consent"))
        }
        components.queryItems = items
        return components.url!
    }

    nonisolated static func registrationRequest(
        profile: Profile,
        endpoint: URL,
        redirectURI: String
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(
            RegistrationRequestBody(
                redirectUris: [redirectURI],
                scope: profile.scopes.isEmpty ? nil : profile.scopes.joined(separator: " ")
            )
        )
        return request
    }

    nonisolated static func tokenExchangeRequest(
        profile: Profile,
        tokenEndpoint: URL,
        clientID: String,
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) -> URLRequest {
        var fields: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", codeVerifier),
        ]
        if let resource = profile.resource { fields.append(("resource", resource)) }
        return formRequest(url: tokenEndpoint, fields: fields)
    }

    nonisolated static func refreshRequest(
        profile: Profile,
        tokenEndpoint: URL,
        clientID: String,
        refreshToken: String
    ) -> URLRequest {
        var fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ]
        if let resource = profile.resource { fields.append(("resource", resource)) }
        return formRequest(url: tokenEndpoint, fields: fields)
    }

    nonisolated static func parseTokenResponse(
        _ data: Data,
        profile: Profile
    ) throws -> TokenResponse {
        do {
            let envelope = try JSONDecoder().decode(TokenEnvelope.self, from: data)
            if envelope.ok == false {
                throw HostedMCPAuthError.tokenExchangeFailed(
                    profile.displayName,
                    envelope.error ?? "provider rejected the request"
                )
            }
            guard let accessToken = envelope.accessToken, !accessToken.isEmpty else {
                throw HostedMCPAuthError.tokenExchangeFailed(
                    profile.displayName,
                    envelope.error ?? "unexpected response shape"
                )
            }
            return TokenResponse(
                accessToken: accessToken,
                refreshToken: envelope.refreshToken,
                expiresIn: envelope.expiresIn
            )
        } catch let error as HostedMCPAuthError {
            throw error
        } catch {
            throw HostedMCPAuthError.tokenExchangeFailed(
                profile.displayName,
                "unexpected response shape"
            )
        }
    }

    nonisolated static func parseCallback(
        target: String,
        expectedState: String,
        displayName: String
    ) throws -> String {
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
              components.path == callbackPath else {
            throw HostedMCPAuthError.missingCode(displayName)
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let error = value("error") {
            throw error == "access_denied"
                ? HostedMCPAuthError.consentDenied(displayName)
                : HostedMCPAuthError.tokenExchangeFailed(displayName, error)
        }
        guard value("state") == expectedState else {
            throw HostedMCPAuthError.stateMismatch(displayName)
        }
        guard let code = value("code"), !code.isEmpty else {
            throw HostedMCPAuthError.missingCode(displayName)
        }
        return code
    }

    enum CallbackDisposition: Equatable, Sendable {
        case success
        case oauthError
        case rejected(statusCode: Int)
    }

    nonisolated static func callbackDisposition(
        target: String,
        expectedState: String
    ) -> CallbackDisposition {
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
              components.path == callbackPath else {
            return .rejected(statusCode: 404)
        }
        let values = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        guard values["state"] == expectedState else {
            return .rejected(statusCode: 400)
        }
        if values["error"]?.isEmpty == false {
            return .oauthError
        }
        guard values["code"]?.isEmpty == false else {
            return .rejected(statusCode: 400)
        }
        return .success
    }

    nonisolated static func pkce() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URLNoPad(Data(bytes))
        let challenge = base64URLNoPad(Data(SHA256.hash(data: Data(verifier.utf8))))
        return (verifier, challenge)
    }

    nonisolated private static func base64URLNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLNoPad(Data(bytes))
    }

    nonisolated private static func formRequest(
        url: URL,
        fields: [(String, String)]
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(
            fields.map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .utf8
        )
        return request
    }

    // MARK: HTTP and discovery

    private static func discoverMetadata(profile: Profile) async throws -> AuthorizationServerMetadata {
        let metadataURL: URL
        if let fixed = profile.authorizationServerMetadataURL {
            metadataURL = fixed
        } else if let protectedResourceURL = profile.protectedResourceMetadataURL {
            let data = try await fetch(
                url: protectedResourceURL,
                profile: profile,
                failure: { HostedMCPAuthError.metadataUnavailable(profile.displayName, $0) }
            )
            let protected = try parseProtectedResourceMetadata(data)
            guard let issuer = protected.authorizationServers.first else {
                throw HostedMCPAuthError.metadataUnavailable(
                    profile.displayName,
                    "no authorization server was advertised"
                )
            }
            metadataURL = authorizationServerMetadataURL(for: issuer)
        } else {
            throw HostedMCPAuthError.metadataUnavailable(
                profile.displayName,
                "no discovery endpoint is configured"
            )
        }

        let data = try await fetch(
            url: metadataURL,
            profile: profile,
            failure: { HostedMCPAuthError.metadataUnavailable(profile.displayName, $0) }
        )
        do {
            return try parseAuthorizationServerMetadata(data)
        } catch {
            throw HostedMCPAuthError.metadataUnavailable(
                profile.displayName,
                "unexpected metadata shape"
            )
        }
    }

    private static func register(
        profile: Profile,
        endpoint: URL,
        redirectURI: String
    ) async throws -> String {
        let data = try await performData(
            registrationRequest(profile: profile, endpoint: endpoint, redirectURI: redirectURI),
            failure: { HostedMCPAuthError.registrationFailed(profile.displayName, $0) }
        )
        do {
            return try JSONDecoder().decode(RegistrationResponse.self, from: data).clientID
        } catch {
            throw HostedMCPAuthError.registrationFailed(
                profile.displayName,
                "unexpected response shape"
            )
        }
    }

    private static func performTokenRequest(
        _ request: URLRequest,
        profile: Profile,
        refresh: Bool
    ) async throws -> TokenResponse {
        let data = try await performData(request) { detail in
            refresh
                ? HostedMCPAuthError.refreshFailed(profile.displayName, detail)
                : HostedMCPAuthError.tokenExchangeFailed(profile.displayName, detail)
        }
        do {
            return try parseTokenResponse(data, profile: profile)
        } catch let error as HostedMCPAuthError {
            if refresh,
               case .tokenExchangeFailed(_, let detail) = error {
                throw HostedMCPAuthError.refreshFailed(profile.displayName, detail)
            }
            throw error
        }
    }

    private static func fetch(
        url: URL,
        profile: Profile,
        failure: (String) -> HostedMCPAuthError
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await performData(request, failure: failure)
    }

    private static func performData(
        _ request: URLRequest,
        failure: (String) -> HostedMCPAuthError
    ) async throws -> Data {
        do {
            let (data, response) = try await networkSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw failure("no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(decoding: data.prefix(300), as: UTF8.self)
                throw failure("HTTP \(http.statusCode): \(detail)")
            }
            return data
        } catch let error as HostedMCPAuthError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw failure(error.localizedDescription)
        }
    }

    private nonisolated static func configuredClientID(infoPlistKey: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let url = Bundle.main.url(forResource: "Configuration", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any],
              let value = dictionary[infoPlistKey] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func withConnectTimeout<T: Sendable>(
        profile: Profile,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: connectTimeout)
                throw HostedMCPAuthError.timedOut(profile.displayName)
            }
            guard let first = try await group.next() else {
                throw HostedMCPAuthError.timedOut(profile.displayName)
            }
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Loopback callback server

/// One-shot RFC 8252 loopback receiver. Its mutable continuation state is
/// lock-protected because Network callbacks run on a dedicated queue.
final class LoopbackCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let expectedState: String
    private let completionDisplayName: String
    private let queue = DispatchQueue(label: "ohia.mcp.oauth.loopback")
    private let lock = NSLock()
    private var callbackContinuation: CheckedContinuation<String, any Error>?
    private var receivedTarget: String?
    private var finished = false

    init(
        port: UInt16? = nil,
        expectedState: String,
        completionDisplayName: String = "the service"
    ) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        )
        self.listener = try NWListener(using: parameters)
        self.expectedState = expectedState
        self.completionDisplayName = completionDisplayName
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeGate()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = self?.listener.port?.rawValue else {
                        if resumed.claim() {
                            continuation.resume(
                                throwing: HostedMCPAuthError.browserOpenFailed("the service")
                            )
                        }
                        return
                    }
                    if resumed.claim() { continuation.resume(returning: port) }
                case .failed(let error), .waiting(let error):
                    if resumed.claim() {
                        continuation.resume(throwing: error)
                    } else {
                        self?.failPending(with: error)
                    }
                case .cancelled:
                    if resumed.claim() {
                        continuation.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func awaitCallback() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let target = receivedTarget {
                    lock.unlock()
                    continuation.resume(returning: target)
                    return
                }
                if finished {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                callbackContinuation = continuation
                lock.unlock()
            }
        } onCancel: {
            failPending(with: CancellationError())
        }
    }

    func stop() {
        failPending(with: CancellationError())
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequestHead(connection, buffer: Data())
    }

    private func receiveRequestHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let lineEnd = buffer.range(of: Data("\r\n".utf8)) {
                let requestLine = String(decoding: buffer[..<lineEnd.lowerBound], as: UTF8.self)
                self.respond(connection, requestLine: requestLine)
            } else if error != nil || isComplete || buffer.count > 16_384 {
                connection.cancel()
            } else {
                self.receiveRequestHead(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, requestLine: String) {
        let parts = requestLine.split(separator: " ")
        let target = parts.count >= 2 && parts[0] == "GET" ? String(parts[1]) : ""
        let disposition = HostedMCPAuth.callbackDisposition(
            target: target,
            expectedState: expectedState
        )

        let heading: String
        let detail: String
        switch disposition {
        case .success:
            heading = "Connected to \(completionDisplayName)"
            detail = "You can close this tab and return to Ohia."
        case .oauthError:
            heading = "Sign-in was not completed"
            detail = "Return to Ohia to try again."
        case .rejected:
            heading = "Invalid sign-in response"
            detail = "Return to Ohia and continue the sign-in already in progress."
        }
        let isAccepted = disposition == .success || disposition == .oauthError
        let body = isAccepted
            ? "<html><head><meta charset=\"utf-8\"><title>Ohia</title></head><body style=\"font-family: -apple-system, sans-serif; text-align: center; padding-top: 4em;\"><h2>\(heading)</h2><p>\(detail)</p></body></html>"
            : "<html><body>\(heading)</body></html>"
        let status: String
        switch disposition {
        case .success, .oauthError: status = "200 OK"
        case .rejected(statusCode: 400): status = "400 Bad Request"
        case .rejected: status = "404 Not Found"
        }
        let bodyData = Data(body.utf8)
        var response = Data(
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n".utf8
        )
        response.append(bodyData)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in connection.cancel() }
        )
        if isAccepted { complete(with: target) }
    }

    private func complete(with target: String) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        receivedTarget = target
        let continuation = callbackContinuation
        callbackContinuation = nil
        lock.unlock()
        continuation?.resume(returning: target)
    }

    private func failPending(with error: any Error) {
        lock.lock()
        let continuation = callbackContinuation
        callbackContinuation = nil
        finished = true
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}
