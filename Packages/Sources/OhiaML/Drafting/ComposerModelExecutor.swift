import Foundation
import Synchronization
import OhiaCore

/// Shared model boundary for the prototype harness and Composer. It carries
/// one action cancellation token through every role, applies the role's
/// personalization scope and sampling, enforces the writer's complete-sequence
/// window, labels the activity for the status strip, and records every call.
public struct ComposerModelExecutor: Sendable {
    private final class TokenCount: Sendable {
        let value = Mutex<Int?>(nil)
    }
    private final class RetryCount: Sendable {
        let value = Mutex(0)
        func next() -> Int { value.withLock { $0 += 1; return $0 } }
    }
    /// How a retry on the author's adapter is sampled: warm enough to write
    /// a different draft in the same voice.
    static let retryTemperature: Float = 0.7
    static let retryTopP: Float = 0.9
    private let retries = RetryCount()
    public struct Trace: Codable, Sendable {
        public let prompt: String
        public let stage: ComposerPipelineStage
        public let result: GenerationResult?
    }

    /// The complete writer sequence (prompt plus completion) must fit the
    /// window the writer task is trained on. Measured development cases reach
    /// 2,532 prompt tokens at Length 9, so the training window is 4,096.
    public static let writerSequenceLimit = TrainingPromptFormat.writerSequenceTokens
    /// The fewest completion tokens the writer is ever started with. A prompt
    /// that leaves less cannot produce a complete email.
    public static let minimumWriterOutputTokens = 128

    public let engine: any TrainingEngine
    public let action: ComposerGenerationAction
    public let writerSequenceLimit: Int
    public let forceBase: Bool
    public let sampling: GenerationSampling
    /// The draft check's JSON comma limit (`ComposerPublicationAudit
    /// .answerCommaLimit`), applied to the auditor role. Nil for an auditor
    /// whose answer holds free text, such as training's meaning verdict.
    public let auditorCommaLimit: Int?
    public let activityPublisher: ModelActivityStatusPublisher?
    public let activitySource: String
    public let trace: @Sendable (Trace) throws -> Void

    public init(engine: any TrainingEngine, action: ComposerGenerationAction,
                writerSequenceLimit: Int = ComposerModelExecutor.writerSequenceLimit, forceBase: Bool = false,
                sampling: GenerationSampling = .deterministic, auditorCommaLimit: Int? = nil,
                activityPublisher: ModelActivityStatusPublisher? = nil, activitySource: String = "draft",
                trace: @escaping @Sendable (Trace) throws -> Void = { _ in }) {
        self.engine = engine
        self.action = action
        self.writerSequenceLimit = writerSequenceLimit
        self.forceBase = forceBase
        self.sampling = sampling
        self.auditorCommaLimit = auditorCommaLimit
        self.activityPublisher = activityPublisher
        self.activitySource = activitySource
        self.trace = trace
    }

    /// The email-writing roles use the caller's sampling (the voice profile).
    /// Preparation and checking are structured answers: precise sampling with
    /// the same seed, base weights, no reasoning span.
    func sampling(for role: ComposerModelRole) -> GenerationSampling {
        switch role {
        case .writer, .baseWriter:
            return sampling
        case .writerRetry:
            // Each retry its own sample: a fixed seed moves on per retry.
            var retry = sampling
            retry.temperature = max(sampling.temperature, Self.retryTemperature)
            retry.topP = min(sampling.topP, Self.retryTopP)
            let count = UInt64(retries.next())
            retry.seed = sampling.seed.map { $0 &+ count &* 7_919 }
            return retry
        case .preparer, .auditor, .repair, .answerCheck, .assentCheck, .doneCheck, .courtesyCheck:
            var precise = GenerationSampling.deterministic
            precise.seed = sampling.seed
            if role == .auditor { precise.objectCommaLimit = auditorCommaLimit }
            return precise
        }
    }

    /// Fallback for an engine without an in-process tokenizer. Against the
    /// Qwen3.5 tokenizer, one token per three UTF-8 bytes usually overcounts
    /// (about 1.5x for English, 1.7x for Japanese) but undercounts digit-,
    /// URL- and calendar-heavy text, so it is not a safe bound. Every
    /// production writer call runs in the generative worker, whose engine
    /// counts with the real tokenizer.
    static func estimatedPromptTokens(_ prompt: String) -> Int {
        max(1, prompt.utf8.count / 3)
    }

    /// The one prompt measurement for the writer window: the engine's exact
    /// count of the framed prompt when it has a tokenizer, otherwise the
    /// estimate above. The window guard below and `ComposerWriterWindow`
    /// both use it, so a fitted prompt can never fail the guard.
    public static func promptTokens(_ prompt: String, counter: (any PromptTokenCounting)?) -> Int {
        counter?.generationPromptTokenCount(prompt) ?? estimatedPromptTokens(prompt)
    }

    public func call(_ prompt: PrefixCachedPrompt, _ role: ComposerModelRole,
                     _ maximumTokens: Int) async throws -> ComposerModelOutput {
        try await call(prompt, role, maximumTokens, thinkingTokens: nil)
    }

    /// Token counting, the writer window and the trace read the whole text
    /// (`prompt.prompt`); the engine gets the checkpoints too. Bounded
    /// reasoning frames its own prompt and reads the whole text.
    public func call(_ prompt: PrefixCachedPrompt, _ role: ComposerModelRole, _ maximumTokens: Int,
                     thinkingTokens: Int?) async throws -> ComposerModelOutput {
        try action.check()
        if let thinkingTokens, role != .auditor || thinkingTokens <= 0 {
            throw ComposerContentError.invalidRequest("Bounded verification reasoning requires the auditor role.")
        }
        let scope: GenerationPersonalizationScope = forceBase ? .base : role.scope
        let roleSampling = sampling(for: role)
        let started = Date()
        let tokens = TokenCount()
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(action.remainingSeconds))
            action.cancel()
        }
        defer { watchdog.cancel() }
        do {
            let result = try await withTaskCancellationHandler {
                let work = Task.detached(priority: .userInitiated) {
                    func generate() throws -> GenerationResult {
                        try action.check()
                        let counter = engine as? any PromptTokenCounting
                        let promptTokens = Self.promptTokens(prompt.prompt, counter: counter)
                        tokens.value.withLock { $0 = promptTokens }
                        let outputLimit: Int
                        if role.writesEmail {
                            outputLimit = min(maximumTokens, writerSequenceLimit - promptTokens - 1)
                            guard outputLimit >= Self.minimumWriterOutputTokens else { throw ComposerContentError.budgetExceeded }
                        } else {
                            outputLimit = maximumTokens
                        }
                        if let contextLimit = counter?.maximumContextTokens,
                           promptTokens + outputLimit > contextLimit { throw ComposerContentError.budgetExceeded }
                        try action.check()
                        let activityToken = activityPublisher?.begin(.drafting, source: "\(activitySource)-\(role.rawValue)")
                        defer { if let activityToken { activityPublisher?.end(activityToken) } }
                        if let thinkingTokens {
                            guard let verifier = engine as? any BoundedReasoningGenerating else {
                                throw TrainingEngineError.generationFailed("The training verifier requires bounded reasoning support.")
                            }
                            return try verifier.generateWithBoundedReasoning(prompt: prompt.prompt,
                                thinkingTokens: thinkingTokens, answerTokens: outputLimit,
                                cancellation: action.cancellation, personalization: .base,
                                seed: roleSampling.seed, answerSampling: roleSampling,
                                diagnostics: { _ in }).answer
                        }
                        if let worker = engine as? WorkerGenerationEngine {
                            // Use the same profile and replay seed on both
                            // sides of the process boundary.
                            return try worker.generateResult(prompt: prompt, maxTokens: outputLimit,
                                cancellation: action.cancellation, activityKind: .drafting,
                                personalization: scope, sampling: roleSampling)
                        }
                        return try PrefixCachedGeneration.generateResult(engine: engine, prompt: prompt,
                            maxTokens: outputLimit, cancellation: action.cancellation,
                            personalization: scope, sampling: roleSampling)
                    }
                    if let serial = engine as? any CancellableGenerationOperation {
                        return try serial.withGenerationOperation(cancellation: action.cancellation, operation: generate)
                    }
                    return try generate()
                }
                // A cancellation aimed at this action (a deleted draft, the
                // deadline watchdog) must reach the engine's cooperative
                // checks as task cancellation too, not only through the token.
                let observer = Task.detached {
                    while !Task.isCancelled {
                        if action.cancellation.isCancelled { work.cancel(); return }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                defer { observer.cancel() }
                return try await work.value
            } onCancel: { action.cancel() }
            try action.check()
            try trace(Trace(prompt: prompt.prompt, stage: ComposerPipelineStage(role: role, scope: scope,
                promptTokens: tokens.value.withLock { $0 }, elapsed: Date().timeIntervalSince(started),
                completed: result.stopReason != .maxTokens, error: nil,
                reusedPromptTokens: result.diagnostics?.reusedPromptTokenCount,
                prefillSeconds: result.diagnostics?.promptSeconds,
                decodeSeconds: result.diagnostics?.decodeSeconds,
                generatedTokens: result.diagnostics?.generatedTokenCount), result: result))
            return ComposerModelOutput(text: result.text, completed: result.stopReason != .maxTokens,
                personalization: result.personalization, diagnostics: result.diagnostics)
        } catch {
            try trace(Trace(prompt: prompt.prompt, stage: ComposerPipelineStage(role: role, scope: scope,
                promptTokens: tokens.value.withLock { $0 }, elapsed: Date().timeIntervalSince(started),
                completed: false, error: String(describing: error)), result: nil))
            if Date() >= action.deadline { throw ComposerContentError.deadlineExceeded }
            throw error
        }
    }
}
