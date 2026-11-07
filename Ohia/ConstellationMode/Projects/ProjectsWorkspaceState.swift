import Foundation
import Observation
import SwiftUI
import OhiaCore
import OhiaML

// Projects is a SwiftUI/Canvas workspace. The normal Metal scene should not mount for `.projects`.

/// The Projects workspace exposes three visual surfaces. `.time` is the
/// default landing — every visible project laid out across the time
/// axis. `.linksFor(projectKey:)` is the per-project workroom — the
/// email-by-email breakdown (`ProjectsWorkroomView`), reached by
/// double-clicking or right-clicking a row, beacon arrivals, and Ask
/// citations. It always carries the project key it's centered on;
/// `.configure` is the in-place manual project editor. Returning to
/// `.time` drops either focused route. (The links case name survives from
/// the retired links-canvas era; the mode is the workroom.)
enum ProjectsWorkspaceMode: Equatable, Sendable {
    case time
    case linksFor(projectKey: String)
    case configure(ProjectConfigurationRoute)

    var isLinks: Bool {
        if case .linksFor = self { return true }
        return false
    }

    var linksProjectKey: String? {
        if case .linksFor(let key) = self { return key }
        return nil
    }

    var configurationRoute: ProjectConfigurationRoute? {
        if case .configure(let route) = self { return route }
        return nil
    }
}

struct ProjectDeletionRequest: Equatable, Sendable {
    let sequence: Int
    let projectID: UUID
    let displayName: String
    let memberCount: Int
}

enum ProjectMutationAction: Equatable, Sendable {
    case rename
    case pin
    case unpin
    case resolve
    case reopen
    case delete
    case discardDraft
    case restore
    case pinDeadline
    case unpinDeadline
    case hideDeadline
    case unhideDeadline

    var failureTitle: String {
        switch self {
        case .rename: return "Couldn't Rename Project"
        case .pin: return "Couldn't Pin Project"
        case .unpin: return "Couldn't Unpin Project"
        case .resolve: return "Couldn't Resolve Project"
        case .reopen: return "Couldn't Reopen Project"
        case .delete: return "Couldn't Delete Project"
        case .discardDraft: return "Couldn't Delete Project Draft"
        case .restore: return "Couldn't Restore Project"
        case .pinDeadline: return "Couldn't Pin Deadline"
        case .unpinDeadline: return "Couldn't Unpin Deadline"
        case .hideDeadline: return "Couldn't Hide Deadline"
        case .unhideDeadline: return "Couldn't Unhide Deadline"
        }
    }
}

struct ProjectMutationFailure: Equatable, Sendable {
    let title: String
    let message: String
}

enum ProjectsHoverTarget: Equatable, Sendable {
    case row(String)
    case message(UUID)
}

/// The two independent trackers the Projects lens hosts. `.projects` is the
/// project surface (Gantt + workroom); `.deadlines` re-organizes the same
/// mailbox scope around dated deadlines. They share nothing but the lens
/// chrome and the filter scope.
enum ProjectsLensTab: String, CaseIterable, Sendable {
    case projects
    case deadlines

    var title: String {
        switch self {
        case .projects: return "Projects"
        case .deadlines: return "Deadlines"
        }
    }
}

struct ProjectsTimeFocusRequest: Equatable, Sendable {
    let sequence: Int
    let messageID: UUID
    let projectKey: String
    let pinReadout: Bool
}

struct ProjectsLinksFocusRequest: Equatable, Sendable {
    let sequence: Int
    let messageID: UUID
    let projectKey: String
    let expandedMode: AnnotationExpandedContentMode
}

struct ProjectsEmptyConfigurationEntryPolicy: Equatable {
    private var hasEvaluatedCurrentVisit = false

    mutating func beginVisit() {
        hasEvaluatedCurrentVisit = false
    }

    mutating func shouldOpenConfiguration(
        lensTab: ProjectsLensTab,
        selectedMode: ProjectsWorkspaceMode,
        hasTrustworthySnapshot: Bool,
        persistedProjectCount: Int,
        hasProjectDraft: Bool
    ) -> Bool {
        guard lensTab == .projects,
              hasEvaluatedCurrentVisit == false else {
            return false
        }
        guard selectedMode == .time else {
            hasEvaluatedCurrentVisit = true
            return false
        }
        guard hasTrustworthySnapshot else { return false }
        hasEvaluatedCurrentVisit = true
        return persistedProjectCount == 0 && hasProjectDraft == false
    }
}

@Observable @MainActor
final class ProjectsWorkspaceState {
    /// Which top-level tracker is showing. Toggled from the mode strip.
    var lensTab: ProjectsLensTab = .projects
    /// The focused deadline entry id (thread- or message-scoped), for the
    /// calendar highlight and the resolve/reminder target. Deadlines-tab only.
    var selectedDeadlineID: String?
    /// Pointer-hovered deadline entry id, for the agenda ↔ calendar
    /// cross-highlight. Deadlines-tab only.
    var hoveredDeadlineID: String?
    /// When set, the Deadlines tab shows the focused workroom for this deadline
    /// (its thread's emails) instead of the agenda + calendar. The mode-strip
    /// back control and Esc clear it — the Deadlines analogue of `.linksFor`.
    var openedDeadlineID: String?
    /// Calendar day the user selected in the month view, to filter the agenda.
    /// `nil` shows every deadline.
    var selectedCalendarDay: Date?
    var selectedMode: ProjectsWorkspaceMode = .time
    /// Selected projects. Replaces single-row focus as the primary
    /// state — a one-element set is the canonical "focused" case and
    /// the axis zoom still tracks it; a multi-element set drops the
    /// axis back to the global range and unlocks the bulk menu.
    var selectedProjectKeys: Set<String> = []
    /// Anchor for ⇧-click range extension. Set on every non-shift
    /// click (toggle or replace) and cleared with the selection.
    var selectionAnchorKey: String?
    var hoveredTarget: ProjectsHoverTarget?
    var currentSnapshot: ProjectsSnapshot?
    /// The full project row captured when the user enters its workroom. Message
    /// Message filters can leave no matching cards, but the workroom must keep
    /// its persisted project identity and apply the refreshed scope only to the
    /// email cards it displays.
    var workroomAnchorRow: ProjectRow?
    /// Per-message action-response gestures — the same coordinator Front Page
    /// and Timeline use (via `DepartingGestureOverlay`). Drives the in-place
    /// delete / resolve Collapse and the send-to-Composer Comet on the Projects
    /// card surfaces (workroom feed, Deadlines rows, focused reader). Each lens
    /// owns its own coordinator so a gesture never bleeds across surfaces.
    let statusGestureCoordinator = MessageStatusGestureCoordinator()

    /// How long a Projects departing gesture's overlay lingers after its motion
    /// begins before it settles. Shared so the host (`ConstellationModeView`) and
    /// the Deadlines view stay in lockstep — the resolved / sent message stays in
    /// the snapshot, so the gesture is cleared on this timer, not by a drop.
    static let departingSettleHold: Double = 1.3

    /// True only when the active Projects surface renders a card that can host a
    /// departing-gesture Collapse / Comet: the per-project workroom feed
    /// (`.linksFor`) or the Deadlines tab (agenda rows + focused reader). The
    /// default Time / Gantt surface hosts no such card, so departing gestures must
    /// NOT begin there — with nothing to render, they would only stall the dot's
    /// rebuild-hold with no animation to show for it.
    var hasDepartingCardSurface: Bool {
        if lensTab == .deadlines { return true }
        return selectedMode.isLinks
    }
    var actionRevision: Int = 0
    /// Lightweight invalidation for per-deadline agenda disposition. This is
    /// intentionally separate from message/project mutations, which rebuild
    /// the full Projects snapshot.
    var deadlineDispositionRevision: Int = 0
    var accountScopeKey: String = "all"
    /// The project whose title is being renamed inline in the Time view.
    /// Set by the Rename Project menu action; the Time view swaps that
    /// row's title for an editable field. Cleared on commit or cancel.
    var renamingProjectKey: String?
    /// Pointer-hovered Time-view section header id (`ProjectsTimeSectionHeader`
    /// constants). Space toggles this section while the pointer is anywhere
    /// over its header band or nested rows (gutter or canvas).
    var hoveredTimeSectionID: String?
    /// Expansion state of the two Time-view sections, each toggled by its
    /// chevron or Space while the pointer is over that section. Active defaults
    /// open; inactive / resolved defaults closed. Shared keyboard
    /// actions read these so their definition of visible rows matches the
    /// screen.
    var activeProjectsExpanded: Bool = true
    var showDormantProjects: Bool = false

    /// Typed presentation request consumed by the deletion workspace. It carries
    /// stable UUID identity and no persistence behavior; issuing it never changes
    /// selection. Project configuration is a first-class workspace mode above.
    var projectDeletionRequest: ProjectDeletionRequest?
    let projectDeletionUndoTarget = MailProjectDeletionUndoTarget()
    var projectMutationFailure: ProjectMutationFailure?
    private var nextProjectDeletionRequestSequence = 0

    /// Manual time-axis zoom window (pinch, horizontal scroll, ⌘+/⌘−).
    /// Nil means automatic: the axis fits the scope, or the focused row's
    /// span when a row is focused. Set, it wins over both, and every row's
    /// dots project onto this shared window so cross-row comparison holds.
    /// ⌘0 or a filter-scope change resets to automatic.
    var timeZoomRange: ClosedRange<Date>?
    var timeFocusRequest: ProjectsTimeFocusRequest?
    var linksFocusRequest: ProjectsLinksFocusRequest?
    private var nextTimeFocusRequestSequence = 0
    private var nextLinksFocusRequestSequence = 0

    /// Single-selection projection of `selectedProjectKeys`. Read
    /// sites that drive axis zoom, focus strip, and Links pivots
    /// resolve to a key only when the selection has exactly one row;
    /// multi-selection collapses these to "no canonical focus."
    var focusedProjectKey: String? {
        guard selectedProjectKeys.count == 1 else { return nil }
        return selectedProjectKeys.first
    }

    /// Replace the selection with the given key (or clear it when
    /// `nil`). All non-modified click paths flow through here so the
    /// anchor and selection stay coherent.
    func focusProject(_ projectKey: String?) {
        if let projectKey {
            selectedProjectKeys = [projectKey]
            selectionAnchorKey = projectKey
        } else {
            selectedProjectKeys = []
            selectionAnchorKey = nil
        }
    }

    /// ⌘+click: toggle a row's membership. Anchor moves to the
    /// clicked row whenever the toggle leaves it selected so a
    /// subsequent ⇧+click extends from the last-touched row.
    func toggleSelection(_ projectKey: String) {
        if selectedProjectKeys.contains(projectKey) {
            selectedProjectKeys.remove(projectKey)
            if selectionAnchorKey == projectKey {
                selectionAnchorKey = selectedProjectKeys.first
            }
        } else {
            selectedProjectKeys.insert(projectKey)
            selectionAnchorKey = projectKey
        }
    }

    /// ⇧+click: replace the selection with the inclusive range from
    /// the current anchor to `projectKey`, ordered by `orderedKeys`.
    /// When the anchor is missing or stale (e.g. its row was hidden
    /// by a bulk action), collapse to a plain focus AND reset the
    /// anchor so subsequent ⇧+click extends predictably from here.
    func extendSelection(to projectKey: String, in orderedKeys: [String]) {
        guard let anchor = selectionAnchorKey,
              let anchorIdx = orderedKeys.firstIndex(of: anchor),
              let targetIdx = orderedKeys.firstIndex(of: projectKey) else {
            focusProject(projectKey)
            return
        }
        let lower = min(anchorIdx, targetIdx)
        let upper = max(anchorIdx, targetIdx)
        selectedProjectKeys = Set(orderedKeys[lower...upper])
    }

    /// Replace the selection with every key in `orderedKeys`. The
    /// anchor pins to the first row so a subsequent ⇧+click extends
    /// predictably from the top of the list.
    func selectAll(in orderedKeys: [String]) {
        guard let first = orderedKeys.first else {
            clearSelection()
            return
        }
        selectedProjectKeys = Set(orderedKeys)
        selectionAnchorKey = first
    }

    func clearSelection() {
        selectedProjectKeys = []
        selectionAnchorKey = nil
    }

    func focusMessage(_ messageID: UUID, projectKey: String) {
        focusProject(projectKey)
        hoveredTarget = .message(messageID)
    }

    func focusMessageInTimeView(
        _ messageID: UUID,
        projectKey: String,
        pinReadout: Bool
    ) {
        selectedMode = .time
        workroomAnchorRow = nil
        workroomExpandedMessageID = nil
        linksFocusRequest = nil
        // A manual zoom window would desync the readout anchor from the
        // canvas projection (the anchor is computed from the focused row's
        // span) — drop it so the focus-fit projection lands.
        timeZoomRange = nil
        focusMessage(messageID, projectKey: projectKey)
        nextTimeFocusRequestSequence &+= 1
        timeFocusRequest = ProjectsTimeFocusRequest(
            sequence: nextTimeFocusRequestSequence,
            messageID: messageID,
            projectKey: projectKey,
            pinReadout: pinReadout
        )
    }

    /// Enter the per-project workroom for `projectKey`. Focuses the
    /// row, dismisses transient popups, and switches the mode so the
    /// workspace re-renders the workroom bound to this project.
    func openLinksFor(_ projectKey: String, anchorRow: ProjectRow? = nil) {
        workroomAnchorRow = anchorRow
            ?? currentSnapshot?.projectDefinitionRow(for: projectKey)
        focusProject(projectKey)
        hoveredTarget = nil
        messageReadout = nil
        workroomExpandedMessageID = nil
        linksFocusRequest = nil
        renamingProjectKey = nil
        selectedMode = .linksFor(projectKey: projectKey)
    }

    /// Route a message-level navigation request into the project it
    /// belongs to, preserving the message as the workroom's subject.
    @discardableResult
    func openLinksForMessage(
        _ messageID: UUID,
        in snapshot: ProjectsSnapshot,
        openEmailReadout: Bool = false
    ) -> Bool {
        guard let row = snapshot.row(containing: messageID, preferredProjectKey: focusedProjectKey) else {
            return false
        }
        openLinksFor(
            row.projectKey,
            anchorRow: snapshot.projectDefinitionRow(for: row.projectKey) ?? row
        )
        focusMessage(messageID, projectKey: row.projectKey)
        // Every programmatic entry mints a focus request — the workroom
        // scrolls the target card to center and rings it with the arrival
        // accent. `.message` additionally opens the in-place reader (Ask
        // citations); beacon and search arrivals highlight without
        // auto-opening.
        requestLinksFocusReadout(
            messageID: messageID,
            projectKey: row.projectKey,
            expandedMode: openEmailReadout ? .message : .summary
        )
        return true
    }

    func requestLinksFocusReadout(
        messageID: UUID,
        projectKey: String,
        expandedMode: AnnotationExpandedContentMode
    ) {
        nextLinksFocusRequestSequence &+= 1
        linksFocusRequest = ProjectsLinksFocusRequest(
            sequence: nextLinksFocusRequestSequence,
            messageID: messageID,
            projectKey: projectKey,
            expandedMode: expandedMode
        )
    }

    func completeLinksFocusRequest(_ request: ProjectsLinksFocusRequest) {
        guard linksFocusRequest?.sequence == request.sequence else { return }
        linksFocusRequest = nil
    }

    /// Return to the Time surface. Used by the back chevron in the
    /// mode strip and by ESC when nothing more transient needs
    /// dismissing. Drops any open readout (its anchor is in the
    /// departing surface's coordinates) and the workroom's expanded
    /// reader.
    func returnToTimeView() {
        selectedMode = .time
        workroomAnchorRow = nil
        hoveredTarget = nil
        hoveredTimeSectionID = nil
        messageReadout = nil
        workroomExpandedMessageID = nil
        linksFocusRequest = nil
        renamingProjectKey = nil
    }

    func clearFocusForFilterChange() {
        let retainedWorkroomKey = lensTab == .projects
            ? selectedMode.linksProjectKey
            : nil
        if let retainedWorkroomKey {
            focusProject(retainedWorkroomKey)
        } else if lensTab == .projects,
                  selectedMode.configurationRoute != nil {
            clearSelection()
            workroomAnchorRow = nil
        } else {
            clearSelection()
            selectedMode = .time
            workroomAnchorRow = nil
        }
        hoveredTarget = nil
        hoveredTimeSectionID = nil
        messageReadout = nil
        workroomExpandedMessageID = nil
        linksFocusRequest = nil
        timeFocusRequest = nil
        renamingProjectKey = nil
        selectedDeadlineID = nil
        hoveredDeadlineID = nil
        openedDeadlineID = nil
        selectedCalendarDay = nil
    }

    func bumpActionRevision() {
        actionRevision &+= 1
    }

    func bumpDeadlineDispositionRevision() {
        deadlineDispositionRevision &+= 1
    }

    /// Begin inline rename of `projectKey`'s title in the Time view.
    func beginRenaming(_ projectKey: String) {
        renamingProjectKey = projectKey
    }

    /// End inline rename (commit or cancel), returning the row to static text.
    func endRenaming() {
        renamingProjectKey = nil
    }

    func reportProjectMutationFailure(
        action: ProjectMutationAction,
        error: any Error
    ) {
        let message: String
        if let repositoryError = error as? MailProjectRepositoryError {
            switch repositoryError {
            case .projectNotFound:
                message = "This project no longer exists."
            case .nameAlreadyExists(let name):
                message = "A project named “\(name)” already exists. Choose a different name."
            case .configurationDraftAlreadyExists:
                message = "Finish or discard the open project configuration before trying again."
            }
        } else {
            message = error.localizedDescription
        }
        projectMutationFailure = ProjectMutationFailure(
            title: action.failureTitle,
            message: message
        )
    }

    func clearProjectMutationFailure() {
        projectMutationFailure = nil
    }

    func requestNewProjectConfiguration() {
        prepareForProjectConfiguration()
        selectedMode = .configure(.newProject)
    }

    func requestProjectConfiguration(projectID: UUID) {
        prepareForProjectConfiguration()
        selectedMode = .configure(.existingProject(projectID))
    }

    func requestProjectDraftConfiguration(draftID: UUID) {
        prepareForProjectConfiguration()
        selectedMode = .configure(.projectDraft(draftID))
    }

    private func prepareForProjectConfiguration() {
        clearSelection()
        workroomAnchorRow = nil
        hoveredTarget = nil
        hoveredTimeSectionID = nil
        messageReadout = nil
        workroomExpandedMessageID = nil
        linksFocusRequest = nil
        timeFocusRequest = nil
        renamingProjectKey = nil
    }

    func requestProjectDeletion(_ row: ProjectRow) {
        nextProjectDeletionRequestSequence &+= 1
        let structuralRow = currentSnapshot?.projectDefinitionRow(for: row.projectKey) ?? row
        projectDeletionRequest = ProjectDeletionRequest(
            sequence: nextProjectDeletionRequestSequence,
            projectID: row.projectID,
            displayName: row.displayLabel,
            memberCount: structuralRow.messageIDs.count
        )
    }

    func clearProjectDeletionRequest() {
        projectDeletionRequest = nil
    }

    /// Switch the top-level tracker. Transient popups anchor to the departing
    /// surface's coordinates, so they're dropped; the two tabs keep their own
    /// selection state otherwise (returning to Projects finds its rows as left).
    func switchLensTab(to tab: ProjectsLensTab) {
        guard lensTab != tab else { return }
        lensTab = tab
        messageReadout = nil
        hoveredTarget = nil
        hoveredDeadlineID = nil
        workroomExpandedMessageID = nil
        renamingProjectKey = nil
    }

    /// Open a deadline's focused workroom (its thread's emails).
    func openDeadline(_ id: String) {
        openedDeadlineID = id
        selectedDeadlineID = id
    }

    /// Leave the deadline workroom, back to the agenda + calendar.
    func closeDeadline() {
        openedDeadlineID = nil
    }

    /// The classified deadline sections for the current snapshot, re-derived
    /// against the live clock so status stays fresh between data refreshes.
    func deadlineTracker(now: Date = .now) -> DeadlineTrackerSnapshot {
        currentSnapshot?.deadlineTracker(now: now) ?? .empty
    }

    func focusDeadline(_ id: String?) {
        selectedDeadlineID = id
    }

    /// The message hover/pinned readout. Nil-ing it through any path resets
    /// the popup pointer latch and cancels a pending grace dismissal, so a
    /// popup that unmounts without delivering a hover-exit event can never
    /// leave the latch stuck; rebinding to a different message resets the
    /// latch for the same reason (the pointer is on the new node, not the
    /// new popup).
    var messageReadout: ProjectsMessageReadoutState? {
        didSet {
            if messageReadout == nil {
                isPointerOverMessageReadout = false
                cancelScheduledEphemeralReadoutDismissal()
            } else if oldValue?.messageID != messageReadout?.messageID {
                isPointerOverMessageReadout = false
            }
        }
    }
    /// The workroom email card currently expanded into its in-place
    /// reader; `nil` when every card is at rest. Lives here (not in the
    /// view) so the ESC ladder can collapse it before falling through
    /// to "return to Time", and so mode/scope transitions can drop it.
    var workroomExpandedMessageID: UUID?

    /// `true` while the pointer is over the readout popup itself, reported
    /// by `ProjectsMessageReadoutOverlay`. The canvas hover handlers own
    /// node residency; an ephemeral readout survives as long as either the
    /// node or the popup holds the pointer.
    @ObservationIgnored private var isPointerOverMessageReadout = false
    /// Grace countdown between "pointer left the node/popup" and dismissal,
    /// so the pointer can travel from a message dot onto the popup (and
    /// back) without the popup vanishing mid-transit. Mirrors the Time
    /// gutter pane's `scheduleGutterDismiss` idiom, including the interval.
    @ObservationIgnored private var ephemeralReadoutDismissal: Task<Void, Never>?

    var focusedRow: ProjectRow? {
        guard let focusedProjectKey else { return nil }
        if selectedMode.isLinks {
            return currentSnapshot?.projectDefinitionRow(for: focusedProjectKey)
                ?? workroomAnchorRow.flatMap { row in
                    row.projectKey == focusedProjectKey ? row : nil
                }
        }
        return currentSnapshot?.visibleRows.first(where: { $0.projectKey == focusedProjectKey })
    }

    /// Rows currently selected, in the visible-row order. Drives the
    /// focus strip aggregate and the bulk context menu.
    var selectedRows: [ProjectRow] {
        guard let snapshot = currentSnapshot, !selectedProjectKeys.isEmpty else { return [] }
        let rows = snapshot.displayedRows()
        return rows.filter { selectedProjectKeys.contains($0.projectKey) }
    }

    func showMessageReadout(
        messageID: UUID,
        anchorPoint: CGPoint,
        pin: Bool,
        avoidRect: CGRect? = nil,
        expanded: Bool = false,
        expandedMode: AnnotationExpandedContentMode = .summary
    ) {
        // Showing (or re-anchoring) a readout means the pointer is on its
        // node, or the caller pinned it deliberately — either way a pending
        // grace dismissal is stale.
        cancelScheduledEphemeralReadoutDismissal()
        if var existing = messageReadout, existing.messageID == messageID {
            existing.anchorPoint = anchorPoint
            existing.isPinned = existing.isPinned || pin
            // Unconditional so a caller-supplied nil clears any earlier
            // exclusion zone. Since the links canvas retired (2026-07-13)
            // every live caller is Time-view and passes nil; the plumbing
            // stays for the next surface that needs an exclusion zone.
            existing.avoidRect = avoidRect
            if expanded {
                existing.expanded = true
                existing.expandedMode = expandedMode
            }
            messageReadout = existing
            return
        }
        messageReadout = ProjectsMessageReadoutState(
            messageID: messageID,
            anchorPoint: anchorPoint,
            expanded: expanded,
            expandedMode: expandedMode,
            isPinned: pin,
            avoidRect: avoidRect
        )
    }

    func dismissMessageReadout() {
        messageReadout = nil
    }

    func clearEphemeralMessageReadoutIfNeeded() {
        guard messageReadout?.isPinned == false else { return }
        messageReadout = nil
    }

    /// Popup pointer residency, reported by the readout popup's own hover.
    /// Entering the popup keeps an ephemeral readout alive (and cancels an
    /// in-flight grace countdown); leaving it starts the countdown — the
    /// readout closes only once the pointer has settled on neither its node
    /// nor the popup.
    func noteMessageReadoutHover(inside: Bool) {
        isPointerOverMessageReadout = inside
        if inside {
            cancelScheduledEphemeralReadoutDismissal()
        } else {
            scheduleEphemeralMessageReadoutDismissal()
        }
    }

    /// Canvas hover left the readout's node: dismiss the ephemeral readout
    /// after a short grace, unless the pointer lands on the popup (latch)
    /// or back on a node (`showMessageReadout` cancels) first. An already
    /// running countdown is left untouched so wandering the empty canvas
    /// cannot keep extending the popup's life tick by tick.
    func scheduleEphemeralMessageReadoutDismissal() {
        guard let readout = messageReadout, !readout.isPinned else { return }
        guard ephemeralReadoutDismissal == nil else { return }
        ephemeralReadoutDismissal = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            self.ephemeralReadoutDismissal = nil
            guard !self.isPointerOverMessageReadout else { return }
            self.clearEphemeralMessageReadoutIfNeeded()
        }
    }

    private func cancelScheduledEphemeralReadoutDismissal() {
        ephemeralReadoutDismissal?.cancel()
        ephemeralReadoutDismissal = nil
    }

    func toggleMessageReadoutExpansion(requestedMode: AnnotationExpandedContentMode) {
        guard var readout = messageReadout else { return }
        if readout.expanded, readout.expandedMode == requestedMode {
            readout.expanded = false
        } else {
            readout.expanded = true
            readout.expandedMode = requestedMode
        }
        messageReadout = readout
    }

    func requestMessageReadoutExpansionFromKeyboard(shift: Bool) {
        guard messageReadout != nil else { return }
        let mode: AnnotationExpandedContentMode = shift ? .message : .summary
        toggleMessageReadoutExpansion(requestedMode: mode)
    }

    /// Space while the pointer is over a section header toggles that section;
    /// otherwise Space / ⇧Space expand the pinned message readout when one is
    /// open. Returns whether the key was consumed.
    @discardableResult
    func handleSpaceKeyFromKeyboard(shift: Bool) -> Bool {
        if let sectionID = hoveredTimeSectionID {
            toggleTimeSection(sectionID)
            return true
        }
        guard messageReadout != nil else { return false }
        requestMessageReadoutExpansionFromKeyboard(shift: shift)
        return true
    }

    /// Chevron-click and Space-on-hover both route here.
    func toggleTimeSection(_ sectionID: String) {
        withAnimation(.easeInOut(duration: 0.22)) {
            switch sectionID {
            case ProjectsTimeSectionHeader.activeID:
                activeProjectsExpanded.toggle()
            case ProjectsTimeSectionHeader.inactiveResolvedID:
                showDormantProjects.toggle()
            default:
                return
            }
        }
        dismissMessageReadout()
        pruneSelectionAfterSectionToggle(sectionID: sectionID)
    }

    private func pruneSelectionAfterSectionToggle(sectionID: String) {
        guard let rows = currentSnapshot?.visibleRows else { return }
        if sectionID == ProjectsTimeSectionHeader.activeID, !activeProjectsExpanded {
            subtractKeysFromSelection(
                Set(rows.filter(isActiveTimeSectionRow).map(\.projectKey))
            )
        }
        if sectionID == ProjectsTimeSectionHeader.inactiveResolvedID, !showDormantProjects {
            subtractKeysFromSelection(
                Set(rows.filter(Self.isDormantTimeSectionRow).map(\.projectKey))
            )
        }
    }

    private func subtractKeysFromSelection(_ keys: Set<String>) {
        selectedProjectKeys.subtract(keys)
        if let anchor = selectionAnchorKey, keys.contains(anchor) {
            selectionAnchorKey = selectedProjectKeys.first
        }
    }

    private func isActiveTimeSectionRow(_ row: ProjectRow) -> Bool {
        !Self.isDormantTimeSectionRow(row)
    }

    private static func isDormantTimeSectionRow(_ row: ProjectRow) -> Bool {
        row.status == .resolved
            || row.status == .quiet
            || row.lifecycleAssessment.state == .inactive
    }

    var retrievalAllowedMessageIDs: [String] {
        if let projectKey = selectedMode.linksProjectKey,
           let snapshot = currentSnapshot,
           let row = snapshot.projectDefinitionRow(for: projectKey)
                ?? workroomAnchorRow.flatMap({ $0.projectKey == projectKey ? $0 : nil }) {
            return Array(Set(snapshot.filteredMarks(in: row).map { $0.messageID.uuidString })).sorted()
        }
        return currentSnapshot?.allowedMessageIDs(selectedProjectKeys: selectedProjectKeys) ?? []
    }

    var visibleRows: [ProjectRow] {
        currentSnapshot?.visibleRows ?? []
    }
}
