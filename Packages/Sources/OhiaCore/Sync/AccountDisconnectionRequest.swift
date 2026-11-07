import Foundation

/// A durable maintenance barrier. Writers remain stopped until the account's
/// files, indexes, credentials, and database rows have all been removed.
public struct AccountDisconnectionRequest: Codable, Sendable {
    public let accountID: UUID
    public let resumePipeline: Bool

    public static func url(in layout: OhiaStorageLayout) -> URL {
        layout.privateRoot.appendingPathComponent("pending-account-disconnection.json")
    }

    public static var isPending: Bool {
        guard let layout = try? OhiaStorageRoot.resolve() else { return false }
        return FileManager.default.fileExists(atPath: url(in: layout).path)
    }

    public static func load(in layout: OhiaStorageLayout) throws -> Self? {
        let location = url(in: layout)
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: location))
    }

    public static func begin(accountID: UUID, in layout: OhiaStorageLayout, resumePipeline: Bool = false) throws {
        if let pending = try load(in: layout) {
            guard pending.accountID == accountID else { throw DisconnectionError.anotherAccountPending }
            return
        }
        try FileManager.default.createDirectory(at: layout.privateRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(Self(accountID: accountID, resumePipeline: resumePipeline)).write(to: url(in: layout), options: .atomic)
    }

    public static func finish(in layout: OhiaStorageLayout) throws {
        let location = url(in: layout)
        if FileManager.default.fileExists(atPath: location.path) {
            try FileManager.default.removeItem(at: location)
        }
    }

    public enum DisconnectionError: LocalizedError {
        case anotherAccountPending
        public var errorDescription: String? {
            "Finish the pending account disconnection before disconnecting another account."
        }
    }
}
