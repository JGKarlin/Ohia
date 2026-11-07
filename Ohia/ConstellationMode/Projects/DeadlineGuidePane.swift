import AppKit
import SwiftUI
import SwiftData
import OhiaCore
import OhiaML

/// The Deadlines tab's right pane: the selected deadline's summary grown into
/// a completion guide, rendered in the lens's shared focused-surface idiom —
/// the same dossier-header-over-a-centered-card-feed form `DeadlineFocusedView`
/// and the Projects workroom use, on `spaceBackground`, so the top level and
/// the focused reader read as one surface. The feed: the dossier header
/// (countdown badge, title, date + stated-as, correspondents), the briefing
/// card, the WHAT'S NEEDED card (numbered tickable steps; each document step
/// carries the model's close reading of that document), then every email in the
/// deadline thread using the Projects workroom's exact collapsed/expandable
/// card, status, action, and departure grammar. Deadline files live in the
/// dedicated file column beside this guide and feed its next re-distillation.
/// Replaces the month calendar; the "Ohia"
/// calendar in Calendar.app remains the month view. Resolve lives on the
/// lens's right control column, which acts on the same selected deadline.
struct DeadlineGuidePane: View {
    @Bindable var workspace: ProjectsWorkspaceState
    let entry: DeadlineEntry
    let now: Date
    let snapshot: ProjectsSnapshot
    let summaryState: DeadlineSummaryState
    /// Deep-read state per resource key ("document:<filename lowercased>").
    let readoutStates: [String: DeadlineGuideReadoutState]
    let completedStepIDs: Set<String>
    let messageActions: FrontPageMessageActionHandlers
    let onToggleStep: (_ stepID: String, _ completed: Bool) -> Void
    let onReply: () -> Void
    let onConfirm: () -> Void
    let onPresentMessageMenu: (UUID, NSPoint, NSView) -> Void

    @Environment(\.readingTextSize) private var readingTextSize
    @Environment(\.modelContext) private var modelContext
    @Query private var composerDrafts: [Draft]
    @State private var messageCards: [DeadlineGuideMessageCard] = []
    @State private var bodyStates: [UUID: ProjectsWorkroomView.WorkroomBodyState] = [:]
    @State private var didLoadMessages = false
    @State private var hitTester = ProjectsHitTester()
    @State private var hoveredMessageID: UUID?
    @State private var hoverExitTask: Task<Void, Never>?
    @State private var accountBadges: [UUID: ProjectsWorkroomView.WorkroomAccountBadge] = [:]

    /// The shared focused-surface feed width (`DeadlineFocusedView.feedWidth`).
    private static let feedWidth: CGFloat = 680

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                dossierHeader
                GuideSectionHeader("SUMMARY", systemImage: "text.alignleft")
                GuideCard {
                    GuideBriefingBody(
                        summaryState: summaryState,
                        subjectNoun: "deadline",
                        placeholderWidth: Self.feedWidth - 60
                    )
                }
                if case .loaded(let result) = summaryState, result.actions.isEmpty == false {
                    let doneCount = result.actions.count { completedStepIDs.contains($0.id) }
                    GuideSectionHeader(
                        "WHAT'S NEEDED",
                        systemImage: "checklist",
                        detail: "· \(doneCount) of \(result.actions.count) done"
                    )
                    GuideCard {
                        GuideNeedsList(
                            result: result,
                            completedStepIDs: completedStepIDs,
                            readoutStates: readoutStates,
                            onToggleStep: onToggleStep
                        ) {
                            if obligationKind != nil {
                                Rectangle().fill(OhiaColors.glassBorder.opacity(0.6)).frame(height: 1)
                                obligationRowView
                                    .padding(.top, 11)
                            }
                        }
                    }
                } else if obligationKind != nil {
                    // The Reply / Confirm affordance never waits on the model —
                    // an outstanding obligation is actionable while the summary
                    // is still loading (or failed to generate).
                    GuideSectionHeader("WHAT'S NEEDED", systemImage: "checklist")
                    GuideCard { obligationRowView }
                }
                GuideSectionHeader("EMAILS", systemImage: "envelope")
                ForEach(messageCards) { card in
                    workroomEmailCard(card)
                        .id(card.id)
                }
                if messageCards.isEmpty && didLoadMessages {
                    Text("The emails for this deadline are no longer in scope.")
                        .font(.system(size: 12))
                        .foregroundStyle(OhiaColors.textSecondary)
                        .padding(.top, 24)
                }
            }
            .frame(maxWidth: Self.feedWidth)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 24)
            .background(
                TimelineEventCatcher(onRightClick: { point, view in
                    handleRightClick(point: point, view: view)
                })
            )
            .coordinateSpace(.named(Self.contentSpace))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OhiaColors.spaceBackground)
        .task(id: messageLoadID) { loadMessages() }
        .task {
            loadAccountBadges()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ohiaAccountColorChanged)) { _ in
            loadAccountBadges()
        }
        .onDisappear {
            hoverExitTask?.cancel()
            hoverExitTask = nil
            hoveredMessageID = nil
            hitTester.reset()
        }
    }

    private static let contentSpace = "deadlineGuideContent"

    // MARK: - Dossier header (the focused view's grammar, top-level controls
    // live elsewhere: reminder on the agenda rows, Resolve on the rail)

    private var dossierHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            countdownBadge
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title.isEmpty ? "(no subject)" : entry.title)
                    .font(readingTextSize.font(base: 17, weight: .bold, maximumScale: 1.20))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(dateLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(statusColor)
                    if !entry.surfaceText.isEmpty {
                        Text("· stated as \u{201C}\(entry.surfaceText)\u{201D}")
                            .font(readingTextSize.font(base: 11, maximumScale: 1.35))
                            .foregroundStyle(OhiaColors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !correspondents.isEmpty {
                    Text(correspondents)
                        .font(readingTextSize.font(base: 11.5, maximumScale: 1.35))
                        .foregroundStyle(OhiaColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(entry.messageCount == 1 ? "1 email" : "\(entry.messageCount) emails")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(OhiaColors.textTertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(OhiaColors.glassPanelBackground)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OhiaColors.glassBorder, lineWidth: 1))
        )
    }

    private var countdownBadge: some View {
        let delta = DeadlineFormatting.dayDelta(from: now, to: entry.deadlineDate)
        return VStack(spacing: 1) {
            if entry.status == .resolved {
                Image(systemName: "checkmark").font(.system(size: 18, weight: .bold))
            } else if delta == 0 {
                Text("Today").font(.system(size: 13, weight: .bold))
            } else {
                Text("\(abs(delta))").font(.system(size: 24, weight: .bold)).monospacedDigit()
                Text(abs(delta) == 1 ? (delta < 0 ? "day ago" : "day") : (delta < 0 ? "days ago" : "days"))
                    .font(.system(size: 8.5, weight: .semibold))
                    .textCase(.uppercase)
            }
        }
        .foregroundStyle(statusColor)
        .frame(width: 64, height: 60)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(statusColor.opacity(0.12))
        )
    }

    private var dateLabel: String {
        entry.granularity == .dateTime
            ? DeadlineFormatting.dayTimeLabel(entry.deadlineDate)
            : DeadlineFormatting.dayLabel(entry.deadlineDate)
    }

    private var correspondents: String {
        let names = entry.correspondents.prefix(5).map { $0.displayName ?? $0.email }
        let extra = entry.correspondents.count - names.count
        let base = names.joined(separator: ", ")
        return extra > 0 ? "\(base)  +\(extra)" : base
    }

    private var statusColor: Color {
        switch entry.status {
        case .resolved: return OhiaColors.textTertiary
        case .past: return OhiaColors.ohiaRed
        case .upcoming:
            return DeadlineFormatting.dayDelta(from: now, to: entry.deadlineDate) <= 2
                ? OhiaColors.chipActiveForeground
                : OhiaColors.textSecondary
        }
    }

    // MARK: - Obligation (reply / confirm) affordance

    /// The deadline's outstanding obligation as an inline action: Reply for a
    /// needs-reply thread, Confirm for a needs-confirmation one (never both,
    /// per the triage rule), or the queued state while a draft is in the
    /// Composer.
    @ViewBuilder
    private var obligationRowView: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OhiaColors.textTertiary)
                .frame(width: 17)
            switch obligationKind {
            case .reply:
                Button(action: onReply) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrowshape.turn.up.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Reply in the Composer")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 12, verticalPadding: 4))
                .help("Queue this deadline's thread in the Composer")
            case .confirm:
                Button(action: onConfirm) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Mark Confirmed")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                }
                .buttonStyle(EmblemButtonStyle(horizontalPadding: 12, verticalPadding: 4))
                .help("Record that this deadline's confirmation was handled")
            case .queued:
                Text("A draft for this deadline is queued in the Composer")
                    .font(.system(size: 10.5).italic())
                    .foregroundStyle(OhiaColors.textTertiary)
            case nil:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
    }

    private enum ObligationKind { case reply, confirm, queued }

    /// `nil` when nothing is owed — sent by the owner, resolved, or the
    /// obligation already discharged.
    private var obligationKind: ObligationKind? {
        guard entry.isSentByUser == false, entry.isResolvedByUser == false else { return nil }
        if liveComposerQueueMembership { return .queued }
        if entry.requiresConfirmation {
            return entry.isConfirmed ? nil : .confirm
        }
        if entry.isActionable {
            return entry.isReplied ? nil : .reply
        }
        return nil
    }

    /// The Projects snapshot is refreshed by mail/attention notifications, but
    /// Composer send completion updates Draft directly. Observing drafts here
    /// makes the visible sentence track the same pending-status gate as the
    /// Composer queue without waiting for an unrelated snapshot refresh.
    private var liveComposerQueueMembership: Bool {
        liveComposerQueueMembership(
            messageID: entry.representativeMessageID,
            fallback: entry.isInComposerQueue
        )
    }

    /// The same-count case matters too: a new summary, status mutation, or
    /// filter projection changes the shared Project card without changing the
    /// deadline identity. The snapshot signature therefore owns reloading.
    private var messageLoadID: DeadlineGuideMessageLoadID {
        DeadlineGuideMessageLoadID(
            entryID: entry.id,
            representativeID: entry.representativeMessageID,
            snapshotSignature: snapshot.signature
        )
    }

    // MARK: - Deadline email thread

    private func workroomEmailCard(_ card: DeadlineGuideMessageCard) -> some View {
        let messageID = card.id
        let filterRow = card.filterRow
        return WorkroomEmailCard(
            mark: card.mark,
            filterRow: filterRow,
            display: ProjectsAnnotationItemBuilder.makeDisplay(
                messageID: messageID,
                row: filterRow,
                summaryOverride: nil,
                userAddresses: snapshot.userAddresses
            ),
            statusDescriptor: MessageStatusDescriptor(mark: card.mark),
            accountBadge: filterRow.accountId.flatMap { accountBadges[$0] },
            isInComposerQueue: liveComposerQueueMembership(
                messageID: messageID,
                fallback: snapshot.rowsSnapshot.messageLookup[messageID]?.isInComposerQueue == true
            ),
            isSummaryRegenerating: false,
            isHovered: hoveredMessageID == messageID,
            expanded: workspace.workroomExpandedMessageID == messageID,
            highlighted: false,
            bodyState: bodyStates[messageID],
            departingGesture: workspace.statusGestureCoordinator.gesture(for: messageID),
            actions: messageActions,
            classification: filterRow.mailClassification,
            customCategoryKeys: filterRow.customCategoryKeys,
            customCategoryCatalog: [],
            showsProjectMembershipControls: false,
            onToggleExpansion: {
                toggleExpansion(messageID: messageID, filterRow: filterRow)
            },
            onHoverChange: { hovering in
                handleHoverChange(hovering, messageID: messageID)
            },
            onClassificationChanged: { _, _ in },
            onShowMembershipDetails: {}
        )
        .zIndex(
            workspace.statusGestureCoordinator.gesture(for: messageID)?
                .action.usesDepartingOverlay == true ? 1 : 0
        )
        .background(
            GeometryReader { geometry in
                Color.clear.onChange(
                    of: geometry.frame(in: .named(Self.contentSpace)),
                    initial: true
                ) { _, frame in
                    hitTester.updateMessage(
                        rect: frame,
                        messageID: messageID,
                        projectKey: "deadline:\(entry.id)"
                    )
                }
            }
        )
    }

    private func loadMessages() {
        didLoadMessages = false
        bodyStates = [:]
        let cards = DeadlineGuideMessageCardSource.fetch(
            representativeID: entry.representativeMessageID,
            modelContext: modelContext,
            visibleMessageRows: snapshot.messageFilterRows,
            deadlineText: entry.surfaceText,
            expectedMessageCount: entry.messageCount
        )
        messageCards = cards
        hitTester.retainMessages(Set(cards.map(\.id)))
        if let expanded = workspace.workroomExpandedMessageID,
           cards.contains(where: { $0.id == expanded }) == false {
            workspace.workroomExpandedMessageID = nil
        }
        didLoadMessages = true
    }

    private func toggleExpansion(messageID: UUID, filterRow: MessageFilterRow?) {
        if workspace.workroomExpandedMessageID == messageID {
            workspace.workroomExpandedMessageID = nil
            return
        }
        workspace.workroomExpandedMessageID = messageID
        kickBodyLoadIfNeeded(messageID: messageID, filterRow: filterRow)
        if let filterRow, filterRow.isRead == false {
            messageActions.setRead([messageID], true)
        }
    }

    private func kickBodyLoadIfNeeded(messageID: UUID, filterRow: MessageFilterRow?) {
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
            guard Task.isCancelled == false else { return }
            guard case .loaded(let source) = result,
                  let text = OriginalMessageText.cleaned(
                    from: LockReadoutBodyContent(source: source).plainText
                  ) else {
                bodyStates[messageID] = .failed
                return
            }
            bodyStates[messageID] = .loaded(text)
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

    private func handleRightClick(point: NSPoint, view: NSView) {
        guard let hit = hitTester.message(at: CGPoint(x: point.x, y: point.y)) else { return }
        onPresentMessageMenu(hit.messageID, point, view)
    }

    private func liveComposerQueueMembership(messageID: UUID, fallback: Bool) -> Bool {
        let requestedID = messageID
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.id == requestedID }
        )
        descriptor.fetchLimit = 1
        let liveEligibility = (try? modelContext.fetch(descriptor).first)?
            .isComposerQueueEligible ?? fallback
        let draftStatus = composerDrafts.first { $0.message?.id == messageID }?.status
        return ProjectsDataController.deadlineComposerQueueMembership(
            isEligible: liveEligibility,
            draftStatus: draftStatus
        )
    }

    private func loadAccountBadges() {
        guard let accounts = try? modelContext.fetch(FetchDescriptor<Account>()) else { return }
        accountBadges = Dictionary(uniqueKeysWithValues: accounts.map { account in
            (
                account.id,
                ProjectsWorkroomView.WorkroomAccountBadge(
                    name: account.displayName,
                    emailAddress: account.emailAddress,
                    color: AccountColorPalette.color(forIndex: account.colorIndex)
                )
            )
        })
    }
}

struct DeadlineGuideMessageLoadID: Equatable {
    let entryID: String
    let representativeID: UUID
    let snapshotSignature: ProjectsSnapshotSignature
}

struct DeadlineGuideMessageCard: Identifiable {
    let mark: ProjectMessageMark
    let filterRow: MessageFilterRow

    var id: UUID { mark.messageID }
    var isSentByUser: Bool { mark.isSentByUser }
}

enum DeadlineGuideMessageCardSource {
    static func fetch(
        representativeID: UUID,
        modelContext: ModelContext,
        visibleMessageRows: [String: MessageFilterRow],
        deadlineText: String,
        expectedMessageCount: Int
    ) -> [DeadlineGuideMessageCard] {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.id == representativeID }
        )
        descriptor.fetchLimit = 1
        guard let representative = try? modelContext.fetch(descriptor).first else { return [] }
        let threadMessages = representative.thread?.messages ?? [representative]
        let projected = threadMessages.compactMap { message -> (Message, MessageFilterRow)? in
            guard let row = visibleMessageRows[message.id.uuidString] else { return nil }
            return (message, row)
        }
        let selected: [(Message, MessageFilterRow)]
        if projected.count == expectedMessageCount {
            selected = projected
        } else {
            let actionState = ProjectLensActionRepository(modelContext: modelContext)
                .sharedMessageActionState()
            let completeThread = threadMessages.map { message in
                let isReplied = actionState.repliedMessageIDs.contains(message.id)
                    || (actionState.replyNeededMessageIDs.contains(message.id) == false
                        && message.repliedAt != nil)
                let isConfirmed = actionState.confirmedMessageIDs.contains(message.id)
                let needsReply = actionState.replyNeededMessageIDs.contains(message.id)
                    || (message.messageType == .actionable && message.requiresReply && isReplied == false)
                let needsConfirmation = actionState.confirmationNeededMessageIDs.contains(message.id)
                    || (message.messageType == .confirmation && isConfirmed == false)
                let row = visibleMessageRows[message.id.uuidString]
                    ?? ProjectsDataController.messageFilterRow(
                        for: message,
                        date: message.vectorTimeFilterDate ?? message.ingestedAt,
                        customCategoryKeys: Set(CustomCategoryKeysJSON.decode(
                            message.analysis?.customCategoryKeysJSON
                        )),
                        dimensions: nil,
                        triageVerdict: nil,
                        isActionable: needsReply,
                        requiresConfirmation: needsConfirmation,
                        isReplied: isReplied,
                        isConfirmed: isConfirmed,
                        isResolved: actionState.resolvedMessageIDs.contains(message.id)
                    )
                return (message, row)
            }
            let newestFirst = completeThread.sorted { lhs, rhs in
                let lhsDate = lhs.1.receivedAt ?? lhs.1.ingestedAt
                let rhsDate = rhs.1.receivedAt ?? rhs.1.ingestedAt
                return lhsDate > rhsDate
            }
            selected = expectedMessageCount > 0 && newestFirst.count > expectedMessageCount
                ? Array(newestFirst.prefix(expectedMessageCount))
                : newestFirst
        }
        return selected
            .map { message, row in
                var obligations: Set<ProjectOpenObligation.Kind> = []
                if row.isSentByUser == false {
                    if row.requiresConfirmation == true, row.isConfirmed == false {
                        obligations.insert(.confirmation)
                    } else if row.isActionable == true, row.isReplied == false {
                        obligations.insert(.pendingReply)
                    }
                }
                let isRepresentative = message.id == representativeID
                return DeadlineGuideMessageCard(
                    mark: ProjectMessageMark(
                        messageID: message.id,
                        date: row.receivedAt ?? row.ingestedAt,
                        isSentByUser: row.isSentByUser,
                        isRead: row.isRead,
                        isFlagged: row.flagged,
                        isReplied: row.isReplied,
                        isConfirmed: row.isConfirmed,
                        isResolvedByUser: row.isResolved,
                        hasAttachments: row.hasAttachments,
                        hasDeadline: isRepresentative,
                        deadlineText: isRepresentative ? deadlineText : nil,
                        subject: row.subject,
                        obligationKinds: obligations
                    ),
                    filterRow: row
                )
            }
            .sorted { $0.mark.date > $1.mark.date }
    }
}
