import Foundation

/// Hand-crafted IMAP command encoder. Covers the verb surface needed for
/// ingestion (capability discovery, auth, folder listing, SELECT, UID FETCH,
/// IDLE, LOGOUT). Pairs with `IMAPResponseReader`, which uses
/// `NIOIMAPCore.ResponseParser` for the response side — parsing is where
/// nio-imap earns its keep. Encoding plaintext IMAP commands is trivial and
/// keeps us free of `@_spi(NIOIMAPInternal)` imports.
///
/// All methods return complete byte sequences ending in `\r\n`, ready for
/// `MailLineStream.write`. Binary-safe — uses `Data`, not `String`, so that
/// `AUTHENTICATE XOAUTH2` base-64 payloads round-trip cleanly.
///
/// Not `Sendable` — owned by `IMAPClient` and accessed only from that actor's
/// executor.
public final class IMAPCommandEncoder {
    private var nextTagCounter: UInt32 = 0

    public init() {}
}

/// Direction of a UID STORE flag mutation.
public enum IMAPStoreFlagOperation: Sendable {
    case add        // +FLAGS
    case remove     // -FLAGS
    case replace    // FLAGS
}

extension IMAPCommandEncoder {

    /// Allocate a fresh tag for a new command. Tags are `A0001`, `A0002`, ...
    public func nextTag() -> String {
        nextTagCounter += 1
        return String(format: "A%04d", nextTagCounter)
    }

    // MARK: - Verb surface

    public func capability(tag: String) -> Data {
        line("\(tag) CAPABILITY")
    }

    public func startTLS(tag: String) -> Data {
        line("\(tag) STARTTLS")
    }

    public func logout(tag: String) -> Data {
        line("\(tag) LOGOUT")
    }

    public func noop(tag: String) -> Data {
        line("\(tag) NOOP")
    }

    /// AUTH=PLAIN with SASL-IR (initial response). `credentialsBase64` must
    /// already be the base-64 encoding of `\0<authzid>\0<authcid>\0<passwd>`
    /// per RFC 4616. When the server lacks SASL-IR, use `authenticatePlainNoIR`
    /// + `authenticationContinuation` instead.
    public func authenticatePlainSASLIR(tag: String, credentialsBase64: String) -> Data {
        line("\(tag) AUTHENTICATE PLAIN \(credentialsBase64)")
    }

    /// AUTH=XOAUTH2 with SASL-IR. `credentialsBase64` is the base-64 encoding
    /// of the SASL XOAUTH2 string (Google/Outlook format:
    /// `user=<addr>\x01auth=Bearer <token>\x01\x01`).
    public func authenticateXOAuth2SASLIR(tag: String, credentialsBase64: String) -> Data {
        line("\(tag) AUTHENTICATE XOAUTH2 \(credentialsBase64)")
    }

    /// Used when SASL-IR isn't advertised: send `AUTHENTICATE <mech>\r\n`,
    /// wait for a `+` continuation request, then send the base-64 payload
    /// via `authenticationContinuation`.
    public func authenticateNoIR(tag: String, mechanism: String) -> Data {
        line("\(tag) AUTHENTICATE \(mechanism)")
    }

    /// Response to a `+` continuation during the AUTHENTICATE handshake.
    /// Just the base-64 payload, CRLF-terminated. Used by both PLAIN and
    /// XOAUTH2 when SASL-IR isn't available. Also used to send the empty
    /// continuation that XOAUTH2 requires after an error challenge.
    public func authenticationContinuation(_ base64: String) -> Data {
        line(base64)
    }

    /// `LIST "" "*"` — enumerate all folders. We always use the empty
    /// reference + `*` pattern; special-use filtering is client-side.
    public func listAll(tag: String) -> Data {
        line("\(tag) LIST \"\" \"*\"")
    }

    /// SELECT a mailbox. Mailbox name is always quoted to handle spaces
    /// (e.g. `"[Gmail]/All Mail"`). Backslashes and quotes inside the name
    /// are escaped per RFC 3501 §4.3.
    public func select(tag: String, mailbox: String) -> Data {
        line("\(tag) SELECT \(quote(mailbox))")
    }

    /// EXAMINE selects a mailbox read-only while returning SELECT-equivalent
    /// metadata (RFC 9051 section 6.3.3).
    public func examine(tag: String, mailbox: String) -> Data {
        line("\(tag) EXAMINE \(quote(mailbox))")
    }

    /// `ENABLE QRESYNC` (RFC 5161 + RFC 7162). Sent after authentication when
    /// the server advertises QRESYNC.
    public func enableQresync(tag: String) -> Data {
        line("\(tag) ENABLE QRESYNC")
    }

    /// `SELECT mailbox (QRESYNC (uidvalidity highestModSeq))` per RFC 7162.
    public func selectWithQresync(
        tag: String,
        mailbox: String,
        uidValidity: UInt32,
        highestModSeq: UInt64
    ) -> Data {
        line("\(tag) SELECT \(quote(mailbox)) (QRESYNC (\(uidValidity) \(highestModSeq)))")
    }

    /// `UID SEARCH ALL` for fallback UID-set diffing.
    public func uidSearchAll(tag: String) -> Data {
        line("\(tag) UID SEARCH ALL")
    }

    /// `UID SEARCH UID <set>` for selecting actual extant UIDs inside a
    /// historical cursor window. This avoids crawling sparse UID ranges.
    public func uidSearchUIDSet(tag: String, uidSet: String) -> Data {
        line("\(tag) UID SEARCH UID \(uidSet)")
    }

    /// `UID SEARCH UID <set> SINCE <date>` for date-scoped historical work.
    /// IMAP SEARCH `SINCE` matches INTERNALDATE at day granularity.
    public func uidSearchUIDSetSince(tag: String, uidSet: String, since: Date) -> Data {
        line("\(tag) UID SEARCH UID \(uidSet) SINCE \(Self.searchDate(since))")
    }

    /// Gmail extension search restricted to the same UID/date window as the
    /// corpus query. Used to count the Drafts-label intersection in All Mail.
    public func uidSearchUIDSet(
        tag: String,
        uidSet: String,
        since: Date?,
        gmailLabel: String
    ) -> Data {
        var command = "\(tag) UID SEARCH UID \(uidSet)"
        if let since {
            command += " SINCE \(Self.searchDate(since))"
        }
        command += " X-GM-LABELS \(quote(gmailLabel))"
        return line(command)
    }

    /// `UID SEARCH BEFORE <date>` for retention cleanup. IMAP SEARCH `BEFORE`
    /// matches INTERNALDATE strictly before the given day.
    public func uidSearchBefore(tag: String, before date: Date) -> Data {
        line("\(tag) UID SEARCH BEFORE \(Self.searchDate(date))")
    }

    public func uidSearchHeader(tag: String, header: String, value: String) -> Data {
        line("\(tag) UID SEARCH HEADER \(header) \(quote(value))")
    }

    /// UID FETCH over a range, with the given attribute spec.
    /// `range` is an IMAP UID set string like `"1:*"`, `"1000:1999"`, or
    /// `"42,47,100"`. `attributeSpec` is the pre-rendered `(UID FLAGS
    /// INTERNALDATE ENVELOPE BODY.PEEK[] RFC822.SIZE)` form.
    public func uidFetch(tag: String, range: String, attributeSpec: String) -> Data {
        line("\(tag) UID FETCH \(range) \(attributeSpec)")
    }

    public func idleStart(tag: String) -> Data {
        line("\(tag) IDLE")
    }

    /// Untagged `DONE\r\n` — signals the server to exit IDLE.
    public func idleDone() -> Data {
        line("DONE")
    }

    /// `UID STORE <uid> <op>FLAGS (<flags>)` per RFC 3501 §6.4.6. `op` is
    /// `"+"` to add flags, `"-"` to remove, or empty to replace. We use
    /// `.SILENT` (`<op>FLAGS.SILENT`) so the server suppresses the
    /// untagged FETCH that would otherwise reflect the new flag state —
    /// the client already has it locally.
    public func uidStoreFlags(
        tag: String,
        uid: UInt32,
        op: IMAPStoreFlagOperation,
        flags: [String]
    ) -> Data {
        let opChar: String
        switch op {
        case .add:     opChar = "+"
        case .remove:  opChar = "-"
        case .replace: opChar = ""
        }
        let flagList = flags.joined(separator: " ")
        return line("\(tag) UID STORE \(uid) \(opChar)FLAGS.SILENT (\(flagList))")
    }

    /// `UID MOVE <uid> <mailbox>` per RFC 6851. Moves a message out of the
    /// currently selected mailbox when the server advertises MOVE.
    public func uidMove(tag: String, uid: UInt32, mailbox: String) -> Data {
        line("\(tag) UID MOVE \(uid) \(quote(mailbox))")
    }

    /// `UID COPY <uid> <mailbox>` per RFC 3501 §6.4.7. Used before marking
    /// the source `\Deleted` on servers that do not advertise MOVE.
    public func uidCopy(tag: String, uid: UInt32, mailbox: String) -> Data {
        line("\(tag) UID COPY \(uid) \(quote(mailbox))")
    }

    /// `CREATE <mailbox>` for accounts that do not advertise a Trash folder.
    public func createMailbox(tag: String, mailbox: String) -> Data {
        line("\(tag) CREATE \(quote(mailbox))")
    }

    /// `UID EXPUNGE <uid>` per RFC 4315 §2.1. Deletes only the message at
    /// the given UID, leaving every other `\Deleted` message intact. When
    /// the server lacks UIDPLUS, callers must fall back to plain `EXPUNGE`.
    public func uidExpunge(tag: String, uid: UInt32) -> Data {
        line("\(tag) UID EXPUNGE \(uid)")
    }

    /// Plain `EXPUNGE` (RFC 3501 §6.4.3). Removes every `\Deleted` message
    /// from the currently-selected mailbox. Used as a fallback when
    /// UIDPLUS isn't advertised.
    public func expunge(tag: String) -> Data {
        line("\(tag) EXPUNGE")
    }

    /// APPEND command header ending with `{N}\r\n`. Caller writes this,
    /// waits for a `+` continuation from the server, writes exactly `byteCount`
    /// octets of message payload, then writes a terminating `\r\n`.
    ///
    /// `flags` are raw tokens including leading backslash (e.g. `"\\Seen"`).
    /// `date` becomes the RFC 3501 §9 internal-date quoted-string
    /// (`"dd-MMM-yyyy HH:mm:ss +zzzz"`, English locale, POSIX). When nil the
    /// server stamps "now" on append.
    public func appendHeader(
        tag: String,
        mailbox: String,
        flags: [String],
        date: Date?,
        byteCount: Int
    ) -> Data {
        var s = "\(tag) APPEND \(quote(mailbox))"
        if !flags.isEmpty {
            s += " (\(flags.joined(separator: " ")))"
        }
        if let d = date {
            s += " \"\(Self.internalDate(d))\""
        }
        s += " {\(byteCount)}"
        return line(s)
    }

    /// RFC 3501 §9 date-time: `"dd-MMM-yyyy HH:mm:ss +zzzz"` (English month
    /// names, UTC offset in `+HHMM` form). POSIX locale + UTC timezone + fixed
    /// format so the output never shifts with user locale or timezone preference.
    static func internalDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    static func searchDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "dd-MMM-yyyy"
        return f.string(from: date)
    }

    // MARK: - Helpers

    private func line(_ s: String) -> Data {
        var d = Data(s.utf8)
        d.append(0x0D) // CR
        d.append(0x0A) // LF
        return d
    }

    /// RFC 3501 §4.3 quoted-string: surround with `"`, escape `\` → `\\` and
    /// `"` → `\"`. IMAP servers also accept literal strings (`{N}\r\n<bytes>`)
    /// for names with CTL chars or 8-bit data, but all providers we target
    /// (Gmail / iCloud / Outlook / Fastmail / Proton / Zoho) use ASCII names
    /// so quoted-string is sufficient.
    private func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            if ch == "\\" || ch == "\"" {
                out.append("\\")
            }
            out.append(ch)
        }
        out.append("\"")
        return out
    }
}
