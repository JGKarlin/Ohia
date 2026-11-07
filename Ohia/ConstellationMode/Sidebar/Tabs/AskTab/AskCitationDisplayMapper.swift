import Foundation
import OhiaML

struct AskCitationDisplayMapping: Equatable {
    let paragraph: String
    let sourceVectorIdsByDisplayIndex: [Int64]
    let sourceMetadataByDisplayIndex: [AskSourceCitationMetadata]
}

enum AskCitationDisplayMapper {
    private static let pattern = try! NSRegularExpression(pattern: "\\[(-?\\d+)\\]")

    /// Ask prompts number every retrieved source, but the answer may cite only
    /// a sparse subset. Render the cited subset as a compact first-seen list
    /// so an answer that only references prompt source `[4]` displays `[1]`.
    static func remap(
        paragraph: String,
        sourceVectorIdsByRank: [Int64],
        sourceCitationMetadataByRank: [AskSourceCitationMetadata] = []
    ) -> AskCitationDisplayMapping {
        guard !paragraph.isEmpty else {
            return AskCitationDisplayMapping(
                paragraph: paragraph,
                sourceVectorIdsByDisplayIndex: [],
                sourceMetadataByDisplayIndex: []
            )
        }

        let ns = paragraph as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var cursor = 0
        var remapped = ""
        var displayIndexByRank: [Int: Int] = [:]
        var displaySourceIds: [Int64] = []
        var displaySourceMetadata: [AskSourceCitationMetadata] = []

        func displayIndex(for rank: Int) -> Int {
            if let existing = displayIndexByRank[rank] {
                return existing
            }
            let next = displaySourceIds.count + 1
            displayIndexByRank[rank] = next
            displaySourceIds.append(sourceVectorIdsByRank[rank - 1])
            if rank <= sourceCitationMetadataByRank.count {
                displaySourceMetadata.append(sourceCitationMetadataByRank[rank - 1])
            } else {
                displaySourceMetadata.append(.empty)
            }
            return next
        }

        pattern.enumerateMatches(in: paragraph, range: fullRange) { match, _, _ in
            guard let match else { return }
            let markerRange = match.range
            if markerRange.location > cursor {
                remapped += ns.substring(
                    with: NSRange(location: cursor, length: markerRange.location - cursor)
                )
            }

            let rankString = ns.substring(with: match.range(at: 1))
            if let rank = Int(rankString),
               rank >= 1,
               rank <= sourceVectorIdsByRank.count {
                remapped += "[\(displayIndex(for: rank))]"
            } else {
                remapped += ns.substring(with: markerRange)
            }
            cursor = markerRange.location + markerRange.length
        }

        if cursor < ns.length {
            remapped += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }

        return AskCitationDisplayMapping(
            paragraph: remapped,
            sourceVectorIdsByDisplayIndex: displaySourceIds,
            sourceMetadataByDisplayIndex: displaySourceMetadata
        )
    }
}
