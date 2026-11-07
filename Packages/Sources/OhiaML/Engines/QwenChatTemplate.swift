import Foundation
import OhiaCore

/// Deterministic ChatML framing for the Qwen model family.
///
/// Ohia's generation prompts are complete single-turn instructions, but the
/// catalog models (`ModelManager.allModels`, all Qwen3-family) are
/// instruction-tuned chat models: fed raw text with no turn markers they
/// "continue the document" instead of answering — restating constraints,
/// repeating blocks, and running away into spec-shaped filler. That is the
/// failure mode every per-surface END-marker band-aid has been patching.
/// Framing the prompt as one user turn with the assistant turn opened
/// addresses the model the way it was trained, and the closing
/// `<|im_end|>` it emits is the tokenizer's EOS, so decoding terminates
/// naturally instead of relying on markers alone.
///
/// Hand-rolled rather than `tokenizer.applyChatTemplate` because
/// swift-transformers' Jinja engine fails on the Qwen3-family templates —
/// the original reason this codebase fell back to raw completion. Every
/// catalog model is ChatML, so the manual form is exact; unknown model
/// families pass through unframed (the previous behavior).
enum QwenChatTemplate {
    struct Capabilities: Equatable, Sendable {
        let supportsThinking: Bool
        let supportsPreservedThinking: Bool
        let supportsReasoningEffort: Bool
    }

    /// Bump whenever training/inference turn framing changes. Checkpoint
    /// manifests use this to keep adapters tied to the token structure they
    /// were trained against.
    static let trainingTemplateVersion = 1

    /// Token-level wrapper for a single user turn.
    struct TurnWrapper: Equatable {
        let header: String
        let footer: String

        func framed(_ prompt: String) -> String {
            header + prompt + footer
        }
    }

    static func isQwenFamily(_ modelID: String?) -> Bool {
        modelID?.lowercased().contains("qwen") == true
    }

    /// Qwen3-family models are thinking models: left to their own template
    /// they open a `<think>` span and spend the token budget reasoning. The
    /// empty think block is the official non-thinking assistant opening.
    static func usesThinkingControl(_ modelID: String?) -> Bool {
        capabilities(for: modelID).supportsThinking
    }

    static func capabilities(for modelID: String?) -> Capabilities {
        let normalized = modelID?.lowercased() ?? ""
        let isQwen38 = normalized.contains("qwen3.8")
        let isQwen36 = normalized.contains("qwen3.6")
        let isThinkingQwen = normalized.contains("qwen3")
        return Capabilities(
            supportsThinking: isThinkingQwen,
            supportsPreservedThinking: isQwen36 || isQwen38,
            supportsReasoningEffort: isQwen38
        )
    }

    /// Returns the user-turn wrapper for the model, or nil when the model
    /// isn't a known ChatML family.
    static func turnWrapper(for modelID: String?) -> TurnWrapper? {
        guard isQwenFamily(modelID) else { return nil }
        let assistantOpening = usesThinkingControl(modelID)
            ? "<|im_start|>assistant\n<think>\n\n</think>\n\n"
            : "<|im_start|>assistant\n"
        return TurnWrapper(
            header: "<|im_start|>user\n",
            footer: "<|im_end|>\n" + assistantOpening
        )
    }

    /// Frames a training example as one complete ChatML turn — the user turn
    /// holds the prompt, the assistant turn holds the completion — so the LoRA
    /// adapter is conditioned on the SAME token structure `generate` produces at
    /// inference time. The assistant opening (incl. the empty <think> block for
    /// qwen3) matches `turnWrapper`'s footer exactly. Non-ChatML model families
    /// fall back to the prior raw `prompt\ncompletion` concatenation.
    static func framedTrainingExample(prompt: String, completion: String, for modelID: String?) -> String {
        let segments = trainingSegments(prompt: prompt, completion: completion, for: modelID)
        return segments.prefix + segments.completion
    }

    /// Separates the inference-identical prompt prefix from the assistant
    /// completion. Training tokenizes the joined text, then derives the safe
    /// token boundary from this prefix so loss never targets prompt tokens.
    static func trainingSegments(
        prompt: String,
        completion: String,
        for modelID: String?
    ) -> (prefix: String, completion: String) {
        guard let wrapper = turnWrapper(for: modelID) else {
            return ("\(prompt)\n", completion)
        }
        return (wrapper.framed(prompt), completion + "<|im_end|>")
    }

    /// Exact text-only subset of the Qwen3-family chat templates used by
    /// Composer: user and assistant turns, model-aware historical reasoning,
    /// low-effort steering, and an open assistant thinking span.
    static func framedConversation(
        _ conversation: GenerationConversation,
        for modelID: String?
    ) -> String? {
        let modelCapabilities = capabilities(for: modelID)
        guard modelCapabilities.supportsThinking,
              !conversation.messages.isEmpty else {
            return nil
        }

        var framed = ""
        if let instruction = reasoningInstruction(for: conversation.reasoningEffort) {
            framed += "<|im_start|>system\n\(instruction)<|im_end|>\n"
        }
        for message in conversation.messages {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            switch message.role {
            case .user:
                framed += "<|im_start|>user\n\(content)<|im_end|>\n"
            case .assistant:
                framed += "<|im_start|>assistant\n"
                if conversation.preserveThinking,
                   modelCapabilities.supportsPreservedThinking {
                    let reasoning = message.reasoningContent?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    framed += "<think>\n\(reasoning)\n</think>\n\n"
                }
                framed += "\(content)<|im_end|>\n"
            }
        }
        framed += "<|im_start|>assistant\n<think>\n"
        return framed
    }

    static func boundedReasoningConversation(prompt: String, for modelID: String?) -> GenerationConversation {
        // Match the model's native thinking template. Token/deadline budgets
        // bound the work separately; inheriting the general conversation's low
        // setting changes how Qwen judges the request, not just its runtime.
        GenerationConversation(messages: [.init(role: .user, content: prompt)],
            reasoningEffort: capabilities(for: modelID).supportsReasoningEffort ? .xhigh : .medium)
    }

    static func reasoningSampling(for modelID: String?) -> GenerationSampling? {
        let normalized = modelID?.lowercased() ?? ""
        guard capabilities(for: modelID).supportsThinking else { return nil }
        if normalized.contains("qwen3.8") {
            return .reasoning
        }
        if normalized.contains("qwen3.5") || normalized.contains("qwen3.6") {
            return .qwen35Reasoning
        }
        return .qwen3Reasoning
    }

    private static func reasoningInstruction(for effort: GenerationReasoningEffort) -> String? {
        switch effort {
        case .low:
            return "Reasoning effort is set to low. Keep your thinking brief and focused, moving directly to the conclusion without unnecessary elaboration."
        case .medium:
            return nil
        case .xhigh:
            return "Reasoning effort is set to xhigh. Please think carefully through the task, validate key assumptions, consider plausible alternatives, and prioritize correctness, consistency, and clarity in the final answer."
        }
    }
}

struct QwenThinkingOutput: Equatable, Sendable {
    let content: String
    let reasoningContent: String?
}

enum QwenThinkingOutputParser {
    static func parse(_ raw: String) -> QwenThinkingOutput {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if working.hasPrefix("<think>") {
            working.removeFirst("<think>".count)
            working = working.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let closeRange = working.range(of: "</think>") else {
            // Qwen3-family generation starts after an opening `<think>` supplied
            // by the prompt, so an unterminated completion is reasoning only
            // even though the opening tag is not present in `raw`.
            return QwenThinkingOutput(content: "", reasoningContent: working.nilIfEmpty)
        }
        let reasoning = String(working[..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let content = String(working[closeRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return QwenThinkingOutput(content: content, reasoningContent: reasoning.nilIfEmpty)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
