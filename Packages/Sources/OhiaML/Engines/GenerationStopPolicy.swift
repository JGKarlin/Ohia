import Foundation

enum GenerationStopPolicy: Sendable, Equatable {
    case none
    case summary
    case contextOrientation
    case ask
    case draft
    case signature

    static let summaryEndMarker = "END_OHIA_SUMMARY"
    static let contextOrientationEndMarker = "END_OHIA_CONTEXT"
    static let askEndMarker = "END_OHIA_ASK"
    static let draftEndMarker = "END_OHIA_DRAFT"
    static let signatureEndMarker = "END_OHIA_SIGNATURE"

    static func forPrompt(_ prompt: String) -> GenerationStopPolicy {
        if prompt.contains(summaryEndMarker) { return .summary }
        if prompt.contains(contextOrientationEndMarker) { return .contextOrientation }
        if prompt.contains(askEndMarker) { return .ask }
        if prompt.contains(draftEndMarker) { return .draft }
        if prompt.contains(signatureEndMarker) { return .signature }
        return .none
    }

    func finishedOutput(from text: String) -> String? {
        switch self {
        case .none:
            return nil
        case .summary:
            return Self.truncatedSummaryOutput(from: text)
        case .contextOrientation:
            return Self.truncatedDelimitedOutput(
                from: text,
                marker: Self.contextOrientationEndMarker
            )
        case .ask:
            return Self.truncatedDelimitedOutput(
                from: text,
                marker: Self.askEndMarker
            )
        case .draft:
            return Self.truncatedDelimitedOutput(
                from: text,
                marker: Self.draftEndMarker
            )
        case .signature:
            return Self.truncatedDelimitedOutput(
                from: text,
                marker: Self.signatureEndMarker
            )
        }
    }

    func finishedStreamingOutput(from text: String) -> String? {
        switch self {
        case .none:
            return nil
        case .summary:
            return Self.truncatedStreamingSummaryOutput(from: text)
        case .contextOrientation:
            return Self.truncatedStreamingDelimitedOutput(
                from: text,
                marker: Self.contextOrientationEndMarker
            )
        case .ask:
            return Self.truncatedStreamingDelimitedOutput(
                from: text,
                marker: Self.askEndMarker
            )
        case .draft:
            return Self.truncatedStreamingDelimitedOutput(
                from: text,
                marker: Self.draftEndMarker
            )
        case .signature:
            return Self.truncatedStreamingDelimitedOutput(
                from: text,
                marker: Self.signatureEndMarker
            )
        }
    }

    func finalizedOutput(from text: String) -> String {
        switch self {
        case .none:
            return text
        case .summary:
            return Self.truncatedSummaryOutput(from: text) ?? text
        case .contextOrientation:
            return Self.truncatedDelimitedOutput(
                from: text,
                marker: Self.contextOrientationEndMarker
            ) ?? text
        case .ask:
            return Self.truncatedDelimitedOutput(
                from: text,
                marker: Self.askEndMarker
            ) ?? text
        case .draft:
            return Self.truncatedDelimitedOutput(
                from: text,
                marker: Self.draftEndMarker
            ) ?? text
        case .signature:
            return Self.truncatedDelimitedOutput(
                from: text,
                marker: Self.signatureEndMarker
            ) ?? text
        }
    }

    static func finalizedSummaryOutput(_ text: String) -> String {
        truncatedSummaryOutput(from: text) ?? text
    }

    private static func truncatedSummaryOutput(from text: String) -> String? {
        if let output = truncatedDelimitedOutput(from: text, marker: summaryEndMarker) {
            return output
        }

        return outputBeforeRepeatedSummaryBlock(in: text)
    }

    private static func truncatedStreamingSummaryOutput(from text: String) -> String? {
        if let output = truncatedStreamingDelimitedOutput(from: text, marker: summaryEndMarker) {
            return output
        }

        let repeatSearchRange = suffixRange(in: text, approximateCharacterCount: 512)
        guard text.range(
            of: "PurposeCandidates",
            options: [.caseInsensitive],
            range: repeatSearchRange
        ) != nil else {
            return nil
        }

        return outputBeforeRepeatedSummaryBlock(in: text)
    }

    private static func truncatedDelimitedOutput(from text: String, marker: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        return String(text[..<markerRange.lowerBound])
    }

    private static func truncatedStreamingDelimitedOutput(from text: String, marker: String) -> String? {
        let markerSearchRange = suffixRange(
            in: text,
            approximateCharacterCount: marker.count + 512
        )
        guard let markerRange = text.range(of: marker, range: markerSearchRange) else {
            return nil
        }
        return String(text[..<markerRange.lowerBound])
    }

    private static func suffixRange(
        in text: String,
        approximateCharacterCount: Int
    ) -> Range<String.Index> {
        let lowerBound = text.index(
            text.endIndex,
            offsetBy: -approximateCharacterCount,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        return lowerBound..<text.endIndex
    }

    private static func outputBeforeRepeatedSummaryBlock(in text: String) -> String? {
        let classificationPattern = #"(?im)^\s*(?:[-*]\s+|\d+[\.)]\s+|>\s+)*(?:\*\*)?\s*PurposeCandidates\s*(?:\*\*)?\s*:"#
        let summaryPattern = #"(?im)^\s*(?:[-*]\s+|\d+[\.)]\s+|>\s+)*(?:\*\*)?\s*Summary\s*(?:\*\*)?\s*:"#
        let classificationRanges = ranges(matching: classificationPattern, in: text)
        guard classificationRanges.count > 1 else { return nil }

        for repeatedStart in classificationRanges.dropFirst() {
            let prefix = String(text[..<repeatedStart.lowerBound])
            if firstRange(matching: summaryPattern, in: prefix) != nil {
                return prefix
            }
        }
        return nil
    }

    private static func ranges(matching pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let nsRange = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, options: [], range: nsRange)
            .compactMap { Range($0.range, in: text) }
    }

    private static func firstRange(matching pattern: String, in text: String) -> Range<String.Index>? {
        ranges(matching: pattern, in: text).first
    }
}
