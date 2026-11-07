import Foundation

public enum ComposerInlinePhotoEncoder {
    public static func referencedAssets(
        html: String?,
        ownerID: UUID,
        assets: [ComposerInlinePhotoAsset]
    ) -> [ComposerInlinePhotoAsset] {
        guard let html else { return [] }
        return assets.filter { asset in
            html.contains(ComposerInlinePhotoToken.url(ownerID: ownerID, assetID: asset.id))
        }
    }

    public static func encodeForSend(
        html: String,
        ownerID: UUID,
        assets: [ComposerInlinePhotoAsset],
        store: ComposerInlinePhotoStore
    ) -> (html: String, images: [OutboxInlineImage]) {
        var rewritten = html
        var manifest: [OutboxInlineImage] = []
        for asset in assets {
            let token = ComposerInlinePhotoToken.url(ownerID: ownerID, assetID: asset.id)
            guard rewritten.contains(token) else { continue }
            rewritten = rewritten.replacingOccurrences(of: token, with: "cid:\(asset.contentID)")
            manifest.append(OutboxInlineImage(
                path: store.fileURL(forOwner: ownerID, asset: asset).path,
                contentID: asset.contentID,
                mimeType: asset.mimeType
            ))
        }
        return (rewritten, manifest)
    }
}
