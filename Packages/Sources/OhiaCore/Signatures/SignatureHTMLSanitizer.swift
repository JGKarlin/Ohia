import Foundation

/// Deterministic allowlist pass over signature HTML.
///
/// Runs on two inputs: raw model output (untrusted) and the fragment the
/// Cocoa writer produces after a hand-edit (trusted but re-checked for
/// defense). The canonical stored form is always a **body fragment with
/// inline styles** — no doctype, no `<head>`, no class-based CSS — so a
/// slot's HTML can be concatenated into a larger HTML body and survives
/// clients that strip `<style>` blocks.
///
/// Allowed elements: `p, br, a, b, strong, i, em, u, span, img` plus the
/// presentation-table subset `table, tbody, tr, td` (`div` is normalized
/// to `p`). Tables are the one email layout primitive that both hostile mail
/// clients and AppKit's attributed-string editor preserve, so app-owned
/// signature templates use them for real rails, frames, bands, and split
/// layouts. Every attribute and style declaration is still reconstructed
/// from a narrow allowlist. Other tags are dropped while their inner text is
/// kept, except `script/style/head/title`, whose content is removed wholesale.
public enum SignatureHTMLSanitizer {

    /// Which link targets survive. `mailto:` and `tel:` always pass; an
    /// `http(s)` link passes only when it matches one of the vetted URLs
    /// (the contact form's website field).
    public struct LinkPolicy: Sendable {
        public var allowedHTTPURLs: [String]

        public init(allowedHTTPURLs: [String] = []) {
            self.allowedHTTPURLs = allowedHTTPURLs
        }

        func permits(_ href: String) -> Bool {
            let value = href.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = value.lowercased()
            if lower.hasPrefix("mailto:") || lower.hasPrefix("tel:") { return true }
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
                return false
            }
            let normalized = Self.normalize(value)
            return allowedHTTPURLs.contains { Self.normalize($0) == normalized }
        }

        static func normalize(_ url: String) -> String {
            var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for prefix in ["https://", "http://"] where s.hasPrefix(prefix) {
                s.removeFirst(prefix.count)
            }
            if s.hasPrefix("www.") { s.removeFirst(4) }
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
    }

    private static let allowedTags: Set<String> = [
        "p", "br", "a", "b", "strong", "i", "em", "u", "span", "img",
        "table", "tbody", "tr", "td"
    ]
    private static let layoutTableTags: Set<String> = [
        "table", "tbody", "tr", "td"
    ]
    private static let contentStrippedTags: Set<String> = [
        "script", "style", "head", "title"
    ]
    /// Disallowed tags that are block-level in the source markup. Models
    /// love table/list layouts for signatures; dropping those tags without
    /// a separator would glue adjacent lines together ("NameTitleOrg"), so
    /// each dropped closing tag leaves a `<br>` in its place.
    private static let droppedBlockTags: Set<String> = [
        "thead", "tfoot", "caption",
        "ul", "ol", "li", "dl", "dt", "dd",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre", "address", "center",
        "section", "article", "header", "footer", "main", "nav", "aside",
        "figure", "figcaption", "form", "fieldset"
    ]
    /// Disallowed table cells: adjacent cells on one row separate with a
    /// space, not a line break.
    private static let droppedCellTags: Set<String> = ["th"]
    /// Dropped tags whose *opening* also starts a new line: HTML5 permits
    /// omitting their end tags (`<li>A<li>B`), so the close-tag break
    /// alone would glue those lines.
    private static let droppedLineStartTags: Set<String> = ["li", "dt", "dd"]
    /// Inline style properties that survive sanitization. Matching is by
    /// exact property name, so longhands must be listed individually — the
    /// `border-left` + `padding-left` pair (the standard accent-rule idiom
    /// in HTML signatures) needs both halves present or the rule renders
    /// with its text jammed against it.
    ///
    /// Deliberately absent: `background-image` and friends are unreachable
    /// anyway because `filterStyle` rejects any value containing `url(`;
    /// positioning, float, and display stay out because this fragment must
    /// survive the editor's Cocoa round trip and hostile mail clients.
    private static let allowedCSSProperties: Set<String> = [
        "color", "font-family", "font-size", "font-weight", "font-style",
        "text-decoration", "margin", "text-align",
        "border", "border-left", "border-right", "border-top", "border-bottom",
        "border-style", "border-width", "border-color",
        "padding", "padding-left", "padding-right", "padding-top", "padding-bottom",
        "background-color", "line-height"
    ]

    /// Sanitizes `html` into the canonical fragment form.
    ///
    /// - Parameters:
    ///   - assets: the images this signature legitimately owns. `<img>`
    ///     tags whose `src` is not an `ohia-sig://` token for one of these
    ///     assets are dropped; surviving tags get the token rewritten to
    ///     `ownerID` and their deterministic display size stamped.
    ///   - ownerID: the slot or design-session id the tokens must carry.
    ///   - linkPolicy: which `href` targets survive on `<a>`.
    ///   - allowLayoutTables: true for app-owned/editor HTML; model output
    ///     passes false so arbitrary tables flatten before privacy scrubbing.
    public static func sanitize(
        _ html: String,
        assets: [SignatureImageAsset],
        ownerID: UUID,
        linkPolicy: LinkPolicy,
        allowLayoutTables: Bool = true
    ) -> String {
        var work = html

        // Comments, doctype, then whole elements whose content must die.
        work = replaceAll(in: work, pattern: "<!--.*?-->", with: "")
        work = replaceAll(in: work, pattern: "<!DOCTYPE[^>]*>", with: "")
        for tag in contentStrippedTags {
            work = replaceAll(
                in: work,
                pattern: "<\(tag)\\b[^>]*>.*?</\(tag)\\s*>",
                with: ""
            )
        }

        let assetsByID = Dictionary(
            uniqueKeysWithValues: assets.map { ($0.id, $0) }
        )

        var out = ""
        // Per the HTML spec, `< ` followed by whitespace is text, not a
        // tag — the name must follow `<` (or `</`) immediately.
        let tagRegex = try! NSRegularExpression(
            pattern: "<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>",
            options: [.dotMatchesLineSeparators]
        )
        let nsWork = work as NSString

        // Anchors whose target the policy rejected open as <span>; this
        // stack remembers, per open <a>, which closing form matches.
        var anchorClosers: [String] = []

        var searchLocation = 0
        while searchLocation < nsWork.length {
            let range = NSRange(location: searchLocation, length: nsWork.length - searchLocation)
            guard let match = tagRegex.firstMatch(in: work, options: [], range: range) else {
                break
            }
            // Text before the tag passes through with stray brackets escaped.
            let textRange = NSRange(
                location: searchLocation,
                length: match.range.location - searchLocation
            )
            out += sanitizeText(nsWork.substring(with: textRange))

            let isClosing = nsWork.substring(with: match.range(at: 1)) == "/"
            var name = nsWork.substring(with: match.range(at: 2)).lowercased()
            let attrText = nsWork.substring(with: match.range(at: 3))
            if name == "div" { name = "p" }

            let isAllowed = allowedTags.contains(name)
                && (allowLayoutTables || !layoutTableTags.contains(name))
            if isAllowed {
                if isClosing {
                    if name == "a" {
                        out += anchorClosers.popLast() ?? "</span>"
                    } else if name != "br" && name != "img" {
                        out += "</\(name)>"
                    }
                } else if name == "a" {
                    let opening = openingTag(
                        name: name,
                        attrText: attrText,
                        assetsByID: assetsByID,
                        ownerID: ownerID,
                        linkPolicy: linkPolicy
                    )
                    anchorClosers.append(opening.hasPrefix("<a") ? "</a>" : "</span>")
                    out += opening
                } else {
                    out += openingTag(
                        name: name,
                        attrText: attrText,
                        assetsByID: assetsByID,
                        ownerID: ownerID,
                        linkPolicy: linkPolicy
                    )
                }
            } else if name == "hr", !isClosing {
                appendBlockBreak(to: &out)
            } else if !allowLayoutTables, name == "td" {
                appendCellGap(to: &out)
            } else if !allowLayoutTables,
                      ["table", "tbody", "tr"].contains(name),
                      isClosing {
                appendBlockBreak(to: &out)
            } else if !allowLayoutTables, name == "tr", !isClosing {
                appendBlockBreak(to: &out)
            } else if droppedCellTags.contains(name) {
                // Opening and closing both gap: `<td>A<td>B` omits the
                // end tag, and the suffix guards collapse the pair.
                appendCellGap(to: &out)
            } else if droppedBlockTags.contains(name), isClosing {
                appendBlockBreak(to: &out)
            } else if droppedLineStartTags.contains(name), !isClosing {
                appendBlockBreak(to: &out)
            }
            // Other disallowed tags vanish; their inner text arrives via
            // the text passthrough on subsequent iterations.

            searchLocation = match.range.location + match.range.length
        }
        if searchLocation < nsWork.length {
            out += sanitizeText(nsWork.substring(from: searchLocation))
        }

        var result = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("<br>") {
            result.removeLast("<br>".count)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// Appends a `<br>` at a dropped block boundary. Nested closes
    /// (`</td></tr></table>`) collapse to a single break; nothing is
    /// emitted before the first content.
    private static func appendBlockBreak(to out: inout String) {
        while let last = out.last, last == " " || last == "\n" || last == "\t" || last == "\r" {
            out.removeLast()
        }
        guard !out.isEmpty, !out.hasSuffix("<br>") else { return }
        out += "<br>"
    }

    private static func appendCellGap(to out: inout String) {
        guard let last = out.last, !last.isWhitespace, !out.hasSuffix("<br>") else { return }
        out += " "
    }

    // MARK: - Tag reconstruction

    private static func openingTag(
        name: String,
        attrText: String,
        assetsByID: [UUID: SignatureImageAsset],
        ownerID: UUID,
        linkPolicy: LinkPolicy
    ) -> String {
        let attrs = parseAttributes(attrText)
        switch name {
        case "br":
            return "<br>"
        case "a":
            guard let href = attrs["href"], linkPolicy.permits(href) else {
                // Rejected target: the anchor degrades to a span so its
                // inner text survives without a link.
                return "<span>"
            }
            return "<a href=\"\(escapeAttribute(href))\">"
        case "img":
            guard let src = attrs["src"],
                  let token = SignatureImageToken.parse(src),
                  let asset = assetsByID[token.assetID] else {
                return ""
            }
            var tag = "<img src=\"\(SignatureImageToken.url(ownerID: ownerID, assetID: asset.id))\""
            if let width = asset.imageType.stampedWidth {
                tag += " width=\"\(width)\""
            }
            if let height = asset.imageType.stampedHeight {
                tag += " height=\"\(height)\""
            }
            if let alt = attrs["alt"], !alt.isEmpty, alt.count <= 120 {
                tag += " alt=\"\(escapeAttribute(alt))\""
            }
            tag += ">"
            return tag
        case "p", "span", "table", "tbody", "tr", "td":
            var kept: [String] = []
            if name == "table" {
                if attrs["role"]?.lowercased() == "presentation" {
                    kept.append("role=\"presentation\"")
                }
                for key in ["cellspacing", "cellpadding"] {
                    if let value = attrs[key], isBoundedInteger(value, range: 0...32) {
                        kept.append("\(key)=\"\(value)\"")
                    }
                }
                if attrs["width"] == "100%" || attrs["width"] == "100.0%" {
                    kept.append("width=\"100%\"")
                }
            } else if name == "td" {
                if let value = attrs["valign"]?.lowercased(),
                   ["top", "middle", "bottom"].contains(value) {
                    kept.append("valign=\"\(value)\"")
                }
                if let value = attrs["colspan"], isBoundedInteger(value, range: 1...8) {
                    kept.append("colspan=\"\(value)\"")
                }
            }
            if let style = attrs["style"] {
                let filtered = filterStyle(style)
                if !filtered.isEmpty {
                    kept.append("style=\"\(escapeAttribute(filtered))\"")
                }
            }
            return kept.isEmpty
                ? "<\(name)>"
                : "<\(name) \(kept.joined(separator: " "))>"
        default: // b, strong, i, em, u
            return "<\(name)>"
        }
    }

    // MARK: - Attribute parsing

    private static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let regex = try! NSRegularExpression(
            pattern: "([a-zA-Z-]+)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        )
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let value: String
            if match.range(at: 3).location != NSNotFound {
                value = ns.substring(with: match.range(at: 3))
            } else if match.range(at: 4).location != NSNotFound {
                value = ns.substring(with: match.range(at: 4))
            } else if match.range(at: 5).location != NSNotFound {
                value = ns.substring(with: match.range(at: 5))
            } else {
                continue
            }
            result[key] = decodeBasicEntities(value)
        }
        return result
    }

    private static func filterStyle(_ style: String) -> String {
        style
            .split(separator: ";")
            .compactMap { declaration -> String? in
                let parts = declaration.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let property = parts[0]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard allowedCSSProperties.contains(property),
                      !value.isEmpty,
                      !value.lowercased().contains("url(") else { return nil }
                return "\(property): \(value)"
            }
            .joined(separator: "; ")
    }

    private static func isBoundedInteger(
        _ value: String,
        range: ClosedRange<Int>
    ) -> Bool {
        guard value.allSatisfy(\.isNumber), let number = Int(value) else {
            return false
        }
        return range.contains(number)
    }

    // MARK: - Text helpers

    private static func replaceAll(
        in text: String, pattern: String, with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: replacement
        )
    }

    private static func escapeStrayBrackets(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Every tag name this sanitizer recognizes, in any role. A `<` followed
    /// immediately by one of these begins a tag; a `<` followed by anything
    /// else is ordinary text.
    private static let recognizedTagNames: Set<String> = allowedTags
        .union(contentStrippedTags)
        .union(droppedBlockTags)
        .union(droppedCellTags)
        .union(droppedLineStartTags)
        .union(["div", "hr", "font", "tt", "small", "big", "strike", "s"])

    /// Recognized tags that end their line. A malformed one still has to
    /// leave its break behind.
    private static let blockLevelTagNames: Set<String> = droppedBlockTags
        .union(droppedCellTags)
        .union(droppedLineStartTags)
        .union(["p", "div", "br", "hr"])

    /// Sanitizes the run of text between two well-formed tags.
    ///
    /// A `<` that opens a *recognized* tag name but never closes is a
    /// malformed tag — a small local model dropping the `">` of a style
    /// attribute is the common case. Escaping it would print raw CSS into
    /// the user's signature (`<p style="font-family:Arial…` as visible
    /// text), so the malformed tag is dropped through to the next `<`
    /// instead: the styling is lost, the content survives, and nothing
    /// leaks.
    ///
    /// Gating on recognized names is what keeps ordinary prose safe —
    /// "a <b then c" is unlucky, but "x <y z" is escaped as the text it is.
    static func sanitizeText(_ fragment: String) -> String {
        guard fragment.contains("<"),
              let opener = try? NSRegularExpression(pattern: "</?([a-zA-Z][a-zA-Z0-9]*)")
        else {
            return escapeStrayBrackets(fragment)
        }
        let ns = fragment as NSString
        var out = ""
        var location = 0
        while location < ns.length {
            let range = NSRange(location: location, length: ns.length - location)
            guard let match = opener.firstMatch(in: fragment, options: [], range: range) else {
                out += escapeStrayBrackets(ns.substring(from: location))
                return out
            }
            out += escapeStrayBrackets(ns.substring(
                with: NSRange(location: location, length: match.range.location - location)
            ))
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            guard recognizedTagNames.contains(name) else {
                // Not a tag at all — the "<" is literal text.
                out += "&lt;"
                location = match.range.location + 1
                continue
            }
            // A malformed tag: drop it and its unterminated attribute run.
            // A block-level one still ends its line, or the text it was
            // wrapping runs into the next line ("MorganProfessor") — the
            // same reason `droppedBlockTags` leaves a break behind.
            if blockLevelTagNames.contains(name) {
                appendBlockBreak(to: &out)
            }
            let after = match.range.location + match.range.length
            let next = ns.range(
                of: "<", range: NSRange(location: after, length: ns.length - after)
            )
            location = next.location == NSNotFound ? ns.length : next.location
        }
        return out
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func decodeBasicEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
