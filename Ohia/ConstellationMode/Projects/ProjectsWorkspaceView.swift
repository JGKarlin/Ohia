import AppKit
import SwiftUI
import SwiftData
import OhiaCore
import OhiaML
import OhiaScheduler

// Projects is a SwiftUI/Canvas workspace. The normal Metal scene should not mount for `.projects`.

enum ProjectsMessageFilterScope {
    nonisolated static func isActive(
        filter: VectorFilter,
        restFilter: VectorFilter
    ) -> Bool {
        var normalizedFilter = filter
        normalizedFilter.collections = restFilter.collections
        return normalizedFilter != restFilter
    }
}

struct DeadlineMastheadCounts: Equatable {
    let upcoming: Int
    let overdue: Int

    static func resolve(
        tracker: DeadlineTrackerSnapshot,
        hiddenIDs: Set<String>
    ) -> DeadlineMastheadCounts {
        DeadlineMastheadCounts(
            upcoming: tracker.upcoming.count(where: { hiddenIDs.contains($0.id) == false }),
            overdue: tracker.past.count(where: { hiddenIDs.contains($0.id) == false })
        )
    }
}

struct ProjectsWorkspaceView: View {
    @Bindable var constellationState: ConstellationState
    @Bindable var workspace: ProjectsWorkspaceState
    let dataController: ProjectsDataController
    let modelContext: ModelContext
    let vectorStore: VectorStore
    let tagRecommendationClient: ProjectTagRecommendationClient
    @Bindable var newStarNavigator: NewStarNavigator
    @Bindable var manualRefresh: ManualRefreshCoordinator
    let summaryByMessageId: [String: String]
    let summaryUnavailableReasonByMessageId: [String: String]
    let summaryUnavailableMessageIds: Set<String>
    let regeneratingSummaryMessageIds: Set<String>
    let projectSummaryService: ProjectSummaryService
    let projectSummaryUserIdentity: SummarizationUserIdentity?
    let deadlineSummaryService: DeadlineSummaryService
    let attachmentSummaryService: AttachmentSummaryService
    let jobCompletionBroadcaster: JobCompletionBroadcaster
    let onStarburstClick: () -> Void
    let onBeaconMenuCommand: (BeaconArrivalMenuRequest) -> Void
    let onPresentMessageMenu: @MainActor (UUID, String, NSPoint, NSView) -> Void
    let onPresentRowMenu: @MainActor (ProjectRow, NSPoint, NSView) -> Void
    let onSendToComposer: @MainActor @Sendable ([UUID]) -> Void
    let onIgnoreMessage: @MainActor @Sendable (UUID) -> Void
    /// Shared cross-lens message mutation bundle, consumed by the
    /// workroom's per-card hover action cluster and reader.
    let messageActions: FrontPageMessageActionHandlers
    let showsControlColumn: Bool
    /// Shared send-to-Composer dispatch coordinator, forwarded to the time view's
    /// comet overlay so a send launches a comet from each queued message's dot.
    let composerDispatch: ComposerDispatchCoordinator

    @Environment(\.undoManager) private var undoManager
    @Query(sort: \MailProjectConfigurationDraft.updatedAt, order: .reverse)
    private var projectConfigurationDraftModels: [MailProjectConfigurationDraft]
    @AppStorage("constellationSidebarSide") private var sidebarSideRaw: String = "leading"
    @State private var didInitialize = false
    @State private var configurationExitRequestSequence = 0
    @State private var configurationCanNavigateAway = true
    @State private var pendingProjectDraftDeletion: ProjectConfigurationDraftRow?

    var body: some View {
        GeometryReader { proxy in
            let columnOnLeading = sidebarSideRaw == "trailing"
            HStack(spacing: 0) {
                if showsControlColumn && columnOnLeading {
                    if workspace.selectedMode.configurationRoute == nil {
                        controlColumn(onLeading: true)
                    }
                }

                VStack(spacing: 0) {
                    projectsModeStrip
                    Divider()
                        .overlay(OhiaColors.glassBorder)
                    workspaceBody
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showsControlColumn && !columnOnLeading {
                    if workspace.selectedMode.configurationRoute == nil {
                        controlColumn(onLeading: false)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.space) {
                workspace.handleSpaceKeyFromKeyboard(shift: false) ? .handled : .ignored
            }
            .onKeyPress(.escape) {
                handleEscapeLadder() ? .handled : .ignored
            }
            .onKeyPress(.init("a"), phases: .down) { press in
                guard press.modifiers.contains(.command),
                      workspace.selectedMode == .time,
                      let snapshot = workspace.currentSnapshot else { return .ignored }
                // Select only rows the user can actually see; collapsed
                // inactive sections must not be swept into bulk actions.
                let keys = ProjectsTimeView.visibleProjectionRows(
                    snapshot: snapshot,
                    workspace: workspace
                )
                .map(\.projectKey)
                workspace.selectAll(in: keys)
                return .handled
            }
            .onKeyPress(.init("d"), phases: .down) { press in
                guard press.modifiers.contains(.command),
                      workspace.selectedMode == .time,
                      !workspace.selectedProjectKeys.isEmpty else { return .ignored }
                workspace.clearSelection()
                return .handled
            }
            // ↑/↓ step the selection through the visible project rows in
            // display order — the keyboard mirror of a plain gutter click.
            // `ProjectsKeyboardCatcher` carries the mouse-driven case (this
            // handler needs container key focus, which mouse use never
            // grants); bare arrows only, so ⇧/⌘/⌥/⌃ combos pass through.
            .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
                // Arrow presses can carry .numericPad/.function — judge only
                // the four real modifiers.
                guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty else {
                    return .ignored
                }
                return stepSelection(by: 1) ? .handled : .ignored
            }
            .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
                guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty else {
                    return .ignored
                }
                return stepSelection(by: -1) ? .handled : .ignored
            }
            .onKeyPress(.init("r"), phases: .down) { press in
                guard press.modifiers.contains(.command),
                      workspace.selectedMode == .time else { return .ignored }
                let rows = workspace.selectedRows
                guard !rows.isEmpty else { return .ignored }
                let repository = MailProjectRepository(modelContext: modelContext)
                // Majority-flips: matches the bulk right-click menu's
                // policy so muscle memory between mouse and keyboard
                // stays aligned on mixed-state selections. Counts derived
                // resolution so cross-lens resolved rows flip too.
                let resolvedCount = rows.filter(\.isResolvedEffective).count
                let target = resolvedCount <= rows.count / 2
                setResolved(rows, to: target, using: repository)
                return .handled
            }
            // ⌘+ / ⌘− zoom the Time view's shared axis around its center;
            // ⌘0 resets to the automatic fit. "=" covers the unshifted
            // key under the + cap on ANSI layouts.
            .onKeyPress(.init("="), phases: .down) { press in
                handleTimeZoomKey(press, scale: 1.5)
            }
            .onKeyPress(.init("+"), phases: .down) { press in
                handleTimeZoomKey(press, scale: 1.5)
            }
            .onKeyPress(.init("-"), phases: .down) { press in
                handleTimeZoomKey(press, scale: 1 / 1.5)
            }
            .onKeyPress(.init("0"), phases: .down) { press in
                guard press.modifiers.contains(.command),
                      workspace.selectedMode == .time,
                      workspace.timeZoomRange != nil else { return .ignored }
                workspace.timeZoomRange = nil
                return .handled
            }
        }
        // The lens shares the Front Page's night-sky backdrop (starfield, no
        // Milky Way band) so its cards and the selection glow sit on the same
        // register as the other card-based lens. The sky is always dark (§18
        // exception), so the whole lens pins to the dark register — same
        // discipline as `ConstellationLensSurfaceStatusView` over the sky —
        // otherwise Light-mode tokens resolve dark-on-near-black.
        .environment(\.colorScheme, .dark)
        .background(NightSkyView(showsMilkyWay: false, twinkles: false))
        .background {
            ProjectsKeyboardCatcher(
                onSpace: {
                    workspace.handleSpaceKeyFromKeyboard(shift: false)
                },
                onShiftSpace: {
                    workspace.handleSpaceKeyFromKeyboard(shift: true)
                },
                onEscape: {
                    handleEscapeLadder()
                },
                onStepSelection: { delta in
                    stepSelection(by: delta)
                }
            )
        }
        .onAppear {
            initializeIfNeeded()
        }
        .onDisappear {
            dataController.unbind()
        }
        .onChange(of: workspaceFingerprint) { previous, current in
            handleFingerprintChange(previous: previous, current: current)
        }
        .confirmationDialog(
            "Discard project draft?",
            isPresented: projectDraftDeletionIsPresented,
            presenting: pendingProjectDraftDeletion
        ) { _ in
            Button("Discard", systemImage: "trash", role: .destructive) {
                Task { await discardProjectDraft() }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", systemImage: "xmark", role: .cancel) {
                pendingProjectDraftDeletion = nil
            }
        } message: { draft in
            if draft.existingProjectID == nil {
                Text("This removes “\(draft.displayName)” and its saved configuration. The project has not been activated.")
            } else {
                Text("This removes the unsaved configuration changes for “\(draft.displayName)”. The active project remains unchanged.")
            }
        }
        .alert(projectWorkspaceAlertTitle, isPresented: projectWorkspaceAlertIsPresented) {
            if let confirmation = projectDeletionConfirmation {
                Button("Cancel", systemImage: "xmark", role: .cancel) {
                    workspace.clearProjectDeletionRequest()
                }
                Button(
                    confirmation.confirmationTitle,
                    systemImage: "trash",
                    role: .destructive
                ) {
                    guard let request = workspace.projectDeletionRequest else { return }
                    workspace.clearProjectDeletionRequest()
                    Task { @MainActor in
                        await Task.yield()
                        await deleteProject(request)
                    }
                }
            } else {
                Button("OK", systemImage: "checkmark") {
                    workspace.clearProjectMutationFailure()
                }
            }
        } message: {
            Text(projectWorkspaceAlertMessage)
        }
    }

    private var projectWorkspaceAlertTitle: String {
        projectDeletionConfirmation?.title
            ?? workspace.projectMutationFailure?.title
            ?? "Project Update Failed"
    }

    private var projectWorkspaceAlertMessage: String {
        projectDeletionConfirmation?.message
            ?? workspace.projectMutationFailure?.message
            ?? ""
    }

    private var projectWorkspaceAlertIsPresented: Binding<Bool> {
        Binding(
            get: {
                workspace.projectDeletionRequest != nil
                    || workspace.projectMutationFailure != nil
            },
            set: { presented in
                guard !presented else { return }
                if workspace.projectDeletionRequest != nil {
                    workspace.clearProjectDeletionRequest()
                } else {
                    workspace.clearProjectMutationFailure()
                }
            }
        )
    }

    private var projectDeletionConfirmation: ProjectDeletionConfirmation? {
        workspace.projectDeletionRequest.map {
            ProjectDeletionConfirmation(
                displayName: $0.displayName,
                memberCount: $0.memberCount
            )
        }
    }

    private var projectDraftDeletionIsPresented: Binding<Bool> {
        Binding(
            get: { pendingProjectDraftDeletion != nil },
            set: { presented in
                if presented == false {
                    pendingProjectDraftDeletion = nil
                }
            }
        )
    }

    private var projectConfigurationDraft: ProjectConfigurationDraftRow? {
        for model in projectConfigurationDraftModels {
            let fallbackName = model.targetProjectID.flatMap { targetID in
                workspace.currentSnapshot?.rows.first(where: { $0.projectID == targetID })?.displayLabel
            }
            let snapshot = MailProjectConfigurationDraftSnapshot(
                id: model.id,
                targetProjectID: model.targetProjectID,
                baseRevision: model.baseRevision,
                payloadVersion: model.payloadVersion,
                payloadJSON: model.payloadJSON,
                createdAt: model.createdAt,
                updatedAt: model.updatedAt
            )
            if let row = ProjectConfigurationDraftRow(
                snapshot: snapshot,
                fallbackDisplayName: fallbackName
            ) {
                return row
            }
        }
        return nil
    }

    private var workspaceBody: some View {
        Group {
            if workspace.lensTab == .projects,
               let route = workspace.selectedMode.configurationRoute {
                ProjectConfigurationWorkspaceHost(
                    route: route,
                    container: modelContext.container,
                    tagRecommendationClient: tagRecommendationClient,
                    exitRequestSequence: configurationExitRequestSequence,
                    canNavigateAway: $configurationCanNavigateAway,
                    onCancel: {
                        workspace.returnToTimeView()
                    },
                    onSaved: { completion in
                        workspace.returnToTimeView()
                        workspace.focusProject(completion.projectID.uuidString.lowercased())
                        workspace.bumpActionRevision()
                        dataController.invalidateAndRefresh()
                    }
                )
                .id(route)
            } else if let snapshot = workspace.currentSnapshot,
               snapshotMatchesCurrentTab(snapshot) {
                if workspace.lensTab == .deadlines {
                    ProjectsDeadlinesView(
                        workspace: workspace,
                        snapshot: snapshot,
                        modelContext: modelContext,
                        dataController: dataController,
                        messageActions: messageActions,
                        composerDispatch: composerDispatch,
                        deadlineSummaryService: deadlineSummaryService,
                        deadlineSummaryUserIdentity: projectSummaryUserIdentity,
                        onPresentMessageMenu: { messageID, point, view in
                            let projectKey = snapshot.row(containing: messageID)?.projectKey ?? ""
                            onPresentMessageMenu(messageID, projectKey, point, view)
                        }
                    )
                } else {
                    projectsSurface(snapshot: snapshot)
                }
            } else {
                OhiaLoadingIndicator(accessibilityLabel: "Loading projects")
            }
        }
    }

    @ViewBuilder
    private func projectsSurface(snapshot: ProjectsSnapshot) -> some View {
        switch workspace.selectedMode {
        case .time:
            ProjectsTimeView(
                        workspace: workspace,
                        snapshot: snapshot,
                        momentsRange: constellationState.filter.timeRange,
                        projectDraft: projectConfigurationDraft,
                        summaryByMessageId: summaryByMessageId,
                        summaryUnavailableReasonByMessageId: summaryUnavailableReasonByMessageId,
                        summaryUnavailableMessageIds: summaryUnavailableMessageIds,
                        regeneratingSummaryMessageIds: regeneratingSummaryMessageIds,
                        modelContext: modelContext,
                        projectSummaryService: projectSummaryService,
                        projectSummaryUserIdentity: projectSummaryUserIdentity,
                        onPresentMessageMenu: { messageID, point, view in
                            let projectKey = snapshot.row(containing: messageID, preferredProjectKey: workspace.focusedProjectKey)?.projectKey
                                ?? workspace.focusedProjectKey
                                ?? ""
                            onPresentMessageMenu(messageID, projectKey, point, view)
                        },
                        onPresentRowMenu: onPresentRowMenu,
                        onCommitRename: { projectKey, newName in
                            guard let row = snapshot.rows.first(where: { $0.projectKey == projectKey }) else {
                                workspace.endRenaming()
                                return true
                            }
                            let sanitized = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !sanitized.isEmpty, sanitized != row.displayLabel else {
                                workspace.endRenaming()
                                return true
                            }
                            let repository = MailProjectRepository(modelContext: modelContext)
                            let succeeded = performProjectMutation(action: .rename) {
                                try repository.rename(projectID: row.projectID, to: sanitized)
                            }
                            if succeeded { workspace.endRenaming() }
                            return succeeded
                        },
                        onCancelRename: {
                            workspace.endRenaming()
                        },
                        onCreateProject: {
                            workspace.requestNewProjectConfiguration()
                        },
                        onOpenProjectDraft: {
                            guard let projectConfigurationDraft else { return }
                            workspace.requestProjectDraftConfiguration(
                                draftID: projectConfigurationDraft.id
                            )
                        },
                        onDeleteProjectDraft: { draft in
                            pendingProjectDraftDeletion = draft
                        },
                        composerDispatch: composerDispatch
                    )
        case .linksFor(let projectKey):
            ProjectsWorkroomView(
                workspace: workspace,
                snapshot: snapshot,
                focusProjectKey: projectKey,
                summaryByMessageId: summaryByMessageId,
                regeneratingSummaryMessageIds: regeneratingSummaryMessageIds,
                modelContext: modelContext,
                messageActions: messageActions,
                deadlineSummaryService: deadlineSummaryService,
                attachmentSummaryService: attachmentSummaryService,
                jobCompletionBroadcaster: jobCompletionBroadcaster,
                guideUserIdentity: projectSummaryUserIdentity,
                hasActiveMessageFilters: ProjectsMessageFilterScope.isActive(
                    filter: constellationState.filter,
                    restFilter: ConstellationState.projectsLensMessageFilterRestState()
                ),
                onMembershipChanged: { hold in
                    dataController.invalidateAndRefresh(holdingFor: hold)
                },
                onPresentMessageMenu: { messageID, point, view in
                    let resolvedProjectKey = snapshot.row(
                        containing: messageID,
                        preferredProjectKey: workspace.focusedProjectKey ?? projectKey
                    )?.projectKey ?? projectKey
                    onPresentMessageMenu(messageID, resolvedProjectKey, point, view)
                }
            )
        case .configure(let route):
            ProjectConfigurationWorkspaceHost(
                route: route,
                container: modelContext.container,
                tagRecommendationClient: tagRecommendationClient,
                exitRequestSequence: configurationExitRequestSequence,
                canNavigateAway: $configurationCanNavigateAway,
                onCancel: {
                    workspace.returnToTimeView()
                },
                onSaved: { completion in
                    workspace.returnToTimeView()
                    workspace.focusProject(completion.projectID.uuidString.lowercased())
                    workspace.bumpActionRevision()
                    dataController.invalidateAndRefresh()
                }
            )
            .id(route)
        }
    }

    private var projectsModeStrip: some View {
        ZStack {
            // Centered identifier — sits in its own layer so it remains horizontally centered
            // on the strip regardless of the picker and status-pill widths to its sides.
            Group {
                if workspace.lensTab == .deadlines {
                    deadlineMasthead
                } else if workspace.selectedMode.configurationRoute != nil {
                    Text("Project Configuration")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OhiaColors.textPrimary)
                } else if workspace.selectedProjectKeys.count >= 2 {
                    Text("\(workspace.selectedProjectKeys.count) projects selected")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                        .monospacedDigit()
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                } else if let row = workspace.focusedRow {
                    Text(row.displayLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                } else if let snapshot = workspace.currentSnapshot {
                    let displayed = snapshot.displayedRows()
                    Text("\(displayed.count) project\(displayed.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OhiaColors.textSecondary)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 12) {
                // The Projects / Deadlines selector belongs to the top level of
                // each tracker; a focused sub-view (project workroom or deadline
                // workroom) shows only the back chevron.
                if !isInFocusedSubview {
                    lensTabToggle
                }

                if workspace.lensTab == .projects, isInFocusedSubview {
                    ProjectsBackButton(
                        accessibilityLabel: workspace.selectedMode.configurationRoute == nil
                            ? "Back to Time"
                            : "Back to Projects",
                        isEnabled: workspace.selectedMode.configurationRoute == nil
                            || configurationCanNavigateAway
                    ) {
                        if workspace.selectedMode.configurationRoute != nil {
                            configurationExitRequestSequence &+= 1
                            return
                        }
                        workspace.returnToTimeView()
                        workspace.focusProject(nil)
                    }
                    .keyboardShortcut(
                        workspace.selectedMode.configurationRoute == nil
                            ? nil
                            : .cancelAction
                    )
                } else if workspace.lensTab == .deadlines, workspace.openedDeadlineID != nil {
                    ProjectsBackButton(accessibilityLabel: "Back to Time", isEnabled: true) {
                        workspace.closeDeadline()
                    }
                }

                if workspace.lensTab == .projects, workspace.selectedMode == .time {
                    if workspace.selectedProjectKeys.count >= 2 {
                        let openCount = workspace.selectedRows.map(\.obligationLoad.visibleOpenCount).reduce(0, +)
                        Text("\(openCount) open")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(openCount > 0 ? OhiaColors.chipActiveForeground : OhiaColors.textTertiary)
                    } else if workspace.focusedRow == nil, let snapshot = workspace.currentSnapshot {
                        // Open-obligation pill only when something is actually
                        // open — a dead "0 open" is chrome without information.
                        let rows = snapshot.displayedRows()
                        let openCount = rows.map(\.obligationLoad.visibleOpenCount).reduce(0, +)
                        if openCount > 0 {
                            Text("\(openCount) open")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(OhiaColors.chipActiveForeground)
                        }
                    }
                }

                Spacer(minLength: 8)

                if workspace.lensTab == .projects,
                   workspace.selectedMode == .time,
                   workspace.timeZoomRange != nil {
                    Button {
                        workspace.timeZoomRange = nil
                    } label: {
                        Label("Reset Zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 9, verticalPadding: 4))
                    .help("Fit the time axis to the current scope (⌘0)")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(height: 48)
        .background(OhiaColors.toolbarBackground)
    }

    /// True while a focused sub-view is mounted — the project workroom or the
    /// deadline workroom. The tab selector hides here; only the back chevron
    /// shows.
    private var isInFocusedSubview: Bool {
        (workspace.lensTab == .projects && (
            workspace.selectedMode.isLinks
                || workspace.selectedMode.configurationRoute != nil
        ))
            || (workspace.lensTab == .deadlines && workspace.openedDeadlineID != nil)
    }

    /// The two-segment Projects / Deadlines switch. The active segment carries
    /// the mode-aware accent; the rest of the strip reacts to `lensTab`.
    private var lensTabToggle: some View {
        HStack(spacing: 0) {
            ForEach(ProjectsLensTab.allCases, id: \.self) { tab in
                let active = workspace.lensTab == tab
                Button {
                    workspace.switchLensTab(to: tab)
                    refresh()
                } label: {
                    Label(
                        tab.title,
                        systemImage: tab == .projects ? "folder" : "calendar"
                    )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(active ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(OhiaColors.chipActiveBackground)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tab.title) tracker")
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(OhiaColors.surface(0.10))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OhiaColors.glassBorder, lineWidth: 1))
        )
    }

    /// Deadlines-tab masthead: upcoming count, and overdue count in petal-red
    /// when anything has lapsed.
    private var deadlineMasthead: some View {
        let tracker = workspace.deadlineTracker()
        let _ = workspace.deadlineDispositionRevision
        let dispositions = DeadlineGuideStateStore(modelContext: modelContext)
            .dispositions(entryIDs: Set(tracker.allEntries.map(\.id)))
        let hiddenIDs = Set(dispositions.compactMap { id, disposition in
            disposition.isHidden ? id : nil
        })
        let counts = DeadlineMastheadCounts.resolve(
            tracker: tracker,
            hiddenIDs: hiddenIDs
        )
        return HStack(spacing: 6) {
            Text("\(counts.upcoming) upcoming")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OhiaColors.textSecondary)
                .monospacedDigit()
            if counts.overdue > 0 {
                Text("·")
                    .font(.system(size: 12))
                    .foregroundStyle(OhiaColors.textTertiary)
                Text("\(counts.overdue) overdue")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OhiaColors.ohiaRed)
                    .monospacedDigit()
            }
        }
    }

    private struct WorkspaceFingerprint: Equatable {
        let filter: VectorFilter
        let actionRevision: Int
    }

    private var workspaceFingerprint: WorkspaceFingerprint {
        WorkspaceFingerprint(
            filter: constellationState.filter,
            actionRevision: workspace.actionRevision
        )
    }

    private func initializeIfNeeded() {
        dataController.bind(
            workspace: workspace,
            modelContext: modelContext,
            vectorStore: vectorStore
        )
        if didInitialize == false {
            didInitialize = true
        }
        refresh()
    }

    private func handleFingerprintChange(
        previous: WorkspaceFingerprint,
        current: WorkspaceFingerprint
    ) {
        if previous.filter != current.filter {
            workspace.clearFocusForFilterChange()
            // A manual axis zoom is meaningless against a different scope's
            // date range — reset to the automatic fit.
            workspace.timeZoomRange = nil
        }
        refresh()
    }

    private func refresh() {
        dataController.requestRefresh(filter: constellationState.filter)
    }

    private func snapshotMatchesCurrentTab(_ snapshot: ProjectsSnapshot) -> Bool {
        switch workspace.lensTab {
        case .projects:
            ProjectsDataController.signatureMatchesCurrentFilter(
                snapshot: snapshot,
                filter: constellationState.filter
            )
        case .deadlines:
            ProjectsDataController.deadlineSignatureMatchesCurrentFilter(
                snapshot: snapshot,
                filter: constellationState.filter
            )
        }
    }

    private func handleTimeZoomKey(_ press: KeyPress, scale: CGFloat) -> KeyPress.Result {
        guard press.modifiers.contains(.command),
              workspace.selectedMode == .time,
              let snapshot = workspace.currentSnapshot else { return .ignored }
        ProjectsTimeView.stepZoom(
            by: scale,
            workspace: workspace,
            snapshot: snapshot,
            momentsRange: constellationState.filter.timeRange
        )
        return .handled
    }

    /// ↑/↓ selection stepping through the rows the user can actually see,
    /// in display order under the current Active/Inactive disclosure. With no
    /// selection, ↓ starts at the first row and ↑ at the last; a
    /// multi-selection collapses to a single row stepped from its anchor.
    /// Edges clamp — the key stays consumed so the scroll view does not
    /// also page. Mirrors a plain gutter click: the manual axis zoom
    /// drops so the focus-fit projection lands on the new row.
    private func stepSelection(by delta: Int) -> Bool {
        guard workspace.selectedMode == .time,
              let snapshot = workspace.currentSnapshot else { return false }
        let keys = ProjectsTimeView.visibleProjectionRows(
            snapshot: snapshot,
            workspace: workspace
        )
        .map(\.projectKey)
        guard !keys.isEmpty else { return false }

        let referenceKey = workspace.focusedProjectKey ?? workspace.selectionAnchorKey
        let targetKey: String
        if let referenceKey, let index = keys.firstIndex(of: referenceKey) {
            targetKey = keys[min(max(index + delta, 0), keys.count - 1)]
        } else {
            targetKey = delta > 0 ? keys.first! : keys.last!
        }
        guard workspace.selectedProjectKeys != [targetKey] else { return true }
        // Stepping re-fits the axis to the new row's span; a pinned readout
        // anchored to pre-reflow coordinates would visibly detach.
        workspace.dismissMessageReadout()
        workspace.focusProject(targetKey)
        workspace.timeZoomRange = nil
        return true
    }

    /// ESC ladder, most-transient first. Shared by the SwiftUI
    /// `.onKeyPress(.escape)` handler (fires when the container has key
    /// focus) and `ProjectsKeyboardCatcher` (fires regardless of SwiftUI
    /// focus — the common mouse-driven case). Returns true when a rung
    /// consumed the key:
    ///   1. Dismiss a pinned message readout if one is open.
    ///   2. From the per-project Links surface, return to Time (also
    ///      drops the focused row, since the back chevron does the same).
    ///   3. From Time view with any selection, release it.
    ///   4. Reset a manual time-axis zoom back to the automatic fit.
    private func handleEscapeLadder() -> Bool {
        if workspace.messageReadout != nil {
            workspace.dismissMessageReadout()
            return true
        }
        if workspace.lensTab == .deadlines {
            if workspace.openedDeadlineID != nil {
                workspace.closeDeadline()
                return true
            }
            if workspace.selectedCalendarDay != nil {
                workspace.selectedCalendarDay = nil
                return true
            }
            return false
        }
        if workspace.selectedMode.configurationRoute != nil {
            return false
        }
        if workspace.selectedMode.isLinks {
            // Collapse the workroom's open reader first; a second ESC
            // then leaves the workroom.
            if workspace.workroomExpandedMessageID != nil {
                workspace.workroomExpandedMessageID = nil
                return true
            }
            workspace.returnToTimeView()
            workspace.clearSelection()
            return true
        }
        if !workspace.selectedProjectKeys.isEmpty {
            workspace.clearSelection()
            return true
        }
        if workspace.timeZoomRange != nil {
            workspace.timeZoomRange = nil
            return true
        }
        return false
    }

    private func controlColumn(onLeading: Bool) -> ProjectsRightControlColumn {
        let sendToComposer: @MainActor @Sendable ([UUID]) -> Void = onSendToComposer
        let ignoreMessage: @MainActor @Sendable (UUID) -> Void = { id in
            onIgnoreMessage(id)
        }
        return ProjectsRightControlColumn(
            workspace: workspace,
            onLeading: onLeading,
            newStarNavigator: newStarNavigator,
            manualRefresh: manualRefresh,
            onStarburstClick: onStarburstClick,
            onBeaconMenuCommand: onBeaconMenuCommand,
            clearMessageFiltersActive: ProjectsMessageFilterScope.isActive(
                filter: constellationState.filter,
                restFilter: ConstellationState.projectsLensMessageFilterRestState()
            ),
            onClearMessageFilters: {
                constellationState.clearProjectsLensMessageFilters()
            },
            onSetPinned: { row, pinned in
                let repository = MailProjectRepository(modelContext: modelContext)
                performProjectMutation(action: pinned ? .pin : .unpin) {
                    try repository.setPinned(projectID: row.projectID, pinned)
                }
            },
            onSetResolved: { row, resolved in
                let repository = MailProjectRepository(modelContext: modelContext)
                performProjectMutation(action: resolved ? .resolve : .reopen) {
                    try repository.setResolved(projectID: row.projectID, resolved)
                }
            },
            deadlineDisposition: { entryID in
                DeadlineGuideStateStore(modelContext: modelContext)
                    .disposition(entryID: entryID)
            },
            onSetDeadlinePinned: { entry, pinned in
                let store = DeadlineGuideStateStore(modelContext: modelContext)
                performDeadlineMutation(action: pinned ? .pinDeadline : .unpinDeadline) {
                    try store.setPinned(pinned, entryID: entry.id)
                }
            },
            onSetDeadlineHidden: { entry, hidden in
                let store = DeadlineGuideStateStore(modelContext: modelContext)
                performDeadlineMutation(action: hidden ? .hideDeadline : .unhideDeadline) {
                    try store.setHidden(hidden, entryID: entry.id)
                }
            },
            onConfigureProject: { row in
                workspace.requestProjectConfiguration(projectID: row.projectID)
            },
            onSendToComposer: { ids in
                sendToComposer(ids)
            },
            ignoreTargetMessageID: listIgnoreTargetMessageID,
            onIgnoreMessage: ignoreMessage,
            messageActions: messageActions
        )
    }

    @discardableResult
    private func performProjectMutation(
        action: ProjectMutationAction,
        _ mutation: () throws -> Void
    ) -> Bool {
        do {
            try mutation()
            workspace.clearProjectMutationFailure()
            workspace.bumpActionRevision()
            dataController.invalidateAndRefresh()
            return true
        } catch {
            workspace.reportProjectMutationFailure(action: action, error: error)
            return false
        }
    }

    @discardableResult
    private func performDeadlineMutation(
        action: ProjectMutationAction,
        _ mutation: () throws -> Void
    ) -> Bool {
        do {
            try mutation()
            workspace.clearProjectMutationFailure()
            workspace.bumpDeadlineDispositionRevision()
            return true
        } catch {
            workspace.reportProjectMutationFailure(action: action, error: error)
            return false
        }
    }

    private func discardProjectDraft() async {
        let service = ManualProjectConfigurationService(
            container: modelContext.container,
            textReader: ProjectTextFileReader()
        )
        do {
            try await service.discardDraft()
            pendingProjectDraftDeletion = nil
            workspace.clearProjectMutationFailure()
            workspace.bumpActionRevision()
            dataController.invalidateAndRefresh()
        } catch {
            workspace.reportProjectMutationFailure(action: .discardDraft, error: error)
        }
    }

    private func deleteProject(_ request: ProjectDeletionRequest) async {
        let repository = MailProjectRepository(modelContext: modelContext)
        do {
            let snapshot = try await repository.delete(
                projectID: request.projectID,
                invalidatingCachesWith: { projectID in
                    await invalidateProjectCaches(projectID: projectID)
                }
            )
            workspace.clearProjectDeletionRequest()
            applySuccessfulProjectDeletionMutation()
            workspace.projectDeletionUndoTarget.registerDeletion(
                on: undoManager,
                snapshot: snapshot,
                restore: { snapshot in
                    try repository.restore(snapshot)
                },
                delete: { projectID in
                    let snapshot = try repository.delete(projectID: projectID)
                    Task { await invalidateProjectCaches(projectID: projectID) }
                    return snapshot
                },
                onMutation: {
                    applySuccessfulProjectDeletionMutation()
                },
                onFailure: { action, error in
                    workspace.reportProjectMutationFailure(action: action, error: error)
                }
            )
        } catch {
            workspace.clearProjectDeletionRequest()
            workspace.reportProjectMutationFailure(action: .delete, error: error)
        }
    }

    private func applySuccessfulProjectDeletionMutation() {
        workspace.clearProjectMutationFailure()
        workspace.returnToTimeView()
        workspace.clearSelection()
        workspace.bumpActionRevision()
        dataController.invalidateAndRefresh()
    }

    private func invalidateProjectCaches(projectID: UUID) async {
        let namespace = MailProjectCacheNamespace(projectID: projectID)
        await projectSummaryService.invalidate(projectKey: namespace.gutterProjectKeyPrefix)
        await deadlineSummaryService.invalidate(
            deadlineKeyPrefix: namespace.guideDeadlineKeyPrefix
        )
    }

    private func setResolved(
        _ rows: [ProjectRow],
        to resolved: Bool,
        using repository: MailProjectRepository
    ) {
        var didMutate = false
        do {
            for row in rows {
                try repository.setResolved(projectID: row.projectID, resolved)
                didMutate = true
            }
            workspace.clearProjectMutationFailure()
        } catch {
            workspace.reportProjectMutationFailure(
                action: resolved ? .resolve : .reopen,
                error: error
            )
        }
        if didMutate {
            workspace.bumpActionRevision()
            dataController.invalidateAndRefresh()
        }
    }

    private var listIgnoreTargetMessageID: UUID? {
        let id: UUID
        if workspace.selectedMode.isLinks,
           let expanded = workspace.workroomExpandedMessageID {
            id = expanded
        } else if let readout = workspace.messageReadout, readout.isPinned {
            id = readout.messageID
        } else {
            return nil
        }
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.id == id })
        descriptor.fetchLimit = 1
        guard let message = try? modelContext.fetch(descriptor).first,
              MailingListIgnoreRuleService.isEligibleListMessage(message) else {
            return nil
        }
        return id
    }
}

private struct ProjectConfigurationWorkspaceHost: View {
    @State private var state: ProjectConfigurationState
    @Binding var canNavigateAway: Bool
    let exitRequestSequence: Int
    let onCancel: () -> Void
    let onSaved: (ProjectConfigurationSaveCompletion) -> Void

    init(
        route: ProjectConfigurationRoute,
        container: ModelContainer,
        tagRecommendationClient: ProjectTagRecommendationClient,
        exitRequestSequence: Int,
        canNavigateAway: Binding<Bool>,
        onCancel: @escaping () -> Void,
        onSaved: @escaping (ProjectConfigurationSaveCompletion) -> Void
    ) {
        _state = State(initialValue: ProjectConfigurationState(
            route: route,
            container: container,
            tagRecommendationClient: tagRecommendationClient
        ))
        _canNavigateAway = canNavigateAway
        self.exitRequestSequence = exitRequestSequence
        self.onCancel = onCancel
        self.onSaved = onSaved
    }

    var body: some View {
        ProjectConfigurationWorkspaceView(
            state: state,
            exitRequestSequence: exitRequestSequence,
            onCancel: onCancel,
            onSaved: onSaved
        )
        .onChange(of: state.canNavigateAway, initial: true) { _, current in
            canNavigateAway = current
        }
    }
}

/// Compact back affordance shown in the mode strip for focused Projects
/// and Deadlines surfaces: a bare `chipActiveBorder` ring
/// with a plain chevron — no surface fill, no status pill beside it —
/// so the affordance itself is the strip's only chrome at rest.
private struct ProjectsBackButton: View {
    let accessibilityLabel: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OhiaColors.chipActiveForeground)
                .frame(width: 38, height: 38)
                .overlay {
                    Circle()
                        .strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
        .opacity(isEnabled ? 1 : 0.45)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}


struct ProjectsFocusedControlAvailability {
    static func showsConfigureProject(
        lensTab: ProjectsLensTab,
        isFocusedProject: Bool,
        hasSelectedProject: Bool
    ) -> Bool {
        lensTab == .projects && (isFocusedProject || hasSelectedProject)
    }
}

struct ProjectsRightControlColumn: View {
    @Bindable var workspace: ProjectsWorkspaceState
    let onLeading: Bool
    @Bindable var newStarNavigator: NewStarNavigator
    @Bindable var manualRefresh: ManualRefreshCoordinator
    let onStarburstClick: () -> Void
    let onBeaconMenuCommand: (BeaconArrivalMenuRequest) -> Void
    let clearMessageFiltersActive: Bool
    let onClearMessageFilters: () -> Void
    let onSetPinned: (ProjectRow, Bool) -> Void
    let onSetResolved: (ProjectRow, Bool) -> Void
    let deadlineDisposition: (String) -> DeadlineAgendaDisposition
    let onSetDeadlinePinned: (DeadlineEntry, Bool) -> Void
    let onSetDeadlineHidden: (DeadlineEntry, Bool) -> Void
    let onConfigureProject: (ProjectRow) -> Void
    let onSendToComposer: @MainActor @Sendable ([UUID]) -> Void
    let ignoreTargetMessageID: UUID?
    let onIgnoreMessage: @MainActor @Sendable (UUID) -> Void
    let messageActions: FrontPageMessageActionHandlers

    @State private var legendPresented = false

    static let columnWidth: CGFloat = 66

    private var selectedMessageMark: ProjectMessageMark? {
        guard workspace.selectedMode.isLinks,
              let messageID = workspace.workroomExpandedMessageID else {
            return nil
        }
        return workspace.focusedRow?.marks.first { $0.messageID == messageID }
    }

    private var selectedMessageInput: ProjectMessageInput? {
        guard let messageID = selectedMessageMark?.messageID else { return nil }
        return workspace.currentSnapshot?.rowsSnapshot.messageLookup[messageID]
    }

    /// The deadline whose email the rail should act on: the opened one, else the
    /// selected one. Deadlines-tab only.
    private var selectedDeadlineEntry: DeadlineEntry? {
        guard workspace.lensTab == .deadlines,
              let id = workspace.openedDeadlineID ?? workspace.selectedDeadlineID else {
            return nil
        }
        return workspace.deadlineTracker().entry(id: id)
    }

    /// The deadline selected at the top level (agenda / calendar) — selected but
    /// not opened into the focused reader. Drives the deadline-level rail.
    private var topLevelSelectedDeadline: DeadlineEntry? {
        guard workspace.lensTab == .deadlines,
              workspace.openedDeadlineID == nil,
              let id = workspace.selectedDeadlineID else {
            return nil
        }
        return workspace.deadlineTracker().entry(id: id)
    }

    /// Projects the deadline's representative email into the `ProjectMessageMark`
    /// the shared message rail consumes, so the Deadlines tab reuses the exact
    /// compose/resolve/confirm/reply/flag controls the workroom uses.
    private static func syntheticMark(for entry: DeadlineEntry) -> ProjectMessageMark {
        var obligations: Set<ProjectOpenObligation.Kind> = []
        if entry.isActionable { obligations.insert(.pendingReply) }
        if entry.requiresConfirmation { obligations.insert(.confirmation) }
        return ProjectMessageMark(
            messageID: entry.representativeMessageID,
            date: entry.deadlineDate,
            isSentByUser: entry.isSentByUser,
            isRead: true,
            isFlagged: entry.isFlagged,
            isReplied: entry.isReplied,
            isConfirmed: entry.isConfirmed,
            isResolvedByUser: entry.isResolvedByUser,
            hasAttachments: false,
            hasDeadline: true,
            deadlineText: entry.surfaceText,
            subject: entry.title,
            obligationKinds: obligations
        )
    }

    /// Deadline-level rail for the top level: resolve, pin, and hide. Email
    /// actions (compose, delete, confirm, reply, flag) stay in the focused
    /// reader, matching the Projects tab's project-only column.
    @ViewBuilder
    private func deadlineActionGroup(_ entry: DeadlineEntry) -> some View {
        let isResolved = entry.isResolvedByUser
        let disposition = deadlineDisposition(entry.id)
        controlDisc(
            glyph: .native("checkmark.circle.fill"),
            label: isResolved ? "Reopen" : "Resolve",
            help: isResolved ? "Reopen deadline" : "Resolve deadline",
            isActive: isResolved,
            isEnabled: true,
            tint: MessageStatusColors.confirmation
        ) {
            messageActions.setResolved([entry.representativeMessageID], !isResolved)
        }

        controlDisc(
            glyph: .native("pin.circle.fill"),
            label: disposition.isPinned ? "Unpin" : "Pin",
            help: disposition.isPinned ? "Unpin deadline" : "Pin deadline",
            isActive: disposition.isPinned,
            isEnabled: true,
            tint: OhiaColors.chipActiveForeground
        ) {
            onSetDeadlinePinned(entry, !disposition.isPinned)
        }

        controlDisc(
            glyph: .native(
                disposition.isHidden
                    ? "eye.circle.fill"
                    : "eye.slash.circle.fill"
            ),
            label: disposition.isHidden ? "Unhide" : "Hide",
            help: disposition.isHidden ? "Unhide deadline" : "Hide deadline",
            isActive: disposition.isHidden,
            isEnabled: true,
            tint: OhiaColors.chipActiveForeground
        ) {
            onSetDeadlineHidden(entry, !disposition.isHidden)
        }
    }

    var body: some View {
        let _ = workspace.deadlineDispositionRevision
        let row = workspace.focusedRow
        let isPinned = row?.isPinned ?? false
        // Derived resolution: the disc lights (and offers Reopen) for rows
        // the cross-lens roll-up resolved, not only explicit ones.
        let isResolved = row?.isResolvedEffective ?? false
        VStack(spacing: 14) {
            StarburstLabelSlot()

            if ProjectsFocusedControlAvailability.showsConfigureProject(
                lensTab: workspace.lensTab,
                isFocusedProject: workspace.selectedMode.isLinks,
                hasSelectedProject: row != nil
            ) {
                configureProjectControl(row: row)
            }

            controlDisc(
                glyph: .native("questionmark.circle.fill"),
                label: "Legend",
                help: "Legend",
                isActive: true,
                isEnabled: !legendPresented
            ) {
                legendPresented.toggle()
            }
            .popover(isPresented: $legendPresented, arrowEdge: onLeading ? .trailing : .leading) {
                ProjectsLegendView(mode: workspace.selectedMode)
                    .frame(width: 440)
            }

            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(width: 26, height: 1)
                .padding(.vertical, 2)

            if workspace.lensTab == .deadlines {
                if workspace.openedDeadlineID != nil, let entry = selectedDeadlineEntry {
                    // Focused reader: the deadline's email carries the full
                    // message actions — compose · resolve · delete · confirm ·
                    // reply · flag.
                    selectedMessageActionGroup(
                        mark: Self.syntheticMark(for: entry),
                        isInComposerQueue: entry.isInComposerQueue
                    )
                } else if let entry = topLevelSelectedDeadline {
                    // Top level (agenda): deadline-level actions only, mirroring
                    // the Projects tab's project-only column.
                    // Email actions live in the focused reader.
                    deadlineActionGroup(entry)
                }
            } else if let selectedMessageMark {
                selectedMessageActionGroup(
                    mark: selectedMessageMark,
                    isInComposerQueue: selectedMessageInput?.isInComposerQueue ?? false
                )
            } else {
                projectActionGroup(row: row, isPinned: isPinned, isResolved: isResolved)
            }
            Spacer(minLength: 0)
        }
        .responsiveActionDiscLabels()
        .padding(.vertical, 14)
        .frame(width: Self.columnWidth)
        .background(OhiaColors.glassPanel)
        .overlay(
            Rectangle()
                .fill(OhiaColors.glassBorder)
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: onLeading ? .trailing : .leading)
        )
        .overlay(alignment: onLeading ? .topLeading : .topTrailing) {
            NewStarFormationNoticeView(
                formingCount: newStarNavigator.formingCount,
                badgeCount: NewMailArrivalLedger.shared.unvisitedCount,
                formationText: starburstCapsuleText,
                isNavigable: NewMailArrivalLedger.shared.unvisitedCount > 0,
                isSearching: manualRefresh.state == .searching,
                failureKind: starburstFailureKind,
                ackFlickerSeq: manualRefresh.ackFlickerSeq,
                emptySignalSeq: manualRefresh.emptySignalSeq,
                action: onStarburstClick,
                menuAction: onBeaconMenuCommand
            )
            .fixedSize()
            .padding(.top, 14)
            .padding(.leading, onLeading ? (Self.columnWidth - 38) / 2 : 0)
            .padding(.trailing, onLeading ? 0 : (Self.columnWidth - 38) / 2)
        }
    }

    /// Message-scoped rail parity with Front Page: compose · resolve · delete,
    /// then confirmation · reply · flag · conditional ignore.
    @ViewBuilder
    private func selectedMessageActionGroup(
        mark: ProjectMessageMark,
        isInComposerQueue: Bool
    ) -> some View {
        let messageID = mark.messageID
        let needsReply = mark.obligationKinds.contains(.pendingReply)
        let replyIsDone = !needsReply && mark.isReplied
        let confirmationMode = ProjectsConfirmationActionMode.resolve(mark: mark)

        LensComposeDisc(
            isActive: !mark.isSentByUser && isInComposerQueue,
            isEnabled: !mark.isSentByUser && !isInComposerQueue,
            restAccessibility: selectedMessageComposerHelp(
                isSentByUser: mark.isSentByUser,
                isInComposerQueue: isInComposerQueue
            ),
            action: { messageActions.sendToComposer([messageID]) }
        )
        controlDisc(
            glyph: .native("checkmark.circle.fill"),
            label: "Resolved",
            help: "Resolved",
            isActive: false,
            isEnabled: true,
            tint: MessageStatusColors.confirmation
        ) {
            messageActions.setResolved([messageID], true)
        }
        controlDisc(
            glyph: .native("xmark.bin.circle.fill"),
            label: "Delete",
            help: "Delete",
            isActive: false,
            isEnabled: true,
            destructive: true
        ) {
            messageActions.delete([messageID])
        }

        Rectangle()
            .fill(OhiaColors.glassBorder)
            .frame(width: 26, height: 1)
            .padding(.vertical, 2)

        controlDisc(
            glyph: confirmationMode.glyph,
            label: confirmationMode.label,
            help: confirmationMode.help,
            isActive: confirmationMode.isActive,
            isEnabled: true,
            tint: MessageStatusColors.confirmation
        ) {
            switch confirmationMode {
            case .confirm:
                messageActions.setConfirmed([messageID], true)
            case .confirmed:
                messageActions.setConfirmed([messageID], false)
            case .markNeeded:
                messageActions.setConfirmationNeeded([messageID], true)
            }
        }
        controlDisc(
            glyph: replyIsDone ? .markReplied : .native("arrowshape.turn.up.left.circle.fill"),
            label: "Replied",
            help: needsReply ? "Mark replied" : "Mark reply needed",
            isActive: replyIsDone,
            isEnabled: true,
            tint: MessageStatusColors.pendingReply
        ) {
            if needsReply {
                messageActions.setReplied([messageID], true)
            } else {
                messageActions.setReplyNeeded([messageID], true)
            }
        }
        controlDisc(
            glyph: mark.isFlagged ? .native("flag.slash.circle.fill") : .native("flag.circle.fill"),
            label: mark.isFlagged ? "Unflag" : "Flag",
            help: mark.isFlagged ? "Unflag" : "Flag",
            isActive: mark.isFlagged,
            isEnabled: true,
            tint: MessageStatusColors.flagged
        ) {
            messageActions.setFlagged([messageID], !mark.isFlagged)
        }
        if ignoreTargetMessageID == messageID {
            controlDisc(
                glyph: .native("eye.slash.circle.fill"),
                label: "Ignore",
                help: "Ignore",
                isActive: false,
                isEnabled: true,
                tint: OhiaColors.ohiaYellow
            ) {
                messageActions.ignore(messageID)
            }
        }
    }

    private func configureProjectControl(row: ProjectRow?) -> some View {
        controlDisc(
            glyph: .native("gear.circle.fill"),
            label: "Configure",
            help: "Configure project",
            isActive: false,
            isEnabled: row != nil
        ) {
            if let row { onConfigureProject(row) }
        }
    }

    @ViewBuilder
    private func projectActionGroup(
        row: ProjectRow?,
        isPinned: Bool,
        isResolved: Bool
    ) -> some View {
        // Project-level actions only. The top-level project list acts on whole
        // projects — resolve, pin, hide, and the lens-wide show-hidden toggle.
        // Message-level actions (compose, ignore) belong to individual emails and
        // live in the per-project workroom, not here.
        controlDisc(
            glyph: .native("checkmark.circle.fill"),
            label: isResolved ? "Reopen" : "Resolved",
            help: isResolved ? "Reopen" : "Resolved",
            isActive: isResolved,
            isEnabled: row != nil,
            tint: MessageStatusColors.confirmation
        ) {
            if let row { onSetResolved(row, !row.isResolvedEffective) }
        }
        controlDisc(
            glyph: .native("pin.circle.fill"),
            label: isPinned ? "Unpin" : "Pin",
            help: isPinned ? "Unpin" : "Pin",
            isActive: isPinned,
            isEnabled: row != nil
        ) {
            if let row { onSetPinned(row, !row.isPinned) }
        }
    }

    private func selectedMessageComposerHelp(
        isSentByUser: Bool,
        isInComposerQueue: Bool
    ) -> String {
        if isSentByUser { return "Sent messages cannot be added to Composer" }
        if isInComposerQueue { return "Already in Composer queue" }
        return "Send to Composer"
    }

    private func controlDisc(
        glyph: ActionDiscGlyph,
        label: String,
        help: String,
        isActive: Bool,
        isEnabled: Bool,
        tint: Color? = nil,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        LensActionDisc(
            glyph: glyph,
            label: label,
            accessibility: help,
            isActive: isActive,
            isEnabled: isEnabled,
            tint: tint,
            destructive: destructive,
            action: action
        )
    }

    private var starburstCapsuleText: String? {
        if manualRefresh.state.isFailure { return manualRefresh.state.capsuleText }
        if let live = newStarNavigator.formationNoticeText { return live }
        return manualRefresh.state.capsuleText
    }

    private var starburstFailureKind: NewStarFormationNoticeView.FailureKind? {
        switch manualRefresh.state {
        case .transientFailure: return .transient
        case .authFailure: return .auth
        case .idle, .searching, .newMail, .empty: return nil
        }
    }
}

/// Horizontal dashed hairline used by legend rows to depict the quiet-gap
/// connector between activity bursts.
private struct LegendDashedLine: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1, dash: [2, 3])
            )
        }
    }
}

/// Teal quad-curve sample matching the canvas's revival arc.
private struct LegendRevivalArc: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height - 2))
            path.addQuadCurve(
                to: CGPoint(x: size.width, y: size.height - 2),
                control: CGPoint(x: size.width / 2, y: 0)
            )
            context.stroke(path, with: .color(OhiaColors.accentTeal.opacity(0.45)), lineWidth: 1.2)
        }
    }
}

/// Projects-workspace legend. Mirrors `ConstellationLegendView`'s
/// chrome — title, sectioned content with caps headers and dividers, a
/// 110pt sample column followed by detail copy — but its content is
/// scoped to the Projects surface. Time mode shows canvas marks + pip
/// column + interactions; Links mode swaps the marks/pips sections
/// for node and edge glyphs that describe what the user is actually
/// looking at on the cross-project network canvas.
private struct ProjectsLegendView: View {
    private static let sampleColumnWidth: CGFloat = 150

    let mode: ProjectsWorkspaceMode

    var body: some View {
        ConstellationLegendScrollContainer {
            VStack(alignment: .leading, spacing: 12) {
                Text("Legend")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
                ConstellationShortcutLegendSection()
                Divider().background(OhiaColors.glassBorder)
                if mode.isLinks {
                    workroomCardsSection
                    Divider().background(OhiaColors.glassBorder)
                    workroomKeyboardSection
                    Divider().background(OhiaColors.glassBorder)
                    workroomPointerSection
                } else {
                    laneSection
                    Divider().background(OhiaColors.glassBorder)
                    marksSection
                    Divider().background(OhiaColors.glassBorder)
                    pipsSection
                    Divider().background(OhiaColors.glassBorder)
                    keyboardSection
                    Divider().background(OhiaColors.glassBorder)
                    pointerSection
                }
            }
        }
    }

    @ViewBuilder
    private var workroomCardsSection: some View {
        sectionTitle("Email cards")
        glyphRow(detail: "newest mail leads · the feed reads back into the project's history") {
            Text("newest → oldest")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        glyphRow(detail: "needs your reply") {
            MessageStatusDot(descriptor: .pendingReply, size: 16)
        }
        glyphRow(detail: "needs confirmation") {
            MessageStatusDot(descriptor: .confirmation, size: 16)
        }
        glyphRow(detail: "evidence-backed deadline · trails the card's status line") {
            Image(systemName: "calendar")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OhiaColors.ohiaRed.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        glyphRow(detail: "arrival ring · the beacon or a citation brought you to this card") {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1)
                .frame(width: 30, height: 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        glyphRow(detail: "linked projects · chips under the header refocus the workroom") {
            Text("Linked")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var workroomKeyboardSection: some View {
        sectionTitle("Keyboard")
        shortcutRow(keys: ["esc"], detail: "close the open reader · then leave the workroom")
    }

    @ViewBuilder
    private var workroomPointerSection: some View {
        sectionTitle("Mouse & Trackpad")
        shortcutRow(keys: ["click card"], detail: "expand into the reader in place · click again to collapse")
        shortcutRow(keys: ["hover card"], detail: "reveal the action cluster · compose, resolve, delete, flag")
        shortcutRow(keys: ["right-click"], detail: "full message menu")
    }

    @ViewBuilder
    private var laneSection: some View {
        sectionTitle("Row lane")
        glyphRow(detail: "activity burst · bar spans mail that happened") {
            RoundedRectangle(cornerRadius: 4)
                .fill(OhiaColors.textSecondary.opacity(0.26))
                .frame(width: 46, height: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        glyphRow(detail: "burst awaiting your reply") {
            RoundedRectangle(cornerRadius: 4)
                .fill(MessageStatusColors.pendingReply.opacity(0.38))
                .frame(width: 46, height: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        glyphRow(detail: "burst awaiting their confirmation") {
            RoundedRectangle(cornerRadius: 4)
                .fill(MessageStatusColors.confirmation.opacity(0.34))
                .frame(width: 46, height: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        glyphRow(detail: "quiet gap between bursts") {
            LegendDashedLine(color: OhiaColors.textTertiary.opacity(0.5))
                .frame(width: 46, height: 9)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        glyphRow(detail: "revival after a quiet gap") {
            LegendRevivalArc()
                .frame(width: 46, height: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        glyphRow(detail: "milestone · evidence-backed deadline") {
            Image(systemName: "diamond")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OhiaColors.ohiaRed.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        glyphRow(detail: "overdue milestone with an open obligation") {
            Image(systemName: "diamond.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OhiaColors.ohiaRed.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        glyphRow(detail: "today") {
            Rectangle()
                .fill(OhiaColors.chipActiveForeground.opacity(0.4))
                .frame(width: 1.5, height: 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var marksSection: some View {
        sectionTitle("Message dots")
        glyphRow(detail: "received mail rides above the lane · unread fills") {
            MessageReadStateDot(descriptor: .receivedMail, size: 16)
        }
        glyphRow(detail: "sent mail rides below the lane") {
            MessageReadStateDot(descriptor: .sentMail, size: 16)
        }
        glyphRow(detail: "needs your reply") {
            MessageStatusDot(descriptor: .pendingReply, size: 16)
        }
        glyphRow(detail: "needs confirmation") {
            MessageStatusDot(descriptor: .confirmation, size: 16)
        }
        glyphRow(detail: "replied") {
            MessageStatusDot(descriptor: .replied, size: 16)
        }
        glyphRow(detail: "confirmed") {
            MessageStatusDot(descriptor: .confirmed, size: 16)
        }
        glyphRow(detail: "several messages close together · count badge") {
            HStack(spacing: 3) {
                MessageReadStateDot(descriptor: .receivedMail, size: 16)
                Text("3")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(OhiaColors.textSecondary)
            }
        }
        glyphRow(detail: "flagged · badge on the dot") {
            MessageStatusFlaggedGlyph(size: 14)
        }
        glyphRow(detail: "mentioned in passing · dashed ring") {
            Circle()
                .strokeBorder(
                    OhiaColors.textTertiary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                )
                .frame(width: 16, height: 16)
        }
    }

    @ViewBuilder
    private var pipsSection: some View {
        sectionTitle("Row pip column")
        glyphRow(detail: "pending replies") {
            pipGlyph(ObligationKindColor.pendingReply)
        }
        glyphRow(detail: "confirmations") {
            pipGlyph(ObligationKindColor.confirmation)
        }
        glyphRow(detail: "deadlines") {
            pipGlyph(ObligationKindColor.deadline)
        }
        glyphRow(detail: "separates pip groups") {
            Rectangle()
                .fill(OhiaColors.glassBorder.opacity(0.6))
                .frame(width: 14, height: 0.6)
        }
        glyphRow(detail: "overflow above 6") {
            Text("+n")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(ObligationKindColor.pendingReply)
        }
    }

    @ViewBuilder
    private var keyboardSection: some View {
        sectionTitle("Keyboard")
        shortcutRow(keys: ["esc"], detail: "dismiss the readout · release the selection · reset zoom, in that order")
        shortcutRow(keys: ["↑↓"], detail: "step the selection through the visible rows")
        shortcutRow(keys: ["⌘", "a"], detail: "select every visible row")
        shortcutRow(keys: ["⌘", "d"], detail: "deselect all")
        shortcutRow(keys: ["⌘", "r"], detail: "resolve the selection · majority-flips on mixed state")
    }

    @ViewBuilder
    private var pointerSection: some View {
        sectionTitle("Mouse & Trackpad")
        shortcutRow(keys: ["click row"], detail: "select row · click again to release")
        shortcutRow(keys: ["⌘", "click"], detail: "toggle row in the multi-selection")
        shortcutRow(keys: ["⇧", "click"], detail: "extend selection from the last-clicked anchor")
        shortcutRow(keys: ["double-click row"], detail: "open this project's workroom")
        shortcutRow(keys: ["right-click"], detail: "open this project's actions")
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(OhiaTypography.telemetrySectionCaps)
            .tracking(0.6)
            .foregroundStyle(OhiaColors.textTertiary)
    }

    private func glyphRow<Sample: View>(detail: String, @ViewBuilder sample: () -> Sample) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack { sample() }
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: Self.sampleColumnWidth, alignment: .leading)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textSecondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }

    private func shortcutRow(keys: [String], detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    keyCap(key)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: Self.sampleColumnWidth, alignment: .leading)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textSecondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(OhiaTypography.legendLine)
            .foregroundStyle(OhiaColors.textPrimary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(OhiaColors.surface(0.10))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
            }
    }

    private func pipGlyph(_ color: Color) -> some View {
        Capsule().fill(color).frame(width: 14, height: 3)
    }
}

func projectStatusText(_ status: ProjectRowStatus) -> String {
    switch status {
    case .active:
        return "active"
    case .revived:
        return "revived"
    case .quiet:
        return "inactive"
    case .resolved:
        return "resolved"
    case .longTail:
        return "grouped projects"
    }
}

func projectLifecycleText(_ row: ProjectRow) -> String {
    if row.status == .resolved || row.status == .longTail {
        return projectStatusText(row.status)
    }
    switch row.lifecycleAssessment.state {
    case .inactive:
        return "inactive"
    case .awaitingUser:
        return "awaiting you"
    case .awaitingOther:
        return "awaiting other"
    case .current:
        return "current"
    case .uncertain:
        return projectStatusText(row.status)
    }
}
