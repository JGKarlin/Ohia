import Foundation

/// Pure helpers for compose drafts. Lives in OhiaCore so tests in
/// OhiaCoreTests can exercise them without dragging in the app target.
public enum ComposeAddressEncoding {

    /// Serialize a list of address strings to a JSON array. Returns nil when
    /// the list is empty (the model's compose*JSON fields treat nil as "not set").
    public static func encode(_ addresses: [String]) -> String? {
        guard !addresses.isEmpty else { return nil }
        let data = (try? JSONEncoder().encode(addresses)) ?? Data()
        return String(data: data, encoding: .utf8)
    }

    /// Serialize an address array even when it is empty. Reply drafts use this
    /// to distinguish "no override; reply to the original sender" from "the
    /// user cleared To and still needs to add a recipient."
    public static func encodePreservingEmpty(_ addresses: [String]) -> String {
        let data = (try? JSONEncoder().encode(addresses)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Deserialize a JSON-array address list. Nil input or malformed JSON → [].
    public static func decode(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    public struct ParseResult: Equatable, Sendable {
        public let valid: [ParsedAddress]
        public let invalid: [String]
        public init(valid: [ParsedAddress], invalid: [String]) {
            self.valid = valid
            self.invalid = invalid
        }
    }

    /// Lightweight Sendable mirror of OhiaMail.EmailAddress so OhiaCore
    /// doesn't need to import OhiaMail. Carries enough for round-trip
    /// (rebuilt for SMTP envelope by SMTPSendExecutor via MailAddressParser).
    public struct ParsedAddress: Sendable, Equatable {
        public let displayName: String?
        public let asciiAddress: String
        public init(displayName: String?, asciiAddress: String) {
            self.displayName = displayName
            self.asciiAddress = asciiAddress
        }
    }

    /// Split a free-text input on commas, trim whitespace, attempt to parse
    /// each piece. Returns valid/invalid partition.
    ///
    /// The actual parsing requires `MailAddressParser` from OhiaMail. To keep
    /// OhiaCore independent of OhiaMail, we use a closure-based hook that
    /// OhiaMail installs at app launch via `ComposeAddressParsingInstall.install()`.
    /// Tests call `install()` in their suite `init` to set up the same hook.
    public static func parseInput(_ raw: String) -> ParseResult {
        Self._parseInputImpl(raw)
    }

    /// Closure-based dispatch so OhiaCore can compile without importing
    /// OhiaMail. The OhiaMail target installs the real impl at app launch.
    /// Default returns "everything is invalid" so a missed install fails
    /// loudly rather than appearing to work.
    ///
    /// `nonisolated(unsafe)`: written exactly once at app launch (or test
    /// suite `init`) before any concurrent read, so external serialization
    /// makes this safe despite Swift 6 strict concurrency.
    public nonisolated(unsafe) static var _parseInputImpl: @Sendable (String) -> ParseResult = { raw in
        ParseResult(valid: [], invalid: raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        })
    }

    /// Resolve the initial "From" account UUID for a new compose draft.
    /// Reads `ohia.compose.lastUsedAccountID` from UserDefaults; if that
    /// account is in the available list, uses it; otherwise returns the
    /// first available account; nil if none.
    public static func resolveInitialFromAccount(
        availableAccountIDs: [UUID],
        defaults: UserDefaults
    ) -> UUID? {
        guard !availableAccountIDs.isEmpty else { return nil }
        if let str = defaults.string(forKey: "ohia.compose.lastUsedAccountID"),
           let id = UUID(uuidString: str),
           availableAccountIDs.contains(id) {
            return id
        }
        return availableAccountIDs.first
    }
}
