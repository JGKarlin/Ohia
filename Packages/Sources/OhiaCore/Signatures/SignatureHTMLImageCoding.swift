import AppKit
import Foundation

/// Bridges signature HTML and the AppKit editing model without ever
/// letting Cocoa's HTML importer/writer touch an `<img>` tag — its
/// attachment handling is not round-trip safe. Each image is swapped for a
/// literal text sentinel `[[OHIA-SIG-IMG:<asset-id>]]` before Cocoa sees
/// the document, and swapped back after; Cocoa only ever processes text
/// and spans.
///
/// All entry points are `@MainActor`: Cocoa's HTML importer is
/// WebKit-backed and main-thread-only.
public extension NSAttributedString.Key {
    /// Carries the owning `SignatureImageAsset` id (uuidString) alongside a
    /// signature image attachment. Identity lives in this attribute — not
    /// in `NSTextAttachment.fileWrapper`, whose state AppKit mutates —
    /// so the export round trip can always find its images.
    static let ohiaSignatureAssetID = NSAttributedString.Key("OhiaSignatureAssetID")
}

@MainActor
public enum SignatureHTMLImageCoding {

    // MARK: - HTML → editor

    /// Imports canonical signature HTML into an editable attributed string,
    /// materializing each owned image as a file-backed `NSTextAttachment`
    /// sized to its deterministic display bounds.
    public static func attributedContent(
        html: String,
        ownerID: UUID,
        assets: [SignatureImageAsset],
        store: SignatureAssetStore
    ) -> NSAttributedString {
        let sentinelHTML = replacingImageTags(in: html, assets: assets)
        guard let data = sentinelHTML.data(using: .utf8),
              let imported = try? NSMutableAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue
                  ],
                  documentAttributes: nil
              ) else {
            return NSAttributedString(string: sentinelHTML)
        }
        replaceSentinels(in: imported, ownerID: ownerID, assets: assets, store: store)
        restoreResponsiveTableWidths(in: imported, sourceHTML: sentinelHTML)
        return imported
    }

    // MARK: - Editor → HTML

    /// Exports the editor's attributed string back to the canonical
    /// fragment form: attachments become sentinels, Cocoa writes a
    /// head-less inline-styled fragment, sentinels become `ohia-sig://`
    /// image tags, and a final sanitizer pass restores canonical attribute
    /// order. Attachments that are not owned signature assets are dropped.
    public static func exportFragmentHTML(
        _ content: NSAttributedString,
        ownerID: UUID,
        assets: [SignatureImageAsset],
        linkPolicy: SignatureHTMLSanitizer.LinkPolicy
    ) -> String? {
        let ownedAssetIDs = Set(assets.map { $0.id.uuidString.lowercased() })
        let work = NSMutableAttributedString(attributedString: content)

        var replacements: [(NSRange, NSAttributedString)] = []
        work.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: work.length)
        ) { value, range, _ in
            guard value is NSTextAttachment else { return }
            let assetID = (work.attribute(
                .ohiaSignatureAssetID, at: range.location, effectiveRange: nil
            ) as? String)?.lowercased()
            let replacement: String
            if let assetID, ownedAssetIDs.contains(assetID), let uuid = UUID(uuidString: assetID) {
                replacement = sentinel(for: uuid)
            } else {
                replacement = ""
            }
            replacements.append((
                range,
                sentinelReplacement(
                    replacement,
                    preserving: work.attributes(
                        at: range.location,
                        effectiveRange: nil
                    )
                )
            ))
        }
        for (range, replacement) in replacements.reversed() {
            work.replaceCharacters(in: range, with: replacement)
        }

        // Cocoa needs a font on every run to write font styles at all.
        let fullRange = NSRange(location: 0, length: work.length)
        if work.length > 0 {
            var missingFontRanges: [NSRange] = []
            work.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                if value == nil { missingFontRanges.append(range) }
            }
            for range in missingFontRanges {
                work.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: range)
            }
        }

        guard let data = try? work.data(
            from: NSRange(location: 0, length: work.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
                // Force a body fragment with inline styles: no doctype, no
                // <head>/<style> class sheet — the canonical slot form must
                // concatenate into larger HTML bodies and survive clients
                // that strip style blocks.
                .excludedElements: [
                    "XML", "DOCTYPE", "html", "head", "meta", "title", "style", "body"
                ]
            ]
        ), let fragment = String(data: data, encoding: .utf8) else {
            return nil
        }

        let withImages = restoringImageTags(
            in: fragment, ownerID: ownerID, assets: assets
        )
        return SignatureHTMLSanitizer.sanitize(
            withImages, assets: assets, ownerID: ownerID, linkPolicy: linkPolicy
        )
    }

    // MARK: - Composer body variants

    /// Sentinel-aware wrapper around `ComposerRichTextCodec.content` for
    /// draft bodies carrying signature images and user-inserted inline
    /// photos. The surrounding body is arbitrary user content; owned images
    /// are shielded behind text sentinels while Cocoa imports the HTML.
    public static func composerContent(
        plainText: String,
        html: String?,
        format: ComposerMessageFormat,
        ownerID: UUID,
        assets: [SignatureImageAsset],
        store: SignatureAssetStore,
        inlinePhotoOwnerID: UUID? = nil,
        inlinePhotos: [ComposerInlinePhotoAsset] = [],
        inlinePhotoStore: ComposerInlinePhotoStore = ComposerInlinePhotoStore()
    ) -> NSAttributedString {
        guard format == .richText, let html else {
            return ComposerRichTextCodec.content(
                plainText: plainText, html: html, format: format
            )
        }

        var sentinelHTML = html
        if let inlinePhotoOwnerID {
            sentinelHTML = ComposerInlinePhotoCoding.replacingImageTags(
                in: sentinelHTML,
                ownerID: inlinePhotoOwnerID,
                assets: inlinePhotos
            )
        }
        if !assets.isEmpty {
            sentinelHTML = replacingImageTags(in: sentinelHTML, assets: assets)
        }
        let imported = ComposerRichTextCodec.content(
            plainText: plainText, html: sentinelHTML, format: format
        )
        let mutable = NSMutableAttributedString(attributedString: imported)
        if !assets.isEmpty {
            replaceSentinels(in: mutable, ownerID: ownerID, assets: assets, store: store)
        }
        if let inlinePhotoOwnerID {
            ComposerInlinePhotoCoding.replaceSentinels(
                in: mutable,
                ownerID: inlinePhotoOwnerID,
                assets: inlinePhotos,
                store: inlinePhotoStore
            )
        }
        if mutable.length > 0,
           ComposerRichTextCodec.plainBodyProjection(of: mutable) == plainText + "\n" {
            mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
        }
        return mutable
    }

    /// Sentinel-aware wrapper around `ComposerRichTextCodec.exportHTML`:
    /// owned signature attachments survive as `ohia-sig://` tags and owned
    /// body photos survive as `ohia-photo://` tags. Any other attachment is
    /// dropped. The body keeps Cocoa's full-document HTML form.
    public static func exportComposerBodyHTML(
        _ content: NSAttributedString,
        format: ComposerMessageFormat,
        ownerID: UUID,
        assets: [SignatureImageAsset],
        inlinePhotoOwnerID: UUID? = nil,
        inlinePhotos: [ComposerInlinePhotoAsset] = []
    ) -> String? {
        guard format == .richText else { return nil }
        let work = ComposerInlinePhotoCoding.replacingAttachmentsWithSentinels(
            in: content,
            assets: inlinePhotos
        )

        let exported: String?
        if assets.isEmpty {
            exported = ComposerRichTextCodec.exportHTML(work, format: format)
        } else {
            let ownedAssetIDs = Set(assets.map { $0.id.uuidString.lowercased() })
            var replacements: [(NSRange, NSAttributedString)] = []
            work.enumerateAttribute(
                .attachment, in: NSRange(location: 0, length: work.length)
            ) { value, range, _ in
                guard value is NSTextAttachment else { return }
                let assetID = (work.attribute(
                    .ohiaSignatureAssetID, at: range.location, effectiveRange: nil
                ) as? String)?.lowercased()
                let replacement: String
                if let assetID,
                   ownedAssetIDs.contains(assetID),
                   let uuid = UUID(uuidString: assetID) {
                    replacement = sentinel(for: uuid)
                } else {
                    replacement = ""
                }
                replacements.append((
                    range,
                    sentinelReplacement(
                        replacement,
                        preserving: work.attributes(
                            at: range.location,
                            effectiveRange: nil
                        )
                    )
                ))
            }
            for (range, replacement) in replacements.reversed() {
                work.replaceCharacters(in: range, with: replacement)
            }
            exported = ComposerRichTextCodec.exportHTML(work, format: format).map {
                restoringImageTags(in: $0, ownerID: ownerID, assets: assets)
            }
        }

        guard let exported else { return nil }
        guard let inlinePhotoOwnerID else { return exported }
        return ComposerInlinePhotoCoding.restoringImageTags(
            in: exported,
            ownerID: inlinePhotoOwnerID,
            assets: inlinePhotos
        )
    }

    /// Accept-time normalization: one import → export round trip so the
    /// stored canonical HTML is byte-stable under any further hand-edit
    /// round trips.
    public static func normalize(
        html: String,
        ownerID: UUID,
        assets: [SignatureImageAsset],
        store: SignatureAssetStore,
        linkPolicy: SignatureHTMLSanitizer.LinkPolicy
    ) -> String {
        let attributed = attributedContent(
            html: html, ownerID: ownerID, assets: assets, store: store
        )
        return exportFragmentHTML(
            attributed, ownerID: ownerID, assets: assets, linkPolicy: linkPolicy
        ) ?? html
    }

    // MARK: - Sentinels

    static func sentinel(for assetID: UUID) -> String {
        "[[OHIA-SIG-IMG:\(assetID.uuidString.lowercased())]]"
    }

    /// Keeps paragraph/table-block metadata when an attachment becomes its
    /// temporary text sentinel. Replacing it with an unstyled string drops
    /// AppKit's `NSTextBlock` stack when the image is the first item in a
    /// table cell, so Cocoa writes closing table tags without their openings.
    private static func sentinelReplacement(
        _ sentinel: String,
        preserving sourceAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        guard !sentinel.isEmpty else { return NSAttributedString(string: "") }
        var attributes = sourceAttributes
        attributes.removeValue(forKey: .attachment)
        attributes.removeValue(forKey: .ohiaSignatureAssetID)
        return NSAttributedString(string: sentinel, attributes: attributes)
    }

    /// Replaces `<img>` tags whose token references an owned asset with
    /// text sentinels; unowned image tags are removed.
    static func replacingImageTags(
        in html: String, assets: [SignatureImageAsset]
    ) -> String {
        let assetIDs = Set(assets.map(\.id))
        let regex = try! NSRegularExpression(
            pattern: "<img\\b[^>]*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let ns = html as NSString
        var out = ""
        var location = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: location, length: match.range.location - location))
            let tag = ns.substring(with: match.range)
            if let src = firstAttribute("src", in: tag),
               let token = SignatureImageToken.parse(src),
               assetIDs.contains(token.assetID) {
                out += sentinel(for: token.assetID)
            }
            location = match.range.location + match.range.length
        }
        out += ns.substring(from: location)
        return out
    }

    /// Replaces sentinels in exported HTML with canonical image tags.
    static func restoringImageTags(
        in html: String, ownerID: UUID, assets: [SignatureImageAsset]
    ) -> String {
        var out = html
        for asset in assets {
            var tag = "<img src=\"\(SignatureImageToken.url(ownerID: ownerID, assetID: asset.id))\""
            if let width = asset.imageType.stampedWidth { tag += " width=\"\(width)\"" }
            if let height = asset.imageType.stampedHeight { tag += " height=\"\(height)\"" }
            tag += ">"
            out = out.replacingOccurrences(of: sentinel(for: asset.id), with: tag)
        }
        return out
    }

    /// Swaps sentinel text runs inside an imported attributed string for
    /// file-backed attachments.
    private static func replaceSentinels(
        in attributed: NSMutableAttributedString,
        ownerID: UUID,
        assets: [SignatureImageAsset],
        store: SignatureAssetStore
    ) {
        for asset in assets {
            let marker = sentinel(for: asset.id)
            while true {
                let range = (attributed.string as NSString).range(of: marker)
                guard range.location != NSNotFound else { break }
                let sourceAttributes = attributed.attributes(
                    at: range.location,
                    effectiveRange: nil
                )
                let attachment = attachment(
                    for: asset, ownerID: ownerID, store: store
                )
                let replacement = NSMutableAttributedString(attachment: attachment)
                replacement.addAttributes(
                    sourceAttributes,
                    range: NSRange(location: 0, length: replacement.length)
                )
                replacement.addAttribute(
                    .ohiaSignatureAssetID,
                    value: asset.id.uuidString.lowercased(),
                    range: NSRange(location: 0, length: replacement.length)
                )
                attributed.replaceCharacters(in: range, with: replacement)
            }
        }
    }

    private static func attachment(
        for asset: SignatureImageAsset,
        ownerID: UUID,
        store: SignatureAssetStore
    ) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        if let data = try? store.data(forOwner: ownerID, asset: asset) {
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = asset.fileName
            attachment.fileWrapper = wrapper
            if let image = NSImage(data: data) {
                attachment.image = image
                let width = asset.imageType.stampedWidth.map(CGFloat.init)
                let height = asset.imageType.stampedHeight.map(CGFloat.init)
                let naturalSize = image.size
                let bounds: CGRect
                switch (width, height) {
                case let (w?, h?):
                    bounds = CGRect(x: 0, y: 0, width: w, height: h)
                case let (w?, nil):
                    let scale = naturalSize.width > 0 ? w / naturalSize.width : 1
                    bounds = CGRect(x: 0, y: 0, width: w, height: naturalSize.height * scale)
                case let (nil, h?):
                    let scale = naturalSize.height > 0 ? h / naturalSize.height : 1
                    bounds = CGRect(x: 0, y: 0, width: naturalSize.width * scale, height: h)
                case (nil, nil):
                    bounds = CGRect(origin: .zero, size: naturalSize)
                }
                attachment.bounds = bounds
            }
        } else {
            let wrapper = FileWrapper(regularFileWithContents: Data())
            wrapper.preferredFilename = asset.fileName
            attachment.fileWrapper = wrapper
        }
        return attachment
    }

    /// AppKit resolves percentage table widths to the importer viewport and
    /// stores that fixed point value. Restore the source semantics so the
    /// editor lays app-owned templates out against its actual container and
    /// Cocoa writes a percentage width when the signature is saved.
    private static func restoreResponsiveTableWidths(
        in attributed: NSMutableAttributedString,
        sourceHTML: String
    ) {
        let tableExpression = try! NSRegularExpression(
            pattern: #"<table\b[^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let source = sourceHTML as NSString
        let tableTags = tableExpression.matches(
            in: sourceHTML,
            range: NSRange(location: 0, length: source.length)
        ).map { source.substring(with: $0.range) }
        guard !tableTags.isEmpty,
              tableTags.allSatisfy({ isResponsiveTableWidth(firstAttribute("width", in: $0)) })
        else { return }

        var restoredTables = Set<ObjectIdentifier>()
        attributed.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            for block in style.textBlocks {
                let table: NSTextTable?
                if let cell = block as? NSTextTableBlock {
                    table = cell.table
                } else {
                    table = block as? NSTextTable
                }
                guard let table,
                      restoredTables.insert(ObjectIdentifier(table)).inserted
                else { continue }
                table.setValue(100, type: .percentageValueType, for: .width)
            }
        }
    }

    private static func isResponsiveTableWidth(_ value: String?) -> Bool {
        value == "100%" || value == "100.0%"
    }

    private static func firstAttribute(_ name: String, in tag: String) -> String? {
        let regex = try! NSRegularExpression(
            pattern: "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')",
            options: [.caseInsensitive]
        )
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        if match.range(at: 2).location != NSNotFound {
            return ns.substring(with: match.range(at: 2))
        }
        if match.range(at: 3).location != NSNotFound {
            return ns.substring(with: match.range(at: 3))
        }
        return nil
    }
}
