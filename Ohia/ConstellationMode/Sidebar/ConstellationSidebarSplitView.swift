import SwiftUI
import AppKit
import QuartzCore

struct ConstellationSidebarSplitView<Sidebar: View, Detail: View>: NSViewRepresentable {
    let placement: ConstellationSidebarPlacement
    @Binding var sidebarWidth: Double
    let minSidebarWidth: CGFloat
    let maxSidebarWidth: CGFloat
    /// Current slide phase (open / opening / closing). Drives the AppKit divider
    /// animation that slides the panel in and out.
    let slidePhase: SidebarSlidePhase
    /// Duration of each slide direction, in seconds.
    let slideDuration: Double
    /// Called once an opening slide has fully extended the panel.
    let onSlideOpened: () -> Void
    /// Called once a closing slide has fully retracted the panel to width 0, so
    /// the container can unmount the split.
    let onSlideClosed: () -> Void
    let onDetailFrameChange: (CGRect) -> Void
    let onSidebarWidthCommit: (CGFloat) -> Void
    let sidebar: () -> Sidebar
    let detail: () -> Detail

    func makeNSView(context: Context) -> SplitNSView<Sidebar, Detail> {
        let view = SplitNSView(sidebar: sidebar(), detail: detail())
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: SplitNSView<Sidebar, Detail>, context: Context) {
        let widthBinding = $sidebarWidth
        nsView.configure(
            placement: placement,
            sidebar: sidebar(),
            detail: detail(),
            preferredSidebarWidth: CGFloat(sidebarWidth),
            minSidebarWidth: minSidebarWidth,
            maxSidebarWidth: maxSidebarWidth,
            slidePhase: slidePhase,
            slideDuration: slideDuration,
            onSlideOpened: onSlideOpened,
            onSlideClosed: onSlideClosed,
            onDetailFrameChange: onDetailFrameChange,
            onSidebarWidthCommit: { width in
                let clampedWidth = min(max(width, minSidebarWidth), maxSidebarWidth)
                if abs(widthBinding.wrappedValue - Double(clampedWidth)) > 0.5 {
                    widthBinding.wrappedValue = Double(clampedWidth)
                }
                onSidebarWidthCommit(clampedWidth)
            }
        )
    }
}

final class SplitNSView<Sidebar: View, Detail: View>: NSSplitView {
    private let sidebarHost: NSHostingView<Sidebar>
    private let detailHost: NSHostingView<Detail>
    private let splitDelegate = SidebarSplitDelegateProxy<Sidebar, Detail>()
    private var currentPlacement: ConstellationSidebarPlacement?
    private var preferredSidebarWidth: CGFloat = 380
    private var minSidebarWidth: CGFloat = 300
    private var maxSidebarWidth: CGFloat = 640
    private var onDetailFrameChange: ((CGRect) -> Void)?
    private var onSidebarWidthCommit: ((CGFloat) -> Void)?
    private var lastPublishedDetailFrame: CGRect = .null
    private var isApplyingDividerPosition = false
    private var isDraggingDivider = false
    private var isDividerHovered = false
    private var dividerTrackingArea: NSTrackingArea?
    private var lastTrackedDividerRect: NSRect = .null
    private var localMouseMonitor: Any?

    // MARK: Slide animation
    //
    // The panel slides in/out by stepping the divider position each tick of a
    // common-mode timer, easing the sidebar width between 0 and the preferred
    // width over `slideTotalDuration`. Stepping the real divider (rather than a
    // Core Animation proxy) means each frame relayouts the split, so the detail's
    // Metal scene reflows in lockstep with the panel — a synchronized slide, not
    // a structural pop. `isAnimatingSlide` suppresses the preferred-width snap and
    // relaxes the min/max divider constraints so the width can travel down to 0.
    private var lastHandledSlidePhase: SidebarSlidePhase = .closed
    private var slideTimer: Timer?
    private var slideStartTime: CFTimeInterval = 0
    private var slideTotalDuration: CFTimeInterval = 1
    private var slideFromWidth: CGFloat = 0
    private var slideToWidth: CGFloat = 0
    private var lastAppliedSlideWidth: CGFloat = 0
    private var slideCompletion: (() -> Void)?
    private var isAnimatingSlide = false
    private var hasActiveSlide = false
    private var slideIsClosing = false
    /// True while the sidebar is fully collapsed (phase `.closed`). The split stays
    /// mounted so the detail/scene is never rebuilt, but the sidebar pane is parked
    /// at width 0 and the divider is suppressed, so it reads as detail-only.
    private var isClosed = false
    /// The divider is user-interactive only after the opening slide has settled.
    /// AppKit otherwise keeps the collapsed divider's effective drag rect alive.
    private var isSidebarResizable = false

    init(sidebar: Sidebar, detail: Detail) {
        sidebarHost = NSHostingView(rootView: sidebar)
        detailHost = NSHostingView(rootView: detail)
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        wantsLayer = true
        applySpaceBackground()
        splitDelegate.owner = self
        delegate = splitDelegate
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySpaceBackground()
    }

    /// Fill the split's own backing — which shows only in the divider gutter (and,
    /// while the sidebar is collapsed, the thin inset where the 0-width pane sits) —
    /// with the space background, so that gutter reads seamlessly against the panel
    /// and the scene in both light and dark.
    private func applySpaceBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(OhiaColors.spaceBackground).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var dividerThickness: CGFloat {
        10
    }

    deinit {
        removeLocalMouseMonitor()
        slideTimer?.invalidate()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        removeLocalMouseMonitor()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installLocalMouseMonitorIfNeeded()
        reconcileDividerHover()
        // The window may resolve a different effective appearance than the app
        // default the layer was first filled with; re-apply against it.
        applySpaceBackground()
    }

    func configure(
        placement: ConstellationSidebarPlacement,
        sidebar: Sidebar,
        detail: Detail,
        preferredSidebarWidth: CGFloat,
        minSidebarWidth: CGFloat,
        maxSidebarWidth: CGFloat,
        slidePhase: SidebarSlidePhase,
        slideDuration: Double,
        onSlideOpened: @escaping () -> Void,
        onSlideClosed: @escaping () -> Void,
        onDetailFrameChange: @escaping (CGRect) -> Void,
        onSidebarWidthCommit: @escaping (CGFloat) -> Void
    ) {
        sidebarHost.rootView = sidebar
        detailHost.rootView = detail
        self.minSidebarWidth = minSidebarWidth
        self.maxSidebarWidth = maxSidebarWidth
        self.onDetailFrameChange = onDetailFrameChange
        self.onSidebarWidthCommit = onSidebarWidthCommit

        // Hand the divider to the slide logic (relaxed min/max constraints, no
        // preferred-width snap) BEFORE laying out subviews, so the initial
        // `installSubviews` doesn't snap to the preferred width and flash a
        // fully-open panel before the slide collapses it. The `.closed` case must
        // hold even when the phase DIDN'T change: a default-closed launch never
        // runs `handleSlidePhase`, so this is the only thing that lets `layout()`
        // park the pane at 0 rather than `constrainMinCoordinate` clamping it open.
        let phaseChanged = slidePhase != lastHandledSlidePhase
        isClosed = slidePhase == .closed
        let wasSidebarResizable = isSidebarResizable
        isSidebarResizable = slidePhase == .open
        if wasSidebarResizable != isSidebarResizable {
            setDividerHovered(false)
            window?.invalidateCursorRects(for: self)
        }
        if isClosed || (phaseChanged && (slidePhase == .opening || slidePhase == .closing)) {
            isAnimatingSlide = true
        }

        installSubviews(for: placement)

        let clampedPreferredWidth = clampSidebarWidth(preferredSidebarWidth)
        if abs(self.preferredSidebarWidth - clampedPreferredWidth) > 0.5 {
            self.preferredSidebarWidth = clampedPreferredWidth
            applyPreferredSidebarWidthIfPossible()
        }

        if phaseChanged {
            lastHandledSlidePhase = slidePhase
            handleSlidePhase(slidePhase, duration: slideDuration, onOpened: onSlideOpened, onClosed: onSlideClosed)
        }
        publishDetailFrameIfNeeded()
    }

    override func layout() {
        super.layout()
        if isClosed {
            // Hold the collapsed sidebar parked at 0 each layout pass, overriding
            // any width AppKit would otherwise restore. Guarded against the
            // reentrant layout `setPosition` triggers.
            if !isApplyingDividerPosition, abs(actualSidebarWidth) > 0.5 {
                setSidebarWidthImmediately(0)
            }
        } else {
            applyPreferredSidebarWidthIfPossible()
        }
        publishDetailFrameIfNeeded()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        // Rebuild the divider's hover tracking area ONLY when its rect actually
        // moves. The constellation HUD drives frequent layout passes; rebuilding
        // the area on every pass churned it and dropped the occasional
        // mouseExited, leaving the hover accent stuck on (it read as a permanent
        // yellow line). A stable area makes enter/exit reliable during normal
        // pointer movement.
        let rect = dividerRect
        if dividerTrackingArea == nil || lastTrackedDividerRect != rect {
            if let dividerTrackingArea {
                removeTrackingArea(dividerTrackingArea)
            }
            let area = NSTrackingArea(
                rect: rect,
                options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            dividerTrackingArea = area
            lastTrackedDividerRect = rect
        }
        // Backstop: reconcile the hover flag against the live cursor position so
        // a dropped exit can never leave the accent stuck.
        reconcileDividerHover()
        super.updateTrackingAreas()
    }

    /// Recompute `isDividerHovered` from the real cursor position and repaint on
    /// change. Self-heals any enter/exit event AppKit dropped, guaranteeing the
    /// accent hairline appears only while the pointer is over the divider.
    private func reconcileDividerHover(windowLocation: NSPoint? = nil) {
        guard !isDraggingDivider else { return }
        if let windowLocation {
            setDividerHovered(dividerRect.contains(convert(windowLocation, from: nil)))
        } else if let window, window.isKeyWindow {
            setDividerHovered(dividerRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        } else {
            setDividerHovered(false)
        }
    }

    private func setDividerHovered(_ hovered: Bool, invalidatesDisplay: Bool = true) {
        guard hovered != isDividerHovered else { return }
        isDividerHovered = hovered
        if invalidatesDisplay {
            needsDisplay = true
        }
    }

    private func reconcileDividerHoverForCurrentDraw() {
        guard !isDraggingDivider else { return }
        if let window, window.isKeyWindow {
            setDividerHovered(
                dividerRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)),
                invalidatesDisplay: false
            )
        } else {
            setDividerHovered(false, invalidatesDisplay: false)
        }
    }

    private func installLocalMouseMonitorIfNeeded() {
        guard localMouseMonitor == nil, window != nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.dividerHoverEventMask) { [weak self] event in
            guard let self, let window = self.window else { return event }
            if event.window === window {
                self.reconcileDividerHover(windowLocation: event.locationInWindow)
            } else if window.isKeyWindow {
                self.reconcileDividerHover()
            } else {
                self.setDividerHovered(false)
            }
            return event
        }
    }

    private func removeLocalMouseMonitor() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(dividerRect, cursor: .resizeLeftRight)
    }

    override func mouseEntered(with event: NSEvent) {
        setDividerHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDraggingDivider else { return }
        setDividerHovered(false)
    }

    override func mouseMoved(with event: NSEvent) {
        reconcileDividerHover()
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard dividerRect.contains(location) else {
            super.mouseDown(with: event)
            return
        }

        isDraggingDivider = true
        setDividerHovered(true)
        super.mouseDown(with: event)
        isDraggingDivider = false
        reconcileDividerHover()
        preferredSidebarWidth = actualSidebarWidth
        onSidebarWidthCommit?(actualSidebarWidth)
        needsDisplay = true
    }

    override func drawDivider(in rect: NSRect) {
        // No hairline while collapsed — the sidebar pane is width 0 and the panel
        // reads as detail-only.
        guard !isClosed else { return }
        reconcileDividerHoverForCurrentDraw()
        let width: CGFloat = isDraggingDivider || isDividerHovered ? 2 : 1
        let lineRect = NSRect(
            x: rect.midX - (width / 2),
            y: rect.minY,
            width: width,
            height: rect.height
        )
        ohiaDividerColor.setFill()
        lineRect.fill()
    }

    fileprivate func constrainMinCoordinate(_ proposedMinimumPosition: CGFloat) -> CGFloat {
        guard bounds.width > 0 else { return proposedMinimumPosition }
        // During a slide the panel travels down to width 0, below the normal
        // minimum — let the animator place the divider anywhere in [0, width].
        if isAnimatingSlide { return 0 }
        switch currentPlacement {
        case .leading:
            return minSidebarWidth
        case .trailing:
            return max(0, bounds.width - maxSidebarWidth - dividerThickness)
        case nil:
            return proposedMinimumPosition
        }
    }

    fileprivate func constrainMaxCoordinate(_ proposedMaximumPosition: CGFloat) -> CGFloat {
        guard bounds.width > 0 else { return proposedMaximumPosition }
        if isAnimatingSlide { return bounds.width }
        switch currentPlacement {
        case .leading:
            return min(maxSidebarWidth, bounds.width - minSidebarWidth - dividerThickness)
        case .trailing:
            return max(0, bounds.width - minSidebarWidth - dividerThickness)
        case nil:
            return proposedMaximumPosition
        }
    }

    fileprivate func effectiveDividerRect(_ proposedRect: NSRect) -> NSRect {
        isSidebarResizable ? proposedRect : .zero
    }

    /// Neutral at rest; active accent while hovered or dragging, matching the
    /// resize affordance expected for both Search/Ask and Withheld panels.
    private var ohiaDividerColor: NSColor {
        isDraggingDivider || isDividerHovered
            ? Self.dividerActiveColor
            : Self.dividerRestColor
    }

    private var dividerRect: NSRect {
        // Closed or sliding: no divider to hit, hover, or show a resize cursor over.
        guard isSidebarResizable, subviews.count >= 2 else { return .zero }
        return NSRect(
            x: subviews[0].frame.maxX,
            y: bounds.minY,
            width: dividerThickness,
            height: bounds.height
        )
    }

    private var actualSidebarWidth: CGFloat {
        sidebarHost.frame.width
    }

    private func publishDetailFrameIfNeeded() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let frame = detailFrameInTopLeftCoordinates()
        guard frame.width > 1, frame.height > 1 else { return }
        guard lastPublishedDetailFrame == .null
            || abs(lastPublishedDetailFrame.minX - frame.minX) > 0.5
            || abs(lastPublishedDetailFrame.minY - frame.minY) > 0.5
            || abs(lastPublishedDetailFrame.width - frame.width) > 0.5
            || abs(lastPublishedDetailFrame.height - frame.height) > 0.5 else {
            return
        }
        lastPublishedDetailFrame = frame
        Task { @MainActor [onDetailFrameChange] in
            onDetailFrameChange?(frame)
        }
    }

    private func detailFrameInTopLeftCoordinates() -> CGRect {
        let frame = detailHost.frame
        return CGRect(
            x: frame.minX,
            y: bounds.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func installSubviews(for placement: ConstellationSidebarPlacement) {
        guard currentPlacement != placement || subviews.count != 2 else { return }
        sidebarHost.removeFromSuperview()
        detailHost.removeFromSuperview()

        switch placement {
        case .leading:
            addArrangedSubview(sidebarHost)
            addArrangedSubview(detailHost)
        case .trailing:
            addArrangedSubview(detailHost)
            addArrangedSubview(sidebarHost)
        }
        if let sidebarIndex = subviews.firstIndex(where: { $0 === sidebarHost }) {
            setHoldingPriority(.defaultHigh, forSubviewAt: sidebarIndex)
        }
        currentPlacement = placement
        applyPreferredSidebarWidthIfPossible(force: true)
    }

    private func applyPreferredSidebarWidthIfPossible(force: Bool = false) {
        // While a slide is in flight (or has just finished closing, before the
        // SwiftUI unmount) the divider position is owned by the animator — never
        // snap it back to the preferred width.
        guard !isAnimatingSlide else { return }
        guard !isDraggingDivider, !isApplyingDividerPosition, bounds.width > 0, subviews.count == 2 else { return }
        let targetWidth = clampSidebarWidth(preferredSidebarWidth)
        guard force || abs(actualSidebarWidth - targetWidth) > 1 else { return }

        isApplyingDividerPosition = true
        switch currentPlacement {
        case .leading:
            setPosition(targetWidth, ofDividerAt: 0)
        case .trailing:
            setPosition(max(0, bounds.width - targetWidth - dividerThickness), ofDividerAt: 0)
        case nil:
            break
        }
        isApplyingDividerPosition = false
    }

    private func clampSidebarWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return minSidebarWidth }
        return min(max(width, minSidebarWidth), maxSidebarWidth)
    }

    // MARK: - Slide animation

    private func handleSlidePhase(
        _ phase: SidebarSlidePhase,
        duration: Double,
        onOpened: @escaping () -> Void,
        onClosed: @escaping () -> Void
    ) {
        switch phase {
        case .opening:
            startSlide(open: true, duration: duration, completion: onOpened)
        case .closing:
            startSlide(open: false, duration: duration, completion: onClosed)
        case .open:
            // Settle fully open: stop any in-flight slide and resume normal,
            // user-resizable divider behavior at the preferred width.
            cancelSlide()
            isAnimatingSlide = false
            applyPreferredSidebarWidthIfPossible(force: true)
            publishDetailFrameIfNeeded()
        case .closed:
            // Park the sidebar fully collapsed. Keep the divider owned by the slide
            // logic (`isAnimatingSlide` relaxes the min/max constraints and stops
            // the preferred-width snap) so it stays at 0, and repaint to drop the
            // suppressed divider hairline.
            cancelSlide()
            isAnimatingSlide = true
            setSidebarWidthImmediately(0)
            publishDetailFrameIfNeeded()
            needsDisplay = true
        }
    }

    /// Begin sliding the panel toward open (preferred width) or closed (width 0).
    /// A fresh open starts collapsed at the edge; a fresh close starts from the
    /// live width; a reversal mid-slide continues from wherever the panel is.
    private func startSlide(open: Bool, duration: Double, completion: @escaping () -> Void) {
        let target = open ? clampSidebarWidth(preferredSidebarWidth) : 0
        let from: CGFloat = hasActiveSlide
            ? lastAppliedSlideWidth
            : (open ? 0 : actualSidebarWidth)

        cancelSlideTimer()
        isAnimatingSlide = true
        hasActiveSlide = true
        slideIsClosing = !open
        slideFromWidth = from
        slideToWidth = target
        slideTotalDuration = max(0.0001, duration)
        slideStartTime = CACurrentMediaTime()
        slideCompletion = completion
        lastAppliedSlideWidth = from

        // Snap to the start width synchronously so the first displayed frame is
        // the collapsed edge (open) rather than a flash of the full panel.
        setSidebarWidthImmediately(from)
        publishDetailFrameIfNeeded()
        startSlideTimer()
    }

    private func slideStep() {
        guard bounds.width > 0, subviews.count == 2 else {
            // No valid layout yet — hold the clock at the start so the panel
            // doesn't jump partway through once the view is finally sized.
            slideStartTime = CACurrentMediaTime()
            return
        }
        let elapsed = CACurrentMediaTime() - slideStartTime
        let t = min(1, max(0, elapsed / slideTotalDuration))
        let eased = CGFloat(Self.easeInOut(t))
        let width = slideFromWidth + (slideToWidth - slideFromWidth) * eased
        lastAppliedSlideWidth = width
        setSidebarWidthImmediately(width)
        publishDetailFrameIfNeeded()
        if t >= 1 { finishSlide() }
    }

    private func finishSlide() {
        cancelSlideTimer()
        lastAppliedSlideWidth = slideToWidth
        setSidebarWidthImmediately(slideToWidth)
        publishDetailFrameIfNeeded()
        hasActiveSlide = false
        // On open, resume normal resize behavior. On close, KEEP `isAnimatingSlide`
        // set: the panel is at width 0 and the SwiftUI unmount lands a moment later,
        // so any layout pass in between must not snap it back to the preferred width.
        if !slideIsClosing { isAnimatingSlide = false }
        let completion = slideCompletion
        slideCompletion = nil
        // Defer the callback so it doesn't mutate SwiftUI state mid-layout.
        DispatchQueue.main.async { completion?() }
    }

    private func cancelSlide() {
        cancelSlideTimer()
        hasActiveSlide = false
        slideCompletion = nil
    }

    private func startSlideTimer() {
        cancelSlideTimer()
        // Common-mode so it keeps firing during tracking/scroll; the eased value
        // is derived from wall-clock elapsed time, so an irregular cadence still
        // lands precisely at the duration.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.slideStep()
        }
        RunLoop.main.add(timer, forMode: .common)
        slideTimer = timer
    }

    private func cancelSlideTimer() {
        slideTimer?.invalidate()
        slideTimer = nil
    }

    /// Place the divider so the sidebar occupies `width`, mapping per placement.
    /// Constraints are relaxed while `isAnimatingSlide`, so width may be 0.
    private func setSidebarWidthImmediately(_ width: CGFloat) {
        guard bounds.width > 0, subviews.count == 2 else { return }
        let clamped = min(max(0, width), bounds.width)
        isApplyingDividerPosition = true
        switch currentPlacement {
        case .leading:
            setPosition(clamped, ofDividerAt: 0)
        case .trailing:
            setPosition(max(0, bounds.width - clamped - dividerThickness), ofDividerAt: 0)
        case nil:
            break
        }
        isApplyingDividerPosition = false
    }

    /// Cubic ease-in-out: slow off the edge, quick through the middle, soft into
    /// place — no overshoot, lands exactly at t = 1.
    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private static var dividerRestColor: NSColor {
        dynamicDividerColor(
            light: NSColor(white: 0, alpha: 0.15),
            dark: NSColor(white: 1, alpha: 0.15)
        )
    }

    private static var dividerActiveColor: NSColor {
        dynamicDividerColor(
            light: NSColor(srgbRed: 0.31, green: 0.518, blue: 0.063, alpha: 0.55),
            dark: NSColor(srgbRed: 248 / 255, green: 248 / 255, blue: 56 / 255, alpha: 0.55)
        )
    }

    private static var dividerHoverEventMask: NSEvent.EventTypeMask {
        [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .leftMouseUp,
            .rightMouseUp,
            .otherMouseUp
        ]
    }

    private static func dynamicDividerColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [
                .darkAqua,
                .vibrantDark,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark
            ]) != nil
            return isDark ? dark : light
        }
    }

    #if DEBUG
    var isDividerHoveredForTesting: Bool {
        isDividerHovered
    }

    func setDividerHoveredForTesting(_ hovered: Bool) {
        setDividerHovered(hovered)
    }

    func reconcileDividerHoverForTesting(pointInView: NSPoint?) {
        guard !isDraggingDivider else { return }
        setDividerHovered(pointInView.map { dividerRect.contains($0) } ?? false)
    }
    #endif
}

private final class SidebarSplitDelegateProxy<Sidebar: View, Detail: View>: NSObject, NSSplitViewDelegate {
    weak var owner: SplitNSView<Sidebar, Detail>?

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        owner?.constrainMinCoordinate(proposedMinimumPosition) ?? proposedMinimumPosition
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        owner?.constrainMaxCoordinate(proposedMaximumPosition) ?? proposedMaximumPosition
    }

    func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        owner?.effectiveDividerRect(proposedEffectiveRect) ?? proposedEffectiveRect
    }
}
