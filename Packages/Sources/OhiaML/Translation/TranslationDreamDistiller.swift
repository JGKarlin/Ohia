// TranslationDreamDistiller.swift
// The distillation core of the dreaming producer for translation memories.
// Where the write-back producer mints cross-language terminology PINS (it has
// both the source email and the target-language corpus), dreaming sees only the
// user's monolingual correspondence in one target language — so it does what
// that substrate supports: distills durable translation STYLE rules (register,
// what to leave untranslated, script/formatting norms) and consolidates the
// existing dossier (reinforce / weaken / delete pins and rules the corpus
// corroborates or contradicts). It deliberately does NOT invent terminology
// pairs from a monolingual corpus — that is the write-back producer's job.
//
// Reuses `MemoryDistiller`'s Operation shape and JSON parser, and routes all
// inserts through `TranslationStyleRuleWriter` so curation suppression and
// dedup are honored by the sole remaining translation-memory producer.

import Foundation
import SwiftData
import OhiaCore

public enum TranslationDreamDistiller {
    /// Cap on style rules added in one dreaming pass, matching the prompt rule.
    public static let maxRulesPerCall = 3
    /// Hard ceiling for the uncached suffix passed to Qwen. Prompt prefill is
    /// not cooperatively interruptible, so background dreaming must keep this
    /// unit small even when the stored translation dossier has grown large.
    public static let maximumPromptSuffixCharacters = 4_000
    public static let maximumExistingMemoriesPerPrompt = 8
    public static let maximumSamplesPerPrompt = 8
    private static let maximumExistingMemoryCharacters = 160
    private static let maximumSampleCharacters = 240
    private static let maximumDisplayNameCharacters = 80

    public struct PromptBatch {
        public let prompt: PrefixCachedPrompt
        /// Exact rows whose 1-based indices appear in `prompt` and may be
        /// passed to `apply` without index drift.
        public let existing: [AccountMemory]
        /// Samples are retained as a stable prefix, allowing the caller to
        /// bind evidence references to exactly what the model saw.
        public let sampleCount: Int
    }

    static let promptPrefix = """
    You maintain one user's TRANSLATION PREFERENCES for a single target language. \
    You will see the preferences already stored (style rules and terminology \
    pins) and SAMPLES of the user's real correspondence written in that target \
    language. Update the preferences. Return JSON only — no prose, no code fences.

    Operations (return an array, possibly empty):
    [{"op":"add","kind":"tacitRule","text":"…"},
     {"op":"reinforce","memory":1},
     {"op":"weaken","memory":2},
     {"op":"delete","memory":3}]

    - "add": a NEW durable translation STYLE rule grounded in the SAMPLES — how \
    this user writes in this language: register / politeness, what they leave \
    untranslated (personal and company names, brands, technical terms, units, \
    codes), script choices, and formatting norms. "kind" MUST be "tacitRule". \
    "text" is ONE imperative sentence a translator could follow, in the user's \
    language (e.g. "Keep company and product names in Latin script."). Do NOT \
    add terminology pairs or "X => Y" mappings here — only style rules.
    - "reinforce": an existing preference (1-based "memory" index) the SAMPLES \
    corroborate. Do NOT restate it.
    - "weaken": the SAMPLES contradict or supersede an existing preference.
    - "delete": an existing preference is clearly wrong, nonsensical, or obsolete.

    Rules:
    - Add at most 3 rules per call. Prefer reinforcing an existing rule over \
    adding a near-duplicate.
    - Write durable preferences, never an observation about one message.
    - Never invent terminology you cannot see in the SAMPLES.
    - Do not include reasoning, analysis, or <think> tags. Disable thinking.


    """

    public static func buildPrompt(
        displayName: String,
        existing: [AccountMemory],
        samples: [String]
    ) -> PrefixCachedPrompt {
        buildPromptBatch(
            displayName: displayName,
            existing: existing,
            samples: samples
        ).prompt
    }

    public static func buildPromptBatch(
        displayName: String,
        existing: [AccountMemory],
        samples: [String]
    ) -> PromptBatch {
        let selectedSamples = samples.prefix(maximumSamplesPerPrompt).map {
            String(sanitize($0).prefix(maximumSampleCharacters))
        }
        let sampleTokens = selectionTokens(selectedSamples.joined(separator: " "))
        let selectedExisting = Array(existing.enumerated()
            .map { offset, memory in
                (
                    offset: offset,
                    memory: memory,
                    overlap: sampleTokens.intersection(selectionTokens(memory.displayText)).count
                )
            }
            .sorted { left, right in
                if left.overlap != right.overlap { return left.overlap > right.overlap }
                return left.offset < right.offset
            }
            .prefix(maximumExistingMemoriesPerPrompt)
            .map(\.memory))

        var lines: [String] = []
        let boundedDisplayName = String(
            sanitize(displayName).prefix(maximumDisplayNameCharacters)
        )
        lines.append("[TARGET LANGUAGE] \(boundedDisplayName)")

        if selectedExisting.isEmpty {
            lines.append("[STORED PREFERENCES]\n(none yet)")
        } else {
            var stored = ["[STORED PREFERENCES]"]
            for (idx, memory) in selectedExisting.enumerated() {
                let kindLabel = memory.targetKindRaw == ConversationCurationAction.TargetKind.tacitRule.rawValue
                    ? "rule"
                    : "pin"
                let text = String(
                    sanitize(memory.displayText).prefix(maximumExistingMemoryCharacters)
                )
                stored.append("\(idx + 1). (\(kindLabel)) \(text)")
            }
            if existing.count > selectedExisting.count {
                stored.append("(\(existing.count - selectedExisting.count) additional preferences omitted from this bounded pass)")
            }
            lines.append(stored.joined(separator: "\n"))
        }

        var sampleBlock = ["[SAMPLES] (the user's real correspondence in this language)"]
        for (idx, sample) in selectedSamples.enumerated() {
            sampleBlock.append("\(idx + 1). \(sample)")
        }
        lines.append(sampleBlock.joined(separator: "\n"))
        lines.append("JSON:")
        lines.append("/no_think")

        let prompt = PrefixCachedPrompt(
            cacheKey: "translation-dream-v2",
            prefix: promptPrefix,
            suffix: lines.joined(separator: "\n\n")
        )
        precondition(prompt.suffix.count <= maximumPromptSuffixCharacters)
        return PromptBatch(
            prompt: prompt,
            existing: selectedExisting,
            sampleCount: selectedSamples.count
        )
    }

    public static func maxTokens(existingCount: Int) -> Int {
        min(640, max(256, existingCount * 12 + 320))
    }

    /// Applies dreaming operations through the exclusive style-rule writer.
    @MainActor
    @discardableResult
    public static func apply(
        ops: [MemoryDistiller.Operation],
        existing: [AccountMemory],
        accountID: UUID,
        target: AccountMemoryDimensionTarget,
        evidence: [AccountMemoryEvidenceReference],
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> Int {
        try TranslationStyleRuleWriter.apply(
            ops: boundedOperations(ops),
            existing: existing,
            accountID: accountID,
            target: target,
            evidence: evidence,
            modelContext: modelContext,
            now: now
        )
    }

    private static func boundedOperations(
        _ operations: [MemoryDistiller.Operation]
    ) -> [MemoryDistiller.Operation] {
        var addCount = 0
        return operations.filter { operation in
            guard operation.op == "add" else { return true }
            guard addCount < maxRulesPerCall else { return false }
            addCount += 1
            return true
        }
    }

    private static func sanitize(_ text: String) -> String {
        TranslationPromptBuilder.neutralizeControlTokens(text)
    }

    private static func selectionTokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { $0.isLetter == false && $0.isNumber == false })
                .filter { $0.count >= 3 }
                .map(String.init)
        )
    }
}
