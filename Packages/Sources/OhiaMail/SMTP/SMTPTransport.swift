import Foundation

public protocol SMTPTransport: Sendable {
    func connect(host: String, port: Int, tls: Bool) async throws
    func readLine() async throws -> String          // one line, including ending CRLF stripped
    func readResponse() async throws -> String      // full SMTP reply (possibly multi-line)
    func writeLine(_ line: String) async throws
    func writeData(_ data: Data) async throws
    func upgradeToTLS() async throws
    func close() async
}
