import Foundation
import OhiaCore
import OhiaML

enum SandboxResetCoordinator {
    private static let pendingResetMarkerVersion = 1

    private struct PendingResetMarker: Codable {
        let version: Int
        let requestedAt: Date
    }

    static func writePendingMarker(
        sharedLayout: OhiaStorageLayout,
        fileManager: FileManager = .default
    ) throws {
        try validateSharedLayout(sharedLayout)
        try fileManager.createDirectory(
            at: sharedLayout.containerRoot,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(
            PendingResetMarker(version: pendingResetMarkerVersion, requestedAt: Date())
        )
        try data.write(to: sharedLayout.pendingResetMarker, options: .atomic)
    }

    /// Completes a reset before SwiftData, workers, or any other private store
    /// opens. Public model downloads are retained only when their complete
    /// artifact metadata matches a pinned registry revision.
    @discardableResult
    static func completePendingReset(
        sharedLayout: OhiaStorageLayout,
        appPrivateRoots: [URL],
        fileManager: FileManager = .default,
        prepareExternalStateForDeletion: () throws -> Void = {}
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: sharedLayout.pendingResetMarker.path) else {
            return false
        }
        try validateSharedLayout(sharedLayout)
        for root in appPrivateRoots {
            try validateAppPrivateRoot(root)
        }
        let marker: PendingResetMarker
        do {
            let data = try Data(contentsOf: sharedLayout.pendingResetMarker)
            marker = try JSONDecoder().decode(PendingResetMarker.self, from: data)
        } catch {
            throw SandboxResetError.invalidPendingResetMarker
        }
        guard marker.version == pendingResetMarkerVersion else {
            throw SandboxResetError.unsupportedPendingResetVersion(marker.version)
        }

        // Credentials and defaults live outside the reset roots. Clear them
        // only after the durable marker and every deletion target have been
        // validated. If this fails, the marker and private files remain so the
        // exact reset can be retried on the next launch.
        try prepareExternalStateForDeletion()

        try removeUnverifiedPublicModels(
            sharedLayout: sharedLayout,
            fileManager: fileManager
        )
        try removeExistingItem(sharedLayout.privateRoot, fileManager: fileManager)
        try removeExistingItem(sharedLayout.publicModelResetStaging, fileManager: fileManager)
        for root in Set(appPrivateRoots.map(\.standardizedFileURL)) {
            try removeExistingItem(root, fileManager: fileManager)
        }
        try removeExistingItem(sharedLayout.pendingResetMarker, fileManager: fileManager)
        return true
    }

    private static func removeUnverifiedPublicModels(
        sharedLayout: OhiaStorageLayout,
        fileManager: FileManager
    ) throws {
        let modelsRoot = sharedLayout.publicModels
            .appendingPathComponent("models", isDirectory: true)
        guard itemExistsWithoutFollowingSymlink(modelsRoot, fileManager: fileManager) else {
            return
        }
        if try isSymbolicLink(modelsRoot, fileManager: fileManager) {
            try fileManager.removeItem(at: modelsRoot)
            return
        }

        let retainedDirectories = Set(ModelManager.allModels.compactMap { model -> URL? in
            let directory = GenerationModelStorage.modelDirectory(
                downloadBaseDirectory: sharedLayout.publicModels,
                modelID: model.modelId
            ).standardizedFileURL
            guard GenerationModelStorage.isVerifiedPublicModel(
                at: directory,
                expectedRevision: model.revision
            ) else {
                return nil
            }
            return directory
        })

        for organization in try fileManager.contentsOfDirectory(
            at: modelsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            if try isSymbolicLink(organization, fileManager: fileManager) {
                try fileManager.removeItem(at: organization)
                continue
            }
            let isDirectory = try organization.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            guard isDirectory else {
                try removeExistingItem(organization, fileManager: fileManager)
                continue
            }
            for modelDirectory in try fileManager.contentsOfDirectory(
                at: organization,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) {
                if try isSymbolicLink(modelDirectory, fileManager: fileManager)
                    || !retainedDirectories.contains(modelDirectory.standardizedFileURL) {
                    try removeExistingItem(modelDirectory, fileManager: fileManager)
                }
            }
            if try fileManager.contentsOfDirectory(atPath: organization.path).isEmpty {
                try fileManager.removeItem(at: organization)
            }
        }
    }

    private static func validateSharedLayout(_ layout: OhiaStorageLayout) throws {
        let container = layout.containerRoot.standardizedFileURL
        guard container.lastPathComponent == OhiaStorageRoot.appGroupIdentifier,
              layout == OhiaStorageRoot.layout(containerURL: container)
        else {
            throw SandboxResetError.invalidSharedLayout(container.path)
        }
    }

    private static func validateAppPrivateRoot(_ root: URL) throws {
        let components = root.standardizedFileURL.pathComponents
        guard components.count >= 4,
              Array(components.suffix(3)) == ["Library", "Application Support", "Ohia"]
        else {
            throw SandboxResetError.invalidAppPrivateRoot(root.path)
        }
    }

    private static func removeExistingItem(_ url: URL, fileManager: FileManager) throws {
        if itemExistsWithoutFollowingSymlink(url, fileManager: fileManager) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func itemExistsWithoutFollowingSymlink(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private static func isSymbolicLink(
        _ url: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }
}

enum SandboxResetError: LocalizedError {
    case invalidSharedLayout(String)
    case invalidAppPrivateRoot(String)
    case invalidPendingResetMarker
    case unsupportedPendingResetVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidSharedLayout(let path):
            return "The shared reset layout is not the Ohia App Group: \(path)"
        case .invalidAppPrivateRoot(let path):
            return "The app-private reset root is not an Ohia Application Support directory: \(path)"
        case .invalidPendingResetMarker:
            return "The pending reset request is invalid. No data was removed."
        case .unsupportedPendingResetVersion(let version):
            return "The pending reset request version \(version) is unsupported. No data was removed."
        }
    }
}
