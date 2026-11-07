import Foundation

public struct IMAPCapability: Sendable, Equatable {
    public let raw: Set<String>           // normalized uppercase
    public let imap4rev1: Bool
    public let idle: Bool
    public let starttls: Bool
    public let specialUse: Bool           // RFC 6154
    public let qresync: Bool              // RFC 7162
    public let xGmExt1: Bool              // Gmail — labels/thread-id/msg-id extensions
    public let authPlain: Bool            // AUTH=PLAIN
    public let authXOAuth2: Bool          // AUTH=XOAUTH2
    public let uidPlus: Bool              // UIDPLUS (RFC 4315) — UID EXPUNGE / UIDNEXT in COPY responses.
    public let move: Bool                 // MOVE (RFC 6851) — atomic UID MOVE support.

    public init(raw: Set<String>) {
        self.raw = raw
        self.imap4rev1    = raw.contains("IMAP4REV1")
        self.idle         = raw.contains("IDLE")
        self.starttls     = raw.contains("STARTTLS")
        self.specialUse   = raw.contains("SPECIAL-USE")
        self.qresync      = raw.contains("QRESYNC")
        self.xGmExt1      = raw.contains("X-GM-EXT-1")
        self.authPlain    = raw.contains("AUTH=PLAIN")
        self.authXOAuth2  = raw.contains("AUTH=XOAUTH2")
        self.uidPlus      = raw.contains("UIDPLUS")
        self.move         = raw.contains("MOVE")
    }

    /// Build from a space-separated capability token list as emitted by the
    /// server: "IMAP4rev1 IDLE LITERAL+ SPECIAL-USE AUTH=PLAIN ...".
    public static func parse(_ line: String) -> IMAPCapability {
        let tokens = line
            .uppercased()
            .split(separator: " ")
            .map(String.init)
        return IMAPCapability(raw: Set(tokens))
    }
}
