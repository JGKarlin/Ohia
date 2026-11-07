import Foundation
import NIOCore
import NIOIMAPCore
import OhiaCore

/// Verb-per-command IMAP client actor. Built on `MailLineStream` for transport,
/// `IMAPResponseReader` (NIOIMAPCore.ResponseParser) for parsing, and
/// `IMAPCommandEncoder` (hand-crafted) for serialization.
///
/// Serialized by actor isolation: only one verb may be in-flight at a time,
/// which matches the IMAP wire model (one tagged command outstanding, except
/// inside an IDLE where DONE is the only valid parallel send — see
/// Task 4.5 for IDLE handling).
public actor IMAPClient {
    private let stream: MailLineStream
    // `nonisolated(unsafe)` on these `let` storages: reader/encoder are
    // non-Sendable classes whose async methods are nonisolated. Actor isolation
    // already serializes every access — only one task is ever inside this
    // actor at a time, so the reader/encoder state is never shared across
    // suspension boundaries. The annotation tells Swift 6's region-based
    // isolation checker we've considered the implications. `stream` itself is
    // `@unchecked Sendable` internally, so no annotation needed there.
    private nonisolated(unsafe) let reader: IMAPResponseReader
    private nonisolated(unsafe) let encoder: IMAPCommandEncoder
    private var lastCapability: IMAPCapability?
    private var currentIdleTag: String?
    private var connectedHost: String = ""

    public init(stream: MailLineStream? = nil) {
        let s = stream ?? MailLineStream()
        self.stream = s
        self.reader = IMAPResponseReader(stream: s)
        self.encoder = IMAPCommandEncoder()
    }

    // MARK: - Public verb surface

    public func connect(
        host: String,
        port: Int,
        security: IMAPSecurity,
        pinnedCertSHA256: String?
    ) async throws {
        stream.pinnedCertSHA256 = pinnedCertSHA256
        self.connectedHost = host
        do {
            try await stream.connect(
                host: host,
                port: port,
                initialTLS: security == .tls
            )
        } catch let err as MailStreamError {
            throw IMAPError.mailStream(err)
        }

        // Greeting: untagged OK / PREAUTH / BYE. Capabilities may be folded
        // into the greeting's OK-response text code `[CAPABILITY ...]`.
        let greeting = try await reader.nextResponse()
        if case .response(.untagged(.conditionalState(.bye))) = greeting {
            throw IMAPError.serverClosedConnection
        }
        if let capsLine = Self.extractCapabilityLine(from: greeting) {
            lastCapability = IMAPCapability.parse(capsLine)
        }

        var caps: IMAPCapability
        if let cached = lastCapability {
            caps = cached
        } else {
            caps = try await capability()
        }
        guard caps.imap4rev1 else { throw IMAPError.notImapServer }

        if security == .starttls {
            guard caps.starttls else {
                throw IMAPError.protocolViolation("server advertises no STARTTLS but account requested .starttls")
            }
            try await runCommand(encoder.startTLS(tag: encoder.nextTag()), label: "STARTTLS")
            do {
                try await stream.startTLS(host: host)
            } catch let err as MailStreamError {
                throw IMAPError.mailStream(err)
            }
            caps = try await capability()
            guard caps.imap4rev1 else { throw IMAPError.notImapServer }
        }
    }

    public func capability() async throws -> IMAPCapability {
        let tag = encoder.nextTag()
        try await write(encoder.capability(tag: tag))
        var caps = IMAPCapability(raw: [])
        while true {
            let resp = try await reader.nextResponse(skippingUntaggedFetch: true)
            if let line = Self.extractCapabilityLine(from: resp) {
                caps = IMAPCapability.parse(line)
            }
            if let (responseTag, state) = Self.extractTagged(from: resp), responseTag == tag {
                try Self.requireOK(state: state, command: "CAPABILITY")
                break
            }
        }
        lastCapability = caps
        return caps
    }

    public func noop() async throws {
        let tag = encoder.nextTag()
        try await write(encoder.noop(tag: tag))
        try await awaitTag(tag, command: "NOOP")
    }

    /// Best-effort close — sends LOGOUT, waits for the tagged OK, swallows any
    /// errors. Always follow with `close()` to tear the stream down.
    public func logout() async {
        let tag = encoder.nextTag()
        try? await write(encoder.logout(tag: tag))
        _ = try? await awaitTag(tag, command: "LOGOUT")
    }

    public func close() async {
        await stream.close()
    }

    // MARK: - Internals

    private func write(_ data: Data) async throws {
        do {
            try await stream.write(data)
        } catch let err as MailStreamError {
            throw IMAPError.mailStream(err)
        }
    }

    /// Send a pre-encoded command (produced by `IMAPCommandEncoder`) and wait
    /// for its tagged response. Extracts the tag from the data prefix (up to
    /// the first space), which works because the encoder writes `<tag> VERB...`.
    private func runCommand(_ data: Data, label: String) async throws {
        guard let spaceIdx = data.firstIndex(of: 0x20),
              let tag = String(data: data.prefix(spaceIdx), encoding: .ascii) else {
            throw IMAPError.protocolViolation("malformed \(label) command bytes")
        }
        try await write(data)
        try await awaitTag(tag, command: label)
    }

    /// Wait for a tagged response matching `tag`; absorb untagged responses
    /// along the way. Throws on NO / BAD.
    private func awaitTag(_ tag: String, command: String) async throws {
        while true {
            let resp = try await reader.nextResponse(skippingUntaggedFetch: true)
            if let (responseTag, state) = Self.extractTagged(from: resp), responseTag == tag {
                try Self.requireOK(state: state, command: command)
                return
            }
        }
    }

    // MARK: - NIOIMAPCore.Response extraction

    /// Pull a capability token list out of a response, whether it came as
    /// an untagged `* CAPABILITY ...` (`.capabilityData`), as an OK-greeting
    /// response-text-code `[CAPABILITY ...]`, or folded into a tagged OK.
    /// Returns a space-joined string like "IMAP4rev1 IDLE AUTH=PLAIN" that
    /// `IMAPCapability.parse` can consume.
    static func extractCapabilityLine(from roc: ResponseOrContinuationRequest) -> String? {
        guard case .response(let r) = roc else { return nil }
        switch r {
        case .untagged(.capabilityData(let caps)):
            return caps.map(Self.capabilityString).joined(separator: " ")
        case .untagged(.conditionalState(let status)):
            let code: ResponseTextCode?
            switch status {
            case .ok(let t), .no(let t), .bad(let t), .preauth(let t), .bye(let t):
                code = t.code
            }
            if case .capability(let caps) = code {
                return caps.map(Self.capabilityString).joined(separator: " ")
            }
            return nil
        case .tagged(let tr):
            let text: ResponseText
            switch tr.state {
            case .ok(let t), .no(let t), .bad(let t): text = t
            }
            if case .capability(let caps) = text.code {
                return caps.map(Self.capabilityString).joined(separator: " ")
            }
            return nil
        default:
            return nil
        }
    }

    /// Reconstruct "NAME" or "NAME=VALUE" from a Capability. We need this
    /// because `Capability.rawValue` is internal; only `.name` and `.value`
    /// are exposed publicly.
    private static func capabilityString(_ c: Capability) -> String {
        if let v = c.value { return "\(c.name)=\(v)" }
        return c.name
    }

    /// Return (tag, state) for a tagged response; nil otherwise.
    static func extractTagged(from roc: ResponseOrContinuationRequest) -> (tag: String, state: TaggedResponse.State)? {
        guard case .response(.tagged(let tr)) = roc else { return nil }
        return (tr.tag, tr.state)
    }

    static func requireOK(state: TaggedResponse.State, command: String) throws {
        switch state {
        case .ok:
            return
        case .no(let text):
            // Prefer the structured response-text code when the server
            // supplied one — NIOIMAPCore parses `[AUTHENTICATIONFAILED]` /
            // `[UNAVAILABLE]` / `[SERVERBUG]` into text.code, so the bracket
            // content does NOT appear in text.text.
            switch text.code {
            case .authenticationFailed, .authorizationFailed:
                throw IMAPError.authFailed(serverText: text.text)
            case .unavailable, .serverBug:
                throw IMAPError.serverTemporary(text.text)
            default:
                break
            }
            // Fall back to scanning the human-readable text for servers that
            // didn't emit a structured code (older Dovecot builds, Zoho's
            // `NO [AUTH] ...` free-form style, etc.).
            let upper = text.text.uppercased()
            if upper.contains("AUTHENTICATIONFAILED") || upper.contains("AUTHFAILED") || upper.contains("AUTHENTICATION FAILED") {
                throw IMAPError.authFailed(serverText: text.text)
            }
            if upper.contains("UNAVAILABLE") || upper.contains("SERVERBUG") {
                throw IMAPError.serverTemporary(text.text)
            }
            throw IMAPError.protocolViolation("\(command) → NO: \(text.text)")
        case .bad(let text):
            throw IMAPError.protocolViolation("\(command) → BAD: \(text.text)")
        }
    }
}

// MARK: - Authentication

extension IMAPClient {
    /// `AUTHENTICATE PLAIN` with SASL-IR (initial response inline). Every
    /// provider in our registry supports SASL-IR, so we skip the `+`
    /// continuation variant.
    ///
    /// RFC 4616: authzid=empty, authcid=username, passwd=password — joined
    /// by NUL (0x00) bytes, base64-encoded.
    public func authenticatePlain(username: String, password: String) async throws {
        var payload = Data()
        payload.append(0)
        payload.append(Data(username.utf8))
        payload.append(0)
        payload.append(Data(password.utf8))
        let b64 = payload.base64EncodedString()

        let tag = encoder.nextTag()
        try await write(encoder.authenticatePlainSASLIR(tag: tag, credentialsBase64: b64))
        try await awaitTag(tag, command: "AUTHENTICATE PLAIN")
    }

    /// `AUTHENTICATE XOAUTH2` with the access token formatted per
    /// https://developers.google.com/gmail/imap/xoauth2-protocol.
    /// `user=<addr>\x01auth=Bearer <token>\x01\x01`, base64-encoded.
    ///
    /// On AUTHENTICATIONFAILED (routed through `requireOK` as
    /// `IMAPError.authFailed`), re-raise as `IMAPError.reauthRequired` so
    /// the caller routes to the OAuth reauth dance. OAuth tokens never
    /// recover without a new consent, unlike password auth which may be a
    /// typo the user can retry inline.
    public func authenticateXOAuth2(username: String, accessToken: String) async throws {
        let sasl = "user=\(username)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        let b64 = Data(sasl.utf8).base64EncodedString()

        let tag = encoder.nextTag()
        try await write(encoder.authenticateXOAuth2SASLIR(tag: tag, credentialsBase64: b64))
        do {
            try await awaitTag(tag, command: "AUTHENTICATE XOAUTH2")
        } catch IMAPError.authFailed(let text) {
            throw IMAPError.reauthRequired(serverText: text)
        }
    }
}

// MARK: - Folder enumeration + mailbox selection

extension IMAPClient {
    /// `LIST "" "*"` — enumerate all folders. On SPECIAL-USE-capable servers
    /// the server will include `\Sent`, `\All`, etc. attributes automatically
    /// (RFC 6154 §5.2 — no explicit `RETURN (SPECIAL-USE)` required when the
    /// capability is advertised).
    public func list() async throws -> [IMAPFolder] {
        let tag = encoder.nextTag()
        try await write(encoder.listAll(tag: tag))

        var folders: [IMAPFolder] = []
        while true {
            let resp = try await reader.nextResponse(skippingUntaggedFetch: true)
            if let folder = Self.extractListResult(from: resp) {
                folders.append(folder)
                continue
            }
            if let (responseTag, state) = Self.extractTagged(from: resp), responseTag == tag {
                try Self.requireOK(state: state, command: "LIST")
                break
            }
        }
        return folders
    }

    /// `SELECT <mailbox>`. Accumulates UIDVALIDITY / UIDNEXT / EXISTS / RECENT
    /// from the untagged response fragments into `IMAPSelectState`.
    /// Throws `IMAPError.protocolViolation("SELECT <mailbox> → NONEXISTENT")`
    /// when the server returns NO with `[NONEXISTENT]`.
    public func select(mailbox: String) async throws -> IMAPSelectState {
        let result = try await selectWithMetadata(mailbox: mailbox)
        return result.select
    }

    /// Plain `SELECT` that also captures `[HIGHESTMODSEQ N]` when the server
    /// sends it. This is used for the first post-upgrade seeding pass before
    /// a stored modseq exists.
    public func selectWithMetadata(mailbox: String) async throws -> IMAPSelectQRESYNCResult {
        let tag = encoder.nextTag()
        return try await readMailboxMetadata(
            tag: tag,
            mailbox: mailbox,
            command: "SELECT",
            bytes: encoder.select(tag: tag, mailbox: mailbox)
        )
    }

    /// Read-only mailbox selection used by onboarding/history estimation.
    public func examineWithMetadata(mailbox: String) async throws -> IMAPSelectQRESYNCResult {
        let tag = encoder.nextTag()
        return try await readMailboxMetadata(
            tag: tag,
            mailbox: mailbox,
            command: "EXAMINE",
            bytes: encoder.examine(tag: tag, mailbox: mailbox)
        )
    }

    private func readMailboxMetadata(
        tag: String,
        mailbox: String,
        command: String,
        bytes: Data
    ) async throws -> IMAPSelectQRESYNCResult {
        try await write(bytes)

        var uidValidity: UInt32 = 0
        var exists: Int = 0
        var uidNext: UInt32 = 0
        var recent: Int = 0
        var highestModSeq: UInt64?
        while true {
            let resp = try await reader.nextResponse(skippingUntaggedFetch: true)
            if let frag = Self.extractSelectStateFragment(from: resp) {
                if let v = frag.uidValidity { uidValidity = v }
                if let e = frag.exists      { exists = e }
                if let n = frag.uidNext     { uidNext = n }
                if let r = frag.recent      { recent = r }
                continue
            }
            if let modSeq = Self.extractHighestModSeq(from: resp) {
                highestModSeq = modSeq
                continue
            }
            if let (responseTag, state) = Self.extractTagged(from: resp), responseTag == tag {
                // Detect NONEXISTENT structurally before requireOK.
                if case .no(let text) = state, case .nonExistent = text.code {
                    throw IMAPError.protocolViolation("\(command) \(mailbox) → NONEXISTENT")
                }
                if let modSeq = Self.extractHighestModSeq(fromTaggedState: state) {
                    highestModSeq = modSeq
                }
                try Self.requireOK(state: state, command: command)
                break
            }
        }
        return IMAPSelectQRESYNCResult(
            select: IMAPSelectState(uidValidity: uidValidity, exists: exists, uidNext: uidNext, recent: recent),
            highestModSeq: highestModSeq,
            vanishedUIDs: [],
            flagSnapshots: []
        )
    }

    public func enableQresync() async throws {
        try await runCommand(encoder.enableQresync(tag: encoder.nextTag()), label: "ENABLE QRESYNC")
    }

    public func selectWithQresync(
        mailbox: String,
        uidValidity: UInt32,
        highestModSeq: UInt64
    ) async throws -> IMAPSelectQRESYNCResult {
        let tag = encoder.nextTag()
        try await write(encoder.selectWithQresync(
            tag: tag,
            mailbox: mailbox,
            uidValidity: uidValidity,
            highestModSeq: highestModSeq
        ))

        var uidValidityResp: UInt32 = 0
        var exists: Int = 0
        var uidNext: UInt32 = 0
        var recent: Int = 0
        var newHighestModSeq: UInt64?
        var vanishedUIDs: [UInt32] = []
        var flagSnapshots: [IMAPFlagSnapshot] = []
        var fetchAccumulator: FetchAccumulator?

        while true {
            let resp = try await reader.nextResponse()
            if case .response(.fetch(let fr)) = resp {
                if let snapshot = Self.applyFetchResponse(fr, to: &fetchAccumulator) {
                    flagSnapshots.append(snapshot)
                }
                continue
            }
            if let frag = Self.extractSelectStateFragment(from: resp) {
                if let v = frag.uidValidity { uidValidityResp = v }
                if let e = frag.exists      { exists = e }
                if let n = frag.uidNext     { uidNext = n }
                if let r = frag.recent      { recent = r }
                continue
            }
            if let vanished = Self.extractVanishedUIDs(from: resp) {
                vanishedUIDs.append(contentsOf: vanished)
                continue
            }
            if let modSeq = Self.extractHighestModSeq(from: resp) {
                newHighestModSeq = modSeq
                continue
            }
            if let (responseTag, state) = Self.extractTagged(from: resp), responseTag == tag {
                if case .no(let text) = state, case .nonExistent = text.code {
                    throw IMAPError.protocolViolation("SELECT \(mailbox) → NONEXISTENT")
                }
                if let modSeq = Self.extractHighestModSeq(fromTaggedState: state) {
                    newHighestModSeq = modSeq
                }
                try Self.requireOK(state: state, command: "SELECT (QRESYNC)")
                break
            }
        }

        return IMAPSelectQRESYNCResult(
            select: IMAPSelectState(uidValidity: uidValidityResp, exists: exists, uidNext: uidNext, recent: recent),
            highestModSeq: newHighestModSeq,
            vanishedUIDs: vanishedUIDs,
            flagSnapshots: flagSnapshots
        )
    }

    public func uidSearchAll() async throws -> [UInt32] {
        let tag = encoder.nextTag()
        try await write(encoder.uidSearchAll(tag: tag))

        return try await collectUIDSearchResults(tag: tag, command: "UID SEARCH ALL")
    }

    public func uidSearch(range: ClosedRange<UInt32>) async throws -> [UInt32] {
        let tag = encoder.nextTag()
        let uidSet = range.lowerBound == range.upperBound
            ? "\(range.lowerBound)"
            : "\(range.lowerBound):\(range.upperBound)"
        try await write(encoder.uidSearchUIDSet(tag: tag, uidSet: uidSet))

        return try await collectUIDSearchResults(tag: tag, command: "UID SEARCH UID")
    }

    public func uidSearch(range: ClosedRange<UInt32>, since: Date) async throws -> [UInt32] {
        let tag = encoder.nextTag()
        let uidSet = range.lowerBound == range.upperBound
            ? "\(range.lowerBound)"
            : "\(range.lowerBound):\(range.upperBound)"
        try await write(encoder.uidSearchUIDSetSince(tag: tag, uidSet: uidSet, since: since))

        return try await collectUIDSearchResults(tag: tag, command: "UID SEARCH UID SINCE")
    }

    public func uidSearch(
        range: ClosedRange<UInt32>,
        since: Date?,
        gmailLabel: String
    ) async throws -> [UInt32] {
        let tag = encoder.nextTag()
        let uidSet = range.lowerBound == range.upperBound
            ? "\(range.lowerBound)"
            : "\(range.lowerBound):\(range.upperBound)"
        try await write(encoder.uidSearchUIDSet(
            tag: tag,
            uidSet: uidSet,
            since: since,
            gmailLabel: gmailLabel
        ))

        return try await collectUIDSearchResults(tag: tag, command: "UID SEARCH X-GM-LABELS")
    }

    public func uidSearch(before date: Date) async throws -> [UInt32] {
        let tag = encoder.nextTag()
        try await write(encoder.uidSearchBefore(tag: tag, before: date))

        return try await collectUIDSearchResults(tag: tag, command: "UID SEARCH BEFORE")
    }

    public func uidSearchHeader(_ header: String, value: String) async throws -> [UInt32] {
        guard Self.isValidHeaderFieldName(header) else {
            throw IMAPError.protocolViolation("invalid IMAP HEADER field name")
        }
        let tag = encoder.nextTag()
        try await write(encoder.uidSearchHeader(tag: tag, header: header, value: value))

        return try await collectUIDSearchResults(tag: tag, command: "UID SEARCH HEADER")
    }

    private static func isValidHeaderFieldName(_ header: String) -> Bool {
        guard !header.isEmpty else { return false }
        return header.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 45
        }
    }

    private func collectUIDSearchResults(tag: String, command: String) async throws -> [UInt32] {
        var uids: [UInt32] = []
        while true {
            let resp = try await reader.nextResponse(skippingUntaggedFetch: true)
            if let found = Self.extractSearchUIDs(from: resp) {
                uids.append(contentsOf: found)
                continue
            }
            if let (responseTag, state) = Self.extractTagged(from: resp), responseTag == tag {
                try Self.requireOK(state: state, command: command)
                break
            }
        }
        return uids
    }

    // MARK: - Extraction helpers

    /// Pull an `IMAPFolder` out of an untagged `* LIST (...) "/" "name"` row.
    static func extractListResult(from roc: ResponseOrContinuationRequest) -> IMAPFolder? {
        guard case .response(.untagged(.mailboxData(.list(let info)))) = roc else { return nil }
        let name = String(decoding: info.path.name.bytes, as: UTF8.self)
        let attrStrings = info.attributes.map { String($0) }
        return IMAPFolder(
            name: name,
            delimiter: info.path.pathSeparator,
            attributes: Set(attrStrings)
        )
    }

    struct SelectFragment {
        let uidValidity: UInt32?
        let exists: Int?
        let uidNext: UInt32?
        let recent: Int?
    }

    /// Pull SELECT-response fragments out of untagged responses:
    /// - `* <N> EXISTS`    → exists
    /// - `* <N> RECENT`    → recent
    /// - `* OK [UIDVALIDITY <v>] ...` → uidValidity
    /// - `* OK [UIDNEXT <u>] ...`     → uidNext
    static func extractSelectStateFragment(from roc: ResponseOrContinuationRequest) -> SelectFragment? {
        guard case .response(.untagged(let payload)) = roc else { return nil }
        switch payload {
        case .mailboxData(.exists(let n)):
            return SelectFragment(uidValidity: nil, exists: n, uidNext: nil, recent: nil)
        case .mailboxData(.recent(let n)):
            return SelectFragment(uidValidity: nil, exists: nil, uidNext: nil, recent: n)
        case .conditionalState(let status):
            let text: ResponseText
            switch status {
            case .ok(let t), .no(let t), .bad(let t), .preauth(let t), .bye(let t): text = t
            }
            switch text.code {
            case .uidValidity(let v):
                return SelectFragment(uidValidity: UInt32(v), exists: nil, uidNext: nil, recent: nil)
            case .uidNext(let u):
                return SelectFragment(uidValidity: nil, exists: nil, uidNext: u.rawValue, recent: nil)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    static func extractVanishedUIDs(from roc: ResponseOrContinuationRequest) -> [UInt32]? {
        guard case .response(.untagged(.messageData(let md))) = roc else { return nil }
        switch md {
        case .vanished(let set), .vanishedEarlier(let set):
            return Self.expandUIDSet(set)
        default:
            return nil
        }
    }

    static func extractHighestModSeq(from roc: ResponseOrContinuationRequest) -> UInt64? {
        guard case .response(.untagged(.conditionalState(let status))) = roc else { return nil }
        let text: ResponseText
        switch status {
        case .ok(let t), .no(let t), .bad(let t), .preauth(let t), .bye(let t):
            text = t
        }
        if case .highestModificationSequence(let value) = text.code {
            return UInt64(value)
        }
        return nil
    }

    static func extractHighestModSeq(fromTaggedState state: TaggedResponse.State) -> UInt64? {
        let text: ResponseText
        switch state {
        case .ok(let t), .no(let t), .bad(let t):
            text = t
        }
        if case .highestModificationSequence(let value) = text.code {
            return UInt64(value)
        }
        return nil
    }

    static func extractSearchUIDs(from roc: ResponseOrContinuationRequest) -> [UInt32]? {
        guard case .response(.untagged(.mailboxData(.search(let ids, _)))) = roc else { return nil }
        return ids.map(\.rawValue)
    }

    static func extractAppendResult(fromTaggedState state: TaggedResponse.State) -> IMAPAppendResult? {
        guard case .ok(let text) = state,
              case .uidAppend(let append)? = text.code else {
            return nil
        }
        return IMAPAppendResult(
            uidValidity: UInt32(append.uidValidity),
            uids: append.uids.set.map(\.rawValue)
        )
    }

    private static func applyFetchResponse(
        _ response: FetchResponse,
        to accumulator: inout FetchAccumulator?
    ) -> IMAPFlagSnapshot? {
        switch response {
        case .start:
            accumulator = FetchAccumulator()
        case .startUID(let uid):
            var acc = FetchAccumulator()
            acc.uid = uid.rawValue
            accumulator = acc
        case .simpleAttribute(let attr):
            accumulator?.apply(attr)
        case .streamingBegin:
            accumulator?.beginStream()
        case .streamingBytes(let buf):
            accumulator?.appendStreamBytes(buf)
        case .streamingEnd:
            accumulator?.endStream()
        case .finish:
            defer { accumulator = nil }
            return accumulator?.makeFlagSnapshot()
        }
        return nil
    }

    private static func expandUIDSet(_ set: UIDSet) -> [UInt32] {
        var out: [UInt32] = []
        for range in set.ranges {
            let lower = range.range.lowerBound.rawValue
            let upper = range.range.upperBound.rawValue
            guard upper >= lower, upper - lower < 100_000 else { continue }
            for uid in lower...upper {
                out.append(uid)
            }
        }
        return out
    }
}

// MARK: - UID FETCH

extension IMAPClient {
    /// `UID FETCH <range> <attrs>` — yields one `IMAPFetch.Message` per
    /// completed FETCH row on the wire. Stream finishes when the tagged
    /// response arrives; throws `IMAPError.protocolViolation` on NO/BAD.
    ///
    /// Cancelling the consumer (by dropping the stream, or throwing from
    /// the loop) cancels the driving Task, which in turn stops consuming
    /// from the underlying `IMAPResponseReader`. Callers must not interleave
    /// other verbs while iterating the stream — the actor serializes all
    /// methods, so in practice the iteration blocks the actor for its duration.
    public nonisolated func uidFetch(
        range: ClosedRange<UInt32>,
        attrs: IMAPFetchAttributes
    ) -> AsyncThrowingStream<IMAPFetch.Message, Error> {
        let uidSet = range.lowerBound == range.upperBound
            ? "\(range.lowerBound)"
            : "\(range.lowerBound):\(range.upperBound)"
        return uidFetch(uidSet: uidSet, attrs: attrs)
    }

    public nonisolated func uidFetch(
        uidSet: String,
        attrs: IMAPFetchAttributes
    ) -> AsyncThrowingStream<IMAPFetch.Message, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runUIDFetch(uidSet: uidSet, attrs: attrs, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runUIDFetch(
        uidSet: String,
        attrs: IMAPFetchAttributes,
        continuation: AsyncThrowingStream<IMAPFetch.Message, Error>.Continuation
    ) async throws {
        let tag = encoder.nextTag()
        try await write(encoder.uidFetch(tag: tag, range: uidSet, attributeSpec: attrs.imapFetchSpec))

        var acc: FetchAccumulator?
        while true {
            let resp = try await reader.nextResponse()
            if case .response(.fetch(let fr)) = resp {
                switch fr {
                case .start:
                    acc = FetchAccumulator()
                case .startUID(let uid):
                    var a = FetchAccumulator()
                    a.uid = uid.rawValue
                    acc = a
                case .simpleAttribute(let attr):
                    acc?.apply(attr)
                case .streamingBegin:
                    acc?.beginStream()
                case .streamingBytes(let buf):
                    acc?.appendStreamBytes(buf)
                case .streamingEnd:
                    acc?.endStream()
                case .finish:
                    if let msg = acc?.makeMessage() {
                        continuation.yield(msg)
                    }
                    acc = nil
                }
                continue
            }
            if let (responseTag, state) = Self.extractTagged(from: resp), responseTag == tag {
                try Self.requireOK(state: state, command: "UID FETCH")
                return
            }
        }
    }

    // MARK: - Fetch accumulator

    /// Per-message accumulator. NIOIMAPCore.FetchResponse emits a sequence of
    /// events per row; we collect them and emit one IMAPFetch.Message on .finish.
    struct FetchAccumulator {
        var uid: UInt32 = 0
        var flags: Set<String> = []
        var hasFlags = false
        var internalDate: Date?
        var envelope: IMAPFetch.Envelope?
        var rfc822Size: Int?
        var streaming = false
        var bodyBytes = Data()
        /// Set when a `BODYSTRUCTURE` attribute is received. `nil` means the
        /// attribute was not requested; `.invalid` means the server sent a
        /// malformed body structure (common for junk mail).
        var bodyStructureWrapper: MessageAttribute.BodyStructure?

        mutating func apply(_ attr: MessageAttribute) {
            switch attr {
            case .uid(let u):
                self.uid = u.rawValue
            case .flags(let fs):
                self.flags = Set(fs.map { String($0) })
                self.hasFlags = true
            case .internalDate(let d):
                self.internalDate = IMAPClient.convertInternalDate(d)
            case .envelope(let env):
                self.envelope = IMAPClient.convertEnvelope(env)
            case .rfc822Size(let n):
                self.rfc822Size = n
            case .body(let wrapper, _):
                self.bodyStructureWrapper = wrapper
            default:
                break   // gmailLabels, preview, etc. — ignored
            }
        }

        mutating func beginStream() { self.streaming = true }

        mutating func appendStreamBytes(_ buf: ByteBuffer) {
            guard streaming else { return }
            self.bodyBytes.append(contentsOf: buf.readableBytesView)
        }

        mutating func endStream() { self.streaming = false }

        func makeMessage() -> IMAPFetch.Message? {
            // A FETCH row with uid=0 is a server bug; skip it.
            guard uid > 0 else { return nil }
            let hasAttachments: Bool
            if let wrapper = bodyStructureWrapper, case .valid(let bs) = wrapper {
                hasAttachments = BodyStructureInspector.hasAttachment(in: bs)
            } else {
                hasAttachments = false
            }
            return IMAPFetch.Message(
                uid: uid,
                flags: flags,
                internalDate: internalDate,
                envelope: envelope,
                rfc822Bytes: bodyBytes,
                rfc822Size: rfc822Size,
                hasAttachments: hasAttachments
            )
        }

        func makeFlagSnapshot() -> IMAPFlagSnapshot? {
            guard uid > 0, hasFlags else { return nil }
            return IMAPFlagSnapshot(uid: uid, flags: flags)
        }
    }

    // MARK: - NIOIMAPCore → Ohia value mapping helpers

    /// Convert NIOIMAPCore.ServerMessageDate to Foundation.Date via its
    /// components. Returns nil if the date can't be expressed in the
    /// current calendar (extreme edge case).
    static func convertInternalDate(_ d: ServerMessageDate) -> Date? {
        let c = d.components
        var comps = DateComponents()
        comps.year = c.year
        comps.month = c.month
        comps.day = c.day
        comps.hour = c.hour
        comps.minute = c.minute
        comps.second = c.second
        comps.timeZone = TimeZone(secondsFromGMT: c.zoneMinutes * 60)
        return Calendar(identifier: .iso8601).date(from: comps)
    }

    /// Convert NIOIMAPCore.Envelope to IMAPFetch.Envelope. All address lists
    /// are flattened to "Name <addr>" strings for downstream MIME parsing.
    /// `date` / `inReplyTo` / `messageID` use NIOIMAPCore's public
    /// `String.init(_:)` conversions, which expose the underlying raw value.
    static func convertEnvelope(_ env: Envelope) -> IMAPFetch.Envelope {
        IMAPFetch.Envelope(
            date: env.date.map { String($0) },
            subject: env.subject.map { String(buffer: $0) },
            from: env.from.compactMap(addressString),
            sender: env.sender.compactMap(addressString),
            replyTo: env.reply.compactMap(addressString),
            to: env.to.compactMap(addressString),
            cc: env.cc.compactMap(addressString),
            bcc: env.bcc.compactMap(addressString),
            inReplyTo: env.inReplyTo.map { String($0) },
            messageID: env.messageID.map { String($0) }
        )
    }

    /// Flatten a single EmailAddressListElement into a "Name <addr>" string.
    /// Groups are rendered as "GroupName: children;" (downstream MIME parser
    /// handles the rare case). Returns nil for addresses with neither mailbox
    /// nor host.
    private static func addressString(_ el: EmailAddressListElement) -> String? {
        switch el {
        case .singleAddress(let a):
            let mailbox = a.mailbox.map { String(buffer: $0) } ?? ""
            let host = a.host.map { String(buffer: $0) } ?? ""
            let addr = "\(mailbox)@\(host)"
            guard addr != "@" else { return nil }
            if let name = a.personName.map({ String(buffer: $0) }), !name.isEmpty {
                return "\(name) <\(addr)>"
            }
            return "<\(addr)>"
        case .group(let g):
            let name = String(buffer: g.groupName)
            let children = g.children.compactMap(addressString).joined(separator: ", ")
            return "\(name): \(children);"
        }
    }
}

// MARK: - IDLE

extension IMAPClient {
    /// Send `IDLE` and await the server's `+ idling` continuation request.
    /// If the server tagged-rejects IDLE instead (no IDLE capability, or
    /// a capability change since the last CAPABILITY), throw.
    public func beginIdle() async throws {
        let tag = encoder.nextTag()
        try await write(encoder.idleStart(tag: tag))

        while true {
            let resp = try await reader.nextResponse(skippingUntaggedFetch: true)
            if Self.isContinuation(resp) {
                currentIdleTag = tag
                return
            }
            if let (responseTag, state) = Self.extractTagged(from: resp), responseTag == tag {
                // The server rejected IDLE with a tagged NO/BAD (or unexpected OK).
                switch state {
                case .ok(let text):
                    throw IMAPError.protocolViolation("IDLE unexpectedly tagged-OK before + continuation: \(text.text)")
                case .no(let text):
                    throw IMAPError.protocolViolation("IDLE rejected: NO \(text.text)")
                case .bad(let text):
                    throw IMAPError.protocolViolation("IDLE rejected: BAD \(text.text)")
                }
            }
            // Ignore any untagged responses that arrive before the + continuation
            // (some servers prefix IDLE with a re-advertised capability set).
        }
    }

    /// Read the next untagged response while IDLE is active. Returns `nil`
    /// on timeout — the caller loops until it either sees a useful signal
    /// (EXISTS / EXPUNGE / BYE) or the 29-min IDLE rotation deadline fires.
    public func readIdleEvent(timeout: TimeInterval) async throws -> IMAPUntaggedResponse? {
        do {
            return try await withTimeout(seconds: timeout) {
                guard let resp = try await self.reader.nextIdleResponse() else { return .flagsChanged }
                return Self.flattenUntagged(resp)
            }
        } catch TimeoutError.timedOut {
            return nil
        }
    }

    /// Send `DONE\r\n` and await the tagged OK for the IDLE command started by
    /// `beginIdle`. No-op when no IDLE is in progress.
    public func endIdle() async throws {
        guard let tag = currentIdleTag else { return }
        try await write(encoder.idleDone())
        try await awaitTag(tag, command: "IDLE (DONE)")
        currentIdleTag = nil
    }

    // MARK: - IDLE helpers

    /// True when the response is the server's `+ ...` continuation request
    /// (the "start idling" / AUTHENTICATE challenge shape).
    static func isContinuation(_ roc: ResponseOrContinuationRequest) -> Bool {
        if case .continuationRequest = roc { return true }
        return false
    }

    /// Flatten an untagged response into `IMAPUntaggedResponse`. Only the
    /// mailbox-change signals IDLE cares about are surfaced; everything
    /// else collapses to `.other`.
    static func flattenUntagged(_ roc: ResponseOrContinuationRequest) -> IMAPUntaggedResponse {
        guard case .response(.untagged(let payload)) = roc else { return .other }
        switch payload {
        case .mailboxData(.exists(let n)):
            return .exists(n)
        case .messageData(.expunge(let seq)):
            return .expunge(seq.rawValue)
        case .conditionalState(.bye):
            return .bye
        case .conditionalState(.ok(let text)):
            if case .alert = text.code {
                return .alert(text.text)
            }
            return .other
        default:
            return .other
        }
    }

    // MARK: - Timeout primitive

    enum TimeoutError: Error { case timedOut }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - APPEND

public struct IMAPAppendResult: Sendable, Equatable {
    public let uidValidity: UInt32?
    public let uids: [UInt32]

    public init(uidValidity: UInt32? = nil, uids: [UInt32] = []) {
        self.uidValidity = uidValidity
        self.uids = uids
    }
}

extension IMAPClient {
    /// RFC 3501 §6.3.11 APPEND with synchronous literal. Writes the command
    /// header ending in `{N}\r\n`, waits for the server's `+` continuation,
    /// writes exactly `payload.count` octets, writes the terminating `\r\n`,
    /// then awaits the tagged OK.
    ///
    /// Non-synchronous literals (`{N+}`, RFC 7888 LITERAL+) are not used —
    /// universal support across providers matters more than the one-RTT
    /// savings for a single APPEND per send.
    @discardableResult
    public func append(
        mailbox: String,
        flags: [String],
        date: Date?,
        payload: Data
    ) async throws -> IMAPAppendResult {
        let tag = encoder.nextTag()
        let header = encoder.appendHeader(
            tag: tag, mailbox: mailbox, flags: flags, date: date, byteCount: payload.count
        )
        try await write(header)

        // Wait for `+ ...` continuation before sending the literal bytes.
        // Absorb any untagged responses that precede it.
        while true {
            let resp = try await reader.nextResponse(skippingUntaggedFetch: true)
            if case .continuationRequest = resp {
                break
            }
            if let (responseTag, state) = Self.extractTagged(from: resp), responseTag == tag {
                // Tagged response without a `+` continuation means the server
                // rejected the command outright (e.g. NO [TRYCREATE]).
                try Self.requireOK(state: state, command: "APPEND")
                throw IMAPError.protocolViolation("APPEND tagged OK before literal continuation")
            }
        }

        try await write(payload)
        try await write(Data("\r\n".utf8))
        while true {
            let resp = try await reader.nextResponse(skippingUntaggedFetch: true)
            if let (responseTag, state) = Self.extractTagged(from: resp), responseTag == tag {
                let result = Self.extractAppendResult(fromTaggedState: state)
                try Self.requireOK(state: state, command: "APPEND")
                return result ?? IMAPAppendResult()
            }
        }
    }
}

// MARK: - UID STORE / COPY / MOVE / EXPUNGE

extension IMAPClient {
    /// `UID STORE <uid> ±FLAGS.SILENT (<flags>)` — change the flag set on
    /// a single message without the server emitting an untagged FETCH for
    /// the new flag state. The mailbox containing `uid` must already be
    /// SELECTed by the caller.
    ///
    /// Throws `IMAPError.protocolViolation` on NO/BAD; the worker layer
    /// classifies these into transient (retry) vs permanent (give up).
    /// `\Seen` and `\Deleted` are the two flags this codebase uses today.
    public func uidStore(
        uid: UInt32,
        op: IMAPStoreFlagOperation,
        flags: [String]
    ) async throws {
        let tag = encoder.nextTag()
        try await write(encoder.uidStoreFlags(tag: tag, uid: uid, op: op, flags: flags))
        try await awaitTag(tag, command: "UID STORE")
    }

    /// `UID MOVE <uid> <mailbox>` — atomically move one message to another
    /// mailbox. Requires the server to advertise MOVE; callers are expected
    /// to fall back to COPY + STORE \Deleted + EXPUNGE when absent.
    public func uidMove(uid: UInt32, mailbox: String) async throws {
        let tag = encoder.nextTag()
        try await write(encoder.uidMove(tag: tag, uid: uid, mailbox: mailbox))
        try await awaitTag(tag, command: "UID MOVE")
    }

    /// `UID COPY <uid> <mailbox>` — copy one message to another mailbox.
    /// Used as the first phase of the non-MOVE Trash fallback.
    public func uidCopy(uid: UInt32, mailbox: String) async throws {
        let tag = encoder.nextTag()
        try await write(encoder.uidCopy(tag: tag, uid: uid, mailbox: mailbox))
        try await awaitTag(tag, command: "UID COPY")
    }

    /// `CREATE <mailbox>` — create a server mailbox when a provider/account
    /// does not advertise a special-use Trash folder.
    public func createMailbox(_ mailbox: String) async throws {
        let tag = encoder.nextTag()
        try await write(encoder.createMailbox(tag: tag, mailbox: mailbox))
        try await awaitTag(tag, command: "CREATE")
    }

    /// `UID EXPUNGE <uid>` — remove only the message at the given UID
    /// from the currently-selected mailbox. Requires UIDPLUS; callers
    /// should check `IMAPCapability.uidPlus` and fall back to
    /// `setDeletedAndExpunge` (which uses plain `EXPUNGE`) when absent.
    public func uidExpunge(uid: UInt32) async throws {
        let tag = encoder.nextTag()
        try await write(encoder.uidExpunge(tag: tag, uid: uid))
        try await awaitTag(tag, command: "UID EXPUNGE")
    }

    /// Plain `EXPUNGE` — remove every `\Deleted` message from the
    /// currently-selected mailbox. Used as the UIDPLUS fallback for
    /// destructive deletes; callers must guarantee no other messages in
    /// the mailbox carry `\Deleted` (otherwise this affects them too).
    public func expunge() async throws {
        let tag = encoder.nextTag()
        try await write(encoder.expunge(tag: tag))
        try await awaitTag(tag, command: "EXPUNGE")
    }
}
