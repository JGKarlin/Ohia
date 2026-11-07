import Foundation
import SwiftData
import OhiaCore

public struct TranslationGlossarySettingsLanguage: Identifiable, Equatable, Sendable {
    public let code: String
    public let label: String
    public var id: String { code }
}

/// An unordered language-pair selection. Canonicalizing the two codes here
/// keeps filtering independent of the direction in which a dyad was observed.
public struct TranslationGlossarySettingsLanguagePair: Identifiable, Hashable, Sendable {
    public let languageA: String
    public let languageB: String

    public init(_ language1: String, _ language2: String) {
        let first = TranslationGlossaryCanonicalizer.baseLanguageCode(language1)
        let second = TranslationGlossaryCanonicalizer.baseLanguageCode(language2)
        languageA = min(first, second)
        languageB = max(first, second)
    }

    public var id: String { "\(languageA)|\(languageB)" }

    public var label: String {
        "\(TranslationGlossarySettingsModel.languageName(languageB)) ↔ \(TranslationGlossarySettingsModel.languageName(languageA))"
    }

    func matches(_ pair: TranslationGlossaryPair) -> Bool {
        languageA == pair.canonicalLanguageA && languageB == pair.canonicalLanguageB
    }
}

public enum TranslationGlossarySettingsAction: String, Equatable, Sendable {
    case confirm
    case edit
    case delete
    case evidence
}

public struct TranslationGlossarySettingsRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let languageA: String
    public let languageB: String
    public let termA: String
    public let termB: String
    public let status: TranslationGlossaryPairStatus
    public let confidence: Double
    public let evidenceCount: Int
    public let updatedAt: Date
    public let actions: [TranslationGlossarySettingsAction]

    public var displayText: String {
        "\(TranslationGlossarySettingsModel.languageName(languageB)): \(termB) ↔ \(TranslationGlossarySettingsModel.languageName(languageA)): \(termA)"
    }
}

public struct TranslationGlossarySettingsEvidenceItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: TranslationGlossaryEvidenceKind
    public let polarity: TranslationGlossaryEvidencePolarity
    public let observedTermA: String
    public let observedTermB: String
    public let sourceMessageID: UUID?
    public let sourceDraftID: UUID?
    public let sourceAccountID: UUID?
    public let sourceAuthorAddress: String?
    public let excerpt: String?
    public let observedAt: Date
    public let strength: Double
}

public struct TranslationGlossarySettingsEvidenceGroup: Identifiable, Equatable, Sendable {
    public let polarity: TranslationGlossaryEvidencePolarity
    public let items: [TranslationGlossarySettingsEvidenceItem]
    public var id: String { polarity.rawValue }
}

/// Testable projection and action boundary for the Translation Settings
/// glossary. Persistence policy stays authoritative in the repository; this
/// type only prepares canonical rows, validates editor input, and delegates
/// synchronous user actions.
public enum TranslationGlossarySettingsModel {
    public static let supportedLanguages: [TranslationGlossarySettingsLanguage] =
        LocalModelLanguageSupport.supportedLanguageIDs.map {
            TranslationGlossarySettingsLanguage(code: $0, label: languageName($0))
        }

    public static let languagePairs: [TranslationGlossarySettingsLanguagePair] = {
        let codes = LocalModelLanguageSupport.supportedLanguageIDs
        return codes.indices.flatMap { left in
            codes.indices.compactMap { right in
                guard right > left else { return nil }
                return TranslationGlossarySettingsLanguagePair(codes[left], codes[right])
            }
        }
    }()

    public static func languageName(_ code: String) -> String {
        LocalModelLanguageSupport.displayName(for: code) ?? code
    }

    public static func rows(
        pairs: [TranslationGlossaryPair],
        evidence: [TranslationGlossaryEvidence],
        selectedLanguagePair: TranslationGlossarySettingsLanguagePair?,
        showDeleted: Bool
    ) -> [TranslationGlossarySettingsRow] {
        let evidenceCountByPairID = Dictionary(grouping: evidence, by: \.pairID).mapValues(\.count)
        let visiblePairs = pairs
            .filter { pair in
                guard showDeleted || pair.statusRaw != TranslationGlossaryPairStatus.deleted.rawValue else {
                    return false
                }
                return selectedLanguagePair?.matches(pair) ?? true
            }
        let winners = Dictionary(grouping: visiblePairs, by: \.canonicalKey)
            .values
            .compactMap { rows in rows.sorted(by: preferredProjectionPair).first }
        return winners
            .map { pair in
                let status = TranslationGlossaryPairStatus(rawValue: pair.statusRaw) ?? .inferred
                let actions: [TranslationGlossarySettingsAction]
                switch status {
                case .inferred:
                    actions = [.confirm, .edit, .delete, .evidence]
                case .confirmed:
                    actions = [.edit, .delete, .evidence]
                case .deleted:
                    actions = [.edit, .evidence]
                }
                return TranslationGlossarySettingsRow(
                    id: pair.id,
                    languageA: pair.canonicalLanguageA,
                    languageB: pair.canonicalLanguageB,
                    termA: pair.termA,
                    termB: pair.termB,
                    status: status,
                    confidence: pair.confidence,
                    evidenceCount: evidenceCountByPairID[pair.id, default: 0],
                    updatedAt: pair.updatedAt,
                    actions: actions
                )
            }
            .sorted { left, right in
                if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
                return left.displayText.localizedStandardCompare(right.displayText) == .orderedAscending
            }
    }

    private static func preferredProjectionPair(
        _ left: TranslationGlossaryPair,
        _ right: TranslationGlossaryPair
    ) -> Bool {
        let leftIsActive = left.statusRaw != TranslationGlossaryPairStatus.deleted.rawValue
        let rightIsActive = right.statusRaw != TranslationGlossaryPairStatus.deleted.rawValue
        if leftIsActive != rightIsActive { return leftIsActive }
        if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
        return left.id.uuidString < right.id.uuidString
    }

    public static func evidenceGroups(
        for pairID: UUID,
        evidence: [TranslationGlossaryEvidence]
    ) -> [TranslationGlossarySettingsEvidenceGroup] {
        let items = evidence
            .filter { $0.pairID == pairID }
            .map { row in
                TranslationGlossarySettingsEvidenceItem(
                    id: row.id,
                    kind: TranslationGlossaryEvidenceKind(rawValue: row.kindRaw) ?? .manual,
                    polarity: TranslationGlossaryEvidencePolarity(rawValue: row.polarityRaw) ?? .supporting,
                    observedTermA: row.observedTermA,
                    observedTermB: row.observedTermB,
                    sourceMessageID: row.sourceMessageID,
                    sourceDraftID: row.sourceDraftID,
                    sourceAccountID: row.sourceAccountID,
                    sourceAuthorAddress: row.sourceAuthorAddress,
                    excerpt: row.excerpt,
                    observedAt: row.observedAt,
                    strength: row.strength
                )
            }
            .sorted { left, right in
                if left.observedAt != right.observedAt { return left.observedAt > right.observedAt }
                return left.id.uuidString < right.id.uuidString
            }
        return TranslationGlossaryEvidencePolarity.allCases.compactMap { polarity in
            let matching = items.filter { $0.polarity == polarity }
            guard matching.isEmpty == false else { return nil }
            return TranslationGlossarySettingsEvidenceGroup(polarity: polarity, items: matching)
        }
    }

    public static func validationMessage(
        language1: String,
        term1: String,
        language2: String,
        term2: String,
        editing pair: TranslationGlossaryPair? = nil
    ) -> String? {
        let term1 = term1.trimmingCharacters(in: .whitespacesAndNewlines)
        let term2 = term2.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pair {
            let proposed = TranslationGlossaryCanonicalizer.canonicalPair(
                language1: language1, term1: term1, language2: language2, term2: term2
            )
            if proposed.languageA == pair.canonicalLanguageA,
               proposed.languageB == pair.canonicalLanguageB,
               proposed.termA == pair.termA,
               proposed.termB == pair.termB {
                return "Make a change before saving."
            }
        }

        let observation = TranslationGlossaryObservation(
            evidenceKey: "settings-validation",
            kind: .manual,
            language1: language1,
            term1: term1,
            language2: language2,
            term2: term2,
            authoredSurfaces: ["\(term1) / \(term2)"],
            sourceMessageID: nil,
            sourceDraftID: nil,
            sourceAccountID: nil,
            sourceAuthorAddress: nil,
            excerpt: nil,
            observedAt: .now,
            strength: TranslationGlossaryPolicy.manualStrength
        )
        switch TranslationGlossaryCandidateValidator.validate(observation) {
        case .success:
            return nil
        case let .failure(rejection):
            return validationMessage(for: rejection)
        }
    }

    @MainActor
    public static func add(
        language1: String,
        term1: String,
        language2: String,
        term2: String,
        in context: ModelContext,
        now: Date
    ) throws {
        try TranslationGlossaryRepository(modelContext: context).addConfirmed(
            language1: language1, term1: term1,
            language2: language2, term2: term2,
            now: now
        )
    }

    @MainActor
    public static func confirm(pairID: UUID, in context: ModelContext, now: Date) throws {
        try TranslationGlossaryRepository(modelContext: context).confirm(pairID: pairID, now: now)
    }

    @MainActor
    public static func edit(
        pairID: UUID,
        language1: String,
        term1: String,
        language2: String,
        term2: String,
        in context: ModelContext,
        now: Date
    ) throws {
        try TranslationGlossaryRepository(modelContext: context).edit(
            pairID: pairID,
            language1: language1, term1: term1,
            language2: language2, term2: term2,
            now: now
        )
    }

    @MainActor
    public static func delete(pairID: UUID, in context: ModelContext, now: Date) throws {
        try TranslationGlossaryRepository(modelContext: context).delete(pairID: pairID, now: now)
    }

    private static func validationMessage(for rejection: TranslationGlossaryCandidateRejection) -> String {
        switch rejection {
        case .invalidLanguage:
            return "Choose a language supported by Ohia."
        case .sameLanguage:
            return "Choose two different languages."
        case .invalidTerm:
            return "Enter a valid term in each language."
        case .equivalentTerms:
            return "Enter two distinct terms."
        case .termDoesNotMatchDeclaredLanguage:
            return "Each term must match its selected language."
        case .termMissingFromAuthoredEvidence,
             .insufficientSharedScriptAnchor,
             .invalidRelationshipAnchor,
             .missingEvidenceSourceIdentity,
             .emptyEvidenceKey:
            return "This pair could not be validated."
        }
    }
}
