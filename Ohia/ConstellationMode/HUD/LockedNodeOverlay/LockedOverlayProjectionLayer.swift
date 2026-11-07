import AppKit
import Combine
import SwiftUI
import simd
import OhiaCore

@MainActor
protocol LockedOverlayProjectionInvalidationSink: AnyObject {
    func lockedOverlayProjectionDidChange()
}

@MainActor
final class LockedOverlayProjectionDriver {
    private weak var view: LockedOverlayProjectionNSView?
    private let invalidationSinks = NSHashTable<AnyObject>.weakObjects()
    private var latestCamera: CameraState = .identity
    private var hasCamera = false

    func attach(_ view: LockedOverlayProjectionNSView, fallbackCamera: CameraState) {
        self.view = view
        if !hasCamera {
            latestCamera = fallbackCamera
            hasCamera = true
        }
        view.updateCamera(latestCamera, force: true)
    }

    func detach(_ view: LockedOverlayProjectionNSView) {
        if self.view === view {
            self.view = nil
        }
    }

    func attachInvalidationSink(_ sink: any LockedOverlayProjectionInvalidationSink) {
        invalidationSinks.add(sink)
    }

    func detachInvalidationSink(_ sink: any LockedOverlayProjectionInvalidationSink) {
        invalidationSinks.remove(sink)
    }

    func update(camera: CameraState) {
        latestCamera = camera
        hasCamera = true
        view?.updateCamera(camera)
        for object in invalidationSinks.allObjects {
            (object as? any LockedOverlayProjectionInvalidationSink)?
                .lockedOverlayProjectionDidChange()
        }
    }
}

/// Sink that latches "the camera is actively re-projecting" into an
/// observable flag. `isLive` flips on with the first invalidation and
/// settles back off `settleDelay` after they stop arriving, so the
/// overlay can run its timeline at frame cadence only while the camera
/// is actually producing new frames. The settle delay keeps the flag
/// high through sustained steering (invalidations keep re-arming it) —
/// a naive pause would freeze tracking chrome mid-gesture. The driver's
/// `update(camera:)` is fed from the Metal view's camera-change path,
/// which goes silent when the scene is at rest.
@MainActor
final class LockedOverlayProjectionActivity: ObservableObject, LockedOverlayProjectionInvalidationSink {
    @Published private(set) var isLive = false
    private let settleDelay: Duration
    private var settleTask: Task<Void, Never>?

    init(settleDelay: Duration = .milliseconds(250)) {
        self.settleDelay = settleDelay
    }

    func lockedOverlayProjectionDidChange() {
        if isLive == false {
            isLive = true
        }
        settleTask?.cancel()
        settleTask = Task { [weak self, settleDelay] in
            try? await Task.sleep(for: settleDelay)
            guard Task.isCancelled == false else { return }
            self?.isLive = false
        }
    }
}

/// Geometric reconciliation between the Metal-rendered viewport and the
/// AppKit projection layer that draws the reticle / tether / leaders on
/// top of it. The Metal `MTKView` is mounted with `.ignoresSafeArea()` so
/// it can extend into the title-bar region; this projection NSView, by
/// design, must NOT (or it would draw the lock card / annotation panes
/// under the title bar). When the two views have different bounds the
/// reticle drifts off the rendered dot — the renderer projects with the
/// taller Metal viewport, the NSView with the shorter overlay viewport,
/// so identical world points land at different screen Ys.
///
/// `size` is the Metal viewport's bounds (the same size used by the
/// renderer to build its projection matrix). `originOffset` is the
/// vector pointing from the Metal viewport's local origin to the
/// projection NSView's local origin in the same window space.
struct LockedOverlayProjectionViewport: Equatable {
    let size: CGSize
    let originOffset: CGSize

    /// Builds the Metal-aligned viewport for an overlay whose local bounds
    /// are `overlaySceneSize`. Returns `nil` when either size is unusable.
    static func aligned(
        metalViewSize: CGSize,
        overlaySceneSize: CGSize
    ) -> LockedOverlayProjectionViewport? {
        guard metalViewSize.width > 1,
              metalViewSize.height > 1,
              overlaySceneSize.width > 1,
              overlaySceneSize.height > 1 else {
            return nil
        }
        return LockedOverlayProjectionViewport(
            size: metalViewSize,
            originOffset: CGSize(
                width: metalViewSize.width - overlaySceneSize.width,
                height: metalViewSize.height - overlaySceneSize.height
            )
        )
    }

    func project(
        world: SIMD3<Float>,
        camera: CameraState,
        fovYRadians: Float = Float.pi / 3
    ) -> CGPoint? {
        guard size.width > 1, size.height > 1 else { return nil }
        guard let point = ScreenProjection.project(
            world: world,
            camera: camera,
            viewSize: size,
            fovYRadians: fovYRadians
        ) else { return nil }
        return CGPoint(
            x: point.x - originOffset.width,
            y: point.y - originOffset.height
        )
    }
}

struct LockedOverlayProjectionSnapshot {
    struct AnnotationLeader: Identifiable {
        struct Rank: Equatable {
            let bestSimilarity: Float
            let threshold: Float
        }

        let id: String
        let anchorWorld: SIMD3<Float>
        /// Screen-space anchor latched at the moment the current wormhole
        /// phase started. When non-nil, the projection layer skips the
        /// per-frame world→screen reprojection so the leader's start point
        /// stays put while the camera warps. Cleared once the phase
        /// completes so the leader resumes tracking the camera.
        let latchedScreenAnchor: CGPoint?
        let rect: CGRect
        let accent: NSColor
        let opacity: Double
        let phase: WormholePhase?
        let rank: Rank?
    }

    /// Main lock anchor source. Keep this world-space only: cached
    /// screen-space anchors drift away from the rendered Metal node as
    /// soon as the camera moves.
    let lockedWorld: SIMD3<Float>?
    let coordReadout: String?
    let cardFrame: CGRect
    let showsCardTether: Bool
    let lockAccent: NSColor
    let lockOpacity: Double
    let annotationOpacity: Double
    let annotationLeaders: [AnnotationLeader]
    /// Optional override identifying the Metal viewport this projection
    /// layer should align with. When `nil`, the NSView projects using its
    /// own `bounds.size` with no offset — correct only when the projection
    /// NSView and the Metal view share bounds.
    let projectionViewport: LockedOverlayProjectionViewport?
}

struct LockedOverlayProjectionLayer: NSViewRepresentable {
    let driver: LockedOverlayProjectionDriver
    let snapshot: LockedOverlayProjectionSnapshot
    let initialCamera: CameraState

    func makeCoordinator() -> Coordinator {
        Coordinator(driver: driver)
    }

    func makeNSView(context: Context) -> LockedOverlayProjectionNSView {
        let view = LockedOverlayProjectionNSView()
        view.configure(snapshot: snapshot)
        context.coordinator.attach(view, fallbackCamera: initialCamera)
        return view
    }

    func updateNSView(_ nsView: LockedOverlayProjectionNSView, context: Context) {
        nsView.configure(snapshot: snapshot)
        context.coordinator.attach(nsView, fallbackCamera: initialCamera)
    }

    static func dismantleNSView(_ nsView: LockedOverlayProjectionNSView, coordinator: Coordinator) {
        coordinator.detach(nsView)
    }

    @MainActor
    final class Coordinator {
        private let driver: LockedOverlayProjectionDriver

        init(driver: LockedOverlayProjectionDriver) {
            self.driver = driver
        }

        func attach(_ view: LockedOverlayProjectionNSView, fallbackCamera: CameraState) {
            driver.attach(view, fallbackCamera: fallbackCamera)
        }

        func detach(_ view: LockedOverlayProjectionNSView) {
            driver.detach(view)
        }
    }
}

final class LockedOverlayProjectionNSView: NSView {
    private static let fovYRadians = Float.pi / 3
    private static let minimumDisplayInterval: CFTimeInterval = 1.0 / 60.0
    private static let subpixelThreshold: CGFloat = 0.5
    private static let forcePixelThreshold: CGFloat = 4

    private var snapshot: LockedOverlayProjectionSnapshot?
    private var camera: CameraState = .identity
    private var lastProjectedPoints: [CGPoint] = []
    private var lastDisplayTime: CFTimeInterval = 0
    private var redrawScheduled = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        postsFrameChangedNotifications = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(snapshot: LockedOverlayProjectionSnapshot) {
        self.snapshot = snapshot
        lastProjectedPoints = []
        needsDisplay = true
    }

    func updateCamera(_ camera: CameraState, force: Bool = false) {
        self.camera = camera
        guard force || shouldDisplay(for: camera) else { return }
        needsDisplay = true
    }

    private func scheduleAnimationRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.minimumDisplayInterval))
            guard let self else { return }
            self.redrawScheduled = false
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let snapshot,
              let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let now = Date.now
        var needsAnimationRedraw = false

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        if let point = lockedPoint(for: snapshot) {
            if snapshot.showsCardTether {
                drawLockTether(
                    from: point,
                    to: snapshot.cardFrame,
                    accent: snapshot.lockAccent,
                    opacity: snapshot.lockOpacity,
                    in: context
                )
            }
            drawReticle(
                center: point,
                accent: snapshot.lockAccent,
                opacity: snapshot.lockOpacity,
                in: context
            )
            if let coordReadout = snapshot.coordReadout {
                drawCoordReadout(
                    coordReadout,
                    at: point,
                    accent: snapshot.lockAccent,
                    opacity: snapshot.lockOpacity,
                    in: context
                )
            }
        }

        for leader in snapshot.annotationLeaders {
            // Latched screen anchor wins over a per-frame reprojection while
            // the wormhole phase is in flight; otherwise track the camera.
            let resolvedAnchor: CGPoint?
            if let latched = leader.latchedScreenAnchor {
                resolvedAnchor = latched
            } else {
                resolvedAnchor = project(leader.anchorWorld)
            }
            guard let anchor = resolvedAnchor else { continue }
            let phaseSample = leader.phase?.at(now)
            if phaseSample?.isComplete == false {
                needsAnimationRedraw = true
            }
            let lineProgress = phaseSample?.leaderProgress ?? 1
            let lineOpacity = leader.opacity
                * snapshot.annotationOpacity
                * (phaseSample?.leaderOpacity ?? 1)
            guard lineProgress > 0.001, lineOpacity > 0.001 else { continue }
            drawReticle(
                center: anchor,
                accent: leader.accent,
                opacity: lineOpacity,
                in: context
            )
            // While closing, the pane is being dragged toward the anchor by
            // `paneTowardAnchor`. Translate the rect we hand to the line
            // drawer by the same amount so the line's terminal edge tracks
            // the pane in motion — otherwise the line would still terminate
            // at the pane's original layout rect while the pane itself is
            // visibly elsewhere on the journey to the wormhole.
            let towardAnchor = phaseSample?.paneTowardAnchor ?? 0
            let leaderRect: CGRect
            if towardAnchor > 0 {
                let dx = (anchor.x - leader.rect.midX) * towardAnchor
                let dy = (anchor.y - leader.rect.midY) * towardAnchor
                leaderRect = leader.rect.offsetBy(dx: dx, dy: dy)
            } else {
                leaderRect = leader.rect
            }
            if let rank = leader.rank {
                drawAffinityRankLeader(
                    from: anchor,
                    to: leaderRect,
                    accent: leader.accent,
                    opacity: lineOpacity,
                    progress: lineProgress,
                    bestSimilarity: rank.bestSimilarity,
                    threshold: rank.threshold,
                    in: context
                )
            } else {
                drawAnnotationLeader(
                    from: anchor,
                    to: leaderRect,
                    accent: leader.accent,
                    opacity: lineOpacity,
                    progress: lineProgress,
                    in: context
                )
            }
        }

        context.restoreGState()

        if needsAnimationRedraw {
            scheduleAnimationRedraw()
        }
    }

    private func shouldDisplay(for camera: CameraState) -> Bool {
        let points = projectedPoints(for: camera)
        let now = CACurrentMediaTime()

        guard !points.isEmpty else {
            let hadVisiblePoints = !lastProjectedPoints.isEmpty
            lastProjectedPoints = []
            if hadVisiblePoints {
                lastDisplayTime = now
            }
            return hadVisiblePoints
        }

        guard !lastProjectedPoints.isEmpty else {
            lastProjectedPoints = points
            lastDisplayTime = now
            return true
        }

        guard points.count == lastProjectedPoints.count else {
            lastProjectedPoints = points
            lastDisplayTime = now
            return true
        }

        let maxDelta = zip(points, lastProjectedPoints)
            .map { lhs, rhs in hypot(lhs.x - rhs.x, lhs.y - rhs.y) }
            .max() ?? 0

        if maxDelta < Self.subpixelThreshold {
            return false
        }

        if now - lastDisplayTime < Self.minimumDisplayInterval,
           maxDelta < Self.forcePixelThreshold {
            return false
        }

        lastProjectedPoints = points
        lastDisplayTime = now
        return true
    }

    private func projectedPoints(for camera: CameraState) -> [CGPoint] {
        guard let snapshot else { return [] }
        var points: [CGPoint] = []
        let viewport = effectiveViewport(for: snapshot)
        if let lockedWorld = snapshot.lockedWorld,
           let point = Self.project(
            lockedWorld,
            camera: camera,
            viewport: viewport
           ) {
            points.append(point)
        }
        for leader in snapshot.annotationLeaders {
            // Latched leaders don't track the camera, so we exclude them from
            // the camera-change detector — otherwise a camera tick would
            // schedule a redraw even though their on-screen position is fixed.
            if leader.latchedScreenAnchor != nil { continue }
            if let point = Self.project(
                leader.anchorWorld,
                camera: camera,
                viewport: viewport
            ) {
                points.append(point)
            }
        }
        return points
    }

    private func project(_ world: SIMD3<Float>) -> CGPoint? {
        guard let snapshot else {
            return Self.project(
                world,
                camera: camera,
                viewport: LockedOverlayProjectionViewport(
                    size: bounds.size,
                    originOffset: .zero
                )
            )
        }
        return Self.project(
            world,
            camera: camera,
            viewport: effectiveViewport(for: snapshot)
        )
    }

    private func effectiveViewport(
        for snapshot: LockedOverlayProjectionSnapshot
    ) -> LockedOverlayProjectionViewport {
        if let viewport = snapshot.projectionViewport,
           viewport.size.width > 1,
           viewport.size.height > 1 {
            return viewport
        }
        return LockedOverlayProjectionViewport(
            size: bounds.size,
            originOffset: .zero
        )
    }

    private func lockedPoint(for snapshot: LockedOverlayProjectionSnapshot) -> CGPoint? {
        guard let lockedWorld = snapshot.lockedWorld else {
            return nil
        }
        return project(lockedWorld)
    }

    private static func project(
        _ world: SIMD3<Float>,
        camera: CameraState,
        viewport: LockedOverlayProjectionViewport
    ) -> CGPoint? {
        viewport.project(
            world: world,
            camera: camera,
            fovYRadians: fovYRadians
        )
    }

    /// Terminates the leader on the popup's near-edge midpoint, matching
    /// `AnnotationLeader` and `AffinityRankLeader` so the dashed line
    /// reaches the pane whether it sits above, below, or beside the node.
    private func annotationLeaderEdgePoint(from anchor: CGPoint, to rect: CGRect) -> CGPoint {
        let edgeX = anchor.x <= rect.midX ? rect.minX : rect.maxX
        return CGPoint(x: edgeX, y: rect.midY)
    }

    private func drawLockTether(
        from anchor: CGPoint,
        to cardFrame: CGRect,
        accent: NSColor,
        opacity: Double,
        in context: CGContext
    ) {
        let edgeX = anchor.x <= cardFrame.midX ? cardFrame.minX : cardFrame.maxX
        drawDashedLine(
            from: anchor,
            to: CGPoint(x: edgeX, y: cardFrame.midY),
            color: accent,
            opacity: opacity,
            in: context
        )
    }

    private func drawAnnotationLeader(
        from anchor: CGPoint,
        to rect: CGRect,
        accent: NSColor,
        opacity: Double,
        progress: Double,
        in context: CGContext
    ) {
        let edgePoint = annotationLeaderEdgePoint(from: anchor, to: rect)
        drawDashedLine(
            from: anchor,
            to: interpolatedPoint(from: anchor, to: edgePoint, progress: progress),
            color: accent,
            opacity: opacity,
            in: context
        )
    }

    private func drawAffinityRankLeader(
        from anchor: CGPoint,
        to rect: CGRect,
        accent: NSColor,
        opacity: Double,
        progress: Double,
        bestSimilarity: Float,
        threshold: Float,
        in context: CGContext
    ) {
        let edgePoint = annotationLeaderEdgePoint(from: anchor, to: rect)
        let denominator = max(0.0001, 1.0 - Double(threshold))
        let normalized = max(0.0, min(1.0, (Double(bestSimilarity) - Double(threshold)) / denominator))
        let scorePoint = CGPoint(
            x: anchor.x + (edgePoint.x - anchor.x) * CGFloat(normalized),
            y: anchor.y + (edgePoint.y - anchor.y) * CGFloat(normalized)
        )
        let clampedProgress = max(0, min(1, progress))
        let drawnEndPoint = interpolatedPoint(from: anchor, to: edgePoint, progress: clampedProgress)
        let scoreProgress = max(0, min(1, normalized))

        if clampedProgress > scoreProgress {
            context.saveGState()
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [2, 3])
            context.setStrokeColor(resolved(accent, alpha: opacity * 0.55).cgColor)
            context.move(to: scorePoint)
            context.addLine(to: drawnEndPoint)
            context.strokePath()
            context.restoreGState()
        }

        context.saveGState()
        context.setLineWidth(0.6)
        context.setStrokeColor(resolved(accent, alpha: opacity * 0.85).cgColor)
        drawAffinityTicks(from: anchor, to: edgePoint, maxFraction: clampedProgress, in: context)
        context.strokePath()
        context.restoreGState()

        context.saveGState()
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        context.setStrokeColor(resolved(accent, alpha: opacity).cgColor)
        context.move(to: anchor)
        context.addLine(to: clampedProgress <= scoreProgress ? drawnEndPoint : scorePoint)
        context.strokePath()
        context.restoreGState()
    }

    private func drawAffinityTicks(
        from anchor: CGPoint,
        to edgePoint: CGPoint,
        maxFraction: Double,
        in context: CGContext
    ) {
        let dx = edgePoint.x - anchor.x
        let dy = edgePoint.y - anchor.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let perpX = -dy / length
        let perpY = dx / length
        let halfLength: CGFloat = 4
        for fraction in [0.25, 0.5, 0.75] as [CGFloat] {
            guard Double(fraction) <= maxFraction else { continue }
            let center = CGPoint(
                x: anchor.x + dx * fraction,
                y: anchor.y + dy * fraction
            )
            context.move(to: CGPoint(
                x: center.x - perpX * halfLength,
                y: center.y - perpY * halfLength
            ))
            context.addLine(to: CGPoint(
                x: center.x + perpX * halfLength,
                y: center.y + perpY * halfLength
            ))
        }
    }

    private func interpolatedPoint(from start: CGPoint, to end: CGPoint, progress: Double) -> CGPoint {
        let clamped = max(0, min(1, progress))
        return CGPoint(
            x: start.x + (end.x - start.x) * CGFloat(clamped),
            y: start.y + (end.y - start.y) * CGFloat(clamped)
        )
    }

    private func drawDashedLine(
        from start: CGPoint,
        to end: CGPoint,
        color: NSColor,
        opacity: Double,
        in context: CGContext
    ) {
        context.saveGState()
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [2, 3])
        context.setStrokeColor(resolved(color, alpha: opacity).cgColor)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
    }

    private func drawReticle(center: CGPoint, accent: NSColor, opacity: Double, in context: CGContext) {
        context.saveGState()
        context.setLineWidth(1)
        context.setStrokeColor(resolved(accent, alpha: 0.85 * opacity).cgColor)
        let geometry = LockNodeReticleGeometry(center: center, side: 60, bracketLength: 12)
        for segment in geometry.cornerSegments {
            context.move(to: segment.0)
            context.addLine(to: segment.1)
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawCoordReadout(
        _ text: String,
        at anchor: CGPoint,
        accent: NSColor,
        opacity: Double,
        in context: CGContext
    ) {
        // Matches `OhiaTypography.coordReadout` (10.5pt) so the Metal-drawn
        // pill stays geometrically consistent with the SwiftUI
        // `LockNodeCoordReadout` rendering at the same coordinate.
        let font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: resolved(accent, alpha: opacity)
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let background = CGRect(
            x: anchor.x - textSize.width / 2 - 6,
            y: anchor.y + 42 - textSize.height / 2 - 2,
            width: textSize.width + 12,
            height: textSize.height + 4
        ).integral

        context.saveGState()
        context.setFillColor(resolved(LockedOverlayProjectionColors.surface, alpha: 0.18 * opacity).cgColor)
        context.addPath(CGPath(roundedRect: background, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()
        context.setStrokeColor(resolved(accent, alpha: 0.55 * opacity).cgColor)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: background.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.strokePath()
        context.restoreGState()

        attributed.draw(at: CGPoint(x: background.minX + 6, y: background.minY + 2))
    }

    private func resolved(_ color: NSColor, alpha: Double? = nil) -> NSColor {
        var converted: NSColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            converted = color.usingColorSpace(NSColorSpace.deviceRGB)
        }
        let resolved = converted ?? color
        guard let alpha else { return resolved }
        return resolved.withAlphaComponent(resolved.alphaComponent * CGFloat(alpha))
    }
}

enum LockedOverlayProjectionColors {
    static let chipActiveBorder = dynamicColor(
        light: srgb(112 / 255, 184 / 255, 24 / 255, 0.60),
        dark: srgb(248 / 255, 248 / 255, 56 / 255, 0.60)
    )
    static let chipActiveForeground = dynamicColor(
        light: srgb(0.31, 0.518, 0.063),
        dark: srgb(248 / 255, 248 / 255, 56 / 255)
    )
    static let surface = dynamicColor(
        light: NSColor(white: 0, alpha: 1),
        dark: NSColor(white: 1, alpha: 1)
    )

    static func accent(for kind: AnnotationKind) -> NSColor {
        // `.mainEmail` falls through to a static pink fallback. Live
        // focal-message projection paths (tether, reticle, coord
        // readout) route through `LockedNodeOverlay.lockAccentNSColor`,
        // which derives from the per-account hue — no live render path
        // reads this branch for `.mainEmail`.
        guard let index = kind.paletteIndex else {
            return dynamicColor(
                light: srgb(0.66, 0.23, 0.49),
                dark: srgb(0.80, 0.40, 0.67)
            )
        }
        // Routes through `AnnotationKind.nsColor(forPaletteIndex:)` so
        // SwiftUI chips and the CGContext-drawn leaders share one
        // dynamic NSColor — same envelope, same sRGB triple — and the
        // mode-aware brightness/saturation switch lands in both render
        // paths simultaneously.
        return AnnotationKind.nsColor(forPaletteIndex: index)
    }

    private static func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
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

    private static func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
}
