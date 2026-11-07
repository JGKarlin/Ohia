import Foundation

public struct TranslationGlossaryMarkerMapping: Sendable, Equatable {
    public let markerID: String
    public let marker: String
    public let targetRendering: String

    public init(markerID: String, marker: String, targetRendering: String) {
        self.markerID = markerID
        self.marker = marker
        self.targetRendering = targetRendering
    }
}

public struct PreparedTranslationGlossaryProtection: Sendable, Equatable {
    public let protectedText: String
    public let mappings: [TranslationGlossaryMarkerMapping]
    public let requiredMarkerIDs: [String]

    public init(
        protectedText: String,
        mappings: [TranslationGlossaryMarkerMapping],
        requiredMarkerIDs: [String]
    ) {
        self.protectedText = protectedText
        self.mappings = mappings
        self.requiredMarkerIDs = requiredMarkerIDs
    }

    /// Restores every surviving exact marker. Direct translation requires each
    /// marker exactly once; omission-tolerant consumers such as summaries pass
    /// `false` and restore only markers the model retained.
    public func restore(in output: String, requireAll: Bool) throws -> String {
        if requireAll {
            for mapping in mappings where occurrenceCount(of: mapping.marker, in: output) != 1 {
                throw TranslationError.glossaryProtectionFailed
            }
        }
        let restored = mappings.reduce(output) { restored, mapping in
            restored.replacingOccurrences(of: mapping.marker, with: mapping.targetRendering)
        }
        guard containsReservedMarkerResidue(in: restored) == false else {
            throw TranslationError.glossaryProtectionFailed
        }
        return restored
    }

    public func containsEveryRequiredMarker(in output: String) -> Bool {
        mappings.allSatisfy { occurrenceCount(of: $0.marker, in: output) == 1 }
    }

    private func occurrenceCount(of marker: String, in text: String) -> Int {
        guard marker.isEmpty == false else { return 0 }
        var count = 0
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: marker, options: [.literal], range: start..<text.endIndex) {
            count += 1
            start = range.upperBound
        }
        return count
    }

    private func requestNonce(for markerID: String) -> String {
        guard let suffixStart = markerID.lastIndex(of: "_"),
              suffixStart > markerID.startIndex,
              markerID[markerID.index(after: suffixStart)...].allSatisfy(\.isNumber) else {
            return markerID
        }
        return String(markerID[..<suffixStart])
    }

    private func containsReservedMarkerResidue(in text: String) -> Bool {
        let uppercase = text.uppercased()
        if uppercase.contains("OHIA_GLOSSARY_")
            || uppercase.contains("OHIA_SUMMARY_SEGMENT_")
            || uppercase.contains("[[OHIA_GLO")
            || uppercase.contains("[[OHIA_SUM")
            || uppercase.contains("OHIA GLOSSARY ")
            || uppercase.contains("OHIA SUMMARY SEGMENT ") {
            return true
        }
        return mappings.contains { mapping in
            uppercase.contains(mapping.markerID.uppercased())
                || uppercase.contains(requestNonce(for: mapping.markerID).uppercased())
        }
    }
}

/// Replaces exact glossary occurrences with opaque, collision-resistant tokens
/// before Qwen sees the source spelling.
public struct TranslationGlossaryProtection: Sendable {
    private let nonceGenerator: @Sendable () -> String

    public init(
        nonceGenerator: @escaping @Sendable () -> String = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
    ) {
        self.nonceGenerator = nonceGenerator
    }

    /// Extends a bounded prefix through one complete prepared glossary marker
    /// when the requested boundary would otherwise expose marker residue.
    public static func markerSafePrefix(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }

        let boundary = text.index(text.startIndex, offsetBy: limit)
        let ordinaryPrefix = String(text[..<boundary])
        let markerPrefix = "[[OHIA_GLOSSARY_"
        let openingDelimiter: Range<String.Index>?
        if boundary > text.startIndex {
            let preceding = text.index(before: boundary)
            if text[preceding...].hasPrefix(markerPrefix) {
                openingDelimiter = preceding..<text.index(after: preceding)
            } else {
                openingDelimiter = text.range(
                    of: "[[",
                    options: [.backwards, .literal],
                    range: text.startIndex..<boundary
                )
            }
        } else {
            openingDelimiter = nil
        }
        guard let openingDelimiter,
        text[openingDelimiter.lowerBound...].hasPrefix(markerPrefix),
        let markerPrefixEnd = text.index(
            openingDelimiter.lowerBound,
            offsetBy: markerPrefix.count,
            limitedBy: text.endIndex
        ),
        let markerEnd = text.range(of: "]]", options: .literal, range: markerPrefixEnd..<text.endIndex),
        markerEnd.upperBound > boundary else {
            return ordinaryPrefix
        }
        return String(text[..<markerEnd.upperBound])
    }

    public func prepare(
        bodyText: String,
        exactGlossary: [TranslationGlossaryEntry]
    ) -> PreparedTranslationGlossaryProtection {
        let entries = exactGlossary
            .filter { $0.authority == .exact && $0.sourceTerm.isEmpty == false }
            .sorted { lhs, rhs in
                if lhs.sourceTerm.count != rhs.sourceTerm.count {
                    return lhs.sourceTerm.count > rhs.sourceTerm.count
                }
                if lhs.sourceTerm != rhs.sourceTerm { return lhs.sourceTerm < rhs.sourceTerm }
                return lhs.pairID.uuidString < rhs.pairID.uuidString
            }

        var occupied: [Range<String.Index>] = []
        var occurrences: [(Range<String.Index>, TranslationGlossaryEntry)] = []
        for entry in entries {
            for range in TranslationGlossaryTextMatcher.eligibleRanges(of: entry.sourceTerm, in: bodyText)
            where occupied.allSatisfy({ !$0.overlaps(range) }) {
                occupied.append(range)
                occurrences.append((range, entry))
            }
        }
        occurrences.sort { $0.0.lowerBound < $1.0.lowerBound }

        let nonce = collisionFreeNonce(for: bodyText)
        let mappings = occurrences.enumerated().map { index, occurrence in
            let markerID = "\(nonce)_\(index)"
            return TranslationGlossaryMarkerMapping(
                markerID: markerID,
                marker: "[[OHIA_GLOSSARY_\(markerID)]]",
                targetRendering: occurrence.1.targetRendering
            )
        }
        var protected = bodyText
        for (index, occurrence) in occurrences.enumerated().reversed() {
            protected.replaceSubrange(occurrence.0, with: mappings[index].marker)
        }
        return PreparedTranslationGlossaryProtection(
            protectedText: protected,
            mappings: mappings,
            requiredMarkerIDs: mappings.map(\.markerID)
        )
    }

    private func collisionFreeNonce(for bodyText: String) -> String {
        let generated = nonceGenerator().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let base = generated.isEmpty ? "GLOSSARY" : String(String.UnicodeScalarView(generated))
        var candidate = base
        var suffix = 0
        while bodyText.contains("[[OHIA_GLOSSARY_\(candidate)_") {
            suffix += 1
            candidate = "\(base)X\(suffix)"
        }
        return candidate
    }
}
