import Foundation

/// Fail-closed filter for automatically researched web/MCP evidence cards.
/// Keeps a card only when it clearly answers the research need or carries a
/// concrete public fact; uncertain or boilerplate cards are dropped.
public enum ComposerWebSourceKeeper {
    private static let snippetLimit = 1_200

    public static func keep(
        _ candidates: [ComposerSource],
        needs: [ComposerWebResearchNeed]
    ) -> [ComposerSource] {
        guard needs.isEmpty == false else { return [] }
        return candidates.compactMap { source in
            guard isAutomaticWebEvidence(source) else { return source }
            guard needs.contains(where: { need in keeps(source, for: need) }) else {
                return nil
            }
            return trimmed(source)
        }
    }

    /// Softer pre-WebRAG filter: URL-bearing snippet hits with minimal need
    /// overlap survive so local page fetch can recover useful evidence.
    public static func keepForExpansion(
        _ candidates: [ComposerSource],
        needs: [ComposerWebResearchNeed]
    ) -> [ComposerSource] {
        guard needs.isEmpty == false else { return [] }
        return candidates.compactMap { source in
            guard isAutomaticWebEvidence(source) else { return source }
            if needs.contains(where: { need in keeps(source, for: need) }) {
                return trimmed(source)
            }
            guard source.kind == .website,
                  crawlableURL(for: source) != nil,
                  needs.contains(where: { need in
                      overlapsNeed(excerpt: "\(source.label)\n\(source.snippet)", need: need, minimumShared: 1)
                  }) else {
                return nil
            }
            return trimmed(source)
        }
    }

    public static func keep(
        _ candidates: [ComposerSource],
        for need: ComposerWebResearchNeed
    ) -> [ComposerSource] {
        keep(candidates, needs: [need])
    }

    public static func keepForExpansion(
        _ candidates: [ComposerSource],
        for need: ComposerWebResearchNeed
    ) -> [ComposerSource] {
        keepForExpansion(candidates, needs: [need])
    }

    static func keeps(_ source: ComposerSource, for need: ComposerWebResearchNeed) -> Bool {
        let excerpt = source.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard excerpt.count >= 40 else { return false }

        if answersNeed(excerpt: excerpt, need: need) {
            return true
        }
        if hasConcreteFact(excerpt) && overlapsNeed(excerpt: excerpt, need: need, minimumShared: 1) {
            return true
        }
        return false
    }

    // MARK: - Signals

    private static func isAutomaticWebEvidence(_ source: ComposerSource) -> Bool {
        guard source.isUserAdded == false else { return false }
        switch source.kind {
        case .website, .mcp:
            return source.provenance != nil
        default:
            return false
        }
    }

    private static func answersNeed(excerpt: String, need: ComposerWebResearchNeed) -> Bool {
        overlapsNeed(excerpt: excerpt, need: need, minimumShared: 2)
            && (hasConcreteFact(excerpt) || excerpt.count >= 80)
    }

    private static func overlapsNeed(
        excerpt: String,
        need: ComposerWebResearchNeed,
        minimumShared: Int
    ) -> Bool {
        let haystack = excerpt.lowercased()
        let needles = distinctiveTokens(from: "\(need.question) \(need.query)")
        guard needles.isEmpty == false else { return false }
        let shared = needles.filter { haystack.contains($0) }.count
        return shared >= minimumShared
    }

    private static func hasConcreteFact(_ text: String) -> Bool {
        let patterns = [
            #"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#,
            #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2}(?:,\s*\d{4})?\b"#,
            #"\b20\d{2}\b"#,
            #"\$\d[\d,]*(?:\.\d+)?"#,
            #"\b\d+(?:\.\d+)?%"#,
            #"\bv?\d+(?:\.\d+){1,3}\b"#,
            #"\b(?:policy|policies|released?|announced|supports?|compatible|official|deadline|launched)\b"#,
            #"\b\d{2,}\b"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if expression.firstMatch(in: text, range: range) != nil {
                return true
            }
        }
        return false
    }

    private static func distinctiveTokens(from text: String) -> [String] {
        let stopwords: Set<String> = [
            "about", "after", "again", "also", "been", "before", "being", "could",
            "does", "from", "have", "into", "just", "like", "more", "most", "only",
            "other", "please", "should", "some", "such", "than", "that", "their",
            "them", "then", "there", "these", "they", "this", "those", "through",
            "under", "until", "very", "were", "what", "when", "where", "which",
            "while", "will", "with", "would", "your", "and", "the", "for", "are",
            "but", "not", "can", "our", "any", "all", "resolve", "question",
            "public", "search", "query", "draft", "email", "need", "fact",
        ]
        var seen = Set<String>()
        var tokens: [String] = []
        for raw in text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) {
            guard raw.count >= 4,
                  stopwords.contains(raw) == false,
                  raw.unicodeScalars.contains(where: \.properties.isAlphabetic),
                  seen.insert(raw).inserted else { continue }
            tokens.append(raw)
            if tokens.count >= 12 { break }
        }
        return tokens
    }

    private static func crawlableURL(for source: ComposerSource) -> String? {
        let candidates = [source.filePath, source.provenance?.sourceURL].compactMap { $0 }
        for raw in candidates {
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            return url.absoluteString
        }
        return nil
    }

    private static func trimmed(_ source: ComposerSource) -> ComposerSource {
        let snippet = String(source.snippet.prefix(snippetLimit))
        guard snippet != source.snippet else { return source }
        return ComposerSource(
            id: source.id,
            kind: source.kind,
            label: source.label,
            snippet: snippet,
            messageID: source.messageID,
            filePath: source.filePath,
            isUserAdded: source.isUserAdded,
            addedAt: source.addedAt,
            provenance: source.provenance,
            memoryUsePolicy: source.memoryUsePolicy,
            authoredByUser: source.authoredByUser,
            authoredAt: source.authoredAt
        )
    }
}
