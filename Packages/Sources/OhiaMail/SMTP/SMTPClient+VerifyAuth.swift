import Foundation
import OhiaCore

extension SMTPClient {
    /// Connects, performs EHLO + optional STARTTLS + AUTH, then QUITs.
    /// Used by the onboarding and Accounts-tab "Test" buttons to validate
    /// credentials without sending a message.
    ///
    /// Intentionally mirrors `sendOne` through the end of the AUTH step and
    /// diverges only by issuing QUIT in place of MAIL/RCPT/DATA. On success
    /// returns; on any failure throws the same `SMTPError` variants.
    public func verifyAuth(
        host: String, port: Int, security: SMTPSecurity,
        auth: Auth
    ) async throws {
        try await transport.connect(host: host, port: port, tls: security == .tls)
        let closer = TransportCloser(transport: transport)
        defer { Task { await closer.close() } }

        _ = try await readResponse()
        var caps = try await ehlo()
        if security == .starttls {
            _ = try await transactOneLine(SMTPCommand.startTLS.wire, context: .startTLS)
            try await transport.upgradeToTLS()
            caps = try await ehlo()
        }

        do {
            try await authenticateWithRefreshRetry(
                auth, caps: caps, host: host, port: port, security: security
            )
        } catch {
            // Even on auth failure, send QUIT so the server can clean up the
            // session gracefully before we close the connection.
            _ = try? await transactOneLine(SMTPCommand.quit.wire, context: .quit)
            await transport.close()
            throw error
        }

        _ = try? await transactOneLine(SMTPCommand.quit.wire, context: .quit)
        await transport.close()
    }
}
