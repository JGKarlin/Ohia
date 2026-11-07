import Foundation

public enum SMTPError: Swift.Error, Equatable {
    case transient(String)
    case permanent(String)
    case authFailed(String)
    case transportFailed(String)
    case protocolViolation(String)

    public enum Context { case greeting, ehlo, startTLS, auth, mailFrom, rcpt, data, quit, other }

    public static func classify(response r: SMTPResponse, context: Context) -> SMTPError {
        let desc = "\(r.code) \(r.lines.joined(separator: " / "))"
        if r.isTransientNegative { return .transient(desc) }
        if r.isPermanentNegative {
            return context == .auth ? .authFailed(desc) : .permanent(desc)
        }
        return .protocolViolation(desc)
    }
}
