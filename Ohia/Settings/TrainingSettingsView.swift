// Ohia/Settings/TrainingSettingsView.swift
// Settings → Training tab. Presents the automatic personalization lifecycle,
// progress, and checkpoint history. Recovery controls live under Developer.

import SwiftUI
import SwiftData
import Charts
import OhiaCore
import OhiaML

struct TrainingSettingsPresentation {
    let phase: TrainingStatusPublisher.Phase
    let runKind: TrainingCorpusRunKind?
    let runState: TrainingCorpusRunState?
    let runTargetCount: Int
    let runEpoch: Int?
    let runEpochCount: Int?
    let attemptedTargetCount: Int
    let incorporatedTargetCount: Int
    let skippedTargetCount: Int
    let failedTargetCount: Int
    let resourceWaitReason: String?
    let idleMinutesThreshold: Int?
    let nextEligibleReason: TrainingReadiness?
    let isPaused: Bool
    let adapterStep: Int?
    let latestCandidateStep: Int?
    let latestCandidateLifecycle: TrainingCheckpointLifecycle?
    let trainingCandidateCorpusProgress: TrainingCandidateCorpusProgress

    init(
        phase: TrainingStatusPublisher.Phase,
        runKind: TrainingCorpusRunKind? = nil,
        runState: TrainingCorpusRunState? = nil,
        runTargetCount: Int,
        runEpoch: Int? = nil,
        runEpochCount: Int? = nil,
        attemptedTargetCount: Int = 0,
        incorporatedTargetCount: Int = 0,
        skippedTargetCount: Int = 0,
        failedTargetCount: Int = 0,
        resourceWaitReason: String? = nil,
        idleMinutesThreshold: Int? = nil,
        nextEligibleReason: TrainingReadiness? = nil,
        isPaused: Bool = false,
        adapterStep: Int? = nil,
        latestCandidateStep: Int? = nil,
        latestCandidateLifecycle: TrainingCheckpointLifecycle? = nil,
        trainingCandidateCorpusProgress: TrainingCandidateCorpusProgress = .empty
    ) {
        self.phase = phase
        self.runKind = runKind
        self.runState = runState
        self.runTargetCount = runTargetCount
        self.runEpoch = runEpoch
        self.runEpochCount = runEpochCount
        self.attemptedTargetCount = attemptedTargetCount
        self.incorporatedTargetCount = incorporatedTargetCount
        self.skippedTargetCount = skippedTargetCount
        self.failedTargetCount = failedTargetCount
        self.resourceWaitReason = resourceWaitReason
        self.idleMinutesThreshold = idleMinutesThreshold
        self.nextEligibleReason = nextEligibleReason
        self.isPaused = isPaused
        self.adapterStep = adapterStep
        self.latestCandidateStep = latestCandidateStep
        self.latestCandidateLifecycle = latestCandidateLifecycle
        self.trainingCandidateCorpusProgress = trainingCandidateCorpusProgress
    }

    var progressLabel: String {
        guard runTargetCount > 0 else { return "No active run" }
        let completed = min(
            runTargetCount,
            max(0, incorporatedTargetCount + skippedTargetCount + failedTargetCount)
        )
        let percentage = Int(
            (Double(completed) / Double(runTargetCount) * 100).rounded()
        )
        let pass = runEpoch.flatMap { epoch in
            runEpochCount.flatMap { $0 > 1 ? " · pass \(epoch) of \($0)" : nil }
        } ?? ""
        return "\(completed) / \(runTargetCount) completed · \(percentage)%\(pass)"
    }

    var candidateCorpusLabel: String {
        let progress = trainingCandidateCorpusProgress
        guard progress.discoveredMessageCount > 0 else {
            return "No sent messages discovered"
        }
        if !progress.isAssessmentComplete {
            return "\(progress.assessedMessageCount) / \(progress.discoveredMessageCount) assessed · \(progress.eligibleMessageCount) eligible"
        }
        guard progress.eligibleMessageCount > 0 else {
            return "0 eligible messages"
        }
        return "\(progress.trainedMessageCount) / \(progress.eligibleMessageCount) trained"
    }

    var statusLabel: String {
        switch phase {
        case .preparing:
            return "Preparing"
        case .training:
            return "Training"
        case .checkpointing:
            return "Checkpointing"
        case .resetting:
            return "Resetting"
        case .idle:
            if isPaused { return "Paused" }
            if let waitReason = resourceWaitReason?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !waitReason.isEmpty {
                if waitReason == "resources", let idleMinutesThreshold,
                   idleMinutesThreshold > 0 {
                    let unit = idleMinutesThreshold == 1 ? "minute" : "minutes"
                    return "Waiting · resources · scheduled after \(idleMinutesThreshold) \(unit) system idle"
                }
                return "Waiting · \(waitReason)"
            }
            if let nextEligibleReason, case .accumulating = nextEligibleReason {
                return "Waiting · building next training batch"
            }
            if let nextEligibleReason, case .waitingForModel = nextEligibleReason {
                return "Waiting · loading personalization model"
            }
            if let nextEligibleReason, case .preparingCorpus = nextEligibleReason {
                return "Waiting · preparing sent email for the first full pass"
            }
            if let nextEligibleReason, case .deferred = nextEligibleReason {
                return "Waiting · the last pass did not improve on the current voice"
            }
            return runTargetCount > 0 ? "Ready" : "Idle"
        }
    }

    var nextEligibleLabel: String {
        guard let nextEligibleReason else { return "—" }
        switch nextEligibleReason {
        case .paused:
            return "paused"
        case .waitingForModel:
            return "waiting · loading personalization model"
        case .noNewPairs:
            return "up to date · no pending evidence revisions"
        case .preparingCorpus(let ready, let remaining):
            return "waiting · \(ready) prepared · \(remaining) sent email\(remaining == 1 ? "" : "s") still preparing for the first full pass"
        case .deferred(let pairs, let retryAt):
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return "deferred · \(pairs) revision\(pairs == 1 ? "" : "s") retry at \(formatter.string(from: retryAt))"
        case .accumulating(let pairs, let target, let eligibleAt):
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return "waiting · \(pairs) / \(target) eligible revisions · 24-hour fallback at \(formatter.string(from: eligibleAt))"
        case .ready(let kind):
            switch kind {
            case .backfill(let pairs):
                return "ready · initial run over \(pairs) revisions"
            case .incremental(let pairs):
                return "ready · \(pairs) pending revision\(pairs == 1 ? "" : "s")"
            case .force:
                return "ready · manual run"
            }
        }
    }

    var currentBatchLabel: String? {
        guard case .training(let step, let totalSteps, let loss) = phase else {
            return nil
        }
        let revisionUnit = attemptedTargetCount == 1 ? "revision" : "revisions"
        return "\(attemptedTargetCount) provisional \(revisionUnit) · optimizer step \(step) / \(totalSteps) · loss \(String(format: "%.3f", loss))"
    }

    var runLabel: String {
        guard let runKind, let runState else { return "None" }
        let kind = switch runKind {
        case .initialFull: "Initial full"
        case .incremental: "Incremental"
        case .manualFull: "Manual full"
        }
        let state = switch runState {
        case .interrupted: "waiting between jobs"
        case .preparing: "preparing"
        case .training: "training"
        case .validating: "validating"
        case .checkpointing: "checkpointing"
        case .completed: "completed"
        case .failed: "failed"
        }
        return "\(kind) · \(state)"
    }

    var loadedAdapterLabel: String {
        guard let adapterStep else { return "Base weights only" }
        return "Promoted · step \(adapterStep)"
    }

    var latestCandidateLabel: String {
        guard let latestCandidateStep else { return "None" }
        let lifecycle = switch latestCandidateLifecycle {
        case .candidate: "Candidate"
        case .resumeCandidate: "Resume candidate"
        case .promoted: "Promoted"
        case .rejected: "Rejected"
        case .quarantined: "Quarantined"
        case nil: "Unknown"
        }
        return "\(lifecycle) · step \(latestCandidateStep)"
    }
}

struct TrainingSettingsView: View {
    @Environment(TrainingStatusPublisher.self) private var publisher: TrainingStatusPublisher?
    @Environment(ModelLoadingService.self) private var modelLoader: ModelLoadingService?
    @Environment(WorkerFleetStatusPublisher.self) private var workerStatuses: WorkerFleetStatusPublisher?
    @Query(sort: \TrainingCheckpoint.stepCount) private var checkpoints: [TrainingCheckpoint]
    @Query private var trainingRunStates: [TrainingRunState]

    var body: some View {
        // Card stack over the night sky, matching General/Sources: section
        // headers on the sky, content in black cards, nebula in the gutters.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusSection
                historySection
                checkpointManifestSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        OhiaSettingsCard("Status") {
            SettingsBlock {
                VStack(alignment: .leading, spacing: 6) {
                    if isTrainingActive {
                        rowView("Status") { RunningTrainingIndicator(label: statusLabel) }
                    } else {
                        row("Status", statusLabel)
                    }
                    row("Run", presentation.runLabel)
                    row("Candidate corpus", presentation.candidateCorpusLabel)
                    row("Latest run", presentation.progressLabel)
                    if let currentBatchLabel = presentation.currentBatchLabel {
                        row("Current batch", currentBatchLabel)
                    }
                    row("Last run", lastRunLabel)
                    row("Last duration", durationLabel)
                    row("Pending revisions", "\(publisher?.pendingTrainingTargetCount ?? 0)")
                    row("Replay", "\(publisher?.replayCount ?? 0)")
                    row("Aggregate target loss", aggregateTargetLossLabel)
                    row("Validation loss", aggregateValidationLossLabel)
                    row("Loaded adapter", presentation.loadedAdapterLabel)
                    row("Latest candidate", presentation.latestCandidateLabel)
                    row("Next eligible", presentation.nextEligibleLabel)
                    if let err = publisher?.lastError {
                        row("Last error", err, emphasis: true)
                    }
                }
            }
            SettingsRowDivider()
            SettingsCaption("Training runs automatically after ingestion finishes and as eligible sent evidence changes. It runs in the background and yields to foreground work.")
        }
    }

    private var historySection: some View {
        OhiaSettingsCard("History (loss)") {
            SettingsBlock {
                let points = Array(checkpoints.suffix(100))
                if points.isEmpty {
                    Text("No checkpoints yet. Training runs will populate this chart.")
                        .font(OhiaTypography.mono)
                        .foregroundStyle(Color.primary)
                } else {
                    Chart {
                        ForEach(points, id: \.id) { ck in
                            LineMark(
                                x: .value("step", ck.stepCount),
                                y: .value("loss", ck.loss)
                            )
                            .foregroundStyle(ck.archived ? Color.primary.opacity(0.5) : OhiaColors.chipActiveForeground)
                            PointMark(
                                x: .value("step", ck.stepCount),
                                y: .value("loss", ck.loss)
                            )
                            .opacity(ck.archived ? 0.4 : 1.0)
                        }
                    }
                    .frame(height: 160)
                }
            }
        }
    }

    private var checkpointManifestSection: some View {
        // Untitled card — the DisclosureGroup's own label ("Checkpoints (N)")
        // is the header, and it lives inside the card so the chevron and the
        // rows it reveals share one surface.
        OhiaSettingsCard {
            SettingsBlock {
                DisclosureGroup("Checkpoints (\(checkpoints.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(checkpoints.reversed(), id: \.id) { ck in
                            HStack(spacing: 16) {
                                Text("step \(ck.stepCount)")
                                    .frame(width: 90, alignment: .leading)
                                Text(String(format: "loss %.3f", ck.loss))
                                    .frame(width: 90, alignment: .leading)
                                Text(ck.lifecycleRaw ?? "unknown")
                                    .frame(width: 90, alignment: .leading)
                                Text(formatted(ck.createdAt))
                                    .frame(width: 120, alignment: .leading)
                                    .foregroundStyle(Color.primary)
                                if ck.archived {
                                    Text("archived")
                                        .foregroundStyle(Color.primary)
                                }
                                Spacer()
                                if !ck.archived {
                                    Button("Reveal") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ck.adapterPath)])
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .font(OhiaTypography.mono)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.headline)
            }
        }
    }

    private func formatted(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .short; df.timeStyle = .short
        return df.string(from: d)
    }

    private var isTrainingActive: Bool {
        guard let pub = publisher else { return false }
        switch pub.phase {
        case .preparing, .training, .checkpointing: return true
        case .idle, .resetting: return false
        }
    }

    // MARK: - Labels

    private var statusLabel: String {
        guard let pub = publisher else { return "—" }
        // Surface model-load state when training is idle and the engine isn't
        // yet ready — distinguish "still loading" from "failed" so the user
        // doesn't wait forever thinking download is in progress.
        if pub.phase == .idle && !pub.isEngineReady {
            if let generativeStatus = workerStatuses?.snapshot(for: .qwen) {
                return "waiting · Generative Worker \(generativeStatus.resourceState.displayLabel)"
            }
            switch modelLoader?.state {
            case .downloading(let f):   return "waiting · model downloading \(Int(f * 100))%"
            case .downloaded:           return "waiting · model downloaded"
            case .loading:              return "waiting · model loading"
            case .paused(let message):  return message.map { "waiting · \($0)" } ?? "waiting · model download stopped"
            case .failed(let msg):      return "model load failed · \(msg)"
            case .idle, .ready, .none:  return "waiting · model not loaded"
            }
        }
        return presentation.statusLabel
    }

    private var lastRunLabel: String {
        guard let t = publisher?.lastRunAt else { return "never" }
        let df = DateFormatter()
        df.dateStyle = .short; df.timeStyle = .short
        return df.string(from: t)
    }

    private var aggregateTargetLossLabel: String {
        guard let loss = publisher?.aggregateTargetLoss else { return "—" }
        return String(format: "%.4f", loss)
    }

    private var aggregateValidationLossLabel: String {
        guard let loss = publisher?.aggregateValidationLoss else { return "—" }
        return String(format: "%.4f", loss)
    }

    private var durationLabel: String {
        guard let d = publisher?.lastDurationSeconds else { return "—" }
        return String(format: "%.1fs", d)
    }

    private var presentation: TrainingSettingsPresentation {
        let latestCandidate = checkpoints
            .filter { !$0.archived }
            .max { $0.createdAt < $1.createdAt }
        return TrainingSettingsPresentation(
            phase: publisher?.phase ?? .idle,
            runKind: publisher?.runKind,
            runState: publisher?.runState,
            runTargetCount: publisher?.runTargetCount ?? 0,
            runEpoch: publisher?.runEpoch,
            runEpochCount: publisher?.runEpochCount,
            attemptedTargetCount: publisher?.attemptedTargetCount ?? 0,
            incorporatedTargetCount: publisher?.incorporatedTargetCount ?? 0,
            skippedTargetCount: publisher?.skippedTargetCount ?? 0,
            failedTargetCount: publisher?.failedTargetCount ?? 0,
            resourceWaitReason: publisher?.resourceWaitReason,
            idleMinutesThreshold: trainingRunStates.first?.idleMinutesThreshold,
            nextEligibleReason: publisher?.nextEligibleReason,
            isPaused: publisher?.isPaused ?? false,
            adapterStep: publisher?.adapterStep,
            latestCandidateStep: latestCandidate?.stepCount,
            latestCandidateLifecycle: latestCandidate?.lifecycleRaw.flatMap(
                TrainingCheckpointLifecycle.init(rawValue:)
            ),
            trainingCandidateCorpusProgress: publisher?.trainingCandidateCorpusProgress ?? .empty
        )
    }

    // MARK: - Helpers

    @ViewBuilder
    private func row(_ label: String, _ value: String, emphasis: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 140, alignment: .leading)
                .foregroundStyle(Color.primary)
            Text(value)
                .foregroundStyle(emphasis ? Color.red : Color.primary)
                .textSelection(.enabled)
            Spacer()
        }
        .font(OhiaTypography.mono)
    }

    /// Same row shape as `row(_:_:)`, but takes an arbitrary value view
    /// instead of a string — used for the "Status" row's pulsing indicator.
    @ViewBuilder
    private func rowView<Content: View>(
        _ label: String,
        @ViewBuilder value: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 140, alignment: .leading)
                .foregroundStyle(Color.primary)
            value()
            Spacer()
        }
        .font(OhiaTypography.mono)
    }
}

/// Animated "Status · Training" readout — a live pulse beside the current
/// phase label so the row shows the trainer actively working rather than
/// printing a static word. Mirrors `RunningDreamIndicator` in
/// MemoriesSettingsView.swift (same pulse timing and hardcoded green), with
/// `waveform.path.ecg` standing in for `moon.stars.fill` — the Training tab's
/// own sidebar icon (SettingsTab.systemImage), so the pulse reads as "this
/// subsystem is alive" the way the moon reads as "dreaming".
private struct RunningTrainingIndicator: View {
    let label: String
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OhiaColors.ohiaGreen)
                .opacity(pulsing ? 1.0 : 0.45)
                .scaleEffect(pulsing ? 1.0 : 0.88)
            Text(label)
                .foregroundStyle(Color.primary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .accessibilityLabel("Training in progress")
    }
}

extension Notification.Name {
    static let ohiaTrainingResetToBase = Notification.Name("ohia.training.resetToBase")
}
