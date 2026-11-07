import Foundation
import OhiaCore

/// Header-derived traffic facts used for safety gates and routing.
///
/// These values are deterministic message facts. They are not categories,
/// are never emitted by the model, and never enter `MailClassification`.
public struct DeterministicMessageTrafficFacts: Sendable, Equatable {
    public let isMailingListOrBulk: Bool
    public let isAutomated: Bool

    public var isNonHumanTraffic: Bool {
        isMailingListOrBulk || isAutomated
    }

    /// Fast safety-gate projection. Freshly ingested rows use the stored
    /// deterministic fact; nil pre-cutover rows fall back to their raw header.
    public static func isNonHumanTraffic(message: Message) -> Bool {
        message.isAutomatedOrBulk ?? Self(message: message).isNonHumanTraffic
    }

    public init(message: Message) {
        let headers = Self.structuredHeaders(at: message.rawPath)
        let hasListID = message.listId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasUnsubscribe = message.listUnsubscribeMailto != nil
            || message.listUnsubscribeURL != nil
            || message.listSupportsOneClickUnsubscribe == true
        let hasBulkPrecedence = headers["precedence"]?
            .lowercased()
            .split(whereSeparator: { character in
                character == "," || character.isWhitespace
            })
            .contains(where: { token in
                token == "bulk" || token == "list"
            }) == true
        let storedIsAutomatedOrBulk = message.isAutomatedOrBulk
        isMailingListOrBulk = hasListID || hasUnsubscribe || hasBulkPrecedence

        let autoSubmitted = headers["auto-submitted"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let rawIsAutomated = autoSubmitted?.isEmpty == false && autoSubmitted != "no"
        // The persisted ingestion fact deliberately combines the two
        // non-human causes. Preserve its safety behavior even when the raw
        // artifact is temporarily unavailable.
        isAutomated = rawIsAutomated
            || (storedIsAutomatedOrBulk == true && isMailingListOrBulk == false)
    }

    private static func structuredHeaders(at rawPath: String?) -> [String: String] {
        guard let rawPath,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: rawPath)) else {
            return [:]
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536), data.isEmpty == false,
              let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1) else {
            return [:]
        }

        var headers: [String: String] = [:]
        var currentName: String?
        for rawLine in raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            if rawLine.isEmpty { break }
            if rawLine.first?.isWhitespace == true, let currentName {
                headers[currentName, default: ""] += " "
                    + rawLine.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = rawLine.firstIndex(of: ":") else {
                currentName = nil
                continue
            }
            let name = rawLine[..<colon]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard name.isEmpty == false else { continue }
            headers[name] = rawLine[rawLine.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            currentName = name
        }
        return headers
    }
}
