import Foundation
import Observation
import OhiaCore

public enum MCPConfigurationError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case httpsRequired
    case credentialsInEndpoint
    case endpointQueryUnsupported
    case endpointFragmentUnsupported
    case invalidHeaderName(String)
    case reservedHeaderName(String)
    case invalidHeaderValue(String)
    case unsupportedService(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Enter a complete MCP server URL."
        case .httpsRequired:
            return "MCP servers must use HTTPS."
        case .credentialsInEndpoint:
            return "Put credentials in a request header, not in the server URL."
        case .endpointQueryUnsupported:
            return "Put connection parameters in request headers, not in the server URL query."
        case .endpointFragmentUnsupported:
            return "MCP server URLs cannot contain a fragment."
        case .invalidHeaderName(let name):
            return "“\(name)” is not a valid HTTP header name."
        case .reservedHeaderName(let name):
            return "“\(name)” is managed by Ohia’s MCP transport and cannot be overridden."
        case .invalidHeaderValue(let name):
            return "The value for “\(name)” is empty or contains a line break."
        case .unsupportedService(let name):
            return "\(name) does not offer a compatible hosted HTTPS MCP endpoint."
        }
    }
}

// MARK: - MCPConfiguredServer

/// One MCP server the user has configured in Settings → Sources.
///
/// Non-secret fields persist as JSON in the App Group; credential and custom
/// request-header values live in Keychain. The JSON file records names only.
public struct MCPConfiguredServer: Codable, Identifiable, Sendable, Equatable {

    /// Shipping catalog services pin a verified hosted endpoint and
    /// credential shape; `custom` is a user-entered HTTPS endpoint.
    /// There is no Google Calendar entry: no official MCP package exists for
    /// it, and Ohia's native EventKit source already supplies calendar
    /// evidence — a community server can always be added as `custom`.
    public enum Service: String, Codable, CaseIterable, Sendable, Identifiable {
        case slack
        case notion
        case github
        case firecrawl
        case custom

        public var id: String { rawValue }

        /// Services with a verified hosted Streamable HTTP MCP endpoint.
        /// Custom records use a user-entered credential-free HTTPS URL.
        public static var remoteCatalog: [Service] {
            [.slack, .notion, .github, .firecrawl].filter {
                HostedMCPAuth.isServiceAvailable($0)
            }
        }

        public var isWebResearchService: Bool {
            self == .firecrawl
        }

        public var displayName: String {
            switch self {
            case .slack:       return "Slack"
            case .notion:      return "Notion"
            case .github:      return "GitHub"
            case .firecrawl:   return "Firecrawl"
            case .custom:      return "Custom"
            }
        }

        public var remoteTemplate: String? {
            switch self {
            case .slack: return "https://mcp.slack.com/mcp"
            case .notion: return "https://mcp.notion.com/mcp"
            case .github: return "https://api.githubcopilot.com/mcp/"
            case .firecrawl: return "https://mcp.firecrawl.dev/v2/mcp"
            case .custom: return nil
            }
        }

        /// The sole credential value a hosted OAuth MCP request may receive.
        /// Refresh tokens and client registration state use a separate,
        /// app-only Keychain item and never enter this environment.
        public var hostedOAuthAccessTokenKey: String? {
            switch self {
            case .slack: return "SLACK_OAUTH_TOKEN"
            case .notion: return "NOTION_OAUTH_TOKEN"
            case .firecrawl: return "FIRECRAWL_OAUTH_TOKEN"
            case .github, .custom: return nil
            }
        }

        public var supportsHostedOAuth: Bool {
            hostedOAuthAccessTokenKey != nil
        }

        /// A manually entered credential supported by a preconfigured
        /// service. Hosted-OAuth-only services and `custom` return `nil`.
        public var credential: (envKey: String, label: String, isSecret: Bool)? {
            switch self {
            case .github:      return ("GITHUB_PERSONAL_ACCESS_TOKEN", "Personal access token", true)
            case .firecrawl:   return ("FIRECRAWL_API_KEY", "API key", true)
            case .slack, .notion, .custom: return nil
            }
        }

        /// One-line editor caption pointing at where the user gets the
        /// service's key. Web-search connectors are bring-your-own-key —
        /// usage bills to the user's own account, never to Ohia.
        public var credentialSignupHint: String? {
            switch self {
            case .firecrawl:   return "Get an API key at firecrawl.dev/app/api-keys"
            case .slack, .notion, .github, .custom:
                return nil
            }
        }

        /// Whether a fresh record starts with automatic draft queries on.
        /// Third-party research is always an explicit opt-in.
        public var defaultAutomaticQueries: Bool {
            false
        }

        /// The exact tool the automatic draft lane should call on this
        /// service's server when it is offered and passes the safety gates.
        /// Both web-search servers expose sibling tools; this names the exact
        /// general-purpose tool whose answer grounds an automatic draft.
        public var preferredAutomaticTool: String? {
            switch self {
            case .firecrawl:   return "firecrawl_search"
            case .slack, .notion, .github, .custom:
                return nil
            }
        }
    }

    /// How a Firecrawl server authenticates. Browser sign-in (OAuth) is the
    /// recommended path for new records; the API key path remains for
    /// existing records and users who prefer a dashboard key. Always `nil`
    /// on other services.
    public enum FirecrawlAuthMethod: String, Codable, Sendable {
        case apiKey
        case oauth

        /// The sole credential slot this mode exposes to the HTTPS transport.
        public var environmentKey: String {
            switch self {
            case .apiKey: return "FIRECRAWL_API_KEY"
            case .oauth:  return "FIRECRAWL_OAUTH_TOKEN"
            }
        }
    }

    public let id: UUID
    public var displayName: String
    public var service: Service
    /// Hosted Streamable HTTP endpoint. Fixed for catalog services; editable
    /// only for custom HTTPS servers.
    public var remoteEndpointURL: String?
    /// Environment-variable names only; values live in the secrets store.
    public var environmentKeys: [String]
    public var isEnabled: Bool
    /// Whether draft preparation may query this server automatically (its
    /// read-only/search-shaped tools) for new drafts. Manual adds from the
    /// Composer picker are governed by `isEnabled` alone.
    public var automaticQueries: Bool
    /// Which auth path a Firecrawl record uses. `nil` on every other
    /// service; never `nil` when `service == .firecrawl`. The initializer
    /// defaults an explicitly created Firecrawl record to `.apiKey`; decoded
    /// records must name a supported method.
    public var firecrawlAuthMethod: FirecrawlAuthMethod?
    public let addedAt: Date

    /// Whether this record's current authentication mode is browser OAuth.
    /// Firecrawl's API-key alternative is the only hosted connector mode
    /// that returns false.
    public var usesHostedOAuth: Bool {
        guard service.supportsHostedOAuth else { return false }
        return service != .firecrawl || firecrawlAuthMethod == .oauth
    }

    /// Keeps only credential values that this record's current mode may
    /// inject into a live request. Custom records treat every stored pair as
    /// a request header; catalog records have exactly one credential slot.
    public func injectableEnvironment(
        from environment: [String: String]
    ) -> [String: String] {
        guard service != .custom else { return environment }
        let key: String?
        if service == .firecrawl {
            key = firecrawlAuthMethod?.environmentKey
        } else {
            key = service.hostedOAuthAccessTokenKey ?? service.credential?.envKey
        }
        guard let key,
              let rawValue = environment[key] else { return [:] }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? [:] : [key: value]
    }

    public init(
        id: UUID = UUID(),
        displayName: String,
        service: Service,
        remoteEndpointURL: String? = nil,
        environmentKeys: [String] = [],
        isEnabled: Bool = true,
        automaticQueries: Bool = false,
        firecrawlAuthMethod: FirecrawlAuthMethod? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.service = service
        self.remoteEndpointURL = service.remoteTemplate ?? remoteEndpointURL
        self.environmentKeys = environmentKeys
        self.isEnabled = isEnabled
        self.automaticQueries = automaticQueries
        self.firecrawlAuthMethod = service == .firecrawl ? (firecrawlAuthMethod ?? .apiKey) : nil
        self.addedAt = addedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.service = try container.decode(Service.self, forKey: .service)
        if let catalogEndpoint = self.service.remoteTemplate {
            self.remoteEndpointURL = catalogEndpoint
        } else {
            self.remoteEndpointURL = try container.decodeIfPresent(
                String.self,
                forKey: .remoteEndpointURL
            )
        }
        self.environmentKeys = try container.decode([String].self, forKey: .environmentKeys)
        self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        // A missing opt-in flag must never enable automatic external queries.
        self.automaticQueries = try container.decodeIfPresent(Bool.self, forKey: .automaticQueries)
            ?? false
        // Never reinterpret an unknown Firecrawl method as a different
        // credential transport. Unsupported or missing methods fail closed.
        self.firecrawlAuthMethod = if self.service == .firecrawl {
            try container.decode(FirecrawlAuthMethod.self, forKey: .firecrawlAuthMethod)
        } else {
            nil
        }
        self.addedAt = try container.decode(Date.self, forKey: .addedAt)
    }

    /// A fresh record for a verified hosted service.
    /// New Firecrawl records default to browser sign-in; the editor's
    /// method picker keeps the API key path one click away.
    public static func preconfigured(_ service: Service) -> MCPConfiguredServer? {
        guard HostedMCPAuth.isServiceAvailable(service),
              let endpointURL = service.remoteTemplate else { return nil }
        let firecrawlAuthMethod: FirecrawlAuthMethod? = service == .firecrawl ? .oauth : nil
        let environmentKeys: [String]
        if let firecrawlAuthMethod {
            environmentKeys = [firecrawlAuthMethod.environmentKey]
        } else if let oauthKey = service.hostedOAuthAccessTokenKey {
            environmentKeys = [oauthKey]
        } else {
            environmentKeys = service.credential.map { [$0.envKey] } ?? []
        }
        return MCPConfiguredServer(
            displayName: service.displayName,
            service: service,
            remoteEndpointURL: endpointURL,
            environmentKeys: environmentKeys,
            isEnabled: false,
            automaticQueries: service.defaultAutomaticQueries,
            firecrawlAuthMethod: firecrawlAuthMethod
        )
    }

    public func validatedRemoteEndpoint() throws -> URL {
        guard let rawURL = service.remoteTemplate ?? remoteEndpointURL else {
            throw MCPConfigurationError.unsupportedService(service.displayName)
        }
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              let url = components.url else {
            if let scheme = URLComponents(string: trimmed)?.scheme,
               !scheme.isEmpty,
               scheme.lowercased() != "https" {
                throw MCPConfigurationError.httpsRequired
            }
            throw MCPConfigurationError.invalidEndpoint
        }
        guard components.user == nil, components.password == nil else {
            throw MCPConfigurationError.credentialsInEndpoint
        }
        guard components.query == nil else {
            throw MCPConfigurationError.endpointQueryUnsupported
        }
        guard components.fragment == nil else {
            throw MCPConfigurationError.endpointFragmentUnsupported
        }
        return url
    }

}

// MARK: - Secrets storage

public protocol MCPServerSecretsStoring: Sendable {
    /// The stored environment values for a server; empty when none exist.
    func environment(for id: UUID) throws -> [String: String]
    func setEnvironment(_ values: [String: String], for id: UUID) throws
    func deleteEnvironment(for id: UUID) throws
}

/// Keychain-backed secrets: one generic-password item per server holding the
/// JSON-encoded environment dictionary, following `KeychainHelpers`' existing
/// service/account addressing.
public struct KeychainMCPServerSecretsStore: MCPServerSecretsStoring {
    public static let service = "ohia-mcp-server-env"

    public init() {}

    public func environment(for id: UUID) throws -> [String: String] {
        guard let data = try KeychainHelpers.get(
            service: Self.service,
            account: id.uuidString
        ) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    public func setEnvironment(_ values: [String: String], for id: UUID) throws {
        if values.isEmpty {
            try KeychainHelpers.delete(service: Self.service, account: id.uuidString)
            return
        }
        let data = try JSONEncoder().encode(values)
        try KeychainHelpers.set(data: data, service: Self.service, account: id.uuidString)
    }

    public func deleteEnvironment(for id: UUID) throws {
        try KeychainHelpers.delete(service: Self.service, account: id.uuidString)
    }
}

// MARK: - MCPServerStore

/// Loads, mutates, and persists the configured-server list backing
/// Settings → Sources → MCP Servers.
///
/// The JSON file holds the non-secret records; the secrets store holds each
/// server's environment values. Mutations write the secrets first, then the
/// file, and every mutation rolls back on a file-write failure — the in-memory
/// list is restored and a just-written secret is deleted (insert) or restored
/// (update), so a failed save never leaves a phantom row or an orphaned
/// Keychain credential no UI can reach.
@MainActor
@Observable
public final class MCPServerStore {

    public private(set) var servers: [MCPConfiguredServer] = []

    private let fileURL: URL
    private let secrets: any MCPServerSecretsStoring

    /// Non-secret MCP records shared with workers through the App Group.
    public nonisolated static func defaultFileURL() -> URL {
        OhiaStorageRoot.required().mcpRecords
            .appendingPathComponent("mcp-servers.json")
    }

    public init(
        fileURL: URL = MCPServerStore.defaultFileURL(),
        secrets: any MCPServerSecretsStoring = KeychainMCPServerSecretsStore()
    ) {
        self.fileURL = fileURL
        self.secrets = secrets
        self.servers = Self.load(from: fileURL)
    }

    // MARK: Reads

    public func server(id: UUID) -> MCPConfiguredServer? {
        servers.first { $0.id == id }
    }

    /// The stored environment values for a server. Errors (locked Keychain,
    /// denied access) surface as empty so display code degrades to
    /// "no credential"; edits that then save will rewrite the item.
    public func environment(for id: UUID) -> [String: String] {
        (try? secrets.environment(for: id)) ?? [:]
    }

    // MARK: Mutations

    /// Inserts or replaces a server and stores its environment values.
    public func upsert(_ server: MCPConfiguredServer, environment: [String: String]) throws {
        var record = server
        _ = try record.validatedRemoteEndpoint()
        let injectableEnvironment = record.injectableEnvironment(from: environment)
        _ = try MCPClientSession.validatedRequestHeaders(
            config: record,
            environment: injectableEnvironment
        )
        record.environmentKeys = injectableEnvironment.keys.sorted()
        let previousServers = servers
        let isNew = !servers.contains { $0.id == record.id }
        // Read the current secret up front so an update can roll back to it.
        let previousEnvironment = isNew ? [:] : ((try? secrets.environment(for: record.id)) ?? [:])
        try secrets.setEnvironment(injectableEnvironment, for: record.id)
        if let index = servers.firstIndex(where: { $0.id == record.id }) {
            servers[index] = record
        } else {
            servers.append(record)
            servers.sort { $0.addedAt < $1.addedAt }
        }
        do {
            try persist()
        } catch {
            servers = previousServers
            if isNew {
                try? secrets.deleteEnvironment(for: record.id)
            } else {
                try? secrets.setEnvironment(previousEnvironment, for: record.id)
            }
            throw error
        }
        postInjectableEnvironmentDidChange()
    }

    public func setEnabled(_ enabled: Bool, id: UUID) throws {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        let previousServers = servers
        servers[index].isEnabled = enabled
        do {
            try persist()
        } catch {
            servers = previousServers
            throw error
        }
        postInjectableEnvironmentDidChange()
    }

    /// Removes the server and its Keychain item. The Keychain delete runs
    /// first so a failure leaves the record visible (and re-removable) rather
    /// than orphaning an invisible secret. A file-write failure restores the
    /// in-memory row to match the still-on-disk record; its credential is
    /// already gone, which the row surfaces as "not set".
    public func remove(id: UUID) throws {
        try secrets.deleteEnvironment(for: id)
        let previousServers = servers
        servers.removeAll { $0.id == id }
        do {
            try persist()
        } catch {
            servers = previousServers
            // The credential is already gone — the restored row must say so
            // rather than claim a Keychain item that no longer exists.
            if let index = servers.firstIndex(where: { $0.id == id }) {
                servers[index].environmentKeys = []
            }
            throw error
        }
        postInjectableEnvironmentDidChange()
    }

    private func postInjectableEnvironmentDidChange() {
        NotificationCenter.default.post(
            name: .ohiaMCPServerInjectableEnvironmentDidChange,
            object: nil
        )
    }

    // MARK: Persistence

    /// One-shot read of the configured servers, for callers outside the
    /// MainActor store — the Composer Add popover and the generative worker's
    /// automatic source provider. Same tolerant load as the store itself.
    public nonisolated static func loadRecords(
        fileURL: URL = MCPServerStore.defaultFileURL()
    ) -> [MCPConfiguredServer] {
        load(from: fileURL)
    }

    public nonisolated static func hasEnabledAutomaticResearchServer(
        fileURL: URL = MCPServerStore.defaultFileURL()
    ) -> Bool {
        load(from: fileURL).contains { $0.isEnabled && $0.automaticQueries }
    }

    private nonisolated static func load(from fileURL: URL) -> [MCPConfiguredServer] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard let rawRecords = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw DecodingError.typeMismatch(
                    [Any].self,
                    .init(codingPath: [], debugDescription: "expected an array of MCP records")
                )
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var records: [MCPConfiguredServer] = []
            records.reserveCapacity(rawRecords.count)
            for rawRecord in rawRecords {
                guard JSONSerialization.isValidJSONObject(rawRecord),
                      let recordData = try? JSONSerialization.data(withJSONObject: rawRecord),
                      let record = try? decoder.decode(MCPConfiguredServer.self, from: recordData)
                else {
                    // A removed service, unsupported auth mode, or malformed
                    // current record fails closed without hiding valid siblings.
                    continue
                }
                records.append(record)
            }
            return records
        } catch {
            // Only an unreadable top-level document is quarantined. Individual
            // invalid records are skipped above and remain available for a
            // future version to inspect or for the next successful save to
            // cut over to the current schema.
            let aside = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            print("[Ohia] ⚠ mcp-servers.json unreadable, moved aside: \(String(reflecting: type(of: error)))")
            return []
        }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(servers)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
