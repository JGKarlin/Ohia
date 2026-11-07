import Foundation
import OhiaCore

/// Detect contradictions and supersessions between extracted claims.
/// Operates on the in-memory snapshot once `ThreadAdjacencyAnalyzer` and
/// `CrossThreadMemoryMiner` have populated their outputs. Distinguishes:
///
/// - `.contradiction`   — newer claim refutes older claim
/// - `.supersession`    — newer claim replaces older claim without refuting
/// - `.scopeNarrowing`  — newer claim restricts scope of older claim
public struct ContradictionDetector: Sendable {
    public struct Configuration: Sendable {
        public let cosineThreshold: Float
        public let maxComparisons: Int

        public init(cosineThreshold: Float = 0.78, maxComparisons: Int = 5_000) {
            self.cosineThreshold = cosineThreshold
            self.maxComparisons = maxComparisons
        }
        public static let `default` = Configuration()
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    public func detect(
        claims: [KnowledgeClaim],
        supersessions: [SupersessionRecord],
        languageByClaim: [String: String?]
    ) -> ContradictionDetectionResult {
        var contradictionLinks: [ContradictionLink] = []
        var statesByKey: [String: ContradictionState] = [:]

        // Pass 1: fold persisted supersessions directly.
        for record in supersessions {
            contradictionLinks.append(
                ContradictionLink(
                    olderClaimKey: record.olderClaimKey,
                    newerClaimKey: record.newerClaimKey,
                    type: .supersession,
                    sourceMessageIDs: record.sourceMessageIDs,
                    detectedAt: record.detectedAt,
                    resolved: false
                )
            )
            statesByKey[record.olderClaimKey] = .superseded
        }

        // Pass 2: similarity-based contradiction pairing across claims.
        let sorted = claims.sorted { $0.firstSeen < $1.firstSeen }
        var comparisons = 0
        outer: for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                comparisons += 1
                if comparisons > configuration.maxComparisons { break outer }
                let older = sorted[i]
                let newer = sorted[j]
                let similarity = Self.lexicalSimilarity(older.text, newer.text)
                guard similarity >= configuration.cosineThreshold else { continue }

                let language = languageByClaim[newer.key] ?? nil
                let hasNegation = NormLanguageLexicon.containsNegationCue(newer.text, language: language)
                    || hasNegationContrastWith(older.text, newer.text)
                let scopeNarrowed = isScopeNarrowing(older: older, newer: newer)

                let type: ContradictionType
                if scopeNarrowed {
                    type = .scopeNarrowing
                } else if hasNegation {
                    type = .contradiction
                } else {
                    type = .supersession
                }

                let stateForOlder: ContradictionState
                switch type {
                case .contradiction:    stateForOlder = .contested
                case .supersession:     stateForOlder = .superseded
                case .scopeNarrowing:   stateForOlder = .scopeNarrowed
                }
                statesByKey[older.key] = stateForOlder

                contradictionLinks.append(
                    ContradictionLink(
                        olderClaimKey: older.key,
                        newerClaimKey: newer.key,
                        type: type,
                        sourceMessageIDs: newer.evidenceLinks.map(\.messageID),
                        detectedAt: newer.firstSeen,
                        resolved: false
                    )
                )
            }
        }

        return ContradictionDetectionResult(
            links: contradictionLinks,
            statesByKey: statesByKey
        )
    }

    // MARK: - Helpers

    /// Cheap lexical similarity — token Jaccard over normalized text.
    /// Cosine over real embeddings would be more accurate but requires
    /// vector lookups which are not part of the snapshot input here.
    /// The threshold in the default configuration is tuned for this
    /// metric, not vector cosine.
    static func lexicalSimilarity(_ a: String, _ b: String) -> Float {
        let tokensA = tokenize(a)
        let tokensB = tokenize(b)
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return 0 }
        let intersection = tokensA.intersection(tokensB).count
        let unionCount = tokensA.union(tokensB).count
        guard unionCount > 0 else { return 0 }
        return Float(intersection) / Float(unionCount)
    }

    private static func tokenize(_ raw: String) -> Set<String> {
        let normalized = ConversationCurationKey.normalize(text: raw)
        return Set(normalized.split(separator: " ").map(String.init))
    }

    /// Detect negation contrast by checking whether one of the claims
    /// contains a negation token (no/not/never/n't) that the other lacks.
    private func hasNegationContrastWith(_ a: String, _ b: String) -> Bool {
        let negations: Set<String> = ["no", "not", "never", "n't", "cannot"]
        let tokensA = Self.tokenize(a)
        let tokensB = Self.tokenize(b)
        let aHas = tokensA.contains(where: { negations.contains($0) })
        let bHas = tokensB.contains(where: { negations.contains($0) })
        return aHas != bHas
    }

    /// Newer claim adds a scope component the older lacks (or vice versa).
    /// Used so an addition like "small purchases bypass review" against
    /// "purchases require review" classifies as scope narrowing rather
    /// than contradiction.
    private func isScopeNarrowing(older: KnowledgeClaim, newer: KnowledgeClaim) -> Bool {
        let olderScope = Set(older.scope)
        let newerScope = Set(newer.scope)
        if olderScope.isSubset(of: newerScope) && newerScope.count > olderScope.count {
            return true
        }
        return false
    }
}

public struct ContradictionDetectionResult: Sendable {
    public let links: [ContradictionLink]
    public let statesByKey: [String: ContradictionState]
}
