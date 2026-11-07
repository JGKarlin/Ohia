import Foundation
import OSLog
import OhiaCore

// Not file-private: `ThreadDiscoursePrompt.parse` in the same module logs
// through this same instance when it salvages truncated model output, so a
// salvaged parse and a genuine parse failure land in one log stream.
let threadDiscourseLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "discourse-extractor"
)

/// LLM-backed discourse extractor that drives the Memory Claim Ledger's
/// thread-unit extraction through any `TrainingEngine` (MLX in production,
/// a mock in tests). The engine generates raw text against
/// `ThreadDiscoursePrompt`, the parser enforces the thread contract and
/// attributes each item back to the message that supplied its evidence, and
/// contract violations get demoted to uncertainties so an LLM goof never
/// becomes a memory card.
///
/// The extractor guards on an engine-loaded check, runs cancellation-safe
/// generation via `runDiscourseGeneration`, and treats a parse failure as
/// `nil` with logging. Its reasoning unit is a whole thread rendered by
/// `ThreadExtractionPacketBuilder`, and its return shape is one
/// `DiscourseMemory` per message that received at least one attributed item,
/// rather than a single memory for one message in isolation.
public final class ThreadDiscourseExtractor: @unchecked Sendable {
    private let engine: any TrainingEngine
    private let maxTokens: Int
    private let generationTaskPriority: TaskPriority

    public init(
        engine: any TrainingEngine,
        maxTokens: Int = 3_072,
        generationTaskPriority: TaskPriority = .background
    ) {
        self.engine = engine
        self.maxTokens = maxTokens
        self.generationTaskPriority = generationTaskPriority
    }

    /// Extracts discourse memories for every message in `packet` that ends
    /// up with at least one attributed claim, decision, tacit-rule signal,
    /// supersession, or uncertainty.
    ///
    /// Returns `nil` when the engine is not loaded, the model produced empty
    /// output, or the output failed to parse — in every one of those cases
    /// the caller keeps whatever deterministic seeds it already has. Throws
    /// `DiscourseExtractionError.engineFailure` only when the engine itself
    /// raises (a `CancellationError` is treated as a soft nil).
    public func extract(
        packet: ThreadExtractionPacket,
        userAddresses: Set<String>,
        language: String?
    ) async throws -> [UUID: DiscourseMemory]? {
        guard engine.isModelLoaded else {
            threadDiscourseLogger.info("Thread discourse extract: engine not loaded, returning nil")
            return nil
        }
        threadDiscourseLogger.info("Thread discourse extract: start messages=\(packet.messages.count, privacy: .public)")
        let prompt = ThreadDiscoursePrompt.makePrompt(
            packet: packet,
            userAddresses: userAddresses,
            language: language
        )
        let raw: String
        do {
            raw = try await runDiscourseGeneration(
                engine: engine,
                prompt: prompt,
                maxTokens: maxTokens,
                priority: generationTaskPriority
            )
        } catch is CancellationError {
            return nil
        } catch {
            threadDiscourseLogger.error("Thread discourse extract: engine failure: \(String(reflecting: type(of: error)), privacy: .public)")
            throw DiscourseExtractionError.engineFailure(String(describing: error))
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            threadDiscourseLogger.info("Thread discourse extract: empty output")
            return nil
        }
        do {
            let parsed = try ThreadDiscoursePrompt.parse(modelOutput: trimmed, packet: packet)
            threadDiscourseLogger.info("Thread discourse extract: parsed messages=\(parsed.count, privacy: .public)")
            return parsed
        } catch {
            threadDiscourseLogger.warning("Thread discourse extract: parse failed: \(String(reflecting: type(of: error)), privacy: .public)")
            // Parse failures don't promote — return nil so the caller keeps
            // whatever deterministic seeds it already has.
            return nil
        }
    }
}

/// Failure cases surfaced when the engine itself raises during thread
/// extraction. The worker funnels these into the snapshot's `.failed`
/// coverage state.
public enum DiscourseExtractionError: Error, Sendable, Equatable {
    case engineFailure(String)
    case parseFailure(String)
}

/// Cancellation-safe wrapper around a `TrainingEngine.generate` call.
/// Lives at module-internal visibility so any LLM adapter inside
/// `ConversationIntelligence/` can share the same cancellation contract.
/// `Summarizer.swift` has its own file-private `runCancellableGeneration`
/// with a closure-shaped signature — the divergence is intentional:
/// summarization composes prompts through `PrefixCachedPrompt` for KV
/// caching, while the discourse extractor builds the prompt once per
/// thread and never reuses it across threads.
@discardableResult
func runDiscourseGeneration(
    engine: any TrainingEngine,
    prompt: String,
    maxTokens: Int,
    priority: TaskPriority
) async throws -> String {
    let cancellation = GenerationCancellation()
    let task = Task.detached(priority: priority) {
        try Task.checkCancellation()
        return try PrefixCachedGeneration.generate(
            engine: engine,
            prompt: prompt,
            maxTokens: maxTokens,
            cancellation: cancellation
        )
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        cancellation.cancel()
        task.cancel()
    }
}
