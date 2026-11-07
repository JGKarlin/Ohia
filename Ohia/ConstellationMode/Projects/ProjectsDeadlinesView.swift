import SwiftUI
import SwiftData
import EventKit
import UniformTypeIdentifiers
import OhiaCore
import OhiaML

// Projects is a SwiftUI/Canvas workspace. The normal Metal scene should not mount for `.projects`.

/// Chooses the one visible deadline surface that owns a departure animation.
/// A Composer send launched for the deadline represented by the center guide
/// belongs to that guide; other departures stay with their agenda row.
enum DeadlineDeparturePlacement: Equatable {
    case agenda
    case guide

    static func resolve(
        action: MessageStatusGestureAction,
        isGuideEntry: Bool
    ) -> DeadlineDeparturePlacement {
        action == .sentToComposer && isGuideEntry ? .guide : .agenda
    }
}

/// The Deadlines tracker — the Projects lens's second surface. It mirrors a
/// dedicated "Ohia" calendar in Calendar.app: the agenda on the left
/// is a days-until-due countdown of every tracked deadline; the month calendar
/// on the right is that Calendar.app calendar. Each deadline carries a reminder
/// (a native calendar alarm) and clicks through to a focused workroom of its
/// actual thread emails.
struct ProjectsDeadlinesView: View {
    @Bindable var workspace: ProjectsWorkspaceState
    let snapshot: ProjectsSnapshot
    let modelContext: ModelContext
    let dataController: ProjectsDataController
    let messageActions: FrontPageMessageActionHandlers
    let composerDispatch: ComposerDispatchCoordinator
    /// Generates the selected deadline's guide copy (Qwen-first, cached),
    /// surfaced on the Activity strip while it runs.
    let deadlineSummaryService: DeadlineSummaryService
    let deadlineSummaryUserIdentity: SummarizationUserIdentity?
    let onPresentMessageMenu: (UUID, NSPoint, NSView) -> Void

    @AppStorage(DeadlineReminderSettings.syncEnabledKey)
    private var syncEnabled: Bool = DeadlineReminderSettings.defaultSyncEnabled
    @AppStorage(DeadlineReminderSettings.meetingSyncEnabledKey)
    private var meetingSyncEnabled: Bool = DeadlineReminderSettings.defaultMeetingSyncEnabled
    @AppStorage(DeadlineReminderSettings.defaultLeadTimeKey)
    private var defaultLeadTimeRaw: String = DeadlineReminderSettings.defaultLeadTime.rawValue
    @AppStorage(DeadlineReminderSettings.reminderHourKey)
    private var reminderHour: Int = DeadlineReminderSettings.defaultReminderHour

    @State private var calendarSync: DeadlineCalendarSync?
    @State private var leadTimes: [String: DeadlineReminderLeadTime] = [:]
    @State private var dateOverrides: [String: DeadlineDateOverride] = [:]
    @State private var calendarSuppressedEntryIDs: Set<String> = []
    @State private var calendarStatus: DeadlineCalendarSyncStatus = .syncing
    @State private var isReconcilingCalendar = false
    @State private var showsCalendarDeletionConfirmation = false
    @State private var showsCalendarDeletionError = false
    @State private var calendarDeletionError = ""
    @State private var deadlineCalendarActivationRequested = false
    @State private var calendarActivationInProgress = false
    @State private var detectedCalendarConflict: ManagedCalendarConflict?
    @State private var showsCalendarConflictConfirmation = false
    @State private var showsCalendarActivationError = false
    @State private var calendarActivationError = ""
    @State private var calendarActivationErrorTitle = "Calendar sync could not be enabled"

    // MARK: Guide pane state
    //
    // The middle pane is the guide: the selected (or most imminent) deadline's
    // summary grown into a tickable step guide with per-document readouts. The
    // right pane is the deadline-scoped file column. `guideInputs` keeps the
    // input each summary was built from; `readoutStates` is keyed
    // "entryID|resourceKey"; `workFilesRevision` bumps when a deadline's file
    // set changes so the guide's `.task` re-runs against fresh fingerprints.
    private let workFileStore = DeadlineWorkFileStore()
    @State private var guideInputs: [String: DeadlineSummaryInput] = [:]
    @State private var readoutStates: [String: DeadlineGuideReadoutState] = [:]
    @State private var completedSteps: [String: Set<String>] = [:]
    @State private var guideLastReads: [String: DeadlineGuideLastRead] = [:]
    @State private var guideWorkFiles: [String: [DeadlineWorkFile]] = [:]
    @State private var workFilesRevision = 0
    /// One guide load per deadline at a time. A file-set change or snapshot
    /// reset cancels the entry's task so its stale result can never land on the
    /// cleared state.
    @State private var summaryLoadTasks: [String: Task<Void, Never>] = [:]
    @State private var agendaDispositions: [String: DeadlineAgendaDisposition] = [:]
    @State private var agendaDispositionsLoaded = false
    @State private var expandedAgendaSections: Set<DeadlineAgendaSectionID> = [.active]

    private static let preferredAgendaPaneWidth: CGFloat = 430
    private static let minimumAgendaPaneWidth: CGFloat = 300
    private static let preferredGuidePaneWidth: CGFloat = 500
    private static let minimumGuidePaneWidth: CGFloat = 340
    private static let preferredFilesPaneWidth: CGFloat = 520
    private static let minimumFilesPaneWidth: CGFloat = 360

    private var guideStateStore: DeadlineGuideStateStore {
        DeadlineGuideStateStore(modelContext: modelContext)
    }

    /// Calendar health is shared with meeting sync, but deadline controls must
    /// always honor the deadline-specific General Settings selection.
    private var deadlineCalendarStatus: DeadlineCalendarSyncStatus {
        DeadlineCalendarStatusScope.resolve(
            deadlineSyncEnabled: syncEnabled,
            calendarStatus: calendarStatus
        )
    }

    // MARK: Deadline guide summary state

    @State private var summaryStates: [String: DeadlineSummaryState] = [:]

    private var defaultLeadTime: DeadlineReminderLeadTime {
        DeadlineReminderLeadTime(rawValue: defaultLeadTimeRaw) ?? .none
    }

    private var observationFingerprint: DeadlineViewObservationFingerprint {
        DeadlineViewObservationFingerprint(
            snapshotSignature: snapshot.signature,
            openedDeadlineID: workspace.openedDeadlineID,
            syncEnabled: syncEnabled,
            meetingSyncEnabled: meetingSyncEnabled,
            defaultLeadTimeRaw: defaultLeadTimeRaw,
            reminderHour: reminderHour,
            deadlineDispositionRevision: workspace.deadlineDispositionRevision
        )
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let tracker = deadlineTracker(now: now)
            content(tracker: tracker, now: now)
        }
        .background(OhiaColors.spaceBackground)
        .task {
            let tracker = deadlineTracker(now: .now)
            refreshAgendaDispositions(tracker: tracker)
            reconcileAgendaSelection(tracker: tracker)
            await activateSync()
        }
        .onChange(of: observationFingerprint) { old, new in
            let snapshotChanged = old.snapshotSignature != new.snapshotSignature
            let dispositionChanged = old.deadlineDispositionRevision
                != new.deadlineDispositionRevision
            let settingsChanged = old.syncEnabled != new.syncEnabled
                || old.meetingSyncEnabled != new.meetingSyncEnabled
                || old.defaultLeadTimeRaw != new.defaultLeadTimeRaw
                || old.reminderHour != new.reminderHour

            if snapshotChanged {
                resetGuideState()
            }
            if snapshotChanged || dispositionChanged {
                let tracker = deadlineTracker(now: .now)
                refreshAgendaDispositions(tracker: tracker)
                reconcileAgendaSelection(tracker: tracker)
            }
            if old.openedDeadlineID != new.openedDeadlineID,
               new.openedDeadlineID != nil {
                resetGuideState()
            }

            if settingsChanged {
                if new.syncEnabled || new.meetingSyncEnabled {
                    Task { await activateSync() }
                } else {
                    calendarStatus = .disabled
                    refreshCalendarPreferences()
                }
            } else if snapshotChanged {
                Task { await synchronizeCalendar(importFirst: true) }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: DeadlineCalendarSync.calendarStoreDidChangeNotification
            )
        ) { _ in
            guard isReconcilingCalendar == false else { return }
            Task { await handleCalendarStoreChange() }
        }
        .alert(
            "Delete Ohia calendar?",
            isPresented: $showsCalendarDeletionConfirmation
        ) {
            Button("Delete Calendar", role: .destructive) {
                disableDeadlineCalendarSyncAndDeleteCalendar()
            }
            Button("Keep Syncing", role: .cancel) {}
        } message: {
            Text("This deletes the dedicated calendar and all of its events from Calendar.app. Email evidence and Calendar-authored overrides remain in Ohia.")
        }
        .alert("Calendar could not be deleted", isPresented: $showsCalendarDeletionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(calendarDeletionError)
        }
        .confirmationDialog(
            calendarConflictTitle,
            isPresented: $showsCalendarConflictConfirmation
        ) {
            Button("Merge") {
                startCalendarConflictResolution(.merge)
            }
            Button("Replace", role: .destructive) {
                startCalendarConflictResolution(.replace)
            }
            Button("Cancel", role: .cancel) {
                cancelCalendarConflictResolution()
            }
        } message: {
            Text(calendarConflictMessage)
        }
        .alert(calendarActivationErrorTitle, isPresented: $showsCalendarActivationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(calendarActivationError)
        }
    }

    @ViewBuilder
    private func content(tracker: DeadlineTrackerSnapshot, now: Date) -> some View {
        if let openedID = workspace.openedDeadlineID, let entry = tracker.entry(id: openedID) {
            DeadlineFocusedView(
                entry: entry,
                workspace: workspace,
                snapshot: snapshot,
                modelContext: modelContext,
                messageActions: messageActions,
                composerDispatch: composerDispatch,
                leadTime: leadTimes[entry.id] ?? .none,
                calendarStatus: deadlineCalendarStatus,
                hasCalendarDateOverride: dateOverrides[entry.id] != nil,
                isCalendarSyncSuppressed: calendarSuppressedEntryIDs.contains(entry.id),
                onSetLeadTime: { setLeadTime($0, for: entry) },
                onRestoreEmailDate: { restoreEmailDate(forEntryID: entry.id) },
                onRestoreCalendarEvent: { restoreCalendarEvent(for: entry) },
                onRequestCalendarSync: { requestCalendarSync() },
                onResolve: { setResolved(entry, resolved: !entry.isResolvedByUser) },
                onPresentMessageMenu: onPresentMessageMenu
            )
        } else if tracker.isEmpty {
            emptyState
        } else if agendaDispositionsLoaded == false {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let projection = agendaProjection(tracker: tracker, now: now)
            let guideEntry = guideEntry(projection: projection)
            ZStack(alignment: .topLeading) {
                GeometryReader { geometry in
                    let filesPaneWidth = min(
                        Self.preferredFilesPaneWidth,
                        max(
                            Self.minimumFilesPaneWidth,
                            geometry.size.width
                                - Self.preferredAgendaPaneWidth
                                - Self.preferredGuidePaneWidth
                        )
                    )
                    let agendaPaneWidth = min(
                        Self.preferredAgendaPaneWidth,
                        max(
                            Self.minimumAgendaPaneWidth,
                            geometry.size.width
                                - filesPaneWidth
                                - Self.preferredGuidePaneWidth
                        )
                    )

                    HStack(spacing: 0) {
                        DeadlineAgendaColumn(
                            tracker: tracker,
                            now: now,
                            pinnedIDs: pinnedDeadlineIDs,
                            hiddenIDs: hiddenDeadlineIDs,
                            expandedSections: expandedAgendaSections,
                            selectedID: guideEntry?.id,
                            hoveredID: workspace.hoveredDeadlineID,
                            leadTimes: leadTimes,
                            deadlineCalendarSyncEnabled: syncEnabled,
                            deadlineCalendarActivationPending: deadlineCalendarActivationRequested,
                            calendarStatus: deadlineCalendarStatus,
                            calendarDateOverrideIDs: Set(dateOverrides.keys),
                            calendarSuppressedEntryIDs: calendarSuppressedEntryIDs,
                            statusGestureCoordinator: workspace.statusGestureCoordinator,
                            onSelect: { workspace.focusDeadline($0.id) },
                            onOpen: { workspace.openDeadline($0.id) },
                            onHover: { workspace.hoveredDeadlineID = $0 },
                            onSetLeadTime: { setLeadTime($1, for: $0) },
                            onRestoreEmailDate: { restoreEmailDate(forEntryID: $0.id) },
                            onRestoreCalendarEvent: { restoreCalendarEvent(for: $0) },
                            onToggleCalendarSync: { toggleDeadlineCalendarSync() },
                            onToggleSection: { toggleAgendaSection($0, tracker: tracker) }
                        )
                        .frame(width: agendaPaneWidth)
                        Divider().overlay(OhiaColors.glassBorder)
                        if let entry = guideEntry {
                            let scopedReadouts = readoutStates(forEntryID: entry.id)
                            let rawDepartureGesture = workspace.statusGestureCoordinator.gesture(
                                for: entry.representativeMessageID
                            )
                            let guideDepartureGesture = rawDepartureGesture.flatMap { gesture in
                                DeadlineDeparturePlacement.resolve(
                                    action: gesture.action,
                                    isGuideEntry: true
                                ) == .guide ? gesture : nil
                            }
                            let fileContent = DeadlineFilePaneContent.build(
                                entry: entry,
                                input: guideInputs[entry.id],
                                workFiles: guideWorkFiles[entry.id] ?? [],
                                readoutStates: scopedReadouts
                            )
                            ZStack {
                                DeadlineGuidePane(
                                    workspace: workspace,
                                    entry: entry,
                                    now: now,
                                    snapshot: snapshot,
                                    summaryState: summaryStates[entry.id] ?? .loading,
                                    readoutStates: scopedReadouts,
                                    completedStepIDs: completedSteps[entry.id] ?? [],
                                    messageActions: messageActions,
                                    onToggleStep: { stepID, completed in
                                        toggleStep(stepID, completed: completed, entry: entry)
                                    },
                                    onReply: { messageActions.sendToComposer([entry.representativeMessageID]) },
                                    onConfirm: { messageActions.setConfirmed([entry.representativeMessageID], true) },
                                    onPresentMessageMenu: onPresentMessageMenu
                                )
                                .opacity(guideDepartureGesture == nil ? 1 : 0)
                                .allowsHitTesting(guideDepartureGesture == nil)

                                if let guideDepartureGesture {
                                    FrontPageReaderDepartureCard(gesture: guideDepartureGesture)
                                }
                            }
                            .frame(minWidth: Self.minimumGuidePaneWidth, maxWidth: .infinity)
                            .layoutPriority(1)
                            .background(OhiaColors.spaceBackground)
                            .animation(.easeOut(duration: 0.28), value: guideDepartureGesture != nil)
                            .modifier(ComposerDepartureSource(messageIDs: [entry.representativeMessageID]))
                            .task(
                                id: GuideSummaryTaskKey(
                                    scopeID: entry.id,
                                    summaryRequestKey: entry.id,
                                    evidenceIdentity: .deadline(snapshot.signature),
                                    filesRevision: workFilesRevision
                                )
                            ) {
                                await loadGuide(for: entry)
                            }
                            ProjectFilesPane(
                                scope: .deadline,
                                records: fileContent.records,
                                generatedSummaries: fileContent.generatedSummaries,
                                loadingSummaryIDs: fileContent.loadingSummaryIDs,
                                onAddFiles: { handleDropFiles($0, entry: entry) },
                                onRemoveManualFile: { handleRemoveWorkFile($0, entry: entry) }
                            )
                            .id(entry.id)
                            .frame(width: filesPaneWidth)
                        }
                    }
                }
            }
        }
    }

    /// The deadline whose guide fills the right pane: the user's selection when
    /// it is still in view, otherwise the most imminent unresolved deadline
    /// (most-recently-overdue first, then the soonest upcoming), falling back
    /// to the latest resolved one so the pane is never empty while the tab has
    /// content.
    private func guideEntry(projection: DeadlineAgendaProjection) -> DeadlineEntry? {
        let visibleEntries = projection.visibleEntries(in: expandedAgendaSections)
        if let selectedID = workspace.selectedDeadlineID,
           let selected = visibleEntries.first(where: { $0.id == selectedID }) {
            return selected
        }
        return visibleEntries.first
    }

    private var pinnedDeadlineIDs: Set<String> {
        Set(agendaDispositions.compactMap { key, value in
            value.isPinned ? key : nil
        })
    }

    private var hiddenDeadlineIDs: Set<String> {
        Set(agendaDispositions.compactMap { key, value in
            value.isHidden ? key : nil
        })
    }

    private func agendaProjection(
        tracker: DeadlineTrackerSnapshot,
        now: Date
    ) -> DeadlineAgendaProjection {
        DeadlineAgendaProjection(
            tracker: tracker,
            now: now,
            pinnedIDs: pinnedDeadlineIDs,
            hiddenIDs: hiddenDeadlineIDs
        )
    }

    private func refreshAgendaDispositions(tracker: DeadlineTrackerSnapshot) {
        agendaDispositions = guideStateStore.dispositions(
            entryIDs: Set(tracker.allEntries.map(\.id))
        )
        agendaDispositionsLoaded = true
    }

    private func reconcileAgendaSelection(tracker: DeadlineTrackerSnapshot) {
        let projection = agendaProjection(tracker: tracker, now: .now)
        let visibleEntries = projection.visibleEntries(in: expandedAgendaSections)
        if let selectedID = workspace.selectedDeadlineID,
           visibleEntries.contains(where: { $0.id == selectedID }) {
            return
        }
        workspace.focusDeadline(visibleEntries.first?.id)
    }

    private func toggleAgendaSection(
        _ sectionID: DeadlineAgendaSectionID,
        tracker: DeadlineTrackerSnapshot
    ) {
        if expandedAgendaSections.contains(sectionID) {
            expandedAgendaSections.remove(sectionID)
        } else {
            expandedAgendaSections.insert(sectionID)
        }
        reconcileAgendaSelection(tracker: tracker)
    }

    /// The readout states scoped to one deadline, re-keyed by resource key for
    /// the pane.
    private func readoutStates(forEntryID entryID: String) -> [String: DeadlineGuideReadoutState] {
        let prefix = "\(entryID)|"
        var scoped: [String: DeadlineGuideReadoutState] = [:]
        for (key, state) in readoutStates where key.hasPrefix(prefix) {
            scoped[String(key.dropFirst(prefix.count))] = state
        }
        return scoped
    }

    private var emptyState: some View {
        OhiaEmptyPaneStateView(
            systemName: "calendar",
            title: "No dated deadlines",
            detail: "Any emails that state a deadline will appear here"
        )
    }

    // MARK: - Sync

    private func activateSync(requesting: Bool = false) async {
        let sync = calendarSync ?? DeadlineCalendarSync(modelContext: modelContext)
        calendarSync = sync
        guard syncEnabled || meetingSyncEnabled else {
            calendarStatus = .disabled
            refreshCalendarPreferences()
            return
        }

        calendarStatus = .syncing
        if requesting || DeadlineCalendarSync.authorizationStatus == .notDetermined {
            _ = await sync.ensureAccess()
        }
        guard DeadlineCalendarSync.hasWriteAccess else {
            calendarStatus = .needsPermission
            refreshCalendarPreferences()
            return
        }
        await synchronizeCalendar(importFirst: true)
    }

    private func requestCalendarSync() {
        guard syncEnabled == false,
              deadlineCalendarActivationRequested == false else {
            return
        }
        deadlineCalendarActivationRequested = true
        calendarStatus = .syncing
        Task { await activateDeadlineCalendarSync() }
    }

    private func activateDeadlineCalendarSync() async {
        guard deadlineCalendarActivationRequested,
              calendarActivationInProgress == false else {
            return
        }
        calendarActivationInProgress = true
        defer { calendarActivationInProgress = false }

        let sync = calendarSync ?? DeadlineCalendarSync(modelContext: modelContext)
        calendarSync = sync
        do {
            let outcome = try await CalendarSyncActivation.run(
                isEnabled: deadlineCalendarActivationRequested,
                hasWriteAccess: DeadlineCalendarSync.hasWriteAccess,
                isStillEnabled: {
                    deadlineCalendarActivationRequested
                },
                requestAccess: {
                    await sync.ensureAccess()
                },
                prepareCalendar: {
                    try sync.prepareManagedCalendar()
                }
            )
            switch outcome {
            case .calendarReady:
                completeDeadlineCalendarActivation()
            case .calendarResolutionRequired(let conflict):
                detectedCalendarConflict = conflict
                showsCalendarConflictConfirmation = true
            case .permissionDenied:
                failDeadlineCalendarActivation(
                    message: DeadlineCalendarSyncError.permissionRequired.localizedDescription
                )
            case .disabled:
                deadlineCalendarActivationRequested = false
                calendarStatus = .disabled
            }
        } catch {
            failDeadlineCalendarActivation(message: error.localizedDescription)
        }
    }

    private func resolveCalendarConflict(
        _ resolution: ManagedCalendarConflictResolution
    ) async {
        guard deadlineCalendarActivationRequested,
              detectedCalendarConflict != nil,
              calendarActivationInProgress == false else {
            return
        }
        calendarActivationInProgress = true
        defer { calendarActivationInProgress = false }

        let sync = calendarSync ?? DeadlineCalendarSync(modelContext: modelContext)
        calendarSync = sync
        do {
            try await sync.resolveManagedCalendarConflict(resolution)
            completeDeadlineCalendarActivation()
            clearCalendarConflict()
        } catch DeadlineCalendarSyncError.postCommitCleanupFailed(let message) {
            completeDeadlineCalendarActivation()
            clearCalendarConflict()
            calendarActivationErrorTitle = "Calendar sync needs attention"
            calendarActivationError = "The Ohia calendar was updated and syncing remains on, but Ohia could not refresh its saved event links. Ohia will recover those links during the next sync. \(message)"
            showsCalendarActivationError = true
        } catch {
            failDeadlineCalendarActivation(message: error.localizedDescription)
            clearCalendarConflict()
        }
    }

    private func startCalendarConflictResolution(
        _ resolution: ManagedCalendarConflictResolution
    ) {
        CalendarConflictResolutionTask.launch {
            await resolveCalendarConflict(resolution)
        }
    }

    private func completeDeadlineCalendarActivation() {
        deadlineCalendarActivationRequested = false
        syncEnabled = true
    }

    private func failDeadlineCalendarActivation(message: String) {
        deadlineCalendarActivationRequested = false
        calendarStatus = .disabled
        calendarActivationErrorTitle = "Calendar sync could not be enabled"
        calendarActivationError = message
        showsCalendarActivationError = true
    }

    private func cancelCalendarConflictResolution() {
        deadlineCalendarActivationRequested = false
        calendarStatus = .disabled
        clearCalendarConflict()
    }

    private func clearCalendarConflict() {
        detectedCalendarConflict = nil
        showsCalendarConflictConfirmation = false
    }

    private var calendarConflictTitle: String {
        let count = detectedCalendarConflict?.calendarCount ?? 0
        return count == 1
            ? "An Ohia calendar already exists"
            : "\(count) Ohia calendars already exist"
    }

    private var calendarConflictMessage: String {
        let count = detectedCalendarConflict?.calendarCount ?? 0
        if count == 1 {
            return "Merge keeps its events and makes it Ohia’s synchronized calendar. Replace deletes it and creates a fresh calendar for Ohia to resynchronize."
        }
        return "Merge combines all events into one synchronized Ohia calendar and removes the redundant calendars. Replace deletes all \(count) calendars and creates a fresh calendar for Ohia to resynchronize."
    }

    private func toggleDeadlineCalendarSync() {
        guard syncEnabled else {
            requestCalendarSync()
            return
        }

        switch CalendarSyncSelectionPolicy.disableAction(
            .deadlines,
            deadlines: syncEnabled,
            meetings: meetingSyncEnabled
        ) {
        case .disableSelection:
            syncEnabled = false
        case .confirmCalendarDeletion:
            showsCalendarDeletionConfirmation = true
        }
    }

    private func disableDeadlineCalendarSyncAndDeleteCalendar() {
        let sync = calendarSync ?? DeadlineCalendarSync(modelContext: modelContext)
        calendarSync = sync
        do {
            try CalendarSyncDisableCoordinator.perform(
                selection: .deadlines,
                deadlines: syncEnabled,
                meetings: meetingSyncEnabled,
                setSelectionEnabled: { selection, enabled in
                    switch selection {
                    case .deadlines: syncEnabled = enabled
                    case .meetings: meetingSyncEnabled = enabled
                    }
                },
                deleteManagedCalendar: {
                    try DeadlineCalendarSync.deleteManagedCalendar()
                },
                clearLinks: {
                    try sync.clearEventLinksAfterManagedCalendarDeletion()
                },
                acknowledgeDeletion: {
                    DeadlineCalendarSync.acknowledgeManagedCalendarDeletion()
                }
            )
        } catch {
            calendarDeletionError = error.localizedDescription
            showsCalendarDeletionError = true
        }
    }

    private func synchronizeCalendar(importFirst: Bool) async {
        guard (syncEnabled || meetingSyncEnabled),
              DeadlineCalendarSync.hasWriteAccess,
              isReconcilingCalendar == false else {
            return
        }
        let sync = calendarSync ?? DeadlineCalendarSync(modelContext: modelContext)
        calendarSync = sync
        isReconcilingCalendar = true
        calendarStatus = .syncing
        defer { isReconcilingCalendar = false }

        do {
            if DeadlineCalendarSync.managedCalendarWasDeleted() {
                try handleManagedCalendarDeletion(using: sync)
                return
            }

            let baseEntries = baseDeadlineTracker(now: .now).allEntries
            if syncEnabled,
               importFirst,
               DeadlineCalendarSync.hasManagedCalendarRegistration {
                _ = try sync.importCalendarChanges(
                    baseEntries: baseEntries,
                    reminderHour: reminderHour
                )
            }
            if syncEnabled {
                try refreshCalendarPreferencesThrowing(using: sync)
                try sync.reconcile(
                    entries: deadlineTracker(now: .now).allEntries,
                    defaultLeadTime: defaultLeadTime,
                    reminderHour: reminderHour
                )
            }
            if meetingSyncEnabled {
                let meetingEntries = try await MeetingCalendarEntryLoader.load(
                    modelContext: modelContext
                )
                guard meetingSyncEnabled, Task.isCancelled == false else {
                    calendarStatus = syncEnabled || meetingSyncEnabled ? .synced : .disabled
                    return
                }
                try sync.reconcileMeetings(
                    entries: meetingEntries,
                    defaultLeadTime: defaultLeadTime,
                    reminderHour: reminderHour
                )
            }
            try refreshCalendarPreferencesThrowing(using: sync)
            calendarStatus = syncEnabled || meetingSyncEnabled ? .synced : .disabled
        } catch DeadlineCalendarSyncError.calendarDeleted {
            do {
                try handleManagedCalendarDeletion(using: sync)
            } catch {
                calendarStatus = .failed(error.localizedDescription)
            }
        } catch {
            calendarStatus = .failed(error.localizedDescription)
        }
    }

    private func handleCalendarStoreChange() async {
        switch DeadlineCalendarLifecyclePolicy.storeChangeAction(
            syncEnabled: syncEnabled || meetingSyncEnabled,
            hasWriteAccess: DeadlineCalendarSync.hasWriteAccess,
            isReconciling: isReconcilingCalendar
        ) {
        case .disabled:
            calendarStatus = .disabled
            return
        case .needsPermission:
            calendarStatus = .needsPermission
            return
        case .ignoreWhileReconciling:
            return
        case .importChanges:
            break
        }
        let sync = calendarSync ?? DeadlineCalendarSync(modelContext: modelContext)
        calendarSync = sync

        if DeadlineCalendarSync.managedCalendarWasDeleted() {
            do {
                try handleManagedCalendarDeletion(using: sync)
            } catch {
                calendarStatus = .failed(error.localizedDescription)
            }
            return
        }

        guard DeadlineCalendarSync.hasManagedCalendarRegistration else { return }
        isReconcilingCalendar = true
        defer { isReconcilingCalendar = false }
        do {
            if syncEnabled {
                _ = try sync.importCalendarChanges(
                    baseEntries: baseDeadlineTracker(now: .now).allEntries,
                    reminderHour: reminderHour
                )
            }
            if meetingSyncEnabled {
                let meetingEntries = try await MeetingCalendarEntryLoader.load(
                    modelContext: modelContext
                )
                guard meetingSyncEnabled, Task.isCancelled == false else {
                    calendarStatus = syncEnabled || meetingSyncEnabled ? .synced : .disabled
                    return
                }
                try sync.reconcileMeetings(
                    entries: meetingEntries,
                    defaultLeadTime: defaultLeadTime,
                    reminderHour: reminderHour
                )
            }
            try refreshCalendarPreferencesThrowing(using: sync)
            calendarStatus = syncEnabled || meetingSyncEnabled ? .synced : .disabled
        } catch DeadlineCalendarSyncError.calendarDeleted {
            do {
                try handleManagedCalendarDeletion(using: sync)
            } catch {
                calendarStatus = .failed(error.localizedDescription)
            }
        } catch {
            calendarStatus = .failed(error.localizedDescription)
        }
    }

    private func handleManagedCalendarDeletion(
        using sync: DeadlineCalendarSync
    ) throws {
        try sync.clearEventLinksAfterManagedCalendarDeletion()
        DeadlineCalendarSync.acknowledgeManagedCalendarDeletion()
        syncEnabled = false
        meetingSyncEnabled = false
        calendarStatus = .disabled
        try refreshCalendarPreferencesThrowing(using: sync)
    }

    private func refreshCalendarPreferences() {
        guard let sync = calendarSync else { return }
        do {
            try refreshCalendarPreferencesThrowing(using: sync)
        } catch {
            calendarStatus = .failed(error.localizedDescription)
        }
    }

    private func refreshCalendarPreferencesThrowing(
        using sync: DeadlineCalendarSync
    ) throws {
        let ids = baseDeadlineTracker(now: .now).allEntries.map(\.id)
        let preferences = try sync.preferences(forEntryIDs: ids)
        leadTimes = preferences.mapValues(\.leadTime)
        dateOverrides = preferences.compactMapValues(\.dateOverride)
        calendarSuppressedEntryIDs = Set(
            preferences.compactMap { $0.value.isCalendarSyncSuppressed ? $0.key : nil }
        )
    }

    private func setLeadTime(_ leadTime: DeadlineReminderLeadTime, for entry: DeadlineEntry) {
        let sync = calendarSync ?? DeadlineCalendarSync(modelContext: modelContext)
        calendarSync = sync
        calendarStatus = .syncing
        do {
            try sync.setLeadTime(
                leadTime,
                for: entry,
                enabled: syncEnabled,
                reminderHour: reminderHour
            )
            try refreshCalendarPreferencesThrowing(using: sync)
            calendarStatus = syncEnabled || meetingSyncEnabled ? .synced : .disabled
        } catch {
            calendarStatus = .failed(error.localizedDescription)
        }
    }

    private func restoreEmailDate(forEntryID entryID: String) {
        guard let baseEntry = baseDeadlineTracker(now: .now).entry(id: entryID) else { return }
        let sync = calendarSync ?? DeadlineCalendarSync(modelContext: modelContext)
        calendarSync = sync
        calendarStatus = .syncing
        do {
            try sync.restoreEmailDate(
                for: baseEntry,
                enabled: syncEnabled,
                reminderHour: reminderHour
            )
            try refreshCalendarPreferencesThrowing(using: sync)
            calendarStatus = syncEnabled || meetingSyncEnabled ? .synced : .disabled
        } catch {
            calendarStatus = .failed(error.localizedDescription)
        }
    }

    private func restoreCalendarEvent(for entry: DeadlineEntry) {
        let sync = calendarSync ?? DeadlineCalendarSync(modelContext: modelContext)
        calendarSync = sync
        calendarStatus = .syncing
        do {
            try sync.restoreCalendarEvent(for: entry, reminderHour: reminderHour)
            try refreshCalendarPreferencesThrowing(using: sync)
            calendarStatus = .synced
        } catch {
            calendarStatus = .failed(error.localizedDescription)
        }
    }

    private func baseDeadlineTracker(now: Date) -> DeadlineTrackerSnapshot {
        snapshot.deadlineTracker(now: now)
    }

    private func deadlineTracker(now: Date) -> DeadlineTrackerSnapshot {
        snapshot.deadlineTracker(now: now, dateOverrides: dateOverrides)
    }

    private func setResolved(_ entry: DeadlineEntry, resolved: Bool) {
        let messageID = entry.representativeMessageID
        // Resolving (not reopening) plays the green Collapse on the deadline's
        // card — the agenda row or the focused reader — via the shared coordinator,
        // matching the Front Page / workroom exit. The message stays in scope, so
        // the gesture is settled on its own timer and the rebuild is held until the
        // motion plays.
        if resolved {
            let now = Date()
            workspace.statusGestureCoordinator.begin(.resolve, for: [messageID], now: now)
            workspace.statusGestureCoordinator.scheduleDepartingSettle(
                for: [messageID], startedAt: now, hold: ProjectsWorkspaceState.departingSettleHold
            )
        }
        messageActions.setResolved([messageID], resolved)
        workspace.bumpActionRevision()
        let hold = resolved ? workspace.statusGestureCoordinator.remainingDepartingHold() : 0
        dataController.invalidateAndRefresh(holdingFor: hold)
    }

    /// Loads one deadline's summary, or joins the load already in flight for
    /// it. A previous `.unavailable` retries (the model may have finished
    /// loading since); a `.loading` left behind by a cancelled run reloads.
    private func loadSummaryIfNeeded(for id: String) async {
        if let inFlight = summaryLoadTasks[id] {
            await inFlight.value
            return
        }
        let task = Task { await performSummaryLoad(for: id) }
        summaryLoadTasks[id] = task
        await task.value
        if summaryLoadTasks[id] == task {
            summaryLoadTasks[id] = nil
        }
    }

    /// The single writer of `summaryStates[id]` / `guideInputs[id]`. Every
    /// post-await write is guarded on the task's own cancellation — a
    /// cancelled run resets to `nil` (so the next run reloads) rather than
    /// landing a stale result on state a file-set change just cleared.
    private func performSummaryLoad(for id: String) async {
        summaryStates[id] = .loading
        let tracker = deadlineTracker(now: .now)
        guard let entry = tracker.entry(id: id) else {
            summaryStates[id] = .unavailable("This deadline is no longer in view.")
            return
        }
        // Working files join the input so the guide is regenerated from the
        // complete deadline-scoped file set.
        let input = await DeadlineSummaryInputBuilder.build(
            entry: entry,
            modelContext: modelContext,
            userIdentity: deadlineSummaryUserIdentity,
            workFileStore: workFileStore
        )
        guard !Task.isCancelled else {
            summaryStates[id] = nil
            return
        }
        guard let input else {
            summaryStates[id] = .unavailable("The emails for this deadline are no longer in scope.")
            return
        }
        guideInputs[id] = input
        guard input.hasEvidence else {
            summaryStates[id] = .unavailable("No summary is available for this deadline yet.")
            return
        }
        let result = await deadlineSummaryService.summary(for: id, input: input)
        guard !Task.isCancelled else {
            summaryStates[id] = nil
            return
        }
        if let result {
            summaryStates[id] = .loaded(result)
        } else {
            summaryStates[id] = .unavailable(
                "A summary for this deadline could not be generated. The generative model may still be loading."
            )
        }
    }

    private func resetGuideState() {
        summaryLoadTasks.values.forEach { $0.cancel() }
        summaryLoadTasks.removeAll()
        summaryStates.removeAll()
        guideInputs.removeAll()
        readoutStates.removeAll()
        guideWorkFiles.removeAll()
    }

    // MARK: - Guide pane loading

    /// Loads everything the guide pane shows for one deadline: persisted step
    /// ticks and re-read stamp, the working-file list, the summary, then the per-document readouts — each
    /// document's close reading generated sequentially so the card fills in
    /// as they arrive.
    private func loadGuide(for entry: DeadlineEntry) async {
        let entryID = entry.id
        // The lens's right control column (Resolve disc) acts on the selected
        // deadline. When the pane defaults to the most imminent entry with no
        // explicit selection yet, promote it to the selection so the rail
        // governs exactly what the pane shows — and the agenda halo agrees.
        if workspace.selectedDeadlineID == nil {
            workspace.focusDeadline(entryID)
        }
        completedSteps[entryID] = guideStateStore.completedStepIDs(entryID: entryID)
        if let last = guideStateStore.lastRead(entryID: entryID) {
            guideLastReads[entryID] = DeadlineGuideLastRead(at: last.at, reason: last.reason)
        }
        guideWorkFiles[entryID] = workFileStore.files(entryID: entryID)

        await loadSummaryIfNeeded(for: entryID)
        guard !Task.isCancelled else { return }
        guard case .loaded(let result) = summaryStates[entryID],
              let input = guideInputs[entryID] else {
            return
        }

        // Thread attachments first (their readouts sit under the document
        // steps), then the owner's working files (theirs sit under the FILES
        // rows) — each document deep-read sequentially so the card fills in
        // as they arrive.
        let resources: [(file: DeadlineSummaryAttachment, origin: DeadlineResourceOrigin, key: String)] =
            input.attachments.map {
                ($0, .threadAttachment, GuideResourceKeys.document(filename: $0.filename))
            } + input.workingFiles.map {
                ($0, .workingFile, GuideResourceKeys.workingFile(filename: $0.filename))
            }

        for resource in resources {
            guard let text = resource.file.extractedText,
                  text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                continue
            }
            let stateKey = "\(entryID)|\(resource.key)"
            guard readoutStates[stateKey] == nil else { continue }
            readoutStates[stateKey] = .loading
            let readoutInput = DeadlineResourceReadoutInput(
                accountID: input.accountID,
                deadlineTitle: input.title,
                deadlineLabel: input.deadlineLabel,
                deadlineDateText: input.deadlineDateText,
                surfaceText: input.surfaceText,
                resourceFilename: resource.file.filename,
                resourceOrigin: resource.origin,
                resourceText: text,
                briefingParagraph: result.paragraph,
                correspondents: input.correspondents,
                userIdentity: deadlineSummaryUserIdentity
            )
            let readout = await deadlineSummaryService.readout(
                for: entryID,
                resourceKey: resource.key,
                input: readoutInput
            )
            // Write nothing when cancelled: every restart path (selection
            // change, snapshot reset, file-set change) already cleared this
            // entry's keys, and a stale mutation here could delete the entry
            // the replacement task just wrote.
            guard !Task.isCancelled else { return }
            readoutStates[stateKey] = readout.map(DeadlineGuideReadoutState.loaded) ?? .unavailable
        }
    }

    private func toggleStep(_ stepID: String, completed: Bool, entry: DeadlineEntry) {
        guideStateStore.setStep(stepID, completed: completed, entryID: entry.id)
        completedSteps[entry.id] = guideStateStore.completedStepIDs(entryID: entry.id)
    }

    private func handleDropFiles(
        _ urls: [URL],
        entry: DeadlineEntry
    ) -> ProjectFileImportResult {
        let added = workFileStore.add(fileURLs: urls, entryID: entry.id)
        if added.isEmpty == false {
            let reason = added.count == 1
                ? "\(added[0].filename) was added"
                : "\(added.count) files were added"
            noteFileSetChange(entry: entry, reason: reason)
        }
        return ProjectFileImportResult(
            requestedCount: urls.count,
            addedCount: added.count
        )
    }

    private func handleRemoveWorkFile(
        _ workFileID: String,
        entry: DeadlineEntry
    ) -> Bool {
        guard let file = workFileStore.files(entryID: entry.id).first(where: { $0.id == workFileID }),
              workFileStore.remove(file) else {
            return false
        }
        noteFileSetChange(entry: entry, reason: "\(file.filename) was removed")
        return true
    }

    /// A change to the deadline's file set queues a full guide re-read: the
    /// persisted stamp records why, the in-flight load is cancelled so its
    /// stale result cannot land on the cleared state, and the synchronous
    /// revision bump restarts the guide's `.task` immediately. No service
    /// invalidation is needed — the changed file set changes the input
    /// fingerprint, so the old cache entries simply never match again (and
    /// racing an invalidate against the fresh generation would cancel it).
    private func noteFileSetChange(entry: DeadlineEntry, reason: String) {
        let entryID = entry.id
        let now = Date.now
        guideStateStore.setLastRead(at: now, reason: reason, entryID: entryID)
        guideLastReads[entryID] = DeadlineGuideLastRead(at: now, reason: reason)
        guideWorkFiles[entryID] = workFileStore.files(entryID: entryID)
        summaryLoadTasks[entryID]?.cancel()
        summaryLoadTasks[entryID] = nil
        summaryStates[entryID] = nil
        guideInputs[entryID] = nil
        readoutStates = readoutStates.filter { !$0.key.hasPrefix("\(entryID)|") }
        workFilesRevision += 1
    }

}

struct DeadlineFilePaneContent: Equatable {
    let records: [ProjectFileRecord]
    let generatedSummaries: [String: String]
    let loadingSummaryIDs: Set<String>

    static func build(
        entry: DeadlineEntry,
        input: DeadlineSummaryInput?,
        workFiles: [DeadlineWorkFile],
        readoutStates: [String: DeadlineGuideReadoutState]
    ) -> DeadlineFilePaneContent {
        var records: [ProjectFileRecord] = []
        var generatedSummaries: [String: String] = [:]
        var loadingSummaryIDs: Set<String> = []

        func captureReadout(_ state: DeadlineGuideReadoutState?, recordID: String) {
            switch state {
            case .loaded(let readout):
                generatedSummaries[recordID] = readout.text
            case .loading:
                loadingSummaryIDs.insert(recordID)
            case .unavailable, nil:
                break
            }
        }

        for attachment in input?.attachments ?? [] {
            let fileURL = attachment.filePath.map { URL(fileURLWithPath: $0) }
            let kind = TimelineAttachmentKind.classify(
                mimeType: attachment.mimeType,
                fileName: attachment.filename
            )
            let stableID = ProjectFileCatalog.stableUUID(
                for: "\(entry.id)|attachment|\(attachment.filename)|\(attachment.filePath ?? "")"
            )
            let recordID = "deadline-attachment-\(stableID.uuidString.lowercased())"
            var metadataLines = [kind.label, attachment.mimeType]
            if let documentKind = attachment.documentKind,
               documentKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                metadataLines.append(documentKind)
            }
            metadataLines.append("From this deadline's correspondence")
            records.append(ProjectFileRecord(
                id: recordID,
                origin: .message(
                    attachmentID: stableID,
                    messageID: entry.representativeMessageID
                ),
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                kind: kind,
                sizeBytes: fileSize(for: fileURL),
                fileURL: fileURL,
                eventDate: entry.lastActivityAt,
                eventLabel: "Attached",
                senderLabel: "Deadline correspondence",
                senderKey: ProjectFileCatalog.senderKey("Deadline correspondence"),
                sourceSubject: entry.title,
                metadataLines: metadataLines,
                storedSummary: nil,
                summaryInput: nil
            ))
            captureReadout(
                readoutStates[GuideResourceKeys.document(filename: attachment.filename)],
                recordID: recordID
            )
        }

        for file in workFiles where file.entryID == entry.id {
            let mimeType = mimeType(for: file.url)
            let kind = TimelineAttachmentKind.classify(
                mimeType: mimeType,
                fileName: file.filename
            )
            let recordID = "manual-\(file.id)"
            records.append(ProjectFileRecord(
                id: recordID,
                origin: .manual(workFileID: file.id),
                filename: file.filename,
                mimeType: mimeType,
                kind: kind,
                sizeBytes: file.sizeBytes,
                fileURL: file.url,
                eventDate: file.addedAt,
                eventLabel: "Added",
                senderLabel: "Added by you",
                senderKey: ProjectFileCatalog.senderKey("Added by you"),
                sourceSubject: nil,
                metadataLines: [kind.label, mimeType, "Stored for this deadline by Ohia"],
                storedSummary: nil,
                summaryInput: nil
            ))
            captureReadout(
                readoutStates[GuideResourceKeys.workingFile(filename: file.filename)],
                recordID: recordID
            )
        }

        return DeadlineFilePaneContent(
            records: records,
            generatedSummaries: generatedSummaries,
            loadingSummaryIDs: loadingSummaryIDs
        )
    }

    private static func mimeType(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        return values?.contentType?.preferredMIMEType
            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }

    private static func fileSize(for url: URL?) -> Int {
        guard let url else { return 0 }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

private struct DeadlineViewObservationFingerprint: Equatable {
    let snapshotSignature: ProjectsSnapshotSignature
    let openedDeadlineID: String?
    let syncEnabled: Bool
    let meetingSyncEnabled: Bool
    let defaultLeadTimeRaw: String
    let reminderHour: Int
    let deadlineDispositionRevision: Int
}

// MARK: - Shared formatting

enum DeadlineFormatting {
    static func dayLabel(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func dayTimeLabel(_ date: Date) -> String { dayTimeFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .init(identifier: "en_US_POSIX"); f.dateFormat = "EEE, MMM d"; return f
    }()
    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .init(identifier: "en_US_POSIX"); f.dateFormat = "EEE, MMM d · HH:mm"; return f
    }()

    static func dayDelta(from now: Date, to date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }
}
