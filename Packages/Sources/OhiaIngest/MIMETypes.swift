import Foundation
import OhiaCore

/// A single RFC 5322 header: name/value pair.
public struct Header: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A decoded attachment extracted from a MIME message.
public struct ParsedAttachment: Sendable {
    public let filename: String
    public let mimeType: String
    public let data: Data
    public let contentId: String?
    /// `true` when the source MIME part carried `Content-Disposition: inline`.
    /// Distinguishes embedded body images (`<img src="cid:...">`) from
    /// genuine attachments — the locked-node overlay suppresses inline-and-
    /// referenced parts so the same image isn't shown twice. Defaults to
    /// `false` when the header was absent or said `attachment`.
    public let dispositionIsInline: Bool

    public init(
        filename: String,
        mimeType: String,
        data: Data,
        contentId: String?,
        dispositionIsInline: Bool = false
    ) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentId = contentId
        self.dispositionIsInline = dispositionIsInline
    }
}

/// The result of parsing a raw RFC 5322 email message.
public struct ParsedEmail: Sendable {
    public let headers: [Header]
    public let textBody: String?
    public let htmlBody: String?
    public let attachments: [ParsedAttachment]
    public let rawData: Data

    public init(
        headers: [Header],
        textBody: String?,
        htmlBody: String?,
        attachments: [ParsedAttachment],
        rawData: Data
    ) {
        self.headers = headers
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
        self.rawData = rawData
    }

    /// Case-insensitive header lookup. Returns the first matching header's value.
    public func headerValue(for name: String) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.name.lowercased() == lowered }?.value
    }

    /// `Subject` decoded through RFC 2047 — non-ASCII subjects (Japanese,
    /// Cyrillic, CJK, accented Latin, etc.) arrive on the wire as encoded
    /// words and must be unwrapped before storage so the persisted value
    /// is human-readable across every UI surface.
    public var subject: String? {
        headerValue(for: "Subject").map(MIMEHeaderDecoder.decodeEncodedWords)
    }

    /// `From` with any encoded-word display-name fragment decoded. Address
    /// portions are unaffected — RFC 2047 encoded-words are illegal inside
    /// the angle-bracketed addr-spec, only legal in the display-name phrase.
    public var from: String? {
        headerValue(for: "From").map(MIMEHeaderDecoder.decodeEncodedWords)
    }
    public var replyTo: String? {
        headerValue(for: "Reply-To").map(MIMEHeaderDecoder.decodeEncodedWords)
    }
    public var to: String? {
        headerValue(for: "To").map(MIMEHeaderDecoder.decodeEncodedWords)
    }
    public var cc: String? {
        headerValue(for: "Cc").map(MIMEHeaderDecoder.decodeEncodedWords)
    }
    public var bcc: String? {
        headerValue(for: "Bcc").map(MIMEHeaderDecoder.decodeEncodedWords)
    }
    public var date: String? { headerValue(for: "Date") }
    public var messageId: String? { headerValue(for: "Message-ID") }
    public var inReplyTo: String? { headerValue(for: "In-Reply-To") }
    public var references: String? { headerValue(for: "References") }
    public var contentType: String? { headerValue(for: "Content-Type") }

    public var summarizableBodyText: String? {
        if let textBody = Self.nonEmptyBody(textBody) {
            return textBody
        }
        guard let htmlBody = Self.nonEmptyBody(htmlBody) else {
            return nil
        }
        return Self.htmlToPlainText(htmlBody)
    }

    private static func nonEmptyBody(_ value: String?) -> String? {
        guard let value,
              value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return value
    }

    private static func htmlToPlainText(_ html: String) -> String? {
        // Keep ingestion/backfills off NSAttributedString's HTML importer:
        // arbitrary email HTML can make synchronous WebKit/UIFoundation calls.
        let quoteStartMarker = "\u{E000}OHIA_BLOCKQUOTE_START\u{E001}"
        let quoteEndMarker = "\u{E000}OHIA_BLOCKQUOTE_END\u{E001}"
        let boundedHTML = String(html.prefix(512 * 1024))
        let withoutScripts = boundedHTML.replacingOccurrences(
            of: "(?is)<(script|style)[^>]*>.*?</\\1>",
            with: " ",
            options: .regularExpression
        )
        let normalizedTagSpacing = withoutScripts.replacingOccurrences(
            of: ">\\s+<",
            with: "> <",
            options: .regularExpression
        )
        let withQuoteMarkers = normalizedTagSpacing
            .replacingOccurrences(
                of: "(?i)<blockquote\\b[^>]*>",
                with: "\n\(quoteStartMarker)\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?i)</blockquote\\s*>",
                with: "\n\(quoteEndMarker)\n",
                options: .regularExpression
            )
        let withStructuralBreaks = withQuoteMarkers
            .replacingOccurrences(
                of: "(?i)<br\\s*/?>",
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?i)</(p|div|li|tr|table|h[1-6]|blockquote|pre|section|article)\\s*>",
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?i)<hr\\b[^>]*>",
                with: "\n",
                options: .regularExpression
            )
        let withoutTags = withStructuralBreaks.replacingOccurrences(
            of: "(?s)<[^>]+>",
            with: "",
            options: .regularExpression
        )
        let decoded = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        let normalized = decoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(
                of: "[\\t ]+",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: " *\\n *",
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\\n{3,}",
                with: "\n\n",
                options: .regularExpression
            )
        let markedQuotes = markHTMLBlockquoteLines(
            normalized,
            startMarker: quoteStartMarker,
            endMarker: quoteEndMarker
        )
        let trimmed = markedQuotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func markHTMLBlockquoteLines(
        _ text: String,
        startMarker: String,
        endMarker: String
    ) -> String {
        var quoteDepth = 0
        var output: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line == startMarker {
                quoteDepth += 1
                continue
            }
            if line == endMarker {
                quoteDepth = max(quoteDepth - 1, 0)
                continue
            }
            if quoteDepth > 0, line.isEmpty == false {
                output.append(String(repeating: ">", count: quoteDepth) + " " + line)
            } else {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }
}

/// Internal type for recursive MIME part parsing.
struct MIMEPart {
    let headers: [Header]
    let body: Data
    let subparts: [MIMEPart]

    var contentType: String? {
        let lowered = "content-type"
        return headers.first { $0.name.lowercased() == lowered }?.value
    }

    var contentTransferEncoding: String? {
        let lowered = "content-transfer-encoding"
        return headers.first { $0.name.lowercased() == lowered }?.value
    }

    var contentDisposition: String? {
        let lowered = "content-disposition"
        return headers.first { $0.name.lowercased() == lowered }?.value
    }
}
