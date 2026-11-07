import Foundation

/// Owns ordinary Composer attachment bytes under
/// the shared App Group's `composer-attachments/<draft-id>/` directory.
public struct ComposerAttachmentStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
    }

    private static func defaultRootDirectory() -> URL {
        do {
            return try OhiaStorageRoot.resolve().composerAttachments
        } catch {
            preconditionFailure("Unable to resolve Composer attachment storage: \(String(reflecting: type(of: error)))")
        }
    }

    public func directory(forOwner ownerID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            ownerID.uuidString.lowercased(),
            isDirectory: true
        )
    }

    @concurrent
    public func importFiles(at sourceURLs: [URL], ownerID: UUID) async throws -> [String] {
        var stagedDirectories: [URL] = []
        var copiedFiles: [URL] = []
        do {
            for source in sourceURLs {
                let stagedDirectory = directory(forOwner: ownerID)
                    .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
                let destination = stagedDirectory
                    .appendingPathComponent(source.lastPathComponent, isDirectory: false)
                try FileManager.default.createDirectory(
                    at: stagedDirectory,
                    withIntermediateDirectories: true
                )
                stagedDirectories.append(stagedDirectory)
                try FileManager.default.copyItem(at: source, to: destination)
                copiedFiles.append(destination)
            }
            return copiedFiles.map(\.path)
        } catch {
            for directory in stagedDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            throw error
        }
    }

    public func deleteAttachment(atOwnedPath path: String, ownerID: UUID) {
        let owner = directory(forOwner: ownerID).standardizedFileURL
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let assetDirectory = file.deletingLastPathComponent()
        guard assetDirectory.deletingLastPathComponent() == owner else { return }
        try? FileManager.default.removeItem(at: assetDirectory)
    }

    public func deleteAttachments(ownerID: UUID) {
        let owner = directory(forOwner: ownerID)
        guard FileManager.default.fileExists(atPath: owner.path) else { return }
        try? FileManager.default.removeItem(at: owner)
    }
}
