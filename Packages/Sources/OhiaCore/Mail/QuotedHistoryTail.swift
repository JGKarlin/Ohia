import Foundation

/// Removes quoted-history content from reply text at two seams, using the
/// same language-agnostic boundary detection as `OriginalMessageText` /
/// `ReplyAttribution`:
///
/// - **Training** (`authoredText(from:)`): a sent reply's body from the
///   mailbox carries the mail client's quoted-history tail ("On … wrote:" +
///   "> " lines). Training on it teaches the generation model to *fabricate*
///   quoted history in drafts, assembled from whatever context the prompt
///   holds — wrong threads included. Completions must contain only the text
///   the user actually authored.
///
/// - **Generation** (`strippingTrailingQuotedBlock(from:)`): a model that
///   already learned the habit (or imitates the style reference) can emit a
///   fabricated trailing quote block. The real quoted original is appended
///   mechanically when `SendDispatcher` freezes the complete recipient-facing
///   body into the outbox, so any quoted tail in generated output is
///   fabrication by construction and is stripped.
///
/// Unlike `OriginalMessageText.cleaned(from:)` (which normalizes whitespace
/// and drops every quoted line for search/embedding text), both entry points
/// preserve the kept text verbatim — it is the user's writing (training) or
/// the send-ready body (generation).
public enum QuotedHistoryTail: Sendable {

    /// Substantive (non-quoted, non-header, non-signature) lines below the
    /// first boundary at or above which a reply is considered interleaved
    /// rather than top-posted.
    ///
    /// Two is a deliberate trade-off: at one, every top-posted reply whose
    /// tail carries a single stray unquoted line below the quote (a device
    /// signature like "Sent from my iPhone" without an RFC 3676 separator)
    /// would keep its entire quoted history in the completion. The cost is
    /// that a terse interleaved reply with exactly one one-line answer below
    /// the attribution is treated as top-posted and loses that line.
    private static let interleavedSubstantiveLineMinimum = 2

    // MARK: - Training seam

    /// The user-authored portion of a sent reply body: everything above the
    /// first quoted-history boundary, plus removal of a trailing bare quoted
    /// run when no attribution line precedes it.
    ///
    /// Interleaved replies are returned unchanged: when substantive authored
    /// lines exist *below* the boundary (the user answered inline between
    /// quoted passages), cutting at the boundary would delete the user's
    /// answers — worse than keeping the history. Signature blocks below the
    /// boundary (the "sig under quote" client setting) do not count as
    /// substantive.
    public static func authoredText(from raw: String) -> String {
        authoredText(from: raw, repliedTo: nil)
    }

    /// The training seam given the message the reply answered. Lines below an
    /// attribution that appear in that message are its history (an HTML quote
    /// flattened to plain text without ">" markers), so they never make a
    /// top-posted reply look interleaved.
    public static func authoredText(from raw: String, repliedTo original: String?) -> String {
        let lines = normalizedLines(raw)

        guard let boundary = firstBoundaryIndex(in: lines) else {
            // No attribution anywhere — still drop a trailing bare quoted
            // run (bottom-quoting clients that omit the attribution line).
            return joined(trimmingTrailingEmpties(stripTrailingQuotedRun(lines)))
        }

        // A divider / header-block boundary ("-----Original Message-----",
        // "From:/Sent:/To:/Subject:") embeds the original *unquoted* — its
        // body lines below are history, never interleaved answers, so the
        // cut is unconditional. Only ">"-quoted attributions can carry an
        // interleaved reply.
        if boundary.kind == .attribution,
           isInterleaved(lines: lines, boundary: boundary.index, history: original.map(History.init)) {
            return joined(trimmingTrailingEmpties(lines))
        }

        // A ">" run directly above the cut is history as well: Apple Mail's
        // nested quote makes a quoted "> On … wrote:" line the first boundary.
        let above = trimmingTrailingEmpties(Array(lines[..<boundary.index]))
        return joined(trimmingTrailingEmpties(stripTrailingQuotedRun(above)))
    }

    /// True when `raw` has an attribution with enough unquoted lines below it
    /// to be read as an interleaved reply: the one case where the replied-to
    /// text can change `authoredText`, so callers look it up only then.
    public static func needsRepliedToText(_ raw: String) -> Bool {
        let lines = normalizedLines(raw)
        guard let boundary = firstBoundaryIndex(in: lines), boundary.kind == .attribution else { return false }
        return isInterleaved(lines: lines, boundary: boundary.index, history: nil)
    }

    /// The immediately received message's authored content for recipient-facing
    /// quoting. Unlike `authoredText(from:)`, this removes quote scaffolding
    /// line by line so inline answers after an attribution are retained without
    /// recursively republishing the older quoted questions around them.
    public static func latestAuthoredText(from raw: String) -> String {
        let lines = normalizedLines(raw)
        var kept: [String] = []
        var index = lines.startIndex

        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if OriginalMessageText.isExplicitHistoryDivider(trimmed)
                || OriginalMessageText.isOriginalHeaderBlockStart(lines: lines, index: index) {
                break
            }
            if OriginalMessageText.isReplyBoundary(trimmed) {
                index = lines.index(after: index)
                continue
            }
            if OriginalMessageText.isWrappedReplyBoundary(lines: lines, index: index) {
                let continuations = lines.dropFirst(index + 1).prefix(2).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let consumed = ReplyAttribution.joinedAttribution(
                    leadIn: trimmed,
                    continuations: continuations
                )?.consumed ?? 0
                index = lines.index(index, offsetBy: consumed + 1)
                continue
            }
            if OriginalMessageText.isQuotedLine(trimmed) {
                index = lines.index(after: index)
                continue
            }

            kept.append(line)
            index = lines.index(after: index)
        }

        return joined(trimmingTrailingEmpties(kept))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Conservative current-message text for evidence systems where
    /// attributing history to the current author is worse than omitting an
    /// interleaved answer. Keeps the top-posted body verbatim and cuts at the
    /// first attribution, original-message divider/header block, or bare
    /// quoted line.
    public static func conservativeAuthoredText(from raw: String) -> String {
        let lines = normalizedLines(raw)
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if OriginalMessageText.isQuotedLine(trimmed)
                || OriginalMessageText.isExplicitHistoryDivider(trimmed)
                || OriginalMessageText.isOriginalHeaderBlockStart(lines: lines, index: index)
                || OriginalMessageText.isReplyBoundary(trimmed)
                || OriginalMessageText.isWrappedReplyBoundary(lines: lines, index: index) {
                return joined(trimmingTrailingEmpties(Array(lines[..<index])))
            }
        }
        return joined(trimmingTrailingEmpties(lines))
    }

    // MARK: - Generation seam

    /// Removes trailing quoted block(s) from generated text: the run of
    /// ">"-prefixed and empty lines at the end, plus the attribution line(s)
    /// directly above each run (single-line or hard-wrapped), plus any bare
    /// dangling attribution the model emitted with no quote under it.
    /// Mid-text quoting is left alone. Returns "" when the whole text is
    /// quoted — callers treat an empty body as a failed generation.
    public static func strippingTrailingQuotedBlock(from text: String) -> String {
        var lines = normalizedLines(text)

        while true {
            lines = trimmingTrailingEmpties(lines)
            let afterRun = stripTrailingQuotedRun(lines)
            guard afterRun.count < lines.count else { break }
            lines = trimmingTrailingEmpties(afterRun)
            lines = strippingTrailingAttribution(lines)
        }

        // A dangling attribution with no quote below it is still fabricated
        // scaffolding — at send the real quote lands directly under it and
        // the message would carry two attribution lines.
        while true {
            lines = trimmingTrailingEmpties(lines)
            let afterAttribution = strippingTrailingAttribution(lines)
            guard afterAttribution.count < lines.count else { break }
            lines = afterAttribution
        }

        return joined(lines)
    }

    // MARK: - Boundary scan

    private enum BoundaryKind {
        /// An "On … wrote:"-style attribution — quoted history follows, and
        /// an interleaved reply is possible.
        case attribution
        /// A literal divider or original-headers block — the unquoted
        /// original follows; never interleaved.
        case divider
    }

    private static func firstBoundaryIndex(in lines: [String]) -> (index: Int, kind: BoundaryKind)? {
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if OriginalMessageText.isExplicitHistoryDivider(trimmed)
                || OriginalMessageText.isOriginalHeaderBlockStart(lines: lines, index: index) {
                return (index, .divider)
            }
            if OriginalMessageText.isReplyBoundary(trimmed)
                || OriginalMessageText.isWrappedReplyBoundary(lines: lines, index: index) {
                return (index, .attribution)
            }
        }
        return nil
    }

    /// True when the text below `boundary` contains enough substantive
    /// authored lines that the reply is interleaved. Quoted lines, empties,
    /// original-header lines, further attribution lines, lines of the
    /// replied-to message (`History`), placeholder and rule lines, and everything
    /// from a signature separator onward are not substantive.
    private static func isInterleaved(lines: [String], boundary: Int, history: History?) -> Bool {
        var substantive = 0
        var index = lines.index(after: boundary)

        // A hard-wrapped attribution's continuation line(s) belong to the
        // attribution, not the content below it.
        let boundaryTrimmed = lines[boundary].trimmingCharacters(in: .whitespacesAndNewlines)
        if !OriginalMessageText.isReplyBoundary(boundaryTrimmed) {
            let continuations = lines.dropFirst(boundary + 1).prefix(2).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let joined = ReplyAttribution.joinedAttribution(
                leadIn: boundaryTrimmed,
                continuations: continuations
            ) {
                index = lines.index(index, offsetBy: joined.consumed)
            }
        }

        // What the line before was: a ">" line (an answer may follow it) or a
        // line of the replied-to message (a short line after it may be that
        // line's hard-wrapped tail).
        var afterQuote = false
        var previousHistoryKey: String?
        while index < lines.endIndex {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            index = lines.index(after: index)

            if trimmed == "--" {
                // RFC 3676 signature separator ("-- " trims to "--") —
                // nothing below it counts as authored content.
                break
            }
            if trimmed.isEmpty { continue }
            // An inline image's "￼" or a rule answers nothing; "○" or "×"
            // under a quoted date does.
            if isPlaceholderOrRule(trimmed) { continue }
            if OriginalMessageText.isQuotedLine(trimmed) {
                afterQuote = true
                previousHistoryKey = nil
                continue
            }
            if OriginalMessageText.isReplyBoundary(trimmed) { continue }
            if isOriginalHeaderLine(trimmed) { continue }
            if let history, history.contains(line: trimmed, afterQuote: afterQuote, previous: previousHistoryKey) {
                previousHistoryKey = History.key(trimmed)
                afterQuote = false
                continue
            }
            afterQuote = false
            previousHistoryKey = nil
            substantive += 1
            if substantive >= interleavedSubstantiveLineMinimum {
                return true
            }
        }
        return false
    }

    /// Header lines from an embedded original-message block ("From: …",
    /// "Sent: …", "To: …", "Subject: …"), in any language a client
    /// localizes them into.
    private static func isOriginalHeaderLine(_ trimmed: String) -> Bool {
        OriginalHeaderBlock.isHeaderLine(trimmed)
    }

    // MARK: - Trailing-run helpers

    /// Drops a trailing contiguous run of ">"-prefixed and empty lines when
    /// the run contains at least one quoted line; otherwise returns the
    /// input unchanged.
    private static func stripTrailingQuotedRun(_ lines: [String]) -> [String] {
        var end = lines.endIndex
        var sawQuoted = false
        while end > lines.startIndex {
            let trimmed = lines[lines.index(before: end)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                end = lines.index(before: end)
            } else if OriginalMessageText.isQuotedLine(trimmed) {
                sawQuoted = true
                end = lines.index(before: end)
            } else {
                break
            }
        }
        guard sawQuoted else { return lines }
        return Array(lines[..<end])
    }

    /// Drops the attribution ending the line array — a single attribution
    /// line, or a hard-wrapped one spanning the last two or three lines.
    private static func strippingTrailingAttribution(_ lines: [String]) -> [String] {
        guard let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
              !last.isEmpty else { return lines }

        if OriginalMessageText.isReplyBoundary(last) {
            return Array(lines.dropLast())
        }
        for span in 2...3 where lines.count >= span {
            let candidate = lines.suffix(span).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let leadIn = candidate.first,
                  ReplyAttribution.joinedAttribution(
                    leadIn: leadIn,
                    continuations: Array(candidate.dropFirst())
                  )?.consumed == span - 1 else { continue }
            return Array(lines.dropLast(span))
        }
        return lines
    }

    // MARK: - Line plumbing

    /// A line made only of inline-image placeholders (U+FFFC, U+FFFD) and
    /// rule characters.
    private static func isPlaceholderOrRule(_ trimmed: String) -> Bool {
        trimmed.allSatisfy { $0.isWhitespace || "\u{FFFC}\u{FFFD}-_=*~—–".contains($0) }
    }

    /// The replied-to message, read for its lines (its own ">" history
    /// unquoted, since a flattened quote flattens every level): a line of at
    /// least eight characters found anywhere in it is that message; so is a
    /// line equal to one of its whole lines at any length (a greeting,
    /// "Best,", a name), unless it sits right under a ">" line, where an
    /// inline answer ("Yes") belongs; and so is a short line that continues
    /// the history line above it, a hard-wrapped tail. Compared folded: case,
    /// whitespace, width, dashes and typographic quotes ignored, so a
    /// flattened "１月８日" still matches.
    private struct History {
        let text: String
        let lines: Set<String>

        init(_ original: String) {
            let unquoted = QuotedHistoryTail.normalizedLines(original).map(Self.unquoted)
            text = unquoted.map(Self.key).joined()
            lines = Set(unquoted.map(Self.key).filter { !$0.isEmpty })
        }

        func contains(line: String, afterQuote: Bool, previous: String?) -> Bool {
            let key = Self.key(line)
            if key.count >= 8 && text.contains(key) { return true }
            if !afterQuote && lines.contains(key) { return true }
            if let previous, text.contains(previous + key) { return true }
            return false
        }

        static func unquoted(_ line: String) -> String {
            var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
            while trimmed.first == ">" {
                trimmed = trimmed.dropFirst().drop { $0 == " " }
            }
            return String(trimmed)
        }

        static func key(_ text: String) -> String {
            let width = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
            var result = ""
            for character in width.lowercased() where !character.isWhitespace {
                switch character {
                case "‘", "’", "‚", "`", "´": result.append("'")
                case "“", "”", "„": result.append("\"")
                case "–", "—", "‐", "‑": result.append("-")
                default: result.append(character)
                }
            }
            return result
        }
    }

    private static func normalizedLines(_ raw: String) -> [String] {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{0085}", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func trimmingTrailingEmpties(_ lines: [String]) -> [String] {
        var end = lines.endIndex
        while end > lines.startIndex,
              lines[lines.index(before: end)]
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end = lines.index(before: end)
        }
        return Array(lines[..<end])
    }

    private static func joined(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
