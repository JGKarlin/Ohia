import Foundation

/// One app-owned, in-memory credential generation for automatic MCP servers.
/// The snapshot crosses only the private worker XPC connection; it has no file
/// or process-environment representation.
public struct MCPWorkerCredentialSnapshot: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case generation
        case values
    }

    public let generation: UInt64
    public let values: [UUID: [String: String]]

    public init(
        generation: UInt64,
        values: [UUID: [String: String]]
    ) {
        self.generation = generation
        self.values = values.filter { !$0.value.isEmpty }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            generation: try container.decode(UInt64.self, forKey: .generation),
            values: try container.decode([UUID: [String: String]].self, forKey: .values)
        )
    }

    public static let empty = MCPWorkerCredentialSnapshot(
        generation: 0,
        values: [:]
    )

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

/// Lock-backed storage lets synchronous source-compilation code resolve one
/// server environment without exposing credentials through global process
/// state. Replacements are monotonic and report only servers whose values
/// changed so their live child sessions can be retired before acknowledgement.
public final class MCPWorkerCredentialStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: MCPWorkerCredentialSnapshot

    public init(snapshot: MCPWorkerCredentialSnapshot = .empty) {
        self.snapshot = snapshot
    }

    @discardableResult
    public func replace(_ replacement: MCPWorkerCredentialSnapshot) -> Set<UUID> {
        lock.withLock {
            guard replacement.generation > snapshot.generation else { return [] }
            let serverIDs = Set(snapshot.values.keys).union(replacement.values.keys)
            let affected = Set(serverIDs.filter {
                snapshot.values[$0] != replacement.values[$0]
            })
            snapshot = replacement
            return affected
        }
    }

    public func environment(for serverID: UUID) -> [String: String] {
        lock.withLock { snapshot.values[serverID] ?? [:] }
    }

    public var generation: UInt64 {
        lock.withLock { snapshot.generation }
    }
}
