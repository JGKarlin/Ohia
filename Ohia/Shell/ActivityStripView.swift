import AppKit
import Foundation
import SwiftUI
import SwiftData
import SQLite3
import OhiaCore
import OhiaMail
import OhiaML
import OhiaScheduler

/// A separate presentation keeps help visible even inside Composer's clipped footer.
/// Keep this modifier outside changing readout identities so live status updates
/// replace the text without resetting the pointer's hover state.
private struct ActivityStripHoverHelp: ViewModifier {
    let text: String
    let presentation: ActivityStripPopoverState
    /// Most sources present help from their own popover so the arrow points
    /// at the hovered element. The state label turns this off: its help shares
    /// the popover that also opens the Activity Log, so a click can swap the
    /// help for the log in place.
    var anchorsOwnPopover = true
    var attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds)
    @State private var owner = UUID()

    @ViewBuilder
    func body(content: Content) -> some View {
        let tracked = content
            .contentShape(Rectangle())
            .onHover { hovering in
                presentation.hoverSource(
                    owner,
                    text: text,
                    hovering: hovering,
                    anchorsOwnPopover: anchorsOwnPopover
                )
            }
            .onChange(of: text) { _, value in
                if presentation.hoverOwner == owner { presentation.detail = value }
            }
            .onDisappear {
                if presentation.hoverOwner == owner {
                    presentation.hoverOwner = nil
                    presentation.detail = nil
                }
            }
            .accessibilityHint(text)
        if anchorsOwnPopover {
            tracked.popover(
                isPresented: Binding(
                    get: { presentation.isShowingHelp(anchoredAt: owner) },
                    // Only a dismissal of this source's own help clears the
                    // state; a stale callback must not close another source's.
                    set: { if !$0, presentation.isShowingHelp(anchoredAt: owner) { presentation.dismiss() } }
                ),
                attachmentAnchor: attachmentAnchor,
                arrowEdge: .bottom
            ) {
                ActivityStripHelpPopoverText(presentation: presentation)
            }
        } else {
            tracked
        }
    }
}

/// Hover help inside an activity strip popover. Hovering the popup keeps it
/// open across the gap from its source.
private struct ActivityStripHelpPopoverText: View {
    let presentation: ActivityStripPopoverState

    private var contentWidth: CGFloat {
        let maximumContentWidth: CGFloat = 316 // 340-point cap minus 12-point padding on each side.
        let bounds = NSAttributedString(
            string: presentation.detail ?? "",
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).boundingRect(
            with: CGSize(width: maximumContentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return min(maximumContentWidth, max(1, ceil(bounds.width)))
    }

    var body: some View {
        Text(presentation.detail ?? "")
            .font(.system(size: 12))
            .foregroundStyle(OhiaColors.textPrimary)
            .lineLimit(nil)
            .frame(width: contentWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .fixedSize(horizontal: true, vertical: true)
            .onHover { presentation.hoverPopup($0) }
    }
}

struct PipelineStage {
    let label: String
    let count: Int
    /// Semantic denominator for status/progress only. `countTotal` may use a
    /// display denominator that must not mark unknown-target ingest complete.
    let total: Int?
    let countTotal: Int?
    let unit: String
    let color: Color
    let status: PipelineActivityStageStatus
    let countDisplay: PipelineStageCountDisplay
}

enum PipelineStageCountDisplay: Equatable {
    case countOnly
    case fraction
}

enum ActivityStripMode: Equatable {
    case constellation
    case composer
}

struct ActivityStripComposerTarget: Equatable {
    let messageID: UUID?
    let isActive: Bool

    static let inactive = ActivityStripComposerTarget(
        messageID: nil,
        isActive: false
    )
}

private struct ActivityStripComposerTargetKey: EnvironmentKey {
    static let defaultValue = ActivityStripComposerTarget.inactive
}

extension EnvironmentValues {
    var activityStripComposerTarget: ActivityStripComposerTarget {
        get { self[ActivityStripComposerTargetKey.self] }
        set { self[ActivityStripComposerTargetKey.self] = newValue }
    }
}

nonisolated enum ActivityStripCorpusGaugeMode {
    static func mode(for presentation: PipelineCorpusGaugePresentation) -> GaugeMode? {
        switch presentation {
        case .mass(let fraction): return .mass(fraction: fraction)
        case .flow: return .flow
        case .none, .steady: return nil
        }
    }
}

nonisolated enum ActivityStripPipelinePausePresentation {
    static let label = "paused"
    static let help = "Ohia’s pipeline is paused. Resume it from Developer Settings."
    static let gaugeMode: GaugeMode = .signal(.ready)
}

nonisolated enum ActivityStripTrainingPresentation {
    static let stageLabel = "trained"
    static let readoutLabel = "training"
    static let progressText: String? = nil
    static let gaugeMode: GaugeMode = .training(fraction: nil)

    static func stageProgress(
        for corpus: TrainingCandidateCorpusProgress
    ) -> ActivityStripTrainingStageProgress {
        let discovered = max(0, corpus.discoveredMessageCount)
        let assessed = min(discovered, max(0, corpus.assessedMessageCount))
        if assessed < discovered {
            return ActivityStripTrainingStageProgress(
                count: assessed,
                total: discovered,
                isAssessing: true
            )
        }
        let eligible = max(0, corpus.eligibleMessageCount)
        return ActivityStripTrainingStageProgress(
            count: min(eligible, max(0, corpus.trainedMessageCount)),
            total: eligible,
            isAssessing: false
        )
    }

    static func isStageWorkActive(runningJobTypes: Set<String>) -> Bool {
        runningJobTypes.contains(JobType.buildTrainingPairs.rawValue)
            || runningJobTypes.contains(JobType.train.rawValue)
    }
}

nonisolated struct ActivityStripTrainingStageProgress: Equatable, Sendable {
    let count: Int
    let total: Int
    let isAssessing: Bool
}

nonisolated enum ActivityStripMessagesPresentation {
    static let labels = [
        "ingested", "datafied", "summarized", ActivityStripTrainingPresentation.stageLabel,
    ]

    static func orderedLabels(_ labels: [String]) -> [String] {
        self.labels.filter(labels.contains)
    }
}

nonisolated enum ActivityStripIndexPresentation {
    private static let preferredLabels = ["embeddings", "nodes", "vectors"]

    static func orderedLabels(_ labels: [String]) -> [String] {
        preferredLabels.filter(labels.contains)
            + labels.filter { !preferredLabels.contains($0) }
    }
}

nonisolated struct ActivityStripIMAPCorpusStoreState: Equatable, Sendable {
    var isKnown: Bool
    var hasConfiguredAccounts: Bool
    var initialIMAPImportCompletedAt: Date?
    var uidWork: [PipelineCorpusUIDWork]

    static let unknown = ActivityStripIMAPCorpusStoreState(
        isKnown: false,
        hasConfiguredAccounts: false,
        initialIMAPImportCompletedAt: nil,
        uidWork: []
    )
}

nonisolated enum ActivityStripIMAPCorpusProjection {
    struct Folder: Equatable, Sendable {
        var name: String
        var attributes: [String]
        var total: Int?
        var remaining: Int?
    }

    /// Initial-import progress represents server acquisition work, not the
    /// deduplicated corpus estimate. Include every synced folder that adds
    /// semantic content — for Gmail, both INBOX and All Mail — while excluding
    /// Drafts. Keep rows whose UID-work snapshot is not known yet so the gauge
    /// remains indeterminate instead of presenting a falsely precise percent.
    static func requiredUIDWork(
        folders: [Folder],
        isGmail: Bool = false
    ) -> [PipelineCorpusUIDWork] {
        let listing = folders.map { folder in
            IMAPFolder(
                name: folder.name,
                delimiter: nil,
                attributes: Set(folder.attributes)
            )
        }
        let capabilities = IMAPCapability(raw: isGmail ? ["X-GM-EXT-1"] : [])
        let requiredNames = Set(GmailFolderFilter.foldersToSync(
            listing: listing,
            capabilities: capabilities
        ).filter { folder in
            IMAPFolderIngestionPolicy.isCorpusEligible(
                folderName: folder.name,
                attributes: Array(folder.attributes)
            )
        }.map(\.name))
        return folders.compactMap { folder in
            guard requiredNames.contains(folder.name) else { return nil }
            return PipelineCorpusUIDWork(total: folder.total, remaining: folder.remaining)
        }
    }

    /// Same host heuristic as `ActivityStripIMAPCorpusSQL.readState` — every
    /// caller of `requiredUIDWork` must derive `isGmail` this way so Gmail's
    /// label folders do not enter the acquisition-work projection.
    static func isGmailHost(_ host: String?) -> Bool {
        let normalized = host?.lowercased() ?? ""
        return normalized.contains("gmail") || normalized.contains("google")
    }
}

nonisolated enum ActivityStripIMAPCorpusSQL {
    static func readState(db: OpaquePointer) -> ActivityStripIMAPCorpusStoreState {
        let schema = ActivityStoreTableSchema(
            db: db,
            tables: ["ZACCOUNT", "ZIMAPFOLDERSTATE"]
        )
        let accountColumns = [
            "Z_PK",
            "ZIMAPHOST",
            "ZIMAPKEYCHAINREF",
            "ZINITIALIMAPIMPORTCOMPLETEDAT",
        ]
        let folderColumns = [
            "ZACCOUNT",
            "ZFOLDERNAME",
            "ZFOLDERATTRIBUTESJSON",
            "ZINITIALIMPORTUIDWORKTOTAL",
            "ZINITIALIMPORTUIDWORKREMAINING",
        ]
        guard accountColumns.allSatisfy({ schema.hasColumn($0, in: "ZACCOUNT") }),
              folderColumns.allSatisfy({ schema.hasColumn($0, in: "ZIMAPFOLDERSTATE") })
        else { return .unknown }

        let accountSQL = """
        SELECT
            COUNT(*),
            COALESCE(SUM(CASE WHEN ZINITIALIMAPIMPORTCOMPLETEDAT IS NULL THEN 1 ELSE 0 END), 0),
            MIN(ZINITIALIMAPIMPORTCOMPLETEDAT)
        FROM ZACCOUNT
        WHERE ZIMAPKEYCHAINREF IS NOT NULL
          AND LENGTH(TRIM(ZIMAPKEYCHAINREF)) > 0
        """
        var accountStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, accountSQL, -1, &accountStatement, nil) == SQLITE_OK,
              let accountStatement else {
            sqlite3_finalize(accountStatement)
            return .unknown
        }
        defer { sqlite3_finalize(accountStatement) }
        guard sqlite3_step(accountStatement) == SQLITE_ROW else { return .unknown }

        let accountCount = Int(sqlite3_column_int64(accountStatement, 0))
        let incompleteAccountCount = Int(sqlite3_column_int64(accountStatement, 1))
        let completedAt: Date? = if accountCount > 0, incompleteAccountCount == 0 {
            Date(timeIntervalSinceReferenceDate: sqlite3_column_double(accountStatement, 2))
        } else {
            nil
        }

        let workSQL = """
        SELECT
            F.ZACCOUNT,
            A.ZIMAPHOST,
            F.ZFOLDERNAME,
            F.ZFOLDERATTRIBUTESJSON,
            F.ZINITIALIMPORTUIDWORKTOTAL,
            F.ZINITIALIMPORTUIDWORKREMAINING
        FROM ZIMAPFOLDERSTATE F
        JOIN ZACCOUNT A ON A.Z_PK = F.ZACCOUNT
        WHERE A.ZIMAPKEYCHAINREF IS NOT NULL
          AND LENGTH(TRIM(A.ZIMAPKEYCHAINREF)) > 0
          AND A.ZINITIALIMAPIMPORTCOMPLETEDAT IS NULL
        ORDER BY F.ZACCOUNT, F.ROWID
        """
        var workStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, workSQL, -1, &workStatement, nil) == SQLITE_OK,
              let workStatement else {
            sqlite3_finalize(workStatement)
            return .unknown
        }
        defer { sqlite3_finalize(workStatement) }

        var accountOrder: [Int64] = []
        var foldersByAccount: [Int64: [ActivityStripIMAPCorpusProjection.Folder]] = [:]
        var gmailByAccount: [Int64: Bool] = [:]
        while sqlite3_step(workStatement) == SQLITE_ROW {
            let accountID = sqlite3_column_int64(workStatement, 0)
            let host = sqlite3_column_text(workStatement, 1).map {
                String(cString: $0).lowercased()
            } ?? ""
            guard let namePointer = sqlite3_column_text(workStatement, 2) else {
                return .unknown
            }
            let name = String(cString: namePointer)
            let attributes: [String] = sqlite3_column_text(workStatement, 3).flatMap { pointer in
                let json = String(cString: pointer)
                guard let data = json.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode([String].self, from: data)
            } ?? []
            let total = sqlite3_column_type(workStatement, 4) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int64(workStatement, 4))
            let remaining = sqlite3_column_type(workStatement, 5) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int64(workStatement, 5))
            if foldersByAccount[accountID] == nil {
                accountOrder.append(accountID)
            }
            gmailByAccount[accountID] = host.contains("gmail") || host.contains("google")
            foldersByAccount[accountID, default: []].append(.init(
                name: name,
                attributes: attributes,
                total: total,
                remaining: remaining
            ))
        }
        var uidWork: [PipelineCorpusUIDWork] = []
        for accountID in accountOrder {
            uidWork.append(contentsOf: ActivityStripIMAPCorpusProjection.requiredUIDWork(
                folders: foldersByAccount[accountID] ?? [],
                isGmail: gmailByAccount[accountID] == true
            ))
        }
        return ActivityStripIMAPCorpusStoreState(
            isKnown: true,
            hasConfiguredAccounts: accountCount > 0,
            initialIMAPImportCompletedAt: completedAt,
            uidWork: uidWork
        )
    }
}

/// Reduces every model-usage signal the ActivityStrip can observe into the
/// atom's three visual states: dim idle, bright held work, or live electrons.
/// Keeping this separate from pipeline stage progress prevents non-pipeline
/// model work (for example dreaming or an interactive query embedding) from
/// being rendered as model-idle.
nonisolated enum ActivityStripModelWorkPresentation {
    struct State: Equatable, Sendable {
        var workExists: Bool
        var isActivelyRunning: Bool
        var hasDirectActiveWork: Bool
    }

    private static let modelJobTypes: Set<String> = [
        JobType.summarize.rawValue,
        JobType.summarizeAttachments.rawValue,
        JobType.resolveSemanticTags.rawValue,
        JobType.accountMemoryRefresh.rawValue,
        JobType.customCategoryDefinition.rawValue,
        JobType.prepareReplySources.rawValue,
        JobType.generateDraft.rawValue,
        JobType.generateDraftingRules.rawValue,
        JobType.distillStyleRegisters.rawValue,
        JobType.train.rawValue,
        JobType.embed.rawValue,
        JobType.entityEmbed.rawValue,
        JobType.entityRefresh.rawValue,
        JobType.reindexEmbeddings.rawValue,
        JobType.extractVisualAttachments.rawValue,
        "generation",
        "queryEmbedding",
    ]

    private static let heldStates: [WorkerState] = [
        .running,
        .busy,
        .throttled,
        .paused,
    ]

    private static let activeStates: [WorkerState] = [
        .running,
        .busy,
    ]

    static func state(
        workers: [WorkerStatusSnapshot],
        hasAppSideModelActivity: Bool,
        hasModelWarmupActivity: Bool,
        now: Date,
        heartbeatMaxAge: TimeInterval = 15
    ) -> State {
        var workExists = hasAppSideModelActivity || hasModelWarmupActivity
        var isActivelyRunning = workExists
        var hasDirectActiveWork = hasAppSideModelActivity

        for worker in workers {
            guard !worker.isHeartbeatStale(maxAge: heartbeatMaxAge, now: now),
                  heldStates.contains(worker.state),
                  let jobType = worker.currentJobType,
                  modelJobTypes.contains(jobType) else {
                continue
            }
            workExists = true
            if activeStates.contains(worker.state) {
                isActivelyRunning = true
                if jobType == JobType.extractVisualAttachments.rawValue {
                    hasDirectActiveWork = true
                }
            }
        }

        return State(
            workExists: workExists,
            isActivelyRunning: isActivelyRunning,
            hasDirectActiveWork: hasDirectActiveWork
        )
    }

    /// Dreaming is a user-facing claim that Qwen owns a live account-memory
    /// refresh, not merely that the durable queue contains one. Requiring the
    /// same fresh held-work heartbeat consumed by the atom keeps its label and
    /// nucleus truthful through queueing, handoff, and worker exit races.
    static func isDreamingModelWorkActive(
        memoryRefreshIsRunning: Bool,
        worker: WorkerStatusSnapshot?,
        now: Date,
        heartbeatMaxAge: TimeInterval = 15
    ) -> Bool {
        guard memoryRefreshIsRunning,
              let worker,
              worker.role == .qwen,
              !worker.isHeartbeatStale(maxAge: heartbeatMaxAge, now: now),
              heldStates.contains(worker.state),
              worker.currentJobType == JobType.accountMemoryRefresh.rawValue else {
            return false
        }
        return true
    }

    /// Tagging is visible only while the durable job and the fresh BGE worker
    /// heartbeat agree that semantic-tag model work is currently held.
    static func isTaggingModelWorkActive(
        semanticTagResolutionIsRunning: Bool,
        worker: WorkerStatusSnapshot?,
        now: Date,
        heartbeatMaxAge: TimeInterval = 15
    ) -> Bool {
        guard semanticTagResolutionIsRunning,
              let worker,
              worker.role == .bge,
              !worker.isHeartbeatStale(maxAge: heartbeatMaxAge, now: now),
              heldStates.contains(worker.state),
              worker.currentJobType == JobType.resolveSemanticTags.rawValue else {
            return false
        }
        return true
    }

    /// Qwen's `.loading` preparation snapshot can outlive the actual weight
    /// load while the worker's main actor waits to publish its next heartbeat.
    /// Once Qwen reports that the model is resident, startup loading is over
    /// even if the preparation enum has not caught up yet. BGE residency is
    /// composite, so its load state remains authoritative while either of its
    /// retrieval components initializes.
    static func modelWarmupActivity(
        generative: WorkerModelStatusSnapshot?,
        retrieval: WorkerModelStatusSnapshot?
    ) -> PipelineActivityPresentation.ModelWarmupActivity? {
        PipelineActivityPresentation.modelWarmupActivity(
            generative: generativeWarmupLoadState(for: generative),
            retrieval: retrieval?.state
        )
    }

    struct TailOrWarmupPresentation: Equatable {
        enum Source: Equatable {
            case strictTail
            case modelWarmup
        }

        let source: Source
        let label: String
        let gaugeMode: GaugeMode
    }

    /// Resolves text and animation together when model warm-up overlaps the
    /// strict ingestion tail. Active tail work keeps precedence, but queued
    /// training's `waiting` state yields to a model that is actually loading.
    static func tailOrWarmupPresentation(
        strictTailActivityLabel: String?,
        modelWarmupActivity: PipelineActivityPresentation.ModelWarmupActivity?
    ) -> TailOrWarmupPresentation? {
        if let strictTailActivityLabel,
           strictTailActivityLabel != "waiting",
           let gaugeMode = strictTailGaugeMode(for: strictTailActivityLabel) {
            return TailOrWarmupPresentation(
                source: .strictTail,
                label: strictTailActivityLabel,
                gaugeMode: gaugeMode
            )
        }

        switch modelWarmupActivity {
        case .loading:
            return TailOrWarmupPresentation(
                source: .modelWarmup,
                label: "loading",
                gaugeMode: .docking
            )
        case .downloading(let fraction):
            return TailOrWarmupPresentation(
                source: .modelWarmup,
                label: "downloading",
                gaugeMode: .kindling(fraction: min(max(fraction, 0), 1))
            )
        case nil:
            guard strictTailActivityLabel == "waiting" else { return nil }
            return TailOrWarmupPresentation(
                source: .strictTail,
                label: "waiting",
                gaugeMode: .signal(.ready)
            )
        }
    }

    private static func strictTailGaugeMode(for label: String) -> GaugeMode? {
        switch label {
        case ActivityStripTrainingPresentation.readoutLabel:
            return ActivityStripTrainingPresentation.gaugeMode
        case "tagging":
            return .resolve
        case "dreaming":
            return .dreaming(fraction: nil)
        default:
            return nil
        }
    }

    private static func generativeWarmupLoadState(
        for model: WorkerModelStatusSnapshot?
    ) -> WorkerModelLoadState? {
        guard let model else { return nil }
        if model.state == .loading, model.isResident == true {
            return nil
        }
        return model.state
    }

    /// App-side requests and Apple visual extraction report their own live
    /// execution, so an unrelated BGE/Qwen worker throttle must not hide their
    /// electrons. Background worker work keeps the existing throttle policy.
    static func showsElectrons(
        hasActivePipelineWork: Bool,
        modelWork: State,
        throttles: [WorkerThrottleSnapshot]
    ) -> Bool {
        if modelWork.hasDirectActiveWork {
            return true
        }
        return PipelineActivityPresentation.showsPipelineFlowIndicator(
            throttles: throttles,
            hasActiveWork: hasActivePipelineWork || modelWork.isActivelyRunning
        )
    }

    static func activityLabel(
        forJobType jobType: String,
        composerDraftStageRaw: String? = nil,
        replyPreparationStatusRaw: String? = nil,
        hasActiveReplySourcePreparation: Bool = false
    ) -> String? {
        if jobType == JobType.summarizeAttachments.rawValue {
            return "digesting"
        }
        if jobType == JobType.distillStyleRegisters.rawValue {
            return "learning"
        }
        // Once prepared sources have been adopted, the Draft stage is
        // authoritative even if a stale preparation job remains visible for
        // one activity snapshot. Both that job and the targeted draft job
        // represent the question-evaluation work now underway.
        if composerDraftStageRaw == DraftStage.evaluatingSources,
           jobType == JobType.prepareReplySources.rawValue
                || jobType == JobType.generateDraft.rawValue {
            return "formulating"
        }
        // A targeted draft job can coexist briefly with the source-preparation
        // row for the same message. The preparation is the work the user is
        // actually waiting on, so it must win over generateDraft's nil-stage
        // "drafting" fallback regardless of SQLite row order.
        if jobType == JobType.generateDraft.rawValue,
           hasActiveReplySourcePreparation {
            return PipelineActivityPresentation.modelActivityLabel(
                forJobType: JobType.prepareReplySources.rawValue,
                replyPreparationStatusRaw: replyPreparationStatusRaw
            )
            .map(displayLabel)
        }
        return PipelineActivityPresentation.modelActivityLabel(
            forJobType: jobType,
            composerDraftStageRaw: composerDraftStageRaw,
            replyPreparationStatusRaw: replyPreparationStatusRaw
        )
        .map(displayLabel)
    }

    static func displayLabel(_ rawLabel: String) -> String {
        switch rawLabel {
        case "questioning":
            return "formulating"
        case "resolving":
            return "tagging"
        default:
            return rawLabel
        }
    }

    /// Generation heartbeats intentionally collapse request details to a
    /// generic `generation` / `summarizing` pair. Recover attachment-summary
    /// identity from the authoritative running durable job without changing
    /// ordinary on-demand summaries.
    static func generationActivityLabel(
        normalizedLabel: String,
        currentJobType: String?,
        currentJobDescription: String?,
        hasRunningAttachmentSummaryJob: Bool
    ) -> String {
        let explicitlyNamesAttachment = currentJobType == JobType.summarizeAttachments.rawValue
            || currentJobDescription?
                .localizedCaseInsensitiveContains("attachment summar") == true
        if explicitlyNamesAttachment
            || normalizedLabel == "summarizing" && hasRunningAttachmentSummaryJob {
            return "digesting"
        }
        return normalizedLabel
    }

    static func shouldShowModelActivityJob(
        jobType: String,
        status: String,
        messageID: UUID? = nil,
        hasSummarizationBacklog: Bool = true,
        isPipelineWorkActive: Bool
    ) -> Bool {
        if jobType == JobType.distillStyleRegisters.rawValue {
            return status == JobStatus.pending.rawValue
                || status == JobStatus.running.rawValue
        }
        return PipelineActivityPresentation.shouldShowModelActivityJob(
            jobType: jobType,
            status: status,
            messageID: messageID,
            hasSummarizationBacklog: hasSummarizationBacklog,
            isPipelineWorkActive: isPipelineWorkActive
        )
    }

    /// Keep retrieval work visible even when the durable job queue updates
    /// before the worker heartbeat. Queued/throttled work lights the nucleus
    /// unless the resolved readout is explicitly `waiting`, which is the
    /// user-facing declaration that no model activity is current.
    static func indicatorWorkExists(
        visibleActivityLabel: String,
        observedWorkExists: Bool
    ) -> Bool {
        guard visibleActivityLabel != "waiting" else { return false }
        return visibleActivityLabel == "embedding"
            || visibleActivityLabel == "captioning"
            || observedWorkExists
    }

    static func pendingModelJobCanLead(
        jobType: String,
        hasActiveDedicatedActivity: Bool
    ) -> Bool {
        guard !hasActiveDedicatedActivity else { return false }
        return jobType != JobType.buildTrainingPairs.rawValue
            && jobType != JobType.train.rawValue
            && jobType != JobType.resolveSemanticTags.rawValue
            && jobType != JobType.accountMemoryRefresh.rawValue
    }

    /// Maps the model-bearing portion of the scheduler's strict ingestion tail
    /// instead of allowing the Activity Strip to narrate whichever durable row
    /// SQLite returns first. Meaning membership is deliberately omitted: it
    /// groups existing vectors without running a model. Tagging and dreaming
    /// require fresh model-worker heartbeats supplied by their callers.
    static func strictTailActivityLabel(
        hasMeaningMembershipWork _: Bool,
        activeJobTypes: Set<String>,
        isTrainingActive: Bool,
        isTaggingActive: Bool = false,
        isDreamingActive: Bool,
        isMessagePipelineActive: Bool = false
    ) -> String? {
        guard isMessagePipelineActive == false else { return nil }
        // Training's hold on the tail is bounded: tagging or Dreaming that
        // outwaited it runs between slices while the next `.train` sits
        // queued. Running released work names the tail; a queued slice alone
        // still reads as waiting, and a running slice still reads as training.
        let trainingQueued = activeJobTypes.contains(JobType.buildTrainingPairs.rawValue)
            || activeJobTypes.contains(JobType.train.rawValue)
        let releasedWorkRunning = isTaggingActive || isDreamingActive
        let stage = IngestionTailStageAuthority.stage(for: .init(
            membershipRequired: false,
            trainingRequired: isTrainingActive
                || (trainingQueued && !releasedWorkRunning),
            taggingRequired: isTaggingActive,
            dreamingRequired: isDreamingActive
        ))
        switch stage {
        case .membership: return nil
        case .training:
            return isTrainingActive
                ? ActivityStripTrainingPresentation.readoutLabel
                : "waiting"
        case .tagging: return "tagging"
        case .dreaming: return "dreaming"
        case .complete: return nil
        }
    }
}

nonisolated private struct PipelineActivityJobSnapshot: Equatable, Sendable {
    var type: String
    var status: String
    var messageID: UUID?
    var payload: String?
    var startedAt: Date?
    var nextAttemptAt: Date?
    /// The mailbox account this job's work belongs to, resolved through the
    /// job's message (`ZJOB.ZMESSAGEID` → `ZMESSAGE.ZACCOUNTID`) or through
    /// the account telemetry of a running generic summarize drain. Nil for
    /// corpus-wide lanes. Drives the flow indicator's electron tint.
    var accountID: UUID?
}

nonisolated private struct PipelineActivitySnapshot: Equatable, Sendable {
    var total = 0
    var interpreted = 0
    var summarized = 0
    var attachmentSummaryTotal = 0
    var attachmentSummarized = 0
    var pendingEmbeds = 0
    var processingEmbeds = 0
    var failedEmbeds = 0
    var embedded = 0
    /// Account owning the next message selected by the generic interpretation
    /// drain. This fills the snapshot gap before the running job publishes its
    /// per-message account payload.
    var nextPendingInterpretationAccountID: UUID?
    /// Account owning the next message selected by the rich-summary drain.
    var nextPendingBodySummaryAccountID: UUID?
    /// Sole account represented by target-role examples in the active
    /// training run. Replay examples do not determine presentation ownership.
    var activeTrainingTargetAccountID: UUID?
    var pendingJobTypes: Set<String> = []
    var runningJobTypes: Set<String> = []
    var activeJobs: [PipelineActivityJobSnapshot] = []
    var activePermanentDeleteMutationCount = 0
    var completedPermanentDeleteMutationCount = 0
    var pendingEmbedNextAttemptAt: Date?
    var failedEmbedJobCount = 0
    var failedInterpretationJobCount = 0
    var jobCount = 0
    var memoryRefreshStates: [ActivityStripMemoryRefreshStateSnapshot] = []
    var imapCorpusState = ActivityStripIMAPCorpusStoreState.unknown

    static let empty = PipelineActivitySnapshot()

    var hasActiveJobs: Bool {
        !activeJobs.isEmpty || !runningJobTypes.isEmpty
    }
}

/// Carries the account identity of active message work and ingestion into the
/// aggregate pipeline readout. A sole owning account supplies the electron
/// tint; mixed-account or accountless work intentionally keeps the Ohia accent.
nonisolated struct ActivityStripPipelineAccountEngagement: Equatable, Sendable {
    private(set) var runningMessageAccountID: UUID?
    private(set) var runningIngestionAccountIDs: Set<UUID> = []

    mutating func observe(
        jobType: String,
        status: String,
        accountID: UUID?
    ) {
        if runningMessageAccountID == nil,
           jobType == JobType.summarize.rawValue,
           status == JobStatus.running.rawValue,
           let accountID {
            runningMessageAccountID = accountID
            return
        }
        guard jobType == JobType.imapBackfill.rawValue
                || jobType == JobType.imapPollFolder.rawValue,
              status == JobStatus.pending.rawValue
                || status == JobStatus.running.rawValue,
              let accountID
        else { return }
        runningIngestionAccountIDs.insert(accountID)
    }

    mutating func observeIngestion(accountID: UUID) {
        runningIngestionAccountIDs.insert(accountID)
    }

    func accountID(for pipelineLabel: String) -> UUID? {
        switch pipelineLabel {
        case "datafying", "summarizing":
            return runningMessageAccountID
        case "backfilling", "syncing", "importing":
            guard runningIngestionAccountIDs.count == 1 else { return nil }
            return runningIngestionAccountIDs.first
        default:
            return nil
        }
    }
}

/// Resolves the account presented by the visible Activity Strip readout. The
/// durable store supplies the next queued message while generic drain
/// telemetry is between items, and training is account-attributable only when
/// every target example in the active run belongs to one account.
nonisolated enum ActivityStripReadoutAccountPresentation {
    static func accountID(
        for label: String,
        reportedAccountID: UUID?,
        queuedMessageAccountID: UUID?,
        trainingTargetAccountID: UUID?
    ) -> UUID? {
        switch label {
        case "datafying", "summarizing":
            return reportedAccountID ?? queuedMessageAccountID
        case "training":
            return trainingTargetAccountID
        default:
            return reportedAccountID
        }
    }

    static func soleAccountID(among accountIDs: [UUID]) -> UUID? {
        let uniqueAccountIDs = Set(accountIDs)
        guard uniqueAccountIDs.count == 1 else { return nil }
        return uniqueAccountIDs.first
    }
}

/// Keeps account-owned message processing visually stable across the brief
/// accountless snapshots between items in the generic summarize drain.
nonisolated enum ActivityStripFlowIndicatorTintPresentation {
    static func source(
        for pipelineLabel: String,
        resolvedSource: FlowIndicatorTintSource,
        previousSource: FlowIndicatorTintSource?
    ) -> FlowIndicatorTintSource {
        guard pipelineLabel == "datafying" || pipelineLabel == "summarizing",
              resolvedSource == .accent,
              let previousSource,
              case .account = previousSource
        else { return resolvedSource }

        return previousSource
    }
}

/// The generic summarize row remains message-agnostic for scheduler semantics.
/// While Qwen is processing one message, its account UUID is carried in the
/// row's otherwise-unused payload solely for Activity Strip presentation.
nonisolated enum ActivityStripPipelineAccountPayload {
    static func accountID(
        jobType: String,
        status: String,
        payload: String?
    ) -> UUID? {
        guard jobType == JobType.summarize.rawValue,
              status == JobStatus.running.rawValue,
              let payload else {
            return nil
        }
        return UUID(uuidString: payload)
    }
}

/// Job-derived values the strip reads many times per render pass, reduced
/// from `PipelineActivitySnapshot.activeJobs` in a single pass when a new
/// snapshot is applied. `activeJobs` can hold thousands of rows during
/// backfill (every pending `.summarize` job is one row), and the previous
/// live computed properties re-scanned it — decoding IMAP job payloads with
/// `JSONDecoder` on each pass — dozens of times per `body` evaluation, which
/// hung the main thread. Values here are at most one refresh tick (1–3 s)
/// stale with respect to `accounts` policy changes, the same staleness bound
/// as the snapshot itself.
nonisolated private struct ActivityStripJobDerivations: Equatable {
    /// A relevant IMAP job for a configured account with its payload decoded
    /// exactly once, in snapshot order.
    struct RelevantIMAPJob: Equatable {
        var job: PipelineActivityJobSnapshot
        var payload: ActivityStripIMAPJobPayload?
    }

    var relevantIMAPJobs: [RelevantIMAPJob] = []
    /// A relevant `.imapBackfill` or `.imapPollFolder` job is running.
    var hasRunningRelevantIMAPImportJob = false
    /// A relevant `.imapBackfill` job is pending or running.
    var hasHistoricalIMAPBackfillJob = false
    /// A relevant `.imapBackfill` job is actively running.
    var hasRunningHistoricalIMAPBackfillJob = false
    /// A relevant `.imapBackfill` job is running or can be claimed now.
    var hasRunnableHistoricalIMAPBackfillJob = false
    /// A relevant `.imapPollFolder` job carries `gapCheck == true`.
    var hasActiveGapCheckJob = false
    /// Jobs passing `shouldShowModelActivityJob`, split by the
    /// `isPipelineWorkActive` flag so the readout picks the right list
    /// without re-filtering the full job array.
    var visibleModelJobsWhilePipelineActive: [PipelineActivityJobSnapshot] = []
    var visibleModelJobsWhilePipelineIdle: [PipelineActivityJobSnapshot] = []
    /// A pending or running cluster-detection job whose payload targets the
    /// Meaning lens. Other frame clustering is not part of the strict tail.
    var hasActiveMeaningMembershipJob = false
    /// Message IDs whose post-render source preparation is currently queued
    /// or running. Used to keep a simultaneous generic draft row from
    /// mislabeling the same work as "drafting."
    var activeReplySourcePreparationMessageIDs: Set<UUID> = []
    /// Durable phase for every active preparation job, loaded once through a
    /// fresh context when the activity snapshot is applied.
    var replyPreparationStatusByMessageID: [UUID: String] = [:]
    /// Store-authoritative stages resolved once per activity refresh, never
    /// from SwiftUI's render/animation path.
    var composerDraftStageByMessageID: [UUID: String] = [:]
    var standaloneComposerDraftStageRaw: String?
    var pendingInterpretationJobCount = 0
    var runningInterpretationJobCount = 0
    var pipelineAccountEngagement = ActivityStripPipelineAccountEngagement()

    static let empty = ActivityStripJobDerivations()
}

nonisolated enum ActivityStripInterpretationSQL {
    static func completePredicate(
        messageAlias: String = "M",
        analysisAlias: String = "A",
        hasLiveInboundColumns: Bool = true,
        hasClassificationColumn: Bool = true
    ) -> String {
        guard hasClassificationColumn,
              let classificationSQL = try? MailClassificationSQL.completePredicate(
                  columnReference: "\(analysisAlias).ZMAILCLASSIFICATIONJSON"
              ) else {
            return "0"
        }
        let triageRequiredSQL = hasLiveInboundColumns
            ? "\(messageAlias).ZLIVEDETECTEDAT IS NOT NULL AND COALESCE(\(messageAlias).ZISSENTBYUSER, 0) = 0"
            : "0"
        let validTriageSQL = """
        \(analysisAlias).ZTRIAGEVERDICTJSON IS NOT NULL
        AND LENGTH(TRIM(\(analysisAlias).ZTRIAGEVERDICTJSON)) > 0
        AND json_valid(\(analysisAlias).ZTRIAGEVERDICTJSON)
        AND COALESCE(json_type(\(analysisAlias).ZTRIAGEVERDICTJSON, '$.isActionable') IN ('true', 'false'), 0)
        AND COALESCE(json_type(\(analysisAlias).ZTRIAGEVERDICTJSON, '$.requiresConfirmation') IN ('true', 'false'), 0)
        """
        return """
        (\(classificationSQL))
        AND (NOT (\(triageRequiredSQL)) OR (\(validTriageSQL)))
        """
    }
}

nonisolated enum ActivityStripRefreshPolicy {
    static let activeActivitySnapshotInterval: TimeInterval = 1
    static let settledActivitySnapshotInterval: TimeInterval = 3
    static let activeVectorSnapshotInterval: TimeInterval = 1
    static let settledVectorSnapshotInterval: TimeInterval = 5

    private static let vectorAffectingJobTypes: Set<String> = [
        JobType.embed.rawValue,
        JobType.index.rawValue,
        JobType.refine.rawValue,
        JobType.frameBurst.rawValue,
        JobType.clusterDetect.rawValue,
        JobType.entityEmbed.rawValue,
        JobType.entityRefresh.rawValue,
        JobType.reconcileVectorIndex.rawValue,
        JobType.reindexEmbeddings.rawValue,
    ]

    private static let backgroundOnlyModelJobTypes: Set<String> = [
        JobType.accountMemoryRefresh.rawValue,
        JobType.train.rawValue,
    ]

    static func activitySnapshotInterval(
        activeJobTypes: Set<String>,
        hasRecentIngestActivity: Bool,
        hasActivePermanentDelete: Bool
    ) -> TimeInterval {
        let hasPipelineChangingActiveJob = activeJobTypes.isEmpty == false
            && activeJobTypes.isSubset(of: backgroundOnlyModelJobTypes) == false
        if hasPipelineChangingActiveJob || hasRecentIngestActivity || hasActivePermanentDelete {
            return activeActivitySnapshotInterval
        }
        return settledActivitySnapshotInterval
    }

    static func vectorSnapshotInterval(
        activeJobTypes: Set<String>,
        hasRecentIngestActivity: Bool
    ) -> TimeInterval {
        if hasRecentIngestActivity || activeJobTypes.isDisjoint(with: vectorAffectingJobTypes) == false {
            return activeVectorSnapshotInterval
        }
        return settledVectorSnapshotInterval
    }

    static func shouldRefresh(now: Date, lastRefresh: Date, interval: TimeInterval) -> Bool {
        now.timeIntervalSince(lastRefresh) >= interval
    }
}

nonisolated enum ActivityStripHistoricalWorkPresentation {
    static func state(
        isInitialImportIncomplete: Bool,
        hasPendingOrRunningBackfill: Bool,
        hasRunnableBackfill: Bool,
        hasRunningBackfill: Bool
    ) -> PipelineHistoricalIMAPWork {
        guard hasPendingOrRunningBackfill else { return .inactive }
        if hasRunningBackfill || (isInitialImportIncomplete && hasRunnableBackfill) {
            return .active
        }
        return .waiting
    }
}

enum ActivityStripTempoProgressText {
    static func text(
        fraction: Double,
        isBottleneckComplete: Bool
    ) -> String {
        let percent = ActivityStripOverallProgress.tempoDisplayPercent(
            fraction: fraction,
            isBottleneckComplete: isBottleneckComplete
        )
        if fraction > 0, percent == 0, !isBottleneckComplete {
            return "1%"
        }
        return "\(percent)%"
    }
}

nonisolated enum ActivityStripMessageScope {
    static func sqlWhereClause(hasTrashedAtColumn: Bool) -> String {
        hasTrashedAtColumn ? "WHERE M.ZTRASHEDAT IS NULL" : ""
    }
}

nonisolated struct ActivityStoreTableSchema: Sendable {
    private let columnsByTable: [String: Set<String>]

    init(db: OpaquePointer, tables: Set<String>) {
        var columnsByTable: [String: Set<String>] = [:]
        for table in tables {
            columnsByTable[table] = Self.readColumns(in: table, db: db)
        }
        self.columnsByTable = columnsByTable
    }

    func hasColumn(_ column: String, in table: String) -> Bool {
        columnsByTable[table]?.contains(column) ?? false
    }

    private static func readColumns(in table: String, db: OpaquePointer) -> Set<String> {
        guard isValidSQLiteIdentifier(table) else { return [] }
        let sql = "PRAGMA table_info(\"\(table)\");"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePointer = sqlite3_column_text(statement, 1) else {
                continue
            }
            columns.insert(String(cString: namePointer))
        }
        return columns
    }

    private static func isValidSQLiteIdentifier(_ identifier: String) -> Bool {
        guard let first = identifier.unicodeScalars.first,
              Self.sqliteIdentifierHeadCharacters.contains(first) else {
            return false
        }
        return identifier.unicodeScalars.allSatisfy {
            Self.sqliteIdentifierCharacters.contains($0)
        }
    }

    private static let sqliteIdentifierHeadCharacters = CharacterSet.uppercaseLetters
        .union(.lowercaseLetters)
        .union(CharacterSet(charactersIn: "_"))

    private static let sqliteIdentifierCharacters = sqliteIdentifierHeadCharacters
        .union(.decimalDigits)
}

private struct PipelineVectorActivitySnapshot: Equatable, Sendable {
    var hasPlacement = false
    var placementTotal = 0
    var placementPlaced = 0
    var hasEmailNodes = false
    var emailNodeTotal = 0
    var emailNodePlaced = 0

    static let empty = PipelineVectorActivitySnapshot()

    init() {}

    init(
        placement: (total: Int, placed: Int)?,
        emailNodes: (total: Int, placed: Int)?
    ) {
        if let placement {
            hasPlacement = true
            placementTotal = placement.total
            placementPlaced = placement.placed
        }
        if let emailNodes {
            hasEmailNodes = true
            emailNodeTotal = emailNodes.total
            emailNodePlaced = emailNodes.placed
        }
    }

    var placement: (total: Int, placed: Int)? {
        hasPlacement ? (placementTotal, placementPlaced) : nil
    }

    var emailNodes: (total: Int, placed: Int)? {
        hasEmailNodes ? (emailNodeTotal, emailNodePlaced) : nil
    }
}

private struct ActivityStripIMAPJobPayload: Decodable, Equatable {
    let accountID: UUID
    let folderName: String?
    let gapCheck: Bool?
}

struct TempoReadout {
    let label: String
    let help: String
    let progressText: String?
    /// The mailbox account this readout's activity belongs to, when the
    /// activity is account-attributable. The flow indicator tints its
    /// electrons with this account's colour, so the orbiting colour and the
    /// readout label always describe the same work. Nil for activities with no
    /// single owning account (model warm-up, interactive retrieval, mixed-
    /// account training, and layout refine) — those keep the strip's accent.
    var accountID: UUID? = nil
    var progressColor: Color? = nil

    static func labelOnly(
        _ label: String,
        help: String,
        accountID: UUID? = nil
    ) -> TempoReadout {
        TempoReadout(label: label, help: help, progressText: nil, accountID: accountID)
    }
}

/// Stable identity for a tempo-gauge presentation change. Associated values
/// that update continuously (progress, event timestamps, and counts) are
/// deliberately excluded so they update in place instead of repeatedly
/// restarting the gauge/readout crossfade.
struct ActivityStripTempoTransitionIdentity: Hashable {
    let label: String
    private let gauge: Gauge

    init(label: String, gaugeMode: GaugeMode) {
        self.label = label
        gauge = Gauge(gaugeMode)
    }

    private enum Gauge: Hashable {
        case mass
        case flow
        case sending(accountColorIndex: Int)
        case signal(Signal)
        case dreaming
        case training(isDeterminate: Bool)
        case clustering
        case distill
        case precis
        case digest
        case cipher
        case converse
        case tag
        case resolve
        case typewriter
        case sift
        case probe
        case pull
        case consolidate
        case hone
        case weights
        case encode
        case trace
        case kindling(isDeterminate: Bool)
        case docking

        init(_ mode: GaugeMode) {
            switch mode {
            case .mass:
                self = .mass
            case .flow:
                self = .flow
            case .sending(let accountColorIndex):
                self = .sending(accountColorIndex: accountColorIndex)
            case .signal(let state):
                self = .signal(Signal(state))
            case .dreaming:
                // Never fills — pipeline-determinate and steady forms render
                // identically, so both must share one transition identity
                // (unlike `.training`, whose fraction still drives the
                // spectrum bars' jitter and so is a real visual distinction).
                self = .dreaming
            case .training(let fraction):
                self = .training(isDeterminate: fraction != nil)
            case .clustering:
                self = .clustering
            case .distill:
                self = .distill
            case .precis:
                // Never fills — the pipeline (real fraction) and on-demand
                // (nil) forms render identically, so both share one identity.
                self = .precis
            case .digest:
                self = .digest
            case .cipher:
                self = .cipher
            case .converse:
                self = .converse
            case .tag:
                self = .tag
            case .resolve:
                self = .resolve
            case .typewriter:
                self = .typewriter
            case .sift:
                self = .sift
            case .probe:
                self = .probe
            case .pull:
                self = .pull
            case .consolidate:
                self = .consolidate
            case .hone:
                self = .hone
            case .weights:
                self = .weights
            case .encode:
                self = .encode
            case .trace:
                self = .trace
            case .kindling(let fraction):
                self = .kindling(isDeterminate: fraction != nil)
            case .docking:
                self = .docking
            }
        }
    }

    private enum Signal: Hashable {
        case watching
        case ready
        case pending
        case connecting
        case authing
        case syncing
        case checkingGaps
        case polling
        case newMail
        case deletionsPending
        case deletionsUpdated
        case verifyingDeletions
        case reconnecting
        case needsAttention

        init(_ state: SignalState) {
            switch state {
            case .watching:
                self = .watching
            case .ready:
                self = .ready
            case .pending:
                self = .pending
            case .connecting:
                self = .connecting
            case .authing:
                self = .authing
            case .syncing:
                self = .syncing
            case .checkingGaps:
                self = .checkingGaps
            case .polling:
                self = .polling
            case .newMail:
                self = .newMail
            case .deletionsPending:
                self = .deletionsPending
            case .deletionsUpdated:
                self = .deletionsUpdated
            case .verifyingDeletions:
                self = .verifyingDeletions
            case .reconnecting:
                self = .reconnecting
            case .needsAttention:
                self = .needsAttention
            }
        }
    }
}

nonisolated struct ActivityStripIMAPPresentationToken: Hashable {
    let sequence: UInt64?
    let kind: String
    let accountID: UUID?
    let folder: String?
    let occurredAt: Date

    init(_ activity: WorkerIMAPActivitySnapshot) {
        sequence = activity.sequence
        kind = activity.kind.rawValue
        accountID = activity.accountID
        folder = activity.folder
        occurredAt = activity.occurredAt
    }
}

struct ActivityStripTempoPresentation {
    let readout: TempoReadout
    let gaugeMode: GaugeMode
    let imapToken: ActivityStripIMAPPresentationToken?
    let startedAt: Date?

    init(
        readout: TempoReadout,
        gaugeMode: GaugeMode,
        imapActivity: WorkerIMAPActivitySnapshot? = nil
    ) {
        self.readout = readout
        self.gaugeMode = gaugeMode
        imapToken = imapActivity.map(ActivityStripIMAPPresentationToken.init)
        startedAt = nil
    }

    var transitionIdentity: ActivityStripTempoTransitionIdentity {
        ActivityStripTempoTransitionIdentity(label: readout.label, gaugeMode: gaugeMode)
    }

    var updateIdentity: ActivityStripTempoPresentationUpdateIdentity {
        ActivityStripTempoPresentationUpdateIdentity(
            transition: transitionIdentity,
            imapToken: imapToken
        )
    }

    func starting(at startedAt: Date) -> ActivityStripTempoPresentation {
        ActivityStripTempoPresentation(
            readout: readout,
            gaugeMode: gaugeMode.startingTransient(at: startedAt),
            imapToken: imapToken,
            startedAt: startedAt
        )
    }

    private init(
        readout: TempoReadout,
        gaugeMode: GaugeMode,
        imapToken: ActivityStripIMAPPresentationToken?,
        startedAt: Date?
    ) {
        self.readout = readout
        self.gaugeMode = gaugeMode
        self.imapToken = imapToken
        self.startedAt = startedAt
    }
}

struct ActivityStripTempoPresentationUpdateIdentity: Hashable {
    let transition: ActivityStripTempoTransitionIdentity
    let imapToken: ActivityStripIMAPPresentationToken?
}

private struct ActivityStripTempoCoordinationTaskIdentity: Hashable {
    let presentation: ActivityStripTempoPresentationUpdateIdentity
    let reduceMotion: Bool
    let imapAdvanceAt: Date?
}

struct ActivityStripTempoPresentationCoordinator {
    private(set) var presented: ActivityStripTempoPresentation?
    private(set) var presentationStartedAt: Date?
    private(set) var nextTransitionAt: Date?
    private var latestPending: ActivityStripTempoPresentation?

    mutating func ingest(
        _ desired: ActivityStripTempoPresentation,
        at now: Date,
        reduceMotion: Bool
    ) {
        if presented == nil {
            present(desired, at: now)
            return
        }

        guard presented?.updateIdentity != desired.updateIdentity else {
            if let presentationStartedAt {
                presented = desired.starting(at: presentationStartedAt)
            } else {
                presented = desired
            }
            latestPending = nil
            nextTransitionAt = nil
            return
        }

        latestPending = desired
        nextTransitionAt = nextCycleBoundary(after: now, reduceMotion: reduceMotion)
        advance(at: now, reduceMotion: reduceMotion)
    }

    mutating func advance(at now: Date, reduceMotion: Bool) {
        guard let latestPending else { return }
        if nextTransitionAt == nil {
            nextTransitionAt = nextCycleBoundary(after: now, reduceMotion: reduceMotion)
        }
        guard let nextTransitionAt, now >= nextTransitionAt else { return }
        present(latestPending, at: now)
    }

    mutating func completeCurrentCycle(
        with desired: ActivityStripTempoPresentation,
        at now: Date
    ) {
        present(desired, at: now)
    }

    private mutating func present(
        _ presentation: ActivityStripTempoPresentation,
        at now: Date
    ) {
        presented = presentation.starting(at: now)
        presentationStartedAt = now
        latestPending = nil
        nextTransitionAt = nil
    }

    private func nextCycleBoundary(
        after now: Date,
        reduceMotion: Bool
    ) -> Date? {
        guard let presented, let presentationStartedAt else { return now }
        let duration = presented.gaugeMode.presentationCycleDuration(
            reduceMotion: reduceMotion
        )
        guard duration > 0 else { return now }
        let elapsed = max(0, now.timeIntervalSince(presentationStartedAt))
        let completedTurns = max(1, ceil(elapsed / duration))
        return presentationStartedAt.addingTimeInterval(completedTurns * duration)
    }

}

struct ActivityStripEventBurst: Equatable {
    var startedAt: Date?
    var count: Int = 0

    mutating func record(delta: Int, at now: Date, duration: TimeInterval) {
        let normalizedDelta = max(1, delta)
        if let startedAt,
           now.timeIntervalSince(startedAt) >= 0,
           now.timeIntervalSince(startedAt) <= duration {
            count += normalizedDelta
        } else {
            startedAt = now
            count = normalizedDelta
        }
    }

    func isActive(at now: Date, duration: TimeInterval) -> Bool {
        guard let startedAt else { return false }
        let elapsed = now.timeIntervalSince(startedAt)
        return elapsed >= 0 && elapsed <= duration
    }
}

enum ActivityStripLiveMailEvent {
    static func newlyDetectedMessageIDs(
        previous: Set<UUID>,
        current: Set<UUID>
    ) -> Set<UUID> {
        current.subtracting(previous)
    }
}

struct ActivityStripIMAPIndicatorIdentity: Hashable {
    let label: String
    let eventStartedAt: Date?

    init(label: String, eventStartedAt: Date? = nil) {
        self.label = label
        self.eventStartedAt = eventStartedAt
    }
}

enum ActivityStripIMAPActivityPriority: Int, Comparable {
    case routine
    case lifecycle
    case userCommand
    case failure

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ActivityStripIMAPActivitySpec: Equatable {
    enum Retention: Equatable {
        case minimumTurn
        case untilTransition
    }

    let label: String
    let help: String
    let priority: ActivityStripIMAPActivityPriority
    let retention: Retention

    init(
        label: String,
        help: String,
        priority: ActivityStripIMAPActivityPriority,
        retention: Retention = .untilTransition
    ) {
        self.label = label
        self.help = help
        self.priority = priority
        self.retention = retention
    }
}

/// Canonical production vocabulary for worker-reported IMAP activity. The
/// queue, readout, gauge, tests, and DEBUG guide all resolve names from this
/// exhaustive mapping instead of maintaining parallel label switches.
enum ActivityStripIMAPActivityPresentation {
    static func spec(for kind: WorkerIMAPActivityKind) -> ActivityStripIMAPActivitySpec {
        switch kind {
        case .ready:
            return .init(label: "ready", help: "Ohia is ready for the next mail server task.", priority: .routine, retention: .minimumTurn)
        case .watching:
            return .init(label: "watching", help: "Ohia is watching the mail server for new mail and deletions.", priority: .routine, retention: .minimumTurn)
        case .pending:
            return .init(label: "pending", help: "Ohia is waiting to begin a queued mailbox task.", priority: .routine)
        case .connecting:
            return .init(label: "connecting", help: "Ohia is opening a connection to the mail server.", priority: .lifecycle)
        case .authenticating:
            return .init(label: "authenticating", help: "Ohia is signing in to the mail server.", priority: .lifecycle)
        case .syncing:
            return .init(label: "syncing", help: "Ohia is syncing mailbox changes from the mail server.", priority: .lifecycle)
        case .polling:
            return .init(label: "polling", help: "Ohia is scanning a mailbox folder for new, changed, or deleted messages.", priority: .routine)
        case .gapChecking:
            return .init(label: "gap checking", help: "Ohia is comparing server and local folder state to find missed changes.", priority: .routine)
        case .verifyingDeletions:
            return .init(label: "verifying", help: "Ohia is checking server deletion state without changing the mailbox.", priority: .routine)
        case .reconciling:
            return .init(label: "reconciling", help: "Ohia is applying confirmed server deletions to its local mail data.", priority: .lifecycle)
        case .deletionsUpdated:
            return .init(label: "reconciling", help: "Ohia updated local mail after confirmed server deletions.", priority: .lifecycle, retention: .minimumTurn)
        case .reconnecting:
            return .init(label: "reconnecting", help: "Ohia is restoring a lost connection to the mail server.", priority: .failure)
        case .needsAttention:
            return .init(label: "attention", help: "Ohia is unable to continue mail synchronization because the server connection failed.", priority: .failure)
        case .backfilling:
            return .init(label: "backfilling", help: "Ohia is importing older historical messages from the mail server.", priority: .routine)
        case .checking:
            return .init(label: "checking", help: "Ohia is checking the mail server for new messages.", priority: .routine, retention: .minimumTurn)
        case .forming:
            return .init(label: "forming", help: "Ohia found new mail and is forming it into the local index.", priority: .lifecycle, retention: .minimumTurn)
        case .movingToTrash:
            return .init(label: "moving to trash", help: "Ohia is moving a message to the server Trash mailbox.", priority: .userCommand)
        case .deleting:
            return .init(label: "deleting", help: "Ohia is permanently deleting a message from the mail server.", priority: .userCommand)
        case .movingToJunk:
            return .init(label: "moving to junk", help: "Ohia is moving a message to the server Junk mailbox.", priority: .userCommand)
        case .movingToInbox:
            return .init(label: "moving to inbox", help: "Ohia is moving a message to the server Inbox mailbox.", priority: .userCommand)
        case .updatingMail:
            return .init(label: "updating mail", help: "Ohia is updating read or flagged state on the mail server.", priority: .userCommand)
        case .savingDraft:
            return .init(label: "saving draft", help: "Ohia is saving a Composer draft to the mail server.", priority: .userCommand)
        case .deletingDraft:
            return .init(label: "deleting draft", help: "Ohia is removing a discarded Composer draft from the mail server.", priority: .userCommand)
        case .syncingDrafts:
            return .init(label: "syncing drafts", help: "Ohia is synchronizing Composer drafts with the mail server.", priority: .userCommand)
        }
    }

    static func maySurfaceInComposer(_ kind: WorkerIMAPActivityKind) -> Bool {
        switch kind {
        case .savingDraft, .deletingDraft, .syncingDrafts:
            true
        default:
            false
        }
    }

    static func attentionHelp(for activity: WorkerIMAPActivitySnapshot, accountName: String?) -> String {
        var location = accountName ?? "Mail account"
        if let folder = activity.folder, !folder.isEmpty {
            location += " — " + folder
        }
        return location + ": " + (activity.attentionCause ?? .mailboxOperation).explanation
    }

    static func activities(
        for mode: ActivityStripMode,
        from activities: [WorkerIMAPActivitySnapshot]
    ) -> [WorkerIMAPActivitySnapshot] {
        switch mode {
        case .constellation:
            return activities
        case .composer:
            return activities.filter {
                maySurfaceInComposer($0.kind) || endsComposerActivity($0.kind)
            }
        }
    }

    // The draft worker restores the session state on completion and reports
    // reconnecting/attention on failure. Consume those transitions even though
    // their labels belong only on the Constellation strip.
    static func endsComposerActivity(_ kind: WorkerIMAPActivityKind) -> Bool {
        switch kind {
        case .ready, .watching, .connecting, .authenticating, .syncing,
             .reconnecting, .needsAttention:
            true
        default:
            false
        }
    }

    static func gaugeMode(
        for activity: WorkerIMAPActivitySnapshot,
        presentationStartedAt: Date
    ) -> GaugeMode {
        switch activity.kind {
        case .ready:
            return .signal(.ready)
        case .watching:
            return .signal(.watching)
        case .pending:
            return .signal(.pending)
        case .connecting:
            return .signal(.connecting)
        case .authenticating:
            return .signal(.authing)
        case .syncing, .checking, .updatingMail, .savingDraft, .deletingDraft,
             .syncingDrafts, .movingToJunk, .movingToInbox:
            return .signal(.syncing(folder: activity.folder))
        case .polling:
            return .signal(.polling(folder: activity.folder))
        case .gapChecking:
            return .signal(.checkingGaps(folder: activity.folder))
        case .verifyingDeletions:
            return .signal(.verifyingDeletions(folder: activity.folder))
        case .reconciling, .movingToTrash, .deleting:
            return .signal(.deletionsPending(count: 1))
        case .deletionsUpdated:
            return .signal(.deletionsUpdated(eventStart: presentationStartedAt, count: 1))
        case .reconnecting:
            return .signal(.reconnecting(attempt: 1))
        case .needsAttention:
            return .signal(.needsAttention)
        case .backfilling:
            return .flow
        case .forming:
            return .signal(.newMail(eventStart: presentationStartedAt, count: 1))
        }
    }
}

struct ActivityStripIMAPActivityQueue {
    private let minimumVisibleDurationOverride: TimeInterval?
    private(set) var presented: WorkerIMAPActivitySnapshot?
    private(set) var presentationStartedAt: Date?
    private var pending: [WorkerIMAPActivitySnapshot] = []
    private var completedComposerActivities: Set<ActivityStripIMAPPresentationToken> = []

    init(minimumVisibleDuration: TimeInterval? = nil) {
        minimumVisibleDurationOverride = minimumVisibleDuration.map { max(0, $0) }
    }

    mutating func ingest(
        _ activities: [WorkerIMAPActivitySnapshot],
        at now: Date,
        reduceMotion: Bool = false,
        mode: ActivityStripMode = .constellation
    ) {
        advance(at: now, reduceMotion: reduceMotion)
        for activity in activities {
            // Retire only an older failure in the domain that recovered.
            if activity.accountID != nil {
                pending.removeAll { Self.resolvesAttention($0, with: activity) }
                if let current = presented, Self.resolvesAttention(current, with: activity) {
                    presented = nil
                    presentationStartedAt = nil
                }
            }
            if mode == .composer,
               !ActivityStripIMAPActivityPresentation.maySurfaceInComposer(activity.kind) {
                if ActivityStripIMAPActivityPresentation.endsComposerActivity(activity.kind) {
                    for queued in (presented.map({ [$0] }) ?? []) + pending {
                        if queued.accountID == activity.accountID,
                           queued.folder == nil || queued.folder == activity.folder,
                           queued.occurredAt <= activity.occurredAt {
                            completedComposerActivities.insert(ActivityStripIMAPPresentationToken(queued))
                        }
                    }
                }
                continue
            }
            guard isDuplicateOfTail(activity) == false else { continue }
            if presented == nil {
                presented = activity
                presentationStartedAt = nil
            } else {
                pending.append(activity)
            }
        }
        advance(at: now, reduceMotion: reduceMotion)
    }

    mutating func markPresented(at now: Date) {
        guard presented != nil, presentationStartedAt == nil else { return }
        presentationStartedAt = now
    }

    mutating func markPresented(
        _ token: ActivityStripIMAPPresentationToken,
        at now: Date
    ) {
        guard let presented,
              ActivityStripIMAPPresentationToken(presented) == token
        else { return }
        markPresented(at: now)
    }

    mutating func advance(at now: Date, reduceMotion: Bool = false) {
        guard let presented, let presentationStartedAt,
              now.timeIntervalSince(presentationStartedAt) >= visibleDuration(
                  for: presented,
                  reduceMotion: reduceMotion
              ) else {
            return
        }
        if pending.isEmpty == false {
            // Other accounts' progress may take a turn, but it does not
            // resolve this account's failed operation.
            if presented.kind == .needsAttention, presented.accountID != nil,
               !pending.contains(where: {
                   $0.kind == .needsAttention && $0.accountID == presented.accountID
                       && $0.folder == presented.folder
                       && $0.operationID == presented.operationID
               }) {
                pending.append(presented)
            }
            completedComposerActivities.remove(ActivityStripIMAPPresentationToken(presented))
            self.presented = pending.removeFirst()
            self.presentationStartedAt = nil
        } else if ActivityStripIMAPActivityPresentation.spec(for: presented.kind).retention == .minimumTurn
                    || completedComposerActivities.contains(ActivityStripIMAPPresentationToken(presented)) {
            completedComposerActivities.remove(ActivityStripIMAPPresentationToken(presented))
            self.presented = nil
            self.presentationStartedAt = nil
        }
    }

    mutating func current(at now: Date, reduceMotion: Bool = false) -> WorkerIMAPActivitySnapshot? {
        advance(at: now, reduceMotion: reduceMotion)
        return presented
    }

    func nextAdvanceAt(reduceMotion: Bool = false) -> Date? {
        guard let presented, let presentationStartedAt else { return nil }
        let retention = ActivityStripIMAPActivityPresentation.spec(for: presented.kind).retention
        guard pending.isEmpty == false || retention == .minimumTurn
                || completedComposerActivities.contains(ActivityStripIMAPPresentationToken(presented))
        else { return nil }
        return presentationStartedAt.addingTimeInterval(
            visibleDuration(for: presented, reduceMotion: reduceMotion)
        )
    }

    mutating func resetForFullReconciliation() {
        presented = nil
        presentationStartedAt = nil
        pending.removeAll(keepingCapacity: true)
        completedComposerActivities.removeAll(keepingCapacity: true)
    }

    private func isDuplicateOfTail(_ activity: WorkerIMAPActivitySnapshot) -> Bool {
        let tail = pending.last ?? presented
        if let tail, completedComposerActivities.contains(ActivityStripIMAPPresentationToken(tail)) {
            return false
        }
        return tail?.kind == activity.kind
            && tail?.accountID == activity.accountID
            && tail?.folder == activity.folder
            && tail?.attentionCause == activity.attentionCause
            && tail?.operationID == activity.operationID
    }

    private static func resolvesAttention(_ failure: WorkerIMAPActivitySnapshot, with recovery: WorkerIMAPActivitySnapshot) -> Bool {
        guard failure.kind == .needsAttention,
              failure.accountID == recovery.accountID,
              failure.occurredAt <= recovery.occurredAt else { return false }
        if let operationID = failure.operationID {
            return recovery.operationID == operationID
                && [.ready, .watching, .syncing, .deletionsUpdated].contains(recovery.kind)
        }
        if failure.attentionCause == .localReconciliation {
            return failure.folder != nil && failure.folder == recovery.folder
                && recovery.kind == .deletionsUpdated
        }
        guard failure.attentionCause != .mailboxOperation, failure.attentionCause != nil else { return false }
        return [.ready, .watching, .reconnecting].contains(recovery.kind)
    }

    private func visibleDuration(
        for activity: WorkerIMAPActivitySnapshot,
        reduceMotion: Bool
    ) -> TimeInterval {
        if let minimumVisibleDurationOverride {
            return minimumVisibleDurationOverride
        }
        return ActivityStripIMAPActivityPresentation.gaugeMode(
            for: activity,
            presentationStartedAt: activity.occurredAt
        ).presentationCycleDuration(reduceMotion: reduceMotion)
    }
}

struct ActivityStripIMAPIndicatorLease: Equatable {
    private(set) var observedIdentity: ActivityStripIMAPIndicatorIdentity?
    private(set) var visibleUntil: Date?

    mutating func observe(
        _ identity: ActivityStripIMAPIndicatorIdentity?,
        at now: Date,
        duration: TimeInterval
    ) {
        guard identity != observedIdentity else { return }
        observedIdentity = identity
        visibleUntil = identity == nil ? nil : now.addingTimeInterval(max(0, duration))
    }

    func isPresenting(_ identity: ActivityStripIMAPIndicatorIdentity, at now: Date) -> Bool {
        guard observedIdentity == identity, let visibleUntil else { return false }
        return now <= visibleUntil
    }
}

private struct ActivityStripIMAPIndicatorPresentation {
    let identity: ActivityStripIMAPIndicatorIdentity
    let readout: TempoReadout
    let gaugeMode: GaugeMode
}

struct ActivityStripView: View {
    enum ComposerActivitySource: Sendable, Equatable {
        case appSidePublisher
        case workerGeneration
        case workerQueryEmbedding
        case durableTargetedJob
    }

    let mode: ActivityStripMode

    @Query private var outboxItems: [OutboxItem]
    @Query private var accounts: [Account]
    @Query private var folderStates: [IMAPFolderState]
    @Environment(\.modelContext) private var modelContext
    @Environment(WorkerFleetStatusPublisher.self) private var workerStatuses: WorkerFleetStatusPublisher?
    @Environment(AppServices.self) private var appServices: AppServices?
    @Environment(IMAPSessionManager.self) private var imapSessionManager: IMAPSessionManager?
    @Environment(TrainingStatusPublisher.self) private var trainingStatus: TrainingStatusPublisher?
    @Environment(\.activityStripComposerTarget) private var composerTarget
    private let outboxStore = OutboxActivitySnapshotStore.shared
    private let activityLog = ActivityLogModel.shared
    @State private var activityPopover = ActivityStripPopoverState()

    /// Auto-ticks the view every second so the "retry in Ns" countdown
    /// rolls live without depending on SwiftData notifications.
    @State private var clock: Date = .now

    /// Mirrors the session-scoped hard-pause notifications consumed by the
    /// scheduler so an unfinished backlog cannot continue to read as active.
    @State private var pipelinePaused = false

    /// Fixed origin for the flow-indicator animation so its `time` starts near
    /// zero and stays small — large absolute timestamps degrade the sin/cos in
    /// the Canvas motion.
    @State private var flowClockOrigin = Date()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var flowIndicatorColorScheme

    /// Crossfading electron tint — the account colour of the work the readout
    /// is naming. Nil until first resolved, so the first frame settles on its
    /// colour instead of fading in from an arbitrary one.
    @State private var electronTint: FlowIndicatorElectronTint?

    @State private var vectorSnapshot: PipelineVectorActivitySnapshot = .empty

    /// Vector-store placement counts. Refreshed by the activity loop instead
    /// of from `body`, because SwiftUI may evaluate this view many times per
    /// display pass while idle.
    private var placement: (total: Int, placed: Int)? {
        vectorSnapshot.placement
    }

    /// Distinct messages that have vectors, and distinct messages whose
    /// vectors have 3-D coordinates. This is the unfiltered all-node count;
    /// active Constellation filters can make fewer nodes visible.
    private var emailNodes: (total: Int, placed: Int)? {
        vectorSnapshot.emailNodes
    }

    @State private var activitySnapshot: PipelineActivitySnapshot = .empty
    @State private var jobDerivations: ActivityStripJobDerivations = .empty
    @State private var hasLoadedActivitySnapshot = false
    @State private var recentIngestActivityUntil: Date?
    @State private var newMailEvent = ActivityStripEventBurst()
    @State private var deletionEvent = ActivityStripEventBurst()
    @State private var permanentDeleteEvent = ActivityStripEventBurst()
    @State private var imapCheckEvent = ActivityStripEventBurst()
    @State private var observedPendingArrivalMessageIDs: Set<UUID> = []
    @State private var imapIndicatorLease = ActivityStripIMAPIndicatorLease()
    @State private var workerIMAPActivityTracker = WorkerIMAPActivityBridgeTracker()
    @State private var workerIMAPActivityQueue = ActivityStripIMAPActivityQueue()
    @State private var tempoPresentationCoordinator = ActivityStripTempoPresentationCoordinator()
    @State private var observedPermanentDeleteCompletionCount: Int?

    /// Fixed gap between the gauge track and the readout label's left edge.
    private static let tempoReadoutLeadingGap: CGFloat = 16

    private enum ActivityStripDensity {
        case full
        case regular
        case compact

        init(width: CGFloat) {
            if width >= 1500 {
                self = .full
            } else if width >= 1350 {
                self = .regular
            } else {
                self = .compact
            }
        }

        var stageSpacing: CGFloat {
            switch self {
            case .full: return 16
            case .regular: return 8
            case .compact: return 8
            }
        }

        var dividerPadding: CGFloat {
            switch self {
            case .full: return 10
            case .regular: return 7
            case .compact: return 7
            }
        }

        var labelTrailingPadding: CGFloat {
            switch self {
            case .full: return 12
            case .regular: return 8
            case .compact: return 8
            }
        }

        var showsStageLabels: Bool {
            switch self {
            case .full, .regular: return true
            case .compact: return false
            }
        }

        var showsStageTotals: Bool {
            true
        }
    }

    init(mode: ActivityStripMode = .constellation) {
        self.mode = mode
    }

    var body: some View {
        VStack(spacing: 0) {
            if mode == .constellation {
                Rectangle()
                    .fill(OhiaColors.glassBorder)
                    .frame(height: 1)
            }

            Group {
                switch mode {
                case .constellation:
                    constellationRow
                        .padding(.horizontal, Self.stripHorizontalInset)
                        .padding(.vertical, 10)
                case .composer:
                    let desired = composerStripPresentation
                    let presentation = displayedTempoPresentation(for: desired)
                    tempoGauge(presentation: presentation, desired: desired)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                mode == .composer
                    ? OhiaColors.composerPanelBackground
                    : OhiaColors.toolbarBackground
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await runActivityRefreshLoop()
        }
        // Hash on (id, status) per item so status-only transitions
        // (queued → sending → sent) re-render the chip immediately, not just
        // count changes. The `id` term keeps swap-but-same-count cases
        // distinct from status flips on a stable item set.
        .onChange(of: outboxFingerprint) { _, _ in outboxStore.update(from: outboxItems) }
        .onAppear {
            outboxStore.update(from: outboxItems)
            observedPendingArrivalMessageIDs = NewMailArrivalLedger.shared.pendingArrivalMessageIDs
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaPausePipeline)) { _ in
            pipelinePaused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaResumePipeline)) { _ in
            pipelinePaused = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaNewMailArrivalVisibilityChanged)) { _ in
            let currentMessageIDs = NewMailArrivalLedger.shared.pendingArrivalMessageIDs
            let newlyDetectedMessageIDs = ActivityStripLiveMailEvent.newlyDetectedMessageIDs(
                previous: observedPendingArrivalMessageIDs,
                current: currentMessageIDs
            )
            observedPendingArrivalMessageIDs = currentMessageIDs
            guard newlyDetectedMessageIDs.isEmpty == false else { return }

            // The arrival ledger publishes as soon as a live IMAP row is
            // detected, before its datafy / summarize / embed work completes.
            // Removals from the ledger are ignored so final announcement does
            // not replay the forming animation.
            newMailEvent.record(
                delta: newlyDetectedMessageIDs.count,
                at: Date(),
                duration: PipelineActivityPresentation.activityNewMailEventDuration
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaIMAPCheckingMail)) { _ in
            imapCheckEvent.record(
                delta: 1,
                at: Date(),
                duration: PipelineActivityPresentation.activityIMAPCheckEventDuration
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaIMAPActivityQueued)) { notification in
            guard let activity = notification.object as? WorkerIMAPActivitySnapshot else { return }
            let activities = ActivityStripIMAPActivityPresentation.activities(
                for: mode,
                from: [activity]
            )
            guard activities.isEmpty == false else { return }
            workerIMAPActivityQueue.ingest(
                activities,
                at: Date(),
                reduceMotion: reduceMotion,
                mode: mode
            )
        }
        .onChange(of: deletionRemovalsCount) { oldCount, newCount in
            // Deletions-updated event: any positive delta to sessionRemovals
            // fires the Signal vocabulary amber fade. Same per-burst accumulation
            // pattern as new-mail, preserving the event count separately
            // from the running session total.
            guard newCount > oldCount else { return }
            let delta = newCount - oldCount
            deletionEvent.record(
                delta: delta,
                at: Date(),
                duration: PipelineActivityPresentation.activityDeletionUpdatedEventDuration
            )
        }
        .onChange(of: activeIMAPIndicatorPresentation?.identity, initial: true) { _, identity in
            imapIndicatorLease.observe(
                identity,
                at: Date(),
                duration: PipelineActivityPresentation.activityEventDuration
            )
        }
        .onChange(of: workerStatuses?.semanticGeneration, initial: true) { _, _ in
            consumeWorkerIMAPActivity(at: Date())
        }
    }

    @ViewBuilder
    private var constellationRow: some View {
        GeometryReader { proxy in
            let rowWidth = max(0, proxy.size.width)
            let density = ActivityStripDensity(width: rowWidth)
            let pipelineStages = stages
            // `stages` is in canonical pipeline order:
            // [ingested, datafied, summarized, embeddings, nodes, vectors,
            // trained]. Presentation groups Trained with message processing.
            let orderedMessageLabels = ActivityStripMessagesPresentation.orderedLabels(
                pipelineStages.map(\.label)
            )
            let messagesGroup = orderedMessageLabels.compactMap { label in
                pipelineStages.first { $0.label == label }
            }
            let indexStages = pipelineStages.filter {
                !ActivityStripMessagesPresentation.labels.contains($0.label)
            }
            let orderedIndexLabels = ActivityStripIndexPresentation.orderedLabels(
                indexStages.map(\.label)
            )
            let indexGroup = orderedIndexLabels.compactMap { label in
                indexStages.first { $0.label == label }
            }

            HStack(spacing: 0) {
                groupLabel("Messages")
                    .padding(.trailing, density.labelTrailingPadding)
                stageGroup(messagesGroup, density: density)

                verticalDivider(horizontalPadding: density.dividerPadding)

                groupLabel("Index")
                    .padding(.trailing, density.labelTrailingPadding)
                stageGroup(indexGroup, density: density)

                verticalDivider(horizontalPadding: density.dividerPadding)

                // Resolved once for the whole row. The readout ladder is not
                // cheap — it scans the active-job array and can issue a
                // SwiftData fetch — and the gauge text, its help, and the flow
                // indicator all need it, so evaluating it per consumer would
                // repeat that work several times per body pass.
                let desired = constellationStripPresentation
                let presentation = displayedTempoPresentation(for: desired)

                tempoGauge(presentation: presentation, desired: desired)
                    .padding(.leading, max(0, 20 - density.dividerPadding))
                    .layoutPriority(0)

                pipelineFlowIndicator(stages: pipelineStages, readout: presentation.readout)
            }
            .frame(width: rowWidth, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: 36)
    }

    @ViewBuilder
    private func stageGroup(
        _ stages: [PipelineStage],
        density: ActivityStripDensity
    ) -> some View {
        HStack(spacing: density.stageSpacing) {
            ForEach(stages, id: \.label) { stage in
                stageView(stage, density: density)
            }
        }
    }

    @ViewBuilder
    private func stageView(
        _ stage: PipelineStage,
        density: ActivityStripDensity
    ) -> some View {
        HStack(spacing: 6) {
            PipelineActivityDot(color: stage.color, status: stage.status)
            if density.showsStageLabels {
                Text(stage.label)
                    .foregroundStyle(OhiaColors.textSecondary)
            }
            Text(stageCountText(stage, density: density))
                .foregroundStyle(OhiaColors.textSecondary)
                .monospacedDigit()
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .modifier(ActivityStripHoverHelp(text: stageHelp(stage), presentation: activityPopover))
        .accessibilityLabel(stageText(stage))
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
    }

    /// Group label — exact toolbar accessor face:
    /// `Font.system(size: 9).tracking(1.0)`, `OhiaColors.textTertiary`,
    /// rendered uppercased. Same source-of-truth as
    /// `ToolbarSection.swift`'s accessor `Text(...)` modifier chain.
    @ViewBuilder
    private func groupLabel(_ name: String) -> some View {
        Text(name.uppercased())
            .font(.system(size: 9))
            .tracking(1.0)
            .foregroundStyle(OhiaColors.textTertiary)
            .fixedSize()
            .layoutPriority(3)
    }

    /// Vertical hairline divider. `strong` switches to `glassBorderBright` —
    /// the same token the toolbar uses to open its display-controls cluster.
    @ViewBuilder
    private func verticalDivider(
        strong: Bool = false,
        horizontalPadding: CGFloat = 10
    ) -> some View {
        Rectangle()
            .fill(strong ? OhiaColors.glassBorderBright : OhiaColors.glassBorder)
            .frame(width: 1, height: 30)
            .padding(.horizontal, horizontalPadding)
    }

    /// Tempo gauge — three visual languages by mode (mass / flow / signal).
    /// The gauge mode is passed in so each strip mode resolves its own ladder:
    /// `.constellation` uses the full `currentGaugeMode`, `.composer` the
    /// composer-scoped `composerGaugeMode`.
    /// See spec: docs/superpowers/specs/2026-05-03-activity-strip-progress-bar-design.md
    @ViewBuilder
    private func tempoGauge(
        presentation: ActivityStripTempoPresentation,
        desired: ActivityStripTempoPresentation
    ) -> some View {
        let readout = presentation.readout
        let gaugeMode = presentation.gaugeMode
        let transitionIdentity = presentation.transitionIdentity
        let transitionAnimation = reduceMotion
            ? Animation.easeOut(duration: 0.12)
            : Animation.easeInOut(duration: 0.22)

        HStack(spacing: Self.tempoReadoutLeadingGap) {
            ZStack {
                ActivityStripGauge(
                    mode: gaugeMode,
                    animationStartedAt: presentation.startedAt
                )
                    .id(transitionIdentity)
                    .transition(.opacity)
            }
            .animation(transitionAnimation, value: transitionIdentity)

            // The readout takes only its intrinsic width. The flexible gauge
            // consumes all remaining space, so short states lengthen the track
            // instead of leaving an invisible reserved label cell. Longer
            // states retain their full width and shorten the track as needed.
            ZStack(alignment: .leading) {
                tempoReadoutText(readout: readout, transitionIdentity: transitionIdentity)
            }
            .animation(transitionAnimation, value: transitionIdentity)
            .font(.system(size: 11.5))
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(3)
        }
        .frame(maxWidth: .infinity)
        .task(id: ActivityStripTempoCoordinationTaskIdentity(
            presentation: desired.updateIdentity,
            reduceMotion: reduceMotion,
            imapAdvanceAt: workerIMAPActivityQueue.nextAdvanceAt(reduceMotion: reduceMotion)
        )) {
            await coordinateTempoPresentation(desired)
        }
        .onChange(of: "\(readout.label)|\(readout.help)|\(readout.accountID?.uuidString ?? "")", initial: true) { _, _ in
            SessionActivityLog.shared.recordState(SessionActivityEvent(
                operation: readout.label.capitalized, phase: .state,
                accountID: readout.accountID,
                accountName: readout.accountID.flatMap { activityAccountNames[$0] },
                detail: readout.help
            ), channel: "strip-\(mode)")
        }
    }

    private var activityAccountNames: [UUID: String] {
        Dictionary(accounts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    private func detailedActivityHelp(_ readout: TempoReadout) -> String {
        guard let detail = activityLog.currentDetail(operation: readout.label,
            accountID: readout.accountID, accountNames: activityAccountNames) else {
            return readout.help
        }
        return "\(readout.help)\n\n\(detail)"
    }

    private func displayedTempoPresentation(
        for desired: ActivityStripTempoPresentation
    ) -> ActivityStripTempoPresentation {
        guard let presented = tempoPresentationCoordinator.presented else {
            return desired
        }
        guard presented.updateIdentity == desired.updateIdentity,
              let presentationStartedAt = tempoPresentationCoordinator.presentationStartedAt
        else {
            return presented
        }
        return desired.starting(at: presentationStartedAt)
    }

    @MainActor
    private func coordinateTempoPresentation(
        _ desired: ActivityStripTempoPresentation
    ) async {
        let observedToken = tempoPresentationCoordinator.presented?.imapToken
        let now = Date()
        tempoPresentationCoordinator.ingest(
            desired,
            at: now,
            reduceMotion: reduceMotion
        )
        markNewIMAPPresentationVisible(after: observedToken, at: now)

        while Task.isCancelled == false {
            let coordinatorDeadline = tempoPresentationCoordinator.nextTransitionAt
            let imapDeadline = workerIMAPActivityQueue.nextAdvanceAt(
                reduceMotion: reduceMotion
            )
            guard let deadline = [coordinatorDeadline, imapDeadline]
                .compactMap({ $0 })
                .min()
            else { return }
            let delay = max(0, deadline.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            let now = Date()
            let previousQueuedToken = workerIMAPActivityQueue.presented.map(
                ActivityStripIMAPPresentationToken.init
            )
            if let imapDeadline, now >= imapDeadline {
                workerIMAPActivityQueue.advance(at: now, reduceMotion: reduceMotion)
            }
            let queuedToken = workerIMAPActivityQueue.presented.map(
                ActivityStripIMAPPresentationToken.init
            )
            if queuedToken != previousQueuedToken {
                let nextDesired = mode == .composer
                    ? composerStripPresentation
                    : constellationStripPresentation
                let previousToken = tempoPresentationCoordinator.presented?.imapToken
                tempoPresentationCoordinator.completeCurrentCycle(
                    with: nextDesired,
                    at: now
                )
                markNewIMAPPresentationVisible(after: previousToken, at: now)
                return
            }
            let previousToken = tempoPresentationCoordinator.presented?.imapToken
            tempoPresentationCoordinator.advance(at: now, reduceMotion: reduceMotion)
            markNewIMAPPresentationVisible(after: previousToken, at: now)
        }
    }

    private func markNewIMAPPresentationVisible(
        after previousToken: ActivityStripIMAPPresentationToken?,
        at now: Date
    ) {
        guard let token = tempoPresentationCoordinator.presented?.imapToken,
              token != previousToken
        else { return }
        workerIMAPActivityQueue.markPresented(token, at: now)
    }

    /// Horizontal content inset of the constellation strip row. Referenced by
    /// the flow indicator to cancel it and align under the HUD control column.
    private static let stripHorizontalInset: CGFloat = 24

    /// The vertical HUD control-column footprint the flow-indicator cell centres
    /// under (`*RightControlColumn.columnWidth` is 66–70 across lenses; use the
    /// narrow end). The cell itself is smaller than this, so it sits with margin
    /// inside the column footprint rather than filling it.
    private static let hudColumnWidth: CGFloat = 66

    /// The flow-indicator cell size — deliberately smaller than the column.
    private static let flowIndicatorWidth: CGFloat = 48
    private static let flowIndicatorHeight: CGFloat = 24

    /// Trailing offset that centres the (last-in-row) cell under the flush-right
    /// HUD column: cancel the strip inset, then recentre for the narrower cell.
    /// Independent of cell width, so resizing the cell keeps it centred.
    private static let flowIndicatorOffset: CGFloat =
        stripHorizontalInset + (flowIndicatorWidth - hudColumnWidth) / 2

    /// Pipeline flow indicator — sits at the strip's trailing edge, within the
    /// footprint of the vertical HUD button column. Two stacked layers over the
    /// strip background: an always-present static nucleus whose dim/bright is a
    /// real SwiftUI opacity animation, and an electron layer (shells, electrons,
    /// dust) that mounts only while the pipeline is actively working and not
    /// externally braked, cross-fading in/out via a SwiftUI transition. When the
    /// pipeline goes idle the electron layer unmounts, so its TimelineView stops
    /// ticking — no idle animation churn. Both layers use a `.clear` background,
    /// so the strip shows through and the cell reads as part of the strip.
    private func pipelineFlowIndicator(
        stages: [PipelineStage],
        readout: TempoReadout
    ) -> some View {
        // Full atom (nucleus + electrons) while actively processing AND not
        // externally throttled; nucleus alone (bright) while work exists but is
        // held/throttled; dimmed nucleus (0.28) when idle.
        let modelWork = modelWorkState
        let resolvedTintSource = flowIndicatorTintSource(for: readout)
        let tintSource = ActivityStripFlowIndicatorTintPresentation.source(
            for: readout.label,
            resolvedSource: resolvedTintSource,
            previousSource: electronTint?.source
        )
        // The colour is part of the key so an appearance switch or a palette
        // edit repaints the electrons, not just a change of engaged account.
        let tintKey = FlowIndicatorTintKey(
            source: tintSource,
            rgb: flowIndicatorRGB(for: tintSource)
        )
        let pipelineWorkExists = stages.contains {
            PipelineActivityPresentation.stageIndicatesHeldWork(status: $0.status, total: $0.total)
        }
        let workExists = ActivityStripModelWorkPresentation.indicatorWorkExists(
            visibleActivityLabel: readout.label,
            observedWorkExists: pipelineWorkExists || modelWork.workExists
        )
        let electronsOn = workExists
            && showsPipelineFlowIndicator(stages: stages, modelWork: modelWork)
        let help = flowIndicatorHelp(electronsOn: electronsOn, workExists: workExists)
        return ZStack {
            // Static nucleus — no motion, no TimelineView. The dim/bright is a
            // real SwiftUI opacity animation bound directly to `workExists`, so
            // it is not reset every frame by a TimelineView tick and needs no
            // @State primed in `onAppear` (no first-frame flash).
            AtomFlowAnimation(
                time: 0,
                reduceMotion: true,
                backgroundColor: .clear,
                coreColor: flowIndicatorAccentColor,
                drawsElectrons: false
            )
            .opacity(workExists ? 1.0 : 0.28)
            .animation(.easeInOut(duration: 0.7), value: workExists)

            // Electron layer — mounted only while running unthrottled. The `if`
            // unmounts it once idle so its TimelineView stops ticking; the
            // `.transition(.opacity)` + ZStack `.animation(value: electronsOn)`
            // cross-fades it on mount/unmount over ~0.7s.
            if electronsOn {
                flowIndicatorElectronLayer
                    .transition(.opacity)
            }
        }
        .frame(width: Self.flowIndicatorWidth, height: Self.flowIndicatorHeight)
        .offset(x: Self.flowIndicatorOffset)
        .layoutPriority(3)
        .animation(.easeInOut(duration: 0.7), value: electronsOn)
        .modifier(ActivityStripHoverHelp(
            text: help,
            presentation: activityPopover,
            // Offset changes the drawing, not the cell's layout bounds.
            // Anchor help to the displayed atom rather than its original cell.
            attachmentAnchor: .rect(.rect(CGRect(
                x: Self.flowIndicatorOffset,
                y: 0,
                width: Self.flowIndicatorWidth,
                height: Self.flowIndicatorHeight
            )))
        ))
        .accessibilityLabel(help)
        // Retarget the electron tint whenever the engaged account changes, so
        // the colour crossfades to the account whose work the readout names.
        // `initial: true` settles the first resolution without a fade.
        .onChange(of: tintKey, initial: true) { _, key in
            let now = Date()
            if electronTint == nil {
                electronTint = FlowIndicatorElectronTint(rgb: key.rgb, source: key.source, at: now)
            } else {
                electronTint?.retarget(to: key.rgb, source: key.source, at: now)
            }
        }
    }

    /// Brief hover text describing the indicator's current meaning.
    private func flowIndicatorHelp(electronsOn: Bool, workExists: Bool) -> String {
        if electronsOn { return "Model work active" }
        guard workExists else { return "Models idle" }
        let throttled = PipelineActivityPresentation.isExternallyThrottled(throttles: [
            workerStatuses?.snapshot(for: .bge).worker.throttle ?? .notThrottled,
            workerStatuses?.snapshot(for: .qwen).worker.throttle ?? .notThrottled
        ])
        return throttled ? "Models throttled — work pending" : "Model work pending"
    }

    /// The animated electron layer — shells, electrons, and dust over a clear
    /// background (the nucleus is drawn by its own static sibling layer). Reduce
    /// Motion swaps the live TimelineView for a composed still; otherwise the
    /// Canvas runs at ~30 fps (ample for this slow motion and considerate of CPU
    /// while the pipeline is busy). This layer is mounted only while the pipeline
    /// is running unthrottled, so the TimelineView stops ticking once idle.
    @ViewBuilder
    private var flowIndicatorElectronLayer: some View {
        if reduceMotion {
            // No animation clock to sample, so the tint shows its settled
            // target rather than a crossfade.
            AtomFlowAnimation(
                time: 3.4,
                reduceMotion: true,
                backgroundColor: .clear,
                coreColor: flowIndicatorAccentColor,
                electronColor: flowIndicatorSettledElectronColor,
                drawsNucleus: false
            )
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                AtomFlowAnimation(
                    time: timeline.date.timeIntervalSince(flowClockOrigin),
                    reduceMotion: false,
                    backgroundColor: .clear,
                    coreColor: flowIndicatorAccentColor,
                    // Sampled per tick: the crossfade rides the animation
                    // clock, because a Canvas parameter is not animatable by
                    // SwiftUI (the timeline would reset it every frame).
                    electronColor: flowIndicatorElectronColor(at: timeline.date),
                    drawsNucleus: false
                )
            }
        }
    }

    /// The strip's active-accent token: Ohia yellow on dark, Ohia green on
    /// light, so the nucleus and electron layers read like a pipeline stage dot.
    private var flowIndicatorAccentColor: Color {
        flowIndicatorColorScheme == .dark
            ? OhiaColors.ohiaYellow
            : OhiaColors.ohiaGreen
    }

    /// Which account (if any) the given readout belongs to. The electrons take
    /// this account's colour, so the orbiting colour names the same work the
    /// readout label does. `.accent` when the engaged activity has no owning
    /// account, or when the account is unknown to the store (e.g. removed
    /// while its jobs were still queued).
    ///
    /// Takes the readout rather than re-reading `activeTempoReadout` so the
    /// indicator evaluates that ladder once per body pass, not twice.
    private func flowIndicatorTintSource(for readout: TempoReadout) -> FlowIndicatorTintSource {
        guard let accountID = readout.accountID,
              accounts.contains(where: { $0.id == accountID })
        else {
            return .accent
        }
        return .account(accountID)
    }

    /// The sRGB triple for a tint source: the account's palette colour, or the
    /// strip's active accent when no account owns the work.
    private func flowIndicatorRGB(for source: FlowIndicatorTintSource) -> SIMD3<Double> {
        switch source {
        case .account(let accountID):
            guard let account = accounts.first(where: { $0.id == accountID }) else {
                return flowIndicatorAccentRGB
            }
            let palette = AccountColorPalette.color(forIndex: account.colorIndex)
            let rgb = AccountColorPalette.rgb(for: palette, brightness: 1.0)
            return SIMD3(Double(rgb.x), Double(rgb.y), Double(rgb.z))
        case .accent:
            return flowIndicatorAccentRGB
        }
    }

    /// The accent token resolved to sRGB components. Derived from the token
    /// rather than hard-coded, so it keeps tracking `OhiaColors` if the brand
    /// hues change. Safe to resolve without an environment because both accent
    /// tokens (`ohiaYellow` / `ohiaGreen`) are static sRGB colours — the
    /// light/dark choice is made here, from `flowIndicatorColorScheme`.
    ///
    /// Resolved once per scheme rather than per body pass: this is read while
    /// building the tint key on every pass, and the strip's body runs several
    /// times a second.
    private static let accentRGBDark = srgbComponents(of: OhiaColors.ohiaYellow)
    private static let accentRGBLight = srgbComponents(of: OhiaColors.ohiaGreen)

    private var flowIndicatorAccentRGB: SIMD3<Double> {
        flowIndicatorColorScheme == .dark ? Self.accentRGBDark : Self.accentRGBLight
    }

    private static func srgbComponents(of color: Color) -> SIMD3<Double> {
        guard let resolved = NSColor(color).usingColorSpace(.sRGB) else {
            // Unreachable for the static brand tokens; a neutral keeps the
            // electrons visible rather than collapsing them to black.
            return SIMD3(1, 1, 1)
        }
        return SIMD3(
            Double(resolved.redComponent),
            Double(resolved.greenComponent),
            Double(resolved.blueComponent)
        )
    }

    /// The electron colour for this frame — the crossfading tint sampled
    /// against the animation clock. Before the tint is primed (only the very
    /// first render, since `.onChange(initial: true)` seeds it) the accent
    /// stands in.
    private func flowIndicatorElectronColor(at date: Date) -> Color {
        Self.color(from: electronTint?.rgb(at: date) ?? flowIndicatorAccentRGB)
    }

    /// The settled electron colour, with no crossfade — the Reduce Motion
    /// path, which renders one still frame and has no clock to sample.
    private var flowIndicatorSettledElectronColor: Color {
        Self.color(from: electronTint?.settled ?? flowIndicatorAccentRGB)
    }

    private static func color(from rgb: SIMD3<Double>) -> Color {
        Color(.sRGB, red: rgb.x, green: rgb.y, blue: rgb.z, opacity: 1)
    }

    private var modelWorkState: ActivityStripModelWorkPresentation.State {
        let workers = workerStatuses.map { statuses in
            [
                statuses.snapshot(for: .bge).worker,
                statuses.snapshot(for: .qwen).worker,
            ]
        } ?? []
        let hasAppSideModelActivity = appServices?
            .modelActivityStatusPublisher
            .snapshot
            .activities
            .isEmpty == false
        return ActivityStripModelWorkPresentation.state(
            workers: workers,
            hasAppSideModelActivity: hasAppSideModelActivity,
            hasModelWarmupActivity: modelWarmupActivity != nil,
            now: clock
        )
    }

    private func showsPipelineFlowIndicator(
        stages: [PipelineStage],
        modelWork: ActivityStripModelWorkPresentation.State
    ) -> Bool {
        guard !pipelinePaused else { return false }
        let hasActivePipelineWork = stages.contains { stage in
            PipelineActivityPresentation.stageIndicatesActiveWork(status: stage.status)
        }
        let throttles = workerStatuses.map { statuses in
            [
                statuses.snapshot(for: .bge).worker.throttle,
                statuses.snapshot(for: .qwen).worker.throttle,
            ]
        } ?? []
        return ActivityStripModelWorkPresentation.showsElectrons(
            hasActivePipelineWork: hasActivePipelineWork,
            modelWork: modelWork,
            throttles: throttles
        )
    }

    @ViewBuilder
    private func tempoReadoutText(
        readout: TempoReadout,
        transitionIdentity: ActivityStripTempoTransitionIdentity
    ) -> some View {
        HStack(spacing: 4) {
            if let progress = readout.progressText {
                Text(progress)
                    .foregroundStyle(
                        readout.progressColor ?? OhiaColors.textPrimary
                    )
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            // Keep the presentation attached to the state text itself, outside
            // its changing transition identity. Progress counts never move the
            // notch away from the label, and status changes keep the log open.
            ZStack {
                Text(readout.label)
                    .foregroundStyle(readout.progressText == nil ? OhiaColors.textPrimary : OhiaColors.textTertiary)
                    .fontWeight(readout.progressText == nil ? .medium : .regular)
                    .id(transitionIdentity)
                    .transition(.opacity)
            }
            .contentShape(Rectangle())
            .modifier(ActivityStripHoverHelp(
                text: detailedActivityHelp(readout),
                presentation: activityPopover,
                anchorsOwnPopover: false
            ))
            .onTapGesture { activityPopover.showsHistory = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Show Activity Log") { activityPopover.showsHistory = true }
            // Shared by the label's help and the Activity Log. Other sources'
            // help anchors on those sources instead; see `ActivityStripHoverHelp`.
            .popover(isPresented: Binding(
                get: { activityPopover.isShowingSharedPopover },
                // Ignore a stale dismissal once another source owns the help.
                set: { if !$0, activityPopover.isShowingSharedPopover { activityPopover.dismiss() } }
            ), arrowEdge: .bottom) {
                activityPopoverContent
            }
        }
    }

    @ViewBuilder
    private var activityPopoverContent: some View {
        if activityPopover.showsHistory {
            ActivityLogView(model: activityLog, accountNames: activityAccountNames)
                .onHover { activityPopover.hoverPopup($0) }
        } else {
            ActivityStripHelpPopoverText(presentation: activityPopover)
        }
    }

    private var outboxFingerprint: Int {
        var hasher = Hasher()
        for item in outboxItems {
            hasher.combine(item.id)
            hasher.combine(item.status)
        }
        return hasher.finalize()
    }

    private var stages: [PipelineStage] {
        let total = activitySnapshot.total
        let stageTotal = PipelineActivityPresentation.messageStageTotal(
            currentCount: total,
            targetTotal: 0,
            isIngesting: workPhase == .ingesting
        )
        let ingestedCount = total
        let ingestedTotal = stageTotal
        let ingestedCountTotal = PipelineActivityPresentation.messageStageCountTotal(
            currentCount: ingestedCount,
            messageCount: total,
            stageTotal: ingestedTotal
        )
        let datafiedCountTotal = PipelineActivityPresentation.messageStageCountTotal(
            currentCount: activitySnapshot.interpreted,
            messageCount: total,
            stageTotal: stageTotal
        )
        let summaryTotal = summaryProgress.messageTotal > 0 ? summaryProgress.messageTotal : stageTotal
        let summaryCountTotal = PipelineActivityPresentation.messageStageCountTotal(
            currentCount: summaryProgress.messageCompleted,
            messageCount: total,
            stageTotal: summaryTotal
        )

        let createdVectors = placement?.total ?? 0
        let placedCount = placement?.placed ?? 0
        let emailNodeCount = emailNodes?.placed ?? 0
        let trainingProgress = ActivityStripTrainingPresentation.stageProgress(
            for: trainingStatus?.trainingCandidateCorpusProgress ?? .empty
        )

        return [
            PipelineStage(
                label: ingestStageLabel,
                count: ingestedCount,
                total: ingestedTotal,
                countTotal: ingestedCountTotal,
                unit: "messages",
                color: OhiaColors.pipelineIngested,
                status: stageStatus(
                    count: ingestedCount,
                    total: ingestedTotal,
                    isProcessing: isActivelyIngesting || (isIngesting && ingestedTotal == nil)
                ),
                countDisplay: .fraction
            ),
            PipelineStage(
                label: "datafied",
                count: activitySnapshot.interpreted,
                total: stageTotal,
                countTotal: datafiedCountTotal,
                unit: "messages",
                color: OhiaColors.pipelineInterpreted,
                status: stageStatus(
                    count: activitySnapshot.interpreted,
                    total: stageTotal,
                    isProcessing: isInterpretationWorkActive
                ),
                countDisplay: .fraction
            ),
            PipelineStage(
                label: "summarized",
                count: summaryProgress.messageCompleted,
                total: summaryTotal,
                countTotal: summaryCountTotal,
                unit: "summaries",
                color: OhiaColors.pipelineSummarized,
                status: summaryStageStatus,
                countDisplay: .fraction
            ),
            PipelineStage(
                label: "embeddings",
                count: activitySnapshot.embedded,
                total: stageTotal,
                countTotal: stageTotal,
                unit: "messages",
                color: OhiaColors.pipelineEmbedded,
                status: stageStatus(
                    count: activitySnapshot.embedded,
                    total: stageTotal,
                    isProcessing: isEmbeddingWorkActive
                ),
                countDisplay: .countOnly
            ),
            PipelineStage(
                label: "nodes",
                count: emailNodeCount,
                total: emailNodes?.total,
                countTotal: emailNodes?.total,
                unit: "nodes",
                color: OhiaColors.pipelinePlaced,
                status: stageStatus(
                    count: emailNodeCount,
                    total: emailNodes?.total,
                    isProcessing: isEmailNodePlacementActive
                ),
                countDisplay: .countOnly
            ),
            PipelineStage(
                label: "vectors",
                count: placedCount,
                total: createdVectors > 0 ? createdVectors : nil,
                countTotal: createdVectors > 0 ? createdVectors : nil,
                unit: "vectors",
                color: OhiaColors.pipelineCreated,
                status: stageStatus(
                    count: placedCount,
                    total: createdVectors > 0 ? createdVectors : nil,
                    isProcessing: isPlacementWorkActive
                ),
                countDisplay: .countOnly
            ),
            PipelineStage(
                label: ActivityStripTrainingPresentation.stageLabel,
                count: trainingProgress.count,
                total: trainingProgress.total,
                countTotal: trainingProgress.total,
                unit: "messages",
                color: OhiaColors.pipelineTrained,
                status: isTrainingStageWorkActive
                    ? .processing
                    : stageStatus(
                        count: trainingProgress.count,
                        total: trainingProgress.total,
                        isProcessing: false
                    ),
                countDisplay: .fraction
            ),
        ]
    }

    private func stageStatus(
        count: Int,
        total: Int?,
        isProcessing: Bool
    ) -> PipelineActivityStageStatus {
        PipelineActivityPresentation.stageStatus(
            count: count,
            total: total,
            isProcessing: isProcessing
        )
    }

    private var summaryStageStatus: PipelineActivityStageStatus {
        if summaryProgress.messageSummariesAreComplete {
            return .complete
        }
        if summaryProgress.messageCompleted > 0, !isSummaryWorkActive {
            return .partial
        }
        guard bulkSummaryPhaseIsEligible else {
            return .waiting
        }
        guard workPhase == .summarizing else {
            return summaryProgress.messageCompleted > 0 ? .partial : .waiting
        }
        return isSummaryWorkActive ? .processing : .waiting
    }

    // MARK: - Training readout

    /// Training keeps a label-only tempo-gauge readout while it owns the strict
    /// tail; the message-scoped candidate and coverage counts live in its
    /// Messages stage. Pending pair preparation is deliberately visible here:
    /// otherwise a queued downstream tagging row can masquerade as current.
    private var trainingTempoReadout: TempoReadout? {
        guard strictTailActivityLabel == ActivityStripTrainingPresentation.readoutLabel else {
            return nil
        }
        return TempoReadout(
            label: ActivityStripTrainingPresentation.readoutLabel,
            help: trainingReadoutHelp,
            progressText: ActivityStripTrainingPresentation.progressText,
            accountID: ActivityStripReadoutAccountPresentation.accountID(
                for: ActivityStripTrainingPresentation.readoutLabel,
                reportedAccountID: nil,
                queuedMessageAccountID: nil,
                trainingTargetAccountID: activitySnapshot.activeTrainingTargetAccountID
            )
        )
    }

    private var isTrainingActive: Bool {
        guard let pub = trainingStatus else { return false }
        switch pub.phase {
        case .preparing, .training, .checkpointing: return true
        case .idle, .resetting: return false
        }
    }

    private var isTrainingStageWorkActive: Bool {
        ActivityStripTrainingPresentation.isStageWorkActive(
            runningJobTypes: activitySnapshot.runningJobTypes
        )
    }

    private var trainingReadoutHelp: String {
        "Ohia is personalizing the reply model from your sent replies."
    }

    private var strictTailActivityLabel: String? {
        ActivityStripModelWorkPresentation.strictTailActivityLabel(
            hasMeaningMembershipWork: jobDerivations.hasActiveMeaningMembershipJob,
            activeJobTypes: activitySnapshot.pendingJobTypes
                .union(activitySnapshot.runningJobTypes),
            isTrainingActive: isTrainingActive,
            isTaggingActive: isSemanticTaggingActive,
            isDreamingActive: isMemoryDreamingActive,
            isMessagePipelineActive: isPipelineWorkActiveForTempo
        )
    }

    private var strictTailTempoReadout: TempoReadout? {
        guard let strictTailActivityLabel else { return nil }
        switch strictTailActivityLabel {
        case ActivityStripTrainingPresentation.readoutLabel:
            return trainingTempoReadout
        case "waiting":
            return .labelOnly(
                "waiting",
                help: "Ohia is waiting for training resources or inactivity."
            )
        case "tagging":
            return .labelOnly(
                "tagging",
                help: "Ohia is matching related terms to existing tags or creating a new tag."
            )
        case "dreaming":
            return memoryDreamTempoReadout
        default:
            return nil
        }
    }

    private func stageText(_ stage: PipelineStage) -> String {
        if let total = stage.countTotal,
           total > 0 {
            return "\(stage.label): \(stage.count) / \(total) \(stage.unit)"
        }
        return "\(stage.label): \(stage.count) \(stage.unit)"
    }

    private func stageCountText(
        _ stage: PipelineStage,
        density: ActivityStripDensity
    ) -> String {
        guard density.showsStageTotals,
              stage.countDisplay == .fraction,
              let total = stage.countTotal,
              total > 0
        else {
            return "\(stage.count)"
        }
        return "\(stage.count)/\(total)"
    }

    private func stageHelp(_ stage: PipelineStage) -> String {
        switch stage.label {
        case "ingested":
            return "Number of messages Ohia has imported."
        case "datafied":
            return "Number of messages the generative model has categorized and interpreted."
        case "summarized":
            return "Number of messages the generative model has summarized."
        case "embeddings":
            return "Number of messages whose semantic vectors have been created."
        case "nodes":
            return "Number of messages placed as nodes in the Constellation."
        case "vectors":
            return "Number of semantic vectors stored in the index."
        case ActivityStripTrainingPresentation.stageLabel:
            let progress = trainingStatus?.trainingCandidateCorpusProgress ?? .empty
            if !progress.isAssessmentComplete {
                return "Number of sent messages assessed as training candidates."
            }
            return "Number of eligible sent messages incorporated into the promoted reply-model adapter."
        default:
            return "\(stage.label.capitalized) counts mail messages."
        }
    }

    /// Embedded / ingested fraction. Used during the embed phase only.
    private var embeddedFraction: CGFloat {
        let total = activitySnapshot.total
        guard total > 0 else { return 0 }
        return CGFloat(activitySnapshot.embedded) / CGFloat(total)
    }

    /// Placed / total-vector fraction. Used during the placing phase.
    private var placedFraction: CGFloat {
        guard let p = placement, p.total > 0 else { return 0 }
        return CGFloat(p.placed) / CGFloat(p.total)
    }

    /// Single overall pipeline progress for the bottom gauge. This tracks the
    /// bottleneck phase instead of averaging completed cheap phases with the
    /// expensive embedding pass. Otherwise a fully ingested
    /// mailbox can read "mostly done" while embeddings still have most of the
    /// real work left.
    private var overallProgressFraction: CGFloat {
        guard !isProgressIndeterminate else { return 0 }
        switch workPhase {
        case .ingesting:
            return ingestFraction
        case .interpreting:
            return messageStageFraction(activitySnapshot.interpreted)
        case .summarizing:
            return summaryProgressFraction
        case .empty, .complete, .partialFailures:
            break
        }
        let denominator = messageProgressDenominator
        let progress = ActivityStripOverallProgress(
            ingested: activitySnapshot.total,
            interpreted: activitySnapshot.interpreted,
            embedded: activitySnapshot.embedded,
            messageDenominator: denominator,
            placed: placement?.placed ?? 0,
            placementTotal: placement?.total ?? 0
        )
        return CGFloat(progress.fraction)
    }

    private func messageStageFraction(_ count: Int) -> CGFloat {
        let denominator = messageProgressDenominator
        guard denominator > 0 else { return 0 }
        let clamped = min(max(count, 0), denominator)
        return CGFloat(clamped) / CGFloat(denominator)
    }

    private func messageProgressText(_ count: Int) -> String? {
        let denominator = messageProgressDenominator
        guard denominator > 0 else { return nil }
        return "\(min(max(count, 0), denominator))/\(denominator)"
    }

    /// Counts that drive the embedding-state badge: pending = queued for the
    /// scheduler, processing = actively embedding right now, failed = dead-
    /// lettered. `complete` only fires when the entire ingested set has
    /// landed — partial completion stays in the working state.
    private var embedSummary: (pending: Int, processing: Int, failed: Int, embedded: Int, total: Int) {
        (
            activitySnapshot.pendingEmbeds,
            activitySnapshot.processingEmbeds,
            activitySnapshot.failedEmbeds,
            activitySnapshot.embedded,
            activitySnapshot.total
        )
    }

    /// User-facing pipeline state for the primary tempo readout. Message work
    /// advances import -> datafication -> summary. Embedding and
    /// placement still run in parallel and remain visible in the Index chips,
    /// but they should not pull the primary readout backward before summaries.
    private enum WorkPhase { case empty, ingesting, interpreting, summarizing, complete, partialFailures }

    private var workPhase: WorkPhase {
        let s = embedSummary

        guard s.total > 0 else {
            return isIngesting ? .ingesting : .empty
        }

        if importStageIsIncomplete {
            return .ingesting
        }

        let allInterpreted = activitySnapshot.interpreted >= s.total
        if !allInterpreted {
            if activitySnapshot.failedInterpretationJobCount > 0
                && !hasPendingOrRunningJob(types: [.summarize]) {
                return .partialFailures
            }
            return .interpreting
        }

        let allSummarized = rawSummaryProgress.messageSummariesAreComplete
        if !allSummarized {
            return .summarizing
        }

        return .complete
    }

    /// Convenience kept for callers that didn't migrate to `workPhase`.
    private enum EmbedState { case empty, working, complete, partialFailures }
    private var embedState: EmbedState {
        switch workPhase {
        case .empty: return .empty
        case .ingesting, .interpreting, .summarizing: return .working
        case .complete: return .complete
        case .partialFailures: return .partialFailures
        }
    }

    private var activeTempoReadout: TempoReadout {
        let tailOrWarmup = tailOrWarmupTempoPresentation

        if pipelinePaused {
            return .labelOnly(
                ActivityStripPipelinePausePresentation.label,
                help: ActivityStripPipelinePausePresentation.help
            )
        }
        if let sending = activelySendingOutboxItem {
            return .labelOnly(
                "sending mail",
                help: "Ohia is transmitting an email from the outbox.",
                accountID: sending.account?.id
            )
        }
        if let readout = permanentDeleteTempoReadout { return readout }
        if let readout = workerIMAPIndicatorPresentation?.readout { return readout }
        if let readout = leasedIMAPIndicatorPresentation?.readout { return readout }
        if let readout = appSideModelActivityTempoReadout { return readout }
        if let readout = activeGenerationTempoReadout { return readout }
        if let readout = activeQueryEmbeddingTempoReadout { return readout }
        if let readout = constellationModelJobTempoReadout { return readout }
        if isPipelineWorkActiveForTempo {
            return pipelineTempoReadout
        }
        if let tailOrWarmup,
           tailOrWarmup.selection.source == .strictTail,
           tailOrWarmup.selection.label != "waiting" {
            return tailOrWarmup.readout
        }
        if let readout = highPriorityTempoReadout { return readout }
        // Resolve queued-training waiting and model warm-up as one paired
        // presentation. An actively loading model is more informative than a
        // downstream queue that is waiting for it.
        if let tailOrWarmup { return tailOrWarmup.readout }
        if let readout = imapTempoReadout { return readout }
        return pipelineTempoReadout
    }

    private var constellationStripPresentation: ActivityStripTempoPresentation {
        let readout = activeTempoReadout
        let gaugeMode = currentGaugeMode
        let identity = ActivityStripTempoTransitionIdentity(
            label: readout.label,
            gaugeMode: gaugeMode
        )
        let imapActivity = workerIMAPIndicatorPresentation.flatMap { workerPresentation in
            let workerIdentity = ActivityStripTempoTransitionIdentity(
                label: workerPresentation.readout.label,
                gaugeMode: workerPresentation.gaugeMode
            )
            return workerIdentity == identity ? workerIMAPActivityQueue.presented : nil
        }
        return ActivityStripTempoPresentation(
            readout: readout,
            gaugeMode: gaugeMode,
            imapActivity: imapActivity
        )
    }

    /// Composer-mode ladder: outbox transmission > composer-relevant model
    /// activity > model warm-up > ready. The Composer strip narrates only the
    /// work of writing and sending mail — ingestion, IMAP, training, dreaming,
    /// clustering, and the rest of the pipeline stay on the Constellation
    /// strip. Readout and gauge are derived together from one pass over the
    /// sources because `ModelActivityStatusPublisher.snapshot` is wall-clock-
    /// pruned and background-mutated — two reads in one body pass can
    /// disagree, and the motif and the label must always describe the same
    /// work.
    private var composerStripPresentation: ActivityStripTempoPresentation {
        if let sending = activelySendingOutboxItem {
            return ActivityStripTempoPresentation(
                readout: .labelOnly(
                    "sending mail",
                    help: "Ohia is transmitting an email from the outbox.",
                    accountID: sending.account?.id
                ),
                gaugeMode: .sending(
                    accountColorIndex: sending.account?.colorIndex ?? AccountColorPalette.defaultIndex
                )
            )
        }
        if let presentation = workerIMAPIndicatorPresentation,
           let activity = workerIMAPActivityQueue.presented,
           ActivityStripIMAPActivityPresentation.maySurfaceInComposer(activity.kind) {
            return ActivityStripTempoPresentation(
                readout: presentation.readout,
                gaugeMode: presentation.gaugeMode,
                imapActivity: activity
            )
        }
        if let readout = composerModelActivityReadout {
            return ActivityStripTempoPresentation(
                readout: readout,
                gaugeMode: Self.generationGaugeMode(for: readout.label)
            )
        }
        // Model warm-up gates drafting, so it outranks the idle baseline:
        // "loading" explains why a draft hasn't started yet.
        if let readout = modelLoadTempoReadout, let gaugeMode = modelLoadGaugeMode {
            return ActivityStripTempoPresentation(readout: readout, gaugeMode: gaugeMode)
        }
        return ActivityStripTempoPresentation(
            readout: .labelOnly(
                "ready",
                help: "Ohia is ready to write, revise, translate, or send mail."
            ),
            gaugeMode: .signal(.ready)
        )
    }

    /// The first target-scoped model-activity readout whose label names
    /// Composer work. Global publisher and worker heartbeats have no target
    /// identity, so they remain visible only in the Constellation ladder.
    private var composerModelActivityReadout: TempoReadout? {
        [
            (ComposerActivitySource.appSidePublisher, appSideModelActivityTempoReadout),
            (ComposerActivitySource.workerGeneration, activeGenerationTempoReadout),
            (ComposerActivitySource.workerQueryEmbedding, activeQueryEmbeddingTempoReadout),
            (ComposerActivitySource.durableTargetedJob, composerModelJobTempoReadout),
        ]
        .first {
            Self.composerActivityMaySurface(source: $0.0)
                && $0.1.map { Self.isComposerActivityLabel($0.label) } == true
        }?
        .1
    }

    private var activeGenerationTempoReadout: TempoReadout? {
        guard let worker = workerStatuses?.snapshot(for: .qwen).worker,
              PipelineActivityPresentation.workerRecentlyActive(
                  worker,
                  for: ["generation"],
                  now: clock,
                  recentCompletionWindow: 15
              )
        else {
            return nil
        }

        let label = ActivityStripModelWorkPresentation.generationActivityLabel(
            normalizedLabel: normalizedGenerationActivityLabel(worker.currentJobDescription),
            currentJobType: worker.currentJobType,
            currentJobDescription: worker.currentJobDescription,
            hasRunningAttachmentSummaryJob: hasRunningJob(types: [.summarizeAttachments])
        )
        return TempoReadout(
            label: label,
            help: generationActivityHelp(label),
            progressText: nil
        )
    }

    private var appSideModelActivityTempoReadout: TempoReadout? {
        guard let activity = appServices?
            .modelActivityStatusPublisher
            .snapshot
            .visibleActivities
            .first
        else {
            return nil
        }
        let label = activity.source == "attachment-summary"
            ? "digesting"
            : normalizedGenerationActivityLabel(activity.kind.label)
        return TempoReadout(
            label: label,
            help: generationActivityHelp(label),
            progressText: nil,
            accountID: activity.accountID
        )
    }

    private var activeQueryEmbeddingTempoReadout: TempoReadout? {
        guard let worker = workerStatuses?.snapshot(for: .bge).worker,
              PipelineActivityPresentation.workerRecentlyActive(
                  worker,
                  for: ["queryEmbedding"],
                  now: clock,
                  recentCompletionWindow: 15
              )
        else {
            return nil
        }
        return TempoReadout(
            label: "retrieving",
            help: "Ohia is finding and ranking relevant evidence for the current request.",
            progressText: nil
        )
    }

    /// Startup model warm-up: the on-device generative (Qwen) or retrieval
    /// (bge-m3) model still loading into memory or downloading after the splash
    /// has handed off to the main shell. `nil` once both are ready (or in any
    /// non-busy state). Pure reduction lives in `PipelineActivityPresentation`.
    private var modelWarmupActivity: PipelineActivityPresentation.ModelWarmupActivity? {
        guard let workerStatuses else { return nil }
        return ActivityStripModelWorkPresentation.modelWarmupActivity(
            generative: workerStatuses.snapshot(for: .qwen).worker.model,
            retrieval: workerStatuses.snapshot(for: .bge).worker.model
        )
    }

    private var modelLoadTempoReadout: TempoReadout? {
        switch modelWarmupActivity {
        case .loading:
            return TempoReadout(
                label: "loading",
                help: "Ohia is loading an on-device model into memory.",
                progressText: nil
            )
        case .downloading(let fraction):
            let clamped = min(max(fraction, 0), 1)
            return TempoReadout(
                label: "downloading",
                help: "Ohia is downloading an on-device model needed for local intelligence.",
                progressText: "\(Int((clamped * 100).rounded()))%"
            )
        case nil:
            return nil
        }
    }

    /// Gauge motif matching `modelLoadTempoReadout`. Loading is indeterminate
    /// (`kindling(fraction: nil)`); downloading rides a determinate fill lane.
    private var modelLoadGaugeMode: GaugeMode? {
        switch modelWarmupActivity {
        case .loading:
            // Loading (indeterminate) uses the blocks-docking motif; downloading
            // (determinate) keeps the kindle motif over its progress fill.
            return .docking
        case .downloading(let fraction):
            return .kindling(fraction: min(max(fraction, 0), 1))
        case nil:
            return nil
        }
    }

    private var tailOrWarmupTempoPresentation: (
        selection: ActivityStripModelWorkPresentation.TailOrWarmupPresentation,
        readout: TempoReadout
    )? {
        guard let selection = ActivityStripModelWorkPresentation.tailOrWarmupPresentation(
            strictTailActivityLabel: strictTailActivityLabel,
            modelWarmupActivity: modelWarmupActivity
        ) else { return nil }

        let readout: TempoReadout?
        switch selection.source {
        case .strictTail:
            readout = strictTailTempoReadout
        case .modelWarmup:
            readout = modelLoadTempoReadout
        }
        guard let readout, readout.label == selection.label else { return nil }
        return (selection, readout)
    }

    private var modelJobTempoReadout: TempoReadout? {
        runningModelJobTempoReadout ?? pendingModelJobTempoReadout
    }

    /// Composer narration is independent of the system-wide model winner.
    /// If training or another pipeline job is running, continue through the
    /// durable queue until the first running or pending Composer job is found.
    /// The Constellation path deliberately continues to use
    /// `constellationModelJobTempoReadout` and retains its full-system view.
    private var composerModelJobTempoReadout: TempoReadout? {
        let visibleModelJobs = isPipelineWorkActiveForTempo
            ? jobDerivations.visibleModelJobsWhilePipelineActive
            : jobDerivations.visibleModelJobsWhilePipelineIdle
        for status in [JobStatus.running.rawValue, JobStatus.pending.rawValue] {
            for job in visibleModelJobs where job.status == status
                && Self.isComposerModelJobType(job.type)
                && Self.composerJobBelongsToActiveTarget(
                    jobMessageID: job.messageID,
                    activeMessageID: composerTarget.messageID,
                    hasActiveComposerTarget: composerTarget.isActive
                ) {
                guard let readout = modelJobReadout(for: job) else { continue }
                if Self.composerActivityLabel(
                    runningLabels: status == JobStatus.running.rawValue ? [readout.label] : [],
                    pendingLabels: status == JobStatus.pending.rawValue ? [readout.label] : []
                ) != nil {
                    return readout
                }
            }
        }
        return nil
    }

    /// Constellation has dedicated readouts for live dreaming and training.
    /// A queued model job is held work, not execution, so it must not obscure
    /// the strict tail's authoritative stage. Running on-demand work still
    /// wins; a stale downstream tail row does not outrank an earlier tail stage.
    private var constellationModelJobTempoReadout: TempoReadout? {
        if let runningModelJobTempoReadout {
            let tailLabels: Set<String> = ["clustering", "training", "tagging", "dreaming"]
            if tailLabels.contains(runningModelJobTempoReadout.label),
               let strictTailActivityLabel,
               strictTailActivityLabel != runningModelJobTempoReadout.label {
                return nil
            }
            return runningModelJobTempoReadout
        }
        guard let pendingModelJobTempoReadout,
              Self.pendingActivityCanLeadConstellation(
                  label: pendingModelJobTempoReadout.label
              )
        else {
            return nil
        }
        return pendingModelJobTempoReadout
    }

    private var runningModelJobTempoReadout: TempoReadout? {
        let visibleModelJobs = isPipelineWorkActiveForTempo
            ? jobDerivations.visibleModelJobsWhilePipelineActive
            : jobDerivations.visibleModelJobsWhilePipelineIdle

        for running in visibleModelJobs where
            running.status == JobStatus.running.rawValue
                && (running.type != JobType.accountMemoryRefresh.rawValue || isMemoryDreamingActive)
                && (running.type != JobType.resolveSemanticTags.rawValue || isSemanticTaggingActive) {
            if let readout = modelJobReadout(for: running) {
                return readout
            }
        }
        return nil
    }

    private var pendingModelJobTempoReadout: TempoReadout? {
        guard !isPipelineWorkActiveForTempo else { return nil }
        for pending in jobDerivations.visibleModelJobsWhilePipelineIdle where
            pending.status == JobStatus.pending.rawValue
                && ActivityStripModelWorkPresentation.pendingModelJobCanLead(
                    jobType: pending.type,
                    hasActiveDedicatedActivity: strictTailTempoReadout != nil
                ) {
            if let readout = modelJobReadout(for: pending) {
                return readout
            }
        }
        return nil
    }

    private func modelJobReadout(for job: PipelineActivityJobSnapshot) -> TempoReadout? {
        let composerStage = composerDraftStageRaw(for: job)
        let replyPreparationStatus = job.messageID.flatMap {
            jobDerivations.replyPreparationStatusByMessageID[$0]
        }
        let hasActiveReplySourcePreparation = job.messageID.map {
            jobDerivations.activeReplySourcePreparationMessageIDs.contains($0)
        } ?? false
        guard let label = ActivityStripModelWorkPresentation.activityLabel(
            forJobType: job.type,
            composerDraftStageRaw: composerStage,
            replyPreparationStatusRaw: replyPreparationStatus,
            hasActiveReplySourcePreparation: hasActiveReplySourcePreparation
        ) else {
            return nil
        }
        return TempoReadout(
            label: label,
            help: modelJobHelp(label: label),
            progressText: nil,
            accountID: job.accountID
        )
    }

    private func composerDraftStageRaw(for job: PipelineActivityJobSnapshot) -> String? {
        guard job.type == JobType.generateDraft.rawValue
                || job.type == JobType.prepareReplySources.rawValue
        else { return nil }
        if let messageID = job.messageID {
            return jobDerivations.composerDraftStageByMessageID[messageID]
        }
        return job.type == JobType.generateDraft.rawValue
            ? jobDerivations.standaloneComposerDraftStageRaw
            : nil
    }

    /// Resolves the stage represented by a generic `.generateDraft` drain.
    /// Reply jobs can name their message directly; new-message drafts cannot,
    /// because `.userCompose` intentionally has no `Message` relationship.
    /// Mirror the orchestrator's compose-first ordering so a queued source
    /// research pass is presented as compiling rather than the nil-stage
    /// drafting fallback.
    @MainActor
    static func composerDraftStageRaw(
        forMessageID messageID: UUID?,
        context: ModelContext,
        now: Date = Date()
    ) -> String? {
        // Worker-process writes do not reliably invalidate a long-lived
        // SwiftData context. Presentation must read the durable stage through
        // a fresh context or an evaluating-sources Draft falls back to the
        // misleading nil-stage "drafting" label.
        let context = ModelContext(context.container)
        return composerDraftStageRaw(
            forMessageID: messageID,
            authoritativeContext: context,
            now: now
        )
    }

    /// The caller owns freshness and invocation cadence. ActivityStrip's live
    /// path calls this only while applying its store snapshot, not while the
    /// animated gauge is rendering.
    @MainActor
    private static func composerDraftStageRaw(
        forMessageID messageID: UUID?,
        authoritativeContext context: ModelContext,
        now: Date
    ) -> String? {
        if let messageID {
            var descriptor = FetchDescriptor<Draft>(
                predicate: #Predicate<Draft> { draft in
                    draft.message?.id == messageID
                }
            )
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first?.resolvedStage
        }

        var descriptor = FetchDescriptor<Draft>(
            predicate: #Predicate<Draft> { draft in
                draft.message == nil
            },
            sortBy: [SortDescriptor(\Draft.generatedAt, order: .reverse)]
        )
        // A standalone compose is user-created and the visible one is among
        // the newest rows. Bound this main-actor presentation query so a
        // large historical Draft table can never become SwiftUI render work.
        descriptor.fetchLimit = 128
        let drafts = (try? context.fetch(descriptor)) ?? []
        let activeDraft = drafts
            .filter { draft in
                draft.kind == .userCompose
                    && draft.status == .pending
                    && (draft.nextGenerationAttemptAt ?? .distantPast) <= now
                    && standaloneComposeOwesModelWork(draft)
            }
            .sorted { $0.generatedAt < $1.generatedAt }
            .first
        guard let activeDraft else { return nil }
        if activeDraft.isAutomaticSourceResearchPending {
            return DraftStage.collectingSources
        }
        return activeDraft.resolvedStage
    }

    @MainActor
    private static func standaloneComposeOwesModelWork(_ draft: Draft) -> Bool {
        if draft.pendingInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false {
            return true
        }
        if draft.pendingStyleRegisterID != nil,
           (draft.revisions ?? []).isEmpty == false {
            return true
        }

        let hasBrief = (draft.composeInstruction ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasRecipient = (ComposeAddressEncoding.decode(draft.composeToJSON).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasSubject = (draft.composeSubject ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false

        if draft.isAutomaticSourceResearchPending {
            return hasRecipient && hasSubject
        }
        if draft.resolvedStage == DraftStage.evaluatingSources {
            return hasBrief
        }
        if draft.resolvedStage == DraftStage.generating {
            return hasBrief && hasRecipient
        }
        return false
    }

    private func normalizedGenerationActivityLabel(_ rawValue: String?) -> String {
        let trimmed = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let displayLabel = ActivityStripModelWorkPresentation.displayLabel(trimmed)
        let labels: Set<String> = [
            "generating",
            "summarizing",
            "digesting",
            "translating",
            "asking",
            "drafting",
            "compiling",
            "formulating",
            "categorizing",
            "tagging",
            "extracting",
            "remembering",
            "dreaming",
            "refining",
            "learning",
            "clustering",
        ]
        if labels.contains(displayLabel) {
            return displayLabel
        }
        if displayLabel == "generating text" {
            return "generating"
        }
        return "generating"
    }

    private func generationActivityHelp(_ label: String) -> String {
        switch label {
        case "translating":
            return "Ohia is translating the email."
        case "summarizing":
            return "Ohia is writing a summary."
        case "digesting":
            return "Ohia is condensing attachment content into a useful summary."
        case "asking":
            return "Ohia is answering your Ask request from the available mail evidence."
        case "drafting":
            return "Ohia is writing or revising your draft."
        case "compiling":
            return "Ohia is gathering, evaluating, and researching sources for your draft."
        case "formulating":
            return "Ohia is checking sources and preparing clarification questions."
        case "categorizing":
            return "Ohia is defining a custom mail category."
        case "tagging":
            return "Ohia is matching related terms to existing tags or creating a new tag."
        case "extracting":
            return "Ohia is converting attachment content into structured evidence."
        case "remembering":
            return "Ohia is updating writing and translation memories from completed mail."
        case "dreaming":
            return "Ohia is updating account memories from your mail for later writing context."
        case "refining":
            return "Ohia is updating its understanding of an active project."
        case "learning":
            return "Ohia is learning drafting rules and writing styles from your sent mail."
        case "clustering":
            return "Ohia is assigning meaningful titles to groups of related emails."
        default:
            return "Ohia is handling an on-demand model request."
        }
    }

    private func modelJobHelp(label: String) -> String {
        switch label {
        case "embedding":
            return "Ohia is converting mail and entity evidence into semantic vectors."
        case "captioning":
            return "Ohia is describing image attachments for later search and summarization."
        case "summarizing":
            return "Ohia is writing rich summaries for message hovers and expanded views."
        case "drafting":
            return "Ohia is writing or revising your draft."
        case "compiling":
            return "Ohia is gathering, evaluating, and researching sources for your draft."
        case "formulating":
            return "Ohia is checking sources and preparing clarification questions."
        case "categorizing":
            return "Ohia is defining a custom mail category."
        case "tagging":
            return "Ohia is matching related terms to existing tags or creating a new tag."
        case "digesting":
            return "Ohia is condensing attachment content into a useful summary."
        case "learning":
            return "Ohia is learning drafting rules and writing styles from your sent mail."
        case "training":
            return "Ohia is personalizing the reply model from your sent replies."
        case "refining":
            return "Ohia is adjusting the arrangement of nodes in the Constellation."
        case "dreaming":
            return "Ohia is updating account memories from your mail for later writing context."
        case "extracting":
            return "Ohia is converting attachment content into structured evidence."
        default:
            return "Ohia is handling an on-demand model request."
        }
    }

    private var shouldDreamingOverridePipelineReadout: Bool {
        return PipelineActivityPresentation.dreamingReadoutShouldOverridePipeline(
            isPipelineWorkActive: isPipelineWorkActiveForTempo
        )
    }

    private var isPipelineWorkActiveForTempo: Bool {
        switch workPhase {
        case .empty, .complete:
            return false
        case .ingesting, .interpreting, .summarizing, .partialFailures:
            return true
        }
    }

    private var pipelineTempoReadout: TempoReadout {
        var engagement = jobDerivations.pipelineAccountEngagement
        if let statuses = imapSessionManager?.statusByAccount {
            for (accountID, status) in statuses {
                if case .syncing = status {
                    engagement.observeIngestion(accountID: accountID)
                }
            }
        }
        let queuedMessageAccountID: UUID?
        switch overallPhaseLabel {
        case "datafying":
            queuedMessageAccountID = activitySnapshot.nextPendingInterpretationAccountID
        case "summarizing":
            queuedMessageAccountID = activitySnapshot.nextPendingBodySummaryAccountID
        default:
            queuedMessageAccountID = nil
        }
        let reportedAccountID = engagement.accountID(for: overallPhaseLabel)
        return TempoReadout(
            label: overallPhaseLabel,
            help: pipelineStateHelp,
            progressText: pipelineProgressText,
            accountID: ActivityStripReadoutAccountPresentation.accountID(
                for: overallPhaseLabel,
                reportedAccountID: reportedAccountID,
                queuedMessageAccountID: queuedMessageAccountID,
                trainingTargetAccountID: nil
            )
        )
    }

    /// Pipeline progress for the tempo readout. The persisted initial IMAP UID
    /// snapshot is the only ingestion denominator. Later historical backfill
    /// is intentionally indeterminate and uses the flow vocabulary.
    /// Ordinary steady-state processing of newly arrived mail through
    /// datafying/summarizing (seed and backfill both complete) never shows a
    /// percentage, even though `shouldShowDeterminateProgressGauge` is true
    /// almost any time there's a nonzero message count — that gate answers
    /// "is a denominator known," not "are we in first-time/historical
    /// catch-up," so it alone is not a sufficient guard here. Message stage
    /// counts still additionally live in the Messages group chips.
    private var pipelineProgressText: String? {
        switch workPhase {
        case .ingesting:
            guard case .mass = corpusPhase.gauge else { return nil }
            return pipelineProgressPercentText
        case .interpreting, .summarizing:
            guard shouldShowDeterminateProgressGauge,
                  isInitialIMAPImportIncomplete || isHistoricalIMAPBackfillStage
            else { return nil }
            return pipelineProgressPercentText
        case .empty, .complete, .partialFailures:
            return nil
        }
    }

    private var pipelineProgressPercentText: String {
        ActivityStripTempoProgressText.text(
            fraction: Double(overallProgressFraction),
            isBottleneckComplete: pipelineBottleneckIsComplete
        )
    }

    /// True when the count driving the current `workPhase` has reached its
    /// target — the gate that allows a `100%` tempo readout for that phase.
    private var pipelineBottleneckIsComplete: Bool {
        let denominator = messageProgressDenominator
        switch workPhase {
        case .ingesting:
            return false
        case .interpreting:
            guard denominator > 0 else { return false }
            return activitySnapshot.interpreted >= denominator
        case .summarizing:
            return summaryProgress.messageSummariesAreComplete
        case .partialFailures, .empty, .complete:
            return false
        }
    }

    private var overallPhaseLabel: String {
        switch workPhase {
        case .empty:
            return "waiting"
        case .ingesting:
            return corpusPhase.label
        case .interpreting:
            return "datafying"
        case .summarizing:
            return "summarizing"
        case .complete:
            return "idling"
        case .partialFailures:
            return "attention"
        }
    }

    private var imapTempoReadout: TempoReadout? {
        guard shouldShowIMAPTempoReadout else { return nil }

        if let highPriority = highPriorityTempoReadout {
            return highPriority
        }
        guard !isPipelineWorkActiveForTempo else { return nil }
        if hasIdlingIMAPSession {
            return .labelOnly(
                "watching",
                help: "Ohia is watching the mail server for new mail and deletions."
            )
        }
        return .labelOnly(
            "waiting",
            help: "Ohia is waiting for the next mail or processing task to begin."
        )
    }

    private var highPriorityTempoReadout: TempoReadout? {
        guard shouldShowIMAPTempoReadout else { return nil }

        if let transientReadout = transientIMAPEventReadout {
            return transientReadout
        }
        if let statusReadout = imapSessionStatusReadout {
            return statusReadout
        }
        if let jobReadout = activeIMAPJobReadout {
            return jobReadout
        }
        if let deletionReadout = deletionTempoReadout {
            return deletionReadout
        }
        return nil
    }

    /// The current IMAP report as one paired label + animation. A new identity
    /// receives one short presentation lease; observing the same sustained
    /// state again cannot renew that lease and starve longer-running model work.
    private var activeIMAPIndicatorPresentation: ActivityStripIMAPIndicatorPresentation? {
        guard let readout = highPriorityTempoReadout,
              let gaugeMode = imapIndicatorGaugeMode(for: readout.label)
        else { return nil }

        let eventStartedAt: Date? = switch readout.label {
        case "forming": newMailEvent.startedAt
        case "checking": imapCheckEvent.startedAt
        case "reconciling": deletionEvent.isActive(
            at: clock,
            duration: PipelineActivityPresentation.activityDeletionUpdatedEventDuration
        ) ? deletionEvent.startedAt : nil
        default: nil
        }

        return ActivityStripIMAPIndicatorPresentation(
            identity: ActivityStripIMAPIndicatorIdentity(
                label: readout.label,
                eventStartedAt: eventStartedAt
            ),
            readout: readout,
            gaugeMode: gaugeMode
        )
    }

    private var leasedIMAPIndicatorPresentation: ActivityStripIMAPIndicatorPresentation? {
        guard let presentation = activeIMAPIndicatorPresentation,
              imapIndicatorLease.isPresenting(presentation.identity, at: clock)
        else { return nil }
        return presentation
    }

    private var workerIMAPIndicatorPresentation: ActivityStripIMAPIndicatorPresentation? {
        guard let activity = workerIMAPActivityQueue.presented else {
            return nil
        }
        let spec = ActivityStripIMAPActivityPresentation.spec(for: activity.kind)
        let presentationStartedAt = workerIMAPActivityQueue.presentationStartedAt
            ?? activity.occurredAt
        return ActivityStripIMAPIndicatorPresentation(
            identity: ActivityStripIMAPIndicatorIdentity(
                label: spec.label,
                eventStartedAt: presentationStartedAt
            ),
            readout: .labelOnly(
                spec.label,
                help: activity.kind == .needsAttention
                    ? attentionHelp(for: activity) : spec.help,
                accountID: activity.accountID
            ),
            gaugeMode: ActivityStripIMAPActivityPresentation.gaugeMode(
                for: activity,
                presentationStartedAt: presentationStartedAt
            )
        )
    }

    private func consumeWorkerIMAPActivity(at now: Date) {
        guard let worker = workerStatuses?.snapshot(for: .bge).worker else { return }
        let result = workerIMAPActivityTracker.consume(worker, observedAt: now)
        if result.requiresFullReconciliation {
            workerIMAPActivityQueue.resetForFullReconciliation()
        }
        let activities = ActivityStripIMAPActivityPresentation.activities(
            for: mode,
            from: result.activities
        )
        guard activities.isEmpty == false else { return }
        workerIMAPActivityQueue.ingest(
            activities,
            at: now,
            reduceMotion: reduceMotion,
            mode: mode
        )
    }

    private func imapIndicatorGaugeMode(for label: String) -> GaugeMode? {
        switch label {
        case "forming":
            guard let stamp = newMailEvent.startedAt else { return nil }
            return .signal(.newMail(eventStart: stamp, count: max(1, newMailEvent.count)))
        case "checking":
            return .signal(.syncing(folder: nil))
        case "reconciling":
            if deletionEvent.isActive(
                at: clock,
                duration: PipelineActivityPresentation.activityDeletionUpdatedEventDuration
            ), let stamp = deletionEvent.startedAt {
                return .signal(.deletionsUpdated(eventStart: stamp, count: max(1, deletionEvent.count)))
            }
            let pending = appServices?.deletionSyncStatusPublisher.snapshot.pendingDeletionCount ?? 0
            return .signal(.deletionsPending(count: max(1, pending)))
        case "attention":
            return .signal(.needsAttention)
        case "reconnecting":
            let attempt = imapSessionManager?.statusByAccount.values.compactMap { status -> Int? in
                if case .reconnecting(let attempt) = status { return attempt }
                return nil
            }.first ?? 1
            return .signal(.reconnecting(attempt: attempt))
        case "connecting":
            return .signal(.connecting)
        case "authenticating":
            return .signal(.authing)
        case "syncing":
            let folder = syncingIMAPSession?.folder
            return .signal(
                hasActiveGapCheckJob
                    ? .checkingGaps(folder: folder)
                    : .syncing(folder: folder)
            )
        case "backfilling":
            return .flow
        case "gap checking":
            let folder = firstRunningIMAPJobFolder
            return .signal(.checkingGaps(folder: folder))
        case "polling":
            let folder = runningPollFolderJob.flatMap { normalizedFolderName($0.payload?.folderName) }
            return .signal(.polling(folder: folder))
        case "verifying":
            let folder = runningDeletionWatchJob.flatMap { normalizedFolderName($0.payload?.folderName) }
            return .signal(.verifyingDeletions(folder: folder))
        case "pending":
            return .signal(.pending)
        default:
            return nil
        }
    }

    private var firstRunningIMAPJobFolder: String? {
        let folderName = jobDerivations.relevantIMAPJobs.first(where: {
            $0.job.status == JobStatus.running.rawValue
        })?.payload?.folderName
        return normalizedFolderName(folderName)
    }

    private func normalizedFolderName(_ folderName: String?) -> String? {
        let normalized = folderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    private var memoryDreamTempoReadout: TempoReadout? {
        let memoryProgress = memoryRefreshProgress
        guard isMemoryDreamingActive else { return nil }
        return .labelOnly(
            "dreaming",
            help: "Ohia is updating account memories from your mail for later writing context.",
            accountID: memoryProgress.runningAccountID
        )
    }

    // MARK: - Gauge mode

    /// True when an active `.imapPollFolder` job carries `gapCheck == true`
    /// in its payload — the signal that distinguishes a "checking gaps"
    /// pass from a regular folder poll. Shared by `currentGaugeMode` and
    /// `activeIMAPJobReadout` so the predicate stays in one place.
    ///
    /// Note: `activeIMAPJobReadout` tests gapCheck on the single selected
    /// job's own payload rather than scanning all active jobs, so it does
    /// NOT use this helper — the two sites have different structural intent.
    private var hasActiveGapCheckJob: Bool {
        jobDerivations.hasActiveGapCheckJob
    }

    /// A running (non-gap-check) `.imapPollFolder` job, for the gauge's radar
    /// "polling" motif. Mirrors `activeIMAPJobReadout`'s running poll branch
    /// (which yields the "polling" label) so the gauge and label agree instead of
    /// the poll falling through to the warm-up / steady gauge. Session
    /// `.syncing` / `.connecting` / `.authing` already win earlier in
    /// `currentGaugeMode`; gap-check polls use the `.checkingGaps` motif.
    private var runningPollFolderJob: ActivityStripJobDerivations.RelevantIMAPJob? {
        guard shouldShowIMAPTempoReadout else { return nil }
        // Mirror `activeIMAPJobReadout` EXACTLY: the label reflects the FIRST
        // running relevant job (not "the poll among the running jobs"). Only show
        // the polling radar when that first running job is itself a non-gap-check
        // poll — otherwise the label is "backfilling" / "gap checking" /
        // "verifying", and the gauge must not claim "polling". Selecting the
        // poll independently here would let the gauge read "polling" while a
        // concurrently-running deletion-watch or gap-check sorts first and drives
        // the label to a different word.
        guard let firstRunning = jobDerivations.relevantIMAPJobs.first(where: {
            $0.job.status == JobStatus.running.rawValue
        }) else { return nil }
        guard firstRunning.job.type == JobType.imapPollFolder.rawValue,
              firstRunning.payload?.gapCheck != true
        else { return nil }
        return firstRunning
    }

    /// A running deletion-watch job, for the gauge's SELECT-only verification
    /// pulse. Mirrors `activeIMAPJobReadout` EXACTLY (the first running relevant
    /// job), so the gauge only claims the deletion-watch motif when the label is
    /// "verifying" — not when a poll or backfill sorts first.
    private var runningDeletionWatchJob: ActivityStripJobDerivations.RelevantIMAPJob? {
        guard shouldShowIMAPTempoReadout else { return nil }
        guard let firstRunning = jobDerivations.relevantIMAPJobs.first(where: {
            $0.job.status == JobStatus.running.rawValue
        }) else { return nil }
        guard firstRunning.job.type == JobType.imapDeletionWatch.rawValue else { return nil }
        return firstRunning
    }

    private var currentGaugeMode: GaugeMode {
        let tailOrWarmup = tailOrWarmupTempoPresentation

        if pipelinePaused {
            return ActivityStripPipelinePausePresentation.gaugeMode
        }
        if let item = activelySendingOutboxItem {
            return .sending(
                accountColorIndex: item.account?.colorIndex ?? AccountColorPalette.defaultIndex
            )
        }
        // Active foreground mailbox commands outrank model-side status so
        // explicit delete feedback is not hidden by unrelated refinement.
        if permanentDeleteEvent.isActive(
            at: clock,
            duration: PipelineActivityPresentation.activityPermanentDeleteEventDuration
        ), let stamp = permanentDeleteEvent.startedAt {
            return .signal(.deletionsUpdated(eventStart: stamp, count: max(1, permanentDeleteEvent.count)))
        }
        if activitySnapshot.activePermanentDeleteMutationCount > 0 {
            return .signal(.deletionsPending(count: activitySnapshot.activePermanentDeleteMutationCount))
        }
        if let presentation = workerIMAPIndicatorPresentation {
            return presentation.gaugeMode
        }
        // Each newly observed IMAP state receives a bounded turn before model
        // work resumes. The lease is not renewed while the same state remains.
        if let presentation = leasedIMAPIndicatorPresentation {
            return presentation.gaugeMode
        }
        // Active on-demand or non-pipeline model work. These have no stable
        // denominator. Each known activity carries its own indigo→cyan motif
        // (read off the active readout's label, in the same source precedence as
        // `activeTempoReadout`); any other generation label keeps the steady
        // weight-spectrum form while the readout supplies the one-word label.
        if let generationReadout = appSideModelActivityTempoReadout
            ?? activeGenerationTempoReadout
            ?? activeQueryEmbeddingTempoReadout {
            return Self.generationGaugeMode(for: generationReadout.label)
        }
        if let generationReadout = constellationModelJobTempoReadout {
            return Self.generationGaugeMode(for: generationReadout.label)
        }
        // 3. Corpus phase. The Core reducer owns initial-import/backfill
        // precedence and its motion contract. Waiting historical work freezes
        // on the ready dot instead of borrowing a lower-priority session sweep.
        if isPipelineWorkActiveForTempo {
            if let mode = ActivityStripCorpusGaugeMode.mode(for: corpusPhase.gauge) {
                return mode
            }
            if isInitialIMAPImportIncomplete || corpusHistoricalWork == .waiting {
                return .signal(.ready)
            }
        }
        // Model-bearing ingestion tails are also sustained work. After the
        // short IMAP lease above, they regain both the label and gauge.
        if let tailOrWarmup,
           tailOrWarmup.selection.source == .strictTail {
            return tailOrWarmup.selection.gaugeMode
        }
        // With no competing sustained work, keep showing the current IMAP
        // report after its lease. The same paired presentation drives both
        // label and animation, including gap checks and historical backfill.
        if let presentation = activeIMAPIndicatorPresentation {
            return presentation.gaugeMode
        }
        // 7. Determinate pipeline progress. The stage chips show the detailed
        // per-phase counts; the gauge remains the overall bottleneck readout
        // while interpretation, embedding, or placement advances.
        // Each datafied/summarizing phase carries its own motif over
        // the same blue→green determinate fill; other phases keep the mass fill.
        if shouldShowDeterminateProgressGauge {
            let fraction = Double(overallProgressFraction)
            switch workPhase {
            case .interpreting: return .distill(fraction: fraction)
            case .summarizing:  return .precis(fraction: fraction)
            case .empty, .ingesting, .complete, .partialFailures:
                return .mass(fraction: fraction)
            }
        }
        // Model warm-up (load / download outlasting the splash). Text and
        //     gauge come from the same paired tail-or-warm-up selection. This
        //     MUST sit below every gauge state that the readout's
        //     `highPriorityTempoReadout` outranks the warm-up presentation with —
        //     not just the active session / transient / flow states above, but
        //     also the pending-IMAP Hold (7.5) and the pending-deletion
        //     "reconciling" case just above (both are inside
        //     `highPriorityTempoReadout` in the readout). It still beats the idle
        //     watching / ready states below. If the gauge and label disagree
        //     here, it's because this block drifted above one of those cases —
        //     keep it in lockstep with `modelLoadTempoReadout`'s placement.
        if let tailOrWarmup,
           tailOrWarmup.selection.source == .modelWarmup {
            return tailOrWarmup.selection.gaugeMode
        }
        if hasIdlingIMAPSession {
            return .signal(.watching)
        }
        if hasConfiguredIMAPIngestion {
            return .signal(.ready)
        }
        // 9. Fallback: ready (no IMAP at all → still render the dim baseline)
        return .signal(.ready)
    }

    /// The worker persists `.sending` immediately before awaiting SMTP, so this
    /// is the exact active-transmission window rather than merely queued mail.
    private var activelySendingOutboxItem: OutboxItem? {
        outboxItems
            .filter { $0.status == .sending }
            .min { $0.createdAt < $1.createdAt }
    }

    /// Model-activity labels that describe the work of writing and sending
    /// mail: drafting, "compiling" (Composer source triage and web-research
    /// planning, ahead of the Continue button), "formulating" (the
    /// clarification-question pass once sources are submitted), the
    /// correspondent-summary pass for new mail, translation, exemplar
    /// retrieval, and the sent-mail personalization lanes
    /// (drafting-rules / style distillation and writing/translation memory
    /// updates). "extracting" is deliberately absent — it is emitted only by
    /// background receipt extraction, a pipeline lane. The Composer strip
    /// shows only these plus outbox transmission and model warm-up; every
    /// other readout stays on the Constellation strip.
    nonisolated static let composerActivityLabels: Set<String> = [
        "drafting",
        "compiling",
        "formulating",
        "summarizing",
        "translating",
        "remembering",
        "learning",
        "retrieving",
    ]

    nonisolated static func isComposerActivityLabel(_ label: String) -> Bool {
        composerActivityLabels.contains(ActivityStripModelWorkPresentation.displayLabel(label))
    }

    /// Selects Composer work by its own running-then-pending priority instead
    /// of accepting the model queue's system-wide winner.
    nonisolated static func composerActivityLabel(
        runningLabels: [String],
        pendingLabels: [String]
    ) -> String? {
        (runningLabels + pendingLabels)
            .map(ActivityStripModelWorkPresentation.displayLabel)
            .first(where: isComposerActivityLabel)
    }

    nonisolated static func isComposerModelJobType(_ typeRaw: String) -> Bool {
        typeRaw == JobType.generateDraft.rawValue
            || typeRaw == JobType.prepareReplySources.rawValue
    }

    /// The global publisher and worker heartbeats identify the kind of model
    /// work but not the message or standalone Draft that owns it. Composer can
    /// therefore trust only the durable job already matched to its active
    /// target; the Constellation strip continues to narrate every source.
    nonisolated static func composerActivityMaySurface(
        source: ComposerActivitySource
    ) -> Bool {
        source == .durableTargetedJob
    }

    /// Reply jobs must match the message currently open in Composer. A
    /// standalone compose owns the nil-message generation lane. With no
    /// active Composer target, background work never makes this strip busy.
    nonisolated static func composerJobBelongsToActiveTarget(
        jobMessageID: UUID?,
        activeMessageID: UUID?,
        hasActiveComposerTarget: Bool
    ) -> Bool {
        guard hasActiveComposerTarget else { return false }
        if let activeMessageID {
            return jobMessageID == activeMessageID
        }
        return jobMessageID == nil
    }

    /// Queued Composer jobs can explain held work inside Composer, but they
    /// must not masquerade as current activity on the Constellation strip.
    /// A running Composer job still reaches that strip through
    /// `runningModelJobTempoReadout`. Summarizing remains eligible because it
    /// is also a genuine Constellation pipeline lane; the active correspondent
    /// summary reaches both strips through the shared app-side publisher.
    nonisolated static func pendingActivityCanLeadConstellation(label: String) -> Bool {
        let displayLabel = ActivityStripModelWorkPresentation.displayLabel(label)
        return displayLabel == "summarizing" || !isComposerActivityLabel(displayLabel)
    }

    nonisolated static func generationGaugeMode(for label: String) -> GaugeMode {
        switch label {
        case "translating":  return .cipher
        case "asking":       return .converse
        case "categorizing": return .tag
        case "tagging":      return .resolve
        case "drafting":     return .typewriter
        case "compiling":    return .sift
        case "formulating":  return .probe
        case "extracting":   return .pull
        case "remembering":  return .consolidate
        // Account-memory distillation reuses the dreaming coalescence gauge.
        case "dreaming":     return .dreaming(fraction: nil)
        case "refining":     return .hone
        case "learning":     return .weights
        case "embedding":    return .encode
        case "retrieving":   return .encode
        case "captioning":   return .trace
        case "clustering":   return .clustering
        case "digesting":    return .digest
        // On-demand summary generation shares the pipeline summarizing
        // stage's Precis motif (indeterminate -> faint baseline).
        case "summarizing":  return .precis(fraction: nil)
        default:             return .training(fraction: nil)
        }
    }

    /// Polls the deletion publisher's session-removal counter so SwiftUI's
    /// `.onChange` machinery can drive event stamping. Returns 0 when no
    /// publisher is configured (e.g., onboarding).
    private var deletionRemovalsCount: Int {
        appServices?.deletionSyncStatusPublisher.snapshot.sessionRemovals ?? 0
    }

    private var shouldShowIMAPTempoReadout: Bool {
        hasConfiguredIMAPIngestion
    }

    private var transientIMAPEventReadout: TempoReadout? {
        let now = clock
        if newMailEvent.isActive(at: now, duration: PipelineActivityPresentation.activityNewMailEventDuration) {
            return canonicalIMAPReadout(.forming)
        }
        if deletionEvent.isActive(at: now, duration: PipelineActivityPresentation.activityDeletionUpdatedEventDuration) {
            return canonicalIMAPReadout(.deletionsUpdated)
        }
        if imapCheckEvent.isActive(at: now, duration: PipelineActivityPresentation.activityIMAPCheckEventDuration) {
            return canonicalIMAPReadout(.checking)
        }
        return nil
    }

    private var permanentDeleteTempoReadout: TempoReadout? {
        if permanentDeleteEvent.isActive(
            at: clock,
            duration: PipelineActivityPresentation.activityPermanentDeleteEventDuration
        ) {
            return canonicalIMAPReadout(.deleting)
        }
        let activeCount = activitySnapshot.activePermanentDeleteMutationCount
        guard activeCount > 0 else { return nil }
        return canonicalIMAPReadout(.deleting)
    }

    private var activeIMAPJobReadout: TempoReadout? {
        let activeJobs = jobDerivations.relevantIMAPJobs
        if let runningJob = activeJobs.first(where: { $0.job.status == JobStatus.running.rawValue }) {
            return imapJobReadout(for: runningJob)
        }
        guard !isPipelineWorkActiveForTempo, let pendingJob = activeJobs.first else {
            return nil
        }
        return imapJobReadout(for: pendingJob)
    }

    private func imapJobReadout(
        for relevantJob: ActivityStripJobDerivations.RelevantIMAPJob
    ) -> TempoReadout? {
        let job = relevantJob.job
        let payload = relevantJob.payload
        let isRunning = job.status == JobStatus.running.rawValue

        // IMAP jobs name their account in the payload rather than through a
        // message, so the tint comes from there.
        let accountID = payload?.accountID

        let kind: WorkerIMAPActivityKind
        switch job.type {
        case JobType.imapBackfill.rawValue:
            kind = isRunning ? .backfilling : .pending
        case JobType.imapPollFolder.rawValue:
            kind = isRunning
                ? (payload?.gapCheck == true ? .gapChecking : .polling)
                : .pending
        case JobType.imapDeletionWatch.rawValue:
            kind = isRunning ? .verifyingDeletions : .pending
        default:
            return nil
        }
        return canonicalIMAPReadout(kind, accountID: accountID)
    }

    private var imapSessionStatusReadout: TempoReadout? {
        // Sorted by account id so that when several accounts sit in the same
        // state the chosen one — and therefore the flow indicator's tint — is
        // stable across refreshes instead of following dictionary order.
        let entries = imapSessionManager
            .map { $0.statusByAccount.sorted { $0.key.uuidString < $1.key.uuidString } } ?? []
        if let entry = entries.first(where: {
            if case .halted = $0.value { return true }
            return false
        }) {
            let activity = WorkerIMAPActivitySnapshot(
                kind: .needsAttention, accountID: entry.key,
                attentionCause: IMAPSessionManager.attentionCause(for: entry.value)
            )
            return .labelOnly("attention", help: attentionHelp(for: activity), accountID: entry.key)
        }
        if let entry = entries.first(where: {
            if case .reconnecting = $0.value { return true }
            return false
        }) {
            return canonicalIMAPReadout(.reconnecting, accountID: entry.key)
        }
        if let entry = entries.first(where: { $0.value == .connecting }) {
            return canonicalIMAPReadout(.connecting, accountID: entry.key)
        }
        if let entry = entries.first(where: { $0.value == .authing }) {
            return canonicalIMAPReadout(.authenticating, accountID: entry.key)
        }
        if let syncing = syncingIMAPSession {
            return canonicalIMAPReadout(.syncing, accountID: syncing.accountID)
        }
        return nil
    }

    private var deletionTempoReadout: TempoReadout? {
        guard let snapshot = appServices?.deletionSyncStatusPublisher.snapshot else { return nil }
        if snapshot.pendingDeletionCount > 0 {
            return canonicalIMAPReadout(.reconciling)
        }
        if snapshot.sessionRemovals > 0,
           let lastSyncAt = snapshot.lastSyncAt,
           clock.timeIntervalSince(lastSyncAt) <= 45 {
            return canonicalIMAPReadout(.deletionsUpdated)
        }
        return nil
    }

    private func canonicalIMAPReadout(
        _ kind: WorkerIMAPActivityKind,
        accountID: UUID? = nil
    ) -> TempoReadout {
        let spec = ActivityStripIMAPActivityPresentation.spec(for: kind)
        return .labelOnly(spec.label, help: spec.help, accountID: accountID)
    }

    private func attentionHelp(for activity: WorkerIMAPActivitySnapshot) -> String {
        let account = accounts.first { $0.id == activity.accountID }
        let name = account.map { "\($0.displayName) (\($0.emailAddress))" }
        return ActivityStripIMAPActivityPresentation.attentionHelp(for: activity, accountName: name)
    }

    /// Human-readable explanation for why embedding may not be making
    /// forward progress right now. nil when nothing is gating the queue.
    /// Computed inline (no IPC into BackgroundScheduler) by reading the
    /// same signals the scheduler sees: thermal state from `ProcessInfo`
    /// and the `Job` table for embed-job backoff or terminal failure.
    private var embedPauseReason: String? {
        // Thermal — matches `ResourcePolicy.evaluate` rules 1 and 4.
        switch ProcessInfo.processInfo.thermalState {
        case .critical: return "paused: thermal critical"
        case .serious:  return "limited: thermal serious"
        default: break
        }

        // `.embed` job in exponential backoff — JobQueue.fail sets
        // `nextAttemptAt` after a throw and `claimNext` skips rows that
        // haven't reached it yet. Surface the countdown so the user knows
        // it's a wait, not a freeze.
        if let earliest = activitySnapshot.pendingEmbedNextAttemptAt,
           earliest > clock {
            let secs = Int(earliest.timeIntervalSince(clock).rounded())
            return "retry in \(secs)s"
        }

        // Terminal: `.embed` job exhausted retries and is stuck `.failed`.
        // `BackgroundScheduler.ensurePipelineJobsExist` should re-enqueue
        // because `embedActionable` is true and `.failed` isn't in
        // `activeTypes` — but if for any reason it doesn't, this surfaces
        // it instead of looking frozen.
        let failedEmbed = activitySnapshot.failedEmbedJobCount
        let hasPendingEmbed = activitySnapshot.pendingJobTypes.contains(JobType.embed.rawValue)
        if failedEmbed > 0 && !hasPendingEmbed {
            return "embed job failed (×\(failedEmbed))"
        }

        // No jobs of any kind — scheduler hasn't seeded the queue yet.
        if activitySnapshot.jobCount == 0 {
            return "queue not seeded"
        }

        return nil
    }

    private var pipelineStateHelp: String {
        switch overallPhaseLabel {
        case "importing":
            return "Ohia is acquiring the initial mailbox history you selected."
        case "backfilling":
            return "Ohia is importing older historical messages from the mail server."
        case "datafying":
            return "Ohia is interpreting messages into categories and structured triage information."
        case "summarizing":
            return "Ohia is writing rich summaries for message hovers and expanded views."
        case "idling":
            return "Ohia is caught up with message processing while background indexing finishes."
        case "syncing":
            return "Ohia is syncing mailbox changes from the mail server."
        case "polling":
            return "Ohia is scanning a mailbox folder for new, changed, or deleted messages."
        case "forming":
            return "Ohia is preparing newly arrived mail for interpretation and the Constellation."
        case "attention":
            if let readout = imapSessionStatusReadout, readout.label == "attention" {
                return readout.help
            }
            return "Message interpretation stopped after \(activitySnapshot.failedInterpretationJobCount) failed processing job(s), and no retry is queued. Retry the failed processing work; if the problem persists, report it to Ohia support."
        default:
            return "Ohia is waiting for the next mail or processing task to begin."
        }
    }

    private var corpusPhase: PipelineCorpusPhasePresentation {
        PipelineActivityPresentation.corpusPhase(
            initialIMAPImportCompletedAt: corpusInitialCompletionMarker,
            uidWork: imapCorpusStoreState.uidWork,
            historicalWork: corpusHistoricalWork,
            steadyActivity: corpusSteadyActivity,
            hasActionableError: hasActionableIMAPError
        )
    }

    private var corpusInitialCompletionMarker: Date? {
        let state = imapCorpusStoreState
        if state.hasConfiguredAccounts {
            return state.initialIMAPImportCompletedAt
        }
        // A schema-unknown store with a configured account is conservatively
        // an incomplete import. No configured IMAP account means there is no
        // initial phase to hold ahead of the ordinary idle presentation.
        return hasConfiguredIMAPIngestion ? nil : .distantPast
    }

    private var isInitialIMAPImportIncomplete: Bool {
        hasConfiguredIMAPIngestion && corpusInitialCompletionMarker == nil
    }

    private var imapCorpusStoreState: ActivityStripIMAPCorpusStoreState {
        hasLoadedActivitySnapshot
            ? activitySnapshot.imapCorpusState
            : swiftDataIMAPCorpusState
    }

    private var swiftDataIMAPCorpusState: ActivityStripIMAPCorpusStoreState {
        let configured = accounts.filter { account in
            account.imapKeychainRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let allComplete = configured.isEmpty == false
            && configured.allSatisfy { $0.initialIMAPImportCompletedAt != nil }
        let incompleteAccounts = configured.filter { $0.initialIMAPImportCompletedAt == nil }
        let work = incompleteAccounts.flatMap { account in
            ActivityStripIMAPCorpusProjection.requiredUIDWork(
                folders: folderStates.compactMap { folder in
                    guard folder.account?.id == account.id else { return nil }
                    return .init(
                        name: folder.folderName,
                        attributes: folder.folderAttributes,
                        total: folder.initialImportUIDWorkTotal,
                        remaining: folder.initialImportUIDWorkRemaining
                    )
                },
                isGmail: ActivityStripIMAPCorpusProjection.isGmailHost(account.imapHost)
            )
        }
        return ActivityStripIMAPCorpusStoreState(
            isKnown: true,
            hasConfiguredAccounts: configured.isEmpty == false,
            initialIMAPImportCompletedAt: allComplete
                ? configured.compactMap(\.initialIMAPImportCompletedAt).min()
                : nil,
            uidWork: work
        )
    }

    private var corpusHistoricalWork: PipelineHistoricalIMAPWork {
        guard isHistoricalIMAPBackfillStage else { return .inactive }
        return ActivityStripHistoricalWorkPresentation.state(
            isInitialImportIncomplete: isInitialIMAPImportIncomplete,
            hasPendingOrRunningBackfill: hasHistoricalIMAPBackfillJob,
            hasRunnableBackfill: jobDerivations.hasRunnableHistoricalIMAPBackfillJob,
            hasRunningBackfill: jobDerivations.hasRunningHistoricalIMAPBackfillJob
        )
    }

    private var corpusSteadyActivity: PipelineSteadyIMAPActivity {
        if newMailEvent.isActive(
            at: clock,
            duration: PipelineActivityPresentation.activityNewMailEventDuration
        ) {
            return .newArrival
        }
        if runningPollFolderJob != nil { return .polling }
        if hasSyncingIMAPSession { return .syncing }
        return .idle
    }

    private var hasActionableIMAPError: Bool {
        imapSessionManager?.statusByAccount.values.contains(where: { status in
            if case .halted = status { return true }
            return false
        }) ?? false
    }

    private var isIngesting: Bool {
        hasSyncingIMAPSession
            || isInitialIMAPImportIncomplete
            || hasActiveIMAPIngestionJob
            || isHistoricalIMAPBackfillStage
    }

    private var importStageIsIncomplete: Bool {
        if isInitialIMAPImportIncomplete || isHistoricalIMAPBackfillStage {
            return true
        }
        return activitySnapshot.total == 0 && isIngesting
    }

    private var isActivelyIngesting: Bool {
        hasRunningJob(types: [.imapBackfill, .imapPollFolder])
            || hasActiveIMAPIngestionJob
            || hasSyncingIMAPSession
            || hasRecentIngestActivity
    }

    private var isProgressIndeterminate: Bool {
        guard workPhase == .ingesting else { return false }
        if case .mass = corpusPhase.gauge { return false }
        return true
    }

    private var shouldShowDeterminateProgressGauge: Bool {
        guard !isProgressIndeterminate else { return false }
        switch workPhase {
        case .ingesting:
            if case .mass = corpusPhase.gauge { return true }
            return false
        case .interpreting, .summarizing, .partialFailures:
            return messageProgressDenominator > 0
                || summaryProgress.total > 0
                || (placement?.total ?? 0) > 0
        case .empty, .complete:
            return false
        }
    }

    private var hasRecentIngestActivity: Bool {
        guard let recentIngestActivityUntil else { return false }
        return recentIngestActivityUntil > clock
    }

    private var ingestStageLabel: String {
        "ingested"
    }

    private var isInterpretationWorkActive: Bool {
        activitySnapshot.interpreted < activitySnapshot.total
            && (
                hasPendingOrRunningJob(types: [.summarize])
                || qwenWorkerRecentlyActive(for: [JobType.summarize.rawValue])
            )
    }

    private var isEmbeddingWorkActive: Bool {
        activitySnapshot.embedded < activitySnapshot.total
            && (
                hasPendingOrRunningJob(types: [.ingest, .embed, .reindexEmbeddings])
                || bgeWorkerRecentlyActive(for: PipelineActivityPresentation.embeddingJobTypes)
            )
    }

    private var isSummaryWorkActive: Bool {
        guard bulkSummaryPhaseIsEligible else { return false }
        return isBodySummaryWorkActive || isAttachmentSummaryWorkActive
    }

    private var isBodySummaryWorkActive: Bool {
        bulkSummaryPhaseIsEligible
            && activitySnapshot.summarized < activitySnapshot.total
            && (
                hasRunningJob(types: [.summarize])
                || qwenWorkerRecentlyActive(for: [JobType.summarize.rawValue])
            )
    }

    private var isAttachmentSummaryWorkActive: Bool {
        bulkSummaryPhaseIsEligible
            && rawSummaryProgress.hasAttachmentBacklog
            && (
                hasRunningJob(types: [.summarizeAttachments])
                || qwenWorkerRecentlyActive(for: [JobType.summarizeAttachments.rawValue])
            )
    }

    private var isVectorCreationActive: Bool {
        activitySnapshot.pendingEmbeds > 0
            && (
                hasPendingOrRunningJob(types: [.ingest, .embed, .entityEmbed, .entityRefresh])
                || bgeWorkerRecentlyActive(for: PipelineActivityPresentation.vectorCreationJobTypes)
            )
    }

    private var isEmailNodePlacementActive: Bool {
        guard let nodes = emailNodes, nodes.total > 0, nodes.placed < nodes.total else {
            return false
        }
        return isPlacementWorkActive
    }

    private var isPlacementWorkActive: Bool {
        guard let p = placement, p.total > 0, p.placed < p.total else {
            return false
        }
        return hasPendingOrRunningJob(types: [.ingest, .embed, .index, .frameBurst])
            || bgeWorkerRecentlyActive(for: PipelineActivityPresentation.placementJobTypes)
    }

    private func hasRunningJob(types: Set<JobType>) -> Bool {
        let rawTypes = Set(types.map(\.rawValue))
        return !activitySnapshot.runningJobTypes.isDisjoint(with: rawTypes)
    }

    /// Counts refresh from SQLite every second even while SwiftData's
    /// cross-context `@Query` notifications are delayed. Mirror the job-state
    /// read there too so incomplete stages pulse while their work is either
    /// actively running or already queued for the scheduler.
    private func hasPendingOrRunningJob(types: Set<JobType>) -> Bool {
        let rawTypes = Set(types.map(\.rawValue))
        let snapshotTypes = activitySnapshot.runningJobTypes
            .union(activitySnapshot.pendingJobTypes)
        return !snapshotTypes.isDisjoint(with: rawTypes)
    }

    private func bgeWorkerRecentlyActive(for jobTypes: Set<String>) -> Bool {
        PipelineActivityPresentation.workerRecentlyActive(
            workerStatuses?.snapshot(for: .bge).worker,
            for: jobTypes,
            now: clock
        )
    }

    private func qwenWorkerRecentlyActive(for jobTypes: Set<String>) -> Bool {
        PipelineActivityPresentation.workerRecentlyActive(
            workerStatuses?.snapshot(for: .qwen).worker,
            for: jobTypes,
            now: clock
        )
    }

    private var isMemoryDreamingActive: Bool {
        ActivityStripModelWorkPresentation.isDreamingModelWorkActive(
            memoryRefreshIsRunning: memoryRefreshProgress.isRunning,
            worker: workerStatuses?.snapshot(for: .qwen).worker,
            now: clock
        )
    }

    private var isSemanticTaggingActive: Bool {
        ActivityStripModelWorkPresentation.isTaggingModelWorkActive(
            semanticTagResolutionIsRunning: hasRunningJob(types: [.resolveSemanticTags]),
            worker: workerStatuses?.snapshot(for: .bge).worker,
            now: clock
        )
    }

    /// Activity-strip presentation for the dreaming (account-memory) pass.
    /// During the initial full-history backfill it is a determinate progress
    /// gauge keyed on processed/eligible aggregated across any accounts still
    /// backfilling; once every account's backfill is complete it falls back to
    /// the plain "dreaming" label (incremental delta runs have no denominator).
    private var dreamingMode: DreamingActivityMode {
        let memoryProgress = memoryRefreshProgress
        return PipelineActivityPresentation.dreamingActivityMode(
            isActive: isMemoryDreamingActive,
            backfillCompleted: memoryProgress.backfillCompleted,
            processed: memoryProgress.processedBackfillMessages,
            eligible: memoryProgress.eligibleBackfillMessages
        )
    }

    private var memoryRefreshProgress: ActivityStripMemoryRefreshProgress {
        ActivityStripMemoryRefreshProgress(states: activitySnapshot.memoryRefreshStates)
    }

    private var summaryProgress: ActivityStripSummaryProgress {
        rawSummaryProgress
    }

    private var rawSummaryProgress: ActivityStripSummaryProgress {
        ActivityStripSummaryProgress(
            messageSummaries: activitySnapshot.summarized,
            messageTotal: messageProgressDenominator,
            attachmentSummaries: activitySnapshot.attachmentSummarized,
            attachmentTotal: activitySnapshot.attachmentSummaryTotal
        )
    }

    private var bulkSummaryPhaseIsEligible: Bool {
        let total = activitySnapshot.total
        guard total > 0,
              !importStageIsIncomplete,
              activitySnapshot.interpreted >= total
        else {
            return false
        }
        return true
    }

    private var hasActiveIMAPIngestionJob: Bool {
        jobDerivations.hasRunningRelevantIMAPImportJob
    }

    private var hasHistoricalIMAPBackfillJob: Bool {
        jobDerivations.hasHistoricalIMAPBackfillJob
    }

    private var isHistoricalIMAPBackfillStage: Bool {
        hasPendingHistoricalIMAPFolderDiscovery || hasIncompleteIMAPBackfill || hasHistoricalIMAPBackfillJob
    }

    /// Single-pass reduction of `snapshot.activeJobs` into every job-derived
    /// value the render path reads. Runs once per applied snapshot (1–3 s
    /// cadence), off the `body` hot path — see `ActivityStripJobDerivations`.
    private func deriveJobState(
        from snapshot: PipelineActivitySnapshot
    ) -> ActivityStripJobDerivations {
        var derivations = ActivityStripJobDerivations()
        let decoder = JSONDecoder()
        let hasSummarizationBacklog = snapshot.interpreted < snapshot.total
            || snapshot.summarized < snapshot.total
        for job in snapshot.activeJobs {
            let isPending = job.status == JobStatus.pending.rawValue
            let isRunning = job.status == JobStatus.running.rawValue

            if job.type == JobType.prepareReplySources.rawValue,
               isPending || isRunning,
               let messageID = job.messageID {
                derivations.activeReplySourcePreparationMessageIDs.insert(messageID)
            }

            derivations.pipelineAccountEngagement.observe(
                jobType: job.type,
                status: job.status,
                accountID: job.accountID
            )
            if job.type == JobType.summarize.rawValue {
                if isPending { derivations.pendingInterpretationJobCount += 1 }
                if isRunning { derivations.runningInterpretationJobCount += 1 }
            }
            if job.type == JobType.clusterDetect.rawValue,
               isPending || isRunning,
               let data = job.payload?.data(using: .utf8),
               let payload = try? decoder.decode(ClusterDetectPayload.self, from: data),
               payload.frame.spatialLens == FrameKey.meaning.spatialLens {
                derivations.hasActiveMeaningMembershipJob = true
            }
            if ActivityStripModelWorkPresentation.shouldShowModelActivityJob(
                jobType: job.type,
                status: job.status,
                messageID: job.messageID,
                hasSummarizationBacklog: hasSummarizationBacklog,
                isPipelineWorkActive: true
            ) {
                derivations.visibleModelJobsWhilePipelineActive.append(job)
            }
            if ActivityStripModelWorkPresentation.shouldShowModelActivityJob(
                jobType: job.type,
                status: job.status,
                messageID: job.messageID,
                hasSummarizationBacklog: hasSummarizationBacklog,
                isPipelineWorkActive: false
            ) {
                derivations.visibleModelJobsWhilePipelineIdle.append(job)
            }

            guard isPending || isRunning else { continue }
            let isBackfill = job.type == JobType.imapBackfill.rawValue
            let isPoll = job.type == JobType.imapPollFolder.rawValue
            let isDeletionWatch = job.type == JobType.imapDeletionWatch.rawValue
            guard isBackfill || isPoll || isDeletionWatch else { continue }

            let payload = Self.decodeIMAPJobPayload(job, decoder: decoder)
            guard imapJobIsRelevantForActivity(job, payload: payload) else { continue }
            derivations.pipelineAccountEngagement.observe(
                jobType: job.type,
                status: job.status,
                accountID: payload?.accountID
            )
            derivations.relevantIMAPJobs.append(
                ActivityStripJobDerivations.RelevantIMAPJob(job: job, payload: payload)
            )
            if isBackfill {
                derivations.hasHistoricalIMAPBackfillJob = true
                if isRunning {
                    derivations.hasRunningHistoricalIMAPBackfillJob = true
                }
                let retryIsReady = job.nextAttemptAt.map { $0 <= clock } ?? true
                if isRunning || (isPending && retryIsReady) {
                    derivations.hasRunnableHistoricalIMAPBackfillJob = true
                }
            }
            if isRunning, isBackfill || isPoll {
                derivations.hasRunningRelevantIMAPImportJob = true
            }
            if isPoll, payload?.gapCheck == true {
                derivations.hasActiveGapCheckJob = true
            }
        }

        // Resolve only the first running and pending Composer candidates from
        // each presentation policy. This keeps stage reads bounded to at most
        // four fresh-context fetches per snapshot while allowing Composer to
        // narrate its queued work even when unrelated model work is running.
        let isComposerJob: (PipelineActivityJobSnapshot) -> Bool = {
            Self.isComposerModelJobType($0.type)
        }
        let stageCandidates = [
            derivations.visibleModelJobsWhilePipelineActive.first(where: {
                $0.status == JobStatus.running.rawValue && isComposerJob($0)
            }),
            derivations.visibleModelJobsWhilePipelineIdle.first(where: {
                $0.status == JobStatus.running.rawValue && isComposerJob($0)
            }),
            derivations.visibleModelJobsWhilePipelineActive.first(where: {
                $0.status == JobStatus.pending.rawValue && isComposerJob($0)
            }),
            derivations.visibleModelJobsWhilePipelineIdle.first(where: {
                $0.status == JobStatus.pending.rawValue && isComposerJob($0)
            }),
        ].compactMap { $0 }
        if derivations.activeReplySourcePreparationMessageIDs.isEmpty == false
            || stageCandidates.isEmpty == false {
            let context = ModelContext(modelContext.container)
            if derivations.activeReplySourcePreparationMessageIDs.isEmpty == false {
                derivations.replyPreparationStatusByMessageID =
                    (try? Self.replyPreparationStatuses(
                        for: derivations.activeReplySourcePreparationMessageIDs,
                        context: context
                    )) ?? [:]
            }

            if stageCandidates.isEmpty == false {
                var resolvedMessageIDs = Set<UUID?>()
                for job in stageCandidates where resolvedMessageIDs.insert(job.messageID).inserted {
                    let stageRaw = Self.composerDraftStageRaw(
                        forMessageID: job.messageID,
                        authoritativeContext: context,
                        now: clock
                    )
                    if let messageID = job.messageID {
                        derivations.composerDraftStageByMessageID[messageID] = stageRaw
                    } else {
                        derivations.standaloneComposerDraftStageRaw = stageRaw
                    }
                }
            }
        }
        return derivations
    }

    /// Reads only preparation rows represented by active queue work. The
    /// messageId index keeps the strip's periodic refresh independent of the
    /// total number of prepared or historical messages in the store.
    static func replyPreparationStatuses(
        for messageIDs: Set<UUID>,
        context: ModelContext
    ) throws -> [UUID: String] {
        var statuses: [UUID: String] = [:]
        for messageID in messageIDs {
            let rows = try context.fetch(
                FetchDescriptor<ReplySourcePreparation>(
                    predicate: #Predicate<ReplySourcePreparation> {
                        $0.messageId == messageID
                    }
                )
            )
            let preferred = rows.reduce(nil as ReplySourcePreparation?) {
                existing,
                candidate in
                guard let existing else { return candidate }
                if existing.updatedAt != candidate.updatedAt {
                    return existing.updatedAt > candidate.updatedAt
                        ? existing
                        : candidate
                }
                return existing.id.uuidString < candidate.id.uuidString
                    ? existing
                    : candidate
            }
            if let preferred {
                statuses[messageID] = preferred.statusRaw
            }
        }
        return statuses
    }

    /// Relevance for a pending/running IMAP-typed job with its payload
    /// already decoded. Callers guarantee the status and type guards that
    /// `deriveJobState` applies before calling.
    private func imapJobIsRelevantForActivity(
        _ job: PipelineActivityJobSnapshot,
        payload: ActivityStripIMAPJobPayload?
    ) -> Bool {
        guard let payload,
              let account = accounts.first(where: { $0.id == payload.accountID })
        else { return true }

        return account.status != .paused
            && account.imapHost != nil
            && account.imapKeychainRef != nil
            && !account.needsImapReauth
    }

    nonisolated private static func decodeIMAPJobPayload(
        _ job: PipelineActivityJobSnapshot,
        decoder: JSONDecoder
    ) -> ActivityStripIMAPJobPayload? {
        guard let data = job.payload?.data(using: .utf8) else { return nil }
        return try? decoder.decode(ActivityStripIMAPJobPayload.self, from: data)
    }

    private var hasSyncingIMAPSession: Bool {
        imapSessionManager?.statusByAccount.values.contains { status in
            if case .syncing = status {
                return true
            }
            return false
        } ?? false
    }

    private var hasIdlingIMAPSession: Bool {
        imapSessionManager?.statusByAccount.values.contains(.idling) ?? false
    }

    private var syncingIMAPSession: (accountID: UUID, folder: String)? {
        imapSessionManager?.statusByAccount.compactMap { accountID, status in
            if case .syncing(let folder) = status {
                return (accountID: accountID, folder: folder)
            }
            return nil
        }.first
    }

    private var hasIncompleteIMAPBackfill: Bool {
        accounts.contains { account in
            guard account.imapHost != nil,
                  account.imapKeychainRef != nil
            else { return false }
            return folderStates.contains { state in
                state.account?.id == account.id
                    && !state.backfillComplete
                    && (state.lowestFetchedUID == 0 || state.lowestFetchedUID > 1)
            }
        }
    }

    private var hasPendingHistoricalIMAPFolderDiscovery: Bool {
        accounts.contains { account in
            guard account.status != .paused,
                  account.imapHost != nil,
                  account.imapKeychainRef != nil,
                  !account.needsImapReauth
            else { return false }
            return !folderStates.contains { $0.account?.id == account.id }
        }
    }

    private var hasConfiguredIMAPIngestion: Bool {
        accounts.contains { account in
            account.imapHost != nil
                && account.imapKeychainRef != nil
        }
    }

    private var messageProgressDenominator: Int {
        return ActivityStripOverallProgress.messageDenominator(
            messageTotal: activitySnapshot.total,
            targetTotal: 0
        )
    }

    /// Fraction of the ingestion target reached. Used to drive the gauge
    /// while `workPhase == .ingesting`.
    private var ingestFraction: CGFloat {
        if case .mass(let fraction) = corpusPhase.gauge {
            return CGFloat(fraction)
        }
        return 0
    }

    private var summaryProgressFraction: CGFloat {
        let total = max(0, rawSummaryProgress.messageTotal)
        guard total > 0 else { return 0 }
        return CGFloat(rawSummaryProgress.messageCompleted) / CGFloat(total)
    }

    @MainActor
    private func refreshActivitySnapshot() async {
        let storeSnapshot = await Task.detached(priority: .utility) {
            Self.readActivitySnapshotFromStore()
        }.value
        if let snapshot = storeSnapshot {
            applyActivitySnapshot(snapshot)
            return
        }
        if !Self.activityStoreExists() {
            let snapshot = Self.readActivitySnapshotFromSwiftData(context: modelContext)
            applyActivitySnapshot(snapshot)
        }
    }

    private func applyActivitySnapshot(_ snapshot: PipelineActivitySnapshot) {
        if hasLoadedActivitySnapshot,
           snapshot.total > activitySnapshot.total {
            recentIngestActivityUntil = clock.addingTimeInterval(6)
        }
        if let previous = observedPermanentDeleteCompletionCount,
           snapshot.completedPermanentDeleteMutationCount > previous {
            permanentDeleteEvent.record(
                delta: snapshot.completedPermanentDeleteMutationCount - previous,
                at: clock,
                duration: PipelineActivityPresentation.activityPermanentDeleteEventDuration
            )
        }
        observedPermanentDeleteCompletionCount = snapshot.completedPermanentDeleteMutationCount
        hasLoadedActivitySnapshot = true

        if activitySnapshot != snapshot {
            activitySnapshot = snapshot
        }

        // Recompute even when the snapshot is unchanged: relevance also
        // depends on account policy (pause / reauth / seed state), which can
        // change between identical job snapshots. One O(jobs) pass per
        // refresh tick, never per render.
        let derivations = deriveJobState(from: snapshot)
        if jobDerivations != derivations {
            jobDerivations = derivations
        }
    }

    @MainActor
    private func runActivityRefreshLoop() async {
        var lastActivitySnapshotRefresh = Date.distantPast
        var lastVectorSnapshotRefresh = Date.distantPast
        while !Task.isCancelled {
            let now = Date()
            clock = now
            await activityLog.refresh()

            let activityInterval = ActivityStripRefreshPolicy.activitySnapshotInterval(
                activeJobTypes: activitySnapshot.pendingJobTypes.union(activitySnapshot.runningJobTypes),
                hasRecentIngestActivity: hasRecentIngestActivity,
                hasActivePermanentDelete: activitySnapshot.activePermanentDeleteMutationCount > 0
            )
            if ActivityStripRefreshPolicy.shouldRefresh(
                now: now,
                lastRefresh: lastActivitySnapshotRefresh,
                interval: activityInterval
            ) {
                await refreshActivitySnapshot()
                lastActivitySnapshotRefresh = now
            }

            let vectorInterval = ActivityStripRefreshPolicy.vectorSnapshotInterval(
                activeJobTypes: activitySnapshot.pendingJobTypes.union(activitySnapshot.runningJobTypes),
                hasRecentIngestActivity: hasRecentIngestActivity
            )
            if ActivityStripRefreshPolicy.shouldRefresh(
                now: now,
                lastRefresh: lastVectorSnapshotRefresh,
                interval: vectorInterval
            ) {
                await refreshVectorSnapshot()
                lastVectorSnapshotRefresh = now
            }

            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                break
            }
        }
    }

    @MainActor
    private func refreshVectorSnapshot() async {
        guard let vectorStore = appServices?.vectorStore else {
            if vectorSnapshot != .empty {
                vectorSnapshot = .empty
            }
            return
        }

        let counts = await Task.detached(priority: .utility) {
            (
                placement: try? vectorStore.placementCounts(),
                emailNodes: try? vectorStore.emailNodeCounts()
            )
        }.value
        let snapshot = PipelineVectorActivitySnapshot(
            placement: counts.placement,
            emailNodes: counts.emailNodes
        )

        if vectorSnapshot != snapshot {
            vectorSnapshot = snapshot
        }
    }

    /// Keep the activity strip off SwiftData's reactive Message query path.
    /// During ingest, `@Query [Message]` materializes thousands of rows and
    /// can fault relationships while SwiftUI is recomputing `body`; a compact
    /// aggregate read keeps the footer cheap and predictable.
    nonisolated private static func readActivitySnapshotFromStore() -> PipelineActivitySnapshot? {
        let storeURL = activityStoreURL()
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(storeURL.path, &db, flags, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)

        let schema = ActivityStoreTableSchema(
            db: db,
            tables: [
                "ZACCOUNT",
                "ZACCOUNTMEMORYREFRESHSTATE",
                "ZATTACHMENT",
                "ZIMAPFOLDERSTATE",
                "ZJOB",
                "ZMAILBOXMUTATION",
                "ZMESSAGE",
                "ZMESSAGEANALYSIS",
                "ZTRAININGCORPUSRUN",
                "ZTRAININGCORPUSRUNTARGET",
            ]
        )
        let hasLiveInboundColumns = schema.hasColumn("ZLIVEDETECTEDAT", in: "ZMESSAGE")
            && schema.hasColumn("ZISSENTBYUSER", in: "ZMESSAGE")
        let hasClassificationColumn = schema.hasColumn(
            "ZMAILCLASSIFICATIONJSON",
            in: "ZMESSAGEANALYSIS"
        )
        let activeMessageWhereSQL = ActivityStripMessageScope.sqlWhereClause(
            hasTrashedAtColumn: schema.hasColumn("ZTRASHEDAT", in: "ZMESSAGE")
        )
        let sql = """
        SELECT
            COUNT(*),
            COALESCE(SUM(CASE WHEN EXISTS (
                SELECT 1
                FROM ZMESSAGEANALYSIS A
                WHERE A.Z_PK = M.ZANALYSIS
                  AND \(ActivityStripInterpretationSQL.completePredicate(
                      messageAlias: "M",
                      analysisAlias: "A",
                      hasLiveInboundColumns: hasLiveInboundColumns,
                      hasClassificationColumn: hasClassificationColumn
                  ))
            ) THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN EXISTS (
                SELECT 1
                FROM ZMESSAGEANALYSIS A
                WHERE A.Z_PK = M.ZANALYSIS
                  AND A.ZBODYSUMMARY IS NOT NULL
                  AND LENGTH(TRIM(A.ZBODYSUMMARY)) > 0
            ) THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN M.ZEMBEDDINGSTATUS = 'pending' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN M.ZEMBEDDINGSTATUS = 'processing' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN M.ZEMBEDDINGSTATUS = 'failed' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN M.ZEMBEDDINGSTATUS = 'completed' THEN 1 ELSE 0 END), 0)
        FROM ZMESSAGE M
        \(activeMessageWhereSQL)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let jobs = readActivityJobs(db: db, schema: schema)
        let jobState = readActivityJobState(db: db)
        let pendingMessageAccounts = readNextPendingMessageAccounts(
            db: db,
            schema: schema,
            hasLiveInboundColumns: hasLiveInboundColumns,
            hasClassificationColumn: hasClassificationColumn
        )
        let activeTrainingTargetAccountID = readActiveTrainingTargetAccountID(
            db: db,
            schema: schema
        )
        let attachmentSummaries = readAttachmentSummaryCounts(db: db, schema: schema)
        let memoryRefreshStates = readMemoryRefreshStates(db: db, schema: schema)
        let permanentDeleteMutations = readPermanentDeleteMutationCounts(db: db, schema: schema, now: Date())
        let imapCorpusState = ActivityStripIMAPCorpusSQL.readState(db: db)

        return PipelineActivitySnapshot(
            total: Int(sqlite3_column_int64(statement, 0)),
            interpreted: Int(sqlite3_column_int64(statement, 1)),
            summarized: Int(sqlite3_column_int64(statement, 2)),
            attachmentSummaryTotal: attachmentSummaries.total,
            attachmentSummarized: attachmentSummaries.completed,
            pendingEmbeds: Int(sqlite3_column_int64(statement, 3)),
            processingEmbeds: Int(sqlite3_column_int64(statement, 4)),
            failedEmbeds: Int(sqlite3_column_int64(statement, 5)),
            embedded: Int(sqlite3_column_int64(statement, 6)),
            nextPendingInterpretationAccountID: pendingMessageAccounts.interpretation,
            nextPendingBodySummaryAccountID: pendingMessageAccounts.bodySummary,
            activeTrainingTargetAccountID: activeTrainingTargetAccountID,
            pendingJobTypes: jobs.pending,
            runningJobTypes: jobs.running,
            activeJobs: jobs.active,
            activePermanentDeleteMutationCount: permanentDeleteMutations.active,
            completedPermanentDeleteMutationCount: permanentDeleteMutations.completed,
            pendingEmbedNextAttemptAt: jobState.pendingEmbedNextAttemptAt,
            failedEmbedJobCount: jobState.failedEmbedJobCount,
            failedInterpretationJobCount: jobState.failedInterpretationJobCount,
            jobCount: jobState.jobCount,
            memoryRefreshStates: memoryRefreshStates,
            imapCorpusState: imapCorpusState
        )
    }

    nonisolated private static func readNextPendingMessageAccounts(
        db: OpaquePointer,
        schema: ActivityStoreTableSchema,
        hasLiveInboundColumns: Bool,
        hasClassificationColumn: Bool
    ) -> (interpretation: UUID?, bodySummary: UUID?) {
        guard schema.hasColumn("ZACCOUNTID", in: "ZMESSAGE") else {
            return (nil, nil)
        }

        let activeMessagePredicate = schema.hasColumn("ZTRASHEDAT", in: "ZMESSAGE")
            ? "M.ZTRASHEDAT IS NULL"
            : "1"
        let completeInterpretationPredicate = ActivityStripInterpretationSQL.completePredicate(
            messageAlias: "M",
            analysisAlias: "A",
            hasLiveInboundColumns: hasLiveInboundColumns,
            hasClassificationColumn: hasClassificationColumn
        )
        let newestFirstSQL = """
        ORDER BY
            COALESCE(M.ZRECEIVEDAT, M.ZSENTAT, M.ZINGESTEDAT) DESC,
            M.ZINGESTEDAT DESC,
            M.ZID ASC
        LIMIT 1
        """
        let interpretationSQL = """
        SELECT M.ZACCOUNTID
        FROM ZMESSAGE M
        LEFT JOIN ZMESSAGEANALYSIS A ON A.Z_PK = M.ZANALYSIS
        WHERE \(activeMessagePredicate)
          AND M.ZACCOUNTID IS NOT NULL
          AND (M.ZANALYSIS IS NULL OR NOT (\(completeInterpretationPredicate)))
        \(newestFirstSQL)
        """
        let bodySummarySQL = """
        SELECT M.ZACCOUNTID
        FROM ZMESSAGE M
        JOIN ZMESSAGEANALYSIS A ON A.Z_PK = M.ZANALYSIS
        WHERE \(activeMessagePredicate)
          AND M.ZACCOUNTID IS NOT NULL
          AND (\(completeInterpretationPredicate))
          AND (A.ZBODYSUMMARY IS NULL OR LENGTH(TRIM(A.ZBODYSUMMARY)) = 0)
        \(newestFirstSQL)
        """
        return (
            readFirstUUID(db: db, sql: interpretationSQL),
            readFirstUUID(db: db, sql: bodySummarySQL)
        )
    }

    nonisolated private static func readActiveTrainingTargetAccountID(
        db: OpaquePointer,
        schema: ActivityStoreTableSchema
    ) -> UUID? {
        guard schema.hasColumn("ZRUN", in: "ZTRAININGCORPUSRUNTARGET"),
              schema.hasColumn("ZROLERAW", in: "ZTRAININGCORPUSRUNTARGET"),
              schema.hasColumn("ZACCOUNTID", in: "ZTRAININGCORPUSRUNTARGET"),
              schema.hasColumn("ZSTATERAW", in: "ZTRAININGCORPUSRUN"),
              schema.hasColumn("ZCREATEDAT", in: "ZTRAININGCORPUSRUN")
        else { return nil }

        let sql = """
        SELECT DISTINCT T.ZACCOUNTID
        FROM ZTRAININGCORPUSRUNTARGET T
        WHERE T.ZRUN = (
            SELECT R.Z_PK
            FROM ZTRAININGCORPUSRUN R
            WHERE R.ZSTATERAW IN ('preparing', 'training', 'validating', 'checkpointing', 'interrupted')
            ORDER BY R.ZCREATEDAT DESC, R.Z_PK DESC
            LIMIT 1
        )
          AND T.ZROLERAW = 'target'
          AND T.ZACCOUNTID IS NOT NULL
        LIMIT 2
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var accountIDs: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let accountID = uuid(from: blobData(statement, column: 0)) {
                accountIDs.append(accountID)
            }
        }
        return ActivityStripReadoutAccountPresentation.soleAccountID(among: accountIDs)
    }

    nonisolated private static func readFirstUUID(
        db: OpaquePointer,
        sql: String
    ) -> UUID? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return uuid(from: blobData(statement, column: 0))
    }

    nonisolated private static func readAttachmentSummaryCounts(
        db: OpaquePointer,
        schema: ActivityStoreTableSchema,
        now: Date = Date()
    ) -> (total: Int, completed: Int) {
        guard schema.hasColumn("ZATTACHMENTSUMMARY", in: "ZATTACHMENT"),
              schema.hasColumn("ZATTACHMENTSUMMARYFINGERPRINT", in: "ZATTACHMENT"),
              schema.hasColumn("ZEXTRACTEDTEXTPATH", in: "ZATTACHMENT"),
              schema.hasColumn("ZVISUALSUMMARY", in: "ZATTACHMENT"),
              schema.hasColumn("ZATTACHMENTSUMMARYATTEMPTEDAT", in: "ZATTACHMENT")
        else {
            return (0, 0)
        }

        let retryCutoff = now.timeIntervalSinceReferenceDate
            - AttachmentSummaryBackfillWorker.failedAttemptRetryInterval
        let sql = """
        SELECT
            COALESCE(SUM(CASE WHEN completed THEN 1 ELSE 0 END), 0)
                + COALESCE(SUM(CASE WHEN actionable THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN completed THEN 1 ELSE 0 END), 0)
        FROM (
            SELECT
                (
                    ZATTACHMENTSUMMARY IS NOT NULL
                    AND LENGTH(TRIM(ZATTACHMENTSUMMARY)) > 0
                    AND ZATTACHMENTSUMMARYFINGERPRINT IS NOT NULL
                    AND LENGTH(TRIM(ZATTACHMENTSUMMARYFINGERPRINT)) > 0
                ) AS completed,
                (
                    NOT (
                        ZATTACHMENTSUMMARY IS NOT NULL
                        AND LENGTH(TRIM(ZATTACHMENTSUMMARY)) > 0
                        AND ZATTACHMENTSUMMARYFINGERPRINT IS NOT NULL
                        AND LENGTH(TRIM(ZATTACHMENTSUMMARYFINGERPRINT)) > 0
                    )
                    AND (
                        ZATTACHMENTSUMMARYATTEMPTEDAT IS NULL
                        OR ZATTACHMENTSUMMARYATTEMPTEDAT <= ?
                    )
                ) AS actionable
        FROM ZATTACHMENT
        WHERE (
            ZEXTRACTEDTEXTPATH IS NOT NULL
            AND LENGTH(TRIM(ZEXTRACTEDTEXTPATH)) > 0
        ) OR (
            ZVISUALSUMMARY IS NOT NULL
            AND LENGTH(TRIM(ZVISUALSUMMARY)) > 0
        )
        )
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return (0, 0)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, retryCutoff)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return (0, 0)
        }

        return (
            Int(sqlite3_column_int64(statement, 0)),
            Int(sqlite3_column_int64(statement, 1))
        )
    }

    nonisolated private static func readMemoryRefreshStates(
        db: OpaquePointer,
        schema: ActivityStoreTableSchema
    ) -> [ActivityStripMemoryRefreshStateSnapshot] {
        guard schema.hasColumn("ZLASTSTATUSRAW", in: "ZACCOUNTMEMORYREFRESHSTATE"),
              schema.hasColumn("ZCURSORPROCESSEDMESSAGECOUNT", in: "ZACCOUNTMEMORYREFRESHSTATE"),
              schema.hasColumn("ZLASTELIGIBLEMESSAGECOUNT", in: "ZACCOUNTMEMORYREFRESHSTATE"),
              schema.hasColumn("ZBACKFILLCOMPLETEDVALUE", in: "ZACCOUNTMEMORYREFRESHSTATE")
        else {
            return []
        }

        // The account column lets the flow indicator tint by whose memories are
        // being distilled; an older store without it degrades to no account.
        let accountIDExpression = schema.hasColumn("ZACCOUNTID", in: "ZACCOUNTMEMORYREFRESHSTATE")
            ? "ZACCOUNTID"
            : "NULL"
        let sql = """
        SELECT
            ZLASTSTATUSRAW,
            COALESCE(ZCURSORPROCESSEDMESSAGECOUNT, 0),
            COALESCE(ZLASTELIGIBLEMESSAGECOUNT, 0),
            COALESCE(ZBACKFILLCOMPLETEDVALUE, 0),
            \(accountIDExpression)
        FROM ZACCOUNTMEMORYREFRESHSTATE
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        var states: [ActivityStripMemoryRefreshStateSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let status = sqlite3_column_text(statement, 0)
                .map { String(cString: $0) } ?? AccountMemoryRefreshStatus.idle
            states.append(ActivityStripMemoryRefreshStateSnapshot(
                statusRaw: status,
                cursorProcessedMessageCount: Int(sqlite3_column_int64(statement, 1)),
                lastEligibleMessageCount: Int(sqlite3_column_int64(statement, 2)),
                backfillCompleted: sqlite3_column_int64(statement, 3) != 0,
                accountID: uuid(from: blobData(statement, column: 4))
            ))
        }
        return states
    }

    nonisolated private static func readPermanentDeleteMutationCounts(
        db: OpaquePointer,
        schema: ActivityStoreTableSchema,
        now: Date
    ) -> (active: Int, completed: Int) {
        guard schema.hasColumn("ZKIND", in: "ZMAILBOXMUTATION"),
              schema.hasColumn("ZSTATUS", in: "ZMAILBOXMUTATION")
        else {
            return (0, 0)
        }

        let hasNextAttemptAfter = schema.hasColumn("ZNEXTATTEMPTAFTER", in: "ZMAILBOXMUTATION")
        let activePredicate = if hasNextAttemptAfter {
            """
            ZSTATUS = 'running'
            OR (
                ZSTATUS = 'queued'
                AND (ZNEXTATTEMPTAFTER IS NULL OR ZNEXTATTEMPTAFTER <= ?)
            )
            """
        } else {
            "ZSTATUS IN ('queued', 'running')"
        }
        let sql = """
        SELECT
            COALESCE(SUM(CASE WHEN \(activePredicate) THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN ZSTATUS = 'succeeded' THEN 1 ELSE 0 END), 0)
        FROM ZMAILBOXMUTATION
        WHERE ZKIND = 'delete'
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return (0, 0)
        }
        defer { sqlite3_finalize(statement) }

        if hasNextAttemptAfter {
            sqlite3_bind_double(statement, 1, now.timeIntervalSinceReferenceDate)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return (0, 0)
        }

        return (
            Int(sqlite3_column_int64(statement, 0)),
            Int(sqlite3_column_int64(statement, 1))
        )
    }

    nonisolated private static func blobData(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let blob = sqlite3_column_blob(statement, column) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        return Data(bytes: blob, count: count)
    }

    nonisolated private static func uuid(from data: Data?) -> UUID? {
        guard let data, data.count == 16 else { return nil }
        return data.withUnsafeBytes { rawBuffer -> UUID? in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            return UUID(uuid: (
                base[0], base[1], base[2], base[3],
                base[4], base[5], base[6], base[7],
                base[8], base[9], base[10], base[11],
                base[12], base[13], base[14], base[15]
            ))
        }
    }

    nonisolated private static func readActivityJobs(
        db: OpaquePointer,
        schema: ActivityStoreTableSchema
    ) -> (pending: Set<String>, running: Set<String>, active: [PipelineActivityJobSnapshot]) {
        let hasJobMessageID = schema.hasColumn("ZMESSAGEID", in: "ZJOB")
        let messageIDExpression = hasJobMessageID ? "J.ZMESSAGEID" : "NULL"
        // Resolve the job's owning account through its message so the flow
        // indicator can tint its electrons by whose mail is being worked on.
        // Guarded on both columns: an older store missing either one simply
        // yields no account, and the indicator falls back to the accent.
        //
        // A correlated scalar subquery rather than a LEFT JOIN, deliberately:
        // `ZMESSAGE.ZID` is indexed but NOT declared unique (the `Message`
        // model carries no `@Attribute(.unique)`), so a join would multiply
        // this job row if two messages ever shared an id — inflating the
        // interpretation job counts and the readout's "n/m" progress text. A
        // scalar subquery yields exactly one value per job whatever the data
        // does, and still resolves through `idx_ohia_message_id`.
        let canResolveAccount = hasJobMessageID
            && schema.hasColumn("ZID", in: "ZMESSAGE")
            && schema.hasColumn("ZACCOUNTID", in: "ZMESSAGE")
        let accountIDExpression = canResolveAccount
            ? "(SELECT M.ZACCOUNTID FROM ZMESSAGE M WHERE M.ZID = J.ZMESSAGEID LIMIT 1)"
            : "NULL"
        let sql = """
        SELECT J.ZTYPE, J.ZSTATUS, J.ZPAYLOAD, J.ZSTARTEDAT, J.ZNEXTATTEMPTAT, \(messageIDExpression), \(accountIDExpression)
        FROM ZJOB J
        WHERE J.ZSTATUS IN ('pending', 'running')
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return ([], [], [])
        }
        defer { sqlite3_finalize(statement) }

        var pending: Set<String> = []
        var running: Set<String> = []
        var active: [PipelineActivityJobSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let typePointer = sqlite3_column_text(statement, 0),
                  let statusPointer = sqlite3_column_text(statement, 1)
            else { continue }

            let type = String(cString: typePointer)
            let status = String(cString: statusPointer)
            let payload = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let startedAt: Date?
            if sqlite3_column_type(statement, 3) == SQLITE_NULL {
                startedAt = nil
            } else {
                startedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3))
            }
            let nextAttemptAt: Date?
            if sqlite3_column_type(statement, 4) == SQLITE_NULL {
                nextAttemptAt = nil
            } else {
                nextAttemptAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4))
            }
            let messageID = uuid(from: blobData(statement, column: 5))
            let accountID = uuid(from: blobData(statement, column: 6))
                ?? ActivityStripPipelineAccountPayload.accountID(
                    jobType: type,
                    status: status,
                    payload: payload
                )
            active.append(PipelineActivityJobSnapshot(
                type: type,
                status: status,
                messageID: messageID,
                payload: payload,
                startedAt: startedAt,
                nextAttemptAt: nextAttemptAt,
                accountID: accountID
            ))
            switch status {
            case "pending":
                pending.insert(type)
            case "running":
                running.insert(type)
            default:
                break
            }
        }

        return (pending, running, active)
    }

    nonisolated private static func readActivityJobState(
        db: OpaquePointer
    ) -> (
        jobCount: Int,
        failedEmbedJobCount: Int,
        failedInterpretationJobCount: Int,
        pendingEmbedNextAttemptAt: Date?
    ) {
        let sql = """
        SELECT
            COUNT(*),
            COALESCE(SUM(CASE WHEN ZTYPE = 'embed' AND ZSTATUS = 'failed' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN ZTYPE = 'summarize' AND ZSTATUS = 'failed' THEN 1 ELSE 0 END), 0),
            MIN(CASE WHEN ZTYPE = 'embed' AND ZSTATUS = 'pending' THEN ZNEXTATTEMPTAT ELSE NULL END)
        FROM ZJOB
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return (0, 0, 0, nil)
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return (0, 0, 0, nil)
        }

        let nextAttemptAt: Date?
        if sqlite3_column_type(statement, 3) == SQLITE_NULL {
            nextAttemptAt = nil
        } else {
            nextAttemptAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3))
        }
        return (
            Int(sqlite3_column_int64(statement, 0)),
            Int(sqlite3_column_int64(statement, 1)),
            Int(sqlite3_column_int64(statement, 2)),
            nextAttemptAt
        )
    }

    nonisolated private static func activityStoreExists() -> Bool {
        FileManager.default.fileExists(atPath: activityStoreURL().path)
    }

    nonisolated private static func activityStoreURL() -> URL {
        OhiaStorageRoot.required().swiftDataStore
    }

    private static func readActivitySnapshotFromSwiftData(
        context: ModelContext
    ) -> PipelineActivitySnapshot {
        let messages = ((try? context.fetch(FetchDescriptor<Message>())) ?? [])
            .filter { $0.trashedAt == nil }
        let now = Date()
        var snapshot = PipelineActivitySnapshot(total: messages.count)
        let newestMessages = messages.sorted(by: Message.newestPipelineFirst)
        snapshot.nextPendingInterpretationAccountID = newestMessages.first {
            !hasCompleteInterpretation($0)
        }?.accountID
        snapshot.nextPendingBodySummaryAccountID = newestMessages.first {
            hasCompleteInterpretation($0) && !hasText($0.analysis?.bodySummary)
        }?.accountID
        let activeTrainingStateRawValues: Set<String> = [
            TrainingCorpusRunState.preparing.rawValue,
            TrainingCorpusRunState.training.rawValue,
            TrainingCorpusRunState.validating.rawValue,
            TrainingCorpusRunState.checkpointing.rawValue,
            TrainingCorpusRunState.interrupted.rawValue,
        ]
        let activeTrainingRun = ((try? context.fetch(FetchDescriptor<TrainingCorpusRun>())) ?? [])
            .filter { activeTrainingStateRawValues.contains($0.stateRaw) }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString > $1.id.uuidString
            }
            .first
        if let activeTrainingRun {
            let targetAccountIDs: [UUID] = activeTrainingRun.targets.compactMap { target -> UUID? in
                guard target.role == .target else { return nil }
                return target.accountID
            }
            snapshot.activeTrainingTargetAccountID =
                ActivityStripReadoutAccountPresentation.soleAccountID(among: targetAccountIDs)
        }
        let mailboxMutations = (try? context.fetch(FetchDescriptor<MailboxMutation>())) ?? []
        snapshot.activePermanentDeleteMutationCount = mailboxMutations.filter {
            $0.kind == .delete
                && PipelineActivityPresentation.mailboxMutationIsActiveForActivity(
                    status: $0.status.rawValue,
                    nextAttemptAfter: $0.nextAttemptAfter,
                    now: now
                )
        }.count
        snapshot.completedPermanentDeleteMutationCount = mailboxMutations.filter {
            $0.kind == .delete && $0.status == .succeeded
        }.count
        for message in messages {
            if hasCompleteInterpretation(message) {
                snapshot.interpreted += 1
            }
            if hasText(message.analysis?.bodySummary) {
                snapshot.summarized += 1
            }
            switch message.embeddingStatus {
            case .pending: snapshot.pendingEmbeds += 1
            case .processing: snapshot.processingEmbeds += 1
            case .failed: snapshot.failedEmbeds += 1
            case .completed: snapshot.embedded += 1
            }
            for attachment in message.attachments {
                guard hasText(attachment.extractedTextPath) || hasText(attachment.visualSummary) else {
                    continue
                }
                if hasText(attachment.attachmentSummary),
                   hasText(attachment.attachmentSummaryFingerprint) {
                    snapshot.attachmentSummaryTotal += 1
                    snapshot.attachmentSummarized += 1
                } else if attachment.attachmentSummaryAttemptedAt.map({
                    now.timeIntervalSince($0) >= AttachmentSummaryBackfillWorker.failedAttemptRetryInterval
                }) ?? true {
                    snapshot.attachmentSummaryTotal += 1
                }
            }
        }
        let memoryStates = (try? context.fetch(FetchDescriptor<AccountMemoryRefreshState>())) ?? []
        snapshot.memoryRefreshStates = memoryStates.map { state in
            ActivityStripMemoryRefreshStateSnapshot(
                statusRaw: state.lastStatusRaw,
                cursorProcessedMessageCount: state.cursorProcessedMessageCount,
                lastEligibleMessageCount: state.lastEligibleMessageCount,
                backfillCompleted: state.backfillCompleted,
                accountID: state.accountID
            )
        }
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let configuredAccounts = accounts.filter {
            $0.imapKeychainRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let allInitialImportsComplete = configuredAccounts.isEmpty == false
            && configuredAccounts.allSatisfy { $0.initialIMAPImportCompletedAt != nil }
        let folders = (try? context.fetch(FetchDescriptor<IMAPFolderState>())) ?? []
        snapshot.imapCorpusState = ActivityStripIMAPCorpusStoreState(
            isKnown: true,
            hasConfiguredAccounts: configuredAccounts.isEmpty == false,
            initialIMAPImportCompletedAt: allInitialImportsComplete
                ? configuredAccounts.compactMap(\.initialIMAPImportCompletedAt).min()
                : nil,
            uidWork: configuredAccounts.filter {
                $0.initialIMAPImportCompletedAt == nil
            }.flatMap { account in
                ActivityStripIMAPCorpusProjection.requiredUIDWork(
                    folders: folders.compactMap { folder in
                        guard folder.account?.id == account.id else { return nil }
                        return .init(
                            name: folder.folderName,
                            attributes: folder.folderAttributes,
                            total: folder.initialImportUIDWorkTotal,
                            remaining: folder.initialImportUIDWorkRemaining
                        )
                    },
                    isGmail: ActivityStripIMAPCorpusProjection.isGmailHost(account.imapHost)
                )
            }
        )
        return snapshot
    }

    private static func hasCompleteInterpretation(_ message: Message) -> Bool {
        guard MailClassificationJSON.isComplete(message.analysis?.mailClassificationJSON) else {
            return false
        }
        guard message.isLiveInboundTriageEligible else {
            return true
        }
        return hasValidTriageVerdictJSON(message.analysis?.triageVerdictJSON)
    }

    private static func hasText(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func hasValidTriageVerdictJSON(_ value: String?) -> Bool {
        TriageVerdictJSON.hasRequiredBooleanFields(value)
    }

}

private struct PipelineActivityDot: View {
    let color: Color
    let status: PipelineActivityStageStatus

    var body: some View {
        Group {
            switch status {
            case .processing:
                TimelineView(.periodic(from: .now, by: OhiaAnimationCadence.frameInterval)) { context in
                    dot(
                        pulse: Self.pulse(at: context.date),
                        blink: Self.blink(at: context.date)
                    )
                }
            case .partial:
                dot(pulse: 1, blink: 0.72)
            case .complete:
                dot(pulse: 1, blink: 1)
            case .waiting:
                dot(pulse: 0, blink: 1)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }

    private func dot(pulse: Double, blink: Double) -> some View {
        let isProcessing = status == .processing
        let isWaiting = status == .waiting
        let dotColor = isWaiting ? OhiaColors.textTertiary : color
        let baseOpacity = isWaiting ? 0.18 : blink
        let haloOpacity = 0.55 * (1 - pulse)
        let haloSize = CGFloat(7.0 + (7.0 * pulse))
        let glowRadius = isProcessing ? CGFloat(2.0 + (3.0 * pulse)) : 2
        let coreScale = isProcessing ? CGFloat(0.88 + (0.14 * (1 - pulse))) : 1

        return ZStack {
            if isProcessing {
                Circle()
                    .stroke(color.opacity(haloOpacity), lineWidth: 1.2)
                    .frame(width: haloSize, height: haloSize)
            }

            Circle()
                .fill(dotColor.opacity(baseOpacity))
                .frame(width: 6, height: 6)
                .overlay {
                    if isWaiting {
                        Circle()
                            .stroke(OhiaColors.textTertiary.opacity(0.18), lineWidth: 1)
                    }
                }
                .shadow(
                    color: color.opacity(isWaiting ? 0 : 0.75),
                    radius: glowRadius
                )
                .scaleEffect(coreScale)
        }
    }

    private static func pulse(at date: Date) -> Double {
        let cycle = 2.2
        let elapsed = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycle) / cycle
        return elapsed < 0.5 ? elapsed * 2 : (1 - elapsed) * 2
    }

    private static func blink(at date: Date) -> Double {
        let cycle = 1.6
        let elapsed = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycle) / cycle
        return elapsed < 0.58 ? 1 : 0.25
    }
}
