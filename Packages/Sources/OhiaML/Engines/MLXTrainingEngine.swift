// MLXTrainingEngine.swift
// Primary training engine backed by mlx-swift-lm for LoRA fine-tuning and inference.

import CryptoKit
import Foundation
import Hub
import MLX
import MLXLMCommon
import MLXLLM
import MLXNN
import OhiaCore
import os
import Synchronization
@preconcurrency import Tokenizers

private let mlxTrainingLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "mlxTraining"
)

struct MLXGenerationOutput: Sendable {
    let text: String
    let stopReason: GenerationStopReason
    let completionInfo: GenerateCompletionInfo?
    /// Tokens of the whole framed prompt. Nil when the iterator saw all of it,
    /// so `completionInfo.promptTokenCount` is already the whole prompt.
    var promptTokenCount: Int? = nil
    /// Prompt tokens whose KV state came from a saved cache.
    var reusedPromptTokenCount: Int = 0
    /// Prefill wall time spent outside the iterator's own prompt step: cache
    /// construction and the chunked prefill before the iterator starts.
    var extraPrefillSeconds: Double = 0
}

/// Presence is defined over this completion, unlike MLX's default recent
/// prompt-and-output window. Keep updates on MLX arrays so sampling does not
/// acquire a CPU/GPU synchronization on every generated token.
private struct CompletionPresencePenaltyProcessor: LogitProcessor {
    var otherPenalties: LogitProcessor?
    var presence: PresencePenaltyContext

    mutating func prompt(_ prompt: MLXArray) {
        otherPenalties?.prompt(prompt)
        presence.prompt(MLXArray.zeros([0], type: Int32.self))
    }

    func process(logits: MLXArray) -> MLXArray {
        presence.process(logits: otherPenalties?.process(logits: logits) ?? logits)
    }

    mutating func didSample(token: MLXArray) {
        otherPenalties?.didSample(token: token)
        presence.didSample(token: token)
    }
}

/// The vocabulary a JSON answer's commas and braces are read from. Qwen's
/// byte-level BPE spells ",", "{" and "}" as themselves in every token that
/// holds them, so one pass over the token strings classifies the vocabulary.
struct ObjectCommaVocabulary: @unchecked Sendable {
    /// Tokens that add a comma without opening or closing an object.
    let extending: MLXArray
    /// Per token ID: 1 when it adds such a comma.
    let addsComma: MLXArray
    /// Per token ID: true when it opens or closes an object.
    let bracesObject: MLXArray
    let count: Int

    init(tokens: [String?]) {
        var extending: [Int32] = [], adds: [Int32] = [], braces: [Bool] = []
        for (id, token) in tokens.enumerated() {
            let text = token ?? ""
            let brace = text.contains("{") || text.contains("}")
            let comma = !brace && text.contains(",")
            if comma { extending.append(Int32(id)) }
            adds.append(comma ? 1 : 0)
            braces.append(brace)
        }
        self.extending = MLXArray(extending)
        self.addsComma = MLXArray(adds)
        self.bracesObject = MLXArray(braces)
        self.count = tokens.count
    }
}

/// Closes a JSON object whose list the model keeps extending. The commas
/// since the last brace are counted on the GPU, with no per-token
/// synchronization; once `limit` stand in one object, every token that would
/// add another without closing a brace is ruled out, so the list closes.
struct ObjectCommaLimitProcessor: LogitProcessor {
    var other: LogitProcessor?
    let limit: Int32
    let vocabulary: ObjectCommaVocabulary
    private var commas = MLXArray([Int32(0)])

    init(other: LogitProcessor?, limit: Int, vocabulary: ObjectCommaVocabulary) {
        self.other = other
        self.limit = Int32(clamping: limit)
        self.vocabulary = vocabulary
    }

    mutating func prompt(_ prompt: MLXArray) {
        other?.prompt(prompt)
        commas = MLXArray([Int32(0)])
    }

    func process(logits: MLXArray) -> MLXArray {
        let logits = other?.process(logits: logits) ?? logits
        guard vocabulary.extending.size > 0 else { return logits }
        let indices = vocabulary.extending.asType(.uint32)[.newAxis, 0...]
        let selected = takeAlong(logits, indices, axis: -1)
        let closed = MLX.where(commas .>= limit, MLXArray(-Float.infinity).asType(selected.dtype), selected)
        return putAlong(logits, indices, values: closed, axis: -1)
    }

    mutating func didSample(token: MLXArray) {
        other?.didSample(token: token)
        guard vocabulary.count > 0 else { return }
        // A sampled ID beyond the classified vocabulary holds no comma.
        let id = MLX.minimum(token.reshaped([1]).asType(.int32), MLXArray(Int32(max(0, vocabulary.count - 1))))
        let known = token.reshaped([1]).asType(.int32) .< Int32(vocabulary.count)
        let adds = MLX.where(known, take(vocabulary.addsComma, id, axis: 0), MLXArray([Int32(0)]))
        let resets = known .&& take(vocabulary.bracesObject, id, axis: 0)
        commas = MLX.where(resets, MLXArray([Int32(0)]), commas + adds)
    }
}

// MARK: - HubApi Downloader Bridge

/// Bridges the swift-transformers `HubApi` to the `MLXLMCommon.Downloader` protocol
/// so that `LLMModelFactory` can download models from Hugging Face.
private struct HubDownloaderBridge: Downloader {
    private let hub: HubApi

    init(hub: HubApi = .shared) {
        self.hub = hub
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await curatedWeightSnapshot(
            hub: hub,
            id: id,
            revision: revision ?? "main",
            patterns: patterns,
            progressHandler: progressHandler
        )
    }
}

/// Progress-reporting downloader bridge. Wraps HubApi and forwards the
/// Foundation `Progress`'s `fractionCompleted` as a simple Double callback
/// so the UI doesn't need to know about Foundation.Progress.
private struct ProgressDownloaderBridge: Downloader {
    private let hub: HubApi
    private let onProgress: @Sendable (Double) -> Void

    init(hub: HubApi = .shared, onProgress: @Sendable @escaping (Double) -> Void) {
        self.hub = hub
        self.onProgress = onProgress
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let callback = onProgress
        return try await curatedWeightSnapshot(
            hub: hub,
            id: id,
            revision: revision ?? "main",
            patterns: patterns
        ) { progress in
            callback(progress.fractionCompleted)
            progressHandler(progress)
        }
    }
}

/// Snapshot wrapper shared by both downloader bridges. For weight downloads it
/// resolves the repo's shard index first, fetches exactly the indexed shard
/// files (plus the configuration/tokenizer patterns), and prunes unindexed
/// weight files already on disk. HubApi's `*.safetensors` glob crosses `/`
/// (`fnmatch` without `FNM_PATHNAME`), so without this, repos that ship
/// unindexed auxiliary weights — e.g. Qwen3.6 27B OptiQ's
/// `optiq/mtp.safetensors` — leak stray tensors into `loadWeights` and corrupt
/// the loaded model. See `ModelWeightSnapshotCuration`.
private func curatedWeightSnapshot(
    hub: HubApi,
    id: String,
    revision: String,
    patterns: [String],
    progressHandler: @Sendable @escaping (Progress) -> Void
) async throws -> URL {
    guard ModelWeightSnapshotCuration.containsWeightGlob(patterns) else {
        return try await hub.snapshot(
            from: id,
            revision: revision,
            matching: patterns,
            progressHandler: progressHandler
        )
    }

    // Metadata phase: configuration + tokenizer + shard-index JSONs. Tiny next
    // to the shards, so download progress is surfaced only for the weights
    // phase below. An empty glob list means "all files" to HubApi, so a
    // hypothetical weights-only pattern set must not collapse to [].
    var metadataPatterns = patterns.filter { $0 != ModelWeightSnapshotCuration.weightGlob }
    if metadataPatterns.isEmpty {
        metadataPatterns = [ModelWeightSnapshotCuration.indexFileName]
    }
    let metadataDirectory = try await hub.snapshot(
        from: id,
        revision: revision,
        matching: metadataPatterns
    )

    let indexedFiles: Set<String>?
    switch ModelWeightSnapshotCuration.resolveIndex(inSnapshot: metadataDirectory) {
    case .indexed(let files):
        indexedFiles = files
    case .missing:
        // Single-file repos have no shard index; the plain glob is correct.
        indexedFiles = nil
    case .unusable:
        mlxTrainingLogger.error(
            "Shard index unusable for \(id, privacy: .public); downloading by glob"
        )
        indexedFiles = nil
    }

    let weightPatterns = indexedFiles.map {
        ModelWeightSnapshotCuration.weightConstrainedPatterns(patterns, indexedFiles: $0)
    } ?? patterns

    let directory = try await hub.snapshot(
        from: id,
        revision: revision,
        matching: weightPatterns,
        progressHandler: progressHandler
    )

    if let indexedFiles {
        switch try ModelWeightSnapshotCuration.pruneUnindexedWeightFiles(
            inSnapshot: directory,
            indexedFiles: indexedFiles
        ) {
        case .pruned(let pruned):
            if !pruned.isEmpty {
                mlxTrainingLogger.notice(
                    "Pruned unindexed weight files from \(id, privacy: .public) count=\(pruned.count, privacy: .public)"
                )
            }
        case .skipped(let missingIndexedFiles):
            mlxTrainingLogger.error(
                "Prune skipped for \(id, privacy: .public): absentFileCount=\(missingIndexedFiles.count, privacy: .public)"
            )
        }
    }
    return directory
}

// MARK: - AutoTokenizer Loader Bridge

/// Bridges swift-transformers `AutoTokenizer` to the `MLXLMCommon.TokenizerLoader` protocol.
private struct AutoTokenizerLoaderBridge: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Self.loadCompatibleTokenizer(from: directory)
        return TokenizerBridge(upstream)
    }

    private static func loadCompatibleTokenizer(from directory: URL) async throws -> any Tokenizers.Tokenizer {
        let tokenizerConfigURL = directory.appendingPathComponent("tokenizer_config.json")
        let tokenizerDataURL = directory.appendingPathComponent("tokenizer.json")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: tokenizerConfigURL.path),
              fileManager.fileExists(atPath: tokenizerDataURL.path)
        else {
            return try await AutoTokenizer.from(modelFolder: directory)
        }

        let hubApi = HubApi.shared
        let tokenizerConfig = try hubApi.configuration(fileURL: tokenizerConfigURL)
        let tokenizerData = try hubApi.configuration(fileURL: tokenizerDataURL)
        return try AutoTokenizer.from(
            tokenizerConfig: MLXTokenizerCompatibility.swiftTransformersCompatibleConfig(
                tokenizerConfig,
                tokenizerData: tokenizerData
            ),
            tokenizerData: tokenizerData
        )
    }
}

enum MLXTokenizerCompatibility {
    static func swiftTransformersCompatibleConfig(_ config: Config, tokenizerData: Config) -> Config {
        let tokenizerClass = config.tokenizerClass.string()?.replacingOccurrences(of: "Fast", with: "")
        guard tokenizerClass == "TokenizersBackend",
              tokenizerData.model.type.string() == "BPE"
        else {
            return config
        }

        var values = config.get(or: [:])
        // Qwen3.5 model repos declare Hugging Face's newer shared
        // TokenizersBackend, but swift-transformers still dispatches through
        // older tokenizer_class names. The underlying tokenizer.json is a
        // standard Qwen BPE pipeline, so the Qwen2Tokenizer bridge is the
        // compatible in-memory spelling for this dependency version.
        values[BinaryDistinctString("tokenizer_class")] = Config("Qwen2Tokenizer")
        return Config(values)
    }
}

/// Bridges the swift-transformers `Tokenizer` to the `MLXLMCommon.Tokenizer` protocol.
/// Marked `@unchecked Sendable` because `Tokenizers.Tokenizer` is not `Sendable` in Swift 6,
/// but the underlying tokenizer state is immutable after creation.
private struct TokenizerBridge: @unchecked Sendable, MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        } catch Tokenizers.TokenizerError.chatTemplate(let reason) {
            // Map swift-transformers chat template errors to MLXLMCommon errors
            if reason.contains("chat template") {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

enum MLXModelContextConfiguration {
    private struct Configuration: Decodable {
        let maxPositionEmbeddings: Int?
        let modelType: String?
        let vocabularySize: Int?
        let textConfig: TextConfiguration?

        struct TextConfiguration: Decodable {
            let maxPositionEmbeddings: Int?
            let modelType: String?
            let vocabularySize: Int?
            private enum CodingKeys: String, CodingKey {
                case maxPositionEmbeddings = "max_position_embeddings"
                case modelType = "model_type"
                case vocabularySize = "vocab_size"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case maxPositionEmbeddings = "max_position_embeddings"
            case modelType = "model_type"
            case vocabularySize = "vocab_size"
            case textConfig = "text_config"
        }
    }

    /// The model's output vocabulary (its logits width), from the text
    /// configuration when the model has one.
    static func vocabularySize(in directory: URL) -> Int? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
              let size = configuration.textConfig?.vocabularySize ?? configuration.vocabularySize,
              size > 0 else { return nil }
        return size
    }

    static func maximumContextTokens(in directory: URL) -> Int? {
        let configurationURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configurationURL),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
              let maximumContextTokens = configuration.textConfig?.maxPositionEmbeddings ?? configuration.maxPositionEmbeddings,
              maximumContextTokens > 0
        else {
            return nil
        }
        return maximumContextTokens
    }

    /// Local snapshot folder names are not reliable model family identifiers.
    /// Preserve catalog generation labels where supplied; otherwise read the
    /// actual text architecture for bounded-reasoning framing and sampling.
    static func reasoningModelID(in directory: URL, requestedID: String?) -> String? {
        let normalized = requestedID?.lowercased() ?? ""
        if normalized.contains("qwen3.8") || normalized.contains("qwen3.6") { return requestedID }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data) else { return requestedID }
        let architecture = configuration.textConfig?.modelType ?? configuration.modelType ?? ""
        if architecture.hasPrefix("qwen3_5") { return "qwen3.5" }
        if architecture == "qwen3" || architecture == "qwen3_moe" { return "qwen3" }
        return requestedID
    }
}

// MARK: - MLXTrainingEngine

struct MLXRuntimeMemoryConfiguration: Equatable, Sendable {
    let memoryLimitBytes: Int
    let recyclableCacheLimitBytes: Int
    /// Pool for `.instructions` checkpoint states: a lane's static
    /// instructions, shared by every email.
    let promptPrefixCacheLimitBytes: Int
    let maximumPromptPrefixEntries: Int
    /// Pool for `.item` checkpoint states: one email's context, reused by
    /// later calls about it. Its own LRU, so per-email states never evict
    /// the shared instruction states.
    let itemCheckpointCacheLimitBytes: Int
    let maximumItemCheckpointEntries: Int
    let maximumPrefixTokenEntries: Int
    let maximumPrefixTokenCount: Int
    /// Bounds the indivisible optimizer step so an exclusive-residency helper
    /// can yield its model-memory turn without interrupting Adam state updates.
    let maximumTrainingBatchSize: Int
    let maximumTrainingSequenceTokens: Int

    /// Entry and byte limits of the pool a checkpoint state lives in.
    func checkpointPoolLimits(
        for reuse: PrefixCachedPrompt.Checkpoint.Reuse
    ) -> (maximumEntries: Int, maximumBytes: Int) {
        switch reuse {
        case .instructions:
            return (maximumPromptPrefixEntries, promptPrefixCacheLimitBytes)
        case .item:
            return (maximumItemCheckpointEntries, itemCheckpointCacheLimitBytes)
        }
    }

    /// Keys to evict from `pool`: LRU over that pool's entries only, so
    /// another pool's entries and operation-held entries are never evicted
    /// and never count against its limits.
    func checkpointVictims(
        in pool: PrefixCachedPrompt.Checkpoint.Reuse,
        entries: [(retention: PromptCheckpointRetention, entry: MLXCacheEvictionEntry)]
    ) -> [String] {
        let limits = checkpointPoolLimits(for: pool)
        return MLXCacheEvictionPolicy.keysToEvict(
            entries: entries.compactMap { $0.retention == .pool(pool) ? $0.entry : nil },
            maximumEntryCount: limits.maximumEntries,
            maximumCost: limits.maximumBytes
        )
    }
}

/// Where a saved prompt state counts against memory limits.
enum PromptCheckpointRetention: Equatable, Sendable {
    /// In its reuse pool's LRU, under that pool's entry and byte limits.
    case pool(PrefixCachedPrompt.Checkpoint.Reuse)
    /// Held outside both pools for one operation, which removes it when it
    /// ends. Never evicted and never counted, so it cannot push another
    /// caller's state out of a pool.
    case operation
}

struct MLXCacheEvictionEntry: Equatable, Sendable {
    let key: String
    let lastAccessedAt: Date
    let cost: Int
}

enum MLXCacheEvictionPolicy {
    /// Returns the oldest keys that must be removed to satisfy both limits.
    /// Equal timestamps use the stable cache key so eviction remains
    /// deterministic across dictionary iteration orders.
    static func keysToEvict(
        entries: [MLXCacheEvictionEntry],
        maximumEntryCount: Int,
        maximumCost: Int
    ) -> [String] {
        var remaining = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
        var remainingCost = remaining.values.reduce(0) { $0 + max(0, $1.cost) }
        var evicted: [String] = []
        let entryLimit = max(0, maximumEntryCount)
        let costLimit = max(0, maximumCost)

        while remaining.count > entryLimit || remainingCost > costLimit {
            guard let victim = remaining.values.min(by: { lhs, rhs in
                if lhs.lastAccessedAt == rhs.lastAccessedAt {
                    return lhs.key < rhs.key
                }
                return lhs.lastAccessedAt < rhs.lastAccessedAt
            }) else {
                break
            }
            remaining.removeValue(forKey: victim.key)
            remainingCost -= max(0, victim.cost)
            evicted.append(victim.key)
        }
        return evicted
    }
}

#if DEBUG
enum MLXTrainingDiagnosticsError: Error, Equatable {
    case nonFiniteValue(parameterName: String)
    case parameterSetMismatch
    case parameterShapeMismatch(parameterName: String)
    case invalidTrainingSequenceLength(Int)
}

struct MLXModelLoadDiagnostics: Sendable {
    let modelType: String
    let flattenedParameterCount: Int
    let hasVisionTowerParameters: Bool
    let hasModelVisualParameters: Bool
}

struct MLXTrainingStepDiagnostics: Sendable {
    let inputSequenceLength: Int
    let batchSize: Int
    let adaptedParameterNamesByLayer: [String: [String]]
    let gradientNormsByLayer: [String: Double]
    let parameterDeltasByLayer: [String: Double]
    let preStepMemory: Memory.Snapshot
    let postStepMemory: Memory.Snapshot
    let effectivePeakMemoryBytes: Int
    let durationSeconds: Double
}
#endif

final class MLXGenerationCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var epoch: UInt64 = 0

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        epoch &+= 1
        lock.unlock()
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        cancelled = false
    }

    func currentEpoch() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }

    func wasCancelled(after observedEpoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return epoch != observedEpoch
    }
}

/// Invalidates async model loads independently of generation cancellation.
/// Task cancellation is cooperative and MLX model construction may not return
/// immediately, so a generation token is the final guard against a stale load
/// installing weights after a resource-pressure unload.
final class MLXModelLoadGenerationState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func beginLoad() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
    }

    func isCurrent(_ observedGeneration: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == observedGeneration
    }
}

/// The primary training engine for Ohia. Uses mlx-swift-lm to:
/// 1. Download open-source models from Hugging Face
/// 2. Run LoRA fine-tuning on the user's sent email
/// 3. Generate personalized draft replies
///
/// All protocol methods are synchronous (per `TrainingEngine`), so async mlx-swift-lm
/// calls are bridged with a semaphore.
public final class MLXTrainingEngine: @unchecked Sendable,
    PersonalizationScopedCancellablePrefixCachedGenerating,
    SamplingScopedPrefixCachedGenerating,
    DetailedSamplingScopedPrefixCachedGenerating,
    TrainingFrontierStashing,
    ConversationPromptTokenCounting,
    ConversationalGenerating,
    BoundedReasoningGenerating, CancellableGenerationOperation
{

    public typealias GenerationPromptUsageReporter = @Sendable (
        WorkerPromptUsageSnapshot
    ) -> Void

    // MARK: - TrainingEngine conformance

    private var _isModelLoaded = false
    private var _isAdapterLoaded = false
    private var _totalSteps = 0
    /// Loaded file digest or a digest of the current in-memory parameters.
    /// A weight mutation invalidates it; generation hashes lazily under the
    /// operation lock, avoiding a GPU-to-CPU copy on every training step.
    private var adapterContinuationRevision: String?
    private var _maximumContextTokens: Int?
    private var generationPromptUsageReporter: GenerationPromptUsageReporter?

    public var isModelLoaded: Bool { withOperationLock { _isModelLoaded } }
    public var isAdapterLoaded: Bool { withOperationLock { _isAdapterLoaded } }
    public var totalSteps: Int { withOperationLock { _totalSteps } }
    public var maximumContextTokens: Int? { withOperationLock { _maximumContextTokens } }
    /// The task this engine trains and whose checkpoints it may load. Fixed
    /// for the engine's lifetime so a candidate for a new task can never be
    /// mistaken for a production adapter.
    public let task: TrainingTaskIdentity

    public var maximumTrainingBatchSize: Int {
        Self.effectiveTrainingBatchSize(task: task, runtime: runtimeMemoryConfiguration)
    }

    /// Longest complete framed example this engine trains or evaluates.
    public var trainingSequenceTokenLimit: Int {
        Self.effectiveTrainingSequenceTokens(task: task, runtime: runtimeMemoryConfiguration)
    }

    /// A task may need longer examples than the memory tier's default, up to
    /// the tier's per-step token budget (batch × sequence). A task within the
    /// tier's default keeps the tier's batch; a longer one trains one example
    /// per step, because activation memory grows with the square of the
    /// sequence and the tier's budget was measured at its default length.
    static func effectiveTrainingSequenceTokens(
        task: TrainingTaskIdentity, runtime: MLXRuntimeMemoryConfiguration
    ) -> Int {
        max(2, min(task.maximumSequenceTokens,
                   runtime.maximumTrainingSequenceTokens * runtime.maximumTrainingBatchSize))
    }

    static func effectiveTrainingBatchSize(
        task: TrainingTaskIdentity, runtime: MLXRuntimeMemoryConfiguration
    ) -> Int {
        let tokens = effectiveTrainingSequenceTokens(task: task, runtime: runtime)
        return tokens > runtime.maximumTrainingSequenceTokens ? 1 : max(1, runtime.maximumTrainingBatchSize)
    }

    /// Without a loaded model the counts below fall back to Unicode scalars.
    public var isTokenizerLoaded: Bool {
        withOperationLock { modelContext?.tokenizer != nil }
    }

    public func promptTokenCount(_ text: String) -> Int {
        withOperationLock {
            guard let tokenizer = modelContext?.tokenizer else {
                return text.unicodeScalars.count
            }
            return tokenizer.encode(text: text, addSpecialTokens: false).count
        }
    }

    public func generationPromptTokenCount(_ text: String) -> Int {
        withOperationLock {
            let framed = QwenChatTemplate.turnWrapper(for: modelId)?.framed(text)
                ?? text
            guard let tokenizer = modelContext?.tokenizer else {
                return framed.unicodeScalars.count
            }
            // Both normal generation (`ModelContainer.encode`) and the
            // prefix-cache path call the tokenizer's default encode entry
            // point, which includes its configured special-token postprocess.
            return tokenizer.encode(text: framed, addSpecialTokens: true).count
        }
    }

    public func generationPromptTokenCount(
        _ conversation: GenerationConversation,
        personalization: GenerationPersonalizationScope
    ) -> Int {
        withOperationLock {
            let eligible = conversation.keepingReasoning(
                matching: continuationFingerprint(for: personalization)
            )
            let framed = QwenChatTemplate.framedConversation(eligible, for: modelId)
                ?? QwenChatTemplate.turnWrapper(for: modelId)?.framed(eligible.fallbackPrompt)
                ?? eligible.fallbackPrompt
            guard let tokenizer = modelContext?.tokenizer else {
                return framed.unicodeScalars.count
            }
            return tokenizer.encode(text: framed, addSpecialTokens: true).count
        }
    }

    /// Installs the worker-runtime observer for the prompt currently entering
    /// the loaded model. The callback must return promptly; generation invokes
    /// it while holding the engine's operation lock so the reported tokenizer
    /// and model context are the exact ones used by that decode.
    public func setGenerationPromptUsageReporter(
        _ reporter: GenerationPromptUsageReporter?
    ) {
        withOperationLock {
            generationPromptUsageReporter = reporter
        }
    }

    public var checkpointCompatibility: TrainingCheckpointCompatibility? {
        withOperationLock {
            guard let modelId else { return nil }
            return TrainingCheckpointCompatibility(
                baseModelID: modelId,
                promptFormatVersion: task.promptFormatVersion,
                chatTemplateVersion: QwenChatTemplate.trainingTemplateVersion,
                loraLayerCount: Self.loraLayerCount,
                loraRank: Self.loraRank,
                loraScale: Self.loraScale,
                taskIdentifier: task.identifier
            )
        }
    }

    // MARK: - Private state

    /// The loaded model container providing thread-safe access to model + tokenizer.
    private var modelContainer: ModelContainer?

    /// The loaded model context (model, tokenizer, processor, configuration).
    /// Retained so we can access the raw model for LoRA training operations.
    private var modelContext: ModelContext?

    /// The Hugging Face model ID that was loaded.
    private var modelId: String?

    /// Current LoRA configuration used for training.
    private var loraConfiguration: LoRAConfiguration?

    /// Evaluated adapter weights retained while the live model is in base
    /// mode. `isAdapterLoaded` means a usable adapter is available; this flag
    /// records whether its layers are currently installed in the model.
    private var adapterSnapshot: LoRAContainer?
    private var isAdapterInstalled = false

    /// Running loss for reporting.
    private var currentLoss: Double = 0.0

    /// Named, bias-corrected Adam state for the active training session.
    /// CheckpointManager persists and restores it with each resumable adapter.
    private var trainingOptimizer: CheckpointableAdam?

    /// An unjudged training frontier set aside while the promoted adapter
    /// serves drafts. Holds evaluated arrays only; released with the model.
    private struct StashedFrontier {
        let marker: TrainingFrontierMarker
        let adapter: LoRAContainer
        let optimizer: CheckpointableAdam?
        let continuationRevision: String?
        let totalSteps: Int
    }
    private var stashedFrontier: StashedFrontier?

    #if DEBUG
    private var trainingStepDiagnosticsObserver: (@Sendable (MLXTrainingStepDiagnostics) -> Void)?
    private var modelLoadDiagnosticsObserver: (@Sendable (MLXModelLoadDiagnostics) -> Void)?
    private var validationTrainingSequenceTokenLimit: Int?
    #endif

    /// Serializes every operation that reads or mutates the live model. The
    /// separate cancellation lock remains callable while a long operation is
    /// in flight, so generation/training can still be interrupted.
    private let operationLock = NSRecursiveLock()

    private struct PromptPrefixCacheEntry {
        let tokenCount: Int
        let cache: [KVCache]
        /// The memory pool this state counts against, or none while one
        /// operation holds it.
        let retention: PromptCheckpointRetention
        let builtAt: Date
        let buildDuration: TimeInterval
        let estimatedBytes: Int
        /// Identity of the weights this KV state was built on
        /// (`PromptCacheWeights.identity`). Filtering on this field, not on
        /// the key text, decides what survives an adapter change.
        let weightIdentity: String
        var hitCount: Int
        var lastAccessedAt: Date
    }

    private struct PromptPrefixTokenCacheEntry {
        let tokens: [Int]
        let builtAt: Date
        var hitCount: Int
        var lastAccessedAt: Date
    }

    /// Saved prompt states at checkpoint boundaries, keyed by
    /// `PromptCacheWeights.key` (model, prompt family, boundary token count
    /// and fingerprint, weight identity). Both pools share this dictionary;
    /// each entry's `pool` decides which LRU and limits it counts against.
    /// Each generation receives a deep copy so a saved state is never
    /// mutated by the text after it or the decode loop.
    private var promptPrefixCache: [String: PromptPrefixCacheEntry] = [:]
    /// Tokens of `.instructions` boundaries' leading text, which recurs
    /// across emails.
    private var promptPrefixTokenCache: [String: PromptPrefixTokenCacheEntry] = [:]

    /// Bumped at every point the LoRA parameters change (load, restore,
    /// reset, training step, fresh model). Part of the identity of any KV
    /// state built with the adapter installed.
    private var adapterWeightsGeneration: UInt64 = 0

    private let generationCancellationState = MLXGenerationCancellationState()
    private let modelLoadGenerationState = MLXModelLoadGenerationState()
    private let hubApi: HubApi
    private let modelDownloadBaseDirectory: URL
    private let runtimeMemoryConfiguration: MLXRuntimeMemoryConfiguration

    public var isCancelled: Bool {
        generationCancellationState.isCancelled
    }

    public func cancel() {
        generationCancellationState.cancel()
        Self.containMLXErrors(operation: "cancel generation") { error in
            // mlx-swift 0.31.3 documents this as deallocating recyclable buffers;
            // active arrays and model weights remain intact.
            Memory.clearCache()
            try error.check()
        }
    }

    public func resetCancellation() {
        generationCancellationState.reset()
    }

    public func unloadModel() {
        modelLoadGenerationState.invalidate()
        Self.containMLXErrors(operation: "unload model") { error in
            withOperationLock {
                cancel()
                modelContainer = nil
                modelContext = nil
                modelId = nil
                _maximumContextTokens = nil
                loraConfiguration = nil
                adapterSnapshot = nil
                isAdapterInstalled = false
                trainingOptimizer = nil
                stashedFrontier = nil
                clearPromptCaches()
                _isModelLoaded = false
                _isAdapterLoaded = false
                _totalSteps = 0
                adapterContinuationRevision = nil
                currentLoss = 0
            }
            Memory.clearCache()
            try error.check()
        }
    }

    /// Drops reusable prompt/KV state and MLX's recyclable buffer pool after
    /// cooperative cancellation has stopped the current decode.
    public func releaseReusableMemory() {
        Self.containMLXErrors(operation: "release reusable memory") { error in
            Memory.clearCache()
            withOperationLock {
                clearPromptCaches()
            }
            Memory.clearCache()
            try error.check()
        }
    }

    /// Drops every prompt KV state (both pools) and the token cache. Used
    /// where the base weights or the model change, or when memory must be
    /// freed.
    private func clearPromptCaches() {
        promptPrefixCache.removeAll()
        promptPrefixTokenCache.removeAll()
    }

    /// Call BEFORE any mutation of the adapter's parameters or installation
    /// state, so a throw part-way through cannot leave old adapter entries
    /// reachable over changed weights. Advance its generation and drop
    /// only the KV state built with an adapter, in both pools. Base-weight KV
    /// state and the weight-independent token cache stay valid.
    private func invalidateAdapterPromptCaches() {
        PromptCacheWeights.invalidateAdapterEntries(
            generation: &adapterWeightsGeneration,
            entries: &promptPrefixCache,
            weightIdentity: \.weightIdentity
        )
    }

    /// Identity of the weights a generation is running on right now.
    private func currentWeightIdentity() -> String {
        PromptCacheWeights.identity(
            adapterInstalled: isAdapterInstalled,
            adapterGeneration: adapterWeightsGeneration
        )
    }

    private func trimPromptPrefixTokenCacheIfNeeded() {
        let configuration = runtimeMemoryConfiguration
        let victims = MLXCacheEvictionPolicy.keysToEvict(
            entries: promptPrefixTokenCache.map { key, entry in
                MLXCacheEvictionEntry(
                    key: key,
                    lastAccessedAt: entry.lastAccessedAt,
                    cost: entry.tokens.count
                )
            },
            maximumEntryCount: configuration.maximumPrefixTokenEntries,
            maximumCost: configuration.maximumPrefixTokenCount
        )
        for victim in victims {
            promptPrefixTokenCache.removeValue(forKey: victim)
        }
    }

    private func trimPromptPrefixCacheIfNeeded(pool: PrefixCachedPrompt.Checkpoint.Reuse) {
        let victims = runtimeMemoryConfiguration.checkpointVictims(
            in: pool,
            entries: promptPrefixCache.map { key, entry in
                (entry.retention, MLXCacheEvictionEntry(
                    key: key,
                    lastAccessedAt: entry.lastAccessedAt,
                    cost: entry.estimatedBytes
                ))
            }
        )
        for victim in victims {
            promptPrefixCache.removeValue(forKey: victim)
        }
        if victims.isEmpty == false {
            Memory.clearCache()
        }
    }

    // MARK: - Init

    public init(modelDownloadBaseDirectory: URL? = nil, task: TrainingTaskIdentity = .production) {
        self.task = task
        self.modelDownloadBaseDirectory = modelDownloadBaseDirectory
            ?? GenerationModelStorage.legacyDocumentsDownloadBaseDirectory()
        self.hubApi = modelDownloadBaseDirectory.map { HubApi(downloadBase: $0) } ?? .shared
        self.runtimeMemoryConfiguration = Self.runtimeMemoryConfiguration(
            forPhysicalMemoryBytes: Int(clamping: ProcessInfo.processInfo.physicalMemory)
        )
    }

    static func runtimeMemoryConfiguration(
        forPhysicalMemoryBytes physicalMemoryBytes: Int
    ) -> MLXRuntimeMemoryConfiguration {
        let gibibyte = 1_073_741_824
        let physicalMemory = max(4 * gibibyte, physicalMemoryBytes)
        let memoryLimit = physicalMemory / 4 * 3

        switch physicalMemory {
        case ...(8 * gibibyte):
            return MLXRuntimeMemoryConfiguration(
                memoryLimitBytes: memoryLimit,
                recyclableCacheLimitBytes: 64 * 1_048_576,
                promptPrefixCacheLimitBytes: 128 * 1_048_576,
                maximumPromptPrefixEntries: 2,
                itemCheckpointCacheLimitBytes: 256 * 1_048_576,
                maximumItemCheckpointEntries: 3,
                maximumPrefixTokenEntries: 8,
                maximumPrefixTokenCount: 4_096,
                maximumTrainingBatchSize: 1,
                maximumTrainingSequenceTokens: 1_024
            )
        case ...(16 * gibibyte):
            return MLXRuntimeMemoryConfiguration(
                memoryLimitBytes: memoryLimit,
                recyclableCacheLimitBytes: 128 * 1_048_576,
                promptPrefixCacheLimitBytes: 256 * 1_048_576,
                maximumPromptPrefixEntries: 4,
                itemCheckpointCacheLimitBytes: 512 * 1_048_576,
                maximumItemCheckpointEntries: 3,
                maximumPrefixTokenEntries: 16,
                maximumPrefixTokenCount: 8_192,
                maximumTrainingBatchSize: 1,
                maximumTrainingSequenceTokens: 1_024
            )
        case ...(32 * gibibyte):
            return MLXRuntimeMemoryConfiguration(
                memoryLimitBytes: memoryLimit,
                recyclableCacheLimitBytes: 256 * 1_048_576,
                promptPrefixCacheLimitBytes: 512 * 1_048_576,
                maximumPromptPrefixEntries: 8,
                itemCheckpointCacheLimitBytes: 1_024 * 1_048_576,
                maximumItemCheckpointEntries: 6,
                maximumPrefixTokenEntries: 24,
                maximumPrefixTokenCount: 16_384,
                maximumTrainingBatchSize: 4,
                maximumTrainingSequenceTokens: 2_048
            )
        case ...(64 * gibibyte):
            return MLXRuntimeMemoryConfiguration(
                memoryLimitBytes: memoryLimit,
                recyclableCacheLimitBytes: 512 * 1_048_576,
                promptPrefixCacheLimitBytes: 2_048 * 1_048_576,
                maximumPromptPrefixEntries: 16,
                itemCheckpointCacheLimitBytes: 3_072 * 1_048_576,
                maximumItemCheckpointEntries: 9,
                maximumPrefixTokenEntries: 32,
                maximumPrefixTokenCount: 32_768,
                maximumTrainingBatchSize: 4,
                maximumTrainingSequenceTokens: 2_048
            )
        default:
            return MLXRuntimeMemoryConfiguration(
                memoryLimitBytes: memoryLimit,
                recyclableCacheLimitBytes: 1_024 * 1_048_576,
                promptPrefixCacheLimitBytes: 4_096 * 1_048_576,
                maximumPromptPrefixEntries: 24,
                itemCheckpointCacheLimitBytes: 6_144 * 1_048_576,
                maximumItemCheckpointEntries: 18,
                maximumPrefixTokenEntries: 48,
                maximumPrefixTokenCount: 65_536,
                maximumTrainingBatchSize: 4,
                maximumTrainingSequenceTokens: 2_048
            )
        }
    }

    private func applyRuntimeMemoryConfiguration() {
        Memory.memoryLimit = min(Memory.memoryLimit, runtimeMemoryConfiguration.memoryLimitBytes)
        Memory.cacheLimit = runtimeMemoryConfiguration.recyclableCacheLimitBytes
    }

    static func prepareForInference(_ module: Module) {
        module.train(false)
    }

    static func withTrainingMode<T>(
        _ module: Module,
        operation: () throws -> T
    ) rethrows -> T {
        module.train(true)
        defer { module.train(false) }
        return try operation()
    }

    static func modelConfiguration(for identifier: String) -> ModelConfiguration {
        var isDirectory: ObjCBool = false
        if (identifier as NSString).isAbsolutePath,
           FileManager.default.fileExists(atPath: identifier, isDirectory: &isDirectory),
           isDirectory.boolValue
        {
            return ModelConfiguration(
                directory: URL(fileURLWithPath: identifier, isDirectory: true)
            )
        }
        let revision = ModelManager.allModels.first {
            $0.modelId == identifier
        }?.revision ?? "main"
        return ModelConfiguration(id: identifier, revision: revision)
    }

    static func validateCatalogSnapshot(
        modelID: String,
        downloadBaseDirectory: URL
    ) throws {
        guard let model = ModelManager.allModels.first(where: {
            $0.modelId == modelID
        }),
              model.revision != "main"
        else {
            return
        }
        guard GenerationModelStorage.isModelDownloaded(
            downloadBaseDirectory: downloadBaseDirectory,
            modelID: modelID
        ) else {
            throw TrainingEngineError.modelUnavailable(
                "Cached \(model.displayName) does not match validated revision "
                    + "\(model.revision). Reconnect and prepare the model again."
            )
        }
    }

    #if DEBUG
    static func adaptedParameterNamesByDecoderLayer(
        _ namedArrays: [(String, MLXArray)]
    ) -> [String: [String]] {
        Dictionary(grouping: namedArrays.map(\.0), by: decoderLayerKey)
            .mapValues { $0.sorted() }
    }

    static func modelLoadDiagnostics(for module: Module) -> MLXModelLoadDiagnostics {
        let flattenedParameters = module.parameters().flattened()
        let parameterNames = flattenedParameters.map(\.0)
        return MLXModelLoadDiagnostics(
            modelType: String(reflecting: type(of: module)),
            flattenedParameterCount: flattenedParameters.count,
            hasVisionTowerParameters: parameterNames.contains {
                $0 == "vision_tower"
                    || $0.hasPrefix("vision_tower.")
                    || $0.contains(".vision_tower.")
            },
            hasModelVisualParameters: parameterNames.contains {
                $0 == "model.visual"
                    || $0.hasPrefix("model.visual.")
                    || $0.contains(".model.visual.")
            }
        )
    }

    static func l2NormsByDecoderLayer(
        _ namedArrays: [(String, MLXArray)],
        stream: StreamOrDevice = .default
    ) throws -> [String: Double] {
        let squaredSums = namedArrays.map { name, array in
            (
                name,
                array.asType(.float32, stream: stream)
                    .square(stream: stream)
                    .sum(stream: stream)
            )
        }
        eval(squaredSums.map(\.1))

        var squaredTotals: [String: Double] = [:]
        for (name, squaredSum) in squaredSums {
            let value = Double(squaredSum.item(Float.self))
            guard value.isFinite else {
                throw MLXTrainingDiagnosticsError.nonFiniteValue(parameterName: name)
            }
            squaredTotals[decoderLayerKey(name), default: 0] += value
        }

        return try squaredTotals.mapValues { value in
            guard value.isFinite else {
                throw MLXTrainingDiagnosticsError.nonFiniteValue(
                    parameterName: "decoder-layer-total"
                )
            }
            return sqrt(max(0, value))
        }
    }

    static func evaluatedDiagnosticSnapshot(
        _ namedArrays: [(String, MLXArray)],
        stream: StreamOrDevice = .default
    ) -> [(String, MLXArray)] {
        let snapshot = namedArrays.map { name, array in
            (
                name,
                add(array, MLXArray.zeros(like: array, stream: stream), stream: stream)
            )
        }
        eval(snapshot.map(\.1))
        return snapshot
    }

    static func l2ParameterDeltasByDecoderLayer(
        before: [(String, MLXArray)],
        after: [(String, MLXArray)],
        stream: StreamOrDevice = .default
    ) throws -> [String: Double] {
        let beforeNames = before.map(\.0)
        let afterNames = after.map(\.0)
        guard Set(beforeNames).count == beforeNames.count,
              Set(afterNames).count == afterNames.count,
              Set(beforeNames) == Set(afterNames)
        else {
            throw MLXTrainingDiagnosticsError.parameterSetMismatch
        }

        let afterByName = Dictionary(uniqueKeysWithValues: after)
        let deltas = try before.map { name, beforeArray in
            guard let afterArray = afterByName[name] else {
                throw MLXTrainingDiagnosticsError.parameterSetMismatch
            }
            guard beforeArray.shape == afterArray.shape else {
                throw MLXTrainingDiagnosticsError.parameterShapeMismatch(parameterName: name)
            }
            return (name, subtract(afterArray, beforeArray, stream: stream))
        }
        return try l2NormsByDecoderLayer(deltas, stream: stream)
    }

    static func resetValidationRandomSeed(_ seed: UInt64) {
        MLXRandom.seed(seed)
    }

    static func validatedTrainingSequenceTokenLimit(
        requested: Int?,
        runtimeMaximum: Int
    ) throws -> Int {
        guard let requested else { return runtimeMaximum }
        guard (2...runtimeMaximum).contains(requested) else {
            throw MLXTrainingDiagnosticsError.invalidTrainingSequenceLength(requested)
        }
        return requested
    }

    private static func decoderLayerKey(_ parameterName: String) -> String {
        let components = parameterName.split(separator: ".")
        guard let layersIndex = components.firstIndex(of: "layers"),
              components.indices.contains(layersIndex + 1),
              Int(components[layersIndex + 1]) != nil
        else {
            return "unscoped"
        }
        return components.prefix(through: layersIndex + 1).joined(separator: ".")
    }

    func setTrainingStepDiagnosticsObserver(
        _ observer: (@Sendable (MLXTrainingStepDiagnostics) -> Void)?
    ) {
        withOperationLock {
            trainingStepDiagnosticsObserver = observer
        }
    }

    func setModelLoadDiagnosticsObserver(
        _ observer: (@Sendable (MLXModelLoadDiagnostics) -> Void)?
    ) {
        withOperationLock {
            modelLoadDiagnosticsObserver = observer
        }
    }

    func setValidationTrainingSequenceTokenLimit(_ maximumTokens: Int?) throws {
        let validated = try Self.validatedTrainingSequenceTokenLimit(
            requested: maximumTokens,
            runtimeMaximum: trainingSequenceTokenLimit
        )
        withOperationLock {
            validationTrainingSequenceTokenLimit = maximumTokens == nil ? nil : validated
        }
    }

    private func publishModelLoadDiagnostics(for module: Module) {
        let observer = withOperationLock { modelLoadDiagnosticsObserver }
        observer?(Self.modelLoadDiagnostics(for: module))
    }
    #endif

    // MARK: - Model Loading

    /// Download model artifacts into the configured Hugging Face cache without
    /// instantiating the model in MLX memory.
    public func downloadModelAsync(
        modelId: String,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        let configuration = Self.modelConfiguration(for: modelId)
        let downloader = ProgressDownloaderBridge(hub: hubApi, onProgress: progressHandler)
        _ = try await resolve(
            configuration: configuration,
            from: downloader,
            useLatest: false,
            progressHandler: { _ in }
        )
        try Self.validateCatalogSnapshot(
            modelID: modelId,
            downloadBaseDirectory: modelDownloadBaseDirectory
        )
        progressHandler(1.0)
    }

    public func loadModel(path: String) throws {
        let resolvedId: String
        if path.isEmpty || path == "default" {
            resolvedId = ModelManager.recommendModelForCurrentHardware().modelId
        } else {
            resolvedId = path
        }

        try Self.checkedMLXOperation(failure: { message in
            .loadFailed("Failed to load model '\(resolvedId)': \(message)")
        }) { error in
            applyRuntimeMemoryConfiguration()
            try withOperationLock {
            let hubApi = self.hubApi
            let result = Self.runAsync {
                try await withError { error in
                    let configuration = Self.modelConfiguration(for: resolvedId)
                    let downloader = HubDownloaderBridge(hub: hubApi)
                    let tokenizerLoader = AutoTokenizerLoaderBridge()
                    let context = try await LLMModelFactory.shared.load(
                        from: downloader,
                        using: tokenizerLoader,
                        configuration: configuration
                    )
                    try error.check()
                    return context
                }
            }
            let context = try result.get()
            try Self.validateCatalogSnapshot(
                modelID: resolvedId,
                downloadBaseDirectory: modelDownloadBaseDirectory
            )
            let maximumContextTokens = Self.maximumContextTokens(for: context)
            Self.prepareForInference(context.model as Module)
            #if DEBUG
            publishModelLoadDiagnostics(for: context.model as Module)
            #endif
            let container = ModelContainer(context: context)
            try warmUpLoadedModel(container: container)
            try error.check()

            self.modelContext = context
            self.modelContainer = container
            self.modelId = resolvedId
            self._maximumContextTokens = maximumContextTokens
            self.resetAdapterStateForFreshModel()
            try error.check()
            self._isModelLoaded = true
            }
        }
    }

    /// Async load with progress reporting. Downloads the model from Hugging Face
    /// (or uses the cache if already present), then loads it into MLX.
    ///
    /// - Parameter modelId: Hugging Face model ID (e.g. "mlx-community/Qwen3.5-9B-OptiQ-4bit")
    /// - Parameter progressHandler: Receives fraction completed (0.0...1.0) during download.
    ///   Called with 1.0 when download finishes and MLX loading begins.
    public func loadModelAsync(
        modelId: String,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        try await Self.checkedMLXAsyncOperation(failure: { message in
            .loadFailed("Failed to load model '\(modelId)': \(message)")
        }) { error in
            applyRuntimeMemoryConfiguration()
            let loadGeneration = modelLoadGenerationState.beginLoad()
            let configuration = Self.modelConfiguration(for: modelId)
            let downloader = ProgressDownloaderBridge(hub: hubApi, onProgress: progressHandler)
            let tokenizerLoader = AutoTokenizerLoaderBridge()

            let context = try await LLMModelFactory.shared.load(
                from: downloader,
                using: tokenizerLoader,
                configuration: configuration
            )
            try error.check()
            try Self.validateCatalogSnapshot(
                modelID: modelId,
                downloadBaseDirectory: modelDownloadBaseDirectory
            )
            let maximumContextTokens = Self.maximumContextTokens(for: context)

            try Task.checkCancellation()
            guard modelLoadGenerationState.isCurrent(loadGeneration) else {
                throw CancellationError()
            }
            Self.prepareForInference(context.model as Module)
            #if DEBUG
            publishModelLoadDiagnostics(for: context.model as Module)
            #endif
            let loadedContainer = ModelContainer(context: context)
            try await warmUpLoadedModelAsync(container: loadedContainer)
            try error.check()
            try Task.checkCancellation()
            guard modelLoadGenerationState.isCurrent(loadGeneration) else {
                throw CancellationError()
            }
            try installLoadedModel(
                context: context,
                container: loadedContainer,
                modelID: modelId,
                maximumContextTokens: maximumContextTokens,
                loadGeneration: loadGeneration
            )
            try error.check()
            progressHandler(1.0)
        }
    }

    private func installLoadedModel(
        context: ModelContext,
        container: ModelContainer,
        modelID: String,
        maximumContextTokens: Int?,
        loadGeneration: UInt64
    ) throws {
        try withOperationLock {
            guard modelLoadGenerationState.isCurrent(loadGeneration) else {
                throw CancellationError()
            }
            self.modelContext = context
            self.modelContainer = container
            self.modelId = modelID
            self._maximumContextTokens = maximumContextTokens
            self.resetAdapterStateForFreshModel()
            self._isModelLoaded = true
        }
    }

    private func resetAdapterStateForFreshModel() {
        loraConfiguration = nil
        adapterSnapshot = nil
        isAdapterInstalled = false
        trainingOptimizer = nil
        stashedFrontier = nil
        _isAdapterLoaded = false
        _totalSteps = 0
        adapterContinuationRevision = nil
        currentLoss = 0
        adapterWeightsGeneration &+= 1
        clearPromptCaches()
    }

    private static func maximumContextTokens(for context: ModelContext) -> Int? {
        guard case let .directory(directory) = context.configuration.id else {
            return nil
        }
        return MLXModelContextConfiguration.maximumContextTokens(in: directory)
    }

    private func warmUpLoadedModel(container: ModelContainer) throws {
        let result = Self.runAsync {
            try await self.warmUpLoadedModelAsync(container: container)
        }
        try result.get()
    }

    private func warmUpLoadedModelAsync(container: ModelContainer) async throws {
        let start = Date()
        do {
            try await withError { error in
                try Task.checkCancellation()
                try await container.perform { context in
                    let tokenIDs = context.tokenizer.encode(text: "a")
                    guard !tokenIDs.isEmpty else { return }
                    let input = LMInput(tokens: MLXArray(tokenIDs))
                    let parameters = GenerateParameters(maxTokens: 1, temperature: 0.1)
                    let stream = try MLXLMCommon.generate(
                        input: input,
                        parameters: parameters,
                        context: context
                    )
                    for await generation in stream {
                        try Task.checkCancellation()
                        if generation.chunk != nil { break }
                    }
                    try error.check()
                }
                try error.check()
                try Task.checkCancellation()
            }
            mlxTrainingLogger.info(
                "qwen warmup completed ms=\(Self.elapsedMilliseconds(since: start), privacy: .public)"
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            mlxTrainingLogger.warning(
                "qwen warmup skipped ms=\(Self.elapsedMilliseconds(since: start), privacy: .public) error=\(String(reflecting: type(of: error)), privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Training

    public func beginTrainingSession(learningRate: Double) throws {
        try Self.checkedMLXOperation(failure: { message in
            .trainingFailed("Failed to begin MLX training session: \(message)")
        }) { error in
            try withOperationLock {
                guard _isModelLoaded else { throw TrainingEngineError.modelNotLoaded }
                if let trainingOptimizer {
                    trainingOptimizer.learningRate = Float(learningRate)
                } else {
                    trainingOptimizer = CheckpointableAdam(
                        learningRate: Float(learningRate)
                    )
                }
                try error.check()
            }
        }
    }

    public func endTrainingSession() {
        Self.containMLXErrors(operation: "end training session") { error in
            try withOperationLock {
                trainingOptimizer = nil
                if let model = modelContext?.model {
                    try setModelPersonalization(.base, model: model, error: error)
                }
                try error.check()
            }
        }
    }

    public func trainStep(
        examples: [TrainingExample], learningRate: Double
    ) throws -> TrainingStepResult {
        try Self.checkedMLXOperation(failure: { message in
            .trainingFailed("MLX optimizer step failed: \(message)")
        }) { error in
            try withOperationLock {
            guard _isModelLoaded, let context = modelContext else {
                throw TrainingEngineError.modelNotLoaded
            }
            guard !examples.isEmpty, examples.count <= maximumTrainingBatchSize else {
                throw TrainingEngineError.trainingFailed(
                    "Expected 1...\(maximumTrainingBatchSize) examples for one optimizer update; received \(examples.count)."
                )
            }

            let start = Date()
            let model = context.model
            let tokenizer = context.tokenizer

            try setModelPersonalization(.personalized, model: model, error: error)
            try error.check()

        // Apply LoRA adapters if none have been created or loaded.
            if loraConfiguration == nil {
                let config = Self.defaultLoRAConfiguration
                invalidateAdapterPromptCaches()
                _ = try LoRAContainer.from(model: model, configuration: config)
                try error.check()
                loraConfiguration = config
                isAdapterInstalled = true
                _isAdapterLoaded = true
            }

            guard model.trainableParameters().flattened().isEmpty == false else {
                throw TrainingEngineError.trainingFailed("No trainable LoRA parameters are active.")
            }

        // Format examples as complete ChatML turns matching the inference framing used in
        // `generate`, so the LoRA adapter is conditioned on the same token distribution it
        // will be invoked with at draft time. Non-ChatML model families fall back to the
        // prior raw `prompt\ncompletion` concatenation via `framedTrainingExample`.
            let batch = try Self.makeCompletionOnlyBatch(
                examples: examples,
                tokenizer: tokenizer,
                modelID: modelId,
                maximumTokens: {
                    #if DEBUG
                    return try Self.validatedTrainingSequenceTokenLimit(
                        requested: validationTrainingSequenceTokenLimit,
                        runtimeMaximum: trainingSequenceTokenLimit
                    )
                    #else
                    return trainingSequenceTokenLimit
                    #endif
                }()
            )
            let optimizer = trainingOptimizer
                ?? CheckpointableAdam(learningRate: Float(learningRate))
            optimizer.learningRate = Float(learningRate)
            trainingOptimizer = optimizer

            #if DEBUG
            let diagnosticsCapture: (
                observer: @Sendable (MLXTrainingStepDiagnostics) -> Void,
                preUpdateParameters: [(String, MLXArray)],
                preStepMemory: Memory.Snapshot
            )?
            if let observer = trainingStepDiagnosticsObserver {
                let preUpdateParameters = Self.evaluatedDiagnosticSnapshot(
                    model.trainableParameters().flattened()
                )
                Memory.clearCache()
                diagnosticsCapture = (
                    observer,
                    preUpdateParameters,
                    Memory.snapshot()
                )
            } else {
                diagnosticsCapture = nil
            }
            #endif

            let lossAndGradient = valueAndGrad(model: model as Module) { module, arrays in
                let languageModel = module as! any LLMModel
                let logits = languageModel(arrays[0], cache: nil).asType(.float32)
                let weightedMask = arrays[2]
                // Normalize by the unweighted number of completion targets.
                // Source weight is an absolute influence multiplier: a lone
                // 0.5 example must produce half the default gradient, while a
                // lone elevated weight-3 edit must produce three times it.
                let tokenCount = arrays[3].sum()
                let loss = (
                    crossEntropy(logits: logits, targets: arrays[1]) * weightedMask
                ).sum() / tokenCount
                return [loss, tokenCount]
            }
            #if DEBUG
            if diagnosticsCapture != nil {
                Memory.peakMemory = 0
            }
            #endif
            let (values, gradients) = Self.withTrainingMode(model as Module) {
                lossAndGradient(
                    model as Module,
                    [batch.inputs, batch.targets, batch.lossWeights, batch.lossMask]
                )
            }
            let loss = try Self.validatedTrainingLoss(from: values, error: error)
            let trainableParameters = Dictionary(
                uniqueKeysWithValues: model.trainableParameters().flattened()
            )
            let flatGradients = Dictionary(
                uniqueKeysWithValues: gradients.flattened()
            )
            let updatedParameters = try optimizer.update(
                parameters: trainableParameters,
                gradients: flatGradients
            )
            adapterContinuationRevision = nil
            invalidateAdapterPromptCaches()
            model.update(parameters: ModuleParameters.unflattened(updatedParameters))
            eval(model, loss)
            try error.check()

            if let configuration = loraConfiguration {
                let snapshot = LoRAContainer(
                    configuration: configuration,
                    parameters: model.trainableParameters()
                )
                try error.check()
                adapterSnapshot = snapshot
                isAdapterInstalled = true
                _isAdapterLoaded = true
            }

            _totalSteps += 1
            currentLoss = Double(loss.item(Float.self))
            invalidateAdapterPromptCaches()

            let duration = Date().timeIntervalSince(start)
            #if DEBUG
            if let diagnosticsCapture {
                let postStepMemory = Memory.snapshot()
                let gradientNorms = try Self.l2NormsByDecoderLayer(
                    gradients.flattened()
                )
                let postUpdateParameters = model.trainableParameters().flattened()
                let parameterDeltas = try Self.l2ParameterDeltasByDecoderLayer(
                    before: diagnosticsCapture.preUpdateParameters,
                    after: postUpdateParameters
                )
                diagnosticsCapture.observer(
                    MLXTrainingStepDiagnostics(
                        inputSequenceLength: batch.inputs.shape.last ?? 0,
                        batchSize: batch.exampleCount,
                        adaptedParameterNamesByLayer: Self.adaptedParameterNamesByDecoderLayer(
                            postUpdateParameters
                        ),
                        gradientNormsByLayer: gradientNorms,
                        parameterDeltasByLayer: parameterDeltas,
                        preStepMemory: diagnosticsCapture.preStepMemory,
                        postStepMemory: postStepMemory,
                        effectivePeakMemoryBytes: max(
                            diagnosticsCapture.preStepMemory.activeMemory,
                            postStepMemory.peakMemory
                        ),
                        durationSeconds: duration
                    )
                )
            }
            #endif
            return TrainingStepResult(
                stepNumber: _totalSteps,
                loss: currentLoss,
                learningRate: learningRate,
                durationSeconds: duration
            )
            }
        }
    }

    private struct CompletionOnlyBatch {
        let inputs: MLXArray
        let targets: MLXArray
        let lossWeights: MLXArray
        let lossMask: MLXArray
        let exampleCount: Int
    }

    static let maximumTrainingSequenceTokens = 2_048

    struct BoundedTrainingTokens: Equatable {
        let tokens: [Int]
        /// Index of the first completion token in `tokens`.
        let completionStart: Int
    }

    /// A training example is one complete framed task. Dropping its middle
    /// destroys content conditioning and can teach a target whose instructions
    /// are absent. Reject over-budget examples instead of splicing either side.
    static func boundedTrainingTokens(
        fullTokens: [Int],
        prefixTokens: [Int],
        maximumTokens: Int = maximumTrainingSequenceTokens
    ) -> BoundedTrainingTokens? {
        guard maximumTokens >= 2, fullTokens.count >= 2,
              fullTokens.count <= maximumTokens else { return nil }
        let boundary = commonPrefixCount(prefixTokens, fullTokens)
        guard boundary > 0, boundary < fullTokens.count else { return nil }

        return BoundedTrainingTokens(
            tokens: fullTokens,
            completionStart: boundary
        )
    }

    private static func makeCompletionOnlyBatch(
        examples: [TrainingExample],
        tokenizer: any MLXLMCommon.Tokenizer,
        modelID: String?,
        maximumTokens: Int
    ) throws -> CompletionOnlyBatch {
        struct EncodedExample {
            let tokens: [Int]
            let completionTargetStart: Int
            let weight: Float
        }

        var encoded: [EncodedExample] = []
        encoded.reserveCapacity(examples.count)
        for example in examples {
            guard example.weight.isFinite, example.weight > 0 else { continue }
            let segments = QwenChatTemplate.trainingSegments(
                prompt: example.prompt,
                completion: example.completion,
                for: modelID
            )
            let fullTokens = tokenizer.encode(text: segments.prefix + segments.completion)
            let prefixTokens = tokenizer.encode(text: segments.prefix)
            guard let bounded = boundedTrainingTokens(
                fullTokens: fullTokens,
                prefixTokens: prefixTokens,
                maximumTokens: maximumTokens
            ) else {
                throw TrainingEngineError.invalidTrainingExample(
                    "A complete framed training example (\(fullTokens.count) tokens) does not fit its sequence budget (\(maximumTokens)) or has no valid completion boundary. No text was truncated.",
                    sequenceTokens: fullTokens.count
                )
            }
            let targetCount = bounded.tokens.count - 1
            let completionTargetStart = max(
                0,
                min(targetCount - 1, bounded.completionStart - 1)
            )
            encoded.append(EncodedExample(
                tokens: bounded.tokens,
                completionTargetStart: completionTargetStart,
                weight: Float(example.weight)
            ))
        }

        guard !encoded.isEmpty else {
            throw TrainingEngineError.trainingFailed("Tokenizer produced no weighted completion tokens.")
        }
        let maxTargetCount = encoded.map { $0.tokens.count - 1 }.max() ?? 0
        let inputs = MLXArray.zeros([encoded.count, maxTargetCount], type: Int32.self)
        let targets = MLXArray.zeros([encoded.count, maxTargetCount], type: Int32.self)
        let lossWeights = MLXArray.zeros([encoded.count, maxTargetCount], type: Float.self)
        let lossMask = MLXArray.zeros([encoded.count, maxTargetCount], type: Float.self)

        for (row, item) in encoded.enumerated() {
            let targetCount = item.tokens.count - 1
            inputs[row, 0 ..< targetCount] = MLXArray(Array(item.tokens.dropLast()))
            targets[row, 0 ..< targetCount] = MLXArray(Array(item.tokens.dropFirst()))
            let completionCount = targetCount - item.completionTargetStart
            lossWeights[row, item.completionTargetStart ..< targetCount] = MLXArray(
                Array(repeating: item.weight, count: completionCount)
            )
            lossMask[row, item.completionTargetStart ..< targetCount] = MLXArray(
                Array(repeating: Float(1), count: completionCount)
            )
        }

        return CompletionOnlyBatch(
            inputs: inputs,
            targets: targets,
            lossWeights: lossWeights,
            lossMask: lossMask,
            exampleCount: encoded.count
        )
    }

    public func evaluate(examples: [TrainingExample]) throws -> TrainingEvaluation {
        try Self.checkedMLXOperation(failure: { message in
            .trainingFailed("MLX validation failed: \(message)")
        }) { error in
            try withOperationLock {
                guard _isModelLoaded, let context = modelContext else {
                    throw TrainingEngineError.modelNotLoaded
                }
                guard !examples.isEmpty else {
                    throw TrainingEngineError.trainingFailed(
                        "Validation requires at least one example."
                    )
                }

                let model = context.model
                try setModelPersonalization(.personalized, model: model, error: error)
                defer {
                    try? setModelPersonalization(.base, model: model, error: error)
                }

                var weightedLoss = 0.0
                var totalCompletionTokens = 0
                var evaluatedExamples = 0
                for start in stride(
                    from: 0,
                    to: examples.count,
                    by: maximumTrainingBatchSize
                ) {
                    let end = min(start + maximumTrainingBatchSize, examples.count)
                    let batch = try Self.makeCompletionOnlyBatch(
                        examples: Array(examples[start..<end]),
                        tokenizer: context.tokenizer,
                        modelID: modelId,
                        maximumTokens: trainingSequenceTokenLimit
                    )
                    let languageModel = model as! any LLMModel
                    let logits = languageModel(batch.inputs, cache: nil).asType(.float32)
                    let tokenCount = batch.lossMask.sum()
                    let loss = (
                        crossEntropy(logits: logits, targets: batch.targets) * batch.lossWeights
                    ).sum() / tokenCount
                    eval(loss, tokenCount)
                    try error.check()

                    let count = Int(tokenCount.item(Float.self).rounded())
                    let value = Double(loss.item(Float.self))
                    guard count > 0, value.isFinite else {
                        throw TrainingEngineError.trainingFailed(
                            "Validation produced a non-finite loss."
                        )
                    }
                    weightedLoss += value * Double(count)
                    totalCompletionTokens += count
                    evaluatedExamples += batch.exampleCount
                }

                return TrainingEvaluation(
                    loss: weightedLoss / Double(totalCompletionTokens),
                    exampleCount: evaluatedExamples,
                    completionTokenCount: totalCompletionTokens
                )
            }
        }
    }

    // MARK: - Adapter Management

    public func saveAdapter(to path: String) throws {
        try Self.checkedMLXOperation(failure: { message in
            .saveFailed("Failed to save adapter to '\(path)': \(message)")
        }) { error in
            try withOperationLock {
                guard _isModelLoaded, let context = modelContext else {
                    throw TrainingEngineError.modelNotLoaded
                }
                try setModelPersonalization(
                    .personalized,
                    model: context.model,
                    error: error
                )
                guard isAdapterInstalled else {
                    throw TrainingEngineError.saveFailed(
                        "No adapter weights are available to save."
                    )
                }
                defer {
                    try? setModelPersonalization(.base, model: context.model, error: error)
                }

                let url = URL(fileURLWithPath: path)
                try LoRATrain.saveLoRAWeights(model: context.model as Module, url: url)
                try error.check()
            }
        }
    }

    public func saveOptimizerState(
        to path: String,
        policyIdentifier: String
    ) throws -> TrainingOptimizerStateDescriptor {
        try Self.checkedMLXOperation(failure: { message in
            .saveFailed("Failed to save optimizer state to '\(path)': \(message)")
        }) { error in
            try withOperationLock {
                guard _isModelLoaded else {
                    throw TrainingEngineError.modelNotLoaded
                }
                guard let trainingOptimizer else {
                    throw TrainingEngineError.saveFailed(
                        "No active optimizer state is available to checkpoint."
                    )
                }
                let descriptor = try trainingOptimizer.saveState(
                    to: URL(fileURLWithPath: path),
                    policyIdentifier: policyIdentifier
                )
                try error.check()
                return descriptor
            }
        }
    }

    public func loadOptimizerState(
        from path: String,
        descriptor: TrainingOptimizerStateDescriptor
    ) throws {
        try Self.checkedMLXOperation(failure: { message in
            .loadFailed("Failed to load optimizer state from '\(path)': \(message)")
        }) { error in
            try withOperationLock {
                guard _isModelLoaded, let model = modelContext?.model else {
                    throw TrainingEngineError.modelNotLoaded
                }
                guard FileManager.default.fileExists(atPath: path) else {
                    throw TrainingEngineError.adapterNotFound(path)
                }
                try setModelPersonalization(.personalized, model: model, error: error)
                defer {
                    try? setModelPersonalization(.base, model: model, error: error)
                }
                let parameters = Dictionary(
                    uniqueKeysWithValues: model.trainableParameters().flattened()
                )
                guard parameters.isEmpty == false else {
                    throw TrainingEngineError.loadFailed(
                        "No trainable LoRA parameters were available for optimizer restore."
                    )
                }
                let optimizer = CheckpointableAdam(
                    learningRate: Float(descriptor.learningRate)
                )
                try optimizer.loadState(
                    from: URL(fileURLWithPath: path),
                    descriptor: descriptor,
                    parameters: parameters
                )
                trainingOptimizer = optimizer
                try error.check()
            }
        }
    }

    public func clearOptimizerState() {
        withOperationLock {
            trainingOptimizer = nil
        }
    }

    // MARK: - In-memory training frontier

    public var stashedTrainingFrontier: TrainingFrontierMarker? {
        withOperationLock { stashedFrontier?.marker }
    }

    public func stashTrainingFrontier(_ marker: TrainingFrontierMarker) throws {
        try Self.checkedMLXOperation(failure: { message in
            .saveFailed("Failed to set the training frontier aside: \(message)")
        }) { error in
            try withOperationLock {
                guard _isModelLoaded, let model = modelContext?.model else {
                    throw TrainingEngineError.modelNotLoaded
                }
                // Base mode captures the installed weights into the snapshot.
                try setModelPersonalization(.base, model: model, error: error)
                guard _isAdapterLoaded, let adapterSnapshot else {
                    throw TrainingEngineError.saveFailed("No adapter weights are available to set aside.")
                }
                stashedFrontier = StashedFrontier(
                    marker: marker,
                    adapter: adapterSnapshot,
                    optimizer: trainingOptimizer,
                    continuationRevision: adapterContinuationRevision,
                    totalSteps: _totalSteps
                )
                try error.check()
            }
        }
    }

    public func restoreStashedTrainingFrontier() throws -> Bool {
        try Self.checkedMLXOperation(failure: { message in
            .loadFailed("Failed to reinstall the training frontier: \(message)")
        }) { error in
            try withOperationLock {
                guard let stash = stashedFrontier else { return false }
                stashedFrontier = nil
                guard _isModelLoaded, let model = modelContext?.model else {
                    throw TrainingEngineError.modelNotLoaded
                }
                if isAdapterInstalled {
                    try setModelPersonalization(.base, model: model, error: error)
                }
                invalidateAdapterPromptCaches()
                adapterSnapshot = nil
                loraConfiguration = nil
                _isAdapterLoaded = false
                let snapshot = try installAdapter(stash.adapter, into: model, mlxError: error)
                loraConfiguration = stash.adapter.configuration
                adapterSnapshot = snapshot
                isAdapterInstalled = true
                invalidateAdapterPromptCaches()
                _isAdapterLoaded = true
                adapterContinuationRevision = stash.continuationRevision
                trainingOptimizer = stash.optimizer
                _totalSteps = stash.totalSteps
                try setModelPersonalization(.base, model: model, error: error)
                return true
            }
        }
    }

    public func discardStashedTrainingFrontier() {
        withOperationLock { stashedFrontier = nil }
    }

    public func loadAdapter(from path: String) throws {
        try Self.checkedMLXOperation(failure: { message in
            .loadFailed("Failed to load adapter from '\(path)': \(message)")
        }) { mlxError in
            try withOperationLock {
                guard _isModelLoaded, let context = modelContext else {
                    throw TrainingEngineError.modelNotLoaded
                }

                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: path) else {
                    throw TrainingEngineError.adapterNotFound(path)
                }
                let continuationRevision = try Self.adapterRevision(at: url)

                if isAdapterInstalled {
                    try setModelPersonalization(.base, model: context.model, error: mlxError)
                }
                invalidateAdapterPromptCaches()
                adapterSnapshot = nil
                loraConfiguration = nil
                _isAdapterLoaded = false

                // Try loading as a full adapter directory
                // (adapter_config.json + adapters.safetensors).
                do {
                    let adapterDirectory = url.deletingLastPathComponent()
                    let container = try LoRAContainer.from(directory: adapterDirectory)
                    try mlxError.check()
                    // A failed install leaves base layers, so the fallback
                    // below starts from the base model.
                    let snapshot = try installAdapter(container, into: context.model, mlxError: mlxError)

                    loraConfiguration = container.configuration
                    adapterSnapshot = snapshot
                    isAdapterInstalled = true
                    invalidateAdapterPromptCaches()
                    _isAdapterLoaded = true
                    adapterContinuationRevision = continuationRevision
                    trainingOptimizer = nil
                    try setModelPersonalization(
                        .base,
                        model: context.model,
                        error: mlxError
                    )
                    return
                } catch {
                    // A native MLX failure must not be treated as a format
                    // mismatch and retried against a potentially invalid graph.
                    try mlxError.check()
                }

                // Fallback: load as raw safetensors weights.
                let weights = try MLX.loadArrays(url: url)
                try mlxError.check()
                let container = LoRAContainer(
                    configuration: Self.defaultLoRAConfiguration,
                    parameters: ModuleParameters.unflattened(weights)
                )
                try mlxError.check()
                let snapshot = try installAdapter(container, into: context.model, mlxError: mlxError)

                loraConfiguration = container.configuration
                adapterSnapshot = snapshot
                isAdapterInstalled = true
                invalidateAdapterPromptCaches()
                _isAdapterLoaded = true
                adapterContinuationRevision = continuationRevision
                trainingOptimizer = nil
                try setModelPersonalization(
                    .base,
                    model: context.model,
                    error: mlxError
                )
            }
        }
    }

    /// Swaps `container`'s LoRA layers in over the model's base layers,
    /// loads its weights and runs `body` with them installed. If anything
    /// throws, every LoRA layer the container's configuration targets is
    /// reverted to its base layer before the error propagates: upstream
    /// `load(into:)` swaps the layers in first, and `update(parameters:)`
    /// writes every matching tensor before it rejects unused keys, so a
    /// failure would otherwise leave adapter layers running while the engine
    /// labels the weights base. Callers have already marked the adapter
    /// uninstalled.
    static func withAdapterInstalled<T>(
        _ container: LoRAContainer,
        in model: any LanguageModel,
        _ body: () throws -> T
    ) throws -> T {
        do {
            model.freeze()
            try container.load(into: model)
            return try body()
        } catch {
            container.unload(from: model)
            model.freeze()
            throw error
        }
    }

    /// Installs `container` and returns an evaluated snapshot of the
    /// installed adapter weights. On failure the model is back on its base
    /// layers and every prompt state is dropped, since states built while
    /// the weights were in doubt cannot be trusted under any label.
    private func installAdapter(
        _ container: LoRAContainer,
        into model: any LanguageModel,
        mlxError: ErrorBox
    ) throws -> LoRAContainer {
        do {
            return try Self.withAdapterInstalled(container, in: model) {
                try mlxError.check()
                let snapshot = LoRAContainer(
                    configuration: container.configuration,
                    parameters: model.trainableParameters()
                )
                try mlxError.check()
                return snapshot
            }
        } catch {
            clearPromptCaches()
            throw error
        }
    }

    private static let loraLayerCount = 16
    private static let loraRank = 16
    private static let loraScale = 10.0

    private static let defaultLoRAConfiguration = LoRAConfiguration(
        numLayers: loraLayerCount,
        fineTuneType: .lora,
        loraParameters: .init(rank: loraRank, scale: Float(loraScale))
    )

    public func resetAdapter() throws {
        try Self.checkedMLXOperation(failure: { message in
            .loadFailed("Failed to reset personalization adapter: \(message)")
        }) { error in
            try withOperationLock {
                guard _isModelLoaded, let model = modelContext?.model else {
                    throw TrainingEngineError.modelNotLoaded
                }
                if isAdapterInstalled {
                    try setModelPersonalization(.base, model: model, error: error)
                }
                invalidateAdapterPromptCaches()
                adapterSnapshot = nil
                loraConfiguration = nil
                isAdapterInstalled = false
                trainingOptimizer = nil
                _isAdapterLoaded = false
                _totalSteps = 0
                adapterContinuationRevision = nil
                currentLoss = 0
                invalidateAdapterPromptCaches()
                model.freeze()
                try error.check()
            }
        }
    }

    // MARK: - Generation

    private func setModelPersonalization(
        _ scope: GenerationPersonalizationScope,
        model: any LanguageModel,
        error: ErrorBox
    ) throws {
        switch scope {
        case .base:
            guard isAdapterInstalled, let configuration = loraConfiguration else { return }
            let snapshot = LoRAContainer(
                configuration: configuration,
                parameters: model.trainableParameters()
            )
            try error.check()
            // A throw after the weights may have changed leaves
            // `isAdapterInstalled` not describing them; the KV caches are
            // then unlabeled, so drop all of them before rethrowing.
            do {
                snapshot.unload(from: model)
                model.freeze()
                try error.check()
            } catch {
                clearPromptCaches()
                throw error
            }
            adapterSnapshot = snapshot
            isAdapterInstalled = false

        case .personalized:
            guard !isAdapterInstalled else { return }
            guard let adapterSnapshot else {
                if _isAdapterLoaded {
                    throw TrainingEngineError.loadFailed(
                        "Personalization adapter state is unavailable."
                    )
                }
                return
            }
            // A failed install is reverted to base layers; drop all KV
            // caches as `.base` does when the installed weights are uncertain.
            do {
                try Self.withAdapterInstalled(adapterSnapshot, in: model) {
                    try error.check()
                }
            } catch {
                clearPromptCaches()
                throw error
            }
            loraConfiguration = adapterSnapshot.configuration
            isAdapterInstalled = true
        }
    }

    private func withGenerationPersonalization<T>(
        _ scope: GenerationPersonalizationScope,
        model: any LanguageModel,
        error: ErrorBox,
        operation: () throws -> T
    ) throws -> T {
        try setModelPersonalization(scope, model: model, error: error)
        defer {
            if scope == .personalized {
                try? setModelPersonalization(.base, model: model, error: error)
            }
        }
        return try operation()
    }

    private func currentGenerationCancellationEpoch() -> UInt64 {
        generationCancellationState.currentEpoch()
    }

    private func generationWasCancelled(after epoch: UInt64) -> Bool {
        generationCancellationState.wasCancelled(after: epoch)
    }

    private func checkGenerationCancellation(
        _ cancellation: GenerationCancellation? = nil,
        after epoch: UInt64
    ) throws {
        try Task.checkCancellation()
        if generationWasCancelled(after: epoch) {
            throw CancellationError()
        }
        try cancellation?.checkCancellation()
    }

    private static func checkGenerationCancellation(_ isCancelled: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        if isCancelled() {
            throw CancellationError()
        }
    }

    func consumeGenerationTask(
        _ handle: GenerationTaskHandle,
        stopPolicy: GenerationStopPolicy,
        requiresThinkingClosure: Bool = false,
        stopsAtThinkingClosure: Bool = false,
        checkCancellation: @escaping @Sendable () throws -> Void
    ) async throws -> MLXGenerationOutput {
        var text = ""
        var completionInfo: GenerateCompletionInfo?
        var reachedApplicationMarker = false

        do {
            for await generation in handle.stream {
                try checkCancellation()
                if let info = generation.info {
                    completionInfo = info
                }
                guard let chunk = generation.chunk else { continue }
                guard !reachedApplicationMarker else { continue }
                text += chunk
                if let finishedText = Self.finishedStreamingOutput(
                    from: text,
                    stopPolicy: stopPolicy,
                    requiresThinkingClosure: requiresThinkingClosure,
                    stopsAtThinkingClosure: stopsAtThinkingClosure
                ) {
                    text = finishedText
                    reachedApplicationMarker = true
                    handle.producer.cancel()
                }
            }
        } catch {
            await handle.cancelAndWait()
            throw error
        }

        await handle.producer.value
        return MLXGenerationOutput(
            text: Self.finalizedOutput(
                from: text,
                stopPolicy: stopPolicy,
                requiresThinkingClosure: requiresThinkingClosure
            ),
            stopReason: try Self.resolvedStopReason(
                reachedApplicationMarker: reachedApplicationMarker,
                completionInfo: completionInfo
            ),
            completionInfo: completionInfo
        )
    }

    static func finishedStreamingOutput(
        from text: String,
        stopPolicy: GenerationStopPolicy,
        requiresThinkingClosure: Bool,
        stopsAtThinkingClosure: Bool = false
    ) -> String? {
        guard requiresThinkingClosure else {
            return stopPolicy.finishedStreamingOutput(from: text)
        }
        guard let closeRange = text.range(of: "</think>") else {
            return nil
        }
        if stopsAtThinkingClosure { return String(text[..<closeRange.upperBound]) }
        let visible = String(text[closeRange.upperBound...])
        guard let finishedVisible = stopPolicy.finishedStreamingOutput(from: visible) else {
            return nil
        }
        return String(text[..<closeRange.upperBound]) + finishedVisible
    }

    static func finalizedOutput(
        from text: String,
        stopPolicy: GenerationStopPolicy,
        requiresThinkingClosure: Bool
    ) -> String {
        guard requiresThinkingClosure else {
            return stopPolicy.finalizedOutput(from: text)
        }
        guard let closeRange = text.range(of: "</think>") else {
            return text
        }
        let visible = String(text[closeRange.upperBound...])
        return String(text[..<closeRange.upperBound]) + stopPolicy.finalizedOutput(from: visible)
    }

    static func generationLogitProcessor(parameters: GenerateParameters,
        objectCommas: (limit: Int, vocabulary: ObjectCommaVocabulary)? = nil) throws -> LogitProcessor? {
        var processor = parameters.processor()
        if let penalty = parameters.presencePenalty, penalty != 0 {
            guard let maximumTokens = parameters.maxTokens, maximumTokens > 0 else {
                throw TrainingEngineError.generationFailed("Presence-penalized generation requires a positive completion budget.")
            }
            var otherParameters = parameters
            otherParameters.presencePenalty = nil
            processor = CompletionPresencePenaltyProcessor(otherPenalties: otherParameters.processor(),
                presence: PresencePenaltyContext(presencePenalty: penalty, presenceContextSize: maximumTokens))
        }
        guard let objectCommas else { return processor }
        guard objectCommas.limit > 0 else {
            throw TrainingEngineError.generationFailed("A JSON object comma limit must be positive.")
        }
        return ObjectCommaLimitProcessor(other: processor, limit: objectCommas.limit, vocabulary: objectCommas.vocabulary)
    }

    private static let objectCommaVocabularies = Mutex<[String: ObjectCommaVocabulary]>([:])

    /// The model's vocabulary classified once per model directory, over the
    /// IDs its output layer can produce (`vocab_size`), so every index the
    /// processor touches is a logit and no tokenizer is asked past its end.
    /// Nil when the model declares no vocabulary size: the limit is then not
    /// applied rather than guessed.
    static func objectCommaVocabulary(context: ModelContext) -> ObjectCommaVocabulary? {
        guard case let .directory(directory) = context.configuration.id,
              let size = MLXModelContextConfiguration.vocabularySize(in: directory) else { return nil }
        let key = directory.standardizedFileURL.path
        if let cached = objectCommaVocabularies.withLock({ $0[key] }) { return cached }
        let vocabulary = ObjectCommaVocabulary(tokens: (0..<size).map { context.tokenizer.convertIdToToken($0) })
        objectCommaVocabularies.withLock { $0[key] = vocabulary }
        return vocabulary
    }

    private static func makeGenerationTask(input: LMInput, cache: [KVCache]? = nil,
        parameters: GenerateParameters, objectCommaLimit: Int? = nil, context: ModelContext) throws -> GenerationTaskHandle {
        let penalized = parameters.presencePenalty.map { $0 != 0 } ?? false
        guard penalized || objectCommaLimit != nil else {
            return try MLXLMCommon.generateTask(input: input, cache: cache, parameters: parameters, context: context)
        }
        // The engine does not enable KV quantization. Preserve its cache
        // allocation and sampler while overriding only presence semantics
        // and the JSON comma limit.
        let objectCommas = objectCommaLimit.flatMap { limit in
            objectCommaVocabulary(context: context).map { (limit, $0) }
        }
        let iterator = try TokenIterator(input: input, model: context.model,
            cache: cache ?? context.model.newCache(parameters: parameters),
            processor: generationLogitProcessor(parameters: parameters, objectCommas: objectCommas),
            sampler: parameters.sampler(),
            prefillStepSize: parameters.prefillStepSize, maxTokens: parameters.maxTokens)
        let (stream, producer) = MLXLMCommon.generateTask(promptTokenCount: input.text.tokens.size,
            modelConfiguration: context.configuration, tokenizer: context.tokenizer, iterator: iterator)
        return GenerationTaskHandle(stream: stream, producer: producer)
    }

    static func generateParameters(
        maxTokens: Int,
        sampling: GenerationSampling
    ) -> GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK ?? 0,
            minP: sampling.minP ?? 0,
            repetitionPenalty: sampling.repetitionPenalty,
            presencePenalty: sampling.presencePenalty,
            seed: sampling.seed
        )
    }

    static func resolvedStopReason(
        reachedApplicationMarker: Bool,
        completionInfo: GenerateCompletionInfo?
    ) throws -> GenerationStopReason {
        if reachedApplicationMarker {
            return .stopMarker
        }
        guard let completionInfo else {
            throw TrainingEngineError.generationFailed(
                "Generation stream completed without completion metadata."
            )
        }
        switch completionInfo.stopReason {
        case .stop:
            return .endOfSequence
        case .length:
            return .maxTokens
        case .cancelled:
            throw CancellationError()
        }
    }

    /// The call's accounting: whole-prompt tokens, tokens reused from a saved
    /// cache, all prefill time (outside the iterator plus its own prompt step)
    /// and decode time. Nil when the iterator reported no completion.
    static func generationDiagnostics(
        for output: MLXGenerationOutput
    ) -> GenerationDiagnostics? {
        guard let info = output.completionInfo else { return nil }
        return GenerationDiagnostics(
            promptTokenCount: output.promptTokenCount ?? info.promptTokenCount,
            generatedTokenCount: info.generationTokenCount,
            promptSeconds: max(0, output.extraPrefillSeconds) + info.promptTime,
            decodeSeconds: info.generateTime,
            reusedPromptTokenCount: output.reusedPromptTokenCount
        )
    }

    private static func generationResult(
        from output: MLXGenerationOutput
    ) -> GenerationResult {
        GenerationResult(
            text: output.text,
            stopReason: output.stopReason,
            diagnostics: generationDiagnostics(for: output)
        )
    }

    public func generate(prompt: String, maxTokens: Int) throws -> String {
        try generate(
            prompt: prompt,
            maxTokens: maxTokens,
            personalization: .base
        )
    }

    public func generate(
        prompt: String,
        maxTokens: Int,
        personalization: GenerationPersonalizationScope
    ) throws -> String {
        try generateResult(
            prompt: prompt,
            maxTokens: maxTokens,
            cancellation: nil,
            personalization: personalization,
            sampling: .deterministic
        ).text
    }

    public func generate(
        conversation: GenerationConversation,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        personalization: GenerationPersonalizationScope
    ) throws -> GenerationResult {
        try generateConversation(
            conversation,
            maxTokens: maxTokens,
            cancellation: cancellation,
            personalization: personalization,
            sampling: QwenChatTemplate.reasoningSampling(for: modelId) ?? .deterministic,
            fallsBackAfterThinkingExhaustion: true
        )
    }

    func generateForReasoningEvaluation(
        conversation: GenerationConversation,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        personalization: GenerationPersonalizationScope,
        sampling: GenerationSampling
    ) throws -> GenerationResult {
        let reasoning = GenerationSampling.reasoning
        guard sampling.seed != nil,
              sampling.temperature == reasoning.temperature,
              sampling.topP == reasoning.topP,
              sampling.topK == reasoning.topK,
              sampling.minP == reasoning.minP,
              sampling.repetitionPenalty == reasoning.repetitionPenalty,
              sampling.presencePenalty == reasoning.presencePenalty
        else {
            throw TrainingEngineError.generationFailed(
                "Reasoning evaluation may vary only the non-nil random seed."
            )
        }
        return try generateConversation(
            conversation,
            maxTokens: maxTokens,
            cancellation: cancellation,
            personalization: personalization,
            sampling: sampling,
            fallsBackAfterThinkingExhaustion: false
        )
    }

    public func generateWithBoundedReasoning(
        prompt: String, thinkingTokens: Int, answerTokens: Int,
        cancellation: GenerationCancellation?, personalization: GenerationPersonalizationScope,
        seed: UInt64?, answerSampling: GenerationSampling,
        diagnostics: @Sendable (BoundedReasoningDiagnostics) -> Void
    ) throws -> BoundedReasoningResult {
        try performGeneration(personalization: personalization) { cancellationEpoch in
            guard let context = modelContext else {
                throw TrainingEngineError.modelNotLoaded
            }
            guard let contextLimit = _maximumContextTokens else {
                throw TrainingEngineError.generationFailed("The loaded model has no declared context limit for reserving a reasoning answer.")
            }
            let reasoningModelID: String?
            if case let .directory(directory) = context.configuration.id {
                reasoningModelID = MLXModelContextConfiguration.reasoningModelID(in: directory, requestedID: modelId)
            } else { reasoningModelID = modelId }
            let conversation = QwenChatTemplate.boundedReasoningConversation(prompt: prompt, for: reasoningModelID)
            guard let framed = QwenChatTemplate.framedConversation(conversation, for: reasoningModelID),
                  var sampling = QwenChatTemplate.reasoningSampling(for: reasoningModelID) else {
                throw TrainingEngineError.generationFailed("The loaded model does not support Qwen bounded reasoning.")
            }
            sampling.seed = seed
            let thinkingSampling = sampling
            let cacheKey = "bounded-" + UUID().uuidString
            let maximumPrefixTokens = max(0, context.tokenizer.encode(text: framed).count - 64)
            defer {
                // Both phases share only this operation's immutable input cache.
                // Do not retain private reasoning contexts.
                promptPrefixCache = promptPrefixCache.filter { !$0.key.contains("|\(cacheKey)|") }
            }
            // The framed prompt is one per-call `.item` checkpoint (never in
            // the token cache): the answer phase resumes from the state the
            // thinking phase saved there. The operation holds it outside the
            // pools, so it never evicts another caller's state.
            let boundaries = [PromptCheckpointChain.Boundary(leadingText: framed, reuse: .item)]
            func annotated(_ value: BoundedReasoningDiagnostics) -> BoundedReasoningDiagnostics {
                var result = value
                result.thinkingSampling = thinkingSampling
                result.answerSampling = answerSampling
                result.reasoningEffort = conversation.reasoningEffort
                return result
            }
            let result = try QwenBoundedReasoning.generate(framedPrompt: framed,
                thinkingTokens: thinkingTokens, answerTokens: answerTokens, contextLimit: contextLimit,
                countTokens: { context.tokenizer.encode(text: $0, addSpecialTokens: true).count },
                checkCancellation: { try self.checkGenerationCancellation(cancellation, after: cancellationEpoch) },
                diagnostics: { diagnostics(annotated($0)) }
            ) { prefill, limit, thinking in
                guard let container = self.modelContainer else { throw TrainingEngineError.modelNotLoaded }
                self.reportGenerationPromptUsage(framedPrompt: prefill, maximumOutputTokens: limit)
                let output = try Self.runAsync {
                    try await self.generateWithCheckpoints(container: container,
                        modelID: reasoningModelID ?? "unknown", cacheKey: cacheKey,
                        boundaries: boundaries, fullPrompt: prefill, maxTokens: limit,
                        stopPolicy: GenerationStopPolicy.forPrompt(prompt), cancellation: cancellation,
                        cancellationEpoch: cancellationEpoch,
                        sampling: thinking ? thinkingSampling : answerSampling,
                        maximumPrefixTokens: maximumPrefixTokens,
                        requiresThinkingClosure: thinking, stopsAtThinkingClosure: thinking,
                        cancellablePrefill: true, holdsCheckpointsForOperation: true)
                }.get()
                return GenerationResult(text: output.text, stopReason: output.stopReason,
                    diagnostics: Self.generationDiagnostics(for: output))
            }
            return BoundedReasoningResult(answer: result.answer, diagnostics: annotated(result.diagnostics))
        }
    }

    private func generateConversation(
        _ conversation: GenerationConversation,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        personalization: GenerationPersonalizationScope,
        sampling: GenerationSampling,
        fallsBackAfterThinkingExhaustion: Bool
    ) throws -> GenerationResult {
        try performGeneration(personalization: personalization) { cancellationEpoch in
            let fingerprint = continuationFingerprint(for: personalization)
            let eligibleConversation = conversation.keepingReasoning(matching: fingerprint)
            guard let framedPrompt = QwenChatTemplate.framedConversation(
                eligibleConversation,
                for: modelId
            ) else {
                let output = try generateInternal(
                    prompt: conversation.fallbackPrompt,
                    maxTokens: maxTokens,
                    cancellation: cancellation,
                    cancellationEpoch: cancellationEpoch,
                    sampling: sampling
                )
                return GenerationResult(
                    text: output.text,
                    stopReason: output.stopReason,
                    diagnostics: Self.generationDiagnostics(for: output)
                )
            }

            let output = try generateInternal(
                prompt: conversation.fallbackPrompt,
                maxTokens: maxTokens,
                cancellation: cancellation,
                cancellationEpoch: cancellationEpoch,
                sampling: sampling,
                preframedPrompt: framedPrompt,
                requiresThinkingClosure: true
            )
            let parsed = QwenThinkingOutputParser.parse(output.text)
            if fallsBackAfterThinkingExhaustion,
               parsed.content.isEmpty,
               output.stopReason == .maxTokens {
                let fallback = try generateInternal(
                    prompt: conversation.fallbackPrompt,
                    maxTokens: maxTokens,
                    cancellation: cancellation,
                    cancellationEpoch: cancellationEpoch,
                    sampling: .deterministic
                )
                return GenerationResult(
                    text: fallback.text,
                    stopReason: fallback.stopReason,
                    diagnostics: Self.generationDiagnostics(for: fallback)
                )
            }
            let preservesThinking = QwenChatTemplate.capabilities(for: modelId)
                .supportsPreservedThinking
            let preservedReasoning = preservesThinking ? parsed.reasoningContent : nil
            return GenerationResult(
                text: parsed.content,
                reasoningContent: preservedReasoning,
                continuationFingerprint: preservedReasoning == nil ? nil : fingerprint,
                stopReason: output.stopReason,
                diagnostics: Self.generationDiagnostics(for: output)
            )
        }
    }

    private func continuationFingerprint(
        for personalization: GenerationPersonalizationScope
    ) -> String {
        let model = modelId ?? "unknown"
        guard personalization == .personalized, _isAdapterLoaded else {
            return "qwen38-preserve-v1|\(model)|base"
        }
        let adapterRevision = currentAdapterRevision() ?? "unavailable"
        return "qwen38-preserve-v1|\(model)|personalized|\(adapterRevision)|steps:\(_totalSteps)"
    }

    /// Called only while the operation lock holds and personalized parameters
    /// are installed. A loaded file's digest stays valid until weights change.
    private func currentAdapterRevision() -> String? {
        guard _isAdapterLoaded else { return nil }
        if let adapterContinuationRevision { return adapterContinuationRevision }
        guard isAdapterInstalled, let model = modelContext?.model else { return nil }
        let parameters = model.trainableParameters().flattened()
        guard !parameters.isEmpty else { return nil }
        let revision = Self.inMemoryAdapterRevision(parameters: parameters)
        adapterContinuationRevision = revision
        return revision
    }

    static func inMemoryAdapterRevision(parameters: [(String, MLXArray)]) -> String {
        var digest = SHA256()
        for (name, array) in parameters.sorted(by: { $0.0 < $1.0 }) {
            let value = array.asData()
            // Include boundaries, names, shapes and storage types: equal bytes
            // in differently shaped or named tensors are different adapters.
            let header = "\(name.utf8.count):\(name)|\(value.dType)|\(value.shape)|\(value.data.count):"
            digest.update(data: Data(header.utf8))
            digest.update(data: value.data)
        }
        return "in-memory-sha256:" + digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func adapterRevision(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func generate(
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation
    ) throws -> String {
        try generate(
            prompt: prompt,
            maxTokens: maxTokens,
            cancellation: cancellation,
            personalization: .base
        )
    }

    public func generate(
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        personalization: GenerationPersonalizationScope
    ) throws -> String {
        try generateResult(
            prompt: prompt,
            maxTokens: maxTokens,
            cancellation: cancellation,
            personalization: personalization,
            sampling: .deterministic
        ).text
    }

    private func generateInternal(
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        cancellationEpoch: UInt64,
        sampling: GenerationSampling = .deterministic,
        preframedPrompt: String? = nil,
        requiresThinkingClosure: Bool = false,
        stopsAtThinkingClosure: Bool = false
    ) throws -> MLXGenerationOutput {
        guard isModelLoaded, let container = modelContainer else {
            throw TrainingEngineError.modelNotLoaded
        }
        try checkGenerationCancellation(cancellation, after: cancellationEpoch)

        let stopPolicy = GenerationStopPolicy.forPrompt(prompt)
        // Frame the instruction as a single ChatML user turn for the Qwen
        // catalog models — raw un-templated completion makes an instruct
        // model continue the document instead of answering it. Unknown model
        // families pass through unframed. (The tokenizer's Jinja
        // applyChatTemplate is not used because swift-transformers fails on
        // Qwen3-family templates; the manual form in QwenChatTemplate is
        // exact for every catalog model.)
        let framedPrompt = preframedPrompt
            ?? QwenChatTemplate.turnWrapper(for: modelId)?.framed(prompt)
            ?? prompt
        reportGenerationPromptUsage(
            framedPrompt: framedPrompt,
            maximumOutputTokens: maxTokens
        )
        let result = Self.runAsync {
            try await withError { error in
                let cancellationCheck: @Sendable () throws -> Void = {
                    try self.checkGenerationCancellation(
                        cancellation,
                        after: cancellationEpoch
                    )
                }
                let parameters = Self.generateParameters(
                    maxTokens: maxTokens,
                    sampling: sampling
                )
                let output = try await container.perform { context in
                    try self.checkGenerationCancellation(
                        cancellation,
                        after: cancellationEpoch
                    )
                    let tokenIDs = context.tokenizer.encode(text: framedPrompt)
                    guard !tokenIDs.isEmpty else {
                        throw TrainingEngineError.generationFailed(
                            "Tokenizer produced no tokens."
                        )
                    }
                    let handle = try Self.makeGenerationTask(
                        input: LMInput(tokens: MLXArray(tokenIDs)),
                        parameters: parameters,
                        objectCommaLimit: sampling.objectCommaLimit,
                        context: context
                    )
                    var consumed = try await self.consumeGenerationTask(
                        handle,
                        stopPolicy: stopPolicy,
                        requiresThinkingClosure: requiresThinkingClosure,
                        stopsAtThinkingClosure: stopsAtThinkingClosure,
                        checkCancellation: cancellationCheck
                    )
                    consumed.promptTokenCount = tokenIDs.count
                    consumed.reusedPromptTokenCount = 0
                    if let diagnostics = Self.generationDiagnostics(for: consumed) {
                        let timing = Self.timingLogFields(for: consumed)
                        mlxTrainingLogger.info(
                            "qwen plain timing totalTokens=\(diagnostics.promptTokenCount, privacy: .public) prefillMs=\(timing.prefillMs, privacy: .public) decodeMs=\(timing.decodeMs, privacy: .public) generatedTokens=\(timing.generatedTokens, privacy: .public)"
                        )
                    }
                    return consumed
                }
                try error.check()
                return output
            }
        }

        switch result {
        case .success(let output):
            return output
        case .failure(let error):
            if let engineError = error as? TrainingEngineError {
                throw engineError
            }
            if error is CancellationError {
                throw error
            }
            throw TrainingEngineError.generationFailed(error.localizedDescription)
        }
    }

    public func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int
    ) throws -> String {
        try generate(
            prompt: prompt,
            maxTokens: maxTokens,
            personalization: .base
        )
    }

    public func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        personalization: GenerationPersonalizationScope
    ) throws -> String {
        try generateResult(
            prompt: prompt,
            maxTokens: maxTokens,
            cancellation: nil,
            personalization: personalization,
            sampling: .deterministic
        ).text
    }

    public func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation
    ) throws -> String {
        try generate(
            prompt: prompt,
            maxTokens: maxTokens,
            cancellation: cancellation,
            personalization: .base
        )
    }

    public func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        personalization: GenerationPersonalizationScope
    ) throws -> String {
        try generateResult(
            prompt: prompt,
            maxTokens: maxTokens,
            cancellation: cancellation,
            personalization: personalization,
            sampling: .deterministic
        ).text
    }

    /// `SamplingScopedGenerating`: the non-prefix-cached half of the
    /// sampling capability, so a sampled request on the plain path is
    /// honored rather than silently decoded greedily.
    public func generate(
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        personalization: GenerationPersonalizationScope,
        sampling: GenerationSampling
    ) throws -> String {
        try generateResult(
            prompt: prompt,
            maxTokens: maxTokens,
            cancellation: cancellation,
            personalization: personalization,
            sampling: sampling
        ).text
    }

    public func generateResult(
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        personalization: GenerationPersonalizationScope,
        sampling: GenerationSampling
    ) throws -> GenerationResult {
        try performGeneration(personalization: personalization) { cancellationEpoch in
            let output = try generateInternal(
                prompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation,
                cancellationEpoch: cancellationEpoch,
                sampling: sampling
            )
            var result = Self.generationResult(from: output)
            result.personalization = GenerationPersonalization(modelID: modelId ?? "unknown",
                adapterActive: personalization == .personalized && _isAdapterLoaded,
                adapterRevision: personalization == .personalized ? currentAdapterRevision() : nil)
            return result
        }
    }

    /// `SamplingScopedPrefixCachedGenerating`: the signature studio's
    /// design lane, the one caller that needs a non-greedy decode.
    public func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        personalization: GenerationPersonalizationScope,
        sampling: GenerationSampling
    ) throws -> String {
        try generateResult(
            prompt: prompt,
            maxTokens: maxTokens,
            cancellation: cancellation,
            personalization: personalization,
            sampling: sampling
        ).text
    }

    public func generateResult(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        personalization: GenerationPersonalizationScope,
        sampling: GenerationSampling
    ) throws -> GenerationResult {
        try performGeneration(personalization: personalization) { cancellationEpoch in
            let output = try generateInternal(
                cachedPrompt: prompt,
                maxTokens: maxTokens,
                cancellation: cancellation,
                cancellationEpoch: cancellationEpoch,
                sampling: sampling
            )
            var result = Self.generationResult(from: output)
            result.personalization = GenerationPersonalization(modelID: modelId ?? "unknown",
                adapterActive: personalization == .personalized && _isAdapterLoaded,
                adapterRevision: personalization == .personalized ? currentAdapterRevision() : nil)
            return result
        }
    }

    private func performGeneration<Value>(
        personalization: GenerationPersonalizationScope,
        operation: (_ cancellationEpoch: UInt64) throws -> Value
    ) throws -> Value {
        try Self.checkedMLXOperation(failure: { message in
            .generationFailed(message)
        }) { error in
            try withOperationLock {
                guard let model = modelContext?.model else {
                    throw TrainingEngineError.modelNotLoaded
                }
                let cancellationEpoch = currentGenerationCancellationEpoch()
                return try withGenerationPersonalization(
                    personalization,
                    model: model,
                    error: error
                ) {
                    let output = try operation(cancellationEpoch)
                    try error.check()
                    return output
                }
            }
        }
    }

    private func generateInternal(
        cachedPrompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        cancellationEpoch: UInt64,
        sampling: GenerationSampling = .deterministic
    ) throws -> MLXGenerationOutput {
        guard isModelLoaded, let container = modelContainer else {
            throw TrainingEngineError.modelNotLoaded
        }
        try checkGenerationCancellation(cancellation, after: cancellationEpoch)

        guard !cachedPrompt.checkpoints.isEmpty else {
            return try generateInternal(
                prompt: cachedPrompt.prompt,
                maxTokens: maxTokens,
                cancellation: cancellation,
                cancellationEpoch: cancellationEpoch,
                sampling: sampling
            )
        }

        let stopPolicy = GenerationStopPolicy.forPrompt(cachedPrompt.prompt)
        // ChatML framing (see generateInternal(prompt:)) splits around the
        // checkpoints: the user-turn header joins the first checkpoint so
        // every boundary's leading text is stable across calls; the turn
        // close + assistant opening ride the suffix.
        let framed = PromptCheckpointChain.framed(
            cachedPrompt,
            wrapper: QwenChatTemplate.turnWrapper(for: modelId)
        )
        reportGenerationPromptUsage(
            framedPrompt: framed.fullText,
            maximumOutputTokens: maxTokens
        )
        let modelID = modelId ?? "unknown"
        let result = Self.runAsync {
            try await self.generateWithCheckpoints(
                container: container,
                modelID: modelID,
                cacheKey: cachedPrompt.cacheKey,
                boundaries: framed.boundaries,
                fullPrompt: framed.fullText,
                maxTokens: maxTokens,
                stopPolicy: stopPolicy,
                cancellation: cancellation,
                cancellationEpoch: cancellationEpoch,
                sampling: sampling,
                cancellablePrefill: cancellation != nil
            )
        }

        switch result {
        case .success(let output):
            return output
        case .failure(let error):
            if let engineError = error as? TrainingEngineError {
                throw engineError
            }
            if error is CancellationError {
                throw error
            }
            throw TrainingEngineError.generationFailed(error.localizedDescription)
        }
    }

    private func reportGenerationPromptUsage(
        framedPrompt: String,
        maximumOutputTokens: Int
    ) {
        guard let reporter = generationPromptUsageReporter,
              let modelMaximum = _maximumContextTokens,
              modelMaximum > 0 else {
            return
        }
        let operatingMaximum = min(
            modelMaximum,
            ComposerContextPacker.Policy().maximumOperatingInputTokens
        )
        guard operatingMaximum > 0 else { return }
        let inputTokens: Int
        if let tokenizer = modelContext?.tokenizer {
            // Matches both real decode paths: ModelContainer.encode for the
            // ordinary path and context.tokenizer.encode for prefix caching.
            inputTokens = tokenizer.encode(
                text: framedPrompt,
                addSpecialTokens: true
            ).count
        } else {
            inputTokens = framedPrompt.unicodeScalars.count
        }
        reporter(WorkerPromptUsageSnapshot(
            inputTokens: inputTokens,
            maximumContextTokens: operatingMaximum,
            maximumOutputTokens: maximumOutputTokens
        ))
    }

    /// Generates from `fullPrompt`, resuming from the deepest checkpoint
    /// boundary with a saved state and saving a state at every deeper usable
    /// boundary on the way. Hybrid Qwen caches cannot be rewound, so each
    /// saved state is an evaluated deep copy taken at its boundary.
    /// `boundaries` hold framed leading text, each a prefix of `fullPrompt`;
    /// `maximumPrefixTokens` caps every boundary's token count. With
    /// `holdsCheckpointsForOperation`, states saved here stay outside the
    /// pools (`PromptCheckpointRetention.operation`) and the caller removes
    /// them when its operation ends.
    private func generateWithCheckpoints(
        container: ModelContainer,
        modelID: String,
        cacheKey: String,
        boundaries: [PromptCheckpointChain.Boundary],
        fullPrompt: String,
        maxTokens: Int,
        stopPolicy: GenerationStopPolicy,
        cancellation: GenerationCancellation?,
        cancellationEpoch: UInt64,
        sampling: GenerationSampling = .deterministic,
        maximumPrefixTokens: Int? = nil,
        requiresThinkingClosure: Bool = false,
        stopsAtThinkingClosure: Bool = false,
        cancellablePrefill: Bool = false,
        holdsCheckpointsForOperation: Bool = false
    ) async throws -> MLXGenerationOutput {
        return try await withError { error in
            let output = try await container.perform { context in
                let checkCancellation = {
                    try self.checkGenerationCancellation(cancellation, after: cancellationEpoch)
                }
                try checkCancellation()
                let totalStart = Date()
                let parameters = Self.generateParameters(
                    maxTokens: maxTokens,
                    sampling: sampling
                )
                let fullTokenizeStart = Date()
                let fullTokens = context.tokenizer.encode(text: fullPrompt)
                try checkCancellation()
                let fullTokenizeMs = Self.elapsedMilliseconds(since: fullTokenizeStart)
                guard !fullTokens.isEmpty else {
                    throw TrainingEngineError.generationFailed("Tokenizer produced no tokens.")
                }

                // Each boundary is the common token prefix of its leading
                // text with the full prompt, so a BPE merge across the
                // boundary never changes the tokens the model reads.
                let boundaryStart = Date()
                var boundaryTokenCounts: [Int] = []
                var tokenCacheHits = 0
                for boundary in boundaries {
                    let leadingTokens: [Int]
                    switch boundary.reuse {
                    case .instructions:
                        let tokenCacheKey = Self.promptPrefixTokenCacheKey(
                            modelID: modelID,
                            cacheKey: cacheKey,
                            leadingText: boundary.leadingText
                        )
                        if var entry = self.promptPrefixTokenCache[tokenCacheKey] {
                            entry.hitCount += 1
                            entry.lastAccessedAt = Date()
                            self.promptPrefixTokenCache[tokenCacheKey] = entry
                            leadingTokens = entry.tokens
                            tokenCacheHits += 1
                        } else {
                            leadingTokens = context.tokenizer.encode(text: boundary.leadingText)
                            let builtAt = Date()
                            self.promptPrefixTokenCache[tokenCacheKey] = PromptPrefixTokenCacheEntry(
                                tokens: leadingTokens,
                                builtAt: builtAt,
                                hitCount: 0,
                                lastAccessedAt: builtAt
                            )
                            self.trimPromptPrefixTokenCacheIfNeeded()
                        }
                    case .item:
                        // Item text changes per email and would thrash the
                        // shared token cache.
                        leadingTokens = context.tokenizer.encode(text: boundary.leadingText)
                    }
                    boundaryTokenCounts.append(min(
                        maximumPrefixTokens ?? Int.max,
                        Self.commonPrefixCount(leadingTokens, fullTokens)
                    ))
                    try checkCancellation()
                }
                let boundaryMs = Self.elapsedMilliseconds(since: boundaryStart)

                let usable = PromptCheckpointChain.usableBoundaries(
                    tokenCounts: boundaryTokenCounts,
                    fullTokenCount: fullTokens.count
                )
                let weightIdentity = self.currentWeightIdentity()
                var keys: [Int: String] = [:]
                for index in usable {
                    let count = boundaryTokenCounts[index]
                    keys[index] = PromptCacheWeights.key(
                        modelID: modelID,
                        cacheKey: cacheKey,
                        prefixTokenCount: count,
                        prefixFingerprint: Self.stableFingerprint(tokens: Array(fullTokens.prefix(count))),
                        weightIdentity: weightIdentity
                    )
                }

                let kvCacheStart = Date()
                // A start whose state cannot be restored counts as unsaved,
                // so the plan falls back to a shallower state or token 0 and
                // builds every boundary past it, exactly as a miss would.
                var cache: [KVCache]?
                let plan = Self.restorableCheckpointPlan(
                    tokenCounts: boundaryTokenCounts,
                    fullTokenCount: fullTokens.count,
                    saved: Set(keys.compactMap { index, key in
                        self.promptPrefixCache[key] == nil ? nil : index
                    }),
                    restore: { start in
                        guard let key = keys[start] else { return false }
                        cache = self.useSavedCheckpoint(
                            forKey: key,
                            ancestorKeys: usable.prefix(while: { $0 != start }).compactMap { keys[$0] }
                        )
                        return cache != nil
                    }
                )
                var position = plan.start.map { boundaryTokenCounts[$0] } ?? 0
                let startTokens = position
                var buildSeconds = 0.0
                var builtCheckpointBytes: [Int] = []
                for index in plan.build {
                    guard let key = keys[index] else { continue }
                    let count = boundaryTokenCounts[index]
                    let segmentStart = Date()
                    let memoryBefore = Memory.snapshot()
                    let working = try Self.buildPromptPrefixCache(
                        tokenIDs: Array(fullTokens[position..<count]),
                        parameters: parameters,
                        context: context,
                        existingCache: cache,
                        checkCancellation: checkCancellation
                    )
                    try error.check()
                    // The saved copy owns materialized arrays; the working
                    // cache continues to the next boundary.
                    let saved = working.map { $0.copy() }
                    eval(saved)
                    try error.check()
                    let duration = Date().timeIntervalSince(segmentStart)
                    let memoryAfter = Memory.snapshot()
                    let logicalBytes = saved.reduce(into: 0) { total, layerCache in
                        total += layerCache.state.reduce(0) { $0 + $1.nbytes }
                    }
                    let estimatedBytes = max(
                        1,
                        max(
                            logicalBytes,
                            (memoryAfter.activeMemory + memoryAfter.cacheMemory)
                                - (memoryBefore.activeMemory + memoryBefore.cacheMemory)
                        )
                    )
                    self.saveCheckpoint(
                        saved,
                        forKey: key,
                        retention: holdsCheckpointsForOperation ? .operation : .pool(boundaries[index].reuse),
                        tokenCount: count,
                        buildDuration: duration,
                        estimatedBytes: estimatedBytes,
                        weightIdentity: weightIdentity
                    )
                    cache = working
                    position = count
                    buildSeconds += duration
                    builtCheckpointBytes.append(estimatedBytes)
                }
                let kvCacheMs = Self.elapsedMilliseconds(since: kvCacheStart)

                let remainingTokens = Array(fullTokens.dropFirst(position))
                let generationStart = Date()
                var output = try await self.generate(
                    tokenIDs: remainingTokens,
                    cache: cache,
                    parameters: parameters,
                    objectCommaLimit: sampling.objectCommaLimit,
                    context: context,
                    stopPolicy: stopPolicy,
                    requiresThinkingClosure: requiresThinkingClosure,
                    stopsAtThinkingClosure: stopsAtThinkingClosure,
                    cancellablePrefill: cancellablePrefill,
                    isCancelled: {
                        self.generationWasCancelled(after: cancellationEpoch)
                            || cancellation?.isCancelled == true
                    }
                )
                try error.check()
                output.promptTokenCount = fullTokens.count
                output.reusedPromptTokenCount = startTokens
                output.extraPrefillSeconds += buildSeconds
                let timing = Self.timingLogFields(for: output)
                let mode = plan.usable.isEmpty ? "fallback" : "cached"
                let bytesField = builtCheckpointBytes.isEmpty
                    ? ""
                    : " checkpointBytes=" + builtCheckpointBytes.map(String.init).joined(separator: ",")
                mlxTrainingLogger.info(
                    "qwen prefix timing mode=\(mode, privacy: .public) totalTokens=\(fullTokens.count, privacy: .public) reusedTokens=\(output.reusedPromptTokenCount, privacy: .public) prefillMs=\(timing.prefillMs, privacy: .public) decodeMs=\(timing.decodeMs, privacy: .public) generatedTokens=\(timing.generatedTokens, privacy: .public) checkpoints=\(plan.usable.count, privacy: .public)/\(boundaries.count, privacy: .public) startTokens=\(startTokens, privacy: .public) built=\(builtCheckpointBytes.count, privacy: .public)\(bytesField, privacy: .public) suffixTokens=\(remainingTokens.count, privacy: .public) prefixTokenCacheHits=\(tokenCacheHits, privacy: .public) fullTokenizeMs=\(fullTokenizeMs, privacy: .public) boundaryMs=\(boundaryMs, privacy: .public) kvCacheMs=\(kvCacheMs, privacy: .public) generationMs=\(Self.elapsedMilliseconds(since: generationStart), privacy: .public) totalMs=\(Self.elapsedMilliseconds(since: totalStart), privacy: .public) outputChars=\(output.text.count, privacy: .public)"
                )
                return output
            }
            try error.check()
            return output
        }
    }

    /// `PromptCheckpointChain.plan` whose start is guaranteed restored:
    /// `restore` is asked for the chosen start, and a start it cannot
    /// restore counts as unsaved, so the plan is recomputed without it (down
    /// to token 0 with every usable boundary to build).
    static func restorableCheckpointPlan(
        tokenCounts: [Int],
        fullTokenCount: Int,
        saved: Set<Int>,
        restore: (Int) -> Bool
    ) -> PromptCheckpointChain.Plan {
        var saved = saved
        while true {
            let plan = PromptCheckpointChain.plan(
                tokenCounts: tokenCounts,
                fullTokenCount: fullTokenCount,
                saved: saved
            )
            guard let start = plan.start, !restore(start) else { return plan }
            saved.remove(start)
        }
    }

    /// A deep copy of the saved state under `key`, marking it and its saved
    /// ancestors (shallower boundaries of the same prompt) as used.
    private func useSavedCheckpoint(forKey key: String, ancestorKeys: [String]) -> [KVCache]? {
        guard var entry = promptPrefixCache[key] else { return nil }
        let now = Date()
        entry.hitCount += 1
        entry.lastAccessedAt = now
        promptPrefixCache[key] = entry
        for ancestorKey in ancestorKeys {
            promptPrefixCache[ancestorKey]?.lastAccessedAt = now
        }
        if entry.hitCount == 1 || entry.hitCount.isMultiple(of: 50) {
            print("[Ohia] Qwen prefix cache hit prefixTokens=\(entry.tokenCount) hits=\(entry.hitCount)")
        }
        return entry.cache.map { $0.copy() }
    }

    private func saveCheckpoint(
        _ cache: [KVCache],
        forKey key: String,
        retention: PromptCheckpointRetention,
        tokenCount: Int,
        buildDuration: TimeInterval,
        estimatedBytes: Int,
        weightIdentity: String
    ) {
        let builtAt = Date()
        promptPrefixCache[key] = PromptPrefixCacheEntry(
            tokenCount: tokenCount,
            cache: cache,
            retention: retention,
            builtAt: builtAt,
            buildDuration: buildDuration,
            estimatedBytes: estimatedBytes,
            weightIdentity: weightIdentity,
            hitCount: 0,
            lastAccessedAt: builtAt
        )
        let poolName: String
        switch retention {
        case .pool(let pool):
            trimPromptPrefixCacheIfNeeded(pool: pool)
            poolName = pool.rawValue
        case .operation:
            poolName = "operation"
        }
        print("[Ohia] Qwen prefix cache built prefixTokens=\(tokenCount) pool=\(poolName) buildMs=\(Int((buildDuration * 1000).rounded()))")
    }

    private static func buildPromptPrefixCache(
        tokenIDs: [Int],
        parameters: GenerateParameters,
        context: ModelContext,
        existingCache: [KVCache]? = nil,
        checkCancellation: () throws -> Void
    ) throws -> [KVCache] {
        try withError { error in
            let cache = existingCache ?? context.model.newCache(parameters: parameters)
            try forEachPrefillChunk(tokenCount: tokenIDs.count, checkCancellation: checkCancellation) { range in
                let input = LMInput(tokens: MLXArray(Array(tokenIDs[range])))
                switch try context.model.prepare(input, cache: cache, windowSize: parameters.prefillStepSize) {
                case .tokens(let remaining):
                    if remaining.tokens.size > 0 {
                        _ = context.model(remaining[text: .newAxis], cache: cache.isEmpty ? nil : cache, state: nil)
                    }
                case .logits(let output):
                    eval(output.logits)
                }
                // Finish this GPU chunk before observing cancellation. Nothing
                // remains scheduled when the owned operation releases its lock.
                eval(cache)
                try error.check()
            }
            return cache
        }
    }

    static func forEachPrefillChunk(tokenCount: Int, chunkSize: Int = 128,
        checkCancellation: () throws -> Void, process: (Range<Int>) throws -> Void) throws {
        guard tokenCount >= 0, chunkSize > 0 else {
            throw TrainingEngineError.generationFailed("Invalid prompt prefill dimensions.")
        }
        try checkCancellation()
        for start in stride(from: 0, to: tokenCount, by: chunkSize) {
            try process(start..<min(start + chunkSize, tokenCount))
            try checkCancellation()
        }
    }

    private func generate(
        tokenIDs: [Int],
        cache: [KVCache]?,
        parameters: GenerateParameters,
        objectCommaLimit: Int? = nil,
        context: ModelContext,
        stopPolicy: GenerationStopPolicy,
        requiresThinkingClosure: Bool = false,
        stopsAtThinkingClosure: Bool = false,
        cancellablePrefill: Bool = false,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> MLXGenerationOutput {
        try await withError { error in
            try Self.checkGenerationCancellation(isCancelled)
            guard !tokenIDs.isEmpty else {
                throw TrainingEngineError.generationFailed(
                    "Tokenizer produced no remaining tokens."
                )
            }
            var generationTokens = tokenIDs
            var generationCache = cache
            let chunkedPrefillStart = Date()
            if cancellablePrefill {
                // Keep the full penalty context in the iterator's input so
                // prompt reuse does not change the configured token penalties.
                let tailCount = max(64, parameters.repetitionContextSize,
                    parameters.presenceContextSize, parameters.frequencyContextSize)
                let prefixCount = max(0, tokenIDs.count - tailCount)
                if prefixCount > 0 {
                    generationCache = try Self.buildPromptPrefixCache(
                        tokenIDs: Array(tokenIDs.prefix(prefixCount)), parameters: parameters,
                        context: context, existingCache: cache,
                        checkCancellation: { try Self.checkGenerationCancellation(isCancelled) })
                    generationTokens = Array(tokenIDs.dropFirst(prefixCount))
                }
            }
            let chunkedPrefillSeconds = Date().timeIntervalSince(chunkedPrefillStart)
            try Self.checkGenerationCancellation(isCancelled)
            let input = LMInput(tokens: MLXArray(generationTokens))
            let handle = try Self.makeGenerationTask(
                input: input,
                cache: generationCache,
                parameters: parameters,
                objectCommaLimit: objectCommaLimit,
                context: context
            )
            var output = try await consumeGenerationTask(
                handle,
                stopPolicy: stopPolicy,
                requiresThinkingClosure: requiresThinkingClosure,
                stopsAtThinkingClosure: stopsAtThinkingClosure,
                checkCancellation: {
                    try Self.checkGenerationCancellation(isCancelled)
                }
            )
            try error.check()
            output.extraPrefillSeconds = chunkedPrefillSeconds
            return output
        }
    }

    private static func commonPrefixCount(_ lhs: [Int], _ rhs: [Int]) -> Int {
        let count = min(lhs.count, rhs.count)
        var index = 0
        while index < count, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    private static func stableFingerprint(tokens: [Int]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for token in tokens {
            hash ^= UInt64(bitPattern: Int64(token))
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func stableFingerprint(text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func promptPrefixTokenCacheKey(
        modelID: String,
        cacheKey: String,
        leadingText: String
    ) -> String {
        [
            modelID,
            cacheKey,
            "\(leadingText.utf8.count)",
            stableFingerprint(text: leadingText)
        ].joined(separator: "|")
    }

    /// Whole milliseconds for the timing log lines; zero when the iterator
    /// reported no completion.
    private static func timingLogFields(
        for output: MLXGenerationOutput
    ) -> (prefillMs: Int, decodeMs: Int, generatedTokens: Int) {
        guard let diagnostics = generationDiagnostics(for: output) else { return (0, 0, 0) }
        return (Int((diagnostics.promptSeconds * 1000).rounded()),
                Int((diagnostics.decodeSeconds * 1000).rounded()),
                diagnostics.generatedTokenCount)
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    /// Validate the deferred native error boundary before reading MLX's loss
    /// output. A failed value-and-gradient operation may return no values while
    /// recording its real failure in `ErrorBox`; subscripting first traps the
    /// worker instead of letting the training orchestrator report the error.
    static func validatedTrainingLoss(
        from values: [MLXArray],
        error: ErrorBox
    ) throws -> MLXArray {
        try error.check()
        guard let loss = values.first else {
            throw TrainingEngineError.trainingFailed(
                "MLX gradient evaluation produced no loss value."
            )
        }
        return loss
    }

    static func checkedMLXOperation<T>(
        failure: (String) -> TrainingEngineError,
        _ operation: (ErrorBox) throws -> T
    ) throws -> T {
        do {
            return try withError { error in
                let value = try operation(error)
                try error.check()
                return value
            }
        } catch let error as TrainingEngineError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            throw failure(error.localizedDescription)
        }
    }

    static func checkedMLXAsyncOperation<T>(
        failure: (String) -> TrainingEngineError,
        _ operation: (ErrorBox) async throws -> T
    ) async throws -> T {
        do {
            return try await withError { error in
                let value = try await operation(error)
                try error.check()
                return value
            }
        } catch let error as TrainingEngineError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            throw failure(error.localizedDescription)
        }
    }

    private static func containMLXErrors(
        operation: String,
        _ body: (ErrorBox) throws -> Void
    ) {
        do {
            try withError { error in
                try body(error)
                try error.check()
            }
        } catch {
            mlxTrainingLogger.error(
                "MLX \(operation, privacy: .public) failed: \(String(reflecting: type(of: error)), privacy: .public)"
            )
        }
    }

    private func withOperationLock<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try body()
    }

    public func withGenerationOperation<T>(cancellation: GenerationCancellation,
        operation: () throws -> T) throws -> T {
        while !operationLock.lock(before: Date().addingTimeInterval(0.02)) {
            try cancellation.checkCancellation()
        }
        defer { operationLock.unlock() }
        try cancellation.checkCancellation()
        return try operation()
    }

    // MARK: - Async-to-Sync Bridge

    /// Runs an async throwing closure synchronously using a semaphore.
    /// Used to bridge the sync `TrainingEngine` protocol to the async mlx-swift-lm API.
    ///
    /// The `nonisolated(unsafe)` usage is safe here because the semaphore ensures
    /// the Task completes before we read the result, providing a happens-before relationship.
    private static func runAsync<T>(
        _ work: @escaping @Sendable () async throws -> sending T
    ) -> Result<T, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error> = .failure(
            TrainingEngineError.trainingFailed("Async operation did not complete"))

        Task {
            do {
                let value = try await work()
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return result
    }
}


/// Which weights a prompt KV cache entry was built on, and the rules that
/// follow from it. Unloading the LoRA adapter restores the exact base weights,
/// so base-weight KV state survives any number of adapter switches; KV state
/// built with the adapter is valid only for that exact adapter state.
enum PromptCacheWeights {
    static let base = "base"

    /// `"base"` when the adapter is not installed (including a personalized
    /// request with no adapter), otherwise `"adapter#<generation>"`.
    static func identity(adapterInstalled: Bool, adapterGeneration: UInt64) -> String {
        adapterInstalled ? "adapter#\(adapterGeneration)" : base
    }

    /// The identity is its own `|`-joined component, so no `cacheKey` text
    /// can be mistaken for it.
    static func key(
        modelID: String,
        cacheKey: String,
        prefixTokenCount: Int,
        prefixFingerprint: String,
        weightIdentity: String
    ) -> String {
        [modelID, cacheKey, "\(prefixTokenCount)", prefixFingerprint, weightIdentity]
            .joined(separator: "|")
    }

    /// Whether an entry built on `weightIdentity` stays valid when the
    /// adapter's parameters change.
    static func survivesAdapterChange(weightIdentity: String) -> Bool {
        weightIdentity == base
    }

    /// Advances the adapter generation and removes every entry built with an
    /// adapter; base entries stay.
    static func invalidateAdapterEntries<Entry>(
        generation: inout UInt64,
        entries: inout [String: Entry],
        weightIdentity: (Entry) -> String
    ) {
        generation &+= 1
        entries = entries.filter { survivesAdapterChange(weightIdentity: weightIdentity($0.value)) }
    }
}
