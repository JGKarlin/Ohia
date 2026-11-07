import Foundation
import SwiftData
import OhiaCore

/// One drafting rule shaped for prompt injection.
public struct DraftingRuleNote: Codable, Sendable, Equatable {
    public let ruleID: UUID
    public let dimensionLabel: String
    public let text: String
    public let weight: Double

    public init(ruleID: UUID, dimensionLabel: String, text: String, weight: Double) {
        self.ruleID = ruleID
        self.dimensionLabel = dimensionLabel
        self.text = text
        self.weight = weight
    }
}

/// Selects the `DraftingRule` rows that apply to a reply and shapes them for
/// the `[DRAFTING RULES]` prompt section.
///
/// Matching is dimension-driven and mirrors `AccountMemoryDraftSelector`:
/// the correspondent's rules, then the message's project rules, then its
/// classification rules, then account-wide rules, deduped across dimensions with
/// count and character caps. Rules are internal state — this selector is the
/// only read path besides the distillation worker, and nothing here ever
/// reaches a UI surface.
public enum DraftingRuleSelector {
    public struct Limits: Sendable, Equatable {
        public var maxCorrespondentRules: Int
        public var maxProjectRules: Int
        public var maxClassificationRules: Int
        public var maxAccountRules: Int
        public var maxTotalRules: Int
        public var maxCharacters: Int

        public init(
            maxCorrespondentRules: Int = 3,
            maxProjectRules: Int = 2,
            maxClassificationRules: Int = 2,
            maxAccountRules: Int = 2,
            maxTotalRules: Int = 6,
            maxCharacters: Int = 900
        ) {
            self.maxCorrespondentRules = maxCorrespondentRules
            self.maxProjectRules = maxProjectRules
            self.maxClassificationRules = maxClassificationRules
            self.maxAccountRules = maxAccountRules
            self.maxTotalRules = maxTotalRules
            self.maxCharacters = maxCharacters
        }

        public static let `default` = Limits()
    }

    /// Returns the prompt-ready rules for this message, strongest first.
    /// The caller is responsible for stamping `lastAppliedAt` /
    /// `Draft.appliedRuleIDsJSON` after a successful generation — selection
    /// itself never mutates.
    @MainActor
    public static func rules(
        for message: Message,
        context: ModelContext,
        limits: Limits = .default
    ) -> [DraftingRuleNote] {
        guard let accountID = message.accountID ?? message.account?.id else { return [] }

        let allRules: [DraftingRule]
        do {
            allRules = try context.fetch(FetchDescriptor<DraftingRule>(
                predicate: #Predicate<DraftingRule> { rule in
                    rule.accountID == accountID
                }
            ))
        } catch {
            return []
        }
        guard allRules.isEmpty == false else { return [] }

        let senderAddress = message.fromAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let classificationValues = Set(draftingMemoryFacets(
            for: message,
            knownCustomCategoryKeys: CustomMailCategoryCatalog.allKeys(in: context)
        ).memoryKeys)
        let projectKeys = Set(projectKeys(of: message))

        let live = allRules.filter {
            $0.weight > DraftingRuleLifecycle.deletionFloor
                && !$0.ruleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // Correspondence is the catch-all purpose, not a content
                // situation that can authorize rules from another request.
                && !($0.dimensionKindRaw == AccountMemoryDimension.classification
                    && $0.dimensionValue == "purpose.correspondence")
                // Account-wide rules generalize across every correspondent.
                // One sent edit is only a hypothesis; require the same habit
                // to be observed in a second, independent sent draft before
                // it can steer generation outside its source context.
                && ($0.dimensionKindRaw != AccountMemoryDimension.account
                    || $0.timesReinforced > 0)
        }

        var selected: [DraftingRuleNote] = []
        var seenTexts = Set<String>()

        @MainActor func take(
            _ dimension: String,
            label: String,
            matching: @MainActor (DraftingRule) -> Bool,
            cap: Int
        ) {
            let candidates = live
                .filter { $0.dimensionKindRaw == dimension && matching($0) }
                .sorted { left, right in
                    if left.weight != right.weight { return left.weight > right.weight }
                    return left.updatedAt > right.updatedAt
                }
                .prefix(cap)
            for rule in candidates {
                guard seenTexts.insert(rule.normalizedText).inserted else { continue }
                selected.append(DraftingRuleNote(
                    ruleID: rule.id,
                    dimensionLabel: label,
                    text: rule.ruleText,
                    weight: rule.weight
                ))
            }
        }

        take(
            AccountMemoryDimension.correspondent,
            label: "this correspondent",
            matching: { $0.dimensionValue == senderAddress },
            cap: limits.maxCorrespondentRules
        )
        take(
            AccountMemoryDimension.project,
            label: "this project",
            matching: { projectKeys.contains($0.dimensionValue) },
            cap: limits.maxProjectRules
        )
        take(
            AccountMemoryDimension.classification,
            label: "this kind of mail",
            matching: { classificationValues.contains($0.dimensionValue) },
            cap: limits.maxClassificationRules
        )
        take(
            AccountMemoryDimension.account,
            label: "this account",
            matching: { _ in true },
            cap: limits.maxAccountRules
        )

        var notes: [DraftingRuleNote] = []
        var remaining = limits.maxCharacters
        for note in selected.prefix(limits.maxTotalRules) {
            let cost = note.text.count + note.dimensionLabel.count + 8
            guard cost <= remaining else { continue }
            notes.append(note)
            remaining -= cost
        }
        return notes
    }

    /// Stamps the selection onto the draft after a successful generation:
    /// `lastAppliedAt` on each rule and the applied id list on the draft.
    @MainActor
    public static func markApplied(
        _ notes: [DraftingRuleNote],
        draft: Draft,
        context: ModelContext,
        now: Date = .now
    ) {
        guard notes.isEmpty == false else {
            draft.appliedRuleIDsJSON = nil
            return
        }
        let ids = Set(notes.map(\.ruleID))
        if let rules = try? context.fetch(FetchDescriptor<DraftingRule>()) {
            for rule in rules where ids.contains(rule.id) {
                rule.lastAppliedAt = now
            }
        }
        let idStrings = notes.map { $0.ruleID.uuidString }
        if let data = try? JSONEncoder().encode(idStrings) {
            draft.appliedRuleIDsJSON = String(data: data, encoding: .utf8)
        }
    }

    @MainActor
    private static func projectKeys(of message: Message) -> [String] {
        guard let json = message.analysis?.dimensionsJSON,
              let data = json.data(using: .utf8),
              let dimensions = try? JSONDecoder().decode(MessageDimensions.self, from: data) else {
            return []
        }
        return SemanticTagProjectionPresentation.canonical(dimensions.semanticTags)
            .map { $0.tagID.uuidString.lowercased() }
    }
}
