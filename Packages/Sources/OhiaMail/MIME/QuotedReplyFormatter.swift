import Foundation
import OhiaCore

public enum QuotedReplyFormatter {
    private static let maxBytes = 50_000

    public struct PreparedQuote: Sendable, Equatable {
        public let plainText: String
        public let html: String

        public init(plainText: String, html: String) {
            self.plainText = plainText
            self.html = html
        }
    }

    public static func plain(incomingBody: String, fromDisplay: String, date: Date) -> String {
        let body = trim(incomingBody)
        let attribution = "On \(formatted(date)), \(fromDisplay) wrote:"
        let quoted = body.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
        return attribution + "\n" + quoted
    }

    /// Builds the complete plain and HTML representations of the immediately
    /// replied-to message. Existing quoted-history tails are removed first so
    /// one reply never recursively republishes the whole thread. When the
    /// incoming body contains only history, there is no honest quote to include.
    public static func prepareForIncoming(
        bodyText: String,
        fromName: String?,
        fromAddress: String,
        receivedAt: Date?,
        ingestedAt: Date
    ) -> PreparedQuote? {
        let authoredBody = QuotedHistoryTail.latestAuthoredText(from: bodyText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authoredBody.isEmpty else { return nil }

        let displayName = fromName ?? fromAddress
        let date = receivedAt ?? ingestedAt
        return PreparedQuote(
            plainText: plain(
                incomingBody: authoredBody,
                fromDisplay: displayName,
                date: date
            ),
            html: html(
                incomingBody: authoredBody,
                fromDisplay: displayName,
                date: date
            )
        )
    }

    public static func html(incomingBody: String, fromDisplay: String, date: Date) -> String {
        let body = trim(incomingBody)
        let escapedBody = htmlEscaped(body)
            .replacingOccurrences(of: "\n", with: "<br>")
        let escapedDisplay = htmlEscaped(fromDisplay)
        return "<div>On \(formatted(date)), \(escapedDisplay) wrote:</div>" +
               #"<blockquote style="margin:0 0 0 0.8ex; border-left:1px solid #ccc; padding-left:1ex;">"# +
               escapedBody + "</blockquote>"
    }

    public static func appending(_ quote: PreparedQuote, toPlainBody body: String) -> String {
        body + "\n\n" + quote.plainText
    }

    public static func appending(_ quote: PreparedQuote, toHTMLBody body: String) -> String {
        let separatedQuote = "<div><br></div>" + quote.html
        if body.contains("</body>") {
            return body.replacingOccurrences(of: "</body>", with: separatedQuote + "</body>")
        }
        return body + separatedQuote
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // Trims body to at most maxBytes UTF-8 bytes, respecting character boundaries.
    private static func trim(_ body: String) -> String {
        let utf8 = body.utf8
        guard utf8.count > maxBytes else { return body }

        // Walk back from the byte limit until we land on a valid UTF-8
        // character boundary (i.e. the byte index can be projected into
        // a String.Index without returning nil).
        var idx = utf8.index(utf8.startIndex, offsetBy: maxBytes)
        while idx > utf8.startIndex && idx.samePosition(in: body) == nil {
            utf8.formIndex(before: &idx)
        }

        let prefix = String(utf8[..<idx]) ?? body
        return prefix + "\n[Quote shortened]"
    }

    private static func formatted(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        return fmt.string(from: date)
    }
}
