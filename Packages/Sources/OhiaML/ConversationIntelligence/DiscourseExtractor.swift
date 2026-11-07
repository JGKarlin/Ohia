import Foundation
import OhiaCore

/// Free functions and version constants for the discourse-memory pass.
/// The `merge` policy is captured here so the thread-walk worker
/// (`AccountMemoryRefreshWorker`) and its test seams agree on what
/// "seed + refined" composition means.
public enum DiscourseExtractor {
    /// Strict union — refined items are appended after seed items so the
    /// deterministic signals always rank first when the UI ties on
    /// confidence. Duplicate detection compares normalized claim text.
    public static func merge(seed: DiscourseMemory, refined: DiscourseMemory) -> DiscourseMemory {
        let normalizedSeedClaims = Set(seed.claimCandidates.map { normalize($0.text) })
        let normalizedSeedDecisions = Set(seed.decisionCandidates.map { normalize($0.text) })
        let normalizedSeedTacit = Set(seed.tacitRuleSignals.map { normalize($0.rule) })

        var moves = seed.discourseMoves
        moves.append(contentsOf: refined.discourseMoves)

        var ibis = seed.ibisRoles
        ibis.append(contentsOf: refined.ibisRoles)

        var claims = seed.claimCandidates
        for candidate in refined.claimCandidates {
            if !normalizedSeedClaims.contains(normalize(candidate.text)) {
                claims.append(candidate)
            }
        }

        var decisions = seed.decisionCandidates
        for decision in refined.decisionCandidates {
            if !normalizedSeedDecisions.contains(normalize(decision.text)) {
                decisions.append(decision)
            }
        }

        var tacit = seed.tacitRuleSignals
        for rule in refined.tacitRuleSignals {
            if !normalizedSeedTacit.contains(normalize(rule.rule)) {
                tacit.append(rule)
            }
        }

        let precedents = seed.precedentSignals + refined.precedentSignals
        let contradictions = seed.contradictionSignals + refined.contradictionSignals
        let supersessions = seed.supersessionSignals + refined.supersessionSignals
        let scopeHints = mergeScopeHints(seed.scopeHints, refined.scopeHints)
        let uncertainties = seed.uncertainties + refined.uncertainties

        return DiscourseMemory(
            discourseMoves: moves,
            ibisRoles: ibis,
            claimCandidates: claims,
            decisionCandidates: decisions,
            precedentSignals: precedents,
            tacitRuleSignals: tacit,
            contradictionSignals: contradictions,
            supersessionSignals: supersessions,
            scopeHints: scopeHints,
            uncertainties: uncertainties,
            extractionVersion: refined.extractionVersion
        )
    }

    private static func mergeScopeHints(_ lhs: [ScopeHint], _ rhs: [ScopeHint]) -> [ScopeHint] {
        var seen = Set<ScopeHint>()
        var result: [ScopeHint] = []
        for hint in lhs + rhs where !seen.contains(hint) {
            seen.insert(hint)
            result.append(hint)
        }
        return result
    }

    private static func normalize(_ text: String) -> String {
        ConversationCurationKey.normalize(text: text)
    }
}
