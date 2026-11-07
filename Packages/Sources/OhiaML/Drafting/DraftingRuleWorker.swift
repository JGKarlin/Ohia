// DraftingRuleWorker.swift
// Drains the `.generateDraftingRules` job: finds sent Composer drafts that
// have not been distilled yet, runs `DraftingRuleDistiller` over each, and
// stamps `rulesGeneratedAt` so the pass is idempotent.

import Foundation
import SwiftData
import OhiaCore

public final class DraftingRuleWorker: @unchecked Sendable {

    public struct Outcome: Sendable {
        public let draftsProcessed: Int
        public let ruleMutations: Int
    }

    private let engine: any TrainingEngine
    private let maxDraftsPerTick: Int
    private let maxTokens: Int

    public init(
        engine: any TrainingEngine,
        maxDraftsPerTick: Int = 2,
        maxTokens: Int = 320
    ) {
        self.engine = engine
        self.maxDraftsPerTick = maxDraftsPerTick
        self.maxTokens = maxTokens
    }

    @MainActor
    public func run(context: ModelContext, now: Date = .now) async throws -> Outcome {
        let drafts = try context.fetch(FetchDescriptor<Draft>())
        let eligible = drafts.filter { draft in
            draft.kind != .userCompose
                && draft.status == .sent
                && draft.rulesGeneratedAt == nil
                && draft.message != nil
                && !draft.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .sorted { $0.generatedAt < $1.generatedAt }

        var processed = 0
        var mutations = 0
        var stamped = 0
        let knownCustomCategoryKeys = CustomMailCategoryCatalog.allKeys(in: context)
        let targetDraftIDs = Set(eligible.prefix(maxDraftsPerTick).map(\.id))
        let signalsByDraftID = approvedSignalsByDraftID(for: targetDraftIDs, context: context)

        for draft in eligible.prefix(maxDraftsPerTick) {
            guard let message = draft.message,
                  let accountID = message.accountID ?? message.account?.id else {
                // No account to index rules under — stamp so the job doesn't
                // reclaim it forever (and count it so the stamp is saved).
                draft.rulesGeneratedAt = now
                stamped += 1
                continue
            }

            let targets = DraftingRuleDistiller.dimensionTargets(
                for: message,
                knownCustomCategoryKeys: knownCustomCategoryKeys
            )
            let activeRules = activeRules(for: draft, targets: targets, accountID: accountID, context: context)
            let interviewInput = ComposerInterviewDraftInputCompiler.compile(draft: draft)
            let modelDraft = firstModelVersion(of: draft)
            let guidanceTrail = guidanceTrail(of: draft)

            let prompt = DraftingRuleDistiller.buildPrompt(
                activeRules: activeRules,
                decisionLines: interviewInput.draftingRuleDecisionLines,
                guidanceTrail: guidanceTrail,
                signals: signalsByDraftID[draft.id] ?? [],
                modelDraft: modelDraft,
                finalText: draft.replyText
            )

            let raw: String
            do {
                let engineRef = engine
                let tokenCap = maxTokens
                raw = try await Task.detached(priority: .utility) { [engineRef, prompt, tokenCap] in
                    try PrefixCachedGeneration.generate(
                        engine: engineRef,
                        prompt: prompt,
                        maxTokens: tokenCap
                    )
                }.value
            } catch {
                // Generation failed (model unloading, pressure) — leave the
                // draft unstamped so the next tick retries.
                print("[Ohia] ⚠ Rule distillation generation failed for draft \(draft.id): \(String(reflecting: type(of: error)))")
                continue
            }

            let operations = DraftingRuleDistiller.parseOperations(raw)
            mutations += DraftingRuleDistiller.apply(
                operations: operations,
                activeRules: activeRules,
                accountID: accountID,
                targets: targets,
                sourceDraftID: draft.id,
                context: context,
                now: now
            )
            // Stamp even when the model returned nothing parseable —
            // re-burning generation on the same evidence won't improve it.
            draft.rulesGeneratedAt = now
            stamped += 1
            processed += 1
        }

        if stamped > 0 {
            try context.save()
        }
        return Outcome(draftsProcessed: processed, ruleMutations: mutations)
    }

    /// True when undistilled sent drafts remain (reseed signal for
    /// `BackgroundScheduler.ensurePipelineJobsExist`).
    @MainActor
    public static func hasPendingWork(context: ModelContext) -> Bool {
        let drafts = (try? context.fetch(FetchDescriptor<Draft>())) ?? []
        return drafts.contains { draft in
            draft.kind != .userCompose
                && (draft.status == .confirmed || draft.status == .sent)
                && draft.rulesGeneratedAt == nil
                && draft.message != nil
                && !draft.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The categorized edit signals `HeuristicEditAnalyzer` detected at send
    /// time (`OutboxItem.approvedTrainingSignalsJSON`), keyed by draft id —
    /// the same evidence `SentTrainingFeedbackRecorder` uses to scale LoRA
    /// sample weight, reused here so the distiller can recognize a recurring
    /// edit category instead of re-deriving it from the raw diff every time.
    /// Drafts with no outbox item or no captured signals simply get `[]`.
    ///
    /// `OutboxItem` rows are never pruned, so this fetches the whole table
    /// (unavoidable — there is no relationship-traversal predicate for
    /// `item.draft?.id`), but only JSON-decodes the handful of items in
    /// `draftIDs` (this tick's `eligible.prefix(maxDraftsPerTick)`) rather
    /// than every historical send.
    @MainActor
    private func approvedSignalsByDraftID(
        for draftIDs: Set<UUID>,
        context: ModelContext
    ) -> [UUID: [TrainingSignal]] {
        guard !draftIDs.isEmpty else { return [:] }
        let items = (try? context.fetch(FetchDescriptor<OutboxItem>())) ?? []
        return items.reduce(into: [:]) { result, item in
            guard let draftID = item.draft?.id, draftIDs.contains(draftID) else { return }
            result[draftID] = TrainingSignal.decodeJSON(item.approvedTrainingSignalsJSON)
        }
    }

    // MARK: - Evidence assembly

    /// The rules to show the distiller, in stable order: the rules that were
    /// actually injected into this draft's generation (by stamped id), then
    /// any other current rules matching the message's dimension targets so
    /// contradicted-but-unapplied rules can still be weakened. Capped to
    /// keep the prompt small.
    @MainActor
    private func activeRules(
        for draft: Draft,
        targets: [DraftingRuleDistiller.DimensionTarget],
        accountID: UUID,
        context: ModelContext
    ) -> [DraftingRule] {
        let all: [DraftingRule] = (try? context.fetch(FetchDescriptor<DraftingRule>(
            predicate: #Predicate<DraftingRule> { rule in
                rule.accountID == accountID
            }
        ))) ?? []
        guard !all.isEmpty else { return [] }

        var ordered: [DraftingRule] = []
        var seen = Set<UUID>()

        if let json = draft.appliedRuleIDsJSON,
           let data = json.data(using: .utf8),
           let idStrings = try? JSONDecoder().decode([String].self, from: data) {
            for idString in idStrings {
                guard let id = UUID(uuidString: idString),
                      let rule = all.first(where: { $0.id == id }),
                      seen.insert(id).inserted else { continue }
                ordered.append(rule)
            }
        }

        let targetPairs = Set(targets.map { "\($0.kindRaw)|\($0.value)" })
        let matching = all
            .filter { targetPairs.contains("\($0.dimensionKindRaw)|\($0.dimensionValue)") }
            .sorted { $0.weight > $1.weight }
        for rule in matching where seen.insert(rule.id).inserted {
            ordered.append(rule)
        }

        return Array(ordered.prefix(10))
    }

    /// The user's typed guidance in the order it was given: the first-draft
    /// guidance persisted on the `.initial` revision, then every revision
    /// request (instruction and instruction-bearing restyle revisions).
    /// Pure register switches persist no instruction and are skipped.
    @MainActor
    private func guidanceTrail(of draft: Draft) -> [String] {
        draft.orderedRevisions.compactMap { revision in
            guard let text = revision.instruction?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty else { return nil }
            return text
        }
    }

    /// The first model-generated version of the draft (revision index 1).
    /// Falls back to the oldest revision, then to the final text itself
    /// (legacy drafts without history — the distiller then sees
    /// "sent unchanged").
    @MainActor
    private func firstModelVersion(of draft: Draft) -> String {
        let revisions = draft.orderedRevisions
        if let initial = revisions.first(where: { $0.triggerRaw == DraftRevisionTrigger.initial }) {
            return initial.bodyText
        }
        if let oldest = revisions.first {
            return oldest.bodyText
        }
        return draft.replyText
    }
}
