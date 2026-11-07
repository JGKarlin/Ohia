import OhiaCore

/// Pure confidence and lifecycle policy shared by glossary ingestion and
/// prompt construction.
public enum TranslationGlossaryPolicy {
    public enum Authority: Sendable, Equatable {
        case excluded
        case provisional
        case exact
    }

    public static let composerCorrectionStrength = 0.90
    public static let explicitBilingualNotationStrength = 0.85
    public static let trustedIdentityDeclarationStrength = 0.85
    public static let correspondentIdentityStrength = 0.80
    public static let linkedCorrespondenceStrength = 0.40
    public static let contradictoryComposerCorrectionStrength = 0.90
    public static let linkedContradictionStrength = 0.60
    public static let manualStrength = 1.0
    /// Inside the provisional band: a model rendering advises future
    /// generation but is enforced verbatim only after the user confirms it
    /// or authored evidence corroborates it.
    public static let modelRenderingStrength = 0.50

    public static let provisionalThreshold = 0.35
    public static let exactThreshold = 0.75
    public static let retirementThreshold = 0.25

    public static func confidence(
        supporting: [Double],
        contradicting: [Double]
    ) -> Double {
        let support = 1 - supporting.reduce(1) { $0 * (1 - clamp($1)) }
        let contradiction = 1 - contradicting.reduce(1) { $0 * (1 - clamp($1)) }
        return clamp(support * (1 - contradiction))
    }

    public static func authority(
        status: TranslationGlossaryPairStatus,
        confidence: Double
    ) -> Authority {
        switch status {
        case .confirmed:
            .exact
        case .deleted:
            .excluded
        case .inferred:
            if confidence >= exactThreshold {
                .exact
            } else if confidence >= provisionalThreshold {
                .provisional
            } else {
                .excluded
            }
        }
    }

    public static func shouldRetire(
        status: TranslationGlossaryPairStatus,
        confidence: Double
    ) -> Bool {
        status == .inferred && confidence < retirementThreshold
    }

    public static func clamp(_ value: Double) -> Double {
        if value.isNaN { return 0 }
        if value == .infinity { return 1 }
        if value == -.infinity { return 0 }
        return min(max(value, 0), 1)
    }
}
