import CryptoKit
import Foundation

/// Process-wide registry of live MCP sessions, one per configured server.
///
/// Sessions are created lazily on first request and kept for the process
/// session. A request whose config or credentials differ from the live
/// session's (edited endpoint or headers, rotated token) retires the old session and
/// starts fresh, so Settings edits take effect without a relaunch.
///
/// `shared` is deliberately process-global: the app and generative worker
/// each want one remote connection per server in their own process.
public actor MCPSessionManager {

    public static let shared = MCPSessionManager()

    public typealias SessionFactory = @Sendable (MCPConfiguredServer, [String: String]) -> any MCPToolCalling

    private var sessions: [UUID: any MCPToolCalling] = [:]
    private var fingerprints: [UUID: String] = [:]
    private let sessionFactory: SessionFactory

    /// `sessionFactory` defaults to the HTTPS `MCPClientSession`; tests
    /// substitute fakes.
    public init(
        sessionFactory: @escaping SessionFactory = { MCPClientSession(config: $0, environment: $1) }
    ) {
        self.sessionFactory = sessionFactory
    }

    /// The live session for this server, creating (or replacing, when the
    /// configuration changed) as needed. Connection stays lazy — this never
    /// opens a network connection by itself.
    public func session(
        for config: MCPConfiguredServer,
        environment: [String: String]
    ) async -> any MCPToolCalling {
        let fingerprint = Self.fingerprint(config: config, environment: environment)
        if let existing = sessions[config.id], fingerprints[config.id] == fingerprint {
            return existing
        }
        if let retired = sessions[config.id] {
            await retired.shutdown()
        }
        let session = sessionFactory(config, environment)
        sessions[config.id] = session
        fingerprints[config.id] = fingerprint
        return session
    }

    /// Retires a server's session (removed server, explicit re-test). The
    /// next `session(for:environment:)` starts clean.
    public func invalidate(id: UUID) async {
        fingerprints[id] = nil
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.shutdown()
    }

    public func stopAll() async {
        let retiring = Array(sessions.values)
        sessions = [:]
        fingerprints = [:]
        for session in retiring {
            await session.shutdown()
        }
    }

    /// Stable digest of everything that affects a live connection. Secret
    /// values participate only as a hash so they never sit in a comparison
    /// string.
    private static func fingerprint(
        config: MCPConfiguredServer,
        environment: [String: String]
    ) -> String {
        var components: [String] = [config.remoteEndpointURL ?? ""]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            components.append(key)
            components.append(SHA256.hash(data: Data(value.utf8))
                .map { String(format: "%02x", $0) }
                .joined())
        }
        return components.joined(separator: "\u{1F}")
    }
}
