import Darwin
import Foundation
import SwiftData
import OhiaCore
import OhiaML
import OhiaScheduler
import OhiaMail

struct RetrievalModelReleaseAction: Equatable, Sendable {
    let includeBGE: Bool
    let reason: String
}

enum QwenModelResidencyAction: Equatable, Sendable {
    case none
    case releaseReusableMemory
    case unloadForCriticalMemory
    case yieldToRetrievalWorker
}

struct QwenModelHandoffDecision: Equatable, Sendable {
    let backgroundLoadingGated: Bool
    let action: QwenModelResidencyAction
}

enum QwenModelPreparationAction: Equatable, Sendable {
    case none
    case prefetch
    case waitForExclusiveTurn
    case start
}

enum ActiveGenerationTaskMonitor {
    static func wait<Value: Sendable>(
        for generationTask: Task<Value, Error>,
        cancellation: GenerationCancellation,
        deadline: Date?,
        pollInterval: Duration = .milliseconds(75),
        now: @escaping @Sendable () -> Date = { Date() },
        shouldCancel: @escaping @Sendable () async -> Bool
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await generationTask.value
            }
            group.addTask {
                while !Task.isCancelled {
                    if let deadline, now() >= deadline {
                        cancellation.cancel()
                        generationTask.cancel()
                        throw CancellationError()
                    }
                    if await shouldCancel() {
                        cancellation.cancel()
                        generationTask.cancel()
                        throw CancellationError()
                    }
                    try await Task.sleep(for: pollInterval)
                }
                throw CancellationError()
            }

            do {
                guard let value = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return value
            } catch {
                cancellation.cancel()
                generationTask.cancel()
                group.cancelAll()
                throw error
            }
        }
    }
}

enum ActivePipelineHeartbeatRenewer {
    static let interval: Duration = .seconds(5)

    static func run(
        interval: Duration = interval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        renew: @escaping @Sendable () async -> Bool
    ) async {
        while !Task.isCancelled {
            do {
                try await sleep(interval)
            } catch {
                return
            }
            guard !Task.isCancelled, await renew() else { return }
        }
    }

    static func refresh(
        statusStore: WorkerStatusStore,
        role: OhiaCore.WorkerRole,
        pid: Int32,
        jobType: String,
        at date: Date = Date()
    ) -> Bool {
        do {
            guard let snapshot = try statusStore.snapshot(for: role),
                  snapshot.pid == pid,
                  snapshot.currentJobType == jobType else {
                return false
            }
            _ = try statusStore.heartbeat(
                role: role,
                pid: snapshot.pid,
                parentPID: snapshot.parentPID,
                state: snapshot.state,
                currentJobType: snapshot.currentJobType,
                currentJobDescription: snapshot.currentJobDescription,
                promptUsage: snapshot.promptUsage,
                throttle: snapshot.throttle,
                statusMessage: snapshot.statusMessage,
                model: snapshot.model,
                training: snapshot.training,
                resource: snapshot.resource,
                completionStreamID: snapshot.completionStreamID,
                at: date
            )
            return true
        } catch {
            return true
        }
    }
}

final class ActivePipelineHeartbeatLease: @unchecked Sendable {
    private let lock = NSLock()
    private var activeID: UUID?

    func begin() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        activeID = id
        return id
    }

    func end() {
        lock.lock()
        activeID = nil
        lock.unlock()
    }

    func performIfCurrent<T>(_ id: UUID, _ operation: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard activeID == id else { return nil }
        return operation()
    }
}

enum WorkerXPCCommandCompletion: Equatable, Sendable {
    case completed(Data?)
    case failed(String)
    case notExecuted(String)
}

/// Retains out-of-order cancellation IDs long enough to meet the matching
/// live request without allowing late or invalid IDs to grow worker memory
/// without bound.
struct WorkerDirectCancellationRegistry: Sendable {
    private var expirations: [UUID: Date] = [:]
    private let retention: TimeInterval
    private let capacity: Int

    init(retention: TimeInterval = 120, capacity: Int = 512) {
        self.retention = max(1, retention)
        self.capacity = max(1, capacity)
    }

    mutating func insert(_ id: UUID, at date: Date = Date()) {
        expirations = expirations.filter { $0.value > date }
        while expirations.count >= capacity,
              let oldest = expirations.min(by: {
                  if $0.value == $1.value {
                      return $0.key.uuidString < $1.key.uuidString
                  }
                  return $0.value < $1.value
              })?.key {
            expirations.removeValue(forKey: oldest)
        }
        expirations[id] = date.addingTimeInterval(retention)
    }

    func contains(_ id: UUID, at date: Date = Date()) -> Bool {
        guard let expiration = expirations[id] else { return false }
        return expiration > date
    }

    mutating func remove(_ id: UUID) {
        expirations.removeValue(forKey: id)
    }
}

private final class PipelinePromptUsageGate: @unchecked Sendable {
    private let lock = NSLock()
    private var composerGenerationIsRunning = false

    func setCurrentJob(_ jobType: JobType?) {
        lock.lock()
        composerGenerationIsRunning = jobType == .generateDraft
        lock.unlock()
    }

    var acceptsComposerPromptUsage: Bool {
        lock.lock()
        defer { lock.unlock() }
        return composerGenerationIsRunning
    }
}

@MainActor
final class WorkerIdleWakeGate {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct ActiveWait {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let sleep: Sleep
    private var activeWait: ActiveWait?

    init(
        sleep: @escaping Sleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.sleep = sleep
    }

    func wait(for duration: Duration) async {
        activeWait?.task.cancel()

        let id = UUID()
        let sleep = sleep
        let task = Task {
            do {
                try Task.checkCancellation()
                try await sleep(duration)
            } catch is CancellationError {
                // Waking idle work is a normal control-flow edge.
            } catch {
                print("[OhiaWorker] idle sleep failed: \(String(reflecting: type(of: error)))")
            }
        }
        activeWait = ActiveWait(id: id, task: task)

        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        if activeWait?.id == id {
            activeWait = nil
        }
    }

    func wake() {
        activeWait?.task.cancel()
    }
}

@MainActor
public final class OhiaWorkerRuntime {
    private struct PendingXPCCommand {
        let command: WorkerCommandSnapshot
        let priority: TaskPriority
        let completion: @Sendable (WorkerXPCCommandCompletion) -> Void
    }

    private struct ActiveGenerationHeartbeat {
        let description: String
        let promptUsage: WorkerPromptUsageSnapshot?
    }

    private let role: WorkerRole
    private let completionStreamID = UUID()
    private let usesXPCCommandTransport: Bool
    private let modelContainer: ModelContainer
    private let appServices: AppServices
    private let manualProjectMembershipCoordinator: ManualProjectMembershipCoordinator
    private let imapSessionManager: IMAPSessionManager
    private let scheduler: BackgroundScheduler
    private let modelLoader: ModelLoadingService?
    private let mcpCredentialStore: MCPWorkerCredentialStore
    /// Foreground generation outranks scheduler heartbeat projections until
    /// its response is written. Without this, the worker's periodic loop can
    /// overwrite the `generation` status (and prompt usage) mid-decode.
    private var activeGenerationHeartbeat: ActiveGenerationHeartbeat?
    /// Tokenizer-backed prompt usage emitted by the worker-local MLX engine
    /// while the authoritative Composer `.generateDraft` job is running.
    private var pipelinePromptUsage: WorkerPromptUsageSnapshot?
    private var currentPipelineJobType: JobType?
    private let pipelinePromptUsageGate = PipelinePromptUsageGate()
    private let appActivityMonitor: SharedAppActivityMonitor
    private let completionBroadcaster: JobCompletionBroadcaster
    private let lockURL: URL
    private let statusStore: WorkerStatusStore
    private let exclusiveModelSlotLock: ExclusiveModelSlotLock
    private let storageLayout: OhiaStorageLayout
    private let parentPID: Int32?
    private var lockFD: Int32 = -1
    private var shouldStop = false
    private var mailActionTasks: [Task<Void, Never>] = []
    private var imapShutdownTask: Task<Void, Never>?
    private var imapStarted = false
    private var bgeModelLoading = false
    private var retrievalModelConstructionInFlight = false
    private var interactiveRetrievalModelDemand = false
    private var qwenBackgroundModelLoadingGated = false
    private var qwenModelTransitionInProgress = false
    private var exclusiveModelSlotLease: ExclusiveModelSlotLease?
    /// Cross-process request encoded as a `.throttled` heartbeat. A helper
    /// raises it only after the sibling actually owns the exclusive low-memory
    /// model turn, avoiding a cold-start tie where both helpers wait forever.
    private var exclusiveModelTurnRequested = false
    private var pipelineWorkStarted = false
    private var pipelineDeferredLogged = false
    private let activePipelineHeartbeatLease = ActivePipelineHeartbeatLease()
    private var activePipelineHeartbeatTask: Task<Void, Never>?
    private var retrievalModelLoadTask: Task<Void, Never>?
    private var retrievalModelLoadOperationID: UUID?
    private var completionBridgeTask: Task<Void, Never>?
    private var commandMonitorTask: Task<Void, Never>?
    private var xpcCommandDrainTask: Task<Void, Never>?
    private var pendingXPCCommands: [PendingXPCCommand] = []
    private var activeXPCCommand: WorkerCommandSnapshot?
    private var liveResponseData: [UUID: Data] = [:]
    private var heartbeatWriteGate = WorkerHeartbeatWriteGate(
        maximumInterval: .seconds(1)
    )
    private let idleWakeGate = WorkerIdleWakeGate()
    private var acceptsXPCCommands = false
    private var directlyCancelledGenerationCommandIDs = WorkerDirectCancellationRegistry()
    private var directlyCancelledQueryEmbeddingCommandIDs = WorkerDirectCancellationRegistry()
    private var signalSources: [DispatchSourceSignal] = []
    private var parentExitSource: DispatchSourceProcess?

    public init(
        role: WorkerRole,
        usesXPCCommandTransport: Bool = false,
        messagesTranscriptProvider: any MessagesTranscriptProviding = UnavailableMessagesTranscriptProvider(),
        mailCredentialResolver: any MailCredentialRequesting & MailPasswordResolving = UnavailableMailCredentialResolver(),
        mcpCredentialSnapshot: MCPWorkerCredentialSnapshot = .empty
    ) throws {
        self.role = role
        self.usesXPCCommandTransport = usesXPCCommandTransport
        let mcpCredentialStore = MCPWorkerCredentialStore(snapshot: mcpCredentialSnapshot)
        self.mcpCredentialStore = mcpCredentialStore

        let storageLayout = try OhiaStorageRoot.resolve()
        try FileManager.default.createDirectory(
            at: storageLayout.workerCoordination,
            withIntermediateDirectories: true
        )
        self.storageLayout = storageLayout
        self.lockURL = storageLayout.workerCoordination.appendingPathComponent(role.lockFilename)
        let statusDirectory = Self.statusDirectoryURL(storageLayout: storageLayout)
        self.statusStore = WorkerStatusStore(
            directoryURL: statusDirectory
        )
        self.exclusiveModelSlotLock = ExclusiveModelSlotLock(
            // Keep the inode outside WorkerStatusStore's resettable runtime
            // directory; unlinking a held flock file would create a second,
            // independently lockable inode at the same path.
            directoryURL: storageLayout.workerCoordination
        )
        self.parentPID = Self.parentPIDFromEnvironment()
        self.appActivityMonitor = SharedAppActivityMonitor(
            snapshotURL: SharedAppActivityMonitor.snapshotURL(
                appSupportDirectory: storageLayout.workerCoordination
            )
        )

        let schema = Schema(OhiaSchema.models)
        let config = ModelConfiguration("Ohia", schema: schema, url: storageLayout.swiftDataStore)
        self.modelContainer = try ModelContainer(for: schema, configurations: [config])
        let manualProjectMembershipCoordinator = ManualProjectMembershipCoordinator(
            container: modelContainer,
            textReader: ProjectTextFileReader()
        )
        self.manualProjectMembershipCoordinator = manualProjectMembershipCoordinator

        let services = try AppServices(
            storageLayout: storageLayout,
            runtimeRole: role == .qwen ? .generativeWorker : .retrievalWorker
        )
        self.appServices = services
        let completionBroadcaster = JobCompletionBroadcaster()
        self.completionBroadcaster = completionBroadcaster
        if let mlx = services.engineSelector.primary as? MLXTrainingEngine {
            let checkpointDir = services.personalizedModelDirectory
            let loader = ModelLoadingService(
                engine: mlx,
                trainingStatusPublisher: services.trainingStatusPublisher,
                checkpointDirectory: checkpointDir,
                modelDownloadBaseDirectory: services.generationModelDownloadBaseDirectory
            )
            if role == .qwen {
                if let pendingID = ModelManager.pendingGenerationModelID() {
                    let selectedID = ModelManager.selectedGenerationModelID()
                    let compatiblePending = ModelManager.compatibleModels(memoryBytes: ModelManager.hardwareInfo().memoryBytes)
                        .contains(where: { $0.modelId == pendingID })
                    if pendingID == selectedID || !compatiblePending {
                        ModelManager.clearPendingGenerationModel()
                    } else if let pendingModel = ModelManager.allModels.first(where: { $0.modelId == pendingID }) {
                        loader.prepareModelSwitch(to: pendingModel)
                    }
                }
                let preparationModelID = loader.preparationModel.modelId
                if ModelManager.isGenerationModelDownloadStopped(for: preparationModelID) {
                    if GenerationModelStorage.isModelDownloaded(
                        downloadBaseDirectory: services.generationModelDownloadBaseDirectory,
                        modelID: preparationModelID
                    ) {
                        ModelManager.clearStoppedGenerationModelDownload()
                    } else {
                        loader.pauseDownload()
                    }
                }
            }
            self.modelLoader = loader
        } else {
            self.modelLoader = nil
        }

        let oauthStore = OAuthTokenStore(
            brokerClient: OAuthTokenBrokerClient(requester: mailCredentialResolver)
        )
        self.imapSessionManager = IMAPSessionManager(
            modelContext: modelContainer.mainContext,
            oauthStore: oauthStore,
            passwordResolver: mailCredentialResolver,
            canonicalStore: services.canonicalStore,
            vectorStore: services.vectorStore,
            neighborsStore: services.vectorNeighborsStore,
            frameLayoutStore: services.vectorFrameLayoutStore,
            clusterStore: services.vectorClusterStore,
            liveInboundBroadcaster: completionBroadcaster,
            deletionSyncStatusPublisher: services.deletionSyncStatusPublisher,
            onManualProjectSourceChange: Self.manualProjectSourceChangeHandler(
                coordinator: manualProjectMembershipCoordinator
            )
        )

        self.scheduler = try Self.makeScheduler(
            role: role,
            services: services,
            modelContainer: modelContainer,
            imapSessionManager: imapSessionManager,
            manualProjectMembershipCoordinator: manualProjectMembershipCoordinator,
            appActivityMonitor: appActivityMonitor,
            completionBroadcaster: completionBroadcaster,
            statusStore: statusStore,
            messagesTranscriptProvider: messagesTranscriptProvider,
            mailCredentialResolver: mailCredentialResolver,
            oauthStore: oauthStore,
            mcpCredentialStore: mcpCredentialStore
        )
        self.scheduler.currentJobReporter = { [weak self] jobType in
            self?.reportCurrentPipelineJob(jobType)
        }
        if role == .bge {
            let statusStore = statusStore
            let activityStreamID = completionStreamID
            imapSessionManager.setIMAPActivityReporter { activity in
                var lastErrorType: String?
                for attempt in 0..<3 {
                    do {
                        try statusStore.appendIMAPActivity(
                            activity,
                            role: .bge,
                            imapActivityStreamID: activityStreamID
                        )
                        return
                    } catch {
                        lastErrorType = String(reflecting: type(of: error))
                        if attempt < 2 {
                            Thread.sleep(forTimeInterval: 0.02)
                        }
                    }
                }
                if let lastErrorType {
                    fputs(
                        "[OhiaWorker] Failed to persist IMAP activity after 3 attempts errorKind=\(lastErrorType)\n",
                        stderr
                    )
                }
            }
        }
        services.trainingStatusPublisher.setWorkerSnapshotReporter { [weak self] _ in
            guard let self else { return }
            let jobType = self.currentPipelineJobType
            self.writeHeartbeat(
                state: .running,
                currentJobType: jobType?.rawValue,
                currentJobDescription: jobType.map {
                    "pipeline: \(Self.pipelineStatusLabel(for: $0))"
                },
                promptUsage: self.pipelinePromptUsage
            )
        }
        if let mlx = services.engineSelector.primary as? MLXTrainingEngine {
            let promptUsageGate = pipelinePromptUsageGate
            let statusStore = statusStore
            let coreRole = role.coreRole
            let parentPID = parentPID
            mlx.setGenerationPromptUsageReporter { [weak self] usage in
                guard promptUsageGate.acceptsComposerPromptUsage else { return }
                // PipelineRunner and DraftGenerationOrchestrator are
                // MainActor-isolated and invoke this synchronous MLX decode
                // directly. Persist here, before hopping actors, so the gauge
                // is visible during the decode rather than only after it.
                try? statusStore.heartbeat(
                    role: coreRole,
                    pid: getpid(),
                    parentPID: parentPID,
                    state: .running,
                    currentJobType: JobType.generateDraft.rawValue,
                    currentJobDescription: "pipeline: drafting",
                    promptUsage: usage
                )
                Task { @MainActor [weak self] in
                    self?.recordPipelinePromptUsage(usage)
                }
            }
        }
    }

    private func recordPipelinePromptUsage(_ usage: WorkerPromptUsageSnapshot) {
        guard role == .qwen, currentPipelineJobType == .generateDraft else {
            return
        }
        pipelinePromptUsage = usage
        writeHeartbeat(
            state: .running,
            currentJobType: JobType.generateDraft.rawValue,
            currentJobDescription: "pipeline: \(Self.pipelineStatusLabel(for: .generateDraft))",
            promptUsage: usage
        )
    }

    private func reportCurrentPipelineJob(_ jobType: JobType?) {
        stopActivePipelineHeartbeatRenewal()
        currentPipelineJobType = jobType
        pipelinePromptUsageGate.setCurrentJob(jobType)
        if jobType != .generateDraft {
            pipelinePromptUsage = nil
        }
        let description = jobType.map {
            "pipeline: \(Self.pipelineStatusLabel(for: $0))"
        }
        writeHeartbeat(
            state: jobType == nil ? .busy : .running,
            currentJobType: jobType?.rawValue,
            currentJobDescription: description,
            promptUsage: pipelinePromptUsage
        )
        guard let jobType else { return }
        startActivePipelineHeartbeatRenewal(for: jobType)
    }

    private func startActivePipelineHeartbeatRenewal(for jobType: JobType) {
        let leaseID = activePipelineHeartbeatLease.begin()
        let lease = activePipelineHeartbeatLease
        let statusStore = statusStore
        let coreRole = role.coreRole
        let pid = getpid()
        let rawJobType = jobType.rawValue
        activePipelineHeartbeatTask = Task.detached(priority: .utility) {
            await ActivePipelineHeartbeatRenewer.run {
                lease.performIfCurrent(leaseID) {
                    ActivePipelineHeartbeatRenewer.refresh(
                        statusStore: statusStore,
                        role: coreRole,
                        pid: pid,
                        jobType: rawJobType
                    )
                } ?? false
            }
        }
    }

    private func stopActivePipelineHeartbeatRenewal() {
        activePipelineHeartbeatTask?.cancel()
        activePipelineHeartbeatLease.end()
        activePipelineHeartbeatTask = nil
    }

    private static func pipelineStatusLabel(for jobType: JobType) -> String {
        switch jobType {
        case .summarize:
            return "Qwen mail analysis"
        case .summarizeAttachments:
            return "attachment summaries"
        case .prepareReplySources:
            return "compiling sources"
        case .generateDraft:
            return "drafting"
        case .generateDraftingRules:
            return "learning"
        default:
            return jobType.rawValue
        }
    }

    public func run() async throws {
        installSignalHandlers()
        installParentExitMonitor()
        guard acquireWorkerLock() else {
            print("\(role.logPrefix) another worker already owns \(lockURL.path); exiting")
            return
        }
        defer { releaseWorkerLock() }
        do {
            try SessionActivityLog.shared.attachToSession(directoryURL: storageLayout.workerState)
        } catch {
            print("\(role.logPrefix) activity log unavailable: \(String(reflecting: type(of: error)))")
        }
        defer { shutdownRoleServices() }
        defer { retrievalModelLoadTask?.cancel() }
        defer { stopActivePipelineHeartbeatRenewal() }
        defer { modelLoader?.cancel() }
        defer { completionBridgeTask?.cancel() }
        defer { commandMonitorTask?.cancel() }
        defer { xpcCommandDrainTask?.cancel() }
        defer { finishPendingXPCCommands(message: "worker runtime stopped") }
        defer { parentExitSource?.cancel() }
        defer { markStopped() }

        let parentDescription = parentPID.map(String.init) ?? "none"
        print("\(role.logPrefix) starting pid=\(getpid()) parent=\(parentDescription)")
        writeHeartbeat(state: .starting)
        startCompletionBridge()
        if usesXPCCommandTransport {
            // Commands left by an interrupted older helper are recovery input,
            // not the live transport. Drain them once before accepting XPC.
            await drainPendingCommands()
            acceptsXPCCommands = true
            startXPCCommandDrainIfNeeded()
        } else {
            startCommandMonitor()
        }

        if role == .bge {
            try runStartupMigrations()
        }
        try await prepareRoleServices()

        try startPipelineWorkIfPreparationAllowed()
        if role == .bge {
            scheduler.usesIndependentMailActions = true
            mailActionTasks = BackgroundScheduler.independentMailActionTypes.map { type in
              Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, !self.shouldStop else { return }
                    do {
                        if Self.isOnboardingPipelinePreparationAllowed() {
                            _ = try await self.scheduler.tickMailAction(type: type, context: self.makeSchedulerContext())
                        }
                        try await Task.sleep(for: .seconds(1))
                    } catch is CancellationError {
                        return
                    } catch {
                        print("\(self.role.logPrefix) \(type) tick failed: \(String(reflecting: Swift.type(of: error)))")
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    }
                }
              }
            }
        }
        defer { mailActionTasks.forEach { $0.cancel() } }
        writeHeartbeat(state: .idle)

        let reseedInterval: TimeInterval = 10
        let maxTicksPerCycle = 16
        var nextSeedAt = Date().addingTimeInterval(reseedInterval)

        while !Task.isCancelled, !shouldStop {
            if parentProcessExited() {
                print("\(role.logPrefix) parent pid \(parentPID ?? -1) exited; stopping")
                writeHeartbeat(state: .stopping, message: "parent process exited")
                break
            }

            var didAnyWork = false
            do {
                let pipelinePreparationAllowed = Self.isOnboardingPipelinePreparationAllowed()
                if pipelinePreparationAllowed {
                    try startPipelineWorkIfPreparationAllowed()
                    for _ in 0..<maxTicksPerCycle {
                        if Date() >= nextSeedAt {
                            try seedRolePipeline()
                            nextSeedAt = Date().addingTimeInterval(reseedInterval)
                        }

                        var didWork = try await tickRolePipeline()
                        if !didWork && !scheduler.isPaused {
                            try seedRolePipeline()
                            nextSeedAt = Date().addingTimeInterval(reseedInterval)
                            didWork = try await tickRolePipeline()
                        }
                        guard didWork else { break }
                        didAnyWork = true
                        await Task.yield()
                    }

                    if Self.isOnboardingPipelineReleased() {
                        startIMAPSyncIfReady()
                        prepareGenerationContextPacksIfReady()
                    }
                } else if !pipelineDeferredLogged {
                    pipelineDeferredLogged = true
                    print("\(role.logPrefix) pipeline deferred until onboarding completes")
                }

                startRetrievalModelLoadingTaskIfReady()
                prepareQwenModelIfReady()
                await applyMemoryPressureProtection()
                releaseExclusiveModelSlotIfUnused()
            } catch {
                print("\(role.logPrefix) tick error: \(String(reflecting: type(of: error)))")
            }

            writeHeartbeat(
                state: exclusiveModelTurnRequested ? .throttled : (didAnyWork ? .busy : .idle),
                message: exclusiveModelTurnRequested ? "waiting for model memory turn" : nil
            )
            let sleepDuration: Duration = didAnyWork
                ? .milliseconds(100)
                : (Self.isOnboardingPipelinePreparationAllowed() ? .seconds(5) : .seconds(1))
            guard !Task.isCancelled, !shouldStop else { break }
            await idleWakeGate.wait(for: sleepDuration)
        }

        scheduler.isPaused = true
        mailActionTasks.forEach { $0.cancel() }
        beginIMAPShutdown()
        await imapShutdownTask?.value
        for task in mailActionTasks { await task.value }
        mailActionTasks.removeAll()
        acceptsXPCCommands = false
        xpcCommandDrainTask?.cancel()
        if let xpcCommandDrainTask {
            await xpcCommandDrainTask.value
        }
        await shutdownResidentModelResources()
        try? modelContainer.mainContext.save()
        print("\(role.logPrefix) stopped")
    }

    private func shutdownResidentModelResources() async {
        switch role {
        case .bge:
            await cancelAndDrainRetrievalModelLoadingTask()
            bgeModelLoading = false
            await releaseRetrievalModelResourcesAndSlot(
                includeBGE: true,
                reason: "worker shutdown"
            )
        case .qwen:
            await unloadQwenModel(reason: "worker shutdown")
        }
        releaseExclusiveModelSlotIfUnused()
    }

    private func startPipelineWorkIfPreparationAllowed() throws {
        guard Self.isOnboardingPipelinePreparationAllowed() else { return }
        guard !pipelineWorkStarted else { return }
        try scheduler.resetStaleRunningJobs(context: makeSchedulerContext(), workerRole: role.coreRole)
        if role == .bge {
            appServices.reconcileVectorIndexInBackground()
        }
        try seedRolePipeline()
        pipelineWorkStarted = true
        print("\(role.logPrefix) seeded pipeline")
    }

    private static func isOnboardingPipelinePreparationAllowed() -> Bool {
        OnboardingPipelineGate.allowsPreparation(defaults: OnboardingPipelineGate.sharedDefaults())
    }

    private static func isOnboardingPipelineReleased() -> Bool {
        OnboardingPipelineGate.isReleased(defaults: OnboardingPipelineGate.sharedDefaults())
    }

    private static func makeScheduler(
        role: WorkerRole,
        services: AppServices,
        modelContainer: ModelContainer,
        imapSessionManager: IMAPSessionManager,
        manualProjectMembershipCoordinator: ManualProjectMembershipCoordinator,
        appActivityMonitor: SharedAppActivityMonitor,
        completionBroadcaster: JobCompletionBroadcaster,
        statusStore: WorkerStatusStore,
        messagesTranscriptProvider: any MessagesTranscriptProviding,
        mailCredentialResolver: any MailPasswordResolving,
        oauthStore: OAuthTokenStore,
        mcpCredentialStore: MCPWorkerCredentialStore
    ) throws -> BackgroundScheduler {
        let layoutOrchestrator = try? LayoutOrchestrator(
            vectorStore: services.vectorStore,
            neighborsStore: services.vectorNeighborsStore,
            frameLayoutStore: services.vectorFrameLayoutStore
        )
        let frameBurstWorker: FrameBurstWorker?
        if role == .bge, let layoutOrchestrator {
            frameBurstWorker = FrameBurstWorker(
                orchestrator: layoutOrchestrator,
                edgeProvider: MessageGraphEdgeProvider(
                    messageStoreURL: services.messageStoreURL,
                    vectorStore: services.vectorStore
                ),
                contextAccessor: { [modelContainer] in
                    Self.makeSchedulerContext(modelContainer: modelContainer)
                }
            )
        } else {
            frameBurstWorker = nil
        }
        // Throwing init: the worker owns a Metal-backed KNNBuilder. Like the
        // layout orchestrator above, Metal-less environments run without
        // cluster detection rather than failing scheduler construction.
        let clusterDetectionWorker = try? ClusterDetectionWorker(
            vectorStore: services.vectorStore,
            frameLayoutStore: services.vectorFrameLayoutStore,
            clusterStore: services.vectorClusterStore,
            featureStore: services.vectorMeaningFeatureStore,
            meaningScopeContinuation: {
                let snapshot = appActivityMonitor.snapshot()
                return snapshot.isFresh() && snapshot.isMeaningLensEnabled
            },
            meaningPublicationContinuation: { inputFingerprint in
                let activity = appActivityMonitor.snapshot()
                guard activity.isFresh(), activity.isMeaningLensEnabled else {
                    return false
                }
                let context = Self.makeSchedulerContext(modelContainer: modelContainer)
                let status = PipelineReadiness.meaningClusterStatus(
                    context: context,
                    vectorStore: services.vectorStore,
                    clusterStore: services.vectorClusterStore,
                    messageStoreURL: services.messageStoreURL,
                    currentEmbeddingVersion: services.embedderRegistry.current.embeddingVersion,
                    initialImportWorkPending: PipelineReadiness.initialImportWorkIsPending(
                        context: context
                    )
                )
                guard status.sourceDataIsSettled,
                      let currentCorpus = try? services.vectorStore
                        .placedContextSummaryVectorsRaw() else {
                    return false
                }
                return ClusterDetectionWorker.corpusFingerprint(
                    ascendingVectorIds: currentCorpus.map(\.id)
                ) == inputFingerprint
            },
            meaningCanonicalTagIdentityProvider: { messageIDs in
                let requested = Set(messageIDs.map { $0.lowercased() })
                guard !requested.isEmpty else { return [:] }
                let context = Self.makeSchedulerContext(modelContainer: modelContainer)
                let messages = try context.fetch(FetchDescriptor<Message>())
                var identitiesByMessageID: [String: [String]] = [:]
                for message in messages {
                    let messageID = message.id.uuidString.lowercased()
                    guard requested.contains(messageID),
                          let dimensionsJSON = message.analysis?.dimensionsJSON,
                          let data = dimensionsJSON.data(using: .utf8),
                          let dimensions = try? JSONDecoder().decode(
                              MessageDimensions.self,
                              from: data
                          ) else {
                        continue
                    }
                    let identities = SemanticTagProjectionPresentation
                        .canonical(dimensions.semanticTags)
                        .map { $0.tagID.uuidString.lowercased() }
                    if !identities.isEmpty {
                        identitiesByMessageID[messageID] = identities
                    }
                }
                return identitiesByMessageID
            }
        )
        let localDeletionCascade = MessageLocalDeletionCascade(
            vectorStore: services.vectorStore,
            neighborsStore: services.vectorNeighborsStore,
            frameLayoutStore: services.vectorFrameLayoutStore,
            clusterStore: services.vectorClusterStore,
            canonicalStore: services.canonicalStore
        )

        return BackgroundScheduler(
            monitor: LiveSystemMonitor(),
            canonicalStore: services.canonicalStore,
            vectorStore: services.vectorStore,
            vectorIndex: services.vectorIndex,
            embedder: services.embedder,
            embedderRegistry: services.embedderRegistry,
            hybridRetriever: services.hybridRetriever,
            migrationCoordinator: services.migrationCoordinator,
            embeddingOrchestrator: services.makeEmbeddingOrchestrator(),
            engine: services.engineSelector.primary,
            sendExecutor: SMTPSendExecutor(
                passwordResolver: mailCredentialResolver,
                oauthStore: oauthStore
            ),
            trainingStatusPublisher: services.trainingStatusPublisher,
            modelActivityStatusPublisher: services.modelActivityStatusPublisher,
            toolRegistry: services.toolRegistry,
            generationContextPackStore: role == .qwen ? services.generationContextPackStore : nil,
            requiresGenerationContextPack: role == .qwen,
            imapSessionManager: imapSessionManager,
            layoutOrchestrator: layoutOrchestrator,
            frameBurstWorker: frameBurstWorker,
            clusterDetectionWorker: clusterDetectionWorker,
            entityOrchestrator: services.makeEntityOrchestrator(),
            allowsIMAPWork: Self.allowsIMAPWork,
            allowsVisiblePlacement: Self.isOnboardingPipelineReleased,
            appActivityMonitor: appActivityMonitor,
            broadcaster: completionBroadcaster,
            onManualProjectSourceChange: Self.manualProjectSourceChangeHandler(
                coordinator: manualProjectMembershipCoordinator
            ),
            messageStoreURL: services.messageStoreURL,
            checkpointDirectory: services.personalizedModelDirectory,
            workerRole: role.coreRole,
            mailActionReachability: PathMonitorReachability(),
            siblingModelWorkerActive: Self.siblingModelWorkerActiveClosure(
                role: role,
                statusStore: statusStore
            ),
            siblingModelResident: Self.siblingModelResidentClosure(
                role: role,
                statusStore: statusStore
            ),
            interactiveQwenGenerationActive: { [statusStore] in
                statusStore.isInteractiveGenerationActive()
            },
            interactiveQwenGenerationLane: { [statusStore] in
                statusStore.interactiveGenerationLane()
            },
            messagesTranscriptProvider: messagesTranscriptProvider,
            mcpEnvironmentResolver: { [mcpCredentialStore] record in
                mcpCredentialStore.environment(for: record.id)
            },
            idleThreshold: 300,
            localDeletionCascade: localDeletionCascade
        )
    }

    public func replaceMCPEnvironment(
        _ snapshot: MCPWorkerCredentialSnapshot
    ) async {
        guard role == .qwen else { return }
        let affectedServerIDs = mcpCredentialStore.replace(snapshot)
        for serverID in affectedServerIDs {
            await MCPSessionManager.shared.invalidate(id: serverID)
        }
    }

    public func mcpEnvironment(for serverID: UUID) -> [String: String] {
        mcpCredentialStore.environment(for: serverID)
    }

    private static func manualProjectSourceChangeHandler(
        coordinator: ManualProjectMembershipCoordinator?
    ) -> @MainActor @Sendable (Set<UUID>, Set<MailProjectRuleFacet>) -> Void {
        { messageIDs, facets in
            guard let coordinator else { return }
            Task {
                await coordinator.reconcile(
                    messageIDs: messageIDs,
                    changedFacets: facets
                )
            }
        }
    }

    private func prepareRoleServices() async throws {
        switch role {
        case .bge:
            appServices.startCrossEncoderDownloadIfNeeded()
            startRetrievalModelLoadingTaskIfReady()
            if Self.isOnboardingPipelineReleased() {
                startIMAPSyncIfReady()
                repairLayoutIfNeeded()
            }
        case .qwen:
            synchronizeTrainingStatusFromStore()
            prepareQwenModelIfReady()
        }
    }

    private func synchronizeTrainingStatusFromStore() {
        let state = TrainingRunState.current(context: makeSchedulerContext())
        appServices.trainingStatusPublisher.syncFromState(state)
        appServices.trainingStatusPublisher.setEngineReady(
            appServices.engineSelector.primary.isModelLoaded
        )
    }

    private func shutdownRoleServices() {
        guard role == .bge else { return }
        appServices.shutdown()
    }

    private func seedRolePipeline() throws {
        try scheduler.ensurePipelineJobsExist(context: makeSchedulerContext())
    }

    private func tickRolePipeline() async throws -> Bool {
        // Base weights become resident before the boot adapter is qualified.
        // Neither training nor generation may borrow that engine mid-selection.
        guard role != .qwen || modelLoader?.state != .loading else { return false }
        return try await scheduler.tick(context: makeSchedulerContext())
    }

    /// Scheduler passes need to observe writes made by the app process while the
    /// worker is already alive, such as the account persisted by onboarding.
    /// Use a short-lived context instead of rolling back `mainContext`, which is
    /// also held by live services such as the IMAP session manager.
    internal static func makeSchedulerContext(modelContainer: ModelContainer) -> ModelContext {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        return context
    }

    private func makeSchedulerContext() -> ModelContext {
        Self.makeSchedulerContext(modelContainer: modelContainer)
    }

    private func runStartupMigrations() throws {
        let context = modelContainer.mainContext
        try AccountMigrationApplier(modelContext: context).run()
        try IdentityMigrationApplier(modelContext: context).run()
    }

    private func startIMAPSyncIfReady() {
        guard role == .bge, !imapStarted, !shouldStop else { return }
        guard Self.isOnboardingPipelineReleased() else { return }
        imapStarted = true
        imapSessionManager.start(
            allowsIMAPWork: Self.allowsIMAPWork()
        )
        print("\(role.logPrefix) IMAP sync started")
    }

    private static func allowsIMAPWork() -> Bool {
        OnboardingPipelineGate.isReleased(
            defaults: OnboardingPipelineGate.sharedDefaults()
        )
    }

    private static func hasCompletedFirstIngestion() -> Bool {
        OnboardingPipelineGate.sharedDefaults()
            .bool(forKey: OnboardingPipelineGate.hasCompletedFirstIngestionKey)
    }

    private func prepareQwenModelIfReady() {
        guard role == .qwen,
              let modelLoader,
              Self.qwenPreparationMayStart(
                modelTransitionInProgress: qwenModelTransitionInProgress,
                downloadStopped: ModelManager.isGenerationModelDownloadStopped(
                    for: modelLoader.preparationModel.modelId
                )
              ) else {
            return
        }
        if modelLoader.isPreparingPendingSwitch,
           qwenGenerationIsActive {
            if Self.pendingModelSwitchPreparationAction(
                modelLoadState: modelLoader.state,
                generationIsActive: true
            ) == .prefetch {
                startModelPrefetchIfNeeded()
            }
            return
        }
        if Self.isQwenModelLoadAllowed() {
            startModelLoadingIfReady()
        } else {
            startModelPrefetchIfNeeded()
        }
    }

    private static func isQwenModelLoadAllowed() -> Bool {
        OnboardingPipelineGate.allowsQwenModelLoad(
            defaults: OnboardingPipelineGate.sharedDefaults()
        )
    }

    private func startModelPrefetchIfNeeded() {
        guard role == .qwen,
              let modelLoader,
              Self.qwenModelPrefetchIsEligible(modelLoadState: modelLoader.state) else {
            return
        }
        modelLoader.prefetch()
        print("\(role.logPrefix) model download started: \(modelLoader.preparationModel.displayName)")
    }

    /// Acquires the kernel-backed model-memory slot before either helper can
    /// construct weights. Heartbeats coordinate who should yield; this lock is
    /// the atomic safety boundary when both processes observe an empty slot at
    /// the same time.
    private func acquireExclusiveModelSlotIfNeeded(
        requiresExclusiveModelResidency: Bool,
        reason: String
    ) -> Bool {
        guard requiresExclusiveModelResidency else { return true }
        if exclusiveModelSlotLease?.isHeld == true { return true }

        do {
            guard let lease = try exclusiveModelSlotLock.tryAcquire() else {
                exclusiveModelTurnRequested = true
                return false
            }
            exclusiveModelSlotLease = lease
            exclusiveModelTurnRequested = false
            print("\(role.logPrefix) acquired exclusive model slot")
            return true
        } catch {
            // Lock-open/acquisition errors fail closed: loading without the
            // lease could put both large model sets in unified memory.
            exclusiveModelTurnRequested = true
            print("\(role.logPrefix) exclusive model slot unavailable: \(String(reflecting: type(of: error)))")
            return false
        }
    }

    private func releaseExclusiveModelSlot(reason: String) {
        guard let lease = exclusiveModelSlotLease else { return }
        lease.release()
        exclusiveModelSlotLease = nil
        print("\(role.logPrefix) released exclusive model slot")
    }

    private func releaseExclusiveModelSlotIfUnused() {
        guard exclusiveModelSlotLease?.isHeld == true else { return }

        let ownsModelMemory: Bool
        switch role {
        case .bge:
            ownsModelMemory = bgeModelLoading
                || retrievalModelConstructionInFlight
                || embeddingProviderUnavailable == false
                || appServices.crossEncoderReranker != nil
        case .qwen:
            ownsModelMemory = appServices.engineSelector.primary.isModelLoaded
                || modelLoader?.state == .loading
        }
        if !ownsModelMemory {
            releaseExclusiveModelSlot(reason: "model resources became nonresident")
        }
    }

    private func startModelLoadingIfReady() {
        guard role == .qwen,
              let modelLoader,
              Self.qwenPreparationMayStart(
                modelTransitionInProgress: qwenModelTransitionInProgress,
                downloadStopped: ModelManager.isGenerationModelDownloadStopped(
                    for: modelLoader.preparationModel.modelId
                )
              ) else {
            return
        }
        let interactiveLane = statusStore.interactiveGenerationLane()
        switch modelLoader.state {
        case .downloading, .loading, .ready:
            exclusiveModelTurnRequested = false
            return
        case .idle, .downloaded, .failed:
            break
        case .paused:
            return
        }
        let context = makeSchedulerContext()
        let resourceSnapshot = scheduler.refreshModelResourceSnapshot(context: context)
        let decision = resourceSnapshot.decision
        let preparationAction = Self.qwenModelPreparationAction(
            requiresExclusiveModelResidency: decision.requiresExclusiveModelResidency,
            modelLoadState: modelLoader.state,
            exclusiveModelTurnAvailable: false
        )
        switch preparationAction {
        case .none:
            return
        case .prefetch:
            // Network transfer does not own the exclusive model slot. Stop
            // here so a later `.downloaded` tick must arbitrate again before
            // `start()` can instantiate MLX weights.
            exclusiveModelTurnRequested = false
            startModelPrefetchIfNeeded()
            return
        case .waitForExclusiveTurn, .start:
            break
        }
        let hasModelDemand = interactiveLane != nil
            || scheduler.hasQwenModelDemand(
                context: context,
                resourceSnapshot: resourceSnapshot
            )
        let siblingResident = Self.siblingModelIsResident(
            snapshot: try? statusStore.snapshot(for: .bge),
            now: Date()
        )
        let wasRequestingTurn = exclusiveModelTurnRequested
        if wasRequestingTurn,
           siblingResident == false,
           decision.throttleReasons.contains(.workerMemoryGuard) {
            // The sibling has dropped its weights but has not yet replaced
            // the active/request heartbeat that triggered the handoff. Keep
            // our request raised for one more observation so neither helper
            // treats the stale heartbeat as a new competing turn.
            qwenBackgroundModelLoadingGated = true
            return
        }
        exclusiveModelTurnRequested = Self.exclusiveModelTurnRequest(
            requiresExclusiveModelResidency: decision.requiresExclusiveModelResidency,
            ownModelResident: false,
            siblingModelResident: siblingResident,
            hasModelDemand: hasModelDemand
        )
        if exclusiveModelTurnRequested {
            qwenBackgroundModelLoadingGated = true
            return
        }
        if wasRequestingTurn, siblingResident == false {
            // The BGE heartbeat acknowledged our request by dropping its
            // weights. This Qwen turn is now safe to claim.
            qwenBackgroundModelLoadingGated = false
        } else if decision.requiresExclusiveModelResidency,
                  (scheduler.hasBGEModelDemand(context: context)
                    || hasPendingGenerationContextPackDemand(context: context)),
                  interactiveLane == nil {
            // BGE owns the initial/background retrieval turn. Qwen will ask
            // for a turn only after BGE publishes resident state, which makes
            // the handoff ordered rather than a simultaneous cold load.
            qwenBackgroundModelLoadingGated = true
            return
        }
        if decision.requiresExclusiveModelResidency,
           decision.throttleReasons.contains(.workerMemoryGuard),
           siblingResident == false,
           interactiveLane == nil {
            // The sibling is preparing but has not published resident state.
            // Let that first turn settle before requesting it back.
            qwenBackgroundModelLoadingGated = true
            return
        }
        guard Self.qwenModelLoadAllowedByHandoff(
            requiresExclusiveModelResidency: decision.requiresExclusiveModelResidency,
            backgroundLoadingGated: qwenBackgroundModelLoadingGated,
            siblingModelResident: siblingResident,
            hasModelDemand: hasModelDemand
        ) else {
            // Interactive Qwen preempts BGE, but waits for BGE's release
            // heartbeat before loading so both weight sets are never resident.
            return
        }
        guard scheduler.allowsQwenModelLoading(context: context) else { return }
        guard Self.qwenModelPreparationAction(
            requiresExclusiveModelResidency: decision.requiresExclusiveModelResidency,
            modelLoadState: modelLoader.state,
            exclusiveModelTurnAvailable: acquireExclusiveModelSlotIfNeeded(
                requiresExclusiveModelResidency: decision.requiresExclusiveModelResidency,
                reason: "Qwen weight load"
            )
        ) == .start else {
            return
        }
        if hasModelDemand {
            qwenBackgroundModelLoadingGated = false
        }
        modelLoader.start(context: context)
        writeHeartbeat(state: .busy, message: "loading Qwen model weights")
        print("\(role.logPrefix) model loading started: \(modelLoader.preparationModel.displayName)")
    }

    private func startRetrievalModelLoadingIfReady() async {
        guard role == .bge else { return }
        let context = makeSchedulerContext()
        let resourceSnapshot = scheduler.refreshModelResourceSnapshot(context: context)
        let decision = resourceSnapshot.decision
        let hasModelDemand = interactiveRetrievalModelDemand
            || scheduler.hasBGEModelDemand(context: context)
            || hasPendingGenerationContextPackDemand(context: context)
        if Self.shouldRequestBGE3Download(
            embeddingProviderUnavailable: embeddingProviderUnavailable,
            hasModelDemand: hasModelDemand
        ) {
            appServices.startBGE3DownloadIfNeeded(
                hasModelDemand: hasModelDemand
            )
        }
        let siblingResident = Self.siblingModelIsResident(
            snapshot: try? statusStore.snapshot(for: .qwen),
            now: Date()
        )
        exclusiveModelTurnRequested = Self.exclusiveModelTurnRequest(
            requiresExclusiveModelResidency: decision.requiresExclusiveModelResidency,
            ownModelResident: embeddingProviderUnavailable == false,
            siblingModelResident: siblingResident,
            hasModelDemand: hasModelDemand
        )
        if let releaseAction = Self.retrievalModelReleaseAction(
            throttleReasons: decision.throttleReasons,
            allowsBGELiveFreshness: decision.modelComputeBudget.allows(.bgeLiveFreshness),
            requiresExclusiveModelResidency: decision.requiresExclusiveModelResidency
        ) {
            await releaseRetrievalModelResourcesAndSlot(
                includeBGE: releaseAction.includeBGE,
                reason: releaseAction.reason
            )
            return
        }
        if exclusiveModelTurnRequested { return }
        if decision.requiresExclusiveModelResidency, hasModelDemand == false {
            await releaseRetrievalModelResourcesAndSlot(
                includeBGE: true,
                reason: "retrieval backlog complete"
            )
            return
        }
        let interactiveLoadAllowed = interactiveRetrievalModelDemand
            && Self.interactiveBGEModelLoadAllowed(
                throttleReasons: decision.throttleReasons
            )
        guard decision.bge.allowsModelHeavyWork || interactiveLoadAllowed else { return }

        let shouldLoadBGE = embeddingProviderUnavailable
            && appServices.bge3Downloader.isAvailable
        let hasResidentRetrievalModel = embeddingProviderUnavailable == false
            || appServices.crossEncoderReranker != nil

        if decision.requiresExclusiveModelResidency,
           hasResidentRetrievalModel,
           !acquireExclusiveModelSlotIfNeeded(
                requiresExclusiveModelResidency: true,
                reason: "existing retrieval model residency"
           ) {
            // A resident model without the shared lease is unsafe (for
            // example after a mixed-version helper restart). Drain it before
            // allowing the sibling to keep the slot.
            await releaseRetrievalModelResourcesAndSlot(
                includeBGE: true,
                reason: "exclusive model slot owned by sibling"
            )
            return
        }
        if shouldLoadBGE {
            guard acquireExclusiveModelSlotIfNeeded(
                requiresExclusiveModelResidency: decision.requiresExclusiveModelResidency,
                reason: "BGE-M3 weight load"
            ) else {
                return
            }
            retrievalModelConstructionInFlight = true
            bgeModelLoading = true
            writeHeartbeat(state: .busy, message: "loading bge-m3 model")
            await appServices.setupBGE3IfAvailable()
        }
        if Task.isCancelled {
            bgeModelLoading = false
            retrievalModelConstructionInFlight = false
            releaseExclusiveModelSlotIfUnused()
            return
        }
        if bgeModelLoading {
            bgeModelLoading = false
            writeHeartbeat(state: embeddingProviderUnavailable ? .waiting : .idle)
        }

        // The BGE constructor suspends the main actor. Re-read demand and the
        // resource policy before starting another model constructor instead
        // of acting on a decision captured before that suspension.
        let refreshedDecision = scheduler.refreshModelResourceSnapshot(context: context).decision
        let shouldLoadCrossEncoder = !Task.isCancelled
            && refreshedDecision.bge.modelMode == .full
            && refreshedDecision.bge.allowsModelHeavyWork
            && !interactiveRetrievalModelDemand
            && appServices.crossEncoderDownloader.isAvailable
            && appServices.crossEncoderReranker == nil
        if shouldLoadCrossEncoder {
            guard acquireExclusiveModelSlotIfNeeded(
                requiresExclusiveModelResidency: refreshedDecision.requiresExclusiveModelResidency,
                reason: "cross-encoder weight load"
            ) else {
                retrievalModelConstructionInFlight = false
                releaseExclusiveModelSlotIfUnused()
                return
            }
            retrievalModelConstructionInFlight = true
            await appServices.setupCrossEncoderIfAvailable()
        }
        retrievalModelConstructionInFlight = false
        releaseExclusiveModelSlotIfUnused()
    }

    private func releaseRetrievalModelResourcesAndSlot(
        includeBGE: Bool,
        reason: String
    ) async {
        await appServices.releaseRetrievalModelResources(
            includeBGE: includeBGE,
            reason: reason
        )
        if includeBGE {
            // AppServices awaits constructor cancellation plus active reranker
            // and embedding-provider drains before this postcondition check.
            retrievalModelConstructionInFlight = false
            releaseExclusiveModelSlotIfUnused()
        }
    }

    private func startRetrievalModelLoadingTaskIfReady() {
        guard role == .bge, retrievalModelLoadTask == nil else { return }
        let operationID = UUID()
        retrievalModelLoadOperationID = operationID
        retrievalModelLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startRetrievalModelLoadingIfReady()
            guard self.retrievalModelLoadOperationID == operationID else { return }
            self.retrievalModelLoadOperationID = nil
            self.retrievalModelLoadTask = nil
        }
    }

    /// Coalesces all callers onto the one retrieval-model reconciliation task.
    /// Query IPC used to invoke the async loader directly, which allowed its
    /// actor suspension points to overlap the periodic loader task.
    private func awaitRetrievalModelLoadingTaskIfReady() async {
        startRetrievalModelLoadingTaskIfReady()
        let pendingLoad = retrievalModelLoadTask
        if let pendingLoad {
            await pendingLoad.value
        }
    }

    /// Cancels and joins the wrapper task before any caller drains AppServices
    /// or releases the cross-process model slot. Clearing the handle first
    /// would let a second actor-reentrant release mistake construction for
    /// completed work.
    private func cancelAndDrainRetrievalModelLoadingTask() async {
        guard let pendingLoad = retrievalModelLoadTask else { return }
        let operationID = retrievalModelLoadOperationID
        pendingLoad.cancel()
        await pendingLoad.value
        if retrievalModelLoadOperationID == operationID {
            retrievalModelLoadOperationID = nil
            retrievalModelLoadTask = nil
        }
    }

    private func applyMemoryPressureProtection() async {
        let context = makeSchedulerContext()
        let resourceSnapshot = scheduler.refreshModelResourceSnapshot(context: context)
        let decision = resourceSnapshot.decision
        switch role {
        case .bge:
            if let releaseAction = Self.retrievalModelReleaseAction(
                throttleReasons: decision.throttleReasons,
                allowsBGELiveFreshness: decision.modelComputeBudget.allows(.bgeLiveFreshness),
                requiresExclusiveModelResidency: decision.requiresExclusiveModelResidency
            ) {
                await cancelAndDrainRetrievalModelLoadingTask()
                bgeModelLoading = false
                await releaseRetrievalModelResourcesAndSlot(
                    includeBGE: releaseAction.includeBGE,
                    reason: releaseAction.reason
                )
            }
        case .qwen:
            let bgeModelDemand = scheduler.hasBGEModelDemand(context: context)
                || hasPendingGenerationContextPackDemand(context: context)
            let handoff = Self.qwenModelHandoffDecision(
                requiresExclusiveModelResidency: decision.requiresExclusiveModelResidency,
                backgroundLoadingGated: qwenBackgroundModelLoadingGated,
                modelLoaded: appServices.engineSelector.primary.isModelLoaded,
                modelLoadState: modelLoader?.state,
                interactiveLane: statusStore.interactiveGenerationLane(),
                bgeWorkPending: bgeModelDemand,
                throttleReasons: decision.throttleReasons
            )
            qwenBackgroundModelLoadingGated = handoff.backgroundLoadingGated

            switch handoff.action {
            case .unloadForCriticalMemory:
                await unloadQwenModel(reason: "critical memory pressure")
                appServices.trainingStatusPublisher.setResourceWaitReason("memory pressure")
            case .yieldToRetrievalWorker:
                await unloadQwenModel(reason: "retrieval worker memory turn")
                appServices.trainingStatusPublisher.setResourceWaitReason("retrieval model progress")
            case .releaseReusableMemory:
                if !appServices.engineSelector.primary.isModelLoaded {
                    await unloadQwenModel(reason: "resource pressure during model load")
                } else {
                    appServices.engineSelector.primary.cancel()
                    if let mlx = appServices.engineSelector.primary as? MLXTrainingEngine {
                        mlx.releaseReusableMemory()
                    }
                }
                appServices.trainingStatusPublisher.setResourceWaitReason("memory pressure")
            case .none:
                break
            }
        }
    }

    private func unloadQwenModel(reason: String) async {
        appServices.engineSelector.primary.cancel()
        if let modelLoader {
            await modelLoader.unloadForResourcePressureAndDrain()
        } else if let mlx = appServices.engineSelector.primary as? MLXTrainingEngine,
                  mlx.isModelLoaded {
            mlx.unloadModel()
            appServices.trainingStatusPublisher.setEngineReady(false)
        }
        releaseExclusiveModelSlotIfUnused()
        print("\(role.logPrefix) unloaded Qwen model")
    }

    nonisolated static func retrievalModelReleaseAction(
        throttleReasons: [ResourceThrottleReason],
        allowsBGELiveFreshness: Bool,
        requiresExclusiveModelResidency: Bool
    ) -> RetrievalModelReleaseAction? {
        if throttleReasons.contains(.memoryCritical) {
            return RetrievalModelReleaseAction(
                includeBGE: true,
                reason: "critical memory pressure"
            )
        }
        if throttleReasons.contains(.interactiveQwenGeneration) {
            return RetrievalModelReleaseAction(
                includeBGE: requiresExclusiveModelResidency,
                reason: "interactive Qwen generation"
            )
        }
        if throttleReasons.contains(.workerMemoryGuard) {
            return RetrievalModelReleaseAction(
                includeBGE: true,
                reason: "sibling model memory guard"
            )
        }
        if throttleReasons.contains(.memoryWarning) {
            return RetrievalModelReleaseAction(
                includeBGE: false,
                reason: "memory pressure"
            )
        }
        if throttleReasons.contains(.qwenInterpretationBackpressure),
           !allowsBGELiveFreshness {
            return RetrievalModelReleaseAction(
                includeBGE: requiresExclusiveModelResidency,
                reason: "Qwen interpretation backpressure"
            )
        }
        return nil
    }

    nonisolated static func interactiveQwenModelTurnReleaseAction(
        role: WorkerRole,
        requiresExclusiveModelResidency: Bool
    ) -> RetrievalModelReleaseAction? {
        guard role == .bge, requiresExclusiveModelResidency else { return nil }
        return RetrievalModelReleaseAction(
            includeBGE: true,
            reason: "interactive Qwen model turn"
        )
    }

    nonisolated static func interactiveBGEModelLoadAllowed(
        throttleReasons: [ResourceThrottleReason]
    ) -> Bool {
        let hardStops: [ResourceThrottleReason] = [
            .memoryWarning,
            .memoryCritical,
            .thermalSerious,
            .thermalCritical,
            .workerMemoryGuard,
        ]
        return throttleReasons.allSatisfy { !hardStops.contains($0) }
    }

    nonisolated static func shouldRequestBGE3Download(
        embeddingProviderUnavailable: Bool,
        hasModelDemand: Bool
    ) -> Bool {
        embeddingProviderUnavailable && hasModelDemand
    }

    nonisolated static func qwenModelHandoffDecision(
        requiresExclusiveModelResidency: Bool,
        backgroundLoadingGated: Bool,
        modelLoaded: Bool,
        modelLoadState: ModelLoadState?,
        interactiveLane: InteractiveGenerationLane?,
        bgeWorkPending: Bool,
        throttleReasons: [ResourceThrottleReason]
    ) -> QwenModelHandoffDecision {
        if throttleReasons.contains(.memoryCritical) {
            return QwenModelHandoffDecision(
                backgroundLoadingGated: true,
                action: .unloadForCriticalMemory
            )
        }

        guard requiresExclusiveModelResidency else {
            return QwenModelHandoffDecision(
                backgroundLoadingGated: false,
                action: throttleReasons.contains(.memoryWarning)
                    || throttleReasons.contains(.workerMemoryGuard)
                    ? .releaseReusableMemory
                    : .none
            )
        }

        if throttleReasons.contains(.memoryWarning) {
            return QwenModelHandoffDecision(
                backgroundLoadingGated: backgroundLoadingGated,
                action: .releaseReusableMemory
            )
        }

        if interactiveLane != nil {
            return QwenModelHandoffDecision(
                backgroundLoadingGated: false,
                action: .none
            )
        }

        // Loading weights reserves the model slot. A network-only download
        // does not: BGE may use the slot while Qwen continues transferring
        // artifacts, and the gate below prevents background Qwen from claiming
        // the slot merely because that transfer is in progress.
        if modelLoadState == .loading {
            return QwenModelHandoffDecision(
                backgroundLoadingGated: backgroundLoadingGated,
                action: .none
            )
        }

        if modelLoaded,
           (bgeWorkPending || throttleReasons.contains(.workerMemoryGuard)) {
            return QwenModelHandoffDecision(
                backgroundLoadingGated: true,
                action: .yieldToRetrievalWorker
            )
        }

        if modelLoaded {
            return QwenModelHandoffDecision(
                backgroundLoadingGated: false,
                action: .none
            )
        }

        if case .downloading = modelLoadState {
            return QwenModelHandoffDecision(
                backgroundLoadingGated: backgroundLoadingGated || bgeWorkPending,
                action: .none
            )
        }

        return QwenModelHandoffDecision(
            backgroundLoadingGated: backgroundLoadingGated
                || throttleReasons.contains(.workerMemoryGuard),
            action: .none
        )
    }

    /// Keeps the periodic preparation tick out of the MainActor reentrancy
    /// window while a command drains one model and mutates the next state.
    nonisolated static func qwenPreparationMayStart(
        modelTransitionInProgress: Bool,
        downloadStopped: Bool = false
    ) -> Bool {
        !modelTransitionInProgress && !downloadStopped
    }

    private var qwenGenerationIsActive: Bool {
        activeGenerationHeartbeat != nil || currentPipelineJobType != nil
    }

    /// Network-only prefetch may overlap generation. Every state that could
    /// enter the combined download-and-load path stays on prefetch, and the
    /// downloaded state waits until no request is using the current weights.
    nonisolated static func pendingModelSwitchPreparationAction(
        modelLoadState: ModelLoadState,
        generationIsActive: Bool
    ) -> QwenModelPreparationAction {
        guard generationIsActive else {
            switch modelLoadState {
            case .idle, .failed, .downloaded:
                return .start
            case .downloading, .loading, .paused, .ready:
                return .none
            }
        }

        switch modelLoadState {
        case .idle, .failed:
            return .prefetch
        case .downloaded:
            return .waitForExclusiveTurn
        case .downloading, .loading, .paused, .ready:
            return .none
        }
    }

    /// Chooses whether Qwen may invoke the loader at its current preparation
    /// state. Exclusive-memory devices always split network prefetch from MLX
    /// weight loading so the worker must reacquire the cross-process turn after
    /// the artifacts reach `.downloaded`.
    nonisolated static func qwenModelPreparationAction(
        requiresExclusiveModelResidency: Bool,
        modelLoadState: ModelLoadState,
        exclusiveModelTurnAvailable: Bool
    ) -> QwenModelPreparationAction {
        switch modelLoadState {
        case .idle, .failed:
            return requiresExclusiveModelResidency ? .prefetch : .start
        case .downloaded:
            if requiresExclusiveModelResidency, !exclusiveModelTurnAvailable {
                return .waitForExclusiveTurn
            }
            return .start
        case .downloading, .loading, .paused, .ready:
            return .none
        }
    }

    /// Prefetch eligibility is derived only from the loader's live state. A
    /// terminal failure therefore remains retryable instead of being blocked
    /// by a historical "started" flag, while active/completed operations stay
    /// idempotent.
    nonisolated static func qwenModelPrefetchIsEligible(
        modelLoadState: ModelLoadState
    ) -> Bool {
        switch modelLoadState {
        case .idle, .failed:
            return true
        case .downloading, .downloaded, .loading, .paused, .ready:
            return false
        }
    }

    nonisolated static func qwenModelLoadAllowedByHandoff(
        requiresExclusiveModelResidency: Bool,
        backgroundLoadingGated: Bool,
        siblingModelResident: Bool,
        hasModelDemand: Bool
    ) -> Bool {
        if backgroundLoadingGated, hasModelDemand == false {
            return false
        }
        if requiresExclusiveModelResidency, siblingModelResident {
            return false
        }
        return true
    }

    nonisolated static func exclusiveModelTurnRequest(
        requiresExclusiveModelResidency: Bool,
        ownModelResident: Bool,
        siblingModelResident: Bool,
        hasModelDemand: Bool
    ) -> Bool {
        requiresExclusiveModelResidency
            && ownModelResident == false
            && siblingModelResident
            && hasModelDemand
    }

    /// Per-message cooldown for context-pack builds that threw. Without it,
    /// one deterministically-failing build re-runs every worker cycle (~5s)
    /// and, because the tiers are ordered, starves every message behind it.
    /// In-memory by design: a worker restart retries everything once.
    private var packPreparationRetryAfter: [UUID: Date] = [:]
    private static let packPreparationFailureCooldown: TimeInterval = 600

    private func hasPendingGenerationContextPackDemand(
        context: ModelContext,
        now: Date = Date()
    ) -> Bool {
        guard PipelineFeatureFlags.automaticReplyDraftGenerationEnabled else {
            return false
        }
        let drafts = (try? context.fetch(FetchDescriptor<Draft>())) ?? []
        if Self.hasMissingReplyContextPackDemand(
            drafts: drafts,
            contextPackStore: appServices.generationContextPackStore,
            retryAfter: packPreparationRetryAfter,
            now: now
        ) {
            return true
        }

        guard initialLocalPipelineComplete(context: context) else { return false }
        let automaticTriageQueueingEnabled = ComposerQueueIntakePreference
            .automaticTriageQueueingEnabled()
        return DraftGenerationOrchestrator.queueCandidateMessages(
            context: context,
            automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
        ).contains { message in
            message.analysis != nil
                && message.draft == nil
                && message.isComposerQueueEligible(
                    automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
                )
                && !appServices.generationContextPackStore.containsPack(for: message.id)
                && (packPreparationRetryAfter[message.id] ?? .distantPast) <= now
        }
    }

    @MainActor
    static func hasMissingReplyContextPackDemand(
        drafts: [Draft],
        contextPackStore: GenerationContextPackStore,
        retryAfter: [UUID: Date],
        now: Date
    ) -> Bool {
        drafts.contains { draft in
            guard draftNeedsPreparedContextPack(draft),
                  let messageID = draft.message?.id,
                  (retryAfter[messageID] ?? .distantPast) <= now else {
                return false
            }
            return !contextPackStore.containsPack(for: messageID)
        }
    }

    private func prepareGenerationContextPacksIfReady(limit: Int = 2) {
        let context = makeSchedulerContext()
        guard PipelineFeatureFlags.automaticReplyDraftGenerationEnabled,
              role == .bge else {
            return
        }

        let pendingDrafts = (try? context.fetch(FetchDescriptor<Draft>())) ?? []
        let packedOwedMessageIDs = Set(pendingDrafts.compactMap { draft -> UUID? in
            guard Self.draftOwesContextBackedGeneration(draft),
                  (draft.generationFailureCount ?? 0) == 0,
                  let messageID = draft.message?.id,
                  appServices.generationContextPackStore.containsPack(for: messageID) else {
                return nil
            }
            return messageID
        })
        for messageID in packedOwedMessageIDs {
            wakeDraftGenerationForPreparedContextPack(messageID: messageID, context: context)
        }

        guard !embeddingProviderUnavailable else {
            return
        }
        let decision = scheduler.refreshModelResourceSnapshot(context: context).decision
        guard decision.bge.allowsModelHeavyWork else {
            return
        }

        let now = Date()
        let automaticTriageQueueingEnabled = ComposerQueueIntakePreference.automaticTriageQueueingEnabled()
        func needsPack(_ message: Message) -> Bool {
            message.analysis != nil
                && !appServices.generationContextPackStore.containsPack(for: message.id)
                && (packPreparationRetryAfter[message.id] ?? .distantPast) <= now
        }
        // Urgent tier — any pending reply draft the generation worker owes
        // (clarifying questions out, answers submitted, or a revision
        // pending). The generative worker requires a pack and throws
        // `.missing` until one exists, so owed work never waits for the
        // initial pipeline to finish — and is deliberately NOT gated on
        // current queue eligibility: a draft the user started stays owed
        // even if its message later left the queue scope (intake-preference
        // flips, reply detected elsewhere). The Draft table only holds
        // Composer-flow rows, so this scan is small.
        let urgent = pendingDrafts.compactMap { draft -> Message? in
            guard Self.draftNeedsPreparedContextPack(draft),
                  let message = draft.message,
                  needsPack(message) else {
                return nil
            }
            return message
        }
        // Bulk tier — queue-eligible intake that hasn't seeded a draft yet.
        // Bounded candidate scan (live inbound + explicit additions, never
        // the whole store); waits for the initial local pipeline so
        // cold-start retrieval isn't built against a half-embedded corpus.
        let bulk: [Message]
        if initialLocalPipelineComplete(context: context) {
            let candidates = DraftGenerationOrchestrator.queueCandidateMessages(
                context: context,
                automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
            )
            bulk = candidates.filter { message in
                message.draft == nil
                    && message.isComposerQueueEligible(
                        automaticTriageQueueingEnabled: automaticTriageQueueingEnabled
                    )
                    && needsPack(message)
            }
        } else {
            bulk = []
        }
        let pending = (urgent + bulk).prefix(limit)

        // Per-message failure isolation: one bad build skips into cooldown
        // instead of aborting the batch and re-running every cycle.
        for message in pending {
            do {
                let packContext = try DraftContextPackBuilder.build(
                    for: message,
                    context: context,
                    vectorStore: appServices.vectorStore,
                    embedder: appServices.embedder,
                    canonicalStore: appServices.canonicalStore,
                    hybridRetriever: appServices.hybridRetriever,
                    toolRegistry: appServices.toolRegistry
                )
                try appServices.generationContextPackStore.write(
                    GenerationContextPack(messageID: message.id, context: packContext)
                )
                packPreparationRetryAfter.removeValue(forKey: message.id)
                wakeDraftGenerationForPreparedContextPack(messageID: message.id, context: context)
                print("\(role.logPrefix) prepared generation context pack for \(message.id)")
            } catch {
                packPreparationRetryAfter[message.id] = now.addingTimeInterval(
                    Self.packPreparationFailureCooldown
                )
                print("\(role.logPrefix) context-pack preparation failed for \(message.id): \(String(reflecting: type(of: error)))")
            }
        }
    }

    private static func draftOwesContextBackedGeneration(_ draft: Draft) -> Bool {
        draft.kind != .userCompose
            && draft.status == .pending
            && draft.message != nil
            && (draft.resolvedStage == DraftStage.generating
                || draft.resolvedStage == DraftStage.evaluatingSources
                || draft.pendingInstruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    private static func draftNeedsPreparedContextPack(_ draft: Draft) -> Bool {
        draft.kind != .userCompose
            && draft.status == .pending
            && draft.message != nil
            && (draft.resolvedStage == DraftStage.generating
                || draft.resolvedStage == DraftStage.evaluatingSources
                || draft.resolvedStage == DraftStage.collectingAnswers
                || draft.pendingInstruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    private func wakeDraftGenerationForPreparedContextPack(messageID: UUID, context: ModelContext) {
        let drafts = (try? context.fetch(FetchDescriptor<Draft>())) ?? []
        let wokeDraft = drafts.contains { draft in
            guard Self.draftOwesContextBackedGeneration(draft),
                  (draft.generationFailureCount ?? 0) == 0,
                  draft.message?.id == messageID else {
                return false
            }
            draft.clearGenerationBackoff()
            return true
        }
        guard wokeDraft else { return }

        do {
            if try !makeExistingGenerateDraftJobClaimable(for: messageID, context: context) {
                try JobQueue().enqueue(
                    type: .generateDraft,
                    priority: ComposerDraftScheduling.userInitiatedPriority,
                    messageId: messageID,
                    context: context
                )
            }
        } catch {
            print("\(role.logPrefix) context-pack wake failed for \(messageID): \(String(reflecting: type(of: error)))")
        }
    }

    private func makeExistingGenerateDraftJobClaimable(for messageID: UUID, context: ModelContext) throws -> Bool {
        let jobs = try JobFetch.jobs(
            type: .generateDraft,
            statuses: [.pending, .running],
            context: context
        )
        var matched = false
        for job in jobs where job.messageId == messageID {
            matched = true
            guard job.status == .pending else { continue }
            job.priority = min(job.priority, ComposerDraftScheduling.userInitiatedPriority)
            job.nextAttemptAt = nil
            job.error = nil
        }
        if matched {
            try context.save()
        }
        return matched
    }

    private func initialLocalPipelineComplete(context: ModelContext) -> Bool {
        PipelineReadiness.initialBGEPipelineStatus(
            context: context,
            vectorStore: appServices.vectorStore,
            messageStoreURL: appServices.messageStoreURL
        ).isComplete
    }

    private func repairLayoutIfNeeded() {
        guard let layoutOrchestrator = try? LayoutOrchestrator(
            vectorStore: appServices.vectorStore,
            neighborsStore: appServices.vectorNeighborsStore,
            frameLayoutStore: appServices.vectorFrameLayoutStore
        ) else {
            return
        }
        Task.detached(priority: .utility) {
            try? await layoutOrchestrator.repairCollapsedLayoutIfNeeded()
        }
    }

    private func startCompletionBridge() {
        guard completionBridgeTask == nil else { return }
        completionBridgeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.completionBroadcaster.events() {
                self.appendCompletion(event)
            }
        }
    }

    private func appendCompletion(_ event: JobCompletionEvent) {
        do {
            _ = try statusStore.appendCompletion(
                WorkerCompletionSnapshot(event: event),
                role: role.coreRole,
                completionStreamID: completionStreamID
            )
            writeHeartbeat(state: .busy)
        } catch {
            print("\(role.logPrefix) completion write failed: \(String(reflecting: type(of: error)))")
        }
    }

    private func startCommandMonitor() {
        guard commandMonitorTask == nil else { return }
        commandMonitorTask = Task { @MainActor [weak self] in
            await self?.runCommandMonitor()
        }
    }

    /// Drains any pre-existing queued commands at startup, then sleeps on a
    /// vnode source watching the command queue directory. This replaces the
    /// previous unconditional 500 ms `Task.sleep` poll, which alone added a
    /// 250 ms average pickup latency to every interactive `WorkerGenerationEngine`
    /// request. A 30-second backstop tick covers the rare missed-event case.
    private func runCommandMonitor() async {
        await drainPendingCommands()

        let activityWatcher = CommandDirectoryActivityWatcher(
            queueDirectory: statusStore.commandQueueDirectoryURL(for: role.coreRole),
            logPrefix: role.logPrefix
        )

        defer {
            activityWatcher.cancel()
        }

        await drainPendingCommands()

        for await _ in activityWatcher.stream {
            if Task.isCancelled { break }
            await drainPendingCommands()
        }
    }

    /// Drains every queued command currently visible. Each `consumeCommand`
    /// removes one queue file, so we loop until the queue reports empty —
    /// otherwise a burst of arrivals during a long generate would only get
    /// processed one-per-event.
    private func drainPendingCommands() async {
        while await handleOneCommand() {
            if Task.isCancelled { break }
        }
    }

    /// Accepts a live XPC command without routing its execution through a file
    /// watcher. The completion remains pending until command handling reaches
    /// a terminal boundary, which keeps the originating XPC scheduling context
    /// active for the actual work. Cancellation is handled out of band so it
    /// cannot wait behind the decode or embedding operation it needs to stop.
    func submitXPCCommand(
        _ command: WorkerCommandSnapshot,
        priority: TaskPriority,
        completion: @escaping @Sendable (WorkerXPCCommandCompletion) -> Void
    ) {
        guard usesXPCCommandTransport, !shouldStop else {
            completion(.notExecuted("worker runtime is stopping"))
            return
        }

        if handleImmediateXPCCommandIfNeeded(
            command,
            priority: priority,
            completion: completion
        ) {
            return
        }

        supersedeXPCGenerationCommandsIfNeeded(with: command)
        pendingXPCCommands.append(
            PendingXPCCommand(
                command: command,
                priority: priority,
                completion: completion
            )
        )
        startXPCCommandDrainIfNeeded()
    }

    public func requestXPCStop() {
        requestStop(message: "XPC client requested stop")
    }

    private func handleImmediateXPCCommandIfNeeded(
        _ command: WorkerCommandSnapshot,
        priority: TaskPriority,
        completion: @escaping @Sendable (WorkerXPCCommandCompletion) -> Void
    ) -> Bool {
        guard Self.handlesXPCCommandImmediately(command.kind) else {
            return false
        }

        switch command.kind {
        case .cancelGeneration:
            if let targetID = command.cancelledGenerationCommandID {
                directlyCancelledGenerationCommandIDs.insert(targetID)
                if cancelQueuedXPCCommand(id: targetID, isGeneration: true) {
                    directlyCancelledGenerationCommandIDs.remove(targetID)
                }
            }
        case .cancelQueryEmbedding:
            if let targetID = command.cancelledQueryEmbeddingCommandID {
                directlyCancelledQueryEmbeddingCommandIDs.insert(targetID)
                if cancelQueuedXPCCommand(id: targetID, isGeneration: false) {
                    directlyCancelledQueryEmbeddingCommandIDs.remove(targetID)
                }
            }
        case .selectGenerationModel, .cancelGenerationModelPreparation:
            break
        default:
            preconditionFailure("Immediate XPC command classification is incomplete")
        }

        Task(priority: priority) { @MainActor [weak self] in
            guard let self else {
                completion(.notExecuted("worker runtime was released"))
                return
            }
            let failure = await self.handleCommand(
                command,
                pickedUpAt: Date(),
                executionPriority: priority
            )
            completion(
                failure.map(WorkerXPCCommandCompletion.failed)
                    ?? .completed(self.takeLiveResponse(for: command.id))
            )
        }
        return true
    }

    nonisolated static func handlesXPCCommandImmediately(
        _ kind: WorkerCommandKind
    ) -> Bool {
        switch kind {
        case .cancelGeneration, .cancelQueryEmbedding,
             .selectGenerationModel, .cancelGenerationModelPreparation:
            return true
        case .cancelTraining, .resetTrainingToBase, .generateText,
             .embedQueries, .requestInteractiveQwenModelTurn,
             .requestInteractiveBGEModelTurn:
            return false
        }
    }

    @discardableResult
    private func cancelQueuedXPCCommand(id: UUID, isGeneration: Bool) -> Bool {
        guard let index = pendingXPCCommands.firstIndex(where: { $0.command.id == id }) else {
            return false
        }
        let pending = pendingXPCCommands.remove(at: index)
        if isGeneration, let request = pending.command.generationRequest {
            recordGenerationResponse(
                commandID: pending.command.id,
                request: request,
                status: .cancelled,
                errorMessage: "Generation request was cancelled before decoding started.",
                pickedUpAt: Date(),
                decodeStartedAt: nil,
                decodeFinishedAt: nil
            )
        } else if !isGeneration, let request = pending.command.queryEmbeddingRequest {
            recordQueryEmbeddingResponse(
                commandID: pending.command.id,
                request: request,
                status: .cancelled,
                errorMessage: "Query embedding request was cancelled before inference."
            )
        }
        pending.completion(.completed(takeLiveResponse(for: pending.command.id)))
        return true
    }

    private func supersedeXPCGenerationCommandsIfNeeded(
        with newerCommand: WorkerCommandSnapshot
    ) {
        guard newerCommand.isUserInteractiveGeneration
                || newerCommand.isInteractiveSummarizationFastLane else {
            return
        }

        if let activeXPCCommand,
           Self.xpcGenerationCommand(activeXPCCommand, isSupersededBy: newerCommand) {
            directlyCancelledGenerationCommandIDs.insert(activeXPCCommand.id)
        }

        var retained: [PendingXPCCommand] = []
        for pending in pendingXPCCommands {
            guard Self.xpcGenerationCommand(
                pending.command,
                isSupersededBy: newerCommand
            ) else {
                retained.append(pending)
                continue
            }
            if let request = pending.command.generationRequest {
                recordGenerationResponse(
                    commandID: pending.command.id,
                    request: request,
                    status: .cancelled,
                    errorMessage: "Generation request was superseded.",
                    pickedUpAt: Date(),
                    decodeStartedAt: nil,
                    decodeFinishedAt: nil
                )
            }
            pending.completion(.completed(takeLiveResponse(for: pending.command.id)))
        }
        pendingXPCCommands = retained
    }

    nonisolated static func xpcGenerationCommand(
        _ candidate: WorkerCommandSnapshot,
        isSupersededBy newerCommand: WorkerCommandSnapshot
    ) -> Bool {
        guard candidate.issuedAt <= newerCommand.issuedAt else { return false }
        if newerCommand.isUserInteractiveGeneration {
            return candidate.isLensAssistGeneration
        }
        if newerCommand.isInteractiveSummarizationFastLane {
            return candidate.isInteractiveSummarizationFastLane
        }
        return false
    }

    private func startXPCCommandDrainIfNeeded() {
        guard acceptsXPCCommands,
              xpcCommandDrainTask == nil,
              !pendingXPCCommands.isEmpty else {
            return
        }
        let priority = pendingXPCCommands.map(\.priority).max() ?? .medium
        xpcCommandDrainTask = Task(priority: priority) { @MainActor [weak self] in
            await self?.drainXPCCommands()
        }
    }

    private func drainXPCCommands() async {
        defer {
            xpcCommandDrainTask = nil
            if acceptsXPCCommands, !pendingXPCCommands.isEmpty {
                startXPCCommandDrainIfNeeded()
            }
        }

        while acceptsXPCCommands, !Task.isCancelled, !pendingXPCCommands.isEmpty {
            pendingXPCCommands.sort(by: Self.prioritizedXPCCommandSort)
            let pending = pendingXPCCommands.removeFirst()
            activeXPCCommand = pending.command
            let failure = await handleCommand(
                pending.command,
                pickedUpAt: Date(),
                executionPriority: pending.priority
            )
            activeXPCCommand = nil
            directlyCancelledGenerationCommandIDs.remove(pending.command.id)
            directlyCancelledQueryEmbeddingCommandIDs.remove(pending.command.id)
            pending.completion(
                failure.map(WorkerXPCCommandCompletion.failed)
                    ?? .completed(takeLiveResponse(for: pending.command.id))
            )
        }
    }

    private nonisolated static func prioritizedXPCCommandSort(
        _ lhs: PendingXPCCommand,
        _ rhs: PendingXPCCommand
    ) -> Bool {
        xpcCommandPrecedes(lhs.command, rhs.command)
    }

    nonisolated static func xpcCommandPrecedes(
        _ lhs: WorkerCommandSnapshot,
        _ rhs: WorkerCommandSnapshot
    ) -> Bool {
        let lhsRank = xpcCommandPriorityRank(lhs)
        let rhsRank = xpcCommandPriorityRank(rhs)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.kind == .generateText, rhs.kind == .generateText {
            if lhs.issuedAt == rhs.issuedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.issuedAt > rhs.issuedAt
        }
        if lhs.issuedAt == rhs.issuedAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.issuedAt < rhs.issuedAt
    }

    private nonisolated static func xpcCommandPriorityRank(
        _ command: WorkerCommandSnapshot
    ) -> Int {
        switch command.kind {
        case .cancelTraining, .resetTrainingToBase, .cancelGeneration,
             .cancelQueryEmbedding, .requestInteractiveQwenModelTurn,
             .requestInteractiveBGEModelTurn, .selectGenerationModel,
             .cancelGenerationModelPreparation:
            return 0
        case .embedQueries:
            return 1
        case .generateText:
            if command.isInteractiveSummarizationFastLane { return 1 }
            if command.isUserInteractiveGeneration { return 2 }
            if command.isLensAssistGeneration { return 3 }
            return 4
        }
    }

    private func finishPendingXPCCommands(message: String) {
        acceptsXPCCommands = false
        let pending = pendingXPCCommands
        pendingXPCCommands.removeAll()
        for command in pending {
            command.completion(.notExecuted(message))
        }
    }

    @discardableResult
    private func handleOneCommand() async -> Bool {
        let pickedUpAt: Date
        let command: WorkerCommandSnapshot
        do {
            guard let pulled = try statusStore.consumePrioritizedCommand(for: role.coreRole) else {
                return false
            }
            pickedUpAt = Date()
            command = pulled
        } catch {
            print("\(role.logPrefix) command pickup failed: \(String(reflecting: type(of: error)))")
            return false
        }

        _ = await handleCommand(
            command,
            pickedUpAt: pickedUpAt,
            executionPriority: Self.defaultExecutionPriority(for: command)
        )
        liveResponseData.removeValue(forKey: command.id)
        return true
    }

    private func takeLiveResponse(for commandID: UUID) -> Data? {
        liveResponseData.removeValue(forKey: commandID)
    }

    private func handleCommand(
        _ command: WorkerCommandSnapshot,
        pickedUpAt: Date,
        executionPriority: TaskPriority
    ) async -> String? {
        do {
            switch command.kind {
            case .cancelTraining:
                appServices.engineSelector.primary.cancel()
                appServices.trainingStatusPublisher.setResourceWaitReason("training stopped")
                writeHeartbeat(state: .paused, message: command.message ?? "training stop requested")
            case .resetTrainingToBase:
                appServices.engineSelector.primary.cancel()
                let checkpointDir = appServices.personalizedModelDirectory
                guard let engine = appServices.trainingEngine else {
                    appServices.trainingStatusPublisher.recordError("reset requested before model loaded")
                    return nil
                }
                try await CheckpointManager(checkpointDirectory: checkpointDir).resetToBase(
                    engine: engine,
                    context: modelContainer.mainContext,
                    publisher: appServices.trainingStatusPublisher
                )
            case .generateText:
                guard let request = command.generationRequest else {
                    return nil
                }
                await handleGenerationRequest(
                    command: command,
                    request: request,
                    pickedUpAt: pickedUpAt,
                    executionPriority: executionPriority
                )
            case .cancelGeneration:
                guard command.cancelledGenerationCommandID != nil else {
                    print("\(role.logPrefix) ignored generation cancellation without a target request")
                    return nil
                }
            case .embedQueries:
                guard let request = command.queryEmbeddingRequest else {
                    return nil
                }
                await handleQueryEmbeddingRequest(
                    command: command,
                    request: request,
                    pickedUpAt: pickedUpAt,
                    executionPriority: executionPriority
                )
            case .cancelQueryEmbedding:
                guard command.cancelledQueryEmbeddingCommandID != nil else {
                    print("\(role.logPrefix) ignored query embedding cancellation without a target request")
                    return nil
                }
            case .requestInteractiveQwenModelTurn:
                guard statusStore.isUserInteractiveGenerationActive(at: pickedUpAt) else {
                    return nil
                }
                let decision = scheduler.refreshModelResourceSnapshot(
                    context: makeSchedulerContext()
                ).decision
                guard let releaseAction = Self.interactiveQwenModelTurnReleaseAction(
                    role: role,
                    requiresExclusiveModelResidency: decision.requiresExclusiveModelResidency
                ) else {
                    return nil
                }
                await cancelAndDrainRetrievalModelLoadingTask()
                bgeModelLoading = false
                exclusiveModelTurnRequested = false
                await releaseRetrievalModelResourcesAndSlot(
                    includeBGE: releaseAction.includeBGE,
                    reason: releaseAction.reason
                )
                writeHeartbeat(
                    state: .idle,
                    message: "yielded model memory to interactive Qwen"
                )
            case .requestInteractiveBGEModelTurn:
                guard role == .qwen,
                      !statusStore.isInteractiveGenerationActive(at: pickedUpAt),
                      let bgeSnapshot = try? statusStore.snapshot(for: .bge),
                      Self.siblingStatusIsFresh(bgeSnapshot, now: pickedUpAt),
                      bgeSnapshot.state == .throttled,
                      bgeSnapshot.statusMessage?.contains(command.id.uuidString) == true else {
                    return nil
                }
                let decision = scheduler.refreshModelResourceSnapshot(
                    context: makeSchedulerContext()
                ).decision
                guard decision.requiresExclusiveModelResidency else { return nil }
                qwenBackgroundModelLoadingGated = true
                await unloadQwenModel(reason: "interactive retrieval model turn")
                writeHeartbeat(
                    state: .idle,
                    message: "yielded model memory to interactive retrieval"
                )
            case .selectGenerationModel:
                guard let modelID = command.message,
                      let model = ModelManager.allModels.first(where: { $0.modelId == modelID }),
                      let modelLoader
                else {
                    writeHeartbeat(state: .waiting, message: "generation model selection was invalid")
                    return nil
                }
                qwenModelTransitionInProgress = true
                if modelLoader.state == .loading {
                    await unloadQwenModel(reason: "generation model selection during weight load")
                }
                ModelManager.clearStoppedGenerationModelDownload()
                modelLoader.prepareModelSwitch(to: model)
                qwenModelTransitionInProgress = false
                // Pending switches begin a network-only prefetch while active
                // generation keeps using the current in-memory weights.
                prepareQwenModelIfReady()
                let message = modelLoader.isPreparingPendingSwitch
                    ? "preparing \(model.displayName); current Qwen remains active"
                    : "selected \(model.displayName)"
                writeHeartbeat(state: .busy, message: message)
            case .cancelGenerationModelPreparation:
                guard let modelLoader else {
                    writeHeartbeat(state: .waiting, message: "generation model preparation stop was invalid")
                    return nil
                }
                let targetModel = modelLoader.preparationModel
                if let modelID = command.message, modelID != targetModel.modelId {
                    writeHeartbeat(state: .waiting, message: "ignored stale generation model preparation stop")
                    return nil
                }
                qwenModelTransitionInProgress = true
                if modelLoader.state == .loading {
                    await unloadQwenModel(reason: "generation model preparation stopped during weight load")
                }
                ModelManager.setGenerationModelDownloadStopped(true, modelID: targetModel.modelId)
                modelLoader.pauseDownload()
                qwenModelTransitionInProgress = false
                writeHeartbeat(
                    state: .paused,
                    message: "stopped \(targetModel.displayName) download; resume to continue"
                )
            }
            return nil
        } catch {
            print("\(role.logPrefix) command handling failed: \(String(reflecting: type(of: error)))")
            return error.localizedDescription
        }
    }

    private nonisolated static func defaultExecutionPriority(
        for command: WorkerCommandSnapshot
    ) -> TaskPriority {
        switch command.kind {
        case .generateText, .embedQueries, .cancelGeneration,
             .cancelQueryEmbedding, .requestInteractiveQwenModelTurn,
             .requestInteractiveBGEModelTurn:
            return .userInitiated
        case .cancelTraining, .resetTrainingToBase, .selectGenerationModel,
             .cancelGenerationModelPreparation:
            return .utility
        }
    }

    private func handleQueryEmbeddingRequest(
        command: WorkerCommandSnapshot,
        request: WorkerQueryEmbeddingRequest,
        pickedUpAt: Date,
        executionPriority: TaskPriority
    ) async {
        guard role == .bge else {
            recordQueryEmbeddingResponse(
                commandID: command.id,
                request: request,
                status: .failed,
                errorMessage: "Query embedding was sent to the wrong worker."
            )
            return
        }
        guard request.embeddingDimension == BGE3Embedder.embeddingDimension,
              request.embeddingVersion == BGE3Embedder.embeddingVersion else {
            recordQueryEmbeddingResponse(
                commandID: command.id,
                request: request,
                status: .failed,
                errorMessage: "Query embedding identity did not match BGE-M3."
            )
            return
        }

        interactiveRetrievalModelDemand = true
        defer {
            interactiveRetrievalModelDemand = false
            exclusiveModelTurnRequested = false
            writeHeartbeat(state: .idle)
        }

        if queryEmbeddingRequestIsCancelled(
            commandID: command.id,
            request: request,
            at: pickedUpAt
        ) {
            recordQueryEmbeddingResponse(
                commandID: command.id,
                request: request,
                status: .cancelled,
                errorMessage: "Query embedding request was cancelled before inference."
            )
            return
        }

        var modelTurnCommandID: UUID?
        while embeddingProviderUnavailable, !request.isExpired() {
            if queryEmbeddingRequestIsCancelled(
                commandID: command.id,
                request: request
            ) {
                recordQueryEmbeddingResponse(
                    commandID: command.id,
                    request: request,
                    status: .cancelled,
                    errorMessage: "Query embedding request was cancelled while waiting for BGE-M3."
                )
                return
            }

            await awaitRetrievalModelLoadingTaskIfReady()
            if exclusiveModelTurnRequested {
                if modelTurnCommandID == nil {
                    let turnCommand = WorkerCommandSnapshot(
                        kind: .requestInteractiveBGEModelTurn,
                        message: "interactive query embedding model turn",
                        targetCommandID: command.id
                    )
                    modelTurnCommandID = turnCommand.id
                    writeHeartbeat(
                        state: .throttled,
                        message: "interactive query embedding \(turnCommand.id.uuidString) waiting for model turn"
                    )
                    do {
                        try WorkerCommandTransport.shared.submit(turnCommand, to: .qwen)
                    } catch {
                        print("\(role.logPrefix) failed to request interactive BGE model turn: \(String(reflecting: type(of: error)))")
                    }
                }
            }

            if embeddingProviderUnavailable {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        guard !embeddingProviderUnavailable else {
            recordQueryEmbeddingResponse(
                commandID: command.id,
                request: request,
                status: request.isExpired() ? .cancelled : .modelNotLoaded,
                errorMessage: request.isExpired()
                    ? "Query embedding deadline elapsed while waiting for BGE-M3."
                    : "BGE-M3 is not loaded."
            )
            return
        }
        if queryEmbeddingRequestIsCancelled(
            commandID: command.id,
            request: request
        ) {
            recordQueryEmbeddingResponse(
                commandID: command.id,
                request: request,
                status: .cancelled,
                errorMessage: "Query embedding request expired while loading BGE-M3."
            )
            return
        }

        writeHeartbeat(
            state: .busy,
            message: "embedding interactive query",
            currentJobType: "queryEmbedding",
            currentJobDescription: "interactive semantic retrieval"
        )
        let provider = appServices.embedder
        let embeddings: [[Float]?]
        if let asyncProvider = provider as? AsyncEmbeddingProvider {
            embeddings = await asyncProvider.embedBatchAsync(
                request.texts,
                priority: executionPriority
            )
        } else {
            embeddings = await Task.detached(priority: executionPriority) {
                provider.embedBatch(request.texts)
            }.value
        }

        if queryEmbeddingRequestIsCancelled(
            commandID: command.id,
            request: request
        ) {
            recordQueryEmbeddingResponse(
                commandID: command.id,
                request: request,
                status: .cancelled,
                errorMessage: "Query embedding request was cancelled during inference."
            )
            return
        }
        guard embeddings.count == request.texts.count,
              embeddings.allSatisfy({ $0 == nil || $0?.count == request.embeddingDimension }) else {
            recordQueryEmbeddingResponse(
                commandID: command.id,
                request: request,
                status: .failed,
                errorMessage: "BGE-M3 returned an invalid embedding batch."
            )
            return
        }
        recordQueryEmbeddingResponse(
            commandID: command.id,
            request: request,
            status: .success,
            embeddings: embeddings
        )
    }

    private func queryEmbeddingRequestIsCancelled(
        commandID: UUID,
        request: WorkerQueryEmbeddingRequest,
        at date: Date = Date()
    ) -> Bool {
        directlyCancelledQueryEmbeddingCommandIDs.contains(commandID)
            || request.isExpired(at: date)
            || ((try? statusStore.hasQueryEmbeddingCancellationCommand(
                for: .bge,
                targetCommandID: commandID
            )) == true)
    }

    private func recordQueryEmbeddingResponse(
        commandID: UUID,
        request: WorkerQueryEmbeddingRequest,
        status: WorkerQueryEmbeddingResponseStatus,
        embeddings: [[Float]?]? = nil,
        errorMessage: String? = nil
    ) {
        do {
            liveResponseData[commandID] = try WorkerXPCPayloadCodec.encodeQueryEmbeddingResponse(
                WorkerQueryEmbeddingResponseSnapshot(
                    commandID: commandID,
                    status: status,
                    embeddings: embeddings,
                    embeddingDimension: request.embeddingDimension,
                    embeddingVersion: request.embeddingVersion,
                    errorMessage: errorMessage
                )
            )
        } catch {
            print("\(role.logPrefix) query embedding response encoding failed: \(String(reflecting: type(of: error)))")
        }
    }

    private func handleGenerationRequest(
        command: WorkerCommandSnapshot,
        request: WorkerGenerationRequest,
        pickedUpAt: Date,
        executionPriority: TaskPriority
    ) async {
        activeGenerationHeartbeat = ActiveGenerationHeartbeat(
            description: request.activityLabel,
            promptUsage: nil
        )
        writeHeartbeat(
            state: .busy,
            message: "handling generation request",
            currentJobType: "generation",
            currentJobDescription: request.activityLabel
        )
        defer {
            activeGenerationHeartbeat = nil
            writeHeartbeat(state: .idle)
        }

        // XPC commands and scheduler jobs run in separate tasks. The foreground
        // lease asks training to yield; wait for its adapter restore to finish,
        // or for boot qualification to select a passing adapter, before decoding.
        while role == .qwen && (modelLoader?.state == .loading || currentPipelineJobType == .train) {
            if Task.isCancelled || directlyCancelledGenerationCommandIDs.contains(command.id)
                || request.isExpired()
                || ((try? statusStore.hasGenerationCancellationCommand(
                    for: role.coreRole, targetCommandID: command.id)) == true) { break }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { break }
        }

        if Task.isCancelled || directlyCancelledGenerationCommandIDs.contains(command.id)
            || request.isExpired()
            || ((try? statusStore.hasGenerationCancellationCommand(
                for: role.coreRole,
                targetCommandID: command.id
            )) == true) {
            recordGenerationResponse(
                commandID: command.id,
                request: request,
                status: .cancelled,
                errorMessage: "Generation request was cancelled before decoding started.",
                pickedUpAt: pickedUpAt,
                decodeStartedAt: nil,
                decodeFinishedAt: nil
            )
            return
        }

        guard let engine = appServices.activeEngine else {
            recordGenerationResponse(
                commandID: command.id,
                request: request,
                status: .modelNotLoaded,
                errorMessage: "Generative model is not loaded.",
                pickedUpAt: pickedUpAt,
                decodeStartedAt: nil,
                decodeFinishedAt: nil
            )
            return
        }

        let promptUsage: WorkerPromptUsageSnapshot?
        if let tokenCounter = engine as? any PromptTokenCounting {
            promptUsage = WorkerGenerationContextUsage.measure(
                request: request,
                tokenCounter: tokenCounter
            )
        } else {
            promptUsage = nil
        }
        activeGenerationHeartbeat = ActiveGenerationHeartbeat(
            description: request.activityLabel,
            promptUsage: promptUsage
        )
        writeHeartbeat(
            state: .busy,
            message: "handling generation request",
            currentJobType: "generation",
            currentJobDescription: request.activityLabel,
            promptUsage: promptUsage
        )

        let decodeStartedAt = Date()
        do {
            let prompt = request.resolvedPrompt
            let maxTokens = request.maxTokens
            let cancellation = GenerationCancellation()
            let generationTask = Task.detached(priority: executionPriority) { () -> GenerationResult in
                try Task.checkCancellation()
                if let conversation = request.conversation,
                   let conversational = engine as? any ConversationalGenerating {
                    return try conversational.generate(
                        conversation: conversation,
                        maxTokens: maxTokens,
                        cancellation: cancellation,
                        personalization: request.resolvedPersonalization
                    )
                }
                if let cachedPrompt = request.cachedPrompt {
                    return try PrefixCachedGeneration.generateResult(
                        engine: engine,
                        prompt: cachedPrompt,
                        maxTokens: maxTokens,
                        cancellation: cancellation,
                        personalization: request.resolvedPersonalization,
                        sampling: request.sampling
                    )
                }
                return try PrefixCachedGeneration.generateResult(
                    engine: engine,
                    prompt: prompt,
                    maxTokens: maxTokens,
                    cancellation: cancellation,
                    personalization: request.resolvedPersonalization,
                    sampling: request.sampling
                )
            }
            let result = try await waitForGeneration(
                generationTask,
                command: command,
                cancellation: cancellation
            )
            let decodeFinishedAt = Date()
            recordGenerationResponse(
                commandID: command.id,
                request: request,
                status: .success,
                text: result.text,
                reasoningContent: result.reasoningContent,
                continuationFingerprint: result.continuationFingerprint,
                stopReason: result.stopReason,
                personalization: result.personalization,
                diagnostics: result.diagnostics,
                pickedUpAt: pickedUpAt,
                decodeStartedAt: decodeStartedAt,
                decodeFinishedAt: decodeFinishedAt
            )
        } catch is CancellationError {
            recordGenerationResponse(
                commandID: command.id,
                request: request,
                status: .cancelled,
                errorMessage: "Generation request was cancelled.",
                pickedUpAt: pickedUpAt,
                decodeStartedAt: decodeStartedAt,
                decodeFinishedAt: Date()
            )
        } catch TrainingEngineError.modelNotLoaded {
            recordGenerationResponse(
                commandID: command.id,
                request: request,
                status: .modelNotLoaded,
                errorMessage: "Generative model is not loaded.",
                pickedUpAt: pickedUpAt,
                decodeStartedAt: decodeStartedAt,
                decodeFinishedAt: Date()
            )
        } catch {
            recordGenerationResponse(
                commandID: command.id,
                request: request,
                status: .failed,
                errorMessage: error.localizedDescription,
                pickedUpAt: pickedUpAt,
                decodeStartedAt: decodeStartedAt,
                decodeFinishedAt: Date()
            )
        }
    }

    private func waitForGeneration(
        _ generationTask: Task<GenerationResult, Error>,
        command: WorkerCommandSnapshot,
        cancellation: GenerationCancellation
    ) async throws -> GenerationResult {
        let statusStore = self.statusStore
        let role = self.role.coreRole
        let issuedAt = command.issuedAt
        return try await ActiveGenerationTaskMonitor.wait(
            for: generationTask,
            cancellation: cancellation,
            deadline: command.generationRequest?.deadline
        ) {
            do {
                if await self.directlyCancelledGenerationCommandIDs.contains(command.id) {
                    return true
                }
                if try statusStore.hasGenerationCancellationCommand(
                    for: role,
                    targetCommandID: command.id
                ) {
                    return true
                }
                if command.isLensAssistGeneration {
                    return try statusStore.hasSupersedingUserInteractiveGenerationCommand(
                        for: role,
                        issuedAfter: issuedAt
                    )
                }
                if command.isInteractiveSummarizationFastLane {
                    return try statusStore.hasSupersedingInteractiveSummarizationCommand(
                        for: role,
                        issuedAfter: issuedAt
                    )
                }
                return false
            } catch {
                // A transient status-directory read error must not abort an
                // otherwise healthy decode. The next poll retries.
                return false
            }
        }
    }

    private func recordGenerationResponse(
        commandID: UUID,
        request _: WorkerGenerationRequest,
        status: WorkerGenerationResponseStatus,
        text: String? = nil,
        reasoningContent: String? = nil,
        continuationFingerprint: String? = nil,
        stopReason: GenerationStopReason? = nil,
        personalization: GenerationPersonalization? = nil,
        diagnostics: GenerationDiagnostics? = nil,
        errorMessage: String? = nil,
        pickedUpAt: Date,
        decodeStartedAt: Date?,
        decodeFinishedAt: Date?
    ) {
        do {
            liveResponseData[commandID] = try WorkerXPCPayloadCodec.encodeGenerationResponse(
                WorkerGenerationResponseSnapshot(
                    commandID: commandID,
                    status: status,
                    text: text,
                    reasoningContent: reasoningContent,
                    continuationFingerprint: continuationFingerprint,
                    stopReason: stopReason,
                    errorMessage: errorMessage,
                    pickedUpAt: pickedUpAt,
                    decodeStartedAt: decodeStartedAt,
                    decodeFinishedAt: decodeFinishedAt,
                    personalization: personalization,
                    diagnostics: diagnostics
                )
            )
        } catch {
            print("\(role.logPrefix) generation response encoding failed: \(String(reflecting: type(of: error)))")
        }
    }

    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.requestStop(message: "SIGTERM received")
            }
        }
        term.resume()

        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.requestStop(message: "SIGINT received")
            }
        }
        interrupt.resume()
        signalSources = [term, interrupt]
    }

    private func requestStop(message: String) {
        shouldStop = true
        scheduler.isPaused = true
        mailActionTasks.forEach { $0.cancel() }
        beginIMAPShutdown()
        idleWakeGate.wake()
        appServices.engineSelector.primary.cancel()
        // Preserve preparation task handles so the async shutdown path can
        // await every in-flight MLX constructor before releasing its model
        // residency lease.
        modelLoader?.requestPreparationCancellationForDrain()
        retrievalModelLoadTask?.cancel()
        writeHeartbeat(state: .stopping, message: message)
    }

    private func beginIMAPShutdown() {
        guard imapShutdownTask == nil else { return }
        // Closing transports releases reads/writes that task cancellation
        // alone cannot finish. Start now, even if the pipeline tick is waiting
        // on mail I/O, and join this same shutdown before draining mail tasks.
        imapShutdownTask = Task { await imapSessionManager.shutdown() }
    }

    private func installParentExitMonitor() {
        guard let parentPID else { return }

        if parentProcessExited() {
            fputs("\(role.logPrefix) parent pid \(parentPID) already exited; terminating helper\n", stderr)
            fflush(stderr)
            Darwin._exit(0)
        }

        let monitoredParentPID = pid_t(parentPID)
        let logPrefix = role.logPrefix
        let source = Self.makeParentExitSource(
            monitoredParentPID: monitoredParentPID,
            logPrefix: logPrefix
        )
        source.resume()
        parentExitSource = source
    }

    private nonisolated static func makeParentExitSource(
        monitoredParentPID: pid_t,
        logPrefix: String
    ) -> DispatchSourceProcess {
        let source = DispatchSource.makeProcessSource(
            identifier: monitoredParentPID,
            eventMask: .exit,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler {
            fputs("\(logPrefix) parent pid \(monitoredParentPID) exited; terminating helper\n", stderr)
            fflush(stderr)
            Darwin._exit(0)
        }
        return source
    }

    private func acquireWorkerLock() -> Bool {
        lockFD = open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { return false }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD)
            lockFD = -1
            return false
        }

        ftruncate(lockFD, 0)
        let pidLine = "\(getpid())\n"
        _ = pidLine.withCString { pointer in
            write(lockFD, pointer, strlen(pointer))
        }
        return true
    }

    private func releaseWorkerLock() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
        try? FileManager.default.removeItem(at: lockURL)
    }

    private func writeHeartbeat(
        state: WorkerState,
        message: String? = nil,
        currentJobType: String? = nil,
        currentJobDescription: String? = nil,
        promptUsage: WorkerPromptUsageSnapshot? = nil
    ) {
        let activeGeneration = activeGenerationHeartbeat
        let resolvedJobType = activeGeneration == nil
            ? currentJobType
            : "generation"
        let resolvedJobDescription = activeGeneration?.description
            ?? currentJobDescription
        let resolvedPromptUsage = activeGeneration?.promptUsage
            ?? promptUsage
        let resolvedState = activeGeneration == nil
            ? state
            : .busy
        let projection = scheduler.cachedModelResourceSnapshot.map {
            WorkerResourceStatusMapper.projection(
                role: role,
                snapshot: $0
            )
        }
        let model = modelStatusSnapshot()
        let training = role == .qwen
            ? appServices.trainingStatusPublisher.workerSnapshot()
            : nil
        let resource = projection?.resource
        let throttle = projection?.throttle ?? .notThrottled
        let statusMessage = message ?? model?.message
        let signature = WorkerHeartbeatSignature(
            state: resolvedState,
            currentJobType: resolvedJobType,
            currentJobDescription: resolvedJobDescription,
            promptUsage: resolvedPromptUsage,
            throttle: throttle,
            statusMessage: statusMessage,
            model: model,
            training: training,
            resource: resource
        )
        let cadenceInstant = ContinuousClock.now
        guard heartbeatWriteGate.shouldWrite(
            signature,
            at: cadenceInstant
        ) else {
            return
        }

        let now = Date()
        do {
            _ = try statusStore.heartbeat(
                role: role.coreRole,
                pid: getpid(),
                parentPID: parentPID,
                state: resolvedState,
                currentJobType: resolvedJobType,
                currentJobDescription: resolvedJobDescription,
                promptUsage: resolvedPromptUsage,
                throttle: throttle,
                statusMessage: statusMessage,
                model: model,
                training: training,
                resource: resource,
                completionStreamID: completionStreamID,
                imapActivityStreamID: role == .bge ? completionStreamID : nil,
                at: now
            )
            heartbeatWriteGate.recordSuccessfulWrite(
                signature,
                at: cadenceInstant
            )
        } catch {
            print("\(role.logPrefix) heartbeat write failed: \(String(reflecting: type(of: error)))")
        }
    }

    private func markStopped() {
        do {
            _ = try statusStore.markStopped(
                role: role.coreRole,
                pid: getpid(),
                parentPID: parentPID,
                message: nil
            )
        } catch {
            print("\(role.logPrefix) stop status write failed: \(String(reflecting: type(of: error)))")
        }
    }

    private func modelStatusSnapshot() -> WorkerModelStatusSnapshot? {
        switch role {
        case .bge:
            let retrievalModelIsResident = embeddingProviderUnavailable == false
                || appServices.crossEncoderReranker != nil
            if bgeModelLoading || retrievalModelConstructionInFlight {
                return WorkerModelStatusSnapshot(
                    name: "bge-m3",
                    state: .loading,
                    isResident: retrievalModelIsResident,
                    laneCount: 1,
                    message: bgeModelLoading
                        ? "loading bge-m3 model"
                        : "loading retrieval reranker"
                )
            }
            let bgeState = appServices.bge3RuntimeState
            switch bgeState {
            case .unavailable(_, _):
                return WorkerModelStatusSnapshot(
                    name: "bge-m3",
                    state: .unavailable,
                    isResident: retrievalModelIsResident,
                    laneCount: nil,
                    message: bgeState.statusMessage
                )
            case .downloading(let fraction, _):
                return WorkerModelStatusSnapshot(
                    name: "bge-m3",
                    state: .downloading(fraction: fraction),
                    isResident: retrievalModelIsResident,
                    laneCount: nil,
                    message: bgeState.statusMessage
                )
            case .loading:
                return WorkerModelStatusSnapshot(
                    name: "bge-m3",
                    state: .loading,
                    isResident: retrievalModelIsResident,
                    laneCount: nil,
                    message: bgeState.statusMessage
                )
            case .ready(let lanes):
                return WorkerModelStatusSnapshot(
                    name: "bge-m3",
                    state: .ready,
                    isResident: retrievalModelIsResident,
                    laneCount: lanes
                )
            case .failed(let message):
                return WorkerModelStatusSnapshot(
                    name: "bge-m3",
                    state: .failed(message),
                    isResident: retrievalModelIsResident,
                    laneCount: nil,
                    message: bgeState.statusMessage
                )
            }
        case .qwen:
            if let modelLoader {
                let state: WorkerModelLoadState
                switch modelLoader.state {
                case .idle:
                    state = appServices.engineSelector.primary.isModelLoaded ? .ready : .unavailable
                case .downloading(let fraction):
                    state = .downloading(fraction: fraction)
                case .downloaded:
                    state = .downloaded
                case .loading:
                    state = .loading
                case .paused(let message):
                    state = .paused(message)
                case .ready:
                    state = .ready
                case .failed(let message):
                    state = .failed(message)
                }
                let model = modelLoader.preparationModel
                let message = modelLoader.isPreparingPendingSwitch
                    ? qwenPendingModelStatusMessage(
                        for: state,
                        activeModel: modelLoader.selectedModel,
                        pendingModel: model
                    )
                    : qwenModelStatusMessage(for: state)
                return WorkerModelStatusSnapshot(
                    name: model.displayName,
                    state: state,
                    isResident: appServices.engineSelector.primary.isModelLoaded,
                    message: message,
                    download: qwenDownloadSnapshot(for: model)
                )
            }
            return WorkerModelStatusSnapshot(
                name: "Qwen",
                state: appServices.engineSelector.primary.isModelLoaded ? .ready : .unavailable,
                isResident: appServices.engineSelector.primary.isModelLoaded
            )
        }
    }

    private func qwenModelStatusMessage(for state: WorkerModelLoadState) -> String? {
        switch state {
        case .unavailable:
            return "waiting to download"
        case .downloading:
            return "downloading model files"
        case .downloaded:
            return "downloaded; waiting for load resources"
        case .loading:
            return "loading model weights"
        case .paused(let message):
            return message ?? "download stopped; resume to continue"
        case .ready, .failed:
            return nil
        }
    }

    private func qwenPendingModelStatusMessage(
        for state: WorkerModelLoadState,
        activeModel: ModelInfo,
        pendingModel: ModelInfo
    ) -> String? {
        switch state {
        case .unavailable:
            return "preparing \(pendingModel.displayName); \(activeModel.displayName) remains active"
        case .downloading:
            return "downloading \(pendingModel.displayName); \(activeModel.displayName) remains active"
        case .downloaded:
            return "downloaded \(pendingModel.displayName); waiting for load resources"
        case .loading:
            return "activating \(pendingModel.displayName)"
        case .paused(let message):
            return message ?? "stopped \(pendingModel.displayName) download; \(activeModel.displayName) remains active"
        case .ready:
            return nil
        case .failed(let message):
            return message
        }
    }

    private func qwenDownloadSnapshot(for model: ModelInfo) -> WorkerModelDownloadSnapshot? {
        let downloadBaseDirectory = appServices.generationModelDownloadBaseDirectory
        let modelDirectory = GenerationModelStorage.modelDirectory(
            downloadBaseDirectory: downloadBaseDirectory,
            modelID: model.modelId
        )

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }

        let totalBytes = qwenSafetensorsTotalBytes(in: modelDirectory)
            ?? qwenEstimatedDownloadBytes(for: model)
        let rawDownloadedBytes = qwenDownloadedWeightBytes(in: modelDirectory)
        let downloadedBytes: Int64
        if let totalBytes, totalBytes > 0 {
            downloadedBytes = min(max(0, rawDownloadedBytes), totalBytes)
        } else {
            downloadedBytes = max(0, rawDownloadedBytes)
        }

        return WorkerModelDownloadSnapshot(
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes
        )
    }

    private func qwenEstimatedDownloadBytes(for model: ModelInfo) -> Int64? {
        let bytes = Int64((model.estimatedDownloadGB * 1_000_000_000).rounded())
        return bytes > 0 ? bytes : nil
    }

    private func qwenSafetensorsTotalBytes(in modelDirectory: URL) -> Int64? {
        let indexURL = modelDirectory.appendingPathComponent("model.safetensors.index.json")
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? JSONDecoder()
            .decode(SafetensorsIndex.self, from: data)
            .metadata?
            .totalSize
    }

    private func qwenDownloadedWeightBytes(in modelDirectory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: modelDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let filename = url.lastPathComponent
            let path = url.path
            let isCacheDownload = path.contains("/.cache/huggingface/download/")
            let isIncompleteWeight = isCacheDownload
                && filename.contains(".safetensors.")
                && filename.hasSuffix(".incomplete")
            let isCompletedWeight = !path.contains("/.cache/")
                && filename.hasSuffix(".safetensors")
            guard isIncompleteWeight || isCompletedWeight else { continue }

            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize
            else {
                continue
            }
            total += Int64(fileSize)
        }
        return total
    }

    private struct SafetensorsIndex: Decodable {
        let metadata: Metadata?

        struct Metadata: Decodable {
            let totalSize: Int64?

            enum CodingKeys: String, CodingKey {
                case totalSize = "total_size"
            }
        }
    }

    private var embeddingProviderUnavailable: Bool {
        if appServices.embedder is UnavailableEmbedder { return true }
        if let swappable = appServices.embedder as? SwappableEmbedder {
            return swappable.isUsingUnavailableProvider
        }
        return false
    }

    private static func siblingModelWorkerActiveClosure(
        role: WorkerRole,
        statusStore: WorkerStatusStore
    ) -> () -> Bool {
        let siblingRole: OhiaCore.WorkerRole = role == .bge ? .qwen : .bge
        return {
            let snapshot = try? statusStore.snapshot(for: siblingRole)
            return Self.siblingModelWorkerIsActive(snapshot: snapshot, now: Date())
        }
    }

    private static func siblingModelResidentClosure(
        role: WorkerRole,
        statusStore: WorkerStatusStore
    ) -> () -> Bool {
        let siblingRole: OhiaCore.WorkerRole = role == .bge ? .qwen : .bge
        return {
            let snapshot = try? statusStore.snapshot(for: siblingRole)
            return Self.siblingModelIsResident(snapshot: snapshot, now: Date())
        }
    }

    nonisolated static func siblingModelWorkerIsActive(
        snapshot: WorkerStatusSnapshot?,
        now: Date = Date()
    ) -> Bool {
        guard let snapshot else { return false }
        if !siblingStatusIsFresh(snapshot, now: now) {
            return staleResidentWorkerMustFailClosed(snapshot)
        }
        if let model = snapshot.model, let isResident = model.isResident {
            // Weight loading owns the slot even before the engine can report
            // itself resident. Otherwise an explicit nonresident signal wins
            // over generic busy/running states from unrelated worker jobs.
            if case .loading = model.state { return true }
            guard isResident else { return false }

            switch snapshot.state {
            case .starting, .running, .busy, .throttled:
                return true
            case .waiting, .idle, .paused, .stopping, .stopped, .failed, .unknown:
                return false
            }
        }

        // Older snapshots have no explicit residency signal. Preserve their
        // conservative state-based behavior until both workers have upgraded.
        switch snapshot.state {
        case .starting, .running, .busy, .throttled:
            return true
        case .waiting, .idle, .paused, .stopping, .stopped, .failed, .unknown:
            break
        }
        if let model = snapshot.model {
            switch model.state {
            case .loading:
                return true
            case .downloading:
                return model.isResident == nil
            case .downloaded, .paused, .ready, .unavailable, .failed:
                break
            }
        }
        return false
    }

    nonisolated static func siblingModelIsResident(
        snapshot: WorkerStatusSnapshot?,
        now: Date = Date()
    ) -> Bool {
        guard let snapshot else { return false }
        if !siblingStatusIsFresh(snapshot, now: now) {
            return staleResidentWorkerMustFailClosed(snapshot)
        }
        guard let model = snapshot.model else { return false }
        if model.isResident == true { return true }
        switch model.state {
        case .loading, .ready:
            return model.isResident != false || model.state == .loading
        case .unavailable, .downloading, .downloaded, .paused, .failed:
            return false
        }
    }

    private nonisolated static func siblingStatusIsFresh(
        _ snapshot: WorkerStatusSnapshot,
        now: Date
    ) -> Bool {
        now.timeIntervalSince(snapshot.updatedAt) < 15
    }

    /// A model-heavy synchronous Core ML operation can keep the worker's main
    /// actor from refreshing its heartbeat for more than the normal freshness
    /// window. On exclusive-memory Macs, a live process whose last model state
    /// was loading/ready therefore remains resident until it explicitly
    /// publishes release. Failing open here can start Qwen over an active BGE
    /// prediction and exceed the machine's safe working set.
    private nonisolated static func staleResidentWorkerMustFailClosed(
        _ snapshot: WorkerStatusSnapshot
    ) -> Bool {
        guard let pid = snapshot.pid,
              pid > 1,
              snapshot.state != .stopping,
              snapshot.state != .stopped,
              snapshot.state != .failed,
              let model = snapshot.model else {
            return false
        }
        let ownsModelMemory: Bool
        if case .loading = model.state {
            ownsModelMemory = true
        } else if let isResident = model.isResident {
            ownsModelMemory = isResident
        } else {
            // Legacy snapshots have no explicit signal. Preserve the previous
            // fail-closed interpretation for ready/loading states only.
            ownsModelMemory = model.state == .ready
        }
        guard ownsModelMemory else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    private static func statusDirectoryURL(storageLayout: OhiaStorageLayout) -> URL {
        if let raw = ProcessInfo.processInfo.environment["OHIA_WORKER_STATUS_DIR"],
           !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return storageLayout.workerState
    }

    private static func parentPIDFromEnvironment() -> Int32? {
        guard let raw = ProcessInfo.processInfo.environment["OHIA_PARENT_PID"],
              let value = Int32(raw),
              value > 1 else {
            return nil
        }
        return value
    }

    private func parentProcessExited() -> Bool {
        guard let parentPID else { return false }
        if kill(parentPID, 0) == 0 {
            return false
        }
        return errno == ESRCH
    }
}

/// Owns the GCD file-system source outside `OhiaWorkerRuntime`'s `@MainActor`
/// isolation. Capturing a MainActor-local `AsyncStream.Continuation` in the
/// dispatch callback trips Swift's executor check when a command file arrives.
private final class CommandDirectoryActivityWatcher: @unchecked Sendable {
    let stream: AsyncStream<Void>

    private let continuation: AsyncStream<Void>.Continuation
    private let source: DispatchSourceFileSystemObject?
    private let backstopTask: Task<Void, Never>
    private let cancellationLock = NSLock()
    private var isCancelled = false

    init(queueDirectory: URL, logPrefix: String) {
        try? FileManager.default.createDirectory(
            at: queueDirectory,
            withIntermediateDirectories: true
        )

        let streamPair = AsyncStream<Void>.makeStream(of: Void.self)
        self.stream = streamPair.stream
        self.continuation = streamPair.continuation

        let fd = open(queueDirectory.path, O_EVTONLY)
        let backstopInterval: Duration
        if fd >= 0 {
            let queue = DispatchQueue(
                label: "org.jgkarlin.Ohia.worker.commandWatcher",
                qos: .userInitiated
            )
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename],
                queue: queue
            )
            let continuation = streamPair.continuation
            source.setEventHandler {
                continuation.yield()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            self.source = source
            backstopInterval = .seconds(30)
        } else {
            self.source = nil
            backstopInterval = .milliseconds(500)
            print("\(logPrefix) command queue watcher could not arm (errno=\(errno)); falling back to backstop polling")
        }

        let continuation = streamPair.continuation
        self.backstopTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: backstopInterval)
                } catch {
                    return
                }
                continuation.yield()
            }
        }
    }

    deinit {
        cancel()
    }

    func cancel() {
        cancellationLock.lock()
        guard !isCancelled else {
            cancellationLock.unlock()
            return
        }
        isCancelled = true
        cancellationLock.unlock()

        backstopTask.cancel()
        source?.cancel()
        continuation.finish()
    }
}
