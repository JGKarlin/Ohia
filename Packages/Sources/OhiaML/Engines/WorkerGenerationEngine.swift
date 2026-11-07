import Foundation
import os
import OhiaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let workerGenerationLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "workerGeneration"
)

/// `TrainingEngine` facade that forwards interactive text generation to the
/// qwen worker process. The UI process no longer keeps its own MLX model
/// loaded, so Ask must talk to the worker that owns the live model.
public final class WorkerGenerationEngine: @unchecked Sendable,
    PersonalizationScopedCancellablePrefixCachedGenerating,
    ConversationalGenerating
{
    /// Allows an exclusive-residency Mac enough time to unload BGE, load Qwen,
    /// and publish a ready heartbeat. Interactive requests also send an
    /// event-driven handoff command; this remains the missed-event backstop.
    public static let interactiveModelHandoffReadinessTimeout: TimeInterval = 30

    private let statusStore: WorkerStatusStore
    private let commandSubmitter: any WorkerCommandSubmitting
    private let liveCommandSubmitter: any WorkerLiveCommandSubmitting
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let statusMaxAge: TimeInterval
    private let readinessTimeout: TimeInterval
    private let requestStateLock = NSLock()
    private var activeRequestIDs: Set<UUID> = []
    private var cancelledRequestIDs: Set<UUID> = []
    private var publishedRequestIDs: Set<UUID> = []

    private enum WorkerReadiness {
        case ready
        case unavailable(String, isTransient: Bool)
    }

    public init(
        statusStore: WorkerStatusStore = WorkerStatusStore(),
        commandSubmitter: any WorkerCommandSubmitting = WorkerCommandTransport.shared,
        liveCommandSubmitter: any WorkerLiveCommandSubmitting = WorkerCommandTransport.shared,
        timeout: TimeInterval = 90,
        pollInterval: TimeInterval = 0.05,
        statusMaxAge: TimeInterval = 15,
        readinessTimeout: TimeInterval? = nil
    ) {
        self.statusStore = statusStore
        self.commandSubmitter = commandSubmitter
        self.liveCommandSubmitter = liveCommandSubmitter
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.statusMaxAge = statusMaxAge
        self.readinessTimeout = readinessTimeout ?? timeout
    }

    public var isModelLoaded: Bool {
        if case .ready = readiness() {
            return true
        } else {
            return false
        }
    }

    public var isAdapterLoaded: Bool { false }
    public var totalSteps: Int { 0 }
    public var isCancelled: Bool {
        requestStateLock.lock(); defer { requestStateLock.unlock() }
        return cancelledRequestIDs.isDisjoint(with: activeRequestIDs) == false
    }

    public func loadModel(path: String) throws {}

    public func trainStep(
        examples: [TrainingExample],
        learningRate: Double
    ) throws -> TrainingStepResult {
        throw TrainingEngineError.trainingFailed("WorkerGenerationEngine does not train.")
    }

    public func saveAdapter(to path: String) throws {}
    public func loadAdapter(from path: String) throws {}

    public func generate(
        conversation: GenerationConversation,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        personalization: GenerationPersonalizationScope
    ) throws -> GenerationResult {
        try generate(
            conversation: conversation,
            maxTokens: maxTokens,
            cancellation: cancellation,
            activityKind: .drafting,
            personalization: personalization
        )
    }

    public func generate(
        conversation: GenerationConversation,
        maxTokens: Int,
        cancellation: GenerationCancellation?,
        activityKind: WorkerGenerationActivityKind,
        personalization: GenerationPersonalizationScope
    ) throws -> GenerationResult {
        try generateResult(
            request: .conversation(conversation, maxTokens: maxTokens),
            cancellation: cancellation,
            lane: .userInteractive,
            activityKind: activityKind,
            leaseTTL: nil,
            personalization: personalization
        )
    }

    /// Plain, non-thinking generation with completion metadata intact.
    public func generateResult(
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        activityKind: WorkerGenerationActivityKind,
        personalization: GenerationPersonalizationScope,
        sampling: GenerationSampling? = nil
    ) throws -> GenerationResult {
        try generateResult(
            request: .plain(prompt: prompt, maxTokens: maxTokens),
            cancellation: cancellation,
            lane: .userInteractive,
            activityKind: activityKind,
            leaseTTL: nil,
            personalization: personalization,
            sampling: sampling
        )
    }

    public func generate(prompt: String, maxTokens: Int) throws -> String {
        try generate(
            request: .plain(prompt: prompt, maxTokens: maxTokens),
            cancellation: nil,
            lane: .userInteractive,
            activityKind: nil,
            leaseTTL: nil
        )
    }

    public func generate(
        prompt: String,
        maxTokens: Int,
        personalization: GenerationPersonalizationScope
    ) throws -> String {
        try generate(
            request: .plain(prompt: prompt, maxTokens: maxTokens),
            cancellation: nil,
            lane: .userInteractive,
            activityKind: nil,
            leaseTTL: nil,
            personalization: personalization
        )
    }

    public func generate(
        prompt: String,
        maxTokens: Int,
        activityKind: WorkerGenerationActivityKind,
        personalization: GenerationPersonalizationScope = .base
    ) throws -> String {
        try generate(
            request: .plain(prompt: prompt, maxTokens: maxTokens),
            cancellation: nil,
            lane: .userInteractive,
            activityKind: activityKind,
            leaseTTL: nil,
            personalization: personalization
        )
    }

    public func generate(
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation
    ) throws -> String {
        try generate(
            request: .plain(prompt: prompt, maxTokens: maxTokens),
            cancellation: cancellation,
            lane: .userInteractive,
            activityKind: nil,
            leaseTTL: nil
        )
    }

    public func generate(
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        personalization: GenerationPersonalizationScope
    ) throws -> String {
        try generate(
            request: .plain(prompt: prompt, maxTokens: maxTokens),
            cancellation: cancellation,
            lane: .userInteractive,
            activityKind: nil,
            leaseTTL: nil,
            personalization: personalization
        )
    }

    public func generate(
        prompt: String,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        lane: InteractiveGenerationLane,
        leaseTTL: TimeInterval? = nil,
        activityKind: WorkerGenerationActivityKind? = nil,
        personalization: GenerationPersonalizationScope = .base
    ) throws -> String {
        try generate(
            request: .plain(prompt: prompt, maxTokens: maxTokens),
            cancellation: cancellation,
            lane: lane,
            activityKind: activityKind,
            leaseTTL: leaseTTL,
            personalization: personalization
        )
    }

    /// Checkpointed counterpart of `generateResult(prompt: String, ...)`.
    public func generateResult(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        activityKind: WorkerGenerationActivityKind,
        personalization: GenerationPersonalizationScope,
        sampling: GenerationSampling? = nil
    ) throws -> GenerationResult {
        try generateResult(
            request: .prefixCached(prompt, maxTokens: maxTokens),
            cancellation: cancellation,
            lane: .userInteractive,
            activityKind: activityKind,
            leaseTTL: nil,
            personalization: personalization,
            sampling: sampling
        )
    }

    public func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int
    ) throws -> String {
        try generate(
            request: .prefixCached(prompt, maxTokens: maxTokens),
            cancellation: nil,
            lane: .userInteractive,
            activityKind: nil,
            leaseTTL: nil
        )
    }

    public func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        personalization: GenerationPersonalizationScope
    ) throws -> String {
        try generate(
            request: .prefixCached(prompt, maxTokens: maxTokens),
            cancellation: nil,
            lane: .userInteractive,
            activityKind: nil,
            leaseTTL: nil,
            personalization: personalization
        )
    }

    public func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation
    ) throws -> String {
        try generate(
            request: .prefixCached(prompt, maxTokens: maxTokens),
            cancellation: cancellation,
            lane: .userInteractive,
            activityKind: nil,
            leaseTTL: nil
        )
    }

    public func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        personalization: GenerationPersonalizationScope
    ) throws -> String {
        try generate(
            request: .prefixCached(prompt, maxTokens: maxTokens),
            cancellation: cancellation,
            lane: .userInteractive,
            activityKind: nil,
            leaseTTL: nil,
            personalization: personalization
        )
    }

    public func generate(
        prompt: PrefixCachedPrompt,
        maxTokens: Int,
        cancellation: GenerationCancellation,
        lane: InteractiveGenerationLane,
        leaseTTL: TimeInterval? = nil,
        activityKind: WorkerGenerationActivityKind? = nil,
        personalization: GenerationPersonalizationScope = .base,
        sampling: GenerationSampling? = nil
    ) throws -> String {
        try generate(
            request: .prefixCached(prompt, maxTokens: maxTokens),
            cancellation: cancellation,
            lane: lane,
            activityKind: activityKind,
            leaseTTL: leaseTTL,
            personalization: personalization,
            sampling: sampling
        )
    }

    private enum GenerationRequestKind {
        case plain(prompt: String, maxTokens: Int)
        case prefixCached(PrefixCachedPrompt, maxTokens: Int)
        case conversation(GenerationConversation, maxTokens: Int)

        var maxTokens: Int {
            switch self {
            case .plain(_, let maxTokens),
                 .prefixCached(_, let maxTokens),
                 .conversation(_, let maxTokens):
                return maxTokens
            }
        }

        func workerRequest(
            enqueuedAt: Date,
            deadline: Date,
            lane: InteractiveGenerationLane,
            activityKind: WorkerGenerationActivityKind?,
            personalization: GenerationPersonalizationScope,
            sampling: GenerationSampling?
        ) -> WorkerGenerationRequest {
            switch self {
            case .plain(let prompt, let maxTokens):
                return WorkerGenerationRequest(
                    prompt: prompt,
                    maxTokens: maxTokens,
                    lane: lane,
                    activityKind: activityKind,
                    personalization: personalization,
                    sampling: sampling,
                    enqueuedAt: enqueuedAt,
                    deadline: deadline
                )
            case .prefixCached(let prompt, let maxTokens):
                return WorkerGenerationRequest(
                    cachedPrompt: prompt,
                    maxTokens: maxTokens,
                    lane: lane,
                    activityKind: activityKind,
                    personalization: personalization,
                    sampling: sampling,
                    enqueuedAt: enqueuedAt,
                    deadline: deadline
                )
            case .conversation(let conversation, let maxTokens):
                return WorkerGenerationRequest(
                    conversation: conversation,
                    maxTokens: maxTokens,
                    lane: lane,
                    activityKind: activityKind,
                    personalization: personalization,
                    sampling: sampling,
                    enqueuedAt: enqueuedAt,
                    deadline: deadline
                )
            }
        }

        var label: String {
            switch self {
            case .plain: return "plain"
            case .prefixCached(let prompt, _): return prompt.cacheKey
            case .conversation: return "conversation"
            }
        }
    }

    private func generate(
        request: GenerationRequestKind,
        cancellation: GenerationCancellation?,
        lane: InteractiveGenerationLane,
        activityKind: WorkerGenerationActivityKind?,
        leaseTTL: TimeInterval?,
        personalization: GenerationPersonalizationScope = .base,
        sampling: GenerationSampling? = nil
    ) throws -> String {
        try generateResult(
            request: request,
            cancellation: cancellation,
            lane: lane,
            activityKind: activityKind,
            leaseTTL: leaseTTL,
            personalization: personalization,
            sampling: sampling
        ).text
    }

    private func generateResult(
        request: GenerationRequestKind,
        cancellation: GenerationCancellation?,
        lane: InteractiveGenerationLane,
        activityKind: WorkerGenerationActivityKind?,
        leaseTTL: TimeInterval?,
        personalization: GenerationPersonalizationScope = .base,
        sampling: GenerationSampling? = nil
    ) throws -> GenerationResult {
        try checkCancellation(cancellation)
        let requestID = UUID()
        registerRequest(requestID)
        defer { unregisterRequest(requestID) }

        let requestedAt = Date()
        let resolvedLeaseTTL = lane == .lensAssist
            ? min(leaseTTL ?? 30, 30)
            : (leaseTTL ?? timeout + readinessTimeout + 30)
        let interactiveLease: WorkerInteractiveGenerationSnapshot?
        do {
            interactiveLease = try statusStore.beginInteractiveGeneration(
                reason: request.label,
                lane: lane,
                ttl: resolvedLeaseTTL,
                at: requestedAt
            )
        } catch let leaseError as WorkerInteractiveGenerationLeaseError {
            throw leaseError
        } catch {
            interactiveLease = nil
        }
        if let interactiveLease {
            requestInteractiveQwenModelTurn(for: interactiveLease)
        }
        defer {
            if let interactiveLease {
                try? statusStore.endInteractiveGeneration(id: interactiveLease.id)
            }
        }

        switch try waitForReadiness(
            cancellation: cancellation,
            requestID: requestID
        ) {
        case .ready:
            break
        case .unavailable(let message, _):
            throw TrainingEngineError.modelUnavailable(message)
        }
        try checkCancellation(cancellation, requestID: requestID)

        let enqueuedAt = Date()
        let deadline = enqueuedAt.addingTimeInterval(timeout)
        let command = WorkerCommandSnapshot(
            id: requestID,
            kind: .generateText,
            issuedAt: enqueuedAt,
            message: "interactive generation request",
            generationRequest: request.workerRequest(
                enqueuedAt: enqueuedAt,
                deadline: deadline,
                lane: lane,
                activityKind: activityKind,
                personalization: personalization,
                sampling: sampling
            )
        )
        var workerSettledRequest = false
        defer {
            if !workerSettledRequest {
                sendCancellationCommand(for: command.id)
            }
        }
        let response = try publishGeneration(command, timeout: timeout)
        workerSettledRequest = true
        try checkCancellation(cancellation, requestID: command.id)
        logTimingBreakdown(
            label: request.label,
            maxTokens: request.maxTokens,
            enqueuedAt: enqueuedAt,
            response: response
        )
        return try resolve(response: response, expectedCommandID: command.id)
    }

    private func checkCancellation(
        _ cancellation: GenerationCancellation?,
        requestID: UUID? = nil
    ) throws {
        try Task.checkCancellation()
        try cancellation?.checkCancellation()
        if let requestID, isRequestCancelled(requestID) {
            throw CancellationError()
        }
    }

    private func logTimingBreakdown(
        label: String,
        maxTokens: Int,
        enqueuedAt: Date,
        response: WorkerGenerationResponseSnapshot
    ) {
        let totalMs = Int(((response.completedAt.timeIntervalSince(enqueuedAt)) * 1000).rounded())
        if let pickedUpAt = response.pickedUpAt,
           let decodeStartedAt = response.decodeStartedAt,
           let decodeFinishedAt = response.decodeFinishedAt {
            let pickupMs = Int(((pickedUpAt.timeIntervalSince(enqueuedAt)) * 1000).rounded())
            let decodeMs = Int(((decodeFinishedAt.timeIntervalSince(decodeStartedAt)) * 1000).rounded())
            let workerOverheadMs = Int(((decodeStartedAt.timeIntervalSince(pickedUpAt)) * 1000).rounded())
            let returnMs = Int(((response.completedAt.timeIntervalSince(decodeFinishedAt)) * 1000).rounded())
            let outputChars = response.text?.count ?? 0
            workerGenerationLogger.info(
                "qwen call maxTokens=\(maxTokens, privacy: .public) totalMs=\(totalMs, privacy: .public) pickupMs=\(pickupMs, privacy: .public) workerOverheadMs=\(workerOverheadMs, privacy: .public) decodeMs=\(decodeMs, privacy: .public) returnMs=\(returnMs, privacy: .public) outputChars=\(outputChars, privacy: .public)"
            )
        } else {
            workerGenerationLogger.info(
                "qwen call maxTokens=\(maxTokens, privacy: .public) totalMs=\(totalMs, privacy: .public) (legacy worker, no detailed timing)"
            )
        }
    }

    public func cancel() {
        requestStateLock.lock()
        let requestIDs = activeRequestIDs
        cancelledRequestIDs.formUnion(requestIDs)
        let publishedRequestIDs = requestIDs.intersection(self.publishedRequestIDs)
        requestStateLock.unlock()

        for requestID in publishedRequestIDs {
            sendCancellationCommand(for: requestID)
        }
    }

    public func resetCancellation() {
        requestStateLock.lock(); defer { requestStateLock.unlock() }
        cancelledRequestIDs.formIntersection(activeRequestIDs)
    }

    private func registerRequest(_ requestID: UUID) {
        requestStateLock.lock(); defer { requestStateLock.unlock() }
        activeRequestIDs.insert(requestID)
    }

    private func publishGeneration(
        _ command: WorkerCommandSnapshot,
        timeout: TimeInterval
    ) throws -> WorkerGenerationResponseSnapshot {
        requestStateLock.lock()
        publishedRequestIDs.insert(command.id)
        let shouldCancel = cancelledRequestIDs.contains(command.id)
        requestStateLock.unlock()
        if shouldCancel {
            sendCancellationCommand(for: command.id)
        }
        return try liveCommandSubmitter.submitGeneration(command, timeout: timeout)
    }

    private func unregisterRequest(_ requestID: UUID) {
        requestStateLock.lock(); defer { requestStateLock.unlock() }
        activeRequestIDs.remove(requestID)
        cancelledRequestIDs.remove(requestID)
        publishedRequestIDs.remove(requestID)
    }

    private func isRequestCancelled(_ requestID: UUID) -> Bool {
        requestStateLock.lock(); defer { requestStateLock.unlock() }
        return cancelledRequestIDs.contains(requestID)
    }

    private func sendCancellationCommand(for requestID: UUID) {
        do {
            try commandSubmitter.submit(
                WorkerCommandSnapshot(
                    kind: .cancelGeneration,
                    message: "interactive generation cancellation",
                    targetCommandID: requestID
                ),
                to: .qwen
            )
        } catch {
            workerGenerationLogger.error(
                "failed to enqueue qwen cancellation requestID=\(requestID.uuidString, privacy: .public) error=\(String(reflecting: type(of: error)), privacy: .public)"
            )
        }
    }

    /// Wake the retrieval helper immediately so low-memory devices can release
    /// BGE before this caller's readiness deadline. The command is advisory:
    /// the BGE worker rechecks its device policy, and the normal lease-based
    /// scheduler path remains the fallback if this submission fails.
    private func requestInteractiveQwenModelTurn(
        for lease: WorkerInteractiveGenerationSnapshot
    ) {
        do {
            try commandSubmitter.submit(
                WorkerCommandSnapshot(
                    kind: .requestInteractiveQwenModelTurn,
                    issuedAt: lease.startedAt,
                    message: lease.reason
                ),
                to: .bge
            )
        } catch {
            workerGenerationLogger.error(
                "failed to request interactive Qwen model turn error=\(String(reflecting: type(of: error)), privacy: .public)"
            )
        }
    }

    private func readiness() -> WorkerReadiness {
        guard let snapshot = try? statusStore.snapshot(for: .qwen) else {
            return .unavailable(
                "Generative Worker has not reported status yet.",
                isTransient: true
            )
        }

        switch snapshot.state {
        case .failed:
            return .unavailable(
                snapshot.statusMessage ?? "Generative Worker failed.",
                isTransient: false
            )
        case .stopped, .stopping:
            return .unavailable(
                "Generative Worker is \(snapshot.state.rawValue).",
                isTransient: true
            )
        default:
            break
        }

        let hasFreshStatus = Date().timeIntervalSince(snapshot.updatedAt) <= statusMaxAge

        if snapshot.model?.state.isReady == true {
            // Long Qwen decodes can outlive the heartbeat freshness window.
            // If the ready worker process is still alive, enqueue the
            // interactive command instead of surfacing a transient status age
            // as user-visible hover text.
            guard hasFreshStatus || Self.isProcessAlive(snapshot.pid) else {
                return .unavailable("Generative Worker status is stale.", isTransient: true)
            }
            return .ready
        }

        guard hasFreshStatus else {
            return .unavailable("Generative Worker status is stale.", isTransient: true)
        }

        if let model = snapshot.model {
            return Self.unavailableMessage(for: model, worker: snapshot)
        }

        if let statusMessage = snapshot.statusMessage, !statusMessage.isEmpty {
            return .unavailable(
                "Generative Worker is \(statusMessage).",
                isTransient: true
            )
        }

        return .unavailable(
            "Generative Worker has not reported a model yet.",
            isTransient: true
        )
    }

    private static func isProcessAlive(_ pid: Int32?) -> Bool {
        guard let pid, pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func waitForReadiness(
        cancellation: GenerationCancellation?,
        requestID: UUID
    ) throws -> WorkerReadiness {
        let deadline = Date().addingTimeInterval(max(0, readinessTimeout))
        var latest = readiness()
        while Date() < deadline {
            try checkCancellation(cancellation, requestID: requestID)
            switch latest {
            case .ready:
                return latest
            case .unavailable(_, let isTransient):
                guard isTransient else { return latest }
                Thread.sleep(forTimeInterval: pollInterval)
                try checkCancellation(cancellation, requestID: requestID)
                latest = readiness()
            }
        }
        return latest
    }

    private static func unavailableMessage(
        for model: WorkerModelStatusSnapshot,
        worker: WorkerStatusSnapshot
    ) -> WorkerReadiness {
        switch model.state {
        case .ready:
            return .unavailable("\(model.name) is ready.", isTransient: true)
        case .downloading(let fraction):
            let percent = Int((min(1, max(0, fraction)) * 100).rounded())
            if percent == 0 {
                return .unavailable(
                    "Generative model \(model.name) is preparing local files.",
                    isTransient: true
                )
            }
            return .unavailable(
                "Generative model \(model.name) is downloading (\(percent)%).",
                isTransient: true
            )
        case .downloaded:
            return .unavailable(
                "Generative model \(model.name) is downloaded and waiting to load.",
                isTransient: true
            )
        case .loading:
            return .unavailable(
                "Generative model \(model.name) is loading.",
                isTransient: true
            )
        case .paused(let message):
            return .unavailable(
                message ?? "Generative model \(model.name) download is stopped. Resume it in Settings.",
                isTransient: true
            )
        case .failed(let message):
            return .unavailable(
                "Generative model \(model.name) failed: \(message)",
                isTransient: false
            )
        case .unavailable:
            if let statusMessage = worker.statusMessage, !statusMessage.isEmpty {
                return .unavailable(
                    "Generative Worker is \(statusMessage).",
                    isTransient: true
                )
            }
            if let modelMessage = model.message, !modelMessage.isEmpty {
                return .unavailable(modelMessage, isTransient: true)
            }
            return .unavailable(
                "Generative model \(model.name) is unavailable.",
                isTransient: true
            )
        }
    }

    private func resolve(
        response: WorkerGenerationResponseSnapshot,
        expectedCommandID: UUID
    ) throws -> GenerationResult {
        guard response.commandID == expectedCommandID else {
            throw TrainingEngineError.generationFailed("Generative worker returned a mismatched response.")
        }

        switch response.status {
        case .success:
            return GenerationResult(
                text: response.text ?? "",
                reasoningContent: response.reasoningContent,
                continuationFingerprint: response.continuationFingerprint,
                stopReason: response.stopReason,
                diagnostics: response.diagnostics,
                personalization: response.personalization
            )
        case .cancelled:
            throw CancellationError()
        case .modelNotLoaded:
            throw TrainingEngineError.modelUnavailable(
                response.errorMessage ?? "Generative model is not loaded."
            )
        case .failed:
            throw TrainingEngineError.generationFailed(
                response.errorMessage ?? "Generative worker failed to generate text."
            )
        }
    }
}
