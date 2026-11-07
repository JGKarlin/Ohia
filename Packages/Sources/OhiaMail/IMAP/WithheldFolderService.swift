import Foundation
import OhiaCore

// MARK: - Domain types

public enum WithheldFolderRole: String, Sendable, CaseIterable {
    case junk, trash
}

public struct WithheldRow: Identifiable, Sendable, Equatable {
    public let id: String
    /// Stable identity of an Ohia-retained Trash row. Nil for transient
    /// provider-only Junk/Trash mail. When present, the drawer can restore the
    /// retained message even before (or without) a provider Trash copy.
    public let localMessageID: UUID?
    public let accountID: UUID
    public let folder: WithheldFolderRole
    public let folderPath: String
    public let uid: UInt32
    public let uidValidity: UInt32
    public let sender: String
    public let senderAddress: String
    public let subject: String
    public let date: Date?
    public let isRead: Bool
    public let hasAttachments: Bool
    public let listId: String?
    public let spamScore: Double?
    public let authResults: String?
    public let messageId: String?

    public init(
        accountID: UUID, folder: WithheldFolderRole, folderPath: String,
        uid: UInt32, uidValidity: UInt32, sender: String, senderAddress: String,
        subject: String, date: Date?, isRead: Bool, hasAttachments: Bool,
        listId: String?, spamScore: Double?, authResults: String?,
        messageId: String? = nil,
        localMessageID: UUID? = nil
    ) {
        self.id = localMessageID.map { "local-trash:\($0.uuidString)" }
            ?? "\(accountID.uuidString):\(folder.rawValue):\(uidValidity):\(uid)"
        self.localMessageID = localMessageID
        self.accountID = accountID; self.folder = folder; self.folderPath = folderPath
        self.uid = uid; self.uidValidity = uidValidity
        self.sender = sender; self.senderAddress = senderAddress; self.subject = subject
        self.date = date; self.isRead = isRead; self.hasAttachments = hasAttachments
        self.listId = listId; self.spamScore = spamScore; self.authResults = authResults
        self.messageId = messageId
    }
}

public struct WithheldResolvedUID: Sendable, Equatable {
    public let uid: UInt32
    public let uidValidity: UInt32
    /// The selected server mailbox that owns `uid`. Optional for compatibility
    /// with test and injected sources that only model UID identity.
    public let folderPath: String?

    public init(uid: UInt32, uidValidity: UInt32, folderPath: String? = nil) {
        self.uid = uid
        self.uidValidity = uidValidity
        self.folderPath = folderPath
    }
}

// MARK: - WithheldFolderResolver

public enum WithheldFolderResolver {
    public static func resolve(role: WithheldFolderRole, in folders: [IMAPFolder]) -> IMAPFolder? {
        if let special = folders.first(where: { role == .junk ? $0.isJunk : $0.isTrash }) {
            return special
        }
        return folders.first { folder in
            guard !folder.isNoselect else { return false }
            switch role {
            case .junk: return IMAPFolderIngestionPolicy.matchesJunkLeafName(folder.name)
            case .trash: return IMAPFolderIngestionPolicy.matchesTrashLeafName(folder.name)
            }
        }
    }
}

// MARK: - WithheldFetchConfig

/// Configuration for a transient, read-only withheld-folder fetch.
public struct WithheldFetchConfig: Sendable {
    public let accountID: UUID
    public let host: String
    public let port: Int
    public let security: IMAPSecurity
    public let username: String
    public let pinnedCertSHA256: String?
    public let auth: SentAppender.Auth
    public let windowDays: Int
    public let maxUIDs: Int

    public init(
        accountID: UUID,
        host: String,
        port: Int,
        security: IMAPSecurity,
        username: String,
        pinnedCertSHA256: String?,
        auth: SentAppender.Auth,
        windowDays: Int = 30,
        maxUIDs: Int = 200
    ) {
        self.accountID = accountID
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.pinnedCertSHA256 = pinnedCertSHA256
        self.auth = auth
        self.windowDays = windowDays
        self.maxUIDs = maxUIDs
    }
}

// MARK: - WithheldHeaderParser

/// Internal parser for the HEADER.FIELDS block returned by `.triageHeaders`.
///
/// Handles:
/// - Case-insensitive header names
/// - RFC 2822 header unfolding (continuation lines beginning with SP or HT)
/// - `List-Id`: extracts the `<...>`-bracketed identifier
/// - `X-Spam-Score`: direct float value
/// - `X-Spam-Status`: falls back to `score=` extraction (SpamAssassin format)
/// - `Authentication-Results`: raw value
enum WithheldHeaderParser {
    struct Result {
        let listId: String?
        let spamScore: Double?
        let authResults: String?
    }

    static func parse(_ data: Data) -> Result {
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
            return Result(listId: nil, spamScore: nil, authResults: nil)
        }

        // Build a [name: value] dictionary by unfolding the header block.
        var headers: [String: String] = [:]
        var currentName: String?
        var currentValue: String = ""

        // Split on CRLF or LF, but preserve continuation detection
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }

        for line in lines {
            if line.isEmpty { continue }
            let firstChar = line.unicodeScalars.first?.value
            let isContinuation = firstChar == 0x20 /* SP */ || firstChar == 0x09 /* HT */
            if isContinuation {
                // Unfold: append with a single space replacing the fold
                if currentName != nil {
                    currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                }
            } else {
                // Save previous header if any
                if let name = currentName {
                    headers[name.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
                }
                // Parse new header
                if let colonIdx = line.firstIndex(of: ":") {
                    currentName = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    currentValue = String(line[line.index(after: colonIdx)...])
                } else {
                    currentName = nil
                    currentValue = ""
                }
            }
        }
        // Flush last header
        if let name = currentName {
            headers[name.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
        }

        // Extract List-Id: parse the <...>-bracketed value
        let listId: String? = headers["list-id"].flatMap { val -> String? in
            guard let lt = val.firstIndex(of: "<"), let gt = val.lastIndex(of: ">"), lt < gt else {
                return nil
            }
            let inner = String(val[val.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            return inner.isEmpty ? nil : inner
        }

        // Extract spam score: X-Spam-Score first, then fall back to X-Spam-Status score=
        var spamScore: Double? = nil
        if let scoreStr = headers["x-spam-score"] {
            spamScore = Double(scoreStr.trimmingCharacters(in: .whitespaces))
        }
        if spamScore == nil, let statusStr = headers["x-spam-status"] {
            spamScore = extractSpamAssassinScore(statusStr)
        }

        let authResults: String? = headers["authentication-results"]

        return Result(listId: listId, spamScore: spamScore, authResults: authResults)
    }

    /// Extract `score=<float>` from a SpamAssassin X-Spam-Status value like
    /// `"Yes, score=5.2 required=5.0 tests=..."`.
    private static func extractSpamAssassinScore(_ value: String) -> Double? {
        // Use case-insensitive search directly on `value` to avoid cross-String index aliasing.
        guard let range = value.range(of: "score=", options: .caseInsensitive) else { return nil }
        let afterEquals = value[range.upperBound...]
        // Take characters that form a number (digits, dot, minus sign at start)
        var numStr = ""
        for (i, ch) in afterEquals.enumerated() {
            if i == 0 && ch == "-" {
                numStr.append(ch)
            } else if ch.isNumber || ch == "." {
                numStr.append(ch)
            } else {
                break
            }
        }
        return numStr.isEmpty ? nil : Double(numStr)
    }
}

// MARK: - WithheldFolderService

/// Performs a transient, read-only IMAP fetch of Junk or Trash messages,
/// mapping each to a `WithheldRow`. Never persists or modifies mailbox state.
public actor WithheldFolderService {
    private let makeClient: @Sendable () -> any IMAPClienting

    /// Production initializer — creates an `IMAPClient` per fetch.
    public init() {
        self.makeClient = { IMAPClient() }
    }

    /// Testable initializer — supply a mock client factory.
    init(makeClient: @escaping @Sendable () -> any IMAPClienting) {
        self.makeClient = makeClient
    }

    public enum ServiceError: Error, Equatable {
        case folderNotFound
        case messageNotFound
        /// The query string contains characters that are illegal in an IMAP quoted-string
        /// (CR, LF, or NUL), which would allow command injection on the wire.
        case invalidQuery
        /// The folder's UIDVALIDITY has changed since the UID was cached; the cached UID
        /// is now invalid and the message must be re-resolved by its RFC Message-ID.
        case uidValidityChanged
    }

    // MARK: - Transient connection lifecycle

    /// Shared helper: create a client, connect, authenticate (with XOAuth2 reauth-retry),
    /// list folders, resolve the role folder, and select it; then run `body` with the
    /// established state and guarantee `close()` is called in all exit paths.
    ///
    /// `body` receives the connected client, the resolved folder, and the select result.
    /// On success the helper calls `logout` then `close`; on any error it calls `close`
    /// and rethrows — matching the `SentAppender.appendToSent` lifecycle.
    private func withConnection<T: Sendable>(
        config: WithheldFetchConfig,
        role: WithheldFolderRole,
        body: (any IMAPClienting, IMAPFolder, IMAPSelectQRESYNCResult) async throws -> T
    ) async throws -> T {
        let client = makeClient()

        do {
            // connect inside the do-block so a connect failure also calls close().
            try await client.connect(
                host: config.host,
                port: config.port,
                security: config.security,
                pinnedCertSHA256: config.pinnedCertSHA256
            )

            // Authenticate
            switch config.auth {
            case .password(let username, let password):
                try await client.authenticatePlain(username: username, password: password)
            case .xoauth2(let username, let initialToken, let refresh):
                do {
                    try await client.authenticateXOAuth2(username: username, accessToken: initialToken)
                } catch IMAPError.reauthRequired {
                    let fresh = try await refresh()
                    try await client.authenticateXOAuth2(username: username, accessToken: fresh)
                }
            }

            // Resolve folder
            let folders = try await client.list()
            guard let folder = WithheldFolderResolver.resolve(role: role, in: folders) else {
                throw ServiceError.folderNotFound
            }

            // Select
            let selectResult = try await client.selectWithMetadata(mailbox: folder.name)

            // Run caller's operation
            let result = try await body(client, folder, selectResult)

            try Task.checkCancellation()
            await client.logout()
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }

    // MARK: - Public API

    /// Fetch recent withheld messages from the given role's folder.
    ///
    /// Connection lifecycle mirrors `SentAppender.appendToSent`:
    /// `connect` → `auth` → operation → `logout` + `close`; on error `close` + rethrow.
    public func fetchRecent(
        role: WithheldFolderRole,
        config: WithheldFetchConfig,
        now: Date = Date()
    ) async throws -> [WithheldRow] {
        try await withConnection(config: config, role: role) { client, folder, selectResult in
            let uidValidity = selectResult.select.uidValidity

            // UID search within the time window
            let since = now.addingTimeInterval(-Double(config.windowDays) * 86400)
            let allUIDs = try await client.uidSearch(range: 1...UInt32.max, since: since)

            // Cap to the most recent maxUIDs (UID search returns ascending order)
            let cappedUIDs = Array(allUIDs.suffix(config.maxUIDs))

            // Fetch triage headers + body structure (BODY.PEEK is only used in fetchBody)
            let attrs = IMAPFetchAttributes([.uid, .flags, .internalDate, .envelope, .triageHeaders, .bodyStructure])
            let stream = await client.uidFetchStream(uids: cappedUIDs, attrs: attrs)

            var rows: [WithheldRow] = []
            for try await msg in stream {
                let row = makeRow(from: msg, role: role, folderPath: folder.name,
                                  accountID: config.accountID, uidValidity: uidValidity)
                rows.append(row)
            }
            return rows
        }
    }

    /// Fetch the raw RFC 822 bytes of a single message via `BODY.PEEK[]` (read-only; never sets `\Seen`).
    ///
    /// Returns raw `Data`; MIME decoding is the responsibility of the app layer.
    /// Throws `ServiceError.messageNotFound` if the stream yields no message for `uid`.
    /// Throws `ServiceError.uidValidityChanged` if `expectedUIDValidity` is non-nil and does not
    /// match the folder's current UIDVALIDITY — the cached UID is stale; call `resolveUID` instead.
    public func fetchBody(
        uid: UInt32,
        expectedUIDValidity: UInt32? = nil,
        role: WithheldFolderRole,
        config: WithheldFetchConfig
    ) async throws -> Data {
        try await withConnection(config: config, role: role) { client, _, selectResult in
            if let expected = expectedUIDValidity, selectResult.select.uidValidity != expected {
                throw ServiceError.uidValidityChanged
            }
            // BODY.PEEK[] must NOT be combined with .triageHeaders (precondition in IMAPFetchAttributes).
            let attrs = IMAPFetchAttributes([.uid, .bodyPeek])
            let stream = await client.uidFetchStream(uids: [uid], attrs: attrs)

            for try await msg in stream {
                return msg.rfc822Bytes // Only one UID requested; return on first response.
            }
            throw ServiceError.messageNotFound
        }
    }

    /// Search the withheld folder for messages matching `query` in Subject or From headers.
    ///
    /// Performs `SEARCH HEADER SUBJECT <query>` ∪ `SEARCH HEADER FROM <query>`, deduplicates
    /// the resulting UID set (capped to `config.maxUIDs` most-recent), then fetches and maps
    /// the messages using the same attrs and mapping as `fetchRecent`.
    ///
    /// Throws `ServiceError.invalidQuery` if `query` contains control characters (CR, LF, NUL)
    /// that would break the IMAP quoted-string encoding.
    public func searchOlder(
        role: WithheldFolderRole,
        config: WithheldFetchConfig,
        query: String
    ) async throws -> [WithheldRow] {
        // Guard against IMAP command injection: RFC 3501 §4.3 forbids CR, LF, and NUL
        // inside a quoted-string. The encoder's quote() only escapes `\` and `"`.
        guard !query.unicodeScalars.contains(where: { $0.value == 0x00 || $0.value == 0x0D || $0.value == 0x0A }) else {
            throw ServiceError.invalidQuery
        }

        return try await withConnection(config: config, role: role) { client, folder, selectResult in
            let uidValidity = selectResult.select.uidValidity

            // Union of SUBJECT and FROM header searches, deduplicated and sorted ascending
            // so the suffix cap is deterministic and matches the "most recent" semantics
            // of fetchRecent (IMAP UIDs are monotonically increasing).
            let subjectUIDs = try await client.uidSearchHeader("SUBJECT", value: query)
            let fromUIDs    = try await client.uidSearchHeader("FROM", value: query)
            let deduped = Array(Set(subjectUIDs + fromUIDs)).sorted()
            let cappedUIDs = Array(deduped.suffix(config.maxUIDs))

            var rows: [WithheldRow] = []
            if !cappedUIDs.isEmpty {
                let attrs = IMAPFetchAttributes([.uid, .flags, .internalDate, .envelope, .triageHeaders, .bodyStructure])
                let stream = await client.uidFetchStream(uids: cappedUIDs, attrs: attrs)
                for try await msg in stream {
                    let row = makeRow(from: msg, role: role, folderPath: folder.name,
                                      accountID: config.accountID, uidValidity: uidValidity)
                    rows.append(row)
                }
            }
            return rows
        }
    }

    /// Re-resolve a message's current UID by its RFC Message-ID header.
    ///
    /// Used when UIDVALIDITY changed and the cached UID is stale. Returns the most-recent
    /// matching UID (UIDs are monotonically increasing, so `max` = most recent), or `nil`
    /// if the server finds no matching message.
    ///
    /// Throws `ServiceError.invalidQuery` if `messageID` contains CR (0x0D), LF (0x0A),
    /// or NUL (0x00) — the same IMAP quoted-string injection guard used by `searchOlder`.
    public func resolveUID(
        messageID: String,
        role: WithheldFolderRole,
        config: WithheldFetchConfig
    ) async throws -> WithheldResolvedUID? {
        guard !messageID.unicodeScalars.contains(where: { $0.value == 0x00 || $0.value == 0x0D || $0.value == 0x0A }) else {
            throw ServiceError.invalidQuery
        }
        return try await withConnection(config: config, role: role) { client, folder, selectResult in
            let uids = try await client.uidSearchHeader("MESSAGE-ID", value: messageID)
            guard let uid = uids.max() else { return nil }
            return WithheldResolvedUID(
                uid: uid,
                uidValidity: selectResult.select.uidValidity,
                folderPath: folder.name
            )
        }
    }

    // MARK: - Private mapping

    private func makeRow(
        from msg: IMAPFetch.Message,
        role: WithheldFolderRole,
        folderPath: String,
        accountID: UUID,
        uidValidity: UInt32
    ) -> WithheldRow {
        // Parse sender from envelope
        let (sender, senderAddress) = parseSender(from: msg.envelope)

        // Parse triage headers from the HEADER.FIELDS block in rfc822Bytes
        let headers = WithheldHeaderParser.parse(msg.rfc822Bytes)

        return WithheldRow(
            accountID: accountID,
            folder: role,
            folderPath: folderPath,
            uid: msg.uid,
            uidValidity: uidValidity,
            sender: sender,
            senderAddress: senderAddress,
            subject: MIMEHeaderDecoder.decodeEncodedWords(msg.envelope?.subject ?? ""),
            date: msg.internalDate,
            isRead: msg.flags.contains("\\Seen"),
            hasAttachments: msg.hasAttachments,
            listId: headers.listId,
            spamScore: headers.spamScore,
            authResults: headers.authResults,
            messageId: msg.envelope?.messageID
        )
    }

    /// Extract display name and address from the envelope's `from` field.
    ///
    /// On parse success: `sender` = displayName (or "" if absent), `senderAddress` = address string.
    /// On parse failure or empty from: both are the raw string (or "").
    private func parseSender(from envelope: IMAPFetch.Envelope?) -> (sender: String, senderAddress: String) {
        guard let raw = envelope?.from.first else {
            return ("", "")
        }
        do {
            let parsed = try MailAddressParser.parseOne(raw)
            let displayName = MIMEHeaderDecoder.decodeEncodedWords(parsed.displayName ?? "")
            return (displayName, parsed.address)
        } catch {
            // Fallback: decode the display half, keep the raw string as the address.
            return (MIMEHeaderDecoder.decodeEncodedWords(raw), raw)
        }
    }
}
