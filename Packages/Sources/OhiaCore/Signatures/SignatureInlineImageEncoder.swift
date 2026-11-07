import Foundation

/// Translates the canonical `ohia-sig://` image tokens inside signature
/// HTML into each consumer's native reference form. Pure string rewrites —
/// deterministic and testable without AppKit.
public enum SignatureInlineImageEncoder {

    /// Send form: tokens become `cid:` references and the owned assets
    /// become an inline-image manifest for `OutboxItem.inlineImagesJSON`.
    /// Only assets actually referenced by the HTML enter the manifest, so
    /// the MIME payload never carries unreferenced parts.
    public static func encodeForSend(
        html: String,
        slot: SignatureSlot,
        store: SignatureAssetStore
    ) -> (html: String, images: [OutboxInlineImage]) {
        var rewritten = html
        var manifest: [OutboxInlineImage] = []
        for asset in slot.images {
            let token = SignatureImageToken.url(ownerID: slot.id, assetID: asset.id)
            guard rewritten.contains(token) else { continue }
            rewritten = rewritten.replacingOccurrences(
                of: token, with: "cid:\(asset.contentID)"
            )
            manifest.append(OutboxInlineImage(
                path: store.fileURL(forOwner: slot.id, asset: asset).path,
                contentID: asset.contentID,
                mimeType: asset.mimeType
            ))
        }
        return (rewritten, manifest)
    }

    /// Removes `<img>` tags whose `src` is an `ohia-sig://` token owned by
    /// `ownerID` — the cleanup applied to a draft's stored HTML when the
    /// slot it referenced is deleted, so dead tokens never reach the wire.
    public static func strippingImageTags(html: String, ownerID: UUID) -> String {
        let owner = NSRegularExpression.escapedPattern(
            for: "\(SignatureImageToken.scheme)://\(ownerID.uuidString.lowercased())/"
        )
        guard let regex = try? NSRegularExpression(
            pattern: "<img\\b[^>]*\(owner)[^>]*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return html }
        return regex.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: (html as NSString).length),
            withTemplate: ""
        )
    }

    /// Preview form: tokens become self-contained `data:` URLs so a
    /// sandboxed WKWebView (which can load no file or remote resources)
    /// renders send-fidelity output. Assets whose backing file is missing
    /// keep their token — the preview shows a broken image rather than
    /// silently hiding the reference.
    public static func encodeForPreview(
        html: String,
        ownerID: UUID,
        assets: [SignatureImageAsset],
        store: SignatureAssetStore
    ) -> String {
        var rewritten = html
        for asset in assets {
            let token = SignatureImageToken.url(ownerID: ownerID, assetID: asset.id)
            guard rewritten.contains(token),
                  let data = try? store.data(forOwner: ownerID, asset: asset) else {
                continue
            }
            let dataURL = "data:\(asset.mimeType);base64,\(data.base64EncodedString())"
            rewritten = rewritten.replacingOccurrences(of: token, with: dataURL)
        }
        return rewritten
    }
}
