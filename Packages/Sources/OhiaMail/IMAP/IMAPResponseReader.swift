import Foundation
import NIOCore
import NIOIMAPCore

/// Consumes bytes from a `MailLineStream` and emits parsed IMAP responses via
/// `NIOIMAPCore.ResponseParser`. Supports literal-body `{N}` reads by briefly
/// switching the underlying stream into byte-count mode.
///
/// The reader is stateful (has an accumulating byte buffer + parser instance)
/// and non-`Sendable`. It's owned by `IMAPClient` and accessed only from that
/// actor's executor.
public final class IMAPResponseReader {
    private let stream: MailLineStream
    private var parser = ResponseParser()
    private var buffer = ByteBuffer()
    private var readingFetchResponse = false

    public init(stream: MailLineStream) {
        self.stream = stream
    }

    /// Read and parse exactly one complete response from the wire. Blocks
    /// until a full response (tagged, untagged, continuation, etc.) is
    /// available.
    ///
    /// Calling this when the stream is mid-literal is undefined — always
    /// complete previous reads before starting a new one.
    public func nextResponse(
        skippingUntaggedFetch: Bool = false
    ) async throws -> ResponseOrContinuationRequest {
        // Never nil: only `nextIdleResponse` stops at a skipped FETCH.
        try await readResponse(skippingUntaggedFetch: skippingUntaggedFetch, stoppingAtSkippedFetch: false)!
    }

    /// One response read during IDLE, or nil when the server sent an untagged
    /// FETCH (a flag change), which is discarded rather than parsed.
    public func nextIdleResponse() async throws -> ResponseOrContinuationRequest? {
        try await readResponse(skippingUntaggedFetch: true, stoppingAtSkippedFetch: true)
    }

    private func readResponse(
        skippingUntaggedFetch: Bool,
        stoppingAtSkippedFetch: Bool
    ) async throws -> ResponseOrContinuationRequest? {
        while true {
            // Ask the parser to take a bite out of the accumulated buffer.
            do {
                if let response = try parser.parseResponseStream(buffer: &buffer) {
                    if case .response(.fetch(let event)) = response {
                        switch event {
                        case .start, .startUID: readingFetchResponse = true
                        case .finish: readingFetchResponse = false
                        default: break
                        }
                    }
                    return response
                }
            } catch {
                throw IMAPError.protocolViolation("IMAP parser: \(error)")
            }
            // Parser wants more bytes. Read one more line and append.
            var line = try await stream.readLine()
            if skippingUntaggedFetch,
               buffer.readableBytes == 0,
               Self.isUntaggedFetchStart(line) {
                try await discardUntaggedFetchResponse(startingWith: line)
                if stoppingAtSkippedFetch { return nil }
                continue
            }
            if readingFetchResponse || Self.isUntaggedFetchStart(line) {
                line = Self.escapingBareQuotedBackslashes(in: line)
            }
            // Detect a literal-body marker: a response ending with "{N}" or
            // "{N+}" where N is a non-negative integer. The line comes back
            // from readLine() WITHOUT its CRLF (readLine consumes it), so we
            // re-append CRLF before giving the parser the bytes, then slurp
            // N raw bytes for the literal body (which may contain CRLFs),
            // then continue the loop to read the line that follows.
            if let literalCount = Self.parseLiteralSuffix(line) {
                buffer.writeString(line + "\r\n")
                if literalCount > 0 {
                    let literalBytes = try await stream.readBytes(count: literalCount)
                    buffer.writeBytes(literalBytes)
                }
                continue
            }
            buffer.writeString(line + "\r\n")
        }
    }

    /// iCloud can return raw ISO-2022-JP envelope text with a bare backslash
    /// (for example, "\\9") in a quoted string. IMAP permits only "\\\\" and
    /// "\\\"" escapes. Preserve the bare backslash by escaping it for the parser.
    /// Only FETCH protocol lines pass here; literal payload bytes stay untouched.
    private static func escapingBareQuotedBackslashes(in line: String) -> String {
        guard line.contains("\\") else { return line }
        let bytes = Array(line.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var inQuotes = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            result.append(byte)
            if inQuotes && byte == 0x5C {
                let next = index + 1
                if next < bytes.count && (bytes[next] == 0x5C || bytes[next] == 0x22) {
                    result.append(bytes[next])
                    index += 1
                } else {
                    result.append(byte)
                }
            } else if byte == 0x22 {
                inQuotes.toggle()
            }
            index += 1
        }
        return String(decoding: result, as: UTF8.self)
    }

    private func discardUntaggedFetchResponse(startingWith firstLine: String) async throws {
        var line = firstLine
        var parenthesisBalance = Self.parenthesisDelta(in: line)
        var continuationLines = 0

        while true {
            if let literalCount = Self.parseLiteralSuffix(line) {
                if literalCount > 0 {
                    _ = try await stream.readBytes(count: literalCount)
                }
                line = try await stream.readLine()
                parenthesisBalance += Self.parenthesisDelta(in: line)
                continuationLines += 1
                continue
            }

            if parenthesisBalance <= 0 {
                return
            }
            guard continuationLines < 10_000 else {
                throw IMAPError.protocolViolation("unterminated untagged FETCH response")
            }
            line = try await stream.readLine()
            parenthesisBalance += Self.parenthesisDelta(in: line)
            continuationLines += 1
        }
    }

    /// If `line` ends with a literal marker like `...{42}` or `...{42+}`
    /// (no trailing CRLF — that's been consumed by `readLine`), return the
    /// literal byte count. Otherwise `nil`. Tolerates `+` (RFC 7888 LITERAL+
    /// / LITERAL- non-synchronizing literals).
    static func parseLiteralSuffix(_ line: String) -> Int? {
        guard line.hasSuffix("}") else { return nil }
        let withoutClose = line.dropLast()
        var plusSeen = false
        var digits = ""
        for ch in withoutClose.reversed() {
            if ch == "+" && digits.isEmpty && !plusSeen {
                plusSeen = true
                continue
            }
            if ch.isNumber {
                digits.append(ch)
                continue
            }
            if ch == "{" && !digits.isEmpty {
                return Int(String(digits.reversed()))
            }
            return nil
        }
        return nil
    }

    static func isUntaggedFetchStart(_ line: String) -> Bool {
        guard line.hasPrefix("* ") else { return false }
        var rest = line.dropFirst(2)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        rest = rest.dropFirst(digits.count)
        guard rest.first == " " else { return false }
        rest = rest.dropFirst()
        let uppercased = rest.uppercased()
        return uppercased.hasPrefix("FETCH (") || uppercased.hasPrefix("UIDFETCH (")
    }

    static func parenthesisDelta(in line: String) -> Int {
        var delta = 0
        var inQuotedString = false
        var escaped = false

        for character in line {
            if inQuotedString {
                if escaped {
                    escaped = false
                    continue
                }
                if character == "\\" {
                    escaped = true
                    continue
                }
                if character == "\"" {
                    inQuotedString = false
                }
                continue
            }

            if character == "\"" {
                inQuotedString = true
            } else if character == "(" {
                delta += 1
            } else if character == ")" {
                delta -= 1
            }
        }

        return delta
    }
}
