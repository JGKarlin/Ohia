import Foundation
import MCP
import OhiaCore

// MARK: - Tool descriptors

/// One primitive input field of an MCP tool, parsed from the tool's JSON
/// schema so the Composer picker can render a form and the automatic source
/// path can decide whether it knows how to fill the tool.
public struct MCPToolParameter: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case string
        case number
        case integer
        case boolean
    }

    public let name: String
    public let detail: String?
    public let kind: Kind
    public let isRequired: Bool

    public var id: String { name }

    public init(name: String, detail: String?, kind: Kind, isRequired: Bool) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.isRequired = isRequired
    }
}

/// A tool discovered on a connected MCP server, reduced to what Ohia needs:
/// identity, safety hints, and the primitive parameters it can fill.
public struct MCPToolDescriptor: Sendable, Equatable, Identifiable {
    public let name: String
    public let title: String?
    public let detail: String?
    /// `annotations.readOnlyHint == true` — the server vouches the tool
    /// doesn't mutate anything.
    public let isReadOnly: Bool
    /// `annotations.destructiveHint == true` — the server warns the tool
    /// performs destructive updates.
    public let isDestructive: Bool
    public let parameters: [MCPToolParameter]
    /// True when the schema requires a parameter Ohia can't render or fill
    /// (nested objects/arrays). The tool stays listed but can't be invoked
    /// from the generic form, and the automatic path skips it.
    public let hasUnsupportedRequiredParameters: Bool

    public var id: String { name }

    public var displayName: String { title ?? name }

    public init(
        name: String,
        title: String? = nil,
        detail: String? = nil,
        isReadOnly: Bool = false,
        isDestructive: Bool = false,
        parameters: [MCPToolParameter] = [],
        hasUnsupportedRequiredParameters: Bool = false
    ) {
        self.name = name
        self.title = title
        self.detail = detail
        self.isReadOnly = isReadOnly
        self.isDestructive = isDestructive
        self.parameters = parameters
        self.hasUnsupportedRequiredParameters = hasUnsupportedRequiredParameters
    }

    /// Parses the SDK tool into a descriptor. Only top-level primitive
    /// properties become form fields; anything else is flagged when required.
    init(tool: Tool) {
        self.name = tool.name
        self.title = tool.title
        self.detail = tool.description
        self.isReadOnly = tool.annotations.readOnlyHint == true
        self.isDestructive = tool.annotations.destructiveHint == true

        let schema = tool.inputSchema.objectValue
        let required = Set(
            schema?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        var parameters: [MCPToolParameter] = []
        var unsupportedRequired = false
        let properties = schema?["properties"]?.objectValue ?? [:]
        for (propertyName, propertySchema) in properties.sorted(by: { $0.key < $1.key }) {
            let object = propertySchema.objectValue
            let kind: MCPToolParameter.Kind?
            switch object?["type"]?.stringValue {
            case "string":  kind = .string
            case "number":  kind = .number
            case "integer": kind = .integer
            case "boolean": kind = .boolean
            default:        kind = nil
            }
            let isRequired = required.contains(propertyName)
            guard let kind else {
                if isRequired { unsupportedRequired = true }
                continue
            }
            parameters.append(MCPToolParameter(
                name: propertyName,
                detail: object?["description"]?.stringValue,
                kind: kind,
                isRequired: isRequired
            ))
        }
        // Required fields first, then alphabetical inside each group.
        self.parameters = parameters.sorted {
            if $0.isRequired != $1.isRequired { return $0.isRequired }
            return $0.name < $1.name
        }
        self.hasUnsupportedRequiredParameters = unsupportedRequired
    }
}

/// A form/automatic value for one tool parameter. Ohia's own type so app UI
/// never needs to import the MCP SDK module.
public indirect enum MCPToolArgument: Sendable, Equatable {
    case null
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)
    case array([MCPToolArgument])
    case object([String: MCPToolArgument])

    var sdkValue: Value {
        switch self {
        case .null:                   return .null
        case .string(let string):   return .string(string)
        case .number(let double):   return .double(double)
        case .integer(let int):     return .int(int)
        case .boolean(let bool):    return .bool(bool)
        case .array(let values):     return .array(values.map(\.sdkValue))
        case .object(let values):    return .object(values.mapValues(\.sdkValue))
        }
    }

    init(value: Value) {
        switch value {
        case .null:
            self = .null
        case .bool(let value):
            self = .boolean(value)
        case .int(let value):
            self = .integer(value)
        case .double(let value):
            self = .number(value)
        case .string(let value):
            self = .string(value)
        case .array(let values):
            self = .array(values.map(MCPToolArgument.init(value:)))
        case .object(let values):
            self = .object(values.mapValues(MCPToolArgument.init(value:)))
        case .data(let mimeType, let data):
            self = .string("[\(mimeType ?? "binary") data, \(data.count) bytes]")
        }
    }

    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .string(let value): return value
        case .number(let value): return value
        case .integer(let value): return value
        case .boolean(let value): return value
        case .array(let values): return values.map(\.foundationObject)
        case .object(let values): return values.mapValues(\.foundationObject)
        }
    }

    static func fromJSONObject(_ object: Any) -> MCPToolArgument? {
        switch object {
        case is NSNull:
            return .null
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .boolean(value.boolValue)
            }
            if CFNumberIsFloatType(value) {
                return .number(value.doubleValue)
            }
            if let integer = Int(exactly: value) {
                return .integer(integer)
            }
            return .number(value.doubleValue)
        case let value as String:
            return .string(value)
        case let values as [Any]:
            return .array(values.compactMap(fromJSONObject))
        case let values as [String: Any]:
            return .object(values.compactMapValues(fromJSONObject))
        default:
            return nil
        }
    }
}

public struct MCPToolCallResult: Sendable, Equatable {
    public let text: String
    public let structuredContent: MCPToolArgument?

    public init(text: String, structuredContent: MCPToolArgument? = nil) {
        self.text = text
        self.structuredContent = structuredContent
    }
}

// MARK: - Session protocol

/// The seam the Composer picker, Settings Test Connection, and the automatic
/// source provider all program against; production is `MCPClientSession`,
/// tests substitute fakes.
public protocol MCPToolCalling: Sendable {
    var serverID: UUID { get }
    var serverDisplayName: String { get }
    /// Connects lazily (idempotent) and returns the server's tools.
    func availableTools() async throws -> [MCPToolDescriptor]
    /// Calls one tool and returns its flattened text result.
    func callTool(name: String, arguments: [String: MCPToolArgument]) async throws -> String
    /// Structured counterpart used by automatic research. Implementations
    /// that only provide text inherit the safe default below.
    func callToolResult(
        name: String,
        arguments: [String: MCPToolArgument]
    ) async throws -> MCPToolCallResult
    func shutdown() async
}

public extension MCPToolCalling {
    func callToolResult(
        name: String,
        arguments: [String: MCPToolArgument]
    ) async throws -> MCPToolCallResult {
        MCPToolCallResult(text: try await callTool(name: name, arguments: arguments))
    }
}

public enum MCPSessionError: LocalizedError, Equatable {
    case handshakeFailed(String)
    case timedOut(Double)
    case notConnected
    case toolError(String)

    public var errorDescription: String? {
        switch self {
        case .handshakeFailed(let message):
            return "The server did not complete the MCP handshake: \(message)"
        case .timedOut(let seconds):
            return "The server did not respond within \(Int(seconds)) seconds."
        case .notConnected:
            return "The server is not connected."
        case .toolError(let message):
            return message.isEmpty ? "The tool reported an error." : message
        }
    }
}

// MARK: - MCPClientSession

/// One live connection to a remote HTTPS MCP server through the swift-sdk
/// `Client`. Lazy — no network request occurs until `availableTools()` or
/// `callTool` is first awaited — and the session stays alive once connected.
///
/// Concurrency shape: connecting is single-flight (concurrent first callers
/// await one shared connect task), every await has a deadline whose expiry
/// disconnects the URL session, and failures have a retry-after window so
/// per-message automatic queries cannot hammer an unavailable service.
public actor MCPClientSession: MCPToolCalling {

    private enum State {
        case idle
        case connecting(Task<[MCPToolDescriptor], Error>)
        case connected(client: Client, tools: [MCPToolDescriptor])
        case failed(message: String, at: ContinuousClock.Instant)
    }

    /// Test seam: substitutes an in-memory transport for remote HTTPS.
    typealias TransportFactory = @Sendable () async throws -> any Transport

    public nonisolated let serverID: UUID
    public nonisolated let serverDisplayName: String

    private let config: MCPConfiguredServer
    private let extraEnvironment: [String: String]
    private let transportFactory: TransportFactory?
    private let connectDeadline: Double
    private let callDeadline: Double

    private var state: State = .idle

    private static let defaultConnectDeadline: Double = 15
    private static let defaultCallDeadline: Double = 25
    /// How long a failure is remembered before a fresh attempt is allowed.
    static let failureRetryInterval: Duration = .seconds(120)
    private static let toolPageLimit = 8  // ≤ ~800 tools; no real server has more

    public init(config: MCPConfiguredServer, environment: [String: String]) {
        self.config = config
        self.extraEnvironment = environment
        self.transportFactory = nil
        self.serverID = config.id
        self.serverDisplayName = config.displayName
        self.connectDeadline = Self.defaultConnectDeadline
        self.callDeadline = Self.defaultCallDeadline
    }

    /// Tests inject an in-memory transport and, when exercising deadline
    /// machinery, short deadlines.
    init(
        config: MCPConfiguredServer,
        environment: [String: String],
        connectDeadline: Double = MCPClientSession.defaultConnectDeadline,
        callDeadline: Double = MCPClientSession.defaultCallDeadline,
        transportFactory: @escaping TransportFactory
    ) {
        self.config = config
        self.extraEnvironment = environment
        self.transportFactory = transportFactory
        self.serverID = config.id
        self.serverDisplayName = config.displayName
        self.connectDeadline = connectDeadline
        self.callDeadline = callDeadline
    }

    // MARK: MCPToolCalling

    public func availableTools() async throws -> [MCPToolDescriptor] {
        try await connectIfNeeded()
    }

    public func callTool(name: String, arguments: [String: MCPToolArgument]) async throws -> String {
        try await callToolResult(name: name, arguments: arguments).text
    }

    public func callToolResult(
        name: String,
        arguments: [String: MCPToolArgument]
    ) async throws -> MCPToolCallResult {
        _ = try await connectIfNeeded()
        guard case .connected(let client, _) = state else {
            throw MCPSessionError.notConnected
        }
        let sdkArguments = arguments.mapValues(\.sdkValue)
        let result: CallTool.Result = try await withDeadline(callDeadline) {
            let request: RequestContext<CallTool.Result> = try await client.callTool(
                name: name,
                arguments: sdkArguments
            )
            return try await request.value
        }
        let text = Self.flatten(result.content)
        if result.isError == true {
            throw MCPSessionError.toolError(text)
        }
        return MCPToolCallResult(
            text: text,
            structuredContent: result.structuredContent.map(MCPToolArgument.init(value:))
        )
    }

    public func shutdown() async {
        if case .connecting(let task) = state {
            task.cancel()
        }
        if case .connected(let client, _) = state {
            await client.disconnect()
        }
        state = .idle
    }

    /// The last failure message, for status display without re-connecting.
    public var failureMessage: String? {
        if case .failed(let message, _) = state { return message }
        return nil
    }

    // MARK: - Connection

    /// Single-flight connect: the first caller starts the handshake, every
    /// concurrent caller awaits the same task.
    private func connectIfNeeded() async throws -> [MCPToolDescriptor] {
        switch state {
        case .connected(_, let tools):
            return tools
        case .connecting(let task):
            return try await task.value
        case .failed(let message, let at):
            // Anti-thrash: within the window, repeat callers get the cached
            // failure instantly. Past it, fall through to a fresh attempt.
            guard ContinuousClock.now - at >= Self.failureRetryInterval else {
                throw MCPSessionError.handshakeFailed(message)
            }
        case .idle:
            break
        }

        let task = Task { try await performConnect() }
        state = .connecting(task)
        return try await task.value
    }

    /// Runs actor-isolated (the connect `Task` inherits the actor), so the
    /// state transition it makes is visible to every concurrent caller the
    /// moment the task completes — a racing `callTool` can never observe a
    /// finished connect still marked `.connecting`.
    private func performConnect() async throws -> [MCPToolDescriptor] {
        do {
            let transport: any Transport
            if let transportFactory {
                transport = try await transportFactory()
            } else {
                transport = try makeRemoteHTTPTransport()
            }

            let client = Client(name: "Ohia", version: "1.0")
            do {
                // The expiry hook disconnects the half-connected client: the
                    // SDK resumes every pending request with CancellationError on
                    // disconnect, so a hung handshake cannot strand the await.
                let tools = try await withDeadline(
                    connectDeadline,
                    onExpiry: { await client.disconnect() }
                ) {
                    try await client.connect(transport: transport)
                    var collected: [Tool] = []
                    var cursor: String? = nil
                    for _ in 0..<Self.toolPageLimit {
                        let page = try await client.listTools(cursor: cursor)
                        collected.append(contentsOf: page.tools)
                        guard let next = page.nextCursor else { break }
                        cursor = next
                    }
                    return collected.map(MCPToolDescriptor.init(tool:))
                }
                guard case .connecting = state else {
                    // Shut down while connecting — discard the connection and
                    // leave the state where shutdown() put it.
                    await client.disconnect()
                    throw CancellationError()
                }
                state = .connected(client: client, tools: tools)
                return tools
            } catch {
                await client.disconnect()
                throw error is CancellationError
                    ? error
                    : MCPSessionError.handshakeFailed(describeFailure(error))
            }
        } catch {
            if case .connecting = state {
                state = error is CancellationError
                    ? .idle
                    : .failed(message: describeFailure(error), at: .now)
            }
            throw error
        }
    }

    /// Converts Keychain credential slots into request headers. Catalog
    /// services expose only their fixed Authorization header; a custom server
    /// treats its stored key/value pairs as explicit HTTP request headers.
    public static func validatedRequestHeaders(
        config: MCPConfiguredServer,
        environment: [String: String]
    ) throws -> [String: String] {
        let headers: [String: String]
        switch config.service {
        case .slack:
            headers = authorizationHeader(
                token: environment["SLACK_OAUTH_TOKEN"]
            )
        case .notion:
            headers = authorizationHeader(
                token: environment["NOTION_OAUTH_TOKEN"]
            )
        case .github:
            headers = authorizationHeader(
                token: environment["GITHUB_PERSONAL_ACCESS_TOKEN"]
            )
        case .firecrawl:
            headers = authorizationHeader(
                token: environment["FIRECRAWL_OAUTH_TOKEN"]
                    ?? environment["FIRECRAWL_API_KEY"]
            )
        case .custom:
            headers = environment
        }

        let reserved = Set([
            "accept", "connection", "content-length", "content-type", "host",
            "mcp-protocol-version", "mcp-session-id", "proxy-authenticate",
            "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade",
        ])
        let tokenPunctuation = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        let validCharacters = CharacterSet.alphanumerics.union(tokenPunctuation)
        for (name, value) in headers {
            guard !name.isEmpty,
                  name.unicodeScalars.allSatisfy({ $0.isASCII && validCharacters.contains($0) }) else {
                throw MCPConfigurationError.invalidHeaderName(name)
            }
            guard !reserved.contains(name.lowercased()) else {
                throw MCPConfigurationError.reservedHeaderName(name)
            }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.rangeOfCharacter(from: .newlines) == nil else {
                throw MCPConfigurationError.invalidHeaderValue(name)
            }
        }
        return headers
    }

    private static func authorizationHeader(token: String?) -> [String: String] {
        guard let token else { return [:] }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let value = trimmed.lowercased().hasPrefix("bearer ")
            ? trimmed
            : "Bearer \(trimmed)"
        return ["Authorization": value]
    }

    private func makeRemoteHTTPTransport() throws -> any Transport {
        let endpoint = try config.validatedRemoteEndpoint()
        let headers = try Self.validatedRequestHeaders(
            config: config,
            environment: extraEnvironment
        )
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.urlCache = nil
        urlSessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        urlSessionConfiguration.httpShouldSetCookies = false

        return HTTPClientTransport(
            endpoint: endpoint,
            configuration: urlSessionConfiguration,
            streaming: true,
            requestModifier: { request in
                var request = request
                for (name, value) in headers {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                return request
            }
        )
    }

    private func describeFailure(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Deadlines

    /// Races `operation` against a deadline. Expiry cancels the operation and
    /// disconnects the transport. A settle flag decides the race exactly once.
    private func withDeadline<T: Sendable>(
        _ seconds: Double,
        onExpiry: (@Sendable () async -> Void)? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let settled = ClaimFlag()
        let work = Task { try await operation() }
        let enforcer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, settled.claim() else { return }
            work.cancel()
            await onExpiry?()
            await self?.deadlineExpired()
        }
        defer { enforcer.cancel() }
        do {
            let value = try await work.value
            guard settled.claim() else {
                // The enforcer fired in the same instant; the transport is
                // already disconnecting, so the result cannot be reused.
                throw MCPSessionError.timedOut(seconds)
            }
            return value
        } catch {
            guard settled.claim() else {
                throw MCPSessionError.timedOut(seconds)
            }
            throw error
        }
    }

    private func deadlineExpired() async {
        if case .connected(let client, _) = state {
            state = .failed(message: "The server stopped responding and was disconnected.", at: .now)
            await client.disconnect()
        }
    }

    // MARK: - Result flattening

    /// Reduces a tool result to prompt-safe text: text blocks verbatim,
    /// embedded resources by their text, links as name+URI lines, and binary
    /// content as a labeled omission.
    static func flatten(_ content: [Tool.Content]) -> String {
        var parts: [String] = []
        for item in content {
            switch item {
            case .text(let text, _, _):
                parts.append(text)
            case .resource(let resource, _, _):
                if let text = resource.text, !text.isEmpty {
                    parts.append(text)
                } else {
                    parts.append("[resource \(resource.uri)\(resource.mimeType.map { " (\($0))" } ?? "") omitted]")
                }
            case .resourceLink(let uri, let name, _, let description, _, _):
                let label = description?.isEmpty == false ? " — \(description!)" : ""
                parts.append("\(name): \(uri)\(label)")
            case .image(_, let mimeType, _, _), .audio(_, let mimeType, _, _):
                parts.append("[\(mimeType) content omitted]")
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Small shared pieces

/// First-caller-wins flag deciding a race exactly once.
final class ClaimFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
