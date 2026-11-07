import Foundation

/// A parsed and normalized email participant (address-list entry).
public struct NormalizedParticipant: Sendable, Equatable {
    /// Lowercased email address.
    public let email: String
    /// Display name, if present.
    public let name: String?
    /// Domain portion of the email address (lowercased).
    public let domain: String

    public init(email: String, name: String? = nil) {
        let lowered = email.lowercased()
        self.email = lowered
        self.name = name
        self.domain = lowered.components(separatedBy: "@").last ?? ""
    }
}

/// Parses RFC 5322 address-list header values into structured participants.
public enum ParticipantNormalizer {

    /// Parse an RFC 5322 address-list string (e.g. the value of To:, From:, Cc:).
    ///
    /// Handles:
    /// - `"Display Name" <user@example.com>`
    /// - `Display Name <user@example.com>`
    /// - `user@example.com`
    ///
    /// Multiple entries separated by commas are supported.
    ///
    /// - Parameter headerValue: Raw header value string.
    /// - Returns: Array of `NormalizedParticipant` values; empty if none could be parsed.
    public static func parse(_ headerValue: String) -> [NormalizedParticipant] {
        // Split on commas that are NOT inside angle brackets or quoted strings.
        let entries = splitAddressList(headerValue)
        return entries.compactMap { parseEntry($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - Private helpers

    /// Splits an address list on top-level commas (not inside <> or "").
    private static func splitAddressList(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0   // angle-bracket depth
        var inQuote = false

        for ch in input {
            switch ch {
            case "\"":
                inQuote.toggle()
                current.append(ch)
            case "<" where !inQuote:
                depth += 1
                current.append(ch)
            case ">" where !inQuote:
                depth -= 1
                current.append(ch)
            case "," where !inQuote && depth == 0:
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            default:
                current.append(ch)
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append(trimmed) }

        return result
    }

    /// Parse a single address-list entry.
    private static func parseEntry(_ entry: String) -> NormalizedParticipant? {
        // Pattern: optional-name <email>
        if let angleBracketRange = entry.range(of: "<"),
           let closingBracket = entry.range(of: ">") {
            let emailStart = entry.index(after: angleBracketRange.lowerBound)
            guard emailStart < closingBracket.lowerBound else { return nil }
            let email = String(entry[emailStart..<closingBracket.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard isValidEmail(email) else { return nil }

            let namePart = String(entry[entry.startIndex..<angleBracketRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let name = extractDisplayName(namePart)

            return NormalizedParticipant(email: email, name: name)
        }

        // Pattern: bare email address
        let candidate = entry.trimmingCharacters(in: .whitespaces)
        if isValidEmail(candidate) {
            return NormalizedParticipant(email: candidate, name: nil)
        }

        return nil
    }

    /// Strip surrounding quotes from a display name.
    private static func extractDisplayName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Remove surrounding double-quotes
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
            let inner = String(trimmed.dropFirst().dropLast())
            let unescaped = inner.replacingOccurrences(of: "\\\"", with: "\"")
            return unescaped.isEmpty ? nil : unescaped
        }
        return trimmed
    }

    /// Minimal email validity check: contains exactly one "@" with non-empty local and domain.
    private static func isValidEmail(_ candidate: String) -> Bool {
        let parts = candidate.components(separatedBy: "@")
        guard parts.count == 2 else { return false }
        return !parts[0].isEmpty && !parts[1].isEmpty
    }
}
