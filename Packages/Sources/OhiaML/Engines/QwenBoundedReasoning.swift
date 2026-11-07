import Foundation
import OhiaCore

public struct BoundedReasoningDiagnostics: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case thinking, answer }
    public let thinkingStopReason: GenerationStopReason?
    public let thinking: GenerationDiagnostics?
    public let answer: GenerationDiagnostics?
    public var activePhase: Phase? = nil
    public var thinkingSampling: GenerationSampling? = nil
    public var answerSampling: GenerationSampling? = nil
    public var reasoningEffort: GenerationReasoningEffort? = nil
}

public struct BoundedReasoningResult: Sendable {
    public let answer: GenerationResult
    public let diagnostics: BoundedReasoningDiagnostics
}

/// Content reasoning receives a separate budget from its final structured
/// answer. Implementations must own both phases under one cancellation scope.
public protocol BoundedReasoningGenerating: TrainingEngine {
    func generateWithBoundedReasoning(prompt: String, thinkingTokens: Int, answerTokens: Int,
        cancellation: GenerationCancellation?, personalization: GenerationPersonalizationScope,
        seed: UInt64?, answerSampling: GenerationSampling,
        diagnostics: @Sendable (BoundedReasoningDiagnostics) -> Void) throws -> BoundedReasoningResult
}

/// Serializes tokenization and generation without making a cancelled caller wait
/// for a different model consumer to finish.
public protocol CancellableGenerationOperation: TrainingEngine {
    func withGenerationOperation<T>(cancellation: GenerationCancellation,
        operation: () throws -> T) throws -> T
}

/// Implements Qwen's assistant-prefill thinking budget. The second prefill
/// retains the actual reasoning and closes the same assistant thinking span;
/// it never restarts the original question in non-thinking mode.
enum QwenBoundedReasoning {
    static func generate(framedPrompt: String, thinkingTokens: Int, answerTokens: Int,
        contextLimit: Int, countTokens: (String) -> Int, checkCancellation: () throws -> Void,
        diagnostics: (BoundedReasoningDiagnostics) -> Void = { _ in },
        generate: (String, Int, Bool) throws -> GenerationResult) throws -> BoundedReasoningResult {
        try checkCancellation()
        let closure = "\n</think>\n\n"
        guard thinkingTokens > 0, answerTokens > 0,
              countTokens(framedPrompt) + thinkingTokens + countTokens(closure) + answerTokens + 1 <= contextLimit else {
            throw TrainingEngineError.generationFailed("Reasoning and answer budgets exceed the model context.")
        }
        diagnostics(.init(thinkingStopReason: nil, thinking: nil, answer: nil, activePhase: .thinking))
        let thinking = try generate(framedPrompt, thinkingTokens, true)
        diagnostics(.init(thinkingStopReason: thinking.stopReason, thinking: thinking.diagnostics,
            answer: nil, activePhase: .answer))
        try checkCancellation()
        let continuation: String
        if let end = thinking.text.range(of: "</think>") {
            continuation = framedPrompt + thinking.text[..<end.upperBound] + "\n\n"
        } else {
            // A tokenizer can emit a delimiter over several streamed chunks.
            // Remove only a trailing incomplete delimiter before closing it.
            var text = thinking.text
            for length in stride(from: "</think>".count - 1, through: 1, by: -1) {
                let prefix = "</think>".prefix(length)
                if text.hasSuffix(prefix) {
                    text.removeLast(length)
                    break
                }
            }
            continuation = framedPrompt + text + closure
        }
        guard countTokens(continuation) + answerTokens + 1 <= contextLimit else {
            throw TrainingEngineError.generationFailed("The reasoning continuation leaves insufficient room for the reserved answer.")
        }
        try checkCancellation()
        let answer = try generate(continuation, answerTokens, false)
        diagnostics(.init(thinkingStopReason: thinking.stopReason, thinking: thinking.diagnostics,
            answer: answer.diagnostics))
        try checkCancellation()
        return BoundedReasoningResult(answer: answer, diagnostics: .init(
            thinkingStopReason: thinking.stopReason, thinking: thinking.diagnostics, answer: answer.diagnostics))
    }
}
