import Combine
import SwiftUI
import SwiftData
import OhiaCore
import OhiaML
import os

enum CalendarSyncActivationOutcome: Sendable, Equatable {
    case disabled
    case permissionDenied
    case calendarReady
    case calendarResolutionRequired(ManagedCalendarConflict)
}

@MainActor
enum CalendarSyncActivation {
    static func run(
        isEnabled: Bool,
        hasWriteAccess: Bool,
        isStillEnabled: () -> Bool = { true },
        requestAccess: () async -> Bool,
        prepareCalendar: () throws -> ManagedCalendarPreparationOutcome
    ) async rethrows -> CalendarSyncActivationOutcome {
        guard isEnabled else { return .disabled }
        if hasWriteAccess == false {
            guard await requestAccess() else {
                return .permissionDenied
            }
        }
        guard isStillEnabled() else { return .disabled }
        switch try prepareCalendar() {
        case .ready:
            return .calendarReady
        case .needsResolution(let conflict):
            return .calendarResolutionRequired(conflict)
        }
    }
}

enum CalendarSyncSelection: Sendable, Hashable {
    case deadlines
    case meetings
}

enum CalendarSyncDisableAction: Sendable, Equatable {
    case disableSelection
    case confirmCalendarDeletion
}

enum CalendarSyncSelectionPolicy {
    static func remindersEnabled(deadlines: Bool, meetings: Bool) -> Bool {
        deadlines || meetings
    }

    static func disableAction(
        _ selection: CalendarSyncSelection,
        deadlines: Bool,
        meetings: Bool
    ) -> CalendarSyncDisableAction {
        switch selection {
        case .deadlines:
            return meetings ? .disableSelection : .confirmCalendarDeletion
        case .meetings:
            return deadlines ? .disableSelection : .confirmCalendarDeletion
        }
    }

    static func shouldValidateAfterStoreChange(
        syncEnabled: Bool,
        isBusy: Bool,
        hasPendingRequest: Bool
    ) -> Bool {
        syncEnabled && isBusy == false && hasPendingRequest == false
    }
}

@MainActor
enum CalendarConflictResolutionTask {
    /// Merge and Replace are explicit user-confirmed operations. Their lifetime
    /// must not be owned by a SwiftUI `.task` modifier, which the framework may
    /// cancel when the confirmation presentation is dismissed or rebuilt.
    @discardableResult
    static func launch(
        operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            await operation()
        }
    }
}

enum CalendarSyncDisableCoordinator {
    /// Re-evaluates the live selection state when a previously presented
    /// deletion confirmation is accepted. Another sync source may have become
    /// active while the alert was open, in which case the shared calendar must
    /// be preserved.
    @discardableResult
    static func perform(
        selection: CalendarSyncSelection,
        deadlines: Bool,
        meetings: Bool,
        setSelectionEnabled: (CalendarSyncSelection, Bool) -> Void,
        deleteManagedCalendar: () throws -> Void,
        clearLinks: () throws -> Void,
        acknowledgeDeletion: () -> Void
    ) throws -> CalendarSyncDisableAction {
        let action = CalendarSyncSelectionPolicy.disableAction(
            selection,
            deadlines: deadlines,
            meetings: meetings
        )

        switch action {
        case .disableSelection:
            setSelectionEnabled(selection, false)
        case .confirmCalendarDeletion:
            setSelectionEnabled(selection, false)
            do {
                try deleteManagedCalendar()
                try ManagedCalendarDeletionCoordinator.clearLinksAndAcknowledge(
                    clearLinks: clearLinks,
                    acknowledge: acknowledgeDeletion
                )
            } catch {
                setSelectionEnabled(selection, true)
                throw error
            }
        }

        return action
    }
}

struct GeneralSettingsView: View {
    private enum CalendarActivationRequest: Hashable {
        case enable(CalendarSyncSelection)
        case validateEnabled
    }

    @Environment(\.modelContext) private var modelContext
    @AppStorage(DeadlineReminderSettings.syncEnabledKey)
    private var deadlineSyncEnabled: Bool = DeadlineReminderSettings.defaultSyncEnabled
    @AppStorage(DeadlineReminderSettings.meetingSyncEnabledKey)
    private var meetingSyncEnabled: Bool = DeadlineReminderSettings.defaultMeetingSyncEnabled
    @AppStorage(DeadlineReminderSettings.defaultLeadTimeKey)
    private var deadlineDefaultLeadTimeRaw: String = DeadlineReminderSettings.defaultLeadTime.rawValue
    @AppStorage(DeadlineReminderSettings.reminderHourKey)
    private var deadlineReminderHour: Int = DeadlineReminderSettings.defaultReminderHour
    @State private var showsCalendarDeletionConfirmation = false
    @State private var showsCalendarDeletionError = false
    @State private var calendarDeletionError = ""
    @State private var pendingCalendarDisableSelection: CalendarSyncSelection?
    @State private var calendarActivationRequest: CalendarActivationRequest?
    @State private var pendingCalendarConflictActivation: CalendarActivationRequest?
    @State private var detectedCalendarConflict: ManagedCalendarConflict?
    @State private var showsCalendarConflictConfirmation = false
    @State private var showsCalendarActivationError = false
    @State private var calendarActivationError = ""
    @State private var calendarActivationErrorTitle = "Calendar sync could not be enabled"
    @State private var calendarOperationInProgress = false
    @State private var calendarStoreChangePending = false

    private static let calendarLogger = Logger(
        subsystem: "org.jgkarlin.Ohia",
        category: "DeadlineCalendarSync"
    )

    private var deadlineSyncBinding: Binding<Bool> {
        calendarSyncBinding(for: .deadlines)
    }

    private var meetingSyncBinding: Binding<Bool> {
        calendarSyncBinding(for: .meetings)
    }

    private var calendarRemindersEnabled: Bool {
        CalendarSyncSelectionPolicy.remindersEnabled(
            deadlines: deadlineSyncEnabled,
            meetings: meetingSyncEnabled
        )
    }

    private var deadlineLeadTimeBinding: Binding<DeadlineReminderLeadTime> {
        Binding(
            get: { DeadlineReminderLeadTime(rawValue: deadlineDefaultLeadTimeRaw) ?? .none },
            set: { deadlineDefaultLeadTimeRaw = $0.rawValue }
        )
    }

    private static func hourLabel(_ hour: Int) -> String {
        let period = hour < 12 ? "AM" : "PM"
        let display = hour % 12 == 0 ? 12 : hour % 12
        return "\(display):00 \(period)"
    }

    @AppStorage("appearance") private var appearanceRaw: String = AppearancePreference.dark.rawValue
    @AppStorage(ReadingTextSize.storageKey)
    private var readingTextSizeRaw: String = ReadingTextSize.defaultPreference.rawValue
    @AppStorage(StartupViewPreference.storageKey)
    private var startupViewRaw: String = StartupViewPreference.defaultPreference.rawValue
    @AppStorage(
        ComposerQueueIntakePreference.storageKey,
        store: OhiaSharedDefaults.store
    )
    private var composerQueueIntakeRaw: String = ComposerQueueIntakePreference.defaultPreference.rawValue
    @AppStorage(ComposerOpenOnQueuePreference.storageKey)
    private var openComposerOnQueue: Bool = ComposerOpenOnQueuePreference.defaultValue
    @AppStorage(ComposerDraftSignalReviewPreference.storageKey)
    private var reviewDraftEditsBeforeSending: Bool = ComposerDraftSignalReviewPreference.defaultValue
    @AppStorage(ComposerMessageFormat.newMessageStorageKey)
    private var newMessageFormatRaw: String = ComposerMessageFormat.defaultNewMessageFormat.rawValue
    @AppStorage(NewStarAlertSoundPreference.storageKey)
    private var newMailAlertSoundFilename: String = NewStarAlertSoundPreference.defaultFilename
    @AppStorage(SentMailSoundPreference.storageKey)
    private var sentMailSoundFilename: String = SentMailSoundPreference.defaultFilename
    @AppStorage(ComposerSoundPreference.storageKey)
    private var composerSoundFilename: String = ComposerSoundPreference.defaultFilename
    @AppStorage(OhiaTooltipPreference.storageKey) private var tooltipsEnabled: Bool = true
    @AppStorage(LensLegendVisibilityPreference.storageKey)
    private var lensLegendsVisible: Bool = LensLegendVisibilityPreference.defaultValue
    @AppStorage(DeletionConfirmationPreference.moveToTrashConfirmationKey)
    private var confirmMoveToTrashDeletion: Bool = DeletionConfirmationPreference.defaultShowsConfirmation
    @AppStorage(DeletionConfirmationPreference.permanentDeleteConfirmationKey)
    private var confirmPermanentDeletion: Bool = DeletionConfirmationPreference.defaultShowsConfirmation
    @State private var soundPreviewPlayer = NewStarAlertSoundPlayer()

    @AppStorage(FilterStateScopePreference.storageKey)
    private var filterStateScopeRaw = FilterStateScopePreference.defaultPreference.rawValue

    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(
            get: { AppearancePreference(rawValue: appearanceRaw) ?? .dark },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    private var readingTextSizeBinding: Binding<ReadingTextSize> {
        Binding(
            get: { ReadingTextSize.resolved(rawValue: readingTextSizeRaw) },
            set: { readingTextSizeRaw = $0.rawValue }
        )
    }

    private var startupViewBinding: Binding<StartupViewPreference> {
        Binding(
            get: { StartupViewPreference(rawValue: startupViewRaw) ?? .defaultPreference },
            set: { startupViewRaw = $0.rawValue }
        )
    }

    private var composerQueueIntakeBinding: Binding<ComposerQueueIntakePreference> {
        Binding(
            get: { ComposerQueueIntakePreference(rawValue: composerQueueIntakeRaw) ?? .defaultPreference },
            set: { composerQueueIntakeRaw = $0.rawValue }
        )
    }

    private var newMessageFormatBinding: Binding<ComposerMessageFormat> {
        Binding(
            get: {
                ComposerMessageFormat(rawValue: newMessageFormatRaw)
                    ?? .defaultNewMessageFormat
            },
            set: { newMessageFormatRaw = $0.rawValue }
        )
    }

    private var filterStateScopeBinding: Binding<FilterStateScopePreference> {
        Binding(
            get: {
                FilterStateScopePreference(rawValue: filterStateScopeRaw)
                    ?? .defaultPreference
            },
            set: { filterStateScopeRaw = $0.rawValue }
        )
    }

    private var sentMailSoundBinding: Binding<String> {
        Binding(
            get: { SentMailSoundPreference.resolvedFilename(from: sentMailSoundFilename) },
            set: { sentMailSoundFilename = $0 }
        )
    }

    // The pickers show what will actually play, so a stored sound that is not
    // bundled (builds from source ship without sound files) reads as No Sound.
    private var newMailAlertSoundBinding: Binding<String> {
        Binding(
            get: { NewStarAlertSoundPreference.resolvedFilename(from: newMailAlertSoundFilename) },
            set: { newMailAlertSoundFilename = $0 }
        )
    }

    private var composerSoundBinding: Binding<String> {
        Binding(
            get: { ComposerSoundPreference.resolvedFilename(from: composerSoundFilename) },
            set: { composerSoundFilename = $0 }
        )
    }

    var body: some View {
        // Hand-built cards rather than `Form(.grouped)`: the system section box
        // is a ~3% white overlay, so over the night-sky backdrop it renders as
        // sky-plus-haze and can never be black. See OhiaSettingsCard.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                appearanceCard
                filterStateScopeCard
                composerCard
                notificationSoundsCard
                calendarCard
                RemoteImageAllowlistSection()
                deletionCard
                helpCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .task {
            guard calendarRemindersEnabled else { return }
            await activateCalendarSync(.validateEnabled)
            schedulePendingCalendarStoreValidationIfNeeded()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: DeadlineCalendarSync.calendarStoreDidChangeNotification
            )
        ) { _ in
            guard calendarRemindersEnabled else {
                calendarStoreChangePending = false
                return
            }
            calendarStoreChangePending = true
            schedulePendingCalendarStoreValidationIfNeeded()
        }
        .task(id: calendarActivationRequest) {
            guard let request = calendarActivationRequest else { return }
            await activateCalendarSync(request)
            if calendarActivationRequest == request {
                calendarActivationRequest = nil
            }
            schedulePendingCalendarStoreValidationIfNeeded()
        }
        .alert(
            "Delete Ohia calendar?",
            isPresented: $showsCalendarDeletionConfirmation
        ) {
            Button("Delete Calendar", role: .destructive) {
                disableCalendarSyncAndDeleteCalendar()
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

    // MARK: - Cards
    //
    // One property per card so each stays small enough for the type-checker;
    // `Toggle` and `Picker` carry explicit styles because outside a Form macOS
    // renders a toggle as a checkbox and inlines a picker's label.

    private var appearanceCard: some View {
        OhiaSettingsCard("Appearance") {
            SettingsRow("Theme") {
                OhiaSegmentedPicker(
                    selection: appearanceBinding,
                    options: AppearancePreference.allCases,
                    title: { $0.label }
                )
            }
            SettingsRowDivider()
            SettingsRow("Startup view") {
                OhiaSegmentedPicker(
                    selection: startupViewBinding,
                    options: StartupViewPreference.allCases,
                    title: { $0.label }
                )
            }
            SettingsRowDivider()
            SettingsBlock {
                // Plain Text (no font override) so the label inherits the same
                // default weight/size/color as the row labels above it.
                Text("Text Size")
                    .foregroundStyle(OhiaColors.textPrimary)

                ReadingTextSizeSlider(selection: readingTextSizeBinding)

                Text("Changes email bodies, summaries, translations, and other reader text without resizing the Constellation interface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var composerCard: some View {
        OhiaSettingsCard("Composer") {
            SettingsRow("New email format") {
                OhiaSegmentedPicker(
                    selection: newMessageFormatBinding,
                    options: ComposerMessageFormat.allCases,
                    title: { $0.label }
                )
            }
            SettingsRowDivider()
            SettingsCaption("New messages start in this format. Replies follow the format of the message being answered, with a per-draft override in the editor.")
            SettingsRowDivider()
            SettingsRow("Needs-reply intake") {
                OhiaSegmentedPicker(
                    selection: composerQueueIntakeBinding,
                    options: ComposerQueueIntakePreference.allCases,
                    title: { $0.label }
                )
            }
            SettingsRowDivider()
            SettingsCaption(composerQueueIntakeBinding.wrappedValue.detail)
            SettingsRowDivider()
            SettingsRow("Open Composer when a message is queued") {
                Toggle("", isOn: $openComposerOnQueue)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRowDivider()
            SettingsCaption("On: sending a message to the Composer brings it to the front, focused on that message. Hold ⌥ while sending to queue quietly without switching windows. Off inverts both — plain sends queue quietly and ⌥ opens.")
            SettingsRowDivider()
            SettingsRow("Review draft edits before sending") {
                Toggle("", isOn: $reviewDraftEditsBeforeSending)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRowDivider()
            SettingsCaption("Off: Send appears immediately, and inferred draft signals are accepted automatically. On: edited model drafts show Confirm so you can review their draft signals before Send.")
        }
    }

    private var notificationSoundsCard: some View {
        OhiaSettingsCard("Notification Sounds") {
            SettingsRow("New mail alert sound") {
                Picker("", selection: newMailAlertSoundBinding) {
                    ForEach(NewStarAlertSoundPreference.options()) { option in
                        Text(option.displayName).tag(option.filename)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: newMailAlertSoundFilename) { _, filename in
                    soundPreviewPlayer.play(filename: filename)
                }
            }
            SettingsRowDivider()
            SettingsRow("Composer queue sound") {
                Picker("", selection: composerSoundBinding) {
                    ForEach(ComposerSoundPreference.options()) { option in
                        Text(option.displayName).tag(option.filename)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: composerSoundFilename) { _, filename in
                    soundPreviewPlayer.play(filename: filename)
                }
            }
            SettingsRowDivider()
            SettingsRow("Sent mail sound") {
                Picker("", selection: sentMailSoundBinding) {
                    ForEach(SentMailSoundPreference.options()) { option in
                        Text(option.displayName).tag(option.filename)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: sentMailSoundFilename) { _, filename in
                    soundPreviewPlayer.play(filename: filename)
                }
            }
        }
    }

    private var calendarCard: some View {
        OhiaSettingsCard("Calendar") {
            SettingsRow("Add deadlines to Calendar.app") {
                Toggle("", isOn: deadlineSyncBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(calendarOperationInProgress)
            }
            SettingsRowDivider()
            SettingsRow("Add meetings to Calendar.app") {
                Toggle("", isOn: meetingSyncBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(calendarOperationInProgress)
            }
            SettingsRowDivider()
            SettingsCaption("Both options use the dedicated “Ohia” calendar and sync in both directions. Calendar edits and recognized invitations take priority over details parsed from email text.")
            SettingsRowDivider()
            SettingsRow("Default reminder") {
                Picker("", selection: deadlineLeadTimeBinding) {
                    ForEach(DeadlineReminderLeadTime.choices(hasTimeOfDay: false)) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(!calendarRemindersEnabled)
            SettingsRowDivider()
            SettingsRow("Remind at") {
                Picker("", selection: $deadlineReminderHour) {
                    ForEach(Array(6...21), id: \.self) { hour in
                        Text(Self.hourLabel(hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(!calendarRemindersEnabled)
        }
    }

    private var helpCard: some View {
        OhiaSettingsCard("Help") {
            SettingsRow("Show hover tooltips") {
                Toggle("", isOn: $tooltipsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRowDivider()
            SettingsCaption("When on, hovering over filter chips and toolbar buttons displays a brief explanation of what the control does. Turn off for a cleaner UI once you know your way around.")
            SettingsGroupDivider()
            SettingsRow("Show Legend") {
                Toggle("", isOn: $lensLegendsVisible)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRowDivider()
            SettingsCaption("Turn off to hide the Legend button.")
        }
    }

    private var deletionCard: some View {
        OhiaSettingsCard("Deletion") {
            SettingsRow("Confirm before moving email to Trash") {
                Toggle("", isOn: $confirmMoveToTrashDeletion)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRowDivider()
            SettingsRow("Confirm before permanently deleting email") {
                Toggle("", isOn: $confirmPermanentDeletion)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var filterStateScopeCard: some View {
        OhiaSettingsCard("Constellation") {
            SettingsRow("Filter states") {
                OhiaSegmentedPicker(
                    selection: filterStateScopeBinding,
                    options: FilterStateScopePreference.allCases,
                    title: { $0.title }
                )
            }
            SettingsRowDivider()
            SettingsCaption(filterStateScopeBinding.wrappedValue.detail)
        }
    }

    private func calendarSyncBinding(
        for selection: CalendarSyncSelection
    ) -> Binding<Bool> {
        Binding(
            get: {
                switch selection {
                case .deadlines: deadlineSyncEnabled
                case .meetings: meetingSyncEnabled
                }
            },
            set: { enabled in
                if enabled {
                    calendarActivationRequest = .enable(selection)
                    return
                }
                switch CalendarSyncSelectionPolicy.disableAction(
                    selection,
                    deadlines: deadlineSyncEnabled,
                    meetings: meetingSyncEnabled
                ) {
                case .disableSelection:
                    setCalendarSyncEnabled(false, for: selection)
                case .confirmCalendarDeletion:
                    pendingCalendarDisableSelection = selection
                    showsCalendarDeletionConfirmation = true
                }
            }
        )
    }

    private func setCalendarSyncEnabled(
        _ enabled: Bool,
        for selection: CalendarSyncSelection
    ) {
        switch selection {
        case .deadlines:
            deadlineSyncEnabled = enabled
        case .meetings:
            meetingSyncEnabled = enabled
        }
    }

    private func disableCalendarSyncAndDeleteCalendar() {
        guard let selection = pendingCalendarDisableSelection else { return }
        let sync = DeadlineCalendarSync(modelContext: modelContext)
        do {
            // Recheck both live preferences because this confirmation may have
            // remained open while another calendar source became enabled.
            try CalendarSyncDisableCoordinator.perform(
                selection: selection,
                deadlines: deadlineSyncEnabled,
                meetings: meetingSyncEnabled,
                setSelectionEnabled: { selection, enabled in
                    setCalendarSyncEnabled(enabled, for: selection)
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
            pendingCalendarDisableSelection = nil
        } catch {
            calendarDeletionError = error.localizedDescription
            showsCalendarDeletionError = true
        }
    }

    private func activateCalendarSync(_ request: CalendarActivationRequest) async {
        guard calendarOperationInProgress == false,
              calendarActivationIsStillRequested(request) else {
            return
        }
        calendarOperationInProgress = true
        defer { calendarOperationInProgress = false }

        let sync = DeadlineCalendarSync(modelContext: modelContext)
        do {
            if case .validateEnabled = request,
               DeadlineCalendarSync.managedCalendarWasDeleted() {
                try ManagedCalendarDeletionCoordinator.clearLinksAndAcknowledge(
                    clearLinks: {
                        try sync.clearEventLinksAfterManagedCalendarDeletion()
                    },
                    acknowledge: {
                        DeadlineCalendarSync.acknowledgeManagedCalendarDeletion()
                    }
                )
                deadlineSyncEnabled = false
                meetingSyncEnabled = false
                return
            }

            let outcome = try await CalendarSyncActivation.run(
                isEnabled: calendarActivationIsStillRequested(request),
                hasWriteAccess: DeadlineCalendarSync.hasWriteAccess,
                isStillEnabled: {
                    calendarActivationIsStillRequested(request)
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
                completeCalendarActivation(request)
            case .calendarResolutionRequired(let conflict):
                pendingCalendarConflictActivation = request
                detectedCalendarConflict = conflict
                showsCalendarConflictConfirmation = true
            case .permissionDenied:
                Self.calendarLogger.notice(
                    "Calendar sync could not be enabled because Calendar access is unavailable"
                )
                failCalendarActivation(
                    request,
                    message: DeadlineCalendarSyncError.permissionRequired.localizedDescription
                )
            case .disabled:
                break
            }
        } catch {
            Self.calendarLogger.error(
                "Could not prepare Calendar sync: \(String(reflecting: type(of: error)), privacy: .public)"
            )
            failCalendarActivation(request, message: error.localizedDescription)
        }
    }

    private func resolveCalendarConflict(
        _ resolution: ManagedCalendarConflictResolution
    ) async {
        guard let request = pendingCalendarConflictActivation,
              calendarOperationInProgress == false else {
            return
        }
        calendarOperationInProgress = true
        defer { calendarOperationInProgress = false }

        let sync = DeadlineCalendarSync(modelContext: modelContext)
        do {
            try await sync.resolveManagedCalendarConflict(resolution)
            completeCalendarActivation(request)
            clearCalendarConflict()
        } catch DeadlineCalendarSyncError.postCommitCleanupFailed(let message) {
            Self.calendarLogger.error(
                "The Ohia calendar was updated, but saved event links could not be refreshed"
            )
            completeCalendarActivation(request)
            clearCalendarConflict()
            calendarActivationErrorTitle = "Calendar sync needs attention"
            calendarActivationError = "The Ohia calendar was updated and syncing remains on, but Ohia could not refresh its saved event links. Ohia will recover those links during the next sync. \(message)"
            showsCalendarActivationError = true
        } catch {
            Self.calendarLogger.error(
                "Could not resolve detected Ohia calendars: \(String(reflecting: type(of: error)), privacy: .public)"
            )
            failCalendarActivation(request, message: error.localizedDescription)
            clearCalendarConflict()
        }
    }

    private func startCalendarConflictResolution(
        _ resolution: ManagedCalendarConflictResolution
    ) {
        CalendarConflictResolutionTask.launch {
            await resolveCalendarConflict(resolution)
            schedulePendingCalendarStoreValidationIfNeeded()
        }
    }

    private func completeCalendarActivation(_ request: CalendarActivationRequest) {
        guard case .enable(let selection) = request else { return }
        setCalendarSyncEnabled(true, for: selection)
    }

    private func failCalendarActivation(
        _ request: CalendarActivationRequest,
        message: String
    ) {
        if case .validateEnabled = request {
            deadlineSyncEnabled = false
            meetingSyncEnabled = false
        } else if calendarRemindersEnabled {
            // If one source was already selected, a failed shared-calendar
            // activation means neither switch can truthfully remain on.
            deadlineSyncEnabled = false
            meetingSyncEnabled = false
        }
        calendarActivationErrorTitle = "Calendar sync could not be enabled"
        calendarActivationError = message
        showsCalendarActivationError = true
    }

    private func cancelCalendarConflictResolution() {
        if case .validateEnabled = pendingCalendarConflictActivation {
            deadlineSyncEnabled = false
            meetingSyncEnabled = false
        }
        clearCalendarConflict()
        schedulePendingCalendarStoreValidationIfNeeded()
    }

    private func clearCalendarConflict() {
        pendingCalendarConflictActivation = nil
        detectedCalendarConflict = nil
        showsCalendarConflictConfirmation = false
    }

    private func calendarActivationIsStillRequested(
        _ request: CalendarActivationRequest
    ) -> Bool {
        switch request {
        case .enable:
            return true
        case .validateEnabled:
            return calendarRemindersEnabled
        }
    }

    private func schedulePendingCalendarStoreValidationIfNeeded() {
        guard calendarStoreChangePending else { return }
        let hasPendingRequest = calendarActivationRequest != nil
            || pendingCalendarConflictActivation != nil
        guard CalendarSyncSelectionPolicy.shouldValidateAfterStoreChange(
            syncEnabled: calendarRemindersEnabled,
            isBusy: calendarOperationInProgress,
            hasPendingRequest: hasPendingRequest
        ) else {
            if calendarRemindersEnabled == false {
                calendarStoreChangePending = false
            }
            return
        }
        calendarStoreChangePending = false
        calendarActivationRequest = .validateEnabled
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
}
