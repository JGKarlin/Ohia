import Foundation
import SwiftData

@Model
public final class Job {
    public var id: UUID
    public var type: JobType
    public var status: JobStatus
    public var messageId: UUID?
    public var priority: Int
    public var checkpointData: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var error: String?
    public var retryCount: Int

    // Type-specific JSON payload (e.g. IMAP worker args). Optional, defaults nil.
    public var payload: String? = nil

    // Soonest the scheduler is allowed to re-claim this job after a failure.
    // Written by `JobQueue.fail` using `backoffDelay(for:)`. `claimNext` skips
    // `.pending` rows whose `nextAttemptAt` is still in the future, so a failing
    // job doesn't spin at tick rate while the underlying issue (network blip,
    // rate-limit) is still hot.
    public var nextAttemptAt: Date? = nil

    public init(type: JobType, priority: Int) {
        self.id = UUID()
        self.type = type
        self.status = .pending
        self.priority = priority
        self.createdAt = Date()
        self.retryCount = 0
    }
}
