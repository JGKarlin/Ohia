import SwiftUI
import OhiaCore
import OhiaML

// MARK: - Agenda column

enum DeadlineCalendarStatusScope {
    static func resolve(
        deadlineSyncEnabled: Bool,
        calendarStatus: DeadlineCalendarSyncStatus
    ) -> DeadlineCalendarSyncStatus {
        deadlineSyncEnabled ? calendarStatus : .disabled
    }
}

enum DeadlineAgendaCalendarIndicatorPresentation: Equatable {
    case off
    case syncing
    case synced
    case needsPermission
    case failed(String)

    static func resolve(
        deadlineSyncEnabled: Bool,
        calendarStatus: DeadlineCalendarSyncStatus,
        activationPending: Bool = false
    ) -> DeadlineAgendaCalendarIndicatorPresentation {
        if activationPending {
            return .syncing
        }
        switch DeadlineCalendarStatusScope.resolve(
            deadlineSyncEnabled: deadlineSyncEnabled,
            calendarStatus: calendarStatus
        ) {
        case .disabled: return .off
        case .syncing: return .syncing
        case .synced: return .synced
        case .needsPermission: return .needsPermission
        case .failed(let message): return .failed(message)
        }
    }

    var iconName: String {
        switch self {
        case .off: return "calendar.badge.minus"
        case .syncing: return "calendar"
        case .synced: return "calendar.badge.checkmark"
        case .needsPermission: return "calendar.badge.plus"
        case .failed: return "exclamationmark.calendar"
        }
    }

    var title: String {
        switch self {
        case .off: return "Calendar off"
        case .syncing: return "Calendar syncing"
        case .synced: return "Calendar synced"
        case .needsPermission: return "Enable Calendar"
        case .failed: return "Calendar sync failed"
        }
    }
}

enum DeadlineAgendaSectionID: String, Identifiable, Hashable {
    case active
    case resolved
    case hidden

    var id: String { rawValue }
}

struct DeadlineAgendaProjection {
    struct Section: Identifiable {
        let id: DeadlineAgendaSectionID
        let title: String
        let entries: [DeadlineEntry]
    }

    let tracker: DeadlineTrackerSnapshot
    let now: Date
    let pinnedIDs: Set<String>
    let hiddenIDs: Set<String>

    var sections: [Section] {
        let active = pinFirst(
            (tracker.past + tracker.upcoming).filter {
                hiddenIDs.contains($0.id) == false
            }
        )
        let resolved = pinFirst(
            tracker.resolved.filter { hiddenIDs.contains($0.id) == false }
        )
        let hidden = pinFirst(
            tracker.allEntries.filter { hiddenIDs.contains($0.id) }
        )

        var result = [
            Section(id: .active, title: "Active deadlines", entries: active),
            Section(id: .resolved, title: "Resolved deadlines", entries: resolved)
        ]
        if hidden.isEmpty == false {
            result.append(
                Section(id: .hidden, title: "Hidden deadlines", entries: hidden)
            )
        }
        return result
    }

    var entries: [DeadlineEntry] {
        sections.flatMap(\.entries)
    }

    func visibleEntries(
        in expandedSectionIDs: Set<DeadlineAgendaSectionID>
    ) -> [DeadlineEntry] {
        sections
            .filter { expandedSectionIDs.contains($0.id) }
            .flatMap(\.entries)
    }

    private func pinFirst(_ entries: [DeadlineEntry]) -> [DeadlineEntry] {
        entries.filter { pinnedIDs.contains($0.id) }
            + entries.filter { pinnedIDs.contains($0.id) == false }
    }
}

enum DeadlineAgendaStampPresentation: Equatable {
    case upcoming
    case overdue
    case pinned
    case resolved
    case hidden

    static func resolve(
        entry: DeadlineEntry,
        isPinned: Bool,
        isHidden: Bool
    ) -> DeadlineAgendaStampPresentation {
        if isPinned { return .pinned }
        if isHidden { return .hidden }
        if entry.status == .resolved { return .resolved }
        return entry.status == .past ? .overdue : .upcoming
    }

    var iconName: String {
        switch self {
        case .upcoming: return "clock.fill"
        case .overdue: return "exclamationmark.circle.fill"
        case .pinned: return "pin.fill"
        case .resolved: return "checkmark.circle.fill"
        case .hidden: return "eye.slash.fill"
        }
    }

    var title: String {
        switch self {
        case .upcoming: return "Upcoming"
        case .overdue: return "Overdue"
        case .pinned: return "Pinned"
        case .resolved: return "Resolved"
        case .hidden: return "Hidden"
        }
    }

    var tint: Color {
        switch self {
        case .upcoming: return OhiaColors.chipActiveForeground
        case .overdue: return OhiaColors.ohiaRed
        case .pinned: return OhiaColors.chipActiveForeground
        case .resolved: return MessageStatusColors.confirmation
        case .hidden: return OhiaColors.textTertiary
        }
    }
}

/// The left column: every tracked deadline as a days-until-due countdown row,
/// grouped into project-style Active, Resolved, and (when needed) Hidden
/// disclosure sections, with a reminder bell and state stamp. A single
/// click selects the row into the guide pane; a double click opens the focused
/// workroom of the deadline's thread emails.
struct DeadlineAgendaColumn: View {
    let tracker: DeadlineTrackerSnapshot
    let now: Date
    let pinnedIDs: Set<String>
    let hiddenIDs: Set<String>
    let expandedSections: Set<DeadlineAgendaSectionID>
    let selectedID: String?
    let hoveredID: String?
    let leadTimes: [String: DeadlineReminderLeadTime]
    let deadlineCalendarSyncEnabled: Bool
    let deadlineCalendarActivationPending: Bool
    let calendarStatus: DeadlineCalendarSyncStatus
    let calendarDateOverrideIDs: Set<String>
    let calendarSuppressedEntryIDs: Set<String>
    /// The Projects lens's shared departing-gesture coordinator — drives the
    /// in-place Collapse / Comet exit on a row when its email is resolved,
    /// deleted, or sent to the Composer, the same as the Front Page cards.
    let statusGestureCoordinator: MessageStatusGestureCoordinator
    let onSelect: (DeadlineEntry) -> Void
    let onOpen: (DeadlineEntry) -> Void
    let onHover: (String?) -> Void
    let onSetLeadTime: (DeadlineEntry, DeadlineReminderLeadTime) -> Void
    let onRestoreEmailDate: (DeadlineEntry) -> Void
    let onRestoreCalendarEvent: (DeadlineEntry) -> Void
    let onToggleCalendarSync: () -> Void
    let onToggleSection: (DeadlineAgendaSectionID) -> Void

    private var projection: DeadlineAgendaProjection {
        DeadlineAgendaProjection(
            tracker: tracker,
            now: now,
            pinnedIDs: pinnedIDs,
            hiddenIDs: hiddenIDs
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(OhiaColors.glassBorder)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(projection.sections) { group in
                        deadlineSectionHeader(group)
                        if expandedSections.contains(group.id) {
                            ForEach(group.entries) { entry in
                                let rawDepartureGesture = statusGestureCoordinator.gesture(
                                    for: entry.representativeMessageID
                                )
                                let agendaDepartureGesture = rawDepartureGesture.flatMap { gesture in
                                    DeadlineDeparturePlacement.resolve(
                                        action: gesture.action,
                                        isGuideEntry: selectedID == entry.id
                                    ) == .agenda ? gesture : nil
                                }
                                DeadlineAgendaRow(
                                    entry: entry,
                                    now: now,
                                    isSelected: selectedID == entry.id,
                                    isHovered: hoveredID == entry.id,
                                    stamp: DeadlineAgendaStampPresentation.resolve(
                                        entry: entry,
                                        isPinned: pinnedIDs.contains(entry.id),
                                        isHidden: hiddenIDs.contains(entry.id)
                                    ),
                                    leadTime: leadTimes[entry.id] ?? .none,
                                    calendarStatus: calendarStatus,
                                    hasCalendarDateOverride: calendarDateOverrideIDs.contains(entry.id),
                                    isCalendarSyncSuppressed: calendarSuppressedEntryIDs.contains(entry.id),
                                    departingGesture: agendaDepartureGesture,
                                    onSelect: { onSelect(entry) },
                                    onOpen: { onOpen(entry) },
                                    onHover: { onHover($0 ? entry.id : nil) },
                                    onSetLeadTime: { onSetLeadTime(entry, $0) },
                                    onRestoreEmailDate: { onRestoreEmailDate(entry) },
                                    onRestoreCalendarEvent: { onRestoreCalendarEvent(entry) }
                                )
                                .zIndex(agendaDepartureGesture?.action.usesDepartingOverlay == true ? 1 : 0)
                                Divider().overlay(OhiaColors.glassBorder.opacity(0.4))
                            }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Deadlines")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OhiaColors.textPrimary)
            Spacer()
            calendarStatusIndicator
        }
        .frame(height: 34)
        .padding(.horizontal, 16)
        .background(OhiaColors.toolbarBackground)
    }

    @ViewBuilder
    private var calendarStatusIndicator: some View {
        let presentation = DeadlineAgendaCalendarIndicatorPresentation.resolve(
            deadlineSyncEnabled: deadlineCalendarSyncEnabled,
            calendarStatus: calendarStatus,
            activationPending: deadlineCalendarActivationPending
        )
        let chipIsActive = deadlineCalendarSyncEnabled || deadlineCalendarActivationPending
        Button(action: onToggleCalendarSync) {
            HStack(spacing: 4) {
                if presentation == .syncing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(OhiaColors.chipActiveForeground)
                } else {
                    Image(systemName: presentation.iconName)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(presentation.title)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(
                chipIsActive
                    ? OhiaColors.chipActiveForeground
                    : OhiaColors.textSecondary
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        chipIsActive
                            ? OhiaColors.chipActiveBackground
                            : OhiaColors.chipRestBackground
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        chipIsActive
                            ? OhiaColors.chipActiveBorder
                            : OhiaColors.chipRestBorder,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(deadlineCalendarActivationPending)
        .help(calendarStatusHelp(for: presentation))
        .accessibilityLabel(presentation.title)
        .accessibilityValue(
            deadlineCalendarActivationPending
                ? "Turning on"
                : (deadlineCalendarSyncEnabled ? "On" : "Off")
        )
        .accessibilityHint(
            deadlineCalendarActivationPending
                ? "Deadline calendar syncing is being turned on"
                : (deadlineCalendarSyncEnabled
                    ? "Turn off deadline calendar syncing"
                    : "Turn on deadline calendar syncing")
        )
    }

    private func calendarStatusHelp(
        for presentation: DeadlineAgendaCalendarIndicatorPresentation
    ) -> String {
        switch presentation {
        case .off:
            return "Deadline calendar syncing is off. Click to turn it on."
        case .syncing:
            return "Deadline calendar syncing is in progress. Click to turn it off."
        case .synced:
            return "Two-way deadline sync with the \u{201C}Ohia\u{201D} calendar is healthy. Click to turn it off."
        case .needsPermission:
            return "Deadline calendar syncing needs Calendar access. Click to turn it off."
        case .failed(let message):
            return "Deadline calendar syncing failed: \(message). Click to turn it off."
        }
    }

    private func deadlineSectionHeader(
        _ group: DeadlineAgendaProjection.Section
    ) -> some View {
        let expanded = expandedSections.contains(group.id)
        let isActive = group.id == .active
        return Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                onToggleSection(group.id)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("\(group.title) · \(group.entries.count) deadline\(group.entries.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isActive ? OhiaColors.textPrimary : OhiaColors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .frame(height: 34)
        .padding(.leading, isActive ? 10 : 14)
        .padding(.trailing, 10)
        .background(OhiaColors.surface(isActive ? 0.045 : 0.075))
        .overlay(alignment: .leading) {
            if isActive == false {
                Rectangle()
                    .fill(OhiaColors.textDim.opacity(0.9))
                    .frame(width: 4)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OhiaColors.glassBorder.opacity(isActive ? 0.58 : 0.86))
                .frame(height: 1)
        }
        .accessibilityLabel(group.title)
        .accessibilityValue(
            "\(group.entries.count) deadlines, \(expanded ? "expanded" : "collapsed")"
        )
    }

}

// MARK: - Agenda row

struct DeadlineAgendaRow: View {
    let entry: DeadlineEntry
    let now: Date
    let isSelected: Bool
    let isHovered: Bool
    let stamp: DeadlineAgendaStampPresentation
    let leadTime: DeadlineReminderLeadTime
    let calendarStatus: DeadlineCalendarSyncStatus
    let hasCalendarDateOverride: Bool
    let isCalendarSyncSuppressed: Bool
    /// The departing (delete / resolve / send-to-Composer) gesture playing on
    /// this deadline's email, if any — drives the in-place Collapse / Comet exit.
    let departingGesture: MessageStatusGesture?
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onHover: (Bool) -> Void
    let onSetLeadTime: (DeadlineReminderLeadTime) -> Void
    let onRestoreEmailDate: () -> Void
    let onRestoreCalendarEvent: () -> Void

    /// True while a departing gesture owns this row: it hides its own content so
    /// the `DepartingGestureOverlay` crumbles the row in place.
    private var departingGestureActive: Bool {
        departingGesture?.action.usesDepartingOverlay == true
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            countdownBlock
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title.isEmpty ? "(no subject)" : entry.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(entry.status == .resolved ? OhiaColors.textSecondary : OhiaColors.textPrimary)
                    .strikethrough(entry.status == .resolved, color: OhiaColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(dateLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(statusColor)
                    if entry.messageCount > 1 {
                        Text("· \(entry.messageCount) emails")
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(OhiaColors.textTertiary)
                    }
                }
                if !correspondents.isEmpty {
                    Text(correspondents)
                        .font(.system(size: 10.5))
                        .foregroundStyle(OhiaColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .center, spacing: 8) {
                    reminderControl
                    Spacer(minLength: 8)
                }
                .padding(.top, 3)
            }
            stateStamp
        }
        // A departing gesture fades the row's content and clears its fill so the
        // Collapse / Comet overlay crumbles the row in place.
        .opacity(departingGestureActive ? 0 : 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background {
            if !departingGestureActive { highlightBackground }
        }
        // The overlay is inset to match the row's rounded fill (its 6/2 padding),
        // then crumbles within it.
        .overlay {
            if let departingGesture, departingGesture.action.usesDepartingOverlay {
                DepartingGestureOverlay(
                    action: departingGesture.action,
                    gesture: departingGesture,
                    cornerRadius: 8,
                    iconSize: 22
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
        }
        .contentShape(Rectangle())
        // A crumbling row is inert: block click-through to the (now invisible)
        // content, reminder control, and cluster while the Collapse / Comet plays.
        .allowsHitTesting(!departingGestureActive)
        // Single click selects (yellow halo, HUD-actionable); double click opens
        // the focused workroom. Guarded too, so the gating never depends on
        // `allowsHitTesting` ordering relative to these gestures.
        .onTapGesture(count: 2) { if !departingGestureActive { onOpen() } }
        .onTapGesture(count: 1) { if !departingGestureActive { onSelect() } }
        .onHover(perform: onHover)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .modifier(ComposerDepartureSource(messageIDs: [entry.representativeMessageID], inScrollView: true))
    }

    private var stateStamp: some View {
        Image(systemName: stamp.iconName)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(stamp.tint)
            .frame(width: 30, height: 30)
            .background {
                Circle().fill(OhiaColors.buttonBackground)
            }
            .overlay {
                Circle().strokeBorder(stamp.tint.opacity(0.8), lineWidth: 1)
            }
            .help(stamp.title)
            .accessibilityLabel(stamp.title)
    }

    /// Selected/hovered fill plus the Front-Page selection halo.
    private var highlightBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? OhiaColors.chipActiveBorder : Color.clear, lineWidth: 2)
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
    }

    private var fillColor: Color {
        if isSelected { return OhiaColors.chipActiveBackground.opacity(0.4) }
        if isHovered { return OhiaColors.surface(0.06) }
        return .clear
    }

    // Countdown — the primary datum.
    private var countdownBlock: some View {
        VStack(spacing: 0) {
            Text(countdownValue)
                .font(.system(size: countdownValue.count > 3 ? 15 : 20, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(countdownUnit)
                .font(.system(size: 8.5, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.3)
                .foregroundStyle(statusColor.opacity(0.85))
        }
        .frame(width: 52)
        .padding(.top, 1)
    }

    private var delta: Int { DeadlineFormatting.dayDelta(from: now, to: entry.deadlineDate) }

    private var countdownValue: String {
        if entry.status == .resolved { return "\u{2713}" }
        if delta == 0 { return "Today" }
        return "\(abs(delta))"
    }

    private var countdownUnit: String {
        if entry.status == .resolved { return "done" }
        if delta == 0 { return "" }
        let unit = abs(delta) == 1 ? "day" : "days"
        return delta < 0 ? "\(unit) ago" : unit
    }

    private var dateLabel: String {
        entry.granularity == .dateTime
            ? DeadlineFormatting.dayTimeLabel(entry.deadlineDate)
            : DeadlineFormatting.dayLabel(entry.deadlineDate)
    }

    private var correspondents: String {
        let names = entry.correspondents.prefix(3).map { $0.displayName ?? $0.email }
        let extra = entry.correspondents.count - names.count
        let base = names.joined(separator: ", ")
        return extra > 0 ? "\(base)  +\(extra)" : base
    }

    private var statusColor: Color {
        switch entry.status {
        case .resolved: return OhiaColors.textTertiary
        case .past: return OhiaColors.ohiaRed
        case .upcoming: return delta <= 2 ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary
        }
    }

    // Reminder bell → lead-time menu. Calendar enablement belongs to the one
    // authoritative chip in the agenda header, not every deadline row.
    @ViewBuilder
    private var reminderControl: some View {
        if entry.status == .resolved || calendarStatus.isSynced == false {
            EmptyView()
        } else if isCalendarSyncSuppressed {
            Button(action: onRestoreCalendarEvent) {
                reminderPill(
                    icon: "calendar.badge.plus",
                    text: "Add to Calendar",
                    tint: OhiaColors.chipActiveForeground
                )
            }
            .buttonStyle(.plain)
        } else {
            Menu {
                ForEach(DeadlineReminderLeadTime.choices(hasTimeOfDay: entry.granularity == .dateTime)) { choice in
                    Button {
                        onSetLeadTime(choice)
                    } label: {
                        Label(
                            choice.title,
                            systemImage: choice == leadTime ? "checkmark" : "bell"
                        )
                    }
                }
                if hasCalendarDateOverride {
                    Divider()
                    Button(
                        "Restore date from email",
                        systemImage: "arrow.uturn.backward",
                        action: onRestoreEmailDate
                    )
                }
            } label: {
                reminderPill(
                    icon: leadTime == .none ? "bell.slash" : "bell.fill",
                    text: leadTime == .none ? "No reminder" : leadTime.shortTitle,
                    tint: leadTime == .none ? OhiaColors.textTertiary : OhiaColors.chipActiveForeground
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func reminderPill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(OhiaColors.buttonBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

}
