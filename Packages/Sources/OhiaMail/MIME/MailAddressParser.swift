import Foundation

public struct EmailAddress: Sendable, Hashable {
    public let displayName: String?
    public let localPart: String
    public let domain: String  // Unicode form
    public var displayAddress: String { "\(localPart)@\(domain)" }
    public var asciiAddress: String { "\(localPart)@\(MailAddressParser.punycode(domain))" }
    public var address: String { displayAddress }
}

extension EmailAddress {
    /// Return a copy of this parsed address with `displayName` replaced.
    /// Scope: the only public way for a caller outside OhiaMail to craft
    /// a variant of a parsed address. Keeps `EmailAddress` construction
    /// parse-first — callers cannot construct with partial/invalid data.
    public func withDisplayName(_ newName: String?) -> EmailAddress {
        EmailAddress(displayName: newName, localPart: localPart, domain: domain)
    }
}

public enum MailAddressParser {
    public enum Error: Swift.Error, Equatable {
        case empty
        case missingAtSign
        case malformed(String)
    }

    /// Parse one RFC 5322 mailbox ("display-name" <addr-spec> | addr-spec).
    public static func parseOne(_ raw: String) throws -> EmailAddress {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.empty }
        if let bracketed = try parseBracketed(trimmed) { return bracketed }
        return try parseBare(trimmed)
    }

    /// Parse a comma-separated address list, respecting quoted strings and brackets.
    public static func parseList(_ raw: String) throws -> [EmailAddress] {
        var results: [EmailAddress] = []
        var current = ""
        var inQuote = false
        var inBracket = false
        for ch in raw {
            switch ch {
            case "\"": inQuote.toggle(); current.append(ch)
            case "<" where !inQuote: inBracket = true; current.append(ch)
            case ">" where !inQuote: inBracket = false; current.append(ch)
            case "," where !inQuote && !inBracket:
                if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                    results.append(try parseOne(current))
                }
                current = ""
            default: current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            results.append(try parseOne(current))
        }
        return results
    }

    // MARK: - Private

    private static func parseBracketed(_ s: String) throws -> EmailAddress? {
        guard let ltIdx = s.firstIndex(of: "<"), let gtIdx = s.lastIndex(of: ">") else {
            return nil
        }
        let namePart = s[..<ltIdx].trimmingCharacters(in: .whitespaces)
        let addrPart = String(s[s.index(after: ltIdx)..<gtIdx])
        let displayName = stripQuotes(namePart)
        let (local, domain) = try splitAddr(addrPart)
        return EmailAddress(
            displayName: displayName.isEmpty ? nil : displayName,
            localPart: local,
            domain: domain
        )
    }

    private static func parseBare(_ s: String) throws -> EmailAddress {
        let (local, domain) = try splitAddr(s)
        return EmailAddress(displayName: nil, localPart: local, domain: domain)
    }

    private static func splitAddr(_ s: String) throws -> (String, String) {
        guard let at = s.firstIndex(of: "@") else { throw Error.missingAtSign }
        let local = String(s[..<at]).trimmingCharacters(in: .whitespaces)
        let domain = String(s[s.index(after: at)...]).trimmingCharacters(in: .whitespaces)
        guard !local.isEmpty, !domain.isEmpty, domain.contains(".") else {
            throw Error.malformed(s)
        }
        return (local, domain)
    }

    private static func stripQuotes(_ s: String) -> String {
        var out = s
        if out.hasPrefix("\"") && out.hasSuffix("\"") && out.count >= 2 {
            out.removeFirst(); out.removeLast()
        }
        return out.replacingOccurrences(of: "\\\"", with: "\"")
    }

    // MARK: - Punycode (minimal IDN support)

    /// Convert a Unicode domain to ASCII Punycode (xn--…). Pure-ASCII domains pass through.
    static func punycode(_ domain: String) -> String {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let encoded = labels.map { label -> String in
            if label.allSatisfy({ $0.isASCII }) { return label }
            return "xn--" + punycodeLabel(label)
        }
        return encoded.joined(separator: ".")
    }

    private static func punycodeLabel(_ input: String) -> String {
        // Bootstring / Punycode per RFC 3492.
        let base = 36, tmin = 1, tmax = 26, skew = 38, damp = 700, initialBias = 72
        let initialN = 128
        var n = initialN, bias = initialBias, delta = 0
        var output = ""
        var basic: [Character] = []

        for ch in input {
            if ch.isASCII { basic.append(ch) }
        }
        output.append(contentsOf: basic)
        var h = basic.count
        let b = basic.count
        if h > 0 { output.append("-") }
        let scalars = input.unicodeScalars.map { Int($0.value) }
        while h < scalars.count {
            var m = Int.max
            for c in scalars where c >= n && c < m { m = c }
            delta += (m - n) * (h + 1)
            n = m
            for c in scalars {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias)
                        if q < t { break }
                        output.append(encodeDigit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(encodeDigit(q))
                    bias = adapt(
                        delta: delta, numPoints: h + 1, firstTime: h == b,
                        damp: damp, base: base, tmin: tmin, tmax: tmax, skew: skew
                    )
                    delta = 0
                    h += 1
                }
            }
            delta += 1; n += 1
        }
        return output
    }

    private static func encodeDigit(_ d: Int) -> Character {
        Character(UnicodeScalar(d + (d < 26 ? 0x61 : 0x30 - 26))!)
    }

    private static func adapt(
        delta: Int, numPoints: Int, firstTime: Bool,
        damp: Int, base: Int, tmin: Int, tmax: Int, skew: Int
    ) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tmin) * tmax) / 2 {
            delta /= (base - tmin); k += base
        }
        return k + (base - tmin + 1) * delta / (delta + skew)
    }
}
