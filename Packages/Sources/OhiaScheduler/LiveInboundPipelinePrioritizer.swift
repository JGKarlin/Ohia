import Foundation
import SwiftData
import OhiaCore
import OhiaML

enum LiveInboundPipelinePrioritizer {
    static let liveEmbedPriority = 1
    static let liveStagePriority = 2
    static let liveWatchdogThreshold: TimeInterval = 20

    @MainActor
    static func seed(
        messageIDs: [UUID],
        observedAt: Date = Date(),
        context: ModelContext
    ) throws {
        try seedPriorityJobs(
            messageIDs: messageIDs,
            liveObservedAt: observedAt,
            context: context
        )
    }

    @MainActor
    static func seedForegroundMessage(
        messageIDs: [UUID],
        context: ModelContext
    ) throws {
        try seedPriorityJobs(
            messageIDs: messageIDs,
            liveObservedAt: nil,
            context: context
        )
    }

    @MainActor
    private static func seedPriorityJobs(
        messageIDs: [UUID],
        liveObservedAt: Date?,
        context: ModelContext
    ) throws {
        let ids = uniquePreservingOrder(messageIDs)
        guard !ids.isEmpty else { return }

        var jobs = try JobFetch.unfinished(context: context)
        var changed = false

        if let liveObservedAt {
            changed = try markLiveDetected(
                messageIDs: ids,
                observedAt: liveObservedAt,
                context: context
            ) || changed
        }

        for messageID in ids {
            changed = upsertSpecificJob(
                type: .embed,
                messageID: messageID,
                priority: liveEmbedPriority,
                jobs: &jobs,
                context: context
            ) || changed
            changed = upsertSpecificJob(
                type: .summarize,
                messageID: messageID,
                priority: liveStagePriority,
                jobs: &jobs,
                context: context
            ) || changed
        }

        if changed {
            try context.save()
        }
    }

    @MainActor
    @discardableResult
    static func nudgeStalledLiveMessages(
        context: ModelContext,
        now: Date = Date(),
        threshold: TimeInterval = liveWatchdogThreshold
    ) throws -> Int {
        let cutoff = now.addingTimeInterval(-threshold)
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.liveDetectedAt != nil && message.placedAt == nil
                    && message.trashedAt == nil
            }
        )
        let stalled = try context.fetch(descriptor).filter { message in
            guard let detectedAt = message.liveDetectedAt else { return false }
            return detectedAt <= cutoff
        }
        guard !stalled.isEmpty else { return 0 }

        var jobs = try JobFetch.unfinished(context: context)
        var changed = false
        var nudged = 0

        for message in stalled {
            let messageID = message.id
            let stage = liveStage(for: message)
            let didChange: Bool
            switch stage {
            case .needsEmbedding:
                didChange = upsertSpecificJob(
                    type: .embed,
                    messageID: messageID,
                    priority: liveEmbedPriority,
                    jobs: &jobs,
                    context: context
                )
            case .needsPlacement:
                // Reply preparation intentionally holds first presentation;
                // an index job cannot advance it until readiness publishes.
                guard !message.blocksFirstPresentationForReplyPreparation(at: now) else { continue }
                didChange = upsertSpecificJob(
                    type: .index,
                    messageID: messageID,
                    priority: liveEmbedPriority,
                    jobs: &jobs,
                    context: context
                )
            case .needsInterpretation:
                didChange = upsertSpecificJob(
                    type: .summarize,
                    messageID: messageID,
                    priority: liveStagePriority,
                    jobs: &jobs,
                    context: context
                )
            }
            if didChange {
                changed = true
                nudged += 1
                print("[Ohia] live inbound watchdog nudged \(messageID.uuidString) at \(stage.rawValue)")
            }
        }

        if changed {
            try context.save()
        }
        return nudged
    }

    @MainActor
    static func hasPendingLiveEmbed(context: ModelContext) throws -> Bool {
        try JobFetch.hasPendingJob(
            type: .embed,
            maxPriority: liveEmbedPriority,
            requiresMessageID: true,
            context: context
        )
    }

    @MainActor
    static func hasPendingForegroundInterpretation(context: ModelContext) throws -> Bool {
        try JobFetch.hasPendingJob(
            type: .summarize,
            maxPriority: liveStagePriority,
            requiresMessageID: true,
            context: context
        )
    }

    /// How long after arrival a new email's reply preparation may run through
    /// the foreground throttle. The email itself appears after at most
    /// `Message.replyPreparationPresentationHold`; its preparation keeps the
    /// lane a while longer so it is not cut off the moment the email appears.
    static let arrivalPreparationWindow: TimeInterval = 600

    /// A newly arrived email's pending or running reply preparation.
    /// `stillHidden` while the email waits to appear with its reply: only
    /// then is a pending one claimed through the foreground throttle; once the
    /// email shows, a running one finishes and a pending one waits for idle or
    /// for the Composer.
    struct ArrivalPreparationJob {
        let job: Job
        let stillHidden: Bool
    }

    /// Pending or running reply preparations of newly arrived mail. Only mail
    /// that arrived within `arrivalPreparationWindow` qualifies, so the lookup
    /// reads a short window of the live-arrival index and then only those
    /// messages' jobs.
    @MainActor
    static func arrivalReplyPreparationJobs(
        context: ModelContext,
        now: Date = Date()
    ) throws -> [ArrivalPreparationJob] {
        let since = now.addingTimeInterval(-arrivalPreparationWindow)
        let recent = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                message.liveDetectedAt != nil && message.liveDetectedAt! > since
            }
        )
        let awaiting = try context.fetch(recent).filter { awaitsArrivalPreparation($0, at: now) }
        var jobs: [ArrivalPreparationJob] = []
        for message in awaiting {
            let messageID = message.id
            let stillHidden = message.replyPreparationPresentationDeadline.map { now < $0 } ?? false
            jobs += try context.fetch(FetchDescriptor<Job>(
                predicate: #Predicate<Job> { $0.messageId == messageID }
            )).filter {
                $0.type == .prepareReplySources
                    && ($0.status == .pending || $0.status == .running)
                    && $0.priority <= ReplySourcePreparationCoordinator.backgroundPriority
            }.map { ArrivalPreparationJob(job: $0, stillHidden: stillHidden) }
        }
        return jobs.sorted { ($0.job.priority, $0.job.createdAt) < ($1.job.priority, $1.job.createdAt) }
    }

    /// An arrival preparation that may be claimed now.
    static func isClaimable(_ arrival: ArrivalPreparationJob, now: Date) -> Bool {
        arrival.stillHidden && arrival.job.status == .pending && (arrival.job.nextAttemptAt ?? .distantPast) <= now
    }

    /// A newly arrived email's first interpretation that may be claimed now.
    @MainActor
    static func hasRunnableLiveInterpretation(context: ModelContext, now: Date = Date()) throws -> Bool {
        try JobFetch.claimablePendingJobs(type: .summarize, now: now, limit: 1, context: context).contains {
            $0.priority <= liveStagePriority && $0.messageId != nil
        }
    }

    /// A newly arrived Needs Reply email whose reply is not prepared yet.
    static func awaitsArrivalPreparation(_ message: Message, at now: Date = Date()) -> Bool {
        guard let detectedAt = message.liveDetectedAt, !message.isSentByUser, message.trashedAt == nil,
              message.replyPreparationRequiredAt != nil, message.replyPreparationReadyAt == nil else {
            return false
        }
        return now < detectedAt.addingTimeInterval(arrivalPreparationWindow)
    }

    private static func upsertSpecificJob(
        type: JobType,
        messageID: UUID,
        priority: Int,
        jobs: inout [Job],
        context: ModelContext
    ) -> Bool {
        if jobs.contains(where: {
            $0.type == type && $0.messageId == messageID && $0.status == .running
        }) {
            return false
        }

        if let job = jobs.first(where: {
            $0.type == type
                && $0.messageId == messageID
                && ($0.status == .pending || $0.status == .failed)
        }) {
            var changed = false
            if job.status != .pending {
                job.status = .pending
                changed = true
            }
            if job.priority > priority {
                job.priority = priority
                changed = true
            }
            if job.startedAt != nil {
                job.startedAt = nil
                changed = true
            }
            if job.completedAt != nil {
                job.completedAt = nil
                changed = true
            }
            if job.nextAttemptAt != nil {
                job.nextAttemptAt = nil
                changed = true
            }
            if job.error != nil {
                job.error = nil
                changed = true
            }
            if job.retryCount != 0 {
                job.retryCount = 0
                changed = true
            }
            return changed
        }

        let job = Job(type: type, priority: priority)
        job.messageId = messageID
        context.insert(job)
        jobs.append(job)
        return true
    }

    @MainActor
    private static func markLiveDetected(
        messageIDs: [UUID],
        observedAt: Date,
        context: ModelContext
    ) throws -> Bool {
        var changed = false
        for messageID in messageIDs {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { message in
                    message.id == messageID
                }
            )
            descriptor.fetchLimit = 1
            guard let message = try context.fetch(descriptor).first else { continue }
            if message.liveDetectedAt.map({ $0 > observedAt }) ?? true {
                message.liveDetectedAt = observedAt
                changed = true
            }
        }
        return changed
    }

    private static func uniquePreservingOrder(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var out: [UUID] = []
        out.reserveCapacity(ids.count)
        for id in ids where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }

    private enum LiveStage: String {
        case needsInterpretation = "interpretation"
        case needsEmbedding = "embedding"
        case needsPlacement = "placement"
    }

    private static func liveStage(for message: Message) -> LiveStage {
        if message.embeddingStatus != .completed {
            return .needsEmbedding
        }
        if message.placedAt == nil {
            return .needsPlacement
        }
        if !hasCompleteInterpretation(message.analysis) {
            return .needsInterpretation
        }
        return .needsPlacement
    }

    static func hasCompleteInterpretation(_ analysis: MessageAnalysis?) -> Bool {
        MailClassificationJSON.isComplete(analysis?.mailClassificationJSON)
            && hasValidTriageVerdictJSON(analysis?.triageVerdictJSON)
    }

    private static func hasValidTriageVerdictJSON(_ value: String?) -> Bool {
        TriageVerdictJSON.hasRequiredBooleanFields(value)
    }
}
