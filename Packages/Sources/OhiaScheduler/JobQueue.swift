import Foundation
import SwiftData
import OhiaCore

public final class JobQueue: Sendable {

    public static let maxRetries = 3

    /// Base delay for the first retry. Doubled per additional retry; see
    /// `backoffDelay(for:)`. Public so callers (tests, the Developer tab)
    /// can display the same numbers the scheduler uses.
    public static let backoffBaseSeconds: TimeInterval = 30

    /// Exponential backoff with ±10% jitter. `retryCount` is the
    /// post-increment value, so the first backoff (retryCount=1) is
    /// `backoffBaseSeconds`, the second (retryCount=2) is `2 *
    /// backoffBaseSeconds`, and so on. Jitter prevents thundering-herd
    /// reclaims when a batch of jobs fails on the same network blip.
    public static func backoffDelay(for retryCount: Int, jitter: Double = Double.random(in: -0.1...0.1)) -> TimeInterval {
        let exponent = max(0, retryCount - 1)
        let base = backoffBaseSeconds * pow(2, Double(exponent))
        return base * (1.0 + jitter)
    }

    public init() {}

    // MARK: - Enqueue

    /// Insert a pending job into `context` without saving. Use when the caller
    /// needs the job to commit atomically with other SwiftData changes.
    @discardableResult
    @MainActor
    public func stage(
        type: JobType,
        priority: Int,
        messageId: UUID? = nil,
        payload: String? = nil,
        context: ModelContext
    ) -> Job {
        let job = Job(type: type, priority: priority)
        job.messageId = messageId
        job.payload = payload
        context.insert(job)
        return job
    }

    @MainActor
    public func enqueue(
        type: JobType,
        priority: Int,
        messageId: UUID? = nil,
        payload: String? = nil,
        context: ModelContext
    ) throws {
        stage(
            type: type,
            priority: priority,
            messageId: messageId,
            payload: payload,
            context: context
        )
        try context.save()
    }

    /// Enqueue a job that shouldn't be claimable until `nextAttemptAt`. Used
    /// by self-pacing worker types (`.refine`) to space out re-enqueues
    /// without blocking the tick loop on `Task.sleep`. Mirrors the shape of
    /// `enqueue` — same `priority` / `payload` semantics — plus a forced
    /// `nextAttemptAt` that `claimNext` respects via the same gate used for
    /// backoff after failure (see `claimNext` + `fail`).
    @MainActor
    public func enqueueDeferred(
        type: JobType,
        priority: Int,
        messageId: UUID? = nil,
        payload: String? = nil,
        nextAttemptAt: Date,
        context: ModelContext
    ) throws {
        let job = Job(type: type, priority: priority)
        job.messageId = messageId
        job.payload = payload
        job.nextAttemptAt = nextAttemptAt
        context.insert(job)
        try context.save()
    }

    /// Collapse duplicate active Composer draft-sync jobs.
    ///
    /// `.syncComposerDrafts` represents "drain the current backlog" rather
    /// than one unit of durable work. If many pending rows already exist,
    /// keeping all of them only forces the scheduler to claim no-op jobs one by
    /// one ahead of lower-priority pipeline work. Do not generalize this to
    /// per-message or payload-carrying job types; those rows are durable work.
    @MainActor
    @discardableResult
    func collapseRedundantComposerDraftSyncJobs(context: ModelContext) throws -> Int {
        let active = try JobFetch.jobs(
            type: .syncComposerDrafts,
            statuses: [.pending, .running],
            context: context,
            sort: true
        )
        guard active.count > 1 else { return 0 }

        let hasRunning = active.contains { $0.status == .running }
        var keptPending = false
        var removed = 0
        for job in active {
            if job.status == .running {
                continue
            }
            if !hasRunning, !keptPending {
                keptPending = true
                continue
            }
            context.delete(job)
            removed += 1
        }
        if removed > 0 {
            try context.save()
        }
        return removed
    }

    // MARK: - Claim

    /// Returns the highest-priority pending job whose priority number is ≤
    /// `maxPriority` (lower number = higher priority), marking it `.running`.
    /// Rows whose `nextAttemptAt` is still in the future (from a recent
    /// failure) are skipped. `now` is injectable so tests can advance time
    /// without sleeping.
    @MainActor
    public func claimNext(
        maxPriority: Int,
        context: ModelContext,
        now: Date = Date(),
        excluding excludedTypes: Set<JobType> = []
    ) throws -> Job? {
        let candidate = try JobFetch.claimablePendingJobs(
            maxPriority: maxPriority,
            now: now,
            excludedTypes: excludedTypes,
            limit: 1,
            context: context
        ).first

        guard let job = candidate else { return nil }
        job.status = .running
        job.startedAt = now
        try context.save()
        return job
    }

    /// Claim a pending job of the given type if one exists, marking it `.running`.
    /// Used by force-run paths that need to bypass the normal priority-first
    /// claim order — e.g. "Train Now" must reach the priority-8 `.train` job
    /// even when lower-numeric-priority types have a large actionable backlog.
    @MainActor
    public func claimSpecificType(_ type: JobType, context: ModelContext, now: Date = Date()) throws -> Job? {
        guard let job = try JobFetch.claimablePendingJobs(
            type: type,
            now: now,
            limit: 1,
            context: context
        ).first else { return nil }
        job.status = .running
        job.startedAt = now
        try context.save()
        return job
    }

    @MainActor
    public func claimSpecificType(
        _ type: JobType,
        limit: Int,
        context: ModelContext,
        now: Date = Date()
    ) throws -> [Job] {
        guard limit > 0 else { return [] }
        let jobs = try JobFetch.claimablePendingJobs(
            type: type,
            now: now,
            limit: limit,
            context: context
        )
        guard !jobs.isEmpty else { return [] }
        for job in jobs {
            job.status = .running
            job.startedAt = now
        }
        try context.save()
        return jobs
    }

    // MARK: - Complete

    @MainActor
    public func complete(job: Job, context: ModelContext) throws {
        try preserveDurablyPromotedPriorities(for: [job], context: context)
        job.status = .completed
        job.completedAt = Date()
        job.error = nil
        job.nextAttemptAt = nil
        job.retryCount = 0
        try context.save()
    }

    @MainActor
    public func complete(jobs: [Job], context: ModelContext) throws {
        guard !jobs.isEmpty else { return }
        try preserveDurablyPromotedPriorities(for: jobs, context: context)
        let completedAt = Date()
        for job in jobs {
            job.status = .completed
            job.completedAt = completedAt
            job.error = nil
            job.nextAttemptAt = nil
            job.retryCount = 0
        }
        try context.save()
    }

    /// Composer can promote an in-flight preparation from the app process while
    /// the worker still holds the priority it claimed. SwiftData saves through
    /// that registered worker model would otherwise restore the stale value
    /// when completion fields change. Merge the durable value immediately before
    /// saving; lower numbers are more urgent and must never be demoted here.
    @MainActor
    private func preserveDurablyPromotedPriorities(
        for jobs: [Job],
        context: ModelContext
    ) throws {
        let preparations = jobs.filter { $0.type == .prepareReplySources }
        guard preparations.isEmpty == false else { return }

        let durableContext = ModelContext(context.container)
        for job in preparations {
            let jobID = job.id
            var descriptor = FetchDescriptor<Job>(
                predicate: #Predicate<Job> { $0.id == jobID }
            )
            descriptor.fetchLimit = 1
            if let durablePriority = try durableContext.fetch(descriptor).first?.priority {
                job.priority = min(job.priority, durablePriority)
            }
        }
    }

    // MARK: - Fail / Retry

    @MainActor
    public func fail(job: Job, error: String, context: ModelContext, now: Date = Date()) throws {
        try preserveDurablyPromotedPriorities(for: [job], context: context)
        job.error = error
        job.retryCount += 1
        if job.retryCount >= Self.maxRetries {
            job.status = .failed
            job.completedAt = now
            job.nextAttemptAt = nil
        } else {
            job.status = .pending
            job.startedAt = nil
            job.nextAttemptAt = now.addingTimeInterval(Self.backoffDelay(for: job.retryCount))
        }
        try context.save()
    }

    @MainActor
    public func fail(jobs: [Job], error: String, context: ModelContext, now: Date = Date()) throws {
        guard !jobs.isEmpty else { return }
        try preserveDurablyPromotedPriorities(for: jobs, context: context)
        for job in jobs {
            job.error = error
            job.retryCount += 1
            if job.retryCount >= Self.maxRetries {
                job.status = .failed
                job.completedAt = now
                job.nextAttemptAt = nil
            } else {
                job.status = .pending
                job.startedAt = nil
                job.nextAttemptAt = now.addingTimeInterval(Self.backoffDelay(for: job.retryCount))
            }
        }
        try context.save()
    }

    /// Mark a job as terminally failed without burning the remaining retry
    /// budget. Used when the error is structurally permanent (TLS handshake,
    /// auth, protocol violation, invalid payload) — re-running the same job
    /// against the same inputs will produce the same error, so the 3x retry
    /// loop wastes scheduler ticks and floods the Pipeline Failures dev panel.
    /// Recovery still happens through the normal re-enqueue paths
    /// (e.g. .imapPollFolder cadence, .imapBackfill state-driven seeding) on
    /// the next scheduler tick once underlying conditions change.
    @MainActor
    public func failPermanently(job: Job, error: String, context: ModelContext, now: Date = Date()) throws {
        try preserveDurablyPromotedPriorities(for: [job], context: context)
        job.error = error
        job.retryCount += 1
        job.status = .failed
        job.completedAt = now
        job.startedAt = nil
        job.nextAttemptAt = nil
        try context.save()
    }

    /// Flip `.failed` rows back to `.pending` so the scheduler retries them.
    /// Clears `retryCount`, `error`, `nextAttemptAt`, `completedAt`. Used by
    /// the Developer tab's "Retry Failed" button. Returns how many rows moved.
    @MainActor
    @discardableResult
    public func retryAllFailed(context: ModelContext) throws -> Int {
        let failed = try JobFetch.failed(context: context)
        for job in failed {
            job.status = .pending
            job.retryCount = 0
            job.error = nil
            job.nextAttemptAt = nil
            job.completedAt = nil
            job.startedAt = nil
        }
        if !failed.isEmpty { try context.save() }
        return failed.count
    }

    /// Delete all `.failed` rows. Used by the Developer tab's "Clear Failures"
    /// button when the user just wants the noise gone.
    @MainActor
    @discardableResult
    public func clearFailed(context: ModelContext) throws -> Int {
        let failed = try JobFetch.failed(context: context)
        stampClearedIMAPFailureCooldowns(failed, context: context)
        for job in failed { context.delete(job) }
        if !failed.isEmpty { try context.save() }
        return failed.count
    }

    @MainActor
    private func stampClearedIMAPFailureCooldowns(_ jobs: [Job], context: ModelContext) {
        let now = Date()
        for job in jobs {
            guard let payload = job.payload?.data(using: .utf8) else { continue }
            switch job.type {
            case .imapPollFolder:
                guard let decoded = try? JSONDecoder().decode(IMAPPollFolderWorker.Payload.self, from: payload) else {
                    continue
                }
                stampIMAPPollFailure(
                    accountID: decoded.accountID,
                    folderName: decoded.folderName,
                    now: now,
                    context: context
                )
            case .imapDeletionWatch:
                guard let decoded = try? JSONDecoder().decode(IMAPDeletionWatchWorker.Payload.self, from: payload) else {
                    continue
                }
                stampIMAPDeletionWatchFailure(
                    accountID: decoded.accountID,
                    folderName: decoded.folderName,
                    now: now,
                    context: context
                )
            default:
                continue
            }
        }
    }

    @MainActor
    private func stampIMAPPollFailure(
        accountID: UUID,
        folderName: String,
        now: Date,
        context: ModelContext
    ) {
        let descriptor = FetchDescriptor<IMAPFolderState>(
            predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID && state.folderName == folderName
            }
        )
        guard let state = try? context.fetch(descriptor).first else { return }
        state.lastPollFailureAt = now
        state.updatedAt = now
    }

    @MainActor
    private func stampIMAPDeletionWatchFailure(
        accountID: UUID,
        folderName: String,
        now: Date,
        context: ModelContext
    ) {
        let descriptor = FetchDescriptor<IMAPFolderState>(
            predicate: #Predicate<IMAPFolderState> { state in
                state.account?.id == accountID && state.folderName == folderName
            }
        )
        guard let state = try? context.fetch(descriptor).first else { return }
        state.lastDeletionWatchFailureAt = now
        state.updatedAt = now
    }

    // MARK: - Count

    @MainActor
    public func pendingCount(context: ModelContext) throws -> Int {
        try JobFetch.pendingCount(context: context)
    }

    // MARK: - Cleanup

    @MainActor
    public func cleanup(olderThan date: Date, context: ModelContext) throws {
        let all = try JobFetch.completedOrFailed(olderThan: date, context: context)
        for job in all { context.delete(job) }
        try context.save()
    }
}
