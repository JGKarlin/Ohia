import Foundation
import OhiaCore

/// Wires OhiaCore's parseInput hook to use MailAddressParser. The
/// ComposeAddressEncoding type lives in OhiaCore so tests can exercise it
/// without an OhiaMail dep, but the actual parsing requires OhiaMail.
public enum ComposeAddressParsingInstall {
    nonisolated(unsafe) private static var installed = false

    /// Idempotent — second and later calls are no-ops. The `_parseInputImpl`
    /// closure is `nonisolated(unsafe)`, so reinstalling under concurrent
    /// reads would technically race even with the same value; the guard makes
    /// the once-only contract enforceable rather than just documented.
    public static func install() {
        guard !installed else { return }
        installed = true
        ComposeAddressEncoding._parseInputImpl = { raw in
            let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var valid: [ComposeAddressEncoding.ParsedAddress] = []
            var invalid: [String] = []
            for piece in parts where !piece.isEmpty {
                if let addr = try? MailAddressParser.parseOne(piece) {
                    valid.append(.init(displayName: addr.displayName, asciiAddress: addr.asciiAddress))
                } else {
                    invalid.append(piece)
                }
            }
            return ComposeAddressEncoding.ParseResult(valid: valid, invalid: invalid)
        }
    }
}
