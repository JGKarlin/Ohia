import Darwin
import Foundation
import OhiaCore
import OhiaML
import SwiftUI

private struct WorkerFleetSupervisorEnvironmentKey: EnvironmentKey {
    static let defaultValue: WorkerFleetSupervisor? = nil
}

extension EnvironmentValues {
    var workerFleetSupervisor: WorkerFleetSupervisor? {
        get { self[WorkerFleetSupervisorEnvironmentKey.self] }
        set { self[WorkerFleetSupervisorEnvironmentKey.self] = newValue }
    }
}

struct MCPWorkerCredentialSnapshotCoordinator {
    private(set) var generation: UInt64 = 0
    private var values: [UUID: [String: String]]?

    mutating func snapshot(
        replacing replacement: [UUID: [String: String]]
    ) -> (snapshot: MCPWorkerCredentialSnapshot, changed: Bool) {
        let changed = values != replacement
        if changed {
            generation += 1
            values = replacement
        }
        return (
            MCPWorkerCredentialSnapshot(
                generation: generation,
                values: values ?? replacement
            ),
            changed
        )
    }
}

@MainActor
protocol WorkerSupervisorConnection: AnyObject {
    func start() throws
    func updateMCPEnvironment(
        _ snapshotData: Data,
        onAcknowledged acknowledgement: @escaping @Sendable (NSError?) -> Void
    ) throws
    func shutdown(
        onAcknowledged acknowledgement: @escaping @Sendable (NSError?) -> Void
    ) throws
    func invalidate()
}

extension WorkerXPCConnectionClient: WorkerSupervisorConnection {}

@MainActor
final class WorkerQuitStopBarrier {
    private(set) var pendingRoles: Set<WorkerRole> = []
    private var continuation: CheckedContinuation<Set<WorkerRole>, Never>?

    func begin(roles: Set<WorkerRole>) {
        pendingRoles = roles
        resumeIfFinished()
    }

    func finish(role: WorkerRole) {
        guard pendingRoles.remove(role) != nil else { return }
        resumeIfFinished()
    }

    func wait() async -> Set<WorkerRole> {
        guard !pendingRoles.isEmpty else { return [] }
        guard !Task.isCancelled else { return pendingRoles }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || pendingRoles.isEmpty {
                    continuation.resume(returning: pendingRoles)
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelWait()
            }
        }
    }

    private func resumeIfFinished() {
        guard pendingRoles.isEmpty, let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: [])
    }

    private func cancelWait() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: pendingRoles)
    }
}

/// Owns app-private XPC connections while launchd owns worker processes.
/// Durable status, role locks, and reset cleanup remain file-backed because
/// they are recovery state rather than live command transport.
@MainActor
final class WorkerFleetSupervisor {
    private let roles: [WorkerRole]
    private let enabledDefault: Bool
    private let statusStore: WorkerStatusStore
    private let commandTransport: WorkerCommandTransport
    private let mailCredentialBroker: MailCredentialBroker
    private let messagesTranscriptBroker: MessagesTranscriptBroker
    private let statusObserver: WorkerStatusDirectoryObserver

    private var connections: [WorkerRole: any WorkerSupervisorConnection]
    private var expectedTerminations: Set<WorkerRole> = []
    private var lastLaunchAt: [WorkerRole: Date] = [:]
    private var restartBackoffUntil: [WorkerRole: Date] = [:]
    private var unexpectedExitCounts: [WorkerRole: Int] = [:]
    private var restartTasks: [WorkerRole: Task<Void, Never>] = [:]
    private var pendingStartsAfterStop: Set<WorkerRole> = []
    private var mcpCredentialSnapshots = MCPWorkerCredentialSnapshotCoordinator()
    private var mcpUpdateInFlightGeneration: UInt64?
    private var pendingMCPUpdate: MCPWorkerCredentialSnapshot?
    private let quitStopBarrier = WorkerQuitStopBarrier()
    private(set) var isStoppingForQuit = false

    init(
        roles: [WorkerRole] = WorkerRole.allCases,
        enabledDefault: Bool = true,
        statusStore: WorkerStatusStore = WorkerStatusStore(),
        commandTransport: WorkerCommandTransport = .shared,
        mailCredentialBroker: MailCredentialBroker = .shared,
        messagesTranscriptBroker: MessagesTranscriptBroker = MessagesTranscriptBroker(),
        initialConnections: [WorkerRole: any WorkerSupervisorConnection] = [:]
    ) {
        self.roles = roles
        self.enabledDefault = enabledDefault
        self.statusStore = statusStore
        self.commandTransport = commandTransport
        self.mailCredentialBroker = mailCredentialBroker
        self.messagesTranscriptBroker = messagesTranscriptBroker
        self.connections = initialConnections
        self.statusObserver = WorkerStatusDirectoryObserver(
            directoryURL: statusStore.directoryURL
        )
    }

    var isRunning: Bool {
        roles.contains { connections[$0] != nil }
    }

    var isFleetRunning: Bool {
        roles.allSatisfy { connections[$0] != nil }
    }

    var statusInvalidations: AsyncStream<Void> {
        statusObserver.stream
    }

    var isEnabled: Bool {
        if let value = UserDefaults.standard.object(
            forKey: "ohia.pipeline.externalWorker.enabled"
        ) as? Bool {
            return value
        }
        return enabledDefault
    }

    var pendingQuitStopRoles: Set<WorkerRole> {
        quitStopBarrier.pendingRoles
    }

    var scheduledRestartRoles: Set<WorkerRole> {
        Set(restartTasks.keys)
    }

    @discardableResult
    func start(roles requestedRoles: [WorkerRole]? = nil) -> Bool {
        guard !AccountDisconnectionRequest.isPending else { return false }
        guard !isStoppingForQuit else { return false }
        guard isEnabled else { return false }
        let targetRoles = requestedRoles ?? roles
        guard !targetRoles.isEmpty else { return true }
        var startedRoles = Set<WorkerRole>()
        pendingStartsAfterStop.formUnion(
            targetRoles.filter { expectedTerminations.contains($0) }
        )
        if targetRoles.allSatisfy({ connections[$0] != nil }) { return true }

        let rolesToStart = targetRoles.filter {
            connections[$0] == nil && !isRestartBackoffActive(for: $0)
        }
        guard !rolesToStart.isEmpty else {
            return targetRoles.allSatisfy { connections[$0] != nil }
        }

        let missingServices = rolesToStart.filter { locateServiceBundle(for: $0) == nil }
        guard missingServices.isEmpty else {
            for role in missingServices {
                recordFailure(
                    role: role,
                    message: "\(role.processName) XPC service unavailable"
                )
            }
            stopAfterStartFailure(
                requestedRolesWereExplicit: requestedRoles != nil,
                startedRoles: startedRoles
            )
            print("[Ohia] worker XPC fleet unavailable — heavy pipeline work degraded")
            return false
        }

        for role in rolesToStart {
            guard startConnection(for: role) else {
                stopAfterStartFailure(
                    requestedRolesWereExplicit: requestedRoles != nil,
                    startedRoles: startedRoles
                )
                print("[Ohia] worker XPC fleet launch failed — heavy pipeline work degraded")
                return false
            }
            startedRoles.insert(role)
        }

        return targetRoles.allSatisfy { connections[$0] != nil }
    }

    private func stopAfterStartFailure(
        requestedRolesWereExplicit: Bool,
        startedRoles: Set<WorkerRole>
    ) {
        let stopRoles = Self.rolesToStopAfterStartFailure(
            requestedRolesWereExplicit: requestedRolesWereExplicit,
            startedRoles: startedRoles,
            activeRoles: Set(connections.keys)
        )
        guard requestedRolesWereExplicit else {
            stop()
            return
        }
        _ = stopConnections(roles: stopRoles)
    }

    static func rolesToStopAfterStartFailure(
        requestedRolesWereExplicit: Bool,
        startedRoles: Set<WorkerRole>,
        activeRoles: Set<WorkerRole>
    ) -> Set<WorkerRole> {
        requestedRolesWereExplicit ? startedRoles : activeRoles
    }

    func stop() {
        pendingStartsAfterStop.removeAll()
        _ = stopConnections()
    }

    func stopForQuit() async -> Set<WorkerRole> {
        isStoppingForQuit = true
        pendingStartsAfterStop.removeAll()
        quitStopBarrier.begin(roles: Set(connections.keys))
        _ = stopConnections()
        return await quitStopBarrier.wait()
    }

    @discardableResult
    func stopAndWait(timeout: TimeInterval = 30) async -> Bool {
        pendingStartsAfterStop.removeAll()
        let activeRoles = stopConnections()
        let externalTargets = stopExternallyOwnedWorkers(excluding: activeRoles)

        if await waitForWorkerStop(
            activeRoles: activeRoles,
            externalTargets: externalTargets,
            timeout: timeout
        ) {
            return true
        }

        logWorkerStopTimeout(
            activeRoles: activeRoles,
            externalTargets: externalTargets
        )

        guard forceKillWorkers(
            roles: Set(roles),
            externalTargets: externalTargets
        ) else {
            return false
        }

        let forceKillTimeout = min(2, max(0.2, timeout / 4))
        let completed = await waitForWorkerStop(
            activeRoles: activeRoles,
            externalTargets: externalTargets,
            timeout: forceKillTimeout
        )
        if !completed {
            logWorkerStopTimeout(
                activeRoles: activeRoles,
                externalTargets: externalTargets
            )
        }
        return completed
    }

    func clearResetArtifacts() throws {
        try statusStore.removeRuntimeArtifacts()
        try removeUnlockedRoleLockFiles()
    }

    func status(for role: WorkerRole) -> WorkerStatusSnapshot? {
        if let snapshot = try? statusStore.snapshot(for: role) {
            return snapshot
        }
        guard connections[role] != nil else { return nil }
        return WorkerStatusSnapshot(
            role: role,
            parentPID: getpid(),
            state: .starting,
            statusMessage: "connecting to \(role.displayName)",
            updatedAt: Date()
        )
    }

    func statusSnapshots() -> [WorkerStatusSnapshot] {
        roles.map { role in
            status(for: role) ?? WorkerStatusSnapshot(
                role: role,
                state: .unknown,
                updatedAt: Date()
            )
        }
    }

    func fleetStatus() -> OhiaCore.WorkerFleetStatusSnapshot {
        OhiaCore.WorkerFleetStatusSnapshot(workers: statusSnapshots(), updatedAt: Date())
    }

    func loadFleetStatus(
        at date: Date = Date()
    ) async throws -> OhiaCore.WorkerFleetStatusSnapshot {
        let store = statusStore
        let loadTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try store.fleetSnapshot(at: date)
        }
        let stored = try await withTaskCancellationHandler {
            try await loadTask.value
        } onCancel: {
            loadTask.cancel()
        }
        try Task.checkCancellation()
        return resolvedFleetStatus(from: stored, at: date)
    }

    func cancelStatusObservation() {
        statusObserver.cancel()
    }

    func processState(for role: WorkerRole) -> WorkerFleetProcessState {
        connections[role] == nil ? .stopped : .running
    }

    private func resolvedFleetStatus(
        from stored: OhiaCore.WorkerFleetStatusSnapshot,
        at date: Date
    ) -> OhiaCore.WorkerFleetStatusSnapshot {
        var workers = stored.workers
        let storedRoles = Set(workers.map(\.role))
        for role in roles where !storedRoles.contains(role) {
            workers.append(WorkerStatusSnapshot(
                role: role,
                parentPID: connections[role] == nil ? nil : getpid(),
                state: connections[role] == nil ? .unknown : .starting,
                statusMessage: connections[role] == nil
                    ? nil
                    : "connecting to \(role.displayName)",
                updatedAt: date
            ))
        }
        return OhiaCore.WorkerFleetStatusSnapshot(
            workers: workers,
            updatedAt: stored.updatedAt
        )
    }

    func requestGenerativeWorkerCommand(_ kind: WorkerCommandKind, message: String? = nil) {
        do {
            try commandTransport.submit(
                WorkerCommandSnapshot(kind: kind, message: message),
                to: .qwen
            )
        } catch {
            print("[Ohia] failed to send \(WorkerRole.qwen.processName) command: \(String(reflecting: type(of: error)))")
        }
    }

    func requestGenerativeModelSelection(_ modelID: String) {
        requestGenerativeWorkerCommand(.selectGenerationModel, message: modelID)
        _ = start(roles: [.qwen])
    }

    func requestGenerativeModelPreparationCancellation(_ modelID: String?) {
        requestGenerativeWorkerCommand(
            .cancelGenerationModelPreparation,
            message: modelID
        )
    }

    /// Replaces the generative worker's in-memory MCP credentials and retires
    /// affected worker sessions before the XPC acknowledgement returns.
    func refreshGenerativeWorkerMCPEnvironment() {
        guard isEnabled else { return }
        let update = currentMCPCredentialSnapshot()
        guard update.changed else { return }
        Task {
            await Self.invalidateAutomaticResearchMCPSessions()
        }
        sendMCPEnvironmentUpdate(update.snapshot)
    }

    private func sendMCPEnvironmentUpdate(_ snapshot: MCPWorkerCredentialSnapshot) {
        if mcpUpdateInFlightGeneration != nil {
            pendingMCPUpdate = snapshot
            return
        }
        guard let client = connections[.qwen] else {
            _ = start(roles: [.qwen])
            return
        }

        do {
            let data = try snapshot.encoded()
            mcpUpdateInFlightGeneration = snapshot.generation
            try client.updateMCPEnvironment(data) { [weak self, weak client] error in
                Task { @MainActor [weak self, weak client] in
                    guard let self, let client else { return }
                    self.finishMCPEnvironmentUpdate(
                        generation: snapshot.generation,
                        client: client,
                        error: error
                    )
                }
            }
        } catch {
            mcpUpdateInFlightGeneration = nil
            restartGenerativeWorkerAfterMCPUpdateFailure(
                client: client,
                error: error as NSError
            )
        }
    }

    private func finishMCPEnvironmentUpdate(
        generation: UInt64,
        client: any WorkerSupervisorConnection,
        error: NSError?
    ) {
        guard mcpUpdateInFlightGeneration == generation else { return }
        mcpUpdateInFlightGeneration = nil
        if let error {
            pendingMCPUpdate = nil
            restartGenerativeWorkerAfterMCPUpdateFailure(client: client, error: error)
            return
        }
        guard let pendingMCPUpdate else { return }
        self.pendingMCPUpdate = nil
        sendMCPEnvironmentUpdate(pendingMCPUpdate)
    }

    private func restartGenerativeWorkerAfterMCPUpdateFailure(
        client: any WorkerSupervisorConnection,
        error: NSError
    ) {
        guard connections[.qwen] === client else { return }
        recordFailure(
            role: .qwen,
            message: "MCP credential update failed; restarting generative worker: \(error.localizedDescription)"
        )
        pendingStartsAfterStop.insert(.qwen)
        expectedTerminations.insert(.qwen)
        do {
            try client.shutdown { [weak self, weak client] shutdownError in
                Task { @MainActor [weak self, weak client] in
                    guard let self, let client else { return }
                    self.finishConnectionStop(
                        role: .qwen,
                        client: client,
                        error: shutdownError
                    )
                }
            }
        } catch {
            finishConnectionStop(role: .qwen, client: client, error: error as NSError)
        }
    }

    private func startConnection(for role: WorkerRole) -> Bool {
        guard !AccountDisconnectionRequest.isPending else { return false }
        cancelScheduledRestart(for: role)
        recordHeartbeat(
            role: role,
            pid: nil,
            state: .starting,
            message: "connecting to \(role.processName) XPC service"
        )

        let client: WorkerXPCConnectionClient
        do {
            client = WorkerXPCConnectionClient(
                role: role,
                serviceName: role.xpcServiceIdentifier,
                bootstrapConfiguration: try bootstrapConfiguration(for: role),
                broker: makeCommandBroker(for: role),
                transport: commandTransport,
                eventHandler: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handle(event)
                    }
                }
            )
        } catch {
            recordFailure(
                role: role,
                message: "\(role.processName) XPC configuration failed: \(error.localizedDescription)"
            )
            return false
        }
        connections[role] = client

        do {
            try client.start()
            lastLaunchAt[role] = Date()
            restartBackoffUntil[role] = nil
            if role == .qwen {
                mcpUpdateInFlightGeneration = nil
                pendingMCPUpdate = nil
            }
            recordHeartbeat(
                role: role,
                pid: nil,
                state: .starting,
                message: "waiting for \(role.processName) XPC bootstrap"
            )
            print("[Ohia] \(role.processName) XPC connection requested")
            return true
        } catch {
            if connections[role] === client {
                connections[role] = nil
            }
            client.invalidate()
            recordFailure(
                role: role,
                message: "\(role.processName) XPC bootstrap failed: \(error.localizedDescription)"
            )
            print("[Ohia] \(role.processName) XPC bootstrap failed: \(String(reflecting: type(of: error)))")
            return false
        }
    }

    private func makeCommandBroker(for role: WorkerRole) -> WorkerXPCCommandBroker {
        WorkerXPCCommandBroker(
            sourceRole: role,
            transport: commandTransport,
            messagesTranscriptResolver: { [messagesTranscriptBroker] requestData, reply in
                messagesTranscriptBroker.resolveMessagesTranscript(
                    requestData,
                    withReply: reply
                )
            },
            mailCredentialResolver: { [mailCredentialBroker] requestData, reply in
                mailCredentialBroker.resolveMailCredential(
                    requestData,
                    withReply: reply
                )
            }
        )
    }

    @discardableResult
    private func stopConnections(
        roles rolesToStop: Set<WorkerRole>? = nil
    ) -> Set<WorkerRole> {
        if let rolesToStop {
            for role in rolesToStop {
                cancelScheduledRestart(for: role)
            }
        } else {
            cancelScheduledRestarts()
        }
        let activeConnections = connections.filter { role, _ in
            rolesToStop?.contains(role) ?? true
        }
        guard !activeConnections.isEmpty else { return [] }

        for (role, client) in activeConnections {
            expectedTerminations.insert(role)
            recordHeartbeat(
                role: role,
                pid: status(for: role)?.pid,
                state: .stopping,
                message: "app requested XPC stop"
            )
            do {
                try client.shutdown { [weak self, weak client] error in
                    Task { @MainActor [weak self, weak client] in
                        guard let self else { return }
                        if error == nil {
                            self.quitStopBarrier.finish(role: role)
                        }
                        guard let client else { return }
                        self.finishConnectionStop(role: role, client: client, error: error)
                    }
                }
            } catch {
                finishConnectionStop(
                    role: role,
                    client: client,
                    error: error as NSError
                )
            }
        }
        return Set(activeConnections.keys)
    }

    private func finishConnectionStop(
        role: WorkerRole,
        client: any WorkerSupervisorConnection,
        error: NSError?
    ) {
        if error == nil {
            quitStopBarrier.finish(role: role)
        }
        guard connections[role] === client else { return }
        connections[role] = nil
        expectedTerminations.remove(role)
        let shouldRestart = pendingStartsAfterStop.remove(role) != nil
        client.invalidate()
        if let error {
            recordFailure(
                role: role,
                message: "\(role.processName) XPC stop failed: \(error.localizedDescription)"
            )
        }
        if shouldRestart, isEnabled {
            // The terminal shutdown reply means the old runtime has exited.
            // Give the service's invalidation handler one turn to return its
            // lifecycle to idle before asking launchd for the replacement.
            scheduleRestart(for: role, after: 0.1)
        }
    }

    func handle(_ event: WorkerXPCConnectionEvent) {
        switch event {
        case .interrupted(let role):
            recordHeartbeat(
                role: role,
                pid: status(for: role)?.pid,
                state: .waiting,
                message: "XPC connection interrupted; reconnecting"
            )
        case .reconnected(let role):
            recordHeartbeat(
                role: role,
                pid: status(for: role)?.pid,
                state: .running,
                message: "XPC connection restored"
            )
        case .invalidated(let role):
            guard connections.removeValue(forKey: role) != nil else { return }
            let expected = expectedTerminations.remove(role) != nil
            lastLaunchAt[role] = nil
            guard !expected else { return }
            guard !isStoppingForQuit else { return }
            let delay = scheduleUnexpectedExitBackoff(for: role, uptime: nil)
            recordFailure(
                role: role,
                message: "\(role.processName) XPC connection invalidated; restart delayed \(Int(delay.rounded()))s"
            )
            scheduleRestart(for: role, after: delay)
            logRemainingWorkersAfterUnexpectedExit(exitedRole: role)
        case .connectionFailed(let role, let message):
            guard let client = connections[role] else { return }
            recordFailure(role: role, message: "XPC connection failed: \(message)")
            connections[role] = nil
            client.invalidate()
            guard !isStoppingForQuit else { return }
            let delay = scheduleUnexpectedExitBackoff(for: role, uptime: nil)
            scheduleRestart(for: role, after: delay)
        case .commandFailed(let role, let commandID, _):
            print("[Ohia] \(role.processName) XPC command \(commandID) failed")
        case .commandCompleted:
            break
        }
    }

    private struct ExternalWorkerStopTarget {
        let role: WorkerRole
        let pid: Int32
        let source: String
    }

    private struct WorkerStopCandidate {
        let pid: Int32
        let source: String
    }

    private func waitForWorkerStop(
        activeRoles: Set<WorkerRole>,
        externalTargets: [ExternalWorkerStopTarget],
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !workerStopCompleted(
            activeRoles: activeRoles,
            externalTargets: externalTargets
        ), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return workerStopCompleted(
            activeRoles: activeRoles,
            externalTargets: externalTargets
        )
    }

    private func workerStopCompleted(
        activeRoles: Set<WorkerRole>,
        externalTargets: [ExternalWorkerStopTarget]
    ) -> Bool {
        activeRoles.allSatisfy {
            connections[$0] == nil && !isRoleLockHeld($0)
        }
            && externalTargets.allSatisfy {
                !isExpectedLiveWorkerProcess(pid: $0.pid, role: $0.role)
            }
            && roles.allSatisfy { !isRoleLockHeld($0) }
    }

    private func stopExternallyOwnedWorkers(
        excluding activeRoles: Set<WorkerRole>
    ) -> [ExternalWorkerStopTarget] {
        var targets: [ExternalWorkerStopTarget] = []

        for role in roles where !activeRoles.contains(role) {
            let lockState = roleLockState(for: role)
            let snapshot = try? statusStore.snapshot(for: role)
            let candidates = externalWorkerStopCandidates(
                role: role,
                lockState: lockState,
                snapshot: snapshot
            )
            var didSignal = false

            for candidate in candidates {
                guard isExpectedLiveWorkerProcess(pid: candidate.pid, role: role) else {
                    continue
                }
                recordHeartbeat(
                    role: role,
                    pid: candidate.pid,
                    state: .stopping,
                    message: "app requested reset stop via \(candidate.source)"
                )
                if Darwin.kill(pid_t(candidate.pid), SIGTERM) == 0 {
                    targets.append(
                        ExternalWorkerStopTarget(
                            role: role,
                            pid: candidate.pid,
                            source: candidate.source
                        )
                    )
                    didSignal = true
                    break
                }
                if errno == ESRCH {
                    recordStopped(role: role, pid: candidate.pid, message: "already stopped")
                } else {
                    recordFailure(
                        role: role,
                        pid: candidate.pid,
                        message: "failed to request reset stop via \(candidate.source): errno \(errno)"
                    )
                }
            }

            if !didSignal, case .held = lockState {
                recordFailure(
                    role: role,
                    message: "\(role.processName) role lock is held, but no validated worker pid was available"
                )
            }
        }
        return targets
    }

    @discardableResult
    private func forceKillWorkers(
        roles targetRoles: Set<WorkerRole>,
        externalTargets: [ExternalWorkerStopTarget]
    ) -> Bool {
        var didSignal = false
        var signaledPIDs: Set<Int32> = []

        for role in targetRoles {
            let candidates = externalWorkerStopCandidates(
                role: role,
                lockState: roleLockState(for: role),
                snapshot: try? statusStore.snapshot(for: role)
            )
            for candidate in candidates
                where signaledPIDs.insert(candidate.pid).inserted
                    && isExpectedLiveWorkerProcess(pid: candidate.pid, role: role) {
                recordHeartbeat(
                    role: role,
                    pid: candidate.pid,
                    state: .stopping,
                    message: "force-killing \(role.processName) after reset timeout"
                )
                if Darwin.kill(pid_t(candidate.pid), SIGKILL) == 0 {
                    didSignal = true
                }
            }
        }

        for target in externalTargets
            where signaledPIDs.insert(target.pid).inserted
                && isExpectedLiveWorkerProcess(pid: target.pid, role: target.role) {
            if Darwin.kill(pid_t(target.pid), SIGKILL) == 0 {
                didSignal = true
            }
        }
        return didSignal
    }

    private func externalWorkerStopCandidates(
        role: WorkerRole,
        lockState: RoleLockState,
        snapshot: WorkerStatusSnapshot?
    ) -> [WorkerStopCandidate] {
        var candidates: [WorkerStopCandidate] = []
        var seen: Set<Int32> = []
        func append(pid: Int32?, source: String) {
            guard let pid, seen.insert(pid).inserted else { return }
            candidates.append(WorkerStopCandidate(pid: pid, source: source))
        }
        if case .held(let pid) = lockState {
            append(pid: pid, source: "role lock")
        }
        if let snapshot,
           snapshot.processName == role.processName,
           shouldTreatStatusSnapshotAsLive(snapshot, lockState: lockState) {
            append(pid: snapshot.pid, source: "status file")
        }
        return candidates
    }

    private func shouldTreatStatusSnapshotAsLive(
        _ snapshot: WorkerStatusSnapshot,
        lockState: RoleLockState
    ) -> Bool {
        if case .held = lockState { return true }
        switch snapshot.state {
        case .starting, .idle, .waiting, .running, .busy, .throttled, .paused, .stopping:
            return true
        case .unknown, .stopped, .failed:
            return false
        }
    }

    private func logWorkerStopTimeout(
        activeRoles: Set<WorkerRole>,
        externalTargets: [ExternalWorkerStopTarget]
    ) {
        var details: [String] = []
        for role in activeRoles where connections[role] != nil {
            details.append("\(role.processName) XPC connection still active")
        }
        for target in externalTargets
            where isExpectedLiveWorkerProcess(pid: target.pid, role: target.role) {
            details.append("\(target.role.processName) pid=\(target.pid) still running")
        }
        for role in roles {
            if case .held(let pid) = roleLockState(for: role) {
                details.append(
                    "\(role.processName) lock still held (\(pid.map { "pid=\($0)" } ?? "unknown pid"))"
                )
            }
        }
        print("[Ohia] worker shutdown timed out: \(details.joined(separator: "; "))")
    }

    private func locateServiceBundle(for role: WorkerRole) -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("XPCServices", isDirectory: true)
            .appendingPathComponent(role.xpcBundleName, isDirectory: true)
        guard let bundle = Bundle(url: url),
              bundle.bundleIdentifier == role.xpcServiceIdentifier,
              let executableURL = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        return url
    }

    private func bootstrapConfiguration(
        for role: WorkerRole
    ) throws -> WorkerXPCBootstrapConfiguration {
        HostedMCPAuth.ensureKeepFreshForConfiguredServers()
        let credentialSnapshot: Data?
        if role == .qwen {
            credentialSnapshot = try currentMCPCredentialSnapshot().snapshot.encoded()
        } else {
            credentialSnapshot = nil
        }
        return WorkerXPCBootstrapConfiguration(
            parentPID: getpid(),
            statusDirectoryPath: statusStore.directoryURL.path,
            mcpCredentialSnapshot: credentialSnapshot
        )
    }

    private func currentMCPCredentialSnapshot() -> (
        snapshot: MCPWorkerCredentialSnapshot,
        changed: Bool
    ) {
        mcpCredentialSnapshots.snapshot(replacing: Self.mcpServerEnvironments())
    }

    private static func mcpServerEnvironments() -> [UUID: [String: String]] {
        let records = MCPServerStore.loadRecords()
            .filter { $0.isEnabled && $0.automaticQueries && !$0.environmentKeys.isEmpty }
        let secrets = KeychainMCPServerSecretsStore()
        var environments: [UUID: [String: String]] = [:]
        for record in records {
            guard canPublishMCPEnvironment(for: record) else { continue }
            guard let stored = try? secrets.environment(for: record.id) else { continue }
            let environment = record.injectableEnvironment(from: stored)
            guard !environment.isEmpty,
                  (try? MCPClientSession.validatedRequestHeaders(
                    config: record,
                    environment: environment
                  )) != nil else { continue }
            environments[record.id] = environment
        }
        return environments
    }

    static func canPublishMCPEnvironment(
        for record: MCPConfiguredServer,
        hostedConnectionState: HostedMCPAuth.ConnectionState? = nil
    ) -> Bool {
        guard record.usesHostedOAuth else { return true }
        let state = hostedConnectionState ?? HostedMCPAuth.connectionState(
            serverID: record.id,
            service: record.service
        )
        // A stale access token may remain in the injectable Keychain record
        // while a failed second write is queued for retry. Only the app-only
        // OAuth record can authorize publication into a worker snapshot.
        return state == .connected
    }

    private static func invalidateAutomaticResearchMCPSessions() async {
        let records = MCPServerStore.loadRecords()
            .filter { $0.isEnabled && $0.automaticQueries }
        for record in records {
            await MCPSessionManager.shared.invalidate(id: record.id)
        }
    }

    private func isRestartBackoffActive(for role: WorkerRole, at date: Date = Date()) -> Bool {
        guard let until = restartBackoffUntil[role] else { return false }
        if until > date { return true }
        restartBackoffUntil[role] = nil
        return false
    }

    @discardableResult
    private func scheduleUnexpectedExitBackoff(
        for role: WorkerRole,
        uptime: TimeInterval?
    ) -> TimeInterval {
        let healthyRuntime: TimeInterval = 30
        let previousCount = unexpectedExitCounts[role] ?? 0
        let count = (uptime ?? 0) >= healthyRuntime ? 1 : min(previousCount + 1, 5)
        unexpectedExitCounts[role] = count
        let delay = min(300, 30 * pow(2, Double(count - 1)))
        restartBackoffUntil[role] = Date().addingTimeInterval(delay)
        return delay
    }

    private func scheduleRestart(for role: WorkerRole, after delay: TimeInterval) {
        guard !isStoppingForQuit else {
            cancelScheduledRestart(for: role)
            return
        }
        cancelScheduledRestart(for: role)
        let sleepNanoseconds = UInt64(max(0, delay + 0.25) * 1_000_000_000)
        restartTasks[role] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.restartTasks[role] = nil
            guard self.isEnabled else { return }
            if self.isRestartBackoffActive(for: role) {
                let retryDelay = max(
                    0.5,
                    self.restartBackoffUntil[role]?.timeIntervalSinceNow ?? 0.5
                )
                self.scheduleRestart(for: role, after: retryDelay)
                return
            }
            _ = self.start(roles: [role])
        }
    }

    private func cancelScheduledRestart(for role: WorkerRole) {
        restartTasks.removeValue(forKey: role)?.cancel()
    }

    private func cancelScheduledRestarts() {
        for task in restartTasks.values {
            task.cancel()
        }
        restartTasks.removeAll()
    }

    private func logRemainingWorkersAfterUnexpectedExit(exitedRole: WorkerRole) {
        let remaining = connections.keys.filter { $0 != exitedRole }
        guard !remaining.isEmpty else { return }
        let names = remaining.map(\.processName).sorted().joined(separator: ", ")
        print("[Ohia] \(exitedRole.processName) exited unexpectedly; leaving \(names) connected")
    }

    private enum RoleLockState {
        case free
        case held(pid: Int32?)
    }

    private func isRoleLockHeld(_ role: WorkerRole) -> Bool {
        if case .held = roleLockState(for: role) { return true }
        return false
    }

    private func roleLockState(for role: WorkerRole) -> RoleLockState {
        let url = workerLockURL(for: role)
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { return .free }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return .free
        }
        guard errno == EWOULDBLOCK else { return .free }
        return .held(pid: workerLockPID(at: url))
    }

    private func workerLockURL(for role: WorkerRole) -> URL {
        statusStore.directoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("worker-coordination", isDirectory: true)
            .appendingPathComponent("\(role.processName).lock", isDirectory: false)
    }

    private func removeUnlockedRoleLockFiles() throws {
        let fileManager = FileManager.default
        for role in roles {
            guard !isRoleLockHeld(role) else { continue }
            let url = workerLockURL(for: role)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func workerLockPID(at url: URL) -> Int32? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isExpectedLiveWorkerProcess(pid: Int32, role: WorkerRole) -> Bool {
        guard pid > 1, pid != getpid(), processExists(pid) else { return false }
        return processExecutableName(pid: pid) == role.processName
    }

    private func processExists(_ pid: Int32) -> Bool {
        if Darwin.kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    private func processExecutableName(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }

    private func recordHeartbeat(
        role: WorkerRole,
        pid: Int32?,
        state: WorkerState,
        message: String?
    ) {
        do {
            _ = try statusStore.heartbeat(
                role: role,
                pid: pid,
                parentPID: getpid(),
                state: state,
                statusMessage: message
            )
        } catch {
            print("[Ohia] failed to write \(role.processName) status: \(String(reflecting: type(of: error)))")
        }
    }

    private func recordStopped(role: WorkerRole, pid: Int32?, message: String?) {
        do {
            _ = try statusStore.markStopped(
                role: role,
                pid: pid,
                parentPID: getpid(),
                message: message
            )
        } catch {
            print("[Ohia] failed to write \(role.processName) stop status: \(String(reflecting: type(of: error)))")
        }
    }

    private func recordFailure(role: WorkerRole, pid: Int32? = nil, message: String) {
        do {
            _ = try statusStore.markFailed(
                role: role,
                pid: pid,
                parentPID: getpid(),
                message: message
            )
        } catch {
            print("[Ohia] failed to write \(role.processName) failure status: \(String(reflecting: type(of: error)))")
        }
    }
}

private extension WorkerRole {
    var xpcServiceIdentifier: String {
        switch self {
        case .bge: "org.jgkarlin.Ohia.RetrievalWorker"
        case .qwen: "org.jgkarlin.Ohia.GenerativeWorker"
        }
    }

    var xpcBundleName: String {
        "\(processName).xpc"
    }
}
