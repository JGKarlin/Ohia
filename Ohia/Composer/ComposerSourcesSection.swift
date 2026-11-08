// Ohia/Composer/ComposerSourcesSection.swift
// The shared Sources list for both Composer steps: every piece of evidence
// the model grounds the reply in. Automatic sources are compiled by the
// drafting pipeline when it seeds the draft row (thread history, past
// replies, memories, attachments, retrieved emails); the user appends their
// own — searched past emails, thread siblings, attachment text, free notes,
// files from disk — via the Add popover. Mutations write straight to
// `Draft.sourcesJSON` and re-project the session; an existing draft body is
// never regenerated automatically (the Regenerate button covers that).

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import OhiaCore
import OhiaIngest
import OhiaML
import OhiaScheduler

/// Shared hover disclosure behavior for Composer evidence sections.
enum ComposerDisclosureState: Hashable {
    case closed
    case open
    case locked

    static var animation: Animation { .easeInOut(duration: 0.32) }
    static var transition: AnyTransition { .opacity.combined(with: .move(edge: .top)) }

    init(startsExpanded: Bool) {
        self = startsExpanded ? .locked : .open
    }

    func isExpanded(isHovering: Bool) -> Bool {
        switch self {
        case .closed:
            return false
        case .open:
            return isHovering
        case .locked:
            return true
        }
    }

    var next: ComposerDisclosureState {
        switch self {
        case .closed:
            return .locked
        case .open:
            return .closed
        case .locked:
            return .open
        }
    }

    func chevronName(isExpanded: Bool) -> String {
        if self == .locked { return "chevron.left" }
        return isExpanded ? "chevron.down" : "chevron.right"
    }

    func helpText(title: String, isExpanded: Bool) -> String {
        switch self {
        case .closed:
            return "Lock \(title) open"
        case .open:
            return isExpanded ? "Close \(title)" : "Keep \(title) closed"
        case .locked:
            return "Return \(title) to hover"
        }
    }

    func accessibilityLabel(title: String, isExpanded: Bool) -> String {
        switch self {
        case .closed:
            return "Lock \(title)"
        case .open:
            return isExpanded ? "Close \(title)" : "Keep \(title) closed"
        case .locked:
            return "Return \(title) to hover"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .closed:
            return "Closed"
        case .open:
            return "Open on hover"
        case .locked:
            return "Locked open"
        }
    }
}

struct ComposerDisclosureHeaderButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

nonisolated enum ComposerSourcePresentation {
    static let condensedContextMarker = "[CONDENSED TO FIT CONTEXT]"

    static func displayLabel(for source: ComposerSource) -> String {
        guard source.kind == .memory else { return source.label }
        let classificationPrefix = "Classification — "
        guard source.label.hasPrefix(classificationPrefix) else { return source.label }
        return "Category — \(source.label.dropFirst(classificationPrefix.count))"
    }

    static func condensedStatus(for source: ComposerSource) -> String? {
        guard source.kind == .file,
              source.snippet.hasPrefix(condensedContextMarker) else { return nil }
        return "Condensed to fit context"
    }
}

/// Compact attachment context carried with a searched email or thread source.
/// This deliberately uses only persisted metadata and generated summaries —
/// never extracted document contents or OCR text — so adding an email cannot
/// unexpectedly consume the Composer's context window.
@MainActor
enum ComposerEmailAttachmentMetadata {
    static func appending(to bodyText: String, attachments: [Attachment]) -> String {
        guard let digest = digest(for: attachments) else { return bodyText }
        return bodyText + "\n\n" + digest
    }

    static func digest(for attachments: [Attachment]) -> String? {
        let entries = attachments
            .filter { $0.isInline != true }
            .map(entry)
        guard !entries.isEmpty else { return nil }
        return "[ATTACHMENT METADATA]\n" + entries.joined(separator: "\n\n")
    }

    private static func entry(for attachment: Attachment) -> String {
        var lines = ["- \(attachment.filename)"]
        var descriptors: [String] = []

        if let kind = cleaned(attachment.detectedDocumentKind) {
            descriptors.append(kind.uppercased())
        } else if let mimeType = cleaned(attachment.mimeType) {
            descriptors.append(mimeType)
        }
        if let unit = cleaned(attachment.extractionStructureUnitKind),
           let count = attachment.extractionStructureUnitCount,
           count > 0 {
            descriptors.append("\(count) \(count == 1 ? unit : unit + "s")")
        }
        if !descriptors.isEmpty {
            lines.append("  \(descriptors.joined(separator: " · "))")
        }
        if let title = cleaned(attachment.documentTitle) {
            lines.append("  Title: \(title)")
        }
        if let author = cleaned(attachment.documentAuthor) {
            lines.append("  Author: \(author)")
        }

        if let evidence = AttachmentEvidencePacket(attachment: attachment) {
            if let summary = evidence.visualSummary {
                lines.append("  Visual caption: \(summary)")
            }
            if let capture = evidence.captureMetadata {
                lines.append(contentsOf: capture.split(separator: "\n").map { "  \($0)" })
            }
            if let summary = evidence.attachmentSummary {
                lines.append("  Document summary: \(summary)")
            }
            if let labels = evidence.labelsLine {
                lines.append("  Vision labels: \(labels)")
            }
            if let objects = evidence.objectsLine {
                lines.append("  Detected objects: \(objects)")
            }
        } else {
            if let summary = cleaned(attachment.visualSummary) {
                lines.append("  Visual caption: \(summary)")
            }
            if let summary = AttachmentSummaryPostProcessor.clean(attachment.attachmentSummary) {
                lines.append("  Document summary: \(summary)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// What the shared Sources section needs from whichever view model hosts it —
/// the reply `ComposerSession` (backed by an inbound `Message`) or the compose
/// `ComposeState` (a standalone draft with no message). The host owns the
/// decoded source list and re-projection; the section reads it for display and
/// writes mutations straight to the backing `Draft`.
@MainActor
protocol ComposerSourceHost: AnyObject, Observable {
    /// Equality-guarded, decoded source list (display, counts, existing-ID sets).
    var sources: [ComposerSource] { get }
    /// True once the backing `Draft` row exists, unlocking the Add affordance.
    var hasDraftRow: Bool { get }
    /// True only while automatic source compilation is the active phase.
    var showsSourcesLoadingIndicator: Bool { get }
    /// False while the worker owns an automatic research merge.
    var sourceMutationsEnabled: Bool { get }
    /// True when the displayed generated version used a different source set.
    var hasPendingSourceChanges: Bool { get }
    /// Thread emails added to the sources after the displayed version was
    /// generated. Zero for hosts without a thread.
    var pendingThreadEmailCount: Int { get }
    /// True when sources differ from the active completed Decisions version.
    var hasPendingDecisionSourceChanges: Bool { get }
    /// Whether this host can surface thread-sibling and attachment candidates.
    /// False for compose-from-scratch — there is no inbound message or thread.
    var supportsMessageCandidates: Bool { get }
    /// The worker's current writer-window measurement of these sources: which
    /// automatic sources the draft writer leaves out, and whether the content
    /// it keeps fits at all. Nil while unmeasured or being measured again.
    var sourceContextUsage: ComposerWriterWindowUsage? { get }
    /// Asynchronous source additions still running. Each finishes through
    /// the Sources column's view (its model context and its alerts), which
    /// stays mounted whether the column is open or closed to its rail; the
    /// rail shows a spinner while this is above zero.
    var inFlightSourceAdditionCount: Int { get set }
    /// The writer-window overflow measurement already warned about, so each
    /// measurement warns once however often the Sources column remounts.
    var warnedWriterOverflowFingerprint: String? { get set }
    /// Resolves the `Draft` that owns `sourcesJSON`, re-fetched in `context` to
    /// dodge stale cross-process relationships. Nil before the row exists.
    func backingDraft(in context: ModelContext) -> Draft?
    /// The message whose thread/attachments seed the candidate lists, or nil
    /// for compose-from-scratch.
    func candidateMessage(in context: ModelContext) -> Message?
    /// The address of the person this draft is with — the inbound sender for
    /// a reply, or the primary "To" recipient for a from-scratch compose.
    /// Nil when nothing is resolved yet (e.g. a compose with no recipient
    /// chosen). Used only to default the manual Messages picker onto the
    /// right contact; not authoritative for anything the drafting engine
    /// itself reasons about.
    func correspondentAddress(in context: ModelContext) -> String?
    /// Re-project the host's view-model state after `sourcesJSON` changed.
    func reloadAfterSourceMutation(in context: ModelContext)
}

extension ComposerSourceHost {
    var showsSourcesLoadingIndicator: Bool { false }
    var pendingThreadEmailCount: Int { 0 }
    var sourcesLeftOutOfDraft: Set<UUID> { Set(sourceContextUsage?.leftOutSourceIDs ?? []) }

    /// The red notice that sources changed since the displayed draft or
    /// Decisions version, or nil when nothing waits on the author. Shown in
    /// the Sources column, and marked on its rail while it is closed.
    var pendingSourceChangeNotice: String? {
        if pendingThreadEmailCount > 0 {
            return pendingThreadEmailCount == 1
                ? "1 new email in this thread since this draft · Regenerate to apply"
                : "\(pendingThreadEmailCount) new emails in this thread since this draft · Regenerate to apply"
        }
        if hasPendingDecisionSourceChanges {
            return "Re-check sources to update draft questions"
        }
        if hasPendingSourceChanges {
            return "Regenerate to apply source changes"
        }
        return nil
    }

    /// Identifies a measurement whose kept content does not fit, so each such
    /// measurement warns once.
    var writerOverflowFingerprint: String? {
        guard let usage = sourceContextUsage, !usage.fits else { return nil }
        return usage.requestFingerprint
    }
}

/// Warns once per writer-window measurement whose kept sources cannot fit:
/// drafting will be rejected, so say so while the author can still change
/// sources. Attached to the Sources column slot, which stays mounted whether
/// the column is open or closed, so the warning reaches the author either way.
struct ComposerSourceOverflowWarning<Host: ComposerSourceHost>: ViewModifier {
    let host: Host
    @State private var warning: ComposerSourceCapacityWarning?

    func body(content: Content) -> some View {
        content
            .onChange(of: host.writerOverflowFingerprint, initial: true) { _, fingerprint in
                guard let fingerprint,
                      fingerprint != host.warnedWriterOverflowFingerprint,
                      let usage = host.sourceContextUsage else { return }
                host.warnedWriterOverflowFingerprint = fingerprint
                warning = ComposerSourceCapacityWarning(overflow: usage)
            }
            .alert(item: $warning) { warning in
                Alert(
                    title: Text("Source Won’t Fit"),
                    message: Text(warning.message),
                    dismissButton: .cancel(Text("Cancel"))
                )
            }
    }
}

@MainActor
enum ComposerSourceMutationPersistence {
    static func prepareForRecheck(draft: Draft) {
        let previous = ComposerInterviewStateCoding.decode(draft.interviewStateJSON)
        if let previous, previous.contractVersion != ComposerInterviewPlanner.contractVersion {
            // Older automatic evidence can contain only prefixes or directory
            // listings. The explicit re-check refreshes that extraction.
            draft.automaticSourceResearchStateRaw = nil
            draft.beginAutomaticSourceResearchIfNeeded()
        }
        draft.interviewStateJSON = previous
            .map { ComposerInterviewDraftInputCompiler.rechecking($0) }
            .flatMap { ComposerInterviewStateCoding.encode($0) }
        draft.decisionResearchOverlayJSON = nil
    }

    static func prepareForPersistence(
        draft: Draft,
        original: [ComposerSource],
        mutated: [ComposerSource]
    ) -> Bool {
        guard mutated != original else { return false }
        if draft.resolvedStage == DraftStage.evaluatingSources,
           draft.generationFailureCount != nil {
            draft.clearGenerationBackoff()
        }
        ComposerDecisionHistoryPersistence.captureCurrentVersionIfNeeded(
            on: draft,
            sourceBaseline: original
        )
        ComposerDecisionHistoryPersistence.refreshActiveVersionFromDraft(on: draft)
        if !ComposerDecisionHistoryPersistence.restoreDecisionStateIfSourcesMatchActiveVersion(
            mutated,
            on: draft
        ) {
            draft.interviewStateJSON = ComposerInterviewStateCoding.decode(draft.interviewStateJSON)
                .map { ComposerInterviewDraftInputCompiler.rechecking($0) }
                .flatMap { ComposerInterviewStateCoding.encode($0) }
            draft.decisionResearchOverlayJSON = nil
        }
        if draft.generatedSourcesJSON == nil,
           !draft.orderedRevisions.isEmpty {
            draft.generatedSourcesJSON = ComposerSourceCoding.encode(original)
        }
        // The count clears until the worker measures the edited list. The
        // fit detail stays: its essential tokens do not depend on the sources
        // that can be left out or added, so the add-source check keeps an
        // honest allowance while the left-out marks wait for the new count.
        draft.sourceContextTokenCount = nil
        draft.sourceContextMeasurementRequestedAt = Date()
        return true
    }
}

@MainActor
enum ComposerSourceContextMeasurementScheduler {
    /// Requests a measurement for sources never measured against the draft
    /// writer's budget, including rows measured before the writer window
    /// existed, and for a count whose fit detail does not decode. A
    /// measurement that could not compile the request keeps the budget with no
    /// count and is not requested again until sources change.
    static func requestIfNeeded(draft: Draft, context: ModelContext) {
        guard draft.sourcesJSON != nil, draft.sourceContextMeasurementRequestedAt == nil else { return }
        let measuredForWriter = draft.sourceContextTokenLimit == ComposerWriterWindow.promptBudget
        let undecodableFit = draft.sourceContextTokenCount != nil
            && ComposerWriterWindowUsage.currentCount(draft.sourceContextTokenCount,
                fitJSON: draft.sourceContextFitJSON) == nil
        guard !measuredForWriter || undecodableFit else { return }
        // The legacy count was against the old allowance; the writer budget
        // shows while the new measurement runs.
        draft.sourceContextTokenCount = nil
        draft.sourceContextTokenLimit = ComposerWriterWindow.promptBudget
        draft.sourceContextMeasurementRequestedAt = Date()
        do {
            try stageMeasurement(draft: draft, context: context)
            try context.save()
        } catch {
            context.rollback()
            print("[Ohia] Composer source-context measurement enqueue failed: \(String(reflecting: type(of: error)))")
        }
    }

    /// Answers and reopened decisions are writer inputs: the writer fit is
    /// measured again. The caller saves.
    static func requestAfterDecisionChange(draft: Draft, context: ModelContext) {
        guard draft.sourcesJSON != nil else { return }
        draft.sourceContextTokenCount = nil
        draft.sourceContextMeasurementRequestedAt = Date()
        do {
            try stageMeasurement(draft: draft, context: context)
        } catch {
            print("[Ohia] Composer source-context measurement enqueue failed: \(String(reflecting: type(of: error)))")
        }
    }

    static func stageMeasurement(draft: Draft, context: ModelContext) throws {
        try ComposerDraftSyncScheduler.stageDraftSync(draft: draft, context: context)
        if let messageID = draft.message?.id {
            try ComposerQueueMembership.stageTargetedDraftJob(
                messageID: messageID,
                context: context
            )
        } else if try JobFetch.activeJobExists(
            type: .generateDraft,
            context: context
        ) == false {
            JobQueue().stage(
                type: .generateDraft,
                priority: ComposerDraftScheduling.userInitiatedPriority,
                context: context
            )
        }
    }
}

struct ComposerSourcesSection<Host: ComposerSourceHost>: View {
    @Bindable var host: Host
    /// Decisions step shows the grounding explanation under the header; the
    /// Draft step's narrow side panel omits it.
    var showsExplanation: Bool
    /// Draft-step panel mode: the row list scrolls and fills the panel
    /// height when internal scrolling is enabled.
    var fillsHeight: Bool
    /// Composer decisions can host sources in the same outer scroll as the
    /// other sections; the draft side panel keeps its dedicated list scroll.
    var allowsInternalScroll: Bool
    /// Decisions-step mode: render the component as a peer section card so it
    /// aligns with the message and questions sections.
    var usesSectionChrome: Bool
    /// Forces the section open while the host is compiling sources. When this
    /// returns to false, Decisions-step chrome returns to user control.
    private var forceExpanded: Bool
    /// Open state, toggle, and close chevron when this section is the
    /// Composer's Sources column (`fillsHeight`).
    private var columnControl: ComposerColumnControl?

    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var appServices: AppServices?

    // Settings → Sources enablement: a switched-off provider disappears from
    // the Add popover (its picker sheet stays unreachable while off).
    @AppStorage(
        ComposerSourceProviderPreference.storageKey(for: .calendar),
        store: OhiaSharedDefaults.store
    )
    private var calendarSourceEnabled: Bool = ComposerSourceProviderPreference.defaultEnabled
    @AppStorage(
        ComposerSourceProviderPreference.storageKey(for: .contacts),
        store: OhiaSharedDefaults.store
    )
    private var contactsSourceEnabled: Bool = ComposerSourceProviderPreference.defaultEnabled
    @AppStorage(
        ComposerSourceProviderPreference.storageKey(for: .appleNotes),
        store: OhiaSharedDefaults.store
    )
    private var appleNotesSourceEnabled: Bool = ComposerSourceProviderPreference.defaultEnabled
    @AppStorage(
        ComposerSourceProviderPreference.storageKey(for: .screenshot),
        store: OhiaSharedDefaults.store
    )
    private var screenshotSourceEnabled: Bool = ComposerSourceProviderPreference.defaultEnabled
    @AppStorage(
        ComposerSourceProviderPreference.storageKey(for: .messages),
        store: OhiaSharedDefaults.store
    )
    private var messagesSourceEnabled: Bool = ComposerSourceProviderPreference.defaultEnabled

    /// User-controlled disclosure state. Hover never opens the section.
    @State private var isUserExpanded: Bool
    @State private var showAddPopover = false
    @State private var showSearchSheet = false
    @State private var showNoteSheet = false
    @State private var showNotesAppSheet = false
    @State private var showCalendarSheet = false
    @State private var showContactSheet = false
    @State private var showWebsiteSheet = false
    @State private var expandThreadCandidates = false
    @State private var expandAttachmentCandidates = false
    @State private var showScreenshotSheet = false
    @State private var showMessagesSheet = false
    @FocusState private var sectionFocused: Bool
    /// Candidate snapshots taken when the Add popover opens, so the 2.5s
    /// store poll can't reorder or refetch the lists mid-interaction. Rows
    /// are removed locally as they're added.
    @State private var siblingCandidates: [Message] = []
    @State private var attachmentCandidateRows: [Attachment] = []
    @State private var addingThreadCandidateIDs: Set<UUID> = []
    @State private var addingAttachmentCandidateIDs: Set<UUID> = []
    @State private var isAddingEntireThread = false
    /// Enabled MCP servers, loaded when the Add popover opens.
    @State private var mcpServers: [MCPConfiguredServer] = []
    @State private var mcpPickerServer: MCPConfiguredServer?
    @State private var sourceCapacityWarning: ComposerSourceCapacityWarning?
    @State private var processingFileName: String?
    @State private var fileSourceFailure: ComposerFileSourceFailure?

    init(
        host: Host,
        showsExplanation: Bool = false,
        fillsHeight: Bool = false,
        startsExpanded: Bool = true,
        forceExpanded: Bool = false,
        allowsInternalScroll: Bool = true,
        usesSectionChrome: Bool = false,
        columnControl: ComposerColumnControl? = nil
    ) {
        self.host = host
        self.showsExplanation = showsExplanation
        self.fillsHeight = fillsHeight
        self.allowsInternalScroll = allowsInternalScroll
        self.usesSectionChrome = usesSectionChrome
        self.forceExpanded = forceExpanded
        self.columnControl = columnControl
        _isUserExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        sectionBody
        .onChange(of: forceExpanded) { wasForcedOpen, isForcedOpen in
            if wasForcedOpen, !isForcedOpen {
                withAnimation(ComposerDisclosureState.animation) {
                    isUserExpanded = false
                }
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            SourceEmailSearchSheet(
                existingMessageIDs: Set(host.sources.compactMap(\.messageID)),
                accountID: sourceSearchAccountID(),
                onAdd: { await addEmailSource($0) }
            )
        }
        .sheet(isPresented: $showNoteSheet) {
            SourceNoteSheet { text in
                append(ComposerSource(kind: .note, label: "Memo", snippet: text, isUserAdded: true))
            }
        }
        .sheet(isPresented: $showNotesAppSheet) {
            SourceNotesPickerSheet { append($0) }
        }
        .sheet(isPresented: $showCalendarSheet) {
            SourceCalendarPickerSheet { append($0) }
        }
        .sheet(isPresented: $showContactSheet) {
            SourceContactPickerSheet { append($0) }
        }
        .sheet(isPresented: $showMessagesSheet) {
            SourceMessagesPickerSheet(defaultAddress: host.correspondentAddress(in: modelContext)) { append($0) }
        }
        .sheet(isPresented: $showWebsiteSheet) {
            SourceWebsitePasteSheet { append($0) }
        }
        .sheet(isPresented: $showScreenshotSheet) {
            SourceScreenshotPickerSheet { append($0) }
        }
        .sheet(item: $mcpPickerServer) { server in
            SourceMCPPickerSheet(server: server) { append($0) }
        }
        .alert(item: $sourceCapacityWarning) { warning in
            Alert(
                title: Text("Source Won’t Fit"),
                message: Text(warning.message),
                dismissButton: .cancel(Text("Cancel"))
            )
        }
        .alert(item: $fileSourceFailure) { failure in
            Alert(
                title: Text("File Could Not Be Added"),
                message: Text(failure.message),
                dismissButton: .cancel(Text("OK"))
            )
        }
    }

    // MARK: - Header

    private var isExpanded: Bool {
        fillsHeight || forceExpanded || isUserExpanded
    }

    @ViewBuilder
    private var sectionBody: some View {
        if fillsHeight {
            // The Draft-step Sources column is fixed chrome: it stays open and
            // its row list owns any overflow scrolling.
            content
        } else if usesSectionChrome {
            content
                .padding(8)
                .background(OhiaColors.chipRestBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            sectionFocused ? OhiaColors.ohiaYellow : OhiaColors.chipRestBorder,
                            lineWidth: sectionFocused ? 1.5 : 1
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .focusable(true)
                .focused($sectionFocused)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { handleSectionKeyPress($0) }
                .onHover { hovering in
                    withAnimation(ComposerDisclosureState.animation) {
                        sectionFocused = hovering
                    }
                }
        } else {
            content
                .contentShape(Rectangle())
                .focusable(true)
                .focused($sectionFocused)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { handleSectionKeyPress($0) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let columnControl {
            ComposerColumnSlide(control: columnControl) {
                openContent
            } rail: {
                rail(columnControl)
            }
        } else {
            openContent
        }
    }

    private var openContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if fillsHeight {
                // The column's full-width Add, matching Queue's New Message.
                addButton {
                    Label("Add Source", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 7, verticalPadding: 5))
            }
            if let notice = host.pendingSourceChangeNotice {
                Label(notice, systemImage: "arrow.clockwise")
                    .font(OhiaTypography.cardDetail)
                    .fontWeight(.regular)
                    .foregroundStyle(OhiaColors.ohiaRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isExpanded {
                expandedContent
                    .transition(ComposerDisclosureState.transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .animation(ComposerDisclosureState.animation, value: isExpanded)
    }

    @ViewBuilder
    private var expandedContent: some View {
        if showsExplanation {
            Text("The model answers from these sources first; the questions below are only what the sources can't settle.")
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if host.sources.isEmpty, processingFileName == nil {
            emptyState
        } else {
            rowList
        }
    }

    @ViewBuilder
    private var header: some View {
        if fillsHeight {
            ComposerColumnHeader(control: columnControl, columnTitle: "Sources") {
                ComposerSectionHeader(
                    title: "Sources",
                    symbolName: "doc.text.magnifyingglass",
                    titleWeight: .bold
                )
            }
        } else {
            HStack(spacing: 6) {
                ComposerDisclosureHeaderButton {
                    toggleOpen()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: chevronName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(OhiaColors.textTertiary)
                        // No count badge — the live source count already lives in the
                        // bottom grounding bar ("Sources N").
                        ComposerSectionHeader(
                            title: "Sources",
                            symbolName: "doc.text.magnifyingglass",
                            titleWeight: .bold
                        )
                        Spacer()
                    }
                }
                .help(disclosureHelpText)
                .accessibilityLabel(disclosureHelpText)
                .accessibilityValue(disclosureAccessibilityValue)

                addButton
            }
        }
    }

    /// Down while open, right while closed.
    private var chevronName: String {
        isExpanded ? "chevron.down" : "chevron.right"
    }

    private var disclosureHelpText: String {
        if forceExpanded { return "Sources stay open while compiling" }
        return isExpanded ? "Collapse Sources" : "Expand Sources"
    }

    private var disclosureAccessibilityValue: String {
        if forceExpanded { return "Open while compiling" }
        return isExpanded ? "Open" : "Closed"
    }

    private func handleSectionKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard sectionFocused, press.key == .space else { return .ignored }
        toggleOpen()
        return .handled
    }

    private func toggleOpen() {
        withAnimation(ComposerDisclosureState.animation) {
            sectionFocused = true
            isUserExpanded.toggle()
        }
    }

    private var addButton: some View {
        addButton {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                Text("Add")
                    .font(OhiaTypography.cardDetail)
            }
        }
        .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 3))
    }

    /// The Add button, opening the Add popover: "+ Add Source" under the
    /// column's header, "+" on the closed column's rail, and "+ Add" beside
    /// the header of the section used outside the column.
    private func addButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Button {
            showAddPopover.toggle()
        } label: {
            label()
        }
        // Add writes to the backing Draft row; until it exists there is nothing
        // to hold the source, so Add waits for the row.
        .disabled(
            !host.hasDraftRow
                || !host.sourceMutationsEnabled
                || processingFileName != nil
        )
        .help(!host.hasDraftRow
            ? "Sources unlock once this message's draft row is prepared"
            : (processingFileName != nil
                ? "Wait for the selected file to finish processing"
                : (host.sourceMutationsEnabled
                ? "Add a source the reply should draw on"
                : "Sources unlock after automatic research finishes")))
        // The rail sits at the stage's leading edge, so its popover opens
        // beside it rather than below.
        .popover(isPresented: $showAddPopover, arrowEdge: columnControl?.isOpen == false ? .trailing : .bottom) {
            addPopoverContent
        }
    }

    // MARK: - Rail

    /// The closed Sources column: Add, a red mark when sources changed since
    /// the draft, a spinner while a source is being added, then one icon per
    /// source type with its count. A type's tooltip lists its sources;
    /// clicking it opens the column.
    private func rail(_ control: ComposerColumnControl) -> some View {
        ComposerColumnRailBody(
            control: control,
            title: "Sources",
            symbolName: "doc.text.magnifyingglass"
        ) {
            addButton {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 7, verticalPadding: 5))
            .accessibilityLabel("Add Source")

            if let notice = host.pendingSourceChangeNotice {
                ComposerRailAttentionMark(notice: notice)
            }
            if let processingFileName {
                ComposerRailSpinner(tint: OhiaColors.iconPillForeground)
                    .frame(width: 12, height: 12)
                    .help("Processing \(processingFileName)")
            } else if host.inFlightSourceAdditionCount > 0 {
                ComposerRailSpinner(tint: OhiaColors.iconPillForeground)
                    .frame(width: 12, height: 12)
                    .help("Adding a source")
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(ComposerSourceTypeGroup.groups(for: host.sources, leftOut: host.sourcesLeftOutOfDraft)) { group in
                        railTypeItem(group, control: control)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
    }

    private func railTypeItem(_ group: ComposerSourceTypeGroup, control: ComposerColumnControl) -> some View {
        Button {
            control.toggle()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: group.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(group.isAllLeftOut ? OhiaColors.textSecondary : OhiaColors.iconPillForeground)
                Text("\(group.sources.count)")
                    .font(OhiaTypography.cardSignal.monospacedDigit())
                    .foregroundStyle(OhiaColors.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Stored labels, not `displayLabel(for:)`: the rail re-renders on the
        // Composer's poll, and that resolves thread labels with a store fetch.
        .help(group.helpText(label: ComposerSourcePresentation.displayLabel(for:)))
        .accessibilityLabel("\(group.name), \(group.sources.count)")
        .accessibilityHint("Opens the Sources column")
    }

    // MARK: - Add popover

    private var addPopoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            popoverSectionLabel("Mail")
            popoverActionRow(symbol: "magnifyingglass", title: "Search Past Emails") {
                showAddPopover = false
                showSearchSheet = true
            }
            // Thread siblings and attachments only exist for a reply's inbound
            // message; compose-from-scratch has neither.
            if host.supportsMessageCandidates {
                threadCandidatesDisclosure
                attachmentCandidatesDisclosure
            }

            if appleNotesSourceEnabled || calendarSourceEnabled || contactsSourceEnabled || messagesSourceEnabled {
                popoverSectionLabel("Mac Apps")
                if appleNotesSourceEnabled {
                    popoverActionRow(symbol: "note.text", title: "Apple Notes") {
                        showAddPopover = false
                        showNotesAppSheet = true
                    }
                }
                if calendarSourceEnabled {
                    popoverActionRow(symbol: "calendar", title: "Calendar") {
                        showAddPopover = false
                        showCalendarSheet = true
                    }
                }
                if contactsSourceEnabled {
                    popoverActionRow(symbol: "person.crop.rectangle", title: "Contacts") {
                        showAddPopover = false
                        showContactSheet = true
                    }
                }
                if messagesSourceEnabled {
                    popoverActionRow(symbol: "message", title: "Messages") {
                        showAddPopover = false
                        showMessagesSheet = true
                    }
                }
            }

            if !mcpServers.isEmpty {
                popoverSectionLabel("MCP Servers")
                ForEach(mcpServers) { server in
                    popoverActionRow(symbol: "server.rack", title: server.displayName) {
                        showAddPopover = false
                        mcpPickerServer = server
                    }
                }
            }

            popoverSectionLabel("Your Own")
            popoverActionRow(symbol: "pencil.line", title: "Memo") {
                showAddPopover = false
                showNoteSheet = true
            }
            popoverActionRow(symbol: "globe", title: "Website") {
                showAddPopover = false
                showWebsiteSheet = true
            }
            if screenshotSourceEnabled {
                popoverActionRow(symbol: "camera.viewfinder", title: "Screenshot") {
                    showAddPopover = false
                    showScreenshotSheet = true
                }
            }
            popoverActionRow(symbol: "doc", title: "File on Disk") {
                showAddPopover = false
                addFileFromDisk()
            }
        }
        .padding(8)
        .frame(width: 320)
        .composerPresentationFrame(inset: 8, cornerRadius: 8)
        .onAppear {
            siblingCandidates = threadSiblingCandidates()
            attachmentCandidateRows = attachmentCandidates()
            mcpServers = MCPServerStore.loadRecords().filter(\.isEnabled)
        }
    }

    // MARK: - Candidate disclosures

    @ViewBuilder
    private var threadCandidatesDisclosure: some View {
        candidateDisclosureHeader(
            title: "From This Thread",
            symbol: "bubble.left.and.bubble.right",
            count: siblingCandidates.count,
            isExpanded: $expandThreadCandidates
        )
        if expandThreadCandidates {
            if siblingCandidates.isEmpty {
                popoverEmptyLine("No other messages in this thread")
            } else {
                // One click pulls in every sibling (not just the newest 8 shown
                // below); they collapse into the single Thread card.
                if siblingCandidates.count > 1 {
                    popoverCandidateRow(
                        symbol: "bubble.left.and.bubble.right",
                        title: "Add entire thread — \(siblingCandidates.count) emails",
                        isDisabled: isAddingEntireThread || !addingThreadCandidateIDs.isEmpty
                    ) {
                        let candidates = siblingCandidates
                        isAddingEntireThread = true
                        Task {
                            defer { isAddingEntireThread = false }
                            if await addAllThreadSources(candidates) {
                                siblingCandidates.removeAll()
                            }
                        }
                    }
                }
                ForEach(Array(siblingCandidates.prefix(8)), id: \.id) { sibling in
                    popoverCandidateRow(
                        symbol: "bubble.left.and.bubble.right",
                        title: ComposerSourceText.label(for: sibling),
                        isDisabled: isAddingEntireThread
                            || addingThreadCandidateIDs.contains(sibling.id)
                    ) {
                        addingThreadCandidateIDs.insert(sibling.id)
                        Task {
                            defer { addingThreadCandidateIDs.remove(sibling.id) }
                            if await addThreadSource(sibling) {
                                siblingCandidates.removeAll { $0.id == sibling.id }
                            }
                        }
                    }
                }
                if siblingCandidates.count > 8 {
                    popoverEmptyLine("\(siblingCandidates.count - 8) more in this thread — add them all above")
                }
            }
        }
    }

    @ViewBuilder
    private var attachmentCandidatesDisclosure: some View {
        candidateDisclosureHeader(
            title: "Attachments",
            symbol: "paperclip",
            count: attachmentCandidateRows.count,
            isExpanded: $expandAttachmentCandidates
        )
        if expandAttachmentCandidates {
            if attachmentCandidateRows.isEmpty {
                popoverEmptyLine("No attachments in this thread")
            } else {
                ForEach(Array(attachmentCandidateRows.prefix(12)), id: \.id) { attachment in
                    popoverCandidateRow(
                        symbol: "paperclip",
                        title: attachment.filename,
                        isDisabled: addingAttachmentCandidateIDs.contains(attachment.id)
                    ) {
                        addingAttachmentCandidateIDs.insert(attachment.id)
                        Task {
                            defer { addingAttachmentCandidateIDs.remove(attachment.id) }
                            if await addAttachmentSource(attachment) {
                                attachmentCandidateRows.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
                if attachmentCandidateRows.count > 12 {
                    popoverEmptyLine("\(attachmentCandidateRows.count - 12) more attachments")
                }
            }
        }
    }

    /// A collapsible header row for a candidate group, with a count badge and a
    /// rotating chevron. Tapping toggles the group; the rows themselves live in
    /// the owning disclosure so several can be added in one pass.
    private func candidateDisclosureHeader(
        title: String,
        symbol: String,
        count: Int,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                if count > 0 {
                    Text("\(count)")
                        .font(OhiaTypography.cardSignal.monospacedDigit())
                        .foregroundStyle(OhiaColors.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    .foregroundStyle(OhiaColors.textTertiary)
            }
            .foregroundStyle(OhiaColors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func popoverActionRow(
        symbol: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
            }
            .foregroundStyle(OhiaColors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A thread-sibling or attachment candidate: tapping adds it as a source
    /// and the row drops out of the candidate list. The popover stays open
    /// so several can be added in one pass.
    private func popoverCandidateRow(
        symbol: String,
        title: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(OhiaColors.iconPillForeground)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(OhiaColors.chipActiveForeground)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private func popoverSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(OhiaTypography.cardSignal)
            .foregroundStyle(OhiaColors.textTertiary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func popoverEmptyLine(_ text: String) -> some View {
        Text(text)
            .font(OhiaTypography.cardSignal)
            .foregroundStyle(OhiaColors.textDim)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    // MARK: - Rows

    @ViewBuilder
    private var emptyState: some View {
        if host.showsSourcesLoadingIndicator {
            AdaptiveSummaryLoadingPlaceholderView(preferredWidth: 320, slotHeight: 24)
                .accessibilityLabel("Sources loading")
        } else {
            Text("No sources yet. Add past emails, notes, or files the reply should draw on.")
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var rowList: some View {
        if allowsInternalScroll && fillsHeight {
            ScrollView {
                LazyVStack(spacing: 4) { rows }
            }
        } else if allowsInternalScroll && host.sources.count > 4 {
            // Bounded in the Decisions step so the questions below keep
            // their room; the inner list scrolls.
            ScrollView {
                VStack(spacing: 4) { rows }
            }
            .frame(height: 232)
        } else {
            VStack(spacing: 4) { rows }
        }
    }

    @ViewBuilder
    private var rows: some View {
        let threadSources = host.sources.filter { $0.kind == .thread }
        let leftOut = host.sourcesLeftOutOfDraft
        if threadSources.count > 1 {
            // Multiple thread messages render as one subject-identified card;
            // the rest render as individual rows.
            threadAggregateRow(threadSources, leftOut: leftOut)
            ForEach(host.sources.filter { $0.kind != .thread }) { source in
                sourceRow(source, isLeftOut: leftOut.contains(source.id))
            }
        } else {
            ForEach(host.sources) { source in
                sourceRow(source, isLeftOut: leftOut.contains(source.id))
            }
        }
        if let processingFileName {
            processingFileRow(processingFileName)
        }
    }

    private func processingFileRow(_ filename: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16)
            Text("Processing \(filename)")
                .font(OhiaTypography.neighborTitle)
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(OhiaColors.chipRestBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Processing \(filename)")
    }

    private func sourceRow(_ source: ComposerSource, isLeftOut: Bool) -> some View {
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: source.kind.sourceSymbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(isLeftOut ? OhiaColors.textSecondary : OhiaColors.iconPillForeground)
                    .frame(width: 16)
                    .padding(.top, 2)

                // Essential info: the labelled title (sender · subject · date,
                // page title, filename, dates) and — for web-backed sources — the
                // cleaned URL beneath it. The grounding body text stays omitted
                // (it ran the cards 8–10 lines each); the label + URL identify the
                // source, and the full text is what the model reads.
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayLabel(for: source))
                        .font(OhiaTypography.neighborTitle)
                        .foregroundStyle(isLeftOut ? OhiaColors.textSecondary : OhiaColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityValue(isLeftOut ? "Left out of draft" : "")
                    if let secondary = secondaryLine(for: source) {
                        Text(secondary)
                            .font(OhiaTypography.neighborExcerpt)
                            .foregroundStyle(OhiaColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ClusterButtonChip(
                    glyph: .native("xmark.bin.circle.fill"),
                    tint: OhiaColors.ohiaRed,
                    help: "Remove source"
                ) {
                    removeSource(source)
                }
                .disabled(!host.sourceMutationsEnabled)
            }

            if isLeftOut {
                leftOutBadge("Left out of draft")
            }
            if source.isUserAdded {
                Text("added by you")
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(OhiaColors.chipActiveBackground)
                    .clipShape(Capsule())
                    .fixedSize()
            }
        }
        .padding(8)
        .background(OhiaColors.chipRestBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Automatic thread labels predate subject-bearing source rows. Resolve a
    /// lone thread message for display without rewriting its persisted/model-
    /// facing label; manual-source badges and source ordering remain unchanged.
    private func displayLabel(for source: ComposerSource) -> String {
        let presentationLabel = ComposerSourcePresentation.displayLabel(for: source)
        guard source.kind == .thread,
              !source.isUserAdded,
              let messageID = source.messageID else { return presentationLabel }
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.id == messageID }
        )
        guard let message = try? modelContext.fetch(descriptor).first else {
            return presentationLabel
        }
        let direction = message.isSentByUser
            ? "you wrote"
            : "\(message.fromName ?? message.fromAddress) wrote"
        return "\(direction) · \(message.subject) · \(ComposerSourceText.shortDate(message.pipelineOrderingDate))"
    }

    /// The display URL for a web-backed source, or nil. Mirrors the carriers
    /// `ComposerWebSourceKeeper` resolves against: the researched provenance URL
    /// first, else the normalized URL stashed in `filePath` for a compiled
    /// website link. The `filePath` fallback is scoped to `.website` so a
    /// `.file` source's local disk path is never shown as a URL.
    private func webURL(for source: ComposerSource) -> String? {
        if let provenanceURL = source.provenance?.sourceURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !provenanceURL.isEmpty {
            return provenanceURL
        }
        if source.kind == .website,
           let path = source.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        return nil
    }

    /// Strips the scheme and any trailing slash for a cleaner read; the row wraps
    /// the remainder fully (no dots, no mid-word cut).
    private func displayURL(_ raw: String) -> String {
        var cleaned = raw
        for scheme in ["https://", "http://"] where cleaned.lowercased().hasPrefix(scheme) {
            cleaned = String(cleaned.dropFirst(scheme.count))
            break
        }
        if cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }
        return cleaned
    }

    /// The one-line qualifier beneath a source's title: the cleaned URL for
    /// web-backed sources, or a short excerpt of the typed text for a memo (whose
    /// generic "Memo" label otherwise says nothing). Every other kind's label
    /// already carries its essential info (sender · subject · date, filename).
    private func secondaryLine(for source: ComposerSource) -> String? {
        if let status = ComposerSourcePresentation.condensedStatus(for: source) {
            return status
        }
        if let raw = webURL(for: source) { return displayURL(raw) }
        if source.kind == .note {
            let excerpt = cleanedExcerpt(source.snippet, limit: 160)
            return excerpt.isEmpty ? nil : excerpt
        }
        return nil
    }

    /// Whitespace-collapsed excerpt bounded on a word boundary — never dotted,
    /// never cut mid-word.
    private func cleanedExcerpt(_ text: String, limit: Int) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let bounded = collapsed.prefix(limit)
        if let lastSpace = bounded.lastIndex(of: " ") {
            return String(bounded[..<lastSpace])
        }
        return String(bounded)
    }

    // MARK: - Left out of draft

    /// Dims a source the draft writer leaves out under its window, so the
    /// author can remove or swap sources to stay within the limit.
    private func leftOutBadge(_ text: String) -> some View {
        Text(text)
            .font(OhiaTypography.cardSignal)
            .foregroundStyle(OhiaColors.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(OhiaColors.chipRestBackground)
            .overlay {
                Capsule()
                    .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
            }
            .clipShape(Capsule())
            .fixedSize()
            .help("The draft writer's window is full, so this is not used in the draft. Remove or swap sources to include it.")
            // VoiceOver reads the state with the row's title instead.
            .accessibilityHidden(true)
    }

    // MARK: - Thread aggregate

    /// Thread siblings collapse into one card: the distinct thread subjects, a
    /// count, and, when the backing message dates resolve, their time range.
    /// Removing it drops every thread email at once.
    private func threadAggregateRow(_ threadSources: [ComposerSource], leftOut: Set<UUID>) -> some View {
        let summary = threadSummary(threadSources)
        let containsUserAddedSource = threadSources.contains(where: \.isUserAdded)
        let leftOutCount = threadSources.count { leftOut.contains($0.id) }
        let isLeftOut = leftOutCount == threadSources.count
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 11))
                    .foregroundStyle(isLeftOut ? OhiaColors.textSecondary : OhiaColors.iconPillForeground)
                    .frame(width: 16)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.subjects.isEmpty ? "Thread" : summary.subjects.joined(separator: "\n"))
                        .font(OhiaTypography.neighborTitle)
                        .foregroundStyle(isLeftOut ? OhiaColors.textSecondary : OhiaColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityValue(isLeftOut ? "Left out of draft"
                            : (leftOutCount > 0 ? "Left out of draft: \(leftOutCount) of \(threadSources.count) emails" : ""))
                    Text(threadSubtitle(count: threadSources.count, range: summary.range))
                        .font(OhiaTypography.neighborExcerpt)
                        .foregroundStyle(OhiaColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ClusterButtonChip(
                    glyph: .native("xmark.bin.circle.fill"),
                    tint: OhiaColors.ohiaRed,
                    help: "Remove all thread emails"
                ) {
                    removeThreadSources(threadSources)
                }
                .disabled(!host.sourceMutationsEnabled)
            }

            if isLeftOut {
                leftOutBadge("Left out of draft")
            } else if leftOutCount > 0 {
                // The writer leaves the oldest thread emails out first.
                leftOutBadge("Left out of draft: \(leftOutCount) of \(threadSources.count) emails")
            }
            if containsUserAddedSource {
                Text("added by you")
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.chipActiveForeground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(OhiaColors.chipActiveBackground)
                    .clipShape(Capsule())
                    .fixedSize()
            }
        }
        .padding(8)
        .background(OhiaColors.chipRestBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Resolves every thread source in one batch. Subjects are de-duplicated by
    /// thread identity while preserving source order; orphaned messages fall
    /// back to their individual subject line.
    private func threadSummary(
        _ sources: [ComposerSource]
    ) -> (subjects: [String], range: (Date, Date)?) {
        let ids = sources.compactMap(\.messageID)
        guard !ids.isEmpty else { return (fallbackThreadSubjects(), nil) }
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { ids.contains($0.id) }
        )
        let messages = (try? modelContext.fetch(descriptor)) ?? []
        let messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

        var seenThreadKeys = Set<String>()
        var subjects: [String] = []
        for source in sources {
            guard let messageID = source.messageID,
                  let message = messagesByID[messageID] else { continue }
            let resolvedSubject = message.subject
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolvedSubject.isEmpty else { continue }
            let threadKey = message.thread?.id.uuidString ?? message.id.uuidString
            if seenThreadKeys.insert(threadKey).inserted {
                subjects.append(resolvedSubject)
            }
        }

        let dates = messages.map(\.pipelineOrderingDate)
        let range = dates.min().flatMap { earliest in
            dates.max().map { latest in (earliest, latest) }
        }
        return (subjects.isEmpty ? fallbackThreadSubjects() : subjects, range)
    }

    private func fallbackThreadSubjects() -> [String] {
        guard let subject = host.candidateMessage(in: modelContext)?.subject
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !subject.isEmpty else { return [] }
        return [subject]
    }

    private func threadSubtitle(count: Int, range: (Date, Date)?) -> String {
        let emails = count == 1 ? "1 email" : "\(count) emails"
        guard let range else { return emails }
        let start = ComposerSourceText.shortDate(range.0)
        let end = ComposerSourceText.shortDate(range.1)
        return start == end ? "\(emails) · \(start)" : "\(emails) · \(start) → \(end)"
    }

    private func removeThreadSources(_ sources: [ComposerSource]) {
        let ids = Set(sources.map(\.id))
        _ = mutateSources { list in
            list.removeAll { ids.contains($0.id) }
        }
    }

    // MARK: - Candidates

    private func threadSiblingCandidates() -> [Message] {
        guard let message = host.candidateMessage(in: modelContext),
              let thread = message.thread else { return [] }
        let existing = Set(host.sources.compactMap(\.messageID))
        return thread.messages
            .filter { $0.id != message.id && !existing.contains($0.id) }
            .sorted { $0.pipelineOrderingDate > $1.pipelineOrderingDate }
    }

    /// Every attachment across the selected message and its thread siblings —
    /// not only the ones with pre-extracted text — minus inline body images and
    /// filenames already in the list. Attachments without extracted text are
    /// read (or OCR'd) on demand when the user picks them.
    private func attachmentCandidates() -> [Attachment] {
        guard let message = host.candidateMessage(in: modelContext) else { return [] }
        var pool = message.attachments
        if let thread = message.thread {
            for sibling in thread.messages where sibling.id != message.id {
                pool.append(contentsOf: sibling.attachments)
            }
        }
        let existing = Set(
            host.sources.filter { $0.kind == .attachment }.map(\.label)
        )
        var seenFilenames = Set<String>()
        return pool
            .filter { attachment in
                guard attachment.isInline != true else { return false }
                let name = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !existing.contains(attachment.filename) else { return false }
                return seenFilenames.insert(name).inserted
            }
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }

    // MARK: - Append actions
    //
    // Every snippet read happens off-main (the bodies, extracted text, and
    // external files can be arbitrarily large); only the final append hops
    // back to write the Draft row.

    private func addEmailSource(_ message: Message) async -> Bool {
        await addMessageBackedSource(message, kind: .email)
    }

    /// Marks an asynchronous source addition as running until it lands (see
    /// `inFlightSourceAdditionCount`).
    private func beginSourceAddition() {
        host.inFlightSourceAdditionCount += 1
    }

    private func endSourceAddition() {
        host.inFlightSourceAdditionCount = max(0, host.inFlightSourceAdditionCount - 1)
    }

    private func sourceSearchAccountID() -> UUID? {
        if let message = host.candidateMessage(in: modelContext) {
            return message.accountID ?? message.account?.id
        }
        return host.backingDraft(in: modelContext)?.composeFromAccountID
    }

    private func addThreadSource(_ message: Message) async -> Bool {
        await addMessageBackedSource(message, kind: .thread)
    }

    /// Adds every thread sibling in one mutation — they collapse into the single
    /// Thread card. Message fields are snapshotted on the main actor (so the
    /// non-Sendable `Message` never crosses actor boundaries), snippets are read
    /// off-main, and a single append avoids N separate saves and re-projections.
    private func addAllThreadSources(_ messages: [Message]) async -> Bool {
        beginSourceAddition()
        defer { endSourceAddition() }
        let specs: [(
            label: String,
            path: String?,
            fallback: String,
            messageID: UUID,
            attachments: [Attachment],
            sentByUser: Bool,
            date: Date
        )] = messages.map {
            (
                ComposerSourceText.label(for: $0),
                $0.bodyTextPath,
                $0.subject,
                $0.id,
                $0.attachments,
                $0.isSentByUser,
                $0.receivedAt ?? $0.sentAt ?? $0.ingestedAt
            )
        }
        guard !specs.isEmpty else { return false }
        var additions: [ComposerSource] = []
        for spec in specs {
            let bodyText = await Task.detached(priority: .userInitiated) {
                ComposerSourceText.textFileSnippet(atPath: spec.path, fallback: spec.fallback)
            }.value
            let snippet = ComposerEmailAttachmentMetadata.appending(
                to: bodyText,
                attachments: spec.attachments
            )
            additions.append(ComposerSource(
                kind: .thread,
                label: spec.label,
                snippet: snippet,
                messageID: spec.messageID,
                isUserAdded: true,
                authoredByUser: spec.sentByUser,
                authoredAt: spec.date
            ))
        }
        return mutateSources { $0.append(contentsOf: additions) }
    }

    private func addMessageBackedSource(
        _ message: Message,
        kind: ComposerSource.Kind
    ) async -> Bool {
        beginSourceAddition()
        defer { endSourceAddition() }
        let label = ComposerSourceText.label(for: message)
        let path = message.bodyTextPath
        let fallback = message.subject
        let messageID = message.id
        let attachments = message.attachments
        // Stamped like the automatic compiler's message sources, so reply
        // preparation knows whose words they are.
        let sentByUser = message.isSentByUser
        let date = message.receivedAt ?? message.sentAt ?? message.ingestedAt
        let bodyText = await Task.detached(priority: .userInitiated) {
            ComposerSourceText.textFileSnippet(atPath: path, fallback: fallback)
        }.value
        let snippet = ComposerEmailAttachmentMetadata.appending(
            to: bodyText,
            attachments: attachments
        )
        return append(ComposerSource(
            kind: kind,
            label: label,
            snippet: snippet,
            messageID: messageID,
            isUserAdded: true,
            authoredByUser: sentByUser,
            authoredAt: date
        ))
    }

    private func addAttachmentSource(_ attachment: Attachment) async -> Bool {
        beginSourceAddition()
        defer { endSourceAddition() }
        let extractedPath = attachment.extractedTextPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalPath = attachment.filePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mimeType = attachment.mimeType
        let label = attachment.filename
        let messageID = attachment.message?.id
        let snippet = await Self.attachmentSnippet(
            extractedTextPath: extractedPath,
            originalPath: originalPath,
            mimeType: mimeType
        )
        return append(ComposerSource(
            kind: .attachment,
            label: label,
            snippet: snippet,
            messageID: messageID,
            isUserAdded: true
        ))
    }

    /// Best snippet for an attachment: its pre-extracted text when present,
    /// otherwise on-demand extraction from the original file — Vision OCR for
    /// images (the same path ingestion uses), document/text extraction
    /// otherwise.
    private static func attachmentSnippet(
        extractedTextPath: String?,
        originalPath: String?,
        mimeType: String
    ) async -> String {
        if let extractedTextPath, !extractedTextPath.isEmpty {
            let text = await Task.detached(priority: .userInitiated) {
                ComposerSourceText.textFileSnippet(atPath: extractedTextPath, fallback: "")
            }.value
            if !text.isEmpty { return text }
        }
        guard let originalPath, !originalPath.isEmpty else {
            return "(attachment text could not be extracted)"
        }
        let url = URL(fileURLWithPath: originalPath)
        let kind = DocumentKind.detect(mimeType: mimeType, filename: url.lastPathComponent)
        if kind == .image || kind == .pdf {
            let result = try? await MultimodalAttachmentExtractor.extractFile(
                at: url, mimeType: mimeType, filename: url.lastPathComponent
            )
            guard let result, let text = result.text, !text.isEmpty else {
                return "(attachment text could not be extracted)"
            }
            return MultimodalAttachmentExtractor.snippet(from: result)
        }
        return await ComposerSourceText.extractFileText(at: url)
    }

    private func addFileFromDisk() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file the reply should draw on"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let attachmentSummaryService = appServices?.attachmentSummaryService else {
            fileSourceFailure = ComposerFileSourceFailure(
                message: "Ohia’s attachment model service is unavailable. The file was not added."
            )
            return
        }
        fileSourceFailure = nil
        sourceCapacityWarning = nil
        withAnimation(ComposerDisclosureState.animation) {
            isUserExpanded = true
        }
        let context = fileSourceContext()
        let accountID = host.candidateMessage(in: modelContext)?.accountID
        let securityScoped = url.startAccessingSecurityScopedResource()
        processingFileName = url.lastPathComponent
        beginSourceAddition()
        Task {
            defer {
                if securityScoped {
                    url.stopAccessingSecurityScopedResource()
                }
                processingFileName = nil
                endSourceAddition()
            }
            do {
                let evidence = try await ComposerFileSourceEvidenceExtractor.extractEvidence(
                    at: url,
                    context: context,
                    documentSummaryRunner: { input in
                        await attachmentSummaryService.summary(
                            for: input.attachmentID,
                            input: input,
                            accountID: accountID
                        )
                    }
                )
                try Task.checkCancellation()
                guard let draft = host.backingDraft(in: modelContext) else {
                    fileSourceFailure = ComposerFileSourceFailure(
                        message: fileSourceInsertionFailureMessage(filename: url.lastPathComponent)
                    )
                    return
                }
                let currentSources = ComposerSourceCoding.decode(draft.sourcesJSON)
                let writerUsage = ComposerWriterWindowUsage.decode(draft.sourceContextFitJSON)
                let unmeasuredContext = writerUsage == nil ? unmeasuredWriterContext(for: draft) : ""
                guard let selection = ComposerFileSourceCapacityFitter.selection(
                    filename: url.lastPathComponent,
                    filePath: url.path,
                    evidence: evidence,
                    currentSources: currentSources,
                    writerUsage: writerUsage,
                    unmeasuredContext: unmeasuredContext
                ) else {
                    sourceCapacityWarning = ComposerSourceCapacityWarning(
                        estimate: ComposerFileSourceCapacityFitter.minimumEstimate(
                            filename: url.lastPathComponent,
                            filePath: url.path,
                            evidence: evidence,
                            currentSources: currentSources,
                            writerUsage: writerUsage,
                            unmeasuredContext: unmeasuredContext
                        ),
                        isReply: draft.message != nil
                    )
                    return
                }
                let added = append(selection)
                if !added, sourceCapacityWarning == nil {
                    fileSourceFailure = ComposerFileSourceFailure(
                        message: fileSourceInsertionFailureMessage(filename: url.lastPathComponent)
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                fileSourceFailure = ComposerFileSourceFailure(
                    message: error.localizedDescription
                )
            }
        }
    }

    private func fileSourceContext() -> ComposerFileSourceEvidenceExtractor.Context {
        let message = host.candidateMessage(in: modelContext)
        let purpose = message?.analysis.flatMap {
            MailClassificationJSON.decode($0.mailClassificationJSON)?.purpose
        }
        return ComposerFileSourceEvidenceExtractor.Context(
            subject: message?.subject ?? "Composer draft",
            senderName: message?.fromName
                ?? message?.fromAddress
                ?? host.correspondentAddress(in: modelContext)
                ?? "Unknown sender",
            receivedAt: message?.receivedAt ?? message?.sentAt,
            purpose: purpose
        )
    }

    private func fileSourceInsertionFailureMessage(filename: String) -> String {
        if !host.hasDraftRow {
            return "“\(filename)” finished processing, but the draft is no longer available. The file was not added."
        }
        if !host.sourceMutationsEnabled {
            return "“\(filename)” finished processing, but Sources became locked while the model was working. The file was not added. Try again when Sources unlock."
        }
        return "“\(filename)” finished processing, but Ohia could not save it to Sources. The file was not added."
    }

    // MARK: - Persistence

    /// What the draft writer reads besides sources, for the add-source check
    /// before the draft's first measurement.
    private func unmeasuredWriterContext(for draft: Draft) -> String {
        ComposerSourceCapacityEstimator.unmeasuredContext(incoming: host.candidateMessage(in: modelContext),
            instructions: [draft.draftingInstruction, draft.composeInstruction, draft.pendingInstruction])
    }

    @discardableResult
    private func append(_ source: ComposerSource) -> Bool {
        mutateSources { $0.append(source) }
    }

    private func removeSource(_ source: ComposerSource) {
        _ = mutateSources { list in
            list.removeAll { $0.id == source.id }
        }
    }

    @discardableResult
    private func mutateSources(
        _ change: (inout [ComposerSource]) -> Void
    ) -> Bool {
        // The host resolves its own backing Draft (re-fetched to dodge stale
        // cross-process relationships); the write targets that row directly.
        guard let draft = host.backingDraft(in: modelContext) else { return false }
        guard !draft.isAutomaticSourceResearchPending else { return false }
        var list = ComposerSourceCoding.decode(draft.sourcesJSON)
        let original = list
        change(&list)
        let originalIDs = Set(original.map(\.id))
        let additions = list.filter {
            !originalIDs.contains($0.id) && $0.isUserAdded
        }
        if !additions.isEmpty {
            let writerUsage = ComposerWriterWindowUsage.decode(draft.sourceContextFitJSON)
            let estimate = ComposerSourceCapacityEstimator.estimate(
                currentSources: original,
                proposedSources: additions,
                writerUsage: writerUsage,
                unmeasuredContext: writerUsage == nil ? unmeasuredWriterContext(for: draft) : ""
            )
            guard !estimate.wouldExceed else {
                sourceCapacityWarning = ComposerSourceCapacityWarning(
                    estimate: estimate,
                    isReply: draft.message != nil
                )
                return false
            }
        }
        guard ComposerSourceMutationPersistence.prepareForPersistence(
            draft: draft,
            original: original,
            mutated: list
        ) else {
            return false
        }
        draft.sourcesJSON = ComposerSourceCoding.encode(list)
        draft.sourcesCuratedAt = draft.sourcesCuratedAt ?? Date()
        do {
            try ComposerSourceContextMeasurementScheduler.stageMeasurement(
                draft: draft,
                context: modelContext
            )
            try modelContext.save()
        } catch {
            // Roll back the dirty row so the host can't project a mutation the
            // store never committed (the next poll tick would silently snap it
            // back otherwise).
            modelContext.rollback()
            print("[Ohia] Composer source save failed: \(String(reflecting: type(of: error)))")
            return false
        }
        host.reloadAfterSourceMutation(in: modelContext)
        return true
    }
}

private struct ComposerFileSourceFailure: Identifiable {
    let id = UUID()
    let message: String
}

private struct ComposerSourceCapacityWarning: Identifiable {
    let id = UUID()
    let message: String

    /// A measurement whose kept content cannot fit the draft writer, worded
    /// for its largest cause.
    init(overflow usage: ComposerWriterWindowUsage) {
        let error = ComposerContentError.writerWindowExceeded(usage.overflow ?? .sources)
        message = error.errorDescription ?? error.kind
    }

    init(estimate: ComposerSourceCapacityEstimate, isReply: Bool) {
        let additional = estimate.estimatedAdditionalTokens.formatted(
            .number.grouping(.automatic)
        )
        let limit = estimate.evidenceTokenLimit.formatted(
            .number.grouping(.automatic)
        )
        // The allowance is the draft writer's room for sources the author
        // adds; automatic sources are left out of the draft first, so only
        // removing an added source frees room.
        if estimate.evidenceTokenLimit == 0 {
            let kept = isReply
                ? "the email you are replying to, your instructions and answers, the sources they rely on, "
                    + "source findings, saved memories and the current draft"
                : "your instructions and answers, the sources you added, saved memories and the current draft"
            message = "What this draft must keep already fills the drafting model's window, so there is "
                + "no room for another source. It was not added. The window holds \(kept)."
        } else if estimate.estimatedAdditionalTokens > estimate.evidenceTokenLimit {
            message = "This selection would add approximately \(additional) tokens, "
                + "more than the \(limit)-token allowance for sources you add. It was not added. "
                + "Choose a smaller source. Ohia reserves the rest of the draft writer's window "
                + "for the message, your instructions and the reply."
        } else {
            message = "This selection would add approximately \(additional) tokens "
                + "and exceed the \(limit)-token allowance for sources you add. It was not added. "
                + "Remove a source you added, then try again. Ohia reserves the rest of the "
                + "draft writer's window for the message, your instructions and the reply."
        }
    }
}

// MARK: - Search sheet

/// Searches the account's full ingested history by sender or subject.
/// Matching runs off the main actor; every match remains available to scroll.
private struct SourceEmailSearchSheet: View {
    let existingMessageIDs: Set<UUID>
    let accountID: UUID?
    let onAdd: (Message) async -> Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var includesSentMail = true
    @State private var includesReceivedMail = true
    @State private var results: [Message] = []
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchError: String?
    @State private var addedIDs: Set<UUID> = []
    @State private var addingIDs: Set<UUID> = []
    @State private var previewedResultID: UUID?
    @State private var hoverBodyStates: [UUID: EmailBodyPreviewState] = [:]
    @State private var previewExitTask: Task<Void, Never>?
    @State private var bodyLoadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Search Past Emails")
                    .font(OhiaTypography.cardTitle)
                    .foregroundStyle(OhiaColors.textPrimary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 4))
            }

            TextField("Sender or subject", text: $query)
                .textFieldStyle(.plain)
                .font(OhiaTypography.cardBody)
                .foregroundStyle(OhiaColors.textPrimary)
                .padding(8)
                .background(OhiaColors.surface(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onSubmit { runSearch() }
                .task(id: query) {
                    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        runSearch()
                        return
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(200))
                    } catch {
                        return
                    }
                    runSearch()
                }

            HStack(spacing: 6) {
                searchDirectionButton(
                    .sent,
                    title: "Sent"
                )
                searchDirectionButton(
                    .received,
                    title: "Received"
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mail direction")

            if accountID != nil {
                Label("Searching this account", systemImage: "at")
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(OhiaColors.textTertiary)
            }

            if results.isEmpty {
                Text(searchError ?? (hasSearched
                    ? "No matching emails."
                    : "Type to search this account by sender or subject."))
                    .font(OhiaTypography.cardDetail)
                    .foregroundStyle(OhiaColors.textDim)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .center
                    )
                    .padding(.vertical, 24)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 4) {
                        ForEach(results, id: \.id) { message in
                            resultRow(message)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 640, height: 560)
        .composerPresentationFrame(usesToolbarBackgroundInLightMode: true)
        .tint(OhiaColors.chipActiveForeground)
        .onDisappear {
            searchTask?.cancel()
            previewExitTask?.cancel()
            previewExitTask = nil
            bodyLoadTask?.cancel()
            bodyLoadTask = nil
        }
    }

    private func searchDirectionButton(
        _ direction: SearchDirection,
        title: String
    ) -> some View {
        let isOn = direction == .sent ? includesSentMail : includesReceivedMail
        let isOnlySelected = isOn && (direction == .sent
            ? !includesReceivedMail
            : !includesSentMail)
        return Button {
            toggleSearchDirection(direction)
        } label: {
            FilterChipLabel(text: title, isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) mail")
        .accessibilityValue(isOn ? "Included" : "Excluded")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(isOnlySelected
            ? "At least one mail direction must remain included"
            : "\(isOn ? "Exclude" : "Include") \(title.lowercased()) mail")
    }

    private func toggleSearchDirection(_ direction: SearchDirection) {
        switch direction {
        case .sent:
            guard !includesSentMail || includesReceivedMail else { return }
            includesSentMail.toggle()
        case .received:
            guard !includesReceivedMail || includesSentMail else { return }
            includesReceivedMail.toggle()
        }
        runSearch()
    }

    private func resultRow(_ message: Message) -> some View {
        let isAdded = addedIDs.contains(message.id) || existingMessageIDs.contains(message.id)
        let isAdding = addingIDs.contains(message.id)
        let sender = message.fromName ?? message.fromAddress
        return HStack(spacing: 8) {
            SourceEmailResultLabel(sender: sender, subject: message.subject)
                .focusable()
                .onKeyPress(.space) {
                    toggleResultPreview(for: message)
                    return .handled
                }
                .onKeyPress(.return) {
                    toggleResultPreview(for: message)
                    return .handled
                }
                .accessibilityAction(named: Text("Preview email body")) {
                    presentResultPreview(for: message)
                }
                .accessibilityHint("Shows the complete message body without quoted reply history")

            Text(ComposerSourceText.shortDate(message.pipelineOrderingDate))
                .font(OhiaTypography.cardSignal.monospacedDigit())
                .foregroundStyle(OhiaColors.textTertiary)
                .fixedSize()

            if isAdded {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text("added")
                        .font(OhiaTypography.cardSignal)
                }
                .foregroundStyle(OhiaColors.chipActiveForeground)
            } else {
                Button(isAdding ? "Adding" : "Add") {
                    addingIDs.insert(message.id)
                    Task {
                        defer { addingIDs.remove(message.id) }
                        if await onAdd(message) {
                            addedIDs.insert(message.id)
                        }
                    }
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 8, verticalPadding: 3))
                .disabled(isAdding)
            }
        }
        .padding(8)
        .background(OhiaColors.chipRestBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            updateResultHover(hovering, message: message)
        }
        .popover(
            isPresented: hoverPopoverBinding(for: message.id),
            arrowEdge: .leading
        ) {
            SourceEmailBodyHoverPreview(
                sender: sender,
                subject: message.subject,
                state: hoverBodyStates[message.id] ?? .loading
            )
            .onHover { hovering in
                updatePreviewHover(hovering, messageID: message.id)
            }
        }
    }

    private func hoverPopoverBinding(for messageID: UUID) -> Binding<Bool> {
        Binding(
            get: { previewedResultID == messageID },
            set: { isPresented in
                guard !isPresented, previewedResultID == messageID else { return }
                previewExitTask?.cancel()
                previewExitTask = nil
                previewedResultID = nil
                cancelBodyLoadIfNeeded(for: messageID)
            }
        )
    }

    private func updateResultHover(_ hovering: Bool, message: Message) {
        if hovering {
            presentResultPreview(for: message)
        } else {
            schedulePreviewExit(for: message.id)
        }
    }

    private func updatePreviewHover(_ hovering: Bool, messageID: UUID) {
        if hovering {
            previewExitTask?.cancel()
            previewExitTask = nil
        } else {
            schedulePreviewExit(for: messageID)
        }
    }

    private func presentResultPreview(for message: Message) {
        previewExitTask?.cancel()
        previewExitTask = nil
        previewedResultID = message.id
        loadHoverBodyIfNeeded(for: message)
    }

    private func toggleResultPreview(for message: Message) {
        if previewedResultID == message.id {
            previewedResultID = nil
            cancelBodyLoadIfNeeded(for: message.id)
        } else {
            presentResultPreview(for: message)
        }
    }

    private func schedulePreviewExit(for messageID: UUID) {
        previewExitTask?.cancel()
        previewExitTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard previewedResultID == messageID else { return }
            previewedResultID = nil
            previewExitTask = nil
            cancelBodyLoadIfNeeded(for: messageID)
        }
    }

    private func cancelBodyLoadIfNeeded(for messageID: UUID) {
        guard hoverBodyStates[messageID] == .loading else { return }
        bodyLoadTask?.cancel()
        bodyLoadTask = nil
        hoverBodyStates.removeValue(forKey: messageID)
    }

    private func loadHoverBodyIfNeeded(for message: Message) {
        if let state = hoverBodyStates[message.id], state != .unavailable {
            return
        }
        bodyLoadTask?.cancel()

        let messageID = message.id
        let htmlPath = message.bodyHtmlPath
        let textPath = message.bodyTextPath
        let rawPath = message.rawPath
        hoverBodyStates = [messageID: .loading]

        bodyLoadTask = Task { @MainActor in
            let body = await SourceEmailBodyPreviewLoader.load(
                htmlPath: htmlPath,
                textPath: textPath,
                rawPath: rawPath
            )
            guard !Task.isCancelled,
                  results.contains(where: { $0.id == messageID }) else { return }
            hoverBodyStates[messageID] = body.map(EmailBodyPreviewState.loaded) ?? .unavailable
            bodyLoadTask = nil
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        searchError = nil
        previewExitTask?.cancel()
        previewExitTask = nil
        bodyLoadTask?.cancel()
        bodyLoadTask = nil
        previewedResultID = nil
        hoverBodyStates = [:]

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hasSearched = false
            results = []
            return
        }
        hasSearched = true

        let container = modelContext.container
        let accountID = accountID
        let sent = includesSentMail
        let received = includesReceivedMail
        results = []
        searchTask = Task {
            do {
                let ids = try await ComposerSourceEmailSearch.messageIDs(
                    container: container, accountID: accountID, query: trimmed,
                    includesSentMail: sent, includesReceivedMail: received
                )
                guard !Task.isCancelled else { return }
                let descriptor = FetchDescriptor<Message>(predicate: #Predicate { ids.contains($0.id) })
                let messages = try modelContext.fetch(descriptor)
                let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
                results = ids.compactMap { byID[$0] }
            } catch {
                guard !Task.isCancelled else { return }
                searchError = "Could not search emails: \(error.localizedDescription)"
            }
        }
    }

    private enum SearchDirection { case received, sent }

    fileprivate enum EmailBodyPreviewState: Equatable, Sendable {
        case loading
        case loaded(String)
        case unavailable
    }
}

enum ComposerSourceEmailSearch {
    @concurrent
    static func messageIDs(
        container: ModelContainer, accountID: UUID?, query: String,
        includesSentMail: Bool, includesReceivedMail: Bool
    ) async throws -> [UUID] {
        guard let accountID else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate {
            $0.accountID == accountID && $0.trashedAt == nil
        })
        var matches: [(id: UUID, date: Date)] = []
        for message in try context.fetch(descriptor) {
            try Task.checkCancellation()
            guard message.isSentByUser ? includesSentMail : includesReceivedMail else { continue }
            if let folder = message.imapFolderPath,
               IMAPFolderIngestionPolicy.isExcluded(folderName: folder, attributes: []) { continue }
            guard message.subject.localizedCaseInsensitiveContains(query)
                || message.fromAddress.localizedCaseInsensitiveContains(query)
                || (message.fromName?.localizedCaseInsensitiveContains(query) ?? false) else { continue }
            matches.append((message.id, message.pipelineOrderingDate))
        }
        return matches.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }.map(\.id)
    }
}

/// Loads the complete authored portion of a source email for the Composer's
/// hover and keyboard preview. Plain-text MIME parts preserve `>` quoting;
/// HTML needs its provider quote containers cut before tags are flattened.
enum SourceEmailBodyPreviewLoader {
    @concurrent
    static func load(
        htmlPath: String?,
        textPath: String?,
        rawPath: String?
    ) async -> String? {
        let plainTextBody = cleanedBody(
            from: loadBodySource(htmlPath: nil, textPath: textPath, rawPath: nil)
        )
        guard !Task.isCancelled else { return nil }

        let htmlSource = loadBodySource(htmlPath: htmlPath, textPath: nil, rawPath: nil)
        let htmlBody = cleanedBody(from: htmlSource)
        guard !Task.isCancelled else { return nil }

        // HTML retains semantic quote containers that its derived body.txt
        // cannot represent. When one is present, its pre-boundary text is the
        // authoritative top post; otherwise prefer the canonical text part.
        if htmlBody.foundQuoteBoundary {
            return htmlBody.text
        }
        if let plainTextBody = plainTextBody.text {
            return plainTextBody
        }
        if let htmlBody = htmlBody.text {
            return htmlBody
        }

        guard !Task.isCancelled else { return nil }
        return cleanedBody(
            from: loadBodySource(htmlPath: nil, textPath: nil, rawPath: rawPath)
        ).text
    }

    /// Loads the best body representation for the explicit reply-quote
    /// system. Unlike the source-card preview, plain text stays structurally
    /// intact so `QuotedHistoryTail.latestAuthoredText` can retain inline
    /// answers while removing the quoted questions around them.
    @concurrent
    static func loadForReplyQuote(
        htmlPath: String?,
        textPath: String?,
        rawPath: String?
    ) async -> String? {
        let plainTextSource = loadBodySource(
            htmlPath: nil,
            textPath: textPath,
            rawPath: nil
        )
        guard !Task.isCancelled else { return nil }

        let htmlBody = replyQuoteBody(
            from: loadBodySource(htmlPath: htmlPath, textPath: nil, rawPath: nil)
        )
        guard !Task.isCancelled else { return nil }

        if htmlBody.foundQuoteBoundary {
            return htmlBody.text
        }
        if let plainTextSource {
            let trimmed = plainTextSource.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let htmlText = htmlBody.text {
            return htmlText
        }

        guard !Task.isCancelled else { return nil }
        return replyQuoteBody(
            from: loadBodySource(htmlPath: nil, textPath: nil, rawPath: rawPath)
        ).text
    }

    nonisolated private static func loadBodySource(
        htmlPath: String?,
        textPath: String?,
        rawPath: String?
    ) -> LockReadoutBodySource? {
        guard case .loaded(let source) = LockReadoutBodyLoader.load(
            htmlPath: htmlPath,
            textPath: textPath,
            rawPath: rawPath
        ) else {
            return nil
        }
        return source
    }

    nonisolated private static func cleanedBody(
        from source: LockReadoutBodySource?
    ) -> (text: String?, foundQuoteBoundary: Bool) {
        guard let source else { return (nil, false) }

        let plainText: String
        let foundQuoteBoundary: Bool
        switch source.format {
        case .plainText:
            plainText = source.text
            foundQuoteBoundary = false
        case .html:
            let unquotedHTML = htmlWithoutQuotedHistory(source.text)
            foundQuoteBoundary = unquotedHTML.foundQuoteBoundary
            let displaySource = LockReadoutBodySource(
                text: unquotedHTML.html,
                format: .html,
                baseURL: source.baseURL
            )
            plainText = LockReadoutBodyContent(source: displaySource).plainText
        }

        let cleaned = OriginalMessageText.cleanedForDisplay(from: plainText)?.text
        return (cleaned, foundQuoteBoundary)
    }

    nonisolated private static func replyQuoteBody(
        from source: LockReadoutBodySource?
    ) -> (text: String?, foundQuoteBoundary: Bool) {
        guard let source else { return (nil, false) }

        let plainText: String
        let foundQuoteBoundary: Bool
        switch source.format {
        case .plainText:
            plainText = source.text
            foundQuoteBoundary = false
        case .html:
            let unquotedHTML = htmlWithoutQuotedHistory(source.text)
            foundQuoteBoundary = unquotedHTML.foundQuoteBoundary
            plainText = LockReadoutBodyContent(
                source: LockReadoutBodySource(
                    text: unquotedHTML.html,
                    format: .html,
                    baseURL: source.baseURL
                )
            ).plainText
        }

        let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? nil : trimmed, foundQuoteBoundary)
    }

    /// Remove semantic blockquotes before flattening HTML so inline answers
    /// after a quoted question remain available. Provider-specific reply-tail
    /// containers run to the end of the message and are cut at their boundary.
    /// Once tags are removed, either kind is indistinguishable from prose.
    nonisolated private static func htmlWithoutQuotedHistory(
        _ html: String
    ) -> (html: String, foundQuoteBoundary: Bool) {
        var result = html
        var foundQuoteBoundary = false

        let providerPattern =
            #"<[^>]*(?:gmail_quote|yahoo_quoted|protonmail_quote|moz-cite-prefix|divrplyfwdmsg|replyforwardmsg)[^>]*>"#
        if let boundary = result.range(
            of: providerPattern,
            options: [.regularExpression, .caseInsensitive]
        )?.lowerBound {
            result = String(result[..<boundary])
            foundQuoteBoundary = true
        }

        guard let blockquoteTag = try? NSRegularExpression(
            pattern: #"(?is)<\s*/?\s*blockquote\b[^>]*>"#
        ) else {
            return (result, foundQuoteBoundary)
        }
        let matches = blockquoteTag.matches(
            in: result,
            range: NSRange(result.startIndex..<result.endIndex, in: result)
        )
        guard !matches.isEmpty else {
            return (result, foundQuoteBoundary)
        }

        var output = ""
        var cursor = result.startIndex
        var quoteDepth = 0
        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            if quoteDepth == 0 {
                output.append(contentsOf: result[cursor..<range.lowerBound])
            }
            let afterOpeningBracket = result[result.index(after: range.lowerBound)..<range.upperBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if afterOpeningBracket.hasPrefix("/") {
                quoteDepth = max(quoteDepth - 1, 0)
            } else {
                quoteDepth += 1
            }
            cursor = range.upperBound
        }
        if quoteDepth == 0 {
            output.append(contentsOf: result[cursor...])
        }
        return (output, true)
    }
}

/// Keeps a single-line sender and subject from introducing an ellipsis while
/// preserving their visual hierarchy. The visible line renders at intrinsic
/// width inside a clipped overlay; the row supplies its finite width, and the
/// mask fades only the trailing overflow.
private struct SourceEmailResultLabel: View {
    /// Match the Memories fade: the rendered copy is bounded before asking
    /// SwiftUI for an intrinsic width, while accessibility keeps the full text.
    private static let maximumRenderedCharacterCount = 256

    let sender: String
    let subject: String

    private var fullLabel: String {
        "\(sender) · \(subject)"
    }

    private var boundedSender: String {
        String(sender.prefix(Self.maximumRenderedCharacterCount))
    }

    private var boundedSubject: String {
        let remainingCount = max(
            0,
            Self.maximumRenderedCharacterCount - boundedSender.count - 3
        )
        return String(subject.prefix(remainingCount))
    }

    var body: some View {
        Text(fullLabel)
            .font(OhiaTypography.cardBody)
            .foregroundStyle(.clear)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    Text(boundedSender)
                        .foregroundStyle(OhiaColors.textPrimary)
                    Text(" · ")
                        .foregroundStyle(OhiaColors.textTertiary)
                    Text(boundedSubject)
                        .foregroundStyle(OhiaColors.textSecondary)
                }
                .font(OhiaTypography.cardBody)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityHidden(true)
            }
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.90),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .accessibilityLabel(fullLabel)
    }
}

/// Hover disclosure for a search result. The body is the complete top-posted
/// message text: `OriginalMessageText` removes reply history and quoted lines,
/// while this scroll view keeps every remaining character reachable.
private struct SourceEmailBodyHoverPreview: View {
    let sender: String
    let subject: String
    let state: SourceEmailSearchSheet.EmailBodyPreviewState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sender)
                .font(OhiaTypography.cardSignal)
                .foregroundStyle(OhiaColors.textTertiary)
            Text(subject)
                .font(OhiaTypography.cardBody.weight(.semibold))
                .foregroundStyle(OhiaColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()

            Group {
                switch state {
                case .loading:
                    ProgressView("Loading message body")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let text):
                    ScrollView(.vertical) {
                        Text(text)
                            .font(OhiaTypography.cardBody)
                            .foregroundStyle(OhiaColors.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .unavailable:
                    Text("No unquoted message body is available.")
                        .font(OhiaTypography.cardDetail)
                        .foregroundStyle(OhiaColors.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(width: 440, height: 340)
        .composerPresentationFrame(
            inset: 8,
            cornerRadius: 8,
            usesToolbarBackgroundInLightMode: true
        )
        .tint(OhiaColors.chipActiveForeground)
    }
}

// MARK: - Note sheet

/// "Note": free text the mailbox doesn't hold — figures, decisions, pasted
/// context — added verbatim as a `.note` source.
private struct SourceNoteSheet: View {
    let onAdd: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Memo")
                .font(OhiaTypography.cardTitle)
                .foregroundStyle(OhiaColors.textPrimary)
            Text("Typed or pasted context the reply should draw on.")
                .font(OhiaTypography.cardDetail)
                .foregroundStyle(OhiaColors.textTertiary)

            TextEditor(text: $text)
                .font(OhiaTypography.cardBody)
                .foregroundStyle(OhiaColors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(OhiaColors.surface(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 4))
                Button("Add Source") {
                    if onAdd(trimmedText) {
                        dismiss()
                    }
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 10, verticalPadding: 4))
                .disabled(trimmedText.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440, height: 320)
        .composerPresentationFrame()
        .tint(OhiaColors.chipActiveForeground)
    }
}

// MARK: - Text helpers

/// Converts a user-selected local file into the same structured evidence used
/// by ingested attachments. Full evidence remains available when it fits;
/// condensed variants retain metadata, the model summary, and selected
/// extracted/OCR passages when the source allowance is smaller.
nonisolated enum ComposerFileSourceEvidenceExtractor {
    typealias VisualExtractor = VisualAttachmentExtractionWorker.ExtractionRunner
    typealias DocumentSummaryRunner = @Sendable (
        AttachmentSummaryInput
    ) async -> AttachmentSummaryResult?

    struct Context: Sendable, Equatable {
        let subject: String
        let senderName: String
        let receivedAt: Date?
        let purpose: MailPurpose?
    }

    struct Evidence: Sendable, Equatable {
        let full: String
        let condensed: String
        let minimum: String

        fileprivate var variants: [String] {
            var values = [full]
            for snippet in [condensed, minimum]
            where values.contains(snippet) == false {
                values.append(snippet)
            }
            return values
        }
    }

    enum ExtractionError: LocalizedError {
        case unsupported(filename: String)
        case tooLarge(filename: String, maximumBytes: Int)
        case unreadable(filename: String)
        case noUsableEvidence(filename: String, reason: String?)
        case modelAnalysisFailed(filename: String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let filename):
                return "“\(filename)” is not a supported image or document."
            case .tooLarge(let filename, let maximumBytes):
                let maximum = ByteCountFormatter.string(
                    fromByteCount: Int64(maximumBytes),
                    countStyle: .file
                )
                return "“\(filename)” is larger than the \(maximum) processing limit."
            case .unreadable(let filename):
                return "Ohia could not read “\(filename)”."
            case .noUsableEvidence(let filename, let reason):
                let detail = reason?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let detail, !detail.isEmpty {
                    return "Ohia could not extract usable evidence from “\(filename)”: \(detail)"
                }
                return "Ohia could not extract usable evidence from “\(filename)”."
            case .modelAnalysisFailed(let filename):
                return "Model analysis failed for “\(filename)”: neither Apple Intelligence nor the local model produced usable text. The file was not added."
            }
        }
    }

    static func extract(
        at url: URL,
        context: Context,
        documentSummaryRunner: @escaping DocumentSummaryRunner,
        visualExtractor: @escaping VisualExtractor = VisualAttachmentExtractionWorker.extractAndSummarize
    ) async throws -> String {
        try await extractEvidence(
            at: url,
            context: context,
            documentSummaryRunner: documentSummaryRunner,
            visualExtractor: visualExtractor
        ).full
    }

    static func extractEvidence(
        at url: URL,
        context: Context,
        documentSummaryRunner: @escaping DocumentSummaryRunner,
        visualExtractor: @escaping VisualExtractor = VisualAttachmentExtractionWorker.extractAndSummarize
    ) async throws -> Evidence {
        let filename = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let contentType = values?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        let detectedMIMEType = contentType?.preferredMIMEType
            ?? "application/octet-stream"
        let detectedKind = DocumentKind.detect(
            mimeType: detectedMIMEType,
            filename: filename
        )
        let treatsAsPlainText = detectedKind == .unsupported
            && contentType?.conforms(to: .text) == true
        let kind: DocumentKind = treatsAsPlainText ? .plainText : detectedKind
        let extractionMIMEType = treatsAsPlainText ? "text/plain" : detectedMIMEType

        guard kind != .unsupported else {
            throw ExtractionError.unsupported(filename: filename)
        }

        let maximumBytes = kind == .image
            ? VisualAttachmentExtractionWorker.maxAttemptedImageBytes
            : AttachmentExtractionWorker.maxAttemptedAttachmentBytes
        if let fileSize = values?.fileSize, fileSize > maximumBytes {
            throw ExtractionError.tooLarge(
                filename: filename,
                maximumBytes: maximumBytes
            )
        }

        if kind == .image {
            return try await extractImage(
                at: url,
                filename: filename,
                mimeType: extractionMIMEType,
                sizeBytes: values?.fileSize,
                context: context,
                visualExtractor: visualExtractor
            )
        }

        let data: Data
        do {
            data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
        } catch {
            throw ExtractionError.unreadable(filename: filename)
        }
        guard data.count <= maximumBytes else {
            throw ExtractionError.tooLarge(
                filename: filename,
                maximumBytes: maximumBytes
            )
        }

        let result = try await MultimodalAttachmentExtractor.extract(
            data: data, mimeType: extractionMIMEType, filename: filename
        )
        guard let result,
              result.status == .completed,
              let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw ExtractionError.noUsableEvidence(
                filename: filename,
                reason: result?.failureReason
            )
        }
        let attachmentID = UUID()
        let summaryInput = AttachmentSummaryInput(
            attachmentID: attachmentID,
            filename: filename,
            mimeType: extractionMIMEType,
            sizeBytes: data.count,
            extractedText: MultimodalAttachmentExtractor.snippet(from: result, maximumCharacters: AttachmentSummaryPromptBuilder.textCharacterLimit),
            documentKind: result.kind.rawValue,
            structureUnitKind: result.structureUnitKind,
            structureUnitCount: result.structureUnitCount,
            characterCount: result.extractedCharacterCount,
            documentTitle: result.documentTitle,
            documentAuthor: result.documentAuthor,
            anchorSubject: context.subject,
            anchorSenderName: context.senderName,
            anchorReceivedAt: context.receivedAt,
            anchorPurpose: context.purpose
        )
        guard let summary = await documentSummaryRunner(summaryInput),
              let paragraph = cleaned(summary.paragraph) else {
            throw ExtractionError.modelAnalysisFailed(filename: filename)
        }
        let metadata = fileMetadata(
            filename: filename,
            mimeType: extractionMIMEType,
            sizeBytes: data.count,
            result: result
        )
        let fullMetadata = fileMetadata(
            filename: filename,
            mimeType: extractionMIMEType,
            sizeBytes: data.count,
            result: nil
        )
        let selectedText = ComposerPassageSelector(
            windowSize: 384,
            overlap: 64,
            maximumSelectedChunks: 3
        ).select(
            from: text,
            anchorTerms: context.anchorTerms
        )
        let summarySection = "[MODEL SUMMARY]\n\(paragraph)"
        let full = summarySection + "\n\n" + fullMetadata + "\n\n"
            + documentEvidence(result: result, text: text)
        let minimum = condensedPrefix
            + metadata + "\n\n"
            + summarySection
        let condensed = selectedText.isEmpty
            ? minimum
            : minimum + "\n\n[SELECTED EXTRACTED TEXT]\n\(selectedText)"
        return Evidence(full: full, condensed: condensed, minimum: minimum)
    }

    private static func extractImage(
        at url: URL,
        filename: String,
        mimeType: String,
        sizeBytes: Int?,
        context: Context,
        visualExtractor: @escaping VisualExtractor
    ) async throws -> Evidence {
        let result: VisualAttachmentExtractionResult?
        do {
            result = try await visualExtractor(
                VisualAttachmentReference(
                    filename: filename,
                    mimeType: mimeType,
                    filePath: url.path
                ),
                AppleIntelligenceModelProfile.current()
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            throw ExtractionError.noUsableEvidence(
                filename: filename,
                reason: error.localizedDescription
            )
        }

        guard let result, result.status == .completed else {
            throw ExtractionError.noUsableEvidence(
                filename: filename,
                reason: result?.failureReason
            )
        }

        let captureSection = await captureMetadataEvidence(at: url).map { "[CAPTURE METADATA]\n\($0)" }

        if let evidenceJSON = result.evidenceJSON,
           let data = evidenceJSON.data(using: .utf8),
           let analysis = try? JSONDecoder().decode(
               VisualAttachmentAnalysisRecord.self,
               from: data
           ),
           analysis.hasSignals {
            let metadata = fileMetadata(
                filename: filename,
                mimeType: mimeType,
                sizeBytes: sizeBytes,
                result: nil
            )
            let full = (["[IMAGE EVIDENCE]\n\(analysis.semanticText)"] + [captureSection].compactMap { $0 })
                .joined(separator: "\n\n")
            var minimumSections = [metadata]
            if let summary = cleaned(analysis.summary) {
                minimumSections.append("[MODEL SUMMARY]\n\(summary)")
            }
            minimumSections.append("Content kind: \(analysis.contentKind.rawValue)")
            if let captureSection {
                minimumSections.append(captureSection)
            }
            let minimum = condensedPrefix
                + minimumSections.joined(separator: "\n\n")
            let selectedOCR = selectedPassages(
                from: analysis.visibleText,
                context: context,
                maximumSelectedChunks: 2
            )
            var condensedSections = minimumSections
            if !selectedOCR.isEmpty {
                condensedSections.append("[SELECTED OCR TEXT]\n\(selectedOCR)")
            }
            if !analysis.salientDetails.isEmpty {
                condensedSections.append(
                    "Visible details: \(analysis.salientDetails.prefix(4).joined(separator: "; "))"
                )
            }
            if !analysis.searchTerms.isEmpty {
                condensedSections.append(
                    "Search terms: \(analysis.searchTerms.prefix(6).joined(separator: ", "))"
                )
            }
            let condensed = condensedPrefix
                + condensedSections.joined(separator: "\n\n")
            return Evidence(full: full, condensed: condensed, minimum: minimum)
        }

        var sections: [String] = []
        if let summary = cleaned(result.summary) {
            sections.append(summary)
        }
        if let kind = cleaned(result.evidenceKind) {
            sections.append("Content kind: \(kind)")
        }
        if let ocrText = cleaned(result.ocrText) {
            sections.append("Visible text: \(ocrText)")
        }
        guard !sections.isEmpty else {
            throw ExtractionError.noUsableEvidence(
                filename: filename,
                reason: result.failureReason
            )
        }
        let metadata = fileMetadata(
            filename: filename,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            result: nil
        )
        let full = (["[IMAGE EVIDENCE]\n" + sections.joined(separator: "\n")] + [captureSection].compactMap { $0 })
            .joined(separator: "\n\n")
        let selectedOCR = selectedPassages(
            from: result.ocrText ?? "",
            context: context,
            maximumSelectedChunks: 2
        )
        let summaryAndKind = sections.filter { !$0.hasPrefix("Visible text:") }
        var minimumSections = [metadata] + summaryAndKind + [captureSection].compactMap { $0 }
        if summaryAndKind.isEmpty, !selectedOCR.isEmpty {
            minimumSections.append("[SELECTED OCR TEXT]\n\(selectedOCR)")
        }
        let minimum = condensedPrefix
            + minimumSections.joined(separator: "\n\n")
        let condensed: String
        if selectedOCR.isEmpty || summaryAndKind.isEmpty {
            condensed = minimum
        } else {
            condensed = minimum + "\n\n[SELECTED OCR TEXT]\n\(selectedOCR)"
        }
        return Evidence(full: full, condensed: condensed, minimum: minimum)
    }

    /// Capture time, MapKit place and captions recorded in a user-chosen
    /// photo, named in the reading language. The user just picked the file,
    /// so a MapKit lookup here is user-initiated.
    private static func captureMetadataEvidence(at url: URL) async -> String? {
        let reading = await Task.detached(priority: .userInitiated) {
            CaptureMetadataReader.readImage(at: url)
        }.value
        guard var metadata = reading?.metadata, metadata.hasContent else { return nil }
        if let coordinate = metadata.coordinate {
            metadata.place = (try? await PlaceNameResolver.shared.place(
                for: coordinate,
                languageIdentifier: SummarizationTargetLanguage.ohiaPreferred().identifier
            )) ?? nil
        }
        return metadata.evidenceText
    }

    private static let condensedPrefix =
        ComposerSourcePresentation.condensedContextMarker + "\n"

    private static func fileMetadata(
        filename: String,
        mimeType: String,
        sizeBytes: Int?,
        result: AttachmentExtractionResult?
    ) -> String {
        var sections = [
            "[FILE METADATA]",
            "Filename: \(filename)",
            "MIME type: \(mimeType)"
        ]
        if let sizeBytes {
            sections.append(
                "File size: \(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))"
            )
        }
        if let result {
            if let unit = cleaned(result.structureUnitKind),
               let count = result.structureUnitCount,
               count > 0 {
                sections.append("Structure: \(count) \(count == 1 ? unit : unit + "s")")
            }
            if let title = cleaned(result.documentTitle) {
                sections.append("Title: \(title)")
            }
            if let author = cleaned(result.documentAuthor) {
                sections.append("Author: \(author)")
            }
        }
        return sections.joined(separator: "\n")
    }

    private static func selectedPassages(
        from text: String,
        context: Context,
        maximumSelectedChunks: Int
    ) -> String {
        guard cleaned(text) != nil else { return "" }
        return ComposerPassageSelector(
            windowSize: 384,
            overlap: 64,
            maximumSelectedChunks: maximumSelectedChunks
        ).select(
            from: text,
            anchorTerms: context.anchorTerms
        )
    }

    private static func documentEvidence(
        result: AttachmentExtractionResult,
        text: String
    ) -> String {
        var sections = [
            "[DOCUMENT EVIDENCE]",
            "Type: \(result.kind.rawValue)"
        ]
        if let unit = cleaned(result.structureUnitKind),
           let count = result.structureUnitCount,
           count > 0 {
            sections.append("Structure: \(count) \(count == 1 ? unit : unit + "s")")
        }
        if let title = cleaned(result.documentTitle) {
            sections.append("Title: \(title)")
        }
        if let author = cleaned(result.documentAuthor) {
            sections.append("Author: \(author)")
        }
        sections.append("Content:\n\(text)")
        return sections.joined(separator: "\n")
    }

    private static func cleaned(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned : nil
    }
}

private extension ComposerFileSourceEvidenceExtractor.Context {
    nonisolated var anchorTerms: [String] {
        [subject, senderName, purpose?.rawValue]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }
}

/// Picks the richest file evidence that fits the draft writer's room for
/// sources the author adds (`writerUsage`, the draft's latest measurement).
nonisolated enum ComposerFileSourceCapacityFitter {
    static func selection(
        filename: String,
        filePath: String,
        evidence: ComposerFileSourceEvidenceExtractor.Evidence,
        currentSources: [ComposerSource],
        writerUsage: ComposerWriterWindowUsage?,
        unmeasuredContext: String
    ) -> ComposerSource? {
        for snippet in evidence.variants {
            let source = ComposerSource(
                kind: .file,
                label: filename,
                snippet: snippet,
                filePath: filePath,
                isUserAdded: true
            )
            let estimate = ComposerSourceCapacityEstimator.estimate(
                currentSources: currentSources,
                proposedSources: [source],
                writerUsage: writerUsage,
                unmeasuredContext: unmeasuredContext
            )
            if !estimate.wouldExceed {
                return source
            }
        }
        return nil
    }

    static func minimumEstimate(
        filename: String,
        filePath: String,
        evidence: ComposerFileSourceEvidenceExtractor.Evidence,
        currentSources: [ComposerSource],
        writerUsage: ComposerWriterWindowUsage?,
        unmeasuredContext: String
    ) -> ComposerSourceCapacityEstimate {
        let source = ComposerSource(
            kind: .file,
            label: filename,
            snippet: evidence.minimum,
            filePath: filePath,
            isUserAdded: true
        )
        return ComposerSourceCapacityEstimator.estimate(
            currentSources: currentSources,
            proposedSources: [source],
            writerUsage: writerUsage,
            unmeasuredContext: unmeasuredContext
        )
    }
}

/// Shared label / snippet / extraction helpers for source construction.
/// Snippet readers are `nonisolated` so call sites can run them off-main —
/// bodies, extracted text, and external files can be arbitrarily large.
@MainActor
enum ComposerSourceText {

    /// "fromName · subject · short date" — mirrors the pipeline compiler's
    /// label shape so automatic and user-added rows read alike.
    static func label(for message: Message) -> String {
        let sender = message.fromName ?? message.fromAddress
        let date = shortDate(message.pipelineOrderingDate)
        return "\(sender) · \(message.subject) · \(date)"
    }

    /// Leading slice of a stored text file (message body or extracted
    /// attachment text); the fallback stands in when the file is missing,
    /// unreadable, or empty.
    nonisolated static func textFileSnippet(
        atPath path: String?,
        fallback: String = "(content could not be extracted)",
        limit: Int = 700
    ) -> String {
        guard let path, !path.isEmpty,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return fallback
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(limit))
    }

    // Cached: chained `Date.FormatStyle` expressions have hit type-checker
    // limits in this codebase, and a fresh DateFormatter per call is
    // expensive on the render path.
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func shortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    /// Best-effort plain-text extraction for "File on Disk" sources. The
    /// content lives in the snippet so the worker process never needs file
    /// access; failures still add the source with an explicit marker. Plain
    /// and PDF extraction run detached; `NSAttributedString` imports stay on
    /// main because the HTML importer is main-thread-only (and RTF / DOCX
    /// imports are fast).
    static func extractFileText(at url: URL, limit: Int = 4000) async -> String {
        let failure = "(content could not be extracted)"
        let text: String?
        switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown", "text", "log", "csv", "tsv", "json", "xml", "":
            text = await Task.detached(priority: .userInitiated) {
                plainText(at: url)
            }.value
        case "pdf":
            text = await Task.detached(priority: .userInitiated) {
                pdfText(at: url)
            }.value
        case "rtf", "rtfd", "docx", "doc", "odt", "html", "htm", "webarchive":
            text = attributedText(at: url)
        default:
            // Unknown extension: rich importers first (they reject binary
            // junk), plain text as the last resort.
            if let rich = attributedText(at: url) {
                text = rich
            } else {
                text = await Task.detached(priority: .userInitiated) {
                    pdfText(at: url) ?? plainText(at: url)
                }.value
            }
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return failure
        }
        return String(trimmed.prefix(limit))
    }

    nonisolated private static func plainText(at url: URL) -> String? {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        // Non-UTF-8 text files decode lossily rather than failing outright —
        // but only when the bytes look like text (no NUL bytes), so binary
        // files fall through to the failure marker instead of garbage.
        guard let data = try? Data(contentsOf: url), !data.contains(0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// PDF text comes from the sandboxed LiteParse service, the same path as
    /// mail attachments, with PDFKit as its fallback. Files without a PDF
    /// header (the PDF format allows it anywhere in the first 1024 bytes)
    /// are not PDFs and never reach the parser.
    nonisolated private static func pdfText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil else {
            return nil
        }
        return AttachmentExtractor.extract(
            data: data,
            mimeType: "application/pdf",
            filename: url.lastPathComponent,
            policy: .full
        )?.text
    }

    private static func attributedText(at url: URL) -> String? {
        (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
    }
}

/// The sources of one type, as the closed Sources column shows them: one
/// icon with a count. Kinds drawn with the same icon (the thread's state and
/// its messages) share a group. Groups keep the order their first source has
/// in the list.
struct ComposerSourceTypeGroup: Identifiable, Equatable {
    /// Sources listed by name in a type's tooltip before the rest are counted.
    static let helpListLimit = 8

    let symbolName: String
    let name: String
    let sources: [ComposerSource]
    /// Sources the draft writer leaves out of the draft.
    let leftOutIDs: Set<UUID>

    var id: String { symbolName }

    /// Every source of the type is left out of the draft.
    var isAllLeftOut: Bool {
        sources.allSatisfy { leftOutIDs.contains($0.id) }
    }

    static func groups(for sources: [ComposerSource], leftOut: Set<UUID>) -> [ComposerSourceTypeGroup] {
        var order: [String] = []
        var names: [String: String] = [:]
        var members: [String: [ComposerSource]] = [:]
        for source in sources {
            let symbol = source.kind.sourceSymbolName
            if members[symbol] == nil {
                order.append(symbol)
                names[symbol] = source.kind.sourceTypeName
            }
            members[symbol, default: []].append(source)
        }
        return order.map { symbol in
            let groupSources = members[symbol] ?? []
            return ComposerSourceTypeGroup(
                symbolName: symbol,
                name: names[symbol] ?? "",
                sources: groupSources,
                leftOutIDs: leftOut.intersection(groupSources.map(\.id))
            )
        }
    }

    /// The type and its count, then its sources by name, marking any the
    /// draft leaves out; past `helpListLimit` the rest are counted.
    func helpText(label: (ComposerSource) -> String) -> String {
        var lines = ["\(name) · \(sources.count)"]
        for source in sources.prefix(Self.helpListLimit) {
            let line = label(source)
            lines.append(leftOutIDs.contains(source.id) ? "\(line) (left out of draft)" : line)
        }
        let remaining = sources.count - Self.helpListLimit
        if remaining > 0 {
            lines.append("and \(remaining) more")
        }
        return lines.joined(separator: "\n")
    }
}

extension ComposerSource.Kind {
    /// The type's name on the closed Sources column's tooltips.
    var sourceTypeName: String {
        switch self {
        case .threadState, .thread: "Thread"
        case .pastReply: "Your past emails"
        case .memory: "Memories"
        case .attachment: "Attachments"
        case .retrieved: "Related emails"
        case .email: "Emails"
        case .note: "Memos"
        case .file: "Files"
        case .website: "Websites"
        case .calendar: "Calendar"
        case .contact: "Contacts"
        case .notesApp: "Apple Notes"
        case .screenshot: "Screenshots"
        case .messages: "Messages"
        case .mcp: "MCP servers"
        }
    }

    var sourceSymbolName: String {
        switch self {
        case .threadState: "bubble.left.and.bubble.right"
        case .thread: "bubble.left.and.bubble.right"
        case .pastReply: "arrowshape.turn.up.left"
        case .memory: "brain"
        case .attachment: "paperclip"
        case .retrieved: "sparkle.magnifyingglass"
        case .email: "envelope"
        case .note: "pencil.line"
        case .file: "doc"
        case .website: "globe"
        case .calendar: "calendar"
        case .contact: "person.crop.rectangle"
        case .notesApp: "note.text"
        case .screenshot: "camera.viewfinder"
        case .messages: "message"
        case .mcp: "server.rack"
        }
    }
}
