import AppKit
import Foundation
import SwiftUI

struct SearchMatchHighlight: Equatable, Sendable {
    let messageID: UUID
    let phrases: [String]
    let fallbackTerms: [String]

    init?(messageID: UUID, phrases: [String], fallbackTerms: [String] = []) {
        let cleanedPhrases = Self.cleanedUniquePhrases(phrases)
        let cleanedFallbackTerms = Self.cleanedUniquePhrases(fallbackTerms)
        guard cleanedPhrases.isEmpty == false else { return nil }
        self.messageID = messageID
        self.phrases = cleanedPhrases
        self.fallbackTerms = cleanedFallbackTerms
    }

    func scoped(to candidateID: UUID) -> SearchMatchHighlight? {
        candidateID == messageID ? self : nil
    }

    private static func cleanedUniquePhrases(_ rawPhrases: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for rawPhrase in rawPhrases {
            let phrase = rawPhrase
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard phrase.isEmpty == false else { continue }
            let key = phrase.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            guard seen.insert(key).inserted else { continue }
            result.append(phrase)
        }
        return result
    }
}

enum SearchMatchTextHighlighter {
    static func highlighted(_ text: String, highlight: SearchMatchHighlight?) -> AttributedString {
        highlighted(AttributedString(text), highlight: highlight)
    }

    static func highlighted(
        _ attributed: AttributedString,
        highlight: SearchMatchHighlight?
    ) -> AttributedString {
        highlighted(NSAttributedString(attributed), highlight: highlight)
    }

    static func highlighted(
        _ attributed: NSAttributedString,
        highlight: SearchMatchHighlight?
    ) -> AttributedString {
        AttributedString(highlightedNSAttributedString(attributed, highlight: highlight))
    }

    static func highlightedNSAttributedString(
        _ attributed: NSAttributedString,
        highlight: SearchMatchHighlight?
    ) -> NSAttributedString {
        guard let highlight, attributed.length > 0 else { return attributed }
        let ranges = matchRanges(
            in: attributed.string,
            primaryPhrases: highlight.phrases,
            fallbackTerms: highlight.fallbackTerms
        )
        guard ranges.isEmpty == false else { return attributed }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        let attributes = highlightAttributes()
        for range in ranges {
            mutable.addAttributes(attributes, range: range)
        }
        return mutable
    }

    static func highlightedHTMLTextNodes(
        in html: String,
        highlight: SearchMatchHighlight?
    ) -> String {
        guard let highlight, html.isEmpty == false else { return html }

        var result = ""
        var textBuffer = ""
        var index = html.startIndex
        var suppressedRawTextTag: String?

        func flushTextBuffer() {
            guard textBuffer.isEmpty == false else { return }
            if suppressedRawTextTag == nil {
                result += highlightedHTMLSegment(textBuffer, highlight: highlight)
            } else {
                result += textBuffer
            }
            textBuffer.removeAll(keepingCapacity: true)
        }

        while index < html.endIndex {
            let character = html[index]
            if character == "<" {
                flushTextBuffer()
                let tagStart = index
                guard let close = html[index...].firstIndex(of: ">") else {
                    textBuffer.append(contentsOf: html[tagStart...])
                    break
                }
                let tagEnd = html.index(after: close)
                let tag = String(html[tagStart..<tagEnd])
                result += tag
                updateSuppressedRawTextTag(tag, suppressedRawTextTag: &suppressedRawTextTag)
                index = tagEnd
            } else {
                textBuffer.append(character)
                index = html.index(after: index)
            }
        }
        flushTextBuffer()
        return result
    }

    private static func highlightedHTMLSegment(
        _ segment: String,
        highlight: SearchMatchHighlight
    ) -> String {
        let entityRanges = htmlEntityRanges(in: segment)
        let ranges = matchRanges(
            in: segment,
            primaryPhrases: highlight.phrases,
            fallbackTerms: highlight.fallbackTerms
        )
        .filter { range in
            entityRanges.contains { entityRange in
                NSIntersectionRange(range, entityRange).length > 0
            } == false
        }
        guard ranges.isEmpty == false else { return segment }

        var result = segment
        for range in ranges.reversed() {
            guard let swiftRange = Range(range, in: result) else { continue }
            let matched = String(result[swiftRange])
            result.replaceSubrange(swiftRange, with: #"<mark class="ohia-search-hit">\#(matched)</mark>"#)
        }
        return result
    }

    private static func updateSuppressedRawTextTag(
        _ tag: String,
        suppressedRawTextTag: inout String?
    ) {
        let lowercased = tag.lowercased()
        if lowercased.hasPrefix("</") {
            guard let rawTextTag = suppressedRawTextTag,
                  lowercased.hasPrefix("</\(rawTextTag)") else { return }
            suppressedRawTextTag = nil
            return
        }
        guard suppressedRawTextTag == nil else { return }
        if lowercased.hasPrefix("<script") {
            suppressedRawTextTag = "script"
        } else if lowercased.hasPrefix("<style") {
            suppressedRawTextTag = "style"
        }
    }

    private static let htmlEntityRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"&(?:#[0-9]+|#x[0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]+);"#)
    }()

    private static func htmlEntityRanges(in segment: String) -> [NSRange] {
        let range = NSRange(segment.startIndex..<segment.endIndex, in: segment)
        return htmlEntityRegex.matches(in: segment, range: range).map(\.range)
    }

    private static func matchRanges(
        in text: String,
        primaryPhrases: [String],
        fallbackTerms: [String]
    ) -> [NSRange] {
        let primaryRanges = nonOverlappingRanges(in: text, phrases: primaryPhrases)
        guard primaryRanges.isEmpty else { return primaryRanges }

        let fallback = fallbackTerms.isEmpty
            ? primaryPhrases.flatMap { phrase in phrase.split(whereSeparator: \.isWhitespace).map(String.init) }
            : fallbackTerms
        return nonOverlappingRanges(in: text, phrases: fallback)
    }

    private static func nonOverlappingRanges(in text: String, phrases: [String]) -> [NSRange] {
        guard text.isEmpty == false, phrases.isEmpty == false else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let sortedPhrases = phrases
            .filter { $0.isEmpty == false }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs < rhs }
                return lhs.count > rhs.count
            }
        var ranges: [NSRange] = []

        for phrase in sortedPhrases {
            var searchRange = fullRange
            while searchRange.location < fullRange.length, searchRange.length > 0 {
                let found = nsText.range(
                    of: phrase,
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    range: searchRange
                )
                guard found.location != NSNotFound, found.length > 0 else { break }
                if ranges.contains(where: { NSIntersectionRange($0, found).length > 0 }) == false {
                    ranges.append(found)
                }
                let nextLocation = found.location + found.length
                guard nextLocation < fullRange.length else { break }
                searchRange = NSRange(location: nextLocation, length: fullRange.length - nextLocation)
            }
        }

        return ranges.sorted { lhs, rhs in
            if lhs.location == rhs.location { return lhs.length > rhs.length }
            return lhs.location < rhs.location
        }
    }

    private static func highlightAttributes() -> [NSAttributedString.Key: Any] {
        [
            .backgroundColor: NSColor(OhiaColors.ohiaYellow).withAlphaComponent(0.42),
            .foregroundColor: OhiaColors.nsTextPrimary,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor(OhiaColors.chipActiveForeground).withAlphaComponent(0.75)
        ]
    }
}
