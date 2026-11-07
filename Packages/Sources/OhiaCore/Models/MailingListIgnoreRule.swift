import Foundation
import SwiftData

public enum MailingListIgnoreRuleStatus {
    public static let active = "active"
    public static let disabled = "disabled"
}

/// A user-created rule that suppresses a recurring series from a single
/// mailing list. The rule never applies across accounts or lists.
@Model
public final class MailingListIgnoreRule {
    #Index<MailingListIgnoreRule>(
        [\.id],
        [\.accountID, \.listId, \.statusRaw]
    )

    public var id: UUID
    public var accountID: UUID
    public var listId: String
    public var displayLabel: String
    public var semanticTagIDsJSON: String
    public var semanticTagLabelsJSON: String
    public var subjectFingerprint: String
    public var subjectAnchorsJSON: String
    public var bodyAnchorsJSON: String
    /// Versioned, source-only feature examples that the user explicitly
    /// accepted as belonging to this recurring series. Optional so stores from
    /// before explainable matching migrate without a repair pass.
    public var positiveExamplesJSON: String?
    /// Source-only examples the user rejected in the historical preview or
    /// restored with rule refinement. These keep a broad list template from
    /// swallowing a nearby but distinct series.
    public var negativeExamplesJSON: String?
    /// Matcher revision that produced the persisted examples and audit scores.
    public var matcherVersion: String?
    public var evidenceMessageID: UUID?
    public var evidenceSubject: String
    public var evidenceSummary: String?
    /// 0 = narrow, 1 = broad. Settings exposes those terms directly so changing
    /// this value never sounds like a claim about correctness or confidence.
    public var matchAggressiveness: Double
    /// Raw string from `MailingListIgnoreRuleStatus`.
    public var statusRaw: String
    public var matchCount: Int
    public var hiddenOnlyCount: Int
    public var lastMatchedAt: Date?
    public var lastActionError: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        listId: String,
        displayLabel: String,
        semanticTagIDs: [String] = [],
        semanticTagLabels: [String] = [],
        subjectFingerprint: String,
        subjectAnchors: [String] = [],
        bodyAnchors: [String] = [],
        positiveExamplesJSON: String? = nil,
        negativeExamplesJSON: String? = nil,
        matcherVersion: String? = nil,
        evidenceMessageID: UUID? = nil,
        evidenceSubject: String,
        evidenceSummary: String? = nil,
        matchAggressiveness: Double = 0.5,
        statusRaw: String = MailingListIgnoreRuleStatus.active,
        matchCount: Int = 0,
        hiddenOnlyCount: Int = 0,
        lastMatchedAt: Date? = nil,
        lastActionError: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.accountID = accountID
        self.listId = listId
        self.displayLabel = displayLabel
        self.semanticTagIDsJSON = Self.encode(semanticTagIDs)
        self.semanticTagLabelsJSON = Self.encode(semanticTagLabels)
        self.subjectFingerprint = subjectFingerprint
        self.subjectAnchorsJSON = Self.encode(subjectAnchors)
        self.bodyAnchorsJSON = Self.encode(bodyAnchors)
        self.positiveExamplesJSON = positiveExamplesJSON
        self.negativeExamplesJSON = negativeExamplesJSON
        self.matcherVersion = matcherVersion
        self.evidenceMessageID = evidenceMessageID
        self.evidenceSubject = evidenceSubject
        self.evidenceSummary = evidenceSummary
        self.matchAggressiveness = Self.clampedAggressiveness(matchAggressiveness)
        self.statusRaw = statusRaw
        self.matchCount = matchCount
        self.hiddenOnlyCount = hiddenOnlyCount
        self.lastMatchedAt = lastMatchedAt
        self.lastActionError = lastActionError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public extension MailingListIgnoreRule {
    var semanticTagIDs: [String] {
        Self.decode(semanticTagIDsJSON)
    }

    var semanticTagLabels: [String] {
        Self.decode(semanticTagLabelsJSON)
    }

    var subjectAnchors: [String] {
        Self.decode(subjectAnchorsJSON)
    }

    var bodyAnchors: [String] {
        Self.decode(bodyAnchorsJSON)
    }

    var isActive: Bool {
        statusRaw == MailingListIgnoreRuleStatus.active
    }

    func replaceSemanticTags(ids: [String], labels: [String]) {
        semanticTagIDsJSON = Self.encode(ids)
        semanticTagLabelsJSON = Self.encode(labels)
        updatedAt = .now
    }

    func replaceAnchors(subject: [String], body: [String]) {
        subjectAnchorsJSON = Self.encode(subject)
        bodyAnchorsJSON = Self.encode(body)
        updatedAt = .now
    }

    func strengthen() {
        matchAggressiveness = Self.clampedAggressiveness(matchAggressiveness + 0.15)
        statusRaw = MailingListIgnoreRuleStatus.active
        updatedAt = .now
    }

    func weaken() {
        matchAggressiveness = Self.clampedAggressiveness(matchAggressiveness - 0.15)
        updatedAt = .now
    }

    func disable() {
        statusRaw = MailingListIgnoreRuleStatus.disabled
        updatedAt = .now
    }

    static func clampedAggressiveness(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    private static func encode(_ values: [String]) -> String {
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let data = try? JSONEncoder().encode(cleaned),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private static func decode(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }
}
