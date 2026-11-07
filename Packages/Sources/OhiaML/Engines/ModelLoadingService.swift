// ModelLoadingService.swift
// Observable service that downloads and loads the MLX model at app startup,
// reporting progress so the UI can show a status indicator.

import Foundation
import SwiftData

/// State of the currently-selected LLM model.
public enum ModelLoadState: Sendable, Equatable {
    case idle
    case downloading(fraction: Double)
    case downloaded
    case loading            // download done, MLX weights being loaded
    case paused(String?)
    case ready
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isPreparingModel: Bool {
        switch self {
        case .downloading, .loading:
            return true
        case .idle, .downloaded, .paused, .ready, .failed:
            return false
        }
    }

    public var shortLabel: String {
        switch self {
        case .idle: "not loaded"
        case .downloading(let f): "downloading \(Int(f * 100))%"
        case .downloaded: "downloaded"
        case .loading: "loading…"
        case .paused: "stopped"
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}

/// The model-preparation surface needed by `ModelLoadingService`. Keeping this
/// boundary smaller than the concrete MLX engine lets shutdown behavior be
/// exercised without constructing real model weights.
protocol ModelLoadingEngine: TrainingEngine {
    func unloadModel()
    func downloadModelAsync(
        modelId: String,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws
    func loadModelAsync(
        modelId: String,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws
}

extension MLXTrainingEngine: ModelLoadingEngine {}

/// Observable service that orchestrates model download + load.
/// Create once at app startup, call `start()` to begin loading.
@Observable
@MainActor
public final class ModelLoadingService {

    public private(set) var state: ModelLoadState = .idle
    public private(set) var selectedModel: ModelInfo
    public private(set) var pendingModel: ModelInfo?

    public var preparationModel: ModelInfo {
        pendingModel ?? selectedModel
    }

    public var isPreparingPendingSwitch: Bool {
        pendingModel != nil
    }

    private let engine: any ModelLoadingEngine
    private let trainingStatusPublisher: TrainingStatusPublisher?
    private let checkpointDirectory: URL?
    private let modelDownloadBaseDirectory: URL?
    private var prefetchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var operationTask: Task<Result<Void, Error>, Never>?
    private var operationID: UUID?
    private var resourceDrainTask: Task<Void, Never>?

    public convenience init(
        engine: MLXTrainingEngine,
        model: ModelInfo? = nil,
        trainingStatusPublisher: TrainingStatusPublisher? = nil,
        checkpointDirectory: URL? = nil,
        modelDownloadBaseDirectory: URL? = nil
    ) {
        self.init(
            modelLoadingEngine: engine,
            model: model,
            trainingStatusPublisher: trainingStatusPublisher,
            checkpointDirectory: checkpointDirectory,
            modelDownloadBaseDirectory: modelDownloadBaseDirectory
        )
    }

    init(
        modelLoadingEngine: any ModelLoadingEngine,
        model: ModelInfo? = nil,
        trainingStatusPublisher: TrainingStatusPublisher? = nil,
        checkpointDirectory: URL? = nil,
        modelDownloadBaseDirectory: URL? = nil
    ) {
        self.engine = modelLoadingEngine
        self.selectedModel = model ?? ModelManager.selectedGenerationModelForCurrentHardware()
        self.trainingStatusPublisher = trainingStatusPublisher
        self.checkpointDirectory = checkpointDirectory
        self.modelDownloadBaseDirectory = modelDownloadBaseDirectory
    }

    /// Change the model to load. Cancels any in-flight load first.
    public func setModel(_ model: ModelInfo) {
        cancel()
        if selectedModel.modelId != model.modelId {
            engine.unloadModel()
            trainingStatusPublisher?.setEngineReady(false)
        }
        selectedModel = model
        pendingModel = nil
        state = .idle
    }

    /// Stage a model change without dropping the currently-loaded model during
    /// the download phase. The old model is unloaded only for the final MLX
    /// load handoff, then the pending selection is promoted after success.
    public func prepareModelSwitch(to model: ModelInfo) {
        cancel()
        if selectedModel.modelId == model.modelId {
            pendingModel = nil
            state = engine.isModelLoaded ? .ready : .idle
            return
        }

        pendingModel = model
        state = .idle
    }

    /// Begin the download + load process. Idempotent for in-flight or ready states.
    /// Call sites that need the boot-time adapter load also pass `context`.
    public func start(context: ModelContext? = nil) {
        guard resourceDrainTask == nil else { return }
        if case .ready = state { return }
        if case .downloading = state { return }
        if case .loading = state { return }

        prefetchTask?.cancel()
        prefetchTask = nil

        let targetModel = preparationModel
        let targetID = targetModel.modelId
        let previousModel = pendingModel == nil ? nil : selectedModel
        let hasPreviousModel = previousModel != nil
        let operationID = UUID()
        self.operationID = operationID
        let alreadyDownloaded = Self.isModelDownloaded(
            state: state,
            downloadBaseDirectory: modelDownloadBaseDirectory,
            modelID: targetID
        )
        if alreadyDownloaded {
            ModelManager.clearStoppedGenerationModelDownload()
        }
        state = alreadyDownloaded ? .loading : .downloading(fraction: 0)

        // Register the detached constructor during this initiating MainActor
        // turn. If shutdown starts before its body is scheduled, cancellation
        // and the operation-ID check below prevent it from entering MLX. More
        // importantly, a drain can never snapshot `operationTask == nil` while
        // a later-scheduled outer task still has authority to create it.
        let (progressStream, continuation) = AsyncStream<Double>.makeStream()
        let modelOperationTask = Task.detached { [engine] in
            do {
                try Task.checkCancellation()
                let operationIsCurrent = await MainActor.run {
                    self.operationID == operationID && !Task.isCancelled
                }
                guard operationIsCurrent else { throw CancellationError() }

                if hasPreviousModel, !alreadyDownloaded {
                    try await engine.downloadModelAsync(modelId: targetID) { fraction in
                        continuation.yield(fraction)
                    }
                }

                try Task.checkCancellation()
                continuation.yield(1.0)
                if hasPreviousModel {
                    let handoffIsCurrent = await MainActor.run {
                        guard self.operationID == operationID, !Task.isCancelled else {
                            return false
                        }
                        self.state = .loading
                        engine.unloadModel()
                        self.trainingStatusPublisher?.setEngineReady(false)
                        return true
                    }
                    guard handoffIsCurrent else { throw CancellationError() }
                }

                try Task.checkCancellation()
                let loadIsCurrent = await MainActor.run {
                    self.operationID == operationID && !Task.isCancelled
                }
                guard loadIsCurrent else { throw CancellationError() }
                try await engine.loadModelAsync(modelId: targetID) { fraction in
                    continuation.yield(
                        Self.displayFractionForLoadModelProgress(
                            fraction,
                            alreadyDownloaded: alreadyDownloaded,
                            hasPreviousModel: hasPreviousModel
                        )
                    )
                }
                try Task.checkCancellation()
                continuation.finish()
                return Result<Void, Error>.success(())
            } catch {
                continuation.finish()
                return Result<Void, Error>.failure(error)
            }
        }
        self.operationTask = modelOperationTask

        loadTask = Task { [engine, trainingStatusPublisher, checkpointDirectory] in
            // AsyncStream bridges the @Sendable progress callback from the
            // downloader into @MainActor state updates on the service.
            for await fraction in progressStream {
                guard self.operationID == operationID, !Task.isCancelled else { return }
                self.state = Self.stateForDownloadProgress(
                    fraction,
                    alreadyDownloaded: alreadyDownloaded
                )
            }

            guard self.operationID == operationID, !Task.isCancelled else { return }
            switch await modelOperationTask.value {
            case .success:
                guard self.operationID == operationID, !Task.isCancelled else { return }
                self.selectedModel = targetModel
                self.pendingModel = nil
                // Boot-time adapter load — only if we have a publisher, context,
                // and checkpoint directory. Failure is non-fatal.
                if let pub = trainingStatusPublisher,
                   let dir = checkpointDirectory,
                   let ctx = context {
                    let loader = BootAdapterLoader(engine: engine, checkpointDirectory: dir, publisher: pub)
                    try? await loader.loadLatestAdapterIfAvailable(context: ctx)
                }
                guard self.operationID == operationID, !Task.isCancelled else { return }
                self.state = .ready
                self.operationTask = nil
                self.operationID = nil
                _ = ModelManager.promotePendingGenerationModelIfMatches(targetID)
            case .failure(let error):
                guard self.operationID == operationID, !Task.isCancelled else { return }
                self.operationTask = nil
                self.operationID = nil
                if let previousModel {
                    await restorePreviousModel(
                        previousModel,
                        failedTarget: targetModel,
                        error: error,
                        engine: engine,
                        trainingStatusPublisher: trainingStatusPublisher,
                        checkpointDirectory: checkpointDirectory,
                        context: context
                    )
                } else {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Download the selected model into Ohia's cache without loading it into
    /// memory. This lets onboarding begin the large one-time transfer as soon
    /// as the user confirms account/language/model choices, while the heavier
    /// MLX load can still wait for the normal resource gate.
    public func prefetch() {
        guard resourceDrainTask == nil else { return }
        switch state {
        case .idle, .paused, .failed:
            break
        case .downloading, .downloaded, .loading, .ready:
            return
        }

        let targetID = preparationModel.modelId
        if Self.isModelDownloaded(
            state: state,
            downloadBaseDirectory: modelDownloadBaseDirectory,
            modelID: targetID
        ) {
            ModelManager.clearStoppedGenerationModelDownload()
            state = .downloaded
            return
        }
        let operationID = UUID()
        self.operationID = operationID
        state = .downloading(fraction: 0)

        let (progressStream, continuation) = AsyncStream<Double>.makeStream()
        let downloadOperationTask = Task.detached { [engine] in
            do {
                try Task.checkCancellation()
                let operationIsCurrent = await MainActor.run {
                    self.operationID == operationID && !Task.isCancelled
                }
                guard operationIsCurrent else { throw CancellationError() }
                try await engine.downloadModelAsync(modelId: targetID) { fraction in
                    continuation.yield(fraction)
                }
                try Task.checkCancellation()
                continuation.finish()
                return Result<Void, Error>.success(())
            } catch {
                continuation.finish()
                return Result<Void, Error>.failure(error)
            }
        }
        self.operationTask = downloadOperationTask

        prefetchTask = Task {
            for await fraction in progressStream {
                guard self.operationID == operationID, !Task.isCancelled else { return }
                let progress = min(1, max(0, fraction))
                self.state = progress >= 1 ? .downloaded : .downloading(fraction: progress)
            }

            guard self.operationID == operationID, !Task.isCancelled else { return }
            switch await downloadOperationTask.value {
            case .success:
                self.operationTask = nil
                self.operationID = nil
                self.state = .downloaded
            case .failure(let error):
                guard self.operationID == operationID, !Task.isCancelled else { return }
                self.operationTask = nil
                self.operationID = nil
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func restorePreviousModel(
        _ previousModel: ModelInfo,
        failedTarget: ModelInfo,
        error: Error,
        engine: any ModelLoadingEngine,
        trainingStatusPublisher: TrainingStatusPublisher?,
        checkpointDirectory: URL?,
        context: ModelContext?
    ) async {
        let failureDetail = error.localizedDescription
        if engine.isModelLoaded {
            selectedModel = previousModel
            pendingModel = failedTarget
            state = .failed("Failed to load \(failedTarget.displayName): \(failureDetail). Restored \(previousModel.displayName).")
            trainingStatusPublisher?.setEngineReady(true)
            return
        }

        do {
            try await engine.loadModelAsync(modelId: previousModel.modelId) { _ in }
            if let trainingStatusPublisher,
               let checkpointDirectory,
               let context {
                let loader = BootAdapterLoader(
                    engine: engine,
                    checkpointDirectory: checkpointDirectory,
                    publisher: trainingStatusPublisher
                )
                try? await loader.loadLatestAdapterIfAvailable(context: context)
            }
            selectedModel = previousModel
            pendingModel = failedTarget
            state = .failed("Failed to load \(failedTarget.displayName): \(failureDetail). Restored \(previousModel.displayName).")
            trainingStatusPublisher?.setEngineReady(true)
        } catch {
            selectedModel = previousModel
            pendingModel = failedTarget
            state = .failed("Failed to load \(failedTarget.displayName): \(failureDetail). Could not restore \(previousModel.displayName): \(error.localizedDescription)")
            trainingStatusPublisher?.setEngineReady(false)
        }
    }

    public func cancel() {
        requestPreparationCancellationForDrain()
        prefetchTask = nil
        loadTask = nil
        operationTask = nil
    }

    /// Requests cooperative cancellation without discarding the task handles.
    /// Worker shutdown uses this synchronous phase to stop new work promptly;
    /// its async teardown then awaits those same handles before releasing the
    /// cross-process model-memory lease.
    public func requestPreparationCancellationForDrain() {
        prefetchTask?.cancel()
        loadTask?.cancel()
        operationTask?.cancel()
        operationID = nil
    }

    public func pauseDownload() {
        let wasDownloaded: Bool
        let wasReady: Bool
        switch state {
        case .downloaded:
            wasDownloaded = true
            wasReady = false
        case .ready:
            wasDownloaded = false
            wasReady = true
        default:
            wasDownloaded = false
            wasReady = false
        }

        cancel()

        if wasReady {
            state = .ready
        } else if wasDownloaded {
            state = .downloaded
        } else {
            state = .paused("Download stopped. Select Resume Download to continue.")
        }
        trainingStatusPublisher?.setEngineReady(engine.isModelLoaded)
    }

    nonisolated static func isModelDownloaded(
        state: ModelLoadState,
        downloadBaseDirectory: URL?,
        modelID: String
    ) -> Bool {
        if case .downloaded = state {
            return true
        }
        guard let downloadBaseDirectory else { return false }
        return GenerationModelStorage.isModelDownloaded(
            downloadBaseDirectory: downloadBaseDirectory,
            modelID: modelID
        )
    }

    nonisolated static func displayFractionForLoadModelProgress(
        _ fraction: Double,
        alreadyDownloaded: Bool,
        hasPreviousModel: Bool
    ) -> Double {
        if alreadyDownloaded || hasPreviousModel {
            return 1
        }
        return fraction
    }

    nonisolated static func stateForDownloadProgress(
        _ fraction: Double,
        alreadyDownloaded: Bool
    ) -> ModelLoadState {
        if fraction >= 1.0 || alreadyDownloaded {
            return .loading
        }
        if fraction > 0 {
            return .downloading(fraction: fraction)
        }
        return .downloading(fraction: 0)
    }

    /// Cancels model preparation, drains every in-flight download/load task,
    /// and only then reports the model as released. Cross-process residency
    /// arbitration must retain its lease until this method returns because a
    /// cancelled MLX load can temporarily keep partially-built weights alive.
    /// The resulting state is restartable on a later resource turn.
    public func unloadForResourcePressureAndDrain() async {
        if let resourceDrainTask {
            await resourceDrainTask.value
            return
        }

        let stateAfterUnload = Self.stateAfterResourceUnload(
            from: state,
            modelWasLoaded: engine.isModelLoaded
        )
        let pendingPrefetchTask = prefetchTask
        let pendingLoadTask = loadTask
        let pendingOperationTask = operationTask

        requestPreparationCancellationForDrain()
        engine.cancel()
        // Invalidating the load generation prevents a cancelled operation
        // from installing its result while the task winds down.
        engine.unloadModel()

        // Publish the shared drain before the first suspension point. Every
        // reentrant caller must await this task; otherwise a second call could
        // observe cleared preparation handles and release the model slot while
        // the first caller is still waiting for MLX construction to unwind.
        let drainTask = Task { @MainActor [engine, trainingStatusPublisher] in
            if let pendingOperationTask {
                _ = await pendingOperationTask.value
            }
            if let pendingLoadTask {
                await pendingLoadTask.value
            }
            if let pendingPrefetchTask {
                await pendingPrefetchTask.value
            }

            // A second unload is cheap and makes the postcondition explicit
            // even if cancellation raced the constructor before it observed
            // the invalidated generation.
            engine.unloadModel()
            trainingStatusPublisher?.setEngineReady(false)
            self.prefetchTask = nil
            self.loadTask = nil
            self.operationTask = nil
            self.state = stateAfterUnload
        }
        resourceDrainTask = drainTask
        await drainTask.value
        resourceDrainTask = nil
    }

    nonisolated static func stateAfterResourceUnload(
        from state: ModelLoadState,
        modelWasLoaded: Bool
    ) -> ModelLoadState {
        switch state {
        case .ready, .loading:
            return .downloaded
        case .idle:
            return modelWasLoaded ? .downloaded : .idle
        case .downloading:
            // The task is cancelled by the unload, so retaining `.downloading`
            // would leave the service claiming an operation that no longer runs.
            return .idle
        case .downloaded:
            return .downloaded
        case .paused(let message):
            return .paused(message)
        case .failed(let message):
            return .failed(message)
        }
    }

    public func suspendForResourcePressure() {
        cancel()
        if !engine.isModelLoaded {
            if case .downloaded = state {
                state = .downloaded
            } else {
                state = .idle
            }
        }
    }
}

/// Loads the newest compatible, promoted checkpoint's adapter into the engine
/// after the base model finishes loading. Decoupled from `ModelLoadingService`
/// so tests can exercise it without standing up the full download machinery.
@MainActor
public struct BootAdapterLoader: Sendable {
    private let engine: TrainingEngine
    private let checkpointManager: CheckpointManager
    private let publisher: TrainingStatusPublisher

    public init(engine: TrainingEngine, checkpointDirectory: URL, publisher: TrainingStatusPublisher) {
        self.engine = engine
        self.checkpointManager = CheckpointManager(checkpointDirectory: checkpointDirectory)
        self.publisher = publisher
    }

    /// Idempotent: if no compatible promoted checkpoint exists, returns without
    /// touching the engine or publisher. A load failure quarantines that row,
    /// preserves its bytes, and falls back through older compatible promoted
    /// checkpoints before accepting base weights.
    public func loadLatestAdapterIfAvailable(context: ModelContext) async throws {
        // Pre-sweep malformed or missing artifacts before compatibility
        // selection so they cannot repeatedly reach the loader.
        let quarantinedCount = (try? checkpointManager.sweepOrphanRows(context: context)) ?? 0
        if quarantinedCount > 0 {
            print("[Ohia] personalization: quarantined \(quarantinedCount) invalid checkpoint row(s) at boot")
        }

        var latestLoadError: String?
        guard let latest = try await checkpointManager.resumeFromLatest(
            engine: engine,
            context: context,
            onLoadFailure: { _, error in
                latestLoadError = error.localizedDescription
            }
        ) else {
            if let latestLoadError {
                let message = "adapter load failed — running on base weights: \(latestLoadError)"
                publisher.recordError(message)
                print("[Ohia] ⚠ personalization: adapter load failed; running on base weights")
            }
            return
        }
        publisher.setAdapterLoaded(step: latest.stepCount, at: Date())
        if publisher.lastError?.hasPrefix("adapter load failed") == true {
            publisher.clearError()
        }
        print("[Ohia] personalization: compatible adapter loaded @ step \(latest.stepCount)")
    }
}
