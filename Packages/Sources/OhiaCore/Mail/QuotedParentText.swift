import Foundation

/// Recovers the message an email directly replies to from that email's own
/// quoted history. Used when the parent itself is not in the store yet — the
/// author's sent reply can reach Ohia through a slower folder sync than the
/// correspondent's answer to it — so a reply is never written as though the
/// author's latest message did not exist.
///
/// Mail clients put the replied-to message first in the quoted history,
/// under an attribution ("On … wrote:", "2026年10月2日(金) 12:35 … <addr>:")
/// or a history divider / `From:` header block. Only that first block is
/// returned; the parent's own deeper history is cut with the same boundary
/// detectors `OriginalMessageText` applies to every stored body.
public enum QuotedParentText: Sendable {

    public struct Recovered: Sendable, Equatable {
        /// The parent's cleaned body, without its own quoted history.
        public let text: String
        /// Display name from the attribution or `From:` line, best-effort.
        public let authorName: String?
        /// Lowercased address from the attribution or `From:` line.
        public let authorAddress: String?
        /// The parent's date when the attribution or `Sent:`/`Date:` line
        /// carries one the system date detector can read.
        public let date: Date?

        public init(text: String, authorName: String?, authorAddress: String?, date: Date?) {
            self.text = text
            self.authorName = authorName
            self.authorAddress = authorAddress
            self.date = date
        }
    }

    /// Lines considered for a `From:`/`Sent:` header block beneath a divider,
    /// including wrapped recipient continuation lines.
    private static let maxHeaderBlockLines = 16

    public static func recover(from rawText: String) -> Recovered? {
        let lines = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{0085}", with: "\n")
            .components(separatedBy: "\n")

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            // Quoted lines above the first boundary belong to an interleaved
            // reply; the parent block starts only at an unquoted boundary.
            if OriginalMessageText.isQuotedLine(trimmed) { continue }
            if OriginalMessageText.isExplicitHistoryDivider(trimmed) {
                return recoverBlock(lines: Array(lines[(index + 1)...]), attribution: nil)
            }
            if OriginalMessageText.isOriginalHeaderBlockStart(lines: lines, index: index) {
                return recoverBlock(lines: Array(lines[index...]), attribution: nil)
            }
            if OriginalMessageText.isReplyBoundary(trimmed) {
                return recoverBlock(lines: Array(lines[(index + 1)...]), attribution: trimmed)
            }
            let continuations = lines.dropFirst(index + 1).prefix(2).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let joined = ReplyAttribution.joinedAttribution(leadIn: trimmed, continuations: continuations) {
                let bodyStart = index + 1 + joined.consumed
                return recoverBlock(lines: Array(lines[bodyStart...]), attribution: joined.text)
            }
        }
        return nil
    }

    private static func recoverBlock(lines: [String], attribution: String?) -> Recovered? {
        guard let firstContent = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return nil
        }

        var region = Array(lines[firstContent...])
        let firstTrimmed = region[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if OriginalMessageText.isQuotedLine(firstTrimmed) {
            region = unquotedLeadingRegion(region)
        }

        var headerAuthor: (name: String?, address: String?) = (nil, nil)
        var headerDate: Date?
        if attribution == nil || startsWithHeaderBlock(region) {
            let header = consumeHeaderBlock(region)
            region = header.remaining
            headerAuthor = header.author
            headerDate = header.date
        }

        // The shared cleaner recognizes English header blocks only; cut the
        // parent's own deeper history at a localized one first.
        if let deeper = region.indices.first(where: { OriginalMessageText.isOriginalHeaderBlockStart(lines: region, index: $0) }) {
            region = Array(region[..<deeper])
        }
        guard let text = OriginalMessageText.cleaned(from: region.joined(separator: "\n")) else {
            return nil
        }

        if let attribution {
            let parsed = ReplyAttribution.parse(attribution)
            return Recovered(
                text: text,
                authorName: parsed.author,
                authorAddress: firstAddress(in: attribution),
                date: detectedDate(in: attribution)
            )
        }
        return Recovered(
            text: text,
            authorName: headerAuthor.name,
            authorAddress: headerAuthor.address,
            date: headerDate
        )
    }

    /// The contiguous `>`-quoted run, with exactly one quoting level removed
    /// so the parent's own attribution and deeper history become top-level
    /// for `OriginalMessageText` to cut. Leading whitespace is dropped but
    /// trailing whitespace is kept so format=flowed lines still join.
    private static func unquotedLeadingRegion(_ lines: [String]) -> [String] {
        var unquoted: [String] = []
        for line in lines {
            let leadingTrimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if leadingTrimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                unquoted.append("")
                continue
            }
            guard leadingTrimmed.hasPrefix(">") else { break }
            var stripped = leadingTrimmed.dropFirst()
            if stripped.hasPrefix(" ") { stripped = stripped.dropFirst() }
            unquoted.append(String(stripped))
        }
        return unquoted
    }

    private static func startsWithHeaderBlock(_ lines: [String]) -> Bool {
        guard !lines.isEmpty else { return false }
        return OriginalMessageText.isOriginalHeaderBlockStart(lines: lines, index: 0)
    }

    /// Skips a `From:` / `Sent:` / `To:` / `Subject:` block (the shape under
    /// "-----Original Message-----" dividers, in any listed language),
    /// returning its author and date.
    private static func consumeHeaderBlock(
        _ lines: [String]
    ) -> (remaining: [String], author: (name: String?, address: String?), date: Date?) {
        var index = 0
        var name: String?
        var address: String?
        var date: Date?
        var lastField: OriginalHeaderBlock.Field?
        while index < lines.count, index < maxHeaderBlockLines {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                index += 1
                if lastField != nil { break }
                continue
            }
            // Outlook's rule above the block is part of it.
            if lastField == nil, OriginalHeaderBlock.isSeparatorRule(trimmed) {
                index += 1
                continue
            }
            guard let parsed = OriginalHeaderBlock.field(trimmed) else {
                // A wrapped recipient list continues the previous header;
                // any other line is the body and is not consumed.
                if lastField == .to || lastField == .cc {
                    index += 1
                    continue
                }
                break
            }
            switch parsed.field {
            case .from:
                address = firstAddress(in: parsed.value)
                name = ReplyAttribution.displayName(from: parsed.value)
                    .flatMap { $0.contains("@") && $0 == address ? nil : $0 }
            case .sent:
                date = detectedDate(in: parsed.value)
            case .to, .cc, .subject:
                break
            }
            lastField = parsed.field
            index += 1
        }
        return (Array(lines[min(index, lines.count)...]), (name, address), date)
    }

    /// Neither side admits `@`, so a run of `@` or of address characters
    /// fails in linear time per start position.
    private static let addressRegex = try? NSRegularExpression(
        pattern: #"[^\s<>()\[\]"',;:@]{1,64}@[^\s<>()\[\]"',;:@]{1,253}"#
    )

    private static func firstAddress(in text: String) -> String? {
        guard text.utf16.count <= 1_000, let addressRegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in addressRegex.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            // A sentence-final period is punctuation, not part of the domain.
            let candidate = String(text[swiftRange]).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let domain = candidate.split(separator: "@").last ?? ""
            if domain.contains("."), !domain.hasPrefix(".") {
                return candidate
            }
        }
        return nil
    }

    private static func detectedDate(in text: String) -> Date? {
        guard text.utf16.count <= 1_000,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.firstMatch(in: text, range: range)?.date
    }
}
