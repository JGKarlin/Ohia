// Ohia/Settings/DeveloperSettingsView.swift
// Development and testing controls — reset state, inspect pipeline.

import Darwin
import Foundation
import Observation
import SwiftUI
import SwiftData
import OhiaCore
import OhiaMail
import OhiaML
import OhiaScheduler

nonisolated struct DeveloperPipelinePauseButtonPresentation: Equatable {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let help: String

    init(isPaused: Bool, hasCurrentIngestion: Bool) {
        title = isPaused ? "Resume Pipeline" : "Pause Pipeline"
        systemImage = isPaused ? "play.fill" : "pause.fill"
        isEnabled = isPaused || hasCurrentIngestion
        if isPaused {
            help = "Resume pipeline ingestion."
        } else if hasCurrentIngestion {
            help = "Pause pipeline ingestion."
        } else {
            help = "The pipeline is not currently ingesting."
        }
    }
}

@Observable @MainActor
final class PipelinePauseState {
    private(set) var isPaused = false

    func setPaused(_ isPaused: Bool) {
        self.isPaused = isPaused
    }
}

struct DeveloperSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.workerFleetSupervisor) private var workerSupervisor
    @Environment(AppServices.self) private var appServices: AppServices?
    @Environment(IMAPSessionManager.self) private var imapSessionManager: IMAPSessionManager?
    @Environment(PipelinePauseState.self) private var pipelinePauseState
    @Environment(TrainingStatusPublisher.self) private var trainingPublisher: TrainingStatusPublisher?
    @AppStorage("hasCompletedOnboarding", store: OhiaSharedDefaults.store)
    private var hasCompletedOnboarding = false
    @AppStorage("hasCompletedFirstIngestion", store: OhiaSharedDefaults.store)
    private var hasCompletedFirstIngestion = false
    @AppStorage(
        OnboardingPipelineGate.hasReachedWitnessPanelKey,
        store: OhiaSharedDefaults.store
    )
    private var hasReachedOnboardingWitnessPanel = false
    @AppStorage(
        OnboardingPipelineGate.hasRequestedModelPreparationKey,
        store: OhiaSharedDefaults.store
    )
    private var hasRequestedOnboardingModelPreparation = false
    @Query private var accounts: [Account]
    @Query private var folderStates: [IMAPFolderState]

    @State private var showResetConfirm = false
    @State private var showTrainingResetConfirm = false
    @State private var resetStatus: String? = nil
    @State private var resetStatusIsError: Bool = false
    @State private var resetInProgress: Bool = false
    @State private var preparedResetTargets: DeveloperSandboxResetTargets?
    @State private var pipelineSummary = DeveloperPipelineSummary.empty
    @State private var failedJobs: [DeveloperFailureRow] = []
    @State private var retryingJobs: [DeveloperFailureRow] = []
    @State private var modelCacheSnapshot: OhiaModelCacheSnapshot?
    @State private var modelCacheJanitorStatus: String?
    @State private var isPruningModelCaches = false
    @State private var summaryCacheStatus: String?
    @State private var summaryCacheStatusIsError = false
    @State private var isClearingEmailSummaries = false
    @State private var isClearingContextSummaries = false
    @State private var advancedDiagnosticsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Developer")
                    .font(.title2)

                GroupBox(label: Text("Pipeline").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Messages", pipelineSummary.messageSummary)
                        row("Jobs", pipelineSummary.jobSummary)
                        if let loadError = pipelineSummary.loadError {
                            Text(loadError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Divider()
                            .padding(.vertical, 2)
                        Text(pipelinePauseState.isPaused
                            ? "Pipeline is paused. New jobs are not claimed and the long-running ingest loop will break out at its next yield."
                            : "Pipeline is running. Pause to halt new tick claims and unwind in-flight ingest work."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        HStack {
                            let presentation = DeveloperPipelinePauseButtonPresentation(
                                isPaused: pipelinePauseState.isPaused,
                                hasCurrentIngestion: pipelineSummary.hasCurrentIngestion
                            )
                            Button {
                                if pipelinePauseState.isPaused {
                                    NotificationCenter.default.post(name: .ohiaResumePipeline, object: nil)
                                } else {
                                    NotificationCenter.default.post(name: .ohiaPausePipeline, object: nil)
                                }
                            } label: {
                                Label(presentation.title, systemImage: presentation.systemImage)
                            }
                            .buttonStyle(.emblem)
                            .disabled(!presentation.isEnabled)
                            .help(presentation.help)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                pipelineFailuresBox

                summaryCachesBox

                GroupBox(label: Text("State").font(.headline)) {
                    VStack(alignment: .leading, spacing: 4) {
                        let firstIngestion = firstIngestionPresentation
                        row("Onboarded", hasCompletedOnboarding ? "yes" : "no")
                        statusRow("First ingestion", firstIngestion.status.rawValue, status: firstIngestion.status)
                        if firstIngestion.rows.isEmpty {
                            Text("No accounts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(firstIngestion.rows) { row in
                                    firstIngestionAccountRow(row)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                advancedDiagnosticsSection

                GroupBox(label: Text("Reset").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Training personalization")
                            .font(.callout.weight(.semibold))
                        Text("Delete all training checkpoints and temporarily return drafting to the base model. Automatic training will personalize it again from eligible sent evidence.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            showTrainingResetConfirm = true
                        } label: {
                            Label("Reset Training to Base", systemImage: "arrow.counterclockwise.circle")
                        }
                        .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
                        .disabled(!canResetTrainingToBase)
                        .confirmationDialog(
                            "Reset training to base",
                            isPresented: $showTrainingResetConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("Reset Training to Base", role: .destructive) {
                                triggerTrainingReset()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This will delete all training checkpoints and revert the model to base weights. Drafts will temporarily lose personalization until the next automatic training run.")
                        }

                        Divider()
                            .padding(.vertical, 2)

                        Text("Application")
                            .font(.callout.weight(.semibold))
                        Text(DeveloperColdResetCopy.confirmation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Reset Ohia", role: .destructive) {
                                prepareResetConfirmation()
                            }
                            .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
                            .disabled(resetInProgress)
                        }
                        if let resetStatus {
                            Text(resetStatus)
                                .font(.caption)
                                .foregroundStyle(resetStatusIsError ? .red : .secondary)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, 8)
        }
        .alert("Reset Ohia?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) { resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                DeveloperColdResetCopy.confirmation
                    + "\n\n"
                    + (preparedResetTargets?.confirmationScope ?? "Reset targets could not be resolved.")
            )
        }
        .task {
            VectorCollectionVisibilityPreferences.registerDefaults()
            refreshDeveloperSnapshot()
            await refreshModelCacheSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDeveloperSnapshot()
            Task { await refreshModelCacheSnapshot() }
        }
    }

    @ViewBuilder
    private var summaryCachesBox: some View {
        GroupBox(label: Text("Summary Caches").font(.headline)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Email summaries are persisted with each message interpretation and also cached in memory while Ohia is running. Context summaries are persisted by vector evidence fingerprint and cached in memory for locked-node orientation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(role: .destructive) {
                        clearEmailSummaryCache()
                    } label: {
                        Label("Clear Email Summaries", systemImage: "trash")
                    }
                    .disabled(isClearingEmailSummaries)

                    Button(role: .destructive) {
                        clearContextSummaryCache()
                    } label: {
                        Label("Clear Context Summaries", systemImage: "trash")
                    }
                    .disabled(appServices == nil || isClearingContextSummaries)
                }
                .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
                if let summaryCacheStatus {
                    Text(summaryCacheStatus)
                        .font(.caption)
                        .foregroundStyle(summaryCacheStatusIsError ? .red : .secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var advancedDiagnosticsSection: some View {
        GroupBox(label: Text("Advanced Diagnostics").font(.headline)) {
            DisclosureGroup("Model cache janitor", isExpanded: $advancedDiagnosticsExpanded) {
                modelCacheJanitorContent
                    .padding(.top, 6)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var modelCacheJanitorContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inactive retrieval caches are cleaned automatically at launch. Current BGE caches are required and are never deleted by this action.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let modelCacheSnapshot {
                row(
                    "Reclaimable",
                    ByteCountFormatter.string(
                        fromByteCount: modelCacheSnapshot.inactiveBytes,
                        countStyle: .file
                    )
                )
                if modelCacheSnapshot.inactiveBytes > 0 {
                    Button(role: .destructive) {
                        pruneInactiveModelCaches()
                    } label: {
                        Label("Run Cleanup", systemImage: "trash")
                    }
                    .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
                    .disabled(appServices == nil || isPruningModelCaches)
                } else {
                    Text("No inactive retrieval caches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Measuring model caches...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let modelCacheJanitorStatus {
                Text(modelCacheJanitorStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Information-rich view of jobs that hit errors. Shows retry-in-progress
    // rows (pending with retryCount > 0, counting down to nextAttemptAt) and
    // terminal failures (status=.failed), with type / attempt / error /
    // timestamp. `TimelineView` redraws every second so the countdown ticks
    // live without a manual timer.
    @ViewBuilder
    private var pipelineFailuresBox: some View {
        GroupBox(label: Text("Pipeline Failures").font(.headline)) {
            VStack(alignment: .leading, spacing: 8) {
                if retryingJobs.isEmpty && failedJobs.isEmpty {
                    Text("No failures.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        VStack(alignment: .leading, spacing: 6) {
                            if !retryingJobs.isEmpty {
                                Text("Retrying")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(retryingJobs) { job in
                                    failureRow(job: job, now: ctx.date, terminal: false)
                                }
                            }
                            if !failedJobs.isEmpty {
                                if !retryingJobs.isEmpty { Divider().padding(.vertical, 2) }
                                Text("Failed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(failedJobs.prefix(20)) { job in
                                    failureRow(job: job, now: ctx.date, terminal: true)
                                }
                                if failedJobs.count > 20 {
                                    Text("+ \(failedJobs.count - 20) more")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    HStack {
                        Button("Retry Failed") { retryAllFailed() }
                            .disabled(failedJobs.isEmpty)
                        Button("Clear Failures") { clearFailed() }
                            .buttonStyle(.emblem(tint: OhiaColors.ohiaRed))
                            .disabled(failedJobs.isEmpty)
                        Spacer()
                    }
                    .buttonStyle(.emblem)
                    .padding(.top, 4)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func failureRow(job: DeveloperFailureRow, now: Date, terminal: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(job.type)
                .font(.caption)
                .frame(width: 130, alignment: .leading)
            Text(terminal ? "failed" : retryCountdownLabel(for: job, now: now))
                .font(.caption)
                .foregroundStyle(terminal ? .red : .orange)
                .frame(width: 90, alignment: .leading)
            Text(job.error ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("#\(job.retryCount)/\(3)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func retryCountdownLabel(for job: DeveloperFailureRow, now: Date) -> String {
        guard let next = job.nextAttemptAt else { return "retrying" }
        let secs = Int(next.timeIntervalSince(now).rounded())
        if secs <= 0 { return "retrying" }
        if secs < 60 { return "retry in \(secs)s" }
        let m = secs / 60
        let s = secs % 60
        return "retry in \(m)m \(s)s"
    }

    private func retryAllFailed() {
        let queue = JobQueue()
        _ = try? queue.retryAllFailed(context: modelContext)
        refreshDeveloperSnapshot()
    }

    private func clearFailed() {
        let queue = JobQueue()
        _ = try? queue.clearFailed(context: modelContext)
        refreshDeveloperSnapshot()
    }

    private func clearEmailSummaryCache() {
        guard !isClearingEmailSummaries else { return }
        isClearingEmailSummaries = true
        summaryCacheStatus = nil
        summaryCacheStatusIsError = false
        Task { @MainActor in
            defer { isClearingEmailSummaries = false }
            do {
                let count = try SummaryInvalidationApplier(modelContext: modelContext).run()
                await appServices?.onDemandSummarizer.clearMemoryCache()
                NotificationCenter.default.post(name: .ohiaEmailSummariesInvalidated, object: nil)
                summaryCacheStatus = "Cleared \(count) persisted email summar\(count == 1 ? "y" : "ies"), reset the on-demand summary memory cache, and invalidated visible summary snapshots."
                summaryCacheStatusIsError = false
                refreshDeveloperSnapshot()
            } catch {
                summaryCacheStatus = "Could not clear email summaries: \(error.localizedDescription)"
                summaryCacheStatusIsError = true
            }
        }
    }

    private func clearContextSummaryCache() {
        guard !isClearingContextSummaries else { return }
        guard let appServices else {
            summaryCacheStatus = "Context summary cache is unavailable because app services are not loaded."
            summaryCacheStatusIsError = true
            return
        }
        isClearingContextSummaries = true
        summaryCacheStatus = nil
        summaryCacheStatusIsError = false
        Task { @MainActor in
            defer { isClearingContextSummaries = false }
            await appServices.contextOrientationService.clearCache()
            summaryCacheStatus = "Cleared persisted and in-memory context summaries. Locked nodes will regenerate context the next time they open."
            summaryCacheStatusIsError = false
        }
    }

    private var firstIngestionPresentation: DeveloperFirstIngestionPresentation {
        DeveloperFirstIngestionPresentation.make(
            accounts: accounts.map { account in
                DeveloperFirstIngestionPresentation.AccountInput(
                    id: account.id,
                    displayName: account.displayName,
                    emailAddress: account.emailAddress,
                    accountStatus: account.status,
                    imapHost: account.imapHost,
                    imapKeychainRef: account.imapKeychainRef,
                    needsReauth: account.needsReauth,
                    needsImapReauth: account.needsImapReauth,
                    initialIMAPImportCompletedAt: account.initialIMAPImportCompletedAt
                )
            },
            folders: folderStates.compactMap { state in
                guard let accountID = state.account?.id else { return nil }
                return DeveloperFirstIngestionPresentation.FolderInput(
                    accountID: accountID,
                    folderName: state.folderName,
                    folderAttributes: state.folderAttributes,
                    initialImportUIDWorkTotal: state.initialImportUIDWorkTotal,
                    initialImportUIDWorkRemaining: state.initialImportUIDWorkRemaining
                )
            },
            hasCompletedFirstIngestion: hasCompletedFirstIngestion
        )
    }

    private func firstIngestionAccountRow(
        _ row: DeveloperFirstIngestionPresentation.AccountRow
    ) -> some View {
        Text(row.summary)
            .font(.callout)
            .foregroundStyle(firstIngestionStatusColor(row.status))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(row.summary)
    }

    private func statusRow(
        _ label: String,
        _ value: String,
        status: DeveloperFirstIngestionStatus
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .foregroundStyle(firstIngestionStatusColor(status))
        }
        .font(.callout)
    }

    private func firstIngestionStatusColor(_ status: DeveloperFirstIngestionStatus) -> Color {
        switch status {
        case .complete:
            return .green
        case .inProgress:
            return OhiaColors.accentTeal
        case .waiting:
            return .secondary
        case .paused:
            return .orange
        case .needsAttention:
            return .red
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func refreshDeveloperSnapshot() {
        do {
            let now = Date()
            let messages = try modelContext.fetch(FetchDescriptor<Message>())
            let allJobs = try modelContext.fetch(FetchDescriptor<Job>())
            let failed = allJobs.filter { $0.status == .failed }
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            let retrying = allJobs.filter { $0.status == .pending && $0.retryCount > 0 }
                .sorted { ($0.nextAttemptAt ?? .distantFuture) < ($1.nextAttemptAt ?? .distantFuture) }

            pipelineSummary = DeveloperPipelineSummary(messages: messages, jobs: allJobs, now: now)
            failedJobs = failed.map { DeveloperFailureRow(job: $0) }
            retryingJobs = retrying.map { DeveloperFailureRow(job: $0) }
        } catch {
            pipelineSummary = DeveloperPipelineSummary.failed(
                "Could not load pipeline diagnostics: \(error.localizedDescription)"
            )
            failedJobs = []
            retryingJobs = []
        }
    }

    private func refreshModelCacheSnapshot() async {
        guard let appServices else {
            modelCacheSnapshot = nil
            return
        }
        let snapshot = await Task.detached(priority: .utility) {
            appServices.ohiaModelCacheSnapshot()
        }.value
        await MainActor.run {
            modelCacheSnapshot = snapshot
        }
    }

    private func pruneInactiveModelCaches() {
        guard let appServices else { return }
        isPruningModelCaches = true
        modelCacheJanitorStatus = nil
        Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try appServices.pruneInactiveOhiaModelCaches()
                }.value
                await refreshModelCacheSnapshot()
                let reclaimed = ByteCountFormatter.string(
                    fromByteCount: result.reclaimedBytes,
                    countStyle: .file
                )
                modelCacheJanitorStatus = result.removedEntries.isEmpty
                    ? "No inactive retrieval caches were found."
                    : "Removed \(result.removedEntries.count) inactive cache folder(s), reclaiming \(reclaimed)."
            } catch {
                modelCacheJanitorStatus = "Cleanup failed: \(error.localizedDescription)"
            }
            isPruningModelCaches = false
        }
    }

    private var canResetTrainingToBase: Bool {
        trainingPublisher?.phase == .idle
    }

    private func triggerTrainingReset() {
        // OhiaApp observes this notification and invokes CheckpointManager.resetToBase.
        NotificationCenter.default.post(name: .ohiaTrainingResetToBase, object: nil)
    }

    private func resetAll() {
        guard !resetInProgress else { return }
        Task { @MainActor in
            await performReset()
        }
    }

    private func prepareResetConfirmation() {
        do {
            preparedResetTargets = DeveloperSandboxResetTargets(
                sharedLayout: try OhiaStorageRoot.resolve(),
                appPrivateRoot: try OhiaStorageRoot.appPrivateRoot()
            )
            resetStatus = nil
            resetStatusIsError = false
            showResetConfirm = true
        } catch {
            preparedResetTargets = nil
            resetStatusIsError = true
            resetStatus = "Reset unavailable: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func performReset() async {
        guard let preparedResetTargets else {
            resetStatusIsError = true
            resetStatus = "Reset unavailable: the deletion targets were not confirmed."
            return
        }
        resetInProgress = true
        resetStatusIsError = false
        resetStatus = "Scheduling reset"

        do {
            try SandboxResetCoordinator.writePendingMarker(
                sharedLayout: preparedResetTargets.sharedLayout
            )
        } catch {
            resetStatusIsError = true
            resetStatus = "Reset failed: could not schedule the clean reset (\(error.localizedDescription))."
            resetInProgress = false
            print("[Ohia] resetAll: sandbox reset scheduling failed: \(String(reflecting: type(of: error)))")
            return
        }

        resetStatus = "Closing Ohia for reset"
        NotificationCenter.default.post(
            name: .ohiaPausePipeline,
            object: nil,
            userInfo: workerSupervisor == nil ? nil : ["skipWorkerStop": true]
        )

        if let workerSupervisor {
            if !(await workerSupervisor.stopAndWait()) {
                print("[Ohia] resetAll: worker shutdown timed out")
            }
        } else {
            try? await Task.sleep(for: .milliseconds(250))
        }

        do {
            resetStatus = "Clearing worker runtime state..."
            if let workerSupervisor {
                try workerSupervisor.clearResetArtifacts()
            } else {
                try WorkerStatusStore().removeRuntimeArtifacts()
            }
            print("[Ohia] resetAll: worker runtime artifacts cleared")
        } catch {
            print("[Ohia] resetAll: worker artifact cleanup failed: \(String(reflecting: type(of: error)))")
        }

        await imapSessionManager?.shutdown()
        appServices?.shutdown()
        Darwin.exit(EXIT_SUCCESS)
    }
}

enum DeveloperCredentialResetter {
    static let services = [
        OAuthTokenStore.service,
        SMTPCredentials.service,
        IMAPCredentials.service,
        KeychainMCPServerSecretsStore.service,
        HostedMCPAuth.appOnlySecretsService,
        "ohia-mcp-firecrawl-oauth",
    ]

    /// Removes only generic-password items whose service is owned by Ohia.
    static func resetAll() throws {
        for service in services {
            try KeychainHelpers.deleteAll(service: service)
        }
    }
}

enum DeveloperDefaultsResetter {
    /// Removes only Ohia's app and App Group persistent domains.
    static func resetAll(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "org.jgkarlin.Ohia"
    ) {
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        OhiaSharedDefaults.store.removePersistentDomain(
            forName: OhiaSharedDefaults.suiteName
        )
        UserDefaults.standard.synchronize()
        OhiaSharedDefaults.store.synchronize()
    }
}

enum DeveloperColdResetCopy {
    static let confirmation = "This removes Ohia accounts, credentials, messages, summaries, memories, drafts, attachments, indexes, caches, and personalized training state, then returns to onboarding. Source mailboxes and manual exports outside Ohia are not changed. Verified public model downloads may be retained."
}

struct DeveloperSandboxResetTargets {
    let sharedLayout: OhiaStorageLayout
    let appPrivateRoot: URL

    var confirmationScope: String {
        [
            "App Group private state deleted on next launch:",
            "• \(sharedLayout.privateRoot.path)",
            "App-private state deleted on next launch:",
            "• \(appPrivateRoot.path)",
            "Credential services deleted on next launch:",
            DeveloperCredentialResetter.services.map { "• \($0)" }.joined(separator: "\n"),
            "Verified public models retained:",
            "• \(sharedLayout.publicModels.path)",
            "Manual exports: outside these targets and unchanged",
        ].joined(separator: "\n")
    }
}

private struct DeveloperFailureRow: Identifiable, Equatable {
    let id: UUID
    let type: String
    let error: String?
    let retryCount: Int
    let nextAttemptAt: Date?

    init(job: Job) {
        self.id = job.id
        self.type = job.type.rawValue
        self.error = job.error
        self.retryCount = job.retryCount
        self.nextAttemptAt = job.nextAttemptAt
    }
}

private struct DeveloperPipelineSummary: Equatable {
    var messageCount: Int
    var classifiedCount: Int
    var summarizedCount: Int
    var embeddedCount: Int
    var jobCount: Int
    var readyJobCount: Int
    var scheduledJobCount: Int
    var runningJobCount: Int
    var retryingJobCount: Int
    var failedJobCount: Int
    var loadError: String?

    static let empty = DeveloperPipelineSummary()

    init(
        messageCount: Int = 0,
        classifiedCount: Int = 0,
        summarizedCount: Int = 0,
        embeddedCount: Int = 0,
        jobCount: Int = 0,
        readyJobCount: Int = 0,
        scheduledJobCount: Int = 0,
        runningJobCount: Int = 0,
        retryingJobCount: Int = 0,
        failedJobCount: Int = 0,
        loadError: String? = nil
    ) {
        self.messageCount = messageCount
        self.classifiedCount = classifiedCount
        self.summarizedCount = summarizedCount
        self.embeddedCount = embeddedCount
        self.jobCount = jobCount
        self.readyJobCount = readyJobCount
        self.scheduledJobCount = scheduledJobCount
        self.runningJobCount = runningJobCount
        self.retryingJobCount = retryingJobCount
        self.failedJobCount = failedJobCount
        self.loadError = loadError
    }

    init(messages: [Message], jobs: [Job], now: Date = Date()) {
        let readyJobs = jobs.filter {
            $0.status == .pending &&
            $0.retryCount == 0 &&
            (($0.nextAttemptAt ?? .distantPast) <= now)
        }
        let scheduledJobs = jobs.filter {
            $0.status == .pending &&
            $0.retryCount == 0 &&
            (($0.nextAttemptAt ?? .distantPast) > now)
        }
        self.init(
            messageCount: messages.count,
            classifiedCount: messages.filter { $0.messageType != .unclassified }.count,
            summarizedCount: messages.filter { $0.analysis?.bodySummary != nil }.count,
            embeddedCount: messages.filter { $0.embeddingStatus == .completed }.count,
            jobCount: jobs.count,
            readyJobCount: readyJobs.count,
            scheduledJobCount: scheduledJobs.count,
            runningJobCount: jobs.filter { $0.status == .running }.count,
            retryingJobCount: jobs.filter { $0.status == .pending && $0.retryCount > 0 }.count,
            failedJobCount: jobs.filter { $0.status == .failed }.count
        )
    }

    static func failed(_ message: String) -> DeveloperPipelineSummary {
        DeveloperPipelineSummary(loadError: message)
    }

    var messageSummary: String {
        "\(Self.decimal(messageCount)) total · \(Self.decimal(classifiedCount)) classified · \(Self.decimal(summarizedCount)) summarized · \(Self.decimal(embeddedCount)) embedded"
    }

    var jobSummary: String {
        "\(Self.decimal(jobCount)) total · \(Self.decimal(readyJobCount)) ready · \(Self.decimal(scheduledJobCount)) scheduled · \(Self.decimal(runningJobCount)) running · \(Self.decimal(retryingJobCount)) retrying · \(Self.decimal(failedJobCount)) failed"
    }

    var hasCurrentIngestion: Bool {
        readyJobCount > 0 || runningJobCount > 0
    }

    private static func decimal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
