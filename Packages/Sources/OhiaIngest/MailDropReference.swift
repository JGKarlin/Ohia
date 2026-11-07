import Foundation

/// A file the sender's Apple Mail uploaded to iCloud (Mail Drop) instead of
/// attaching. The message carries only a top-level `Remote-Attachment-Url`
/// header per file plus an HTML download card, never a MIME part:
///
///     Remote-Attachment-Url: https://…/IMG_7859.MOV?…; filename="IMG_7859.MOV";
///      mimeType="video/quicktime"; filesize=0; expiration-date=1793869618.000000
public struct MailDropReference: Sendable, Equatable {
    public static let headerName = "Remote-Attachment-Url"

    public let url: URL
    public let filename: String
    public let mimeType: String
    /// Size the header declares. iPhone Mail writes `0`; the real size is
    /// learned from the server when the capture-metadata worker reads the file.
    public let declaredSizeBytes: Int
    public let expiresAt: Date?

    public init(url: URL, filename: String, mimeType: String, declaredSizeBytes: Int, expiresAt: Date?) {
        self.url = url
        self.filename = filename
        self.mimeType = mimeType
        self.declaredSizeBytes = declaredSizeBytes
        self.expiresAt = expiresAt
    }

    /// Every well-formed Mail Drop reference in the message headers, in
    /// header order, without duplicate URLs.
    public static func references(in headers: [Header]) -> [MailDropReference] {
        let target = headerName.lowercased()
        var seen = Set<String>()
        return headers
            .filter { $0.name.lowercased() == target }
            .compactMap { parse(headerValue: $0.value) }
            .filter { seen.insert($0.url.absoluteString).inserted }
    }

    /// Mail Drop downloads are served from `*.icloud-content.com` (observed:
    /// `cvws.icloud-content.com`). The header is sender-controlled, so any
    /// other host is ignored: fetching it would let a sender learn when and
    /// from where the mail was read, the leak remote-image blocking prevents.
    public static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "icloud-content.com" || host.hasSuffix(".icloud-content.com")
    }

    public static func parse(headerValue: String) -> MailDropReference? {
        let separator = headerValue.firstIndex(of: ";") ?? headerValue.endIndex
        // Unfolding can leave whitespace inside a long URL; a URL never
        // contains literal whitespace, so drop it before parsing.
        let rawURL = headerValue[..<separator].filter { !$0.isWhitespace }
        guard let url = URL(string: rawURL), isTrustedDownloadURL(url) else {
            return nil
        }
        let parameters = String(headerValue[separator...])
        let filename = MIMEParser.decodedParameterValue(named: "filename", from: parameters)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFilename = filename?.isEmpty == false ? filename! : url.lastPathComponent
        guard !resolvedFilename.isEmpty else { return nil }
        let mimeType = MIMEParser.decodedParameterValue(named: "mimetype", from: parameters)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let size = MIMEParser.decodedParameterValue(named: "filesize", from: parameters)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let expiry = MIMEParser.decodedParameterValue(named: "expiration-date", from: parameters)
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return MailDropReference(
            url: url,
            filename: resolvedFilename,
            mimeType: mimeType?.isEmpty == false ? mimeType!.lowercased() : "application/octet-stream",
            declaredSizeBytes: max(0, size),
            expiresAt: expiry
        )
    }
}
