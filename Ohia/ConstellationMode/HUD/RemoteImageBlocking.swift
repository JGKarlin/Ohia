import Foundation

/// Pre-render transform that neutralizes remote (`http`/`https`/protocol-relative)
/// resource references in an email HTML body so they never hit the network —
/// the default privacy posture for received mail. Each blocked `<img>` keeps its
/// box but paints nothing (a transparent pixel, no broken-image glyph) over an
/// optional neutral placeholder fill; the original URL is stashed in a
/// `data-ohia-remote-src` attribute so callers can audit or restore it.
///
/// `cid:` and `data:` images are left untouched — they are local / self-contained
/// (inline attachments are already rewritten to `data:` URLs upstream). When the
/// user trusts the sender, callers simply render the *original* HTML instead of
/// the blocked output, so no "unblock" parsing is needed.
///
/// Pure and `nonisolated` so the geometry/parsing is unit-testable off-main.
enum RemoteImageBlocking {

    /// 1×1 transparent GIF. Replacing a blocked `src` with this makes WebKit
    /// paint nothing (no broken-image glyph) while the element keeps its
    /// declared width/height, so sized images become a neutral box and 1×1
    /// tracking pixels stay invisible.
    nonisolated static let transparentPixel =
        "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    struct Result: Equatable {
        /// HTML with every remote resource reference neutralized.
        let html: String
        /// Number of `<img>` elements whose remote `src` was blocked — the
        /// count surfaced by the "Load remote images" affordance.
        let blockedImageCount: Int
    }

    /// True when the body references at least one remote image — a remote
    /// `<img>`, an `<input type="image">` with a remote `src`, or an SVG
    /// `<image>` with a remote `href`/`xlink:href`. Used to decide whether the
    /// unblock affordance should appear at all.
    nonisolated static func containsRemoteImages(in html: String) -> Bool {
        firstRemoteImageRange(in: html) != nil
            || containsRemoteInputImage(in: html)
            || containsRemoteSVGImage(in: html)
    }

    /// Upgrades remote image references from `http://` to `https://`. Marketing
    /// mail routinely mixes the two, and default App Transport Security blocks
    /// the cleartext ones; most CDNs serve the same asset over https, so forcing
    /// https loads them *without* relaxing ATS or transmitting in cleartext.
    /// Applied only for trusted senders (when images are being loaded), scoped
    /// to image-bearing URL positions — `src`/`srcset`/`background` attributes,
    /// srcset continuation URLs, and CSS `url(...)` — so visible body text is
    /// untouched. A genuinely http-only host still fails, which is the secure
    /// outcome (we never downgrade to cleartext).
    nonisolated static func upgradingInsecureImageURLs(in html: String) -> String {
        var result = html
        if let insecureImageURLRegex {
            result = insecureImageURLRegex.stringByReplacingMatches(
                in: result, range: fullRange(result), withTemplate: "$1https://"
            )
        }
        // srcset holds a comma-separated URL list; upgrade every http:// inside
        // each srcset value — handled separately so a stray comma in body text
        // is never matched.
        result = upgradeSrcsetValues(in: result, regex: doubleQuotedSrcsetRegex)
        result = upgradeSrcsetValues(in: result, regex: singleQuotedSrcsetRegex)
        return result
    }

    // Single-URL image positions: `src`/`background` attributes and CSS
    // `url(...)`. srcset is handled by `upgradeSrcsetValues` (it holds a list).
    nonisolated private static let insecureImageURLRegex = makeRegex(
        #"(?i)((?:\b(?:src|background)\s*=\s*["']?|url\(\s*['"]?)\s*)http://"#
    )
    nonisolated private static let doubleQuotedSrcsetRegex = makeRegex(#"(?i)(srcset\s*=\s*")([^"]*)(")"#)
    nonisolated private static let singleQuotedSrcsetRegex = makeRegex(#"(?i)(srcset\s*=\s*')([^']*)(')"#)

    nonisolated private static func upgradeSrcsetValues(in html: String, regex: NSRegularExpression?) -> String {
        guard let regex else { return html }
        let matches = regex.matches(in: html, range: fullRange(html))
        guard matches.isEmpty == false else { return html }
        var result = html
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4,
                  let fullR = Range(match.range, in: result),
                  let prefixR = Range(match.range(at: 1), in: html),
                  let valueR = Range(match.range(at: 2), in: html),
                  let suffixR = Range(match.range(at: 3), in: html) else { continue }
            let value = String(html[valueR])
            guard value.range(of: "http://", options: .caseInsensitive) != nil else { continue }
            let prefix = String(html[prefixR])
            let suffix = String(html[suffixR])
            let upgraded = value.replacingOccurrences(of: "http://", with: "https://")
            result.replaceSubrange(fullR, with: "\(prefix)\(upgraded)\(suffix)")
        }
        return result
    }

    /// Returns the body with remote `<img>` sources, `srcset`s, `<source>`
    /// srcsets, remote `url(...)` CSS references, remote `background=` table
    /// attributes, and remote stylesheet `<link>`s neutralized, plus the count
    /// of blocked images. `placeholderHex` (resolved by the caller from
    /// `OhiaColors` for the active appearance) tints the placeholder box; `nil`
    /// leaves blocked images transparent.
    nonisolated static func block(in html: String, placeholderHex: String?) -> Result {
        var blockedImageCount = 0

        var result = localizingKnownReactionImages(in: html)
        result = rewriteImgTags(in: result) { blockedImageCount += 1 }
        result = rewriteInputImageTags(in: result) { blockedImageCount += 1 }
        result = neutralizeSVGImageHrefs(in: result) { blockedImageCount += 1 }
        result = neutralizeSourceSrcset(in: result)
        result = neutralizeCSSURLs(in: result)
        result = neutralizeBackgroundAttributes(in: result)
        result = removeRemoteStylesheets(in: result)

        if let placeholderHex, blockedImageCount > 0 {
            result = prependingPlaceholderStyle(to: result, hex: placeholderHex)
        }
        return Result(html: result, blockedImageCount: blockedImageCount)
    }

    // MARK: - <img>

    nonisolated private static let imgTagRegex = makeRegex(#"(?is)<img\b[^>]*>"#)
    nonisolated private static func attrRegex(_ attr: String) -> NSRegularExpression? {
        makeRegex(#"(?i)\b"# + attr + #"\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#)
    }
    nonisolated private static let srcAttrRegex = attrRegex("src")
    nonisolated private static let srcsetAttrRegex = attrRegex("srcset")
    nonisolated private static let altAttrRegex = attrRegex("alt")

    /// Outlook reaction notifications encode their meaning as a small remote
    /// CDN image. Blocking that image preserves privacy but otherwise erases
    /// the reaction because the transparent replacement loads successfully and
    /// WebKit never paints its alt text. Convert the provider's known `like`
    /// asset to a local color-emoji glyph before applying generic blocking.
    nonisolated private static func localizingKnownReactionImages(in html: String) -> String {
        guard let imgTagRegex else { return html }
        let tags = imgTagRegex.matches(in: html, range: fullRange(html))
        guard tags.isEmpty == false else { return html }

        var result = html
        for tagMatch in tags.reversed() {
            guard let tagRange = Range(tagMatch.range, in: result) else { continue }
            let tag = String(result[tagRange])
            guard knownReactionEmoji(in: tag) == "👍" else { continue }
            result.replaceSubrange(
                tagRange,
                with: #"<span role="img" aria-label="like" style="display:inline-block;font-family:'Apple Color Emoji';font-size:25px;line-height:25px;width:25px;height:25px">👍</span>"#
            )
        }
        return result
    }

    nonisolated private static func knownReactionEmoji(in tag: String) -> String? {
        guard let alt = attributeValue(in: tag, regex: altAttrRegex)?.lowercased(),
              alt == "like",
              let source = attributeValue(in: tag, regex: srcAttrRegex),
              let url = URL(string: source),
              let host = url.host?.lowercased(),
              host.hasSuffix(".cdn.office.net"),
              url.path.lowercased() == "/assets/reaction/like.png" else {
            return nil
        }
        return "👍"
    }

    /// Rewrites each `<img>` whose `src` is remote: stashes the original in
    /// `data-ohia-remote-src`, swaps `src` to the transparent pixel, and
    /// neutralizes any `srcset`. Local (`cid:`/`data:`/relative) images pass
    /// through untouched. `onBlocked` fires once per blocked image.
    nonisolated private static func rewriteImgTags(in html: String, onBlocked: () -> Void) -> String {
        guard let imgTagRegex else { return html }
        let tags = imgTagRegex.matches(in: html, range: fullRange(html))
        guard tags.isEmpty == false else { return html }

        var result = html
        for tagMatch in tags.reversed() {
            guard let tagRange = Range(tagMatch.range, in: result) else { continue }
            let tag = String(result[tagRange])
            let srcValue = attributeValue(in: tag, regex: srcAttrRegex)
            let srcIsRemote = srcValue.map(isRemote) ?? false
            let srcsetIsRemote = attributeValue(in: tag, regex: srcsetAttrRegex)
                .map(srcsetReferencesRemote) ?? false
            // An image can carry a remote `srcset` with no `src` at all — block
            // either vector, not just `src`.
            guard srcIsRemote || srcsetIsRemote else { continue }

            var rewritten = tag
            if srcIsRemote, let srcValue {
                rewritten = replaceAttribute("src", in: rewritten, with: transparentPixel)
                rewritten = insertAttribute("data-ohia-remote-src", value: srcValue, intoTag: rewritten)
            }
            // Neutralize a responsive srcset so WebKit can't pick a remote
            // candidate over (or in the absence of) the blocked src.
            if srcsetIsRemote {
                rewritten = renameAttribute("srcset", to: "data-ohia-remote-srcset", inTag: rewritten)
            }
            result.replaceSubrange(tagRange, with: rewritten)
            onBlocked()
        }
        return result
    }

    // MARK: - <input type="image" src="...">

    nonisolated private static let inputTagRegex = makeRegex(#"(?is)<input\b[^>]*>"#)
    nonisolated private static let typeAttrRegex = attrRegex("type")

    /// `<input type="image">` is a form submit button rendered as an image; its
    /// `src` fetches a remote asset exactly like `<img>`, so it is an equivalent
    /// tracking vector. Rewrites each such input whose `src` is remote: stashes
    /// the original in `data-ohia-remote-src` and swaps `src` to the transparent
    /// pixel. Inputs of any other `type` (or with a local `src`) pass through
    /// untouched. `onBlocked` fires once per blocked input.
    nonisolated private static func rewriteInputImageTags(in html: String, onBlocked: () -> Void) -> String {
        guard let inputTagRegex else { return html }
        let tags = inputTagRegex.matches(in: html, range: fullRange(html))
        guard tags.isEmpty == false else { return html }

        var result = html
        for tagMatch in tags.reversed() {
            guard let tagRange = Range(tagMatch.range, in: result) else { continue }
            let tag = String(result[tagRange])
            // Only `type="image"` inputs load a `src`; checkboxes, text fields,
            // submit buttons, etc. never fetch a remote asset.
            guard let typeValue = attributeValue(in: tag, regex: typeAttrRegex),
                  typeValue.caseInsensitiveCompare("image") == .orderedSame else { continue }
            guard let srcValue = attributeValue(in: tag, regex: srcAttrRegex),
                  isRemote(srcValue) else { continue }

            var rewritten = replaceAttribute("src", in: tag, with: transparentPixel)
            rewritten = insertAttribute("data-ohia-remote-src", value: srcValue, intoTag: rewritten)
            result.replaceSubrange(tagRange, with: rewritten)
            onBlocked()
        }
        return result
    }

    // MARK: - SVG <image href="..."/xlink:href="...">

    // `<image\b` so this never matches `<img>` (the `\b` after `image` requires
    // a word boundary, so `<img ` / `<img>` are excluded). SVG images expose the
    // remote URL via either the plain `href` or the namespaced `xlink:href`.
    nonisolated private static let svgImageTagRegex = makeRegex(#"(?is)<image\b[^>]*>"#)
    nonisolated private static let xlinkHrefAttrRegex = attrRegex("xlink:href")
    // The bare-`href` matcher must NOT match the `href` *inside* `xlink:href`:
    // `\b` treats the `:` in `xlink:href` as a word boundary, so the generic
    // `attrRegex("href")` would falsely match it. Require the char before
    // `href` to be a tag/attribute separator (whitespace or `<`), never `:` or
    // a name char, so only a standalone `href` attribute is matched.
    nonisolated private static let bareHrefAttrRegex = makeRegex(
        #"(?i)(?<=[\s<])href\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#
    )

    /// Neutralizes SVG `<image>` elements whose `href`/`xlink:href` is remote by
    /// renaming the attribute to a non-loading `data-ohia-remote-href` /
    /// `data-ohia-remote-xlink-href` so the browser never fetches it. Both forms
    /// are checked because SVG accepts either. `onBlocked` fires once per blocked
    /// `<image>` (even if it carried both attribute forms).
    nonisolated private static func neutralizeSVGImageHrefs(in html: String, onBlocked: () -> Void) -> String {
        guard let svgImageTagRegex else { return html }
        let tags = svgImageTagRegex.matches(in: html, range: fullRange(html))
        guard tags.isEmpty == false else { return html }

        var result = html
        for tagMatch in tags.reversed() {
            guard let tagRange = Range(tagMatch.range, in: result) else { continue }
            let tag = String(result[tagRange])
            let bareHrefRemote = attributeValue(in: tag, regex: bareHrefAttrRegex).map(isRemote) ?? false
            let xlinkRemote = attributeValue(in: tag, regex: xlinkHrefAttrRegex).map(isRemote) ?? false
            guard bareHrefRemote || xlinkRemote else { continue }

            var rewritten = tag
            // Rename the namespaced form first: its attribute name contains the
            // bare `href`, so renaming `href` first would corrupt `xlink:href`.
            // `xlink:href` renames by name (no overlap with other attrs); the
            // bare `href` renames via `bareHrefAttrRegex` so it can't touch a
            // remaining `xlink:href` substring.
            if xlinkRemote, let regex = attrRegex("xlink:href") {
                rewritten = regex.stringByReplacingMatches(
                    in: rewritten,
                    range: fullRange(rewritten),
                    withTemplate: "data-ohia-remote-xlink-href=$1"
                )
            }
            if bareHrefRemote, let bareHrefAttrRegex {
                rewritten = bareHrefAttrRegex.stringByReplacingMatches(
                    in: rewritten,
                    range: fullRange(rewritten),
                    withTemplate: "data-ohia-remote-href=$1"
                )
            }
            result.replaceSubrange(tagRange, with: rewritten)
            onBlocked()
        }
        return result
    }

    // MARK: - <source srcset> (inside <picture>)

    nonisolated private static let sourceTagRegex = makeRegex(#"(?is)<source\b[^>]*>"#)

    nonisolated private static func neutralizeSourceSrcset(in html: String) -> String {
        guard let sourceTagRegex else { return html }
        let tags = sourceTagRegex.matches(in: html, range: fullRange(html))
        guard tags.isEmpty == false else { return html }

        var result = html
        for tagMatch in tags.reversed() {
            guard let tagRange = Range(tagMatch.range, in: result) else { continue }
            let tag = String(result[tagRange])
            guard let value = attributeValue(in: tag, regex: srcsetAttrRegex),
                  srcsetReferencesRemote(value) else { continue }
            let rewritten = renameAttribute("srcset", to: "data-ohia-remote-srcset", inTag: tag)
            result.replaceSubrange(tagRange, with: rewritten)
        }
        return result
    }

    // MARK: - CSS url(...) (inline style attrs and <style> blocks)

    nonisolated private static let cssRemoteURLRegex = makeRegex(
        #"(?i)url\(\s*(['"]?)\s*(?:https?:)?//[^)'"]*\1\s*\)"#
    )

    nonisolated private static func neutralizeCSSURLs(in html: String) -> String {
        guard let cssRemoteURLRegex else { return html }
        return cssRemoteURLRegex.stringByReplacingMatches(
            in: html,
            range: fullRange(html),
            withTemplate: "url('\(transparentPixel)')"
        )
    }

    // MARK: - background="..." table attribute

    nonisolated private static let backgroundAttrRegex = makeRegex(
        #"(?i)\bbackground\s*=\s*("(?:https?:)?//[^"]*"|'(?:https?:)?//[^']*'|(?:https?:)?//[^\s>]+)"#
    )

    nonisolated private static func neutralizeBackgroundAttributes(in html: String) -> String {
        guard let backgroundAttrRegex else { return html }
        return backgroundAttrRegex.stringByReplacingMatches(
            in: html,
            range: fullRange(html),
            withTemplate: #"data-ohia-remote-background=$1"#
        )
    }

    // MARK: - remote stylesheet <link>

    nonisolated private static let linkTagRegex = makeRegex(#"(?is)<link\b[^>]*>"#)
    nonisolated private static let hrefAttrRegex = attrRegex("href")

    nonisolated private static func removeRemoteStylesheets(in html: String) -> String {
        guard let linkTagRegex else { return html }
        let tags = linkTagRegex.matches(in: html, range: fullRange(html))
        guard tags.isEmpty == false else { return html }

        // Match `<link>` tags carrying both rel=stylesheet and a remote href in
        // any attribute order (HTML imposes none), so an `href`-first tag can't
        // slip a remote stylesheet through.
        var result = html
        for tagMatch in tags.reversed() {
            guard let tagRange = Range(tagMatch.range, in: result) else { continue }
            let tag = String(result[tagRange])
            let isStylesheet = tag.range(
                of: #"(?i)\brel\s*=\s*['"]?stylesheet"#,
                options: .regularExpression
            ) != nil
            guard isStylesheet,
                  let href = attributeValue(in: tag, regex: hrefAttrRegex),
                  isRemote(href) else { continue }
            result.replaceSubrange(tagRange, with: "")
        }
        return result
    }

    // MARK: - placeholder fill

    nonisolated private static func prependingPlaceholderStyle(to html: String, hex: String) -> String {
        // An attribute selector targets exactly the blocked images, so no class
        // bookkeeping is needed. Sized images render a neutral box; 1×1 tracking
        // pixels stay 1px (invisible).
        let style = """
        <style>img[data-ohia-remote-src]{background-color:\(hex);}</style>
        """
        return style + html
    }

    // MARK: - attribute helpers

    nonisolated private static func attributeValue(in tag: String, regex: NSRegularExpression?) -> String? {
        guard let regex,
              let match = regex.firstMatch(in: tag, range: fullRange(tag)),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: tag) else {
            return nil
        }
        return unquote(String(tag[valueRange]))
    }

    nonisolated private static func replaceAttribute(_ attr: String, in tag: String, with newValue: String) -> String {
        guard let regex = attrRegex(attr) else { return tag }
        return regex.stringByReplacingMatches(
            in: tag,
            range: fullRange(tag),
            withTemplate: "\(attr)=\"\(escapeTemplate(newValue))\""
        )
    }

    nonisolated private static func renameAttribute(_ attr: String, to newName: String, inTag tag: String) -> String {
        guard let regex = attrRegex(attr) else { return tag }
        // Keep the original value, just change the attribute name so the
        // browser ignores it.
        return regex.stringByReplacingMatches(
            in: tag,
            range: fullRange(tag),
            withTemplate: "\(newName)=$1"
        )
    }

    // Matches the opening `<tagname` of any element so a new attribute can be
    // spliced in right after the tag name (e.g. `<img`, `<input`), without
    // disturbing the closing `>`.
    nonisolated private static let openingTagNameRegex = makeRegex(#"(?i)^<[a-z][a-z0-9]*"#)

    nonisolated private static func insertAttribute(_ attr: String, value: String, intoTag tag: String) -> String {
        // Insert right after the opening `<tagname` (e.g. `<img`, `<input`) so
        // we don't disturb the closing `>`.
        guard let openingTagNameRegex,
              let match = openingTagNameRegex.firstMatch(in: tag, range: fullRange(tag)),
              let openRange = Range(match.range, in: tag) else { return tag }
        let escaped = value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        var result = tag
        result.insert(contentsOf: " \(attr)=\"\(escaped)\"", at: openRange.upperBound)
        return result
    }

    // MARK: - classification

    nonisolated private static func isRemote(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("http://")
            || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("//")
    }

    nonisolated private static func srcsetReferencesRemote(_ value: String) -> Bool {
        value
            .split(separator: ",")
            .contains { candidate in
                isRemote(candidate.trimmingCharacters(in: .whitespaces))
            }
    }

    nonisolated private static func firstRemoteImageRange(in html: String) -> Range<String.Index>? {
        guard let imgTagRegex else { return nil }
        for match in imgTagRegex.matches(in: html, range: fullRange(html)) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            if knownReactionEmoji(in: tag) != nil { continue }
            if let src = attributeValue(in: tag, regex: srcAttrRegex), isRemote(src) {
                return tagRange
            }
            if let srcset = attributeValue(in: tag, regex: srcsetAttrRegex),
               srcsetReferencesRemote(srcset) {
                return tagRange
            }
        }
        return nil
    }

    /// True when the body has an `<input type="image">` with a remote `src`.
    nonisolated private static func containsRemoteInputImage(in html: String) -> Bool {
        guard let inputTagRegex else { return false }
        for match in inputTagRegex.matches(in: html, range: fullRange(html)) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let type = attributeValue(in: tag, regex: typeAttrRegex),
                  type.caseInsensitiveCompare("image") == .orderedSame,
                  let src = attributeValue(in: tag, regex: srcAttrRegex),
                  isRemote(src) else { continue }
            return true
        }
        return false
    }

    /// True when the body has an SVG `<image>` with a remote `href`/`xlink:href`.
    nonisolated private static func containsRemoteSVGImage(in html: String) -> Bool {
        guard let svgImageTagRegex else { return false }
        for match in svgImageTagRegex.matches(in: html, range: fullRange(html)) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            if let href = attributeValue(in: tag, regex: bareHrefAttrRegex), isRemote(href) {
                return true
            }
            if let xlink = attributeValue(in: tag, regex: xlinkHrefAttrRegex), isRemote(xlink) {
                return true
            }
        }
        return false
    }

    // MARK: - primitives

    nonisolated private static func unquote(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2,
           let first = trimmed.first, let last = trimmed.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed
    }

    nonisolated private static func escapeTemplate(_ value: String) -> String {
        // `$` is the only metacharacter in a replacement template.
        value.replacingOccurrences(of: "$", with: "\\$")
    }

    nonisolated private static func fullRange(_ string: String) -> NSRange {
        NSRange(string.startIndex..<string.endIndex, in: string)
    }

    nonisolated private static func makeRegex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }
}
