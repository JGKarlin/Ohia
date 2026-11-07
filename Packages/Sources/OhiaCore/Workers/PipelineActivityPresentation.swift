import Foundation

public enum DreamingActivityMode: Equatable, Sendable {
    case hidden
    case labelOnly
    case gauge(fraction: Double)
}

public enum PipelineActivityStageStatus: Equatable, Sendable {
    case waiting
    case partial
    case processing
    case complete
}

public struct PipelineCorpusUIDWork: Equatable, Sendable {
    public let total: Int?
    public let remaining: Int?

    public init(total: Int?, remaining: Int?) {
        self.total = total
        self.remaining = remaining
    }
}

public enum PipelineHistoricalIMAPWork: Equatable, Sendable {
    case inactive
    case waiting
    case active
}

public enum PipelineSteadyIMAPActivity: Equatable, Sendable {
    case idle
    case syncing
    case polling
    case newArrival
}

public enum PipelineCorpusGaugePresentation: Equatable, Sendable {
    case none
    case mass(fraction: Double)
    case flow
    /// Existing Signal vocabulary owns the concrete steady-state gauge.
    case steady
}

public struct PipelineCorpusPhasePresentation: Equatable, Sendable {
    public let label: String
    public let gauge: PipelineCorpusGaugePresentation

    public init(label: String, gauge: PipelineCorpusGaugePresentation) {
        self.label = label
        self.gauge = gauge
    }
}

public enum PipelineActivityPresentation {
    public static let embeddingJobTypes: Set<String> = [
        "ingest",
        "embed",
        "reindexEmbeddings",
    ]

    public static let vectorCreationJobTypes: Set<String> = [
        "ingest",
        "embed",
        "entityEmbed",
        "entityRefresh",
    ]

    public static let placementJobTypes: Set<String> = [
        "ingest",
        "embed",
        "index",
        "frameBurst",
    ]

    public static let memoryDreamJobTypes: Set<String> = [
        "accountMemoryRefresh",
    ]

    public static func modelActivityLabel(
        forJobType rawValue: String,
        composerDraftStageRaw: String? = nil,
        replyPreparationStatusRaw: String? = nil
    ) -> String? {
        guard let type = JobType(rawValue: rawValue) else { return nil }
        switch type {
        case .summarize,
             .summarizeAttachments:
            return "summarizing"
        case .customCategoryDefinition:
            return "categorizing"
        case .resolveSemanticTags:
            return "resolving"
        case .accountMemoryRefresh:
            return "dreaming"
        case .prepareReplySources:
            switch replyPreparationStatusRaw {
            case nil,
                 ReplySourcePreparationStatus.compilingSources:
                return "compiling"
            case ReplySourcePreparationStatus.formulatingQuestions:
                return "questioning"
            case ReplySourcePreparationStatus.drafting:
                return "drafting"
            default:
                return nil
            }
        case .generateDraft:
            return composerDraftActivityLabel(stageRaw: composerDraftStageRaw)
        case .generateDraftingRules:
            return "learning"
        case .buildTrainingPairs:
            return "training"
        case .train:
            return "training"
        case .refine:
            return "refining"
        case .embed,
             .entityEmbed,
             .entityRefresh,
             .reindexEmbeddings:
            return "embedding"
        case .extractAttachments:
            return "extracting"
        case .extractVisualAttachments:
            return "captioning"
        default:
            return nil
        }
    }

    public static func composerDraftActivityLabel(stageRaw: String?) -> String {
        if stageRaw == DraftStage.collectingSources {
            return "compiling"
        }
        if stageRaw == DraftStage.evaluatingSources {
            return "questioning"
        }
        return "drafting"
    }

    public static func shouldShowModelActivityJob(
        jobType rawValue: String,
        status rawStatus: String,
        messageID: UUID? = nil,
        hasSummarizationBacklog: Bool = true,
        isPipelineWorkActive: Bool
    ) -> Bool {
        guard rawStatus == JobStatus.pending.rawValue
            || rawStatus == JobStatus.running.rawValue
        else { return false }
        guard modelActivityLabel(forJobType: rawValue) != nil else {
            return false
        }
        if rawValue == JobType.summarize.rawValue,
           messageID == nil,
           hasSummarizationBacklog == false {
            return false
        }
        if rawValue == JobType.summarizeAttachments.rawValue,
           rawStatus == JobStatus.pending.rawValue {
            return false
        }
        if rawValue == JobType.refine.rawValue,
           rawStatus == JobStatus.pending.rawValue {
            return false
        }
        if modelActivityJobHasDedicatedReadout(
            jobType: rawValue,
            isPipelineWorkActive: isPipelineWorkActive
        ) {
            return false
        }
        return true
    }

    public static func modelActivityJobHasDedicatedReadout(
        jobType rawValue: String,
        isPipelineWorkActive: Bool
    ) -> Bool {
        if rawValue == JobType.accountMemoryRefresh.rawValue
            || rawValue == JobType.train.rawValue {
            return true
        }
        if rawValue == JobType.summarize.rawValue
            || rawValue == JobType.summarizeAttachments.rawValue
            || rawValue == JobType.embed.rawValue
            || rawValue == JobType.entityEmbed.rawValue
            || rawValue == JobType.entityRefresh.rawValue
            || rawValue == JobType.reindexEmbeddings.rawValue {
            return isPipelineWorkActive
        }
        return false
    }

    public static func mailboxMutationIsActiveForActivity(
        status rawStatus: String,
        nextAttemptAfter: Date?,
        now: Date
    ) -> Bool {
        if rawStatus == MailboxMutationStatus.running.rawValue {
            return true
        }
        if rawStatus == MailboxMutationStatus.queued.rawValue {
            return nextAttemptAfter == nil || nextAttemptAfter! <= now
        }
        return false
    }

    /// Startup model warm-up surfaced by the activity strip when a model load
    /// or download outlasts the splash screen. Either on-device model — the
    /// generative (Qwen) or the retrieval (bge-m3) embedder — being busy raises
    /// this. Downloading (the longer, percentage-bearing phase) takes precedence
    /// over an in-memory load.
    public enum ModelWarmupActivity: Equatable, Sendable {
        case loading
        case downloading(fraction: Double)
    }

    /// Reduces the two on-device model load states into the single warm-up
    /// activity the activity strip should announce, or `nil` when neither model
    /// is loading or downloading. `ready`, `downloaded`, `paused`, `unavailable`,
    /// and `failed` all read as "nothing to announce here" — the strip falls
    /// back to its normal idle / pipeline readout. The generative model is
    /// preferred for the reported download fraction when — improbably — both
    /// models download at once.
    ///
    /// On a normal startup the generative model is already downloaded (its
    /// download is a precondition for completing onboarding), so it can only be
    /// `.loading` here; the retrieval embedder downloads lazily in the
    /// background and can legitimately be `.downloading` on the first launches.
    public static func modelWarmupActivity(
        generative: WorkerModelLoadState?,
        retrieval: WorkerModelLoadState?
    ) -> ModelWarmupActivity? {
        if case .downloading(let fraction) = generative {
            return .downloading(fraction: fraction)
        }
        if case .downloading(let fraction) = retrieval {
            return .downloading(fraction: fraction)
        }
        if case .loading = generative { return .loading }
        if case .loading = retrieval { return .loading }
        return nil
    }

    /// Animation duration for the Signal vocabulary's new-mail formation in the
    /// activity-strip gauge. Shared by `ActivityStripGauge` (animation cycle
    /// length) and `ActivityStripView` (event-stamping window) so a change to
    /// one stays in sync with the other.
    public static let activityNewMailEventDuration: TimeInterval = 3.0

    /// Animation duration for the Signal vocabulary's deletions-updated
    /// event-horizon animation in the activity-strip gauge.
    public static let activityDeletionUpdatedEventDuration: TimeInterval = 3.0

    /// Minimum visible window for explicit IMAP permanent-delete commands.
    public static let activityPermanentDeleteEventDuration: TimeInterval = activityDeletionUpdatedEventDuration

    /// Minimum visible window for short IMAP check activity. Manual starburst
    /// polls can complete in less than one render pass when no new mail exists,
    /// so the ActivityStrip latches the check signal briefly.
    public static let activityIMAPCheckEventDuration: TimeInterval = 3.0

    /// Compatibility alias for callers that only need the longest Signal
    /// transient window.
    public static let activityEventDuration: TimeInterval = activityDeletionUpdatedEventDuration

    public static func stageStatus(
        count: Int,
        total: Int?,
        isProcessing: Bool
    ) -> PipelineActivityStageStatus {
        if let total, total > 0, count >= total {
            return .complete
        }
        if isProcessing {
            return .processing
        }
        if total == nil, count > 0 {
            return .complete
        }
        if count > 0 {
            return .partial
        }
        return .waiting
    }

    public static func messageStageTotal(
        currentCount: Int,
        targetTotal: Int,
        isIngesting: Bool
    ) -> Int? {
        if targetTotal > 0 {
            return max(currentCount, targetTotal)
        }
        if isIngesting {
            return nil
        }
        return currentCount > 0 ? currentCount : nil
    }

    public static func messageStageCountTotal(
        currentCount: Int,
        messageCount: Int,
        stageTotal: Int?
    ) -> Int? {
        let normalizedCount = max(0, currentCount)
        if let stageTotal, stageTotal > 0 {
            return max(normalizedCount, stageTotal)
        }
        let denominator = max(normalizedCount, max(0, messageCount))
        return denominator > 0 ? denominator : nil
    }

    /// Single authority for the account/corpus phase shown by ActivityStrip.
    /// The persisted completion marker separates the one-time initial IMAP
    /// acquisition from later user-requested older-range backfill. A missing
    /// marker is authoritative even when a lower-priority sync or arrival is
    /// active; missing UID work is not guessed into a percentage.
    public static func corpusPhase(
        initialIMAPImportCompletedAt: Date?,
        uidWork: [PipelineCorpusUIDWork],
        historicalWork: PipelineHistoricalIMAPWork,
        steadyActivity: PipelineSteadyIMAPActivity,
        hasActionableError: Bool
    ) -> PipelineCorpusPhasePresentation {
        if hasActionableError {
            return PipelineCorpusPhasePresentation(label: "attention", gauge: .none)
        }

        if initialIMAPImportCompletedAt == nil {
            guard historicalWork == .active,
                  let fraction = initialImportFraction(uidWork)
            else {
                return PipelineCorpusPhasePresentation(label: "waiting", gauge: .none)
            }
            return PipelineCorpusPhasePresentation(
                label: "importing",
                gauge: .mass(fraction: fraction)
            )
        }

        switch historicalWork {
        case .active:
            return PipelineCorpusPhasePresentation(label: "backfilling", gauge: .flow)
        case .waiting:
            return PipelineCorpusPhasePresentation(label: "waiting", gauge: .none)
        case .inactive:
            break
        }

        switch steadyActivity {
        case .syncing:
            return PipelineCorpusPhasePresentation(label: "syncing", gauge: .steady)
        case .polling:
            return PipelineCorpusPhasePresentation(label: "polling", gauge: .steady)
        case .newArrival:
            return PipelineCorpusPhasePresentation(label: "forming", gauge: .steady)
        case .idle:
            return PipelineCorpusPhasePresentation(label: "waiting", gauge: .none)
        }
    }

    private static func initialImportFraction(
        _ uidWork: [PipelineCorpusUIDWork]
    ) -> Double? {
        guard uidWork.isEmpty == false else { return nil }
        var total = 0
        var remaining = 0
        for work in uidWork {
            guard let folderTotal = work.total,
                  let folderRemaining = work.remaining,
                  folderTotal >= 0,
                  folderRemaining >= 0
            else { return nil }
            total += folderTotal
            remaining += min(folderRemaining, folderTotal)
        }
        guard total > 0 else { return nil }
        return Double(total - remaining) / Double(total)
    }

    public static func workerRecentlyActive(
        _ worker: WorkerStatusSnapshot?,
        for jobTypes: Set<String>,
        now: Date = Date(),
        recentCompletionWindow: TimeInterval = 45
    ) -> Bool {
        guard let worker else { return false }
        let activeStates: Set<WorkerState> = [.busy, .running, .throttled]

        let heartbeatFresh = now.timeIntervalSince(worker.updatedAt) <= max(0, recentCompletionWindow)
        if heartbeatFresh,
           activeStates.contains(worker.state),
           let currentJobType = worker.currentJobType,
           jobTypes.contains(currentJobType) {
            return true
        }

        guard activeStates.contains(worker.state) else {
            return false
        }

        let cutoff = now.addingTimeInterval(-max(0, recentCompletionWindow))
        return worker.recentCompletions.contains { completion in
            jobTypes.contains(completion.jobType) && completion.completedAt >= cutoff
        }
    }

    /// Activity-strip presentation for the dreaming pass. During the initial
    /// backfill (`backfillCompleted == false` with a known denominator) it is a
    /// progress gauge; afterward it is a plain "dreaming" label.
    public static func dreamingActivityMode(
        isActive: Bool,
        backfillCompleted: Bool,
        processed: Int,
        eligible: Int
    ) -> DreamingActivityMode {
        guard isActive else { return .hidden }
        guard backfillCompleted == false, eligible > 0 else { return .labelOnly }
        let fraction = min(1.0, max(0.0, Double(processed) / Double(eligible)))
        return .gauge(fraction: fraction)
    }

    public static func dreamingReadoutShouldOverridePipeline(
        isPipelineWorkActive: Bool
    ) -> Bool {
        isPipelineWorkActive == false
    }
}

// MARK: - Pipeline flow indicator

extension PipelineActivityPresentation {
    /// The flow indicator claims "running at full speed", so it demands a
    /// stage that is actively processing — not merely a backlog that exists.
    /// A stalled shortfall (`.partial` without processing, `.waiting`)
    /// must never light a positive "running" signal.
    public static func stageIndicatesActiveWork(
        status: PipelineActivityStageStatus
    ) -> Bool {
        status == .processing
    }

    /// True when a stage has model work in flight OR still to do — actively
    /// processing, partway, or waiting on a known target. Lights the flow
    /// indicator's nucleus even while throttled (work exists, just held); an
    /// empty or fully-complete pipeline reads as idle.
    public static func stageIndicatesHeldWork(
        status: PipelineActivityStageStatus,
        total: Int?
    ) -> Bool {
        switch status {
        case .processing, .partial:
            return true
        case .waiting:
            return (total ?? 0) > 0
        case .complete:
            return false
        }
    }

    /// The pipeline's *internal* flow control — clamping one model family so
    /// the other can run flat-out — is self-balancing at maximum sustainable
    /// speed, not a brake. Only these reasons qualify; everything else
    /// (user activity, battery, thermal, memory, user-initiated priority)
    /// is an external brake.
    public static func throttleReasonIsInternalFlowControl(
        _ rawValue: String
    ) -> Bool {
        rawValue == "qwen_active" || rawValue == "qwen_interpretation_backpressure"
    }

    /// True when the pipeline is running unthrottled: work is actively
    /// moving AND no worker is externally braked. A worker throttled purely
    /// by internal flow control still counts as running; a throttled worker
    /// with no stated reason cannot be classified, so it counts as braked
    /// rather than letting the indicator overclaim.
    public static func showsPipelineFlowIndicator(
        throttles: [WorkerThrottleSnapshot],
        hasActiveWork: Bool
    ) -> Bool {
        guard hasActiveWork else { return false }
        return isExternallyThrottled(throttles: throttles) == false
    }

    /// True when a worker is held by an EXTERNAL brake (user activity, battery,
    /// thermal, memory, user-initiated priority) rather than the pipeline's own
    /// internal flow control. A throttled worker with no stated reason cannot
    /// be classified, so it counts as externally braked.
    public static func isExternallyThrottled(
        throttles: [WorkerThrottleSnapshot]
    ) -> Bool {
        throttles.contains { snapshot in
            guard snapshot.isThrottled else { return false }
            guard snapshot.reasons.isEmpty == false else { return true }
            return snapshot.reasons.contains { reason in
                throttleReasonIsInternalFlowControl(reason) == false
            }
        }
    }

    /// Human-readable label for a `ResourceThrottleReason` raw value. The
    /// raw strings cross the worker status file as plain strings, so the
    /// mapping is string-keyed here; unknown values fall back to the raw
    /// value with underscores opened up.
    public static func throttleReasonLabel(_ rawValue: String) -> String {
        switch rawValue {
        case "user_active": "user activity"
        case "ohia_foreground": "Ohia frontmost"
        case "constellation_active": "Constellation interaction"
        case "catch_up_disabled": "catch-up disabled"
        case "not_on_ac_power": "on battery power"
        case "low_power_mode": "Low Power Mode"
        case "memory_warning": "memory pressure"
        case "memory_critical": "critical memory pressure"
        case "thermal_serious": "elevated thermal state"
        case "thermal_critical": "critical thermal state"
        case "activity_snapshot_stale": "stale activity signal"
        case "worker_memory_guard": "model residency guard"
        case "qwen_active": "generative model active"
        case "interactive_qwen_generation": "interactive generation"
        case "qwen_interpretation_backpressure": "interpretation backpressure"
        default: rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }
}
