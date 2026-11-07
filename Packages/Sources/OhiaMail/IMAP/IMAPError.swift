import Foundation

public enum IMAPError: Error, Sendable {
    case transient(underlying: Error)
    case authFailed(serverText: String)
    case reauthRequired(serverText: String)
    case protocolViolation(String)
    case cancelled
    case mailStream(MailStreamError)
    case serverTemporary(String)
    case serverClosedConnection
    case notConnected
    case notImapServer
}

extension IMAPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transient(let underlying):
            return "IMAP transient error: \((underlying as NSError).localizedDescription)"
        case .authFailed(let text):
            return "IMAP authentication failed: \(text)"
        case .reauthRequired(let text):
            return "IMAP re-authentication required: \(text)"
        case .protocolViolation(let text):
            return "IMAP protocol violation: \(text)"
        case .cancelled:
            return "IMAP operation cancelled."
        case .mailStream(let inner):
            return inner.errorDescription ?? "IMAP transport error."
        case .serverTemporary(let text):
            return "IMAP server temporary failure: \(text)"
        case .serverClosedConnection:
            return "IMAP server closed the connection."
        case .notConnected:
            return "IMAP client is not connected."
        case .notImapServer:
            return "Server did not advertise IMAP4rev1."
        }
    }
}
