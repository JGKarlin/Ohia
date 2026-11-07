// WithheldDrawerView.swift
// The Withheld — standalone slide-in drawer (Junk & Trash), its own surface.
//
// Withheld mail is live and never ingested, so it carries only envelope / header /
// flag metadata — no vectors, no datafication. It therefore does NOT reuse the
// constellation lens, toolbar, Ask, or Search. It lives in the split layout on
// the edge opposite the Ask/Search sidebar, reserving scene space the same way.
//
// The drawer owns rudimentary controls (scope · sort · account · compact filters)
// and a LINEAR substring search (sender + subject), over a single-column Ledger of
// withdrawn surfaces with push-to-detail. Tapping a row slides in the contested
// inscription (live body peek + decomposed header signals + Not Junk / Restore).
// Promotion is the only path into the corpus (wired in Phase B; disabled here).
//
// Styling routes entirely through OhiaColors / OhiaTypography / EmblemButtonStyle;
// withheld surfaces read DIM / WITHDRAWN, never lurid red. Components and display
// helpers are file-private for Phase A; Phase C extracts the shared pieces (and the
// beacon affordance) when it reuses them.

import AppKit
import Combine
import SwiftUI
import OhiaCore
import OhiaMail

struct WithheldDrawerView: View {
    @Bindable var model: WithheldDrawerModel
    /// Promote a row out of Junk/Trash into the corpus. Wired in Phase B; the
    /// affordance is present-but-disabled in Phase A.
    var onPromote: (WithheldRow) -> Void
    var actions = WithheldMessageActionHandlers()
    var onDragBegan: () -> Void = {}
    var onClose: () -> Void
    var allowsEscapeBack: Bool = true
    /// Triggered when the drawer appears — drives the live, read-only fetch.
    var onLoad: () async -> Void = {}

    @State private var sortMenuPresented = false
    @State private var accountMenuPresented = false

    var body: some View {
        VStack(spacing: 0) {
            if let selected = model.selectedRow {
                WithheldDetailView(
                    row: selected,
                    bodyText: model.bodyTextByID[selected.id],
                    isLoadingBody: model.bodyLoadingID == selected.id,
                    isPromoting: model.promotingID == selected.id,
                    promoteError: model.promoteErrors[selected.id],
                    onPromote: onPromote,
                    onClose: onClose,
                    allowsEscapeBack: allowsEscapeBack,
                    onBack: { model.selectedID = nil }
                )
            } else {
                listMode
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OhiaColors.spaceBackground)
        .background(
            WithheldOutsideSelectionClearer {
                guard !model.selectedRowIDs.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    model.clearSelection()
                }
            }
        )
        .task(id: model.selectedID) {
            if let row = model.selectedRow { await model.body(for: row) }
        }
        .task { await onLoad() }
    }

    // MARK: List mode

    private var listMode: some View {
        VStack(spacing: 0) {
            header
            controls
            Divider().overlay(OhiaColors.glassBorder)
            if model.isLoading && model.rows.isEmpty {
                loadingState
            } else if model.visibleRows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleRows) { row in
                            WithheldLedgerRow(
                                row: row,
                                inscriptionLine: model.ledgerLine(for: row),
                                showsFolderTag: model.scope == .all,
                                isSelected: model.isSelected(row.id),
                                isPromoting: model.promotingID == row.id,
                                dragPayload: WithheldRowDragPayload(rowIDs: model.dragRowIDs(startingAt: row)),
                                onSelectClick: { modifiers in
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        model.handleSelectionClick(
                                            id: row.id,
                                            modifiers: modifiers,
                                            orderedIDs: model.visibleRows.map(\.id)
                                        )
                                    }
                                },
                                onClearSelection: {
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        model.clearSelection()
                                    }
                                },
                                onOpen: { model.selectedID = row.id },
                                onPresentMenu: { point, view in
                                    presentRowMenu(row: row, point: point, view: view)
                                },
                                onDragBegan: onDragBegan,
                                onPromote: { onPromote(row) },
                                onDelete: { actions.deletePermanently([row]) }
                            )
                            Rectangle().fill(OhiaColors.glassBorder).frame(height: 1).padding(.leading, WithheldLedgerRow.textColumnLeadingInset)
                        }
                    }
                }
            }
        }
    }

    private func presentRowMenu(row: WithheldRow, point: NSPoint, view: NSView) {
        let rows = model.actionRows(startingAt: row)
        WithheldMessageContextMenu.present(
            at: point,
            in: view,
            context: WithheldMessageContextMenu.Context(
                rows: rows,
                onRestore: { actions.restore(rows) },
                onSelectAll: {
                    model.selectAllVisible()
                    actions.selectAll()
                },
                onSetRead: { value in actions.setRead(rows, value) },
                onDeletePermanently: { actions.deletePermanently(rows) }
            )
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            scopeChips
            Spacer(minLength: 8)
            SidebarPanelChromeButtons(
                closeLabel: "Close Junk/Trash",
                onClose: onClose
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // Scope as three INDIVIDUAL selectable chips (not one connected segmented bar),
    // each carrying its count. Single-select — All / Junk / Trash are mutually
    // exclusive scopes, so the active one reads in the accent.
    private var scopeChips: some View {
        HStack(spacing: 6) {
            ForEach(WithheldScope.allCases) { scope in
                let isOn = model.scope == scope
                Button { model.scope = scope } label: {
                    HStack(spacing: 4) {
                        Image(systemName: scope.icon).font(.system(size: 9.5, weight: isOn ? .semibold : .regular))
                        Text("\(scope.title) (\(model.count(for: scope)))")
                            .font(.system(size: 10.5, weight: isOn ? .semibold : .regular))
                    }
                    .foregroundStyle(isOn ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? OhiaColors.chipActiveBackground : OhiaColors.chipRestBackground))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isOn ? OhiaColors.chipActiveBorder : OhiaColors.chipRestBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            SearchField(query: $model.query, isSearching: model.isSearching, onSubmit: { Task { await model.search() } })
            HStack(spacing: 6) {
                sortChip
                accountChip
                FilterChip(label: "Unread", icon: "envelope", isOn: model.unreadOnly) { model.unreadOnly.toggle() }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var sortChip: some View {
        Button {
            sortMenuPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 9, weight: .medium))
                Text(model.effectiveSort.title).font(.system(size: 10.5, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .medium))
            }
            .foregroundStyle(OhiaColors.chipActiveForeground)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(OhiaColors.chipActiveBackground))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $sortMenuPresented, arrowEdge: .bottom) {
            sortPicker
        }
        .fixedSize()
        .accessibilityLabel("Sort")
    }

    private var sortPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.availableSorts) { option in
                Button {
                    model.sort = option
                    sortMenuPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Text(option.title)
                            .font(.system(size: 12))
                        Spacer()
                        if option == model.effectiveSort {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundStyle(OhiaColors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minWidth: 140, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    // Account SCOPE (not a category — withheld mail has none): a pulldown over the
    // user's accounts, defaulting to all. Populated at load time (Task 8).
    private var accountChip: some View {
        Button {
            accountMenuPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2").font(.system(size: 9, weight: .medium))
                Text(accountLabel).font(.system(size: 10.5, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .medium))
            }
            .foregroundStyle(accountChipForeground)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(accountChipBackground))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(accountChipBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $accountMenuPresented, arrowEdge: .bottom) {
            accountPicker
        }
        .fixedSize()
    }

    private var accountPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.accountFilter = nil
                accountMenuPresented = false
            } label: {
                HStack(spacing: 8) {
                    Text("All accounts")
                        .font(.system(size: 12))
                    Spacer()
                    if model.accountFilter == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundStyle(OhiaColors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minWidth: 180, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !model.accountOptions.isEmpty {
                Divider().overlay(OhiaColors.glassBorder)
                ForEach(model.accountOptions) { opt in
                    Button {
                        model.accountFilter = opt.id
                        accountMenuPresented = false
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(AccountColorPalette.color(forIndex: opt.colorIndex).swiftUIColor)
                                .frame(width: 8, height: 8)
                            Text(opt.name)
                                .font(.system(size: 12))
                            Spacer()
                            if model.accountFilter == opt.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        .foregroundStyle(OhiaColors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(minWidth: 180, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var accountLabel: String {
        if let opt = selectedAccountOption {
            return opt.name
        }
        return "All accounts"
    }

    private var selectedAccountOption: WithheldAccountOption? {
        guard let id = model.accountFilter else { return nil }
        return model.accountOptions.first(where: { $0.id == id })
    }

    // Ohia yellow for "All accounts"; the selected account's stellar color otherwise.
    private var accountChipForeground: Color {
        if let opt = selectedAccountOption {
            return AccountColorPalette.color(forIndex: opt.colorIndex).swiftUIColor
        }
        return OhiaColors.ohiaYellow
    }

    private var accountChipBackground: Color {
        if let opt = selectedAccountOption {
            return AccountColorPalette.color(forIndex: opt.colorIndex).swiftUIColor.opacity(0.18)
        }
        return OhiaColors.chipActiveBackground
    }

    private var accountChipBorder: Color {
        if let opt = selectedAccountOption {
            return AccountColorPalette.color(forIndex: opt.colorIndex).swiftUIColor.opacity(0.60)
        }
        return OhiaColors.chipActiveBorder
    }

    // Shown on first open while the transient IMAP fetch is in flight and no rows
    // have arrived yet — distinct from the empty state, which otherwise reads as
    // "you have no withheld mail" during the load.
    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading withheld mail")
                .font(.system(size: 12))
                .foregroundStyle(OhiaColors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if !model.loadErrors.isEmpty {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(OhiaColors.textTertiary)
                Text("Couldn't load some accounts")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OhiaColors.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.loadErrors.sorted { $0.key.uuidString < $1.key.uuidString }, id: \.key) { _, message in
                        Text(message)
                            .font(.system(size: 10.5))
                            .foregroundStyle(OhiaColors.textDim)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 24)
            } else {
                OhiaEmptyPaneStateView(
                    systemName: "tray",
                    title: "No withheld mail matches",
                    detail: "Adjust the current scope or filters to bring withheld mail into view."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WithheldOutsideSelectionClearer: NSViewRepresentable {
    var onOutsideClick: @MainActor () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.focusRingType = .none
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onOutsideClick = onOutsideClick
    }

    final class CatcherView: NSView {
        var onOutsideClick: (@MainActor () -> Void)?
        private var leftMouseMonitor: Any?

        override var acceptsFirstResponder: Bool { false }
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                tearDownMonitor()
            } else if leftMouseMonitor == nil {
                installMonitor()
            }
        }

        deinit {
            tearDownMonitor()
        }

        private func installMonitor() {
            leftMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let pointInView = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(pointInView), let handler = self.onOutsideClick {
                    DispatchQueue.main.async {
                        handler()
                    }
                }
                return event
            }
        }

        private func tearDownMonitor() {
            if let leftMouseMonitor {
                NSEvent.removeMonitor(leftMouseMonitor)
                self.leftMouseMonitor = nil
            }
        }
    }
}

// MARK: - Option-key hover monitor

/// Tracks whether the Option key is held while the cursor is over a Withheld row,
/// driving the live restore↔delete swap of the row's hover quick-action. A local
/// `flagsChanged` monitor is installed only while the row is hovered — so at most
/// one monitor is live (only one row is hovered at a time) — and torn down on
/// hover-exit. Mirrors the local-monitor pattern in `WithheldOutsideSelectionClearer`.
private final class OptionKeyHoverMonitor: ObservableObject {
    @Published private(set) var isOptionHeld = false
    private var monitor: Any?

    /// Seed from the current modifier state (so an Option already held when the
    /// cursor enters reads immediately) and begin tracking live changes.
    func begin() {
        isOptionHeld = NSEvent.modifierFlags.contains(.option)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // `.flagsChanged` fires for every modifier; publish only when the
            // Option state actually flips, so holding Shift/⌘ over a hovered row
            // doesn't churn the row's view tree.
            let held = event.modifierFlags.contains(.option)
            if let self, self.isOptionHeld != held { self.isOptionHeld = held }
            return event
        }
    }

    func end() {
        tearDown()
        isOptionHeld = false
    }

    deinit {
        tearDown()
    }

    private func tearDown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// MARK: - Ledger row (single column, withdrawn)

private struct WithheldLedgerRow: View {
    let row: WithheldRow
    /// Plain-language rescue hint for this row (resolved by the model against
    /// corpus signals; one line).
    let inscriptionLine: String?
    let showsFolderTag: Bool
    let isSelected: Bool
    let isPromoting: Bool
    let dragPayload: WithheldRowDragPayload
    let onSelectClick: (NSEvent.ModifierFlags) -> Void
    let onClearSelection: () -> Void
    let onOpen: () -> Void
    let onPresentMenu: (NSPoint, NSView) -> Void
    let onDragBegan: () -> Void
    let onPromote: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var pendingPlainSelectionClear = false
    @StateObject private var optionMonitor = OptionKeyHoverMonitor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: Self.contentSpacing) {
            // Left gutter — reserves the row's leading slot for the restore
            // button overlaid here (vertically centered against the row). Kept
            // non-hit-testing so the empty gutter never intercepts the row's own
            // click / drag handling.
            Color.clear
                .frame(width: Self.restoreGutterWidth)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // Read/unread status dot in the accent color, sitting just
                    // left of the folder tag (filled = unread, hollow ring = read).
                    WithdrawnGlyph(isUnread: !row.isRead)
                    if showsFolderTag { FolderTag(folder: row.folder) }
                    Text(displaySender)
                        .font(.system(size: 13, weight: row.isRead ? .regular : .semibold))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .lineLimit(1)
                    if row.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 9))
                            .foregroundStyle(OhiaColors.textDim)
                    }
                    Spacer(minLength: 8)
                    Text(compactAge(row.date)).font(.system(size: 10.5)).foregroundStyle(OhiaColors.textTertiary)
                }
                Text(row.subject)
                    .font(.system(size: 12))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .lineLimit(1)
                if let inscriptionLine {
                    InscriptionTag(text: inscriptionLine)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OhiaColors.textDim)
                .padding(.top, 2)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 11)
        .background(rowBackground)
        .overlay { rowBorder.allowsHitTesting(false) }
        .contentShape(Rectangle())
        .background(
            TimelineEventCatcher(
                onLeftClick: { _, _, modifiers in handleLeftClick(modifiers) },
                onRightClick: { point, view in onPresentMenu(point, view) },
                onDoubleClick: { _, _ in onOpen() }
            )
        )
        .onTapGesture {
            finishPlainTapIfNeeded()
        }
        .onDrag {
            pendingPlainSelectionClear = false
            onDragBegan()
            return dragPayload.itemProvider
        } preview: {
            dragPreview
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Double-click to open message details")
        .overlay(alignment: .leading) { quickActionAffordance }
        .onHover { hovering in
            if hovering { optionMonitor.begin() } else { optionMonitor.end() }
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeInOut(duration: 0.12)) { isHovered = hovering }
            }
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? OhiaColors.chipActiveBackground.opacity(0.16) : Color.clear)
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(
                isSelected
                    ? OhiaColors.chipActiveBorder
                    : (isHovered ? OhiaColors.chipActiveBorder.opacity(0.42) : Color.clear),
                lineWidth: isSelected ? 2 : 1
            )
    }

    private var dragPreview: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11, weight: .medium))
            Text(dragPayload.rowIDs.count == 1 ? "Restore" : "Restore (\(dragPayload.rowIDs.count))")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(OhiaColors.chipActiveForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(OhiaColors.chipRestBackground))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OhiaColors.chipActiveBorder, lineWidth: 1))
    }

    /// Row geometry constants. Kept named (not inline literals) so the leading
    /// restore gutter, the overlaid button's alignment padding, and the inter-row
    /// divider inset all derive from one source and can't drift apart.
    static let horizontalPadding: CGFloat = 14
    static let contentSpacing: CGFloat = 10
    /// Width of the row's leading gutter — both the reserved `Color.clear` slot
    /// in the layout and the hover chip's tap target overlaid into it. The chip
    /// is sized to fill this exactly, so trimming it tightens the space flanking
    /// the restore/delete glyph.
    static let restoreGutterWidth: CGFloat = 22
    /// Leading inset that lines a full-bleed element (the inter-row divider) up
    /// with the start of the row's text column, past the restore gutter.
    static let textColumnLeadingInset: CGFloat = horizontalPadding + restoreGutterWidth + contentSpacing

    /// Hover quick-action occupying the row's leading slot (where the read/unread
    /// dot used to sit), vertically centered against the row. Hidden at rest —
    /// it fades in only while the row is hovered — and rendered as the shared
    /// §3.10 `ClusterButtonChip`: the **restore** chip (green) by default, swapped
    /// live to the **delete** chip (red) while the Option key is held. During an
    /// in-flight promotion it shows a spinner in the same slot regardless of hover
    /// so the restore stays visible if the cursor moves away.
    @ViewBuilder private var quickActionAffordance: some View {
        Group {
            if isPromoting {
                ProgressView().controlSize(.small)
            } else if isHovered {
                quickActionChip
                    .transition(.opacity)
            }
        }
        .frame(width: Self.restoreGutterWidth)
        // Align the overlaid chip with the reserved gutter, which begins after
        // the row's leading padding.
        .padding(.leading, Self.horizontalPadding)
        .allowsHitTesting(!isPromoting)
        // Sit above the row's tap gesture so a tap on the chip acts on the row
        // rather than navigating to detail.
        .zIndex(1)
    }

    /// The hover chip itself: restore by default, delete while Option is held. The
    /// `ClusterButtonChip` carries its own hover ring / lift / two-tone fill, so
    /// the disc stays put and only the inner icon, ring, and lift move on hover —
    /// green→yellow for restore, red→yellow for delete (the §3.10 hover-fill map).
    @ViewBuilder private var quickActionChip: some View {
        if optionMonitor.isOptionHeld {
            ClusterButtonChip(
                glyph: .native("trash.circle.fill"),
                tint: OhiaColors.ohiaRed,
                help: "Delete Permanently",
                width: Self.restoreGutterWidth,
                action: onDelete
            )
        } else {
            ClusterButtonChip(
                glyph: row.folder.promoteGlyph,
                tint: OhiaColors.ohiaGreen,
                help: row.folder.promoteVerb,
                width: Self.restoreGutterWidth,
                action: onPromote
            )
        }
    }

    private var displaySender: String {
        row.sender.isEmpty ? row.senderAddress : row.sender
    }

    private var accessibilityLabelText: String {
        if let inscriptionLine, !inscriptionLine.isEmpty {
            return "\(displaySender), \(row.subject), \(inscriptionLine)"
        }
        return "\(displaySender), \(row.subject)"
    }

    private func handleLeftClick(_ modifiers: NSEvent.ModifierFlags) {
        pendingPlainSelectionClear = isSelected && isPlainSelectionClick(modifiers)
        onSelectClick(modifiers)
    }

    private func finishPlainTapIfNeeded() {
        guard pendingPlainSelectionClear else { return }
        pendingPlainSelectionClear = false
        onClearSelection()
    }

    private func isPlainSelectionClick(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.contains(.shift)
            && !modifiers.contains(.command)
            && !modifiers.contains(.control)
    }
}

// MARK: - Push-to-detail (contested inscription)

private struct WithheldDetailView: View {
    let row: WithheldRow
    let bodyText: String?
    let isLoadingBody: Bool
    let isPromoting: Bool
    let promoteError: String?
    var onPromote: (WithheldRow) -> Void
    var onClose: () -> Void
    let allowsEscapeBack: Bool
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OhiaColors.ohiaYellow)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Withheld list")
                FolderTag(folder: row.folder)
                Spacer(minLength: 0)
                SidebarPanelChromeButtons(
                    closeLabel: "Close Junk/Trash",
                    onClose: onClose
                )
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().overlay(OhiaColors.glassBorder)

            ScrollView {
                WithheldContestedInscription(
                    row: row, bodyText: bodyText, isLoadingBody: isLoadingBody,
                    isPromoting: isPromoting, promoteError: promoteError, onPromote: onPromote
                )
                .padding(16)
            }
        }
        .background {
            if allowsEscapeBack {
                escBackButton
            }
        }
    }

    private var escBackButton: some View {
        Button(action: onBack) {
            EmptyView()
        }
        .keyboardShortcut(.cancelAction)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WithheldContestedInscription: View {
    let row: WithheldRow
    let bodyText: String?
    let isLoadingBody: Bool
    let isPromoting: Bool
    let promoteError: String?
    var onPromote: (WithheldRow) -> Void

    @Environment(\.readingTextSize) private var readingTextSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    WithdrawnGlyph(isUnread: !row.isRead)
                    Text(row.sender.isEmpty ? row.senderAddress : row.sender)
                        .font(readingTextSize.font(base: 13, weight: .semibold, maximumScale: 1.35))
                        .foregroundStyle(OhiaColors.textPrimary).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(compactAge(row.date))
                        .font(readingTextSize.font(base: 10.5, maximumScale: 1.35))
                        .foregroundStyle(OhiaColors.textTertiary)
                }
                Text(row.senderAddress)
                    .font(readingTextSize.font(base: 10.5, maximumScale: 1.35))
                    .foregroundStyle(OhiaColors.textTertiary)
                    .lineLimit(1)
                Text(row.subject)
                    .font(readingTextSize.font(base: 16, weight: .semibold, maximumScale: 1.20))
                    .foregroundStyle(OhiaColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            bodySection

            VStack(alignment: .leading, spacing: 6) {
                Text(row.folder.withheldCaption)
                    .font(OhiaTypography.telemetrySectionCaps)
                    .foregroundStyle(OhiaColors.textTertiary)
                let signals = WithheldSignals.inspector(for: row)
                if signals.isEmpty {
                    Text("No header signals")
                        .font(.system(size: 10.5))
                        .foregroundStyle(OhiaColors.textDim)
                } else {
                    FlowSignals(signals: signals)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(OhiaColors.surface(0.04)))

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button { onPromote(row) } label: {
                        if isPromoting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(row.folder.promoteVerb, systemImage: row.folder.promoteIcon)
                                .font(OhiaTypography.button)
                        }
                    }
                    .buttonStyle(EmblemButtonStyle(tint: OhiaColors.ohiaGreen, horizontalPadding: 12, verticalPadding: 7))
                    .disabled(isPromoting)
                    // Keep a stable VoiceOver label across both states: while promoting,
                    // the label is a bare spinner, so without this the button would read
                    // as unlabeled. The "in progress" value cues the in-flight state.
                    .accessibilityLabel(row.folder.promoteVerb)
                    .accessibilityValue(isPromoting ? "In progress" : "")
                }
                if let promoteError {
                    Text(promoteError)
                        .font(.system(size: 10.5))
                        .foregroundStyle(OhiaColors.ohiaRed)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var bodySection: some View {
        if let bodyText, !bodyText.isEmpty {
            Text(bodyText)
                .font(readingTextSize.font(base: 12.5))
                .foregroundStyle(OhiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if isLoadingBody {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading message").font(.system(size: 11.5)).foregroundStyle(OhiaColors.textTertiary)
            }
        } else {
            Text("No message body").font(.system(size: 11.5)).foregroundStyle(OhiaColors.textDim)
        }
    }
}

// MARK: - Small components (file-private; Phase C extracts shared ones)

private struct WithdrawnGlyph: View {
    /// Unread → filled accent dot; read → hollow accent ring. Always rendered in
    /// the Ohia accent (yellow on dark, green on light) via `chipActiveForeground`.
    var isUnread: Bool = false
    var body: some View {
        Circle()
            .strokeBorder(OhiaColors.chipActiveForeground.opacity(isUnread ? 0 : 0.6), lineWidth: 1)
            .background(Circle().fill(isUnread ? OhiaColors.chipActiveForeground : Color.clear))
            .frame(width: 8, height: 8)
    }
}

private struct FolderTag: View {
    let folder: WithheldFolderRole
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: folder.tagIcon).font(.system(size: 8, weight: .regular))
            Text(folder.tagTitle).font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(OhiaColors.textTertiary)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 3).fill(OhiaColors.surface(0.05)))
    }
}

/// The ledger row's plain-language signal line (why this message might matter).
private struct InscriptionTag: View {
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "questionmark.diamond")
                .font(.system(size: 8.5))
                .foregroundStyle(OhiaColors.textDim)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 9.5))
                .foregroundStyle(OhiaColors.textTertiary)
                .lineLimit(1)
        }
    }
}

private struct SignalChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9.5)).foregroundStyle(OhiaColors.textTertiary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(OhiaColors.chipRestBackground))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1))
    }
}

private struct FlowSignals: View {
    let signals: [String]
    var body: some View {
        WrappingChipStack(horizontalSpacing: 5, verticalSpacing: 5) {
            ForEach(signals, id: \.self) { SignalChip(text: $0) }
        }
    }
}

private struct SearchField: View {
    @Binding var query: String
    /// True while the on-submit server header-search is in flight; shows a spinner in
    /// the trailing slot so the keyboard search reads as "working", not "did nothing".
    var isSearching: Bool = false
    var onSubmit: () -> Void = {}
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(OhiaColors.textTertiary)
            TextField("Search sender or subject", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(OhiaColors.textPrimary)
                .onSubmit(onSubmit)
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(OhiaColors.textDim)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(OhiaColors.chipRestBackground))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OhiaColors.chipRestBorder, lineWidth: 1))
    }
}

private struct FilterChip: View {
    let label: String
    let icon: String?
    let isOn: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: isOn ? .semibold : .regular)) }
                Text(label).font(.system(size: 10.5, weight: isOn ? .semibold : .regular))
            }
            .foregroundStyle(isOn ? OhiaColors.chipActiveForeground : OhiaColors.textSecondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? OhiaColors.chipActiveBackground : OhiaColors.chipRestBackground))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isOn ? OhiaColors.chipActiveBorder : OhiaColors.chipRestBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Display helpers (file-private)

private extension WithheldScope {
    var title: String { switch self { case .all: "All"; case .junk: "Junk"; case .trash: "Trash" } }
    var icon: String { switch self { case .all: "tray.2"; case .junk: "xmark.bin"; case .trash: "trash" } }
}

private extension WithheldSort {
    var title: String {
        switch self { case .date: "Date"; case .sender: "Sender"; case .spam: "Spam score"; case .subject: "Subject" }
    }
}

private extension WithheldFolderRole {
    var tagTitle: String { self == .junk ? "Junk" : "Trash" }
    var tagIcon: String { self == .junk ? "xmark.bin" : "trash" }
    var promoteVerb: String { self == .junk ? "Not Junk" : "Restore" }
    var promoteIcon: String { self == .junk ? "tray.and.arrow.down" : "arrow.uturn.backward" }
    /// Circle-family glyph for the row's hover restore affordance, matching the
    /// Front Page cluster buttons. Both Junk and Trash use the same clean native
    /// "put back" undo arrow (the knocked-out tray glyph read poorly); the
    /// folder-specific meaning is carried by the tooltip/verb ("Not Junk" vs
    /// "Restore").
    var promoteGlyph: ActionDiscGlyph {
        .native("arrow.uturn.backward.circle.fill")
    }
    var withheldCaption: String { self == .junk ? "WITHHELD BY SPAM FILTER" : "REMOVED TO TRASH" }
}

/// Terse relative age ("now" / "2m" / "1h" / "4d" / "3w" / "5mo" / "2y") for the
/// withdrawn register. Old Trash can be months or years old, so the scale steps up
/// past days into weeks, months, then years — no decimals, no ellipses.
private func compactAge(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let seconds = max(0, now.timeIntervalSince(date))
    let day = 86400.0
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < day { return "\(Int(seconds / 3600))h" }
    let days = seconds / day
    if days < 7 { return "\(Int(days))d" }
    if days < 56 { return "\(Int(days / 7))w" }              // up to ~8 weeks → weeks
    // Cap the month bucket at "11mo" so it never reads "12mo" the day before "1y".
    if days < 365 { return "\(max(1, min(11, Int(days / 30))))mo" }
    return "\(Int(days / 365))y"
}
