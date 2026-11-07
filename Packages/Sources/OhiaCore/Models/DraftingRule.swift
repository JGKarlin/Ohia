import Foundation
import SwiftData

/// Lifecycle constants for `DraftingRule` weights. Rules are born at
/// `initialWeight`, move by `reinforceDelta` / `weakenDelta` as each Composer
/// iteration confirms or contradicts them, and are hard-deleted once they
/// fall to `deletionFloor`. Tuned so roughly three uncontested weakenings
/// retire a rule and sustained reinforcement saturates at `ceiling`.
public enum DraftingRuleLifecycle {
    public static let initialWeight = 0.5
    public static let reinforceDelta = 0.15
    public static let weakenDelta = -0.2
    public static let deletionFloor = 0.1
    public static let ceiling = 1.0
    /// Cap per (dimensionKind, dimensionValue) pair — the distillation pass
    /// must delete or merge before adding beyond this.
    public static let maxRulesPerDimensionValue = 8

    public static func clamped(_ weight: Double) -> Double {
        min(ceiling, max(0, weight))
    }
}

/// A context-specific rule for how the user writes email, distilled by the
/// generation model from Composer outcomes: the model's draft vs the user's
/// final sent text, and the user's answers to the clarifying questions.
///
/// Rules are indexed by the same four dossier dimensions as `AccountMemory`
/// (`AccountMemoryDimension`: account / correspondent / classification / project)
/// and are never generalized across dimensions — a rule learned from mail
/// with one correspondent applies only there. Rules are internal pipeline
/// state: they are injected into draft prompts by weight and updated by the
/// distillation pass, but never surfaced in any UI.
@Model
public final class DraftingRule {
    public var id: UUID

    /// Owning account — rules never cross accounts.
    public var accountID: UUID

    /// Dossier dimension (`AccountMemoryDimension` raw string).
    public var dimensionKindRaw: String

    /// Dimension-specific key: normalized correspondent address, mail
    /// classification-facet value, or canonical project key. Empty for `account`.
    public var dimensionValue: String

    /// The rule itself — one imperative sentence the draft prompt can apply
    /// ("Open replies to her in Japanese", "Never commit to a date without
    /// a buffer").
    public var ruleText: String

    /// Lowercased, whitespace-collapsed `ruleText` used as the dedupe key
    /// within a dimension value.
    public var normalizedText: String

    /// Injection weight in [0, 1]. Top-weighted rules win selection; the
    /// distillation pass reinforces, weakens, and deletes through
    /// `DraftingRuleLifecycle`.
    public var weight: Double

    public var timesReinforced: Int
    public var timesWeakened: Int

    /// The draft whose send most recently created or adjusted this rule.
    public var sourceDraftID: UUID?

    /// Stamped when the rule was last injected into a generation prompt.
    public var lastAppliedAt: Date?

    public var extractionVersion: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        dimensionKindRaw: String,
        dimensionValue: String,
        ruleText: String,
        weight: Double = DraftingRuleLifecycle.initialWeight,
        timesReinforced: Int = 0,
        timesWeakened: Int = 0,
        sourceDraftID: UUID? = nil,
        lastAppliedAt: Date? = nil,
        extractionVersion: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.accountID = accountID
        self.dimensionKindRaw = dimensionKindRaw
        self.dimensionValue = dimensionValue
        self.ruleText = ruleText
        self.normalizedText = DraftingRule.normalize(ruleText)
        self.weight = weight
        self.timesReinforced = timesReinforced
        self.timesWeakened = timesWeakened
        self.sourceDraftID = sourceDraftID
        self.lastAppliedAt = lastAppliedAt
        self.extractionVersion = extractionVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Canonical dedupe form: lowercased with runs of whitespace collapsed
    /// to single spaces. Language-agnostic — no English-specific stripping.
    public static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
