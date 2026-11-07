import Darwin
import Foundation

@_silgen_name("flock")
private func workerStatusSystemFlock(_ fileDescriptor: Int32, _ operation: Int32) -> Int32

public enum WorkerStatusStoreError: Error, Equatable, Sendable, LocalizedError {
    case liveOnlyCommand(WorkerCommandKind)

    public var errorDescription: String? {
        switch self {
        case .liveOnlyCommand(let kind):
            return "The \(kind.rawValue) command requires a live worker connection."
        }
    }
}

public struct WorkerStatusStore: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
    }

    public static func defaultDirectoryURL() -> URL {
        do {
            return try OhiaStorageRoot.resolve().workerState
        } catch {
            preconditionFailure("Unable to resolve Ohia worker storage: \(String(reflecting: type(of: error)))")
        }
    }

    public static func directoryURL(storageLayout: OhiaStorageLayout) -> URL {
        storageLayout.workerState
    }

    public func statusURL(for role: WorkerRole) -> URL {
        directoryURL.appendingPathComponent(role.statusFilename, isDirectory: false)
    }

    public func commandURL(for role: WorkerRole) -> URL {
        directoryURL.appendingPathComponent(
            "worker-\(role.rawValue).command.json",
            isDirectory: false
        )
    }

    public func commandQueueDirectoryURL(for role: WorkerRole) -> URL {
        directoryURL
            .appendingPathComponent("commands", isDirectory: true)
            .appendingPathComponent(role.rawValue, isDirectory: true)
    }

    /// Durable journal for commands accepted by the live XPC transport but not
    /// yet acknowledged by the destination worker. This is deliberately
    /// separate from `commandQueueDirectoryURL`: journal entries are replayed
    /// over XPC so their scheduling context and QoS are preserved.
    public func xpcCommandJournalDirectoryURL(for role: WorkerRole) -> URL {
        directoryURL
            .appendingPathComponent("xpc-command-journal", isDirectory: true)
            .appendingPathComponent(role.rawValue, isDirectory: true)
    }

    public func interactiveGenerationURL() -> URL {
        directoryURL.appendingPathComponent(
            "worker-interactive-qwen-generation.json",
            isDirectory: false
        )
    }

    public func interactiveGenerationLeaseDirectoryURL() -> URL {
        directoryURL.appendingPathComponent(
            "interactive-qwen-leases",
            isDirectory: true
        )
    }

    public func snapshot(for role: WorkerRole) throws -> WorkerStatusSnapshot? {
        let url = statusURL(for: role)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try Self.decoder().decode(WorkerStatusSnapshot.self, from: data)
    }

    public func snapshots() throws -> [WorkerStatusSnapshot] {
        try WorkerRole.allCases.compactMap { role in
            try snapshot(for: role)
        }
    }

    public func fleetSnapshot(at date: Date = Date()) throws -> WorkerFleetStatusSnapshot {
        WorkerFleetStatusSnapshot(workers: try snapshots(), updatedAt: date)
    }

    @discardableResult
    public func write(_ snapshot: WorkerStatusSnapshot) throws -> WorkerStatusSnapshot {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder().encode(snapshot)
        try data.write(to: statusURL(for: snapshot.role), options: .atomic)
        return snapshot
    }

    @discardableResult
    public func heartbeat(
        role: WorkerRole,
        pid: Int32? = nil,
        parentPID: Int32? = nil,
        state: WorkerState = .running,
        currentJobType: String? = nil,
        currentJobDescription: String? = nil,
        promptUsage: WorkerPromptUsageSnapshot? = nil,
        throttle: WorkerThrottleSnapshot = .notThrottled,
        statusMessage: String? = nil,
        model: WorkerModelStatusSnapshot? = nil,
        training: WorkerTrainingStatusSnapshot? = nil,
        resource: WorkerResourceStatusSnapshot? = nil,
        completionStreamID: UUID? = nil,
        imapActivityStreamID: UUID? = nil,
        at date: Date = Date()
    ) throws -> WorkerStatusSnapshot {
        try withMutationLock(for: role) {
            let existing = try snapshotForMutation(for: role)
            let resolvedModel = model ?? Self.preservedModel(
                from: existing?.model,
                forHeartbeatState: state
            )
            let resolvedResource = resource ?? (
                state == .starting ? nil : existing?.resource
            )
            let streamChanged = completionStreamID != nil
                && completionStreamID != existing?.completionStreamID
            let imapStreamChanged = imapActivityStreamID != nil
                && imapActivityStreamID != existing?.imapActivityStreamID
            let promptUsageJobTypes = ["generation", "generateDraft"]
            let resolvedPromptUsage = currentJobType.map(promptUsageJobTypes.contains) == true
                ? promptUsage
                : nil
            let snapshot = WorkerStatusSnapshot(
                role: role,
                pid: pid,
                parentPID: parentPID,
                state: state,
                currentJobType: currentJobType,
                currentJobDescription: currentJobDescription,
                promptUsage: resolvedPromptUsage,
                throttle: throttle,
                statusMessage: statusMessage,
                model: resolvedModel,
                training: training ?? existing?.training,
                resource: resolvedResource,
                startedAt: state == .starting
                    ? date
                    : (existing?.startedAt ?? startDate(for: state, at: date)),
                updatedAt: date,
                completionStreamID:
                    completionStreamID ?? existing?.completionStreamID,
                completionSequence:
                    streamChanged ? 0 : existing?.completionSequence,
                recentCompletions:
                    streamChanged ? [] : (existing?.recentCompletions ?? []),
                imapActivityStreamID:
                    imapActivityStreamID ?? existing?.imapActivityStreamID,
                imapActivitySequence:
                    imapStreamChanged ? 0 : existing?.imapActivitySequence,
                recentIMAPActivities:
                    imapStreamChanged ? [] : (existing?.recentIMAPActivities ?? [])
            )
            return try write(snapshot)
        }
    }

    @discardableResult
    public func markStopped(
        role: WorkerRole,
        pid: Int32? = nil,
        parentPID: Int32? = nil,
        message: String? = nil,
        at date: Date = Date()
    ) throws -> WorkerStatusSnapshot {
        try withMutationLock(for: role) {
            let existing = try snapshotForMutation(for: role)
            let snapshot = WorkerStatusSnapshot(
                role: role,
                pid: pid,
                parentPID: parentPID,
                state: .stopped,
                statusMessage: message,
                model: Self.stoppedModel(from: existing?.model),
                training: existing?.training,
                startedAt: existing?.startedAt,
                updatedAt: date,
                completionStreamID: existing?.completionStreamID,
                completionSequence: existing?.completionSequence,
                recentCompletions: existing?.recentCompletions ?? [],
                imapActivityStreamID: existing?.imapActivityStreamID,
                imapActivitySequence: existing?.imapActivitySequence,
                recentIMAPActivities: existing?.recentIMAPActivities ?? []
            )
            return try write(snapshot)
        }
    }

    @discardableResult
    public func markFailed(
        role: WorkerRole,
        pid: Int32? = nil,
        parentPID: Int32? = nil,
        message: String,
        at date: Date = Date()
    ) throws -> WorkerStatusSnapshot {
        try withMutationLock(for: role) {
            let existing = try snapshotForMutation(for: role)
            let snapshot = WorkerStatusSnapshot(
                role: role,
                pid: pid,
                parentPID: parentPID,
                state: .failed,
                statusMessage: message,
                model: Self.stoppedModel(from: existing?.model),
                training: existing?.training,
                startedAt: existing?.startedAt,
                updatedAt: date,
                completionStreamID: existing?.completionStreamID,
                completionSequence: existing?.completionSequence,
                recentCompletions: existing?.recentCompletions ?? [],
                imapActivityStreamID: existing?.imapActivityStreamID,
                imapActivitySequence: existing?.imapActivitySequence,
                recentIMAPActivities: existing?.recentIMAPActivities ?? []
            )
            return try write(snapshot)
        }
    }

    @discardableResult
    public func appendCompletion(
        _ completion: WorkerCompletionSnapshot,
        role: WorkerRole,
        completionStreamID: UUID? = nil,
        limit: Int = 20,
        at date: Date = Date()
    ) throws -> WorkerStatusSnapshot {
        try withMutationLock(for: role) {
        let existing = try snapshotForMutation(for: role) ?? WorkerStatusSnapshot(
            role: role,
            state: .unknown,
            updatedAt: date
        )
        let resolvedStreamID = completionStreamID
            ?? existing.completionStreamID
            ?? UUID()
        let streamChanged = existing.completionStreamID != resolvedStreamID
        let priorSequence = streamChanged
            ? 0
            : (existing.completionSequence
                ?? existing.recentCompletions.compactMap(\.sequence).max()
                ?? 0)
        let nextSequence = priorSequence &+ 1
        let sequencedCompletion = completion.assigning(
            sequence: nextSequence
        )
        let trimmedLimit = max(0, limit)
        let retainedCompletions = streamChanged
            ? []
            : existing.recentCompletions
        let completions = ([sequencedCompletion] + retainedCompletions)
            .prefix(trimmedLimit)
        let snapshot = WorkerStatusSnapshot(
            role: role,
            pid: existing.pid,
            parentPID: existing.parentPID,
            state: existing.state,
            currentJobType: existing.currentJobType,
            currentJobDescription: existing.currentJobDescription,
            promptUsage: existing.promptUsage,
            throttle: existing.throttle,
            statusMessage: existing.statusMessage,
            model: existing.model,
            training: existing.training,
            resource: existing.resource,
            startedAt: existing.startedAt,
            updatedAt: date,
            completionStreamID: resolvedStreamID,
            completionSequence: nextSequence,
            recentCompletions: Array(completions),
            imapActivityStreamID: existing.imapActivityStreamID,
            imapActivitySequence: existing.imapActivitySequence,
            recentIMAPActivities: existing.recentIMAPActivities
        )
        return try write(snapshot)
        }
    }

    @discardableResult
    public func appendIMAPActivity(
        _ activity: WorkerIMAPActivitySnapshot,
        role: WorkerRole,
        imapActivityStreamID: UUID? = nil,
        limit: Int = 256,
        at date: Date = Date()
    ) throws -> WorkerStatusSnapshot {
        try withMutationLock(for: role) {
        let existing = try snapshotForMutation(for: role) ?? WorkerStatusSnapshot(
            role: role,
            state: .unknown,
            updatedAt: date
        )
        let resolvedStreamID = imapActivityStreamID
            ?? existing.imapActivityStreamID
            ?? UUID()
        let streamChanged = existing.imapActivityStreamID != resolvedStreamID
        let priorSequence = streamChanged
            ? 0
            : (existing.imapActivitySequence
                ?? existing.recentIMAPActivities.compactMap(\.sequence).max()
                ?? 0)
        let nextSequence = priorSequence &+ 1
        let sequencedActivity = activity.assigning(sequence: nextSequence)
        let retainedActivities = streamChanged ? [] : existing.recentIMAPActivities
        let activities = ([sequencedActivity] + retainedActivities)
            .prefix(max(0, limit))
        return try write(WorkerStatusSnapshot(
            role: role,
            pid: existing.pid,
            parentPID: existing.parentPID,
            state: existing.state,
            currentJobType: existing.currentJobType,
            currentJobDescription: existing.currentJobDescription,
            promptUsage: existing.promptUsage,
            throttle: existing.throttle,
            statusMessage: existing.statusMessage,
            model: existing.model,
            training: existing.training,
            resource: existing.resource,
            startedAt: existing.startedAt,
            updatedAt: date,
            completionStreamID: existing.completionStreamID,
            completionSequence: existing.completionSequence,
            recentCompletions: existing.recentCompletions,
            imapActivityStreamID: resolvedStreamID,
            imapActivitySequence: nextSequence,
            recentIMAPActivities: Array(activities)
        ))
        }
    }

    public func removeSnapshot(for role: WorkerRole) throws {
        let url = statusURL(for: role)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Worker status is an ephemeral same-build DTO. A stale enum payload may
    /// be replaced by the next writer, while actual file reads must still fail.
    private func withMutationLock<T>(
        for role: WorkerRole,
        _ operation: () throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let lockURL = directoryURL.appendingPathComponent(
            ".worker-\(role.rawValue).status.lock",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = Darwin.close(descriptor) }
        guard workerStatusSystemFlock(descriptor, LOCK_EX) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = workerStatusSystemFlock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func snapshotForMutation(
        for role: WorkerRole
    ) throws -> WorkerStatusSnapshot? {
        do {
            return try snapshot(for: role)
        } catch is DecodingError {
            return nil
        }
    }

    /// Removes worker runtime handoff files after a confirmed shutdown.
    ///
    /// The workers directory only contains ephemeral status and content-free
    /// control-command state. A developer reset should not carry either across
    /// into the next onboarding run.
    public func removeRuntimeArtifacts() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return
        }

        let children = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        for child in children {
            try fileManager.removeItem(at: child)
        }
    }

    @discardableResult
    public func writeCommand(
        _ command: WorkerCommandSnapshot,
        for role: WorkerRole
    ) throws -> WorkerCommandSnapshot {
        guard !command.kind.requiresLiveConnection else {
            throw WorkerStatusStoreError.liveOnlyCommand(command.kind)
        }
        let queueDirectory = commandQueueDirectoryURL(for: role)
        try FileManager.default.createDirectory(
            at: queueDirectory,
            withIntermediateDirectories: true
        )
        if role == .qwen,
           let targetCommandID = command.cancelledGenerationCommandID,
           try queuedCommands(for: role).contains(where: {
               $0.command.cancelledGenerationCommandID == targetCommandID
           }) {
            return command
        }
        if role == .bge,
           let targetCommandID = command.cancelledQueryEmbeddingCommandID,
           try queuedCommands(for: role).contains(where: {
               $0.command.cancelledQueryEmbeddingCommandID == targetCommandID
           }) {
            return command
        }
        let data = try Self.encoder().encode(command)
        try data.write(to: queuedCommandURL(for: role, command: command), options: .atomic)
        return command
    }

    @discardableResult
    public func journalXPCCommand(
        _ command: WorkerCommandSnapshot,
        for role: WorkerRole
    ) throws -> WorkerCommandSnapshot {
        guard !command.kind.requiresLiveConnection else {
            throw WorkerStatusStoreError.liveOnlyCommand(command.kind)
        }
        let journalDirectory = xpcCommandJournalDirectoryURL(for: role)
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder().encode(command)
        try data.write(
            to: xpcCommandJournalURL(for: role, commandID: command.id),
            options: .atomic
        )
        return command
    }

    public func journaledXPCCommands(for role: WorkerRole) throws -> [WorkerCommandSnapshot] {
        let directory = xpcCommandJournalDirectoryURL(for: role)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        let prefix = "worker-\(role.rawValue)-xpc-command-"
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix(prefix) && name.hasSuffix(".json")
        }
        .compactMap { url in
            do {
                let data = try Data(contentsOf: url)
                let command = try Self.decoder().decode(WorkerCommandSnapshot.self, from: data)
                return command.kind.requiresLiveConnection ? nil : command
            } catch {
                let cocoaError = error as NSError
                if cocoaError.domain == NSCocoaErrorDomain,
                   cocoaError.code == NSFileReadNoSuchFileError {
                    // A terminal acknowledgement may remove an entry after the
                    // directory listing but before this read.
                    return nil
                }
                throw error
            }
        }
        .sorted {
            if $0.issuedAt == $1.issuedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.issuedAt < $1.issuedAt
        }
    }

    public func acknowledgeXPCCommand(commandID: UUID, for role: WorkerRole) throws {
        let url = xpcCommandJournalURL(for: role, commandID: commandID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func command(for role: WorkerRole) throws -> WorkerCommandSnapshot? {
        if let queued = try queuedCommands(for: role).first {
            return queued.command
        }

        let url = commandURL(for: role)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let command = try Self.decoder().decode(WorkerCommandSnapshot.self, from: data)
        return command.kind.requiresLiveConnection ? nil : command
    }

    public func consumeCommand(for role: WorkerRole) throws -> WorkerCommandSnapshot? {
        if let queued = try queuedCommands(for: role).first {
            try? FileManager.default.removeItem(at: queued.url)
            return queued.command
        }

        let url = commandURL(for: role)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let command = try Self.decoder().decode(WorkerCommandSnapshot.self, from: data)
        guard !command.kind.requiresLiveConnection else { return nil }
        try? FileManager.default.removeItem(at: commandURL(for: role))
        return command
    }

    public func consumePrioritizedCommand(for role: WorkerRole) throws -> WorkerCommandSnapshot? {
        if let queued = try prioritizedQueuedCommands(for: role).first {
            try? FileManager.default.removeItem(at: queued.url)
            return queued.command
        }

        let url = commandURL(for: role)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let command = try Self.decoder().decode(WorkerCommandSnapshot.self, from: data)
        guard !command.kind.requiresLiveConnection else { return nil }
        try? FileManager.default.removeItem(at: commandURL(for: role))
        return command
    }

    public func hasSupersedingInteractiveSummarizationCommand(
        for role: WorkerRole,
        issuedAfter issuedAt: Date
    ) throws -> Bool {
        try queuedCommands(for: role).contains { queued in
            queued.command.isInteractiveSummarizationFastLane
                && queued.command.issuedAt > issuedAt
        }
    }

    public func hasSupersedingUserInteractiveGenerationCommand(
        for role: WorkerRole,
        issuedAfter issuedAt: Date
    ) throws -> Bool {
        try queuedCommands(for: role).contains { queued in
            queued.command.isUserInteractiveGeneration
                && queued.command.issuedAt > issuedAt
        }
    }

    public func hasGenerationCancellationCommand(
        for role: WorkerRole,
        targetCommandID: UUID
    ) throws -> Bool {
        try queuedCommands(for: role).contains { queued in
            queued.command.cancelledGenerationCommandID == targetCommandID
        }
    }

    public func hasQueryEmbeddingCancellationCommand(
        for role: WorkerRole,
        targetCommandID: UUID
    ) throws -> Bool {
        try queuedCommands(for: role).contains { queued in
            queued.command.cancelledQueryEmbeddingCommandID == targetCommandID
        }
    }

    @discardableResult
    public func beginInteractiveGeneration(
        reason: String,
        lane: InteractiveGenerationLane = .userInteractive,
        ttl: TimeInterval = 120,
        at date: Date = Date()
    ) throws -> WorkerInteractiveGenerationSnapshot {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        if let active = try interactiveGenerationSnapshot(at: date),
           active.lane > lane {
            throw WorkerInteractiveGenerationLeaseError.higherPriorityActive(
                activeLane: active.lane,
                activeReason: active.reason,
                requestedLane: lane,
                requestedReason: reason
            )
        }
        let snapshot = WorkerInteractiveGenerationSnapshot(
            reason: reason,
            lane: lane,
            startedAt: date,
            expiresAt: date.addingTimeInterval(max(1, ttl))
        )
        let leaseDirectory = interactiveGenerationLeaseDirectoryURL()
        try FileManager.default.createDirectory(
            at: leaseDirectory,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder().encode(snapshot)
        try data.write(
            to: leaseDirectory.appendingPathComponent("\(snapshot.id.uuidString).json"),
            options: .atomic
        )
        if lane == .userInteractive {
            InteractiveGenerationPreemptionBroker.shared.publishUserInteractiveBegan()
        }
        return snapshot
    }

    public func interactiveGenerationSnapshot(
        at date: Date = Date()
    ) throws -> WorkerInteractiveGenerationSnapshot? {
        try activeInteractiveGenerationSnapshots(at: date).max { lhs, rhs in
            if lhs.lane == rhs.lane {
                return lhs.startedAt < rhs.startedAt
            }
            return lhs.lane < rhs.lane
        }
    }

    public func isInteractiveGenerationActive(at date: Date = Date()) -> Bool {
        do {
            return try interactiveGenerationSnapshot(at: date) != nil
        } catch {
            return false
        }
    }

    public func interactiveGenerationLane(at date: Date = Date()) -> InteractiveGenerationLane? {
        do {
            return try interactiveGenerationSnapshot(at: date)?.lane
        } catch {
            return nil
        }
    }

    public func isUserInteractiveGenerationActive(at date: Date = Date()) -> Bool {
        interactiveGenerationLane(at: date) == .userInteractive
    }

    public func endInteractiveGeneration(
        id: UUID,
        at date: Date = Date()
    ) throws {
        let leaseURL = interactiveGenerationLeaseDirectoryURL()
            .appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: leaseURL)

        // Remove a legacy single-file lease only when this caller owns it.
        let legacyURL = interactiveGenerationURL()
        if FileManager.default.fileExists(atPath: legacyURL.path),
           let data = try? Data(contentsOf: legacyURL),
           let snapshot = try? Self.decoder().decode(
               WorkerInteractiveGenerationSnapshot.self,
               from: data
           ),
           snapshot.id == id {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        _ = try activeInteractiveGenerationSnapshots(at: date)
    }

    private func activeInteractiveGenerationSnapshots(
        at date: Date
    ) throws -> [WorkerInteractiveGenerationSnapshot] {
        let fileManager = FileManager.default
        var snapshots: [WorkerInteractiveGenerationSnapshot] = []
        let leaseDirectory = interactiveGenerationLeaseDirectoryURL()
        if fileManager.fileExists(atPath: leaseDirectory.path) {
            for url in try fileManager.contentsOfDirectory(
                at: leaseDirectory,
                includingPropertiesForKeys: nil
            ) where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let snapshot = try? Self.decoder().decode(
                          WorkerInteractiveGenerationSnapshot.self,
                          from: data
                      ) else {
                    try? fileManager.removeItem(at: url)
                    continue
                }
                if snapshot.isActive(at: date) {
                    snapshots.append(snapshot)
                } else {
                    try? fileManager.removeItem(at: url)
                }
            }
        }

        // Read the pre-multiplexing file until all users have upgraded. New
        // writers use one file per lease so equal-priority callers cannot erase
        // each other's residency protection.
        let legacyURL = interactiveGenerationURL()
        if fileManager.fileExists(atPath: legacyURL.path) {
            if let data = try? Data(contentsOf: legacyURL),
               let snapshot = try? Self.decoder().decode(
                   WorkerInteractiveGenerationSnapshot.self,
                   from: data
               ),
               snapshot.isActive(at: date) {
                snapshots.append(snapshot)
            } else {
                try? fileManager.removeItem(at: legacyURL)
            }
        }
        return snapshots
    }

    private func startDate(for state: WorkerState, at date: Date) -> Date? {
        switch state {
        case .starting, .idle, .waiting, .running, .busy, .throttled, .paused:
            return date
        case .unknown, .stopping, .stopped, .failed:
            return nil
        }
    }

    private static func preservedModel(
        from existing: WorkerModelStatusSnapshot?,
        forHeartbeatState state: WorkerState
    ) -> WorkerModelStatusSnapshot? {
        switch state {
        case .starting, .running, .stopping, .stopped, .failed, .unknown:
            return nil
        case .idle, .waiting, .busy, .throttled, .paused:
            return existing
        }
    }

    private static func stoppedModel(
        from existing: WorkerModelStatusSnapshot?
    ) -> WorkerModelStatusSnapshot? {
        guard let existing else { return nil }
        return WorkerModelStatusSnapshot(
            name: existing.name,
            state: .unavailable,
            message: "worker stopped; model is not loaded in memory",
            download: existing.download
        )
    }

    private struct QueuedCommand {
        let command: WorkerCommandSnapshot
        let url: URL
    }

    private func queuedCommandURL(for role: WorkerRole, command: WorkerCommandSnapshot) -> URL {
        let micros = max(0, Int64((command.issuedAt.timeIntervalSinceReferenceDate * 1_000_000).rounded()))
        let timestamp = String(format: "%020lld", micros)
        return commandQueueDirectoryURL(for: role)
            .appendingPathComponent(
                "worker-\(role.rawValue)-command-\(timestamp)-\(command.id.uuidString).json",
                isDirectory: false
            )
    }

    private func xpcCommandJournalURL(for role: WorkerRole, commandID: UUID) -> URL {
        xpcCommandJournalDirectoryURL(for: role)
            .appendingPathComponent(
                "worker-\(role.rawValue)-xpc-command-\(commandID.uuidString).json",
                isDirectory: false
            )
    }

    private func queuedCommands(for role: WorkerRole) throws -> [QueuedCommand] {
        let directory = commandQueueDirectoryURL(for: role)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let prefix = "worker-\(role.rawValue)-command-"
        return try urls
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix(prefix) && name.hasSuffix(".json")
            }
            .map { url in
                let data = try Data(contentsOf: url)
                return QueuedCommand(
                    command: try Self.decoder().decode(WorkerCommandSnapshot.self, from: data),
                    url: url
                )
            }
            .filter { !$0.command.kind.requiresLiveConnection }
            .sorted {
                if $0.command.issuedAt == $1.command.issuedAt {
                    return $0.command.id.uuidString < $1.command.id.uuidString
                }
                return $0.command.issuedAt < $1.command.issuedAt
            }
    }

    private func prioritizedQueuedCommands(for role: WorkerRole) throws -> [QueuedCommand] {
        try queuedCommands(for: role).sorted(by: Self.prioritizedCommandSort)
    }

    private static func prioritizedCommandSort(_ lhs: QueuedCommand, _ rhs: QueuedCommand) -> Bool {
        let lhsRank = priorityRank(for: lhs.command)
        let rhsRank = priorityRank(for: rhs.command)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        if lhs.command.kind == .generateText, rhs.command.kind == .generateText {
            if lhs.command.issuedAt == rhs.command.issuedAt {
                return lhs.command.id.uuidString < rhs.command.id.uuidString
            }
            return lhs.command.issuedAt > rhs.command.issuedAt
        }

        if lhs.command.issuedAt == rhs.command.issuedAt {
            return lhs.command.id.uuidString < rhs.command.id.uuidString
        }
        return lhs.command.issuedAt < rhs.command.issuedAt
    }

    private static func priorityRank(for command: WorkerCommandSnapshot) -> Int {
        switch command.kind {
        case .cancelTraining, .resetTrainingToBase, .cancelGeneration,
             .cancelQueryEmbedding,
             .requestInteractiveQwenModelTurn,
             .requestInteractiveBGEModelTurn,
             .selectGenerationModel, .cancelGenerationModelPreparation:
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

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
