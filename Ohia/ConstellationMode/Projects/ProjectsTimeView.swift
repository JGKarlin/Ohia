import AppKit
import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

// Projects is a SwiftUI/Canvas workspace. The normal Metal scene should not mount for `.projects`.

struct ProjectsTimeSectionHeader: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
    /// Every section header renders a disclosure chevron, toggles its
    /// persistent open/closed state on click or Space (while the pointer is
    /// anywhere over that section's band or rows), and reflects that state
    /// here. The two hover-disclosed sections additionally peek open on pointer
    /// hover — that lives in the Time view's hover handler, not on the header.
    var isExpanded: Bool = true
    var showsDisclosure: Bool = false

    nonisolated static let draftsID = "drafts"
    nonisolated static let activeID = "active"
    nonisolated static let inactiveResolvedID = "inactive-resolved"
}

enum ProjectsTimeDisplayEntry: Identifiable, Equatable {
    case section(ProjectsTimeSectionHeader)
    case draft(ProjectConfigurationDraftRow)
    case row(ProjectRow)

    var id: String {
        switch self {
        case .section(let header):
            return "section:\(header.id)"
        case .draft(let draft):
            return "draft:\(draft.id.uuidString.lowercased())"
        case .row(let row):
            return "row:\(row.projectKey)"
        }
    }

    var isSection: Bool {
        if case .section = self { return true }
        return false
    }
}

struct ProjectsTimeEntryLayout: Equatable {
    private static let minimumEntryHeight: CGFloat = 64
    // 116 lets a modest project list stretch to fill the canvas — a Gantt
    // surface with a dead band under its last row reads unfinished. Dense
    // mailboxes still compress toward the 64pt floor via containerHeight /
    // rowCount.
    private static let maximumRelaxedEntryHeight: CGFloat = 116
    /// Section bands are fixed-height labels, not data rows — they never
    /// stretch with the relaxed row height, so the canvas has no dead bands.
    static let sectionHeaderHeight: CGFloat = 34
    private static let rowHorizontalPadding: CGFloat = 24
    private static let rowTrailingSpacerReservation: CGFloat = 12
    private static let rowVerticalPadding: CGFloat = 18
    private static let titleFontSize: CGFloat = 14
    private static let activitySpanLineHeight: CGFloat = 15
    private static let correspondentsLineHeight: CGFloat = 15
    private static let cardLineSpacing: CGFloat = 4

    private let framesByEntryID: [String: CGRect]
    private let rowCentersByProjectKey: [String: CGFloat]
    let contentHeight: CGFloat

    static func make(
        entries: [ProjectsTimeDisplayEntry],
        containerHeight: CGFloat,
        gutterWidth: CGFloat = ProjectsTimeLayoutMetrics.gutterWidth
    ) -> ProjectsTimeEntryLayout {
        let sectionCount = entries.filter(\.isSection).count
        let rowCount = entries.count - sectionCount
        let baselineHeight = baselineEntryHeight(
            containerHeight: containerHeight - CGFloat(sectionCount) * sectionHeaderHeight,
            rowCount: rowCount
        )
        var frames: [String: CGRect] = [:]
        var centers: [String: CGFloat] = [:]
        var y: CGFloat = 0

        for entry in entries {
            let height: CGFloat
            switch entry {
            case .section:
                height = sectionHeaderHeight
            case .draft:
                height = baselineHeight
            case .row(let row):
                height = max(
                    baselineHeight,
                    requiredGutterRowHeight(for: row, gutterWidth: gutterWidth)
                )
            }
            frames[entry.id] = CGRect(x: 0, y: y, width: gutterWidth, height: height)
            if case .row(let row) = entry {
                centers[row.projectKey] = y + height / 2
            }
            y += height
        }

        return ProjectsTimeEntryLayout(
            framesByEntryID: frames,
            rowCentersByProjectKey: centers,
            contentHeight: y
        )
    }

    func frame(for entry: ProjectsTimeDisplayEntry) -> CGRect {
        framesByEntryID[entry.id] ?? CGRect(
            x: 0,
            y: 0,
            width: ProjectsTimeLayoutMetrics.gutterWidth,
            height: ProjectsTimeLayoutMetrics.defaultRowHeight
        )
    }

    func height(for entry: ProjectsTimeDisplayEntry) -> CGFloat {
        frame(for: entry).height
    }

    func centerY(forProjectKey projectKey: String) -> CGFloat? {
        rowCentersByProjectKey[projectKey]
    }

    /// Height the Front Page-register card needs: the fully wrapped measured
    /// title, the activity span line, and the correspondents line, plus
    /// vertical padding. Rows never compress below their card.
    static func requiredGutterRowHeight(
        for row: ProjectRow,
        gutterWidth: CGFloat = ProjectsTimeLayoutMetrics.gutterWidth
    ) -> CGFloat {
        let textWidth = max(40, gutterWidth - rowHorizontalPadding - rowTrailingSpacerReservation)
        let titleHeight = measuredTitleHeight(row.displayLabel, width: textWidth)
        return ceil(
            titleHeight
                + cardLineSpacing + activitySpanLineHeight
                + cardLineSpacing + correspondentsLineHeight
                + rowVerticalPadding
        )
    }

    private static func baselineEntryHeight(containerHeight: CGFloat, rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return ProjectsTimeLayoutMetrics.defaultRowHeight }
        return max(
            minimumEntryHeight,
            min(maximumRelaxedEntryHeight, containerHeight / CGFloat(rowCount))
        )
    }

    private static func measuredTitleHeight(_ text: String, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let font = NSFont.systemFont(ofSize: titleFontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return max(font.ascender - font.descender + font.leading, ceil(rect.height))
    }
}

private enum ProjectsTimeScrollTarget {
    static func row(_ projectKey: String) -> String {
        "projects-time-row:\(projectKey)"
    }
}

/// Keeps the exact range boundaries visible while the shared calendar tick
/// renderer supplies the intermediate labels. The masks reserve each edge for
/// its boundary label so a nearby aligned tick cannot overprint it.
private struct ProjectsTimeBoundaryLabels: View {
    let range: ClosedRange<Date>
    let canvasWidth: CGFloat

    private static let edgeInset: CGFloat = 30
    private static let minimumMaskWidth: CGFloat = 58
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(
                    width: ProjectsTimeLayoutMetrics.gutterWidth,
                    height: ProjectsTimeAxisHeader.bandHeight
                )

            Canvas { context, size in
                drawBoundaries(context: &context, size: size)
            }
            .frame(width: max(1, canvasWidth), height: ProjectsTimeAxisHeader.bandHeight)
        }
        .frame(height: ProjectsTimeAxisHeader.bandHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawBoundaries(context: inout GraphicsContext, size: CGSize) {
        let projectedWidth = max(1, size.width - ProjectsTimeLayoutMetrics.pipColumnInset)
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        let lowerLabel = Self.label(for: range.lowerBound, span: span)
        let upperLabel = Self.label(for: range.upperBound, span: span)
        let lowerMaskWidth = Self.maskWidth(for: lowerLabel)
        let upperMaskWidth = Self.maskWidth(for: upperLabel)

        context.fill(
            Path(CGRect(x: 0, y: 1, width: lowerMaskWidth, height: max(0, size.height - 2))),
            with: .color(OhiaColors.glassPanel)
        )
        context.fill(
            Path(
                CGRect(
                    x: max(0, projectedWidth - upperMaskWidth),
                    y: 1,
                    width: upperMaskWidth,
                    height: max(0, size.height - 2)
                )
            ),
            with: .color(OhiaColors.glassPanel)
        )

        drawBoundary(
            context: &context,
            x: 0,
            labelX: min(Self.edgeInset, projectedWidth / 2),
            label: lowerLabel,
            height: size.height
        )
        drawBoundary(
            context: &context,
            x: projectedWidth,
            labelX: max(projectedWidth / 2, projectedWidth - Self.edgeInset),
            label: upperLabel,
            height: size.height
        )
    }

    private func drawBoundary(
        context: inout GraphicsContext,
        x: CGFloat,
        labelX: CGFloat,
        label: String,
        height: CGFloat
    ) {
        var path = Path()
        path.move(to: CGPoint(x: x, y: height - 7))
        path.addLine(to: CGPoint(x: x, y: height))
        context.stroke(path, with: .color(OhiaColors.glassBorder), lineWidth: 1)
        context.draw(
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(OhiaColors.textPrimary),
            at: CGPoint(x: labelX, y: 10)
        )
    }

    private static func maskWidth(for label: String) -> CGFloat {
        let width = (label as NSString).size(withAttributes: [.font: labelFont]).width
        return max(minimumMaskWidth, width + 14)
    }

    private static func label(for date: Date, span: TimeInterval) -> String {
        if span < 86_400 {
            return timeFormatter.string(from: date)
        }
        if span >= 330 * 86_400 {
            return yearDateFormatter.string(from: date)
        }
        return dayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let yearDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMy")
        return formatter
    }()
}

struct ProjectsTimeView: View {
    @Bindable var workspace: ProjectsWorkspaceState
    let snapshot: ProjectsSnapshot
    /// The authoritative range selected by the shared Moments filter. A nil
    /// value means All Time, whose natural project-evidence extent is used.
    let momentsRange: ClosedRange<Date>?
    let projectDraft: ProjectConfigurationDraftRow?
    let summaryByMessageId: [String: String]
    let summaryUnavailableReasonByMessageId: [String: String]
    let summaryUnavailableMessageIds: Set<String>
    let regeneratingSummaryMessageIds: Set<String>
    let modelContext: ModelContext
    let projectSummaryService: ProjectSummaryService
    let projectSummaryUserIdentity: SummarizationUserIdentity?
    let onPresentMessageMenu: (UUID, NSPoint, NSView) -> Void
    let onPresentRowMenu: (ProjectRow, NSPoint, NSView) -> Void
    /// Commit an inline project rename: `(projectKey, newName)`. An empty
    /// Empty names are rejected by the manual-project repository.
    let onCommitRename: (String, String) -> Bool
    /// Dismiss the inline rename editor without persisting a change.
    let onCancelRename: () -> Void
    /// Open the in-place editor for a new manual project.
    let onCreateProject: () -> Void
    /// Resume the singleton manual-project draft from its project-column row.
    let onOpenProjectDraft: () -> Void
    /// Ask the workspace to confirm deletion of the singleton draft.
    let onDeleteProjectDraft: (ProjectConfigurationDraftRow) -> Void
    /// Shared send-to-Composer dispatch coordinator, read by the comet overlay to
    /// launch a comet from each queued message's dot when a send fires.
    let composerDispatch: ComposerDispatchCoordinator

    @State private var hitTester = ProjectsHitTester()
    @State private var scrollContentMinY: CGFloat = 0
    // Defers row-focus toggles by the system double-click interval so
    // a fast second click can cancel the toggle and upgrade to the
    // Links drill-in. Message-dot single clicks (which pin the
    // readout) fire immediately — they're not part of the double-tap
    // pattern.
    @State private var pendingRowTapWorkItem: DispatchWorkItem?
    // Pinch zoom scales relative to the projection window captured at
    // gesture start; cleared on gesture end so the next pinch re-bases.
    @State private var magnifyBaseRange: ClosedRange<Date>?

    private static let gutterWidth: CGFloat = ProjectsTimeLayoutMetrics.gutterWidth
    /// Manual zoom can't narrow below this span — beyond it the axis stops
    /// conveying correspondence structure.
    private static let minimumZoomSpan: TimeInterval = 6 * 3600

    var body: some View {
        GeometryReader { proxy in
            let allRows = snapshot.displayedRows()
            let entries = Self.displayEntries(
                from: allRows,
                projectDraft: projectDraft,
                showActiveProjects: workspace.activeProjectsExpanded,
                showDormantProjects: workspace.showDormantProjects
            )
            // Only rows that actually appear in the entry list drive the
            // projection range, density tier, and ⇧-range ordering —
            // collapsed inactive rows must not stretch the axis.
            let rows = entries.compactMap { entry -> ProjectRow? in
                if case .row(let row) = entry { return row }
                return nil
            }
            let scopeRange = Self.projectionScopeRange(momentsRange: momentsRange, rows: rows)
            let projectionRange = Self.currentProjectionRange(
                workspace: workspace,
                fullRange: scopeRange
            )
            let headerHeight = ProjectsTimeAxisHeader.bandHeight
            let scrollHeight = max(0, proxy.size.height - headerHeight)
            let layout = ProjectsTimeEntryLayout.make(
                entries: entries,
                containerHeight: scrollHeight,
                gutterWidth: Self.gutterWidth
            )
            let contentHeight = max(
                scrollHeight,
                layout.contentHeight
            )
            let canvasWidth = max(0, proxy.size.width - Self.gutterWidth)
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ProjectsTimeAxisHeader(
                        row: workspace.timeZoomRange == nil ? workspace.focusedRow : nil,
                        canvasWidth: canvasWidth,
                        explicitRange: workspace.timeZoomRange,
                        fallbackRange: scopeRange
                    )

                    // At the top-level overview, keep both range endpoints
                    // explicit while the axis header labels the intervening
                    // calendar divisions. Focused sub-day rows retain their
                    // single centered activity label.
                    if workspace.focusedRow == nil || workspace.timeZoomRange != nil {
                        ProjectsTimeBoundaryLabels(
                            range: projectionRange,
                            canvasWidth: canvasWidth
                        )
                    }
                }

                ScrollViewReader { scrollProxy in
                    ZStack(alignment: .topLeading) {
                        ScrollView(.vertical) {
                            HStack(spacing: 0) {
                                gutterColumn(
                                    entries: entries,
                                    layout: layout,
                                    rows: rows,
                                    contentHeight: contentHeight
                                )

                                ZStack(alignment: .topLeading) {
                                    Canvas { context, size in
                                        draw(
                                            context: &context,
                                            size: size,
                                            entries: entries,
                                            rows: rows,
                                            layout: layout,
                                            automaticRange: scopeRange
                                        )
                                    }
                                    .frame(height: contentHeight)
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onEnded { value in
                                                handleTap(at: value.location)
                                            }
                                    )
                                    .simultaneousGesture(
                                        MagnifyGesture()
                                            .onChanged { value in
                                                handleMagnify(
                                                    magnification: value.magnification,
                                                    // The projection maps dates onto the canvas
                                                    // minus the trailing pip column; anchor on
                                                    // the same width or zoom drifts at the
                                                    // right edge.
                                                    anchorFraction: value.startLocation.x
                                                        / max(1, canvasWidth - ProjectsTimeLayoutMetrics.pipColumnInset),
                                                    fullRange: scopeRange
                                                )
                                            }
                                            .onEnded { _ in
                                                magnifyBaseRange = nil
                                            }
                                    )
                                    .onContinuousHover { phase in
                                        handleHover(phase)
                                    }
                                    .background(
                                        TimelineEventCatcher(
                                            onHorizontalScroll: { deltaX, _ in
                                                handleHorizontalPan(
                                                    deltaX: deltaX,
                                                    canvasWidth: canvasWidth,
                                                    fullRange: scopeRange
                                                )
                                            },
                                            // Consume horizontal swipes only while a zoom
                                            // window exists — with nothing to pan they pass
                                            // through untouched.
                                            isHorizontalScrollActive: workspace.timeZoomRange != nil,
                                            onRightClick: { point, view in
                                                handleRightClick(point: point, view: view)
                                            },
                                            onDoubleClick: { point, _ in
                                                handleDoubleClick(at: point)
                                            }
                                        )
                                    )

                                    // At-rest pip-column obligation indicator.
                                    // Lives in the same scroll content as the canvas
                                    // so it tracks vertically with the rows. Sized to
                                    // match the canvas; positions one pip column per
                                    // row at the trailing edge.
                                    ProjectsObligationOverlay(
                                        entries: entries,
                                        layout: layout
                                    )
                                    .frame(height: contentHeight)

                                    // Send-to-Composer comet: launches from each
                                    // queued message's dot (rects recorded in the
                                    // shared hit tester during the canvas draw, same
                                    // content coordinate space) toward the Composer.
                                    ProjectsComposerDispatchOverlay(
                                        coordinator: composerDispatch,
                                        hitTester: hitTester,
                                        viewportSize: CGSize(width: canvasWidth, height: scrollHeight)
                                    )
                                    .frame(height: contentHeight)
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                selectionRingOverlay(entries: entries, layout: layout)
                            }
                            .onContinuousHover { phase in
                                handleSectionHover(phase, entries: entries, layout: layout)
                            }
                            .frame(minHeight: scrollHeight, alignment: .top)
                        }
                        .onScrollGeometryChange(for: CGFloat.self) { geometry in
                            -geometry.visibleRect.minY
                        } action: { _, minY in
                            scrollContentMinY = minY
                        }
                        .onAppear {
                            handleTimeFocusRequest(
                                workspace.timeFocusRequest,
                                scrollProxy: scrollProxy,
                                rows: rows,
                                layout: layout,
                                canvasWidth: canvasWidth
                            )
                        }
                        .onChange(of: workspace.timeFocusRequest) { _, request in
                            handleTimeFocusRequest(
                                request,
                                scrollProxy: scrollProxy,
                                rows: rows,
                                layout: layout,
                                canvasWidth: canvasWidth
                            )
                        }
                        .onChange(of: workspace.showDormantProjects) { _, _ in
                            handleTimeFocusRequest(
                                workspace.timeFocusRequest,
                                scrollProxy: scrollProxy,
                                rows: rows,
                                layout: layout,
                                canvasWidth: canvasWidth
                            )
                        }
                        .onChange(of: workspace.activeProjectsExpanded) { _, _ in
                            handleTimeFocusRequest(
                                workspace.timeFocusRequest,
                                scrollProxy: scrollProxy,
                                rows: rows,
                                layout: layout,
                                canvasWidth: canvasWidth
                            )
                        }
                        // Selecting a row zooms the axis to its span — bring
                        // the selected row fully into view.
                        .onChange(of: workspace.focusedProjectKey) { _, key in
                            guard let key else { return }
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.24)) {
                                    scrollProxy.scrollTo(ProjectsTimeScrollTarget.row(key), anchor: .center)
                                }
                            }
                        }

                        ProjectsMessageReadoutOverlay(
                            workspace: workspace,
                            snapshot: snapshot,
                            viewportSize: CGSize(width: proxy.size.width, height: scrollHeight),
                            scrollContentMinY: scrollContentMinY,
                            summaryByMessageId: summaryByMessageId,
                            summaryUnavailableReasonByMessageId: summaryUnavailableReasonByMessageId,
                            summaryUnavailableMessageIds: summaryUnavailableMessageIds,
                            regeneratingSummaryMessageIds: regeneratingSummaryMessageIds,
                            modelContext: modelContext
                        )
                        .frame(width: proxy.size.width, height: scrollHeight, alignment: .topLeading)
                        // Hit-testable whenever a readout is mounted (not
                        // just pinned): the ephemeral hover card must take
                        // the pointer so it survives hover and its controls
                        // work.
                        // Only the card's own content shape intercepts; the
                        // overlay's empty area still passes through.
                        .allowsHitTesting(workspace.messageReadout != nil)
                    }
                }
            }
            .onDisappear {
                workspace.hoveredTimeSectionID = nil
                // Sections keep whatever open/closed state the user set — no
                // hover state to reset. A section left collapsed still drops
                // the selection of any row inside it so an off-screen row can't
                // keep driving the axis zoom on return.
                if !workspace.showDormantProjects { clearDormantProjectSelection() }
                if !workspace.activeProjectsExpanded { clearActiveProjectSelection() }
            }
        }
    }

    /// Full-width selection ring: a selected project reads as one card
    /// spanning the gutter card and its Gantt lane — a hairline accent
    /// border wrapped in a visible accent aura, the same register as the
    /// Meaning / People focus cards. A `.shadow` cannot produce that halo
    /// here: shadow brightness scales with the caster's alpha mass, and a
    /// 1pt hairline diluted over a 12–36pt blur is invisible (the locked
    /// card's aura works because its caster is a large opaque card). The
    /// neon technique instead layers blurred strokes of the ring itself —
    /// a wide soft pass and a tight bright pass — under the crisp border.
    @ViewBuilder
    private func selectionRingOverlay(
        entries: [ProjectsTimeDisplayEntry],
        layout: ProjectsTimeEntryLayout
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(entries) { entry in
                if case .row(let row) = entry,
                   workspace.selectedProjectKeys.contains(row.projectKey) {
                    let frame = layout.frame(for: entry)
                    let shape = RoundedRectangle(cornerRadius: 10)
                    ZStack {
                        shape
                            .stroke(OhiaColors.chipActiveBorder.opacity(0.40), lineWidth: 10)
                            .blur(radius: 12)
                        shape
                            .stroke(OhiaColors.chipActiveBorder.opacity(0.70), lineWidth: 3.5)
                            .blur(radius: 3.5)
                        shape
                            .strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1)
                    }
                    .padding(.horizontal, 4)
                    .frame(height: max(0, frame.height - 6))
                    .offset(y: frame.minY + 3)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// The left project-list column (row headlines + inline rename editor).
    /// Extracted from `body` so the Time view's large view tree stays within
    /// the Swift type-checker's complexity budget.
    @ViewBuilder
    private func gutterColumn(
        entries: [ProjectsTimeDisplayEntry],
        layout: ProjectsTimeEntryLayout,
        rows: [ProjectRow],
        contentHeight: CGFloat
    ) -> some View {
        ProjectsTimeGutter(
            entries: entries,
            layout: layout,
            userAddresses: snapshot.userAddresses,
            onSelect: { key, modifiers in
                handleRowSelection(
                    projectKey: key,
                    modifiers: modifiers,
                    orderedKeys: rows.map(\.projectKey)
                )
            },
            onActivate: { key in
                // Drilling into a project's Links commits to showing it: expand
                // its section so the row stays visible (and selected) on the
                // return trip. Active rows need nothing — Active defaults open.
                if let row = snapshot.visibleRows.first(where: { $0.projectKey == key }) {
                    if Self.belongsInDormantSection(row) {
                        workspace.showDormantProjects = true
                    }
                }
                workspace.openLinksFor(key)
            },
            onRightClick: { key, point, view in
                handleGutterRightClick(projectKey: key, point: point, view: view)
            },
            onToggleSection: { sectionID in
                workspace.toggleTimeSection(sectionID)
            },
            onCreateProject: onCreateProject,
            canCreateProject: projectDraft == nil,
            onOpenProjectDraft: onOpenProjectDraft,
            onDeleteProjectDraft: onDeleteProjectDraft,
            renamingProjectKey: workspace.renamingProjectKey,
            renameMutationFailureActive: workspace.projectMutationFailure != nil,
            onCommitRename: onCommitRename,
            onCancelRename: onCancelRename
        )
        .frame(width: Self.gutterWidth, height: contentHeight, alignment: .top)
        // Opaque plate: the project list column sits on solid ground, not the
        // starfield — only the Gantt canvas is sky-backed.
        .background(OhiaColors.glassPanel)
        .background(OhiaColors.spaceBackground)
    }

    nonisolated static func displayEntries(
        from rows: [ProjectRow],
        projectDraft: ProjectConfigurationDraftRow? = nil,
        showActiveProjects: Bool,
        showDormantProjects: Bool
    ) -> [ProjectsTimeDisplayEntry] {
        let dormantRows = rows
            .filter(belongsInDormantSection)
            .sorted(by: dormantActivitySort)
        let dormantKeys = Set(dormantRows.map(\.projectKey))
        let activeRows = rows.filter { dormantKeys.contains($0.projectKey) == false }
        var entries: [ProjectsTimeDisplayEntry] = []
        if let projectDraft {
            entries.append(
                .section(
                    ProjectsTimeSectionHeader(
                        id: ProjectsTimeSectionHeader.draftsID,
                        title: "Drafts",
                        count: 1
                    )
                )
            )
            entries.append(.draft(projectDraft))
        }
        entries.append(
            .section(
                ProjectsTimeSectionHeader(
                    id: ProjectsTimeSectionHeader.activeID,
                    title: "Active projects",
                    count: activeRows.count,
                    isExpanded: showActiveProjects,
                    showsDisclosure: true
                )
            )
        )
        if showActiveProjects {
            entries += activeRows.map(ProjectsTimeDisplayEntry.row)
        }
        entries.append(
            .section(
                ProjectsTimeSectionHeader(
                    id: ProjectsTimeSectionHeader.inactiveResolvedID,
                    title: "Inactive / resolved projects",
                    count: dormantRows.count,
                    isExpanded: showDormantProjects,
                    showsDisclosure: true
                )
            )
        )
        if showDormantProjects {
            entries += dormantRows.map(ProjectsTimeDisplayEntry.row)
        }
        return entries
    }

    nonisolated static func selectableProjectKeys(
        in entries: [ProjectsTimeDisplayEntry]
    ) -> [String] {
        entries.compactMap { entry in
            if case .row(let row) = entry { return row.projectKey }
            return nil
        }
    }

    /// Maps a Y coordinate in the shared gutter/canvas scroll content to the
    /// section it belongs to — header band or any row nested under that header.
    nonisolated static func sectionID(
        atY y: CGFloat,
        entries: [ProjectsTimeDisplayEntry],
        layout: ProjectsTimeEntryLayout
    ) -> String? {
        var currentSectionID: String?
        for entry in entries {
            let frame = layout.frame(for: entry)
            switch entry {
            case .section(let header):
                currentSectionID = header.showsDisclosure ? header.id : nil
                if y >= frame.minY, y < frame.maxY, let currentSectionID {
                    return currentSectionID
                }
            case .draft, .row:
                if y >= frame.minY, y < frame.maxY {
                    return currentSectionID
                }
            }
        }
        return nil
    }

    private func clearDormantProjectSelection() {
        let dormantKeys = Set(
            snapshot.visibleRows
                .filter(Self.belongsInDormantSection)
                .map(\.projectKey)
        )
        workspace.selectedProjectKeys.subtract(dormantKeys)
        if let anchor = workspace.selectionAnchorKey, dormantKeys.contains(anchor) {
            workspace.selectionAnchorKey = workspace.selectedProjectKeys.first
        }
    }

    /// Collapsing Active projects drops its rows from the selection for the
    /// same reason the other sections do — an off-screen selected row would
    /// keep driving the axis zoom and focus strip.
    private func clearActiveProjectSelection() {
        let activeKeys = Set(
            snapshot.visibleRows
                .filter { !Self.belongsInDormantSection($0) }
                .map(\.projectKey)
        )
        workspace.selectedProjectKeys.subtract(activeKeys)
        if let anchor = workspace.selectionAnchorKey, activeKeys.contains(anchor) {
            workspace.selectionAnchorKey = workspace.selectedProjectKeys.first
        }
    }

    private nonisolated static func belongsInDormantSection(_ row: ProjectRow) -> Bool {
        row.status == .resolved
            || row.status == .quiet
            || row.lifecycleAssessment.state == .inactive
    }

    private nonisolated static func dormantActivitySort(_ lhs: ProjectRow, _ rhs: ProjectRow) -> Bool {
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        if lhs.messageIDs.count != rhs.messageIDs.count {
            return lhs.messageIDs.count > rhs.messageIDs.count
        }
        return lhs.displayLabel.localizedStandardCompare(rhs.displayLabel) == .orderedAscending
    }

    private func draw(
        context: inout GraphicsContext,
        size: CGSize,
        entries: [ProjectsTimeDisplayEntry],
        rows: [ProjectRow],
        layout: ProjectsTimeEntryLayout,
        automaticRange: ClosedRange<Date>
    ) {
        hitTester.reset()
        // Projection precedence: a manual zoom window (pinch / horizontal
        // scroll / ⌘+⌘−) wins, then a *focused* row's activity span, then
        // the whole-scope range. Hover deliberately does not re-project the
        // canvas — it only previews dates in the header — so pointer travel
        // never silently re-maps every other row's dots. Non-focused rows
        // still draw under focus-zoom, but their out-of-range marks/
        // deadlines/arcs are skipped per-element so they don't pile up at
        // the clamped canvas edges.
        let range: ClosedRange<Date>
        if let zoom = workspace.timeZoomRange {
            range = zoom
        } else if let focused = workspace.focusedRow {
            range = ProjectsTimeAxisHeader.axisRange(for: focused)
        } else {
            range = automaticRange
        }
        // Narrow the projection by the pip-column inset so date→x mapping never
        // places marks (or deadline ticks, revival arcs, emergence markers, the
        // activity band) under the trailing pip column rendered by
        // `ProjectsObligationOverlay`. All renderer date mappings flow through
        // this single projection so they inherit the inset automatically.
        let projection = ProjectsTimeProjection(
            range: range,
            width: max(1, size.width - ProjectsTimeLayoutMetrics.pipColumnInset)
        )
        let density = ProjectsDensityTier.tier(forVisibleRowCount: rows.count)
        let now = Date.now
        drawRuler(context: &context, size: size, projection: projection)
        drawTodayLine(context: &context, size: size, projection: projection, now: now)
        var rowIndex = 0
        for entry in entries {
            let rect = CGRect(
                x: 0,
                y: layout.frame(for: entry).minY,
                width: size.width,
                height: layout.height(for: entry)
            )
            switch entry {
            case .section(let header):
                drawSectionDivider(context: &context, rect: rect, header: header)
            case .draft:
                drawDraftRowBackground(context: &context, rect: rect)
            case .row(let row):
                ProjectsTimeViewRowRenderer.draw(
                    row: row,
                    index: rowIndex,
                    isFocused: workspace.selectedProjectKeys.contains(row.projectKey),
                    hoveredTarget: workspace.hoveredTarget,
                    density: density,
                    now: now,
                    context: &context,
                    projection: projection,
                    rect: rect,
                    hitTester: hitTester
                )
                rowIndex += 1
            }
        }
    }

    private func drawDraftRowBackground(
        context: inout GraphicsContext,
        rect: CGRect
    ) {
        context.fill(Path(rect), with: .color(OhiaColors.surface(0.035)))
        var bottomPath = Path()
        bottomPath.move(to: CGPoint(x: rect.minX, y: rect.maxY - 0.5))
        bottomPath.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5))
        context.stroke(
            bottomPath,
            with: .color(OhiaColors.glassBorder.opacity(0.42)),
            lineWidth: 1
        )
    }


    /// The Gantt "now" hairline. Drawn under row content (rows paint after
    /// the ruler) so bars and dots stay legible over it. Only renders when
    /// the current moment falls inside the projected range — the axis never
    /// fabricates blank future space just to show a marker.
    private func drawTodayLine(
        context: inout GraphicsContext,
        size: CGSize,
        projection: ProjectsTimeProjection,
        now: Date
    ) {
        guard projection.contains(now) else { return }
        let x = projection.x(for: now)
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(
            path,
            with: .color(OhiaColors.chipActiveForeground.opacity(0.4)),
            lineWidth: 1
        )
    }

    private func drawSectionDivider(
        context: inout GraphicsContext,
        rect: CGRect,
        header: ProjectsTimeSectionHeader
    ) {
        let isActiveHeader = header.id == ProjectsTimeSectionHeader.activeID
        context.fill(
            Path(rect),
            with: .color(OhiaColors.surface(isActiveHeader ? 0.045 : 0.075))
        )
        if !isActiveHeader {
            let accentRect = CGRect(x: rect.minX, y: rect.minY, width: 4, height: rect.height)
            context.fill(Path(accentRect), with: .color(OhiaColors.textDim.opacity(0.9)))
        }
        // No label here: the gutter cell immediately to the left already
        // titles the section, and repeating it on the canvas read as a
        // duplicated header. The canvas band carries only fill + accent +
        // divider so the section still separates visually at full width.
        let bottomColor = isActiveHeader
            ? OhiaColors.glassBorder.opacity(0.58)
            : OhiaColors.glassBorder.opacity(0.86)
        var bottomPath = Path()
        bottomPath.move(to: CGPoint(x: rect.minX, y: rect.maxY - 0.5))
        bottomPath.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5))
        context.stroke(bottomPath, with: .color(bottomColor), lineWidth: 1)
    }

    private func drawRuler(context: inout GraphicsContext, size: CGSize, projection: ProjectsTimeProjection) {
        // Faint vertical guides at calendar boundaries — midnights, week
        // starts, and month starts — drawn through the shared projection.
        for tick in ProjectsTimeAxisTicks.ticks(in: projection.range) {
            let x = projection.x(for: tick.date)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(
                path,
                with: .color(OhiaColors.glassBorder.opacity(tick.isMajor ? 0.5 : 0.35)),
                lineWidth: 1
            )
        }
    }

    private static func expandedDateRange(rows: [ProjectRow]) -> ClosedRange<Date> {
        let activityDates = rows.flatMap { row in
            [row.firstActivityAt, row.lastActivityAt] + row.deadlineTicks.map(\.date)
        }
        let lower = activityDates.min() ?? Date.now.addingTimeInterval(-86_400)
        var upper = activityDates.max() ?? Date.now
        // Anchor the right edge at "now" when the scope is current (newest
        // evidence within two weeks) so the today hairline renders and
        // recent activity reads against it. Older/historical scopes keep
        // their evidence-bounded edge — no fabricated future space.
        let now = Date.now
        if upper < now, now.timeIntervalSince(upper) <= 14 * 86_400 {
            upper = now
        }
        let span = max(86_400, upper.timeIntervalSince(lower))
        let pad = span * 0.04
        return lower.addingTimeInterval(-pad) ... upper.addingTimeInterval(pad)
    }

    /// The shared Moments window is the top-level Projects scale. All Time is
    /// the only preset without an explicit bound, so it falls back to the
    /// visible projects' evidence extent.
    private static func projectionScopeRange(
        momentsRange: ClosedRange<Date>?,
        rows: [ProjectRow]
    ) -> ClosedRange<Date> {
        momentsRange ?? expandedDateRange(rows: rows)
    }

    private func scrollContentAnchor(fromCanvasPoint point: CGPoint) -> CGPoint {
        CGPoint(x: Self.gutterWidth + point.x, y: point.y)
    }

    private func scrollContentAnchor(from hit: ProjectsHitTester.MessageHit) -> CGPoint {
        scrollContentAnchor(fromCanvasPoint: CGPoint(x: hit.rect.midX, y: hit.rect.midY))
    }

    private func handleTimeFocusRequest(
        _ request: ProjectsTimeFocusRequest?,
        scrollProxy: ScrollViewProxy,
        rows: [ProjectRow],
        layout: ProjectsTimeEntryLayout,
        canvasWidth: CGFloat
    ) {
        guard let request else { return }
        guard rows.contains(where: { $0.projectKey == request.projectKey }) else {
            // A focus request can target a row inside a collapsed section
            // (citation click, Links pivot). Expand that section, then let
            // the layout change re-trigger this handler; the request stays
            // pending until it resolves. A target absent from the scope
            // entirely can never resolve; drop the request so it doesn't
            // stay pending forever.
            guard let target = snapshot.visibleRows.first(
                where: { $0.projectKey == request.projectKey }
            ) else {
                workspace.timeFocusRequest = nil
                return
            }
            if Self.belongsInDormantSection(target) {
                if !workspace.showDormantProjects {
                    workspace.showDormantProjects = true
                    return
                }
            } else if !workspace.activeProjectsExpanded {
                workspace.activeProjectsExpanded = true
                return
            }
            // The target's section is already expanded yet the row still
            // isn't displayed — unresolvable.
            workspace.timeFocusRequest = nil
            return
        }
        let requestSequence = request.sequence
        if let anchor = timeFocusAnchor(
            for: request,
            rows: rows,
            layout: layout,
            canvasWidth: canvasWidth
        ) {
            workspace.showMessageReadout(
                messageID: request.messageID,
                anchorPoint: anchor,
                pin: request.pinReadout
            )
        }
        DispatchQueue.main.async {
            // The request stays pending until the centering scroll settles:
            // `onScrollGeometryChange` re-runs the hover handler on every
            // animation frame with the retained pointer, and clearing the
            // request at scroll start would let those frames collapse the
            // section under the target row and dismiss the just-pinned
            // readout mid-flight.
            withAnimation(.easeInOut(duration: 0.24), completionCriteria: .removed) {
                scrollProxy.scrollTo(ProjectsTimeScrollTarget.row(request.projectKey), anchor: .center)
            } completion: {
                if workspace.timeFocusRequest?.sequence == requestSequence {
                    workspace.timeFocusRequest = nil
                }
            }
        }
    }

    private func timeFocusAnchor(
        for request: ProjectsTimeFocusRequest,
        rows: [ProjectRow],
        layout: ProjectsTimeEntryLayout,
        canvasWidth: CGFloat
    ) -> CGPoint? {
        guard let row = rows.first(where: { $0.projectKey == request.projectKey }) else {
            return nil
        }
        // The lane spine sits mid-row; dots offset above (received) or
        // below (sent) the spine.
        let rowFrame = layout.frame(for: .row(row))
        let laneY = rowFrame.midY
        guard let mark = row.marks.first(where: { $0.messageID == request.messageID }) else {
            let x = min(max(Self.gutterWidth + 120, Self.gutterWidth + 24), Self.gutterWidth + canvasWidth - 24)
            return CGPoint(x: x, y: laneY)
        }
        let projection = ProjectsTimeProjection(
            range: ProjectsTimeAxisHeader.axisRange(for: row),
            width: max(1, canvasWidth - ProjectsTimeLayoutMetrics.pipColumnInset)
        )
        let radius = ProjectsTimeViewRowRenderer.markRadius
        let rawX = projection.x(for: mark.date)
        let x = min(
            canvasWidth - ProjectsTimeLayoutMetrics.pipColumnInset - radius,
            max(radius, rawX)
        )
        let y = mark.isSentByUser
            ? laneY + ProjectsTimeViewRowRenderer.markLaneOffset
            : laneY - ProjectsTimeViewRowRenderer.markLaneOffset
        return CGPoint(x: Self.gutterWidth + x, y: y)
    }

    private func handleTap(at point: CGPoint) {
        // Cancel any prior pending row-tap effect. If the user is
        // mid-double-click, the second click's mouseDown is consumed
        // upstream by TimelineEventCatcher → handleDoubleClick, which
        // also cancels this work item; canceling here covers the case
        // where two separate clicks landed inside the system
        // double-click interval but on different rows.
        pendingRowTapWorkItem?.cancel()
        pendingRowTapWorkItem = nil

        // Message-dot single clicks fire immediately: pinning the
        // readout is the canonical single-click interaction and there
        // is no double-click ambiguity on a dot (per-message double
        // navigation isn't defined).
        if let hit = hitTester.message(at: point) {
            workspace.focusMessage(hit.messageID, projectKey: hit.projectKey)
            workspace.showMessageReadout(
                messageID: hit.messageID,
                anchorPoint: scrollContentAnchor(from: hit),
                pin: true
            )
            return
        }

        // Row hits route through the modifier-aware selection
        // handler. Plain clicks still debounce so a fast second
        // click can promote to the Links drill-in; ⌘ / ⇧ clicks
        // fire immediately and never upgrade.
        if let rowHit = hitTester.row(at: point) {
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            let orderedKeys = snapshot
                .displayedRows()
                .map(\.projectKey)
            if modifiers.contains(.command) || modifiers.contains(.shift) {
                handleRowSelection(
                    projectKey: rowHit.projectKey,
                    modifiers: modifiers,
                    orderedKeys: orderedKeys
                )
                workspace.dismissMessageReadout()
                return
            }
            let projectKey = rowHit.projectKey
            let workItem = DispatchWorkItem {
                MainActor.assumeIsolated {
                    handleRowSelection(
                        projectKey: projectKey,
                        modifiers: [],
                        orderedKeys: orderedKeys
                    )
                    workspace.dismissMessageReadout()
                }
            }
            pendingRowTapWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + NSEvent.doubleClickInterval,
                execute: workItem
            )
        }
    }

    /// Modifier-aware row selection. Plain click toggles the row in
    /// or out of being the lone selection (mirrors the prior focus-
    /// toggle behavior); ⌘ toggles set membership; ⇧ extends the
    /// range from the current anchor.
    private func handleRowSelection(
        projectKey: String,
        modifiers: NSEvent.ModifierFlags,
        orderedKeys: [String]
    ) {
        if modifiers.contains(.shift) {
            workspace.extendSelection(to: projectKey, in: orderedKeys)
        } else if modifiers.contains(.command) {
            workspace.toggleSelection(projectKey)
        } else if workspace.selectedProjectKeys == [projectKey] {
            workspace.clearSelection()
            workspace.timeZoomRange = nil
        } else {
            // Plain-click focus means "show me this project" — drop any
            // manual zoom so the focus-fit projection actually lands.
            workspace.focusProject(projectKey)
            workspace.timeZoomRange = nil
        }
    }

    // MARK: Manual axis zoom / pan

    /// Rows that actually appear in the Time view's entry list under the
    /// current toggles — the shared basis for the projection range across
    /// gestures, keyboard zoom, and the body's layout pass.
    static func visibleProjectionRows(
        snapshot: ProjectsSnapshot,
        workspace: ProjectsWorkspaceState
    ) -> [ProjectRow] {
        displayEntries(
            from: snapshot.displayedRows(),
            showActiveProjects: workspace.activeProjectsExpanded,
            showDormantProjects: workspace.showDormantProjects
        )
        .compactMap { entry -> ProjectRow? in
            if case .row(let row) = entry { return row }
            return nil
        }
    }

    /// The window the canvas is currently projecting — manual zoom, else
    /// the focused row's span, else the whole scope. Gesture handlers
    /// re-base from this so zooming while focused starts from what the
    /// user is actually looking at.
    private static func currentProjectionRange(
        workspace: ProjectsWorkspaceState,
        fullRange: ClosedRange<Date>
    ) -> ClosedRange<Date> {
        if let zoom = workspace.timeZoomRange { return zoom }
        if let focused = workspace.focusedRow {
            return ProjectsTimeAxisHeader.axisRange(for: focused)
        }
        return fullRange
    }

    private func handleMagnify(
        magnification: CGFloat,
        anchorFraction: CGFloat,
        fullRange: ClosedRange<Date>
    ) {
        guard magnification.isFinite, magnification > 0 else { return }
        let base = magnifyBaseRange
            ?? Self.currentProjectionRange(workspace: workspace, fullRange: fullRange)
        if magnifyBaseRange == nil {
            magnifyBaseRange = base
        }
        workspace.timeZoomRange = Self.zoomWindow(
            current: base,
            full: fullRange,
            scale: magnification,
            anchorFraction: min(1, max(0, anchorFraction)),
            minimumSpan: Self.minimumZoomSpan
        )
    }

    private func handleHorizontalPan(
        deltaX: CGFloat,
        canvasWidth: CGFloat,
        fullRange: ClosedRange<Date>
    ) {
        // Panning only applies to an actual zoom window; the auto-fit view
        // has nowhere to pan to.
        guard let current = workspace.timeZoomRange else { return }
        let fraction = -deltaX / max(1, canvasWidth)
        workspace.timeZoomRange = Self.pannedWindow(
            current: current,
            full: fullRange,
            byFraction: fraction
        )
    }

    /// Keyboard zoom (⌘+ / ⌘−) around the window center. Callable from the
    /// workspace chrome, which owns the key handlers. ⌘0 resets by setting
    /// `timeZoomRange` to nil at the call site.
    @MainActor
    static func stepZoom(
        by scale: CGFloat,
        workspace: ProjectsWorkspaceState,
        snapshot: ProjectsSnapshot,
        momentsRange: ClosedRange<Date>?
    ) {
        let rows = visibleProjectionRows(snapshot: snapshot, workspace: workspace)
        let fullRange = projectionScopeRange(momentsRange: momentsRange, rows: rows)
        workspace.timeZoomRange = zoomWindow(
            current: currentProjectionRange(workspace: workspace, fullRange: fullRange),
            full: fullRange,
            scale: scale,
            anchorFraction: 0.5,
            minimumSpan: minimumZoomSpan
        )
    }

    /// Scale a window around an anchor, clamped inside `full`. Returns nil
    /// when the result covers the whole scope — the caller then falls back
    /// to the automatic fit rather than storing a redundant window.
    static func zoomWindow(
        current: ClosedRange<Date>,
        full: ClosedRange<Date>,
        scale: CGFloat,
        anchorFraction: CGFloat,
        minimumSpan: TimeInterval
    ) -> ClosedRange<Date>? {
        let currentSpan = current.upperBound.timeIntervalSince(current.lowerBound)
        let fullSpan = full.upperBound.timeIntervalSince(full.lowerBound)
        guard currentSpan > 0, fullSpan > 0 else { return nil }
        let newSpan = min(max(currentSpan / Double(scale), min(minimumSpan, fullSpan)), fullSpan)
        if newSpan >= fullSpan { return nil }
        let anchor = current.lowerBound.addingTimeInterval(currentSpan * Double(anchorFraction))
        var lower = anchor.addingTimeInterval(-newSpan * Double(anchorFraction))
        let maxLower = full.upperBound.addingTimeInterval(-newSpan)
        lower = max(full.lowerBound, min(lower, maxLower))
        return lower ... lower.addingTimeInterval(newSpan)
    }

    /// Shift a window sideways by a fraction of its own span, clamped
    /// inside `full`.
    static func pannedWindow(
        current: ClosedRange<Date>,
        full: ClosedRange<Date>,
        byFraction fraction: CGFloat
    ) -> ClosedRange<Date> {
        let span = current.upperBound.timeIntervalSince(current.lowerBound)
        guard span > 0 else { return current }
        var lower = current.lowerBound.addingTimeInterval(span * Double(fraction))
        let maxLower = full.upperBound.addingTimeInterval(-span)
        lower = max(full.lowerBound, min(lower, maxLower))
        return lower ... lower.addingTimeInterval(span)
    }

    private func handleSectionHover(
        _ phase: HoverPhase,
        entries: [ProjectsTimeDisplayEntry],
        layout: ProjectsTimeEntryLayout
    ) {
        switch phase {
        case .active(let point):
            workspace.hoveredTimeSectionID = Self.sectionID(
                atY: point.y,
                entries: entries,
                layout: layout
            )
        case .ended:
            workspace.hoveredTimeSectionID = nil
        }
    }

    private func handleHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let point):
            if let hit = hitTester.message(at: point) {
                workspace.hoveredTarget = .message(hit.messageID)
                if workspace.messageReadout?.isPinned != true {
                    workspace.showMessageReadout(
                        messageID: hit.messageID,
                        anchorPoint: scrollContentAnchor(from: hit),
                        pin: false
                    )
                } else if workspace.messageReadout?.messageID == hit.messageID {
                    var readout = workspace.messageReadout
                    readout?.anchorPoint = scrollContentAnchor(from: hit)
                    workspace.messageReadout = readout
                }
            } else if let hit = hitTester.row(at: point) {
                workspace.hoveredTarget = .row(hit.projectKey)
                workspace.scheduleEphemeralMessageReadoutDismissal()
            } else {
                workspace.hoveredTarget = nil
                workspace.scheduleEphemeralMessageReadoutDismissal()
            }
        case .ended:
            // Grace-delayed, not instant: entering the popup steals hover
            // from the canvas, and the readout must survive that hand-off
            // so the reader can interact with the card. The workspace
            // dismisses only once the pointer is over neither the dot nor
            // the popup.
            workspace.hoveredTarget = nil
            workspace.scheduleEphemeralMessageReadoutDismissal()
        }
    }

    /// Canvas double-click. Resolves the row under the cursor — a
    /// dot is part of its row, so dot double-clicks open Links for
    /// the row containing the dot. Cancels any pending row-tap work
    /// item so the first click's focus toggle never lands.
    private func handleDoubleClick(at point: CGPoint) {
        pendingRowTapWorkItem?.cancel()
        pendingRowTapWorkItem = nil
        let projectKey: String?
        if let messageHit = hitTester.message(at: point) {
            projectKey = messageHit.projectKey
        } else if let rowHit = hitTester.row(at: point) {
            projectKey = rowHit.projectKey
        } else {
            projectKey = nil
        }
        guard let key = projectKey else { return }
        workspace.openLinksFor(key)
    }

    private func handleRightClick(point: NSPoint, view: NSView) {
        if let hit = hitTester.message(at: point) {
            workspace.focusMessage(hit.messageID, projectKey: hit.projectKey)
            onPresentMessageMenu(hit.messageID, point, view)
            return
        }
        guard let hit = hitTester.row(at: point),
              let row = snapshot.visibleRows.first(where: { $0.projectKey == hit.projectKey }) else {
            return
        }
        // The presenter collapses selection to this one manual project before
        // showing its project-specific commands.
        onPresentRowMenu(row, point, view)
    }

    private func handleGutterRightClick(projectKey: String, point: NSPoint, view: NSView) {
        guard let row = snapshot.visibleRows.first(where: { $0.projectKey == projectKey }) else {
            return
        }
        onPresentRowMenu(row, point, view)
    }
}

private struct ProjectsTimeGutter: View {
    let entries: [ProjectsTimeDisplayEntry]
    let layout: ProjectsTimeEntryLayout
    /// Lowercased account / identity addresses of the local user, used to
    /// keep them off the correspondents line — their mailbox implies them.
    let userAddresses: Set<String>
    let onSelect: (String, NSEvent.ModifierFlags) -> Void
    let onActivate: (String) -> Void
    let onRightClick: (String, NSPoint, NSView) -> Void
    let onToggleSection: (String) -> Void
    let onCreateProject: () -> Void
    let canCreateProject: Bool
    let onOpenProjectDraft: () -> Void
    let onDeleteProjectDraft: (ProjectConfigurationDraftRow) -> Void
    /// The project whose title is being renamed inline (nil = none). That
    /// row swaps its static title for an editable field.
    let renamingProjectKey: String?
    /// Prevents the alert taking focus from retrying a rejected rename.
    let renameMutationFailureActive: Bool
    /// Commit the inline rename: `(projectKey, newName)`. Empty is rejected.
    let onCommitRename: (String, String) -> Bool
    /// Dismiss the inline editor without persisting.
    let onCancelRename: () -> Void

    // Inline rename editor state. Only one row edits at a time, so a single
    // draft / focus pair at the gutter level is sufficient. `renameActiveKey`
    // is a local guard so commit/cancel run exactly once per session even as
    // focus-loss (blur) and the parent's `renamingProjectKey` change race.
    @State private var renameDraft: String = ""
    @State private var renameActiveKey: String?
    @FocusState private var renameFieldFocused: Bool

    // Per-row tap debounce. SwiftUI's stacked `.onTapGesture(count:2)`
    // / `.onTapGesture(count:1)` does not reliably defer the single-
    // tap recognizer on macOS — both fire on a double-click, causing
    // the focus state to flicker before the Links drill-in lands.
    // Tracking the last tap timestamp + projectKey + a cancelable
    // single-tap work item gives us the same upgrade pattern as the
    // canvas (which uses NSEvent.clickCount via TimelineEventCatcher).
    @State private var pendingTapWorkItem: DispatchWorkItem?
    @State private var lastTap: (projectKey: String, time: Date)?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                switch entry {
                case .section(let header):
                    ProjectsTimeSectionDivider(
                        header: header,
                        // Every section header carries a chevron and toggles
                        // its persistent open state on click or space.
                        onToggle: header.showsDisclosure
                            ? { onToggleSection(header.id) }
                            : nil,
                        onCreateProject: header.id == ProjectsTimeSectionHeader.activeID
                            ? onCreateProject
                            : nil,
                        isCreateProjectEnabled: canCreateProject
                    )
                    .frame(height: layout.height(for: entry))
                case .draft(let draft):
                    ProjectDraftGutterRow(
                        draft: draft,
                        onOpen: onOpenProjectDraft,
                        onDelete: { onDeleteProjectDraft(draft) }
                    )
                    .frame(height: layout.height(for: entry))
                case .row(let row):
                    // Front Page card register: headline, activity span line,
                    // correspondents line. Selection is rendered by the
                    // full-width ring overlay in `ProjectsTimeView`, not here.
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            if renamingProjectKey == row.projectKey {
                                renameField(for: row)
                            } else {
                                Text(row.displayLabel)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(rowTextColor(row))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            activitySpanLine(row)
                            correspondentsLine(row)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: layout.height(for: entry))
                    .id(ProjectsTimeScrollTarget.row(row.projectKey))
                    .contentShape(Rectangle())
                    .background(
                        TimelineEventCatcher(
                            onRightClick: { point, view in
                                // While this row is being renamed, clicks belong
                                // to the editor — don't re-present the menu.
                                guard renamingProjectKey != row.projectKey else { return }
                                // Drop any debounced single-tap effect so
                                // the focus toggle does not fire moments
                                // after the menu closes on a tap-then-
                                // right-click sequence on the same row.
                                pendingTapWorkItem?.cancel()
                                pendingTapWorkItem = nil
                                lastTap = nil
                                onRightClick(row.projectKey, point, view)
                            }
                        )
                    )
                    // macOS `.onTapGesture` silently drops ⌘/⇧-held clicks, so
                    // multi-select needs explicit modified recognizers (see
                    // FrontPagePackageCard for the sanctioned pattern). Plain
                    // clicks still flow through the debounced handler below.
                    .gesture(
                        TapGesture().modifiers(.command).onEnded {
                            guard renamingProjectKey != row.projectKey else { return }
                            handleModifiedTap(rowKey: row.projectKey, modifiers: .command)
                        }
                    )
                    .gesture(
                        TapGesture().modifiers(.shift).onEnded {
                            guard renamingProjectKey != row.projectKey else { return }
                            handleModifiedTap(rowKey: row.projectKey, modifiers: .shift)
                        }
                    )
                    .onTapGesture {
                        guard renamingProjectKey != row.projectKey else { return }
                        handleTap(rowKey: row.projectKey)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(rowTooltip(row))
                    .accessibilityAction {
                        onSelect(row.projectKey, [])
                    }
                    .accessibilityAction(named: Text("Show Project Links")) {
                        onActivate(row.projectKey)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .onChange(of: renamingProjectKey) { _, newKey in
            seedRenameEditor(for: newKey)
        }
        // `.onChange` doesn't fire on mount when the value is unchanged, so a
        // gutter that re-mounts while a rename is already armed (fresh @State)
        // would otherwise show a dead, unseeded field. Seeding on appear too
        // makes the editor recover its draft + focus on any remount.
        .onAppear {
            seedRenameEditor(for: renamingProjectKey)
        }
    }

    // MARK: Inline rename

    /// Seed (or tear down) the inline editor when the parent arms/clears
    /// `renamingProjectKey`. Focus is set on the next runloop tick — the
    /// well-known reliable pattern for focusing a just-appeared macOS
    /// `TextField` (setting it synchronously can miss the not-yet-mounted
    /// field). Pre-fills with the row's current title so an edit starts from
    /// the existing name rather than blank.
    private func seedRenameEditor(for newKey: String?) {
        guard let newKey, let row = projectRow(forKey: newKey) else {
            renameActiveKey = nil
            renameFieldFocused = false
            return
        }
        renameDraft = row.displayLabel
        renameActiveKey = newKey
        DispatchQueue.main.async {
            renameFieldFocused = true
        }
    }

    /// Commit the current draft for the active edit session. The parent returns
    /// whether persistence succeeded; a rejected write leaves this editor and
    /// its draft intact so the user can correct or retry it.
    private func commitRename() {
        guard let key = renameActiveKey else { return }
        guard onCommitRename(key, renameDraft) else { return }
        renameActiveKey = nil
        renameFieldFocused = false
    }

    private func cancelRename() {
        guard renameActiveKey != nil else { return }
        renameActiveKey = nil
        renameFieldFocused = false
        onCancelRename()
    }

    private func projectRow(forKey key: String) -> ProjectRow? {
        for entry in entries {
            if case .row(let row) = entry, row.projectKey == key {
                return row
            }
        }
        return nil
    }

    /// Debounced single-tap handler. If the prior tap landed on the
    /// same row inside the system double-click window, this tap is
    /// the second click of a double-click — cancel the pending
    /// single-tap effect and call `onActivate`. Otherwise schedule a
    /// new single-tap effect to run after the double-click window.
    ///
    /// ⌘ and ⇧ modified clicks bypass the debounce entirely: they
    /// drive selection ops directly, never double-click upgrade
    /// (range / toggle have no "second click promotes" semantics),
    /// and firing them with no latency matches macOS list-view feel.
    /// ⌘/⇧ clicks, delivered via the explicit modified `TapGesture`
    /// recognizers: cancel any pending plain-tap effect and drive the
    /// selection op immediately — no double-click upgrade semantics.
    private func handleModifiedTap(rowKey: String, modifiers: NSEvent.ModifierFlags) {
        pendingTapWorkItem?.cancel()
        pendingTapWorkItem = nil
        lastTap = nil
        onSelect(rowKey, modifiers)
    }

    private func handleTap(rowKey: String) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            pendingTapWorkItem?.cancel()
            pendingTapWorkItem = nil
            lastTap = nil
            onSelect(rowKey, modifiers)
            return
        }
        let now = Date()
        if let prior = lastTap,
           prior.projectKey == rowKey,
           now.timeIntervalSince(prior.time) <= NSEvent.doubleClickInterval {
            pendingTapWorkItem?.cancel()
            pendingTapWorkItem = nil
            lastTap = nil
            onActivate(rowKey)
            return
        }
        pendingTapWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            onSelect(rowKey, [])
        }
        pendingTapWorkItem = workItem
        lastTap = (rowKey, now)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NSEvent.doubleClickInterval,
            execute: workItem
        )
    }

    private func rowTooltip(_ row: ProjectRow) -> String {
        var parts: [String] = [row.displayLabel]
        if row.obligationLoad.pendingReplyCount > 0 {
            parts.append("\(row.obligationLoad.pendingReplyCount) pending reply\(row.obligationLoad.pendingReplyCount == 1 ? "" : "s")")
        }
        if row.obligationLoad.confirmationCount > 0 {
            parts.append("\(row.obligationLoad.confirmationCount) confirmation\(row.obligationLoad.confirmationCount == 1 ? "" : "s")")
        }
        if !row.deadlineTicks.isEmpty {
            parts.append("\(row.deadlineTicks.count) evidence-backed deadline\(row.deadlineTicks.count == 1 ? "" : "s")")
        }
        if !row.revivalArcs.isEmpty {
            parts.append("\(row.revivalArcs.count) revival\(row.revivalArcs.count == 1 ? "" : "s") after inactive gap")
        }
        if !row.emergenceMarkers.isEmpty {
            parts.append("emerged \(row.firstActivityAt.formatted(.dateTime.month().day()))")
        }
        return parts.joined(separator: " · ")
    }

    /// Activity span line: when the project's mail ran, its volume, and —
    /// when one exists — the nearest relevant deadline. The lifecycle word
    /// and recency token retired from this card; the section bands (Active /
    /// Inactive) already say what state a row is in, and the
    /// span's end date says how recent it is.
    /// Inline title editor shown in place of the row headline while this
    /// project is being renamed. Enter or click-away commits; Esc cancels
    /// (see `onExitCommand`). Clearing the field leaves the current name.
    @ViewBuilder
    private func renameField(for row: ProjectRow) -> some View {
        TextField("Project name", text: $renameDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(OhiaColors.textPrimary)
            .lineLimit(1)
            .focused($renameFieldFocused)
            .onSubmit { commitRename() }
            .onExitCommand { cancelRename() }
            .onChange(of: renameFieldFocused) { _, focused in
                // A mutation alert also takes focus. That blur must not retry
                // the rejected write; the intact editor remains available
                // after the user dismisses the error.
                if !focused, !renameMutationFailureActive { commitRename() }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(OhiaColors.buttonBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
            )
    }

    private func activitySpanLine(_ row: ProjectRow) -> some View {
        let messageCount = row.messageIDs.count
        let volume = "\(messageCount) message\(messageCount == 1 ? "" : "s")"
        return HStack(spacing: 6) {
            Text(activitySpanText(row))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OhiaColors.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textTertiary)
            Text(volume)
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let milestone = nextMilestone(for: row) {
                HStack(spacing: 3) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 7.5))
                    Text(milestone.date.formatted(deadlineDateStyle(for: milestone.date)))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(
                    milestone.isOverdueOpen
                        ? OhiaColors.ohiaRed
                        : OhiaColors.ohiaRed.opacity(0.65)
                )
                .lineLimit(1)
            }
        }
    }

    /// First-to-last activity dates. Years appear only when the span leaves
    /// the current calendar year; a single-day project shows one date.
    private func activitySpanText(_ row: ProjectRow) -> String {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date.now)
        let firstYear = calendar.component(.year, from: row.firstActivityAt)
        let lastYear = calendar.component(.year, from: row.lastActivityAt)
        let style: Date.FormatStyle = (firstYear == currentYear && lastYear == currentYear)
            ? .dateTime.month().day()
            : .dateTime.month().day().year()
        if calendar.isDate(row.firstActivityAt, inSameDayAs: row.lastActivityAt) {
            return row.firstActivityAt.formatted(style)
        }
        return "\(row.firstActivityAt.formatted(style)) → \(row.lastActivityAt.formatted(style))"
    }

    /// The deadline diamond sits on the same line as the year-aware span
    /// text, so it follows the same rule: bare month-day inside the current
    /// year, explicit year outside it.
    private func deadlineDateStyle(for date: Date) -> Date.FormatStyle {
        let calendar = Calendar.current
        return calendar.component(.year, from: date) == calendar.component(.year, from: Date.now)
            ? .dateTime.month().day()
            : .dateTime.month().day().year()
    }

    /// Who the correspondence is with: the two highest-volume correspondents
    /// by full display name, with the remainder folded into "+N". The user's
    /// own addresses are filtered out — this is their mailbox, so their
    /// presence on every project is implied, not listed.
    @ViewBuilder
    private func correspondentsLine(_ row: ProjectRow) -> some View {
        let others = row.participants.filter { !userAddresses.contains($0.email) }
        if !others.isEmpty {
            let names = others.prefix(2).map { participant in
                participant.displayName?.isEmpty == false ? participant.displayName! : participant.email
            }
            let extra = others.count - names.count
            Text(extra > 0 ? "\(names.joined(separator: ", ")) +\(extra)" : names.joined(separator: ", "))
                .font(.system(size: 11))
                .foregroundStyle(OhiaColors.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// The row's most relevant milestone for the gutter ledger: the nearest
    /// upcoming evidence-backed deadline, or — when nothing lies ahead —
    /// the most recent overdue deadline whose source message still carries
    /// an open obligation. Cleared past deadlines stay off the ledger.
    private func nextMilestone(for row: ProjectRow) -> (date: Date, isOverdueOpen: Bool)? {
        guard !row.deadlineTicks.isEmpty else { return nil }
        let now = Date.now
        if let upcoming = row.deadlineTicks
            .filter({ $0.date >= now })
            .min(by: { $0.date < $1.date }) {
            return (upcoming.date, false)
        }
        let openMessageIDs = Set(row.obligations.map(\.messageID))
        if let overdue = row.deadlineTicks
            .filter({ $0.date < now && openMessageIDs.contains($0.messageID) })
            .max(by: { $0.date < $1.date }) {
            return (overdue.date, true)
        }
        return nil
    }

    private func rowTextColor(_ row: ProjectRow) -> Color {
        isDormantLifecycleRow(row) ? OhiaColors.textTertiary : OhiaColors.textPrimary
    }

    private func isDormantLifecycleRow(_ row: ProjectRow) -> Bool {
        row.status == .resolved
            || row.status == .quiet
            || row.lifecycleAssessment.state == .inactive
    }

}

private struct ProjectDraftGutterRow: View {
    let draft: ProjectConfigurationDraftRow
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.badge.clock")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OhiaColors.chipActiveForeground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(draft.existingProjectID == nil
                        ? "Project not yet active"
                        : "Unsaved project changes")
                    Text("·")
                    Text(draft.updatedAt, format: .relative(presentation: .named))
                }
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textSecondary)
            }
            Spacer(minLength: 4)
            if isHovered {
                ClusterButtonChip(
                    glyph: .native("xmark.bin.circle.fill"),
                    tint: OhiaColors.ohiaRed,
                    help: "Delete",
                    action: onDelete
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(OhiaColors.surface(0.035))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OhiaColors.glassBorder.opacity(0.42))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open Project Draft", systemImage: "pencil", action: onOpen)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(draft.displayName), project draft")
        .accessibilityAction {
            onOpen()
        }
        .accessibilityAction(named: Text("Delete Project Draft"), onDelete)
    }
}

private struct ProjectsTimeSectionDivider: View {
    let header: ProjectsTimeSectionHeader
    var onToggle: (() -> Void)?
    var onCreateProject: (() -> Void)?
    var isCreateProjectEnabled = true

    var body: some View {
        HStack(spacing: 5) {
            if let onToggle {
                Button(action: onToggle) {
                    sectionLabel
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .focusEffectDisabled()
                .accessibilityLabel(accessibilityText)
                .accessibilityValue(header.isExpanded ? "Expanded" : "Collapsed")
            } else {
                sectionLabel
                    .accessibilityLabel(accessibilityText)
            }

            if let onCreateProject {
                Button(action: onCreateProject) {
                    Label("Project", systemImage: "plus")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 3))
                .fixedSize()
                .disabled(isCreateProjectEnabled == false)
                .accessibilityLabel("New Project")
                .help(isCreateProjectEnabled
                    ? "New Project (⇧⌘N)"
                    : "Continue or delete the current project draft first")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, isActiveHeader ? 10 : 14)
        .padding(.trailing, 10)
        .background(OhiaColors.surface(isActiveHeader ? 0.045 : 0.075))
        .overlay(alignment: .leading) {
            if !isActiveHeader {
                Rectangle()
                    .fill(OhiaColors.textDim.opacity(0.9))
                    .frame(width: 4)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OhiaColors.glassBorder.opacity(isActiveHeader ? 0.58 : 0.86))
                .frame(height: 1)
        }
    }

    private var sectionLabel: some View {
        HStack(spacing: 5) {
            if header.showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .rotationEffect(.degrees(header.isExpanded ? 90 : 0))
            }
            Text(titleText)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(isActiveHeader ? OhiaColors.textPrimary : OhiaColors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var isActiveHeader: Bool {
        header.id == ProjectsTimeSectionHeader.activeID
    }

    private var titleText: String {
        if header.id == ProjectsTimeSectionHeader.draftsID {
            return "\(header.title) · \(header.count)"
        }
        return "\(header.title) · \(header.count) project\(header.count == 1 ? "" : "s")"
    }

    private var accessibilityText: String {
        if header.id == ProjectsTimeSectionHeader.draftsID {
            return "\(header.count) project draft\(header.count == 1 ? "" : "s")"
        }
        guard header.showsDisclosure else {
            return "\(header.title), \(header.count) projects"
        }
        return "\(header.title), \(header.count) projects, \(header.isExpanded ? "expanded" : "collapsed")"
    }
}
