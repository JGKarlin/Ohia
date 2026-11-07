import Foundation
import SwiftData
import OhiaCore

/// Idempotent enqueue of `.clusterDetect` for a specific frame.
///
/// Called from `FrameBurstWorker.run` after a burst commits frame-layout
/// rows, and from the scheduler when enabled Meaning needs a pass; only a
/// frame with a cluster runner (`isRunnable`) is enqueued. Skips the enqueue
/// if the queue already holds an active (pending or running) `.clusterDetect`
/// whose payload targets the same frame, so repeated bursts and demand checks
/// never stack duplicate Meaning passes.
///
/// Mirrors the IMAP-seeder pattern in
/// `BackgroundScheduler.ensurePipelineJobsExist`: decode active cluster jobs'
/// payloads, compare fields, skip on match.
public enum ClusterDetectSeeder {
    public static let priority = 6

    /// Only Meaning membership has a cluster runner: the scheduler claims
    /// `.clusterDetect` solely for the Meaning lens. A job for any other frame
    /// would sit in the queue forever.
    public static func isRunnable(_ frame: FrameKey) -> Bool {
        frame.spatialLens == FrameKey.meaning.spatialLens
    }

    /// Removes pending `.clusterDetect` jobs nothing can claim: a frame without
    /// a cluster runner, or a payload that does not decode (the claim path
    /// decodes every payload, and `seedIfNeeded` treats an undecodable active
    /// job as blocking). Running jobs are left to finish. Returns the number
    /// removed.
    @MainActor
    @discardableResult
    public static func discardUnrunnable(context: ModelContext) throws -> Int {
        let decoder = JSONDecoder()
        let pending = try JobFetch.jobs(
            type: .clusterDetect,
            statuses: [.pending],
            context: context,
            sort: false
        )
        var removed = 0
        for job in pending {
            if let data = job.payload?.data(using: .utf8),
               let payload = try? decoder.decode(ClusterDetectPayload.self, from: data),
               isRunnable(payload.frame) {
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

    @MainActor
    public static func seedIfNeeded(
        frame: FrameKey,
        context: ModelContext,
        promoteDeferred: Bool = true
    ) throws {
        guard isRunnable(frame) else { return }
        let now = Date()
        let targetClusters = ClusterDetectPayload.stableMeaningTargetClusters
        let active = try JobFetch.jobs(
            type: .clusterDetect,
            statuses: [.pending, .running],
            context: context
        )
        var removedStalePending = false
        for job in active {
            guard let data = job.payload?.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ClusterDetectPayload.self, from: data) else {
                // Undecodable active job — treat as blocking. The ghost will eventually
                // fail out via retryCount; we don't pile duplicates on top of it.
                return
            }
            guard payload.frame == frame else { continue }
            guard payload.semanticTargetClusters == targetClusters else {
                if job.status == .running {
                    if removedStalePending { try context.save() }
                    return
                }
                context.delete(job)
                removedStalePending = true
                continue
            }
            guard job.status != .running else {
                if removedStalePending { try context.save() }
                return
            }
            if let nextAttemptAt = job.nextAttemptAt, nextAttemptAt > now {
                guard promoteDeferred else {
                    if removedStalePending { try context.save() }
                    return
                }
                job.priority = Self.priority
                job.nextAttemptAt = nil
                try context.save()
            }
            if removedStalePending {
                try context.save()
            }
            return
        }
        if removedStalePending {
            try context.save()
        }

        let payload = ClusterDetectPayload(frame: frame, semanticTargetClusters: targetClusters)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        try JobQueue().enqueue(
            type: .clusterDetect,
            priority: Self.priority,
            payload: json,
            context: context
        )
    }
}
