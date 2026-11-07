// Ohia/Composer/ComposerQueuePane.swift
// Left pane of the Composer: the queue, which is also the outbox. Every row
// carries workflow information — who, subject, where the draft stands,
// urgency, deadline, send status — and selecting a row loads that item's
// surface (reply flow or compose surface). Per-row buttons + a right-click
// context menu manage the item (open, send now, dismiss, discard), mirroring
// the Constellation locked-node menu idiom.

import SwiftUI
import OhiaCore

/// A management action invoked from a queue row's button or context menu.
/// Reply and compose items share one consistent action set.
enum ComposerQueueAction: Equatable {
    /// Make this the active item in the editor.
    case open
    /// Push a ready draft straight to send (SMTP), bypassing any wait.
    case sendNow
    /// Remove the item: a reply draft is discarded from the queue and provider
    /// Drafts, a compose draft is discarded, an in-flight/failed send is
    /// cancelled.
    case delete
    /// A failed send: requeue it for another delivery attempt.
    case retrySend
}

/// Ordered queue selection shared by the pane and Composer bulk actions.
/// `activeID` is the last row the user acted on; `anchorID` remains stable
/// across Shift-click range extension, matching the Front Page / Projects
/// selection contract.
struct ComposerQueueSelection: Equatable {
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var activeID: UUID?
    private(set) var anchorID: UUID?

    mutating func handleClick(
        id: UUID,
        modifiers: NSEvent.ModifierFlags,
        orderedIDs: [UUID]
    ) {
        if modifiers.contains(.shift) {
            guard let anchorID,
                  let anchorIndex = orderedIDs.firstIndex(of: anchorID),
                  let targetIndex = orderedIDs.firstIndex(of: id) else {
                selectOnly(id)
                return
            }
            let lower = min(anchorIndex, targetIndex)
            let upper = max(anchorIndex, targetIndex)
            selectedIDs = Set(orderedIDs[lower...upper])
            activeID = id
            return
        }

        if modifiers.contains(.command) {
            if selectedIDs.remove(id) != nil {
                if activeID == id {
                    activeID = orderedIDs.last(where: { selectedIDs.contains($0) })
                }
                if anchorID == id {
                    anchorID = orderedIDs.last(where: { selectedIDs.contains($0) })
                }
                if selectedIDs.isEmpty {
                    activeID = nil
                    anchorID = nil
                }
            } else {
                selectedIDs.insert(id)
                activeID = id
                anchorID = id
            }
            return
        }

        selectOnly(id)
    }

    mutating func selectOnly(_ id: UUID) {
        selectedIDs = [id]
        activeID = id
        anchorID = id
    }

    mutating func selectAll(in orderedIDs: [UUID]) {
        guard let first = orderedIDs.first else {
            clear()
            return
        }
        selectedIDs = Set(orderedIDs)
        if activeID == nil || !selectedIDs.contains(activeID!) {
            activeID = first
        }
        anchorID = activeID
    }

    mutating func reconcile(with orderedIDs: [UUID]) {
        let available = Set(orderedIDs)
        selectedIDs.formIntersection(available)
        guard !selectedIDs.isEmpty else {
            clear()
            return
        }
        if activeID == nil || !selectedIDs.contains(activeID!) {
            activeID = orderedIDs.first(where: { selectedIDs.contains($0) })
        }
        if anchorID == nil || !selectedIDs.contains(anchorID!) {
            anchorID = activeID
        }
    }

    mutating func clear() {
        selectedIDs = []
        activeID = nil
        anchorID = nil
    }

    func selectedItems(from items: [ComposerQueueItem]) -> [ComposerQueueItem] {
        items.filter { selectedIDs.contains($0.id) }
    }
}

struct ComposerQueuePane: View {
    let items: [ComposerQueueItem]
    let selectedIDs: Set<UUID>
    let onSelectionClick: (ComposerQueueItem, NSEvent.ModifierFlags) -> Void
    let onSelectAll: () -> Void
    let onNewMessage: () -> Void
    let onAction: (ComposerQueueAction, ComposerQueueItem) -> Void
    /// Open state, toggle, and close chevron for the Queue column.
    var columnControl: ComposerColumnControl?

    /// Row under the pointer; reveals that row's quick-action affordances.
    @State private var hoveredID: UUID?
    @FocusState private var queueIsFocused: Bool

    var body: some View {
        GlassPane(
            accentColor: OhiaColors.chipActiveForeground,
            isForeground: true,
            isFocused: false,
            horizontalPadding: isOpen ? ComposerColumn.openPanePadding : ComposerColumn.railHorizontalPadding
        ) {
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
        // The row under the pointer when the column closed is not under it
        // when the column reopens.
        .onChange(of: isOpen) { hoveredID = nil }
        .focusable()
        .focusEffectDisabled()
        .focused($queueIsFocused)
        .onKeyPress(.init("a"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            onSelectAll()
            return .handled
        }
    }

    private var isOpen: Bool {
        columnControl?.isOpen ?? true
    }

    private var openContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ComposerColumnHeader(control: columnControl, columnTitle: "Queue") {
                ComposerSectionHeader(title: "Queue", symbolName: "tray.full", count: items.count, titleWeight: .bold)
            }

            Button(action: onNewMessage) {
                Label("New Message", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 7, verticalPadding: 5))
            .help("New Message (⌘N)")

            if items.isEmpty {
                OhiaEmptyPaneStateView(
                    systemName: "tray",
                    title: "Nothing queued",
                    detail: "Replies and drafts will appear here."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items) { item in
                            queueRow(item)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rail

    /// The closed Queue: New Message, then one initials circle per queued
    /// item with a dot for where it stands. A circle selects its item like a
    /// row does (⌘ and ⇧ extend the selection) and carries the row's menu.
    private func rail(_ control: ComposerColumnControl) -> some View {
        ComposerColumnRailBody(
            control: control,
            title: "Queue",
            symbolName: "tray.full",
            count: items.count
        ) {
            Button(action: onNewMessage) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(EmblemButtonStyle(horizontalPadding: 7, verticalPadding: 5))
            .help("New Message (⌘N)")
            .accessibilityLabel("New Message")

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        railCircle(item)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder
    private func railCircle(_ item: ComposerQueueItem) -> some View {
        let isSelected = !item.state.isOutbox && selectedIDs.contains(item.id)
        Group {
            if item.state.isOutbox {
                ComposerQueueRailCircle(item: item, isSelected: false)
            } else {
                ComposerQueueRailCircle(item: item, isSelected: isSelected)
                    .contentShape(Circle())
                    .gesture(TapGesture().modifiers(.command).onEnded {
                        queueIsFocused = true
                        onSelectionClick(item, .command)
                    })
                    .gesture(TapGesture().modifiers(.shift).onEnded {
                        queueIsFocused = true
                        onSelectionClick(item, .shift)
                    })
                    .onTapGesture {
                        queueIsFocused = true
                        onSelectionClick(item, [])
                    }
                    .accessibilityAction {
                        queueIsFocused = true
                        onSelectionClick(item, [])
                    }
            }
        }
        .help(ComposerQueueRailCircle.helpText(for: item))
        .contextMenu { ComposerQueueItemMenu(item: item, onAction: onAction) }
        .accessibilityLabel(item.name)
        .accessibilityValue(item.state.label)
        // A send in flight or failed is a status, not a selectable item; its
        // actions live in its menu.
        .accessibilityAddTraits(
            item.state.isOutbox ? [] : (isSelected ? [.isButton, .isSelected] : [.isButton])
        )
    }

    @ViewBuilder
    private func queueRow(_ item: ComposerQueueItem) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        Group {
            if item.state.isOutbox {
                // An in-flight / failed send isn't editable — render it as a
                // static status row (not a tappable selection) so the only
                // affordances are its Retry / Discard actions.
                rowContent(item, isSelected: false)
            } else {
                rowContent(item, isSelected: isSelected)
                    .contentShape(RoundedRectangle(cornerRadius: 4))
                    .gesture(TapGesture().modifiers(.command).onEnded {
                        queueIsFocused = true
                        onSelectionClick(item, .command)
                    })
                    .gesture(TapGesture().modifiers(.shift).onEnded {
                        queueIsFocused = true
                        onSelectionClick(item, .shift)
                    })
                    .onTapGesture {
                        queueIsFocused = true
                        onSelectionClick(item, [])
                    }
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    .accessibilityAction {
                        queueIsFocused = true
                        onSelectionClick(item, [])
                    }
            }
        }
        .onHover { hovering in
            if hovering {
                hoveredID = item.id
            } else if hoveredID == item.id {
                hoveredID = nil
            }
        }
        .contextMenu { ComposerQueueItemMenu(item: item, onAction: onAction) }
    }

    private func rowContent(_ item: ComposerQueueItem, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.name)
                    .font(OhiaTypography.cardTitle)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .lineLimit(1)
                Spacer()
                if item.urgency >= 0.7 && !item.state.isOutbox {
                    Text("urgent")
                        .font(OhiaTypography.cardSignal)
                        .foregroundStyle(isSelected ? OhiaColors.textPrimary : OhiaColors.frameUrgencyHigh)
                }
                if hoveredID == item.id {
                    hoverActions(item)
                }
            }
            .frame(minHeight: 18)
            Text(item.subject)
                .font(OhiaTypography.cardBody)
                .foregroundStyle(isSelected ? OhiaColors.textPrimary : OhiaColors.textSecondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                if item.state.isFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(OhiaColors.frameUrgencyHigh)
                }
                if item.state.showsProgressIndicator {
                    ProgressView()
                        .controlSize(.small)
                        .tint(item.state.tint(isSelected: isSelected))
                        .accessibilityHidden(true)
                }
                Text(item.state.label)
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(item.state.tint(isSelected: isSelected))
                Spacer()
                Text(item.receivedAt, format: .relative(presentation: .named))
                    .font(OhiaTypography.cardSignal)
                    .foregroundStyle(isSelected ? OhiaColors.textPrimary : OhiaColors.textTertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? OhiaColors.chipActiveBackground : OhiaColors.chipRestBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isSelected ? OhiaColors.chipActiveBorder : OhiaColors.chipRestBorder,
                    lineWidth: 1
                )
        }
    }

    /// Quick-action buttons revealed on hover — the same set for reply and
    /// compose. Send is deliberately NOT here: an accidental hover-click would
    /// fire an irreversible send, so sending lives only in the right-click
    /// menu. Retry (failed sends) and Delete remain — both recoverable or
    /// confirmed.
    @ViewBuilder
    private func hoverActions(_ item: ComposerQueueItem) -> some View {
        HStack(spacing: 2) {
            if item.state.isFailed {
                clusterButton(
                    glyph: .native("arrow.clockwise.circle.fill"),
                    help: "Retry",
                    tint: MessageStatusColors.pendingReply
                ) {
                    onAction(.retrySend, item)
                }
            }
            clusterButton(
                glyph: .native("xmark.bin.circle.fill"),
                help: "Delete",
                tint: OhiaColors.ohiaRed
            ) {
                onAction(.delete, item)
            }
        }
    }

    /// Inline message-status action chip (§3.10): a compact circle-family glyph
    /// rendered through the shared `ActionDiscGlyphView` with no chrome, matching
    /// the Front Page card hover cluster. The `.help` tooltip carries the label
    /// since the chip shows no gloss text.
    private func clusterButton(
        glyph: ActionDiscGlyph,
        help: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        ClusterButtonChip(glyph: glyph, tint: tint, help: help, action: action)
    }
}

/// The management menu a queued item carries, on its row and on its rail
/// circle alike.
struct ComposerQueueItemMenu: View {
    let item: ComposerQueueItem
    let onAction: (ComposerQueueAction, ComposerQueueItem) -> Void

    var body: some View {
        let hasPrimaryAction = !item.state.isOutbox || item.state.isSendable || item.state.isFailed
        if !item.state.isOutbox {
            Button("Open in Composer") { onAction(.open, item) }
        }
        if item.state.isSendable {
            Button("Send Now") { onAction(.sendNow, item) }
        }
        if item.state.isFailed {
            Button("Retry Send") { onAction(.retrySend, item) }
        }
        if hasPrimaryAction {
            Divider()
        }
        Button("Delete", role: .destructive) { onAction(.delete, item) }
    }
}

/// One queued item on the closed Queue's rail: the correspondent's initials
/// in a circle, lit when selected, with a corner mark for where the item
/// stands — a spinning arc while work runs, otherwise a dot in the row's
/// state color.
struct ComposerQueueRailCircle: View {
    static let diameter: CGFloat = 30

    let item: ComposerQueueItem
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle()
                    .fill(isSelected ? OhiaColors.chipActiveBackground : OhiaColors.chipRestBackground)
                Circle()
                    .strokeBorder(
                        isSelected ? OhiaColors.chipActiveForeground : OhiaColors.chipRestBorder,
                        lineWidth: isSelected ? 1.5 : 1
                    )
                Group {
                    if let initials {
                        Text(initials)
                            .font(.system(size: 10.5, weight: .semibold))
                            .minimumScaleFactor(0.62)
                    } else {
                        // A compose draft with no recipient yet, or a sender
                        // with neither name nor address.
                        Image(systemName: "person.fill.questionmark")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(isSelected ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary)
                .padding(.horizontal, 3)
            }
            .frame(width: Self.diameter, height: Self.diameter)

            stateMark
                .offset(x: 3, y: 2)
        }
        .frame(width: Self.diameter + 6, height: Self.diameter + 2)
        .accessibilityElement(children: .ignore)
    }

    /// The circle's letters, or nil when there is no one to name.
    private var initials: String? {
        guard item.name != ComposerQueueItem.noRecipientName else { return nil }
        let letters = ComposerPersonInitials.initials(name: item.name, email: item.name)
        return letters.isEmpty ? nil : letters
    }

    @ViewBuilder
    private var stateMark: some View {
        let tint = item.state.tint(isSelected: false)
        ZStack {
            Circle()
                .fill(OhiaColors.composerRaisedPanelBackground)
            if item.state.showsProgressIndicator {
                ComposerRailSpinner(tint: tint)
                    .padding(2)
            } else {
                Circle()
                    .fill(tint)
                    .padding(2)
            }
        }
        .frame(width: 11, height: 11)
        .accessibilityHidden(true)
    }

    /// Who, what, and where it stands, for the circle's tooltip.
    static func helpText(for item: ComposerQueueItem) -> String {
        [item.name, item.subject, item.state.label]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

extension ComposerQueueItem.WorkState {
    /// The color a queued item's state reads in: its row's status line and
    /// its rail circle's dot. A selected row reads in the primary text color.
    func tint(isSelected: Bool) -> Color {
        if isSelected { return OhiaColors.textPrimary }
        switch self {
        case .awaitingDecisions: return OhiaColors.textSecondary
        case .readyToDraft: return OhiaColors.chipActiveForeground
        case .sourcesReady: return OhiaColors.textSecondary
        case .sourcePreparationFailed: return OhiaColors.frameUrgencyHigh
        case .sourcesNotPrepared: return OhiaColors.textTertiary
        case .curatingSources: return OhiaColors.textSecondary
        case .evaluatingSources: return OhiaColors.iconPillForeground
        case .researchingSources: return OhiaColors.iconPillForeground
        case .draftReady: return OhiaColors.chipActiveForeground
        case .preparingEvidence: return OhiaColors.iconPillForeground
        case .generationBlocked: return OhiaColors.frameUrgencyHigh
        case .writing: return OhiaColors.iconPillForeground
        case .queued: return OhiaColors.textTertiary
        case .composeDraft: return OhiaColors.chipActiveForeground
        case .queuedToSend, .sending: return OhiaColors.iconPillForeground
        case .failed: return OhiaColors.frameUrgencyHigh
        }
    }
}
