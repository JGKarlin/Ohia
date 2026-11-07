import Foundation

public enum ComposerInlinePhotoSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case small
    case medium
    case large
    case original

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .original: "Original"
        }
    }

    public var requestedWidth: Int? {
        switch self {
        case .small: 240
        case .medium: 480
        case .large: 720
        case .original: nil
        }
    }

    public func pixelSize(for asset: ComposerInlinePhotoAsset) -> (width: Int, height: Int) {
        let width = max(1, requestedWidth ?? asset.pixelWidth)
        let aspectHeight = Double(width) * Double(asset.pixelHeight) / Double(max(1, asset.pixelWidth))
        return (width, max(1, Int(aspectHeight.rounded())))
    }
}

/// Durable metadata for one photo copied into a Composer draft's private
/// asset directory. Display size lives on each attributed-string occurrence,
/// so one photo can appear more than once at different presets.
public struct ComposerInlinePhotoAsset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var fileExtension: String
    public var mimeType: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(
        id: UUID = UUID(),
        fileExtension: String,
        mimeType: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.fileExtension = fileExtension
        self.mimeType = mimeType
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
    }

    public var fileName: String { "\(id.uuidString.lowercased()).\(fileExtension)" }
    public var previewFileName: String { "\(id.uuidString.lowercased()).preview.png" }
    public var contentID: String { "photo-\(id.uuidString.lowercased())@ohia" }
}

public enum ComposerInlinePhotoAssetCoding {
    public static func encode(_ assets: [ComposerInlinePhotoAsset]) -> String? {
        guard !assets.isEmpty, let data = try? JSONEncoder().encode(assets) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String?) -> [ComposerInlinePhotoAsset] {
        guard let json,
              let data = json.data(using: .utf8),
              let assets = try? JSONDecoder().decode([ComposerInlinePhotoAsset].self, from: data)
        else { return [] }
        return assets
    }
}

/// Canonical URL stored in draft HTML. It is translated to `cid:` only in a
/// provider Drafts copy or Outbox item; the stable token remains in SwiftData.
public enum ComposerInlinePhotoToken {
    public static let scheme = "ohia-photo"

    public static func url(ownerID: UUID, assetID: UUID) -> String {
        "\(scheme)://\(ownerID.uuidString.lowercased())/\(assetID.uuidString.lowercased())"
    }

    public static func parse(_ string: String) -> (ownerID: UUID, assetID: UUID)? {
        let lower = string.lowercased()
        let prefix = "\(scheme)://"
        guard lower.hasPrefix(prefix) else { return nil }
        let parts = lower.dropFirst(prefix.count).split(separator: "/")
        guard parts.count == 2,
              let ownerID = UUID(uuidString: String(parts[0])),
              let assetID = UUID(uuidString: String(parts[1]))
        else { return nil }
        return (ownerID, assetID)
    }
}
