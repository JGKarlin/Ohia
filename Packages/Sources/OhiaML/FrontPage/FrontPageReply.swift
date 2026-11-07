import Foundation
import OhiaCore

/// One prior message in a Front Page reader's "Replies" comment section: the
/// newspaper-comment unit rendered beneath the focused article. Produced by
/// `FrontPageReplyComposer` from either the ingested conversation
/// (`buildTree`, the primary source) or, when the conversation is not in the
/// store, by parsing the focused message's own quoted body (`extractInBody`,
/// the fallback). Either source yields the same flat-with-`depth` shape so the
/// view renders one indented reply tree regardless of provenance.
///
/// `date` is the clean received/sent timestamp when the message is in the
/// store; for an in-body-extracted reply it is `nil` and `rawDateText` carries
/// the attribution line's date phrase verbatim (any language) so the byline
/// still reads. `author` is `nil` only when an attribution line could not be
/// parsed — the reply still appears (it was found by quote structure, not by
/// language), it simply renders without a name.
public struct FrontPageReplyNode: Sendable, Identifiable, Equatable {
    public let id: String
    public let author: String?
    public let isSentByUser: Bool
    public let date: Date?
    public let rawDateText: String?
    public let bodyText: String
    /// Indentation level in the reply tree. `0` is the oldest / least-indented
    /// reply at the top; each nested reply increments by one (newest deepest).
    public let depth: Int

    public init(
        id: String,
        author: String?,
        isSentByUser: Bool,
        date: Date?,
        rawDateText: String?,
        bodyText: String,
        depth: Int
    ) {
        self.id = id
        self.author = author
        self.isSentByUser = isSentByUser
        self.date = date
        self.rawDateText = rawDateText
        self.bodyText = bodyText
        self.depth = depth
    }
}

/// A single ingested message in the focused article's conversation, reduced to
/// the fields `FrontPageReplyComposer.buildTree` needs. The app resolves each
/// message's *own* content (quotes stripped) into `bodyText` before calling the
/// pure builder, so the builder stays free of file I/O and is unit-testable.
public struct FrontPageThreadDescriptor: Sendable, Equatable {
    /// Stable identity (the message's UUID string). Distinct from `messageID`,
    /// the RFC 5322 `Message-ID` header used for parent resolution.
    public let id: String
    public let messageID: String?
    public let inReplyTo: String?
    public let references: [String]
    public let author: String?
    public let isSentByUser: Bool
    public let date: Date?
    public let bodyText: String

    public init(
        id: String,
        messageID: String?,
        inReplyTo: String?,
        references: [String],
        author: String?,
        isSentByUser: Bool,
        date: Date?,
        bodyText: String
    ) {
        self.id = id
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.author = author
        self.isSentByUser = isSentByUser
        self.date = date
        self.bodyText = bodyText
    }
}

/// Pure, deterministic composer for the Front Page reader's threaded comment
/// section. Two entry points, mirroring the hybrid source the user chose:
///
///   1. `buildTree(descriptors:focusedID:)` — **primary.** Reconstructs the
///      conversation from the ingested thread using `In-Reply-To` / `References`
///      parentage, excludes the focused message (it is the article above), and
///      re-parents its replies into its slot so the tree stays connected.
///   2. `extractInBody(plainText:)` — **fallback,** used when the store has no
///      other messages in the thread. Splits the focused message's own quoted
///      history into a linear reply chain by attribution lines and quote depth.
///
/// Both return `[FrontPageReplyNode]` in render order: oldest first, depth
/// increasing as the conversation nests toward the present.
public enum FrontPageReplyComposer {

    // MARK: - Primary: ingested thread → reply tree

    /// Builds the indented reply tree from the ingested conversation.
    /// `focusedID` is the article being read; it is omitted from the output and
    /// its children are promoted into its position so the chain reads
    /// continuously. Siblings are ordered oldest-first; depth is distance from
    /// a root (a message whose parent is not in the set).
    public static func buildTree(
        descriptors: [FrontPageThreadDescriptor],
        focusedID: String
    ) -> [FrontPageReplyNode] {
        guard descriptors.isEmpty == false else { return [] }

        let topology = ThreadTopology(descriptors: descriptors)

        var childrenByParent: [String: [FrontPageThreadDescriptor]] = [:]
        var roots: [FrontPageThreadDescriptor] = []
        for descriptor in descriptors {
            if let parent = topology.parentID(of: descriptor), topology.idSet.contains(parent) {
                childrenByParent[parent, default: []].append(descriptor)
            } else {
                roots.append(descriptor)
            }
        }

        var result: [FrontPageReplyNode] = []
        var visited: Set<String> = []

        func visit(_ descriptor: FrontPageThreadDescriptor, depth: Int) {
            guard visited.insert(descriptor.id).inserted else { return } // cycle guard
            let isFocused = (descriptor.id == focusedID)
            let childDepth: Int
            if isFocused {
                // The focused message is the article above; skip it but keep
                // its replies at its own depth so they take its place.
                childDepth = depth
            } else {
                result.append(node(from: descriptor, depth: depth))
                childDepth = depth + 1
            }
            for child in sortedOldestFirst(childrenByParent[descriptor.id] ?? []) {
                visit(child, depth: childDepth)
            }
        }

        for root in sortedOldestFirst(roots) {
            visit(root, depth: 0)
        }
        // Safety net: a malformed parentage cycle can leave every message a
        // child (no root), or a subgraph unreachable. Never silently drop a
        // message — sweep any unvisited descriptor in as a depth-0 root.
        for descriptor in sortedOldestFirst(descriptors) where visited.contains(descriptor.id) == false {
            visit(descriptor, depth: 0)
        }
        return result
    }

    /// Returns the visible focused message whose reply section should display
    /// `targetID`. Used by Front Page search when the exact/nearby hit is a
    /// sent reply: sent mail is not its own Front Page article, so navigation
    /// should open the closest eligible ancestor article that contains it.
    public static func focusIDDisplayingReply(
        targetID: String,
        descriptors: [FrontPageThreadDescriptor],
        eligibleFocusIDs: Set<String>
    ) -> String? {
        guard eligibleFocusIDs.isEmpty == false else { return nil }
        if eligibleFocusIDs.contains(targetID) { return targetID }

        let topology = ThreadTopology(descriptors: descriptors)
        guard topology.descriptorByID[targetID] != nil else { return nil }

        var visited: Set<String> = []
        var cursor = topology.parentID(ofID: targetID)
        while let candidateID = cursor, visited.insert(candidateID).inserted {
            if eligibleFocusIDs.contains(candidateID) {
                return candidateID
            }
            cursor = topology.parentID(ofID: candidateID)
        }

        return sortedDisplayFallbacks(
            targetID: targetID,
            descriptors: descriptors,
            eligibleFocusIDs: eligibleFocusIDs,
            topology: topology
        ).first?.id
    }

    private static func sortedDisplayFallbacks(
        targetID: String,
        descriptors: [FrontPageThreadDescriptor],
        eligibleFocusIDs: Set<String>,
        topology: ThreadTopology
    ) -> [FrontPageThreadDescriptor] {
        guard let target = topology.descriptorByID[targetID] else { return [] }
        let targetDate = target.date
        return descriptors
            .filter { eligibleFocusIDs.contains($0.id) }
            .filter { candidate in
                buildTree(descriptors: descriptors, focusedID: candidate.id)
                    .contains { $0.id == targetID }
            }
            .sorted { lhs, rhs in
                fallbackSortPrecedes(lhs, rhs, targetDate: targetDate)
            }
    }

    private static func fallbackSortPrecedes(
        _ lhs: FrontPageThreadDescriptor,
        _ rhs: FrontPageThreadDescriptor,
        targetDate: Date?
    ) -> Bool {
        guard let targetDate else { return sortedOldestFirst([lhs, rhs]).first?.id == lhs.id }
        switch (lhs.date, rhs.date) {
        case let (l?, r?):
            let lAfter = l >= targetDate
            let rAfter = r >= targetDate
            if lAfter != rAfter { return lAfter }
            let lDistance = abs(l.timeIntervalSince(targetDate))
            let rDistance = abs(r.timeIntervalSince(targetDate))
            if lDistance != rDistance { return lDistance < rDistance }
            return lhs.id < rhs.id
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.id < rhs.id
        }
    }

    private static func node(from descriptor: FrontPageThreadDescriptor, depth: Int) -> FrontPageReplyNode {
        FrontPageReplyNode(
            id: descriptor.id,
            author: descriptor.author,
            isSentByUser: descriptor.isSentByUser,
            date: descriptor.date,
            rawDateText: nil,
            bodyText: descriptor.bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
            depth: depth
        )
    }

    private static func sortedOldestFirst(
        _ descriptors: [FrontPageThreadDescriptor]
    ) -> [FrontPageThreadDescriptor] {
        descriptors.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (l?, r?):
                return l == r ? lhs.id < rhs.id : l < r
            case (nil, _?):
                return false        // undated sorts after dated
            case (_?, nil):
                return true
            case (nil, nil):
                return lhs.id < rhs.id
            }
        }
    }

    /// Normalizes an RFC `Message-ID` for matching: strips angle brackets and
    /// surrounding whitespace. Returns `nil` for empty/absent ids.
    static func normalizedID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(
            in: CharacterSet(charactersIn: "<> ").union(.whitespacesAndNewlines)
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct ThreadTopology {
        let descriptorByID: [String: FrontPageThreadDescriptor]
        let idSet: Set<String>
        private let byMessageID: [String: FrontPageThreadDescriptor]

        init(descriptors: [FrontPageThreadDescriptor]) {
            var descriptorByID: [String: FrontPageThreadDescriptor] = [:]
            for descriptor in descriptors where descriptorByID[descriptor.id] == nil {
                descriptorByID[descriptor.id] = descriptor
            }
            self.descriptorByID = descriptorByID
            self.idSet = Set(descriptors.map(\.id))

            var byMessageID: [String: FrontPageThreadDescriptor] = [:]
            for descriptor in descriptors {
                guard let messageID = FrontPageReplyComposer.normalizedID(descriptor.messageID) else { continue }
                // First writer wins so a duplicated Message-ID can't shadow the
                // earlier row; parentage stays deterministic.
                if byMessageID[messageID] == nil { byMessageID[messageID] = descriptor }
            }
            self.byMessageID = byMessageID
        }

        func parentID(ofID id: String) -> String? {
            guard let descriptor = descriptorByID[id] else { return nil }
            return parentID(of: descriptor)
        }

        func parentID(of descriptor: FrontPageThreadDescriptor) -> String? {
            if let inReplyTo = FrontPageReplyComposer.normalizedID(descriptor.inReplyTo),
               let parent = byMessageID[inReplyTo],
               parent.id != descriptor.id {
                return parent.id
            }
            // Fall back to the nearest ancestor named in References (last entry
            // is the immediate parent per RFC 5322 §3.6.4).
            for reference in descriptor.references.reversed() {
                if let normalized = FrontPageReplyComposer.normalizedID(reference),
                   let parent = byMessageID[normalized],
                   parent.id != descriptor.id {
                    return parent.id
                }
            }
            return nil
        }
    }

    // MARK: - Fallback: in-body quoted history → linear reply chain

    /// Parses the focused message's own plain-text body into a reply chain when
    /// the conversation is not in the store. The top post (before the quoted
    /// history) is dropped — it is rendered as the article — and the quoted
    /// history is segmented into one node per prior message, oldest (deepest)
    /// first: by **`>` quote-nesting depth** for clients that re-quote, and by
    /// **attribution lines alone** for no-requote clients that paste the prior
    /// message verbatim (common in Japanese mail). A sender's text that wraps
    /// around a nested quote is reassembled into that sender's node.
    ///
    /// Detection is structural: an attribution line *or* a sustained `>`-quoted
    /// block opens the history, so non-English mail still yields replies — only
    /// the per-reply byline degrades to "unknown author" when the attribution
    /// phrase can't be parsed. (Honours the no-English-only-paths rule.)
    public static func extractInBody(plainText: String) -> [FrontPageReplyNode] {
        let normalized = normalizeLineBreaks(plainText)
        let lines = mergingWrappedAttributions(normalized.components(separatedBy: "\n"))
        guard let start = firstHistoryIndex(in: lines) else { return [] }

        if isOriginalHeaderBlockStart(lines: lines, index: start) {
            let headerNodes = extractOriginalHeaderBlockReplies(lines: lines, start: start)
            if headerNodes.isEmpty == false { return headerNodes }
        }

        // Walk the history sequentially. A reply normally lives at quote
        // depth `q` (its content is `q` levels of `>` deep) with the
        // attribution that names its author one level shallower; but clients
        // that don't re-quote leave the prior message's text *at the
        // attribution's own depth* ("no-requote" — common for Japanese mail,
        // where the plain-text part carries the quoted history verbatim). The
        // sequential walk supports both: an attribution opens a reply
        // expecting depth `q+1`; if content then arrives at depth `q` before
        // any `q+1` content, the reply is no-requote and depth-`q` lines
        // belong to it until the next attribution. Otherwise depth-`d` lines
        // join the most recent reply expecting depth `d` — which is also how
        // a sender's text reassembles around a nested quote.
        final class ReplyBuilder {
            let order: Int
            let attribution: String?
            let expectedDepth: Int
            var lines: [String] = []
            var sawExpectedDepthContent = false
            init(order: Int, attribution: String?, expectedDepth: Int) {
                self.order = order
                self.attribution = attribution
                self.expectedDepth = expectedDepth
            }
        }

        var builders: [ReplyBuilder] = []
        var candidate: ReplyBuilder?      // most recent attribution-opened reply
        var noRequote: ReplyBuilder?      // candidate confirmed as no-requote
        var noRequoteDepth = 0

        for rawLine in lines[start...] {
            let q = quoteDepth(rawLine)
            let stripped = strippingQuoteMarkers(rawLine)
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)

            if isAttributionLine(trimmed) {
                let builder = ReplyBuilder(
                    order: builders.count,
                    attribution: trimmed,
                    expectedDepth: q + 1
                )
                builders.append(builder)
                candidate = builder
                noRequote = nil
                continue
            }

            if trimmed.isEmpty {
                // Blank lines keep paragraph breaks inside whichever reply is
                // absorbing this depth, but never open one.
                if let noRequote, q == noRequoteDepth {
                    noRequote.lines.append("")
                } else if q >= 1, let existing = builders.last(where: { $0.expectedDepth == q }) {
                    existing.lines.append("")
                }
                continue
            }

            if let noRequote, q == noRequoteDepth {
                noRequote.lines.append(stripped)
            } else if let candidate, candidate.sawExpectedDepthContent == false,
                      q == candidate.expectedDepth - 1 {
                // First content after the attribution stayed at the
                // attribution's own depth: a no-requote client.
                noRequote = candidate
                noRequoteDepth = q
                candidate.lines.append(stripped)
            } else if q >= 1 {
                if let existing = builders.last(where: { $0.expectedDepth == q }) {
                    existing.lines.append(stripped)
                } else {
                    let anonymous = ReplyBuilder(
                        order: builders.count,
                        attribution: nil,
                        expectedDepth: q
                    )
                    anonymous.lines.append(stripped)
                    builders.append(anonymous)
                }
            }
            // Depth-0 lines with no open no-requote reply (e.g. a trailing
            // signature after a fully-quoted history) belong to no reply.

            if let candidate, q >= candidate.expectedDepth {
                candidate.sawExpectedDepthContent = true
            }
        }

        // Render oldest first, least-indented at the top: deepest quote level
        // first; within a level (an unquoted linear chain), later attributions
        // are older messages.
        let ordered = builders.sorted { lhs, rhs in
            if lhs.expectedDepth != rhs.expectedDepth { return lhs.expectedDepth > rhs.expectedDepth }
            return lhs.order > rhs.order
        }
        var nodes: [FrontPageReplyNode] = []
        for builder in ordered {
            let body = collapseBody(builder.lines)
            if body.isEmpty && builder.attribution == nil { continue }
            let parsed = parseAttribution(builder.attribution)
            nodes.append(
                FrontPageReplyNode(
                    id: "inbody-\(builder.order)",
                    author: parsed.author,
                    isSentByUser: false,
                    date: nil,
                    rawDateText: parsed.dateText,
                    bodyText: body,
                    depth: nodes.count
                )
            )
        }
        return nodes
    }

    private static func normalizeLineBreaks(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{0085}", with: "\n")
    }

    private struct OriginalHeaderBlock {
        let startIndex: Int
        let author: String?
        let dateText: String?
        let bodyStart: Int
    }

    private struct PendingReplyNode {
        let id: String
        let author: String?
        let dateText: String?
        let body: String
    }

    private static func extractOriginalHeaderBlockReplies(
        lines: [String],
        start: Int
    ) -> [FrontPageReplyNode] {
        var groups: [[PendingReplyNode]] = []
        var index = start

        while index < lines.count {
            guard let header = parseOriginalHeaderBlock(lines: lines, index: index) else {
                index += 1
                continue
            }

            var nextHeader = header.bodyStart
            while nextHeader < lines.count {
                if isOriginalHeaderBlockStart(lines: lines, index: nextHeader) { break }
                nextHeader += 1
            }

            let split = splitOriginalHeaderBody(
                lines: lines[header.bodyStart..<nextHeader]
            )
            let body = collapseBody(trimOriginalHeaderBodyLines(split.ownLines))
            var group = split.nestedReplies
            if body.isEmpty == false || header.author != nil || header.dateText != nil {
                group.append(
                    PendingReplyNode(
                        id: "inbody-header-\(header.startIndex)",
                        author: header.author,
                        dateText: header.dateText,
                        body: body
                    )
                )
            }
            if group.isEmpty == false {
                groups.append(group)
            }

            index = max(nextHeader, index + 1)
        }

        let pending = groups.reversed().flatMap { $0 }
        var nodes: [FrontPageReplyNode] = []
        nodes.reserveCapacity(pending.count)
        for (renderDepth, node) in pending.enumerated() {
            nodes.append(
                FrontPageReplyNode(
                    id: node.id,
                    author: node.author,
                    isSentByUser: false,
                    date: nil,
                    rawDateText: node.dateText,
                    bodyText: node.body,
                    depth: renderDepth
                )
            )
        }
        return nodes
    }

    private static func splitOriginalHeaderBody(
        lines rawLines: ArraySlice<String>
    ) -> (ownLines: [String], nestedReplies: [PendingReplyNode]) {
        guard rawLines.isEmpty == false else { return ([], []) }
        for index in rawLines.indices {
            let stripped = strippingQuoteMarkers(rawLines[index])
            let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAttributionLine(trimmed) else { continue }
            let ownLines = rawLines[..<index].map(strippingQuoteMarkers)
            let nestedReplies = extractNestedAttributionReplies(from: rawLines[index...])
            return (ownLines, nestedReplies)
        }
        return (rawLines.map(strippingQuoteMarkers), [])
    }

    private static func extractNestedAttributionReplies(
        from rawLines: ArraySlice<String>
    ) -> [PendingReplyNode] {
        var replies: [PendingReplyNode] = []
        var index = rawLines.startIndex
        while index < rawLines.endIndex {
            let stripped = strippingQuoteMarkers(rawLines[index])
            let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAttributionLine(trimmed) else {
                index = rawLines.index(after: index)
                continue
            }

            var next = rawLines.index(after: index)
            while next < rawLines.endIndex {
                let nextTrimmed = strippingQuoteMarkers(rawLines[next])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if isAttributionLine(nextTrimmed) { break }
                next = rawLines.index(after: next)
            }

            let body = collapseBody(
                trimOriginalHeaderBodyLines(
                    rawLines[rawLines.index(after: index)..<next].map(strippingQuoteMarkers)
                )
            )
            let parsed = parseAttribution(trimmed)
            if body.isEmpty == false || parsed.author != nil || parsed.dateText != nil {
                replies.append(
                    PendingReplyNode(
                        id: "inbody-attribution-\(index)",
                        author: parsed.author,
                        dateText: parsed.dateText,
                        body: body
                    )
                )
            }
            index = next
        }
        return replies.reversed()
    }

    private static func parseOriginalHeaderBlock(
        lines: [String],
        index: Int
    ) -> OriginalHeaderBlock? {
        guard isOriginalHeaderBlockStart(lines: lines, index: index) else { return nil }

        var cursor = index
        var author: String?
        var dateText: String?
        var sawHeaderField = false

        while cursor < lines.count {
            let line = strippingQuoteMarkers(lines[cursor])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty {
                cursor += 1
                if sawHeaderField { break }
                continue
            }

            // Outlook's rule above the block is part of it.
            if !sawHeaderField, isThreadSeparatorLine(line) {
                cursor += 1
                continue
            }
            guard let field = originalHeaderField(line) else {
                break
            }

            sawHeaderField = true
            switch field.field {
            case .from:
                author = displayName(from: field.value)
            case .sent:
                if dateText == nil {
                    let trimmedDate = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    dateText = trimmedDate.isEmpty ? nil : trimmedDate
                }
            default:
                break
            }
            cursor += 1
        }

        while cursor < lines.count {
            let line = strippingQuoteMarkers(lines[cursor])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || isThreadSeparatorLine(line) {
                cursor += 1
            } else {
                break
            }
        }

        return OriginalHeaderBlock(
            startIndex: index,
            author: author,
            dateText: dateText,
            bodyStart: cursor
        )
    }

    private static func originalHeaderField(_ line: String) -> (field: OhiaCore.OriginalHeaderBlock.Field, value: String)? {
        OhiaCore.OriginalHeaderBlock.field(line)
    }

    private static func trimOriginalHeaderBodyLines(_ lines: [String]) -> [String] {
        var start = lines.startIndex
        var end = lines.endIndex

        while start < end {
            let trimmed = lines[start].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || isThreadSeparatorLine(trimmed) {
                start = lines.index(after: start)
            } else {
                break
            }
        }

        while start < end {
            let beforeEnd = lines.index(before: end)
            let trimmed = lines[beforeEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || isThreadSeparatorLine(trimmed) {
                end = beforeEnd
            } else {
                break
            }
        }

        return Array(lines[start..<end])
    }

    private static func isThreadSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5 else { return false }
        return trimmed.allSatisfy { character in
            character == "_" || character == "-" || character == "=" || character == "—"
        }
    }

    /// Index of the first line that begins the quoted history. The **strong**
    /// signal — an attribution line or an Outlook-style "From:/Sent:/To:/Subject:"
    /// header block — wins wherever it appears. Only when none exists does a
    /// `>`-quote block count, and then only a **sustained** one (≥ 2 quoted
    /// lines), so a lone `>` line in the sender's own prose (a quoted snippet,
    /// Markdown blockquote, or "a > b") never prematurely cuts the body.
    /// `nil` when the body has no quoted history (e.g. a newsletter).
    private static func firstHistoryIndex(in lines: [String]) -> Int? {
        for index in lines.indices {
            let unquoted = strippingQuoteMarkers(lines[index]).trimmingCharacters(in: .whitespaces)
            if isAttributionLine(unquoted) { return index }
            if isOriginalHeaderBlockStart(lines: lines, index: index) { return index }
        }
        return firstSustainedQuoteBlockIndex(in: lines)
    }

    /// Start index of the first run of ≥ 2 `>`-quoted lines (blank lines are
    /// permitted between them, as quoted mail often interleaves blanks); `nil`
    /// if no such block exists. A single isolated quoted line is not enough.
    private static func firstSustainedQuoteBlockIndex(in lines: [String]) -> Int? {
        var blockStart: Int?
        var quotedCount = 0
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") {
                if blockStart == nil { blockStart = index }
                quotedCount += 1
                if quotedCount >= 2 { return blockStart }
            } else if trimmed.isEmpty {
                continue   // blanks don't break a run, but can't start one
            } else {
                blockStart = nil
                quotedCount = 0
            }
        }
        return nil
    }

    /// Number of leading `>` quote markers on a line (each optionally followed
    /// by one space/tab): `"> > text"` → 2, `"text"` → 0. Mirrors what
    /// `strippingQuoteMarkers` removes, so depth and stripped text stay aligned.
    static func quoteDepth(_ line: String) -> Int {
        var depth = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        while index < line.endIndex, line[index] == ">" {
            depth += 1
            index = line.index(after: index)
            if index < line.endIndex, line[index] == " " || line[index] == "\t" {
                index = line.index(after: index)
            }
        }
        return depth
    }

    /// Strips one-or-more leading `>` quote markers (Internet-message quoting,
    /// any nesting depth) from a line: `"> > text"` → `"text"`.
    static func strippingQuoteMarkers(_ line: String) -> String {
        guard let regex = quoteMarkerRegex else { return line }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
    }

    /// Joins a reply's body lines, collapsing runs of blank lines to a single
    /// blank and trimming the edges.
    private static func collapseBody(_ lines: [String]) -> String {
        var result: [String] = []
        var lastWasBlank = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if result.isEmpty == false && lastWasBlank == false {
                    result.append("")
                }
                lastWasBlank = true
            } else {
                result.append(trimmed)
                lastWasBlank = false
            }
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }

    // MARK: - Attribution detection / parsing (multi-locale, best-effort)

    /// True when the line introduces a quoted reply. Delegates to the shared
    /// `ReplyAttribution` detector so the comment-tree boundary and
    /// `OriginalMessageText`'s body-cleaning boundary stay identical; mail
    /// that matches none still surfaces via the `>`-quote path.
    static func isAttributionLine(_ trimmed: String) -> Bool {
        ReplyAttribution.isAttributionLine(trimmed)
    }

    /// Splits an attribution line into a display name and the date phrase via
    /// the shared `ReplyAttribution` parser. Anything it can't split degrades
    /// to (nil author, whole-line date).
    static func parseAttribution(_ attribution: String?) -> (author: String?, dateText: String?) {
        ReplyAttribution.parse(attribution)
    }

    /// Rejoins attributions that hard-wrapped across lines in the plain-text
    /// part ("2026年6月5日（金）17:46 名前\n<addr>:") so downstream parsing
    /// sees one attribution line. Only merges when the joined result is a
    /// valid attribution and the continuation lines share the lead-in's quote
    /// depth; everything else passes through untouched.
    static func mergingWrappedAttributions(_ lines: [String]) -> [String] {
        var merged: [String] = []
        merged.reserveCapacity(lines.count)
        var index = 0
        while index < lines.count {
            let depth = quoteDepth(lines[index])
            let stripped = strippingQuoteMarkers(lines[index])
                .trimmingCharacters(in: .whitespaces)
            if isAttributionLine(stripped) == false {
                var continuations: [String] = []
                var cursor = index + 1
                while cursor < lines.count, continuations.count < 2, quoteDepth(lines[cursor]) == depth {
                    continuations.append(
                        strippingQuoteMarkers(lines[cursor]).trimmingCharacters(in: .whitespaces)
                    )
                    cursor += 1
                }
                if let joined = ReplyAttribution.joinedAttribution(
                    leadIn: stripped,
                    continuations: continuations
                ) {
                    merged.append(String(repeating: "> ", count: depth) + joined.text)
                    index += joined.consumed + 1
                    continue
                }
            }
            merged.append(lines[index])
            index += 1
        }
        return merged
    }

    private static func displayName(from chunk: String) -> String? {
        ReplyAttribution.displayName(from: chunk)
    }

    /// An embedded original's header block (`OriginalHeaderBlock`, in any
    /// language a client localizes it into), read through quote markers.
    private static func isOriginalHeaderBlockStart(lines: [String], index: Int) -> Bool {
        guard lines.indices.contains(index) else { return false }
        // The block, with Outlook's rule above it, spans at most nine lines.
        let window = lines[index..<min(lines.count, index + 9)].map(strippingQuoteMarkers)
        return OhiaCore.OriginalHeaderBlock.starts(lines: window, at: 0)
    }

    // MARK: - Regex cache

    private static let quoteMarkerRegex = try? NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]?)+"#)
}
