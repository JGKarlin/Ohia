import Foundation

public enum MailClassificationStatus: String, Codable, Sendable, CaseIterable {
    case classified
    case uncertain
    case deterministicFallback
}

/// The shared, account-independent category vocabulary assigned during ingestion.
public enum MailPurpose: String, Codable, Sendable, CaseIterable {
    case correspondence
    case announcement
    case receipt
    case promotion
    case newsletter
    case verificationCode
    case notification
    case security
    case shipping
    case travel
    case finance
    case calendar
    case support
    case legal
    case socialActivity
    case other
}

public enum MailEvidencePolarity: String, Codable, Sendable, CaseIterable {
    case supporting
    case contradicting
}

public enum MailEvidenceSourceKind: String, Codable, Sendable, CaseIterable {
    case header
    case recipient
    case mime
    case thread
    case correspondent
    case bodyStructure
    case model
}

/// Storage grammar for stable classification rule identifiers.
public enum MailClassificationRuleID {
    public static func isValid(_ value: String) -> Bool {
        guard value.isEmpty == false else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (65...90).contains(value)
                || (97...122).contains(value)
                || (48...57).contains(value)
                || value == 46
                || value == 95
                || value == 45
        }
    }
}

public struct MailPurposeCandidate: Codable, Sendable, Equatable {
    public var purpose: MailPurpose
    public var confidence: Double
    public var ruleIDs: [String]

    public init(_ purpose: MailPurpose, confidence: Double, ruleIDs: [String]) {
        self.purpose = purpose
        self.confidence = confidence
        self.ruleIDs = ruleIDs
    }
}

/// Traceable evidence for a purpose assignment. Purpose is the only built-in
/// category produced by the ingestion classifier.
public struct MailClassificationEvidence: Codable, Sendable, Equatable {
    public var purpose: MailPurpose
    public var ruleID: String
    public var polarity: MailEvidencePolarity
    public var strength: Double
    public var sourceKind: MailEvidenceSourceKind

    public init(
        purpose: MailPurpose,
        ruleID: String,
        polarity: MailEvidencePolarity,
        strength: Double,
        sourceKind: MailEvidenceSourceKind
    ) {
        self.purpose = purpose
        self.ruleID = ruleID
        self.polarity = polarity
        self.strength = strength
        self.sourceKind = sourceKind
    }

    public var isDeterministic: Bool {
        switch sourceKind {
        case .header, .recipient, .mime, .bodyStructure:
            true
        case .thread, .correspondent, .model:
            false
        }
    }
}

public struct MailClassification: Codable, Sendable, Equatable {
    public static let defaultClassifierVersion = "mail-purpose-v2"
    public static let defaultResolverVersion = "mail-purpose-resolver-v2"

    public var status: MailClassificationStatus
    public var purpose: MailPurpose?
    public var purposeConfidence: Double?
    public var purposeCandidates: [MailPurposeCandidate]
    public var evidence: [MailClassificationEvidence]
    public var classifierVersion: String
    public var resolverVersion: String

    public init(
        status: MailClassificationStatus,
        purpose: MailPurpose?,
        purposeConfidence: Double?,
        purposeCandidates: [MailPurposeCandidate],
        evidence: [MailClassificationEvidence],
        classifierVersion: String,
        resolverVersion: String
    ) {
        self.status = status
        self.purpose = purpose
        self.purposeConfidence = purposeConfidence
        self.purposeCandidates = purposeCandidates
        self.evidence = evidence
        self.classifierVersion = classifierVersion
        self.resolverVersion = resolverVersion
    }

    public static func uncertain(
        evidence: [MailClassificationEvidence] = [],
        purposeCandidates: [MailPurposeCandidate] = [],
        classifierVersion: String = defaultClassifierVersion,
        resolverVersion: String = defaultResolverVersion
    ) -> MailClassification {
        MailClassification(
            status: .uncertain,
            purpose: nil,
            purposeConfidence: nil,
            purposeCandidates: purposeCandidates,
            evidence: evidence,
            classifierVersion: classifierVersion,
            resolverVersion: resolverVersion
        )
    }

    public static func userAssigned(purpose: MailPurpose) -> MailClassification {
        MailClassification(
            status: .classified,
            purpose: purpose,
            purposeConfidence: 1,
            purposeCandidates: [],
            evidence: [],
            classifierVersion: "user-assigned-v2",
            resolverVersion: "user-assigned-v2"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case purpose
        case purposeConfidence
        case purposeCandidates
        case evidence
        case classifierVersion
        case resolverVersion
    }

    /// Keep nullable purpose fields explicit so every persisted document has
    /// one exact, SQL-verifiable shape even when the classifier abstains.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        if let purpose {
            try container.encode(purpose, forKey: .purpose)
        } else {
            try container.encodeNil(forKey: .purpose)
        }
        if let purposeConfidence {
            try container.encode(purposeConfidence, forKey: .purposeConfidence)
        } else {
            try container.encodeNil(forKey: .purposeConfidence)
        }
        try container.encode(purposeCandidates, forKey: .purposeCandidates)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(classifierVersion, forKey: .classifierVersion)
        try container.encode(resolverVersion, forKey: .resolverVersion)
    }
}

public enum MailClassificationValidationError: Error, Equatable {
    case invalidConfidence
    case tooManyPurposeCandidates
    case tooManyEvidenceRecords
    case invalidStatusInvariant
    case invalidEvidence
    case missingVersion
}

public enum MailClassificationJSON {
    public static let maximumPurposeCandidates = 3
    public static let maximumEvidenceRecords = 12

    public static func encode(_ classification: MailClassification) throws -> String {
        let canonical = try canonicalized(classification)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(canonical)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                canonical,
                .init(codingPath: [], debugDescription: "Classification JSON was not UTF-8")
            )
        }
        return json
    }

    public static func decode(_ value: String?) -> MailClassification? {
        guard let value,
              value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let data = value.data(using: .utf8),
              containsDuplicateObjectKeys(in: data) == false,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set([
                  "status", "purpose", "purposeConfidence", "purposeCandidates",
                  "evidence", "classifierVersion", "resolverVersion",
              ]),
              let decoded = try? JSONDecoder().decode(MailClassification.self, from: data),
              let canonical = try? canonicalized(decoded) else {
            return nil
        }
        return canonical
    }

    public static func isComplete(_ value: String?) -> Bool {
        decode(value) != nil
    }

    private static func canonicalized(_ value: MailClassification) throws -> MailClassification {
        try validate(value)
        var value = value
        value.purposeCandidates = value.purposeCandidates
            .map { candidate in
                var candidate = candidate
                candidate.ruleIDs = canonicalRuleIDs(candidate.ruleIDs)
                return candidate
            }
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                return purposeOrder(lhs.purpose) < purposeOrder(rhs.purpose)
            }
        value.evidence.sort { lhs, rhs in
            if lhs.ruleID != rhs.ruleID { return lhs.ruleID < rhs.ruleID }
            if lhs.purpose != rhs.purpose { return purposeOrder(lhs.purpose) < purposeOrder(rhs.purpose) }
            return sourceOrder(lhs.sourceKind) < sourceOrder(rhs.sourceKind)
        }
        return value
    }

    private static func validate(_ value: MailClassification) throws {
        guard value.purposeCandidates.count <= maximumPurposeCandidates else {
            throw MailClassificationValidationError.tooManyPurposeCandidates
        }
        guard value.evidence.count <= maximumEvidenceRecords else {
            throw MailClassificationValidationError.tooManyEvidenceRecords
        }

        let confidenceValues = [value.purposeConfidence].compactMap { $0 }
            + value.purposeCandidates.map(\.confidence)
            + value.evidence.map(\.strength)
        guard confidenceValues.allSatisfy(isValidConfidence) else {
            throw MailClassificationValidationError.invalidConfidence
        }

        guard (value.purpose == nil) == (value.purposeConfidence == nil) else {
            throw MailClassificationValidationError.invalidStatusInvariant
        }
        switch value.status {
        case .classified:
            guard value.purpose != nil else {
                throw MailClassificationValidationError.invalidStatusInvariant
            }
        case .uncertain:
            guard value.purpose == nil else {
                throw MailClassificationValidationError.invalidStatusInvariant
            }
        case .deterministicFallback:
            guard let purpose = value.purpose,
                  let expectedRuleID = MailClassificationRuleInventory.necessaryPurposeRuleID[purpose],
                  value.evidence.contains(where: { evidence in
                      evidence.purpose == purpose
                          && evidence.ruleID == expectedRuleID
                          && evidence.polarity == .supporting
                          && evidence.isDeterministic
                  }) else {
                throw MailClassificationValidationError.invalidStatusInvariant
            }
        }

        guard MailClassificationRuleID.isValid(value.classifierVersion),
              MailClassificationRuleID.isValid(value.resolverVersion) else {
            throw MailClassificationValidationError.missingVersion
        }
        let ruleIDs = value.purposeCandidates.flatMap(\.ruleIDs) + value.evidence.map(\.ruleID)
        guard ruleIDs.allSatisfy(MailClassificationRuleID.isValid),
              value.evidence.allSatisfy({ evidence in
                  MailClassificationRuleID.isValid(evidence.ruleID)
                      && MailClassificationRuleInventory.necessaryPurposeRuleID[evidence.purpose] == evidence.ruleID
              }) else {
            throw MailClassificationValidationError.invalidEvidence
        }
    }

    private static func isValidConfidence(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private static func canonicalRuleIDs(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static func purposeOrder(_ value: MailPurpose) -> Int {
        MailPurpose.allCases.firstIndex(of: value) ?? .max
    }

    private static func sourceOrder(_ value: MailEvidenceSourceKind) -> Int {
        MailEvidenceSourceKind.allCases.firstIndex(of: value) ?? .max
    }

    /// Foundation's JSON decoders collapse duplicate object keys, while
    /// SQLite JSON1 exposes every occurrence. Reject duplicates before either
    /// decoder chooses a value so Swift and SQL agree on document completeness.
    private static func containsDuplicateObjectKeys(in data: Data) -> Bool {
        enum Container {
            case object(keys: Set<String>, expectsKey: Bool)
            case array
        }

        let bytes = Array(data)
        var containers: [Container] = []
        var index = 0

        while index < bytes.count {
            switch bytes[index] {
            case 0x7B: // {
                containers.append(.object(keys: [], expectsKey: true))
            case 0x5B: // [
                containers.append(.array)
            case 0x7D, 0x5D: // } or ]
                if containers.isEmpty == false {
                    containers.removeLast()
                }
            case 0x2C: // ,
                if case let .object(keys, _) = containers.last {
                    containers[containers.count - 1] = .object(keys: keys, expectsKey: true)
                }
            case 0x22: // "
                let start = index
                index += 1
                var escaped = false
                while index < bytes.count {
                    let byte = bytes[index]
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C { // \
                        escaped = true
                    } else if byte == 0x22 {
                        break
                    }
                    index += 1
                }

                guard index < bytes.count else { return true }
                if case let .object(keys, expectsKey) = containers.last, expectsKey {
                    let encodedKey = Data(bytes[start...index])
                    guard let key = try? JSONDecoder().decode(String.self, from: encodedKey) else {
                        return true
                    }
                    var updatedKeys = keys
                    guard updatedKeys.insert(key).inserted else { return true }
                    containers[containers.count - 1] = .object(
                        keys: updatedKeys,
                        expectsKey: false
                    )
                }
            default:
                break
            }
            index += 1
        }

        return false
    }
}

public enum CustomCategoryKeysJSON {
    public static let keyPrefix = "custom."

    public static func encode<S: Sequence>(_ keys: S) throws -> String where S.Element == String {
        let canonical = canonicalKeys(keys)
        let data = try JSONEncoder().encode(canonical)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                canonical,
                .init(codingPath: [], debugDescription: "Custom-category JSON was not UTF-8")
            )
        }
        return json
    }

    public static func decode(_ value: String?) -> [String] {
        guard let value,
              let data = value.data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return canonicalKeys(keys)
    }

    /// Filters, deduplicates, and sorts custom category keys without a JSON
    /// round trip. Consumers that already hold typed keys use this directly;
    /// persisted storage continues to enter through `decode`.
    public static func canonicalKeys<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        Array(Set(keys.filter(isCanonicalCustomKey))).sorted()
    }

    public static func isCanonicalKey(_ key: String) -> Bool {
        guard key.hasPrefix(keyPrefix), key.count > keyPrefix.count, key == key.lowercased() else {
            return false
        }
        return key.dropFirst(keyPrefix.count).unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
    }

    private static func isCanonicalCustomKey(_ key: String) -> Bool {
        isCanonicalKey(key)
    }
}
