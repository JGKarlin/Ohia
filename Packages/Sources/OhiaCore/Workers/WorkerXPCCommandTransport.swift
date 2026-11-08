import Foundation
import OhiaPDFParsing

/// Process configuration delivered by the app before an XPC worker starts its
/// runtime. Secrets stay inside the app-private XPC connection instead of being
/// exposed through process arguments.
public struct WorkerXPCBootstrapConfiguration: Codable, Equatable, Sendable {
    public let parentPID: Int32
    public let statusDirectoryPath: String
    public let mcpCredentialSnapshot: Data?

    public init(
        parentPID: Int32,
        statusDirectoryPath: String,
        mcpCredentialSnapshot: Data? = nil
    ) {
        self.parentPID = parentPID
        self.statusDirectoryPath = statusDirectoryPath
        self.mcpCredentialSnapshot = mcpCredentialSnapshot
    }
}

/// The app-to-worker XPC surface. `submitCommand` intentionally includes a
/// reply block that the service keeps until the command reaches a terminal
/// state. Keeping that request alive lets macOS carry request-scoped scheduling
/// context into the worker for the command's lifetime.
@objc(OhiaWorkerXPCCommandServiceProtocol)
public protocol WorkerXPCCommandServiceProtocol {
    func bootstrap(
        _ configurationData: Data,
        withReply reply: @escaping @Sendable (NSError?) -> Void
    )

    func submitCommand(
        _ commandData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    func updateMCPEnvironment(
        _ snapshotData: Data,
        withReply reply: @escaping @Sendable (NSError?) -> Void
    )

    func shutdown(withReply reply: @escaping @Sendable (NSError?) -> Void)
}

/// The worker-to-app surface used when one worker must hand a command to its
/// sibling. `WorkerRole` crosses XPC as its stable raw string because Swift
/// enums are not Objective-C XPC interface types.
@objc(OhiaWorkerXPCCommandBrokerProtocol)
public protocol WorkerXPCCommandBrokerProtocol {
    func forwardCommand(
        _ commandData: Data,
        toRole roleRawValue: String,
        withReply reply: @escaping @Sendable (NSError?) -> Void
    )

    func resolveMessagesTranscript(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    func requestMailCredential(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    /// Parses one PDF in the app's sandboxed `OhiaPDFParser.xpc`, which only
    /// the app can reach. The reply carries the same fields as
    /// `PDFParserXPCProtocol.parse`.
    func parsePDF(
        _ pdf: Data,
        maxPages: Int,
        withReply reply: @escaping @Sendable (Data?, Int, Int32, String?) -> Void
    )

    /// Renders pages of one PDF as PNG images in the app's sandboxed
    /// `OhiaPDFParser.xpc`. The reply carries the same fields as
    /// `PDFParserXPCProtocol.renderPages`.
    func renderPDFPages(
        _ pdf: Data,
        maxPages: Int,
        maxPixelSize: Int,
        withReply reply: @escaping @Sendable (Data?, Int) -> Void
    )
}

public enum WorkerXPCPayloadCodec {
    public static let retryableDeliveryErrorKey = "OhiaWorkerXPCRetryableDeliveryError"

    public static func encodeCommand(_ command: WorkerCommandSnapshot) throws -> Data {
        try encoder().encode(command)
    }

    public static func decodeCommand(from data: Data) throws -> WorkerCommandSnapshot {
        try decoder().decode(WorkerCommandSnapshot.self, from: data)
    }

    public static func encodeGenerationResponse(
        _ response: WorkerGenerationResponseSnapshot
    ) throws -> Data {
        try encoder().encode(response)
    }

    public static func decodeGenerationResponse(
        from data: Data
    ) throws -> WorkerGenerationResponseSnapshot {
        let response = try decoder().decode(WorkerGenerationResponseSnapshot.self, from: data)
        guard response.responseKind == .generateText else {
            throw WorkerXPCConnectionError.invalidLiveResponse(
                "expected a generation response"
            )
        }
        return response
    }

    public static func encodeQueryEmbeddingResponse(
        _ response: WorkerQueryEmbeddingResponseSnapshot
    ) throws -> Data {
        try encoder().encode(response)
    }

    public static func decodeQueryEmbeddingResponse(
        from data: Data
    ) throws -> WorkerQueryEmbeddingResponseSnapshot {
        let response = try decoder().decode(WorkerQueryEmbeddingResponseSnapshot.self, from: data)
        guard response.responseKind == .embedQueries else {
            throw WorkerXPCConnectionError.invalidLiveResponse(
                "expected a query embedding response"
            )
        }
        return response
    }

    public static func encodeBootstrap(
        _ configuration: WorkerXPCBootstrapConfiguration
    ) throws -> Data {
        try encoder().encode(configuration)
    }

    public static func decodeBootstrap(
        from data: Data
    ) throws -> WorkerXPCBootstrapConfiguration {
        try decoder().decode(WorkerXPCBootstrapConfiguration.self, from: data)
    }

    public static func error(
        _ error: any Error,
        operation: String,
        retryableDeliveryFailure: Bool = false
    ) -> NSError {
        let underlying = error as NSError
        return NSError(
            domain: "org.jgkarlin.Ohia.WorkerXPC",
            code: underlying.code,
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation): \(underlying.localizedDescription)",
                NSUnderlyingErrorKey: underlying,
                retryableDeliveryErrorKey: retryableDeliveryFailure,
            ]
        )
    }

    public static func isRetryableDeliveryFailure(_ error: NSError) -> Bool {
        error.userInfo[retryableDeliveryErrorKey] as? Bool == true
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}

/// A live command sender installed for one worker role.
public protocol WorkerCommandSending: Sendable {
    func send(_ command: WorkerCommandSnapshot, to role: WorkerRole) throws
}

/// The common synchronous submission boundary used by app and worker code.
/// XPC senders enqueue the remote call and return without waiting for the
/// command's terminal reply.
public protocol WorkerCommandSubmitting: Sendable {
    @discardableResult
    func submit(
        _ command: WorkerCommandSnapshot,
        to role: WorkerRole
    ) throws -> WorkerCommandSnapshot
}

/// Synchronous, request-scoped transport for user-derived payloads that must
/// never enter a fallback queue or XPC replay journal.
public protocol WorkerLiveCommandSubmitting: Sendable {
    func submitGeneration(
        _ command: WorkerCommandSnapshot,
        timeout: TimeInterval
    ) throws -> WorkerGenerationResponseSnapshot

    func submitQueryEmbedding(
        _ command: WorkerCommandSnapshot,
        timeout: TimeInterval
    ) throws -> WorkerQueryEmbeddingResponseSnapshot
}

protocol WorkerLiveCommandSending: Sendable {
    func sendGeneration(
        _ command: WorkerCommandSnapshot,
        timeout: TimeInterval
    ) throws -> WorkerGenerationResponseSnapshot

    func sendQueryEmbedding(
        _ command: WorkerCommandSnapshot,
        timeout: TimeInterval
    ) throws -> WorkerQueryEmbeddingResponseSnapshot
}

public struct WorkerCommandSenderRegistration: Hashable, Sendable {
    fileprivate let id: UUID
    fileprivate let role: WorkerRole
}

public enum WorkerCommandSubmissionDisposition: Equatable, Sendable {
    case liveXPC
    case durableQueue
}

/// Routes commands over a live XPC sender when one is registered. Live sends
/// are journaled until the destination's terminal acknowledgement so an XPC
/// interruption cannot discard an accepted command. The existing atomic file
/// queue remains the fallback when no XPC sender is registered.
public final class WorkerCommandTransport: WorkerCommandSubmitting,
    WorkerLiveCommandSubmitting,
    @unchecked Sendable {
    public static let shared = WorkerCommandTransport()

    private struct Entry {
        let registrationID: UUID
        let sender: any WorkerCommandSending
    }

    private let lock = NSLock()
    private let fallbackStore: WorkerStatusStore
    private var entries: [WorkerRole: Entry] = [:]

    public init(statusStore: WorkerStatusStore = WorkerStatusStore()) {
        self.fallbackStore = statusStore
    }

    @discardableResult
    public func register(
        _ sender: any WorkerCommandSending,
        for role: WorkerRole
    ) -> WorkerCommandSenderRegistration {
        let registration = WorkerCommandSenderRegistration(id: UUID(), role: role)
        lock.withLock {
            entries[role] = Entry(
                registrationID: registration.id,
                sender: sender
            )
        }
        return registration
    }

    /// Removes a sender only if the token still identifies the current
    /// registration. A delayed invalidation from an old connection cannot tear
    /// down its replacement.
    public func unregister(_ registration: WorkerCommandSenderRegistration) {
        lock.withLock {
            guard entries[registration.role]?.registrationID == registration.id else {
                return
            }
            entries.removeValue(forKey: registration.role)
        }
    }

    @discardableResult
    public func submit(
        _ command: WorkerCommandSnapshot,
        to role: WorkerRole
    ) throws -> WorkerCommandSnapshot {
        try submitWithDisposition(command, to: role).command
    }

    public func submitWithDisposition(
        _ command: WorkerCommandSnapshot,
        to role: WorkerRole
    ) throws -> (
        command: WorkerCommandSnapshot,
        disposition: WorkerCommandSubmissionDisposition
    ) {
        guard !command.kind.requiresLiveConnection else {
            throw WorkerXPCConnectionError.liveConnectionRequired(command.kind)
        }
        lock.lock()
        let sender = entries[role]?.sender
        if let sender {
            let journaled: WorkerCommandSnapshot
            do {
                journaled = try fallbackStore.journalXPCCommand(command, for: role)
            } catch {
                lock.unlock()
                throw error
            }
            lock.unlock()
            try sender.send(journaled, to: role)
            return (journaled, .liveXPC)
        }
        // Keep registration serialized with the durable write. A service
        // cannot register, finish its startup replay, and strand a fallback
        // command that was selected just before registration.
        defer { lock.unlock() }
        return (try fallbackStore.writeCommand(command, for: role), .durableQueue)
    }

    public func journaledCommands(for role: WorkerRole) throws -> [WorkerCommandSnapshot] {
        try lock.withLock {
            try fallbackStore.journaledXPCCommands(for: role)
        }
    }

    public func acknowledge(commandID: UUID, for role: WorkerRole) throws {
        try lock.withLock {
            try fallbackStore.acknowledgeXPCCommand(commandID: commandID, for: role)
        }
    }

    public func submitGeneration(
        _ command: WorkerCommandSnapshot,
        timeout: TimeInterval
    ) throws -> WorkerGenerationResponseSnapshot {
        guard command.kind == .generateText,
              command.generationRequest != nil else {
            throw WorkerXPCConnectionError.invalidLiveCommand(command.kind)
        }
        guard let sender = liveSender(for: .qwen) else {
            throw WorkerXPCConnectionError.liveConnectionRequired(.generateText)
        }
        return try sender.sendGeneration(command, timeout: timeout)
    }

    public func submitQueryEmbedding(
        _ command: WorkerCommandSnapshot,
        timeout: TimeInterval
    ) throws -> WorkerQueryEmbeddingResponseSnapshot {
        guard command.kind == .embedQueries,
              command.queryEmbeddingRequest != nil else {
            throw WorkerXPCConnectionError.invalidLiveCommand(command.kind)
        }
        guard let sender = liveSender(for: .bge) else {
            throw WorkerXPCConnectionError.liveConnectionRequired(.embedQueries)
        }
        return try sender.sendQueryEmbedding(command, timeout: timeout)
    }

    private func liveSender(for role: WorkerRole) -> (any WorkerLiveCommandSending)? {
        lock.withLock { entries[role]?.sender as? any WorkerLiveCommandSending }
    }
}

/// Default exported broker object for app-owned connections. It decodes the
/// sibling command and routes it through the same live-or-durable transport as
/// commands originating in the app.
public final class WorkerXPCCommandBroker: NSObject,
    WorkerXPCCommandBrokerProtocol,
    @unchecked Sendable {
    public typealias MessagesTranscriptResolver = @Sendable (
        Data,
        @escaping @Sendable (Data?, NSError?) -> Void
    ) -> Void
    public typealias MailCredentialResolver = @Sendable (
        Data,
        @escaping @Sendable (Data?, NSError?) -> Void
    ) -> Void
    public typealias PDFParseResolver = @Sendable (
        Data,
        Int,
        WorkerRole,
        @escaping @Sendable (PDFParserReply) -> Void
    ) -> Void

    public typealias PDFRenderResolver = @Sendable (
        Data,
        Int,
        Int,
        WorkerRole,
        @escaping @Sendable (PDFRenderReply) -> Void
    ) -> Void

    /// The app's resolver: relays each worker PDF to `OhiaPDFParser.xpc`,
    /// in the lane that matches the work the requesting worker does.
    public static let appPDFParseResolver: PDFParseResolver = { pdf, maxPages, role, reply in
        PDFParserRelay.shared.parse(pdf, maxPages: maxPages, lane: relayLane(for: role), reply: reply)
    }

    /// The app's resolver for page renders, in the same lanes as parses.
    public static let appPDFRenderResolver: PDFRenderResolver = { pdf, maxPages, maxPixelSize, role, reply in
        PDFParserRelay.shared.renderPages(
            pdf,
            maxPages: maxPages,
            maxPixelSize: maxPixelSize,
            lane: relayLane(for: role),
            reply: reply
        )
    }

    /// The retrieval worker extracts mail attachments in the background; the
    /// generative worker parses the Composer sources the user is waiting on.
    static func relayLane(for role: WorkerRole) -> PDFParserRelay.Lane {
        switch role {
        case .bge: .background
        case .qwen: .interactive
        }
    }

    private let sourceRole: WorkerRole
    private let transport: WorkerCommandTransport
    private let messagesTranscriptResolver: MessagesTranscriptResolver
    private let mailCredentialResolver: MailCredentialResolver
    private let pdfParseResolver: PDFParseResolver
    private let pdfRenderResolver: PDFRenderResolver

    public init(
        sourceRole: WorkerRole,
        transport: WorkerCommandTransport = .shared,
        messagesTranscriptResolver: @escaping MessagesTranscriptResolver = { _, reply in
            reply(
                nil,
                WorkerXPCConnectionError.serviceFailure(
                    "Messages transcript broker is unavailable"
                ) as NSError
            )
        },
        mailCredentialResolver: @escaping MailCredentialResolver = { _, reply in
            reply(
                nil,
                WorkerXPCConnectionError.serviceFailure(
                    "Mail credential broker is unavailable"
                ) as NSError
            )
        },
        pdfParseResolver: @escaping PDFParseResolver = { _, _, _, reply in
            reply(PDFParserReply(outcome: .serviceUnavailable))
        },
        pdfRenderResolver: @escaping PDFRenderResolver = { _, _, _, _, reply in
            reply(PDFRenderReply(outcome: .serviceUnavailable))
        }
    ) {
        self.sourceRole = sourceRole
        self.transport = transport
        self.messagesTranscriptResolver = messagesTranscriptResolver
        self.mailCredentialResolver = mailCredentialResolver
        self.pdfParseResolver = pdfParseResolver
        self.pdfRenderResolver = pdfRenderResolver
        super.init()
    }

    public func forwardCommand(
        _ commandData: Data,
        toRole roleRawValue: String,
        withReply reply: @escaping @Sendable (NSError?) -> Void
    ) {
        do {
            guard let role = WorkerRole(rawValue: roleRawValue) else {
                throw WorkerXPCConnectionError.invalidRole(roleRawValue)
            }
            let command = try WorkerXPCPayloadCodec.decodeCommand(from: commandData)
            let submission = try transport.submitWithDisposition(command, to: role)
            if submission.disposition == .durableQueue {
                // A sibling may have created the XPC journal before forwarding
                // to the app. Once the app has atomically queued the fallback,
                // that source journal is redundant and must not be replayed.
                try transport.acknowledge(commandID: command.id, for: role)
            }
            reply(nil)
        } catch {
            reply(WorkerXPCPayloadCodec.error(error, operation: "Forward worker command"))
        }
    }

    public func resolveMessagesTranscript(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        guard sourceRole == .qwen else {
            reply(nil, capabilityDenied("Messages transcript"))
            return
        }
        messagesTranscriptResolver(requestData, reply)
    }

    public func requestMailCredential(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        guard sourceRole == .bge else {
            reply(nil, capabilityDenied("Mail credential"))
            return
        }
        mailCredentialResolver(requestData, reply)
    }

    /// Both workers parse attachments (the retrieval worker for mail, the
    /// generative worker for Composer sources), so both may ask the app to
    /// run the sandboxed PDF parser on their behalf.
    public func parsePDF(
        _ pdf: Data,
        maxPages: Int,
        withReply reply: @escaping @Sendable (Data?, Int, Int32, String?) -> Void
    ) {
        pdfParseResolver(pdf, maxPages, sourceRole) { result in
            reply(result.output, result.outcome.rawValue, result.status, result.stderr)
        }
    }

    /// Both workers render PDF pages for Apple Intelligence's image analysis
    /// (mail attachments, Composer sources).
    public func renderPDFPages(
        _ pdf: Data,
        maxPages: Int,
        maxPixelSize: Int,
        withReply reply: @escaping @Sendable (Data?, Int) -> Void
    ) {
        pdfRenderResolver(pdf, maxPages, maxPixelSize, sourceRole) { result in
            reply(result.wireOutput, result.outcome.rawValue)
        }
    }

    private func capabilityDenied(_ capability: String) -> NSError {
        WorkerXPCConnectionError.serviceFailure(
            "\(capability) capability is unavailable for \(sourceRole.rawValue) worker"
        ) as NSError
    }
}

public enum WorkerXPCConnectionError: Error, Equatable, Sendable, LocalizedError {
    case alreadyStarted
    case notStarted
    case invalidated
    case bootstrapTimedOut(TimeInterval)
    case mcpEnvironmentUpdateTimedOut(TimeInterval)
    case liveCommandTimedOut(TimeInterval)
    case liveConnectionRequired(WorkerCommandKind)
    case invalidLiveCommand(WorkerCommandKind)
    case invalidLiveResponse(String)
    case invalidRole(String)
    case roleMismatch(expected: WorkerRole, received: WorkerRole)
    case remoteInterfaceUnavailable
    case remoteFailure(String)
    case serviceFailure(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "The worker XPC connection has already started."
        case .notStarted:
            return "The worker XPC connection has not started."
        case .invalidated:
            return "The worker XPC connection is invalidated."
        case .bootstrapTimedOut(let timeout):
            return "The worker XPC bootstrap did not reply within \(String(format: "%.1f", timeout)) seconds."
        case .mcpEnvironmentUpdateTimedOut(let timeout):
            return "The worker MCP environment update did not reply within \(String(format: "%.1f", timeout)) seconds."
        case .liveCommandTimedOut(let timeout):
            return "The live worker request did not reply within \(String(format: "%.1f", timeout)) seconds."
        case .liveConnectionRequired(let kind):
            return "The \(kind.rawValue) request requires a live worker connection."
        case .invalidLiveCommand(let kind):
            return "The \(kind.rawValue) request does not match its live worker contract."
        case .invalidLiveResponse(let message):
            return "The live worker response was invalid: \(message)"
        case let .invalidRole(rawValue):
            return "Unknown worker role '\(rawValue)'."
        case let .roleMismatch(expected, received):
            return "The \(expected.rawValue) connection cannot send a \(received.rawValue) command."
        case .remoteInterfaceUnavailable:
            return "The worker XPC remote interface is unavailable."
        case let .remoteFailure(message):
            return "Worker XPC transport failed: \(message)"
        case let .serviceFailure(message):
            return "Worker XPC service failed: \(message)"
        }
    }
}

public enum WorkerXPCConnectionEvent: Equatable, Sendable {
    case interrupted(WorkerRole)
    case reconnected(WorkerRole)
    case invalidated(WorkerRole)
    case commandCompleted(role: WorkerRole, commandID: UUID)
    case commandFailed(role: WorkerRole, commandID: UUID, message: String)
    case connectionFailed(role: WorkerRole, message: String)
}

/// App-side connection wrapper. Command submission is deliberately one-way
/// from the caller's perspective: the XPC reply remains outstanding until the
/// worker finishes, while `send` returns as soon as Foundation accepts the
/// invocation. Bootstrap is asynchronous and bounded. The client is registered
/// immediately as a journaling sink, but it withholds live dispatch until the
/// service accepts its configuration.
public final class WorkerXPCConnectionClient: NSObject,
    WorkerCommandSending,
    WorkerLiveCommandSending,
    @unchecked Sendable {
    public typealias EventHandler = @Sendable (WorkerXPCConnectionEvent) -> Void

    private enum Phase {
        case created
        case starting
        case active
        case invalidated
    }

    private struct State {
        var phase: Phase = .created
        var registration: WorkerCommandSenderRegistration?
        var pendingCommandIDs: Set<UUID> = []
        var bootstrapAttempt: UInt64 = 0
    }

    public let role: WorkerRole
    public let serviceName: String

    private let bootstrapConfiguration: WorkerXPCBootstrapConfiguration
    private let transport: WorkerCommandTransport
    private let broker: any WorkerXPCCommandBrokerProtocol
    private let eventHandler: EventHandler?
    private let bootstrapTimeout: TimeInterval
    private let connection: NSXPCConnection
    private let stateLock = NSLock()
    private let recoveryQueue: DispatchQueue
    private var state = State()

    public init(
        role: WorkerRole,
        serviceName: String,
        bootstrapConfiguration: WorkerXPCBootstrapConfiguration,
        broker: any WorkerXPCCommandBrokerProtocol,
        transport: WorkerCommandTransport = .shared,
        bootstrapTimeout: TimeInterval = 5,
        eventHandler: EventHandler? = nil
    ) {
        self.role = role
        self.serviceName = serviceName
        self.bootstrapConfiguration = bootstrapConfiguration
        self.broker = broker
        self.transport = transport
        self.eventHandler = eventHandler
        self.bootstrapTimeout = max(0.1, bootstrapTimeout)
        self.connection = NSXPCConnection(serviceName: serviceName)
        self.recoveryQueue = DispatchQueue(
            label: "org.jgkarlin.Ohia.worker-xpc-recovery.\(role.rawValue)",
            qos: .utility
        )
        super.init()

        connection.remoteObjectInterface = NSXPCInterface(
            with: WorkerXPCCommandServiceProtocol.self
        )
        connection.exportedInterface = NSXPCInterface(
            with: WorkerXPCCommandBrokerProtocol.self
        )
        connection.exportedObject = broker
        connection.interruptionHandler = { [weak self] in
            self?.handleInterruption()
        }
        connection.invalidationHandler = { [weak self] in
            self?.handleInvalidation()
        }
    }

    public func start() throws {
        try stateLock.withLock {
            switch state.phase {
            case .created:
                state.phase = .starting
            case .starting, .active:
                throw WorkerXPCConnectionError.alreadyStarted
            case .invalidated:
                throw WorkerXPCConnectionError.invalidated
            }
        }

        let registration = transport.register(self, for: role)
        let retainedRegistration = stateLock.withLock { () -> Bool in
            guard state.phase == .starting else { return false }
            state.registration = registration
            return true
        }
        guard retainedRegistration else {
            transport.unregister(registration)
            throw WorkerXPCConnectionError.invalidated
        }
        connection.resume()
        beginBootstrap(isRecovery: false)
    }

    public func send(
        _ command: WorkerCommandSnapshot,
        to role: WorkerRole
    ) throws {
        guard role == self.role else {
            throw WorkerXPCConnectionError.roleMismatch(
                expected: self.role,
                received: role
            )
        }
        let phase = stateLock.withLock { state.phase }
        switch phase {
        case .starting:
            // `WorkerCommandTransport` has already durably journaled this
            // command. Bootstrap replay will deliver it once the service is
            // ready, avoiding a legacy file-queue race during startup.
            _ = stateLock.withLock {
                state.pendingCommandIDs.insert(command.id)
            }
            return
        case .active:
            break
        case .created:
            throw WorkerXPCConnectionError.notStarted
        case .invalidated:
            throw WorkerXPCConnectionError.invalidated
        }

        _ = stateLock.withLock {
            state.pendingCommandIDs.insert(command.id)
        }
        do {
            try dispatch(command)
        } catch {
            emitDeliveryFailure(for: command, error: error)
            throw error
        }
    }

    private func dispatch(_ command: WorkerCommandSnapshot) throws {
        let commandData = try WorkerXPCPayloadCodec.encodeCommand(command)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.emitDeliveryFailure(for: command, error: error)
        }) as? any WorkerXPCCommandServiceProtocol else {
            throw WorkerXPCConnectionError.remoteInterfaceUnavailable
        }

        proxy.submitCommand(commandData) { [weak self] _, error in
            self?.handleTerminalReply(error, for: command)
        }
    }

    func sendGeneration(
        _ command: WorkerCommandSnapshot,
        timeout: TimeInterval
    ) throws -> WorkerGenerationResponseSnapshot {
        guard role == .qwen,
              command.kind == .generateText,
              command.generationRequest != nil else {
            throw WorkerXPCConnectionError.invalidLiveCommand(command.kind)
        }
        let data = try submitLive(command, timeout: timeout)
        let response = try WorkerXPCPayloadCodec.decodeGenerationResponse(from: data)
        guard response.commandID == command.id else {
            throw WorkerXPCConnectionError.invalidLiveResponse(
                "generation command ID did not match"
            )
        }
        let hasReasoning = response.reasoningContent?.isEmpty == false
        let hasFingerprint = response.continuationFingerprint?.isEmpty == false
        guard hasReasoning == hasFingerprint else {
            throw WorkerXPCConnectionError.invalidLiveResponse(
                "generation reasoning fingerprint was inconsistent"
            )
        }
        return response
    }

    func sendQueryEmbedding(
        _ command: WorkerCommandSnapshot,
        timeout: TimeInterval
    ) throws -> WorkerQueryEmbeddingResponseSnapshot {
        guard role == .bge,
              command.kind == .embedQueries,
              let request = command.queryEmbeddingRequest else {
            throw WorkerXPCConnectionError.invalidLiveCommand(command.kind)
        }
        let data = try submitLive(command, timeout: timeout)
        let response = try WorkerXPCPayloadCodec.decodeQueryEmbeddingResponse(from: data)
        guard response.commandID == command.id,
              response.embeddingDimension == request.embeddingDimension,
              response.embeddingVersion == request.embeddingVersion else {
            throw WorkerXPCConnectionError.invalidLiveResponse(
                "query embedding identity did not match"
            )
        }
        if response.status == .success {
            guard let embeddings = response.embeddings,
                  embeddings.count == request.texts.count,
                  embeddings.allSatisfy({
                      $0 == nil || $0?.count == request.embeddingDimension
                  }) else {
                throw WorkerXPCConnectionError.invalidLiveResponse(
                    "query embedding shape did not match"
                )
            }
        }
        return response
    }

    private func submitLive(
        _ command: WorkerCommandSnapshot,
        timeout: TimeInterval
    ) throws -> Data {
        switch stateLock.withLock({ state.phase }) {
        case .active:
            break
        case .created, .starting:
            throw WorkerXPCConnectionError.notStarted
        case .invalidated:
            throw WorkerXPCConnectionError.invalidated
        }

        let commandData = try WorkerXPCPayloadCodec.encodeCommand(command)
        let reply = XPCLiveCommandReply()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply.send(
                data: nil,
                error: WorkerXPCPayloadCodec.error(
                    error,
                    operation: "Send live worker command",
                    retryableDeliveryFailure: true
                )
            )
        }) as? any WorkerXPCCommandServiceProtocol else {
            throw WorkerXPCConnectionError.remoteInterfaceUnavailable
        }
        proxy.submitCommand(commandData) { data, error in
            reply.send(data: data, error: error)
        }

        try reply.waitUntilResolved(timeout: timeout)
        if let error = reply.error {
            throw error
        }
        guard let data = reply.data else {
            throw WorkerXPCConnectionError.invalidLiveResponse("response payload was missing")
        }
        return data
    }

    /// Replaces the generative worker's in-memory MCP credential generation.
    /// The acknowledgement is delayed until affected child sessions retire.
    public func updateMCPEnvironment(
        _ snapshotData: Data,
        onAcknowledged acknowledgement: @escaping @Sendable (NSError?) -> Void
    ) throws {
        let phase = stateLock.withLock { state.phase }
        switch phase {
        case .active:
            break
        case .created, .starting:
            throw WorkerXPCConnectionError.notStarted
        case .invalidated:
            throw WorkerXPCConnectionError.invalidated
        }

        let completion = XPCBootstrapReplyOnce(completion: acknowledgement)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion.send(error as NSError)
        }) as? any WorkerXPCCommandServiceProtocol else {
            throw WorkerXPCConnectionError.remoteInterfaceUnavailable
        }
        proxy.updateMCPEnvironment(snapshotData) { error in
            completion.send(error)
        }
        recoveryQueue.asyncAfter(deadline: .now() + bootstrapTimeout) { [bootstrapTimeout] in
            completion.send(
                WorkerXPCConnectionError.mcpEnvironmentUpdateTimedOut(bootstrapTimeout) as NSError
            )
        }
    }

    /// Requests an orderly service shutdown without waiting for the worker's
    /// terminal reply. The caller can continue observing the durable role lock
    /// or status snapshot and invalidate the connection once shutdown finishes.
    public func shutdown() throws {
        try shutdown { _ in }
    }

    /// Requests shutdown and reports after the worker runtime has reached its
    /// terminal edge. This lets the supervisor invalidate and replace the
    /// connection without racing a still-running helper session.
    public func shutdown(
        onAcknowledged acknowledgement: @escaping @Sendable (NSError?) -> Void
    ) throws {
        let phase = stateLock.withLock { state.phase }
        switch phase {
        case .active:
            break
        case .created, .starting:
            throw WorkerXPCConnectionError.notStarted
        case .invalidated:
            throw WorkerXPCConnectionError.invalidated
        }

        let completion = XPCShutdownAcknowledgement(acknowledgement)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            guard let self else { return }
            self.emit(.connectionFailed(role: self.role, message: error.localizedDescription))
            completion.send(error as NSError)
        }) as? any WorkerXPCCommandServiceProtocol else {
            throw WorkerXPCConnectionError.remoteInterfaceUnavailable
        }
        proxy.shutdown { [weak self] error in
            if let self, let error {
                self.emit(.connectionFailed(role: self.role, message: error.localizedDescription))
            }
            completion.send(error)
        }
    }

    public func invalidate() {
        let registration = stateLock.withLock { () -> WorkerCommandSenderRegistration? in
            guard state.phase != .invalidated else { return nil }
            state.phase = .invalidated
            let registration = state.registration
            state.registration = nil
            return registration
        }
        if let registration {
            transport.unregister(registration)
        }
        connection.invalidate()
        emit(.invalidated(role))
    }

    private func handleInterruption() {
        let didTransition = stateLock.withLock { () -> Bool in
            guard state.phase == .active else { return false }
            state.phase = .starting
            return true
        }
        guard didTransition else { return }
        emit(.interrupted(role))
        beginBootstrap(isRecovery: true)
    }

    private func beginBootstrap(isRecovery: Bool) {
        let attempt = stateLock.withLock { () -> UInt64? in
            guard state.phase == .starting else { return nil }
            state.bootstrapAttempt &+= 1
            return state.bootstrapAttempt
        }
        guard let attempt else { return }

        let configurationData: Data
        do {
            configurationData = try WorkerXPCPayloadCodec.encodeBootstrap(
                bootstrapConfiguration
            )
        } catch {
            finishBootstrap(
                attempt: attempt,
                isRecovery: isRecovery,
                error: error as NSError
            )
            return
        }

        let reply = XPCBootstrapReplyOnce { [weak self] error in
            self?.finishBootstrap(
                attempt: attempt,
                isRecovery: isRecovery,
                error: error
            )
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply.send(error as NSError)
        }) as? any WorkerXPCCommandServiceProtocol else {
            reply.send(WorkerXPCConnectionError.remoteInterfaceUnavailable as NSError)
            return
        }
        proxy.bootstrap(configurationData) { error in
            reply.send(error)
        }
        recoveryQueue.asyncAfter(deadline: .now() + bootstrapTimeout) { [weak self] in
            guard let self else { return }
            reply.send(
                WorkerXPCConnectionError.bootstrapTimedOut(self.bootstrapTimeout) as NSError
            )
        }
    }

    private func finishBootstrap(
        attempt: UInt64,
        isRecovery: Bool,
        error: NSError?
    ) {
        guard stateLock.withLock({
            state.phase == .starting && state.bootstrapAttempt == attempt
        }) else { return }

        if let error {
            emit(.connectionFailed(role: role, message: error.localizedDescription))
            invalidate()
            return
        }

        let becameActive = stateLock.withLock { () -> Bool in
            guard state.phase == .starting,
                  state.bootstrapAttempt == attempt,
                  state.registration != nil else {
                return false
            }
            state.phase = .active
            return true
        }
        guard becameActive else { return }

        do {
            try replayJournaledCommands()
            if isRecovery {
                emit(.reconnected(role))
            }
        } catch {
            emit(.connectionFailed(role: role, message: error.localizedDescription))
            invalidate()
        }
    }

    private func replayJournaledCommands() throws {
        for command in try transport.journaledCommands(for: role) {
            let shouldDispatch = stateLock.withLock { () -> Bool in
                guard state.phase != .invalidated else { return false }
                state.pendingCommandIDs.insert(command.id)
                return true
            }
            guard shouldDispatch else {
                throw WorkerXPCConnectionError.invalidated
            }
            Task.detached(priority: Self.replayPriority(for: command)) { [weak self] in
                guard let self else { return }
                do {
                    try self.dispatch(command)
                } catch {
                    self.emitDeliveryFailure(for: command, error: error)
                }
            }
        }
    }

    private static func replayPriority(for command: WorkerCommandSnapshot) -> TaskPriority {
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

    private func handleTerminalReply(
        _ error: NSError?,
        for command: WorkerCommandSnapshot
    ) {
        if let error, WorkerXPCPayloadCodec.isRetryableDeliveryFailure(error) {
            emitDeliveryFailure(for: command, error: error)
            return
        }

        do {
            try transport.acknowledge(commandID: command.id, for: role)
        } catch {
            emitDeliveryFailure(for: command, error: error)
            return
        }

        let wasPending = stateLock.withLock {
            state.pendingCommandIDs.remove(command.id) != nil
        }
        guard wasPending else { return }
        if let error {
            emit(
                .commandFailed(
                    role: role,
                    commandID: command.id,
                    message: error.localizedDescription
                )
            )
        } else {
            emit(.commandCompleted(role: role, commandID: command.id))
        }
    }

    private func emitDeliveryFailure(
        for command: WorkerCommandSnapshot,
        error: any Error
    ) {
        let message = error.localizedDescription
        emit(.commandFailed(role: role, commandID: command.id, message: message))
        emit(.connectionFailed(role: role, message: message))
    }

    private func handleInvalidation() {
        let registration = stateLock.withLock { () -> WorkerCommandSenderRegistration? in
            guard state.phase != .invalidated else { return nil }
            state.phase = .invalidated
            let registration = state.registration
            state.registration = nil
            return registration
        }
        if let registration {
            transport.unregister(registration)
        }
        emit(.invalidated(role))
    }

    private func emit(_ event: WorkerXPCConnectionEvent) {
        eventHandler?(event)
    }
}

private final class XPCBootstrapReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private let completion: @Sendable (NSError?) -> Void
    private var didReply = false

    init(completion: @escaping @Sendable (NSError?) -> Void) {
        self.completion = completion
    }

    func send(_ error: NSError?) {
        let shouldReply = lock.withLock { () -> Bool in
            guard !didReply else { return false }
            didReply = true
            return true
        }
        if shouldReply {
            completion(error)
        }
    }
}

private final class XPCShutdownAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private let acknowledgement: @Sendable (NSError?) -> Void
    private var didSend = false

    init(_ acknowledgement: @escaping @Sendable (NSError?) -> Void) {
        self.acknowledgement = acknowledgement
    }

    func send(_ error: NSError?) {
        let shouldSend = lock.withLock { () -> Bool in
            guard !didSend else { return false }
            didSend = true
            return true
        }
        if shouldSend {
            acknowledgement(error)
        }
    }
}

final class XPCLiveCommandReply: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didReply = false
    private var storedData: Data?
    private var storedError: NSError?

    func send(data: Data?, error: NSError?) {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !didReply else { return false }
            didReply = true
            storedData = data
            storedError = error
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func waitUntilResolved(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05
    ) throws {
        let boundedTimeout = max(0, timeout)
        let boundedPollInterval = min(0.05, max(0.001, pollInterval))
        let deadline = ProcessInfo.processInfo.systemUptime + boundedTimeout

        while true {
            try Task.checkCancellation()
            let remaining = max(
                0,
                deadline - ProcessInfo.processInfo.systemUptime
            )
            if wait(timeout: min(boundedPollInterval, remaining)) {
                return
            }
            guard remaining > 0 else {
                throw WorkerXPCConnectionError.liveCommandTimedOut(boundedTimeout)
            }
        }
    }

    var data: Data? { lock.withLock { storedData } }
    var error: NSError? { lock.withLock { storedError } }
}
