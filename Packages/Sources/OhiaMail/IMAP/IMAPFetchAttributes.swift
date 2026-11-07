import Foundation

public struct IMAPFetchAttributes: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let uid          = IMAPFetchAttributes(rawValue: 1 << 0)
    public static let flags        = IMAPFetchAttributes(rawValue: 1 << 1)
    public static let internalDate = IMAPFetchAttributes(rawValue: 1 << 2)
    public static let envelope     = IMAPFetchAttributes(rawValue: 1 << 3)
    public static let bodyPeek      = IMAPFetchAttributes(rawValue: 1 << 4)
    public static let rfc822Size    = IMAPFetchAttributes(rawValue: 1 << 5)
    /// Fetch selected spam/list signal headers. Must NOT be combined with `.bodyPeek`
    /// (two body-section fetches would concatenate their bytes in the stream).
    /// Not included in `.all`.
    public static let triageHeaders = IMAPFetchAttributes(rawValue: 1 << 6)
    /// Fetch the MIME body structure (BODYSTRUCTURE). Not included in `.all`.
    public static let bodyStructure = IMAPFetchAttributes(rawValue: 1 << 7)

    public static let all: IMAPFetchAttributes = [.uid, .flags, .internalDate, .envelope, .bodyPeek, .rfc822Size]

    /// Render as an IMAP FETCH attribute macro list, e.g.
    /// "(UID FLAGS INTERNALDATE ENVELOPE BODY.PEEK[] RFC822.SIZE)"
    public var imapFetchSpec: String {
        precondition(!(contains(.bodyPeek) && contains(.triageHeaders)),
                     "IMAPFetchAttributes: .bodyPeek and .triageHeaders both emit a body section; combining them concatenates two sections into rfc822Bytes. Request them in separate fetches.")
        var parts: [String] = []
        if contains(.uid)           { parts.append("UID") }
        if contains(.flags)         { parts.append("FLAGS") }
        if contains(.internalDate)  { parts.append("INTERNALDATE") }
        if contains(.envelope)      { parts.append("ENVELOPE") }
        if contains(.rfc822Size)    { parts.append("RFC822.SIZE") }
        if contains(.bodyStructure) { parts.append("BODYSTRUCTURE") }
        if contains(.bodyPeek)      { parts.append("BODY.PEEK[]") }
        if contains(.triageHeaders) {
            parts.append("BODY.PEEK[HEADER.FIELDS (LIST-ID X-SPAM-SCORE X-SPAM-STATUS X-SPAM-FLAG AUTHENTICATION-RESULTS)]")
        }
        return "(" + parts.joined(separator: " ") + ")"
    }
}
