import Foundation
import OhiaCore

/// Language-neutral structural pre-filter for memory promotion. Replaces the
/// retired `MemoryPromotionGate`, whose English keyword lists were overfit to
/// a single mailbox and violated the no-English-only-paths rule. This filter
/// makes no semantic/durability judgment — that moves into `MemoryDistiller`.
/// It only (1) drops pure transactional ID atoms by structure and (2) gates
/// on corroboration so the distiller is fed signal, not noise.
public enum MemoryEvidencePreFilter {

    /// A pure transactional atom: a long alphanumeric identifier sitting in a
    /// number/code context. Detected by shape, not by language-specific words,
    /// so it works for English, Japanese, and any other script.
    public static func isTransactionalAtom(_ text: String) -> Bool {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let longMixedID = folded.range(
            of: #"(?=[A-Za-z0-9-]*[0-9])(?=[A-Za-z0-9-]*[A-Za-z])[A-Za-z0-9-]{8,}"#,
            options: .regularExpression
        ) != nil
        let longDigitRun = folded.range(of: #"\d{6,}"#, options: .regularExpression) != nil
        return longMixedID || longDigitRun
    }

    /// Corroboration gate. `.standard` accepts a repeated-pattern bucket or a
    /// confident multi-message/multi-thread bucket. `.strict` (transactional
    /// dossiers) requires genuine multi-message recurrence.
    public static func qualifies(
        supportingMessageCount: Int,
        distinctThreadCount: Int,
        maxConfidence: Double,
        hasRepeatedPatternSupport: Bool,
        strictness: MemoryPromotionStrictness
    ) -> Bool {
        switch strictness {
        case .standard:
            if hasRepeatedPatternSupport { return true }
            if supportingMessageCount >= 2 && (distinctThreadCount >= 2) && maxConfidence >= 0.5 { return true }
            return supportingMessageCount >= 1 && maxConfidence >= 0.6
        case .strict:
            if hasRepeatedPatternSupport && supportingMessageCount >= 2 { return true }
            return supportingMessageCount >= 3 && distinctThreadCount >= 2 && maxConfidence >= 0.6
        }
    }
}
