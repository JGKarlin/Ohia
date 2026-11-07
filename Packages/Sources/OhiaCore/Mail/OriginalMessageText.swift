import Foundation

public enum OriginalMessageText: Sendable {
    private struct Line {
        let text: String
        let isFlowed: Bool
    }

    /// A cleaned body for display surfaces. Never carries the `"\n..."`
    /// truncation marker — ellipsis dots are banned in displayed text —
    /// so a capped surface learns about the cut from `isTruncated` and
    /// responds with layout (scrolling, a footnote) instead of dots.
    public struct CleanedBody: Sendable, Equatable {
        public let text: String
        public let isTruncated: Bool

        public init(text: String, isTruncated: Bool) {
            self.text = text
            self.isTruncated = isTruncated
        }
    }

    /// Prompt-facing variant: identical cleaning, with the legacy `"\n..."`
    /// marker appended when `characterLimit` cuts the body. Pipeline
    /// consumers (triage, list-rule mining, reply prompts) depend on this
    /// exact shape — display surfaces use `cleanedForDisplay` instead.
    public static func cleaned(from rawText: String, characterLimit: Int? = nil) -> String? {
        guard let body = cleanedForDisplay(from: rawText, characterLimit: characterLimit) else {
            return nil
        }
        return body.isTruncated ? body.text + "\n..." : body.text
    }

    public static func cleanedForDisplay(
        from rawText: String,
        characterLimit: Int? = nil
    ) -> CleanedBody? {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{0085}", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var kept: [Line] = []
        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isReplyBoundary(trimmed)
                || isWrappedReplyBoundary(lines: lines, index: index)
                || isOriginalHeaderBlockStart(lines: lines, index: index) {
                break
            }
            guard !isQuotedLine(trimmed) else { continue }
            kept.append(
                Line(
                    text: line.trimmingCharacters(in: .whitespaces),
                    isFlowed: !trimmed.isEmpty && hasTrailingWhitespace(line)
                )
            )
        }

        let collapsed = collapse(kept)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if let characterLimit, collapsed.count > characterLimit {
            return CleanedBody(
                text: String(collapsed.prefix(max(0, characterLimit)))
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                isTruncated: true
            )
        }
        return CleanedBody(text: collapsed, isTruncated: false)
    }

    private static func collapse(_ lines: [Line]) -> String {
        var result: [String] = []
        var pendingLine: String?
        var pendingLineIsFlowed = false
        var lastWasBlank = false

        func flushPendingLine() {
            guard let lineToFlush = pendingLine else { return }
            result.append(lineToFlush)
            lastWasBlank = false
            pendingLine = nil
            pendingLineIsFlowed = false
        }

        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushPendingLine()
                if !result.isEmpty, !lastWasBlank {
                    result.append("")
                    lastWasBlank = true
                }
                continue
            }

            if let currentLine = pendingLine {
                if pendingLineIsFlowed {
                    pendingLine = currentLine + " " + trimmed
                } else {
                    flushPendingLine()
                    pendingLine = trimmed
                }
            } else {
                pendingLine = trimmed
            }
            pendingLineIsFlowed = line.isFlowed
        }
        flushPendingLine()

        while result.last?.isEmpty == true {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }

    private static func hasTrailingWhitespace(_ line: String) -> Bool {
        line.unicodeScalars.last.map { CharacterSet.whitespaces.contains($0) } == true
    }

    static func isQuotedLine(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        return trimmed.hasPrefix(">")
    }

    // Boundary detectors are internal (not private) so `QuotedHistoryTail`
    // cuts authored reply text at exactly the same boundaries this cleaner
    // uses for search/embedding text.

    /// Literal history dividers ("-----Original Message-----",
    /// "Begin forwarded message:"). Distinguished from attribution lines
    /// because the content below a divider is the *unquoted* original —
    /// there is no interleaved-reply reading of it.
    static func isExplicitHistoryDivider(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        let lowercased = trimmed.lowercased()
        let dividerCore = lowercased.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return lowercased == "-----original message-----"
            || lowercased == "begin forwarded message:"
            || dividerCore == "forwarded message"
            || dividerCore == "forwarded message:"
            || lowercased.hasPrefix("forwarded message")
            || lowercased.hasPrefix("original message")
    }

    static func isReplyBoundary(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        if isExplicitHistoryDivider(trimmed) {
            return true
        }
        // Bounded classes + a length cap keep this linear on hostile input —
        // it runs on every line of every ingested message.
        if trimmed.utf16.count <= 600,
           trimmed.range(
               of: #"^.{1,400}<[^<>\s]{1,200}>\s+wrote:$"#,
               options: .regularExpression
           ) != nil {
            return true
        }
        return ReplyAttribution.isAttributionLine(trimmed)
    }

    /// True when the line at `index` starts an attribution that hard-wrapped
    /// across the following line(s) — common in plain-text parts, where
    /// "2026年6月5日（金）17:46 名前\n<addr>:" arrives as two lines.
    static func isWrappedReplyBoundary(lines: [String], index: Int) -> Bool {
        let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        let continuations = lines.dropFirst(index + 1).prefix(2).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ReplyAttribution.joinedAttribution(leadIn: trimmed, continuations: continuations) != nil
    }

    /// An embedded original's header block, in any language a client
    /// localizes it into (`OriginalHeaderBlock`).
    static func isOriginalHeaderBlockStart(lines: [String], index: Int) -> Bool {
        OriginalHeaderBlock.starts(lines: lines, at: index)
    }
}
