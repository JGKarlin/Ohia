// Ohia/Composer/ComposerView.swift
// The Composer: Ohia's reply-drafting workflow surface, replacing the
// retired Focus mode. A queue of triaged needs-reply messages on the left;
// for the selected message, a left-to-right step flow — resolve the
// clarifying decisions, then review, revise, and send the generated draft.
// Sending feeds the training-pair loop (edit diff) and the dimension-indexed
// drafting-rule distillation.

import SwiftUI
import SwiftData
import Foundation
import OhiaCore
import OhiaMail
import OhiaML
import OhiaScheduler

nonisolated struct ComposerIncomingMessageBody: Sendable {
    let plainText: String
    let htmlDocument: LockReadoutHTMLDocument?

    init?(source: LockReadoutBodySource) {
        let displaySource: LockReadoutBodySource
        switch source.format {
        case .plainText:
            displaySource = source
        case .html:
            displaySource = LockReadoutBodySource(
                text: frontPageFocusedMessageHTML(source.text),
                format: .html,
                baseURL: source.baseURL,
                inlineAttachments: source.inlineAttachments
            )
        }

        let content = LockReadoutBodyContent(source: displaySource)
        let cleanedText = OriginalMessageText.cleaned(from: content.plainText)
            ?? content.plainText
        let trimmedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else { return nil }

        plainText = trimmedText
        htmlDocument = content.htmlDocument
    }
}

enum ComposerDraftSignalReviewPreference {
    static let storageKey = "ohia.composerReviewDraftSignalsBeforeSending"
    static let defaultValue = false
}

enum ComposerTerminationFlushError: Error {
    case missingReplyMessage
    case missingReplyDraft
    case missingComposeDraft
}

enum ComposerTrainingSignalSendDecision {
    case review([TrainingSignal])
    case send([TrainingSignal]?)
}

struct ComposerDraftVersionBarItem: Identifiable, Equatable {
    let version: ComposerDraftVersion
    let isSelected: Bool

    var id: UUID { version.id }
    var label: String { "v\(version.index)" }
}

struct ComposerDecisionVersionBarItem: Identifiable, Equatable {
    let version: ComposerDecisionVersion
    let isSelected: Bool

    var id: UUID { version.id }
    var label: String { "v\(version.index)" }
}

struct ComposerView: View {
    /// Message to select on open (from Almanac rows, notifications, or the
    /// Constellation locked node). Nil opens on the queue's first item.
    let initialMessageID: UUID?

    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var appServices: AppServices?
    @Environment(AutomaticMessagesAccessCoordinator.self)
    private var automaticMessagesAccessCoordinator: AutomaticMessagesAccessCoordinator?
    @Environment(\.colorScheme) private var colorScheme

    @State private var queueItems: [ComposerQueueItem] = []
    @State private var selectedID: UUID?
    @State private var queueSelection = ComposerQueueSelection()
    @State private var activeMessage: Message?
    /// A reply message shown by explicit out-of-queue direct-open (e.g. a
    /// notification for a specific draft). Exempt from the queue reconcile in
    /// `refreshQueue`, so the 2.5s poll never clears an intentionally-opened
    /// message that isn't a queue member. Set by `selectMessage` based on live
    /// membership; cleared when a compose surface takes over.
    @State private var directOpenMessageID: UUID?
    @State private var activeMessageBody: ComposerIncomingMessageBody?
    @State private var activeMessageBodyLoadKey: String?
    @State private var session: ComposerSession? {
        didSet {
            if oldValue?.messageID != session?.messageID {
                Self.publishOpenReply(session?.messageID)
            }
        }
    }
    @State private var readCoordinator = ComposerReadCoordinator()
    /// Reply sessions use a replaceable context for the same reason standalone
    /// compose does: source preparation and question generation are written by
    /// another process, and a registered model in the window's root context is
    /// not an authoritative poll boundary.
    @State private var replyModelContext: ModelContext?
    /// Active compose-from-scratch surface, when a `.compose` queue item is
    /// selected. Mutually exclusive with `session` (reply flow).
    @State private var composeState: ComposeState?
    /// Full new-message header shown before a recipient or subject commit
    /// creates a persisted Draft row.
    @State private var provisionalComposeState = ComposerProvisionalComposeState()
    @State private var isStartingNewMessage = true
    /// Compose uses its own context so replacing the state during a worker
    /// poll cannot return the main context's registered, pre-worker Draft.
    /// This same context is injected into every compose child, including
    /// Sources, so all edits remain on one coherent object graph.
    @State private var composeModelContext: ModelContext?
    /// A single queued reply or compose draft pending deletion confirmation.
    @State private var pendingQueueDelete: ComposerQueueItem?
    /// Multi-selected queue drafts always confirm as one batch, including
    /// Command-Delete, so a modifier cannot silently discard dozens of drafts.
    @State private var pendingBulkDelete: [ComposerQueueItem] = []
    @State private var pendingConfirmedDiscardIDs: Set<UUID> = []
    @State private var sendError: String?
    @State private var replySendNowInFlightIDs: Set<UUID> = []
    @State private var identities: [Identity] = []
    @State private var cachedDispatcher: SendDispatcher?
    @State private var attachmentImportRegistry = ComposerAttachmentImportRegistry()
    @AppStorage("showComposerActivityStrip") private var showActivityStrip = true
    @State private var sendTakeoverCoordinator = ComposerSendTakeoverCoordinator()
    @State private var sendTakeoverPollTask: Task<Void, Never>?
    @AppStorage(SentMailSoundPreference.storageKey)
    private var sentMailSoundFilename = SentMailSoundPreference.defaultFilename
    @AppStorage(ComposerDraftSignalReviewPreference.storageKey)
    private var reviewDraftEditsBeforeSending = ComposerDraftSignalReviewPreference.defaultValue
    /// Column open state persists across messages and launches; the View ›
    /// Composer Columns menu writes the same keys.
    @AppStorage(ComposerColumn.queue.openStorageKey) private var isQueueColumnOpen = true
    @AppStorage(ComposerColumn.sources.openStorageKey) private var isSourcesColumnOpen = true
    @AppStorage(ComposerColumn.style.openStorageKey) private var isStyleColumnOpen = true
    /// The columns' left-to-right order (`ComposerColumnOrder`).
    @AppStorage(ComposerColumnOrder.storageKey) private var columnOrderStorage = ComposerColumnOrder.defaultStorageValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The column under the pointer, which Space and the View › Composer
    /// Columns moves act on. Read by the menu and the columns' hover cue,
    /// not by this view, so pointer movement does not re-render it.
    @State private var columnPointer = ComposerColumnPointer()

    static func requiresQueueDeleteConfirmation(for item: ComposerQueueItem) -> Bool {
        !item.state.isOutbox
    }

    static func canConfirmQueueDeletion(
        _ pendingItem: ComposerQueueItem,
        liveItems: [ComposerQueueItem]
    ) -> Bool {
        liveItems.contains {
            $0.id == pendingItem.id
                && $0.kind == pendingItem.kind
                && requiresQueueDeleteConfirmation(for: $0)
        }
    }

    /// Saves the active reply editor and buffered recipients as one durable
    /// transaction before the app begins asynchronous shutdown work.
    @MainActor
    static func flushReplyForTermination(
        session: ComposerSession,
        context: ModelContext,
        adoptingViewedVersion: Bool = true,
        stageDraftSync: ComposerDraftSyncStager = ComposerDraftSyncScheduler.stageDraftSync,
        saveContext: ComposerContextSaver = ComposerPersistence.save
    ) throws -> ComposerRecipientCommitResult {
        let editorProjection = session.editorPersistenceProjection(
            adoptingViewedVersion: adoptingViewedVersion
        )
        guard editorProjection.hasEdits || session.hasPendingChangesToSave else { return .valid }
        guard fetchMessage(session.messageID, context: context) != nil else {
            throw ComposerTerminationFlushError.missingReplyMessage
        }
        guard let draft = session.backingDraft(in: context) else {
            throw ComposerTerminationFlushError.missingReplyDraft
        }
        let draftID = draft.id
        let predicate = #Predicate<Draft> { $0.id == draftID }
        let authoritativeContext = ModelContext(context.container)
        guard draft.status == .pending,
              try authoritativeContext.fetch(FetchDescriptor<Draft>(predicate: predicate)).first?.status == .pending else {
            throw ComposerEditorFlushError.settledDraft
        }

        let projectsBody = editorProjection.hasEdits
        let editorHTML = projectsBody ? session.exportedHTML(for: editorProjection.snapshot) : nil
        if projectsBody, editorProjection.snapshot.format == .richText, editorHTML == nil {
            throw ComposerEditorFlushError.richTextExportFailed
        }
        let recipientProjection = session.stageAddressBuffersForTermination(on: draft)

        if let viewedVersion = editorProjection.historicalVersion {
            draft.baseRevisionID = viewedVersion.id
            draft.styleRegisterID = viewedVersion.styleRegisterID
            draft.styleControlSnapshot = viewedVersion.styleControlSnapshot
            draft.generatedSourcesJSON = viewedVersion.generatedSourcesJSON
            draft.pendingStyleControlSnapshot = nil
        }
        if projectsBody {
            draft.replyText = ComposerRichTextCodec.plainBodyProjection(of: editorProjection.snapshot.content)
            draft.messageFormatRaw = editorProjection.snapshot.format.rawValue
            draft.inlinePhotosJSON = ComposerInlinePhotoAssetCoding.encode(editorProjection.snapshot.inlinePhotos)
            draft.bodyHTML = editorHTML
            try ComposerManualEdit.recordSnapshot(on: draft, context: context)
        }
        if recipientProjection.didChangeDraft {
            // Recipient changes invalidate the active decision projection. Do
            // this after the body projection so history captures the final
            // body and provenance being committed by this transaction.
            ComposerDecisionHistoryPersistence.refreshActiveVersionFromDraft(on: draft)
        }

        guard recipientProjection.didChangeDraft || projectsBody || context.hasChanges else {
            session.acceptAddressBuffersForTermination(recipientProjection)
            return recipientProjection.outcome
        }

        do {
            try stageDraftSync(draft, context)
            try saveContext(context)
        } catch {
            // Keep both the session buffers and pending model/header changes
            // available for retry when close or Quit is vetoed.
            throw error
        }

        session.acceptAddressBuffersForTermination(recipientProjection)
        if projectsBody {
            session.acceptPersistedEditorProjection(editorProjection, html: draft.bodyHTML)
        }
        return recipientProjection.outcome
    }

    static func trainingSignalSendDecision(
        for session: ComposerSession,
        reviewDraftEditsBeforeSending: Bool,
        analyzer: any EditAnalyzing,
        languageID: String?
    ) -> ComposerTrainingSignalSendDecision {
        if session.showDiffAnalysis {
            return .send(session.trainingSignals)
        }
        guard session.hasTextEdits else {
            return .send(nil)
        }

        let signals = analyzer.analyze(
            originalDraft: session.baselineText,
            editedDraft: session.plainEditorText,
            correspondentEmail: session.correspondentEmail,
            citations: session.citations,
            languageID: languageID
        )
        if reviewDraftEditsBeforeSending {
            return .review(signals)
        }
        return .send(signals.isEmpty ? nil : signals)
    }

    private func dispatcher(context: ModelContext? = nil) -> SendDispatcher {
        let context = context ?? modelContext
        if context === modelContext {
            if let cachedDispatcher { return cachedDispatcher }
            let new = SendDispatcher(context: context, jobQueue: JobQueue())
            cachedDispatcher = new
            return new
        }
        return SendDispatcher(context: context, jobQueue: JobQueue())
    }

    /// Starts the full-composer send takeover for a just-enqueued OutboxItem.
    /// The candidate is chosen by the user's configured sent-mail sound. The
    /// flourish resolves on the earliest genuine send evidence: this poll's
    /// `.sent` sighting (durable SMTP acceptance, usually first) or the
    /// worker's post-housekeeping `.ohiaMailSendConfirmed` hint (the
    /// coordinator listens for that itself). Either way the coordinator owns
    /// playing the coqui at the flourish's white-out; the durable playback
    /// flag is consumed only on the hint. Past the grace deadline with no
    /// acceptance seen, the takeover fades quietly.
    private func beginSendTakeover(outboxItemID: UUID, accountColorIndex: Int?) {
        let candidate = ComposerSendTakeoverCandidate.resolve(sentMailSoundFilename: sentMailSoundFilename)
        sendTakeoverCoordinator.begin(outboxItemID: outboxItemID, candidate: candidate, accountColorIndex: accountColorIndex)

        sendTakeoverPollTask?.cancel()
        sendTakeoverPollTask = Task { @MainActor in
            let deadline = Date().addingTimeInterval(ComposerSendTakeoverCoordinator.gracePeriod)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled,
                      sendTakeoverCoordinator.active?.outboxItemID == outboxItemID,
                      sendTakeoverCoordinator.active?.resolution == nil else { return }
                if let item = fetchOutboxItem(outboxItemID) {
                    switch item.status {
                    case .failed, .cancelled:
                        sendTakeoverCoordinator.resolveFailed(outboxItemID: outboxItemID)
                        return
                    case .sent:
                        // `.sent` is durable SMTP acceptance — the earliest
                        // evidence the send really happened, typically well
                        // before the worker's post-housekeeping hint. Resolve
                        // the flourish now; the coordinator plays the coqui
                        // at its own white-out, and the durable playback
                        // flag is only ever consumed on the hint (never
                        // here), so the worker's later whole-row saves race
                        // nothing.
                        sendTakeoverCoordinator.resolveConfirmed(outboxItemID: outboxItemID)
                        return
                    case .queued, .sending:
                        break
                    }
                }
                if Date() >= deadline {
                    sendTakeoverCoordinator.resolveTimedOut(outboxItemID: outboxItemID)
                    return
                }
            }
        }
    }

    private func finishSendTakeover() {
        sendTakeoverPollTask?.cancel()
        sendTakeoverPollTask = nil
        sendTakeoverCoordinator.dismiss()
    }

    private var activeChildModelContext: ModelContext {
        if composeState != nil, let composeModelContext {
            return composeModelContext
        }
        if session != nil, let replyModelContext {
            return replyModelContext
        }
        return modelContext
    }

    private var activeReplyModelContext: ModelContext {
        replyModelContext ?? modelContext
    }

    var body: some View {
        let activeQueueItem = session.flatMap { activeSession in
            queueItems.first { $0.id == activeSession.messageID && $0.kind == .reply }
        }

        VStack(spacing: 0) {
            ComposerBriefHeaderBar(
                session: session,
                composeState: composeState,
                provisionalComposeState: session == nil && composeState == nil && isStartingNewMessage
                    ? provisionalComposeState
                    : nil,
                message: activeMessage,
                queueItem: activeQueueItem,
                replyIdentities: identities,
                replyIdentity: session.map { activeSession in
                    Binding(
                        get: {
                            let current = fetchMessage(activeSession.messageID)?.draft?.fromIdentityID
                            return identities.first(where: { $0.id == current })
                                ?? identities.first(where: { $0.isPrimary })
                                ?? identities.first
                        },
                        set: { newIdentity in
                            guard let newIdentity else { return }
                            applyIdentityChange(to: newIdentity, session: activeSession)
                        }
                    )
                },
                replySignatureSlots: session?.accountSignatureSlots ?? [],
                replySignatureSlotID: session.map { activeSession in
                    Binding(
                        get: { activeSession.resolvedSignatureSlotID },
                        set: { newID in
                            applySignatureSlotChange(
                                to: activeSession.accountSignatureSlots.first(where: { $0.id == newID }),
                                session: activeSession
                            )
                        }
                    )
                }
            )

            if let error = sendError ?? composeState?.persistenceError {
                errorBanner(error)
            }

            columnsRow

            if showActivityStrip {
                ComposerEvidenceFooterBar(
                    sources: composeState?.sources ?? session?.sources ?? [],
                    sourceContextTokenCount: composeState?.draft.flatMap {
                        ComposerWriterWindowUsage.currentCount($0.sourceContextTokenCount,
                            fitJSON: $0.sourceContextFitJSON)
                    } ?? session?.sourceContextTokenCount,
                    sourceContextTokenLimit: composeState?.draft?.sourceContextTokenLimit
                        ?? session?.sourceContextTokenLimit,
                    isMeasuringSourceContext: composeState.map {
                        $0.draft?.sourceContextMeasurementRequestedAt != nil
                    } ?? session?.isMeasuringSourceContext ?? false
                )
                    .environment(
                        \.activityStripComposerTarget,
                        ActivityStripComposerTarget(
                            messageID: session?.messageID,
                            isActive: session != nil || composeState != nil
                        )
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .modelContext(activeChildModelContext)
        .animation(.easeInOut(duration: 0.2), value: showActivityStrip)
        .composerKeyboardHandler(
            session: session,
            onSend: {
                if let composeState {
                    handleComposeSend(composeState)
                } else if let session {
                    handleSend(session)
                }
            },
            onDeleteSelected: { deleteSelectedQueueItem() }
        )
        .background(
            colorScheme == .dark
                ? OhiaColors.composerPanelBackground
                : OhiaColors.toolbarBackground
        )
        .tint(OhiaColors.chipActiveForeground)
        .overlay {
            if sendTakeoverCoordinator.active != nil {
                ComposerSendTakeoverOverlay(coordinator: sendTakeoverCoordinator) {
                    finishSendTakeover()
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: sendTakeoverCoordinator.active != nil)
        .confirmationDialog(
            "Discard draft?",
            isPresented: Binding(
                get: { pendingQueueDelete != nil },
                set: { if !$0 { pendingQueueDelete = nil } }
            ),
            presenting: pendingQueueDelete
        ) { item in
            Button("Discard", role: .destructive) {
                performConfirmedQueueDiscard(item)
                pendingQueueDelete = nil
            }
            // Make Discard the default so Return/Enter confirms. A .destructive
            // role does not auto-bind the default action (matching NSAlert's
            // hasDestructiveAction suppression), so bind it explicitly. Cancel
            // keeps Escape via its .cancel role.
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { pendingQueueDelete = nil }
        } message: { _ in
            Text("This removes the draft from Composer and deletes its provider Drafts copy where present.")
        }
        .confirmationDialog(
            "Discard \(pendingBulkDelete.count) drafts?",
            isPresented: Binding(
                get: { !pendingBulkDelete.isEmpty },
                set: { if !$0 { pendingBulkDelete = [] } }
            )
        ) {
            Button("Discard \(pendingBulkDelete.count) Drafts", role: .destructive) {
                performBulkDiscard(pendingBulkDelete)
                pendingBulkDelete = []
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { pendingBulkDelete = [] }
        } message: {
            Text("This removes the selected items from Composer and deletes their provider Drafts copies where present.")
        }
        .onAppear {
            // Tell the generative worker the Composer is the front surface:
            // question prep and drafting get foreground model priority for
            // as long as this view is mounted.
            NotificationCenter.default.post(
                name: .ohiaComposerSurfaceActive,
                object: nil,
                userInfo: ["active": true]
            )
            provisionalComposeState.reset(context: modelContext)
            if AppCommand.pendingComposerNewMessage() {
                AppCommand.clearPendingComposerNewMessage()
                beginNewMessage()
                refreshQueue()
                return
            }
            // Other compose entry points can still latch a specific existing
            // draft to select.
            if let composeID = AppCommand.pendingComposerComposeDraftID() {
                AppCommand.clearPendingComposerComposeDraftID()
                selectComposeDraft(id: composeID)
                refreshQueue()
                return
            }
            refreshQueue(afterInstall: { selectInitialOrFirstReply() })
        }
        .onChange(of: provisionalComposeState.promotionRequest) { _, request in
            if let request {
                promoteProvisionalMessage(request)
            }
        }
        .onDisappear {
            _ = flushComposeEditorBeforeLeaving()
            readCoordinator.cancel()
            automaticMessagesAccessCoordinator?.deactivate()
            NotificationCenter.default.post(
                name: .ohiaComposerSurfaceActive,
                object: nil,
                userInfo: ["active": false]
            )
            Self.publishOpenReply(nil)
            // The real send is unaffected — OutboxWorker keeps working in the
            // background regardless of whether this view or its takeover is
            // on screen. This only stops the local poll/overlay from lingering.
            sendTakeoverPollTask?.cancel()
            sendTakeoverPollTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaWillPrepareForTermination)) { notification in
            do {
                if let composeState {
                    let outcome = try composeState.flushForTermination()
                    try outcome.requireValidForLeaving()
                    print("[Ohia] Composer termination flush completed for compose lane: \(outcome)")
                } else if let session {
                    let outcome = try Self.flushReplyForTermination(
                        session: session,
                        context: activeReplyModelContext,
                        adoptingViewedVersion: false
                    )
                    try outcome.requireValidForLeaving()
                    print("[Ohia] Composer termination flush completed for reply lane: \(outcome)")
                }
            } catch {
                (notification.object as? AppTerminationPreparation)?.reportFailure(error)
                sendError = "Could not save the current draft: \(error.localizedDescription)"
                NSLog(
                    "[Ohia] Composer termination flush failed: %@",
                    String(reflecting: type(of: error))
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaComposerDismissNoReply)) { _ in
            guard let selectedID,
                  let item = queueItems.first(where: { $0.id == selectedID }) else { return }
            dismissNoReply(item)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaComposerSelectMessage)) { notification in
            guard let requestedID = notification.userInfo?["messageID"] as? UUID else { return }
            // An earlier email its conversation's reply covers opens that reply.
            let id = ComposerQueueMembership.queueItemMessageID(
                for: requestedID,
                context: ModelContext(modelContext.container)
            )
            guard id != selectedID else { return }
            guard flushComposeEditorBeforeLeaving() else { return }
            readCoordinator.changeSelection()
            refreshQueue(afterInstall: { selectMessage(id: id) })
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaComposerSelectCompose)) { notification in
            guard let id = notification.userInfo?["draftID"] as? UUID else { return }
            AppCommand.clearPendingComposerComposeDraftID()
            refreshQueue()
            selectComposeDraft(id: id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaComposerBeginNewMessage)) { _ in
            AppCommand.clearPendingComposerNewMessage()
            beginNewMessage()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: AutomaticMessagesAccessCoordinator.didMergeSourceNotification
            )
        ) { notification in
            guard let mergedDraftID = notification.userInfo?["draftID"] as? UUID else {
                return
            }
            let activeDraftID = session?.backingDraft(in: activeReplyModelContext)?.id
                ?? composeState?.draft?.id
            guard mergedDraftID == activeDraftID else { return }
            reloadSelectedFromStore()
            reloadComposeStateFromStore()
        }
        .modifier(AutomaticMessagesAccessPresentation())
        .background {
            ComposerWindowCloseGuard(shouldClose: { flushComposeEditorBeforeLeaving() })
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .task(id: session.map { ObjectIdentifier($0) }, priority: .utility) {
            await loadNeighborsForCurrentSession()
        }
        .task(id: selectedID) {
            activateAutomaticMessagesContext()
            // Steady poll while the Composer is open: question seeding,
            // generation, and revisions all happen in the Qwen worker
            // process, so the app refetches to see those writes land — for
            // the selected session AND for queue rows still waiting on
            // their question-stage draft.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2.5)) }
                catch { break }
                guard !Task.isCancelled else { break }
                reloadSelectedFromStore()
                if composeState != nil {
                    reloadComposeStateFromStore()
                    // The draft was sent/discarded out from under us.
                    if composeState?.draft == nil {
                        composeState = nil
                        selectedID = nil
                    }
                }
                refreshQueue(invalidatingInFlight: false)
            }
        }
    }

    /// The four columns in their persisted order, over the night sky in dark
    /// mode, with the training-review panel under them while it is open.
    /// Split out of `body` to keep its modifier chain within the type
    /// checker's budget.
    private var columnsRow: some View {
        VStack(spacing: 10) {
            ComposerColumnRow(
                order: columnOrder,
                isPresent: isColumnSlotPresent,
                spacing: 10,
                grabBand: columnGrabBand,
                layoutKey: columnOpenStates,
                pointer: columnPointer,
                moveActions: columnMoveActions,
                onReorder: { setColumnOrder($0) },
                onSpaceToggle: { toggleColumn($0) }
            ) { slot in
                columnSlot(slot)
            }
            .frame(maxHeight: .infinity)

            diffAnalysisPanel
        }
        .padding(colorScheme == .dark ? 16 : 10)
        .frame(maxHeight: .infinity)
        .background {
            if colorScheme == .dark {
                ComposerNightSkyBackdrop()
            }
        }
        .animation(reduceMotion ? nil : ComposerColumn.slideAnimation, value: columnOpenStates)
        // Scene-scoped, so the View › Composer Columns menu enables while this
        // window is key wherever focus sits inside it.
        .focusedSceneValue(\.composerColumnsCommandTarget, columnsCommandTarget)
    }

    @ViewBuilder
    private func columnSlot(_ slot: ComposerColumnSlot) -> some View {
        switch slot {
        case .queue:
            queueColumn
        case .sources:
            if let composeState {
                sourcesColumn(composeState)
            } else if let session {
                sourcesColumn(session)
            }
        case .draft:
            draftColumn
        case .style:
            if let composeState {
                styleColumn { composeStylePanel(composeState).id(ObjectIdentifier(composeState)) }
            } else if let session {
                styleColumn { replyStylePanel(session).id(ObjectIdentifier(session)) }
            }
        }
    }

    private var queueColumn: some View {
        ComposerQueuePane(
            items: queueItems,
            selectedIDs: queueSelection.selectedIDs,
            onSelectionClick: { handleQueueSelectionClick($0, modifiers: $1) },
            onSelectAll: { selectAllQueueDrafts() },
            onNewMessage: { beginNewMessage() },
            onAction: { handleQueueAction($0, item: $1) },
            columnControl: columnControl(.queue)
        )
        .frame(width: isQueueColumnOpen ? ComposerColumn.queue.openWidth : ComposerColumn.railWidth)
    }

    // MARK: - Stage

    /// The Draft column: the active item's Decisions or Draft step, or the
    /// empty stage when nothing is open.
    private var draftColumn: some View {
        Group {
            if let composeState {
                composeStageColumn(composeState)
            } else if let session {
                replyStageColumn(session)
            } else {
                emptyStage
                    // The send takeover overlay's scrim doesn't fully
                    // opaque the composer content in its early frames,
                    // so this placeholder can bleed through right as
                    // a send clears the active session/compose state.
                    .opacity(sendTakeoverCoordinator.active == nil ? 1 : 0)
                    // No header to carry the column's moves while nothing
                    // is open, so the placeholder carries them.
                    .contentShape(Rectangle())
                    .contextMenu { ComposerColumnMoveMenuItems() }
                    .modifier(ComposerColumnMoveAccessibilityActions())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func replyStageColumn(_ session: ComposerSession) -> some View {
        switch session.step {
        case .decisions:
            ComposerQuestionsStep(
                session: session,
                messageSummary: messageSummary(for: session.messageID),
                messageBody: messageBody(for: session.messageID),
                initialSourceRequirementText: nil,
                onContinue: { handleContinue(session) },
                onCommitAnswer: {
                    handleCommitAnswer(
                        session,
                        node: $0,
                        selectedOptionID: $1,
                        freeText: $2,
                        skipped: $3
                    )
                },
                onChangeAnswer: { handleChangeAnswer(session, nodeID: $0) },
                onGenerate: { handleGenerate(session) },
                stageRail: replyStageRail(session)
            )
            .id(ObjectIdentifier(session))
        case .draft:
            ComposerDraftStep(
                session: session,
                onSave: { _ = persistEditorText(session) },
                onRegenerate: { handleRegenerate(session) },
                onInstruction: { handleInstruction(session, instruction: $0) },
                onAddAttachment: { presentAttachPanel(for: session) },
                onDropAttachments: { importDroppedAttachments($0, for: session) },
                onRemoveAttachment: {
                    guard session.removeAttachment(
                        at: $0,
                        context: activeReplyModelContext
                    ) else {
                        sendError = "Could not remove the attachment from this reply draft."
                        return
                    }
                    sendError = nil
                },
                onSetQuotedOriginalInclusion: {
                    updateQuotedOriginalInclusion($0, session: session)
                },
                onRetryQuotedOriginal: {
                    guard let message = fetchMessage(session.messageID) else {
                        session.failReplyQuotePreparation(
                            "The original message is no longer available."
                        )
                        return
                    }
                    refreshQuotedPreview(session, message: message, force: true)
                },
                onDiscard: nil,
                reviewDraftEditsBeforeSending: reviewDraftEditsBeforeSending,
                onSend: { handleSend(session) },
                beginInlinePhotoImport: {
                    beginInlinePhotoImport(for: session)
                },
                validateInlinePhotoImport: {
                    validateInlinePhotoImport($0, for: session)
                },
                finishInlinePhotoImport: {
                    finishInlinePhotoImport($0, for: session)
                },
                stageRail: replyStageRail(session)
            )
        }
    }

    /// The reply training-review panel, under the columns while it is open.
    @ViewBuilder
    private var diffAnalysisPanel: some View {
        if composeState == nil, let session, session.step == .draft,
           session.showDiffAnalysis && reviewDraftEditsBeforeSending {
            DiffAnalysisView(
                signals: Binding(
                    get: { session.trainingSignals },
                    set: { session.trainingSignals = $0 }
                ),
                onCancel: {
                    withAnimation { session.showDiffAnalysis = false }
                }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func replyStylePanel(_ session: ComposerSession) -> StyleRegisterPanel {
        StyleRegisterPanel(
            model: session.stylePanel,
            personalization: session.personalizationDisplay,
            onSelect: { handleRestyle(session, registerID: $0) },
            onSave: { handleSaveStyle(session, name: $0, axes: $1) },
            onRename: { handleRegisterRename(session, registerID: $0, newName: $1) },
            onDelete: { handleDeleteStyle(session, registerID: $0) },
            onSelectLanguage: { handleLanguageChange(session, languageID: $0) },
            onStyleAxesChange: { handleStyleAxesChange(session, axes: $0) },
            columnControl: columnControl(.style)
        )
    }

    private func replyStageRail(_ session: ComposerSession) -> some View {
        stepIndicator(
            session,
            allowsUnwrittenDraftSelection: false,
            versions: session.versions,
            viewingVersionIndex: session.viewingVersionIndex,
            onSelectDecisions: {
                do {
                    _ = try Self.flushReplyForTermination(
                        session: session, context: activeReplyModelContext, adoptingViewedVersion: false)
                } catch {
                    sendError = error.localizedDescription
                    return
                }
                session.isUserRevisitingDecisions = true
                session.step = .decisions
            },
            onSelectDecisionVersion: { version in
                restoreDecisionVersion(version, in: session)
            },
            onSelectDraft: {
                session.isUserRevisitingDecisions = false
                session.step = .draft
            },
            onSelectDraftVersion: { version in
                session.isUserRevisitingDecisions = false
                session.step = .draft
                selectDraftVersion(version, in: session)
            }
        )
    }

    @ViewBuilder
    private func composeStageColumn(_ state: ComposeState) -> some View {
        switch state.step {
        case .decisions:
            ComposerQuestionsStep(
                session: state,
                messageSummary: nil,
                messageBody: nil,
                initialSourceRequirementText: Self.initialSourceRequirementText(
                    hasRecipient: !state.toChips.isEmpty,
                    subject: state.draft?.composeSubject
                ),
                onContinue: { state.submitSourcesAndEvaluate() },
                onCommitAnswer: {
                    state.commitInterviewAnswer(
                        node: $0,
                        selectedOptionID: $1,
                        freeText: $2,
                        skipped: $3
                    )
                },
                onChangeAnswer: { state.changeAnswer(nodeID: $0) },
                onGenerate: { state.submitAnswersAndGenerate() },
                stageRail: composeStageRail(state)
            )
            .id(ObjectIdentifier(state))
        case .draft:
            ComposerDraftStep(
                session: state,
                onSave: {
                    do {
                        try state.saveEditorNow()
                        sendError = nil
                    } catch {
                        sendError = "Could not save the draft: \(error.localizedDescription)"
                    }
                },
                onRegenerate: { state.regenerate() },
                onInstruction: { state.submitRevision($0) },
                onAddAttachment: { presentAttachPanel(for: state) },
                onDropAttachments: { importDroppedAttachments($0, for: state) },
                onRemoveAttachment: {
                    guard state.removeAttachment(at: $0) else {
                        sendError = "Could not remove the attachment from this draft."
                        return
                    }
                    sendError = nil
                },
                onSetQuotedOriginalInclusion: nil,
                onRetryQuotedOriginal: nil,
                onDiscard: { requestActiveComposeDiscard(state) },
                reviewDraftEditsBeforeSending: reviewDraftEditsBeforeSending,
                onSend: { handleComposeSend(state) },
                beginInlinePhotoImport: {
                    beginInlinePhotoImport(for: state)
                },
                validateInlinePhotoImport: {
                    validateInlinePhotoImport($0, for: state)
                },
                finishInlinePhotoImport: {
                    finishInlinePhotoImport($0, for: state)
                },
                stageRail: composeStageRail(state)
            )
        }
    }

    private func composeStageRail(_ state: ComposeState) -> some View {
        stepIndicator(
            state,
            allowsUnwrittenDraftSelection: true,
            versions: state.versions,
            viewingVersionIndex: state.viewingVersionIndex,
            onSelectDecisions: { state.selectStep(.decisions) },
            onSelectDecisionVersion: { version in
                _ = state.restoreDecisionVersion(version)
            },
            onSelectDraft: { state.selectStep(.draft) },
            onSelectDraftVersion: { version in
                state.selectStep(.draft)
                selectDraftVersion(version, in: state)
            }
        )
    }

    private func composeStylePanel(_ state: ComposeState) -> StyleRegisterPanel {
        StyleRegisterPanel(
            model: state.stylePanel,
            personalization: state.personalizationDisplay,
            onSelect: { state.selectStyleRegister($0) },
            onSave: {
                do {
                    try state.saveCustomStyle(name: $0, axes: $1)
                    sendError = nil
                } catch {
                    sendError = error.localizedDescription
                }
            },
            onRename: {
                do {
                    try state.renameStyleRegister(id: $0, newName: $1)
                    sendError = nil
                } catch {
                    sendError = error.localizedDescription
                }
            },
            onDelete: {
                do {
                    try state.deleteStyleRegister(id: $0)
                    sendError = nil
                } catch {
                    sendError = error.localizedDescription
                }
            },
            onSelectLanguage: { state.selectDraftLanguage($0) },
            onStyleAxesChange: { state.selectStyleAxes($0) },
            columnControl: columnControl(.style)
        )
    }

    // MARK: - Columns

    private var columnOpenStates: [Bool] {
        [isQueueColumnOpen, isSourcesColumnOpen, isStyleColumnOpen]
    }

    private var columnOrder: [ComposerColumnSlot] {
        ComposerColumnOrder.decode(columnOrderStorage)
    }

    private func setColumnOrder(_ order: [ComposerColumnSlot]) {
        columnOrderStorage = ComposerColumnOrder.encode(order)
    }

    /// Queue and Draft are always on screen; Sources and Style only while a
    /// reply or compose draft is open.
    private func isColumnSlotPresent(_ slot: ComposerColumnSlot) -> Bool {
        switch slot {
        case .queue, .draft: true
        case .sources, .style: composeState != nil || session != nil
        }
    }

    private var presentColumnSlots: Set<ComposerColumnSlot> {
        Set(ComposerColumnSlot.allCases.filter(isColumnSlotPresent))
    }

    /// The band at a column's top whose hover shows its grabber: the header
    /// line of an open column, the icon stack of a rail.
    private func columnGrabBand(_ slot: ComposerColumnSlot) -> CGFloat {
        if let column = slot.closableColumn, !isColumnOpen(column) {
            return ComposerColumn.railGrabBand
        }
        return ComposerColumn.headerGrabBand
    }

    private func columnMoveActions(_ slot: ComposerColumnSlot) -> ComposerColumnMoveActions {
        let order = columnOrder
        let present = presentColumnSlots
        func action(_ direction: ComposerColumnMoveDirection) -> (() -> Void)? {
            guard ComposerColumnOrder.moving(slot, direction, in: order, present: present) != nil else { return nil }
            return { moveColumn(slot, direction) }
        }
        return ComposerColumnMoveActions(moveLeft: action(.left), moveRight: action(.right))
    }

    /// A move from a context menu, the menu bar, or an accessibility action.
    /// The columns trade places on the drawers' spring.
    private func moveColumn(_ slot: ComposerColumnSlot, _ direction: ComposerColumnMoveDirection) {
        guard let moved = ComposerColumnOrder.moving(
            slot,
            direction,
            in: columnOrder,
            present: presentColumnSlots
        ) else { return }
        withAnimation(reduceMotion ? nil : ComposerColumn.reorderAnimation) {
            setColumnOrder(moved)
        }
    }

    /// The View › Composer Columns commands. Move acts on the column under
    /// the pointer.
    private var columnsCommandTarget: ComposerColumnsCommandTarget {
        ComposerColumnsCommandTarget(
            pointer: columnPointer,
            order: columnOrder,
            present: presentColumnSlots,
            move: { moveColumn($0, $1) },
            resetOrder: {
                withAnimation(reduceMotion ? nil : ComposerColumn.reorderAnimation) {
                    setColumnOrder(ComposerColumnOrder.defaultOrder)
                }
            }
        )
    }

    private func columnControl(_ column: ComposerColumn) -> ComposerColumnControl {
        ComposerColumnControl(
            column: column,
            isOpen: isColumnOpen(column),
            toggle: { toggleColumn(column) },
            revealEdge: ComposerColumnOrder.revealEdge(of: column.slot, in: columnOrder)
        )
    }

    private func isColumnOpen(_ column: ComposerColumn) -> Bool {
        switch column {
        case .queue: isQueueColumnOpen
        case .sources: isSourcesColumnOpen
        case .style: isStyleColumnOpen
        }
    }

    /// Opens or closes a column from its chevron, its rail, its context menu,
    /// or Space with the pointer over it. Keyboard focus stays where it is.
    private func toggleColumn(_ column: ComposerColumn) {
        switch column {
        case .queue: isQueueColumnOpen.toggle()
        case .sources: isSourcesColumnOpen.toggle()
        case .style: isStyleColumnOpen.toggle()
        }
    }

    /// The Sources slot. The section renders both the open column and its
    /// rail inside one pane, so a source still being added, its sheets and
    /// its alerts carry on through either. The overflow warning hangs off
    /// the slot so it fires whether the column is open or closed.
    private func sourcesColumn<Host: ComposerSourceHost>(_ host: Host) -> some View {
        GlassPane(
            accentColor: OhiaColors.chipActiveForeground,
            isForeground: false,
            horizontalPadding: isSourcesColumnOpen ? ComposerColumn.openPanePadding : ComposerColumn.railHorizontalPadding
        ) {
            ComposerSourcesSection(
                host: host,
                fillsHeight: true,
                columnControl: columnControl(.sources)
            )
            // One item's in-progress additions and pickers never carry over
            // to the next; open/close and Decisions/Draft keep them.
            .id(ObjectIdentifier(host))
        }
        .frame(width: isSourcesColumnOpen ? ComposerColumn.sources.openWidth : ComposerColumn.railWidth)
        .modifier(ComposerSourceOverflowWarning(host: host))
    }

    /// The Style slot; the panel renders its own rail while the column is
    /// closed.
    private func styleColumn<Panel: View>(_ panel: () -> Panel) -> some View {
        panel()
            .frame(width: isStyleColumnOpen ? ComposerColumn.style.openWidth : ComposerColumn.railWidth)
    }

    /// Height of one stage-rail slot; every chip and the separator center in
    /// it so a wrapped row lines up like the single-line rail.
    private static let stageRailItemHeight: CGFloat = 26

    /// The flow rail: both steps always visible and clickable, so the user
    /// can move backward or forward at any point before sending. It sits
    /// under the stage column's header and wraps onto further rows when the
    /// version chips outgrow the column.
    private func stepIndicator<Host: ComposerDecisionsHost>(
        _ session: Host,
        allowsUnwrittenDraftSelection: Bool,
        versions: [ComposerDraftVersion],
        viewingVersionIndex: Int?,
        onSelectDecisions: @escaping () -> Void,
        onSelectDecisionVersion: @escaping (ComposerDecisionVersion) -> Void,
        onSelectDraft: @escaping () -> Void,
        onSelectDraftVersion: @escaping (ComposerDraftVersion) -> Void
    ) -> some View {
        WrappingChipStack(horizontalSpacing: 8, verticalSpacing: 6) {
            stepChip(
                number: 1,
                title: "Decisions",
                detail: session.isAwaitingModel || !session.hasDraftRow
                    ? nil
                    : session.decisionsStepSubtitle,
                isActive: session.step == .decisions
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { onSelectDecisions() }
            }

            ForEach(Self.decisionVersionBarItems(
                versions: session.decisionVersions,
                activeVersionID: session.activeDecisionVersionID
            )) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        onSelectDecisionVersion(item.version)
                    }
                } label: {
                    Text(item.label)
                        .font(OhiaTypography.cardDetail.monospacedDigit())
                        .foregroundStyle(
                            item.isSelected
                                ? OhiaColors.chipActiveForeground
                                : OhiaColors.textTertiary
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    item.isSelected
                                        ? OhiaColors.chipActiveBackground
                                        : OhiaColors.chipRestBackground
                                )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    item.isSelected
                                        ? OhiaColors.chipActiveBorder
                                        : OhiaColors.chipRestBorder,
                                    lineWidth: 1
                                )
                        }
                }
                .buttonStyle(.plain)
                .fixedSize()
                .frame(height: Self.stageRailItemHeight)
                .disabled(session.isAwaitingModel)
                .accessibilityLabel("Decisions version \(item.version.index)")
                .accessibilityAddTraits(item.isSelected ? [.isSelected] : [])
                .help("Restore Decisions version \(item.version.index)")
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(height: Self.stageRailItemHeight)
                .accessibilityHidden(true)

            stepChip(
                number: 2,
                title: "Draft",
                detail: session.isAwaitingModel || session.hasDraftVersions
                    ? nil
                    : "not written yet",
                isActive: session.step == .draft
            ) {
                guard Self.draftStepIsSelectable(
                    allowsUnwrittenDraftSelection: allowsUnwrittenDraftSelection,
                    hasDraftVersions: session.hasDraftVersions,
                    isAwaitingModel: session.isAwaitingModel
                ) else { return }
                withAnimation(.easeInOut(duration: 0.2)) { onSelectDraft() }
            }

            ForEach(Self.draftVersionBarItems(
                versions: versions,
                viewingVersionIndex: viewingVersionIndex
            )) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        onSelectDraftVersion(item.version)
                    }
                } label: {
                    Text(item.label)
                        .font(OhiaTypography.cardDetail.monospacedDigit())
                        .foregroundStyle(
                            item.isSelected
                                ? OhiaColors.chipActiveForeground
                                : OhiaColors.textTertiary
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    item.isSelected
                                        ? OhiaColors.chipActiveBackground
                                        : OhiaColors.chipRestBackground
                                )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    item.isSelected
                                        ? OhiaColors.chipActiveBorder
                                        : OhiaColors.chipRestBorder,
                                    lineWidth: 1
                                )
                        }
                }
                .buttonStyle(.plain)
                .fixedSize()
                .frame(height: Self.stageRailItemHeight)
                .accessibilityLabel("Draft version \(item.version.index)")
                .accessibilityAddTraits(item.isSelected ? [.isSelected] : [])
                .help(item.version.instruction ?? "Saved draft version \(item.version.index)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func draftVersionBarItems(
        versions: [ComposerDraftVersion],
        viewingVersionIndex: Int?
    ) -> [ComposerDraftVersionBarItem] {
        let selectedIndex = viewingVersionIndex ?? versions.last?.index
        return versions.map { version in
            ComposerDraftVersionBarItem(
                version: version,
                isSelected: version.index == selectedIndex
            )
        }
    }

    static func decisionVersionBarItems(
        versions: [ComposerDecisionVersion],
        activeVersionID: UUID?
    ) -> [ComposerDecisionVersionBarItem] {
        let selectedID = activeVersionID ?? versions.last?.id
        return versions.map { version in
            ComposerDecisionVersionBarItem(
                version: version,
                isSelected: version.id == selectedID
            )
        }
    }

    private func selectDraftVersion<Host: ComposerDraftEditingHost>(
        _ version: ComposerDraftVersion,
        in session: Host
    ) {
        if version.id == session.versions.last?.id {
            session.showLiveDraft()
        } else {
            session.showVersion(version)
        }
    }

    static func draftStepIsSelectable(
        allowsUnwrittenDraftSelection: Bool,
        hasDraftVersions: Bool,
        isAwaitingModel: Bool
    ) -> Bool {
        allowsUnwrittenDraftSelection || hasDraftVersions || isAwaitingModel
    }

    private func stepChip(
        number: Int,
        title: String,
        detail: String?,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text("\(number)")
                    .font(OhiaTypography.cardDetail.monospacedDigit())
                    .foregroundStyle(isActive ? OhiaColors.chipActiveForeground : OhiaColors.textTertiary)
                    .frame(width: 16, height: 16)
                    .background(
                        Circle()
                            .fill(isActive ? OhiaColors.chipActiveBackground : OhiaColors.chipRestBackground)
                    )
                    .overlay {
                        Circle()
                            .strokeBorder(
                                isActive ? OhiaColors.chipActiveBorder : OhiaColors.chipRestBorder,
                                lineWidth: 1
                            )
                    }
                Text(title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? OhiaColors.textPrimary : OhiaColors.textSecondary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(isActive ? OhiaColors.textPrimary : OhiaColors.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? OhiaColors.chipActiveBackground : OhiaColors.chipRestBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isActive ? OhiaColors.chipActiveBorder : OhiaColors.chipRestBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .frame(height: Self.stageRailItemHeight)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var emptyStage: some View {
        centeredInstruction(
            systemName: "envelope.open",
            title: "Select a queued reply or create a new message"
        )
    }

    private func centeredInstruction(systemName: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OhiaColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Selection + refresh

    private func refreshQueue(
        authoritative: Bool = false,
        invalidatingInFlight: Bool = true,
        afterInstall: (() -> Void)? = nil
    ) {
        // Every background refresh owns a fresh context; both ordinary and
        // mutation-triggered requests therefore observe worker-process saves.
        readCoordinator.requestQueue(
            container: modelContext.container,
            invalidatingInFlight: invalidatingInFlight,
            onInstall: { installQueue($0) },
            afterInstall: afterInstall
        )
    }

    /// Projection and persistence must finish before releasing the active
    /// state. A failure keeps its editable buffer mounted for retry.
    private func flushComposeEditorBeforeLeaving() -> Bool {
        do {
            if let composeState {
                guard composeState.hasPendingChangesToSave else { return true }
                try composeState.flushForTermination().requireValidForLeaving()
            } else if let session {
                guard session.hasPendingChangesToSave else { return true }
                try Self.flushReplyForTermination(
                    session: session,
                    context: activeReplyModelContext,
                    adoptingViewedVersion: false
                ).requireValidForLeaving()
            }
            return true
        } catch {
            sendError = "Could not save the current draft: \(error.localizedDescription)"
            return false
        }
    }

    private func installQueue(_ items: [ComposerQueueItem]) {
        if queueItems != items { queueItems = items }
        queueSelection.reconcile(with: selectableQueueIDs)
        clearExternallyDeletedComposeSelection()
        let replyMessageExists: Bool
        if let messageID = session?.messageID {
            let context = ModelContext(modelContext.container)
            let predicate = #Predicate<Message> { $0.id == messageID }
            replyMessageExists = (try? context.fetchCount(FetchDescriptor<Message>(predicate: predicate))) != 0
        } else {
            replyMessageExists = true
        }
        // Reconcile the open reply session against the rebuilt queue. If its
        // message has silently left the queue — resolved, replied, confirmed, or
        // removed from another surface while this window stayed open — clear it so
        // the pane returns to the empty stage rather than stranding a stale
        // drafting session (an empty queue must show a blank Composer). The
        // in-Composer mutation handlers already clear their own selection, so this
        // only fires for external removals. A deliberate out-of-queue direct-open
        // is exempt.
        if Self.replySelectionIsStale(
            sessionMessageID: session?.messageID,
            directOpenMessageID: directOpenMessageID,
            draftStatus: activeMessage?.draft?.status,
            isExplicitlyExcluded: activeMessage?.composerQueueOverride == .exclude,
            messageExists: replyMessageExists,
            queueItems: queueItems
        ) {
            clearReplySelection()
        }
        if queueItems.isEmpty, session == nil, composeState == nil {
            isStartingNewMessage = true
        }
    }

    /// Compose mutations save through a compose-scoped context. Rebuilding
    /// through a new context prevents the main context's registered pre-send
    /// or pre-discard Draft from resurfacing in the queue.
    static func authoritativeQueueItems(container: ModelContainer) -> [ComposerQueueItem] {
        ComposerQueueModel.build(context: ModelContext(container))
    }

    /// Whether an open reply session no longer corresponds to any queue member
    /// and should be cleared. Pure so it can be unit-tested: a session is stale
    /// once its draft is settled, or when its message is absent from the queue as
    /// a `.reply` row and it is not an unfinished direct-open draft. No session
    /// (or a compose surface, which leaves `session` nil) is never stale.
    static func replySelectionIsStale(
        sessionMessageID: UUID?,
        directOpenMessageID: UUID?,
        draftStatus: DraftStatus?,
        isExplicitlyExcluded: Bool = false,
        messageExists: Bool = true,
        queueItems: [ComposerQueueItem]
    ) -> Bool {
        guard let sessionMessageID else { return false }
        if !messageExists { return true }
        if isExplicitlyExcluded { return true }
        if let draftStatus, draftStatus != .pending { return true }
        if queueItems.contains(where: { $0.id == sessionMessageID && $0.kind == .reply }) {
            return false
        }
        return sessionMessageID != directOpenMessageID || draftStatus != .pending
    }

    /// Whether a reply session may be opened for a message: it is a live queue
    /// member awaiting its first draft, or it carries a pending draft to
    /// continue. Confirmed, sent, rejected, and discarded drafts are settled and
    /// must never reopen as editable sessions, even if the queue snapshot is
    /// stale. Pure so it can be unit-tested, mirroring `replySelectionIsStale`.
    static func replyIsOpenable(
        isQueueMember: Bool,
        draftStatus: DraftStatus?,
        isExplicitlyExcluded: Bool = false
    ) -> Bool {
        if isExplicitlyExcluded { return false }
        if let draftStatus { return draftStatus == .pending }
        return isQueueMember
    }

    /// Shared pre-adoption gate for initial selection and the steady refresh
    /// poll. Adoption can relink or advance a Draft, so durable exclusion must
    /// be checked before invoking it rather than during later queue reconcile.
    static func adoptReadySourcesForOpenReply(
        message: Message,
        context: ModelContext,
        assessment: ReplySourcePreparationAssessment? = nil
    ) throws -> ReplySourcePreparationAdoptionResult? {
        guard !message.isTrashed, message.composerQueueOverride != .exclude else { return nil }
        return try ReplySourcePreparationAdopter.adoptReadySources(
            for: message,
            context: context,
            assessment: assessment
        )
    }

    /// Tears down the active reply session and its selection, returning the pane
    /// to the empty stage.
    private func clearReplySelection() {
        readCoordinator.changeSelection()
        session = nil
        replyModelContext = nil
        activeMessage = nil
        directOpenMessageID = nil
        clearActiveMessageBodyText()
        selectedID = nil
    }

    private func select(_ item: ComposerQueueItem) {
        guard Self.performQueueNavigation(
            flush: flushComposeEditorBeforeLeaving,
            invalidatePendingSelection: { readCoordinator.changeSelection() },
            changeSelection: { queueSelection.selectOnly(item.id) }
        ) else { return }
        openQueueItem(item)
    }

    @discardableResult
    static func performQueueNavigation(
        flush: () -> Bool,
        invalidatePendingSelection: () -> Void,
        changeSelection: () -> Void
    ) -> Bool {
        guard flush() else { return false }
        invalidatePendingSelection()
        changeSelection()
        return true
    }

    private func openQueueItem(_ item: ComposerQueueItem) {
        isStartingNewMessage = false
        switch item.kind {
        case .reply:
            selectMessage(id: item.id)
        case .compose:
            selectComposeDraft(id: item.id)
        }
    }

    private var selectableQueueIDs: [UUID] {
        queueItems.filter { !$0.state.isOutbox }.map(\.id)
    }

    private func handleQueueSelectionClick(
        _ item: ComposerQueueItem,
        modifiers: NSEvent.ModifierFlags
    ) {
        guard Self.performQueueNavigation(
            flush: flushComposeEditorBeforeLeaving,
            invalidatePendingSelection: { readCoordinator.changeSelection() },
            changeSelection: {
                queueSelection.handleClick(
                    id: item.id, modifiers: modifiers, orderedIDs: selectableQueueIDs
                )
            }
        ) else { return }
        guard let activeID = queueSelection.activeID,
              let activeItem = queueItems.first(where: { $0.id == activeID }) else {
            if selectedID == item.id {
                composeState = nil
                composeModelContext = nil
                clearReplySelection()
            }
            return
        }
        if selectedID != activeID {
            openQueueItem(activeItem)
        }
    }

    private func selectAllQueueDrafts() {
        guard Self.performQueueNavigation(
            flush: flushComposeEditorBeforeLeaving,
            invalidatePendingSelection: { readCoordinator.changeSelection() },
            changeSelection: { queueSelection.selectAll(in: selectableQueueIDs) }
        ) else { return }
        if let activeID = queueSelection.activeID, activeID != selectedID,
           let item = queueItems.first(where: { $0.id == activeID }) {
            openQueueItem(item)
        }
    }

    /// Opening selection for the Composer: honor the latched focus message when
    /// it is still openable, otherwise default to the queue's first reply. A
    /// latched pointer that has gone stale (its draft deleted, resurfacing from
    /// `UserDefaults` on a relaunch) fails `selectMessage`'s eligibility guard
    /// and falls through here — so a dismissed message can't strand the pane on
    /// a resurrected draft when the queue is empty, nor mask a live queue member
    /// when it isn't.
    ///
    /// The openability guard in `selectMessage` rejects a stale latched message
    /// before any cache-miss draft can be seeded. A real queue member is allowed
    /// to start fallback compilation when no precompiled snapshot exists.
    private func selectInitialOrFirstReply() {
        if let initial = initialMessageID {
            selectMessage(id: initial, fallBackToFirstReply: true)
            return
        }
        if let first = queueItems.first(where: { $0.kind == .reply }) {
            select(first)
        }
    }

    /// Loads a compose draft into the in-Composer compose surface, replacing
    /// any active reply session.
    private func selectComposeDraft(id: UUID) {
        guard flushComposeEditorBeforeLeaving() else { return }
        readCoordinator.changeSelection()
        isStartingNewMessage = false
        session = nil
        replyModelContext = nil
        activeMessage = nil
        directOpenMessageID = nil
        clearActiveMessageBodyText()
        guard let refreshed = Self.refreshedComposeState(
            draftID: id,
            container: modelContext.container
        ) else { return }
        refreshed.state.loadRecipientSuggestions()
        composeModelContext = refreshed.context
        composeState = refreshed.state
        selectedID = id
    }

    /// Returns the Composer to its unpersisted new-message surface. The queue
    /// is untouched until the user commits a recipient or subject.
    private func beginNewMessage() {
        guard flushComposeEditorBeforeLeaving() else { return }
        readCoordinator.changeSelection()
        session = nil
        replyModelContext = nil
        composeState = nil
        composeModelContext = nil
        activeMessage = nil
        directOpenMessageID = nil
        clearActiveMessageBodyText()
        selectedID = nil
        queueSelection.clear()
        provisionalComposeState.reset(context: modelContext)
        isStartingNewMessage = true
    }

    /// Materializes the provisional header exactly when its first valid
    /// recipient or subject is committed, then selects the resulting queue row.
    private func promoteProvisionalMessage(_ request: ComposerProvisionalComposeRequest) {
        guard isStartingNewMessage, composeState == nil, session == nil else { return }

        let context = ModelContext(modelContext.container)
        let draft = ComposeState.createBlankDraft(
            context: context,
            draftID: provisionalComposeState.id,
            seed: ComposeDraftCreationSeed(
                subject: request.subject,
                to: request.to,
                cc: request.cc,
                bcc: request.bcc,
                identityID: request.identityID,
                signatureSlotID: request.signatureSlotID
            )
        )
        let state = ComposeState(draftID: draft.id, context: context)
        state.loadRecipientSuggestions()

        composeModelContext = context
        composeState = state
        selectedID = draft.id
        isStartingNewMessage = false
        refreshQueue(authoritative: true)
        queueSelection.selectOnly(draft.id)
    }

    /// Replaces the whole compose state while the worker owns the draft.
    /// Cross-process SwiftData writes do not invalidate an already registered
    /// model reliably; a new context is the store-authoritative poll boundary.
    private func reloadComposeStateFromStore() {
        guard !clearExternallyDeletedComposeSelection() else { return }
        guard let state = composeState, let id = state.draft?.id else { return }
        guard flushComposeEditorBeforeLeaving() else { return }
        guard Self.composeStatePollRequiresReplacement(state) else {
            state.reloadFromStore()
            return
        }
        guard let refreshed = Self.refreshedComposeState(
            draftID: id,
            container: modelContext.container,
            userSelectedStep: state.userSelectedStep
        ) else { return }
        refreshed.state.reuseRecipientSuggestions(from: state)
        composeModelContext = refreshed.context
        composeState = refreshed.state
        activateAutomaticMessagesContext()
    }

    @discardableResult
    private func clearExternallyDeletedComposeSelection() -> Bool {
        guard let state = composeState, state.invalidateIfRemovedFromStore() else { return false }
        readCoordinator.changeSelection()
        composeState = nil
        composeModelContext = nil
        selectedID = nil
        sendError = nil
        activateAutomaticMessagesContext()
        return true
    }

    private func activateAutomaticMessagesContext() {
        if let session {
            let draftID = session.backingDraft(in: activeReplyModelContext)?.id
            automaticMessagesAccessCoordinator?.activateReply(
                messageID: session.messageID,
                draftID: draftID
            )
        } else if let draftID = composeState?.draft?.id,
                  let correspondentAddress = composeState?.correspondentAddress(
                    in: activeChildModelContext
                  ) {
            automaticMessagesAccessCoordinator?.activateCompose(
                draftID: draftID,
                correspondentAddress: correspondentAddress
            )
        } else {
            automaticMessagesAccessCoordinator?.deactivate()
        }
    }

    /// Initial source research owns an app-side detached preview compile.
    /// Poll that one phase through its existing state so a compile longer
    /// than the poll interval is not cancelled and restarted forever. Its
    /// `reloadFromStore` performs the required fresh-context reconciliation.
    static func composeStatePollRequiresReplacement(_ state: ComposeState) -> Bool {
        state.isAwaitingModel && !state.isDeterminingInitialSources
    }

    static func refreshedComposeState(
        draftID: UUID,
        container: ModelContainer,
        userSelectedStep: ComposerStep? = nil
    ) -> (state: ComposeState, context: ModelContext)? {
        let context = ModelContext(container)
        let state = ComposeState(draftID: draftID, context: context)
        guard state.draft != nil else { return nil }
        if let userSelectedStep {
            state.selectStep(userSelectedStep)
        } else if state.needsInitialSourcePreparation {
            state.step = .decisions
        }
        return (state, context)
    }

    static func initialSourceRequirementText(
        hasRecipient: Bool,
        subject: String?
    ) -> String? {
        let hasSubject = subject?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        switch (hasRecipient, hasSubject) {
        case (false, false):
            return "A recipient and subject are required."
        case (false, true):
            return "A recipient is required."
        case (true, false):
            return "A subject is required."
        case (true, true):
            return nil
        }
    }

    /// A compose finished (sent or discarded): clear the surface and advance
    /// to the next queue item.
    private func handleComposeFinished() {
        readCoordinator.changeSelection()
        composeState = nil
        composeModelContext = nil
        selectedID = nil
        refreshQueue(authoritative: true, afterInstall: {
            if let next = queueItems.first {
                select(next)
            } else {
                provisionalComposeState.reset(context: modelContext)
                isStartingNewMessage = true
            }
        })
    }

    private func handleComposeSend(_ state: ComposeState) {
        // See enqueueSendAndAdvance for why this guard exists: the takeover
        // overlay blocks mouse interaction but not the ⌘Return shortcut.
        guard sendTakeoverCoordinator.active == nil else { return }
        guard state.step == .draft else { return }
        if let ownerID = state.draft?.id, !permitSend(for: ownerID) { return }
        state.commitAddressBuffers()
        guard state.canSendDraft else {
            sendError = state.isImportingAttachments
                ? "Wait for attachments to finish importing before sending."
                : (state.draft?.hasPendingStyleControlDecision == true
                    ? "Regenerate to apply the pending style adjustments before sending."
                    : "Add a valid To recipient and draft body before sending.")
            return
        }
        do {
            let outboxItemID = try state.send()
            sendError = nil
            if let outboxItemID {
                // state.fromAccount, not an `identities` lookup: `identities`
                // is only ever populated by the reply surface (selectMessage),
                // never by compose-from-scratch, so a lookup against it here
                // would silently miss on the app's most common send path.
                // ComposeState keeps fromAccount in lockstep with the chosen
                // identity (setIdentity), and send() itself already requires
                // it non-nil to have produced outboxItemID at all.
                beginSendTakeover(outboxItemID: outboxItemID, accountColorIndex: state.fromAccount?.colorIndex)
            }
            handleComposeFinished()
        } catch {
            sendError = "Could not queue send: \(error.localizedDescription)"
        }
    }

    private func requestActiveComposeDiscard(_ state: ComposeState) {
        guard let id = state.draft?.id,
              let item = queueItems.first(where: { $0.id == id && $0.kind == .compose }) else {
            return
        }
        pendingQueueDelete = item
    }

    private func performActiveComposeDiscard(_ state: ComposeState) {
        let discarded = state.isEmpty
            ? state.discardHard()
            : state.discardSoft()
        guard discarded else {
            sendError = "Could not discard this draft. Please try again."
            return
        }
        sendError = nil
        handleComposeFinished()
    }

    private func presentAttachPanel(for state: ComposeState) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            importAttachments(
                at: panel.urls,
                for: state,
                securityScopedURLsToRelease: panel.urls
            )
        }
    }

    private func importDroppedAttachments(_ sourceURLs: [URL], for state: ComposeState) {
        let securityScopedURLs = sourceURLs.filter {
            $0.startAccessingSecurityScopedResource()
        }
        let regularFiles = Self.regularDroppedFiles(from: sourceURLs)
        let regularFileSet = Set(regularFiles)
        let rejectedScopedURLs = securityScopedURLs.filter { !regularFileSet.contains($0) }
        rejectedScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        let acceptedScopedURLs = securityScopedURLs.filter { regularFileSet.contains($0) }
        let rejectedDirectories = regularFiles.count != sourceURLs.count
        guard !regularFiles.isEmpty else {
            sendError = "Folders cannot be attached. Drop individual files instead."
            return
        }
        importAttachments(
            at: regularFiles,
            for: state,
            securityScopedURLsToRelease: acceptedScopedURLs,
            successNotice: rejectedDirectories
                ? "Folders were not attached. The individual files were added."
                : nil
        )
    }

    private func importAttachments(
        at sourceURLs: [URL],
        for state: ComposeState,
        securityScopedURLsToRelease: [URL],
        successNotice: String? = nil
    ) {
        guard let attachmentImport = state.beginAttachmentImport() else {
            securityScopedURLsToRelease.forEach { $0.stopAccessingSecurityScopedResource() }
            sendError = "Could not add attachments because this draft is no longer available."
            return
        }
        attachmentImportRegistry.register(attachmentImport)
        Task {
            let store = ComposerAttachmentStore()
            var copiedPaths: [String] = []
            defer {
                securityScopedURLsToRelease.forEach { $0.stopAccessingSecurityScopedResource() }
                state.finishAttachmentImport(attachmentImport)
                attachmentImportRegistry.unregister(attachmentImport)
            }
            do {
                copiedPaths = try await store.importFiles(
                    at: sourceURLs,
                    ownerID: attachmentImport.ownerID
                )
                guard !Task.isCancelled,
                      state.acceptImportedAttachmentPaths(
                          copiedPaths,
                          for: attachmentImport
                      ) else {
                    copiedPaths.forEach {
                        store.deleteAttachment(
                            atOwnedPath: $0,
                            ownerID: attachmentImport.ownerID
                        )
                    }
                    if !Task.isCancelled {
                        sendError = "Could not add attachments because this draft is no longer available."
                    }
                    return
                }
                sendError = successNotice
            } catch {
                copiedPaths.forEach {
                    store.deleteAttachment(
                        atOwnedPath: $0,
                        ownerID: attachmentImport.ownerID
                    )
                }
                if !(error is CancellationError) {
                    sendError = error.localizedDescription
                }
            }
        }
    }

    private func beginInlinePhotoImport(
        for state: ComposeState
    ) -> ComposerAttachmentImport? {
        guard composeState === state,
              composeState?.inlinePhotoOwnerID == state.inlinePhotoOwnerID,
              let draftAssetImport = state.beginAttachmentImport()
        else { return nil }
        attachmentImportRegistry.register(draftAssetImport)
        return draftAssetImport
    }

    private func validateInlinePhotoImport(
        _ draftAssetImport: ComposerAttachmentImport,
        for state: ComposeState
    ) -> Bool {
        guard composeState === state,
              composeState?.inlinePhotoOwnerID == draftAssetImport.ownerID
        else { return false }
        return state.isDraftAssetImportValid(draftAssetImport)
    }

    private func finishInlinePhotoImport(
        _ draftAssetImport: ComposerAttachmentImport,
        for state: ComposeState
    ) {
        state.finishAttachmentImport(draftAssetImport)
        attachmentImportRegistry.unregister(draftAssetImport)
    }

    private func presentAttachPanel(for session: ComposerSession) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            importAttachments(
                at: panel.urls,
                for: session,
                securityScopedURLsToRelease: panel.urls
            )
        }
    }

    private func importDroppedAttachments(
        _ sourceURLs: [URL],
        for session: ComposerSession
    ) {
        let securityScopedURLs = sourceURLs.filter {
            $0.startAccessingSecurityScopedResource()
        }
        let regularFiles = Self.regularDroppedFiles(from: sourceURLs)
        let regularFileSet = Set(regularFiles)
        let rejectedScopedURLs = securityScopedURLs.filter { !regularFileSet.contains($0) }
        rejectedScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        let acceptedScopedURLs = securityScopedURLs.filter { regularFileSet.contains($0) }
        let rejectedDirectories = regularFiles.count != sourceURLs.count
        guard !regularFiles.isEmpty else {
            sendError = "Folders cannot be attached. Drop individual files instead."
            return
        }
        importAttachments(
            at: regularFiles,
            for: session,
            securityScopedURLsToRelease: acceptedScopedURLs,
            successNotice: rejectedDirectories
                ? "Folders were not attached. The individual files were added."
                : nil
        )
    }

    private func importAttachments(
        at sourceURLs: [URL],
        for session: ComposerSession,
        securityScopedURLsToRelease: [URL],
        successNotice: String? = nil
    ) {
        let context = activeReplyModelContext
        guard let attachmentImport = session.beginAttachmentImport(context: context) else {
            securityScopedURLsToRelease.forEach { $0.stopAccessingSecurityScopedResource() }
            sendError = "Could not add attachments because this reply draft is no longer available."
            return
        }
        attachmentImportRegistry.register(attachmentImport)
        Task {
            let store = ComposerAttachmentStore()
            var copiedPaths: [String] = []
            defer {
                securityScopedURLsToRelease.forEach { $0.stopAccessingSecurityScopedResource() }
                session.finishAttachmentImport(attachmentImport)
                attachmentImportRegistry.unregister(attachmentImport)
            }
            do {
                copiedPaths = try await store.importFiles(
                    at: sourceURLs,
                    ownerID: attachmentImport.ownerID
                )
                guard !Task.isCancelled,
                      session.acceptImportedAttachmentPaths(
                          copiedPaths,
                          for: attachmentImport,
                          context: context
                      ) else {
                    for path in copiedPaths {
                        store.deleteAttachment(
                            atOwnedPath: path,
                            ownerID: attachmentImport.ownerID
                        )
                    }
                    if !Task.isCancelled {
                        sendError = "Could not add the selected files to this reply draft."
                    }
                    return
                }
                sendError = successNotice
            } catch {
                copiedPaths.forEach {
                    store.deleteAttachment(
                        atOwnedPath: $0,
                        ownerID: attachmentImport.ownerID
                    )
                }
                if !(error is CancellationError) {
                    sendError = error.localizedDescription
                }
            }
        }
    }

    nonisolated static func regularDroppedFiles(from urls: [URL]) -> [URL] {
        urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
    }

    private func beginInlinePhotoImport(
        for activeSession: ComposerSession
    ) -> ComposerAttachmentImport? {
        guard session === activeSession,
              session?.inlinePhotoOwnerID == activeSession.inlinePhotoOwnerID,
              let draftAssetImport = activeSession.beginAttachmentImport(
                  context: activeReplyModelContext
              )
        else { return nil }
        attachmentImportRegistry.register(draftAssetImport)
        return draftAssetImport
    }

    private func validateInlinePhotoImport(
        _ draftAssetImport: ComposerAttachmentImport,
        for activeSession: ComposerSession
    ) -> Bool {
        guard session === activeSession,
              session?.inlinePhotoOwnerID == draftAssetImport.ownerID
        else { return false }
        return activeSession.isDraftAssetImportValid(
            draftAssetImport,
            context: activeReplyModelContext
        )
    }

    private func finishInlinePhotoImport(
        _ draftAssetImport: ComposerAttachmentImport,
        for activeSession: ComposerSession
    ) {
        activeSession.finishAttachmentImport(draftAssetImport)
        attachmentImportRegistry.unregister(draftAssetImport)
    }

    /// Opens a reply session for `id`, returning whether it did. A message is
    /// openable only when it is a live queue member or still carries a real
    /// draft to continue. A stale out-of-queue pointer — e.g. the last-focused
    /// message latched in `UserDefaults`, whose reply draft was since deleted,
    /// resurfacing on the next launch — is neither, so this bails rather than
    /// letting `ensureSourceDraft` resurrect a fresh draft for a message the
    /// user already dismissed. A genuine direct-open for an unfinished pending
    /// draft still passes; a settled draft does not reopen as editable.
    ///
    /// Every openable entry may atomically adopt a valid prepared snapshot; that
    /// transition starts at `evaluatingSources`. If preparation is unavailable,
    /// a real queue member starts foreground fallback compilation. The preceding
    /// openability guard prevents stale out-of-queue focus pointers from ever
    /// reaching that fallback.
    private func selectMessage(id requestedID: UUID, fallBackToFirstReply: Bool = false) {
        guard flushComposeEditorBeforeLeaving() else { return }
        // A conversation is one queue item: an email its reply covers (or a
        // row a refresh has not yet replaced after the reply moved) opens
        // that item, never a second Draft of its own.
        let id = ComposerQueueMembership.queueItemMessageID(
            for: requestedID,
            context: ModelContext(modelContext.container)
        )
        readCoordinator.requestReply(
            messageID: id,
            container: modelContext.container,
            isOpening: true,
            onResult: { assessment in
                guard flushComposeEditorBeforeLeaving() else { return }
                do {
                    if let assessment, try installSelectedReply(assessment) { return }
                    if fallBackToFirstReply,
                       let first = queueItems.first(where: { $0.kind == .reply && $0.id != id }) {
                        select(first)
                    }
                } catch ReplySourcePreparationAssessmentError.staleInput {
                    selectMessage(id: id, fallBackToFirstReply: fallBackToFirstReply)
                } catch {
                    sendError = "Could not open prepared sources: \(error.localizedDescription)"
                }
            },
            onError: { error in
                sendError = "Could not open prepared sources: \(error.localizedDescription)"
            }
        )
    }

    private func installSelectedReply(_ assessment: ReplySourcePreparationAssessment) throws -> Bool {
        let id = assessment.messageID
        let context = ModelContext(modelContext.container)
        guard let message = Self.fetchMessage(id, context: context) else { return false }
        guard let adoptionResult = try Self.adoptReadySourcesForOpenReply(
            message: message, context: context, assessment: assessment
        ) else { return false }
        let isQueueMember = queueItems.contains { $0.id == id && $0.kind == .reply }
        let storedDraft = message.draft
            ?? ComposerQueueMembership.storedDraft(for: id, context: context)
        guard Self.replyIsOpenable(
            isQueueMember: isQueueMember,
            draftStatus: storedDraft?.status,
            isExplicitlyExcluded: message.composerQueueOverride == .exclude
        ) else {
            return false
        }
        isStartingNewMessage = false
        composeState = nil
        composeModelContext = nil
        replyModelContext = context
        markReadOnOpenIfNeeded(message)
        activeMessage = message
        ensureBodyTextLoaded(for: message)
        selectedID = id
        // Remember an out-of-queue direct-open (message not currently a queue
        // member) so the reconcile poll leaves it be; an in-queue selection
        // clears the flag so it can be reconciled normally once it drops out.
        directOpenMessageID = isQueueMember ? nil : id
        identities = message.account?.identities ?? []
        if Self.shouldSeedSourceDraft(
            adoptionResult: adoptionResult
        ) {
            // Seed the source-compilation draft on demand so the Sources pane
            // is live the instant the message opens. Once compilation finishes,
            // the worker advances an explicitly queued message directly into
            // question evaluation without a separate source-confirmation gate.
            ensureSourceDraft(for: message, context: context)
        } else {
            // Preemptive preparation still owns the work. Surface only an
            // existing cross-process row until the Composer poll adopts it.
            linkExistingSourceDraft(for: message, context: context)
        }
        let newSession = ComposerSession(message: message)
        refreshStylePanel(newSession, message: message)
        refreshQuotedPreview(newSession, message: message)
        session = newSession
        return true
    }

    /// Foreground compilation is a cache-miss fallback only. A valid
    /// ingestion-time preparation that is still pending/running owns the
    /// source work; the Composer poll will adopt it as soon as it becomes
    /// ready without creating a competing Draft or generate-draft job.
    static func shouldSeedSourceDraft(
        adoptionResult: ReplySourcePreparationAdoptionResult
    ) -> Bool {
        adoptionResult != .preparationInProgress
    }

    /// Links an existing source-curation draft the `Message` object hasn't
    /// observed yet (the generative worker can create the row in its own
    /// process), without ever creating one. The open-only counterpart to
    /// `ensureSourceDraft`.
    private func linkExistingSourceDraft(
        for message: Message,
        context: ModelContext
    ) {
        guard message.draft == nil,
              let existing = ComposerQueueMembership.storedDraft(
                  for: message.id,
                  context: context
              ) else {
            return
        }
        message.draft = existing
    }

    /// Ensures the message carries its source-compilation draft (`collectingSources`),
    /// creating a truthful worker-owned shell when no prepared snapshot or
    /// existing Draft is available. The authoritative reply-source compiler
    /// fills the shell asynchronously, then explicit queue intake advances to
    /// question evaluation. This foreground seam never persists a reduced local
    /// evidence set. Existing rows remain untouched so user-added sources are
    /// never clobbered.
    @discardableResult
    private func ensureSourceDraft(
        for message: Message,
        context: ModelContext
    ) -> Draft? {
        if let existing = message.draft ?? ComposerQueueMembership.storedDraft(
            for: message.id,
            context: context
        ) {
            if message.draft == nil { message.draft = existing }
            return existing
        }
        // The conversation's reply Draft lives on another email and moves to
        // its reply target; a second Draft here would split the conversation.
        guard ReplySourcePreparationEligibility.otherEmailHoldingUnsentReplyDraft(
            for: message,
            context: context
        ) == nil else {
            return nil
        }
        let draft = Draft(
            message: message,
            replyText: "",
            confidence: 0,
            sourceThreadCount: 0,
            sourceExemplarCount: 0,
            styleMatch: 0
        )
        draft.stageRaw = DraftStage.collectingSources
        draft.sourcesJSON = nil
        // Local source triage is required even when optional MCP web research
        // is disabled. The same worker pass conditionally adds external
        // research only when providers are configured.
        draft.beginAutomaticSourceResearchIfNeeded()
        draft.fromIdentityID = IdentityResolver.resolveReplyIdentity(message: message)?.id
        context.insert(draft)
        message.draft = draft
        do {
            try ComposerQueueMembership.stageTargetedDraftJob(
                messageID: message.id,
                context: context
            )
            try context.save()
        } catch {
            sendError = "Could not prepare automatic sources: \(error.localizedDescription)"
        }
        return draft
    }

    /// Decisions step "Continue" / "Re-check sources": submit the curated
    /// sources for a fresh conditional interview. Re-check evidence and routing
    /// while retaining the user's explicitly accepted instructions.
    private func handleContinue(_ session: ComposerSession) {
        let context = activeReplyModelContext
        do {
            _ = try Self.flushReplyForTermination(session: session, context: context, adoptingViewedVersion: false)
        } catch {
            sendError = error.localizedDescription
            return
        }
        guard let message = fetchMessage(session.messageID) else { return }
        guard let draft = ensureSourceDraft(for: message, context: context) else {
            sendError = "This conversation's reply draft moved to its newest email. Open it from the queue."
            return
        }
        // Source research that failed and was parked: retry it as it stood.
        if draft.isAutomaticSourceResearchPending, session.isGenerationBlocked {
            handleRegenerate(session)
            return
        }
        guard !draft.isAutomaticSourceResearchPending else { return }
        ComposerDecisionHistoryPersistence.updateActiveQuestionsAndAnswers(on: draft)
        let draftingInstruction = session.draftingInstructionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        draft.draftingInstruction = draftingInstruction.isEmpty ? nil : draftingInstruction
        ComposerSourceMutationPersistence.prepareForRecheck(draft: draft)
        draft.sourcesCuratedAt = draft.sourcesCuratedAt ?? Date()
        draft.stageRaw = DraftStage.evaluatingSources
        // An explicit user request overrides any failure backoff window.
        draft.clearGenerationBackoff()
        do {
            try JobQueue().enqueue(
                type: .generateDraft,
                priority: ComposerDraftScheduling.userInitiatedPriority,
                messageId: message.id,
                context: context
            )
            try context.save()
        } catch {
            sendError = "Could not queue source evaluation: \(error.localizedDescription)"
            return
        }
        session.resetInterviewState()
        session.reload(from: message)
        activeMessage = message
        refreshQueue()
    }

    private func restoreDecisionVersion(
        _ version: ComposerDecisionVersion,
        in session: ComposerSession
    ) {
        let context = activeReplyModelContext
        do {
            _ = try Self.flushReplyForTermination(session: session, context: context, adoptingViewedVersion: false)
        } catch {
            sendError = error.localizedDescription
            return
        }
        guard !session.isAwaitingModel,
              let message = fetchMessage(session.messageID),
              let draft = message.draft ?? ComposerQueueMembership.storedDraft(
                  for: message.id,
                  context: context
              ) else {
            return
        }
        if session.activeDecisionVersionID == version.id,
           !session.hasPendingDecisionInputChanges {
            session.isUserRevisitingDecisions = true
            session.step = .decisions
            return
        }
        ComposerDecisionHistoryPersistence.updateActiveQuestionsAndAnswers(on: draft)
        ComposerDecisionHistoryPersistence.restore(version, on: draft)
        do {
            try ComposerSourceContextMeasurementScheduler.stageMeasurement(
                draft: draft,
                context: context
            )
            try context.save()
        } catch {
            context.rollback()
            sendError = "Could not restore Decisions v\(version.index): \(error.localizedDescription)"
            return
        }
        session.resetInterviewState()
        session.isUserRevisitingDecisions = true
        session.step = .decisions
        session.reload(from: message)
        activeMessage = message
        refreshQueue()
    }

    /// Commits the current graph node. Closed options and skips advance
    /// locally; a nonempty free-text commit schedules one repair pass.
    private func handleCommitAnswer(
        _ session: ComposerSession,
        node: ComposerInterviewNode,
        selectedOptionID: String?,
        freeText: String?,
        skipped: Bool
    ) {
        let context = activeReplyModelContext
        guard let message = fetchMessage(session.messageID),
              let draft = message.draft ?? ComposerQueueMembership.storedDraft(
                  for: message.id,
                  context: context
              ) else {
            sendError = "The draft for this message is missing — reselect it and try again."
            return
        }
        guard draft.resolvedStage == DraftStage.collectingAnswers
                || draft.resolvedStage == DraftStage.drafted else {
            session.reload(from: message)
            return
        }
        guard let state = ComposerInterviewStateCoding.decode(draft.interviewStateJSON),
              let updated = try? ComposerInterviewExecutor.commit(
                  nodeID: node.id,
                  selectedOptionID: selectedOptionID,
                  freeText: freeText,
                  skipped: skipped,
                  in: state
              ) else {
            return
        }
        draft.interviewStateJSON = ComposerInterviewStateCoding.encode(updated)
        draft.decisionResearchOverlayJSON = nil
        ComposerSourceContextMeasurementScheduler.requestAfterDecisionChange(draft: draft, context: context)
        ComposerDecisionHistoryPersistence.updateActiveQuestionsAndAnswers(on: draft)
        let needsRepair = ComposerInterviewExecutor.project(updated).pendingRepairAnswer != nil
        draft.stageRaw = needsRepair
            ? DraftStage.evaluatingSources
            : DraftStage.collectingAnswers
        if needsRepair { draft.clearGenerationBackoff() }
        do {
            if needsRepair {
                try JobQueue().enqueue(
                    type: .generateDraft,
                    priority: ComposerDraftScheduling.userInitiatedPriority,
                    messageId: message.id,
                    context: context
                )
            }
            try context.save()
        } catch {
            sendError = "Could not save the decision: \(error.localizedDescription)"
            return
        }
        session.reload(from: message)
        refreshQueue()
    }

    /// Reopen a path entry and deterministically prune its downstream state.
    private func handleChangeAnswer(_ session: ComposerSession, nodeID: String) {
        let context = activeReplyModelContext
        guard let message = fetchMessage(session.messageID),
              let draft = message.draft ?? ComposerQueueMembership.storedDraft(
                  for: message.id,
                  context: context
              ) else {
            sendError = "The draft for this message is missing — reselect it and try again."
            return
        }
        guard draft.resolvedStage == DraftStage.collectingAnswers
                || draft.resolvedStage == DraftStage.drafted else {
            session.reload(from: message)
            return
        }
        guard let state = ComposerInterviewStateCoding.decode(draft.interviewStateJSON),
              let reopened = try? ComposerInterviewExecutor.reopen(
                  nodeID: nodeID,
                  in: state,
                  researchOverlay: ComposerDecisionResearchOverlayCoding.decode(
                      draft.decisionResearchOverlayJSON
                  )
              ) else { return }
        draft.interviewStateJSON = ComposerInterviewStateCoding.encode(reopened.state)
        draft.decisionResearchOverlayJSON = ComposerDecisionResearchOverlayCoding.encode(
            reopened.researchOverlay
        )
        ComposerDecisionHistoryPersistence.refreshActiveVersionFromDraft(on: draft)
        ComposerSourceContextMeasurementScheduler.requestAfterDecisionChange(draft: draft, context: context)
        // Reopening a decision returns the draft to answering — including
        // from a drafted state, where the interview resumes and the user
        // regenerates with the updated decisions afterwards.
        draft.stageRaw = DraftStage.collectingAnswers
        do {
            try context.save()
        } catch {
            sendError = "Could not reopen the decision: \(error.localizedDescription)"
            return
        }
        session.reload(from: message)
        refreshQueue()
    }

    /// "No Reply Needed": set the explicit exclude override, clear the reply
    /// obligation, and discard any pending provider draft — the same write path
    /// as deleting a reply from the queue.
    private func dismissNoReply(_ item: ComposerQueueItem) {
        guard item.kind == .reply, let message = fetchMessage(item.id) else { return }
        let context = message.modelContext ?? modelContext
        do {
            try ComposerQueueMembership.setNeedsReply(false, message: message, context: context)
        } catch {
            sendError = "Could not dismiss: \(error.localizedDescription)"
            return
        }
        if selectedID == item.id {
            clearReplySelection()
        }
        refreshQueue()
    }

    // MARK: - Queue management actions

    private func handleQueueAction(_ action: ComposerQueueAction, item: ComposerQueueItem) {
        switch action {
        case .open:
            select(item)
        case .sendNow:
            sendNow(item)
        case .delete:
            requestQueueDelete(item)
        case .retrySend:
            retryOutboxItem(item)
        }
    }

    /// Delete from a row button or context menu. When the invoked row belongs
    /// to a multi-selection, preserve that selection and route the whole batch
    /// through the existing confirmation. An unselected row remains a
    /// single-row action, matching native list behavior.
    private func requestQueueDelete(_ item: ComposerQueueItem) {
        guard Self.requiresQueueDeleteConfirmation(for: item) else {
            cancelOutboxItem(item)
            return
        }

        if queueSelection.selectedIDs.contains(item.id) {
            let selectedItems = queueSelection.selectedItems(from: queueItems)
            if selectedItems.count > 1 {
                pendingBulkDelete = selectedItems
                return
            }
        }

        pendingQueueDelete = item
    }

    /// Keyboard delete for the currently selected queue draft (⌫ / ⌘⌫).
    /// Every queued draft routes through the same confirmation as row Delete.
    /// Returns whether an item was found so the key is consumed only when it
    /// acted.
    @discardableResult
    private func deleteSelectedQueueItem() -> Bool {
        let selectedItems = queueSelection.selectedItems(from: queueItems)
        if selectedItems.count > 1 {
            pendingBulkDelete = selectedItems
            return true
        }
        guard let item = selectedItems.first
            ?? selectedID.flatMap({ id in queueItems.first(where: { $0.id == id }) }) else {
            return false
        }
        handleQueueAction(.delete, item: item)
        return true
    }

    private func performConfirmedQueueDiscard(_ item: ComposerQueueItem) {
        guard pendingConfirmedDiscardIDs.insert(item.id).inserted else { return }
        let container = modelContext.container
        let worker = readCoordinator.worker
        Task { @MainActor in
            defer { pendingConfirmedDiscardIDs.remove(item.id) }
            do {
                let liveItems = try await worker.run {
                    try ComposerQueueModel.load(context: ModelContext(container))
                }
                applyConfirmedQueueDiscard(item, liveItems: liveItems)
            } catch {
                sendError = "Could not verify the queued draft: \(error.localizedDescription)"
            }
        }
    }

    private func applyConfirmedQueueDiscard(_ item: ComposerQueueItem, liveItems: [ComposerQueueItem]) {
        guard Self.canConfirmQueueDeletion(item, liveItems: liveItems) else {
            if selectedID == item.id, item.kind == .compose {
                composeState = nil
                composeModelContext = nil
                selectedID = nil
            }
            refreshQueue(authoritative: true)
            sendError = "This draft is no longer queued and was not discarded."
            return
        }
        switch item.kind {
        case .reply:
            dismissNoReply(item)
        case .compose:
            performComposeDiscard(item)
        }
    }

    private func performBulkDiscard(_ items: [ComposerQueueItem]) {
        var failures = 0
        for item in items {
            switch item.kind {
            case .reply:
                guard let message = fetchMessage(item.id) else {
                    failures += 1
                    continue
                }
                do {
                    let context = message.modelContext ?? modelContext
                    try ComposerQueueMembership.setNeedsReply(
                        false,
                        message: message,
                        context: context
                    )
                } catch {
                    failures += 1
                }
                if selectedID == item.id {
                    clearReplySelection()
                }
            case .compose:
                if let state = composeState, state.draft?.id == item.id {
                    let discarded = state.isEmpty
                        ? state.discardHard()
                        : state.discardSoft()
                    if !discarded {
                        failures += 1
                    } else {
                        composeState = nil
                        composeModelContext = nil
                        selectedID = nil
                    }
                    continue
                }
                guard let draft = fetchDraft(item.id),
                      ComposeState.discardDraft(
                        draft,
                        hardDeleteLocalDraft: draft.isEmptyCompose,
                        context: modelContext
                      ) else {
                    failures += 1
                    continue
                }
                if selectedID == item.id {
                    composeState = nil
                    selectedID = nil
                }
            }
        }
        refreshQueue(authoritative: true)
        sendError = failures == 0
            ? nil
            : "Could not discard \(failures) selected \(failures == 1 ? "draft" : "drafts"). Please try again."
    }

    /// Send a ready draft immediately. For replies `item.id` is the message
    /// id; for composes it's the draft id.
    private func sendNow(_ item: ComposerQueueItem) {
        switch item.kind {
        case .reply:
            guard replySendNowInFlightIDs.insert(item.id).inserted else { return }
            Task { @MainActor in
                defer { replySendNowInFlightIDs.remove(item.id) }
                await sendReplyNow(messageID: item.id)
            }
            return
        case .compose:
            guard let draft = fetchDraft(item.id),
                  let accountID = draft.composeFromAccountID,
                  let account = fetchAccount(accountID) else {
                sendError = "No account configured for this draft."
                return
            }
            guard permitSend(for: draft.id) else { return }
            guard let identity = account.resolveIdentity(for: draft.fromIdentityID) else {
                sendError = "No send identity configured for \(account.emailAddress). Add an identity in Settings."
                return
            }
            do {
                try dispatcher().enqueueCompose(draft: draft, account: account, identity: identity)
            } catch {
                sendError = "Could not send: \(error.localizedDescription)"
                return
            }
            if selectedID == item.id {
                composeState = nil
                selectedID = nil
            }
        }
        refreshQueue()
    }

    /// Queue-row Send Now honors the same default/explicit quote choice as the
    /// open Composer. An unopened reply has no prepared snapshot yet, so this
    /// prepares and persists the default included quote before dispatch.
    private func sendReplyNow(messageID: UUID) async {
        guard let message = fetchMessage(messageID),
              let draft = message.draft,
              message.account != nil else {
            sendError = "No draft or account for this message."
            return
        }
        guard permitSend(for: draft.id) else { return }

        if draft.resolvedIncludesQuotedOriginal, !draft.hasPreparedQuotedOriginal {
            let prepared = await Self.prepareReplyQuote(
                htmlPath: message.bodyHtmlPath,
                textPath: message.bodyTextPath,
                rawPath: message.rawPath,
                fromName: message.fromName,
                fromAddress: message.fromAddress,
                receivedAt: message.receivedAt,
                ingestedAt: message.ingestedAt
            )
            guard let prepared else {
                sendError = "The original message could not be prepared. Open the reply to retry or turn off Include in reply."
                return
            }
            guard let refreshedMessage = fetchMessage(messageID),
                  let refreshedDraft = refreshedMessage.draft else {
                sendError = "The reply draft is no longer available."
                return
            }
            refreshedDraft.quotedReplyPlainText = prepared.plainText
            refreshedDraft.quotedReplyHTML = prepared.html
            do {
                try (refreshedMessage.modelContext ?? modelContext).save()
            } catch {
                sendError = "Could not save the original message quote."
                return
            }
        }

        guard let currentMessage = fetchMessage(messageID),
              let currentDraft = currentMessage.draft,
              let currentAccount = currentMessage.account else {
            sendError = "No draft or account for this message."
            return
        }
        guard let identity = currentAccount.resolveIdentity(for: currentDraft.fromIdentityID) else {
            sendError = "No send identity configured for \(currentAccount.emailAddress). Add an identity in Settings."
            return
        }
        do {
            let context = currentMessage.modelContext ?? modelContext
            try dispatcher(context: context).enqueueSend(
                draft: currentDraft,
                account: currentAccount,
                identity: identity
            )
        } catch SendDispatcher.Error.quotedOriginalUnavailable {
            sendError = "The original message is not ready. Open the reply to retry or turn off Include in reply."
            return
        } catch {
            sendError = "Could not queue send: \(error.localizedDescription)"
            return
        }
        if selectedID == messageID {
            clearReplySelection()
        }
        refreshQueue()
    }

    /// After confirmation, hard-delete an empty compose draft and soft-discard
    /// one with authored content.
    private func performComposeDiscard(_ item: ComposerQueueItem) {
        if let state = composeState, state.draft?.id == item.id {
            performActiveComposeDiscard(state)
            return
        }
        guard item.kind == .compose, let draft = fetchDraft(item.id) else { return }
        guard ComposeState.discardDraft(
            draft,
            hardDeleteLocalDraft: draft.isEmptyCompose,
            context: modelContext
        ) else {
            sendError = "Could not discard this draft. Please try again."
            return
        }
        sendError = nil
        if selectedID == item.id {
            composeState = nil
            selectedID = nil
        }
        refreshQueue()
    }

    /// Cancel an in-flight / failed outbox send.
    private func cancelOutboxItem(_ item: ComposerQueueItem) {
        guard let outbox = fetchOutboxItem(item.id) else { return }
        outbox.status = .cancelled
        outbox.cancellationRequested = true
        try? modelContext.save()
        refreshQueue()
    }

    /// Requeue a failed send for another delivery attempt.
    private func retryOutboxItem(_ item: ComposerQueueItem) {
        guard let outbox = fetchOutboxItem(item.id) else { return }
        outbox.status = .queued
        outbox.nextAttemptAfter = nil
        outbox.attempts = 0
        outbox.lastError = nil
        try? modelContext.save()
        NotificationCenter.default.post(name: .ohiaSendAllOutboxNow, object: nil)
        refreshQueue()
    }

    private func reloadSelectedFromStore() {
        guard let target = session else { return }
        readCoordinator.requestReply(
            messageID: target.messageID,
            container: modelContext.container,
            isOpening: false,
            onResult: { assessment in
                guard session === target else { return }
                guard let assessment else {
                    clearReplySelection()
                    return
                }
                do {
                    try installReplyRefresh(assessment, into: target)
                } catch ReplySourcePreparationAssessmentError.staleInput {
                    // Keep the current editor; the next poll reads the new
                    // source version without applying this obsolete result.
                } catch {
                    sendError = "Could not refresh prepared sources: \(error.localizedDescription)"
                }
            },
            onError: { error in
                guard session === target else { return }
                sendError = "Could not refresh prepared sources: \(error.localizedDescription)"
            }
        )
    }

    private func installReplyRefresh(
        _ assessment: ReplySourcePreparationAssessment,
        into session: ComposerSession
    ) throws {
        let context = ModelContext(modelContext.container)
        guard let message = Self.fetchMessage(session.messageID, context: context) else {
            clearReplySelection()
            return
        }
        guard try Self.adoptReadySourcesForOpenReply(
            message: message, context: context, assessment: assessment
        ) != nil else {
            clearReplySelection()
            return
        }
        replyModelContext = context
        activeMessage = message
        ensureBodyTextLoaded(for: message)
        // An open-only session (notification / Send to Composer) can start with
        // `message.draft` nil while the pipeline seeds the row in the worker
        // process. Link it here — as every other draft-reading site does via
        // `storedDraft` — so the poll surfaces the seeded draft rather than
        // holding the pane on "preparing sources".
        linkExistingSourceDraft(for: message, context: context)
        session.reload(from: message)
        activateAutomaticMessagesContext()
        refreshStylePanel(session, message: message)
        refreshQuotedPreview(session, message: message)
    }

    private func loadNeighborsForCurrentSession() async {
        guard let target = session, let services = appServices else { return }
        guard let neighbors = try? await Self.loadSourceNeighbors(
            provider: services.makeNeighborProvider(),
            citations: target.citations,
            correspondentEmail: target.correspondentEmail,
            subject: "Re: \(target.subject)"
        ), !Task.isCancelled, session === target else { return }
        target.sourceNeighbors = neighbors
    }

    /// Related-message retrieval can wait on SQLite and search the full index.
    /// Keep it off the UI executor and discard results from cancelled sessions.
    @concurrent
    static func loadSourceNeighbors(
        provider: any NeighborProviding,
        citations: [Citation],
        correspondentEmail: String,
        subject: String
    ) async throws -> [NeighborData] {
        try Task.checkCancellation()
        let neighbors = provider.fetchNeighbors(
            citations: citations,
            findings: [],
            correspondentEmail: correspondentEmail,
            subject: subject
        )
        try Task.checkCancellation()
        return neighbors.sourceNeighbors
    }

    /// Recomputes the Style panel's register card + picker for the session's
    /// message. Equality-guarded so the 2.5s poll tick doesn't re-render the
    /// panel when nothing moved.
    private func refreshStylePanel(_ session: ComposerSession, message: Message) {
        let context = message.modelContext ?? activeReplyModelContext
        let model = StyleRegisterPanelModel.forReply(message: message, context: context)
        session.updateStylePanel(model)
    }

    /// Stores a slider move as pending draft-local direction. Matching the
    /// controls already applied to the visible body cancels the pending
    /// change; returning to register defaults is represented by nil.
    private func handleStyleAxesChange(
        _ session: ComposerSession,
        axes: StyleAxisValues?
    ) {
        guard let message = fetchMessage(session.messageID),
              let draft = message.draft,
              draft.status == .pending else { return }
        if session.viewingVersionIndex != nil {
            guard persistEditorText(session) else { return }
        }
        guard let card = session.stylePanel.card,
              let defaults = card.styleAxes else { return }
        draft.stageStyleControlDecision(
            effectiveAxes: axes,
            registerID: card.id,
            registerRevision: card.revision,
            defaults: defaults
        )
        try? activeReplyModelContext.save()
        refreshStylePanel(session, message: message)
    }

    /// Prepares one durable plain/HTML quote snapshot from the latest authored
    /// portion of the incoming message. Composer previews the persisted plain
    /// representation; `SendDispatcher` freezes both representations into the
    /// outbox before delivery.
    private func refreshQuotedPreview(
        _ session: ComposerSession,
        message: Message,
        force: Bool = false
    ) {
        // Open-only sessions can precede the worker-created Draft row, and
        // ingestion can publish body paths a poll later. Keep the control in
        // its loading state until both durable inputs exist instead of turning
        // a normal pipeline handoff into a user-visible failure.
        guard message.draft != nil else { return }
        let htmlPath = message.bodyHtmlPath
        let textPath = message.bodyTextPath
        let rawPath = message.rawPath
        guard htmlPath != nil || textPath != nil || rawPath != nil else { return }
        guard session.beginReplyQuotePreparation(force: force) else { return }
        let fromName = message.fromName
        let fromAddress = message.fromAddress
        let receivedAt = message.receivedAt
        let ingestedAt = message.ingestedAt
        Task { @MainActor in
            let prepared = await Self.prepareReplyQuote(
                htmlPath: htmlPath,
                textPath: textPath,
                rawPath: rawPath,
                fromName: fromName,
                fromAddress: fromAddress,
                receivedAt: receivedAt,
                ingestedAt: ingestedAt
            )
            guard self.session === session else { return }
            guard let prepared else {
                session.failReplyQuotePreparation(
                    "Ohia could not prepare the original message. Retry, or turn off Include in reply."
                )
                return
            }
            guard let currentMessage = fetchMessage(session.messageID),
                  let draft = currentMessage.draft else {
                session.failReplyQuotePreparation(
                    "The reply draft is no longer available."
                )
                return
            }

            let previousPlain = draft.quotedReplyPlainText
            let previousHTML = draft.quotedReplyHTML
            draft.quotedReplyPlainText = prepared.plainText
            draft.quotedReplyHTML = prepared.html
            do {
                try activeReplyModelContext.save()
                session.applyPreparedReplyQuote(prepared.plainText)
            } catch {
                draft.quotedReplyPlainText = previousPlain
                draft.quotedReplyHTML = previousHTML
                session.failReplyQuotePreparation(
                    "Ohia could not save the original message. Retry, or turn off Include in reply."
                )
            }
        }
    }

    /// Uses the Composer's tested authored-body loader so semantic HTML quote
    /// containers are removed before their tags are flattened. The canonical
    /// plain part remains authoritative when HTML has no structural boundary.
    @concurrent
    private static func prepareReplyQuote(
        htmlPath: String?,
        textPath: String?,
        rawPath: String?,
        fromName: String?,
        fromAddress: String,
        receivedAt: Date?,
        ingestedAt: Date
    ) async -> QuotedReplyFormatter.PreparedQuote? {
        guard let body = await SourceEmailBodyPreviewLoader.loadForReplyQuote(
            htmlPath: htmlPath,
            textPath: textPath,
            rawPath: rawPath
        ) else {
            return nil
        }
        return QuotedReplyFormatter.prepareForIncoming(
            bodyText: body,
            fromName: fromName,
            fromAddress: fromAddress,
            receivedAt: receivedAt,
            ingestedAt: ingestedAt
        )
    }

    private func updateQuotedOriginalInclusion(
        _ included: Bool,
        session: ComposerSession
    ) {
        let context = activeReplyModelContext
        guard let message = fetchMessage(session.messageID),
              let draft = message.draft else {
            sendError = "The reply draft is no longer available."
            return
        }
        let previous = draft.includesQuotedOriginal
        draft.includesQuotedOriginal = included
        do {
            try context.save()
            session.updateQuotedOriginalInclusion(included)
            sendError = nil
        } catch {
            draft.includesQuotedOriginal = previous
            sendError = "Could not save the original-message choice."
        }
    }

    // MARK: - Flow actions

    /// Decisions step CTA: persist answers, flip the draft to `.generating`,
    /// and enqueue the generation job at user-initiated priority. When the
    /// pipeline hasn't seeded a question-stage draft yet (model loading,
    /// backlog), create the draft here so the user can demand a draft
    /// without waiting for intake.
    private func handleGenerate(_ session: ComposerSession) {
        let context = activeReplyModelContext
        do {
            _ = try Self.flushReplyForTermination(session: session, context: context, adoptingViewedVersion: false)
        } catch {
            sendError = error.localizedDescription
            return
        }
        guard let message = fetchMessage(session.messageID) else { return }
        let draft: Draft
        // The generative worker may have seeded this message's draft row in
        // its own process while the registered Message object here still
        // carries a stale nil relationship — re-check through a real fetch
        // before inserting so the one-to-one can't fork into a duplicate.
        if let existing = message.draft ?? ComposerQueueMembership.storedDraft(
            for: message.id,
            context: context
        ) {
            draft = existing
            if message.draft == nil {
                message.draft = existing
            }
        } else {
            draft = Draft(
                message: message,
                replyText: "",
                confidence: 0,
                sourceThreadCount: message.thread?.messages.count ?? 1,
                sourceExemplarCount: 0,
                styleMatch: 0
            )
            context.insert(draft)
            message.draft = draft
        }
        guard !draft.isAutomaticSourceResearchPending else { return }
        ComposerDecisionHistoryPersistence.updateActiveQuestionsAndAnswers(on: draft)
        let draftingInstruction = session.draftingInstructionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        draft.draftingInstruction = draftingInstruction.isEmpty ? nil : draftingInstruction
        draft.stageRaw = DraftStage.generating
        // An explicit user request overrides any failure backoff window.
        draft.clearGenerationBackoff()
        session.isUserRevisitingDecisions = false
        do {
            try JobQueue().enqueue(
                type: .generateDraft,
                priority: ComposerDraftScheduling.userInitiatedPriority,
                messageId: message.id,
                context: context
            )
            try context.save()
        } catch {
            sendError = "Could not queue draft generation: \(error.localizedDescription)"
            return
        }
        session.reload(from: message)
        activeMessage = message
        ensureBodyTextLoaded(for: message)
        withAnimation(.easeInOut(duration: 0.2)) { session.step = .draft }
        refreshQueue()
    }

    /// Instruction box: capture manual edits as a version when present,
    /// stamp the pending instruction, and let the worker produce the next
    /// version.
    private func handleInstruction(_ session: ComposerSession, instruction: String) {
        let context = activeReplyModelContext
        guard let message = fetchMessage(session.messageID), let draft = message.draft else { return }
        guard persistEditorText(session) else { return }
        draft.pendingInstruction = instruction
        draft.clearGenerationBackoff()
        do {
            try JobQueue().enqueue(
                type: .generateDraft,
                priority: ComposerDraftScheduling.userInitiatedPriority,
                messageId: message.id,
                context: context
            )
            try context.save()
        } catch {
            sendError = "Could not queue revision: \(error.localizedDescription)"
            return
        }
        session.reload(from: message)
        refreshQueue()
    }

    /// Style picker: stamp the pending register switch. With a body present
    /// the worker owes a restyled version (same lifecycle as an instruction
    /// revision); before first generation the choice simply steers the
    /// initial pass, so no job is queued beyond what the flow already owes.
    private func handleRestyle(_ session: ComposerSession, registerID: UUID) {
        let context = activeReplyModelContext
        guard let message = fetchMessage(session.messageID), let draft = message.draft else { return }
        // Only pending drafts can be restyled — confirmed/sent bodies are
        // final, and the worker drains only pending rows.
        guard draft.status == .pending else { return }
        guard StyleRegisterResolver.register(
            withID: registerID,
            language: session.stylePanel.selectedLanguageID,
            context: context
        ) != nil else { return }
        let wasViewingVersion = session.viewingVersionIndex != nil
        if wasViewingVersion {
            guard persistEditorText(session) else { return }
        }
        let activeID = draft.pendingStyleRegisterID ?? draft.styleRegisterID
        guard registerID != activeID else {
            // Re-picking the style already shown affirms it as the choice.
            if draft.chosenStyleRegisterID != registerID {
                draft.chosenStyleRegisterID = registerID
                try? context.save()
            }
            return
        }
        if !wasViewingVersion {
            guard persistEditorText(session) else { return }
        }
        draft.pendingStyleRegisterID = registerID
        draft.chosenStyleRegisterID = registerID
        resetStyleAxesForNewDefault(on: draft)
        draft.clearGenerationBackoff()
        // A restyle job is owed only against a generated body (≥1 revision);
        // before first generation the choice steers the initial pass.
        let hasGeneratedBody = (draft.revisions ?? []).isEmpty == false
        do {
            if hasGeneratedBody {
                try JobQueue().enqueue(
                    type: .generateDraft,
                    priority: ComposerDraftScheduling.userInitiatedPriority,
                    messageId: message.id,
                    context: context
                )
            }
            try context.save()
        } catch {
            sendError = "Could not queue the style change: \(error.localizedDescription)"
            return
        }
        session.reload(from: message)
        refreshStylePanel(session, message: message)
        refreshQueue()
    }

    /// Rename a style register in place. `userRenamed` pins the name against
    /// future distillation passes; the revision bump re-stamps member
    /// training pairs with the new conditioning line on the next style pass.
    private func handleRegisterRename(_ session: ComposerSession, registerID: UUID, newName: String) {
        let context = activeReplyModelContext
        do {
            try StyleRegisterCatalog.renameStyle(
                id: registerID,
                newName: newName,
                context: context
            )
            sendError = nil
            if let message = fetchMessage(session.messageID) {
                refreshStylePanel(session, message: message)
            }
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// Saves the draft-local Custom profile as a durable account/language
    /// style, then selects it. Selecting the new row turns the same slider
    /// values into named defaults and queues the normal restyle lifecycle.
    private func handleSaveStyle(
        _ session: ComposerSession,
        name: String,
        axes: StyleAxisValues
    ) {
        let context = activeReplyModelContext
        guard let message = fetchMessage(session.messageID),
              message.draft != nil else {
            sendError = "The reply draft is no longer available."
            return
        }
        do {
            let register = try StyleRegisterCatalog.saveCustomStyle(
                name: name,
                axes: axes,
                languageID: session.stylePanel.selectedLanguageID,
                context: context
            )
            sendError = nil
            handleRestyle(session, registerID: register.id)
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// Soft-retires a style. When it shaped the current draft, the remaining
    /// style for the language becomes the normal pending restyle selection.
    private func handleDeleteStyle(_ session: ComposerSession, registerID: UUID) {
        let context = activeReplyModelContext
        guard let message = fetchMessage(session.messageID),
              let draft = message.draft else {
            sendError = "The reply draft is no longer available."
            return
        }
        let activeID = draft.pendingStyleRegisterID ?? draft.styleRegisterID
        do {
            let replacement = try StyleRegisterCatalog.deleteStyle(
                id: registerID,
                languageID: session.stylePanel.selectedLanguageID,
                context: context
            )
            sendError = nil
            if activeID == registerID {
                handleRestyle(session, registerID: replacement.id)
            } else {
                refreshStylePanel(session, message: message)
            }
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// Language picker: stamp the draft's output language. Styles are
    /// language-scoped, so a pending register pick is drained — promoted to
    /// the stamped choice when it covers the new language, dropped when it
    /// can't (leaving it pending would trigger a restyle-revision of the
    /// old-language body instead of the owed regeneration). With a generated
    /// body the worker owes a fresh generation pass in the new language
    /// (same lifecycle as Regenerate). Prepared evidence and answers remain
    /// available; the canonical writer request carries the new language.
    private func handleLanguageChange(_ session: ComposerSession, languageID: String) {
        let context = activeReplyModelContext
        guard let message = fetchMessage(session.messageID), let draft = message.draft else { return }
        guard draft.status == .pending else { return }
        guard let newID = DraftLanguage.familyID(for: languageID),
              newID != DraftLanguage.resolvedID(for: message) else { return }
        guard persistEditorText(session) else { return }
        draft.languageID = newID
        ComposerDecisionHistoryPersistence.refreshActiveVersionFromDraft(on: draft)
        if let pendingID = draft.pendingStyleRegisterID {
            if StyleRegisterResolver.register(
                withID: pendingID,
                language: newID,
                context: context
            ) != nil {
                draft.styleRegisterID = pendingID
            }
            draft.pendingStyleRegisterID = nil
        }
        draft.clearGenerationBackoff()
        let hasGeneratedBody = (draft.revisions ?? []).isEmpty == false
        do {
            if hasGeneratedBody {
                // The reply is written afresh in the new language; a typed
                // instruction still waiting then revises that body.
                draft.stageRaw = DraftStage.generating
                try JobQueue().enqueue(
                    type: .generateDraft,
                    priority: ComposerDraftScheduling.userInitiatedPriority,
                    messageId: message.id,
                    context: context
                )
            }
            try context.save()
        } catch {
            sendError = "Could not queue the language change: \(error.localizedDescription)"
            return
        }
        session.reload(from: message)
        refreshStylePanel(session, message: message)
        refreshQueue()
    }

    private func resetStyleAxesForNewDefault(on draft: Draft) {
        draft.pendingStyleControlSnapshot = nil
    }

    /// Context-grounded rewrite of whichever body the editor is displaying.
    private func handleRegenerate(_ session: ComposerSession) {
        let context = activeReplyModelContext
        let isRetry = session.isGenerationBlocked
        guard isRetry || session.hasPendingRegenerationInputs,
              let message = fetchMessage(session.messageID),
              let draft = message.draft else { return }
        if isRetry { session.showLiveDraft() }
        guard persistEditorText(session) else { return }
        if !isRetry {
            draft.pendingInstruction = DraftGenerationOrchestrator.regenerationInstruction
            draft.stageRaw = DraftStage.drafted
        }
        draft.clearGenerationBackoff()
        do {
            try JobQueue().enqueue(
                type: .generateDraft,
                priority: ComposerDraftScheduling.userInitiatedPriority,
                messageId: message.id,
                context: context
            )
            try context.save()
        } catch {
            sendError = "Could not queue regeneration: \(error.localizedDescription)"
            return
        }
        session.reload(from: message)
        refreshStylePanel(session, message: message)
        refreshQueue()
    }

    /// Send: edited drafts either surface their training-signal diff for
    /// review or accept the inferred signals automatically, according to the
    /// Composer preference. An already-open review sends only the signals the
    /// user kept.
    private func handleSend(_ session: ComposerSession) {
        guard session.step == .draft else { return }
        if let ownerID = session.inlinePhotoOwnerID, !permitSend(for: ownerID) { return }
        guard session.canSendDraft else {
            sendError = replySendBlockingReason(session)
            return
        }
        let analyzer: any EditAnalyzing = appServices?.makeEditAnalyzer() ?? HeuristicEditAnalyzer()
        let languageID = fetchMessage(session.messageID).flatMap {
            DraftLanguage.resolvedID(for: $0)
        }
        switch Self.trainingSignalSendDecision(
            for: session,
            reviewDraftEditsBeforeSending: reviewDraftEditsBeforeSending,
            analyzer: analyzer,
            languageID: languageID
        ) {
        case .review(let signals):
            session.trainingSignals = signals
            withAnimation(.spring(duration: 0.3)) { session.showDiffAnalysis = true }
        case .send(let approvedSignals):
            enqueueSendAndAdvance(session, approvedTrainingSignals: approvedSignals)
        }
    }

    private func enqueueSendAndAdvance(
        _ session: ComposerSession,
        approvedTrainingSignals: [TrainingSignal]? = nil
    ) {
        let context = activeReplyModelContext
        // The takeover overlay blocks mouse interaction with the Send button
        // while showing, but not the ⌘Return keyboard shortcut — without this
        // guard a reflexive second press mid-hold would enqueue a second real
        // send whose takeover the first send's delayed dismiss could then
        // stomp on.
        guard sendTakeoverCoordinator.active == nil else { return }
        if let ownerID = session.inlinePhotoOwnerID, !permitSend(for: ownerID) { return }
        guard session.canSendDraft else {
            sendError = replySendBlockingReason(session)
            return
        }
        switch session.commitAddressBuffers(context: context) {
        case .valid:
            sendError = nil
        case .invalid:
            sendError = "Fix invalid recipients before sending."
            return
        case .persistenceFailed:
            sendError = "Could not save recipient changes before sending."
            return
        }
        guard persistEditorText(session) else { return }
        guard let message = fetchMessage(session.messageID),
              let draft = message.draft,
              let account = message.account else {
            sendError = "No draft or account for this message."
            return
        }
        guard permitSend(for: draft.id) else { return }
        guard let identity = account.resolveIdentity(for: draft.fromIdentityID) else {
            sendError = "No send identity configured for \(account.emailAddress). Add an identity in Settings."
            return
        }
        let outboxItemID: UUID
        do {
            outboxItemID = try dispatcher(context: context).enqueueSend(
                draft: draft,
                account: account,
                identity: identity,
                approvedTrainingSignalsJSON: encodeTrainingSignals(approvedTrainingSignals)
            )
        } catch SendDispatcher.Error.quotedOriginalUnavailable {
            sendError = "The original message is not ready. Retry it, or turn off Include in reply."
            return
        } catch {
            sendError = "Could not queue send: \(error.localizedDescription)"
            return
        }
        beginSendTakeover(outboxItemID: outboxItemID, accountColorIndex: account.colorIndex)
        clearReplySelection()
        refreshQueue(afterInstall: {
            if let next = queueItems.first(where: { $0.kind == .reply }) { select(next) }
        })
    }

    private func replySendBlockingReason(_ session: ComposerSession) -> String {
        if session.hasPendingStyleControlDecision {
            return "Regenerate to apply the pending style adjustments before sending."
        }
        if session.isImportingAttachments {
            return "Wait for attachments to finish importing before sending."
        }
        if session.includesQuotedOriginal, !session.replyQuotePresentation.isReady {
            return "The original message is not ready. Retry it, or turn off Include in reply."
        }
        return "Add a draft body before sending."
    }

    private func permitSend(for ownerID: UUID) -> Bool {
        guard attachmentImportRegistry.blocksSending(ownerID: ownerID) == false else {
            sendError = "Wait for attachments to finish importing before sending."
            return false
        }
        return true
    }

    /// Writes the editor's content back to the draft row: plain text always,
    /// HTML when the content carries formatting, and a
    /// `manualEdit` revision so the distiller sees the user's text as its
    /// own version.
    private static func publishOpenReply(_ messageID: UUID?) {
        NotificationCenter.default.post(
            name: .ohiaComposerOpenReplyChanged,
            object: nil,
            userInfo: messageID.map { ["messageID": $0] } ?? [:]
        )
    }

    private func persistEditorText(_ session: ComposerSession) -> Bool {
        let context = activeReplyModelContext
        guard let message = fetchMessage(session.messageID), let draft = message.draft else {
            sendError = "Could not save your edits because this draft is unavailable."
            return false
        }
        let viewedVersion = session.versionForPersistence
        if let viewedVersion {
            // The visible historical body carries immutable style
            // provenance. Promoting it for Save, Regenerate, or Send must
            // promote those controls too, rather than relabeling it with the
            // live draft's newer style.
            draft.styleRegisterID = viewedVersion.styleRegisterID
            draft.styleControlSnapshot = viewedVersion.styleControlSnapshot
            draft.generatedSourcesJSON = viewedVersion.generatedSourcesJSON
            draft.pendingStyleControlSnapshot = nil
            // The adopted version is what the live body now derives from:
            // edits are measured against it, not the newest generation.
            draft.baseRevisionID = viewedVersion.id
        }
        let plain = session.plainEditorText
        if session.hasEdits || viewedVersion != nil {
            draft.replyText = plain
            draft.messageFormatRaw = session.messageFormat.rawValue
            draft.inlinePhotosJSON = ComposerInlinePhotoAssetCoding.encode(session.inlinePhotos)
            draft.bodyHTML = session.exportedHTML()
        }
        do {
            // Save is an author action too. Capture a previously saved body
            // even when the editor has already cleared its dirty flag.
            try ComposerManualEdit.recordSnapshot(on: draft, context: context)
            try context.save()
        } catch {
            sendError = "Could not save your edits: \(error.localizedDescription)"
            return false
        }
        try? ComposerDraftSyncScheduler.enqueueDraftSync(draft: draft, context: context)
        session.rebase(
            plain: draft.replyText,
            html: draft.bodyHTML,
            format: session.messageFormat
        )
        return true
    }

    private func applyIdentityChange(to new: Identity, session: ComposerSession) {
        let context = activeReplyModelContext
        guard let message = fetchMessage(session.messageID), let draft = message.draft else { return }
        // Signatures are account-scoped: only an identity from a different
        // account changes the tail (reply identities usually all belong to
        // the message's account, so this is normally a pure From change).
        let previousAccountID = identities.first(where: { $0.id == draft.fromIdentityID })?.account?.id
            ?? message.account?.id
        draft.fromIdentityID = new.id
        let didChangeAccount = new.account?.id != previousAccountID
        if let newAccount = new.account, didChangeAccount {
            let slot = newAccount.defaultSignatureSlot
            draft.signatureSlotID = slot?.id
            swapSignatureTail(to: slot, draft: draft, session: session)
        }
        if didChangeAccount {
            ComposerDecisionHistoryPersistence.refreshActiveVersionFromDraft(on: draft)
            draft.interviewStateJSON = nil
            draft.decisionResearchOverlayJSON = nil
        }
        try? context.save()
        try? ComposerDraftSyncScheduler.enqueueDraftSync(draft: draft, context: context)
        if didChangeAccount {
            session.reload(from: message)
        }
    }

    /// Signature-picker mutation: re-stamps the draft's slot (nil = "No
    /// Signature") and swaps the editor's signature tail in place.
    private func applySignatureSlotChange(to slot: SignatureSlot?, session: ComposerSession) {
        let context = activeReplyModelContext
        guard let message = fetchMessage(session.messageID), let draft = message.draft else { return }
        guard draft.signatureSlotID != slot?.id else { return }
        draft.signatureSlotID = slot?.id
        swapSignatureTail(to: slot, draft: draft, session: session)
        try? context.save()
        try? ComposerDraftSyncScheduler.enqueueDraftSync(draft: draft, context: context)
    }

    private func swapSignatureTail(to slot: SignatureSlot?, draft: Draft, session: ComposerSession) {
        let signature: NSAttributedString?
        if let slot, session.messageFormat == .richText, slot.isRich, let html = slot.html {
            signature = SignatureHTMLImageCoding.attributedContent(
                html: html,
                ownerID: slot.id,
                assets: slot.images,
                store: SignatureAssetStore()
            )
        } else if let slot, !slot.plainText.isEmpty {
            signature = NSAttributedString(string: slot.plainText)
        } else {
            signature = nil
        }
        let swapped = ComposerRichTextCodec.swappingSignature(
            in: session.editorText,
            newAttributedSignature: signature
        )
        session.updateSignatureContext(slot: slot)
        draft.replyText = ComposerRichTextCodec.plainBodyProjection(of: swapped)
        draft.inlinePhotosJSON = ComposerInlinePhotoAssetCoding.encode(session.inlinePhotos)
        draft.bodyHTML = SignatureHTMLImageCoding.exportComposerBodyHTML(
            swapped,
            format: session.messageFormat,
            ownerID: slot?.id ?? UUID(),
            assets: slot?.images ?? [],
            inlinePhotoOwnerID: session.inlinePhotoOwnerID,
            inlinePhotos: session.inlinePhotos
        )
        session.rebase(
            plain: draft.replyText,
            html: draft.bodyHTML,
            format: session.messageFormat
        )
    }

    private func encodeTrainingSignals(_ signals: [TrainingSignal]?) -> String? {
        guard let signals,
              let data = try? JSONEncoder().encode(signals) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Helpers

    private func fetchMessage(_ messageID: UUID) -> Message? {
        let context = session?.messageID == messageID
            ? activeReplyModelContext
            : modelContext
        return Self.fetchMessage(messageID, context: context)
    }

    private static func fetchMessage(
        _ messageID: UUID,
        context: ModelContext
    ) -> Message? {
        let predicate = #Predicate<Message> { $0.id == messageID }
        return try? context.fetch(FetchDescriptor<Message>(predicate: predicate)).first
    }

    private func fetchDraft(_ id: UUID) -> Draft? {
        let predicate = #Predicate<Draft> { $0.id == id }
        return try? modelContext.fetch(FetchDescriptor<Draft>(predicate: predicate)).first
    }

    private func fetchAccount(_ id: UUID) -> Account? {
        let predicate = #Predicate<Account> { $0.id == id }
        return try? modelContext.fetch(FetchDescriptor<Account>(predicate: predicate)).first
    }

    private func fetchOutboxItem(_ id: UUID) -> OutboxItem? {
        let predicate = #Predicate<OutboxItem> { $0.id == id }
        return try? modelContext.fetch(FetchDescriptor<OutboxItem>(predicate: predicate)).first
    }

    private func messageSummary(for messageID: UUID) -> String? {
        let summary: String?
        let evidence: String?
        if activeMessage?.id == messageID {
            summary = activeMessage?.analysis?.bodySummary
            evidence = activeMessageBody?.plainText
        } else {
            summary = fetchMessage(messageID)?.analysis?.bodySummary
            evidence = nil
        }
        return Self.readerFacingComposerSummary(summary, evidence: evidence)
    }

    private func messageBody(for messageID: UUID) -> ComposerIncomingMessageBody? {
        guard activeMessage?.id == messageID else { return nil }
        return activeMessageBody
    }

    private static func readerFacingComposerSummary(_ summary: String?, evidence: String?) -> String? {
        guard let summary else { return nil }
        var cleaned = summary
        cleaned = replaceComposerSummaryMatches(
            in: cleaned,
            pattern: #"\b(?:the\s+)?account owner\s*,\s*[^\n,;:!?()]{2,80},"#,
            options: [.caseInsensitive]
        ) { match in
            composerPronoun(for: match, lower: "you", upper: "You")
        }
        if let evidence, !composerEvidenceMentionsAccountOwner(evidence) {
            cleaned = replaceComposerSummaryMatches(
                in: cleaned,
                pattern: #"\b(?:the\s+)?account owner(?:'s|’s)\b"#,
                options: [.caseInsensitive]
            ) { match in
                composerPronoun(for: match, lower: "your", upper: "Your")
            }
            cleaned = replaceComposerSummaryMatches(
                in: cleaned,
                pattern: #"\b(?:the\s+)?account owner\b(?!\s+(?:for|at|of|in|on|from|with|under|within|over|as)\b)"#,
                options: [.caseInsensitive]
            ) { match in
                composerPronoun(for: match, lower: "you", upper: "You")
            }
        }
        cleaned = repairComposerSecondPersonAgreement(in: cleaned)
        return cleaned
    }

    private static func composerEvidenceMentionsAccountOwner(_ evidence: String) -> Bool {
        evidence.range(of: "account owner", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func repairComposerSecondPersonAgreement(in text: String) -> String {
        [
            (#"\b([Yy])ou prefers\b"#, "$1ou prefer"),
            (#"\b([Yy])ou wants\b"#, "$1ou want"),
            (#"\b([Yy])ou needs\b"#, "$1ou need"),
            (#"\b([Yy])ou has\b"#, "$1ou have"),
            (#"\b([Yy])ou is\b"#, "$1ou are"),
            (#"\b([Yy])ou was\b"#, "$1ou were"),
            (#"\b([Yy])ou asks\b"#, "$1ou ask"),
            (#"\b([Yy])ou says\b"#, "$1ou say"),
            (#"\b([Yy])ou receives\b"#, "$1ou receive"),
            (#"\b([Yy])ou reviews\b"#, "$1ou review"),
            (#"\b([Yy])ou approves\b"#, "$1ou approve")
        ].reduce(text) { partial, repair in
            replaceComposerSummaryRegex(
                repair.0,
                in: partial,
                withTemplate: repair.1,
                options: [.caseInsensitive]
            )
        }
    }

    private static func composerPronoun(for match: String, lower: String, upper: String) -> String {
        let trimmed = match.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return lower }
        return first.isUppercase ? upper : lower
    }

    private static func replaceComposerSummaryMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let ns = text as NSString
        var result = text
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        )
        for match in matches.reversed() {
            let original = ns.substring(with: match.range)
            result = (result as NSString).replacingCharacters(
                in: match.range,
                with: transform(original)
            )
        }
        return result
    }

    private static func replaceComposerSummaryRegex(
        _ pattern: String,
        in text: String,
        withTemplate template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    private func clearActiveMessageBodyText() {
        activeMessageBodyLoadKey = nil
        activeMessageBody = nil
    }

    private func ensureBodyTextLoaded(for message: Message) {
        let messageID = message.id
        let htmlPath = message.bodyHtmlPath
        let textPath = message.bodyTextPath
        let rawPath = message.rawPath
        let loadKey = [
            messageID.uuidString,
            htmlPath ?? "",
            textPath ?? "",
            rawPath ?? ""
        ].joined(separator: "|")
        guard activeMessageBodyLoadKey != loadKey else { return }
        activeMessageBodyLoadKey = loadKey
        activeMessageBody = nil

        Task { @MainActor in
            let body = await Task.detached(priority: .userInitiated) {
                Self.displayBody(htmlPath: htmlPath, textPath: textPath, rawPath: rawPath)
            }.value
            guard activeMessage?.id == messageID else { return }
            activeMessageBody = body
        }
    }

    nonisolated private static func displayBody(
        htmlPath: String?,
        textPath: String?,
        rawPath: String?
    ) -> ComposerIncomingMessageBody? {
        guard case .loaded(let source) = LockReadoutBodyLoader.load(
            htmlPath: htmlPath,
            textPath: textPath,
            rawPath: rawPath
        ) else {
            return nil
        }
        return ComposerIncomingMessageBody(source: source)
    }

    private func markReadOnOpenIfNeeded(_ message: Message) {
        guard !message.isReadOrFalse else { return }
        let mutationDispatcher = MailboxMutationDispatcher(context: modelContext, jobQueue: JobQueue())
        do {
            let outcome = try mutationDispatcher.setRead(messageID: message.id, value: true)
            if !outcome.propagatedToServer {
                print("[Ohia] Composer mark-read updated a local-only message: \(message.id)")
            }
            NotificationCenter.default.post(name: .ohiaEmailSummariesInvalidated, object: nil)
        } catch {
            print("[Ohia] Composer mark-read failed for \(message.id): \(String(reflecting: type(of: error)))")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OhiaColors.frameUrgencyHigh)
            Text(message)
                .font(OhiaTypography.cardBody)
                .foregroundStyle(OhiaColors.textPrimary)
            Spacer()
            Button("Dismiss") { sendError = nil }
                .font(OhiaTypography.button)
                .buttonStyle(EmblemButtonStyle(tint: OhiaColors.frameUrgencyHigh, horizontalPadding: 10, verticalPadding: 5))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(OhiaColors.composerRaisedPanelBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OhiaColors.frameUrgencyHigh.opacity(0.35), lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }
}
