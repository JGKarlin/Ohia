import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Queries Mail.app via AppleScript for a given account's SMTP server
/// metadata only. Used during onboarding to pre-fill outgoing configuration.
/// It does not inspect Mail.app message files, local mailbox directories, or
/// credentials; the user always supplies authentication.
public struct MailAppSMTPReader: Sendable {
    public struct Info: Sendable, Equatable {
        public let host: String
        public let username: String
        public let port: Int
        public let usesSSL: Bool
    }

    public enum ParseError: Swift.Error, Equatable {
        case scriptReturnedNil
        case malformedRecord(String)
    }

    public typealias Executor = @Sendable (String) -> String?

    private let executor: Executor

    /// Default executor shells out to NSAppleScript. Injectable for tests.
    public init(executor: @escaping Executor = MailAppSMTPReader.defaultExecutor) {
        self.executor = executor
    }

    public func read(forAccountName name: String) async throws -> Info {
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Mail"
            try
                set srv to smtp server of account "\(escaped)"
                return (server name of srv) & ", " & (user name of srv) & ", " & (port of srv) & ", " & (uses ssl of srv)
            on error
                return ""
            end try
        end tell
        """
        guard let output = executor(script), !output.isEmpty else {
            throw ParseError.scriptReturnedNil
        }
        return try Self.parseScriptOutput(output)
    }

    /// Parses the AppleScript output string — comma-separated four-tuple of
    /// `host, user, port, ssl`. Internal so unit tests can exercise it.
    static func parseScriptOutput(_ raw: String) throws -> Info {
        let parts = raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 4,
              let port = Int(parts[2]) else {
            throw ParseError.malformedRecord(raw)
        }
        let ssl = parts[3].lowercased() == "true"
        return Info(host: parts[0], username: parts[1], port: port, usesSSL: ssl)
    }

    /// Default synchronous AppleScript metadata executor. Callers control its
    /// execution context; tests replace it with an in-memory closure.
    public static let defaultExecutor: Executor = { source in
        #if canImport(AppKit)
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
        #else
        return nil
        #endif
    }
}
