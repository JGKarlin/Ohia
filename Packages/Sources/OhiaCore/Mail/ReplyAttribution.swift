import Foundation

/// Language-agnostic detection and parsing of quoted-reply attribution lines —
/// the "On … wrote:" / "Am … schrieb …:" / "2026年6月5日（金）17:46 …
/// <addr>:" line a mail client inserts above quoted history. Shared by
/// `OriginalMessageText` (body cleaning) and `FrontPageReplyComposer`
/// (comment-tree extraction) so both surfaces cut the history at the same
/// boundary.
///
/// Detection is structural wherever possible, but every structural form is
/// gated on hard evidence of a *date* (a plausible year) **and** a
/// time-of-day, because these regexes run on every line of every ingested
/// message: an ungated "…ends with `<addr>:`" or "…ends with a CJK quoting
/// verb" pattern matches ordinary prose ("Please send the 14:00 report to
/// ops <ops@example.com>:", "田中さんは次のように書きました：") and silently
/// truncates the real message. Real client attributions always carry the
/// full date.
///
/// All patterns use deterministic character classes (no nested ambiguous
/// quantifiers) and every entry point caps input by UTF-16 length, since the
/// input is attacker-controlled email body text and regex cost scales with
/// UTF-16 units, not grapheme count.
public enum ReplyAttribution: Sendable {

    /// Hard ceiling on the line length considered, in UTF-16 units. Real
    /// attribution lines are far shorter; longer lines are body text.
    private static let maxLineUTF16Length = 600

    /// True when the trimmed line introduces a quoted reply.
    public static func isAttributionLine(_ trimmed: String) -> Bool {
        guard trimmed.isEmpty == false, trimmed.utf16.count <= maxLineUTF16Length else { return false }
        for regex in anchoredAttributionRegexes where firstMatch(regex, in: trimmed) != nil {
            return true
        }
        // Structural forms: require date + time evidence before the
        // (per-position) suffix scans run, both as a ReDoS guard and to keep
        // prose that merely ends with "<addr>:" or a quoting verb from
        // matching.
        guard firstMatch(timeOfDayRegex, in: trimmed) != nil,
              firstMatch(yearMarkerRegex, in: trimmed) != nil else {
            return false
        }
        if firstMatch(angleAddressColonSuffixRegex, in: trimmed) != nil { return true }
        if firstMatch(cjkVerbColonSuffixRegex, in: trimmed) != nil { return true }
        return false
    }

    /// Cheap precheck for wrapped-attribution joining: true when the trimmed
    /// line *starts* like an attribution (date-led or locale lead-in word) but
    /// is not itself one — the colon-terminated tail may sit on the next line.
    public static func isLeadIn(_ trimmed: String) -> Bool {
        guard trimmed.isEmpty == false, trimmed.utf16.count <= maxLineUTF16Length else { return false }
        for regex in leadInRegexes where firstMatch(regex, in: trimmed) != nil {
            return true
        }
        return false
    }

    /// Joins a lead-in line with up to `maxContinuations` following lines and
    /// returns the merged attribution plus the number of continuation lines
    /// consumed, or `nil` when no join produces a valid attribution. Blank
    /// continuations end the attempt — an attribution never wraps across a
    /// blank line.
    public static func joinedAttribution(
        leadIn: String,
        continuations: [String],
        maxContinuations: Int = 2
    ) -> (text: String, consumed: Int)? {
        guard isLeadIn(leadIn) else { return nil }
        var joined = leadIn
        for (offset, continuation) in continuations.prefix(maxContinuations).enumerated() {
            guard continuation.isEmpty == false else { return nil }
            joined += " " + continuation
            if isAttributionLine(joined) {
                return (joined, offset + 1)
            }
        }
        return nil
    }

    /// Splits an attribution line into a display name and the date phrase.
    /// Best-effort and language-tolerant: strips the closing verb phrase and
    /// trailing colon, peels a leading CJK / numeric date-time prefix off as
    /// the date, prefers an embedded `Name <addr>` for the name, and falls
    /// back to the trailing comma-separated chunk. Anything it cannot split
    /// degrades to (nil author, whole-phrase date) — the reply still renders,
    /// just without a byline.
    public static func parse(_ attribution: String?) -> (author: String?, dateText: String?) {
        guard let attribution, attribution.isEmpty == false,
              attribution.utf16.count <= maxLineUTF16Length else {
            return (nil, nil)
        }

        var inner = attribution
        if let verbRange = inner.range(
            of: #"\s*(wrote|schrieb|a écrit|escribió|écrit|写道|書きました|のメッセージ|님이 작성)\s*[:：]?\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            inner.removeSubrange(verbRange)
        }
        // Gmail's locale-agnostic "… <addr>:" form has no verb — strip a bare
        // trailing colon (half- or full-width).
        if inner.hasSuffix(":") || inner.hasSuffix("：") {
            inner.removeLast()
        }
        inner = inner.replacingOccurrences(
            of: #"^(On|Am|Le|El|在)\s+"#,
            with: "",
            options: [.regularExpression]
        )
        inner = inner.trimmingCharacters(in: .whitespaces)
        guard inner.isEmpty == false else { return (nil, attribution) }

        // A CJK or numeric date-time prefix ("2026年6月5日（金）17:46",
        // "2026/06/05 9:00") is the date phrase; the remainder is the sender.
        if let prefix = firstMatch(dateTimePrefixRegex, in: inner),
           let prefixRange = Range(prefix.range, in: inner) {
            let dateText = String(inner[prefixRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: ",、 \t"))
            let remainder = String(inner[prefixRange.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: ",、 \t"))
            guard remainder.isEmpty == false else {
                return (nil, dateText.isEmpty ? nil : dateText)
            }
            return (displayName(from: remainder), dateText.isEmpty ? nil : dateText)
        }

        // Prefer an explicit "Display Name <addr>".
        if let nameAddr = firstMatch(displayNameAddressRegex, in: inner),
           let whole = Range(nameAddr.range, in: inner) {
            let chunk = String(inner[whole]).trimmingCharacters(in: .whitespaces)
            let name = displayName(from: chunk)
            let dateText = inner.replacingCharacters(in: whole, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: ", \t"))
            return (name, dateText.isEmpty ? nil : dateText)
        }

        // Otherwise treat the trailing comma-separated chunk as the name.
        if let lastComma = inner.range(of: ",", options: .backwards) {
            let name = String(inner[lastComma.upperBound...]).trimmingCharacters(in: .whitespaces)
            let dateText = String(inner[..<lastComma.lowerBound]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty == false {
                return (cleanName(name), dateText.isEmpty ? nil : dateText)
            }
        }

        // No separable name: surface the whole phrase as the date line.
        return (nil, inner)
    }

    /// "Alice Smith <a@x.com>" → "Alice Smith"; bare "<a@x.com>" → "a".
    public static func displayName(from chunk: String) -> String? {
        if let angle = chunk.range(of: "<") {
            let before = String(chunk[..<angle.lowerBound]).trimmingCharacters(
                in: CharacterSet(charactersIn: "\"' \t")
            )
            if before.isEmpty == false { return before }
            let addr = chunk[angle.upperBound...].prefix { $0 != ">" }
            let local = addr.split(separator: "@").first.map(String.init)
            return local?.isEmpty == false ? local : nil
        }
        return cleanName(chunk)
    }

    private static func cleanName(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Regex cache

    private static func firstMatch(
        _ regex: NSRegularExpression?,
        in string: String
    ) -> NSTextCheckingResult? {
        guard let regex else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.firstMatch(in: string, range: range)
    }

    /// An angle-bracket address: the local part cannot contain `<`, `>`, `@`,
    /// or whitespace and the domain cannot contain `<`, `>`, or whitespace, so
    /// the match is deterministic — no quantifier ambiguity to backtrack over.
    private static let angleAddressPattern = #"<[^<>@\s]{1,200}@[^<>\s]{1,200}>"#

    private static let displayNameAddressRegex = try? NSRegularExpression(
        pattern: #"[^,<]{0,200}"# + angleAddressPattern
    )

    /// A time-of-day ("17:46"), not embedded in a longer digit run.
    private static let timeOfDayRegex = try? NSRegularExpression(
        pattern: #"(?<!\d)\d{1,2}:\d{2}(?!\d)"#
    )

    /// A plausible calendar year — the date evidence required before any
    /// structural suffix form may match. Mail clients always include the year
    /// in attributions.
    private static let yearMarkerRegex = try? NSRegularExpression(
        pattern: #"(?<!\d)(19|20)\d{2}(?!\d)"#
    )

    /// Locale-agnostic Gmail structure: ends with an angle-bracket address and
    /// a colon ("… 名前 <addr>:"). Only consulted after the date + time gate.
    private static let angleAddressColonSuffixRegex = try? NSRegularExpression(
        pattern: angleAddressPattern + #"\s*[:：]$"#
    )

    /// CJK / Korean quoting-verb endings (Gmail zh "… 写道：", ja 書きました,
    /// Apple Mail ja "… のメッセージ:", Gmail ko "… 님이 작성:"). Only
    /// consulted after the date + time gate — Japanese is verb-final, so
    /// ordinary prose can end with these verbs too.
    private static let cjkVerbColonSuffixRegex = try? NSRegularExpression(
        pattern: #"(写道|書きました|のメッセージ|님이 작성)\s*[:：]$"#
    )

    /// Leading CJK / numeric date-time phrase: "2026年6月5日（金）17:46",
    /// "2026년 6월 5일 (금) 17:46", "2026/06/05 9:00", with optional weekday
    /// parenthetical, optional am/pm marker, and optional seconds.
    private static let dateTimePrefixRegex = try? NSRegularExpression(
        pattern: #"^(?:\d{4}[年년]\s*\d{1,2}[月월]\s*\d{1,2}[日일]|\d{4}[/.-]\d{1,2}[/.-]\d{1,2})\s*(?:[（(][^（）()]{1,4}[）)]|周.|週.)?\s*[,、]?\s*(?:午前|午後|上午|下午|오전|오후)?\s*\d{1,2}:\d{2}(?::\d{2})?"#
    )

    /// Start-anchored per-locale forms. The `.{1,400}` interiors are bounded
    /// single quantifiers against literal anchored tails — linear backtracking
    /// under the UTF-16 length cap.
    private static let anchoredAttributionRegexes: [NSRegularExpression] = {
        let patterns = [
            #"^On .{1,400} wrote:$"#,
            #"^Am .{1,400} schrieb.*:$"#,
            #"^Le .{1,400} a écrit\s*:$"#,
            #"^El .{1,400} escribió\s*:$"#,
            #"^.{0,400}"# + angleAddressPattern + #"\s+wrote:$"#,
            // Full CJK date + weekday + time ending with a colon, address
            // optional (sender shown by name only). The date is inherent to
            // the pattern, so it needs no separate gate.
            #"^\d{4}[年년]\s*\d{1,2}[月월]\s*\d{1,2}[日일]\s*[（(][^（）()]{1,4}[）)]\s*\d{1,2}:\d{2}.{0,300}[:：]$"#
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    /// Starts of attributions that may have wrapped: a leading date (CJK or
    /// numeric) or a locale lead-in word followed by a digit somewhere.
    private static let leadInRegexes: [NSRegularExpression] = {
        let patterns = [
            #"^\d{4}[年년]\s*\d{1,2}[月월]\s*\d{1,2}[日일]"#,
            #"^\d{4}[/.-]\d{1,2}[/.-]\d{1,2}\b"#,
            #"^(On|Am|Le|El|在)\s.{0,400}\d"#
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()
}
