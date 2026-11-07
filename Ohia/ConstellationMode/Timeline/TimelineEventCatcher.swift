import AppKit
import SwiftUI
import WebKit

/// Bridges AppKit event streams (scroll wheel, click, right-click) to SwiftUI
/// surfaces inside the Timeline lens. Two flavors live on this view —
/// scroll and mouse events — and both share the same window-scoped
/// `NSEvent.localMonitor` lifecycle, bounds filter, and focus-ring
/// suppression, so any future event type plugs in with one line.
///
/// Why a local monitor rather than `mouseDown` / `menu(for:)`
/// overrides: when the catcher is mounted as `.background()` it sits
/// behind any child views in the responder chain, so a plain method
/// override gets shadowed by foreground text fields, web views, etc.
/// The local monitor sees every matching event in the window, then
/// filters by the catcher's own bounds — and returning `nil` consumes
/// the event. For right-clicks, the catcher first asks the foreground
/// AppKit/WebKit text surface whether the click is inside a selection;
/// that branch gets a Copy-only menu, while every other point routes to
/// the card-wide message menu.
///
/// Mount points today:
/// - Multitrack canvas: `.background(TimelineEventCatcher(onScroll:))`
/// - Ruler / minimap / chapter strip band: same scroll-only catcher
/// - Email semantic viewport: `.background(TimelineEventCatcher(onRightClick:))`
struct TimelineEventCatcher: NSViewRepresentable {
    /// Local monitors bypass SwiftUI hit testing. Callers that recede a surface
    /// must disable its bridge explicitly as well as its SwiftUI content.
    var isInteractionEnabled = true

    /// Closure called for each scroll wheel event whose pointer location
    /// is inside the catcher's bounds. `deltaY` is the vertical scroll
    /// delta (positive = scrolled up gesture); `modifiers` carries the
    /// active key flags so the parent can branch on shift / option.
    var onScroll: (@MainActor (_ deltaY: CGFloat, _ modifiers: NSEvent.ModifierFlags) -> Void)? = nil

    /// Closure called for horizontally-dominant scroll events (|deltaX| >
    /// |deltaY|) inside the catcher's bounds — trackpad side-swipes and
    /// tilt wheels. Only these events are consumed; vertically-dominant
    /// scrolls pass through untouched so an enclosing vertical ScrollView
    /// keeps working. Positive `deltaX` means content should move right
    /// (scrolled toward earlier content), matching AppKit's convention.
    var onHorizontalScroll: (@MainActor (_ deltaX: CGFloat, _ modifiers: NSEvent.ModifierFlags) -> Void)? = nil

    /// Gates `onHorizontalScroll` consumption without unwiring the closure:
    /// when `false`, horizontally-dominant events pass through instead of
    /// being swallowed. Lets callers whose pan target only sometimes exists
    /// (e.g. an active zoom window) keep a stable closure identity.
    var isHorizontalScrollActive: Bool = true

    /// Closure called for each left-click inside the catcher's bounds. The
    /// caller receives the AppKit modifier flags so row surfaces can implement
    /// table-like shift / command / control selection without depending on
    /// SwiftUI gesture arbitration.
    var onLeftClick: (@MainActor (_ point: NSPoint, _ view: NSView, _ modifiers: NSEvent.ModifierFlags) -> Void)? = nil

    /// Closure called for each right-click (including control-click and
    /// trackpad secondary-tap) inside the catcher's bounds. `point` is
    /// in the catcher view's coordinate space (suitable for
    /// `NSMenu.popUp(positioning:at:in:)`), and `view` is the catcher
    /// view itself — both arguments map directly onto what
    /// `ConstellationNodeContextMenu.present` expects.
    var onRightClick: (@MainActor (_ point: NSPoint, _ view: NSView) -> Void)? = nil

    static func selectedText(in textView: NSTextView, at point: NSPoint) -> String? {
        let stringLength = (textView.string as NSString).length
        guard stringLength > 0 else { return nil }
        let characterIndex = textView.characterIndexForInsertion(at: point)

        for value in textView.selectedRanges {
            let range = value.rangeValue
            guard range.length > 0,
                  range.location != NSNotFound,
                  NSMaxRange(range) <= stringLength,
                  NSLocationInRange(characterIndex, range) else {
                continue
            }
            return (textView.string as NSString).substring(with: range)
        }
        return nil
    }

    static func selectedText(in webView: WKWebView, at point: NSPoint) async -> String? {
        let zoom = max(webView.pageZoom, 0.001)
        let cssX = point.x / zoom
        let viewY = webView.isFlipped ? point.y : webView.bounds.height - point.y
        let cssY = viewY / zoom
        let script = """
        (() => {
            const selection = window.getSelection();
            if (!selection || selection.isCollapsed || selection.rangeCount === 0) {
                return '';
            }
            const x = \(cssX);
            const y = \(cssY);
            for (let rangeIndex = 0; rangeIndex < selection.rangeCount; rangeIndex += 1) {
                const rects = selection.getRangeAt(rangeIndex).getClientRects();
                for (const rect of rects) {
                    if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
                        return selection.toString();
                    }
                }
            }
            return '';
        })()
        """

        do {
            let result = try await webView.evaluateJavaScript(
                script,
                in: nil,
                contentWorld: .page
            )
            guard let text = result as? String,
                  text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return nil
            }
            return text
        } catch {
            return nil
        }
    }

    static func selectionMenu(
        for selectedText: String,
        pasteboard: NSPasteboard = .general
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copyItem = SelectedTextCopyMenuItem(text: selectedText, pasteboard: pasteboard)
        copyItem.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: nil
        )
        menu.addItem(copyItem)
        return menu
    }

    /// Closure called for each left-mouse double-click inside the
    /// catcher's bounds. AppKit's `clickCount == 2` semantics already
    /// honor the system double-click interval and position tolerance,
    /// so no separate debounce is needed. Returning `nil` from the
    /// monitor consumes the second click so SwiftUI's foreground
    /// gestures see only the first click (the single-tap effect still
    /// fires on the first cycle, mirroring NSTableView's
    /// `singleAction → doubleAction` upgrade pattern).
    var onDoubleClick: (@MainActor (_ point: NSPoint, _ view: NSView) -> Void)? = nil

    /// Synchronous predicate consulted before a double-click is consumed.
    /// Return `true` for points (catcher-local, top-left origin) that belong to
    /// an interactive foreground control — e.g. a Front Page card's action
    /// cluster — so a rapid second press on a button passes through to SwiftUI
    /// and activates the control instead of being swallowed as an "open"
    /// double-click. `nil` keeps the unconditional consume.
    var isDoubleClickExempt: (@MainActor (_ point: NSPoint) -> Bool)? = nil

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        // Suppress the AppKit system focus ring — the catcher is a
        // hit-test surface for events, not a focusable input.
        view.focusRingType = .none
        view.isInteractionEnabled = isInteractionEnabled
        view.onScroll = onScroll
        view.onHorizontalScroll = onHorizontalScroll
        view.isHorizontalScrollActive = isHorizontalScrollActive
        view.onLeftClick = onLeftClick
        view.onRightClick = onRightClick
        view.onDoubleClick = onDoubleClick
        view.isDoubleClickExempt = isDoubleClickExempt
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.isInteractionEnabled = isInteractionEnabled
        nsView.onScroll = onScroll
        nsView.onHorizontalScroll = onHorizontalScroll
        nsView.isHorizontalScrollActive = isHorizontalScrollActive
        nsView.onLeftClick = onLeftClick
        nsView.onRightClick = onRightClick
        nsView.onDoubleClick = onDoubleClick
        nsView.isDoubleClickExempt = isDoubleClickExempt
        // A handler that was nil at mount (e.g. horizontal pan wired only
        // while a zoom window exists) must still get its monitor once it
        // appears. The monitor closures re-check handler presence per
        // event, so an installed monitor with nil handlers passes events
        // through untouched.
        nsView.ensureScrollMonitorIfNeeded()
    }

    final class CatcherView: NSView {
        var isInteractionEnabled = true

        var onScroll: (@MainActor (CGFloat, NSEvent.ModifierFlags) -> Void)?
        var onHorizontalScroll: (@MainActor (CGFloat, NSEvent.ModifierFlags) -> Void)?
        var isHorizontalScrollActive = true
        var onLeftClick: (@MainActor (NSPoint, NSView, NSEvent.ModifierFlags) -> Void)?
        var onRightClick: (@MainActor (NSPoint, NSView) -> Void)?
        var onDoubleClick: (@MainActor (NSPoint, NSView) -> Void)?
        var isDoubleClickExempt: (@MainActor (NSPoint) -> Bool)?

        private var scrollMonitor: Any?
        private var leftMouseMonitor: Any?
        private var rightClickMonitor: Any?
        private var monitorsAttempted = false

        // Coalesce scroll events arriving faster than the runloop can
        // process them. Each event accumulates into `pendingDeltaY` and
        // schedules an async flush; subsequent events that arrive before
        // the flush runs are summed in. The flush then dispatches a
        // single state mutation per frame instead of one per raw event.
        private var pendingDeltaY: CGFloat = 0
        private var pendingModifiers: NSEvent.ModifierFlags = []
        private var flushScheduled = false

        override var acceptsFirstResponder: Bool { false }

        // SwiftUI's coordinate system is top-left origin / Y-down. Flipping the
        // catcher view means `convert(event.locationInWindow, from: nil)` returns
        // a point that matches SwiftUI's hit-test rectangles directly — without
        // this, right-clicks get a Y-inverted point and the parent's hit-test
        // misses or, worse, lands on a different row by coincidence. `NSMenu.popUp`
        // respects the view's flipped state, so menu positioning stays correct.
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, !monitorsAttempted {
                monitorsAttempted = true
                installMonitors()
            } else if window == nil {
                tearDownMonitors()
                monitorsAttempted = false
            }
        }

        func ensureScrollMonitorIfNeeded() {
            guard window != nil,
                  scrollMonitor == nil,
                  onScroll != nil || onHorizontalScroll != nil else { return }
            installScrollMonitor()
        }

        private func installMonitors() {
            // Scroll-wheel monitor — only registered if a handler is
            // wired. Trackpads / Magic Mouse deliver precise (continuous)
            // deltas; classic scroll wheels deliver discrete clicks.
            // Amplify the discrete path so both input devices yield
            // comparable scrub / zoom speed for the same physical gesture.
            if onScroll != nil || onHorizontalScroll != nil {
                installScrollMonitor()
            }

            installMouseMonitors()
        }

        private func installScrollMonitor() {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                guard self.eventIsInsideBounds(event) else { return event }
                let dy: CGFloat
                let dx: CGFloat
                if event.hasPreciseScrollingDeltas {
                    dy = event.scrollingDeltaY
                    dx = event.scrollingDeltaX
                } else {
                    dy = event.deltaY * 8
                    dx = event.deltaX * 8
                }
                // Horizontally-dominant scrolls route to the horizontal
                // handler and are consumed; vertically-dominant scrolls
                // either go to the vertical handler (consumed, Timeline's
                // scrub behavior) or pass through to the enclosing
                // ScrollView when only the horizontal handler is wired.
                if self.onHorizontalScroll != nil, self.isHorizontalScrollActive, abs(dx) > abs(dy) {
                    self.enqueueHorizontalScroll(deltaX: dx, modifiers: event.modifierFlags)
                    return nil
                }
                guard self.onScroll != nil else { return event }
                self.enqueueScroll(deltaY: dy, modifiers: event.modifierFlags)
                return nil
            }
        }

        private func installMouseMonitors() {
            // Left-mouse monitor — installed only when a single-click or
            // double-click handler is wired. When `onLeftClick` is absent,
            // singles pass through so existing SwiftUI foreground gestures
            // continue to receive them. When it is present, the caller owns
            // table-like selection and we consume the event.
            if onLeftClick != nil || onDoubleClick != nil {
                leftMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    guard let self else { return event }
                    guard self.eventIsInsideBounds(event) else { return event }
                    let point = self.convert(event.locationInWindow, from: nil)
                    if event.clickCount == 2, let handler = self.onDoubleClick {
                        // A rapid second press over an exempt region (a card's
                        // action cluster) is a repeated button press, not an
                        // "open" double-click — hand it back to SwiftUI so the
                        // control activates instead of the press vanishing.
                        if self.isDoubleClickExempt?(point) == true {
                            return event
                        }
                        DispatchQueue.main.async {
                            handler(point, self)
                        }
                        return nil
                    }
                    guard event.clickCount == 1, let handler = self.onLeftClick else { return event }
                    DispatchQueue.main.async {
                        handler(point, self, event.modifierFlags)
                    }
                    // Let SwiftUI still see the originating down event so row
                    // affordances such as `.draggable` can begin a drag after
                    // selection has been updated.
                    return event
                }
            }

            // Right-click monitor — covers control-click and trackpad
            // secondary-tap (AppKit synthesizes both as rightMouseDown).
            // Returning nil consumes the event so foreground text views
            // never get to show their default Cut / Copy / Spelling menu.
            if onRightClick != nil {
                rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                    guard let self else { return event }
                    guard self.eventIsInsideBounds(event) else { return event }
                    if event.modifierFlags.contains(.control), let handler = self.onLeftClick {
                        let point = self.convert(event.locationInWindow, from: nil)
                        DispatchQueue.main.async {
                            handler(point, self, event.modifierFlags)
                        }
                        return nil
                    }
                    guard self.onRightClick != nil else { return event }
                    let point = self.convert(event.locationInWindow, from: nil)
                    switch self.foregroundTextTarget(for: event) {
                    case .appKit(let textView, let textPoint):
                        let selectedText = TimelineEventCatcher.selectedText(
                            in: textView,
                            at: textPoint
                        )
                        self.presentRightClickMenu(
                            selectedText: selectedText,
                            point: point
                        )
                    case .webKit(let webView, let webPoint):
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            let selectedText = await TimelineEventCatcher.selectedText(
                                in: webView,
                                at: webPoint
                            )
                            self.presentRightClickMenu(
                                selectedText: selectedText,
                                point: point
                            )
                        }
                    case nil:
                        self.presentRightClickMenu(
                            selectedText: nil,
                            point: point
                        )
                    }
                    return nil
                }
            }
        }

        private enum ForegroundTextTarget {
            case appKit(NSTextView, NSPoint)
            case webKit(WKWebView, NSPoint)
        }

        private func foregroundTextTarget(for event: NSEvent) -> ForegroundTextTarget? {
            guard let contentView = window?.contentView else { return nil }
            let contentPoint = contentView.convert(event.locationInWindow, from: nil)
            var candidate = contentView.hitTest(contentPoint)
            while let view = candidate {
                if let textView = view as? NSTextView {
                    return .appKit(
                        textView,
                        textView.convert(event.locationInWindow, from: nil)
                    )
                }
                if let webView = view as? WKWebView {
                    return .webKit(
                        webView,
                        webView.convert(event.locationInWindow, from: nil)
                    )
                }
                candidate = view.superview
            }
            return nil
        }

        private func presentRightClickMenu(
            selectedText: String?,
            point: NSPoint
        ) {
            // Hop to the next runloop tick so AppKit finishes its own
            // right-mouse-down processing before an NSMenu pops. Popping inline
            // can race the menu-down stack and leave a half-installed menu.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let selectedText {
                    TimelineEventCatcher.selectionMenu(for: selectedText)
                        .popUp(positioning: nil, at: point, in: self)
                } else {
                    self.onRightClick?(point, self)
                }
            }
        }

        private func tearDownMonitors() {
            if let m = scrollMonitor {
                NSEvent.removeMonitor(m)
                scrollMonitor = nil
            }
            if let m = rightClickMonitor {
                NSEvent.removeMonitor(m)
                rightClickMonitor = nil
            }
            if let m = leftMouseMonitor {
                NSEvent.removeMonitor(m)
                leftMouseMonitor = nil
            }
        }

        private func eventIsInsideBounds(_ event: NSEvent) -> Bool {
            guard let window = self.window, event.window === window else { return false }
            let pointInView = self.convert(event.locationInWindow, from: nil)
            return acceptsInteraction(at: pointInView)
        }

        func acceptsInteraction(at point: NSPoint) -> Bool {
            isInteractionEnabled
                && !isHiddenOrHasHiddenAncestor
                && bounds.contains(point)
                && visibleRect.contains(point)
        }

        private func enqueueScroll(deltaY: CGFloat, modifiers: NSEvent.ModifierFlags) {
            pendingDeltaY += deltaY
            pendingModifiers = modifiers
            guard !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let dy = self.pendingDeltaY
                let mods = self.pendingModifiers
                self.pendingDeltaY = 0
                self.flushScheduled = false
                guard dy != 0, let handler = self.onScroll else { return }
                handler(dy, mods)
            }
        }

        // Mirrors `enqueueScroll` for the horizontal axis with its own
        // accumulator/flush pair so diagonal gestures can't starve either
        // handler.
        private var pendingDeltaX: CGFloat = 0
        private var pendingHorizontalModifiers: NSEvent.ModifierFlags = []
        private var horizontalFlushScheduled = false

        private func enqueueHorizontalScroll(deltaX: CGFloat, modifiers: NSEvent.ModifierFlags) {
            pendingDeltaX += deltaX
            pendingHorizontalModifiers = modifiers
            guard !horizontalFlushScheduled else { return }
            horizontalFlushScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let dx = self.pendingDeltaX
                let mods = self.pendingHorizontalModifiers
                self.pendingDeltaX = 0
                self.horizontalFlushScheduled = false
                guard dx != 0, let handler = self.onHorizontalScroll else { return }
                handler(dx, mods)
            }
        }
    }
}

private final class SelectedTextCopyMenuItem: NSMenuItem {
    private let text: String
    private let pasteboard: NSPasteboard

    init(text: String, pasteboard: NSPasteboard) {
        self.text = text
        self.pasteboard = pasteboard
        super.init(title: "Copy", action: #selector(copySelection), keyEquivalent: "c")
        target = self
        keyEquivalentModifierMask = [.command]
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported for SelectedTextCopyMenuItem")
    }

    @objc private func copySelection() {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
