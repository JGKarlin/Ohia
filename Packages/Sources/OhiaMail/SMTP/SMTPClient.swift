import Foundation
import OhiaCore

public actor SMTPClient {
    public enum Auth: Sendable {
        case password(username: String, password: String)
        case xoauth2(
            username: String,
            initialToken: String,
            refresh: @Sendable () async throws -> String
        )
    }

    let transport: SMTPTransport
    private let hostname: String

    /// `localhost` is the defensive fallback when the caller cannot provide
    /// a clean SMTP client identity. Production callers use
    /// `ehloHostname(forAddress:)`, which resolves the current Mac's hostname.
    public init(transport: SMTPTransport, hostname: String = "localhost") {
        self.transport = transport
        self.hostname = hostname
    }

    /// Resolve the EHLO/HELO argument to the SMTP client's identity. The
    /// sender address is deliberately not used: advertising `gmail.com`,
    /// `outlook.com`, or another mailbox provider from a residential client
    /// falsely claims that provider's host identity and can trigger recipient
    /// anti-spam checks. The address parameter remains at the established call
    /// sites, but it must never influence the greeting.
    public static func ehloHostname(forAddress _: String) -> String {
        let hostname = ProcessInfo.processInfo.hostName
        return isValidEHLODomain(hostname) ? hostname : "localhost"
    }

    private static func isValidEHLODomain(_ domain: String) -> Bool {
        guard !domain.isEmpty,
              !domain.hasPrefix("."), !domain.hasSuffix("."),
              !domain.contains("..") else {
            return false
        }
        return domain.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", ".":
                true
            default:
                false
            }
        }
    }

    public func sendOne(
        host: String, port: Int, security: SMTPSecurity,
        auth: Auth,
        envelope: MessageBuilder.Envelope,
        payload: Data,
        onAccepted: @Sendable () async -> Void = {}
    ) async throws {
        try await transport.connect(host: host, port: port, tls: security == .tls)
        // Close idempotently on any exit path — the happy-path QUIT+close below
        // still runs; on throw, this ensures NWConnection file descriptors are
        // released rather than leaking under OutboxWorker retry pressure.
        let closer = TransportCloser(transport: transport)
        defer { Task { await closer.close() } }

        _ = try await readResponse()

        var caps = try await ehlo()
        if security == .starttls {
            _ = try await transactOneLine(SMTPCommand.startTLS.wire, context: .startTLS)
            try await transport.upgradeToTLS()
            caps = try await ehlo()
        }

        try await authenticateWithRefreshRetry(
            auth,
            caps: caps,
            host: host,
            port: port,
            security: security
        )

        // Enforce the SIZE capability advertised in EHLO. Reject over-limit
        // payloads locally rather than spending a MAIL FROM round-trip just to
        // get a 552 back. Note: `caps` here reflects the last EHLO performed
        // inline in sendOne; the XOAUTH2 reconnect path discards its fresh caps
        // (TODO: thread the reconnect caps back out so we re-check after token
        // refresh — SIZE rarely changes mid-session so this is acceptable for
        // now).
        let limit = maxAllowedSize(caps: caps)
        if payload.count > limit {
            throw SMTPError.permanent("message size \(payload.count) exceeds server SIZE limit \(limit)")
        }

        _ = try await transactOneLine(SMTPCommand.mailFrom(envelope.from.asciiAddress).wire, context: .mailFrom)
        for rcpt in envelope.to + envelope.cc + envelope.bcc {
            _ = try await transactOneLine(SMTPCommand.rcptTo(rcpt.asciiAddress).wire, context: .rcpt)
        }
        _ = try await transactOneLine(SMTPCommand.data.wire, context: .data)
        try await writeDotStuffedData(payload)
        let finalReply = try await readResponse()
        if !finalReply.isPositiveCompletion {
            throw SMTPError.classify(response: finalReply, context: .data)
        }
        await onAccepted()
        _ = try? await transactOneLine(SMTPCommand.quit.wire, context: .quit)
        await transport.close()
    }

    // MARK: - Private helpers

    func ehlo() async throws -> SMTPResponse {
        try await transport.writeLine(SMTPCommand.ehlo(hostname: hostname).wire)
        let r = try await readResponse()
        if !r.isPositiveCompletion { throw SMTPError.classify(response: r, context: .ehlo) }
        return r
    }

    private func maxAllowedSize(caps: SMTPResponse) -> Int {
        let defaultMax = 25 * 1024 * 1024  // 25 MB fallback when SIZE absent
        guard let sizeLine = caps.lines.first(where: { $0.uppercased().hasPrefix("SIZE ") ||
                                                        $0.uppercased() == "SIZE" }) else {
            return defaultMax
        }
        let tokens = sizeLine.split(separator: " ")
        // "SIZE"    → no explicit limit (unlimited per server policy); fall back to default.
        // "SIZE N"  → N bytes.
        guard tokens.count >= 2, let n = Int(tokens[1]) else { return defaultMax }
        return n
    }

    func authenticateWithRefreshRetry(
        _ auth: Auth,
        caps: SMTPResponse,
        host: String,
        port: Int,
        security: SMTPSecurity
    ) async throws {
        switch auth {
        case .password:
            try await authenticate(auth, caps: caps)
        case .xoauth2(let u, let initialToken, let refresh):
            do {
                try await xoauth2(username: u, token: initialToken, caps: caps)
            } catch SMTPError.authFailed {
                // Token rejected (5xx). Refresh once, reconnect (real clients do
                // this because RSET doesn't reset session-level AUTH state), and
                // retry AUTH XOAUTH2 once. A second failure propagates.
                let freshToken = try await refresh()
                let newCaps = try await reconnectAndEhlo(host: host, port: port, security: security)
                try await xoauth2(username: u, token: freshToken, caps: newCaps)
            }
        }
    }

    private func reconnectAndEhlo(
        host: String,
        port: Int,
        security: SMTPSecurity
    ) async throws -> SMTPResponse {
        await transport.close()
        try await transport.connect(host: host, port: port, tls: security == .tls)
        _ = try await readResponse()
        var newCaps = try await ehlo()
        if security == .starttls {
            _ = try await transactOneLine(SMTPCommand.startTLS.wire, context: .startTLS)
            try await transport.upgradeToTLS()
            newCaps = try await ehlo()
        }
        return newCaps
    }

    private func authenticate(_ auth: Auth, caps: SMTPResponse) async throws {
        let authLine = caps.lines.first(where: { $0.uppercased().hasPrefix("AUTH ") }) ?? ""
        let mechanisms = Set(authLine
            .dropFirst(5)
            .split(separator: " ")
            .map { $0.uppercased() })

        switch auth {
        case .password(let u, let p):
            if mechanisms.contains("PLAIN") {
                try await transport.writeLine(SMTPCommand.authPlain(username: u, password: p).wire)
                let r = try await readResponse()
                if !r.isPositiveCompletion { throw SMTPError.classify(response: r, context: .auth) }
            } else if mechanisms.contains("LOGIN") {
                try await transport.writeLine(SMTPCommand.authLoginUsername(u).wire)
                let r1 = try await readResponse()
                guard r1.code == 334 else { throw SMTPError.classify(response: r1, context: .auth) }
                try await transport.writeLine(SMTPCommand.authLoginPassword(p).wire)
                let r2 = try await readResponse()
                if !r2.isPositiveCompletion { throw SMTPError.classify(response: r2, context: .auth) }
            } else {
                throw SMTPError.permanent("no supported AUTH mechanism advertised")
            }
        case .xoauth2:
            // Handled via authenticateWithRefreshRetry + xoauth2(username:token:caps:)
            // so we can reconnect and refresh the token on 535.
            throw SMTPError.protocolViolation("xoauth2 must be dispatched via authenticateWithRefreshRetry")
        }
    }

    private func xoauth2(username: String, token: String, caps: SMTPResponse) async throws {
        let authLine = caps.lines.first(where: { $0.uppercased().hasPrefix("AUTH ") }) ?? ""
        let mechanisms = Set(authLine
            .dropFirst(5)
            .split(separator: " ")
            .map { $0.uppercased() })
        guard mechanisms.contains("XOAUTH2") else {
            throw SMTPError.permanent("server does not advertise XOAUTH2")
        }
        try await transport.writeLine(SMTPCommand.authXOAuth2(username: username, accessToken: token).wire)
        let r = try await readResponse()
        if !r.isPositiveCompletion { throw SMTPError.classify(response: r, context: .auth) }
    }

    func readResponse() async throws -> SMTPResponse {
        let raw = try await transport.readResponse()
        return try SMTPResponse.parse(raw)
    }

    func transactOneLine(_ line: String, context: SMTPError.Context) async throws -> SMTPResponse {
        try await transport.writeLine(line)
        let r = try await readResponse()
        if !r.isPositiveCompletion && !r.isPositiveIntermediate {
            throw SMTPError.classify(response: r, context: context)
        }
        return r
    }

    private func writeDotStuffedData(_ data: Data) async throws {
        // Split on CRLF, dot-stuff lines starting with "." (RFC 5321 §4.5.2), and
        // append the end-of-data terminator. All written in one call so the final
        // 250 reply corresponds to the complete message.
        // The terminator is exactly `.<CRLF>` appended after the body's own
        // trailing CRLF — if the payload already ends with CRLF (MessageBuilder
        // guarantees this), we don't insert an extra blank line before the dot.
        let str = String(data: data, encoding: .utf8) ?? ""
        let stuffed = str.components(separatedBy: "\r\n").map { line -> String in
            line.hasPrefix(".") ? "." + line : line
        }.joined(separator: "\r\n")
        let withTerminator = stuffed.hasSuffix("\r\n")
            ? stuffed + ".\r\n"
            : stuffed + "\r\n.\r\n"
        try await transport.writeData(Data(withTerminator.utf8))
    }
}

/// Helper to satisfy `defer` in an async context — `defer` bodies are sync, so
/// we hop to a Task to drive the async `transport.close()`.
final class TransportCloser: @unchecked Sendable {
    private let transport: SMTPTransport
    private var closed = false
    init(transport: SMTPTransport) { self.transport = transport }
    func close() async {
        guard !closed else { return }
        closed = true
        await transport.close()
    }
}
