import Darwin
import Dispatch
import Foundation
import OhiaCore

nonisolated enum WorkerStatusRefreshAction: Equatable {
    case none
    case startRead
    case schedule(after: Duration)
}

nonisolated struct WorkerStatusRefreshGate {
    private let minimumInterval: Duration
    private var readIsInFlight = false
    private var hasPendingInvalidation = false
    private var hasScheduledRead = false
    private var lastReadStartedAt: ContinuousClock.Instant?
    private var isCancelled = false

    private(set) var generation = 0

    init(minimumInterval: Duration) {
        self.minimumInterval = max(.zero, minimumInterval)
    }

    mutating func invalidate(
        at instant: ContinuousClock.Instant,
        force: Bool = false
    ) -> WorkerStatusRefreshAction {
        guard !isCancelled else { return .none }

        if readIsInFlight {
            hasPendingInvalidation = true
            return .none
        }

        if force {
            hasPendingInvalidation = false
            hasScheduledRead = false
            return startRead(at: instant)
        }

        if hasScheduledRead {
            hasPendingInvalidation = true
            return .none
        }

        guard let lastReadStartedAt else {
            return startRead(at: instant)
        }

        let elapsed = lastReadStartedAt.duration(to: instant)
        if elapsed < .zero {
            hasPendingInvalidation = false
            return startRead(at: instant)
        }
        let remaining = minimumInterval - elapsed
        if remaining <= .zero {
            hasPendingInvalidation = false
            return startRead(at: instant)
        }

        hasPendingInvalidation = true
        hasScheduledRead = true
        return .schedule(after: remaining)
    }

    mutating func readFinished(
        at instant: ContinuousClock.Instant
    ) -> WorkerStatusRefreshAction {
        guard !isCancelled, readIsInFlight else { return .none }
        readIsInFlight = false

        guard hasPendingInvalidation else { return .none }
        guard let lastReadStartedAt else {
            hasPendingInvalidation = false
            return startRead(at: instant)
        }

        let elapsed = lastReadStartedAt.duration(to: instant)
        if elapsed < .zero {
            hasPendingInvalidation = false
            return startRead(at: instant)
        }
        let remaining = minimumInterval - elapsed
        if remaining <= .zero {
            hasPendingInvalidation = false
            return startRead(at: instant)
        }

        if hasScheduledRead {
            return .none
        }
        hasScheduledRead = true
        return .schedule(after: remaining)
    }

    mutating func readFailed() -> WorkerStatusRefreshAction {
        guard !isCancelled, readIsInFlight else { return .none }
        readIsInFlight = false
        hasPendingInvalidation = false
        hasScheduledRead = false
        return .none
    }

    mutating func scheduledReadFired(
        at instant: ContinuousClock.Instant
    ) -> WorkerStatusRefreshAction {
        guard !isCancelled,
              hasScheduledRead,
              hasPendingInvalidation,
              !readIsInFlight else {
            return .none
        }

        hasScheduledRead = false
        guard let lastReadStartedAt else {
            hasPendingInvalidation = false
            return startRead(at: instant)
        }

        let elapsed = lastReadStartedAt.duration(to: instant)
        if elapsed < .zero {
            hasPendingInvalidation = false
            return startRead(at: instant)
        }
        let remaining = minimumInterval - elapsed
        if remaining > .zero {
            hasScheduledRead = true
            return .schedule(after: remaining)
        }

        hasPendingInvalidation = false
        return startRead(at: instant)
    }

    func shouldInstall(generation candidate: Int) -> Bool {
        !isCancelled
            && readIsInFlight
            && candidate == generation
    }

    mutating func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        readIsInFlight = false
        hasPendingInvalidation = false
        hasScheduledRead = false
        generation &+= 1
    }

    private mutating func startRead(
        at instant: ContinuousClock.Instant
    ) -> WorkerStatusRefreshAction {
        readIsInFlight = true
        lastReadStartedAt = instant
        generation &+= 1
        return .startRead
    }
}

nonisolated struct BoundedWorkerCompletionHistory {
    let capacity: Int
    private(set) var ids: Set<UUID> = []
    private var order: [UUID] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func insert(_ id: UUID) -> Bool {
        guard ids.insert(id).inserted else { return false }
        order.append(id)
        while order.count > max(0, capacity) {
            ids.remove(order.removeFirst())
        }
        return true
    }
}

nonisolated struct WorkerCompletionBridgeResult: Equatable {
    let completions: [WorkerCompletionSnapshot]
    let requiresFullReconciliation: Bool
}

/// Tracks each worker runtime's completion watermark independently. New
/// workers use a new stream ID, so their sequence reset establishes a fresh
/// baseline instead of looking like packet loss. Snapshots without the full
/// sequence protocol stay on the legacy UUID-dedup path.
nonisolated struct WorkerCompletionBridgeTracker {
    private struct Cursor {
        let streamID: UUID
        var watermark: UInt64
    }

    private var cursors: [WorkerRole: Cursor] = [:]
    private var completionHistory: BoundedWorkerCompletionHistory

    init(historyCapacity: Int) {
        completionHistory = BoundedWorkerCompletionHistory(
            capacity: historyCapacity
        )
    }

    mutating func consume(
        _ worker: WorkerStatusSnapshot
    ) -> WorkerCompletionBridgeResult {
        guard let streamID = worker.completionStreamID,
              let watermark = worker.completionSequence else {
            return WorkerCompletionBridgeResult(
                completions: consumeLegacy(worker.recentCompletions),
                requiresFullReconciliation: false
            )
        }

        let cursor = cursors[worker.role]
        let isInitialObservation = cursor == nil
        let streamChanged = cursor?.streamID != streamID
        let previousWatermark = streamChanged ? 0 : (cursor?.watermark ?? 0)

        // An atomic status file can be observed late but should not move
        // backward within one runtime. Ignore a regressed copy rather than
        // replaying old events or manufacturing a second gap reconciliation.
        guard streamChanged || watermark >= previousWatermark else {
            return WorkerCompletionBridgeResult(
                completions: consumeLegacy(
                    worker.recentCompletions.filter { $0.sequence == nil }
                ),
                requiresFullReconciliation: false
            )
        }

        let newSequencedCompletions = worker.recentCompletions
            .filter { completion in
                guard let sequence = completion.sequence else { return false }
                return sequence > previousWatermark && sequence <= watermark
            }
            .sorted { lhs, rhs in
                guard let lhsSequence = lhs.sequence,
                      let rhsSequence = rhs.sequence,
                      lhsSequence != rhsSequence else {
                    return lhs.completedAt < rhs.completedAt
                }
                return lhsSequence < rhsSequence
            }
        let presentSequences = Set(
            newSequencedCompletions.compactMap(\.sequence)
        )
        let expectedCount = watermark - previousWatermark
        let gapDetected = UInt64(presentSequences.count) != expectedCount

        cursors[worker.role] = Cursor(
            streamID: streamID,
            watermark: watermark
        )

        let legacyCompletions = consumeLegacy(
            worker.recentCompletions.filter { $0.sequence == nil }
        )
        let sequencedCompletions = newSequencedCompletions.filter {
            completionHistory.insert($0.id)
        }
        return WorkerCompletionBridgeResult(
            completions: legacyCompletions + sequencedCompletions,
            requiresFullReconciliation: gapDetected
        )
    }

    private mutating func consumeLegacy(
        _ completions: [WorkerCompletionSnapshot]
    ) -> [WorkerCompletionSnapshot] {
        completions.reversed().filter {
            completionHistory.insert($0.id)
        }
    }
}

/// Exactly-once bridge for the retrieval worker's bounded IMAP activity ring.
/// A worker restart establishes a new stream and retires the old identifier;
/// a late atomic-file observation from that retired process is ignored rather
/// than being mistaken for another restart. The first observation of any new
/// stream filters old ring entries so opening Ohia never narrates minutes-old
/// connection history.
nonisolated struct WorkerIMAPActivityBridgeResult: Sendable, Sequence {
    let activities: [WorkerIMAPActivitySnapshot]
    let requiresFullReconciliation: Bool

    var isEmpty: Bool { activities.isEmpty }

    func makeIterator() -> Array<WorkerIMAPActivitySnapshot>.Iterator {
        activities.makeIterator()
    }
}

nonisolated struct WorkerIMAPActivityBridgeTracker {
    private struct Cursor {
        let streamID: UUID
        var watermark: UInt64
    }

    private let maximumInitialAge: TimeInterval
    private var cursors: [WorkerRole: Cursor] = [:]
    private var retiredStreamIDs: [WorkerRole: Set<UUID>] = [:]

    init(maximumInitialAge: TimeInterval = 15) {
        self.maximumInitialAge = max(0, maximumInitialAge)
    }

    mutating func consume(
        _ worker: WorkerStatusSnapshot,
        observedAt: Date = Date()
    ) -> WorkerIMAPActivityBridgeResult {
        guard let streamID = worker.imapActivityStreamID,
              let watermark = worker.imapActivitySequence else {
            return WorkerIMAPActivityBridgeResult(
                activities: [],
                requiresFullReconciliation: false
            )
        }
        guard retiredStreamIDs[worker.role, default: []].contains(streamID) == false else {
            return WorkerIMAPActivityBridgeResult(
                activities: [],
                requiresFullReconciliation: false
            )
        }

        let cursor = cursors[worker.role]
        let isInitialObservation = cursor == nil
        let streamChanged = cursor?.streamID != streamID
        if streamChanged, let priorStreamID = cursor?.streamID {
            retiredStreamIDs[worker.role, default: []].insert(priorStreamID)
        }
        let previousWatermark = streamChanged ? 0 : (cursor?.watermark ?? 0)
        guard streamChanged || watermark >= previousWatermark else {
            return WorkerIMAPActivityBridgeResult(
                activities: [],
                requiresFullReconciliation: false
            )
        }

        let freshnessCutoff = observedAt.addingTimeInterval(-maximumInitialAge)
        let sequencedActivities = worker.recentIMAPActivities
            .filter { activity in
                guard let sequence = activity.sequence,
                      sequence > previousWatermark,
                      sequence <= watermark else {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                guard let lhsSequence = lhs.sequence,
                      let rhsSequence = rhs.sequence,
                      lhsSequence != rhsSequence else {
                    return lhs.occurredAt < rhs.occurredAt
                }
                return lhsSequence < rhsSequence
            }

        let requiresFullReconciliation: Bool
        if isInitialObservation || watermark == previousWatermark {
            requiresFullReconciliation = false
        } else {
            let expectedCount = watermark - previousWatermark
            let isContiguous = sequencedActivities.enumerated().allSatisfy { offset, activity in
                activity.sequence == previousWatermark + UInt64(offset) + 1
            }
            requiresFullReconciliation = UInt64(sequencedActivities.count) != expectedCount
                || isContiguous == false
        }

        var activities = sequencedActivities
        if isInitialObservation {
            activities = sequencedActivities.filter { $0.occurredAt >= freshnessCutoff }
            if activities.isEmpty,
               worker.state == .running,
               worker.updatedAt >= freshnessCutoff,
               let latest = sequencedActivities.last,
               Self.isSustained(latest.kind) {
                // A long-running operation can predate the initial-history
                // window. Keep the latest sustained state when the worker's
                // heartbeat proves that the stream itself is still live.
                activities = [latest]
            }
        }

        cursors[worker.role] = Cursor(streamID: streamID, watermark: watermark)
        return WorkerIMAPActivityBridgeResult(
            activities: activities,
            requiresFullReconciliation: requiresFullReconciliation
        )
    }

    private static func isSustained(_ kind: WorkerIMAPActivityKind) -> Bool {
        switch kind {
        case .ready, .watching, .checking, .forming, .deletionsUpdated:
            return false
        default:
            return true
        }
    }
}

/// Converts atomic status-file replacements into coalescible invalidation
/// hints. JSON decoding deliberately happens elsewhere, away from both this
/// dispatch queue and MainActor.
nonisolated final class WorkerStatusDirectoryObserver: @unchecked Sendable {
    let stream: AsyncStream<Void>

    private let directoryURL: URL
    private let continuation: AsyncStream<Void>.Continuation
    private let backstopWait: @Sendable () async throws -> Void
    private let queue = DispatchQueue(
        label: "org.jgkarlin.Ohia.worker.statusWatcher",
        qos: .utility
    )
    private let stateLock = NSLock()

    private var source: DispatchSourceFileSystemObject?
    private var rearmTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var backstopTask: Task<Void, Never>?
    private var isArming = false
    private var isCancelled = false

    init(
        directoryURL: URL,
        backstopWait: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(15))
        }
    ) {
        self.directoryURL = directoryURL
        self.backstopWait = backstopWait
        let streamPair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stream = streamPair.stream
        self.continuation = streamPair.continuation

        if !armIfNeeded() {
            startRetryLoop()
        }
    }

    deinit {
        cancel()
    }

    func cancel() {
        stateLock.lock()
        guard !isCancelled else {
            stateLock.unlock()
            return
        }
        isCancelled = true
        isArming = false

        let source = self.source
        let rearmTask = self.rearmTask
        let retryTask = self.retryTask
        let backstopTask = self.backstopTask
        self.source = nil
        self.rearmTask = nil
        self.retryTask = nil
        self.backstopTask = nil
        stateLock.unlock()

        rearmTask?.cancel()
        retryTask?.cancel()
        backstopTask?.cancel()
        source?.cancel()
        continuation.finish()
    }

    @discardableResult
    private func armIfNeeded() -> Bool {
        stateLock.lock()
        guard !isCancelled, source == nil, !isArming else {
            let isArmed = source != nil
            stateLock.unlock()
            return isArmed
        }
        isArming = true
        stateLock.unlock()

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            finishFailedArm()
            return false
        }

        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            finishFailedArm()
            return false
        }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .revoke],
            queue: queue
        )
        newSource.setEventHandler { [weak self] in
            self?.handleCurrentSourceEvents()
        }
        newSource.setCancelHandler {
            close(descriptor)
        }

        let newBackstopTask = makeBackstopTask()

        stateLock.lock()
        isArming = false
        guard !isCancelled, source == nil else {
            stateLock.unlock()
            newBackstopTask.cancel()
            newSource.activate()
            newSource.cancel()
            return false
        }

        source = newSource
        backstopTask?.cancel()
        backstopTask = newBackstopTask
        let retryTask = self.retryTask
        self.retryTask = nil
        newSource.activate()
        stateLock.unlock()

        retryTask?.cancel()
        return true
    }

    private func finishFailedArm() {
        stateLock.lock()
        isArming = false
        stateLock.unlock()
    }

    private func handleCurrentSourceEvents() {
        stateLock.lock()
        let events = source?.data ?? []
        stateLock.unlock()
        guard !events.isEmpty else { return }

        continuation.yield()
        let destructiveEvents: DispatchSource.FileSystemEvent = [
            .rename,
            .delete,
            .revoke,
        ]
        guard !events.intersection(destructiveEvents).isEmpty else { return }
        invalidateSourceAndScheduleRearm()
    }

    private func invalidateSourceAndScheduleRearm() {
        stateLock.lock()
        guard !isCancelled, let source else {
            stateLock.unlock()
            return
        }
        self.source = nil
        let backstopTask = self.backstopTask
        self.backstopTask = nil
        stateLock.unlock()

        backstopTask?.cancel()
        source.cancel()
        scheduleRearm()
    }

    private func scheduleRearm() {
        stateLock.lock()
        guard !isCancelled, rearmTask == nil else {
            stateLock.unlock()
            return
        }

        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self else { return }
            self.clearRearmTask()
            if !self.armIfNeeded() {
                self.startRetryLoop()
            }
        }
        rearmTask = task
        stateLock.unlock()
    }

    private func clearRearmTask() {
        stateLock.lock()
        rearmTask = nil
        stateLock.unlock()
    }

    private func startRetryLoop() {
        stateLock.lock()
        guard !isCancelled, source == nil, retryTask == nil else {
            stateLock.unlock()
            return
        }

        let task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, !self.cancelled else { return }
                self.continuation.yield()
                if self.armIfNeeded() {
                    return
                }
            }
        }
        retryTask = task
        stateLock.unlock()
    }

    private func makeBackstopTask() -> Task<Void, Never> {
        let backstopWait = backstopWait
        return Task.detached(
            priority: .utility
        ) { [weak self, backstopWait] in
            while !Task.isCancelled {
                do {
                    try await backstopWait()
                } catch {
                    return
                }
                guard let self, self.armed else { return }
                self.continuation.yield()
            }
        }
    }

    private var armed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !isCancelled && source != nil
    }

    private var cancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isCancelled
    }
}
