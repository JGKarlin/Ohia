import Foundation

public enum SemanticTagCentrality: String, Codable, Sendable, Hashable, CaseIterable {
    case primary
    case secondary
    case mention

    public var weightMultiplier: Double {
        switch self {
        case .primary: 1
        case .secondary: 0.72
        case .mention: 0.42
        }
    }

    fileprivate static func parse(_ raw: String) -> Self? {
        switch normalizedWords(raw) {
        case "primary", "central", "main", "anchor": .primary
        case "secondary", "supporting": .secondary
        case "mention", "mentioned", "incidental", "background": .mention
        default: nil
        }
    }
}

public enum SemanticTagRole: String, Codable, Sendable, Hashable, CaseIterable {
    case request
    case decision
    case blocker
    case update
    case document
    case logistics
    case confirmation
    case deadline
    case scheduling
    case vendor
    case participant
    case location
    case status
    case offer
    case payment
    case access
    case other

    fileprivate static func parse(_ raw: String) -> Self? {
        switch normalizedWords(raw) {
        case "ask", "action", "action item", "request": .request
        case "approval", "choice", "decision": .decision
        case "block", "blocked", "blocker", "issue", "problem", "risk": .blocker
        case "progress", "status update", "update": .update
        case "attachment", "document", "file", "form", "packet": .document
        case "arrangement", "coordination", "logistics": .logistics
        case "acknowledgement", "acknowledgment", "confirmation": .confirmation
        case "deadline", "due date", "expiry": .deadline
        case "calendar", "meeting", "scheduling": .scheduling
        case "contractor", "provider", "supplier", "vendor": .vendor
        case "participant", "person", "recipient", "sender": .participant
        case "address", "location", "place", "venue": .location
        case "state", "status": .status
        case "deal", "offer", "promotion": .offer
        case "charge", "invoice", "payment": .payment
        case "access", "code", "login", "password": .access
        case "other": .other
        default: nil
        }
    }
}

public struct SemanticTagQualifier: Codable, Sendable, Equatable, Hashable {
    public let kind: String
    public let value: String

    public init(kind: String, value: String) {
        self.kind = normalizedWords(kind)
        self.value = collapsedWhitespace(value)
    }
}

public struct SemanticTagCandidate: Codable, Sendable, Equatable {
    public let preferredLabel: String
    public let sourceForms: [String]
    public let qualifiers: [SemanticTagQualifier]
    public let centrality: SemanticTagCentrality
    public let roles: [SemanticTagRole]
    public let confidence: Double

    public init(
        preferredLabel: String,
        sourceForms: [String],
        qualifiers: [SemanticTagQualifier],
        centrality: SemanticTagCentrality,
        roles: [SemanticTagRole],
        confidence: Double
    ) {
        self.preferredLabel = Self.cleanDisplay(preferredLabel)
        self.sourceForms = Self.uniqueNonEmpty(sourceForms.map(Self.cleanDisplay))
        self.qualifiers = Self.uniqueQualifiers(qualifiers)
        self.centrality = centrality
        self.roles = Self.uniqueRoles(roles)
        self.confidence = min(1, max(0, confidence.isFinite ? confidence : 0))
    }

    public var weightedScore: Double {
        confidence * centrality.weightMultiplier
    }

    fileprivate static func cleanDisplay(_ raw: String) -> String {
        collapsedWhitespace(raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_|/=:()[]{}\"'"))
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var identities = Set<String>()
        return values.filter { value in
            !value.isEmpty && identities.insert(normalizedComparisonText(value)).inserted
        }
    }

    private static func uniqueQualifiers(
        _ values: [SemanticTagQualifier]
    ) -> [SemanticTagQualifier] {
        var identities = Set<String>()
        return values.filter { qualifier in
            !qualifier.kind.isEmpty
                && !qualifier.value.isEmpty
                && identities.insert("\(qualifier.kind)=\(normalizedComparisonText(qualifier.value))").inserted
        }
    }

    private static func uniqueRoles(_ values: [SemanticTagRole]) -> [SemanticTagRole] {
        var identities = Set<SemanticTagRole>()
        return values.filter { identities.insert($0).inserted }
    }
}

public enum SemanticTagCandidateParsing {
    private static let maximumCandidateCount = 3
    private static let confidenceFloor = 0.45
    private static let emptySentinels: Set<String> = [
        "", "none", "null", "nil", "n a", "na", "not applicable", "empty",
    ]
    private static let classificationOnlyLabels: Set<String> = [
        "announcement", "calendar", "correspondence", "finance", "marketing",
        "notification", "receipt", "security", "support", "travel",
        "お知らせ", "カレンダー", "連絡", "財務", "マーケティング", "通知",
        "領収書", "セキュリティ", "サポート", "旅行", "旅行通知",
    ]

    public static func candidates(from fields: [String: String]) -> [SemanticTagCandidate] {
        guard let raw = fields["semanticTags"] else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !emptySentinels.contains(normalizedWords(trimmed)) else { return [] }

        var orderedIdentities: [String] = []
        var byIdentity: [String: SemanticTagCandidate] = [:]

        for rawCandidate in trimmed.components(separatedBy: "||") {
            guard let candidate = parseCandidate(rawCandidate),
                  candidate.confidence >= confidenceFloor,
                  isReusable(candidate) else {
                continue
            }
            let identity = orderInsensitiveIdentity(candidate.preferredLabel)
            guard !identity.isEmpty else { continue }
            if let existing = byIdentity[identity] {
                if candidate.weightedScore > existing.weightedScore {
                    byIdentity[identity] = candidate
                }
            } else {
                orderedIdentities.append(identity)
                byIdentity[identity] = candidate
            }
        }

        let deduplicated = orderedIdentities.compactMap { byIdentity[$0] }
        let withoutBroadParents = deduplicated.filter { candidate in
            !deduplicated.contains { other in
                candidate.preferredLabel != other.preferredLabel
                    && isBroad(candidate, comparedWith: other)
            }
        }
        return Array(withoutBroadParents.prefix(maximumCandidateCount))
    }

    private static func parseCandidate(_ raw: String) -> SemanticTagCandidate? {
        let parts = raw
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 6 else { return nil }

        let preferredLabel = SemanticTagCandidate.cleanDisplay(parts[0])
        guard !preferredLabel.isEmpty,
              let aliasValue = assignmentValue(parts[1], key: "aliases"),
              let qualifierValue = assignmentValue(parts[2], key: "qualifiers"),
              let centralityValue = assignmentValue(parts[3], key: "centrality"),
              let roleValue = assignmentValue(parts[4], key: "roles"),
              let confidenceValue = assignmentValue(parts[5], key: "confidence"),
              let centrality = SemanticTagCentrality.parse(centralityValue),
              let confidence = Double(confidenceValue),
              confidence.isFinite else {
            return nil
        }

        let sourceForms = aliasValue
            .components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sourceForms.isEmpty else { return nil }

        let qualifiers = qualifierValue
            .components(separatedBy: ",")
            .compactMap(parseQualifier)
        let roles = roleValue
            .replacingOccurrences(of: "/", with: "+")
            .replacingOccurrences(of: ",", with: "+")
            .components(separatedBy: "+")
            .compactMap(SemanticTagRole.parse)

        return SemanticTagCandidate(
            preferredLabel: preferredLabel,
            sourceForms: sourceForms,
            qualifiers: qualifiers,
            centrality: centrality,
            roles: roles,
            confidence: confidence
        )
    }

    private static func parseQualifier(_ raw: String) -> SemanticTagQualifier? {
        guard let delimiter = raw.firstIndex(of: ":") else { return nil }
        let kind = String(raw[..<delimiter])
        let value = String(raw[raw.index(after: delimiter)...])
        let qualifier = SemanticTagQualifier(kind: kind, value: value)
        return qualifier.kind.isEmpty || qualifier.value.isEmpty ? nil : qualifier
    }

    private static func assignmentValue(_ raw: String, key: String) -> String? {
        guard let delimiter = raw.firstIndex(of: "=") else { return nil }
        let suppliedKey = normalizedWords(String(raw[..<delimiter]))
        guard suppliedKey == key else { return nil }
        return String(raw[raw.index(after: delimiter)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isReusable(_ candidate: SemanticTagCandidate) -> Bool {
        let normalizedLabel = normalizedWords(candidate.preferredLabel)
        guard !emptySentinels.contains(normalizedLabel),
              !isClassificationOnly(candidate) else {
            return false
        }
        let surfaces = [candidate.preferredLabel] + candidate.sourceForms
        return !(candidate.roles.contains(.participant)
            && surfaces.contains(where: looksLikePersonName))
    }

    private static func isClassificationOnly(_ candidate: SemanticTagCandidate) -> Bool {
        ([candidate.preferredLabel] + candidate.sourceForms).contains { surface in
            let normalized = normalizedWords(surface)
            if classificationOnlyLabels.contains(normalized) { return true }
            let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
            return !tokens.isEmpty && tokens.allSatisfy { token in
                classificationOnlyLabels.contains(singularizedClassificationToken(token))
            }
        }
    }

    private static func singularizedClassificationToken(_ token: String) -> String {
        if token.hasSuffix("ies"), token.count > 3 {
            return String(token.dropLast(3)) + "y"
        }
        if token.hasSuffix("s"), token.count > 1 {
            return String(token.dropLast())
        }
        return token
    }

    private static func looksLikePersonName(_ raw: String) -> Bool {
        let tokens = raw.split(whereSeparator: \.isWhitespace)
        guard (2...4).contains(tokens.count) else { return false }
        return tokens.allSatisfy { token in
            let letters = token.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard let first = letters.first, !letters.isEmpty else { return false }
            return CharacterSet.uppercaseLetters.contains(first)
        }
    }

    private static func isBroad(
        _ candidate: SemanticTagCandidate,
        comparedWith other: SemanticTagCandidate
    ) -> Bool {
        guard !other.qualifiers.isEmpty else { return false }
        let candidateTokens = comparisonTokens(candidate.preferredLabel)
        let otherTokens = comparisonTokens(other.preferredLabel)
        return !candidateTokens.isEmpty
            && candidateTokens.count < otherTokens.count
            && candidateTokens.isSubset(of: otherTokens)
    }
}

private func normalizedWords(_ raw: String) -> String {
    normalizedComparisonText(raw)
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}

private func collapsedWhitespace(_ raw: String) -> String {
    raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func normalizedComparisonText(_ raw: String) -> String {
    let normalized = raw.precomposedStringWithCompatibilityMapping.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
    return String(normalized.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
    })
}

private func comparisonTokens(_ raw: String) -> Set<String> {
    Set(normalizedWords(raw).split(whereSeparator: \.isWhitespace).map(String.init))
}

private func orderInsensitiveIdentity(_ raw: String) -> String {
    comparisonTokens(raw).sorted().joined(separator: " ")
}
