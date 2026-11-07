import Foundation
import SwiftData
import OhiaCore

public extension JobType {
    var workerRole: WorkerRole? {
        switch self {
        case .imapLiveInbound:
            return nil

        case .ingest,
             .parse,
             .triage,
             .embed,
             .resolveSemanticTags,
             .index,
             .refine,
             .frameBurst,
             .clusterDetect,
             .imapBackfill,
             .imapPollFolder,
             .imapDeletionWatch,
             .entityPromote,
             .entityEmbed,
             .entityRefresh,
             .pendingDeletionReaper,
             .reconcileVectorIndex,
             .reindexEmbeddings,
             .extractAttachments,
             .extractVisualAttachments,
             .extractCaptureMetadata,
             .translationGlossaryRefresh:
            return .bge

        case .buildTrainingPairs,
             .train,
             .summarize,
             .summarizeAttachments,
             .accountMemoryRefresh,
             .customCategoryDefinition,
             .generateDraft,
             .prepareReplySources,
             .generateDraftingRules,
             .distillStyleRegisters:
            return .qwen

        case .categoryLifecycle,
             .sendOutbox,
             .syncComposerDrafts,
             .mailboxMutation,
             .withheldAutoDelete:
            return .bge
        }
    }

    func isOwned(by workerRole: WorkerRole?) -> Bool {
        guard let workerRole else { return true }
        return self.workerRole == workerRole
    }
}

public extension JobQueue {
    @MainActor
    func claimNext(
        maxPriority: Int,
        context: ModelContext,
        now: Date = Date(),
        excluding excludedTypes: Set<JobType> = [],
        workerRole: WorkerRole
    ) throws -> Job? {
        let candidate = try JobFetch.claimablePendingJobs(
            maxPriority: maxPriority,
            now: now,
            excludedTypes: excludedTypes,
            ownedTypes: workerRole.jobTypes,
            limit: 1,
            context: context
        ).first

        guard let job = candidate else { return nil }
        job.status = .running
        job.startedAt = now
        try context.save()
        return job
    }

    @MainActor
    func claimSpecificType(
        _ type: JobType,
        context: ModelContext,
        now: Date = Date(),
        workerRole: WorkerRole
    ) throws -> Job? {
        guard type.isOwned(by: workerRole) else { return nil }
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
    func claimSpecificType(
        _ type: JobType,
        limit: Int,
        context: ModelContext,
        now: Date = Date(),
        workerRole: WorkerRole
    ) throws -> [Job] {
        guard limit > 0, type.isOwned(by: workerRole) else { return [] }
        let jobs = try JobFetch.claimablePendingJobs(
            type: type,
            now: now,
            limit: limit,
            context: context
        )
        guard jobs.isEmpty == false else { return [] }
        for job in jobs {
            job.status = .running
            job.startedAt = now
        }
        try context.save()
        return jobs
    }
}

private extension WorkerRole {
    var jobTypes: Set<JobType> {
        Set(JobType.allCases.filter { $0.workerRole == self })
    }
}
