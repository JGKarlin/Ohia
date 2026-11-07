import Foundation
import OhiaCore

/// A producer-provided, inspectable relationship between exact authored
/// surfaces. It is required for shared-script Composer and correspondence
/// observations, where provenance identifiers alone cannot prove a dyad.
public enum TranslationGlossaryRelationshipAnchor: Sendable, Equatable {
    case composerCorrection(
        sourceSurfaceIndex: Int,
        finalUserTextSurfaceIndex: Int
    )
    case linkedCorrespondence(
        sourceSurfaceIndex: Int,
        relatedSurfaceIndex: Int,
        relatedMessageID: UUID,
        provenance: TranslationGlossaryLinkProvenance
    )
    case correspondentIdentity(
        sourceSurfaceIndex: Int,
        relatedSurfaceIndex: Int,
        provenance: TranslationGlossaryLinkProvenance
    )
}

/// Inspectable mechanical reason why two independently authored identity
/// surfaces refer to the same correspondent. The producer must carry one of
/// these values; thread membership or retrieval similarity by itself is never
/// a relationship anchor.
public enum TranslationGlossaryLinkProvenance: Sendable, Equatable {
    case normalizedParticipantAddress(String)
    case thread(threadID: UUID, attributableIdentity: String)
    case quotedAttribution(address: String)
    case stableIdentity(String)
}

public struct TranslationGlossaryObservation: Sendable, Equatable {
    public let evidenceKey: String
    public let kind: TranslationGlossaryEvidenceKind
    public let language1: String
    public let term1: String
    public let language2: String
    public let term2: String
    public let authoredSurfaces: [String]
    public let sourceMessageID: UUID?
    public let sourceDraftID: UUID?
    public let sourceAccountID: UUID?
    public let sourceAuthorAddress: String?
    public let relationshipAnchor: TranslationGlossaryRelationshipAnchor?
    public let excerpt: String?
    public let observedAt: Date
    public let strength: Double

    public init(
        evidenceKey: String,
        kind: TranslationGlossaryEvidenceKind,
        language1: String,
        term1: String,
        language2: String,
        term2: String,
        authoredSurfaces: [String],
        sourceMessageID: UUID?,
        sourceDraftID: UUID?,
        sourceAccountID: UUID?,
        sourceAuthorAddress: String?,
        relationshipAnchor: TranslationGlossaryRelationshipAnchor? = nil,
        excerpt: String?,
        observedAt: Date,
        strength: Double
    ) {
        self.evidenceKey = evidenceKey
        self.kind = kind
        self.language1 = language1
        self.term1 = term1
        self.language2 = language2
        self.term2 = term2
        self.authoredSurfaces = authoredSurfaces
        self.sourceMessageID = sourceMessageID
        self.sourceDraftID = sourceDraftID
        self.sourceAccountID = sourceAccountID
        self.sourceAuthorAddress = sourceAuthorAddress
        self.relationshipAnchor = relationshipAnchor
        self.excerpt = excerpt
        self.observedAt = observedAt
        self.strength = strength
    }
}

public enum TranslationGlossaryCandidateRejection: Error, Sendable, Equatable {
    case emptyEvidenceKey
    case invalidLanguage
    case sameLanguage
    case invalidTerm
    case equivalentTerms
    case termDoesNotMatchDeclaredLanguage
    case termMissingFromAuthoredEvidence
    case insufficientSharedScriptAnchor
    case invalidRelationshipAnchor
    case missingEvidenceSourceIdentity
}

/// Deterministically validates producer output before it reaches the glossary
/// repository. It does not detect language from a message body and never
/// generates or repairs a term.
public enum TranslationGlossaryCandidateValidator {
    public static let maximumTermLength = 80

    public static func validate(
        _ observation: TranslationGlossaryObservation
    ) -> Result<TranslationGlossaryObservation, TranslationGlossaryCandidateRejection> {
        let language1 = LocalModelLanguageSupport.canonicalLanguageID(for: observation.language1)
        let language2 = LocalModelLanguageSupport.canonicalLanguageID(for: observation.language2)
        guard let language1, let language2 else {
            return .failure(.invalidLanguage)
        }
        guard language1 != language2 else { return .failure(.sameLanguage) }
        guard isValidTerm(observation.term1, language: language1),
              isValidTerm(observation.term2, language: language2) else {
            return .failure(.invalidTerm)
        }
        if requiresAutomatedArtifactFiltering(observation.kind),
           (isLikelyMessageMetadata(observation.term1)
               || isLikelyMessageMetadata(observation.term2)) {
            return .failure(.invalidTerm)
        }

        guard matchesDeclaredLanguage(observation.term1, language: language1),
              matchesDeclaredLanguage(observation.term2, language: language2) else {
            return .failure(.termDoesNotMatchDeclaredLanguage)
        }
        let normalized1 = TranslationGlossaryCanonicalizer.normalizedIdentityTerm(observation.term1)
        let normalized2 = TranslationGlossaryCanonicalizer.normalizedIdentityTerm(observation.term2)
        guard normalized1.isEmpty == false, normalized2.isEmpty == false,
              normalized1 != normalized2,
              orderInsensitiveNameKey(observation.term1, language: language1)
                != orderInsensitiveNameKey(observation.term2, language: language2) else {
            return .failure(.equivalentTerms)
        }
        guard occursInAuthoredSurfaces(observation.term1, surfaces: observation.authoredSurfaces),
              occursInAuthoredSurfaces(observation.term2, surfaces: observation.authoredSurfaces) else {
            return .failure(.termMissingFromAuthoredEvidence)
        }
        switch sharedScriptAnchorValidation(
            language1: language1,
            term1: observation.term1,
            language2: language2,
            term2: observation.term2,
            kind: observation.kind,
            surfaces: observation.authoredSurfaces,
            sourceMessageID: observation.sourceMessageID,
            sourceDraftID: observation.sourceDraftID,
            sourceAuthorAddress: observation.sourceAuthorAddress,
            relationshipAnchor: observation.relationshipAnchor
        ) {
        case .success:
            break
        case let .failure(rejection):
            return .failure(rejection)
        }

        let canonical = TranslationGlossaryCanonicalizer.canonicalPair(
            language1: language1,
            term1: observation.term1,
            language2: language2,
            term2: observation.term2
        )
        let resolvedEvidenceKey: String
        switch canonicalEvidenceKey(for: observation, canonicalKey: canonical.canonicalKey) {
        case let .success(key): resolvedEvidenceKey = key
        case let .failure(rejection): return .failure(rejection)
        }
        let canonicalAnchor = reorientedAnchor(
            observation.relationshipAnchor,
            swapped: canonical.languageA != language1
        )
        return .success(TranslationGlossaryObservation(
            evidenceKey: resolvedEvidenceKey,
            kind: observation.kind,
            language1: canonical.languageA,
            term1: canonical.termA,
            language2: canonical.languageB,
            term2: canonical.termB,
            authoredSurfaces: observation.authoredSurfaces,
            sourceMessageID: observation.sourceMessageID,
            sourceDraftID: observation.sourceDraftID,
            sourceAccountID: observation.sourceAccountID,
            sourceAuthorAddress: observation.sourceAuthorAddress,
            relationshipAnchor: canonicalAnchor,
            excerpt: observation.excerpt,
            observedAt: observation.observedAt,
            strength: TranslationGlossaryPolicy.clamp(observation.strength)
        ))
    }

    private static func reorientedAnchor(
        _ anchor: TranslationGlossaryRelationshipAnchor?,
        swapped: Bool
    ) -> TranslationGlossaryRelationshipAnchor? {
        guard swapped, let anchor else { return anchor }
        switch anchor {
        case let .composerCorrection(sourceIndex, finalIndex):
            return .composerCorrection(
                sourceSurfaceIndex: finalIndex,
                finalUserTextSurfaceIndex: sourceIndex
            )
        case let .linkedCorrespondence(sourceIndex, relatedIndex, relatedMessageID, provenance):
            return .linkedCorrespondence(
                sourceSurfaceIndex: relatedIndex,
                relatedSurfaceIndex: sourceIndex,
                relatedMessageID: relatedMessageID,
                provenance: provenance
            )
        case let .correspondentIdentity(sourceIndex, relatedIndex, provenance):
            return .correspondentIdentity(
                sourceSurfaceIndex: relatedIndex,
                relatedSurfaceIndex: sourceIndex,
                provenance: provenance
            )
        }
    }

    private static func isValidTerm(_ term: String, language: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.count <= maximumTermLength else { return false }
        let folded = trimmed.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard placeholderTerms.contains(folded) == false,
              beginsWithScaffolding(folded, candidates: greetings) == false,
              beginsWithAttachedCJKGreeting(trimmed, language: language) == false,
              headerLabels.contains(folded) == false,
              headerLabels.contains(where: { folded.hasPrefix("\($0):") }) == false,
              folded.contains("@") == false,
              folded.contains("http://") == false,
              folded.contains("https://") == false else {
            return false
        }
        let tokens = scaffoldTokens(in: folded)
        return tokens.isEmpty == false && tokens.allSatisfy { ignoredNameTokens.contains($0) } == false
    }

    private static func requiresAutomatedArtifactFiltering(
        _ kind: TranslationGlossaryEvidenceKind
    ) -> Bool {
        switch kind {
        case .manual, .composerCorrection:
            return false
        case .explicitBilingualNotation, .trustedIdentityDeclaration,
             .correspondentIdentity, .linkedCorrespondence, .modelRendering:
            return true
        }
    }

    /// Rejects transient mail metadata that can resemble a short bilingual
    /// pair after signature or subject punctuation is split. Manual entries
    /// and explicit Composer corrections remain authoritative.
    private static func isLikelyMessageMetadata(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased(with: Locale(identifier: "en_US_POSIX"))

        if listItemPrefixes.contains(where: trimmed.hasPrefix) { return true }
        if mailingListViaMarkers.contains(where: folded.contains) { return true }
        if messageSubjectPrefixes.contains(where: { beginsWithFieldPrefix(folded, prefix: $0) }) {
            return true
        }
        if contactFieldLabels.contains(where: { beginsWithFieldPrefix(folded, prefix: $0) }) {
            return true
        }
        if looksLikeTelephoneExtension(trimmed) { return true }
        return looksLikeCalendarDate(trimmed, folded: folded)
    }

    private static func beginsWithFieldPrefix(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let suffix = value.dropFirst(prefix.count)
        guard let first = suffix.first else { return false }
        return first == ":" || first == "："
    }

    private static func looksLikeTelephoneExtension(_ value: String) -> Bool {
        guard value.hasPrefix("内") else { return false }
        let suffix = value.dropFirst()
        let digits = suffix.filter(\.isNumber)
        guard digits.count >= 3 else { return false }
        return suffix.allSatisfy { character in
            character.isNumber || character.isWhitespace || "-‐‑‒–—".contains(character)
        }
    }

    private static func looksLikeCalendarDate(_ value: String, folded: String) -> Bool {
        guard value.contains(where: \.isNumber) else { return false }
        let tokens = Set(scaffoldTokens(in: folded))
        if tokens.isDisjoint(with: calendarMonthTokens) == false { return true }
        return value.contains("年")
            || (value.contains("月") && value.contains("日"))
    }

    /// The shared script-compatibility contract for deterministic evidence
    /// producers. A producer must only infer an unlabeled language when this
    /// returns exactly one declared language.
    public static func scriptCompatibleDeclaredLanguages(
        for term: String,
        declaredLanguages: [String]
    ) -> [String] {
        Array(Set(declaredLanguages.compactMap(LocalModelLanguageSupport.canonicalLanguageID(for:)))
            .filter { matchesDeclaredLanguage(term, language: $0) })
            .sorted()
    }

    /// Conservative person-name shape for raw signature candidates and other
    /// untrusted text-derived identity surfaces. Trusted participant/contact
    /// metadata is not limited to people because organization renderings are
    /// also legitimate glossary evidence.
    public static func isPlausiblePersonalName(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              trimmed.count <= maximumTermLength,
              trimmed.rangeOfCharacter(from: .newlines) == nil,
              trimmed.rangeOfCharacter(from: .decimalDigits) == nil,
              trimmed.contains("@") == false,
              trimmed.contains("://") == false,
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ",;|/\\")) == nil else {
            return false
        }

        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.isEmpty == false, words.count <= 5 else { return false }
        let folded = trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let foldedTokens = Set(scaffoldTokens(in: folded))
        guard foldedTokens.isDisjoint(with: organizationOrTitleTokens),
              organizationMarkers.contains(where: folded.contains) == false,
              organizationSuffixes.contains(where: folded.hasSuffix) == false else {
            return false
        }

        let families = scriptFamilies(in: trimmed)
        guard families.isEmpty == false,
              families.isSubset(of: [.latin, .cyrillic, .han, .kana, .hangul]) else {
            return false
        }
        if families.isSubset(of: [.latin, .cyrillic]) {
            return words.allSatisfy { word in
                guard let firstLetter = word.first(where: \.isLetter) else { return false }
                return firstLetter.isUppercase
            }
        }
        return trimmed.filter(\.isLetter).count <= 12
    }

    /// Returns a name only from a bounded, recognized localized signature
    /// field. Unlabeled signature prose is never guessed to be an identity.
    public static func personalNameValue(inLabeledField line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              trimmed.utf16.count <= 200,
              trimmed.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }
        let separators = trimmed.indices.filter { trimmed[$0] == ":" || trimmed[$0] == "：" }
        guard separators.count == 1, let separator = separators.first else { return nil }
        let label = trimmed[..<separator]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let value = trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard signatureNameFieldLabels.contains(label),
              isPlausiblePersonalName(value) else {
            return nil
        }
        return value
    }

    private static func matchesDeclaredLanguage(_ term: String, language: String) -> Bool {
        switch language {
        case "ja": return hasOnlyAllowedScripts(term, allowed: [.han, .kana, .latin], requiring: [.han, .kana])
        case "zh": return hasOnlyAllowedScripts(term, allowed: [.han, .latin], requiring: [.han])
        case "ko": return hasOnlyAllowedScripts(term, allowed: [.hangul, .latin], requiring: [.hangul])
        case "ru": return hasOnlyAllowedScripts(term, allowed: [.cyrillic, .latin], requiring: [.cyrillic])
        case "en", "fr", "de", "es", "pt", "it": return hasOnlyAllowedScripts(term, allowed: [.latin], requiring: [.latin])
        default: return false
        }
    }

    private static func sharedScriptAnchorValidation(
        language1: String,
        term1: String,
        language2: String,
        term2: String,
        kind: TranslationGlossaryEvidenceKind,
        surfaces: [String],
        sourceMessageID: UUID?,
        sourceDraftID: UUID?,
        sourceAuthorAddress: String?,
        relationshipAnchor: TranslationGlossaryRelationshipAnchor?
    ) -> Result<Void, TranslationGlossaryCandidateRejection> {
        if kind == .linkedCorrespondence {
            return validateLinkedCorrespondenceAnchor(
                term1: term1,
                term2: term2,
                surfaces: surfaces,
                sourceMessageID: sourceMessageID,
                sourceAuthorAddress: sourceAuthorAddress,
                relationshipAnchor: relationshipAnchor
            )
        }
        guard scriptFamilies(in: term1).isDisjoint(with: scriptFamilies(in: term2)) == false else {
            return .success(())
        }
        switch kind {
        case .manual:
            return .success(())
        case .explicitBilingualNotation:
            return surfaces.contains {
                locallyPairsExplicitTerms($0, term1: term1, term2: term2, language1: language1, language2: language2)
            }
                ? .success(())
                : .failure(.insufficientSharedScriptAnchor)
        case .composerCorrection:
            guard let relationshipAnchor else {
                return .failure(.insufficientSharedScriptAnchor)
            }
            guard sourceDraftID != nil,
                  case let .composerCorrection(sourceIndex, finalIndex) = relationshipAnchor,
                  indexesAreDistinctAndBounded(sourceIndex, finalIndex, in: surfaces)
                && surface(at: sourceIndex, in: surfaces, contains: term1)
                && surface(at: finalIndex, in: surfaces, contains: term2) else {
                return .failure(.invalidRelationshipAnchor)
            }
            return .success(())
        case .linkedCorrespondence:
            return .failure(.invalidRelationshipAnchor) // handled above
        case .correspondentIdentity:
            return validateCorrespondentIdentityAnchor(
                term1: term1,
                term2: term2,
                surfaces: surfaces,
                sourceAuthorAddress: sourceAuthorAddress,
                relationshipAnchor: relationshipAnchor
            )
        case .trustedIdentityDeclaration, .modelRendering:
            return .failure(.insufficientSharedScriptAnchor)
        }
    }

    private static func validateCorrespondentIdentityAnchor(
        term1: String,
        term2: String,
        surfaces: [String],
        sourceAuthorAddress: String?,
        relationshipAnchor: TranslationGlossaryRelationshipAnchor?
    ) -> Result<Void, TranslationGlossaryCandidateRejection> {
        guard let relationshipAnchor else {
            return .failure(.insufficientSharedScriptAnchor)
        }
        guard case let .correspondentIdentity(sourceIndex, relatedIndex, provenance) = relationshipAnchor,
              indexesAreDistinctAndBounded(sourceIndex, relatedIndex, in: surfaces),
              surface(at: sourceIndex, in: surfaces, contains: term1),
              surface(at: relatedIndex, in: surfaces, contains: term2),
              validCorrespondentIdentityProvenance(
                provenance,
                sourceAuthorAddress: sourceAuthorAddress
              ) else {
            return .failure(.invalidRelationshipAnchor)
        }
        return .success(())
    }

    private static func validateLinkedCorrespondenceAnchor(
        term1: String,
        term2: String,
        surfaces: [String],
        sourceMessageID: UUID?,
        sourceAuthorAddress: String?,
        relationshipAnchor: TranslationGlossaryRelationshipAnchor?
    ) -> Result<Void, TranslationGlossaryCandidateRejection> {
        guard let relationshipAnchor else {
            return .failure(.insufficientSharedScriptAnchor)
        }
        guard let sourceMessageID,
              case let .linkedCorrespondence(sourceIndex, relatedIndex, relatedMessageID, provenance) = relationshipAnchor,
              relatedMessageID != sourceMessageID,
              indexesAreDistinctAndBounded(sourceIndex, relatedIndex, in: surfaces),
              surface(at: sourceIndex, in: surfaces, contains: term1),
              surface(at: relatedIndex, in: surfaces, contains: term2),
              validLinkedProvenance(provenance, sourceAuthorAddress: sourceAuthorAddress) else {
            return .failure(.invalidRelationshipAnchor)
        }
        return .success(())
    }

    private static func occursInAuthoredSurfaces(_ term: String, surfaces: [String]) -> Bool {
        surfaces.contains { $0.range(of: term) != nil }
    }

    private static func indexesAreDistinctAndBounded(_ first: Int, _ second: Int, in surfaces: [String]) -> Bool {
        first != second && surfaces.indices.contains(first) && surfaces.indices.contains(second)
    }

    private static func surface(at index: Int, in surfaces: [String], contains term: String) -> Bool {
        surfaces.indices.contains(index) && surfaces[index].range(of: term, options: .literal) != nil
    }

    private static func validLinkedProvenance(
        _ provenance: TranslationGlossaryLinkProvenance,
        sourceAuthorAddress: String?
    ) -> Bool {
        switch provenance {
        case let .normalizedParticipantAddress(address):
            guard let normalized = normalizedEmailAddress(address),
                  let source = normalizedEmailAddress(sourceAuthorAddress) else { return false }
            return normalized == source
        case let .thread(_, attributableIdentity):
            guard let normalized = normalizedEmailAddress(attributableIdentity),
                  let source = normalizedEmailAddress(sourceAuthorAddress) else { return false }
            return normalized == source
        case let .quotedAttribution(address):
            return normalizedEmailAddress(address) != nil
        case let .stableIdentity(identity):
            return identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && identity.count <= 256
        }
    }

    private static func validCorrespondentIdentityProvenance(
        _ provenance: TranslationGlossaryLinkProvenance,
        sourceAuthorAddress: String?
    ) -> Bool {
        switch provenance {
        case .normalizedParticipantAddress, .stableIdentity:
            return validLinkedProvenance(
                provenance,
                sourceAuthorAddress: sourceAuthorAddress
            )
        case .thread, .quotedAttribution:
            return false
        }
    }

    private static func normalizedEmailAddress(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count <= 320,
              let at = normalized.firstIndex(of: "@"),
              at != normalized.startIndex,
              normalized.index(after: at) != normalized.endIndex,
              normalized[normalized.index(after: at)...].contains(".") else { return nil }
        return normalized
    }

    private static func scriptFamilies(in value: String) -> Set<ScriptFamily> {
        var families: Set<ScriptFamily> = []
        for scalar in value.unicodeScalars {
            if let family = scriptFamily(of: scalar) { families.insert(family) }
        }
        return families
    }

    private static func hasOnlyAllowedScripts(
        _ value: String,
        allowed: Set<ScriptFamily>,
        requiring required: Set<ScriptFamily>
    ) -> Bool {
        let families = scriptFamilies(in: value)
        guard families.isEmpty == false, families.isSubset(of: allowed), families.isDisjoint(with: required) == false else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            guard let family = scriptFamily(of: scalar) else { return isNeutral(scalar) }
            return allowed.contains(family)
        }
    }

    private static func scriptFamily(of scalar: Unicode.Scalar) -> ScriptFamily? {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF: .latin
        case 0x3040...0x30FF, 0x31F0...0x31FF: .kana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: .han
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: .hangul
        case 0x0400...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F: .cyrillic
        default: nil
        }
    }

    private static func isNeutral(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
            || CharacterSet.decimalDigits.contains(scalar)
            || CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.nonBaseCharacters.contains(scalar)
            || (0x3000...0x303F).contains(scalar.value)
    }

    private static func locallyPairsExplicitTerms(
        _ surface: String,
        term1: String,
        term2: String,
        language1: String,
        language2: String
    ) -> Bool {
        if hasBoundedConnector(surface, first: term1, second: term2)
            || hasBoundedConnector(surface, first: term2, second: term1) {
            return true
        }
        let label1 = LocalModelLanguageSupport.displayName(for: language1) ?? language1
        let label2 = LocalModelLanguageSupport.displayName(for: language2) ?? language2
        let lines = surface
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let first = "\(label1): \(term1)".lowercased()
        let second = "\(label2): \(term2)".lowercased()
        return lines.indices.dropLast().contains { index in
            let lhs = lines[index].lowercased()
            let rhs = lines[lines.index(after: index)].lowercased()
            return (lhs == first && rhs == second) || (lhs == second && rhs == first)
        }
    }

    private static func hasBoundedConnector(_ surface: String, first: String, second: String) -> Bool {
        guard let firstRange = surface.range(of: first, options: .literal),
              let secondRange = surface.range(of: second, options: .literal),
              firstRange.upperBound <= secondRange.lowerBound else { return false }
        let gap = surface[firstRange.upperBound..<secondRange.lowerBound]
        guard gap.count <= 24 else { return false }
        let trimmed = gap.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/" || trimmed == "／" { return true }
        if trimmed == "(" || trimmed == "（" {
            let suffix = surface[secondRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.first == ")" || suffix.first == "）"
        }
        return false
    }

    private static func canonicalEvidenceKey(
        for observation: TranslationGlossaryObservation,
        canonicalKey: String
    ) -> Result<String, TranslationGlossaryCandidateRejection> {
        let record: String?
        switch observation.kind {
        case .manual:
            return .success("manual:\(canonicalKey)")
        case .composerCorrection:
            record = observation.sourceDraftID.map { "draft:\($0.uuidString.lowercased())" }
        case .linkedCorrespondence:
            record = observation.sourceMessageID.map { "message:\($0.uuidString.lowercased())" }
        case .explicitBilingualNotation:
            record = observation.sourceMessageID.map { "message:\($0.uuidString.lowercased())" }
                ?? observation.sourceDraftID.map { "draft:\($0.uuidString.lowercased())" }
        case .trustedIdentityDeclaration:
            record = observation.sourceMessageID.map { "message:\($0.uuidString.lowercased())" }
                ?? observation.sourceDraftID.map { "draft:\($0.uuidString.lowercased())" }
                ?? observation.sourceAuthorAddress.map { "identity:\($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" }
        case .correspondentIdentity:
            record = observation.sourceMessageID.map { "message:\($0.uuidString.lowercased())" }
                ?? observation.sourceAuthorAddress.map { "identity:\($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" }
        case .modelRendering:
            // One record per canonical pair, whatever message surfaced it:
            // a model rendering can never reinforce itself.
            return .success("modelRendering:\(canonicalKey)")
        }
        guard let record, record.isEmpty == false else { return .failure(.missingEvidenceSourceIdentity) }
        return .success("\(observation.kind.rawValue):\(record):\(canonicalKey)")
    }

    private static func scaffoldTokens(in value: String) -> [String] {
        value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.isEmpty == false }
    }

    private static func beginsWithScaffolding(_ value: String, candidates: Set<String>) -> Bool {
        candidates.contains { candidate in
            guard value.hasPrefix(candidate) else { return false }
            let suffix = value.dropFirst(candidate.count)
            guard let first = suffix.unicodeScalars.first else { return true }
            return CharacterSet.whitespacesAndNewlines.contains(first)
                || CharacterSet.punctuationCharacters.contains(first)
        }
    }

    private static func beginsWithAttachedCJKGreeting(_ value: String, language: String) -> Bool {
        cjkAttachedGreetingPrefixes[language]?.contains { prefix in
            value.hasPrefix(prefix) && value.count > prefix.count
        } ?? false
    }

    private static func removingAttachedCJKHonorificAffixes(from value: String, language: String) -> String {
        var result = value
        while let prefix = cjkHonorificPrefixes[language]?.first(where: {
            result.hasPrefix($0) && result.count > $0.count
        }) {
            result.removeFirst(prefix.count)
        }
        while let suffix = cjkHonorificSuffixes[language]?.first(where: {
            result.hasSuffix($0) && result.count > $0.count
        }) {
            result.removeLast(suffix.count)
        }
        return result
    }

    private static func orderInsensitiveNameKey(_ term: String, language: String) -> [String] {
        removingAttachedCJKHonorificAffixes(from: term, language: language)
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.isEmpty == false && ignoredNameTokens.contains($0) == false }
            .sorted()
    }

    private static let placeholderTerms: Set<String> = [
        "(not present)", "not present", "n/a", "[unknown]", "（該当なし）", "該当なし", "なし", "---", "?"
    ]

    private static let organizationOrTitleTokens: Set<String> = [
        "department", "faculty", "institute", "laboratory", "office", "school", "university",
        "college", "center", "centre", "division", "program", "programme", "professor", "doctor",
        "кафедра", "университет", "институт", "факультет", "профессор",
    ]

    private static let organizationSuffixes = [
        "大学", "学部", "学科", "研究科", "研究所", "研究部", "事業部", "営業部", "総務部", "人事部",
        "営業課", "総務課", "人事課", "研究課", "研究室", "事務室", "会議室", "委員会", "センター", "事務局",
        "本社", "支社", "支店", "会社", "学校",
        "학교", "대학교", "학부", "학과", "연구소", "부서", "센터",
    ]
    private static let organizationMarkers = ["株式会社", "有限会社", "合同会社"]
    private static let signatureNameFieldLabels: Set<String> = [
        // English and explicit language-specific English labels
        "name", "full name", "english name", "chinese name", "japanese name", "korean name",
        "french name", "german name", "spanish name", "portuguese name", "italian name", "russian name",
        // Chinese and Japanese
        "姓名", "名字", "氏名", "名前", "お名前", "日本語名", "英語名",
        // Korean
        "성명", "이름",
        // French
        "nom", "nom complet",
        // German (diacritic-folded)
        "vollstandiger name",
        // Spanish
        "nombre", "nombre completo",
        // Portuguese and Italian
        "nome", "nome completo",
        // Russian
        "имя", "фио",
    ]
    private static let greetings: Set<String> = [
        "hi", "hello", "dear", "greetings", "bonjour", "hallo", "hola", "olá", "ciao", "привет", "你好", "您好", "こんにちは", "お世話になっております", "안녕하세요"
    ]
    private static let headerLabels: Set<String> = [
        "from", "to", "cc", "bcc", "subject", "sender", "recipient", "reply-to", "de", "à", "objet", "expéditeur", "destinataire", "von", "an", "betreff", "para", "asunto", "assunto", "da", "a", "oggetto", "от", "кому", "тема", "发件人", "收件人", "主题", "抄送", "密送", "差出人", "宛先", "件名", "送信者", "보낸사람", "받는사람", "제목"
    ]
    private static let listItemPrefixes = ["- ", "– ", "— ", "• ", "* "]
    private static let mailingListViaMarkers = ["' via ", "’ via "]
    private static let messageSubjectPrefixes = ["re", "fw", "fwd"]
    private static let contactFieldLabels = [
        "tel", "telephone", "phone", "mobile", "fax", "ext", "extension", "内線",
    ]
    private static let calendarMonthTokens: Set<String> = [
        "jan", "january", "feb", "february", "mar", "march", "apr", "april",
        "may", "jun", "june", "jul", "july", "aug", "august", "sep", "sept",
        "september", "oct", "october", "nov", "november", "dec", "december",
    ]
    private static let ignoredNameTokens: Set<String> = [
        "mr", "mrs", "ms", "miss", "dr", "prof", "professor", "sir", "madam", "m", "mme", "mlle", "monsieur", "madame", "herr", "frau", "hr", "señor", "señora", "sr", "sra", "senhor", "senhora", "signor", "signora", "sig", "sigra", "г", "н", "жа", "господин", "госпожа", "san", "sama", "sensei", "先生", "様", "선생님"
    ]
    private static let cjkAttachedGreetingPrefixes: [String: [String]] = [
        "zh": ["您好", "你好"],
        "ja": ["こんにちは", "こんばんは", "おはよう"],
        "ko": ["안녕하십니까", "안녕하세요", "안녕"],
    ]
    private static let cjkHonorificPrefixes: [String: [String]] = [
        "zh": ["尊敬的", "教授", "老师", "先生", "女士", "同学"],
        "ja": ["先生", "教授", "様"],
        "ko": ["선생님", "교수님", "님", "씨"],
    ]
    private static let cjkHonorificSuffixes: [String: [String]] = [
        "zh": ["教授", "老师", "先生", "女士", "同学", "总"],
        "ja": ["先生", "教授", "ちゃん", "さん", "様", "君"],
        "ko": ["선생님", "교수님", "님", "씨"],
    ]

    private enum ScriptFamily: Hashable {
        case latin
        case kana
        case han
        case hangul
        case cyrillic
    }
}
