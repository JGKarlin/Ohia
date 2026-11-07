import AppKit
import Foundation

public extension NSAttributedString.Key {
    static let ohiaInlinePhotoAssetID = NSAttributedString.Key("OhiaInlinePhotoAssetID")
    static let ohiaInlinePhotoSize = NSAttributedString.Key("OhiaInlinePhotoSize")
}

@MainActor
public enum ComposerInlinePhotoCoding {
    public static func containsPhoto(in content: NSAttributedString) -> Bool {
        guard content.length > 0 else { return false }
        var found = false
        content.enumerateAttribute(
            .ohiaInlinePhotoAssetID,
            in: NSRange(location: 0, length: content.length)
        ) { value, _, stop in
            guard value != nil else { return }
            found = true
            stop.pointee = true
        }
        return found
    }

    public static func attachmentContent(
        asset: ComposerInlinePhotoAsset,
        ownerID: UUID,
        store: ComposerInlinePhotoStore,
        size: ComposerInlinePhotoSize
    ) -> NSAttributedString {
        let attachment = makeAttachment(asset: asset, ownerID: ownerID, store: store, size: size)
        let content = NSMutableAttributedString(attachment: attachment)
        let range = NSRange(location: 0, length: content.length)
        content.addAttributes([
            .ohiaInlinePhotoAssetID: asset.id.uuidString.lowercased(),
            .ohiaInlinePhotoSize: size.rawValue
        ], range: range)
        return content
    }

    public static func updateBounds(
        of attachment: NSTextAttachment,
        asset: ComposerInlinePhotoAsset,
        size: ComposerInlinePhotoSize
    ) {
        let pixels = size.pixelSize(for: asset)
        attachment.bounds = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
    }

    static func replacingImageTags(
        in html: String,
        ownerID: UUID,
        assets: [ComposerInlinePhotoAsset]
    ) -> String {
        let assetIDs = Set(assets.map(\.id))
        let regex = try! NSRegularExpression(
            pattern: "<img\\b[^>]*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let ns = html as NSString
        var result = ""
        var location = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(
                location: location,
                length: match.range.location - location
            ))
            let tag = ns.substring(with: match.range)
            let source = firstAttribute("src", in: tag)
            if let source, let token = ComposerInlinePhotoToken.parse(source) {
                if token.ownerID == ownerID, assetIDs.contains(token.assetID) {
                    let rawSize = firstAttribute("data-ohia-size", in: tag)
                    let size = ComposerInlinePhotoSize(rawValue: rawSize ?? "") ?? .medium
                    result += sentinel(assetID: token.assetID, size: size)
                }
            } else {
                result += tag
            }
            location = match.range.location + match.range.length
        }
        result += ns.substring(from: location)
        return result
    }

    static func replaceSentinels(
        in attributed: NSMutableAttributedString,
        ownerID: UUID,
        assets: [ComposerInlinePhotoAsset],
        store: ComposerInlinePhotoStore
    ) {
        for asset in assets {
            for size in ComposerInlinePhotoSize.allCases {
                let marker = sentinel(assetID: asset.id, size: size)
                while true {
                    let range = (attributed.string as NSString).range(of: marker)
                    guard range.location != NSNotFound else { break }
                    attributed.replaceCharacters(
                        in: range,
                        with: attachmentContent(
                            asset: asset,
                            ownerID: ownerID,
                            store: store,
                            size: size
                        )
                    )
                }
            }
        }
    }

    static func replacingAttachmentsWithSentinels(
        in content: NSAttributedString,
        assets: [ComposerInlinePhotoAsset]
    ) -> NSMutableAttributedString {
        let ownedIDs = Set(assets.map(\.id))
        let result = NSMutableAttributedString(attributedString: content)
        var replacements: [(NSRange, String)] = []
        result.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: result.length)
        ) { value, range, _ in
            guard value is NSTextAttachment,
                  let rawID = result.attribute(
                      .ohiaInlinePhotoAssetID,
                      at: range.location,
                      effectiveRange: nil
                  ) as? String,
                  let assetID = UUID(uuidString: rawID),
                  ownedIDs.contains(assetID)
            else { return }
            let rawSize = result.attribute(
                .ohiaInlinePhotoSize,
                at: range.location,
                effectiveRange: nil
            ) as? String
            let size = ComposerInlinePhotoSize(rawValue: rawSize ?? "") ?? .medium
            replacements.append((range, sentinel(assetID: assetID, size: size)))
        }
        for (range, marker) in replacements.reversed() {
            result.replaceCharacters(in: range, with: marker)
        }
        return result
    }

    static func restoringImageTags(
        in html: String,
        ownerID: UUID,
        assets: [ComposerInlinePhotoAsset]
    ) -> String {
        var result = html
        for asset in assets {
            for size in ComposerInlinePhotoSize.allCases {
                let pixels = size.pixelSize(for: asset)
                let tag = "<img src=\"\(ComposerInlinePhotoToken.url(ownerID: ownerID, assetID: asset.id))\" width=\"\(pixels.width)\" height=\"\(pixels.height)\" data-ohia-size=\"\(size.rawValue)\">"
                result = result.replacingOccurrences(
                    of: sentinel(assetID: asset.id, size: size),
                    with: tag
                )
            }
        }
        return result
    }

    private static func makeAttachment(
        asset: ComposerInlinePhotoAsset,
        ownerID: UUID,
        store: ComposerInlinePhotoStore,
        size: ComposerInlinePhotoSize
    ) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        if let data = try? store.previewData(forOwner: ownerID, asset: asset) {
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = asset.previewFileName
            attachment.fileWrapper = wrapper
            attachment.image = NSImage(data: data)
        } else if let data = try? store.data(forOwner: ownerID, asset: asset) {
            // Preserve display compatibility for drafts created before bounded
            // preview files were introduced.
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = asset.fileName
            attachment.fileWrapper = wrapper
            attachment.image = NSImage(data: data)
        } else {
            let wrapper = FileWrapper(regularFileWithContents: Data())
            wrapper.preferredFilename = asset.fileName
            attachment.fileWrapper = wrapper
        }
        updateBounds(of: attachment, asset: asset, size: size)
        return attachment
    }

    private static func sentinel(assetID: UUID, size: ComposerInlinePhotoSize) -> String {
        "[[OHIA-INLINE-PHOTO:\(assetID.uuidString.lowercased()):\(size.rawValue)]]"
    }

    private static func firstAttribute(_ name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let regex = try! NSRegularExpression(
            pattern: "\(escapedName)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')",
            options: [.caseInsensitive]
        )
        let ns = tag as NSString
        guard let match = regex.firstMatch(
            in: tag,
            range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        if match.range(at: 2).location != NSNotFound {
            return ns.substring(with: match.range(at: 2))
        }
        if match.range(at: 3).location != NSNotFound {
            return ns.substring(with: match.range(at: 3))
        }
        return nil
    }
}
