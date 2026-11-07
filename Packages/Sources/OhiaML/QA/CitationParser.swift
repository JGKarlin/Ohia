// Packages/Sources/OhiaML/QA/CitationParser.swift
import Foundation

public enum CitationParser {

    private static let pattern = try! NSRegularExpression(pattern: "\\[(-?\\d+)\\]")

    /// Extracts `[N]` citation markers from `raw`, returning each distinct N
    /// in the order of first appearance, filtered to `1...sourceCount`.
    public static func extract(from raw: String, sourceCount: Int) -> [Int] {
        guard sourceCount > 0 else { return [] }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        var seen: Set<Int> = []
        var out: [Int] = []
        pattern.enumerateMatches(in: raw, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: raw) else { return }
            guard let n = Int(raw[r]), n >= 1, n <= sourceCount else { return }
            if seen.insert(n).inserted { out.append(n) }
        }
        return out
    }
}
