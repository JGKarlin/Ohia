import Foundation

/// Canonical key for comparing RFC 5322 Message-ID values across provider,
/// IMAP ENVELOPE responses, and local SwiftData rows.
public func normalizeMessageIDHeader(_ value: String?) -> String? {
    guard var trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count > 2 {
        trimmed.removeFirst()
        trimmed.removeLast()
    }
    let collapsed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed.isEmpty ? nil : collapsed.lowercased()
}

/// True only for the stable RFC Message-ID assigned to an unsent Ohia
/// Composer mailbox draft. The UUID-shaped local part keeps ordinary or
/// spoof-like `draft-*` IDs outside this private namespace.
public func isOhiaComposerMailboxDraftMessageID(_ value: String?) -> Bool {
    guard let messageID = normalizeMessageIDHeader(value) else { return false }
    let prefix = "draft-"
    let suffix = "@ohia.local"
    guard messageID.hasPrefix(prefix), messageID.hasSuffix(suffix) else { return false }
    let uuidStart = messageID.index(messageID.startIndex, offsetBy: prefix.count)
    let uuidEnd = messageID.index(messageID.endIndex, offsetBy: -suffix.count)
    guard uuidStart < uuidEnd else { return false }
    return UUID(uuidString: String(messageID[uuidStart..<uuidEnd])) != nil
}

/// A single RFC 5322 dot-atom Message-ID suitable for interpolation into a
/// provider search operand. This is deliberately conservative: unusual or
/// malformed IDs fail closed rather than allowing whitespace or query grammar
/// characters to broaden a provider-side search.
public func canonicalProviderMessageID(_ value: String?) -> String? {
    guard var token = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          token.isEmpty == false else {
        return nil
    }
    if token.hasPrefix("<"), token.hasSuffix(">"), token.count > 2 {
        token.removeFirst()
        token.removeLast()
    }
    guard token.contains("<") == false,
          token.contains(">") == false,
          token.unicodeScalars.allSatisfy({ $0.isASCII }) else {
        return nil
    }

    let parts = token.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let local = String(parts[0])
    let domain = String(parts[1])
    guard local.isEmpty == false,
          domain.isEmpty == false,
          local.hasPrefix(".") == false,
          local.hasSuffix(".") == false,
          local.contains("..") == false,
          domain.hasPrefix(".") == false,
          domain.hasSuffix(".") == false,
          domain.contains("..") == false else {
        return nil
    }

    let localPunctuation = Set("!#$%&'*+-/=?^_`{|}~.")
    let localIsSafe = local.allSatisfy { character in
        character.isASCII && (character.isLetter || character.isNumber || localPunctuation.contains(character))
    }
    let domainIsSafe = domain.allSatisfy { character in
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == ".")
    }
    guard localIsSafe, domainIsSafe else { return nil }
    return "<\(local)@\(domain)>"
}

/// Canonical tokens from a single Message-ID or a whitespace/comma-separated
/// References/In-Reply-To value. Angle-bracketed tokens are extracted first so
/// formatting differences cannot break thread or training-parent matching.
public func normalizedMessageIDTokens(_ value: String?) -> Set<String> {
    guard let value, !value.isEmpty else { return [] }
    var tokens = Set<String>()
    var remainder = value

    while let open = remainder.firstIndex(of: "<"),
          let close = remainder[remainder.index(after: open)...].firstIndex(of: ">") {
        if let token = normalizeMessageIDHeader(String(remainder[open...close])) {
            tokens.insert(token)
        }
        remainder.removeSubrange(open...close)
    }

    for raw in remainder.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
        if let token = normalizeMessageIDHeader(String(raw)) {
            tokens.insert(token)
        }
    }
    return tokens
}
