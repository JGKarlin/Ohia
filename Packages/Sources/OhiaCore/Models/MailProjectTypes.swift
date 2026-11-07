import Foundation

public enum MailProjectHealth: String, Codable, Sendable, CaseIterable {
    case healthy, needsAttention, membershipUpdatePending
}

public enum MailProjectRuleGroupKind: String, Codable, Sendable {
    case invalid
    case sharedCriteria
    case match
    case projectWideExclusion
}

public enum MailProjectRuleFacet: String, Codable, Sendable, CaseIterable {
    case invalid
    case account, correspondent, mailingList, fixedCategory, customCategory
    case semanticTag, language
    case subject, body, attachmentFilename, attachmentText

    public static let allCases: [Self] = [
        .account, .correspondent, .mailingList, .fixedCategory, .customCategory,
        .semanticTag, .language,
        .subject, .body, .attachmentFilename, .attachmentText,
    ]
}

public enum MailProjectMailingListValue {
    public static func stableKey(accountID: UUID, listID: String) -> String {
        let normalizedListID = listID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(accountID.uuidString)|\(normalizedListID)"
    }
}

public enum MailProjectConditionPolarity: String, Codable, Sendable {
    case include, exclude
}

public enum MailProjectValueQuantifier: String, Codable, Sendable {
    case any, all
}

public enum MailProjectCorrespondentRole: String, Codable, Sendable, CaseIterable {
    case from, to, cc, bcc, involves
}

public enum MailProjectKeywordOperator: String, Codable, Sendable, CaseIterable {
    case containsPhrase, anyWord, allWords
}

public enum MailProjectKeywordScope: String, Codable, Sendable, CaseIterable {
    case subject, body, attachmentFilename, attachmentText
}

public enum MailProjectDecisionTargetKind: String, Codable, Sendable {
    case message, thread
}

public enum MailProjectDecisionValue: String, Codable, Sendable {
    case include, exclude
}

public enum MailProjectMembershipSource: String, Codable, Sendable {
    case messageOverride, threadOverride, rule
}

public enum MailProjectNameError: Error, Equatable, Sendable {
    case emptyName
}

public enum MailProjectJSONError: Error, Equatable, Sendable {
    case malformedArray
    case invalidUUID(String)
    case invalidKeywordScope(String)
}

/// Canonical array encoding for fields that contribute to manual-project
/// configuration fingerprints. All helpers deduplicate and sort their values.
public enum MailProjectJSON {
    public static func encodeUUIDs(_ values: [UUID]) throws -> String {
        try encodeStrings(values.map(\.uuidString))
    }

    public static func decodeUUIDs(_ value: String) throws -> [UUID] {
        try decodeStrings(value).map { string in
            guard let id = UUID(uuidString: string) else {
                throw MailProjectJSONError.invalidUUID(string)
            }
            return id
        }
    }

    public static func encodeStrings(_ values: [String]) throws -> String {
        let data = try JSONEncoder().encode(Array(Set(values)).sorted())
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeStrings(_ value: String) throws -> [String] {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            throw MailProjectJSONError.malformedArray
        }
        return Array(Set(decoded)).sorted()
    }

    public static func encodeKeywordScopes(_ values: [MailProjectKeywordScope]) throws -> String {
        try encodeStrings(values.map(\.rawValue))
    }

    public static func decodeKeywordScopes(_ value: String?) throws -> [MailProjectKeywordScope] {
        guard let value else { return [] }
        return try decodeStrings(value).map { string in
            guard let scope = MailProjectKeywordScope(rawValue: string) else {
                throw MailProjectJSONError.invalidKeywordScope(string)
            }
            return scope
        }
    }

    public static func encodeConditionValues(_ values: [String]) throws -> String {
        try encodeStrings(values)
    }

    public static func decodeConditionValues(_ value: String) throws -> [String] {
        try decodeStrings(value)
    }
}
