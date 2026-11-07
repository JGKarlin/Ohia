import Foundation

/// Deterministic pre-planner gate for automatic MCP web research.
/// Prefer precision: when uncertain, allow the planner (which may still
/// return an empty need list).
public enum ComposerWebResearchGate {
    public enum Decision: Sendable, Equatable {
        case allow
        case skip(reason: String)
    }

    public static func evaluate(_ context: ComposerWebResearchContext) -> Decision {
        let subject = context.subject
        let body = context.bodyOrBrief
        let combined = "\(subject)\n\(body)"

        if hasPublicFactSurface(combined) == false,
           looksJudgmentOrSchedulingOnly(combined) {
            return .skip(reason: "judgment-or-scheduling-only")
        }

        if hasFreshnessSignal(combined) == false,
           localCoverageAlreadySettles(context) {
            return .skip(reason: "local-coverage")
        }

        return .allow
    }

    // MARK: - Heuristics

    private static let publicFactPatterns: [String] = [
        #"https?://"#,
        #"\b(?:policy|policies|pricing|price|cost|fee|release|version|announce(?:d|ment)?|product|organization|organisation|company|deadline|launch|compatible|compatibility|documentation|official|changelog|roadmap|spec(?:ification)?s?)\b"#,
        #"\b(?:20\d{2})\b"#,
        #"\$\d"#,
        #"\b\d+(?:\.\d+)?%"#,
    ]

    private static let schedulingPatterns: [String] = [
        #"\b(?:schedul(?:e|ing)|availability|available|calendar|meet(?:ing)?|call|zoom|teams|hangout|time\s*zone|timezone|when\s+works|free\s+on|does\s+\w+\s+work|book\s+a\s+time)\b"#,
    ]

    private static let judgmentPatterns: [String] = [
        #"\b(?:prefer(?:ence)?|tone|wording|phrasing|polite|friendly|formal|casual|keep\s+it\s+short|what\s+should\s+i\s+say|how\s+should\s+i\s+reply)\b"#,
    ]

    private static let freshnessPatterns: [String] = [
        #"\b(?:current|currently|latest|updated?|recent(?:ly)?|as\s+of|today|this\s+(?:week|month|year)|20\d{2})\b"#,
    ]

    private static let stopwords: Set<String> = [
        "about", "after", "again", "also", "been", "before", "being", "between",
        "could", "does", "doing", "from", "have", "here", "into", "just", "like",
        "more", "most", "only", "other", "over", "please", "should", "some",
        "such", "than", "that", "their", "them", "then", "there", "these",
        "they", "this", "those", "through", "under", "until", "very", "want",
        "were", "what", "when", "where", "which", "while", "will", "with",
        "would", "your", "you", "and", "the", "for", "are", "but", "not",
        "can", "our", "any", "all", "get", "got", "let", "know", "thanks",
        "thank", "hello", "hi", "hey", "dear", "regards", "best",
    ]

    static func hasPublicFactSurface(_ text: String) -> Bool {
        matchesAny(text, patterns: publicFactPatterns)
    }

    static func looksJudgmentOrSchedulingOnly(_ text: String) -> Bool {
        let scheduling = matchesAny(text, patterns: schedulingPatterns)
        let judgment = matchesAny(text, patterns: judgmentPatterns)
        return scheduling || judgment
    }

    static func hasFreshnessSignal(_ text: String) -> Bool {
        matchesAny(text, patterns: freshnessPatterns)
    }

    static func localCoverageAlreadySettles(_ context: ComposerWebResearchContext) -> Bool {
        let digest = evidenceOnlyDigest(context.knownContextDigest)
        guard digest.isEmpty == false else { return false }
        // Require answer-like material, not a restatement of the ask / provenance.
        guard hasConcreteFactSignal(digest) else { return false }

        let hingeTokens = distinctiveTokens(from: "\(context.subject)\n\(context.bodyOrBrief)")
        guard hingeTokens.count >= 2 else { return false }

        let digestLower = digest.lowercased()
        let covered = hingeTokens.filter { digestLower.contains($0) }.count
        let allowedMisses = hingeTokens.count >= 4 ? 1 : 0
        return covered >= hingeTokens.count - allowedMisses
    }

    /// Drop provenance metadata lines so research_question / search_query
    /// echoes cannot fake local coverage.
    static func evidenceOnlyDigest(_ digest: String) -> String {
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed != "None." else { return "" }
        let skippedPrefixes = [
            "research_question:",
            "search_query:",
            "provider:",
            "retrieved_at:",
            "source_url:",
            "published_at:",
            "treat the following web material",
        ]
        return trimmed
            .components(separatedBy: .newlines)
            .filter { line in
                let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard lower.isEmpty == false else { return false }
                return skippedPrefixes.contains { lower.hasPrefix($0) } == false
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasConcreteFactSignal(_ text: String) -> Bool {
        let patterns = [
            #"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#,
            #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2}"#,
            #"\b20\d{2}\b"#,
            #"\$\d"#,
            #"\b\d+(?:\.\d+)?%"#,
            #"\bv?\d+(?:\.\d+){1,3}\b"#,
            #"\b(?:policy|policies|released?|announced|supports?|compatible|official|deadline|launched)\b"#,
        ]
        return matchesAny(text, patterns: patterns)
    }

    static func distinctiveTokens(from text: String) -> [String] {
        var seen = Set<String>()
        var tokens: [String] = []
        let scalars = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                token.count >= 5
                    && stopwords.contains(token) == false
                    && token.unicodeScalars.contains(where: \.properties.isAlphabetic)
            }
        for token in scalars {
            guard seen.insert(token).inserted else { continue }
            tokens.append(token)
            if tokens.count >= 8 { break }
        }
        return tokens
    }

    private static func matchesAny(_ text: String, patterns: [String]) -> Bool {
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
}
