// Packages/Sources/OhiaMail/IMAP/SentAppender.swift
import Foundation
import OhiaCore

/// Best-effort IMAP APPEND to the account's Sent folder. Opens a short-lived
/// connection, authenticates, detects the Sent folder via SPECIAL-USE or
/// name heuristic, and APPENDs the RFC 5322 payload with `\Seen`.
///
/// Skips entirely on Gmail — SMTP sends through Gmail's MSA auto-file into
/// `[Gmail]/Sent Mail` server-side, and an APPEND on top creates a
/// duplicate visible in every client.
///
/// Errors from connect / auth / list / append are thrown to the caller, which
/// in production is `SMTPSendExecutor`'s best-effort wrapper — they're logged
/// but never fail the overall send.
public enum SentAppender {
    public enum Auth: Sendable {
        case password(username: String, password: String)
        case xoauth2(username: String, initialToken: String, refresh: @Sendable () async throws -> String)
    }

    public enum Result: Equatable, Sendable {
        case appended(folder: String)
        case skippedGmail
        case skippedNoSentFolder
    }

    public static func appendToSent(
        host: String,
        port: Int,
        security: IMAPSecurity,
        auth: Auth,
        pinnedCertSHA256: String?,
        payload: Data,
        date: Date?
    ) async throws -> Result {
        let client = IMAPClient()
        try await client.connect(host: host, port: port, security: security, pinnedCertSHA256: pinnedCertSHA256)

        do {
            switch auth {
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

            // Re-query capabilities post-auth — some servers advertise
            // `X-GM-EXT-1` only after authentication.
            let caps = try await client.capability()
            if caps.xGmExt1 {
                await client.logout()
                await client.close()
                return .skippedGmail
            }

            let folders = try await client.list()
            guard let sentName = SentFolderResolver.resolve(folders: folders) else {
                await client.logout()
                await client.close()
                return .skippedNoSentFolder
            }

            try await client.append(mailbox: sentName, flags: ["\\Seen"], date: date, payload: payload)
            await client.logout()
            await client.close()
            return .appended(folder: sentName)
        } catch {
            await client.close()
            throw error
        }
    }
}
