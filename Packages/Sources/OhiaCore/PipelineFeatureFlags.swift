import Foundation

public enum PipelineFeatureFlags {
    /// Gates the Composer's questions-first drafting pipeline: the
    /// `.generateDraft` job (clarifying-question seeding, owed generations,
    /// instruction revisions) and BGE generation-context-pack preparation.
    /// Which messages enter the queue is governed separately by
    /// `ComposerQueueIntakePreference` (manual "Send to Composer" vs
    /// automatic triage queueing). Disabling this strands Composer drafts in
    /// "preparing questions" / "writing draft" — the worker completes every
    /// `.generateDraft` job as a no-op.
    public static let automaticReplyDraftGenerationEnabled = true

    /// Gates the full personalization-training lifecycle: sent-mail
    /// training-pair preparation (`.buildTrainingPairs`) and event-driven LoRA
    /// adapter training (`.train`). Enabled as of the Phase-A prompt-format
    /// unification — the adapter now trains on the same ChatML prompt/completion
    /// contract the Composer drafts with, so training meaningfully improves
    /// drafts. The `.train` job yields to interactive `.generateDraft` work via
    /// the scheduler's borrow lanes, so background training never starves the
    /// Composer's foreground generation.
    public static let qwenPersonalizationTrainingEnabled = true
}
