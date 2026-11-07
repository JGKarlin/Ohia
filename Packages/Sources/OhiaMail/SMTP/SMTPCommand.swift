import Foundation

public enum SMTPCommand: Sendable {
    case ehlo(hostname: String)
    case startTLS
    case authPlain(username: String, password: String)
    case authLoginUsername(String)
    case authLoginPassword(String)
    case authXOAuth2(username: String, accessToken: String)
    case mailFrom(String)
    case rcptTo(String)
    case data
    case quit

    public var wire: String {
        switch self {
        case .ehlo(let h): return "EHLO \(h)\r\n"
        case .startTLS: return "STARTTLS\r\n"
        case .authPlain(let u, let p):
            let payload = Data("\0\(u)\0\(p)".utf8).base64EncodedString()
            return "AUTH PLAIN \(payload)\r\n"
        case .authLoginUsername(let u):
            return "AUTH LOGIN \(Data(u.utf8).base64EncodedString())\r\n"
        case .authLoginPassword(let p):
            return "\(Data(p.utf8).base64EncodedString())\r\n"
        case .authXOAuth2(let u, let token):
            let payload = "user=\(u)\u{01}auth=Bearer \(token)\u{01}\u{01}"
            return "AUTH XOAUTH2 \(Data(payload.utf8).base64EncodedString())\r\n"
        case .mailFrom(let addr): return "MAIL FROM:<\(addr)>\r\n"
        case .rcptTo(let addr): return "RCPT TO:<\(addr)>\r\n"
        case .data: return "DATA\r\n"
        case .quit: return "QUIT\r\n"
        }
    }
}
