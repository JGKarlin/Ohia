import Foundation
import OhiaCore

public struct TranslationGlossaryIdentitySurface: Sendable, Equatable {
    public enum Provenance: Sendable, Equatable {
        case participantAddress(String)
        case quotedAttribution(String)
        case stableSignature(String)
        case stableContact(String)
    }

    public let term: String
    public let language: String?
    public let provenance: Provenance

    public init(term: String, language: String? = nil, provenance: Provenance) {
        self.term = term
        self.language = language.flatMap(LocalModelLanguageSupport.canonicalLanguageID(for:))
        self.provenance = provenance
    }
}

/// Authored material for deterministic evidence. Subjects are notation-only;
/// every identity term carries typed provenance to the person it represents.
public struct TranslationGlossaryEvidenceSource: Sendable, Equatable {
    public let messageID: UUID
    public let accountID: UUID?
    public let authorAddress: String
    public let declaredLanguages: [String]
    public let body: String
    public let identitySurfaces: [TranslationGlossaryIdentitySurface]
    public let notationHeaderSurfaces: [String]
    public let threadID: UUID?
    public let observedAt: Date

    public init(
        messageID: UUID,
        accountID: UUID?,
        authorAddress: String,
        declaredLanguages: [String],
        body: String,
        identitySurfaces: [TranslationGlossaryIdentitySurface] = [],
        notationHeaderSurfaces: [String] = [],
        threadID: UUID?,
        observedAt: Date
    ) {
        self.messageID = messageID; self.accountID = accountID; self.authorAddress = authorAddress
        self.declaredLanguages = declaredLanguages; self.body = body
        self.identitySurfaces = identitySurfaces.nonEmptyUnique
        self.notationHeaderSurfaces = notationHeaderSurfaces
        self.threadID = threadID; self.observedAt = observedAt
    }

    public var notationSurfaces: [String] { ([body] + notationHeaderSurfaces).nonEmptyUnique }
}

public enum TranslationGlossaryEvidenceProducers {
    public struct IdentityRecord: Sendable, Equatable {
        public let address: String; public let displayName: String; public let language: String
        public let accountID: UUID?; public let sourceMessageID: UUID?; public let observedAt: Date
        public init(address: String, displayName: String, language: String, accountID: UUID?, sourceMessageID: UUID? = nil, observedAt: Date) {
            self.address = address; self.displayName = displayName; self.language = language
            self.accountID = accountID; self.sourceMessageID = sourceMessageID; self.observedAt = observedAt
        }
    }

    /// Produces only observations owned by `current`; this makes a newly
    /// arrived spelling additive without rewriting old message evidence.
    public static func identityObservations(current: IdentityRecord, related: [IdentityRecord]) -> [TranslationGlossaryObservation] {
        related.compactMap { other in
            let address = normalizedAddress(current.address)
            guard current.sourceMessageID != other.sourceMessageID || current.sourceMessageID == nil,
                  address == normalizedAddress(other.address),
                  substantivelyDifferent(current.displayName, other.displayName) else { return nil }
            return validatedObservation(key: "identity:\(address):\(current.displayName):\(other.displayName)", kind: .correspondentIdentity, language1: current.language, term1: current.displayName, language2: other.language, term2: other.displayName, surfaces: [current.displayName, other.displayName], sourceMessageID: current.sourceMessageID, sourceAccountID: current.accountID, sourceAuthorAddress: current.address, anchor: .correspondentIdentity(sourceSurfaceIndex: 0, relatedSurfaceIndex: 1, provenance: .normalizedParticipantAddress(address)), observedAt: current.observedAt, strength: TranslationGlossaryPolicy.correspondentIdentityStrength)
        }.uniqued(by: \.evidenceKey)
    }

    /// Compatibility entry point for callers that explicitly provide a finite
    /// record set. The newest record owns each observation.
    public static func identityObservations(records: [IdentityRecord]) -> [TranslationGlossaryObservation] {
        records.enumerated().flatMap { index, current in
            identityObservations(current: current, related: Array(records[..<index]))
        }.uniqued(by: \.evidenceKey)
    }

    public static func explicitNotationObservations(from source: TranslationGlossaryEvidenceSource) -> [TranslationGlossaryObservation] {
        let surfaces = source.notationSurfaces
        let candidates = surfaces.flatMap {
            localPairs(
                in: $0,
                declaredLanguages: source.declaredLanguages,
                identitySurfaces: source.identitySurfaces
            )
        }
        return candidates.compactMap { candidate in
            guard let lhs = candidate.firstLanguage ?? uniquelyCompatibleLanguage(for: candidate.first, declared: source.declaredLanguages),
                  let rhs = candidate.secondLanguage ?? uniquelyCompatibleLanguage(for: candidate.second, declared: source.declaredLanguages) else { return nil }
            return validatedObservation(key: "notation:\(source.messageID.uuidString):\(candidate.first):\(candidate.second)", kind: .explicitBilingualNotation, language1: lhs, term1: candidate.first, language2: rhs, term2: candidate.second, surfaces: surfaces, sourceMessageID: source.messageID, sourceAccountID: source.accountID, sourceAuthorAddress: source.authorAddress, anchor: nil, observedAt: source.observedAt, strength: candidate.strength)
        }.strongestByEvidenceKey
    }

    public static func linkedCorrespondenceObservations(source: TranslationGlossaryEvidenceSource, related: [TranslationGlossaryEvidenceSource]) -> [TranslationGlossaryObservation] {
        related.flatMap { other -> [TranslationGlossaryObservation] in
            guard other.messageID != source.messageID else { return [] }
            return source.identitySurfaces.flatMap { first in
                other.identitySurfaces.compactMap { second in
                    guard identityKey(first.provenance) == identityKey(second.provenance),
                          safeIdentitySurface(first), safeIdentitySurface(second),
                          let provenance = linkProvenance(source: source, first: first, other: other, second: second),
                          let lhs = first.language ?? uniquelyCompatibleLanguage(for: first.term, declared: source.declaredLanguages),
                          let rhs = second.language ?? uniquelyCompatibleLanguage(for: second.term, declared: other.declaredLanguages),
                          substantivelyDifferent(first.term, second.term) else { return nil }
                    return validatedObservation(
                        key: "linked:\(source.messageID.uuidString):\(other.messageID.uuidString):\(first.term):\(second.term)",
                        kind: .linkedCorrespondence,
                        language1: lhs, term1: first.term,
                        language2: rhs, term2: second.term,
                        surfaces: [first.term, second.term],
                        sourceMessageID: source.messageID,
                        sourceAccountID: source.accountID,
                        sourceAuthorAddress: source.authorAddress,
                        anchor: .linkedCorrespondence(
                            sourceSurfaceIndex: 0,
                            relatedSurfaceIndex: 1,
                            relatedMessageID: other.messageID,
                            provenance: provenance
                        ),
                        observedAt: source.observedAt,
                        strength: 0.40
                    )
                }
            }
        }.uniqued(by: \.evidenceKey)
    }

    private static func identityKey(_ provenance: TranslationGlossaryIdentitySurface.Provenance) -> String {
        switch provenance {
        case let .participantAddress(address), let .quotedAttribution(address):
            return "address:\(normalizedAddress(address))"
        case let .stableSignature(identity), let .stableContact(identity):
            let normalized = identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.hasPrefix("address:") ? normalized : "stable:\(normalized)"
        }
    }

    /// Participant, contact, and structured attribution metadata may name an
    /// organization as well as a person. Only raw signature-derived terms use
    /// the stricter personal-name classifier after extraction from a
    /// recognized labeled field.
    private static func safeIdentitySurface(_ surface: TranslationGlossaryIdentitySurface) -> Bool {
        guard case .stableSignature = surface.provenance else { return true }
        return TranslationGlossaryCandidateValidator.isPlausiblePersonalName(surface.term)
    }

    private static func linkProvenance(
        source: TranslationGlossaryEvidenceSource,
        first: TranslationGlossaryIdentitySurface,
        other: TranslationGlossaryEvidenceSource,
        second: TranslationGlossaryIdentitySurface
    ) -> TranslationGlossaryLinkProvenance? {
        let key = identityKey(first.provenance)
        guard key == identityKey(second.provenance) else { return nil }
        if case let .quotedAttribution(address) = first.provenance {
            return .quotedAttribution(address: normalizedAddress(address))
        }
        if case let .quotedAttribution(address) = second.provenance {
            return .quotedAttribution(address: normalizedAddress(address))
        }
        if case .stableSignature = first.provenance { return .stableIdentity(stableIdentityValue(first.provenance)) }
        if case .stableContact = first.provenance { return .stableIdentity(stableIdentityValue(first.provenance)) }
        if case .stableSignature = second.provenance { return .stableIdentity(stableIdentityValue(second.provenance)) }
        if case .stableContact = second.provenance { return .stableIdentity(stableIdentityValue(second.provenance)) }
        let address = normalizedAddress(source.authorAddress)
        guard address == normalizedAddress(other.authorAddress), key == "address:\(address)" else { return nil }
        if let threadID = source.threadID, threadID == other.threadID {
            return .thread(threadID: threadID, attributableIdentity: address)
        }
        return .normalizedParticipantAddress(address)
    }

    private static func stableIdentityValue(_ provenance: TranslationGlossaryIdentitySurface.Provenance) -> String {
        switch provenance {
        case let .stableSignature(identity), let .stableContact(identity):
            return identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case let .participantAddress(address), let .quotedAttribution(address):
            return normalizedAddress(address)
        }
    }

    private struct LocalPair {
        let first: String
        let second: String
        let firstLanguage: String?
        let secondLanguage: String?
        let strength: Double
    }

    private static func localPairs(
        in surface: String,
        declaredLanguages: [String],
        identitySurfaces: [TranslationGlossaryIdentitySurface]
    ) -> [LocalPair] {
        let lines = surface.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var pairs = lines.compactMap { line -> LocalPair? in
            guard let pair = structuralPair(in: String(line)) else { return nil }
            let strength = identitySurfacesPair(
                pair.0,
                pair.1,
                identitySurfaces: identitySurfaces,
                declaredLanguages: declaredLanguages
            )
                ? TranslationGlossaryPolicy.explicitBilingualNotationStrength
                : TranslationGlossaryPolicy.provisionalThreshold
            return LocalPair(
                first: pair.0,
                second: pair.1,
                firstLanguage: nil,
                secondLanguage: nil,
                strength: strength
            )
        }
        var pending: (language: String, value: String)?
        for line in lines {
            guard line.isEmpty == false else {
                pending = nil
                continue
            }
            guard let labeled = labeledValue(in: String(line), declaredLanguages: declaredLanguages) else {
                pending = nil
                continue
            }
            if let prior = pending, prior.language != labeled.language {
                pairs.append(LocalPair(
                    first: prior.value,
                    second: labeled.value,
                    firstLanguage: prior.language,
                    secondLanguage: labeled.language,
                    strength: TranslationGlossaryPolicy.explicitBilingualNotationStrength
                ))
                pending = nil
            } else {
                pending = labeled
            }
        }
        return pairs
    }

    /// A notation must occupy the complete trimmed line. This intentionally
    /// rejects prose appositives and sentence-internal punctuation.
    private static func structuralPair(in line: String) -> (String, String)? {
        guard line.isEmpty == false, line.count <= 170 else { return nil }
        if let open = line.firstIndex(where: { $0 == "(" || $0 == "（" }),
           let close = line.lastIndex(where: { $0 == ")" || $0 == "）" }), open < close,
           line.index(after: close) == line.endIndex {
            let lhs = String(line[..<open]).trimmingCharacters(in: .whitespaces)
            let rhs = String(line[line.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            guard line.filter({ $0 == "(" || $0 == "（" || $0 == ")" || $0 == "）" }).count == 2 else { return nil }
            return entityLike(lhs) && entityLike(rhs) ? (lhs, rhs) : nil
        }
        let separators = line.indices.filter { line[$0] == "/" || line[$0] == "／" }
        guard separators.count == 1, let separator = separators.first else { return nil }
        let lhs = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        let rhs = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        return entityLike(lhs) && entityLike(rhs) ? (lhs, rhs) : nil
    }

    private static func labeledValue(in line: String, declaredLanguages: [String]) -> (language: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let label = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = ["english name": "en", "japanese name": "ja", "chinese name": "zh", "korean name": "ko", "russian name": "ru", "french name": "fr", "german name": "de", "spanish name": "es", "portuguese name": "pt", "italian name": "it"]
        guard let language = labels[label], declaredLanguages.compactMap(LocalModelLanguageSupport.canonicalLanguageID(for:)).contains(language), entityLike(value) else { return nil }
        return (language, value)
    }

    private static func uniquelyCompatibleLanguage(for term: String, declared: [String]) -> String? {
        let compatible = TranslationGlossaryCandidateValidator.scriptCompatibleDeclaredLanguages(for: term, declaredLanguages: declared)
        return compatible.count == 1 ? compatible[0] : nil
    }

    private static func entityLike(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false, value.count <= TranslationGlossaryCandidateValidator.maximumTermLength,
              value.rangeOfCharacter(from: .newlines) == nil else { return false }
        let words = value.split(whereSeparator: \.isWhitespace)
        guard words.count <= 3 else { return false }
        let latinWords = words.filter { $0.unicodeScalars.contains(where: { (0x0041...0x024F).contains($0.value) }) }
        if latinWords.isEmpty {
            // Unlabeled CJK notation is intentionally name-sized, not a
            // sentence ending in a parenthesized gloss.
            return value.filter { $0.isWhitespace == false }.count <= 6
        }
        return words.count == 1 || latinWords.allSatisfy { $0.first?.isUppercase == true }
    }

    private static func identitySurfacesPair(
        _ first: String,
        _ second: String,
        identitySurfaces: [TranslationGlossaryIdentitySurface],
        declaredLanguages: [String]
    ) -> Bool {
        let firstMatches = identitySurfaces.filter {
            $0.term.trimmingCharacters(in: .whitespacesAndNewlines) == first
                && validIdentitySurface($0, declaredLanguages: declaredLanguages)
        }
        let secondMatches = identitySurfaces.filter {
            $0.term.trimmingCharacters(in: .whitespacesAndNewlines) == second
                && validIdentitySurface($0, declaredLanguages: declaredLanguages)
        }
        return firstMatches.contains { lhs in
            secondMatches.contains { identityKey(lhs.provenance) == identityKey($0.provenance) }
        }
    }

    private static func validIdentitySurface(
        _ surface: TranslationGlossaryIdentitySurface,
        declaredLanguages: [String]
    ) -> Bool {
        guard safeIdentitySurface(surface) else { return false }
        guard let language = surface.language else { return true }
        let declared = Set(declaredLanguages.compactMap(LocalModelLanguageSupport.canonicalLanguageID(for:)))
        return declared.contains(language)
            && TranslationGlossaryCandidateValidator.scriptCompatibleDeclaredLanguages(
                for: surface.term,
                declaredLanguages: [language]
            ) == [language]
    }

    private static func validatedObservation(key: String, kind: TranslationGlossaryEvidenceKind, language1: String, term1: String, language2: String, term2: String, surfaces: [String], sourceMessageID: UUID?, sourceAccountID: UUID?, sourceAuthorAddress: String?, anchor: TranslationGlossaryRelationshipAnchor?, observedAt: Date, strength: Double) -> TranslationGlossaryObservation? {
        let candidate = TranslationGlossaryObservation(evidenceKey: key, kind: kind, language1: language1, term1: term1, language2: language2, term2: term2, authoredSurfaces: surfaces, sourceMessageID: sourceMessageID, sourceDraftID: nil, sourceAccountID: sourceAccountID, sourceAuthorAddress: sourceAuthorAddress, relationshipAnchor: anchor, excerpt: surfaces.first, observedAt: observedAt, strength: strength)
        guard case let .success(validated) = TranslationGlossaryCandidateValidator.validate(candidate) else { return nil }
        return validated
    }

    static func normalizedAddress(_ address: String) -> String { address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private static func substantivelyDifferent(_ lhs: String, _ rhs: String) -> Bool { TranslationGlossaryCanonicalizer.normalizedIdentityTerm(lhs) != TranslationGlossaryCanonicalizer.normalizedIdentityTerm(rhs) }
}

private extension Array where Element == String {
    var nonEmptyUnique: [String] { var seen = Set<String>(); return filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && seen.insert($0).inserted } }
}
private extension Array where Element == TranslationGlossaryIdentitySurface {
    var nonEmptyUnique: [Element] {
        var seen = Set<String>()
        return filter {
            let term = $0.term.trimmingCharacters(in: .whitespacesAndNewlines)
            return term.isEmpty == false
                && seen.insert("\(term)|\($0.language ?? "")|\(String(describing: $0.provenance))").inserted
        }
    }
}
private extension Array where Element == TranslationGlossaryObservation {
    func uniqued(by keyPath: KeyPath<Element, String>) -> [Element] { var seen = Set<String>(); return filter { seen.insert($0[keyPath: keyPath]).inserted } }

    var strongestByEvidenceKey: [Element] {
        Dictionary(grouping: self, by: \.evidenceKey)
            .values
            .compactMap { $0.max { $0.strength < $1.strength } }
            .sorted { $0.evidenceKey < $1.evidenceKey }
    }
}
