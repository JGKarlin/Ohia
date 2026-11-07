import Foundation
import UniformTypeIdentifiers

/// Owns the on-disk image files behind signature slots:
/// the shared App Group's `signatures/<owner-id>/<asset-id>.<ext>` directory.
///
/// The design studio stages imports under a throwaway session UUID; saving
/// a slot promotes the session directory to the slot's id in one move so a
/// cancelled session never leaks files into a slot's namespace. All
/// operations are plain synchronous file I/O — callers hop off the main
/// actor for bulk work.
public struct SignatureAssetStore: Sendable {
    public enum Error: Swift.Error {
        case unreadableImageData
        case unsupportedImageType(String)
        case assetMissing(URL)
    }

    public let rootDirectory: URL

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
    }

    private static func defaultRootDirectory() -> URL {
        do {
            return try OhiaStorageRoot.resolve().signatureAssets
        } catch {
            preconditionFailure("Unable to resolve signature asset storage: \(String(reflecting: type(of: error)))")
        }
    }

    public func directory(forOwner ownerID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            ownerID.uuidString.lowercased(), isDirectory: true
        )
    }

    public func fileURL(forOwner ownerID: UUID, asset: SignatureImageAsset) -> URL {
        directory(forOwner: ownerID)
            .appendingPathComponent(asset.fileName, isDirectory: false)
    }

    /// Copies raw image bytes into the owner's directory and returns the
    /// asset descriptor. The extension/MIME pair is derived from the source
    /// filename's UTType; only real image types are accepted.
    public func importImage(
        data: Data,
        sourceFileName: String,
        imageType: SignatureImageType,
        ownerID: UUID
    ) throws -> SignatureImageAsset {
        guard !data.isEmpty else { throw Error.unreadableImageData }
        let ext = (sourceFileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty,
              let utType = UTType(filenameExtension: ext),
              utType.conforms(to: .image),
              let mime = utType.preferredMIMEType else {
            throw Error.unsupportedImageType(sourceFileName)
        }

        let asset = SignatureImageAsset(
            fileExtension: ext, mimeType: mime, imageType: imageType
        )
        let dir = directory(forOwner: ownerID)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        try data.write(
            to: dir.appendingPathComponent(asset.fileName, isDirectory: false),
            options: .atomic
        )
        return asset
    }

    /// Moves a design session's staged assets into a slot's directory.
    /// Merges file-by-file when the slot directory already exists (slot
    /// edits stage revisions under a fresh session id).
    public func promote(sessionID: UUID, toSlot slotID: UUID) throws {
        let fm = FileManager.default
        let source = directory(forOwner: sessionID)
        guard fm.fileExists(atPath: source.path) else { return }
        let destination = directory(forOwner: slotID)

        if !fm.fileExists(atPath: destination.path) {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.moveItem(at: source, to: destination)
            return
        }
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let from = source.appendingPathComponent(name, isDirectory: false)
            let to = destination.appendingPathComponent(name, isDirectory: false)
            if fm.fileExists(atPath: to.path) {
                try fm.removeItem(at: to)
            }
            try fm.moveItem(at: from, to: to)
        }
        try fm.removeItem(at: source)
    }

    /// Copies one owner's assets to another owner (slot duplication).
    /// A missing source directory is a no-op.
    public func duplicateAssets(from sourceID: UUID, to destinationID: UUID) throws {
        let fm = FileManager.default
        let source = directory(forOwner: sourceID)
        guard fm.fileExists(atPath: source.path) else { return }
        let destination = directory(forOwner: destinationID)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.copyItem(at: source, to: destination)
    }

    /// Deletes an owner's whole directory (slot removal, session cancel).
    /// Missing directories are a no-op.
    public func deleteAssets(ownerID: UUID) {
        let dir = directory(forOwner: ownerID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Reads an asset's bytes, throwing when the backing file is gone.
    public func data(forOwner ownerID: UUID, asset: SignatureImageAsset) throws -> Data {
        let url = fileURL(forOwner: ownerID, asset: asset)
        guard let data = try? Data(contentsOf: url) else {
            throw Error.assetMissing(url)
        }
        return data
    }
}
