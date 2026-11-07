import Foundation

/// A message field family changed by a completed pipeline operation.
public enum PipelineMessageFacet: String, Codable, Hashable, Sendable {
    case interpretation
    case summary
    case visibility
}

/// Message-scoped changes produced by one pipeline operation. A completion may
/// contain multiple entries when different messages changed different facets.
public struct PipelineMessageMutation: Codable, Equatable, Sendable {
    public let messageIDs: [UUID]
    public let facets: Set<PipelineMessageFacet>

    public init(messageIDs: [UUID], facets: Set<PipelineMessageFacet>) {
        self.messageIDs = messageIDs
        self.facets = facets
    }
}

/// Typed completion event surfaced by `BackgroundScheduler` after every
/// successful `queue.complete(job:)`. Listeners decode `payload` per
/// `type` (e.g. `FrameBurstPayload` for `.frameBurst`).
///
/// Failed jobs are NOT broadcast — the scheduler's `catch` branch calls
/// `queue.fail`, not `queue.complete`. Listeners needing failure signals
/// will need a separate event type.
public struct JobCompletionEvent: Sendable {
    public let type: JobType
    public let payload: String?
    public let completedAt: Date
    /// `nil` means the producer predates message-scoped completion metadata,
    /// so consumers must use the job-type fallback. An empty array is an
    /// authoritative no-message-change result.
    public let messageMutations: [PipelineMessageMutation]?

    public init(
        type: JobType,
        payload: String?,
        completedAt: Date,
        messageMutations: [PipelineMessageMutation]? = nil
    ) {
        self.type = type
        self.payload = payload
        self.completedAt = completedAt
        self.messageMutations = messageMutations
    }
}

public struct IMAPLiveInboundPayload: Codable, Sendable, Equatable {
    public let accountID: UUID
    public let folder: String
    public let count: Int
    public let messageIDs: [UUID]
    public let observedAt: Date

    public init(
        accountID: UUID,
        folder: String,
        count: Int,
        messageIDs: [UUID],
        observedAt: Date
    ) {
        self.accountID = accountID
        self.folder = folder
        self.count = count
        self.messageIDs = messageIDs
        self.observedAt = observedAt
    }
}

/// Multi-consumer pub/sub for job completions. Each call to `events()`
/// returns a fresh `AsyncStream` with its own continuation; `yield`
/// broadcasts to every live continuation. Continuations self-remove from
/// the internal dict when their stream terminates (consumer `break` or
/// `Task` cancellation).
///
/// Lives in `OhiaCore` (not `OhiaScheduler`) so that `AppServices`
/// (`OhiaML`, which depends on `OhiaCore`) can own the instance and
/// both producers (`BackgroundScheduler`, upstream of `AppServices`) and
/// consumers (the SwiftUI view layer) can reach it without a dependency
/// cycle.
@MainActor
public final class JobCompletionBroadcaster {
    private var continuations: [UUID: AsyncStream<JobCompletionEvent>.Continuation] = [:]

    public init() {}

    public var subscriberCount: Int { continuations.count }

    public func events() -> AsyncStream<JobCompletionEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    public func yield(_ event: JobCompletionEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}
