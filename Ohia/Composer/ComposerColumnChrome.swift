// Ohia/Composer/ComposerColumnChrome.swift
// The Composer's four columns (Queue, Sources, the Draft stage, and Style)
// share one header line. The side columns (Queue, Sources, Style) can each be
// closed to a narrow rail of icons and buttons; the stage column always stays
// open. A column opens and closes the way the Ask and Junk/Trash drawers
// slide (`ComposerColumnSlide`). Open state persists in user defaults, so a
// column the user closed stays closed for every later Composer message. The
// View › Composer Columns menu toggles the same defaults keys. The columns'
// order is `ComposerColumnOrder`.

import AppKit
import SwiftUI

/// A Composer column the user can close to a rail. The Draft stage column is
/// deliberately absent: it is the working surface and never closes.
enum ComposerColumn: String, CaseIterable, Identifiable {
    case queue
    case sources
    case style

    var id: String { rawValue }

    /// Defaults key holding whether the column is open (default true).
    var openStorageKey: String { "composerColumnOpen.\(rawValue)" }

    /// Menu-bar label and column title.
    var menuTitle: String {
        switch self {
        case .queue: "Queue"
        case .sources: "Sources"
        case .style: "Style"
        }
    }

    /// ⌃⌘ letter that toggles the column. The Constellation shortcut groups
    /// own the digits, and macOS reserves ⌃⌘Q, ⌃⌘F, and ⌃⌘D.
    var shortcutKey: KeyEquivalent {
        switch self {
        case .queue: "u"
        case .sources: "s"
        case .style: "y"
        }
    }

    var shortcutGlyph: String { "⌃⌘\(String(shortcutKey.character).uppercased())" }

    static let shortcutModifiers: EventModifiers = [.control, .command]

    /// Width of a closed column's rail.
    static let railWidth: CGFloat = 52

    /// Width a rail's controls lay out in, inside its pane inset.
    static let railContentWidth: CGFloat = 44

    /// The column name under a rail's icon, set small enough that the longest
    /// title ("Sources") fits the rail on one line.
    static let railTitleFont = Font.system(size: 9, weight: .bold)

    /// Width of the open column.
    var openWidth: CGFloat {
        switch self {
        case .queue: 290
        case .sources: 250
        case .style: 250
        }
    }

    /// Horizontal inset of an open column's pane.
    static let openPanePadding: CGFloat = 12

    /// How far down an open column the pointer shows the column's grabber:
    /// the pane's top inset, the header line, and a little below it.
    static let headerGrabBand: CGFloat = 12 + headerHeight + 8

    /// The same for a rail: the pane's top inset and the rail's header (icon,
    /// name, count, chevron).
    static let railGrabBand: CGFloat = 96

    /// Width the open column's content lays out in, inside its pane inset.
    var openContentWidth: CGFloat { openWidth - 2 * Self.openPanePadding }

    /// How far the open content moves as the column opens or closes: the
    /// pane's change in width less the change in its inset, so the content's
    /// pinned edge keeps the same inset from the pane's moving edge.
    var slideTravel: CGFloat {
        (openWidth - Self.railWidth) - (Self.openPanePadding - Self.railHorizontalPadding)
    }

    /// One direction of an open or close, matching the Ask and Junk/Trash
    /// drawers (`ConstellationSidebarContainer.slideDuration`).
    static let slideDuration: Double = 1.0

    /// The width change of an open or close: the drawers' ease-in-out cubic
    /// over `slideDuration`.
    static let slideAnimation = Animation.timingCurve(0.65, 0, 0.35, 1, duration: slideDuration)

    /// Columns trading places, by drag or by a move command; the drawers'
    /// toggle spring.
    static let reorderAnimation = Animation.spring(response: 0.32, dampingFraction: 0.82)

    /// Height of the header line every column shares, so the four titles sit
    /// on one line. A trailing status that wraps (a long working or blocked
    /// reason) may grow its own header downward rather than be cut off; the
    /// title stays on the shared line.
    static let headerHeight: CGFloat = 24

    /// A column toggle from the menu bar must not tear down a column while a
    /// sheet or alert is attached to the Composer window: the sheet's
    /// presenter lives inside the column, and closing it would discard
    /// whatever the sheet holds.
    @MainActor
    static var isWindowModalPresentationActive: Bool {
        NSApp.keyWindow?.sheetParent != nil || NSApp.modalWindow != nil
    }
}

/// Where the pointer is among the Composer's columns. Space acts on the
/// column under it; the View › Composer Columns moves act on the column it
/// was last over, so they still work when the pointer has gone up to the menu
/// bar. Owned by `ComposerView` and written by each column's
/// `ComposerColumnDragHandle` as the pointer crosses it; only the chevrons and
/// the menu read it, so the Composer itself does not re-render as the pointer
/// moves.
@Observable
final class ComposerColumnPointer {
    /// The column under the pointer; nil between columns or outside the row.
    var slot: ComposerColumnSlot?
    /// The column the pointer was last over, kept after it leaves.
    var lastSlot: ComposerColumnSlot?
    /// Space would toggle a column right now: no text is being typed and
    /// Full Keyboard Access is off (it gives Space to the focused control).
    /// Refreshed as the pointer moves and when a column click ends typing.
    var spaceToggles = true

    func enter(_ column: ComposerColumnSlot) {
        if slot != column { slot = column }
        if lastSlot != column { lastSlot = column }
    }

    func leave(_ column: ComposerColumnSlot) {
        if slot == column { slot = nil }
    }

    /// Forgets a column that is no longer on screen.
    func forget(unless placed: [ComposerColumnSlot]) {
        if let slot, !placed.contains(slot) { self.slot = nil }
        if let lastSlot, !placed.contains(lastSlot) { self.lastSlot = nil }
    }

    func refreshSpaceToggles(in window: NSWindow?) {
        let toggles = !ComposerColumnSpaceKeyMonitor.isEditingText(window?.firstResponder)
            && !NSApp.isFullKeyboardAccessEnabled
        if spaceToggles != toggles { spaceToggles = toggles }
    }

    /// A click on a column's header line or rail background: typing ends, as
    /// clicking anywhere outside text does, so Space then toggles the column.
    func endTyping() {
        guard let window = NSApp.keyWindow else { return }
        if ComposerColumnSpaceKeyMonitor.isEditingText(window.firstResponder) {
            window.makeFirstResponder(nil)
        }
        refreshSpaceToggles(in: window)
    }
}

/// The Composer window's column commands for the View › Composer Columns
/// menu, published while a Composer is in front (the menu disables without
/// it). The moves act on the column the pointer is over or was last over.
struct ComposerColumnsCommandTarget: Equatable {
    let pointer: ComposerColumnPointer
    let order: [ComposerColumnSlot]
    /// The columns on screen; a move steps over the others.
    let present: Set<ComposerColumnSlot>
    let move: (ComposerColumnSlot, ComposerColumnMoveDirection) -> Void
    let resetOrder: () -> Void

    var isDefaultOrder: Bool { order == ComposerColumnOrder.defaultOrder }

    /// The column the moves act on. Reads the pointer, so the menu follows it.
    var pointerColumn: ComposerColumnSlot? {
        pointer.slot ?? pointer.lastSlot
    }

    /// Whether that column can move that way.
    func canMovePointerColumn(_ direction: ComposerColumnMoveDirection) -> Bool {
        guard let slot = pointerColumn else { return false }
        return ComposerColumnOrder.moving(slot, direction, in: order, present: present) != nil
    }

    func movePointerColumn(_ direction: ComposerColumnMoveDirection) {
        guard let slot = pointerColumn, canMovePointerColumn(direction) else { return }
        move(slot, direction)
    }

    /// The menu item's title, naming the column it will move.
    func moveTitle(_ direction: ComposerColumnMoveDirection) -> String {
        let side = direction == .left ? "Left" : "Right"
        return "Move \(pointerColumn?.title ?? "Column") \(side)"
    }

    /// Equal when the menu would read the same: the same pointer, order and
    /// columns on screen. The closures act on the Composer's state when they
    /// run, so ones built on a later pass do the same thing; comparing this
    /// way keeps the Composer's poll from rebuilding the View menu.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pointer === rhs.pointer && lhs.order == rhs.order && lhs.present == rhs.present
    }
}

extension FocusedValues {
    @Entry var composerColumnsCommandTarget: ComposerColumnsCommandTarget?
}

extension EnvironmentValues {
    /// The Composer's pointer tracking and the column a view sits in, set
    /// once per column by `ComposerColumnRow`. Both stay the same as the
    /// pointer moves, so only the views that read the pointer itself (the
    /// chevrons) update; the columns' content never sees a change.
    @Entry var composerColumnPointer: ComposerColumnPointer? = nil
    @Entry var composerColumnSlot: ComposerColumnSlot? = nil
}

/// Everything a column's header or rail needs to toggle its column. Built by
/// `ComposerView`, which owns the persisted open state.
struct ComposerColumnControl {
    let column: ComposerColumn
    /// Whether the column shows its full content (true) or its rail.
    let isOpen: Bool
    /// Opens or closes the column.
    let toggle: () -> Void
    /// The edge the open content stays pinned to while the column slides
    /// open or closed (see `ComposerColumnOrder.revealEdge`).
    var revealEdge: HorizontalEdge = .trailing
}

/// The chevron that opens or closes a column, lit in the accent while Space
/// would toggle the column: the pointer is over it and no text is being typed.
private struct ComposerColumnChevron: View {
    let systemName: String
    var height: CGFloat = ComposerColumn.headerHeight
    var width: CGFloat? = 18

    @Environment(\.composerColumnPointer) private var pointer
    @Environment(\.composerColumnSlot) private var slot

    private var isUnderPointer: Bool {
        guard let pointer, let slot else { return false }
        return pointer.slot == slot && pointer.spaceToggles
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isUnderPointer ? OhiaColors.chipActiveForeground : OhiaColors.textTertiary)
            .animation(.easeInOut(duration: 0.15), value: isUnderPointer)
            .frame(width: width, height: height)
    }
}

/// One column's header line: title on the left, optional trailing controls,
/// and the close chevron at the far right. The chevron, Space with the
/// pointer over the column, or the context menu closes it; clicking the line
/// ends any typing so Space reaches the column. A nil control
/// renders the plain header with no chevron, for previews and sandboxes
/// outside the Composer.
struct ComposerColumnHeader<Title: View, Trailing: View>: View {
    let control: ComposerColumnControl?
    let columnTitle: String
    @ViewBuilder let title: Title
    @ViewBuilder let trailing: Trailing

    @Environment(\.composerColumnMove) private var move
    @Environment(\.composerColumnPointer) private var pointer

    init(
        control: ComposerColumnControl?,
        columnTitle: String,
        @ViewBuilder title: () -> Title,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.control = control
        self.columnTitle = columnTitle
        self.title = title()
        self.trailing = trailing()
    }

    var body: some View {
        let row = HStack(alignment: .top, spacing: 6) {
            title
                .frame(height: ComposerColumn.headerHeight)
                .layoutPriority(1)
            Spacer(minLength: 8)
            trailing
                .frame(minHeight: ComposerColumn.headerHeight)
            if let control {
                Button {
                    control.toggle()
                } label: {
                    ComposerColumnChevron(systemName: "chevron.down")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close \(columnTitle) (\(control.column.shortcutGlyph))")
                .accessibilityLabel("Close \(columnTitle)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if let control {
            row
                .contentShape(Rectangle())
                .onTapGesture { pointer?.endTyping() }
                .contextMenu {
                    Button("Close \(columnTitle)") { control.toggle() }
                        .keyboardShortcut(control.column.shortcutKey, modifiers: ComposerColumn.shortcutModifiers)
                    if !move.isEmpty {
                        Divider()
                        ComposerColumnMoveMenuItems()
                    }
                }
                .accessibilityAction(named: "Close \(columnTitle)") {
                    control.toggle()
                }
                .modifier(ComposerColumnMoveAccessibilityActions())
        } else if !move.isEmpty {
            // The Draft column: it never closes, but it moves.
            row
                .contentShape(Rectangle())
                .contextMenu { ComposerColumnMoveMenuItems() }
                .modifier(ComposerColumnMoveAccessibilityActions())
        } else {
            row
        }
    }
}

extension ComposerColumnHeader where Trailing == EmptyView {
    init(
        control: ComposerColumnControl?,
        columnTitle: String,
        @ViewBuilder title: () -> Title
    ) {
        self.init(control: control, columnTitle: columnTitle, title: title, trailing: { EmptyView() })
    }
}


/// A closed column's rail: the column's icon, its name in small horizontal
/// type, an optional count, and the open chevron, with the column's compact
/// controls below (queued drafts, source types, styles). Clicking the header,
/// or Space with the pointer anywhere over the rail, reopens the column. Each
/// column renders its rail inside its own pane, so a column's sheets, alerts
/// and in-flight work survive closing and reopening it.
struct ComposerColumnRailBody<Content: View>: View {
    let control: ComposerColumnControl
    let title: String
    let symbolName: String
    var count: Int? = nil
    @ViewBuilder let content: Content

    @Environment(\.composerColumnMove) private var move
    @Environment(\.composerColumnPointer) private var pointer

    init(
        control: ComposerColumnControl,
        title: String,
        symbolName: String,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.control = control
        self.title = title
        self.symbolName = symbolName
        self.count = count
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            content
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { pointer?.endTyping() }
        // Anywhere on the rail, as on the strip it replaced; a control with
        // its own menu (a queued draft's circle) shows that one instead.
        .contextMenu {
            openMenuItem
            if !move.isEmpty {
                Divider()
                ComposerColumnMoveMenuItems()
            }
        }
    }

    private var header: some View {
        Button {
            control.toggle()
        } label: {
            VStack(spacing: 4) {
                ComposerSectionIcon(symbolName: symbolName)
                    .frame(height: ComposerColumn.headerHeight)
                Text(title)
                    .font(ComposerColumn.railTitleFont)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                if let count {
                    ComposerSectionCountBadge(count: count)
                }
                ComposerColumnChevron(systemName: "chevron.right", height: 14, width: nil)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(title) (\(control.column.shortcutGlyph))")
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityValue("Closed")
        .accessibilityHint("Opens the \(title) column")
        .modifier(ComposerColumnMoveAccessibilityActions())
    }

    private var openMenuItem: some View {
        Button("Open \(title)") { control.toggle() }
            .keyboardShortcut(control.column.shortcutKey, modifiers: ComposerColumn.shortcutModifiers)
    }
}

extension ComposerColumn {
    /// Horizontal inset of a rail's pane, leaving `railContentWidth` inside.
    static var railHorizontalPadding: CGFloat { (railWidth - railContentWidth) / 2 }
}

/// Opens and closes a column the way the Ask and Junk/Trash drawers slide
/// (`ConstellationSidebarContainer`): the open content is laid out once at its
/// full width, pinned to the edge facing the Draft column, and revealed by the
/// pane as it widens, so it slides in as a unit instead of re-flowing at every
/// intermediate width. The rail fades as the column starts to open and comes
/// back as it finishes closing. The pane's width itself animates in
/// `ComposerView` on `ComposerColumn.slideAnimation`; this view runs the same
/// clock for its phases. A reversal mid-slide continues from wherever the
/// column is; Reduce Motion makes the change immediate; a column already open
/// or closed when it first appears does not animate.
struct ComposerColumnSlide<Open: View, Rail: View>: View {
    let control: ComposerColumnControl
    @ViewBuilder let open: () -> Open
    @ViewBuilder let rail: () -> Rail

    @State private var phase: SidebarSlidePhase
    @State private var railOpacity: Double
    /// The pinned edge for the slide under way, held from its start so a
    /// column moved mid-slide does not flip its content across the pane.
    @State private var slideEdge: HorizontalEdge
    @State private var settle: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        control: ComposerColumnControl,
        @ViewBuilder open: @escaping () -> Open,
        @ViewBuilder rail: @escaping () -> Rail
    ) {
        self.control = control
        self.open = open
        self.rail = rail
        _phase = State(initialValue: control.isOpen ? .open : .closed)
        _railOpacity = State(initialValue: control.isOpen ? 0 : 1)
        _slideEdge = State(initialValue: control.revealEdge)
    }

    /// How long the rail takes to fade at either end of a slide.
    static var railFadeDuration: Double { 0.25 }

    var body: some View {
        // Every flexible frame here takes `minWidth: 0`: without it a frame
        // never narrows below its fixed-width child, and a closing column
        // would draw its full open width over its neighbors until it settles.
        ZStack {
            if phase != .closed {
                // One identity from opening through open to closing: only the
                // pinned width comes and goes. Inserted on the slide's clock
                // from where it sits in the closed pane, so it travels in with
                // the pane's moving edge rather than being uncovered in place.
                let isSliding = phase == .opening || phase == .closing
                open()
                    .frame(width: isSliding ? control.column.openContentWidth : nil)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: pinnedAlignment)
                    .clipped()
                    .allowsHitTesting(phase != .closing)
                    .accessibilityHidden(phase == .closing)
                    .transition(.asymmetric(insertion: .offset(x: insertionOffset), removal: .identity))
            }
            if phase != .open {
                rail()
                    .frame(width: ComposerColumn.railContentWidth)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: railAlignment)
                    .opacity(railOpacity)
                    .allowsHitTesting(phase != .opening)
                    .accessibilityHidden(phase == .opening)
                    .transition(.identity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: control.isOpen) { _, isOpen in
            slide(open: isOpen)
        }
        .onDisappear { settle?.cancel() }
    }

    private var edge: HorizontalEdge {
        phase == .opening || phase == .closing ? slideEdge : control.revealEdge
    }

    private var pinnedAlignment: Alignment {
        edge == .leading ? .leading : .trailing
    }

    /// The rail holds the column's far side, which stays put while the pane
    /// widens or narrows toward the Draft column.
    private var railAlignment: Alignment {
        edge == .leading ? .trailing : .leading
    }

    /// Where the open content starts as the column opens: as far toward the
    /// column's far side as the pane is narrower when closed.
    private var insertionOffset: CGFloat {
        edge == .leading ? control.column.slideTravel : -control.column.slideTravel
    }

    private func slide(open isOpen: Bool) {
        settle?.cancel()
        guard !reduceMotion else {
            phase = isOpen ? .open : .closed
            railOpacity = isOpen ? 0 : 1
            return
        }
        slideEdge = control.revealEdge
        if isOpen {
            withAnimation(ComposerColumn.slideAnimation) {
                phase = .opening
            }
        } else {
            phase = .closing
        }
        let fade = isOpen
            ? Animation.easeOut(duration: Self.railFadeDuration)
            : Animation.easeIn(duration: Self.railFadeDuration)
                .delay(ComposerColumn.slideDuration - Self.railFadeDuration)
        withAnimation(fade) {
            railOpacity = isOpen ? 0 : 1
        }
        settle = Task { @MainActor in
            try? await Task.sleep(for: .seconds(ComposerColumn.slideDuration))
            guard !Task.isCancelled else { return }
            phase = isOpen ? .open : .closed
        }
    }
}

/// A small spinning arc marking work in progress on a rail (a queued draft
/// being written, a source being added). Its angle is read from the clock,
/// so a spinner scrolled away and back in a lazy list picks up turning
/// again. Holds still under Reduce Motion.
struct ComposerRailSpinner: View {
    static let period: TimeInterval = 0.9

    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? 0 : Self.angle(at: context.date)))
        }
        .accessibilityHidden(true)
    }

    static func angle(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period * 360
    }
}

/// The red mark a rail shows when something waits on the author (sources
/// changed since the draft, slider adjustments not yet applied); its tooltip
/// carries the notice the open column would show.
struct ComposerRailAttentionMark: View {
    let notice: String

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(OhiaColors.ohiaRed)
            .frame(height: 14)
            .help(notice)
            .accessibilityLabel(notice)
    }
}

/// The hairline that separates a rail's groups of controls.
struct ComposerRailDivider: View {
    var body: some View {
        Rectangle()
            .fill(OhiaColors.iconPillBorder)
            .frame(width: 24, height: 1)
            .accessibilityHidden(true)
    }
}
