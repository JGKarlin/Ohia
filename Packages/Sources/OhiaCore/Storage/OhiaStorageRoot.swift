import Foundation
import Synchronization

public struct OhiaStorageLayout: Equatable, Sendable {
    public let containerRoot: URL
    public let privateRoot: URL
    public let swiftDataStore: URL
    public let canonicalStore: URL
    public let workerState: URL
    public let workerCoordination: URL
    public let vectorData: URL
    public let vectorIndex: URL
    public let cacheData: URL
    public let retrievalModels: URL
    public let composerAttachments: URL
    public let composerInlinePhotos: URL
    public let signatureAssets: URL
    public let deadlineAssets: URL
    public let mcpRecords: URL
    public let personalizedModels: URL
    public let publicModels: URL
    public let publicModelResetStaging: URL
    public let pendingResetMarker: URL
}

public enum OhiaStorageRoot {
    public static let appGroupIdentifier = "group.org.jgkarlin.Ohia"

    private static let testContainer = Mutex<URL?>(nil)

    /// Points every store at `containerURL`, instead of the App Group
    /// container, for the rest of this process. Only test targets call this,
    /// so a test run never reads, writes or deletes files in the user's live
    /// Ohia storage. No production source calls it (enforced by
    /// `StorageRootSourceInventoryTests`).
    public static func overrideContainerForTesting(_ containerURL: URL) {
        testContainer.withLock { $0 = containerURL.standardizedFileURL }
    }

    public static func resolve(fileManager: FileManager = .default) throws -> OhiaStorageLayout {
        if let containerURL = testContainer.withLock({ $0 }) {
            return layout(containerURL: containerURL)
        }
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw OhiaStorageRootError.appGroupUnavailable(appGroupIdentifier)
        }
        return layout(containerURL: containerURL)
    }

    public static func required(fileManager: FileManager = .default) -> OhiaStorageLayout {
        do {
            return try resolve(fileManager: fileManager)
        } catch {
            preconditionFailure("Unable to resolve Ohia shared storage: \(String(reflecting: type(of: error)))")
        }
    }

    public static func layout(containerURL: URL) -> OhiaStorageLayout {
        let container = containerURL.standardizedFileURL
        let privateRoot = container.appendingPathComponent("private-state", isDirectory: true)
        let vectorData = privateRoot.appendingPathComponent("vectors.sqlite")
        return OhiaStorageLayout(
            containerRoot: container,
            privateRoot: privateRoot,
            swiftDataStore: privateRoot.appendingPathComponent("Ohia.store"),
            canonicalStore: privateRoot.appendingPathComponent("messages", isDirectory: true),
            workerState: privateRoot.appendingPathComponent("workers", isDirectory: true),
            workerCoordination: privateRoot.appendingPathComponent("worker-coordination", isDirectory: true),
            vectorData: vectorData,
            vectorIndex: privateRoot.appendingPathComponent("vector_index", isDirectory: true),
            cacheData: privateRoot.appendingPathComponent("caches", isDirectory: true),
            retrievalModels: privateRoot.appendingPathComponent("models", isDirectory: true),
            composerAttachments: privateRoot.appendingPathComponent("composer-attachments", isDirectory: true),
            composerInlinePhotos: privateRoot.appendingPathComponent("composer-inline-photos", isDirectory: true),
            signatureAssets: privateRoot.appendingPathComponent("signatures", isDirectory: true),
            deadlineAssets: privateRoot.appendingPathComponent("deadline-work", isDirectory: true),
            mcpRecords: privateRoot.appendingPathComponent("mcp", isDirectory: true),
            personalizedModels: privateRoot.appendingPathComponent("personalized-models", isDirectory: true),
            publicModels: container
                .appendingPathComponent("public-models", isDirectory: true)
                .appendingPathComponent("huggingface", isDirectory: true),
            publicModelResetStaging: container
                .appendingPathComponent("public-models.reset-staging", isDirectory: true),
            pendingResetMarker: container.appendingPathComponent("pending-reset.json")
        )
    }

    /// App-only state lives in the app's own sandbox container. Callers pass
    /// this root explicitly; shared code and workers never derive it.
    public static func appPrivateRoot(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw OhiaStorageRootError.appPrivateRootUnavailable
        }
        return applicationSupport.appendingPathComponent("Ohia", isDirectory: true)
    }

    public static func requiredAppPrivateRoot(fileManager: FileManager = .default) -> URL {
        do {
            return try appPrivateRoot(fileManager: fileManager)
        } catch {
            preconditionFailure("Unable to resolve Ohia app-private storage: \(String(reflecting: type(of: error)))")
        }
    }
}

public enum OhiaStorageRootError: Error, Equatable, Sendable, LocalizedError {
    case appGroupUnavailable(String)
    case appPrivateRootUnavailable

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let identifier):
            return "The Ohia App Group container is unavailable: \(identifier)."
        case .appPrivateRootUnavailable:
            return "The Ohia app-private Application Support directory is unavailable."
        }
    }
}
