import Foundation
import UniformTypeIdentifiers
import CryptoKit

public enum MessageBuilder {
    /// An image emitted as a `multipart/related` inline part that the HTML
    /// body references via `cid:<contentID>`. Ignored when the envelope
    /// carries no HTML body — inline parts exist only relative to one.
    public struct InlineImage: Sendable, Equatable {
        public var path: String        // local file path
        public var contentID: String   // without angle brackets
        public var mimeType: String

        public init(path: String, contentID: String, mimeType: String) {
            self.path = path
            self.contentID = contentID
            self.mimeType = mimeType
        }
    }

    public struct Envelope: Sendable {
        public var from: EmailAddress
        public var replyTo: EmailAddress?
        public var to: [EmailAddress]
        public var cc: [EmailAddress]
        public var bcc: [EmailAddress]
        public var subject: String
        public var messageID: String          // with < >
        public var inReplyTo: String?
        public var referencesChain: String?
        public var plainBody: String
        public var htmlBody: String?
        public var attachments: [String]      // file paths
        public var inlineImages: [InlineImage]
        public var date: Date
        public var includeBccHeader: Bool

        public init(
            from: EmailAddress,
            replyTo: EmailAddress? = nil,
            to: [EmailAddress],
            cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
            subject: String, messageID: String,
            inReplyTo: String? = nil, referencesChain: String? = nil,
            plainBody: String, htmlBody: String? = nil,
            attachments: [String] = [],
            inlineImages: [InlineImage] = [],
            date: Date = Date(),
            includeBccHeader: Bool = false
        ) {
            self.from = from
            self.replyTo = replyTo
            self.to = to; self.cc = cc; self.bcc = bcc
            self.subject = subject; self.messageID = messageID
            self.inReplyTo = inReplyTo; self.referencesChain = referencesChain
            self.plainBody = plainBody; self.htmlBody = htmlBody
            self.attachments = attachments
            self.inlineImages = inlineImages
            self.date = date
            self.includeBccHeader = includeBccHeader
        }
    }

    public enum Error: Swift.Error {
        case attachmentNotReadable(String)
    }

    /// Generate an outgoing RFC 5322 Message-ID rooted in the sending
    /// account's own mail domain (e.g. `<uuid@gmail.com>`), not the local
    /// machine's hostname. Receiving MTAs — Gmail in particular — read a
    /// Message-ID domain that doesn't match the sender's mail domain,
    /// especially a non-routable `.local` mDNS hostname, as a strong
    /// unsolicited-mail signal and can silently 550-reject the send even
    /// though SPF/DKIM/DMARC all pass.
    public static func generateMessageID(fromAddress address: String) -> String {
        // Message-ID must be ASCII atext (RFC 5322) — use the punycode form
        // for IDN sender domains, never the Unicode `.domain`.
        let domain: String
        if let parsed = try? MailAddressParser.parseOne(address) {
            domain = MailAddressParser.punycode(parsed.domain)
        } else {
            domain = ProcessInfo.processInfo.hostName
            print("[Ohia] MessageBuilder: sender address did not parse; Message-ID falls back to the local hostname domain")
        }
        return "<\(UUID().uuidString)@\(domain)>"
    }

    public static func build(envelope env: Envelope) throws -> Data {
        var out = Data()
        let hasHTML = env.htmlBody != nil
        let hasAttachments = !env.attachments.isEmpty

        // Deterministic boundaries derived from the messageID, so retries produce
        // byte-identical payloads (spec §6.1 idempotency).
        let seed = Data(SHA256.hash(data: Data(env.messageID.utf8)))
        let seedHex = seed.prefix(16).map { String(format: "%02x", $0) }.joined()
        let mixedBoundary = "mix_\(seedHex)"
        let altBoundary = "alt_\(seedHex)"
        let relatedBoundary = "rel_\(seedHex)"

        // --- Headers
        appendHeader(&out, "Date", value: rfc5322Date(env.date))
        appendHeader(&out, "From", value: formatAddress(env.from))
        if let replyTo = env.replyTo {
            appendHeader(&out, "Reply-To", value: formatAddress(replyTo))
        }
        appendHeader(&out, "To", value: env.to.map(formatAddress).joined(separator: ", "))
        if !env.cc.isEmpty {
            appendHeader(&out, "Cc", value: env.cc.map(formatAddress).joined(separator: ", "))
        }
        // Sent mail must not expose Bcc. Drafts can opt in so other clients
        // preserve the in-progress recipient list.
        if env.includeBccHeader, !env.bcc.isEmpty {
            appendHeader(&out, "Bcc", value: env.bcc.map(formatAddress).joined(separator: ", "))
        }
        appendHeader(&out, "Subject", value: RFC2047.encodeWord(env.subject))
        appendHeader(&out, "Message-ID", value: env.messageID)
        if let inReplyTo = env.inReplyTo {
            appendHeader(&out, "In-Reply-To", value: inReplyTo)
        }
        if let refs = env.referencesChain {
            appendMessageIDListHeader(&out, "References", value: refs)
        }
        appendHeader(&out, "MIME-Version", value: "1.0")
        appendHeader(&out, "User-Agent", value: "Ohia/\(OhiaMail.version) (macOS)")

        if hasAttachments {
            appendHeader(&out, "Content-Type",
                         value: "multipart/mixed; boundary=\"\(mixedBoundary)\"")
            appendCRLF(&out)
            appendString(&out, "--\(mixedBoundary)\r\n")
            try appendAlternativePart(
                &out, env: env,
                altBoundary: altBoundary, relatedBoundary: relatedBoundary,
                hasHTML: hasHTML
            )
            for path in env.attachments {
                appendString(&out, "--\(mixedBoundary)\r\n")
                try appendAttachment(&out, path: path)
            }
            appendString(&out, "--\(mixedBoundary)--\r\n")
        } else if hasHTML {
            appendHeader(&out, "Content-Type",
                         value: "multipart/alternative; boundary=\"\(altBoundary)\"")
            appendCRLF(&out)
            try appendAlternativePartInner(
                &out, env: env,
                altBoundary: altBoundary, relatedBoundary: relatedBoundary
            )
        } else {
            appendHeader(&out, "Content-Type", value: "text/plain; charset=UTF-8")
            appendHeader(&out, "Content-Transfer-Encoding", value: "quoted-printable")
            appendCRLF(&out)
            appendString(&out, QuotedPrintable.encode(env.plainBody))
            appendCRLF(&out)
        }
        return out
    }

    // MARK: - Helpers

    private static func appendHeader(_ out: inout Data, _ name: String, value: String) {
        appendString(&out, "\(name): \(value)\r\n")
    }

    private static func appendMessageIDListHeader(
        _ out: inout Data,
        _ name: String,
        value: String
    ) {
        let messageIDs = value.split(whereSeparator: \Character.isWhitespace)
        guard messageIDs.isEmpty == false else {
            appendHeader(&out, name, value: value)
            return
        }

        let preferredLineLength = 78
        var line = "\(name):"
        for messageID in messageIDs {
            let candidate = "\(line) \(messageID)"
            if candidate.utf8.count > preferredLineLength {
                appendString(&out, "\(line)\r\n")
                line = " \(messageID)"
            } else {
                line = candidate
            }
        }
        appendString(&out, "\(line)\r\n")
    }

    private static func appendCRLF(_ out: inout Data) {
        out.append(contentsOf: [0x0D, 0x0A])
    }

    private static func appendString(_ out: inout Data, _ s: String) {
        out.append(s.data(using: .utf8)!)
    }

    private static func formatAddress(_ a: EmailAddress) -> String {
        if let display = a.displayName, !display.isEmpty {
            return "\(RFC2047.encodePhrase(display)) <\(a.asciiAddress)>"
        }
        return a.asciiAddress
    }

    private static func rfc5322Date(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return fmt.string(from: date)
    }

    private static func appendAlternativePart(
        _ out: inout Data, env: Envelope,
        altBoundary: String, relatedBoundary: String, hasHTML: Bool
    ) throws {
        if hasHTML {
            appendString(&out, "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n")
            try appendAlternativePartInner(
                &out, env: env,
                altBoundary: altBoundary, relatedBoundary: relatedBoundary
            )
        } else {
            appendString(&out, "Content-Type: text/plain; charset=UTF-8\r\n")
            appendString(&out, "Content-Transfer-Encoding: quoted-printable\r\n\r\n")
            appendString(&out, QuotedPrintable.encode(env.plainBody))
            appendCRLF(&out)
        }
    }

    private static func appendAlternativePartInner(
        _ out: inout Data, env: Envelope,
        altBoundary: String, relatedBoundary: String
    ) throws {
        // text/plain part
        appendString(&out, "--\(altBoundary)\r\n")
        appendString(&out, "Content-Type: text/plain; charset=UTF-8\r\n")
        appendString(&out, "Content-Transfer-Encoding: quoted-printable\r\n\r\n")
        appendString(&out, QuotedPrintable.encode(env.plainBody))
        appendCRLF(&out)
        // HTML alternative: a bare text/html leaf, or — when inline images
        // ride along — multipart/related(text/html, image parts) per
        // RFC 2387 (type parameter names the root part's media type).
        appendString(&out, "--\(altBoundary)\r\n")
        if env.inlineImages.isEmpty {
            appendHTMLLeaf(&out, env: env)
        } else {
            appendString(
                &out,
                "Content-Type: multipart/related; type=\"text/html\"; boundary=\"\(relatedBoundary)\"\r\n\r\n"
            )
            appendString(&out, "--\(relatedBoundary)\r\n")
            appendHTMLLeaf(&out, env: env)
            for image in env.inlineImages {
                appendString(&out, "--\(relatedBoundary)\r\n")
                try appendInlineImage(&out, image: image)
            }
            appendString(&out, "--\(relatedBoundary)--\r\n")
        }
        appendString(&out, "--\(altBoundary)--\r\n")
    }

    private static func appendHTMLLeaf(_ out: inout Data, env: Envelope) {
        appendString(&out, "Content-Type: text/html; charset=UTF-8\r\n")
        appendString(&out, "Content-Transfer-Encoding: quoted-printable\r\n\r\n")
        appendString(&out, QuotedPrintable.encode(env.htmlBody ?? ""))
        appendCRLF(&out)
    }

    private static func appendInlineImage(_ out: inout Data, image: InlineImage) throws {
        let url = URL(fileURLWithPath: image.path)
        guard let data = try? Data(contentsOf: url) else {
            throw Error.attachmentNotReadable(image.path)
        }
        let filename = url.lastPathComponent
        appendString(&out, "Content-Type: \(image.mimeType)\r\n")
        appendString(&out, "Content-ID: <\(image.contentID)>\r\n")
        appendString(&out, "Content-Disposition: inline; \(MIMEParameterEncoder.filenameParameters(filename))\r\n")
        appendString(&out, "Content-Transfer-Encoding: base64\r\n\r\n")
        let b64 = data.base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
        )
        appendString(&out, b64 + "\r\n")
    }

    private static func appendAttachment(_ out: inout Data, path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            throw Error.attachmentNotReadable(path)
        }
        let filename = url.lastPathComponent
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        appendString(&out, "Content-Type: \(mime)\r\n")
        appendString(&out, "Content-Disposition: attachment; \(MIMEParameterEncoder.filenameParameters(filename))\r\n")
        appendString(&out, "Content-Transfer-Encoding: base64\r\n\r\n")
        let b64 = data.base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
        )
        appendString(&out, b64 + "\r\n")
    }
}
