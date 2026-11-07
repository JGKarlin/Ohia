import Foundation

public final class SMTPStreamTransport: SMTPTransport, @unchecked Sendable {
    private let stream = MailLineStream()
    private var connectedHost: String = ""

    /// Forwarded to the underlying `MailLineStream` on the next `connect(...)`.
    /// Set before calling `connect(...)`. See `Account.pinnedCertSHA256`.
    public var pinnedCertSHA256: String? = nil

    public init() {}

    public func connect(host: String, port: Int, tls: Bool) async throws {
        connectedHost = host
        stream.pinnedCertSHA256 = pinnedCertSHA256
        try await wrap { try await self.stream.connect(host: host, port: port, initialTLS: tls) }
    }

    public func readLine() async throws -> String {
        try await wrap { try await self.stream.readLine() }
    }

    public func readResponse() async throws -> String {
        try await wrap {
            var acc = ""
            while true {
                let line = try await self.stream.readLine()
                acc += line + "\r\n"
                // Terminal line per RFC 5321 §4.2: 3 digits followed by space.
                if line.count >= 4, line[line.index(line.startIndex, offsetBy: 3)] == " " { break }
            }
            return acc
        }
    }

    public func writeLine(_ line: String) async throws {
        try await wrap { try await self.stream.write(Data(line.utf8)) }
    }

    public func writeData(_ data: Data) async throws {
        try await wrap { try await self.stream.write(data) }
    }

    public func upgradeToTLS() async throws {
        try await wrap { try await self.stream.startTLS(host: self.connectedHost) }
    }

    public func close() async {
        await stream.close()
    }

    /// Translate any thrown error to SMTPError via wrapTransport. Identity
    /// pass-through for already-SMTPError throws.
    private func wrap<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch { throw SMTPStreamTransport.wrapTransport(error) }
    }

    static func wrapTransport(_ err: Error) -> SMTPError {
        if let s = err as? SMTPError { return s }
        guard let m = err as? MailStreamError else {
            return .transportFailed("unknown transport error: \(err)")
        }
        switch m {
        case .tlsHandshakeFailed:
            return .transportFailed("TLS handshake failed: \(err)")
        case .certPinMismatch(let presented):
            return .transportFailed("certificate pin mismatch: \(presented)")
        case .connectionClosed:
            return .transient("connection closed: \(err)")
        case .stream(let underlying):
            return .transient("stream error: \(underlying)")
        case .notConnected, .wrongState, .invalidUTF8:
            return .protocolViolation("transport state error: \(err)")
        }
    }
}
