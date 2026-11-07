// DraftingRuleDistiller.swift
// Post-send learning pass for the Composer. For each sent reply draft it
// shows the model: the first model-generated version, the user's final sent
// text, the user's clarifying-question answers (including what they skipped),
// the revision requests they typed while iterating, and the rules that were
// active during generation — and asks for add / reinforce / weaken / delete
// operations over the dimension-indexed `DraftingRule` store.
//
// Rules are internal pipeline state. They are never rendered in any UI;
// their entire lifecycle is this distiller (write) and
// `DraftingRuleSelector` (read). Durable account memories are produced only
// by the evidence-backed conversation-memory pipeline.

import Foundation
import SwiftData
import OhiaCore

public enum DraftingRuleDistiller {

    public static let extractionVersion = "rule-distill-v3"

    /// One model-proposed operation against the rule store.
    public struct Operation: Decodable, Equatable, Sendable {
        public let op: String        // "add" | "reinforce" | "weaken" | "delete"
        public let rule: Int?        // 1-based index into the listed existing rules
        public let text: String?     // for "add"
        public let dimension: String? // for "add": account|correspondent|classification|project

        public init(op: String, rule: Int? = nil, text: String? = nil, dimension: String? = nil) {
            self.op = op
            self.rule = rule
            self.text = text
            self.dimension = dimension
        }
    }

    /// The dimension targets a draft's message resolves to. `value` is the
    /// normalized dimension key. `displayName` is retained for callers that
    /// present the resolved target outside the rule store.
    public struct DimensionTarget: Equatable, Sendable {
        public let kindRaw: String
        public let value: String
        public let displayName: String

        public init(kindRaw: String, value: String, displayName: String = "") {
            self.kindRaw = kindRaw
            self.value = value
            self.displayName = displayName
        }
    }

    // MARK: - Dimension resolution

    /// The dimension targets for a message: its account, its sender, its
    /// canonical classification memory facets, and its semantic projects.
    @MainActor
    public static func dimensionTargets(for message: Message) -> [DimensionTarget] {
        dimensionTargets(
            for: message,
            knownCustomCategoryKeys: message.modelContext.map {
                CustomMailCategoryCatalog.allKeys(in: $0)
            } ?? []
        )
    }

    /// Explicit catalog-snapshot overload for batch workers. The snapshot is
    /// resolved once per batch so removed keys fail closed without a catalog
    /// fetch for every message.
    @MainActor
    public static func dimensionTargets(
        for message: Message,
        knownCustomCategoryKeys: Set<String>
    ) -> [DimensionTarget] {
        var targets: [DimensionTarget] = [
            DimensionTarget(kindRaw: AccountMemoryDimension.account, value: "")
        ]
        let sender = message.fromAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !sender.isEmpty {
            targets.append(DimensionTarget(
                kindRaw: AccountMemoryDimension.correspondent,
                value: sender,
                displayName: message.fromName ?? sender
            ))
        }
        for key in draftingMemoryFacets(
            for: message,
            knownCustomCategoryKeys: knownCustomCategoryKeys
        ).memoryKeys {
            targets.append(DimensionTarget(
                kindRaw: AccountMemoryDimension.classification,
                value: key,
                displayName: DraftingMemoryFacets.displayName(for: key)
            ))
        }
        if let json = message.analysis?.dimensionsJSON,
           let data = json.data(using: .utf8),
           let dimensions = try? JSONDecoder().decode(MessageDimensions.self, from: data) {
            for tag in SemanticTagProjectionPresentation.canonical(dimensions.semanticTags) {
                targets.append(DimensionTarget(
                    kindRaw: AccountMemoryDimension.project,
                    value: tag.tagID.uuidString.lowercased(),
                    displayName: tag.displayName
                ))
            }
        }
        return targets
    }

    // MARK: - Prompt

    /// Static instruction stem, identical across calls for KV prefix caching.
    static let promptPrefix = """
    You maintain private rules describing how one specific user writes email \
    replies in one specific context. You will see \
    the rules that were active, the decisions the user made before drafting, \
    the revision requests the user typed while iterating on the draft, the \
    draft a model wrote, and the final text the user actually sent. Compare \
    them and update the store. Return JSON only — no prose, no code fences.

    Operations (return an array, possibly empty):
    [{"op": "reinforce", "rule": 1},
     {"op": "weaken", "rule": 2},
     {"op": "delete", "rule": 3},
     {"op": "add", "dimension": "correspondent", "text": "…"}]

    - "reinforce": the final text confirms the rule was right.
    - "weaken": the final text contradicts the rule or the user edited away \
    what the rule produced.
    - "delete": the rule is clearly wrong or obsolete.
    - "add": a NEW durable habit visible in how the user changed the draft, \
    in the decisions they made, or in the revision requests they typed. \
    "dimension" is where the habit belongs: "correspondent" (specific to \
    this sender), "project" (specific to this project), "classification" (specific \
    to this kind of mail), or "account" (how the user writes everywhere from \
    this address). Prefer the narrowest dimension the evidence supports. \
    "text" is one imperative sentence in the language of the user's email. \
    When [EDIT SIGNALS] is present, its categories (contentAdded, \
    contentRemoved, rewrite, toneShift, sourceOverride) are the same kind of \
    edit each time they recur — if a signal's category matches what an \
    existing active rule already describes, "reinforce" that rule instead of \
    "add"-ing a rephrased duplicate, so a repeated habit converges onto one \
    rule rather than scattering across near-identical text.
    Rules must capture durable writing behavior (length, structure, \
    commitments, openings, language choice, what to include or withhold) — \
    never facts, events, tasks, or summaries about a single email. The \
    revision requests are the \
    strongest evidence: the user asked for those changes in their own words. \
    Add at most 2 rules. When the user sent the model's \
    draft unchanged, reinforce the rules that shaped it and add nothing.


    """

    public static func buildPrompt(
        activeRules: [DraftingRule],
        decisionLines: [String],
        guidanceTrail: [String] = [],
        signals: [TrainingSignal] = [],
        modelDraft: String,
        finalText: String
    ) -> PrefixCachedPrompt {
        var lines: [String] = []

        if activeRules.isEmpty {
            lines.append("[ACTIVE RULES]\n(none yet)")
        } else {
            var ruleLines = ["[ACTIVE RULES]"]
            for (idx, rule) in activeRules.enumerated() {
                ruleLines.append("\(idx + 1). (\(rule.dimensionKindRaw)) \(rule.ruleText)")
            }
            lines.append(ruleLines.joined(separator: "\n"))
        }

        if !decisionLines.isEmpty {
            lines.append("[USER DECISIONS]\n" + decisionLines.map { "- \($0)" }.joined(separator: "\n"))
        }

        // The user's own words about what to change, in the order they were
        // typed: first-draft guidance, then each revision request. Capped to
        // the most recent requests so a long iteration session can't balloon
        // the prompt.
        let requests = guidanceTrail
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(6)
            .map { String($0.prefix(300)) }
        if !requests.isEmpty {
            var requestLines = ["[REVISION REQUESTS]"]
            for (idx, request) in requests.enumerated() {
                requestLines.append("\(idx + 1). \(request)")
            }
            lines.append(requestLines.joined(separator: "\n"))
        }

        // Categorized edit signals HeuristicEditAnalyzer already detected
        // between modelDraft and finalText — a cheap, consistent hint so the
        // model matches "the same kind of edit as last time" against
        // [ACTIVE RULES] instead of re-deriving that recognition from the
        // raw diff on every call.
        if !signals.isEmpty {
            let signalLines = signals.map { "- \($0.type.rawValue): \($0.description.prefix(120))" }
            lines.append("[EDIT SIGNALS]\n" + signalLines.joined(separator: "\n"))
        }

        lines.append("[MODEL DRAFT]\n\(modelDraft.prefix(2000))")
        lines.append("[FINAL SENT TEXT]\n\(finalText.prefix(2000))")
        lines.append("JSON:")

        return PrefixCachedPrompt(
            cacheKey: "drafting-rules-v3",
            prefix: promptPrefix,
            suffix: lines.joined(separator: "\n\n")
        )
    }

    // MARK: - Parsing

    /// Extracts the first JSON array from the model output. Tolerates
    /// leading/trailing prose and code fences; returns [] when unparseable.
    public static func parseOperations(_ raw: String) -> [Operation] {
        let stripped = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let start = stripped.firstIndex(of: "["),
              let end = stripped.lastIndex(of: "]"),
              start < end,
              let data = String(stripped[start...end]).data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([Operation].self, from: data)) ?? []
    }

    // MARK: - Application

    /// Applies parsed operations against the store. `activeRules` must be
    /// the exact ordered list that was shown in the prompt (1-based indices
    /// resolve into it). Returns the number of mutations applied.
    ///
    /// Adds are deduped by normalized text within their dimension target;
    /// a duplicate add reinforces the existing rule instead. Adds beyond
    /// the per-dimension cap replace the weakest existing rule only when
    /// the cap is full AND the weakest rule is below the initial weight —
    /// otherwise the add is dropped (the established rules have earned
    /// their place).
    @MainActor
    @discardableResult
    public static func apply(
        operations: [Operation],
        activeRules: [DraftingRule],
        accountID: UUID,
        targets: [DimensionTarget],
        sourceDraftID: UUID,
        context: ModelContext,
        now: Date = .now
    ) -> Int {
        var mutations = 0

        // Live view of the account's rules across this batch: adds append,
        // deletes remove, so a second `add` with the same text dedupes
        // against the first and the per-dimension cap counts what actually
        // remains after mid-batch deletions.
        var accountRules: [DraftingRule] = (try? context.fetch(FetchDescriptor<DraftingRule>(
            predicate: #Predicate<DraftingRule> { rule in
                rule.accountID == accountID
            }
        ))) ?? []

        @MainActor func remove(_ rule: DraftingRule) {
            let ruleID = rule.id
            accountRules.removeAll { $0.id == ruleID }
            context.delete(rule)
        }

        func target(for dimensionRaw: String?) -> DimensionTarget? {
            guard let dimensionRaw else { return nil }
            // Narrowest matching target for the requested dimension kind.
            return targets.first(where: { $0.kindRaw == dimensionRaw })
        }

        for operation in operations {
            switch operation.op {
            case "reinforce":
                guard let rule = resolve(operation.rule, in: activeRules) else { continue }
                // Reprocessing one sent draft is not independent evidence.
                if rule.dimensionKindRaw == AccountMemoryDimension.account {
                    guard rule.sourceDraftID != sourceDraftID else { continue }
                }
                rule.weight = DraftingRuleLifecycle.clamped(
                    rule.weight + DraftingRuleLifecycle.reinforceDelta
                )
                rule.timesReinforced += 1
                rule.updatedAt = now
                rule.sourceDraftID = sourceDraftID
                mutations += 1

            case "weaken":
                guard let rule = resolve(operation.rule, in: activeRules) else { continue }
                rule.weight = DraftingRuleLifecycle.clamped(
                    rule.weight + DraftingRuleLifecycle.weakenDelta
                )
                rule.timesWeakened += 1
                rule.updatedAt = now
                rule.sourceDraftID = sourceDraftID
                if rule.weight <= DraftingRuleLifecycle.deletionFloor {
                    remove(rule)
                }
                mutations += 1

            case "delete":
                guard let rule = resolve(operation.rule, in: activeRules) else { continue }
                remove(rule)
                mutations += 1

            case "add":
                guard let text = operation.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty,
                      let target = target(for: operation.dimension) else { continue }
                let normalized = DraftingRule.normalize(text)
                let siblings = accountRules.filter {
                    $0.dimensionKindRaw == target.kindRaw && $0.dimensionValue == target.value
                }
                if let existing = siblings.first(where: { $0.normalizedText == normalized }) {
                    // Duplicate operations from one distillation pass collapse
                    // without promoting a one-off observation into a habit.
                    if existing.dimensionKindRaw == AccountMemoryDimension.account {
                        guard existing.sourceDraftID != sourceDraftID else { continue }
                    }
                    existing.weight = DraftingRuleLifecycle.clamped(
                        existing.weight + DraftingRuleLifecycle.reinforceDelta
                    )
                    existing.timesReinforced += 1
                    existing.updatedAt = now
                    existing.sourceDraftID = sourceDraftID
                    mutations += 1
                    continue
                }
                if siblings.count >= DraftingRuleLifecycle.maxRulesPerDimensionValue {
                    let weakest = siblings.min(by: { $0.weight < $1.weight })
                    guard let weakest, weakest.weight < DraftingRuleLifecycle.initialWeight else {
                        continue
                    }
                    remove(weakest)
                }
                let rule = DraftingRule(
                    accountID: accountID,
                    dimensionKindRaw: target.kindRaw,
                    dimensionValue: target.value,
                    ruleText: text,
                    sourceDraftID: sourceDraftID,
                    extractionVersion: extractionVersion,
                    createdAt: now,
                    updatedAt: now
                )
                context.insert(rule)
                accountRules.append(rule)
                mutations += 1

            default:
                continue
            }
        }
        return mutations
    }

    private static func resolve(_ index: Int?, in rules: [DraftingRule]) -> DraftingRule? {
        guard let index, index >= 1, index <= rules.count else { return nil }
        let rule = rules[index - 1]
        guard rule.isDeleted == false else { return nil }
        return rule
    }

}
