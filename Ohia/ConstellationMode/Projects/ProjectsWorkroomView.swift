import AppKit
import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

// Projects is a SwiftUI/Canvas workspace. The normal Metal scene should not mount for `.projects`.

struct ProjectFocusedWorkroomEmptyState: Equatable, Sendable {
    let title: String
    let keepsProjectFocused: Bool

    static func resolve(
        committedMessageCount: Int,
        visibleMessageCount: Int,
        hasActiveFilters: Bool
    ) -> Self? {
        guard visibleMessageCount == 0 else { return nil }
        if committedMessageCount > 0, hasActiveFilters {
            return Self(
                title: "No project messages match current filters",
                keepsProjectFocused: true
            )
        }
        return Self(
            title: "No messages are currently in this project",
            keepsProjectFocused: true
        )
    }
}

/// The per-project workroom — the Projects lens's focused surface, mounted
/// for `selectedMode == .linksFor(projectKey)`. Where the Time surface
/// treats the project as a unit (select, resolve, hide), the workroom is
/// the email-by-email breakdown: a dossier header (title, activity span,
/// correspondents, open load, linked-project chips) over a newest-first
/// feed of email cards in the Front Page register, alongside the project's
/// attachment and working-file catalog. Clicking an email card expands it
/// in place into a reader with the full body; Esc collapses, then returns
/// to Time. The retired cross-project links canvas survives only as the
/// header's "Linked" chips, which refocus the workroom on the neighbour.
struct ProjectsWorkroomView: View {
    @Environment(\.readingTextSize) private var readingTextSize

    @Bindable var workspace: ProjectsWorkspaceState
    let snapshot: ProjectsSnapshot
    let focusProjectKey: String
    let summaryByMessageId: [String: String]
    let regeneratingSummaryMessageIds: Set<String>
    let modelContext: ModelContext
    /// Shared cross-lens message mutations (reply/confirm/flag/read/delete,
    /// send-to-Composer) — the same closure bundle the Front Page cards use.
    /// Send-to-Composer plays the in-place Comet via each card's
    /// `DepartingGestureOverlay`, so the workroom needs no dispatch coordinator.
    let messageActions: FrontPageMessageActionHandlers
    /// Generates the project guide (briefing + WHAT'S NEEDED + readouts) —
    /// the same service the Deadlines guide pane uses, prompting in the
    /// project register via `framing: .project`.
    let deadlineSummaryService: DeadlineSummaryService
    let attachmentSummaryService: AttachmentSummaryService
    let jobCompletionBroadcaster: JobCompletionBroadcaster
    let guideUserIdentity: SummarizationUserIdentity?
    let hasActiveMessageFilters: Bool
    let onMembershipChanged: (Double) -> Void
    let onPresentMessageMenu: (UUID, NSPoint, NSView) -> Void

    @State private var hitTester = ProjectsHitTester()
    @State private var bodyStates: [UUID: WorkroomBodyState] = [:]

    // MARK: Project guide state
    //
    // The guide sits between the dossier header and the email feed: the
    // project's summary grown into a completion guide, exactly the Deadlines
    // pane's grammar. Ticks and working files persist under the
    // "project-<key>" entry id, so they survive snapshot rebuilds.
    private let workFileStore = DeadlineWorkFileStore()
    @State private var guideSummaryState: DeadlineSummaryState = .loading
    @State private var guideReadoutStates: [String: DeadlineGuideReadoutState] = [:]
    @State private var guideCompletedSteps: Set<String> = []
    /// Bumped when the project's file set changes so the guide's `.task`
    /// restarts against the new fingerprint.
    @State private var guideFilesRevision = 0
    @State private var projectFileRecords: [ProjectFileRecord] = []
    @State private var generatedProjectFileSummaries: [String: String] = [:]
    @State private var loadingProjectFileSummaryIDs: Set<String> = []
    @State private var attachmentDataRevision = 0

    private var guideKey: String { "project-\(focusProjectKey)" }

    private var guideStateStore: DeadlineGuideStateStore {
        DeadlineGuideStateStore(modelContext: modelContext)
    }
    /// Beacon / citation arrival emphasis — the card the last
    /// `linksFocusRequest` navigated to keeps its accent ring until the
    /// user interacts elsewhere.
    @State private var highlightedMessageID: UUID?
    @State private var accountBadges: [UUID: WorkroomAccountBadge] = [:]
    /// One workroom-wide hover owner, matching Front Page's single
    /// `hoveredArticleID`: entering a second card immediately releases the first.
    @State private var hoveredMessageID: UUID?
    @State private var hoverExitTask: Task<Void, Never>?
    @State private var customCategoryCatalog: [CustomMailCategoryDescriptor] = []
    @State private var classificationOverrides: [UUID: MailClassification] = [:]
    @State private var customCategoryOverrides: [UUID: Set<String>] = [:]
    @State private var membershipDetails: ProjectMembershipDetailsPresentation?
    @State private var categoryDepartureNotice: ProjectCategoryDepartureNotice?
    @State private var categoryReconciliationTask: Task<Void, Never>?
    @State private var categoryMutationFailure: String?

    private static let feedWidth: CGFloat = 820
    private static let minimumFeedPaneWidth: CGFloat = 640
    private static let preferredFilesPaneWidth: CGFloat = 520
    private static let minimumFilesPaneWidth: CGFloat = 360
    private static let cardCornerRadius: CGFloat = 10

    enum WorkroomBodyState: Equatable {
        case loading
        case loaded(String)
        case failed
    }

    struct WorkroomAccountBadge: Equatable {
        let name: String
        let emailAddress: String
        let color: AccountColor
    }

    var body: some View {
        Group {
            if let row = focusedRow {
                GeometryReader { geometry in
                    let filesPaneWidth = min(
                        Self.preferredFilesPaneWidth,
                        max(
                            Self.minimumFilesPaneWidth,
                            geometry.size.width - Self.minimumFeedPaneWidth
                        )
                    )

                    HStack(spacing: 0) {
                        projectFeed(row: row)
                            .frame(minWidth: Self.minimumFeedPaneWidth, maxWidth: .infinity)
                            .layoutPriority(1)
                        ProjectFilesPane(
                            scope: .project,
                            records: projectFileRecords,
                            generatedSummaries: generatedProjectFileSummaries,
                            loadingSummaryIDs: loadingProjectFileSummaryIDs,
                            onAddFiles: handleGuideDropFiles,
                            onRemoveManualFile: handleProjectFileRemoval
                        )
                        .id(focusProjectKey)
                        .frame(width: filesPaneWidth)
                    }
                }
                .task(
                    id: ProjectFileCatalogTaskKey(
                        projectKey: focusProjectKey,
                        summaryRequestKey: ProjectSummaryInputBuilder.requestKey(for: row),
                        filesRevision: guideFilesRevision,
                        attachmentDataRevision: attachmentDataRevision
                    )
                ) {
                    await loadProjectFiles(row: row)
                }
            } else {
                // The project dissolved out of the current snapshot (merge,
                // refinement, filter change). The mode strip's back chevron
                // remains the exit; this pane just states the fact.
                OhiaEmptyPaneStateView(
                    systemName: "folder",
                    title: "This project is no longer in the current scope.",
                    detail: "Return to the project list to choose another project."
                )
            }
        }
        .task {
            loadAccountBadges()
            loadCustomCategoryCatalog()
        }
        .task {
            await observeProjectFileCompletions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaAccountColorChanged)) { _ in
            loadAccountBadges()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaCustomCategoriesDidChange)) { _ in
            loadCustomCategoryCatalog()
        }
        // The view keeps its @State across a Linked-chip refocus (same
        // position in the mode switch), so per-project caches must not
        // leak into the neighbour: body cache, arrival ring, and hit
        // rects all reset with the project.
        .onChange(of: focusProjectKey) { _, _ in
            categoryReconciliationTask?.cancel()
            categoryReconciliationTask = nil
            onMembershipChanged(0)
            hoverExitTask?.cancel()
            hoverExitTask = nil
            hoveredMessageID = nil
            bodyStates = [:]
            highlightedMessageID = nil
            hitTester.reset()
            resetGuideDisplayState()
            guideCompletedSteps = []
            projectFileRecords = []
            generatedProjectFileSummaries = [:]
            loadingProjectFileSummaryIDs = []
            categoryDepartureNotice = nil
            membershipDetails = nil
            classificationOverrides = [:]
            customCategoryOverrides = [:]
        }
        .onDisappear {
            hoverExitTask?.cancel()
            hoverExitTask = nil
            hoveredMessageID = nil
            categoryReconciliationTask?.cancel()
            categoryReconciliationTask = nil
            onMembershipChanged(0)
        }
        .sheet(item: $membershipDetails) { details in
            ProjectMembershipDetailsView(details: details)
        }
        .overlay(alignment: .top) {
            if let notice = categoryDepartureNotice {
                categoryDepartureBanner(notice)
                    .padding(.top, 12)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .alert(
            "Project Update Failed",
            isPresented: Binding(
                get: { categoryMutationFailure != nil },
                set: { if !$0 { categoryMutationFailure = nil } }
            )
        ) {
            Button("OK", systemImage: "checkmark") { categoryMutationFailure = nil }
        } message: {
            Text(categoryMutationFailure ?? "")
        }
    }

    private func projectFeed(row: ProjectRow) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                feedContent(row: row)
            }
            .onChange(of: workspace.linksFocusRequest) { _, _ in
                applyPendingFocusRequest(row: row, scrollProxy: scrollProxy)
            }
            .task(id: workspace.linksFocusRequest?.sequence) {
                applyPendingFocusRequest(row: row, scrollProxy: scrollProxy)
            }
            .onChange(of: snapshot.signature) { _, _ in
                reconcileWithSnapshot()
            }
            .task(
                id: GuideSummaryTaskKey(
                    scopeID: focusProjectKey,
                    summaryRequestKey: ProjectSummaryInputBuilder.requestKey(for: row),
                    evidenceIdentity: .project(snapshot.signature),
                    filesRevision: guideFilesRevision
                )
            ) {
                await loadProjectGuide(row: row)
            }
        }
    }

    /// Snapshot refresh reconciliation: prune hit rects for messages no
    /// longer in the project (delete, refinement) so right-clicks and
    /// comets can't resolve to vacated regions, and release the expanded
    /// reader / arrival ring when their message left the feed — otherwise
    /// the ESC ladder consumes a press on an invisible reader.
    private func reconcileWithSnapshot() {
        guard let row = focusedRow else {
            workspace.workroomExpandedMessageID = nil
            hoverExitTask?.cancel()
            hoverExitTask = nil
            hoveredMessageID = nil
            highlightedMessageID = nil
            hitTester.reset()
            return
        }
        let ids = Set(snapshot.filteredMarks(in: row).map(\.messageID))
        hitTester.retainMessages(ids)
        if let expanded = workspace.workroomExpandedMessageID, !ids.contains(expanded) {
            workspace.workroomExpandedMessageID = nil
        }
        if let highlighted = highlightedMessageID, !ids.contains(highlighted) {
            highlightedMessageID = nil
        }
        if let hovered = hoveredMessageID, !ids.contains(hovered) {
            hoverExitTask?.cancel()
            hoverExitTask = nil
            hoveredMessageID = nil
        }
    }

    // MARK: - Feed

    /// The event catcher, comet overlay, and the named coordinate space
    /// all attach to the same width-capped feed frame the card rects are
    /// recorded in — a right-click point and a comet origin must resolve
    /// in the exact space the per-card geometry reported.
    private func feedContent(row: ProjectRow) -> some View {
        let marks = orderedMarks(row: row)
        return VStack(alignment: .leading, spacing: 14) {
            dossierHeader(row: row, visibleMarks: marks)
            guideSection
            GuideSectionHeader("EMAILS", systemImage: "envelope")
            if let emptyState = ProjectFocusedWorkroomEmptyState.resolve(
                committedMessageCount: row.messageIDs.count,
                visibleMessageCount: marks.count,
                hasActiveFilters: hasActiveMessageFilters
            ) {
                focusedEmptyState(emptyState)
            } else {
                ForEach(marks, id: \.messageID) { mark in
                    card(mark: mark, row: row)
                        .id(mark.messageID)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: Self.feedWidth + 56)
        .background(
            // Right-click only — no double-click handler, so the catcher's
            // left-mouse monitor never installs and double-click word
            // selection inside an expanded reader keeps working.
            TimelineEventCatcher(
                onRightClick: { point, view in
                    handleRightClick(point: point, view: view)
                }
            )
        )
        // Send-to-Composer now plays the Front Page in-place Comet on the card
        // itself (via each card's `DepartingGestureOverlay`), so the workroom no
        // longer mounts the from-the-dot launch comet the Time surface uses.
        .coordinateSpace(name: Self.contentSpace)
        .frame(maxWidth: .infinity)
    }

    private static let contentSpace = "projectsWorkroomContent"

    /// Newest first — the workroom leads with the project's present, the
    /// history sinking below (Front Page order, per the user's choice).
    private func orderedMarks(row: ProjectRow) -> [ProjectMessageMark] {
        snapshot.filteredMarks(in: row).sorted { $0.date > $1.date }
    }

    private var focusedRow: ProjectRow? {
        snapshot.projectDefinitionRow(for: focusProjectKey)
            ?? workspace.workroomAnchorRow.flatMap { row in
                row.projectKey == focusProjectKey ? row : nil
            }
    }

    private func focusedEmptyState(_ state: ProjectFocusedWorkroomEmptyState) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(OhiaColors.ohiaYellow)
            Text(state.title)
                .font(readingTextSize.font(base: 15, weight: .semibold, maximumScale: 1.3))
                .foregroundStyle(OhiaColors.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 18)
        .background(OhiaColors.glassPanel)
        .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cardCornerRadius)
                .strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        }
    }

    private func categoryDepartureBanner(_ notice: ProjectCategoryDepartureNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.and.line.horizontal.and.arrow.down")
                .foregroundStyle(OhiaColors.ohiaYellow)
            Text(notice.message)
                .font(readingTextSize.font(base: 13, weight: .semibold, maximumScale: 1.3))
                .foregroundStyle(OhiaColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if notice.actions.contains(.undoChange) {
                Button("Undo Change", systemImage: "arrow.uturn.backward") {
                    undoCategoryChange(notice)
                }
                .buttonStyle(.emblem)
            }
            Button("Keep in Project", systemImage: "folder.badge.plus") {
                keepMessageInProject(notice)
            }
            .buttonStyle(.emblem)
        }
        .padding(12)
        .background(OhiaColors.glassPanel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(OhiaColors.ohiaYellow, lineWidth: 1)
        }
        .shadow(color: OhiaColors.ohiaYellow.opacity(0.18), radius: 16)
    }

    // MARK: - Dossier header

    @ViewBuilder
    private func dossierHeader(
        row: ProjectRow,
        visibleMarks: [ProjectMessageMark]
    ) -> some View {
        let firstActivityAt = visibleMarks.map(\.date).min() ?? row.firstActivityAt
        let lastActivityAt = visibleMarks.map(\.date).max() ?? row.lastActivityAt
        let visibleOpenCount = visibleMarks.reduce(into: 0) { count, mark in
            count += mark.obligationKinds.count
        }
        VStack(alignment: .leading, spacing: 7) {
            Text(row.displayLabel)
                .font(readingTextSize.font(base: 22, weight: .semibold, maximumScale: 1.25))
                .foregroundStyle(OhiaColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(Self.activitySpanText(first: firstActivityAt, last: lastActivityAt))
                    .font(readingTextSize.font(base: 13, maximumScale: 1.3))
                    .monospacedDigit()
                    .foregroundStyle(OhiaColors.textSecondary)
                Text("·")
                    .font(readingTextSize.font(base: 13, maximumScale: 1.3))
                    .foregroundStyle(OhiaColors.textTertiary)
                Text("\(visibleMarks.count) message\(visibleMarks.count == 1 ? "" : "s")")
                    .font(readingTextSize.font(base: 13, maximumScale: 1.3))
                    .monospacedDigit()
                    .foregroundStyle(OhiaColors.textSecondary)
                if visibleOpenCount > 0 {
                    Text("·")
                        .font(readingTextSize.font(base: 13, maximumScale: 1.3))
                        .foregroundStyle(OhiaColors.textTertiary)
                    Text("\(visibleOpenCount) open")
                        .font(readingTextSize.font(base: 13, weight: .semibold, maximumScale: 1.3))
                        .monospacedDigit()
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                }
            }

            if let correspondents = correspondentsLine(row: row) {
                Text(correspondents)
                    .font(readingTextSize.font(base: 12.5, maximumScale: 1.3))
                    .foregroundStyle(OhiaColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let linked = linkedRows(for: row)
            if !linked.isEmpty {
                HStack(spacing: 8) {
                    Text("Linked")
                        .font(readingTextSize.font(base: 11, weight: .semibold, maximumScale: 1.25))
                        .tracking(0.4)
                        .foregroundStyle(OhiaColors.textTertiary)
                    ForEach(linked, id: \.projectKey) { neighbour in
                        Button {
                            workspace.openLinksFor(neighbour.projectKey)
                        } label: {
                            Label(neighbour.displayLabel, systemImage: "link")
                                .font(readingTextSize.font(base: 12, weight: .medium, maximumScale: 1.25))
                                .lineLimit(1)
                        }
                        .buttonStyle(EmblemButtonStyle(horizontalPadding: 9, verticalPadding: 3))
                        .help("Open \(neighbour.displayLabel)")
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    /// Complete correspondent roster minus the user (their mailbox implies
    /// them). The focused view has the room, so every name appears —
    /// volume-ordered from the row computation, wrapping as needed — rather
    /// than the Time surface's truncated "+N".
    private func correspondentsLine(row: ProjectRow) -> String? {
        let others = row.participants.filter { !snapshot.userAddresses.contains($0.email) }
        guard !others.isEmpty else { return nil }
        let names = others.map { participant in
            let display = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (display?.isEmpty == false ? display! : participant.email)
        }
        return names.joined(separator: ", ")
    }

    // MARK: - Project guide

    /// The project's summary grown into a completion guide — briefing and
    /// WHAT'S NEEDED (tickable steps with per-document readouts) — in the
    /// shared guide-card grammar, between the dossier header and email feed.
    @ViewBuilder
    private var guideSection: some View {
        GuideSectionHeader("SUMMARY", systemImage: "text.alignleft")
        GuideCard {
            GuideBriefingBody(
                summaryState: guideSummaryState,
                subjectNoun: "project",
                placeholderWidth: Self.feedWidth - 60
            )
        }
        if case .loaded(let result) = guideSummaryState, result.actions.isEmpty == false {
            let doneCount = result.actions.count { guideCompletedSteps.contains($0.id) }
            GuideSectionHeader(
                "WHAT'S NEEDED",
                systemImage: "checklist",
                detail: "· \(doneCount) of \(result.actions.count) done"
            )
            GuideCard {
                GuideNeedsList(
                    result: result,
                    completedStepIDs: guideCompletedSteps,
                    readoutStates: guideReadoutStates,
                    onToggleStep: { stepID, completed in
                        guideStateStore.setStep(stepID, completed: completed, entryID: guideKey)
                        guideCompletedSteps = guideStateStore.completedStepIDs(entryID: guideKey)
                    }
                )
            }
        }
    }

    /// Clears the guide's derived display state; persisted ticks and working
    /// files reload in `loadProjectGuide`.
    private func resetGuideDisplayState() {
        guideSummaryState = .loading
        guideReadoutStates = [:]
    }

    /// Loads everything the guide shows: persisted ticks, the working-file
    /// list, the project-framed summary (service-cached),
    /// then each document's close reading sequentially so the cards fill in
    /// as they arrive. Every post-await write is cancellation-guarded — the
    /// `.task(id:)` restarts on selection, snapshot, or file-set changes.
    private func loadProjectGuide(row: ProjectRow) async {
        let key = guideKey
        let summaryKey = "project-guide:\(ProjectSummaryInputBuilder.requestKey(for: row))"
        guideCompletedSteps = guideStateStore.completedStepIDs(entryID: key)

        // Always rebuild current evidence on project open, snapshot change, or
        // file-set change. Unchanged input resolves from the service cache.
        guideSummaryState = .loading
        guideReadoutStates = [:]
        let builtInput = await ProjectGuideInputBuilder.build(
            row: row,
            marks: row.marks,
            modelContext: modelContext,
            userIdentity: guideUserIdentity,
            workFileStore: workFileStore,
            guideKey: key,
            userAddresses: snapshot.userAddresses
        )
        guard !Task.isCancelled else { return }
        guard let input = builtInput else {
            guideSummaryState = .unavailable("No committed project correspondence is available yet.")
            return
        }
        guard input.hasEvidence else {
            guideSummaryState = .unavailable("No summary is available for this project yet.")
            return
        }
        let generated = await deadlineSummaryService.summary(for: summaryKey, input: input)
        guard !Task.isCancelled else { return }
        guard let result = generated else {
            guideSummaryState = .unavailable(
                "A summary for this project could not be generated. The generative model may still be loading."
            )
            return
        }
        guideSummaryState = .loaded(result)

        // Correspondence attachments keep their contextual readouts under the
        // matching guide steps. User-added files now carry their own summary
        // lifecycle in the dedicated Files pane.
        let resources: [(file: DeadlineSummaryAttachment, origin: DeadlineResourceOrigin, key: String)] =
            input.attachments.map {
                ($0, .threadAttachment, GuideResourceKeys.document(filename: $0.filename))
            }

        for resource in resources {
            guard let text = resource.file.extractedText,
                  text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                continue
            }
            guard guideReadoutStates[resource.key] == nil else { continue }
            guideReadoutStates[resource.key] = .loading
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
                userIdentity: guideUserIdentity,
                framing: .project
            )
            let readout = await deadlineSummaryService.readout(
                for: summaryKey,
                resourceKey: resource.key,
                input: readoutInput
            )
            // Write nothing when cancelled: every restart path (project
            // refocus, snapshot change, file-set change) already cleared the
            // map, and a stale mutation here could delete the entry the
            // replacement task just wrote.
            guard !Task.isCancelled else { return }
            guideReadoutStates[resource.key] = readout.map(DeadlineGuideReadoutState.loaded) ?? .unavailable
        }
    }

    private func loadProjectFiles(row: ProjectRow) async {
        let workFiles = workFileStore.files(entryID: guideKey)
        let records = ProjectFileCatalog.records(
            row: row,
            modelContext: modelContext,
            workFiles: workFiles
        )
        guard Task.isCancelled == false else { return }
        let currentIDs = Set(records.map(\.id))
        projectFileRecords = records
        generatedProjectFileSummaries = generatedProjectFileSummaries.filter {
            currentIDs.contains($0.key)
        }
        let pending = records.filter {
            $0.storedSummary == nil
                && generatedProjectFileSummaries[$0.id] == nil
                && $0.summaryInput != nil
        }
        loadingProjectFileSummaryIDs = Set(pending.map(\.id))

        // Generate sequentially: both the attachment summary service and the
        // guide favor one local model request at a time, while each completed
        // orientation appears immediately in the row that requested it.
        for record in pending {
            guard Task.isCancelled == false else { return }
            let generated = await ProjectFileSummaryLoader.summary(
                for: record,
                workFiles: workFiles,
                workFileStore: workFileStore,
                service: attachmentSummaryService
            )
            guard Task.isCancelled == false else { return }
            loadingProjectFileSummaryIDs.remove(record.id)
            guard let generated else { continue }
            generatedProjectFileSummaries[record.id] = generated.paragraph
            persistGeneratedSummary(generated, for: record)
        }
    }

    private func persistGeneratedSummary(
        _ generated: ProjectFileGeneratedSummary,
        for record: ProjectFileRecord
    ) {
        guard case .message(let attachmentID, _) = record.origin else { return }
        var descriptor = FetchDescriptor<Attachment>(
            predicate: #Predicate { $0.id == attachmentID }
        )
        descriptor.fetchLimit = 1
        guard let attachment = try? modelContext.fetch(descriptor).first else { return }
        attachment.attachmentSummary = generated.paragraph
        attachment.attachmentSummaryFingerprint = generated.fingerprint
        attachment.attachmentSummaryGeneratedAt = .now
        attachment.attachmentSummaryAttemptedAt = .now
        attachment.attachmentSummaryFailureReason = nil
        try? modelContext.save()
    }

    private func handleGuideDropFiles(_ urls: [URL]) -> ProjectFileImportResult {
        let added = workFileStore.add(fileURLs: urls, entryID: guideKey)
        if added.isEmpty == false {
            let reason = added.count == 1
                ? "\(added[0].filename) was added"
                : "\(added.count) files were added"
            noteGuideFileSetChange(reason: reason)
        }
        return ProjectFileImportResult(
            requestedCount: urls.count,
            addedCount: added.count
        )
    }

    private func handleGuideRemoveWorkFile(_ file: DeadlineWorkFile) -> Bool {
        guard workFileStore.remove(file) else { return false }
        noteGuideFileSetChange(reason: "\(file.filename) was removed")
        return true
    }

    private func handleProjectFileRemoval(_ workFileID: String) -> Bool {
        guard let file = workFileStore.files(entryID: guideKey)
            .first(where: { $0.id == workFileID }) else { return false }
        return handleGuideRemoveWorkFile(file)
    }

    @MainActor
    private func observeProjectFileCompletions() async {
        for await event in jobCompletionBroadcaster.events() {
            guard Task.isCancelled == false else { return }
            guard ProjectFileRefreshPolicy.requiresReload(after: event.type) else { continue }
            attachmentDataRevision &+= 1
        }
    }

    /// A change to the project's file set queues a full guide re-read: the
    /// persisted stamp records why, and the synchronous revision bump
    /// restarts the guide's `.task` against the new input fingerprint (the
    /// changed file set re-keys the cache; no service invalidation needed).
    private func noteGuideFileSetChange(reason: String) {
        let now = Date.now
        guideStateStore.setLastRead(at: now, reason: reason, entryID: guideKey)
        resetGuideDisplayState()
        guideFilesRevision += 1
    }

    /// Projects sharing a cross-project link with this one, resolved to
    /// structurally scoped rows so message filters do not dissolve neighbours.
    private func linkedRows(for row: ProjectRow) -> [ProjectRow] {
        let neighbourKeys = snapshot.projectDefinitionLinks.compactMap { link -> String? in
            if link.leftProjectKey == row.projectKey { return link.rightProjectKey }
            if link.rightProjectKey == row.projectKey { return link.leftProjectKey }
            return nil
        }
        var seen = Set<String>()
        return neighbourKeys.compactMap { key in
            guard seen.insert(key).inserted else { return nil }
            return snapshot.projectDefinitionVisibleRows.first { $0.projectKey == key }
        }
    }

    /// "Jun 16 → Jun 26" activity span — same register as the Time gutter
    /// card: years appear only outside the current year, a same-day span
    /// collapses to a single date, and the separator is a real arrow.
    static func activitySpanText(first: Date, last: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: now)
        func label(_ date: Date) -> String {
            let year = calendar.component(.year, from: date)
            let formatter = year == currentYear ? workroomMonthDayFormatter : workroomMonthDayYearFormatter
            return formatter.string(from: date)
        }
        if calendar.isDate(first, inSameDayAs: last) {
            return label(first)
        }
        return "\(label(first)) → \(label(last))"
    }

    // MARK: - Cards

    @ViewBuilder
    private func card(mark: ProjectMessageMark, row: ProjectRow) -> some View {
        let messageID = mark.messageID
        let filterRow = snapshot.messageFilterRows[messageID.uuidString]
        let classification = classificationOverrides[messageID] ?? filterRow?.mailClassification
        let customKeys = customCategoryOverrides[messageID] ?? filterRow?.customCategoryKeys ?? []
        let expanded = workspace.workroomExpandedMessageID == messageID
        let highlighted = highlightedMessageID == messageID
        WorkroomEmailCard(
            mark: mark,
            filterRow: filterRow,
            display: filterRow.map { filter in
                ProjectsAnnotationItemBuilder.makeDisplay(
                    messageID: messageID,
                    row: filter,
                    summaryOverride: summaryByMessageId[messageID.uuidString],
                    userAddresses: snapshot.userAddresses
                )
            },
            statusDescriptor: statusDescriptor(mark: mark, row: row),
            accountBadge: filterRow?.accountId.flatMap { accountBadges[$0] },
            isInComposerQueue: snapshot.rowsSnapshot.messageLookup[messageID]?.isInComposerQueue == true,
            isSummaryRegenerating: regeneratingSummaryMessageIds.contains(messageID.uuidString),
            isHovered: hoveredMessageID == messageID,
            expanded: expanded,
            highlighted: highlighted,
            bodyState: bodyStates[messageID],
            departingGesture: workspace.statusGestureCoordinator.gesture(for: messageID),
            actions: messageActions,
            classification: classification,
            customCategoryKeys: customKeys,
            customCategoryCatalog: customCategoryCatalog,
            showsProjectMembershipControls: true,
            onToggleExpansion: {
                toggleExpansion(messageID: messageID, filterRow: filterRow)
            },
            onHoverChange: { hovering in
                handleHoverChange(hovering, messageID: messageID)
            },
            onClassificationChanged: { newClassification, customKeys in
                changeCategory(
                    messageID: messageID,
                    row: row,
                    previousClassification: classification,
                    previousCustomCategoryKeys: customKeys,
                    classification: newClassification,
                    customCategoryKeys: customKeys
                )
            },
            onShowMembershipDetails: {
                showMembershipDetails(projectID: row.projectID, messageID: messageID)
            }
        )
        // A departing card rides above its feed siblings so its Collapse /
        // Comet can bloom past its own edge into the neighbours' space.
        .zIndex(workspace.statusGestureCoordinator.gesture(for: messageID)?.action.usesDepartingOverlay == true ? 1 : 0)
        .background(
            GeometryReader { geo in
                Color.clear.onChange(
                    of: geo.frame(in: .named(Self.contentSpace)),
                    initial: true
                ) { _, frame in
                    hitTester.updateMessage(
                        rect: frame,
                        messageID: messageID,
                        projectKey: row.projectKey
                    )
                }
            }
        )
    }

    private func statusDescriptor(mark: ProjectMessageMark, row: ProjectRow) -> MessageStatusDescriptor {
        let hasDeadline = mark.hasDeadline
            || row.deadlineTicks.contains { $0.messageID == mark.messageID }
        let deadlineText = mark.deadlineText
            ?? row.deadlineTicks.first { $0.messageID == mark.messageID }?.evidenceText
        return MessageStatusDescriptor(
            mark: mark,
            hasDeadline: hasDeadline,
            deadlineText: deadlineText
        )
    }

    private func toggleExpansion(messageID: UUID, filterRow: MessageFilterRow?) {
        highlightedMessageID = nil
        if workspace.workroomExpandedMessageID == messageID {
            workspace.workroomExpandedMessageID = nil
            return
        }
        workspace.workroomExpandedMessageID = messageID
        kickBodyLoadIfNeeded(messageID: messageID, filterRow: filterRow)
        // Opening a message is reading it — same policy as the Front Page
        // reader flipping an unread message to read on entry.
        if let filterRow, !filterRow.isRead {
            messageActions.setRead([messageID], true)
        }
    }

    private func handleHoverChange(_ hovering: Bool, messageID: UUID) {
        if hovering {
            hoverExitTask?.cancel()
            hoverExitTask = nil
            hoveredMessageID = messageID
            return
        }

        guard hoveredMessageID == messageID else { return }
        hoverExitTask?.cancel()
        hoverExitTask = Task { @MainActor in
            do {
                try await Task.sleep(for: FrontPageCardHoverMotion.exitGracePeriod)
            } catch {
                return
            }
            guard hoveredMessageID == messageID else { return }
            hoveredMessageID = nil
            hoverExitTask = nil
        }
    }

    // MARK: - Membership and category editing

    private func showMembershipDetails(projectID: UUID, messageID: UUID) {
        let context = ModelContext(modelContext.container)
        membershipDetails = try? ProjectMembershipDetailsBuilder.build(
            projectID: projectID,
            messageID: messageID,
            in: context
        )
    }

    private func changeCategory(
        messageID: UUID,
        row: ProjectRow,
        previousClassification: MailClassification?,
        previousCustomCategoryKeys: Set<String>,
        classification: MailClassification?,
        customCategoryKeys: Set<String>
    ) {
        let detailsContext = ModelContext(modelContext.container)
        let priorDetails = try? ProjectMembershipDetailsBuilder.build(
            projectID: row.projectID,
            messageID: messageID,
            in: detailsContext
        )
        classificationOverrides[messageID] = classification
        customCategoryOverrides[messageID] = customCategoryKeys

        // Hold any membership notification-triggered refresh while the exact
        // outcome is evaluated. If the message stays, the hold is cancelled;
        // if it leaves, it is reset from the moment the Collapse begins.
        onMembershipChanged(MessageStatusGesturePhase.departingFloor)
        let saveSucceeded = messageActions.setClassificationAndReportSuccess(
            messageID,
            classification,
            customCategoryKeys
        )
        guard saveSucceeded else {
            classificationOverrides.removeValue(forKey: messageID)
            customCategoryOverrides.removeValue(forKey: messageID)
            onMembershipChanged(0)
            categoryMutationFailure = "The category change could not be saved."
            return
        }

        categoryReconciliationTask?.cancel()
        categoryReconciliationTask = Task { @MainActor in
            await messageActions.reconcileProjectMembership(messageID)
            guard !Task.isCancelled else { return }
            let remainsMember = committedMembershipExists(
                projectID: row.projectID,
                messageID: messageID
            )
            if remainsMember {
                workspace.statusGestureCoordinator.clear(messageID)
                categoryDepartureNotice = nil
                onMembershipChanged(0)
                return
            }

            let now = Date()
            workspace.statusGestureCoordinator.begin(.resolve, for: [messageID], now: now)
            workspace.statusGestureCoordinator.scheduleDepartingSettle(
                for: [messageID],
                startedAt: now,
                hold: ProjectsWorkspaceState.departingSettleHold
            )
            let categoryName = ProjectCategoryDepartureReason.categoryName(
                previousClassification: previousClassification,
                classification: classification,
                previousCustomCategoryKeys: previousCustomCategoryKeys,
                customCategoryKeys: customCategoryKeys,
                catalog: customCategoryCatalog,
                fallback: priorDetails?.categoryRequirementLabel
            )
            withAnimation(.easeOut(duration: 0.16)) {
                categoryDepartureNotice = ProjectCategoryDepartureNotice(
                    messageID: messageID,
                    projectID: row.projectID,
                    projectName: row.displayLabel,
                    categoryName: categoryName,
                    canUndo: messageActions.canUndoClassification(messageID)
                )
            }
            onMembershipChanged(workspace.statusGestureCoordinator.remainingDepartingHold())
        }
    }

    private func undoCategoryChange(_ notice: ProjectCategoryDepartureNotice) {
        guard notice.canUndo, messageActions.undoClassification(notice.messageID) else {
            categoryDepartureNotice = ProjectCategoryDepartureNotice(
                messageID: notice.messageID,
                projectID: notice.projectID,
                projectName: notice.projectName,
                categoryName: notice.categoryName,
                canUndo: false
            )
            return
        }
        onMembershipChanged(MessageStatusGesturePhase.departingFloor)
        categoryReconciliationTask?.cancel()
        categoryReconciliationTask = Task { @MainActor in
            await messageActions.reconcileProjectMembership(notice.messageID)
            guard !Task.isCancelled else { return }
            if committedMembershipExists(
                projectID: notice.projectID,
                messageID: notice.messageID
            ) {
                workspace.statusGestureCoordinator.clear(notice.messageID)
                withAnimation(.easeOut(duration: 0.14)) {
                    categoryDepartureNotice = nil
                }
                classificationOverrides.removeValue(forKey: notice.messageID)
                customCategoryOverrides.removeValue(forKey: notice.messageID)
            } else {
                categoryDepartureNotice = ProjectCategoryDepartureNotice(
                    messageID: notice.messageID,
                    projectID: notice.projectID,
                    projectName: notice.projectName,
                    categoryName: notice.categoryName,
                    canUndo: false
                )
            }
            onMembershipChanged(0)
        }
    }

    private func keepMessageInProject(_ notice: ProjectCategoryDepartureNotice) {
        do {
            let context = ModelContext(modelContext.container)
            let repository = ManualProjectMembershipRepository(modelContext: context)
            try repository.setMessageDecision(
                projectID: notice.projectID,
                messageID: notice.messageID,
                included: true
            )
            workspace.statusGestureCoordinator.clear(notice.messageID)
            withAnimation(.easeOut(duration: 0.14)) {
                categoryDepartureNotice = nil
            }
            onMembershipChanged(0)
        } catch {
            categoryMutationFailure = error.localizedDescription
        }
    }

    private func committedMembershipExists(projectID: UUID, messageID: UUID) -> Bool {
        let context = ModelContext(modelContext.container)
        let key = MailProjectMembership.key(projectID: projectID, messageID: messageID)
        var descriptor = FetchDescriptor<MailProjectMembership>(
            predicate: #Predicate { $0.membershipKey == key }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first) != nil
    }

    // MARK: - Body loading

    private func kickBodyLoadIfNeeded(messageID: UUID, filterRow: MessageFilterRow?) {
        // A failed load is retryable — expansion is user-driven, so a
        // transient I/O failure must not pin "Message unavailable." for
        // the whole session.
        guard bodyStates[messageID] == nil || bodyStates[messageID] == .failed else { return }
        guard let filterRow else {
            bodyStates[messageID] = .failed
            return
        }
        bodyStates[messageID] = .loading
        let htmlPath = filterRow.bodyHtmlPath
        let textPath = filterRow.bodyTextPath
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                LockReadoutBodyLoader.load(
                    htmlPath: textPath == nil ? htmlPath : nil,
                    textPath: textPath
                )
            }.value
            guard case .loaded(let source) = result else {
                bodyStates[messageID] = .failed
                return
            }
            let bodyContent = LockReadoutBodyContent(source: source)
            // Full body, no character cap: the workroom is the reading
            // surface and the feed scrolls, so nothing is cut (a cap
            // would also append the banned "..." marker).
            if let text = OriginalMessageText.cleaned(from: bodyContent.plainText) {
                bodyStates[messageID] = .loaded(text)
            } else {
                bodyStates[messageID] = .failed
            }
        }
    }

    // MARK: - Focus requests (beacon, citation, dispatch)

    /// Consume a pending `linksFocusRequest`: scroll the target card to
    /// center, ring it with the arrival accent, and open it as a reader
    /// when the request asks for the message tier — the workroom's form
    /// of "fly to the project with the email highlighted".
    @MainActor
    private func applyPendingFocusRequest(row: ProjectRow, scrollProxy: ScrollViewProxy) {
        guard let request = workspace.linksFocusRequest,
              request.projectKey == focusProjectKey,
              row.marks.contains(where: { $0.messageID == request.messageID }) else {
            return
        }
        workspace.focusMessage(request.messageID, projectKey: request.projectKey)
        highlightedMessageID = request.messageID
        if request.expandedMode == .message {
            workspace.workroomExpandedMessageID = request.messageID
            let filterRow = snapshot.messageFilterRows[request.messageID.uuidString]
            kickBodyLoadIfNeeded(
                messageID: request.messageID,
                filterRow: filterRow
            )
            // Opening the reader is reading it, however it opened — same
            // policy as the tap path and the Front Page reader.
            if let filterRow, !filterRow.isRead {
                messageActions.setRead([request.messageID], true)
            }
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            scrollProxy.scrollTo(request.messageID, anchor: .center)
        }
        workspace.completeLinksFocusRequest(request)
    }

    // MARK: - Right-click

    private func handleRightClick(point: NSPoint, view: NSView) {
        guard let hit = hitTester.message(at: CGPoint(x: point.x, y: point.y)) else { return }
        workspace.focusMessage(hit.messageID, projectKey: hit.projectKey)
        onPresentMessageMenu(hit.messageID, point, view)
    }

    // MARK: - Accounts

    private func loadCustomCategoryCatalog() {
        customCategoryCatalog = CustomMailCategoryCatalog.descriptors(in: modelContext)
    }

    /// One fetch per mount: id → (name, address, palette color), so multi-
    /// account projects can carry the Front Page account glyph per card.
    private func loadAccountBadges() {
        let descriptor = FetchDescriptor<Account>()
        guard let accounts = try? modelContext.fetch(descriptor) else { return }
        accountBadges = Dictionary(uniqueKeysWithValues: accounts.map { account in
            (
                account.id,
                WorkroomAccountBadge(
                    name: account.displayName,
                    emailAddress: account.emailAddress,
                    color: AccountColorPalette.color(forIndex: account.colorIndex)
                )
            )
        })
    }
}

private let workroomMonthDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return formatter
}()

private let workroomMonthDayYearFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy")
    return formatter
}()

// MARK: - Email card

enum WorkroomEmailDisclosurePresentation {
    static func chevronName(expanded: Bool) -> String {
        expanded ? "chevron.down" : "chevron.right"
    }

    static func handleSpace(_ action: () -> Void) -> KeyPress.Result {
        action()
        return .handled
    }
}

/// One project email in the Front Page register: kicker (status mark +
/// account glyph + trailing deadline), subject headline, byline, full
/// summary — expanding in place into a reader with the message body.
/// Hover borrows the Front Page card motion and reveals the shared action
/// cluster in a clear band at the bottom-trailing corner.
struct WorkroomEmailCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.readingTextSize) private var readingTextSize
    @FocusState private var disclosureFocused: Bool

    let mark: ProjectMessageMark
    let filterRow: MessageFilterRow?
    let display: ProjectsAnnotationDisplay?
    let statusDescriptor: MessageStatusDescriptor
    let accountBadge: ProjectsWorkroomView.WorkroomAccountBadge?
    let isInComposerQueue: Bool
    let isSummaryRegenerating: Bool
    let isHovered: Bool
    let expanded: Bool
    let highlighted: Bool
    let bodyState: ProjectsWorkroomView.WorkroomBodyState?
    /// The departing (delete / resolve / send-to-Composer) gesture playing on
    /// this card's message, if any — drives the in-place Collapse / Comet exit,
    /// the same one the Front Page cards use.
    let departingGesture: MessageStatusGesture?
    let actions: FrontPageMessageActionHandlers
    let classification: MailClassification?
    let customCategoryKeys: Set<String>
    let customCategoryCatalog: [CustomMailCategoryDescriptor]
    /// Deadline feeds share this card but do not represent one project whose
    /// membership can be inspected or changed from the expanded reader.
    let showsProjectMembershipControls: Bool
    let onToggleExpansion: () -> Void
    let onHoverChange: (Bool) -> Void
    let onClassificationChanged: (MailClassification?, Set<String>) -> Void
    let onShowMembershipDetails: () -> Void

    /// True while a departing gesture owns this card: the card hides its own
    /// chrome so the `DepartingGestureOverlay` *becomes* the card, crumpling in
    /// place (mirrors `FrontPageArticleCard.departingGestureActive`).
    private var departingGestureActive: Bool {
        departingGesture?.action.usesDepartingOverlay == true
    }

    private var actionClusterClearance: CGFloat {
        FrontPageArticleCard.actionClusterClearance(
            revealed: isHovered,
            restHeight: nil,
            padding: 16
        )
    }

    private var actionClusterAnimation: Animation {
        guard !reduceMotion else { return FrontPageCardHoverMotion.actionClusterHide }
        return isHovered
            ? FrontPageCardHoverMotion.actionClusterReveal
            : FrontPageCardHoverMotion.actionClusterHide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // The toggle lives on the header block only: a click inside
            // the expanded reader body must select text, never collapse
            // the card out from under the reading.
            Button(action: onToggleExpansion) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        kicker
                        Text(subjectText)
                            .font(readingTextSize.font(base: 16, weight: .semibold, maximumScale: 1.35))
                            .foregroundStyle(OhiaColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        byline
                        if let summary = summaryText {
                            Text(summary)
                                .font(readingTextSize.font(base: 13))
                                .lineSpacing(readingTextSize.spacing(2.5))
                                .foregroundStyle(OhiaColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if isSummaryRegenerating {
                            SummaryLoadingPlaceholderView(contentWidth: 264)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: WorkroomEmailDisclosurePresentation.chevronName(expanded: expanded))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OhiaColors.textTertiary)
                        .frame(width: 16, height: 16)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(true)
            .focused($disclosureFocused)
            .focusEffectDisabled()
            .onKeyPress(.space) {
                WorkroomEmailDisclosurePresentation.handleSpace(onToggleExpansion)
            }
            .accessibilityLabel(accessibilityText)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Press Space to close email" : "Press Space to open email")
            if expanded {
                Divider()
                    .overlay(OhiaColors.glassBorder)
                    .padding(.vertical, 4)
                if showsProjectMembershipControls {
                    HStack(spacing: 8) {
                        ProjectMessageCategoryControl(
                            classification: classification,
                            customCategoryKeys: customCategoryKeys,
                            customCategoryCatalog: customCategoryCatalog,
                            onChange: onClassificationChanged
                        )
                        Button(
                            "Membership Details…",
                            systemImage: "folder.badge.questionmark",
                            action: onShowMembershipDetails
                        )
                            .buttonStyle(.emblem)
                        Spacer(minLength: 0)
                    }
                }
                readerBody
            }
        }
        // A departing gesture turns the whole card into the Collapse / Comet:
        // its own text fades out and its fill / border clear, so the overlay is
        // the only thing on screen and the page shows through the widening gaps.
        .opacity(departingGestureActive ? 0 : 1)
        .padding(.bottom, actionClusterClearance)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(departingGestureActive ? Color.clear : OhiaColors.glassPanel)
        .background(departingGestureActive ? Color.clear : OhiaColors.spaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            if !departingGestureActive {
                cardBorder
            }
        }
        .shadow(color: selectionGlowColor, radius: 14)
        .shadow(color: selectionGlowColor, radius: 34)
        .compositingGroup()
        .animation(
            reduceMotion ? nil : FrontPageCardHoverMotion.expansion,
            value: isHovered
        )
        .animation(FrontPageCardHoverMotion.highlight, value: isHovered)
        .overlay(alignment: .bottomTrailing) {
            if isHovered && !departingGestureActive {
                actionCluster
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .animation(actionClusterAnimation, value: isHovered)
        // The centred Collapse / Comet, drawn OUTSIDE the clipped card body so
        // its flash / shockwave / comet tail can bloom into the surrounding
        // margin (the parent raises this card's zIndex while it departs).
        .overlay {
            if let departingGesture, departingGesture.action.usesDepartingOverlay {
                DepartingGestureOverlay(
                    action: departingGesture.action,
                    gesture: departingGesture,
                    cornerRadius: 10,
                    iconSize: 30
                )
            }
        }
        .allowsHitTesting(!departingGestureActive)
        .modifier(ComposerDepartureSource(messageIDs: [mark.messageID], inScrollView: true))
        .onHover { hovering in
            disclosureFocused = hovering
            onHoverChange(hovering)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Chrome

    @ViewBuilder
    private var cardBorder: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        if highlighted {
            // Arrival emphasis — the same neon recipe as the Time surface's
            // selected-row ring, so "the beacon brought me here" reads in
            // the lens's one selection language.
            ZStack {
                shape.stroke(OhiaColors.chipActiveBorder.opacity(0.40), lineWidth: 10).blur(radius: 12)
                shape.stroke(OhiaColors.chipActiveBorder.opacity(0.70), lineWidth: 3.5).blur(radius: 3.5)
                shape.strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1)
            }
        } else if expanded {
            shape.strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 2)
        } else if isHovered {
            shape.strokeBorder(OhiaColors.chipActiveBorder.opacity(0.5), lineWidth: 1)
        } else {
            shape.strokeBorder(OhiaColors.glassBorder, lineWidth: 1)
        }
    }

    /// Same dual-radius aura as a selected Front Page card. The Projects lens
    /// pins the dark register, so `chipActiveBorder` resolves to the yellow accent.
    private var selectionGlowColor: Color {
        expanded ? OhiaColors.chipActiveBorder.opacity(0.42) : .clear
    }

    // MARK: Rows

    private var kicker: some View {
        HStack(spacing: 6) {
            MessageStatusMark(
                descriptor: statusDescriptor,
                size: 14,
                showsDeadlineSignal: false,
                showsTextGloss: true,
                glossFont: readingTextSize.font(base: 11, weight: .semibold, maximumScale: 1.25)
            )
            if let accountBadge {
                FrontPageAccountIndicator(
                    accountName: accountBadge.name,
                    accountEmailAddress: accountBadge.emailAddress,
                    accountColor: accountBadge.color,
                    size: 13
                )
            }
            MessageStatusDeadlineMark(
                descriptor: statusDescriptor,
                size: 14,
                glossFont: readingTextSize.font(base: 11, weight: .semibold, maximumScale: 1.25)
            )
            .layoutPriority(-1)
            Spacer(minLength: 0)
        }
    }

    private var byline: some View {
        HStack(spacing: 6) {
            Text(bylineText)
                .font(readingTextSize.font(base: 12.5, weight: .medium, maximumScale: 1.35))
                .foregroundStyle(OhiaColors.textSecondary)
                .lineLimit(1)
            if let dateLabel = display?.derived.dateLabel, !dateLabel.isEmpty {
                Text("·")
                    .foregroundStyle(OhiaColors.textTertiary)
                Text(dateLabel)
                    .font(readingTextSize.font(base: 12.5, maximumScale: 1.35))
                    .foregroundStyle(OhiaColors.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var readerBody: some View {
        switch bodyState {
        case .loading, nil:
            SummaryLoadingPlaceholderView(contentWidth: 264)
        case .failed:
            Text("Message unavailable.")
                .font(readingTextSize.font(base: 13).italic())
                .foregroundStyle(OhiaColors.textTertiary)
        case .loaded(let text):
            Text(text)
                .font(readingTextSize.font(base: 15))
                .lineSpacing(readingTextSize.spacing(3))
                .foregroundStyle(OhiaColors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The Front Page card cluster, verbatim in shape: Compose (inbound
    /// only), Resolve, Delete, Mark replied / confirmed when the message
    /// carries that obligation, Flag toggle. It uses the same unplated
    /// bottom-trailing presentation as Front Page.
    private var actionCluster: some View {
        HStack(spacing: 2) {
            if !mark.isSentByUser {
                ComposeClusterButton(isInQueue: isInComposerQueue) {
                    actions.sendToComposer([mark.messageID])
                }
            }
            ClusterButtonChip(
                glyph: .native("checkmark.circle.fill"),
                tint: MessageStatusColors.confirmation,
                help: "Resolved"
            ) {
                actions.setResolved([mark.messageID], true)
            }
            ClusterButtonChip(
                glyph: .native("xmark.bin.circle.fill"),
                tint: OhiaColors.ohiaRed,
                help: "Delete"
            ) {
                actions.delete([mark.messageID])
            }
            if mark.obligationKinds.contains(.pendingReply) {
                ClusterButtonChip(
                    glyph: .markReplied,
                    tint: MessageStatusColors.pendingReply,
                    help: "Mark replied"
                ) {
                    actions.setReplied([mark.messageID], true)
                }
            }
            if mark.obligationKinds.contains(.confirmation) {
                ClusterButtonChip(
                    glyph: .knockout("checkmark.seal.fill"),
                    tint: MessageStatusColors.confirmation,
                    help: "Mark confirmed"
                ) {
                    actions.setConfirmed([mark.messageID], true)
                }
            }
            ClusterButtonChip(
                glyph: mark.isFlagged ? .native("flag.slash.circle.fill") : .native("flag.circle.fill"),
                tint: MessageStatusColors.flagged,
                help: mark.isFlagged ? "Unflag" : "Flag"
            ) {
                actions.setFlagged([mark.messageID], !mark.isFlagged)
            }
        }
    }

    // MARK: Derived text

    private var subjectText: String {
        let subject = filterRow?.subject ?? mark.subject
        return subject.isEmpty ? "(no subject)" : subject
    }

    /// "Mei LIN" for received mail, "to Mei LIN" for sent — the
    /// same direction-aware counterparty the hover readout renders.
    private var bylineText: String {
        guard let derived = display?.derived else {
            return mark.isSentByUser ? "Sent" : "Received"
        }
        if derived.senderLabel.isEmpty {
            return mark.isSentByUser ? "Sent" : "Received"
        }
        return derived.senderPrefix.isEmpty
            ? derived.senderLabel
            : "\(derived.senderPrefix) \(derived.senderLabel)"
    }

    private var summaryText: String? {
        guard let summary = display?.item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return nil
        }
        return summary
    }

    private var accessibilityText: String {
        var parts = [subjectText, bylineText]
        if let dateLabel = display?.derived.dateLabel, !dateLabel.isEmpty {
            parts.append(dateLabel)
        }
        parts.append(expanded ? "Collapse message" : "Expand message")
        return parts.joined(separator: ". ")
    }
}

struct ProjectFileCatalogTaskKey: Equatable {
    let projectKey: String
    let summaryRequestKey: String
    let filesRevision: Int
    let attachmentDataRevision: Int
}
