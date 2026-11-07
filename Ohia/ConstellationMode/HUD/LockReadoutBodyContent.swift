import Foundation
import OhiaIngest

nonisolated enum LockReadoutBodyFormat: Sendable, Equatable {
    case plainText
    case html
}

nonisolated struct LockReadoutInlineAttachment: Sendable {
    let contentId: String
    let mimeType: String
    let data: Data

    var dataURLString: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    static func normalizedContentID(_ value: String) -> String {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased().hasPrefix("cid:") {
            normalized.removeFirst(4)
        }
        if normalized.hasPrefix("<"), normalized.hasSuffix(">"), normalized.count >= 2 {
            normalized.removeFirst()
            normalized.removeLast()
        }
        if let decoded = normalized.removingPercentEncoding {
            normalized = decoded
        }
        return normalized
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'").union(.whitespacesAndNewlines))
            .lowercased()
    }
}

nonisolated struct LockReadoutBodySource: Sendable {
    let text: String
    let format: LockReadoutBodyFormat
    let baseURL: URL?
    let inlineAttachments: [String: LockReadoutInlineAttachment]

    init(
        text: String,
        format: LockReadoutBodyFormat,
        baseURL: URL? = nil,
        inlineAttachments: [String: LockReadoutInlineAttachment] = [:]
    ) {
        self.text = text
        self.format = format
        self.baseURL = baseURL
        self.inlineAttachments = inlineAttachments
    }
}

nonisolated struct LockReadoutHTMLDocument: Sendable, Equatable {
    let html: String
    let baseURL: URL?
}

nonisolated enum LockReadoutBodyLoadResult: Sendable {
    case loaded(LockReadoutBodySource)
    case missing
    case failed
}

nonisolated struct LockReadoutBodyContent {
    let attributedText: AttributedString?
    let plainText: String
    let htmlDocument: LockReadoutHTMLDocument?
    let format: LockReadoutBodyFormat

    var isEmpty: Bool {
        if case .html = format, let htmlDocument {
            return htmlDocument.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(source: LockReadoutBodySource) {
        format = source.format
        switch source.format {
        case .plainText:
            attributedText = nil
            htmlDocument = nil
            plainText = source.text
        case .html:
            htmlDocument = LockReadoutHTMLDocument(
                html: Self.htmlForWebDisplay(
                    source.text,
                    inlineAttachments: source.inlineAttachments
                ),
                baseURL: source.baseURL
            )
            attributedText = nil
            plainText = Self.plainTextFallback(fromHTML: source.text)
        }
    }

    private static func htmlForWebDisplay(
        _ html: String,
        inlineAttachments: [String: LockReadoutInlineAttachment]
    ) -> String {
        replacingCIDReferences(in: html, inlineAttachments: inlineAttachments)
    }

    private static func replacingCIDReferences(
        in html: String,
        inlineAttachments: [String: LockReadoutInlineAttachment]
    ) -> String {
        guard html.range(of: "cid:", options: .caseInsensitive) != nil,
              inlineAttachments.isEmpty == false,
              let regex = try? NSRegularExpression(pattern: #"(?i)cid:([^"'\s>)]+)"#) else {
            return html
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsRange)
        guard matches.isEmpty == false else { return html }

        var rewritten = html
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let fullRange = Range(match.range(at: 0), in: rewritten),
                  let idRange = Range(match.range(at: 1), in: rewritten) else {
                continue
            }

            let contentId = LockReadoutInlineAttachment.normalizedContentID(String(rewritten[idRange]))
            guard let attachment = inlineAttachments[contentId] else { continue }
            rewritten.replaceSubrange(fullRange, with: attachment.dataURLString)
        }
        return rewritten
    }

    private static func plainTextFallback(fromHTML html: String) -> String {
        let withBreaks = htmlForTextDisplay(html)
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</p\\s*>", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</div\\s*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</tr\\s*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</li\\s*>", with: "\n", options: .regularExpression)
        let stripped = withBreaks.replacingOccurrences(
            of: "(?s)<[^>]+>",
            with: "",
            options: .regularExpression
        )
        return decodeHTMLEntities(stripped)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&"),
              let regex = try? NSRegularExpression(pattern: #"&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z][A-Za-z0-9]+);"#) else {
            return text
        }

        let matches = regex.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
        guard matches.isEmpty == false else { return text }

        var decoded = ""
        var cursor = text.startIndex
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: text),
                  let entityRange = Range(match.range(at: 1), in: text),
                  let replacement = decodedHTMLEntity(String(text[entityRange])) else {
                continue
            }

            decoded.append(contentsOf: text[cursor..<fullRange.lowerBound])
            decoded.append(replacement)
            cursor = fullRange.upperBound
        }
        decoded.append(contentsOf: text[cursor...])
        return decoded
    }

    private static func decodedHTMLEntity(_ entity: String) -> String? {
        let lowercased = entity.lowercased()
        if lowercased.hasPrefix("#x") {
            return UInt32(lowercased.dropFirst(2), radix: 16)
                .flatMap(UnicodeScalar.init)
                .map(String.init)
        }
        if lowercased.hasPrefix("#") {
            return UInt32(lowercased.dropFirst(), radix: 10)
                .flatMap(UnicodeScalar.init)
                .map(String.init)
        }

        switch lowercased {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "ndash": return "\u{2013}"
        case "mdash": return "\u{2014}"
        case "hellip": return "\u{2026}"
        case "copy": return "\u{00A9}"
        case "reg": return "\u{00AE}"
        default: return nil
        }
    }

    private static func htmlForTextDisplay(_ html: String) -> String {
        html
            .replacingOccurrences(
                of: "(?is)<script\\b[^>]*>.*?</script>",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?is)<style\\b[^>]*>.*?</style>",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?is)<link\\b[^>]*>",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?is)<img\\b[^>]*>",
                with: "",
                options: .regularExpression
            )
    }
}
