import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Owns copied photo bytes for draft-inline images under
/// the shared App Group's `composer-inline-photos/<draft-id>/` directory.
public struct ComposerInlinePhotoStore: Sendable {
    public enum Error: Swift.Error, LocalizedError, Equatable {
        case unreadableImageData
        case unsupportedImageType(String)
        case photoTooLarge
        case photoDimensionsTooLarge
        case previewCreationFailed
        case assetMissing(URL)

        public var errorDescription: String? {
            switch self {
            case .unreadableImageData:
                "The selected file could not be read as a photo."
            case .unsupportedImageType(let fileName):
                "The photo format for \(fileName) is not supported."
            case .photoTooLarge:
                "The selected photo is larger than 25 MiB."
            case .photoDimensionsTooLarge:
                "The selected photo is larger than 50 megapixels."
            case .previewCreationFailed:
                "Ohia could not prepare the selected photo for the editor."
            case .assetMissing:
                "The stored photo file could not be found."
            }
        }
    }

    static let maximumByteCount = 25 * 1_024 * 1_024
    static let maximumPixelCount = 50_000_000
    static let maximumPreviewDimension = 2_048

    public let rootDirectory: URL

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
    }

    private static func defaultRootDirectory() -> URL {
        do {
            return try OhiaStorageRoot.resolve().composerInlinePhotos
        } catch {
            preconditionFailure("Unable to resolve Composer inline-photo storage: \(String(reflecting: type(of: error)))")
        }
    }

    public func directory(forOwner ownerID: UUID) -> URL {
        rootDirectory.appendingPathComponent(ownerID.uuidString.lowercased(), isDirectory: true)
    }

    public func fileURL(forOwner ownerID: UUID, asset: ComposerInlinePhotoAsset) -> URL {
        directory(forOwner: ownerID).appendingPathComponent(asset.fileName, isDirectory: false)
    }

    public func previewFileURL(forOwner ownerID: UUID, asset: ComposerInlinePhotoAsset) -> URL {
        directory(forOwner: ownerID)
            .appendingPathComponent(asset.previewFileName, isDirectory: false)
    }

    /// Compatibility entry point for callers that already own in-memory
    /// bytes. File-backed UI imports use the `@concurrent` URL API below.
    public func importPhoto(
        data: Data,
        sourceFileName: String,
        ownerID: UUID
    ) throws -> ComposerInlinePhotoAsset {
        try importValidatedPhoto(
            data: data,
            sourceFileName: sourceFileName,
            ownerID: ownerID
        )
    }

    @concurrent
    public func importPhoto(
        from sourceURL: URL,
        sourceFileName: String,
        ownerID: UUID
    ) async throws -> ComposerInlinePhotoAsset {
        try Task.checkCancellation()
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > Self.maximumByteCount {
            throw Error.photoTooLarge
        }

        try Task.checkCancellation()
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        try Task.checkCancellation()
        return try importPhoto(
            data: data,
            sourceFileName: sourceFileName,
            ownerID: ownerID
        )
    }

    func validateLimits(byteCount: Int, width: Int, height: Int) throws {
        guard byteCount <= Self.maximumByteCount else { throw Error.photoTooLarge }
        guard width > 0, height > 0 else { throw Error.unreadableImageData }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= Self.maximumPixelCount else {
            throw Error.photoDimensionsTooLarge
        }
    }

    private func importValidatedPhoto(
        data: Data,
        sourceFileName: String,
        ownerID: UUID
    ) throws -> ComposerInlinePhotoAsset {
        guard !data.isEmpty else { throw Error.unreadableImageData }
        guard data.count <= Self.maximumByteCount else { throw Error.photoTooLarge }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else {
            throw Error.unreadableImageData
        }
        guard let typeID = CGImageSourceGetType(source),
              let type = UTType(typeID as String),
              type.conforms(to: .image),
              let mimeType = type.preferredMIMEType,
              let fileExtension = type.preferredFilenameExtension
        else {
            throw Error.unsupportedImageType(sourceFileName)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
              let rawPixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let rawPixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw Error.unreadableImageData
        }
        try validateLimits(
            byteCount: data.count,
            width: rawPixelWidth,
            height: rawPixelHeight
        )
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swapsDisplayAxes = (5...8).contains(orientation)
        let pixelWidth = swapsDisplayAxes ? rawPixelHeight : rawPixelWidth
        let pixelHeight = swapsDisplayAxes ? rawPixelWidth : rawPixelHeight

        let asset = ComposerInlinePhotoAsset(
            fileExtension: type == .jpeg ? "jpg" : fileExtension.lowercased(),
            mimeType: mimeType.lowercased(),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        try Task.checkCancellation()
        let previewData = try makePreviewData(from: source)
        try Task.checkCancellation()

        let directory = directory(forOwner: ownerID)
        let originalURL = fileURL(forOwner: ownerID, asset: asset)
        let previewURL = previewFileURL(forOwner: ownerID, asset: asset)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Task.checkCancellation()
            try data.write(to: originalURL, options: .atomic)
            try Task.checkCancellation()
            try previewData.write(to: previewURL, options: .atomic)
            try Task.checkCancellation()
            return asset
        } catch {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: previewURL)
            throw error
        }
    }

    private func makePreviewData(from source: CGImageSource) throws -> Data {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumPreviewDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw Error.previewCreationFailed
        }
        try Task.checkCancellation()

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw Error.previewCreationFailed
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.previewCreationFailed
        }
        return output as Data
    }

    public func data(forOwner ownerID: UUID, asset: ComposerInlinePhotoAsset) throws -> Data {
        let url = fileURL(forOwner: ownerID, asset: asset)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw Error.assetMissing(url)
        }
        return data
    }

    public func previewData(
        forOwner ownerID: UUID,
        asset: ComposerInlinePhotoAsset
    ) throws -> Data {
        let url = previewFileURL(forOwner: ownerID, asset: asset)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw Error.assetMissing(url)
        }
        return data
    }

    public func deletePhotos(ownerID: UUID) {
        let url = directory(forOwner: ownerID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public func prunePhotos(ownerID: UUID, keeping assetIDs: Set<UUID>) {
        let ownerDirectory = directory(forOwner: ownerID)
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: ownerDirectory.path
        ) else { return }

        for name in names {
            guard let rawID = name.split(separator: ".").first,
                  let assetID = UUID(uuidString: String(rawID)),
                  !assetIDs.contains(assetID)
            else { continue }
            try? FileManager.default.removeItem(
                at: ownerDirectory.appendingPathComponent(name, isDirectory: false)
            )
        }
    }

    public func deletePhoto(ownerID: UUID, asset: ComposerInlinePhotoAsset) {
        let urls = [
            fileURL(forOwner: ownerID, asset: asset),
            previewFileURL(forOwner: ownerID, asset: asset)
        ]
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @concurrent
    public func discardImportedPhoto(
        ownerID: UUID,
        asset: ComposerInlinePhotoAsset
    ) async {
        deletePhoto(ownerID: ownerID, asset: asset)
    }
}
