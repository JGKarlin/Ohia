// Ohia/Composer/ComposerColumnOrder.swift
// The Composer's four columns (Queue, Sources, Draft, Style) can stand in any
// order. The order persists in user defaults like each column's open state,
// so it holds for every later message. A column moves by dragging the grabber
// that appears on its top edge while the pointer is over its header: the
// column lifts and follows the pointer, the others slide aside to open the
// gap, and releasing settles it (Esc, or releasing outside the window, puts
// it back). Move Left / Move Right in a header's context menu, View ›
// Composer Columns (acting on the column under the pointer), and the
// matching accessibility actions do the same. Space with the pointer over
// Queue, Sources or Style opens or closes that column.

import AppKit
import SwiftUI

/// A column's place in the Composer row. Unlike `ComposerColumn`, which lists
/// only the columns that close, this includes the Draft stage column.
enum ComposerColumnSlot: String, CaseIterable, Identifiable {
    case queue
    case sources
    case draft
    case style

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue: "Queue"
        case .sources: "Sources"
        case .draft: "Draft"
        case .style: "Style"
        }
    }

    /// The closable column in this slot; nil for Draft, which never closes.
    var closableColumn: ComposerColumn? {
        switch self {
        case .queue: .queue
        case .sources: .sources
        case .draft: nil
        case .style: .style
        }
    }
}

extension ComposerColumn {
    var slot: ComposerColumnSlot {
        switch self {
        case .queue: .queue
        case .sources: .sources
        case .style: .style
        }
    }
}

enum ComposerColumnMoveDirection {
    case left
    case right
}

/// The persisted column order and the moves that change it.
enum ComposerColumnOrder {
    static let storageKey = "composerColumnOrder"
    static let defaultOrder: [ComposerColumnSlot] = [.queue, .sources, .draft, .style]
    static let defaultStorageValue = encode(defaultOrder)

    static func encode(_ order: [ComposerColumnSlot]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }

    /// The stored order made whole: unknown and repeated entries are dropped,
    /// and any column missing from it is added at the end in default order,
    /// so every column always has exactly one place.
    static func decode(_ stored: String) -> [ComposerColumnSlot] {
        var seen = Set<ComposerColumnSlot>()
        var order: [ComposerColumnSlot] = []
        for entry in stored.split(separator: ",") {
            let raw = entry.trimmingCharacters(in: .whitespaces)
            if let slot = ComposerColumnSlot(rawValue: raw), seen.insert(slot).inserted {
                order.append(slot)
            }
        }
        for slot in defaultOrder where !seen.contains(slot) {
            order.append(slot)
        }
        return order
    }

    /// `order` with `slot` moved past its nearest neighbor in `direction`
    /// among the columns on screen (`present`); nil when it is already at
    /// that end. Columns not on screen (Sources and Style with no message
    /// open) keep their places.
    static func moving(
        _ slot: ComposerColumnSlot,
        _ direction: ComposerColumnMoveDirection,
        in order: [ComposerColumnSlot],
        present: Set<ComposerColumnSlot>
    ) -> [ComposerColumnSlot]? {
        guard let index = order.firstIndex(of: slot) else { return nil }
        let neighbor: ComposerColumnSlot? = switch direction {
        case .left: order[..<index].last(where: present.contains)
        case .right: order[(index + 1)...].first(where: present.contains)
        }
        guard let neighbor else { return nil }
        var moved = order
        moved.remove(at: index)
        guard let neighborIndex = moved.firstIndex(of: neighbor) else { return nil }
        moved.insert(slot, at: direction == .left ? neighborIndex : neighborIndex + 1)
        return moved
    }

    /// The edge a closable column's content stays pinned to while it opens
    /// or closes: the edge facing the Draft column, which gives or takes the
    /// width. The content therefore slides out from the far side, as the Ask
    /// and Junk/Trash drawers slide out from the window edge.
    static func revealEdge(of slot: ComposerColumnSlot, in order: [ComposerColumnSlot]) -> HorizontalEdge {
        guard let index = order.firstIndex(of: slot),
              let draftIndex = order.firstIndex(of: .draft) else { return .trailing }
        return index < draftIndex ? .trailing : .leading
    }
}

// MARK: - Move actions

/// The moves open to one column, set on it by the row so its header and rail
/// can offer them in their context menus and as accessibility actions. A nil
/// move is not possible (the column is already at that end).
struct ComposerColumnMoveActions {
    var moveLeft: (() -> Void)?
    var moveRight: (() -> Void)?

    var isEmpty: Bool { moveLeft == nil && moveRight == nil }
}

extension EnvironmentValues {
    @Entry var composerColumnMove = ComposerColumnMoveActions()
}

/// Move Left / Move Right for a column's context menu.
struct ComposerColumnMoveMenuItems: View {
    @Environment(\.composerColumnMove) private var move

    var body: some View {
        Button("Move Left") { move.moveLeft?() }
            .disabled(move.moveLeft == nil)
        Button("Move Right") { move.moveRight?() }
            .disabled(move.moveRight == nil)
    }
}

/// The same moves as VoiceOver actions.
struct ComposerColumnMoveAccessibilityActions: ViewModifier {
    @Environment(\.composerColumnMove) private var move

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if let moveLeft = move.moveLeft {
                Button("Move Left", action: moveLeft)
            }
            if let moveRight = move.moveRight {
                Button("Move Right", action: moveRight)
            }
        }
    }
}

// MARK: - Drag layout

/// Where the columns stand while one is dragged. Widths and the row's start
/// are measured once, when the drag begins; every position after that is
/// computed from them in the live order, so neither the dragged column's
/// offset nor the measurement of its neighbors mid-animation can feed back
/// into the decision to trade places.
struct ComposerColumnDragLayout: Equatable {
    let rowStart: CGFloat
    let widths: [ComposerColumnSlot: CGFloat]
    let spacing: CGFloat

    /// The columns on screen, in `order`.
    func placed(_ order: [ComposerColumnSlot]) -> [ComposerColumnSlot] {
        order.filter { widths[$0] != nil }
    }

    /// The column's leading edge when laid out in `order`.
    func minX(of slot: ComposerColumnSlot, in order: [ComposerColumnSlot]) -> CGFloat? {
        var x = rowStart
        for placedSlot in placed(order) {
            guard let width = widths[placedSlot] else { continue }
            if placedSlot == slot { return x }
            x += width + spacing
        }
        return nil
    }

    /// The trailing edge of the last column.
    var rowEnd: CGFloat {
        let placedWidths = widths.values
        return rowStart + placedWidths.reduce(0, +) + spacing * CGFloat(max(0, placedWidths.count - 1))
    }

    /// The dragged column's leading edge as it follows the pointer, held
    /// inside the row.
    func visualMinX(of slot: ComposerColumnSlot, startMinX: CGFloat, translation: CGFloat) -> CGFloat {
        let width = widths[slot] ?? 0
        return min(max(startMinX + translation, rowStart), max(rowStart, rowEnd - width))
    }

    /// The live order once the dragged column's center stands at `center`:
    /// it trades places with a neighbor as soon as its center passes that
    /// neighbor's center. Trading moves the neighbor a full column width the
    /// other way, so the same position never trades straight back. Nil when
    /// nothing moves.
    func reordered(
        _ order: [ComposerColumnSlot],
        dragging slot: ComposerColumnSlot,
        center: CGFloat
    ) -> [ComposerColumnSlot]? {
        var current = order
        var changed = false
        // A fast drag can pass more than one column in a single update.
        for _ in 0..<order.count {
            let row = placed(current)
            guard let index = row.firstIndex(of: slot) else { return nil }
            if index + 1 < row.count, let next = midX(of: row[index + 1], in: current), center > next,
               let moved = ComposerColumnOrder.moving(slot, .right, in: current, present: Set(row)) {
                current = moved
                changed = true
            } else if index > 0, let previous = midX(of: row[index - 1], in: current), center < previous,
                      let moved = ComposerColumnOrder.moving(slot, .left, in: current, present: Set(row)) {
                current = moved
                changed = true
            } else {
                break
            }
        }
        return changed ? current : nil
    }

    private func midX(of slot: ComposerColumnSlot, in order: [ComposerColumnSlot]) -> CGFloat? {
        guard let minX = minX(of: slot, in: order), let width = widths[slot] else { return nil }
        return minX + width / 2
    }
}

// MARK: - Drag model

/// One column drag, from the grabber's first movement to release. Kept in an
/// observable model so pointer movement is read only by the dragged column's
/// lift (`ComposerColumnDragHandle`): the row re-renders when the columns
/// trade places, never per pointer event, and no column's content
/// re-renders for the drag.
@Observable
final class ComposerColumnDragModel {
    static let coordinateSpaceName = "ComposerColumnRow"

    struct Session: Equatable {
        let slot: ComposerColumnSlot
        let layout: ComposerColumnDragLayout
        let startMinX: CGFloat
    }

    /// The drag under way; nil while no column is held.
    private(set) var session: Session?
    /// The order while a column is held; the row lays the columns out in it.
    private(set) var liveOrder: [ComposerColumnSlot]?
    /// Pointer travel since the drag began. Read only for the held column.
    private(set) var translation: CGFloat = 0
    /// The column whose header band the pointer is over.
    var hoveredSlot: ComposerColumnSlot?

    /// The columns' last measured frames in the row. Read only when a drag
    /// begins, so a window resize re-measures them without re-rendering.
    @ObservationIgnored var frames: [ComposerColumnSlot: CGRect] = [:]
    /// The row's window, for telling a drop inside it from one outside.
    @ObservationIgnored weak var window: NSWindow?
    /// The drag ended early (Esc, or the columns changed under it) while the
    /// pointer is still down: the rest of that gesture is ignored.
    @ObservationIgnored private(set) var isIgnoringGesture = false
    @ObservationIgnored private let escapeMonitor = ComposerColumnEscapeMonitor()

    var draggedSlot: ComposerColumnSlot? { session?.slot }

    /// Measures the row as it stands (`placed` in order) and lifts `slot`.
    /// False when a column has not been measured yet or the gesture is being
    /// ignored.
    func begin(
        _ slot: ComposerColumnSlot,
        order: [ComposerColumnSlot],
        placed: [ComposerColumnSlot],
        spacing: CGFloat
    ) -> Bool {
        guard session == nil, !isIgnoringGesture else { return false }
        var widths: [ComposerColumnSlot: CGFloat] = [:]
        for placedSlot in placed {
            guard let frame = frames[placedSlot] else { return false }
            widths[placedSlot] = frame.width
        }
        guard let start = frames[slot],
              let rowStart = placed.compactMap({ frames[$0]?.minX }).min() else { return false }
        session = Session(
            slot: slot,
            layout: ComposerColumnDragLayout(rowStart: rowStart, widths: widths, spacing: spacing),
            startMinX: start.minX
        )
        liveOrder = order
        translation = 0
        escapeMonitor.start { [weak self] in
            self?.cancel(ignoringRestOfGesture: true, animated: true)
        }
        return true
    }

    /// Follows the pointer. Returns the new live order when the held column
    /// has passed a neighbor's center, for the caller to apply with
    /// animation; nil when nothing trades.
    func follow(translation newTranslation: CGFloat) -> [ComposerColumnSlot]? {
        guard let session, let liveOrder else { return nil }
        translation = newTranslation
        let visual = session.layout.visualMinX(
            of: session.slot,
            startMinX: session.startMinX,
            translation: newTranslation
        )
        let center = visual + (session.layout.widths[session.slot] ?? 0) / 2
        return session.layout.reordered(liveOrder, dragging: session.slot, center: center)
    }

    func setLiveOrder(_ order: [ComposerColumnSlot]) {
        guard session != nil else { return }
        liveOrder = order
    }

    /// The order to keep at release: the live order when it differs from
    /// `persisted` and the pointer is inside the row's window; otherwise nil
    /// and the column goes back.
    func releasedOrder(persisted: [ComposerColumnSlot], pointerInsideWindow: Bool) -> [ComposerColumnSlot]? {
        guard session != nil, let liveOrder, pointerInsideWindow, liveOrder != persisted else { return nil }
        return liveOrder
    }

    /// Drops the drag. Call inside the animation that settles the columns.
    func clear() {
        escapeMonitor.stop()
        session = nil
        liveOrder = nil
        translation = 0
    }

    /// Ends the drag early and puts the column back. With
    /// `ignoringRestOfGesture`, the pointer is still down on a grabber that
    /// stays on screen, so its remaining movement must not start another drag;
    /// without it the grabber is gone and so is its gesture.
    func cancel(ignoringRestOfGesture: Bool, animated: Bool) {
        guard session != nil else { return }
        isIgnoringGesture = ignoringRestOfGesture
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(animated && !reduceMotion ? ComposerColumn.reorderAnimation : nil) {
            clear()
        }
    }

    /// The grabber's gesture finished; the next one may start a drag.
    func gestureEnded() {
        isIgnoringGesture = false
    }

    /// How far the held column is drawn from its slot so it stays under the
    /// pointer; 0 for every other column. Reads the pointer only for the held
    /// column, so only its view tracks pointer movement.
    func offset(of slot: ComposerColumnSlot) -> CGFloat {
        guard let session, session.slot == slot, let liveOrder,
              let layoutMinX = session.layout.minX(of: slot, in: liveOrder) else { return 0 }
        let visual = session.layout.visualMinX(of: slot, startMinX: session.startMinX, translation: translation)
        return visual - layoutMinX
    }

    var isPointerInsideWindow: Bool {
        guard let window else { return true }
        return window.frame.contains(NSEvent.mouseLocation)
    }
}

// MARK: - Row

/// The Composer's columns in their persisted order, with drag-to-reorder.
struct ComposerColumnRow<Column: View>: View {
    let order: [ComposerColumnSlot]
    let isPresent: (ComposerColumnSlot) -> Bool
    let spacing: CGFloat
    /// Depth of the band at a column's top whose hover shows its grabber:
    /// the header line of an open column, the icon stack of a rail.
    let grabBand: (ComposerColumnSlot) -> CGFloat
    /// Changes when a column opens or closes; a drag under way ends, since
    /// the widths it measured no longer hold.
    let layoutKey: [Bool]
    /// Written with the column under the pointer.
    let pointer: ComposerColumnPointer
    let moveActions: (ComposerColumnSlot) -> ComposerColumnMoveActions
    let onReorder: ([ComposerColumnSlot]) -> Void
    /// Space with the pointer over a closable column.
    let onSpaceToggle: (ComposerColumn) -> Void
    @ViewBuilder let column: (ComposerColumnSlot) -> Column

    @State private var model = ComposerColumnDragModel()
    @State private var spaceKey = ComposerColumnSpaceKeyMonitor()

    var body: some View {
        let placed = order.filter(isPresent)
        HStack(spacing: spacing) {
            ForEach((model.liveOrder ?? order).filter(isPresent)) { slot in
                column(slot)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(ComposerColumnDragModel.coordinateSpaceName))
                    } action: { frame in
                        model.frames[slot] = frame
                    }
                    .environment(\.composerColumnMove, moveActions(slot))
                    .environment(\.composerColumnPointer, pointer)
                    .environment(\.composerColumnSlot, slot)
                    .modifier(ComposerColumnDragHandle(
                        slot: slot,
                        grabBand: grabBand(slot),
                        model: model,
                        pointer: pointer,
                        begin: { model.begin(slot, order: order, placed: placed, spacing: spacing) },
                        persistedOrder: order,
                        onReorder: onReorder
                    ))
                    .layoutPriority(slot == .draft ? 2 : 0)
            }
        }
        .coordinateSpace(.named(ComposerColumnDragModel.coordinateSpaceName))
        .background(ComposerColumnWindowAnchor(model: model))
        .onChange(of: placed) { _, nowPlaced in
            if let hovered = model.hoveredSlot, !nowPlaced.contains(hovered) {
                model.hoveredSlot = nil
            }
            pointer.forget(unless: nowPlaced)
            guard let dragged = model.draggedSlot else { return }
            // A column came or went: the measured widths no longer hold. If
            // the held column itself went, so did its gesture.
            model.cancel(ignoringRestOfGesture: nowPlaced.contains(dragged), animated: true)
        }
        .onChange(of: layoutKey) {
            model.cancel(ignoringRestOfGesture: true, animated: true)
        }
        .onAppear {
            spaceKey.start(
                window: { [weak model] in model?.window },
                pointer: pointer,
                isDragging: { [weak model] in model?.draggedSlot != nil },
                toggle: onSpaceToggle
            )
        }
        .onDisappear {
            spaceKey.stop()
            pointer.forget(unless: [])
            model.cancel(ignoringRestOfGesture: false, animated: false)
            model.gestureEnded()
        }
    }
}

/// Space opens or closes the closable column under the pointer, in this
/// Composer window only, unless text is being typed: a focused editable text
/// view (the draft editor, an answer or search field) keeps its spaces. With
/// Full Keyboard Access on, Space presses the focused control as macOS
/// expects. A key monitor rather than a focused view, so hovering never moves
/// keyboard focus away from what the author is typing.
final class ComposerColumnSpaceKeyMonitor {
    static let spaceKeyCode: UInt16 = 49

    enum Outcome: Equatable {
        /// Open or close this column and consume the key.
        case toggle(ComposerColumn)
        /// Consume the key and do nothing: a held Space repeating after a
        /// toggle, which would otherwise beep.
        case swallow
        /// Leave the key to the focused view.
        case pass
    }

    // Read by `deinit` as a last resort; every other access is on the main
    // actor.
    nonisolated(unsafe) private var monitor: Any?

    func start(
        window: @escaping () -> NSWindow?,
        pointer: ComposerColumnPointer,
        isDragging: @escaping () -> Bool,
        toggle: @escaping (ComposerColumn) -> Void
    ) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = window() else { return event }
            let outcome = Self.outcome(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                isRepeat: event.isARepeat,
                isInComposerWindow: event.window === window,
                column: pointer.slot?.closableColumn,
                isDragging: isDragging(),
                isEditingText: Self.isEditingText(window.firstResponder),
                isFullKeyboardAccessOn: NSApp.isFullKeyboardAccessEnabled
            )
            switch outcome {
            case .toggle(let column):
                toggle(column)
                return nil
            case .swallow:
                return nil
            case .pass:
                return event
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// What a key press does: a plain Space (no modifier) in the Composer
    /// window, with the pointer over a closable column, no drag under way, no
    /// text being typed, and Full Keyboard Access off, toggles that column;
    /// its key repeats are swallowed; everything else passes through.
    static func outcome(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isRepeat: Bool,
        isInComposerWindow: Bool,
        column: ComposerColumn?,
        isDragging: Bool,
        isEditingText: Bool,
        isFullKeyboardAccessOn: Bool
    ) -> Outcome {
        let held = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard keyCode == spaceKeyCode, held.isEmpty, isInComposerWindow,
              let column, !isDragging, !isEditingText, !isFullKeyboardAccessOn else { return .pass }
        return isRepeat ? .swallow : .toggle(column)
    }

    /// Text fields edit through a field editor, itself an `NSTextView`, so an
    /// editable text view as first responder covers both.
    static func isEditingText(_ responder: NSResponder?) -> Bool {
        guard let textView = responder as? NSTextView else { return false }
        return textView.isEditable
    }
}

/// A column's drag handle and lift: the grabber on its top edge (shown while
/// the pointer is over the header band), the drag gesture, and, while held,
/// the accent border, shadow, and pointer-following offset. The column's own
/// content passes through untouched, so pointer movement re-renders only this.
struct ComposerColumnDragHandle: ViewModifier {
    let slot: ComposerColumnSlot
    let grabBand: CGFloat
    let model: ComposerColumnDragModel
    let pointer: ComposerColumnPointer
    let begin: () -> Bool
    let persistedOrder: [ComposerColumnSlot]
    let onReorder: ([ComposerColumnSlot]) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let isHeld = model.draggedSlot == slot
        content
            .overlay(alignment: .top) {
                ComposerColumnGrabber(
                    title: slot.title,
                    isVisible: isHeld || (model.draggedSlot == nil && model.hoveredSlot == slot),
                    isDragging: isHeld
                )
                .gesture(dragGesture)
            }
            // Outside the grabber, so the pointer resting on the grabber still
            // counts as over the header band.
            .onContinuousHover(coordinateSpace: .local) { phase in
                updateHover(phase)
            }
            .overlay {
                if isHeld {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(OhiaColors.chipActiveForeground, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .background {
                // The lift: a shadow under a plain shape, so the column's own
                // content is not re-rendered for it while it moves.
                if isHeld {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(OhiaColors.composerPanelBackground)
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                }
            }
            .offset(x: model.offset(of: slot))
            .zIndex(isHeld ? 1 : 0)
            // The held column tracks the pointer; only its neighbors animate
            // when the order changes under it.
            .transaction { transaction in
                if isHeld { transaction.animation = nil }
            }
    }

    private var reorderAnimation: Animation? {
        reduceMotion ? nil : ComposerColumn.reorderAnimation
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(ComposerColumnDragModel.coordinateSpaceName))
            .onChanged { value in
                if model.draggedSlot == nil {
                    guard begin() else { return }
                }
                guard model.draggedSlot == slot else { return }
                if let traded = model.follow(translation: value.translation.width) {
                    withAnimation(reorderAnimation) {
                        model.setLiveOrder(traded)
                    }
                }
            }
            .onEnded { _ in
                defer { model.gestureEnded() }
                guard model.draggedSlot == slot else { return }
                let kept = model.releasedOrder(
                    persisted: persistedOrder,
                    pointerInsideWindow: model.isPointerInsideWindow
                )
                withAnimation(reorderAnimation) {
                    if let kept {
                        onReorder(kept)
                    }
                    model.clear()
                }
            }
    }

    private func updateHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            pointer.enter(slot)
            pointer.refreshSpaceToggles(in: model.window)
            let inBand = location.y <= grabBand
            if inBand, model.hoveredSlot != slot {
                model.hoveredSlot = slot
            } else if !inBand, model.hoveredSlot == slot {
                model.hoveredSlot = nil
            }
        case .ended:
            pointer.leave(slot)
            if model.hoveredSlot == slot { model.hoveredSlot = nil }
        }
    }
}

/// Hands the row's window to the drag model; never takes a click.
private struct ComposerColumnWindowAnchor: NSViewRepresentable {
    let model: ComposerColumnDragModel

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.model = model
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.model = model
        model.window = view.window
    }

    final class AnchorView: NSView {
        weak var model: ComposerColumnDragModel?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            model?.window = window
        }
    }
}

/// The handle on a column's top edge: a small grid of dots that fades in
/// while the pointer is over the column's header, with the open-hand pointer
/// over it and the closed hand while dragging.
struct ComposerColumnGrabber: View {
    static let height: CGFloat = 11

    let title: String
    let isVisible: Bool
    let isDragging: Bool

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<2, id: \.self) { _ in
                GridRow {
                    ForEach(0..<4, id: \.self) { _ in
                        Circle()
                            .fill(isDragging ? OhiaColors.chipActiveForeground : OhiaColors.textTertiary)
                            .frame(width: 2.5, height: 2.5)
                    }
                }
            }
        }
        .frame(width: 44, height: Self.height)
        .contentShape(Rectangle())
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isVisible)
        .allowsHitTesting(isVisible)
        .pointerStyle(isDragging ? .grabActive : .grabIdle)
        .help("Drag to move \(title)")
        .accessibilityHidden(true)
    }
}

/// Watches for Esc while a column is being dragged; consumes it so it does
/// not also reach the focused control.
final class ComposerColumnEscapeMonitor {
    private static let escapeKeyCode: UInt16 = 53

    // Read by `deinit` as a last resort; every other access is on the main
    // actor.
    nonisolated(unsafe) private var monitor: Any?

    func start(onEscape: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == Self.escapeKeyCode else { return event }
            onEscape()
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
