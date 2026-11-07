import Darwin
import Foundation
import OhiaCore
import OhiaMail
import OhiaML
import OSLog
import XPC

struct WorkerXPCServiceLifecycle {
    enum BootstrapAction: Equatable {
        case start
        case alreadyStarted
        case stopping
        case failed(String)
    }

    enum CommandReadiness: Equatable {
        case ready
        case notBootstrapped
        case stopping
        case failed(String)
    }

    private enum Phase: Equatable {
        case idle
        case active
        case stopping(connectionInvalidated: Bool)
        case waitingForConnectionInvalidation
        case failed(String)
    }

    private var phase: Phase = .idle

    mutating func beginBootstrap() -> BootstrapAction {
        switch phase {
        case .idle:
            phase = .active
            return .start
        case .active:
            return .alreadyStarted
        case .stopping, .waitingForConnectionInvalidation:
            return .stopping
        case .failed(let message):
            return .failed(message)
        }
    }

    var commandReadiness: CommandReadiness {
        switch phase {
        case .idle:
            return .notBootstrapped
        case .active:
            return .ready
        case .stopping, .waitingForConnectionInvalidation:
            return .stopping
        case .failed(let message):
            return .failed(message)
        }
    }

    var shouldStopPublishedRuntime: Bool {
        if case .stopping = phase {
            return true
        }
        return false
    }

    var shouldInvalidateConnectionWhenRuntimeFinishes: Bool {
        phase == .active
    }

    @discardableResult
    mutating func requestStop() -> Bool {
        switch phase {
        case .active:
            phase = .stopping(connectionInvalidated: false)
            return true
        case .stopping:
            return true
        case .idle, .waitingForConnectionInvalidation, .failed:
            return false
        }
    }

    mutating func runtimeFinished(message: String?) {
        switch phase {
        case .active:
            if let message {
                phase = .failed(message)
            } else {
                phase = .waitingForConnectionInvalidation
            }
        case .stopping(let connectionInvalidated):
            phase = connectionInvalidated ? .idle : .waitingForConnectionInvalidation
        case .idle, .waitingForConnectionInvalidation, .failed:
            break
        }
    }

    mutating func connectionInvalidated() {
        switch phase {
        case .active:
            // Runtime construction or execution can still be in flight. Keep
            // bootstrap closed until that runtime reaches its terminal edge.
            phase = .stopping(connectionInvalidated: true)
        case .stopping:
            phase = .stopping(connectionInvalidated: true)
        case .waitingForConnectionInvalidation, .failed:
            // The finished session has no runtime left. Its replacement may
            // construct a fresh runtime in this service process.
            phase = .idle
        case .idle:
            break
        }
    }
}

struct WorkerXPCCommandLedger {
    private struct CompletedRecord {
        let command: WorkerCommandSnapshot
        let outcome: TerminalOutcome
    }

    enum TerminalOutcome: Equatable {
        case completed
        case responded(Data)
        case failed(String)
    }

    enum Registration: Equatable {
        case new
        case duplicateInFlight
        case completed(TerminalOutcome)
        case conflictingPayload
    }

    private var inFlight: [UUID: WorkerCommandSnapshot] = [:]
    private var completed: [UUID: CompletedRecord] = [:]
    private var completionOrder: [UUID] = []
    private let completionLimit: Int

    init(completionLimit: Int = 512) {
        self.completionLimit = max(1, completionLimit)
    }

    mutating func register(_ command: WorkerCommandSnapshot) -> Registration {
        if let existing = inFlight[command.id] {
            return existing == command ? .duplicateInFlight : .conflictingPayload
        }
        if let record = completed[command.id] {
            return record.command == command
                ? .completed(record.outcome)
                : .conflictingPayload
        }
        inFlight[command.id] = command
        return .new
    }

    @discardableResult
    mutating func complete(_ commandID: UUID, outcome: TerminalOutcome) -> Bool {
        guard let command = inFlight.removeValue(forKey: commandID) else { return false }
        completed[commandID] = CompletedRecord(command: command, outcome: outcome)
        completionOrder.append(commandID)
        while completionOrder.count > completionLimit {
            completed.removeValue(forKey: completionOrder.removeFirst())
        }
        return true
    }

    @discardableResult
    mutating func abandon(_ commandID: UUID) -> Bool {
        inFlight.removeValue(forKey: commandID) != nil
    }

    mutating func abandonAll() -> [UUID] {
        let commandIDs = Array(inFlight.keys)
        inFlight.removeAll()
        return commandIDs
    }
}

/// Launches one app-private, launchd-managed XPC worker. The listener keeps
/// the command reply open until `OhiaWorkerRuntime` reaches the command's
/// terminal boundary, allowing the incoming scheduling context to cover the
/// model work instead of ending at a filesystem notification.
public enum OhiaWorkerXPCServiceEntrypoint {
    public static func run(role: WorkerRole) -> Never {
        let service = OhiaWorkerXPCService(role: role)
        let delegate = OhiaWorkerXPCListenerDelegate(service: service)
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        fatalError("NSXPCListener.service() unexpectedly returned")
    }
}

private final class OhiaWorkerXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: OhiaWorkerXPCService

    init(service: OhiaWorkerXPCService) {
        self.service = service
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard service.attach(to: newConnection) else { return false }
        newConnection.exportedInterface = NSXPCInterface(
            with: WorkerXPCCommandServiceProtocol.self
        )
        newConnection.exportedObject = service
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: WorkerXPCCommandBrokerProtocol.self
        )
        newConnection.resume()
        return true
    }
}

private final class OhiaWorkerXPCService: NSObject,
    WorkerXPCCommandServiceProtocol,
    @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "org.jgkarlin.Ohia",
        category: "WorkerXPCService"
    )

    private struct PendingCommand {
        let command: WorkerCommandSnapshot
        let priority: TaskPriority
    }

    private let role: WorkerRole
    private let stateLock = NSLock()
    private var connection: NSXPCConnection?
    private var runtime: OhiaWorkerRuntime?
    private var pendingCommands: [PendingCommand] = []
    private var commandLedger = WorkerXPCCommandLedger()
    private var commandReplies: [UUID: [WorkerXPCCommandReplyOnce]] = [:]
    private var shutdownReplies: [WorkerXPCReplyOnce] = []
    private var lifecycle = WorkerXPCServiceLifecycle()
    private var transactionIsActive = false
    private var brokerRegistration: WorkerCommandSenderRegistration?
    private var mcpCredentialSnapshot = MCPWorkerCredentialSnapshot.empty

    init(role: WorkerRole) {
        self.role = role
        super.init()
    }

    func attach(to connection: NSXPCConnection) -> Bool {
        stateLock.withLock {
            guard self.connection == nil else { return false }
            self.connection = connection
            connection.invalidationHandler = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.connectionInvalidated(connection)
            }
            return true
        }
    }

    func bootstrap(
        _ configurationData: Data,
        withReply reply: @escaping (NSError?) -> Void
    ) {
        let reply = WorkerXPCReplyOnce(reply)
        do {
            let configuration = try WorkerXPCPayloadCodec.decodeBootstrap(
                from: configurationData
            )
            try Self.validate(configuration)
            let credentialSnapshot = try Self.decodeMCPBootstrapSnapshot(
                configuration.mcpCredentialSnapshot,
                role: role
            )

            let action = stateLock.withLock { () -> WorkerXPCServiceLifecycle.BootstrapAction in
                let action = lifecycle.beginBootstrap()
                if action == .start {
                    transactionIsActive = true
                    mcpCredentialSnapshot = credentialSnapshot
                }
                return action
            }

            switch action {
            case .alreadyStarted:
                reply.send(nil)
                return
            case .failed(let message):
                throw WorkerXPCServiceError.runtimeFailed(message)
            case .stopping:
                throw WorkerXPCServiceError.stopping
            case .start:
                break
            }

            Self.apply(configuration, role: role)
            installSiblingBrokerSenderIfAvailable()
            xpc_transaction_begin()
            Self.logger.notice(
                "\(self.role.processName, privacy: .public) bootstrap accepted"
            )
            startRuntime()
            // Acknowledge configuration synchronously. Commands arriving while
            // SwiftData/AppServices initialize are retained below with their
            // original XPC reply and scheduling priority.
            reply.send(nil)
        } catch {
            reply.send(
                WorkerXPCPayloadCodec.error(error, operation: "Bootstrap worker XPC service")
            )
        }
    }

    func updateMCPEnvironment(
        _ snapshotData: Data,
        withReply reply: @escaping @Sendable (NSError?) -> Void
    ) {
        let reply = WorkerXPCReplyOnce(reply)
        do {
            guard role == .qwen else {
                throw WorkerXPCServiceError.invalidCommand(
                    "MCP credential updates require the generative worker"
                )
            }
            let replacement = try MCPWorkerCredentialSnapshot.decode(snapshotData)
            let target = try stateLock.withLock { () throws -> OhiaWorkerRuntime? in
                switch lifecycle.commandReadiness {
                case .notBootstrapped:
                    throw WorkerXPCServiceError.notBootstrapped
                case .stopping:
                    throw WorkerXPCServiceError.stopping
                case .failed(let message):
                    throw WorkerXPCServiceError.runtimeFailed(message)
                case .ready:
                    break
                }
                guard replacement.generation > mcpCredentialSnapshot.generation else {
                    return nil
                }
                guard let runtime else {
                    mcpCredentialSnapshot = replacement
                    return nil
                }
                return runtime
            }

            guard let target else {
                reply.send(nil)
                return
            }
            Task { @MainActor in
                await target.replaceMCPEnvironment(replacement)
                self.stateLock.withLock {
                    guard replacement.generation > self.mcpCredentialSnapshot.generation else {
                        return
                    }
                    self.mcpCredentialSnapshot = replacement
                }
                reply.send(nil)
            }
        } catch {
            reply.send(
                WorkerXPCPayloadCodec.error(
                    error,
                    operation: "Update worker MCP environment"
                )
            )
        }
    }

    func submitCommand(
        _ commandData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let reply = WorkerXPCCommandReplyOnce(reply)
        do {
            let command = try WorkerXPCPayloadCodec.decodeCommand(from: commandData)
            try Self.validate(command, for: role)
            let priority = Self.currentTaskPriority()

            let delivery = stateLock.withLock { () -> CommandDelivery in
                switch commandLedger.register(command) {
                case .duplicateInFlight:
                    commandReplies[command.id, default: []].append(reply)
                    return .duplicate
                case .completed(let outcome):
                    return .completed(outcome)
                case .conflictingPayload:
                    return .conflictingPayload
                case .new:
                    break
                }
                switch lifecycle.commandReadiness {
                case .notBootstrapped:
                    commandLedger.abandon(command.id)
                    return .notBootstrapped
                case .stopping:
                    commandLedger.abandon(command.id)
                    return .stopping
                case .failed(let message):
                    commandLedger.abandon(command.id)
                    return .failed(message)
                case .ready:
                    break
                }
                commandReplies[command.id] = [reply]
                if let runtime {
                    return .runtime(runtime)
                }
                pendingCommands.append(
                    PendingCommand(command: command, priority: priority)
                )
                return .queued
            }

            switch delivery {
            case .runtime(let runtime):
                deliver(command, priority: priority, to: runtime)
            case .queued, .duplicate:
                break
            case .completed(let outcome):
                let result = Self.result(for: outcome)
                reply.send(data: result.data, error: result.error)
            case .conflictingPayload:
                throw WorkerXPCServiceError.invalidCommand(
                    "command UUID was reused with a different payload"
                )
            case .notBootstrapped:
                reply.send(
                    data: nil,
                    error: Self.retryableDeliveryError(WorkerXPCServiceError.notBootstrapped)
                )
            case .stopping:
                reply.send(
                    data: nil,
                    error: Self.retryableDeliveryError(WorkerXPCServiceError.stopping)
                )
            case .failed(let message):
                reply.send(
                    data: nil,
                    error: Self.retryableDeliveryError(
                        WorkerXPCServiceError.runtimeFailed(message)
                    )
                )
            }
        } catch {
            reply.send(
                data: nil,
                error: WorkerXPCPayloadCodec.error(
                    error,
                    operation: "Submit worker XPC command"
                )
            )
        }
    }

    func shutdown(withReply reply: @escaping (NSError?) -> Void) {
        let reply = WorkerXPCReplyOnce(reply)
        let snapshot = stateLock.withLock { () -> (
            OhiaWorkerRuntime?,
            [PendingCommand],
            Bool
        ) in
            let waitsForRuntime = lifecycle.requestStop()
            if waitsForRuntime {
                shutdownReplies.append(reply)
            }
            let pending = pendingCommands
            pendingCommands.removeAll()
            return (runtime, pending, waitsForRuntime)
        }
        for pending in snapshot.1 {
            abandonCommand(
                pending.command.id,
                error: Self.retryableDeliveryError(
                    WorkerXPCServiceError.stopping,
                    operation: "Stop worker XPC service"
                )
            )
        }
        if let runtime = snapshot.0 {
            Task { @MainActor in
                runtime.requestXPCStop()
            }
        }
        if !snapshot.2 {
            reply.send(nil)
        }
    }

    private func startRuntime() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                Self.logger.notice(
                    "\(self.role.processName, privacy: .public) constructing runtime"
                )
                ComposeAddressParsingInstall.install()
                let workerConnection = self.stateLock.withLock { self.connection }
                let mcpCredentialSnapshot = self.stateLock.withLock {
                    self.mcpCredentialSnapshot
                }
                let messagesProvider: any MessagesTranscriptProviding
                let mailCredentialResolver: any MailCredentialRequesting & MailPasswordResolving
                if let workerConnection {
                    switch self.role {
                    case .qwen:
                        messagesProvider = WorkerMessagesTranscriptClient(
                            connection: workerConnection
                        )
                        mailCredentialResolver = UnavailableMailCredentialResolver()
                    case .bge:
                        messagesProvider = UnavailableMessagesTranscriptProvider()
                        mailCredentialResolver = WorkerMailCredentialClient(
                            connection: workerConnection
                        )
                    }
                } else {
                    messagesProvider = UnavailableMessagesTranscriptProvider()
                    mailCredentialResolver = UnavailableMailCredentialResolver()
                }
                let runtime = try OhiaWorkerRuntime(
                    role: self.role,
                    usesXPCCommandTransport: true,
                    messagesTranscriptProvider: messagesProvider,
                    mailCredentialResolver: mailCredentialResolver,
                    mcpCredentialSnapshot: mcpCredentialSnapshot
                )
                Self.logger.notice(
                    "\(self.role.processName, privacy: .public) entering runtime loop"
                )
                let shouldStop = await self.publish(runtime: runtime)
                if shouldStop {
                    runtime.requestXPCStop()
                }
                try await runtime.run()
                self.runtimeFinished(message: nil)
            } catch {
                let message = error.localizedDescription
                Self.logger.fault(
                    "\(self.role.processName, privacy: .public) runtime failed errorKind=\(String(reflecting: type(of: error)), privacy: .public)"
                )
                fputs("\(self.role.logPrefix) XPC runtime failed errorKind=\(String(reflecting: type(of: error)))\n", stderr)
                self.runtimeFinished(message: message)
            }
        }
    }

    @MainActor
    private func publish(runtime: OhiaWorkerRuntime) async -> Bool {
        let snapshot = stateLock.withLock { () -> (
            Bool,
            [PendingCommand],
            MCPWorkerCredentialSnapshot
        ) in
            self.runtime = runtime
            let pending = pendingCommands
            pendingCommands.removeAll()
            return (
                lifecycle.shouldStopPublishedRuntime,
                pending,
                mcpCredentialSnapshot
            )
        }
        // Publishing the runtime and taking the latest snapshot happen under
        // one lock. An update racing construction therefore either lands here
        // before queued commands are delivered or sees the published runtime
        // and applies itself before its own acknowledgement.
        await runtime.replaceMCPEnvironment(snapshot.2)
        for pending in snapshot.1 {
            deliver(
                pending.command,
                priority: pending.priority,
                to: runtime
            )
        }
        return snapshot.0
    }

    private func deliver(
        _ command: WorkerCommandSnapshot,
        priority: TaskPriority,
        to runtime: OhiaWorkerRuntime
    ) {
        Task(priority: priority) { @MainActor in
            runtime.submitXPCCommand(command, priority: priority) { [weak self] completion in
                switch completion {
                case .completed(let data):
                    self?.completeCommand(
                        command.id,
                        outcome: data.map(WorkerXPCCommandLedger.TerminalOutcome.responded)
                            ?? .completed
                    )
                case .failed(let message):
                    self?.completeCommand(command.id, outcome: .failed(message))
                case .notExecuted(let message):
                    self?.abandonCommand(
                        command.id,
                        error: Self.retryableDeliveryError(
                            WorkerXPCServiceError.runtimeFailed(message)
                        )
                    )
                }
            }
        }
    }

    private func runtimeFinished(message: String?) {
        let snapshot = stateLock.withLock { () -> (
            [WorkerXPCCommandReplyOnce],
            [WorkerXPCReplyOnce],
            Bool,
            NSXPCConnection?
        ) in
            runtime = nil
            pendingCommands.removeAll()
            let abandonedCommandIDs = commandLedger.abandonAll()
            let replies = abandonedCommandIDs.flatMap {
                commandReplies.removeValue(forKey: $0) ?? []
            }
            let stopReplies = shutdownReplies
            shutdownReplies.removeAll()
            let shouldEndTransaction = transactionIsActive
            transactionIsActive = false
            let connectionToInvalidate = lifecycle.shouldInvalidateConnectionWhenRuntimeFinishes
                ? connection
                : nil
            lifecycle.runtimeFinished(message: message)
            return (replies, stopReplies, shouldEndTransaction, connectionToInvalidate)
        }
        let terminalMessage = message ?? "worker runtime stopped"
        Self.logger.notice(
            "\(self.role.processName, privacy: .public) runtime finished failed=\(message != nil, privacy: .public)"
        )
        for reply in snapshot.0 {
            reply.send(
                data: nil,
                error: Self.retryableDeliveryError(
                    WorkerXPCServiceError.runtimeFailed(terminalMessage),
                    operation: "Execute worker XPC command"
                )
            )
        }
        for reply in snapshot.1 {
            reply.send(nil)
        }
        if snapshot.2 {
            xpc_transaction_end()
        }
        snapshot.3?.invalidate()
    }

    private func completeCommand(
        _ commandID: UUID,
        outcome: WorkerXPCCommandLedger.TerminalOutcome
    ) {
        let replies = stateLock.withLock { () -> [WorkerXPCCommandReplyOnce] in
            guard commandLedger.complete(commandID, outcome: outcome) else { return [] }
            return commandReplies.removeValue(forKey: commandID) ?? []
        }
        let result = Self.result(for: outcome)
        for reply in replies {
            reply.send(data: result.data, error: result.error)
        }
    }

    private func abandonCommand(_ commandID: UUID, error: NSError) {
        let replies = stateLock.withLock { () -> [WorkerXPCCommandReplyOnce] in
            guard commandLedger.abandon(commandID) else { return [] }
            return commandReplies.removeValue(forKey: commandID) ?? []
        }
        for reply in replies {
            reply.send(data: nil, error: error)
        }
    }

    private static func result(
        for outcome: WorkerXPCCommandLedger.TerminalOutcome
    ) -> (data: Data?, error: NSError?) {
        switch outcome {
        case .completed:
            return (nil, nil)
        case .responded(let data):
            return (data, nil)
        case .failed(let message):
            return (
                nil,
                WorkerXPCPayloadCodec.error(
                    WorkerXPCServiceError.runtimeFailed(message),
                    operation: "Execute worker XPC command"
                )
            )
        }
    }

    private static func retryableDeliveryError(
        _ error: any Error,
        operation: String = "Submit worker XPC command"
    ) -> NSError {
        WorkerXPCPayloadCodec.error(
            error,
            operation: operation,
            retryableDeliveryFailure: true
        )
    }

    private func installSiblingBrokerSenderIfAvailable() {
        let connection = stateLock.withLock { self.connection }
        guard let connection else { return }
        let sender = WorkerXPCBrokerSender(connection: connection)
        let siblingRole: OhiaCore.WorkerRole = role == .bge ? .qwen : .bge
        let registration = WorkerCommandTransport.shared.register(sender, for: siblingRole)
        stateLock.withLock {
            if let oldRegistration = brokerRegistration {
                WorkerCommandTransport.shared.unregister(oldRegistration)
            }
            brokerRegistration = registration
        }
    }

    private func connectionInvalidated(_ invalidatedConnection: NSXPCConnection) {
        let snapshot = stateLock.withLock { () -> (
            WorkerCommandSenderRegistration?,
            OhiaWorkerRuntime?
        )? in
            guard connection === invalidatedConnection else { return nil }
            connection = nil
            lifecycle.connectionInvalidated()
            let registration = brokerRegistration
            brokerRegistration = nil
            return (registration, runtime)
        }
        guard let snapshot else { return }
        if let registration = snapshot.0 {
            WorkerCommandTransport.shared.unregister(registration)
        }
        if let runtime = snapshot.1 {
            Task { @MainActor in
                runtime.requestXPCStop()
            }
        }
    }

    private static func validate(_ configuration: WorkerXPCBootstrapConfiguration) throws {
        guard configuration.parentPID > 1 else {
            throw WorkerXPCServiceError.invalidBootstrap("parent pid must identify the app")
        }
        guard !configuration.statusDirectoryPath.isEmpty else {
            throw WorkerXPCServiceError.invalidBootstrap(
                "status directory is required"
            )
        }
    }

    private static func decodeMCPBootstrapSnapshot(
        _ data: Data?,
        role: WorkerRole
    ) throws -> MCPWorkerCredentialSnapshot {
        guard let data else { return .empty }
        guard role == .qwen else {
            throw WorkerXPCServiceError.invalidBootstrap(
                "MCP credentials may be sent only to the generative worker"
            )
        }
        do {
            return try MCPWorkerCredentialSnapshot.decode(data)
        } catch {
            throw WorkerXPCServiceError.invalidBootstrap(
                "MCP credential snapshot is malformed"
            )
        }
    }

    private static func validate(
        _ command: WorkerCommandSnapshot,
        for role: WorkerRole
    ) throws {
        let isAllowed: Bool
        switch (role, command.kind) {
        case (.bge, .embedQueries),
             (.bge, .cancelQueryEmbedding),
             (.bge, .requestInteractiveQwenModelTurn),
             (.qwen, .cancelTraining),
             (.qwen, .resetTrainingToBase),
             (.qwen, .generateText),
             (.qwen, .cancelGeneration),
             (.qwen, .requestInteractiveBGEModelTurn),
             (.qwen, .selectGenerationModel),
             (.qwen, .cancelGenerationModelPreparation):
            isAllowed = true
        default:
            isAllowed = false
        }
        guard isAllowed else {
            throw WorkerXPCServiceError.commandRoleMismatch(
                command: command.kind.rawValue,
                role: role.rawValue
            )
        }
        if command.kind == .generateText, command.generationRequest == nil {
            throw WorkerXPCServiceError.invalidCommand("generateText requires a request")
        }
        if command.kind == .embedQueries, command.queryEmbeddingRequest == nil {
            throw WorkerXPCServiceError.invalidCommand("embedQueries requires a request")
        }
        if command.kind == .cancelGeneration, command.cancelledGenerationCommandID == nil {
            throw WorkerXPCServiceError.invalidCommand("cancelGeneration requires a target")
        }
        if command.kind == .cancelQueryEmbedding,
           command.cancelledQueryEmbeddingCommandID == nil {
            throw WorkerXPCServiceError.invalidCommand(
                "cancelQueryEmbedding requires a target"
            )
        }
    }

    private static func apply(
        _ configuration: WorkerXPCBootstrapConfiguration,
        role: WorkerRole
    ) {
        setEnvironment("OHIA_PARENT_PID", value: String(configuration.parentPID))
        setEnvironment("OHIA_WORKER_ROLE", value: role.rawValue)
        setEnvironment("OHIA_WORKER_PROCESS_NAME", value: role.processName)
        setEnvironment("OHIA_WORKER_STATUS_DIR", value: configuration.statusDirectoryPath)
        let statusURL = URL(
            fileURLWithPath: configuration.statusDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(role.coreRole.statusFilename)
        setEnvironment("OHIA_WORKER_STATUS_FILE", value: statusURL.path)
        setEnvironment("OHIA_\(role.rawValue.uppercased())_WORKER", value: "1")
        setEnvironment("OHIA_XPC_SERVICE", value: "1")
    }

    private static func setEnvironment(_ key: String, value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }

    private static func currentTaskPriority() -> TaskPriority {
        switch qos_class_self() {
        case QOS_CLASS_USER_INTERACTIVE, QOS_CLASS_USER_INITIATED:
            return .userInitiated
        case QOS_CLASS_DEFAULT:
            return .medium
        case QOS_CLASS_UTILITY:
            return .utility
        case QOS_CLASS_BACKGROUND:
            return .background
        default:
            return Task.currentPriority
        }
    }

    private enum CommandDelivery {
        case runtime(OhiaWorkerRuntime)
        case queued
        case duplicate
        case completed(WorkerXPCCommandLedger.TerminalOutcome)
        case conflictingPayload
        case notBootstrapped
        case stopping
        case failed(String)
    }
}

private final class WorkerXPCBrokerSender: WorkerCommandSending, @unchecked Sendable {
    private struct PendingDelivery {
        let commandData: Data
        let role: OhiaCore.WorkerRole
        var attempt: Int
    }

    private let connection: NSXPCConnection
    private let lock = NSLock()
    private let retryQueue = DispatchQueue(
        label: "org.jgkarlin.Ohia.worker-xpc-sibling-retry",
        qos: .userInitiated
    )
    private var pending: [UUID: PendingDelivery] = [:]

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func send(_ command: WorkerCommandSnapshot, to role: OhiaCore.WorkerRole) throws {
        let data = try WorkerXPCPayloadCodec.encodeCommand(command)
        let isNew = lock.withLock { () -> Bool in
            guard pending[command.id] == nil else { return false }
            pending[command.id] = PendingDelivery(
                commandData: data,
                role: role,
                attempt: 0
            )
            return true
        }
        if isNew {
            dispatch(commandID: command.id)
        }
    }

    private func dispatch(commandID: UUID) {
        guard let delivery = lock.withLock({ pending[commandID] }) else { return }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.retry(commandID: commandID, error: error)
        }) as? any WorkerXPCCommandBrokerProtocol else {
            retry(
                commandID: commandID,
                error: WorkerXPCConnectionError.remoteInterfaceUnavailable
            )
            return
        }
        proxy.forwardCommand(delivery.commandData, toRole: delivery.role.rawValue) { [weak self] error in
            if let error {
                self?.retry(commandID: commandID, error: error)
            } else {
                guard let self else { return }
                _ = self.lock.withLock {
                    self.pending.removeValue(forKey: commandID)
                }
            }
        }
    }

    private func retry(commandID: UUID, error: any Error) {
        let retry = lock.withLock { () -> (attempt: Int, delay: TimeInterval)? in
            guard var delivery = pending[commandID] else { return nil }
            delivery.attempt += 1
            pending[commandID] = delivery
            let delay = min(2.0, 0.1 * pow(2.0, Double(min(delivery.attempt, 5))))
            return (delivery.attempt, delay)
        }
        guard let retry else { return }
        fputs(
            "[OhiaWorkerXPC] sibling command \(commandID) delivery failed; retrying errorKind=\(String(reflecting: type(of: error)))\n",
            stderr
        )
        retryQueue.asyncAfter(deadline: .now() + retry.delay) { [weak self] in
            guard let self else { return }
            let isCurrentAttempt = self.lock.withLock {
                self.pending[commandID]?.attempt == retry.attempt
            }
            if isCurrentAttempt {
                self.dispatch(commandID: commandID)
            }
        }
    }
}

private final class WorkerXPCReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private let reply: (NSError?) -> Void
    private var didReply = false

    init(_ reply: @escaping (NSError?) -> Void) {
        self.reply = reply
    }

    func send(_ error: NSError?) {
        let shouldReply = lock.withLock { () -> Bool in
            guard !didReply else { return false }
            didReply = true
            return true
        }
        if shouldReply {
            reply(error)
        }
    }
}

private final class WorkerXPCCommandReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private let reply: (Data?, NSError?) -> Void
    private var didReply = false

    init(_ reply: @escaping (Data?, NSError?) -> Void) {
        self.reply = reply
    }

    func send(data: Data?, error: NSError?) {
        let shouldReply = lock.withLock { () -> Bool in
            guard !didReply else { return false }
            didReply = true
            return true
        }
        if shouldReply {
            reply(data, error)
        }
    }
}

private enum WorkerXPCServiceError: Error, LocalizedError {
    case notBootstrapped
    case stopping
    case invalidBootstrap(String)
    case invalidCommand(String)
    case commandRoleMismatch(command: String, role: String)
    case runtimeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notBootstrapped:
            return "The worker XPC service has not been bootstrapped."
        case .stopping:
            return "The worker XPC service is stopping."
        case .invalidBootstrap(let message):
            return "Invalid worker bootstrap: \(message)."
        case .invalidCommand(let message):
            return "Invalid worker command: \(message)."
        case .commandRoleMismatch(let command, let role):
            return "Command \(command) is not valid for the \(role) worker."
        case .runtimeFailed(let message):
            return "Worker runtime failed: \(message)."
        }
    }
}
