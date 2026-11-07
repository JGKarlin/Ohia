import Foundation
import SwiftData

/// Persisted lifecycle states for a translation dyad. The raw value is stored
/// so SwiftData never has to translate a custom enum in a predicate.
public enum TranslationGlossaryPairStatus: String, Sendable, CaseIterable {
    case inferred
    case confirmed
    case deleted
}

/// Whether an observation supports or contradicts its pair's current terms.
public enum TranslationGlossaryEvidencePolarity: String, Sendable, CaseIterable {
    case supporting
    case contradicting
}

/// The source that produced a glossary observation. Every kind is authored
/// evidence except `modelRendering`: the local model's own translation of a
/// term it had left untranslated in displayed text. That kind only ever
/// founds a new provisional pair and never corroborates or contradicts
/// authored evidence.
public enum TranslationGlossaryEvidenceKind: String, Sendable, CaseIterable {
    case composerCorrection
    case explicitBilingualNotation
    case trustedIdentityDeclaration
    case correspondentIdentity
    case linkedCorrespondence
    case manual
    case modelRendering
}

/// The canonical, unordered identity and exact authored surfaces for one
/// bilingual term pair.
public struct TranslationGlossaryCanonicalPair: Sendable, Equatable {
    public let languageA: String
    public let termA: String
    public let normalizedTermA: String
    public let languageB: String
    public let termB: String
    public let normalizedTermB: String
    public let canonicalKey: String
}

/// Builds the shared identity for a bilingual dyad without changing its
/// authored surfaces. Validation belongs to the repository layer.
public enum TranslationGlossaryCanonicalizer {
    public static func canonicalPair(
        language1: String,
        term1: String,
        language2: String,
        term2: String
    ) -> TranslationGlossaryCanonicalPair {
        let language1 = baseLanguageCode(language1)
        let language2 = baseLanguageCode(language2)
        let normalizedTerm1 = normalizedIdentityTerm(term1)
        let normalizedTerm2 = normalizedIdentityTerm(term2)

        let firstPrecedesSecond =
            language1 < language2
            || (language1 == language2 && normalizedTerm1 <= normalizedTerm2)

        let languageA = firstPrecedesSecond ? language1 : language2
        let termA = firstPrecedesSecond ? term1 : term2
        let normalizedTermA = firstPrecedesSecond ? normalizedTerm1 : normalizedTerm2
        let languageB = firstPrecedesSecond ? language2 : language1
        let termB = firstPrecedesSecond ? term2 : term1
        let normalizedTermB = firstPrecedesSecond ? normalizedTerm2 : normalizedTerm1

        return TranslationGlossaryCanonicalPair(
            languageA: languageA,
            termA: termA,
            normalizedTermA: normalizedTermA,
            languageB: languageB,
            termB: termB,
            normalizedTermB: normalizedTermB,
            canonicalKey: lengthPrefixedKey([
                languageA,
                normalizedTermA,
                languageB,
                normalizedTermB,
            ])
        )
    }

    public static func baseLanguageCode(_ identifier: String) -> String {
        identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)?
            .lowercased() ?? ""
    }

    public static func normalizedIdentityTerm(_ term: String) -> String {
        let compatibilityNormalized = term.precomposedStringWithCompatibilityMapping
        let caseFolded = compatibilityNormalized.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let withoutPunctuation = String(caseFolded.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
        })
        return withoutPunctuation
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func lengthPrefixedKey(_ values: [String]) -> String {
        values.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

/// The legacy directional-pin text shape. This parser exists only so the
/// cutover can identify the old `AccountMemory` representation consistently
/// with the remaining style-rule writer; it accepts either spaced or unspaced
/// arrows and does not validate a target-language dossier.
public struct TranslationGlossaryLegacyPinText: Sendable, Equatable {
    public let sourceTerm: String
    public let targetTerm: String

    public init?(_ text: String) {
        guard let arrow = text.range(of: "=>") else { return nil }
        let source = text[..<arrow.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let target = text[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.isEmpty == false, target.isEmpty == false else { return nil }
        self.sourceTerm = String(source)
        self.targetTerm = String(target)
    }

    public static func isGlossaryShaped(_ text: String) -> Bool {
        Self(text) != nil
    }
}

/// One user-wide bilingual fact. Exact terms remain separate from their
/// normalized identity, so prompts and Settings always use authored text.
@Model
public final class TranslationGlossaryPair {
    public var id: UUID
    public var canonicalLanguageA: String
    public var canonicalLanguageB: String
    public var termA: String
    public var termB: String
    public var normalizedTermA: String
    public var normalizedTermB: String
    @Attribute(.unique) public var canonicalKey: String
    public var statusRaw: String
    public var confidence: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var lastEvidenceAt: Date?
    public var confirmedAt: Date?

    public init(
        id: UUID = UUID(),
        canonicalLanguageA: String,
        canonicalLanguageB: String,
        termA: String,
        termB: String,
        normalizedTermA: String,
        normalizedTermB: String,
        canonicalKey: String,
        statusRaw: String = TranslationGlossaryPairStatus.inferred.rawValue,
        confidence: Double = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastEvidenceAt: Date? = nil,
        confirmedAt: Date? = nil
    ) {
        self.id = id
        self.canonicalLanguageA = canonicalLanguageA
        self.canonicalLanguageB = canonicalLanguageB
        self.termA = termA
        self.termB = termB
        self.normalizedTermA = normalizedTermA
        self.normalizedTermB = normalizedTermB
        self.canonicalKey = canonicalKey
        self.statusRaw = statusRaw
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastEvidenceAt = lastEvidenceAt
        self.confirmedAt = confirmedAt
    }
}

/// Immutable authored observation attached by scalar ID so evidence survives
/// an inferred pair's revision or tombstoning.
@Model
public final class TranslationGlossaryEvidence {
    public var id: UUID
    public var pairID: UUID
    @Attribute(.unique) public var evidenceKey: String
    public var kindRaw: String
    public var polarityRaw: String
    public var observedTermA: String
    public var observedTermB: String
    public var sourceMessageID: UUID?
    public var sourceDraftID: UUID?
    public var sourceAccountID: UUID?
    public var sourceAuthorAddress: String?
    public var excerpt: String?
    public var observedAt: Date
    public var strength: Double

    public init(
        id: UUID = UUID(),
        pairID: UUID,
        evidenceKey: String,
        kindRaw: String,
        polarityRaw: String,
        observedTermA: String,
        observedTermB: String,
        sourceMessageID: UUID? = nil,
        sourceDraftID: UUID? = nil,
        sourceAccountID: UUID? = nil,
        sourceAuthorAddress: String? = nil,
        excerpt: String? = nil,
        observedAt: Date = .now,
        strength: Double
    ) {
        self.id = id
        self.pairID = pairID
        self.evidenceKey = evidenceKey
        self.kindRaw = kindRaw
        self.polarityRaw = polarityRaw
        self.observedTermA = observedTermA
        self.observedTermB = observedTermB
        self.sourceMessageID = sourceMessageID
        self.sourceDraftID = sourceDraftID
        self.sourceAccountID = sourceAccountID
        self.sourceAuthorAddress = sourceAuthorAddress
        self.excerpt = excerpt
        self.observedAt = observedAt
        self.strength = strength
    }
}
