import Foundation
import OhiaCore

/// Executes content-derived Composer research against configured MCP
/// connectors. Web providers receive every bounded research need through
/// typed, exact tool adapters; other MCP sources retain one safe contextual
/// lookup for the highest-priority need.
public struct MCPComposerResearchProvider: ComposerExternalResearching {

    private let records: @Sendable () -> [MCPConfiguredServer]
    private let environmentResolver: @Sendable (MCPConfiguredServer) -> [String: String]
    private let sessions: MCPSessionManager
    private let perServerDeadline: Double
    private let cache: MCPResearchResultCache

    private static let maxSources = 2
    private static let defaultPerServerDeadline: Double = 18
    private static let snippetLimit = 1_200

    /// App-process production wiring: records from the config file and
    /// credentials from Keychain. Worker runtimes use the resolver-injecting
    /// initializer below so helpers never read Keychain directly.
    public init(
        recordsFileURL: URL = MCPServerStore.defaultFileURL(),
        sessions: MCPSessionManager = .shared
    ) {
        self.records = { MCPServerStore.loadRecords(fileURL: recordsFileURL) }
        self.environmentResolver = { record in
            guard !KeychainHelpers.isWorkerProcess else { return [:] }
            return (try? KeychainMCPServerSecretsStore().environment(for: record.id)) ?? [:]
        }
        self.sessions = sessions
        self.perServerDeadline = Self.defaultPerServerDeadline
        self.cache = .shared
    }

    /// Worker-process production wiring. The resolver is backed by the
    /// runtime's XPC-injected, lock-protected credential snapshot.
    public init(
        recordsFileURL: URL = MCPServerStore.defaultFileURL(),
        environmentResolver: @escaping @Sendable (MCPConfiguredServer) -> [String: String],
        sessions: MCPSessionManager = .shared
    ) {
        self.records = { MCPServerStore.loadRecords(fileURL: recordsFileURL) }
        self.environmentResolver = environmentResolver
        self.sessions = sessions
        self.perServerDeadline = Self.defaultPerServerDeadline
        self.cache = .shared
    }

    /// Test wiring.
    init(
        records: @escaping @Sendable () -> [MCPConfiguredServer],
        environmentResolver: @escaping @Sendable (MCPConfiguredServer) -> [String: String],
        sessions: MCPSessionManager,
        perServerDeadline: Double = MCPComposerResearchProvider.defaultPerServerDeadline,
        cache: MCPResearchResultCache = MCPResearchResultCache()
    ) {
        self.records = records
        self.environmentResolver = environmentResolver
        self.sessions = sessions
        self.perServerDeadline = perServerDeadline
        self.cache = cache
    }

    public func sources(for needs: [ComposerWebResearchNeed]) async -> [ComposerSource] {
        let safeNeeds = needs.compactMap(Self.privacyFilteredNeed)
        guard !safeNeeds.isEmpty else { return [] }
        let eligible = records().filter { Self.isEligible($0) }
        guard !eligible.isEmpty else { return [] }

        let webRecords = eligible.filter { $0.service.isWebResearchService }
        let contextualRecords = eligible.filter { !$0.service.isWebResearchService }
        var assignments: [(MCPConfiguredServer, ComposerWebResearchNeed)] = []
        if let primaryWeb = webRecords.first {
            assignments.append(contentsOf: safeNeeds.map { (primaryWeb, $0) })
        }
        if let primaryNeed = safeNeeds.first {
            assignments.append(contentsOf: contextualRecords.prefix(2).map { ($0, primaryNeed) })
        }
        guard !assignments.isEmpty else { return [] }

        let resolver = environmentResolver
        let sessions = sessions
        let deadline = perServerDeadline
        let cache = cache
        let results = await withTaskGroup(of: (Int, [ComposerSource]).self) { group in
            for (index, assignment) in assignments.enumerated() {
                let (record, need) = assignment
                group.addTask {
                    (
                        index,
                        await Self.sources(
                            from: record,
                            need: need,
                            environment: resolver(record),
                            sessions: sessions,
                            deadline: deadline,
                            cache: cache
                        )
                    )
                }
            }
            var batches: [(Int, [ComposerSource])] = []
            for await batch in group {
                batches.append(batch)
            }
            return batches.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        return Array(Self.dedup(results).prefix(Self.maxSources))
    }

    static func isEligible(
        _ record: MCPConfiguredServer,
        hostedConnectionState: HostedMCPAuth.ConnectionState? = nil,
        isWorkerProcess: Bool = KeychainHelpers.isWorkerProcess
    ) -> Bool {
        guard record.isEnabled,
              record.automaticQueries,
              (try? record.validatedRemoteEndpoint()) != nil else { return false }
        guard record.usesHostedOAuth else { return true }
        // Workers cannot read the app-only OAuth Keychain record. Their
        // main-process credential snapshot has already omitted pending or
        // reconnect-required records, and the empty-environment guard below
        // rejects any record absent from that snapshot.
        if isWorkerProcess { return true }
        let state = hostedConnectionState ?? HostedMCPAuth.connectionState(
            serverID: record.id,
            service: record.service
        )
        return state == .connected
    }

    private static func privacyFilteredNeed(
        _ need: ComposerWebResearchNeed
    ) -> ComposerWebResearchNeed? {
        guard let query = ComposerWebResearchPrivacy.sanitizedQuery(need.query) else { return nil }
        return ComposerWebResearchNeed(
            question: need.question,
            query: query,
            reason: need.reason,
            freshness: need.freshness,
            requiresCorroboration: need.requiresCorroboration
        )
    }

    // MARK: - Per-server query

    private static func sources(
        from record: MCPConfiguredServer,
        need: ComposerWebResearchNeed,
        environment: [String: String],
        sessions: MCPSessionManager,
        deadline: Double,
        cache: MCPResearchResultCache
    ) async -> [ComposerSource] {
        // A server whose credential is recorded but unreadable here can only
        // fail its handshake — skip instead of opening a doomed connection.
        if !record.environmentKeys.isEmpty && environment.isEmpty {
            return []
        }

        let session = await sessions.session(for: record, environment: environment)
        let outcome = await withSoftDeadline(seconds: deadline) {
            () -> [ComposerSource] in
            guard let tools = try? await session.availableTools(),
                  let pick = automaticTool(from: tools, service: record.service) else { return [] }
            let arguments = automaticArguments(
                for: record.service,
                toolName: pick.tool.name,
                queryParameter: pick.queryParameter,
                need: need
            )
            let cacheKey = MCPResearchResultCache.Key(
                serverID: record.id,
                toolName: pick.tool.name,
                query: need.query,
                freshness: need.freshness?.rawValue,
                requiresCorroboration: need.requiresCorroboration
            )
            let callResult: MCPToolCallResult
            if let cached = await cache.value(for: cacheKey) {
                callResult = cached
            } else if let result = try? await session.callToolResult(
                name: pick.tool.name,
                arguments: arguments
            ) {
                callResult = result
                await cache.store(result, for: cacheKey)
            } else {
                return []
            }
            return sources(
                from: callResult,
                record: record,
                tool: pick.tool,
                need: need
            )
        }
        return outcome ?? []
    }

    // MARK: - Tool selection

    private static let searchStems: Set<String> = [
        "search", "query", "find", "lookup", "list", "read", "get", "fetch",
        "retrieve", "browse", "show", "view", "describe", "count",
    ]

    /// Verbs that mutate. A single one of these anywhere in the NAME tokens
    /// disqualifies a tool outright — including tools the server annotates
    /// read-only, because a mislabeled "trash_search_results" is not worth
    /// one source. Descriptions are deliberately ignored: "does not delete
    /// anything" must not disqualify a legitimate reader.
    private static let mutationStems: Set<String> = [
        "create", "update", "delete", "remove", "post", "send", "write",
        "add", "insert", "upload", "modify", "patch", "archive", "trash",
        "move", "execute", "run", "set", "destroy", "purge", "clear",
        "erase", "drop", "rename", "put", "edit", "append", "publish",
        "submit", "cancel", "close", "merge", "apply", "revoke", "assign",
        "star", "react", "reply", "comment", "invite", "kick", "ban",
        "replace", "overwrite", "truncate", "reset", "restore", "import",
        "deploy", "grant", "deny", "lock", "unlock",
    ]

    private static let queryParameterNames = [
        "query", "q", "search", "keywords", "text", "term", "prompt", "question", "input"
    ]

    /// Lowercased word tokens of a tool identifier, split on both
    /// non-alphanumerics (snake/kebab case) and camelCase boundaries — so
    /// "trashSearchResults" and "trash_search_results" both yield
    /// ["trash", "search", "results"]. Internal for tests.
    static func identifierTokens(_ identifier: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var previousWasLower = false
        for character in identifier {
            if character.isLetter || character.isNumber {
                if character.isUppercase && previousWasLower {
                    if !current.isEmpty { tokens.append(current.lowercased()) }
                    current = String(character)
                } else {
                    current.append(character)
                }
                previousWasLower = character.isLowercase
            } else {
                if !current.isEmpty { tokens.append(current.lowercased()) }
                current = ""
                previousWasLower = false
            }
        }
        if !current.isEmpty { tokens.append(current.lowercased()) }
        return tokens
    }

    /// Built-in web services use exact allowlists. Generic MCP sources must
    /// explicitly declare a read-only tool and pass the shape checks below.
    static func automaticTool(
        from tools: [MCPToolDescriptor],
        service: MCPConfiguredServer.Service
    ) -> (tool: MCPToolDescriptor, queryParameter: String)? {
        let exactNames: [String]
        switch service {
        case .firecrawl:
            exactNames = ["firecrawl_search"]
        default:
            exactNames = []
        }
        for name in exactNames {
            guard let tool = tools.first(where: { $0.name == name }),
                  safeAutomaticTool(tool),
                  let parameter = queryParameter(for: tool) else { continue }
            return (tool, parameter)
        }
        guard exactNames.isEmpty else { return nil }

        let candidates: [(tool: MCPToolDescriptor, parameter: String, rank: Int)] = tools.compactMap { tool in
            guard safeAutomaticTool(tool) else { return nil }
            guard tool.isReadOnly else { return nil }
            guard let parameter = queryParameter(for: tool) else { return nil }

            let nameTokens = Set(identifierTokens(tool.name))
            guard nameTokens.isDisjoint(with: mutationStems) else { return nil }
            guard nameTokens.isDisjoint(with: searchStems) == false else { return nil }

            var rank = 0
            if nameTokens.contains("search") { rank += 0 }
            else if nameTokens.contains("query") { rank += 1 }
            else if nameTokens.contains("find") { rank += 2 }
            else { rank += 3 }
            return (tool, parameter, rank)
        }
        guard let best = candidates.min(by: {
            ($0.rank, $0.tool.name) < ($1.rank, $1.tool.name)
        }) else { return nil }
        return (best.tool, best.parameter)
    }

    private static func safeAutomaticTool(_ tool: MCPToolDescriptor) -> Bool {
        guard !tool.isDestructive, !tool.hasUnsupportedRequiredParameters else { return false }
        let tokens = Set(identifierTokens(tool.name))
        return tokens.isDisjoint(with: mutationStems)
    }

    /// The string parameter the search text goes into: the sole required
    /// string parameter, or (when nothing is required) an optional string
    /// parameter with a query-like name.
    private static func queryParameter(for tool: MCPToolDescriptor) -> String? {
        let required = tool.parameters.filter(\.isRequired)
        if required.count == 1, required[0].kind == .string {
            return required[0].name
        }
        guard required.isEmpty else { return nil }
        let optionalStrings = tool.parameters.filter { $0.kind == .string }
        return queryParameterNames.first { name in
            optionalStrings.contains { $0.name.lowercased() == name }
        }
    }

    static func automaticArguments(
        for service: MCPConfiguredServer.Service,
        toolName: String,
        queryParameter: String,
        need: ComposerWebResearchNeed
    ) -> [String: MCPToolArgument] {
        var arguments: [String: MCPToolArgument] = [queryParameter: .string(need.query)]
        switch (service, toolName) {
        case (.firecrawl, "firecrawl_search"):
            // Automatic path is snippet-first: never attach scrapeOptions.
            // Deep page text comes from local WebRAG on kept URLs.
            arguments["limit"] = .integer(3)
        default:
            break
        }
        return arguments
    }

    // MARK: - Structured result normalization

    private struct Evidence {
        let title: String?
        let url: String?
        let text: String
        let publishedAt: Date?
        let contentExtracted: Bool
    }

    static func sources(
        from result: MCPToolCallResult,
        record: MCPConfiguredServer,
        tool: MCPToolDescriptor,
        need: ComposerWebResearchNeed,
        now: Date = Date()
    ) -> [ComposerSource] {
        let root = result.structuredContent ?? jsonArgument(from: result.text)
        var evidence: [Evidence] = []
        if let root { collectEvidence(from: root, into: &evidence) }
        evidence = dedupEvidence(evidence)
        let limit = need.requiresCorroboration ? 2 : 1
        let selected = Array(rankEvidence(evidence, for: need).prefix(limit))

        if !selected.isEmpty {
            return selected.map { item in
                let url = item.url.flatMap(normalizedHTTPURL)
                let trimmedTitle = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let shortQuestion = String(need.question.prefix(72))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let label = (trimmedTitle?.isEmpty == false ? trimmedTitle : nil)
                    ?? (shortQuestion.isEmpty ? nil : "Web · \(shortQuestion)")
                    ?? url.flatMap { URL(string: $0)?.host }
                    ?? "\(record.displayName) research"
                let provenance = ComposerSourceProvenance(
                    provider: record.displayName,
                    toolName: tool.name,
                    researchQuestion: need.question,
                    query: need.query,
                    sourceURL: url,
                    retrievedAt: now,
                    publishedAt: item.publishedAt,
                    webContentExtracted: item.contentExtracted
                )
                return ComposerSource(
                    kind: url == nil ? .mcp : .website,
                    label: String(label.prefix(180)),
                    snippet: String(item.text.prefix(snippetLimit)),
                    filePath: url,
                    isUserAdded: false,
                    provenance: provenance
                )
            }
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [ComposerSource(
            kind: .mcp,
            label: "\(record.displayName) · \(tool.displayName)",
            snippet: String(text.prefix(snippetLimit)),
            isUserAdded: false,
            provenance: ComposerSourceProvenance(
                provider: record.displayName,
                toolName: tool.name,
                researchQuestion: need.question,
                query: need.query,
                retrievedAt: now,
                webContentExtracted: false
            )
        )]
    }

    private static func jsonArgument(from text: String) -> MCPToolArgument? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return MCPToolArgument.fromJSONObject(object)
    }

    private static func collectEvidence(from value: MCPToolArgument, into result: inout [Evidence]) {
        switch value {
        case .array(let values):
            values.forEach { collectEvidence(from: $0, into: &result) }
        case .object(let object):
            let url = string(in: object, keys: ["url", "link", "source_url", "sourceURL", "canonical_url"])
            let title = string(in: object, keys: ["title", "name", "page_title"])
            let extracted = string(in: object, keys: ["markdown", "content", "page_content", "pageContent"])
            let snippet = string(in: object, keys: ["snippet", "description", "text"])
            let extra = strings(in: object, keys: ["extra_snippets", "snippets"])
            let content = ([extracted, snippet].compactMap { $0 } + extra)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            if url != nil || (title != nil && !content.isEmpty) {
                result.append(Evidence(
                    title: title,
                    url: url,
                    text: content.isEmpty ? title ?? "Web result" : content,
                    publishedAt: parseDate(string(in: object, keys: ["published", "published_at", "publishedAt", "date"])),
                    contentExtracted: extracted != nil
                ))
            }
            object.values.forEach { collectEvidence(from: $0, into: &result) }
        default:
            break
        }
    }

    private static func string(in object: [String: MCPToolArgument], keys: [String]) -> String? {
        for key in keys {
            if case .string(let value)? = object[key], !value.isEmpty { return value }
        }
        return nil
    }

    private static func strings(in object: [String: MCPToolArgument], keys: [String]) -> [String] {
        for key in keys {
            guard case .array(let values)? = object[key] else { continue }
            return values.compactMap { value in
                guard case .string(let text) = value else { return nil }
                return text
            }
        }
        return []
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func normalizedHTTPURL(_ raw: String) -> String? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url.absoluteString
    }

    private static func dedupEvidence(_ evidence: [Evidence]) -> [Evidence] {
        var seen = Set<String>()
        return evidence.filter { item in
            let key = item.url?.lowercased() ?? "\(item.title ?? "")\u{1f}\(item.text.prefix(200))"
            return seen.insert(key).inserted
        }
    }

    /// Prefer hits whose title/snippet overlap the research question/query
    /// tokens. Equal scores preserve the provider's original order.
    private static func rankEvidence(
        _ evidence: [Evidence],
        for need: ComposerWebResearchNeed
    ) -> [Evidence] {
        let needles = needOverlapTokens(from: "\(need.question) \(need.query)")
        guard needles.isEmpty == false else { return evidence }
        return evidence.enumerated()
            .sorted { lhs, rhs in
                let left = evidenceScore(lhs.element, needles: needles)
                let right = evidenceScore(rhs.element, needles: needles)
                if left != right { return left > right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func evidenceScore(_ item: Evidence, needles: [String]) -> Int {
        let haystack = "\(item.title ?? "")\n\(item.text)".lowercased()
        var score = needles.reduce(0) { partial, token in
            partial + (haystack.contains(token) ? 1 : 0)
        }
        if item.contentExtracted { score += 1 }
        if item.url != nil { score += 1 }
        return score
    }

    private static func needOverlapTokens(from text: String) -> [String] {
        var seen = Set<String>()
        var tokens: [String] = []
        for raw in text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) {
            guard raw.count >= 4, seen.insert(raw).inserted else { continue }
            tokens.append(raw)
            if tokens.count >= 16 { break }
        }
        return tokens
    }

    private static func dedup(_ sources: [ComposerSource]) -> [ComposerSource] {
        var seen = Set<String>()
        return sources.filter { source in
            let key = source.provenance?.sourceURL?.lowercased()
                ?? "\(source.label)\u{1f}\(source.provenance?.query ?? "")"
            return seen.insert(key).inserted
        }
    }

    /// Races the operation against a deadline WITHOUT tearing anything down
    /// or waiting for the loser: the abandoned work keeps running in the
    /// background, warming the session for the next message. (A task group
    /// can't do this — it always awaits its children before returning.)
    private static func withSoftDeadline<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            Task {
                let value = await operation()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}

actor MCPResearchResultCache {
    struct Key: Hashable, Sendable {
        let serverID: UUID
        let toolName: String
        let query: String
        let freshness: String?
        let requiresCorroboration: Bool
    }

    private struct Entry: Sendable {
        let result: MCPToolCallResult
        let storedAt: Date
    }

    static let shared = MCPResearchResultCache()
    private let ttl: TimeInterval
    private var entries: [Key: Entry] = [:]

    init(ttl: TimeInterval = 15 * 60) {
        self.ttl = ttl
    }

    func value(for key: Key, now: Date = Date()) -> MCPToolCallResult? {
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.storedAt) <= ttl else {
            entries[key] = nil
            return nil
        }
        return entry.result
    }

    func store(_ result: MCPToolCallResult, for key: Key, now: Date = Date()) {
        entries[key] = Entry(result: result, storedAt: now)
    }
}

/// First-caller-wins guard for the soft-deadline race above.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

// MARK: - Credential-change notification

extension Notification.Name {
    /// Posted when injectable MCP server credentials change. The main app
    /// sends a newer in-memory snapshot to the generative worker.
    public static let ohiaMCPServerInjectableEnvironmentDidChange = Notification.Name(
        "ohia.mcp.injectableEnvironmentDidChange"
    )
}
