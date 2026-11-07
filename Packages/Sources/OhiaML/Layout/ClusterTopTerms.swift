import Foundation
import NaturalLanguage

/// Pure TF-IDF top-term extraction over message clusters. No I/O, no actor
/// hops, no MainActor — input is plain text per cluster id, output is a
/// deterministic list of top terms per cluster.
///
/// Used by the Meaning lens to render the "raw" line of each cluster's
/// dual label (the data evidence beneath the LLM interpretation). Pure
/// function so it stays language-agnostic and fast on the caller's thread.
public struct ClusterTopTerm: Sendable, Equatable {
    public let term: String
    public let score: Float
    public let normalizedWeight: Float

    public init(term: String, score: Float, normalizedWeight: Float) {
        self.term = term
        self.score = score
        self.normalizedWeight = normalizedWeight
    }
}

public enum ClusterTopTerms {

    /// Returns the top-N most distinctive terms per cluster, computed via
    /// TF-IDF over the supplied per-cluster text. TF is per-cluster term
    /// frequency normalized by cluster length; IDF is
    /// log(N_clusters / clusters_containing_term).
    ///
    /// Tokens are restricted to nouns, proper nouns, and adjectives via
    /// `NLTagger`, then case-folded and length-filtered (≥ 3 chars, not
    /// pure digits, no `@` or `http` substrings to drop address-fragment
    /// and URL noise). Language is detected per cluster via
    /// `NLLanguageRecognizer` so the tokenizer and tagger run with the
    /// right linguistic model — no English-only path.
    ///
    /// `terms` caps the size of each cluster's result. `minimumTerms`
    /// keeps the first few terms when available before score dropoff can
    /// trim the tail. `minScoreRatio` is the cascading floor after that:
    /// term N+1 is kept only if its score is at least
    /// `minScoreRatio × score(N)`.
    ///
    /// When the input contains a single cluster, IDF collapses to zero,
    /// so the function falls back to raw TF and reports the most common
    /// surviving nouns/adjectives — useful so the user still sees a
    /// label for solitary clusters during cold start.
    public static func topTerms(
        textPerCluster: [Int64: String],
        terms: Int = 3,
        minimumTerms: Int = 0,
        minScoreRatio: Float = 0.5
    ) -> [Int64: [String]] {
        scoredTopTerms(
            textPerCluster: textPerCluster,
            terms: terms,
            minimumTerms: minimumTerms,
            minScoreRatio: minScoreRatio
        )
        .mapValues { terms in
            terms.map(\.term)
        }
    }

    public static func scoredTopTerms(
        textPerCluster: [Int64: String],
        terms: Int = 3,
        minimumTerms: Int = 0,
        minScoreRatio: Float = 0.5
    ) -> [Int64: [ClusterTopTerm]] {
        guard !textPerCluster.isEmpty, terms > 0 else { return [:] }
        let requiredTerms = min(max(minimumTerms, 0), terms)

        var tokensPerCluster: [Int64: [String]] = [:]
        tokensPerCluster.reserveCapacity(textPerCluster.count)
        for (clusterId, text) in textPerCluster {
            tokensPerCluster[clusterId] = tokenizeAndFilter(text)
        }

        // df[w] = number of clusters in which w appears at least once.
        var df: [String: Int] = [:]
        for (_, tokens) in tokensPerCluster {
            let unique = Set(tokens)
            for w in unique { df[w, default: 0] += 1 }
        }

        let nClusters = Float(tokensPerCluster.count)
        let degenerate = nClusters < 2

        var result: [Int64: [ClusterTopTerm]] = [:]
        result.reserveCapacity(tokensPerCluster.count)

        for (clusterId, tokens) in tokensPerCluster {
            guard !tokens.isEmpty else {
                result[clusterId] = []
                continue
            }
            var tf: [String: Int] = [:]
            for w in tokens { tf[w, default: 0] += 1 }
            let length = Float(tokens.count)

            var scored: [(token: String, score: Float)] = []
            scored.reserveCapacity(tf.count)
            for (w, count) in tf {
                let tfW = Float(count) / length
                if degenerate {
                    scored.append((w, tfW))
                } else {
                    let dfW = Float(df[w] ?? 1)
                    let idf = log(nClusters / dfW)
                    let score = tfW * idf
                    if score > 0 {
                        scored.append((w, score))
                    }
                }
            }

            // Sort by score desc; ties broken by lexicographic order so
            // the output is stable across runs.
            scored.sort { lhs, rhs in
                lhs.score > rhs.score
                    || (lhs.score == rhs.score && lhs.token < rhs.token)
            }

            // Cascading floor: keep going only while each pick clears
            // `minScoreRatio × previousScore`. Stops naturally when the
            // tail is much weaker than the head.
            var picked: [(token: String, score: Float)] = []
            picked.reserveCapacity(terms)
            var lastScore: Float = .greatestFiniteMagnitude
            for (index, entry) in scored.prefix(terms).enumerated() {
                if index >= requiredTerms,
                   !picked.isEmpty,
                   entry.score < lastScore * minScoreRatio {
                    break
                }
                picked.append(entry)
                lastScore = entry.score
            }
            let topScore = picked.first?.score ?? 0
            result[clusterId] = picked.map { entry in
                ClusterTopTerm(
                    term: entry.token,
                    score: entry.score,
                    normalizedWeight: topScore > 0 ? entry.score / topScore : 0
                )
            }
        }
        return result
    }

    /// Tokenizes `text`, filters to nouns / proper nouns / adjectives via
    /// NLTagger, lowercases, and drops tokens that fail
    /// `isAcceptable`. URLs and email addresses are stripped from the
    /// input first so NLTokenizer can not hand back their pieces
    /// (`user`, `example`, `com`) as innocent-looking word tokens.
    static func tokenizeAndFilter(_ text: String) -> [String] {
        let scrubbed = stripURLsAndEmails(text)
        let trimmed = scrubbed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let language = recognizer.dominantLanguage ?? .english

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = trimmed
        tagger.setLanguage(language, range: trimmed.startIndex..<trimmed.endIndex)

        let keepTags: Set<NLTag> = [
            .noun, .placeName, .personalName, .organizationName, .adjective
        ]
        var tokens: [String] = []
        tagger.enumerateTags(
            in: trimmed.startIndex..<trimmed.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, range in
            guard let tag, keepTags.contains(tag) else { return true }
            let token = String(trimmed[range]).lowercased()
            if isAcceptable(token: token) {
                tokens.append(token)
            }
            return true
        }
        return tokens
    }

    /// Replace any URL / email substring with a single space so the
    /// downstream tokenizer never sees their internal letter pieces.
    /// `NSRegularExpression` is used so the patterns work across every
    /// macOS deployment target the app supports.
    private static func stripURLsAndEmails(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var working = text
        for pattern in [#"https?://\S+"#, #"\S+@\S+\.\S+"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(working.startIndex..., in: working)
            working = regex.stringByReplacingMatches(
                in: working,
                range: range,
                withTemplate: " "
            )
        }
        return working
    }

    private static func isAcceptable(token: String) -> Bool {
        guard token.count >= 3 else { return false }
        // Reject anything containing a non-letter character. This is
        // intentionally strict — NLTokenizer can hand back URL fragments
        // (`example.com`), address pieces (`user`, `example`), or mixed-
        // character tokens (`q3`, `42a`) when input text contains them,
        // and a TF-IDF label of `example · com` is worse than nothing.
        // Apostrophes within a word (e.g. `wouldn't`) are allowed so
        // contracted forms survive. Unicode `isLetter` covers Latin,
        // CJK, Cyrillic, etc., so this stays language-agnostic.
        for ch in token {
            if !ch.isLetter && ch != "'" { return false }
        }
        return true
    }
}
