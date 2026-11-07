import AppKit
import MetalKit
import SwiftUI
import simd
import OhiaCore

struct ConstellationMetalRedrawPolicy {
    /// Keep Meaning's expensive metaball bodies off briefly after camera
    /// movement so wheel/trackpad event gaps don't re-enable the body pass
    /// mid-gesture.
    static let meaningClusterMetaballSettleDelay: TimeInterval = 0.18
    static let meaningClusterPointerHoverPickInterval: TimeInterval = 1.0 / 30.0

    static func preferredFramesPerSecond(lowPowerModeEnabled: Bool) -> Int {
        lowPowerModeEnabled ? 30 : 60
    }

    @MainActor
    static func applyDrawingMode(continuousRedrawActive: Bool, in view: MTKView) {
        // MetalKit's timed mode requires BOTH flags false; notification
        // drawing requires BOTH true. Keep event-loop invalidation disabled
        // while timed updates own the cadence. Switch modes without
        // scheduling another clock.
        if continuousRedrawActive {
            if view.enableSetNeedsDisplay { view.enableSetNeedsDisplay = false }
            if view.isPaused { view.isPaused = false }
        } else {
            if view.isPaused == false { view.isPaused = true }
            if view.enableSetNeedsDisplay == false { view.enableSetNeedsDisplay = true }
        }
    }

    @MainActor
    static func requestEventDrivenDraw(in view: MTKView) {
        // The next timed frame consumes updated input, buffers and hover
        // state while continuous rendering is active. A paused view needs
        // this explicit wake to draw once and, if needed, resume its clock.
        guard view.isPaused, view.enableSetNeedsDisplay else { return }
        view.setNeedsDisplay(view.bounds)
    }

    static func drawsPeopleOrbitPaths(
        showsOrbitPaths: Bool,
        pathCount: Int,
        degradationTier: RenderDegradationTier
    ) -> Bool {
        showsOrbitPaths
            && pathCount > 0
            && degradationTier < .aggregateHeavy
    }

    static func requiresContinuousRedraw(
        sourceWarpActive: Bool,
        hasShimmeringPersonRing: Bool,
        peopleContextDimAnimating: Bool = false,
        peopleOrbitalMotionActive: Bool = false,
        warpAnimatorActive: Bool = false,
        cameraMotionActive: Bool = false,
        apertureMotionActive: Bool = false,
        signalPulsesActive: Bool = false,
        settlePending: Bool = false
    ) -> Bool {
        sourceWarpActive
            || hasShimmeringPersonRing
            || peopleContextDimAnimating
            || peopleOrbitalMotionActive
            || warpAnimatorActive
            || cameraMotionActive
            || apertureMotionActive
            || signalPulsesActive
            || settlePending
    }

    /// Whether a camera-projection change should re-resolve the hover
    /// hit-test under a resting cursor. During animated flights the world
    /// sweeps beneath a stationary pointer, so a "hover" resolved mid-flight
    /// names a body the user never pointed at and anchors a popup the lock
    /// lifecycle immediately discards — flights and Meaning's live camera
    /// motion therefore suppress re-resolution. A locked People portrait
    /// also suppresses resting-cursor re-picks during manual camera motion;
    /// its dedicated overlay tracker still handles real pointer events.
    static func refreshesHoverOnCameraChange(
        warpAnimatorActive: Bool,
        sourceWarpActive: Bool,
        cameraMotionActive: Bool = false,
        suppressDuringMeaningCameraMotion: Bool = false,
        suppressDuringLockedPeopleCameraMotion: Bool = false
    ) -> Bool {
        guard warpAnimatorActive == false,
              sourceWarpActive == false else {
            return false
        }
        if cameraMotionActive,
           suppressDuringMeaningCameraMotion || suppressDuringLockedPeopleCameraMotion {
            return false
        }
        return true
    }

    /// Raw mouse-moved events can arrive faster than the display cadence.
    /// Hover resolution fans out into host-side work (popup anchoring,
    /// readout rebuilds), so cluster-heavy Meaning packets coalesce it to a
    /// frame-scale cadence. People remains immediate because hover is the
    /// solar system's motion damper.
    static func resolvesPointerHoverImmediately(
        now: TimeInterval,
        lastPickTime: TimeInterval,
        meaningClusterHubCount: Int,
        personSunActive: Bool
    ) -> Bool {
        guard meaningClusterHubCount > 0, personSunActive == false else { return true }
        return now - lastPickTime >= meaningClusterPointerHoverPickInterval
    }

    /// Keep the Meaning lens focused on its cluster landmarks. The nuclei,
    /// diffraction glows, member stars, and connections carry the cluster
    /// structure without the broad metaball bodies obscuring adjacent groups.
    static func drawsMeaningClusterMetaballBodies(
        hubCount _: Int,
        clusterVisibility _: Float,
        cameraMotionActive _: Bool,
        sourceWarpActive _: Bool,
        secondsSinceCameraMotion _: TimeInterval = .infinity
    ) -> Bool {
        false
    }

    static func isWaitingForMeaningClusterMetaballSettle(
        hubCount: Int,
        clusterVisibility: Float,
        cameraMotionActive: Bool,
        sourceWarpActive: Bool,
        secondsSinceCameraMotion: TimeInterval
    ) -> Bool {
        hubCount > 0
            && clusterVisibility > 0.001
            && sourceWarpActive == false
            && cameraMotionActive == false
            && secondsSinceCameraMotion < meaningClusterMetaballSettleDelay
    }
}

/// Frame-rate-independent descriptor of the live-lock field-collapse warp.
/// The host arms one of these when a lock transition begins and clears it at
/// release; the Metal draw loop derives the per-frame `ConstellationSourceWarp`
/// value itself via `warp(at:)`. Passing the descriptor (which changes twice
/// per transition) instead of the per-frame value (which changed every tick)
/// is what keeps SwiftUI from re-evaluating the whole scene subtree at 60Hz
/// for the duration of every lock entry and exit.
public struct ConstellationSourceWarpDrive: Equatable {
    let id: Int
    let startedAt: Date
    let duration: TimeInterval
    let directionSign: Float
    let fieldDimTarget: Float?
    /// Every live-lock warp fades Meaning clusters toward 0 (the locked
    /// endpoint), in both directions — exit reverses via the same
    /// phase-progress flip as the dim. Carried on the drive, not read from
    /// the packet, so the entry ramp is correct before the async
    /// lock-flagged refresh installs the visibility-0 packet (planner
    /// latency scales with the scene).
    let meaningClusterVisibilityTarget: Float?

    func warp(at date: Date) -> ConstellationSourceWarp {
        let progress: Float
        if duration > 0 {
            let elapsed = date.timeIntervalSince(startedAt)
            progress = Float(min(1, max(0, elapsed / duration)))
        } else {
            progress = 1
        }
        let phaseProgress = directionSign < 0 ? 1 - progress : progress
        return ConstellationSourceWarp(
            intensity: 1,
            phase: LiveMetalFocusTransitionPolicy.fieldDimPhase(progress: phaseProgress),
            fieldDimTarget: fieldDimTarget,
            meaningClusterVisibilityTarget: meaningClusterVisibilityTarget
        )
    }
}

public struct ConstellationMetalView: NSViewRepresentable {
    public let renderer: ConstellationMetalRenderer
    public let packet: ConstellationRenderPacket
    @ObservedObject public var cameraController: CameraController
    @ObservedObject public var flightInput: FlightInputHandler
    public let warpAnimator: WarpAnimator
    public let sourceWarpDrive: ConstellationSourceWarpDrive?
    public let peopleContextDimAnimating: Bool
    /// Orbital clock + mouse-damping state machine for the People solar
    /// system. Nil hosts (or non-solar packets) render statically.
    public let orbitalMotion: PeopleOrbitalMotionController?
    /// Settled-lock state from the host's lock lifecycle (locked message,
    /// locked correspondent portrait, or a pending focus click). Freezes
    /// the orbital clock for the whole life of the lock so overlay
    /// anchors, telemetry, and ring interactions read stable geometry.
    public let peopleLockActive: Bool
    /// Controls only the engraved People orbit paths and recency guides.
    /// Correspondent bodies, Saturn rings, message nodes, and orbital motion
    /// remain present when this is false.
    public let showsPeopleOrbitPaths: Bool
    /// Mirrored from the host's process-power notification so a paused,
    /// event-driven MTKView does not depend on a future draw to notice the
    /// system frame-rate policy changed.
    public let lowPowerModeEnabled: Bool
    public let onHover: (HitProxy?, CGPoint) -> Void
    public let onClick: (HitProxy?, CGPoint) -> Void
    /// Right-click: receives the hit-tested proxy (nil for empty space),
    /// the click point in the source NSView's bottom-left coordinate
    /// space (suitable for `NSMenu.popUp(positioning:at:in:)`), and a
    /// reference to the source view so the caller can pop a context menu.
    public let onRightClick: (HitProxy?, CGPoint, NSView) -> Void
    public let onApertureDelta: (Float) -> Void
    /// `(keyCode, modifierFlags) -> consumed`. Modifier flags are passed
    /// through so consumers can distinguish chords like Tab vs. Shift+Tab,
    /// which the locked-overlay rank-step navigator uses for forward /
    /// backward stepping.
    public let onKeyDown: (UInt16, NSEvent.ModifierFlags) -> Bool
    public let onCameraProjectionChange: @MainActor () -> Void
    public let onViewSizeChange: @MainActor (CGSize) -> Void
    public let onPacketDrawn: @MainActor (ConstellationMetalFrameStats) -> Void
    public let onFrameStats: @MainActor (ConstellationMetalFrameStats) -> Void
    public let acceptsWithheldDrop: Bool
    public let onWithheldDropTargeted: @MainActor (Bool) -> Void
    public let onWithheldRowsDrop: @MainActor ([String]) -> Void
    public let onWithheldDropEnded: @MainActor () -> Void
    /// When false, the Coordinator silently drops drag / scroll / magnify
    /// and keyDown / keyUp events so the camera and aperture stay frozen.
    /// Used by the onboarding witness state where the user is meant to
    /// passively observe node formation.
    public let inputEnabled: Bool
    /// When true the drawable clears to fully transparent and the backing
    /// layer is marked non-opaque, so a SwiftUI view placed behind this
    /// Metal view (e.g. the People / Meanings `NightSkyView` backdrop)
    /// shows through the empty space between nodes. Off by default, so
    /// any other mount keeps its opaque near-black clear.
    public let transparentBackground: Bool

    public init(
        renderer: ConstellationMetalRenderer,
        packet: ConstellationRenderPacket,
        cameraController: CameraController,
        flightInput: FlightInputHandler,
        warpAnimator: WarpAnimator,
        sourceWarpDrive: ConstellationSourceWarpDrive? = nil,
        peopleContextDimAnimating: Bool = false,
        orbitalMotion: PeopleOrbitalMotionController? = nil,
        peopleLockActive: Bool = false,
        showsPeopleOrbitPaths: Bool = true,
        lowPowerModeEnabled: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        onHover: @escaping (HitProxy?, CGPoint) -> Void,
        onClick: @escaping (HitProxy?, CGPoint) -> Void,
        onRightClick: @escaping (HitProxy?, CGPoint, NSView) -> Void,
        onApertureDelta: @escaping (Float) -> Void,
        onKeyDown: @escaping (UInt16, NSEvent.ModifierFlags) -> Bool = { _, _ in false },
        onCameraProjectionChange: @escaping @MainActor () -> Void = {},
        onViewSizeChange: @escaping @MainActor (CGSize) -> Void,
        onPacketDrawn: @escaping @MainActor (ConstellationMetalFrameStats) -> Void = { _ in },
        onFrameStats: @escaping @MainActor (ConstellationMetalFrameStats) -> Void,
        acceptsWithheldDrop: Bool = false,
        onWithheldDropTargeted: @escaping @MainActor (Bool) -> Void = { _ in },
        onWithheldRowsDrop: @escaping @MainActor ([String]) -> Void = { _ in },
        onWithheldDropEnded: @escaping @MainActor () -> Void = {},
        inputEnabled: Bool = true,
        transparentBackground: Bool = false
    ) {
        self.renderer = renderer
        self.packet = packet
        self.cameraController = cameraController
        self.flightInput = flightInput
        self.warpAnimator = warpAnimator
        self.sourceWarpDrive = sourceWarpDrive
        self.peopleContextDimAnimating = peopleContextDimAnimating
        self.orbitalMotion = orbitalMotion
        self.peopleLockActive = peopleLockActive
        self.showsPeopleOrbitPaths = showsPeopleOrbitPaths
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.onHover = onHover
        self.onClick = onClick
        self.onRightClick = onRightClick
        self.onApertureDelta = onApertureDelta
        self.onKeyDown = onKeyDown
        self.onCameraProjectionChange = onCameraProjectionChange
        self.onViewSizeChange = onViewSizeChange
        self.onPacketDrawn = onPacketDrawn
        self.onFrameStats = onFrameStats
        self.acceptsWithheldDrop = acceptsWithheldDrop
        self.onWithheldDropTargeted = onWithheldDropTargeted
        self.onWithheldRowsDrop = onWithheldRowsDrop
        self.onWithheldDropEnded = onWithheldDropEnded
        self.inputEnabled = inputEnabled
        self.transparentBackground = transparentBackground
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> InputMetalView {
        let view = InputMetalView(frame: .zero, device: renderer.metalDevice)
        view.delegate = context.coordinator
        view.inputDelegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        // Depth attachment enables proper z-test for the 3D person-hub
        // planets in the People lens. Other lenses don't use depth-writing
        // pipelines so they render as before (cleared depth = 1.0, every
        // `less` test passes). Cleared once per frame in the standard
        // MTKView path; no manual pass-descriptor management needed.
        view.depthStencilPixelFormat = .depth32Float
        view.clearDepth = 1.0
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.preferredFramesPerSecond = ConstellationMetalRedrawPolicy.preferredFramesPerSecond(
            lowPowerModeEnabled: lowPowerModeEnabled
        )
        // Drives the clear colour + backing-layer opacity. When true the
        // drawable clears to transparent and the CAMetalLayer is marked
        // non-opaque, so the SwiftUI `NightSkyView` behind this view shows
        // through the empty space between nodes. Applied via the view's own
        // setter so it survives MTKView re-finalising its layer on window
        // attach (setting it once here, pre-window, gets reset to opaque).
        view.rendersTransparentBackground = transparentBackground
        view.registerForDraggedTypes([WithheldRowDragPayload.pasteboardType])
        context.coordinator.install(packet: packet, in: view)
        context.coordinator.requestDraw(in: view)
        renderer.onGlyphAtlasReady = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.requestDraw(in: view)
        }
        // Engaging a warp from an async Task (e.g. rank-step Tab) lands
        // outside the input runloop pass, so without this hook there's no
        // `setNeedsDisplay` to kick the draw loop and the warp animator
        // would sit at `isWarping=true` without ever ticking. The draw
        // loop self-sustains once running (see `Coordinator.draw`), so we
        // only need to wake it once per engagement.
        warpAnimator.onEngageRequested = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.requestDraw(in: view)
        }
        // The orbital resume ramp fires when a hover release's grace
        // window elapses — usually while the MTKView sits paused with
        // nothing else scheduling frames. The controller's wake pokes the
        // draw loop exactly once; the loop then self-sustains through
        // `isAnimating`.
        orbitalMotion?.onWakeNeeded = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.requestDraw(in: view)
        }
        return view
    }

    public func updateNSView(_ nsView: InputMetalView, context: Context) {
        context.coordinator.update(self, view: nsView)
    }

#if DEBUG
    public static func dismantleNSView(_ nsView: InputMetalView, coordinator: Coordinator) {
        coordinator.stopPresentationSampling(in: nsView)
    }
#endif

    @MainActor
    public final class Coordinator: NSObject, MTKViewDelegate, InputMetalViewDelegate {
        private var parent: ConstellationMetalView
        private var lastPacketGeneratedAt: TimeInterval = .nan
        private var lastDrawnPacketGeneratedAt: TimeInterval = .nan
        private var lastFrameTime = CACurrentMediaTime()
        private var lastStatsTime = CACurrentMediaTime()
        private var lastViewSize: CGSize = .zero
        private var lastSourceWarpDrive: ConstellationSourceWarpDrive?
        private var lastPeopleContextDimAnimating = false
        private var lastShowsPeopleOrbitPaths: Bool
        private var lastHover: HitProxy?
        private var lastHoverPoint: CGPoint?
        private var lastHoverPickTime: TimeInterval = -.infinity
        private var pendingHoverPickPoint: CGPoint?
        private var pendingHoverPickTask: Task<Void, Never>?
        private var hoverSuppressionWasActive = false
        private var meaningPointerHoverSuppressed = false
        private var lastCameraProjectionSignature: CameraProjectionSignature?
        private var lastMeaningCameraMotionTime: TimeInterval = -.infinity

        init(_ parent: ConstellationMetalView) {
            self.parent = parent
            lastShowsPeopleOrbitPaths = parent.showsPeopleOrbitPaths
        }

        deinit {
            pendingHoverPickTask?.cancel()
        }

        func update(_ parent: ConstellationMetalView, view: MTKView) {
            self.parent = parent
            lastInputView = view
            let preferredFramesPerSecond = ConstellationMetalRedrawPolicy.preferredFramesPerSecond(
                lowPowerModeEnabled: parent.lowPowerModeEnabled
            )
            if view.preferredFramesPerSecond != preferredFramesPerSecond {
                view.preferredFramesPerSecond = preferredFramesPerSecond
            }
            install(packet: parent.packet, in: view)
        }

        func install(packet: ConstellationRenderPacket, in view: MTKView) {
            lastInputView = view
            var needsDraw = false
            if lastPacketGeneratedAt != packet.generatedAt {
                parent.renderer.update(packet: packet)
                lastPacketGeneratedAt = packet.generatedAt
                needsDraw = true
            }
            let size = CGSize(width: view.bounds.width, height: view.bounds.height)
            if size != lastViewSize {
                lastViewSize = size
                parent.onViewSizeChange(size)
                needsDraw = true
            }
            if parent.sourceWarpDrive != lastSourceWarpDrive {
                lastSourceWarpDrive = parent.sourceWarpDrive
                needsDraw = true
            }
            if parent.peopleContextDimAnimating != lastPeopleContextDimAnimating {
                lastPeopleContextDimAnimating = parent.peopleContextDimAnimating
                needsDraw = true
            }
            if parent.showsPeopleOrbitPaths != lastShowsPeopleOrbitPaths {
                lastShowsPeopleOrbitPaths = parent.showsPeopleOrbitPaths
                needsDraw = true
            }
            // Flip the MTKView between paused (event-driven redraw) and
            // unpaused (display-link continuous redraw) based on whether
            // the surface needs smooth frame-to-frame updates. Four
            // production surfaces need this:
            //   * an active focused source warp, whose phase changes at the
            //     transition cadence and should never depend on sparse
            //     event-driven redraws;
            //   * a WarpAnimator camera flight (lock entry/exit, rank-step,
            //     search-match glides) — without the display link its frames
            //     depend on the setNeedsDisplay chain, which slips whenever
            //     the main runloop pass is busy;
            //   * the focused-correspondent ring trim-sweep glisten
            //     (`shimmer = true` on the locked hub's ring instances);
            //   * the People portrait context-dim ramp, which updates only a
            //     renderer uniform after the focused packet installs.
            //
            // The People-hub orb itself (iridescence shader) is static —
            // its rim hue rotation is driven by viewing angle, not time
            // — so people hubs alone do NOT require continuous redraw.
            // Falls back to event-driven redraw (the default) when
            // no animated surface is present so a static People
            // lens or a stars-only scene doesn't burn frames. The draw
            // loop mirrors this flip each frame (see `draw(in:)`) because
            // warps can engage from async tasks with no SwiftUI update to
            // run this install path.
            let continuousRedrawActive = ConstellationMetalRedrawPolicy.requiresContinuousRedraw(
                sourceWarpActive: parent.sourceWarpDrive != nil,
                hasShimmeringPersonRing: packet.personRings.contains(where: \.shimmer),
                peopleContextDimAnimating: parent.peopleContextDimAnimating,
                peopleOrbitalMotionActive: packet.personSun != nil
                    && (parent.orbitalMotion?.isAnimating ?? false),
                warpAnimatorActive: parent.warpAnimator.isWarping,
                cameraMotionActive: (parent.inputEnabled && parent.flightInput.hasActiveInput)
                    || parent.cameraController.state.isMovingForConstellationDisplay,
                signalPulsesActive: parent.renderer.scenePulsesSignals,
                settlePending: parent.renderer.pulseRestSettling
            )
#if DEBUG
            parent.renderer.setPresentationSamplingActive(
                continuousRedrawActive, framesPerSecond: view.preferredFramesPerSecond
            )
#endif
            ConstellationMetalRedrawPolicy.applyDrawingMode(
                continuousRedrawActive: continuousRedrawActive, in: view
            )
            if needsDraw {
                requestDraw(in: view)
            }
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            lastViewSize = CGSize(width: view.bounds.width, height: view.bounds.height)
            parent.onViewSizeChange(lastViewSize)
            requestDraw(in: view)
        }

        public func draw(in view: MTKView) {
            let now = CACurrentMediaTime()
            let preferredFramesPerSecond = ConstellationMetalRedrawPolicy.preferredFramesPerSecond(
                lowPowerModeEnabled: parent.lowPowerModeEnabled
            )
            if view.preferredFramesPerSecond != preferredFramesPerSecond {
                view.preferredFramesPerSecond = preferredFramesPerSecond
            }
            let dt = Float(min(1.0 / 20.0, max(1.0 / 240.0, now - lastFrameTime)))
            lastFrameTime = now

            // One warp sample per frame. The drive descriptor is constant
            // for the life of a transition, so the per-frame phase is
            // derived here in the draw loop instead of being pushed through
            // a SwiftUI re-evaluation every tick.
            let sourceWarpDrive = parent.sourceWarpDrive
            let sourceWarp = sourceWarpDrive?.warp(at: Date.now)

            let acceptsInput = parent.inputEnabled
            let hadActiveInput = acceptsInput && parent.flightInput.hasActiveInput
            let warping = parent.warpAnimator.tick()
            if acceptsInput && warping == false {
                let command = parent.flightInput.consumeCommand()
                parent.cameraController.integrate(command: command, dt: dt)
                let orbit = parent.flightInput.consumeOrbitDelta(dt: dt)
                if orbit.yaw != 0 || orbit.pitch != 0,
                   let anchor = orbitAnchor() {
                    parent.cameraController.orbit(
                        around: anchor,
                        yawDelta: orbit.yaw,
                        pitchDelta: orbit.pitch
                    )
                }
            }

            let apertureDelta = acceptsInput
                ? parent.flightInput.consumeApertureDelta()
                : 0
            if apertureDelta != 0 {
                parent.onApertureDelta(apertureDelta)
            }

            // Shader-side signal pulses (search / citation / selected) are
            // time-driven, so the scene keeps redrawing while the installed
            // packet lights any of those channels. The renderer computes
            // the predicate once per packet install; membership changes
            // arrive as new packets, so no per-frame host callback is
            // involved.
            let highlightsActive = parent.renderer.scenePulsesSignals
            let cameraState = parent.cameraController.state

            // People solar system: advance the orbital clock through the
            // damper. Programmatic flights and lock transitions freeze the
            // clock transiently (a flight must land on a non-moving
            // target); the settled-lock freeze is owned by the host view's
            // lock lifecycle.
            var peopleOrbitalTime: TimeInterval?
            let solarSystemActive = parent.packet.personSun != nil
            if solarSystemActive, let motion = parent.orbitalMotion {
                motion.setLockFrozen(parent.peopleLockActive)
                motion.setFlightFrozen(warping || parent.warpAnimator.isWarping || sourceWarpDrive != nil)
                peopleOrbitalTime = motion.advance().clock
            } else if let motion = parent.orbitalMotion {
                // Non-solar packet: `updateHover` gates its damper feed on
                // the solar packet, so a hover engaged at the moment the
                // lens switched away would stay latched and hold the
                // system stopped on return to People. Any non-solar frame
                // releases it; the controller's transition guard makes
                // this a free no-op after the first frame.
                motion.setHoverEngaged(false)
            }

            let liveWarpAnimatorActive = parent.warpAnimator.isWarping
            let activeInputAfterConsume = acceptsInput && parent.flightInput.hasActiveInput
            let cameraMotionActive = warping
                || liveWarpAnimatorActive
                || hadActiveInput
                || activeInputAfterConsume
                || cameraState.isMovingForConstellationDisplay
            let effectiveMeaningClusterVisibility = ConstellationMetalRenderer.effectiveMeaningClusterVisibility(
                target: parent.packet.meaningClusterVisibility,
                sourceWarp: sourceWarp
            )
            let meaningClusterHubCount = parent.packet.meaningClusterHubs.count
            if meaningClusterHubCount > 0, cameraMotionActive {
                lastMeaningCameraMotionTime = now
            }
            let secondsSinceMeaningCameraMotion = now - lastMeaningCameraMotionTime
            let drawMeaningClusterMetaballBodies = ConstellationMetalRedrawPolicy.drawsMeaningClusterMetaballBodies(
                hubCount: meaningClusterHubCount,
                clusterVisibility: effectiveMeaningClusterVisibility,
                cameraMotionActive: cameraMotionActive,
                sourceWarpActive: sourceWarpDrive != nil,
                secondsSinceCameraMotion: secondsSinceMeaningCameraMotion
            )
            let meaningMetaballSettlePending = ConstellationMetalRedrawPolicy.isWaitingForMeaningClusterMetaballSettle(
                hubCount: meaningClusterHubCount,
                clusterVisibility: effectiveMeaningClusterVisibility,
                cameraMotionActive: cameraMotionActive,
                sourceWarpActive: sourceWarpDrive != nil,
                secondsSinceCameraMotion: secondsSinceMeaningCameraMotion
            )
            // In a settled People lock, ring-node hover is owned by the
            // overlay's world-space tracker. Re-running the generic renderer
            // pick scan under a resting cursor on every manual camera frame
            // duplicates that work and competes with camera integration on
            // the main actor. Programmatic/source-warp flights keep their
            // existing clear-on-entry behavior.
            let lockedPeopleManualCameraMotion = parent.peopleLockActive
                && parent.packet.personHubs.isEmpty == false
                && liveWarpAnimatorActive == false
                && sourceWarpDrive == nil
                && cameraMotionActive
            // A programmatic flight, lock transition, or live Meaning camera
            // motion invalidates resting-cursor hover. The camera is sweeping
            // the world beneath the pointer, and the popup's anchor is a
            // function of (cursor, camera) — a mid-flight re-resolution names
            // a body the user never pointed at. Clear once on the engagement
            // edge so no popup freezes mid-air. Hover returns on the next
            // pointer move, matching hover's pointer-gesture semantics; there is
            // deliberately no re-resolution until Meaning's metaball settle
            // grace has expired, which keeps short wheel-event gaps from
            // repeatedly clearing hover state. An active `projectedHoverTarget`
            // survives this clear via the host's nil-proxy early return.
            let hoverRefreshAllowed = ConstellationMetalRedrawPolicy.refreshesHoverOnCameraChange(
                warpAnimatorActive: liveWarpAnimatorActive,
                sourceWarpActive: sourceWarpDrive != nil,
                cameraMotionActive: cameraMotionActive || meaningMetaballSettlePending,
                suppressDuringMeaningCameraMotion: meaningClusterHubCount > 0,
                suppressDuringLockedPeopleCameraMotion: lockedPeopleManualCameraMotion
            )
            meaningPointerHoverSuppressed = isMeaningPointerHoverSuppressed(
                hoverRefreshAllowed: hoverRefreshAllowed,
                meaningClusterHubCount: meaningClusterHubCount
            )
            if meaningPointerHoverSuppressed {
                cancelPendingHoverPick()
            }
            if hoverRefreshAllowed == false,
               lockedPeopleManualCameraMotion == false,
               hoverSuppressionWasActive == false,
               let point = lastHoverPoint {
                cancelPendingHoverPick()
                lastHover = nil
                parent.onHover(nil, point)
                // Release the orbital damper with the popup. Hover events
                // are suppressed for a flight and there is no re-resolution
                // at landing, so a body hovered at flight start would
                // otherwise leave `hoverEngaged` latched true — and after
                // the flight's freeze lifts, a latched hover holds the
                // system at zero with no wake ever scheduled.
                if parent.packet.personSun != nil {
                    parent.orbitalMotion?.setHoverEngaged(false)
                }
            }
            hoverSuppressionWasActive = hoverRefreshAllowed == false
                && lockedPeopleManualCameraMotion == false

            parent.renderer.draw(
                in: view,
                camera: cameraState,
                sourceWarp: sourceWarp,
                peopleOrbitalTime: peopleOrbitalTime,
                showsPeopleOrbitPaths: parent.showsPeopleOrbitPaths,
                drawMeaningClusterMetaballBodies: drawMeaningClusterMetaballBodies
            )
            notifyCameraProjectionChangeIfNeeded(cameraState, in: view, hoverRefreshAllowed: hoverRefreshAllowed)

            if lastDrawnPacketGeneratedAt != lastPacketGeneratedAt {
                lastDrawnPacketGeneratedAt = lastPacketGeneratedAt
                parent.onPacketDrawn(parent.renderer.frameStats())
            }

            if now - lastStatsTime >= 0.35 {
                lastStatsTime = now
                parent.onFrameStats(parent.renderer.frameStats())
            }

            // Self-sustaining draw loop for any transition or time-dependent
            // fragment. The focused source warp changes phase during the
            // live-to-locked handoff, the focused-correspondent ring trim-sweep
            // reads `uniforms.viewportTimeScale.z`, and the People portrait dim
            // ramp updates a renderer uniform. Without
            // this clause the renderer can stop after one frame and freeze an
            // animated surface. The People-hub orb itself (iridescence shader) is
            // static, so people hubs alone still do not contribute to this trigger.
            let sustainedRedraw = ConstellationMetalRedrawPolicy.requiresContinuousRedraw(
                sourceWarpActive: sourceWarpDrive != nil,
                hasShimmeringPersonRing: parent.packet.personRings.contains(where: \.shimmer),
                peopleContextDimAnimating: parent.peopleContextDimAnimating,
                peopleOrbitalMotionActive: solarSystemActive
                    && (parent.orbitalMotion?.isAnimating ?? false),
                warpAnimatorActive: warping || liveWarpAnimatorActive,
                cameraMotionActive: cameraMotionActive,
                apertureMotionActive: apertureDelta != 0,
                signalPulsesActive: highlightsActive,
                settlePending: meaningMetaballSettlePending
            )
            // A settle tail needs display-linked frames but must not itself
            // re-arm the pulse animation, or the renderer never reaches idle.
            parent.renderer.setPulseAnimationActive(sustainedRedraw)
            let continuousRedrawActive = sustainedRedraw || parent.renderer.pulseRestSettling
            // Mirror `install()`'s paused/display-link flip from inside the
            // loop. `install()` only runs on SwiftUI updates, but warps can
            // engage from async tasks (rank-step Tab, search-match glides)
            // whose only wake is `onEngageRequested` → one event-driven
            // frame; this flip is what promotes that frame into a
            // display-link-paced flight. The symmetric flip back on the
            // frame an animation ends returns the surface to event-driven
            // redraw without waiting for the next SwiftUI pass.
#if DEBUG
            parent.renderer.setPresentationSamplingActive(
                continuousRedrawActive, framesPerSecond: view.preferredFramesPerSecond
            )
#endif
            ConstellationMetalRedrawPolicy.applyDrawingMode(
                continuousRedrawActive: continuousRedrawActive, in: view
            )

            // The MTKView display link owns every sustained animation,
            // including manual camera inertia and selection pulses. An
            // event-driven setNeedsDisplay chain bypasses its frame cadence.
        }

        func requestDraw(in view: MTKView) {
            ConstellationMetalRedrawPolicy.requestEventDrivenDraw(in: view)
        }

#if DEBUG
        func stopPresentationSampling(in view: MTKView) {
            parent.renderer.setPresentationSamplingActive(false, framesPerSecond: view.preferredFramesPerSecond)
        }
#endif

        private var acceptsLiveCameraInput: Bool {
            parent.inputEnabled
        }

        public func hover(at point: CGPoint, in view: InputMetalView) {
            let now = CACurrentMediaTime()
            let viewSize = rememberHoverPoint(point, in: view)

            guard lastHoverPoint != nil else {
                cancelPendingHoverPick()
                updateHover(
                    at: point,
                    in: view,
                    camera: parent.cameraController.state,
                    rememberedViewSize: viewSize,
                    now: now
                )
                return
            }

            if isMeaningPointerHoverSuppressedNow(now: now) {
                meaningPointerHoverSuppressed = true
                cancelPendingHoverPick()
                return
            }
            meaningPointerHoverSuppressed = false

            guard ConstellationMetalRedrawPolicy.resolvesPointerHoverImmediately(
                now: now,
                lastPickTime: lastHoverPickTime,
                meaningClusterHubCount: parent.packet.meaningClusterHubs.count,
                personSunActive: parent.packet.personSun != nil
            ) else {
                schedulePendingHoverPick(at: point, in: view, now: now)
                return
            }

            cancelPendingHoverPick()
            updateHover(
                at: point,
                in: view,
                camera: parent.cameraController.state,
                rememberedViewSize: viewSize,
                now: now
            )
        }

        private func schedulePendingHoverPick(at point: CGPoint, in view: MTKView, now: TimeInterval) {
            pendingHoverPickPoint = point

            guard pendingHoverPickTask == nil else { return }

            let elapsed = now - lastHoverPickTime
            let delay = max(0, ConstellationMetalRedrawPolicy.meaningClusterPointerHoverPickInterval - elapsed)
            pendingHoverPickTask = Task { @MainActor [weak self, weak view] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard let self, Task.isCancelled == false else { return }
                self.pendingHoverPickTask = nil
                guard let view else {
                    self.pendingHoverPickPoint = nil
                    return
                }
                self.flushPendingHoverPick(in: view)
            }
        }

        private func flushPendingHoverPick(in view: MTKView) {
            guard let point = pendingHoverPickPoint else {
                return
            }
            pendingHoverPickPoint = nil

            let now = CACurrentMediaTime()
            let viewSize = rememberHoverPoint(point, in: view)
            guard lastHoverPoint != nil else {
                updateHover(
                    at: point,
                    in: view,
                    camera: parent.cameraController.state,
                    rememberedViewSize: viewSize,
                    now: now
                )
                return
            }
            if isMeaningPointerHoverSuppressedNow(now: now) {
                meaningPointerHoverSuppressed = true
                cancelPendingHoverPick()
                return
            }
            meaningPointerHoverSuppressed = false
            guard ConstellationMetalRedrawPolicy.resolvesPointerHoverImmediately(
                now: now,
                lastPickTime: lastHoverPickTime,
                meaningClusterHubCount: parent.packet.meaningClusterHubs.count,
                personSunActive: parent.packet.personSun != nil
            ) else {
                schedulePendingHoverPick(at: point, in: view, now: now)
                return
            }
            updateHover(
                at: point,
                in: view,
                camera: parent.cameraController.state,
                rememberedViewSize: viewSize,
                now: now
            )
        }

        private func cancelPendingHoverPick() {
            pendingHoverPickTask?.cancel()
            pendingHoverPickTask = nil
            pendingHoverPickPoint = nil
        }

        private func isMeaningPointerHoverSuppressed(
            hoverRefreshAllowed: Bool,
            meaningClusterHubCount: Int
        ) -> Bool {
            hoverRefreshAllowed == false && meaningClusterHubCount > 0
        }

        private func isMeaningPointerHoverSuppressedNow(now: TimeInterval) -> Bool {
            let meaningClusterHubCount = parent.packet.meaningClusterHubs.count
            guard meaningClusterHubCount > 0 else { return false }

            let sourceWarpActive = parent.sourceWarpDrive != nil
            let cameraMotionActive = parent.warpAnimator.isWarping
                || (parent.inputEnabled && parent.flightInput.hasActiveInput)
                || parent.cameraController.state.isMovingForConstellationDisplay
            if cameraMotionActive {
                lastMeaningCameraMotionTime = now
            }
            let effectiveMeaningClusterVisibility = ConstellationMetalRenderer.effectiveMeaningClusterVisibility(
                target: parent.packet.meaningClusterVisibility,
                sourceWarp: parent.sourceWarpDrive?.warp(at: Date.now)
            )
            let meaningMetaballSettlePending = ConstellationMetalRedrawPolicy.isWaitingForMeaningClusterMetaballSettle(
                hubCount: meaningClusterHubCount,
                clusterVisibility: effectiveMeaningClusterVisibility,
                cameraMotionActive: cameraMotionActive,
                sourceWarpActive: sourceWarpActive,
                secondsSinceCameraMotion: now - lastMeaningCameraMotionTime
            )
            let hoverRefreshAllowed = ConstellationMetalRedrawPolicy.refreshesHoverOnCameraChange(
                warpAnimatorActive: parent.warpAnimator.isWarping,
                sourceWarpActive: sourceWarpActive,
                cameraMotionActive: cameraMotionActive || meaningMetaballSettlePending,
                suppressDuringMeaningCameraMotion: true
            )
            return isMeaningPointerHoverSuppressed(
                hoverRefreshAllowed: hoverRefreshAllowed,
                meaningClusterHubCount: meaningClusterHubCount
            )
        }

        /// Option-held pointer work in the Meaning lens targets clusters
        /// exclusively: the pick restricts to cluster-hub targets so hover
        /// and click never lose to the message nodes layered through the
        /// gas body. Reading the live modifier state (rather than
        /// threading it through every delegate signature) keeps the whole
        /// input surface — moves, clicks, right-clicks, and the
        /// `flagsChanged` re-dispatch — on one definition of "Option held".
        private var meaningClusterPickOnly: Bool {
            NSEvent.modifierFlags.contains(.option)
                && parent.packet.meaningClusterHubs.isEmpty == false
        }

        private func updateHover(
            at point: CGPoint,
            in view: MTKView,
            camera: CameraState,
            rememberedViewSize: CGSize? = nil,
            now: TimeInterval = CACurrentMediaTime()
        ) {
            let viewSize = rememberedViewSize ?? rememberHoverPoint(point, in: view)
            let proxy = parent.renderer.hitTest(
                at: point,
                viewSize: viewSize,
                drawableSize: view.drawableSize,
                camera: camera,
                onlyMeaningClusters: meaningClusterPickOnly
            )
            lastHoverPickTime = now
            // The agreed interaction grammar (revised 2026-07-04): hover on
            // a body is the SOLE damping input for the People solar system.
            // Resting on a node/planet/sun eases the orbits to a stop (so
            // an imminent click's target settles under the cursor); leaving
            // starts a short grace, then the gentle resume ramp. General
            // pointer movement, drags, and scrolls never damp motion.
            if parent.packet.personSun != nil {
                parent.orbitalMotion?.setHoverEngaged(proxy != nil)
            }
            if proxy != lastHover {
                lastHover = proxy
                parent.onHover(proxy, point)
                // Hover state drives renderer-side transient materials (the
                // Meaning nucleus/spike/gas flare via `lockControls.w`), and
                // the host has just updated them synchronously in `onHover`.
                // The paused, event-driven MTKView schedules no frame for
                // pointer movement on a settled scene, so without this kick
                // the flare would neither appear nor clear until an
                // unrelated wake (camera input, packet refresh).
                requestDraw(in: view)
            } else if proxy != nil {
                parent.onHover(proxy, point)
            }
        }

        public func click(at point: CGPoint, count: Int, in view: InputMetalView) {
            // Only the first click in a click-sequence acts; subsequent
            // rapid clicks (NSEvent reports clickCount >= 2) are ignored
            // so the constellation surface has no double-click affordance.
            guard count == 1 else { return }
            let proxy = parent.renderer.hitTest(
                at: point,
                viewSize: CGSize(width: view.bounds.width, height: view.bounds.height),
                drawableSize: view.drawableSize,
                camera: parent.cameraController.state,
                onlyMeaningClusters: meaningClusterPickOnly
            )
            parent.onClick(proxy, point)
        }

        public func rightClick(at point: CGPoint, in view: InputMetalView) {
            let proxy = parent.renderer.hitTest(
                at: point,
                viewSize: CGSize(width: view.bounds.width, height: view.bounds.height),
                drawableSize: view.drawableSize,
                camera: parent.cameraController.state,
                onlyMeaningClusters: meaningClusterPickOnly
            )
            // The hit-test runs in top-left-origin coords; NSMenu's
            // popUp expects bottom-left-origin coords (the standard
            // NSView coordinate space). Flip y back so the menu opens
            // exactly under the cursor.
            let menuPoint = CGPoint(x: point.x, y: view.bounds.height - point.y)
            parent.onRightClick(proxy, menuPoint, view)
        }

        public func drag(delta: CGSize, at point: CGPoint, in view: InputMetalView) {
            _ = rememberHoverPoint(point, in: view)
            guard acceptsLiveCameraInput else {
                parent.flightInput.clearBufferedInput()
                return
            }
            parent.flightInput.handleRotateDelta(delta)
            requestDrawFromInput()
        }

        public func scroll(delta: CGSize, modifiers: NSEvent.ModifierFlags, isPrecise: Bool) {
            guard acceptsLiveCameraInput else {
                parent.flightInput.clearBufferedInput()
                return
            }
            let flags = modifiers.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.option) {
                parent.flightInput.handleScrollOrbitDelta(delta, isPrecise: isPrecise)
            } else if flags.contains(.shift) {
                parent.flightInput.handleScrollPanDelta(delta, isPrecise: isPrecise)
            } else {
                parent.flightInput.handleScrollThrustDelta(delta.height)
            }
            requestDrawFromInput()
        }

        public func magnify(_ magnification: CGFloat) {
            guard acceptsLiveCameraInput else {
                parent.flightInput.clearBufferedInput()
                return
            }
            parent.flightInput.handleMagnify(magnification)
            requestDrawFromInput()
        }

        public func endMagnify() {
            guard parent.inputEnabled else { return }
            parent.flightInput.resetMagnifyBaseline()
            if acceptsLiveCameraInput {
                requestDrawFromInput()
            }
        }

        public func keyDown(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
            guard parent.inputEnabled else { return }
            if parent.onKeyDown(keyCode, modifiers) {
                requestDrawFromInput()
                return
            }
            guard acceptsLiveCameraInput else {
                parent.flightInput.clearBufferedInput()
                return
            }
            if let orbitDirection = orbitDirection(for: keyCode, modifiers: modifiers) {
                parent.flightInput.orbitKeyDown(orbitDirection)
                requestDrawFromInput()
                return
            }
            if parent.flightInput.handleApertureKeyDown(keyCode) == false {
                parent.flightInput.keyDown(keyCode)
            }
            requestDrawFromInput()
        }

        public func keyUp(_ keyCode: UInt16) {
            guard parent.inputEnabled else { return }
            parent.flightInput.orbitKeyUp(keyCode)
            parent.flightInput.keyUp(keyCode)
            if acceptsLiveCameraInput {
                requestDrawFromInput()
            }
        }

        public func withheldDropOperation(for pasteboard: NSPasteboard) -> NSDragOperation {
            guard parent.acceptsWithheldDrop,
                  WithheldRowDragPayload.hasPayload(pasteboard) else {
                parent.onWithheldDropTargeted(false)
                return []
            }
            parent.onWithheldDropTargeted(true)
            return .move
        }

        public func prepareWithheldDrop(from pasteboard: NSPasteboard) -> Bool {
            let accepts = parent.acceptsWithheldDrop
                && WithheldRowDragPayload.hasPayload(pasteboard)
            if !accepts {
                finishWithheldDrop()
            }
            return accepts
        }

        public func performWithheldDrop(from pasteboard: NSPasteboard) -> Bool {
            defer { finishWithheldDrop() }
            guard parent.acceptsWithheldDrop else { return false }
            let rowIDs = WithheldRowDragPayload.payloads(from: pasteboard).flatMap(\.rowIDs)
            guard !rowIDs.isEmpty else { return false }
            parent.onWithheldRowsDrop(rowIDs)
            return true
        }

        public func withheldDropExited() {
            parent.onWithheldDropTargeted(false)
        }

        public func finishWithheldDrop() {
            parent.onWithheldDropTargeted(false)
            parent.onWithheldDropEnded()
        }

        private func orbitDirection(
            for keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags
        ) -> FlightInputHandler.OrbitKeyDirection? {
            guard modifiers.intersection(.deviceIndependentFlagsMask).contains(.shift) else {
                return nil
            }
            switch keyCode {
            case FlightInputHandler.OrbitKeyDirection.left.keyCode:
                return .left
            case FlightInputHandler.OrbitKeyDirection.right.keyCode:
                return .right
            default:
                return nil
            }
        }

        private func orbitAnchor() -> SIMD3<Float>? {
            let stars = parent.packet.stars
            if let locked = stars.max(by: { $0.signal.lockFocus < $1.signal.lockFocus }),
               locked.signal.lockFocus > 0.001 {
                return locked.position
            }
            if let selected = stars.max(by: { $0.signal.selected < $1.signal.selected }),
               selected.signal.selected > 0.001 {
                return selected.position
            }
            if stars.isEmpty == false {
                let sum = stars.reduce(SIMD3<Float>.zero) { partial, star in
                    partial + star.position
                }
                return sum / Float(stars.count)
            }
            let proxies = parent.packet.hitProxies
            guard proxies.isEmpty == false else { return nil }
            let sum = proxies.reduce(SIMD3<Float>.zero) { partial, proxy in
                partial + proxy.worldPosition
            }
            return sum / Float(proxies.count)
        }

        private func notifyCameraProjectionChangeIfNeeded(
            _ state: CameraState,
            in view: MTKView,
            hoverRefreshAllowed: Bool
        ) {
            let signature = CameraProjectionSignature(state)
            guard signature.isMeaningfullyDifferent(from: lastCameraProjectionSignature) else { return }
            lastCameraProjectionSignature = signature
            parent.onCameraProjectionChange()
            if let point = lastHoverPoint, hoverRefreshAllowed {
                updateHover(at: point, in: view, camera: state)
            }
        }

        @discardableResult
        private func rememberHoverPoint(_ point: CGPoint, in view: MTKView) -> CGSize {
            let viewSize = CGSize(width: view.bounds.width, height: view.bounds.height)
            let isInside = point.x >= 0
                && point.y >= 0
                && point.x < viewSize.width
                && point.y < viewSize.height
            lastHoverPoint = isInside ? point : nil
            return viewSize
        }

        private func requestDrawFromInput() {
            guard let view = lastInputView else { return }
            requestDraw(in: view)
        }

        private weak var lastInputView: MTKView?
    }
}

private extension CameraState {
    var isMovingForConstellationDisplay: Bool {
        simd_length_squared(velocity) > 0.000001
            || abs(yawRate) > 0.0001
            || abs(pitchRate) > 0.0001
            || abs(rollRate) > 0.0001
    }
}

private struct CameraProjectionSignature {
    let position: SIMD3<Float>
    let yaw: Float
    let pitch: Float
    let roll: Float

    init(_ state: CameraState) {
        position = state.position
        yaw = state.yaw
        pitch = state.pitch
        roll = state.roll
    }

    func isMeaningfullyDifferent(from previous: CameraProjectionSignature?) -> Bool {
        guard let previous else { return true }
        let positionDelta = position - previous.position
        let positionEpsilon = Float(0.0001)
        let angleEpsilon = Float(0.00005)
        return simd_dot(positionDelta, positionDelta) > positionEpsilon * positionEpsilon
            || angularDistance(yaw, previous.yaw) > angleEpsilon
            || angularDistance(pitch, previous.pitch) > angleEpsilon
            || angularDistance(roll, previous.roll) > angleEpsilon
    }

    private func angularDistance(_ lhs: Float, _ rhs: Float) -> Float {
        let fullTurn = Float.pi * 2
        let raw = abs(lhs - rhs).truncatingRemainder(dividingBy: fullTurn)
        return min(raw, fullTurn - raw)
    }
}

@MainActor
public protocol InputMetalViewDelegate: AnyObject {
    func hover(at point: CGPoint, in view: InputMetalView)
    func click(at point: CGPoint, count: Int, in view: InputMetalView)
    func rightClick(at point: CGPoint, in view: InputMetalView)
    func drag(delta: CGSize, at point: CGPoint, in view: InputMetalView)
    func scroll(delta: CGSize, modifiers: NSEvent.ModifierFlags, isPrecise: Bool)
    func magnify(_ magnification: CGFloat)
    func endMagnify()
    func keyDown(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags)
    func keyUp(_ keyCode: UInt16)
    func withheldDropOperation(for pasteboard: NSPasteboard) -> NSDragOperation
    func prepareWithheldDrop(from pasteboard: NSPasteboard) -> Bool
    func performWithheldDrop(from pasteboard: NSPasteboard) -> Bool
    func withheldDropExited()
    func finishWithheldDrop()
}

public final class InputMetalView: MTKView {
    public weak var inputDelegate: (any InputMetalViewDelegate)?
    private var tracking: NSTrackingArea?
    private var lastDragPoint: CGPoint?
    /// Last pointer position handed to the hover pipeline, in the same
    /// top-left space `mouseMoved` dispatches. `flagsChanged` re-dispatches
    /// from here so modifier presses retarget the hover without motion.
    private var lastHoverDispatchPoint: CGPoint?

    /// Opaque near-black clear used by every lens except the People / Meanings
    /// backdrop. Matches the `NightSkyView` base so swapping to transparency
    /// leaves the additive nebula / halo passes compositing essentially the same.
    private static let opaqueClear = MTLClearColor(red: 0.012, green: 0.016, blue: 0.024, alpha: 1)

    /// When true, the drawable clears to transparent and the backing
    /// CAMetalLayer is marked non-opaque so a SwiftUI view behind this Metal
    /// view shows through the gaps between nodes. Re-applied on window attach
    /// because MTKView re-finalises its layer there and would otherwise reset
    /// the layer back to opaque.
    public var rendersTransparentBackground = false {
        didSet { applyBackgroundOpacity() }
    }

    private func applyBackgroundOpacity() {
        // `MTKView.layer` is the CAMetalLayer, so toggling `isOpaque` on it
        // controls whether the drawable composites with views behind it.
        if rendersTransparentBackground {
            clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            layer?.isOpaque = false
        } else {
            clearColor = Self.opaqueClear
            layer?.isOpaque = true
        }
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        // MTKView reconfigures its CAMetalLayer on window attach, so re-assert
        // the non-opaque backing here or the transparency set in makeNSView is lost.
        applyBackgroundOpacity()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = topLeftPoint(for: event)
        lastHoverDispatchPoint = point
        inputDelegate?.hover(at: point, in: self)
    }

    public override func mouseExited(with event: NSEvent) {
        lastHoverDispatchPoint = nil
        inputDelegate?.hover(at: CGPoint(x: -10_000, y: -10_000), in: self)
    }

    public override func flagsChanged(with event: NSEvent) {
        // Pressing or releasing a modifier retargets the hover in place —
        // holding Option flips the Meaning lens into cluster-only picking,
        // and the flip should land immediately, not on the next 1px of
        // pointer travel.
        if let point = lastHoverDispatchPoint {
            inputDelegate?.hover(at: point, in: self)
        }
        super.flagsChanged(with: event)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDragPoint = eventPoint(for: event)
        inputDelegate?.click(at: topLeftPoint(for: event), count: event.clickCount, in: self)
    }

    public override func mouseDragged(with event: NSEvent) {
        let current = eventPoint(for: event)
        if let last = lastDragPoint {
            inputDelegate?.drag(
                delta: CGSize(width: current.x - last.x, height: current.y - last.y),
                at: topLeftPoint(for: event),
                in: self
            )
        }
        lastDragPoint = current
    }

    public override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
    }

    public override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        inputDelegate?.rightClick(at: topLeftPoint(for: event), in: self)
    }

    public override func scrollWheel(with event: NSEvent) {
        inputDelegate?.scroll(
            delta: CGSize(width: event.scrollingDeltaX, height: -event.scrollingDeltaY),
            modifiers: event.modifierFlags,
            isPrecise: event.hasPreciseScrollingDeltas
        )
    }

    public override func magnify(with event: NSEvent) {
        inputDelegate?.magnify(1.0 + event.magnification)
    }

    public override func smartMagnify(with event: NSEvent) {
        inputDelegate?.endMagnify()
    }

    public override func keyDown(with event: NSEvent) {
        inputDelegate?.keyDown(event.keyCode, modifiers: event.modifierFlags)
    }

    public override func keyUp(with event: NSEvent) {
        inputDelegate?.keyUp(event.keyCode)
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        inputDelegate?.withheldDropOperation(for: sender.draggingPasteboard) ?? []
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        inputDelegate?.withheldDropOperation(for: sender.draggingPasteboard) ?? []
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        inputDelegate?.withheldDropExited()
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        inputDelegate?.prepareWithheldDrop(from: sender.draggingPasteboard) ?? false
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        inputDelegate?.performWithheldDrop(from: sender.draggingPasteboard) ?? false
    }

    public override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        inputDelegate?.finishWithheldDrop()
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        inputDelegate?.finishWithheldDrop()
    }

    private func eventPoint(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func topLeftPoint(for event: NSEvent) -> CGPoint {
        let point = eventPoint(for: event)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }
}
