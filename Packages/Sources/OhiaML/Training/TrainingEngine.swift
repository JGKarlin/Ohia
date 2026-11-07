// TrainingEngine.swift
// Protocol for the ML training engine. Production uses MLXTrainingEngine;
// test doubles live under Packages/Tests/OhiaMLTests/Support.

import Foundation
import OhiaCore

/// The result of a single training step.
public struct TrainingStepResult: Sendable {
    public let stepNumber: Int
    public let loss: Double
    public let learningRate: Double
    public let durationSeconds: Double

    public init(stepNumber: Int, loss: Double, learningRate: Double, durationSeconds: Double) {
        self.stepNumber = stepNumber
        self.loss = loss
        self.learningRate = learningRate
        self.durationSeconds = durationSeconds
    }
}

/// The task an adapter learns: which prompt format renders its inputs and how
/// long one complete framed example may be. Production keeps the sent-reply
/// task until a reviewed release; the Composer writer task is a separate
/// identity whose checkpoints never load into the production task and vice
/// versa.
public struct TrainingTaskIdentity: Codable, Sendable, Equatable {
    public let identifier: String
    public let promptFormatVersion: Int
    public let maximumSequenceTokens: Int

    public init(identifier: String, promptFormatVersion: Int, maximumSequenceTokens: Int) {
        self.identifier = identifier
        self.promptFormatVersion = promptFormatVersion
        self.maximumSequenceTokens = maximumSequenceTokens
    }

    /// The task every adapter trained before 15 September 2026 belongs to:
    /// `TrainingPairBuilder` prompts at format 7 in a 2,048-token window.
    /// Manifests written before task identity existed decode as this task,
    /// so those adapters remain visible history and never load into the
    /// writer task.
    public static let legacySentReply = TrainingTaskIdentity(
        identifier: "sent-reply",
        promptFormatVersion: TrainingPromptFormat.legacySentReply,
        maximumSequenceTokens: 2_048
    )

    /// The Composer writer task: `ComposerWriterPrompt` inputs over a frozen
    /// request and brief, at the runtime writer window. Released as the live
    /// task on 15 September 2026 with the step-485 candidate.
    public static let composerWriter = TrainingTaskIdentity(
        identifier: "\(ComposerWriterTraining.taskIdentifier)/reconstruction-\(ComposerWriterTraining.reconstructionVersion)/\(ComposerStyleRubric.version)",
        promptFormatVersion: TrainingPromptFormat.writerTask,
        maximumSequenceTokens: ComposerModelExecutor.writerSequenceLimit
    )

    /// The live task: what the app trains and which checkpoints it loads.
    public static let production = composerWriter
}

/// Exact training-run identity. Inference and a fresh optimizer may retain
/// promoted voice weights across prompt-only revisions via `canRetainVoice`.
public struct TrainingCheckpointCompatibility: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let baseModelID: String
    public let promptFormatVersion: Int
    public let chatTemplateVersion: Int
    public let loraLayerCount: Int
    public let loraRank: Int
    public let loraScale: Double
    public let taskIdentifier: String

    /// A renderer revision changes the supervised inputs, not the meaning of
    /// the learned voice. Changes to reconstruction or style measurement still
    /// require a separate lineage. Base-model and LoRA tensor checks stay exact.
    public func canRetainVoice(from previous: Self) -> Bool {
        guard schemaVersion == previous.schemaVersion,
              baseModelID == previous.baseModelID,
              chatTemplateVersion == previous.chatTemplateVersion,
              loraLayerCount == previous.loraLayerCount,
              loraRank == previous.loraRank,
              loraScale == previous.loraScale else { return false }
        if self == previous { return true }
        guard let current = Self.voiceContract(taskIdentifier),
              let inherited = Self.voiceContract(previous.taskIdentifier) else { return false }
        return current == inherited
    }

    static func voiceContract(_ identifier: String) -> String? {
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].hasPrefix("composer-content-to-prose-v"),
              Int(parts[0].dropFirst("composer-content-to-prose-v".count)) != nil,
              parts[1].hasPrefix("reconstruction-"),
              Int(parts[1].dropFirst("reconstruction-".count)) != nil,
              parts[2].hasPrefix("composer-style-rubric-v"),
              Int(parts[2].dropFirst("composer-style-rubric-v".count)) != nil else { return nil }
        return parts.dropFirst().joined(separator: "/")
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        baseModelID: String,
        promptFormatVersion: Int,
        chatTemplateVersion: Int,
        loraLayerCount: Int,
        loraRank: Int,
        loraScale: Double,
        taskIdentifier: String = TrainingTaskIdentity.production.identifier
    ) {
        self.schemaVersion = schemaVersion
        self.baseModelID = baseModelID
        self.promptFormatVersion = promptFormatVersion
        self.chatTemplateVersion = chatTemplateVersion
        self.loraLayerCount = loraLayerCount
        self.loraRank = loraRank
        self.loraScale = loraScale
        self.taskIdentifier = taskIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, baseModelID, promptFormatVersion, chatTemplateVersion
        case loraLayerCount, loraRank, loraScale, taskIdentifier
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        baseModelID = try container.decode(String.self, forKey: .baseModelID)
        promptFormatVersion = try container.decode(Int.self, forKey: .promptFormatVersion)
        chatTemplateVersion = try container.decode(Int.self, forKey: .chatTemplateVersion)
        loraLayerCount = try container.decode(Int.self, forKey: .loraLayerCount)
        loraRank = try container.decode(Int.self, forKey: .loraRank)
        loraScale = try container.decode(Double.self, forKey: .loraScale)
        taskIdentifier = try container.decodeIfPresent(String.self, forKey: .taskIdentifier)
            ?? TrainingTaskIdentity.legacySentReply.identifier
    }
}

public struct TrainingEvaluation: Sendable, Equatable {
    public let loss: Double
    public let exampleCount: Int
    public let completionTokenCount: Int

    public init(loss: Double, exampleCount: Int, completionTokenCount: Int) {
        self.loss = loss
        self.exampleCount = exampleCount
        self.completionTokenCount = completionTokenCount
    }
}

/// Versioned optimization behavior that participates in corpus eligibility
/// without changing adapter compatibility. Updating this identifier makes
/// evidence deferred by an older optimization regime eligible again while
/// preserving the last promoted adapter.
///
/// A run visits every target pair once per epoch. The learning rate warms up
/// linearly, then decays on a cosine to a floor over the whole run. A
/// candidate is judged only when an epoch completes: it must beat the base
/// model's held-out loss on the author's own mail, and within a lineage it
/// may not regress the promoted adapter's held-out loss by more than
/// `maximumValidationRegressionFraction`.
public struct TrainingOptimizationPolicy: Codable, Sendable, Equatable {
    public static let current = TrainingOptimizationPolicy(
        identifier: "epoch-cosine-v3",
        peakLearningRate: 0.000_05,
        warmupFraction: 0.05,
        minimumWarmupSteps: 8,
        floorLearningRateFraction: 0.1,
        fullRunEpochs: 3,
        incrementalEpochs: 2,
        maximumValidationRegressionFraction: 0.01,
        maximumValidationExamples: 32,
        deferralRetryInterval: 24 * 60 * 60
    )

    public let identifier: String
    public let peakLearningRate: Double
    public let warmupFraction: Double
    public let minimumWarmupSteps: Int
    public let floorLearningRateFraction: Double
    /// Passes over the whole eligible corpus in a full run.
    public let fullRunEpochs: Int
    /// Passes over the new pairs in an incremental run; replay ballast from
    /// the promoted corpus interleaves with each pass.
    public let incrementalEpochs: Int
    public let maximumValidationRegressionFraction: Double
    /// Held-out examples evaluated per judgment, a stable subset of the
    /// validation holdout, so a judgment costs minutes rather than scaling
    /// with the corpus.
    public let maximumValidationExamples: Int
    /// A pair deferred by a rejected, never-promoted run becomes eligible
    /// again after this long; only a manual full run ignores deferral.
    public let deferralRetryInterval: TimeInterval

    public init(
        identifier: String,
        peakLearningRate: Double,
        warmupFraction: Double,
        minimumWarmupSteps: Int,
        floorLearningRateFraction: Double,
        fullRunEpochs: Int,
        incrementalEpochs: Int,
        maximumValidationRegressionFraction: Double,
        maximumValidationExamples: Int,
        deferralRetryInterval: TimeInterval
    ) {
        self.identifier = identifier
        self.peakLearningRate = peakLearningRate
        self.warmupFraction = warmupFraction
        self.minimumWarmupSteps = minimumWarmupSteps
        self.floorLearningRateFraction = floorLearningRateFraction
        self.fullRunEpochs = fullRunEpochs
        self.incrementalEpochs = incrementalEpochs
        self.maximumValidationRegressionFraction = maximumValidationRegressionFraction
        self.maximumValidationExamples = maximumValidationExamples
        self.deferralRetryInterval = deferralRetryInterval
    }

    public func epochs(for kind: TrainingCorpusRunKind) -> Int {
        kind == .incremental ? incrementalEpochs : fullRunEpochs
    }

    /// Learning rate for zero-based optimizer `step` of a run with
    /// `totalSteps` visits: linear warmup to `peak` (default
    /// `peakLearningRate`), then cosine decay to the floor fraction of it.
    public func learningRate(step: Int, totalSteps: Int, peak: Double? = nil) -> Double {
        let peakLearningRate = peak ?? self.peakLearningRate
        let total = max(totalSteps, 1)
        let warmup = min(max(minimumWarmupSteps, Int((Double(total) * warmupFraction).rounded(.up))), total)
        let position = min(max(step, 0), total - 1)
        if position < warmup {
            return peakLearningRate * Double(position + 1) / Double(warmup)
        }
        let decaySteps = max(total - warmup, 1)
        let progress = Double(position - warmup) / Double(decaySteps)
        let floor = peakLearningRate * floorLearningRateFraction
        return floor + (peakLearningRate - floor) * 0.5 * (1 + cos(Double.pi * progress))
    }
}

/// Engine-neutral metadata binding a manifest to the optimizer tensors saved
/// beside its adapter. Tensor names and shapes are validated by the engine.
public struct TrainingOptimizerStateDescriptor: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let optimizerIdentifier: String
    public let optimizerStep: Int
    public let stateTensorCount: Int
    public let policyIdentifier: String
    public let learningRate: Double

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        optimizerIdentifier: String,
        optimizerStep: Int,
        stateTensorCount: Int,
        policyIdentifier: String,
        learningRate: Double
    ) {
        self.schemaVersion = schemaVersion
        self.optimizerIdentifier = optimizerIdentifier
        self.optimizerStep = optimizerStep
        self.stateTensorCount = stateTensorCount
        self.policyIdentifier = policyIdentifier
        self.learningRate = learningRate
    }
}

/// Errors that can be thrown by a TrainingEngine.
public enum TrainingEngineError: Error, Sendable {
    case modelNotLoaded
    case modelUnavailable(String)
    case adapterNotFound(String)
    case saveFailed(String)
    case loadFailed(String)
    case trainingFailed(String)
    /// Rejected before an optimizer update; retrying unchanged text cannot
    /// help. `sequenceTokens` is the framed example's measured length when
    /// the rejection was its length.
    case invalidTrainingExample(String, sequenceTokens: Int? = nil)
    case generationFailed(String)
}

extension TrainingEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Base model is not loaded yet."
        case .modelUnavailable(let detail):
            return detail
        case .adapterNotFound(let path):
            return "Adapter file not found at \(path)."
        case .saveFailed(let detail):
            return "Adapter save failed: \(detail)"
        case .loadFailed(let detail):
            return "Adapter load failed: \(detail)"
        case .trainingFailed(let detail):
            return "Training step failed: \(detail)"
        case .invalidTrainingExample(let detail, _):
            return "Training example rejected: \(detail)"
        case .generationFailed(let detail):
            return "Generation failed: \(detail)"
        }
    }
}

/// Abstracts ML computation so the full pipeline can be tested without a real model.
public protocol TrainingEngine: AnyObject, Sendable {
    var isModelLoaded: Bool { get }
    var isAdapterLoaded: Bool { get }
    var totalSteps: Int { get }

    /// Set by `cancel()`; read by the detached training loop between steps so
    /// a mid-session pause / app-shutdown exits cleanly. Transitions back to
    /// false when `resetCancellation()` is called at the top of a new session.
    var isCancelled: Bool { get }

    /// Hard upper bound for one optimizer update. The orchestrator passes no
    /// more than this many examples and therefore knows exactly which pairs
    /// contributed to the gradient it records as trained.
    var maximumTrainingBatchSize: Int { get }

    func loadModel(path: String) throws
    func beginTrainingSession(learningRate: Double) throws
    func trainStep(examples: [TrainingExample], learningRate: Double) throws -> TrainingStepResult
    func endTrainingSession()
    func saveAdapter(to path: String) throws
    func loadAdapter(from path: String) throws
    func generate(prompt: String, maxTokens: Int) throws -> String

    /// Request cancellation. Safe to call from any thread; individual
    /// `trainStep` calls complete normally, then the detached loop checks
    /// `isCancelled` before starting the next step.
    func cancel()

    /// Clear `isCancelled` for a fresh session. Called by the orchestrator at
    /// the start of `runTrainingRun`.
    func resetCancellation()
}

/// Optional capability for engines that can count prompt tokens with their
/// loaded tokenizer and report the model's native context capacity.
public protocol PromptTokenCounting: Sendable {
    func promptTokenCount(_ text: String) -> Int
    /// Counts the exact text the generation engine will encode, including
    /// any model-family chat wrapper added around the caller's prompt.
    func generationPromptTokenCount(_ text: String) -> Int
    var maximumContextTokens: Int? { get }
    /// False while counts are a stand-in for the model's tokenizer (no model
    /// loaded). Decisions that must hold for the real tokenizer, such as the
    /// writer window fit, wait instead of trusting a stand-in. Every counter
    /// states it; there is no default.
    var isTokenizerLoaded: Bool { get }
}

public extension PromptTokenCounting {
    func generationPromptTokenCount(_ text: String) -> Int {
        promptTokenCount(text)
    }
}

/// Optional structured multi-turn generation. Composer uses this capability
/// for Qwen3.8 preserved thinking; engines without it receive the complete
/// model-neutral `fallbackPrompt` through the existing string API.
public protocol ConversationalGenerating: TrainingEngine {
    func generate(
        conversation: GenerationConversation,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        personalization: GenerationPersonalizationScope
    ) throws -> GenerationResult
}

/// Counts the exact structured prompt an engine will encode.
public protocol ConversationPromptTokenCounting: PromptTokenCounting {
    func generationPromptTokenCount(
        _ conversation: GenerationConversation,
        personalization: GenerationPersonalizationScope
    ) -> Int
}

public enum WorkerGenerationContextUsage {
    public static func measure(
        request: WorkerGenerationRequest,
        tokenCounter: any PromptTokenCounting,
        policy: ComposerContextPacker.Policy = .init()
    ) -> WorkerPromptUsageSnapshot? {
        guard let modelMaximum = tokenCounter.maximumContextTokens,
              modelMaximum > 0 else {
            return nil
        }
        let operatingMaximum = min(
            modelMaximum,
            max(0, policy.maximumOperatingInputTokens)
        )
        guard operatingMaximum > 0 else { return nil }
        let inputTokens: Int
        if let conversation = request.conversation,
           let conversationCounter = tokenCounter as? any ConversationPromptTokenCounting {
            inputTokens = conversationCounter.generationPromptTokenCount(
                conversation,
                personalization: request.resolvedPersonalization
            )
        } else {
            inputTokens = tokenCounter.generationPromptTokenCount(request.resolvedPrompt)
        }
        return WorkerPromptUsageSnapshot(
            inputTokens: inputTokens,
            maximumContextTokens: operatingMaximum,
            maximumOutputTokens: request.maxTokens
        )
    }
}

/// Production engines expose enough information to reject foreign adapters,
/// evaluate candidates on held-out authored mail, and return to the exact
/// already-loaded base model without resolving a new hardware default.
public protocol CheckpointAwareTrainingEngine: TrainingEngine {
    var checkpointCompatibility: TrainingCheckpointCompatibility? { get }
    func evaluate(examples: [TrainingExample]) throws -> TrainingEvaluation
    func resetAdapter() throws
    /// Drafts the quality probes `resuming` lacks; throws
    /// `CheckpointQualityError.incomplete` with the drafts so far when stopped.
    func evaluateCheckpointQuality(adapterDigest: String, identity: CheckpointQualityIdentity,
                                   resuming: CheckpointQualityReport?,
                                   cancellation: GenerationCancellation) throws -> CheckpointQualityReport
}

/// Optional production capability for engines whose optimizer can be saved
/// and restored by stable named tensors. CheckpointManager treats a resume
/// candidate from such an engine as incomplete unless this state is present.
public protocol OptimizerCheckpointingTrainingEngine: CheckpointAwareTrainingEngine {
    func saveOptimizerState(
        to path: String,
        policyIdentifier: String
    ) throws -> TrainingOptimizerStateDescriptor
    func loadOptimizerState(
        from path: String,
        descriptor: TrainingOptimizerStateDescriptor
    ) throws
    func clearOptimizerState()
}

/// Identifies an unjudged training frontier held in memory between jobs of
/// one run: exactly the ledger rows its weights have trained on, with the
/// bookkeeping a job resumes from, and when it was last written to disk.
public struct TrainingFrontierMarker: Sendable, Equatable {
    public let runID: UUID
    /// The promoted checkpoint the frontier was trained on (nil: the base
    /// model). A frontier resumes only on that same parent.
    public let parentCheckpointID: UUID?
    public let attemptIDs: Set<UUID>
    public let stepCount: Int
    public let lossSum: Double
    public let lossSampleCount: Int
    /// When this frontier (or an earlier point of it) was last persisted as
    /// a resume checkpoint; nil when it never was.
    public let persistedAt: Date?

    public init(runID: UUID, parentCheckpointID: UUID?, attemptIDs: Set<UUID>, stepCount: Int, lossSum: Double,
                lossSampleCount: Int, persistedAt: Date?) {
        self.runID = runID
        self.parentCheckpointID = parentCheckpointID
        self.attemptIDs = attemptIDs
        self.stepCount = stepCount
        self.lossSum = lossSum
        self.lossSampleCount = lossSampleCount
        self.persistedAt = persistedAt
    }
}

/// Engines that can set the in-progress adapter and optimizer aside in
/// memory while the promoted adapter serves drafts, and reinstall them for
/// the next training job without a disk round trip. A stash never outlives
/// the loaded model.
public protocol TrainingFrontierStashing: OptimizerCheckpointingTrainingEngine {
    /// Detaches the current adapter and optimizer state under `marker`,
    /// replacing any earlier stash. The engine's active adapter is unchanged.
    func stashTrainingFrontier(_ marker: TrainingFrontierMarker) throws
    /// The stashed frontier's marker, if one is held for the loaded model.
    var stashedTrainingFrontier: TrainingFrontierMarker? { get }
    /// Reinstalls the stashed adapter and optimizer as the active training
    /// state and releases the stash. False when nothing is stashed.
    func restoreStashedTrainingFrontier() throws -> Bool
    func discardStashedTrainingFrontier()
}

public extension TrainingEngine {
    var maximumTrainingBatchSize: Int { 4 }

    /// Engines without optimizer state do not need session setup/teardown.
    func beginTrainingSession(learningRate: Double) throws {}
    func endTrainingSession() {}
}

public final class GenerationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    public func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}

/// Optional capability for engines that can reuse the model state of a
/// prompt's checkpoints (`PrefixCachedPrompt`). Engines that do not implement
/// this simply use `TrainingEngine.generate` with `prompt.prompt`.
public protocol PrefixCachedGenerating: TrainingEngine {
    func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int
    ) throws -> String
}

public protocol CancellableGenerating: TrainingEngine {
    func generate(
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation
    ) throws -> String
}

public protocol CancellablePrefixCachedGenerating: PrefixCachedGenerating, CancellableGenerating {
    func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation
    ) throws -> String
}

/// Optional capability for engines that can explicitly enable or suppress an
/// installed personalization adapter for one generation operation.
public protocol PersonalizationScopedGenerating: TrainingEngine {
    func generate(
        prompt: String,
        maxTokens: Int,
        personalization: GenerationPersonalizationScope
    ) throws -> String
}

public protocol PersonalizationScopedCancellableGenerating:
    PersonalizationScopedGenerating,
    CancellableGenerating
{
    func generate(
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        personalization: GenerationPersonalizationScope
    ) throws -> String
}

public protocol PersonalizationScopedPrefixCachedGenerating:
    PersonalizationScopedGenerating,
    PrefixCachedGenerating
{
    func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        personalization: GenerationPersonalizationScope
    ) throws -> String
}

public protocol PersonalizationScopedCancellablePrefixCachedGenerating:
    PersonalizationScopedCancellableGenerating,
    PersonalizationScopedPrefixCachedGenerating,
    CancellablePrefixCachedGenerating
{
    func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        personalization: GenerationPersonalizationScope
    ) throws -> String
}

/// Optional capability for engines that accept per-call sampling controls.
///
/// Every lane in the app decodes near-greedily by default, which is what
/// drafting, Ask, triage, summarization, and extraction want. The signature
/// studio is the sole exception: its contract is that three tiers and each
/// regenerate produce materially different designs, which a near-greedy
/// decode collapses. Rather than add a sampling parameter to every generate
/// overload, engines that can honor it adopt this capability and callers
/// that need it pass `sampling:`; everyone else is unaffected.
public protocol SamplingScopedGenerating: TrainingEngine {
    func generate(
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        personalization: GenerationPersonalizationScope,
        sampling: GenerationSampling
    ) throws -> String
}

public protocol SamplingScopedPrefixCachedGenerating: SamplingScopedGenerating, PrefixCachedGenerating {
    func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        personalization: GenerationPersonalizationScope,
        sampling: GenerationSampling
    ) throws -> String
}

public protocol DetailedSamplingScopedGenerating: SamplingScopedGenerating {
    func generateResult(
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        personalization: GenerationPersonalizationScope,
        sampling: GenerationSampling
    ) throws -> GenerationResult
}

public protocol DetailedSamplingScopedPrefixCachedGenerating:
    DetailedSamplingScopedGenerating,
    SamplingScopedPrefixCachedGenerating
{
    func generateResult(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        personalization: GenerationPersonalizationScope,
        sampling: GenerationSampling
    ) throws -> GenerationResult
}

public enum PrefixCachedGeneration {
    private static func unsupportedPersonalization() -> TrainingEngineError {
        .generationFailed(
            "The active generation engine cannot explicitly install a personalization adapter."
        )
    }

    public static func generate(
        engine: any TrainingEngine,
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        personalization: GenerationPersonalizationScope = .base
    ) throws -> String {
        if let scoped = engine as? any PersonalizationScopedPrefixCachedGenerating {
            return try scoped.generate(
                prompt: prompt,
                maxTokens: maxTokens,
                personalization: personalization
            )
        }
        if personalization == .personalized {
            if let scoped = engine as? any PersonalizationScopedGenerating {
                return try scoped.generate(
                    prompt: prompt.prompt,
                    maxTokens: maxTokens,
                    personalization: personalization
                )
            }
            throw unsupportedPersonalization()
        }
        if let cached = engine as? any PrefixCachedGenerating {
            return try cached.generate(
                prompt: prompt,
                maxTokens: maxTokens
            )
        }
        return try engine.generate(prompt: prompt.prompt, maxTokens: maxTokens)
    }

    public static func generate(
        engine: any TrainingEngine,
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        personalization: GenerationPersonalizationScope = .base,
        sampling: GenerationSampling? = nil
    ) throws -> String {
        try cancellation.checkCancellation()
        if let sampling, let scoped = engine as? any SamplingScopedGenerating {
            return try scoped.generate(
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation,
                personalization: personalization,
                sampling: sampling
            )
        }
        if let scoped = engine as? any PersonalizationScopedCancellableGenerating {
            return try scoped.generate(
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation,
                personalization: personalization
            )
        }
        if personalization == .personalized {
            if let scoped = engine as? any PersonalizationScopedGenerating {
                let output = try scoped.generate(
                    prompt: prompt,
                    maxTokens: maxTokens,
                    personalization: personalization
                )
                try cancellation.checkCancellation()
                return output
            }
            throw unsupportedPersonalization()
        }
        if let cancellable = engine as? any CancellableGenerating {
            return try cancellable.generate(
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation
            )
        }
        let output = try engine.generate(prompt: prompt, maxTokens: maxTokens)
        try cancellation.checkCancellation()
        return output
    }

    public static func generateResult(
        engine: any TrainingEngine,
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        personalization: GenerationPersonalizationScope = .base,
        sampling: GenerationSampling? = nil
    ) throws -> GenerationResult {
        try cancellation.checkCancellation()
        if let detailed = engine as? any DetailedSamplingScopedGenerating {
            return try detailed.generateResult(
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation,
                personalization: personalization,
                sampling: sampling ?? .deterministic
            )
        }
        return GenerationResult(text: try generate(
            engine: engine,
            prompt: prompt,
            maxTokens: maxTokens,
            cancellation: cancellation,
            personalization: personalization,
            sampling: sampling
        ))
    }

    public static func generate(
        engine: any TrainingEngine,
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        personalization: GenerationPersonalizationScope = .base,
        sampling: GenerationSampling? = nil
    ) throws -> String {
        try cancellation.checkCancellation()
        // Sampling is a best-effort hint: an engine that cannot honor it
        // still generates, decoding deterministically. That is deliberate —
        // variation is a quality nicety for the one lane that asks, never a
        // correctness requirement worth failing a generation over. See
        // `SignatureGenerationService.run`.
        if let sampling, let scoped = engine as? any SamplingScopedPrefixCachedGenerating {
            return try scoped.generate(
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation,
                personalization: personalization,
                sampling: sampling
            )
        }
        if let scoped = engine as? any PersonalizationScopedCancellablePrefixCachedGenerating {
            return try scoped.generate(
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation,
                personalization: personalization
            )
        }
        if let scoped = engine as? any PersonalizationScopedCancellableGenerating {
            return try scoped.generate(
                prompt: prompt.prompt,
                maxTokens: maxTokens,
                cancellation: cancellation,
                personalization: personalization
            )
        }
        if personalization == .personalized {
            if let scoped = engine as? any PersonalizationScopedPrefixCachedGenerating {
                let output = try scoped.generate(
                    prompt: prompt,
                    maxTokens: maxTokens,
                    personalization: personalization
                )
                try cancellation.checkCancellation()
                return output
            }
            if let scoped = engine as? any PersonalizationScopedGenerating {
                let output = try scoped.generate(
                    prompt: prompt.prompt,
                    maxTokens: maxTokens,
                    personalization: personalization
                )
                try cancellation.checkCancellation()
                return output
            }
            throw unsupportedPersonalization()
        }
        if let cached = engine as? any CancellablePrefixCachedGenerating {
            return try cached.generate(
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation
            )
        }
        if let cancellable = engine as? any CancellableGenerating {
            return try cancellable.generate(
                prompt: prompt.prompt,
                maxTokens: maxTokens,
                cancellation: cancellation
            )
        }
        let output = try generate(
            engine: engine,
            prompt: prompt,
            maxTokens: maxTokens,
            personalization: personalization
        )
        try cancellation.checkCancellation()
        return output
    }

    public static func generateResult(
        engine: any TrainingEngine,
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        personalization: GenerationPersonalizationScope = .base,
        sampling: GenerationSampling? = nil
    ) throws -> GenerationResult {
        try cancellation.checkCancellation()
        if let detailed = engine as? any DetailedSamplingScopedPrefixCachedGenerating {
            return try detailed.generateResult(
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation,
                personalization: personalization,
                sampling: sampling ?? .deterministic
            )
        }
        return GenerationResult(text: try generate(
            engine: engine,
            prompt: prompt,
            maxTokens: maxTokens,
            cancellation: cancellation,
            personalization: personalization,
            sampling: sampling
        ))
    }
}
