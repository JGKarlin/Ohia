import AppKit
import MetalKit
import SwiftUI
import SwiftData
import OhiaCore

struct SplashView: View {
    let onFinished: () -> Void
    var canDismiss: Bool
    /// Outer time gate — the splash auto-dismisses after this many seconds even
    /// if the parent never signals `canDismiss`. Also the duration over which
    /// the eclipse moon completes one full pass.
    var maximumVisibleDuration: TimeInterval = 12

    @Query private var accounts: [Account]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tagline = OhiaTaglines.random
    /// The ʻōhiʻa mark, title, and text. Fades in on appear. On dismiss it is
    /// not faded out here — the shell cross-dissolves the entire splash into the
    /// lens as one unit, so this stays at full opacity until the whole view goes.
    @State private var contentOpacity: Double = 0
    /// The night-sky backdrop. Fades in with the content and stays at full
    /// opacity thereafter; on dismiss the shell fades the whole splash (sky
    /// included) into the lens. Because the lens draws the same deterministic
    /// starfield underneath, that sky fade is invisible — only the mark + text
    /// read as fading, and the night sky stays continuous across the hand-off.
    @State private var skyOpacity: Double = 0
    @State private var minimumHoldElapsed = false
    @State private var didStartFadeOut = false
    @State private var animationStart = Date()
    @SwiftUI.FocusState private var skipInputFocused: Bool

    /// The moon's color identity. Picks the most recently active account
    /// (highest `lastSyncAt`) and adopts its `AccountColor` hue + saturation.
    /// When that account has no `colorIndex` chosen, falls back to the
    /// original cream/gold palette so the splash looks unchanged for users
    /// who never visit the color picker.
    private var moonTint: MoonTint {
        let mostRecent = accounts.max { lhs, rhs in
            (lhs.lastSyncAt ?? .distantPast) < (rhs.lastSyncAt ?? .distantPast)
        }
        guard let colorIndex = mostRecent?.colorIndex else { return .cream }
        let color = AccountColorPalette.color(forIndex: colorIndex)
        return .tinted(hue: color.hue, saturation: color.saturation)
    }

    private let fadeInDuration: Double = 0.4
    /// Time the splash stays visible after fade-in completes before it is
    /// allowed to fade out, even if the parent has already signaled
    /// `canDismiss`. Without this the splash flashes when both workers
    /// are warm-cache loaded.
    private let minimumVisibleHold: Double = 0.8

    var body: some View {
        ZStack {
            // Deep night sky — the persistent backdrop. It fades *in* with the
            // splash but is held at full opacity on the way out (see
            // `dismissIfAllowed`), so it stays put while the ʻōhiʻa mark and
            // text fade, then carries across into the Constellation-loading
            // backdrop with no visible seam.
            NightSkyView(showsShootingStars: true)
                .ignoresSafeArea()
                .opacity(skyOpacity)

            VStack(spacing: 0) {
                Spacer()

                // Eclipse stage — the ʻōhiʻa with a moon rising from the
                // left, passing behind the silhouette at apex (an annular
                // corona blooms during occlusion), and setting on the
                // right. One full pass over `maximumVisibleDuration`.
                EclipseSplashStage(
                    animationStart: animationStart,
                    duration: maximumVisibleDuration,
                    tint: moonTint,
                    reduceMotion: reduceMotion
                )
                .frame(width: 380, height: 200)
                .padding(.bottom, 12)
                .accessibilityHidden(true)

                // Title
                Text("Ohia")
                    .font(OhiaTypography.appTitle)
                    .foregroundStyle(OhiaColors.textPrimary)
                    .padding(.bottom, 12)

                // Tagline
                Text(tagline)
                    .font(OhiaTypography.body)
                    .foregroundStyle(OhiaColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                Spacer()

                Text("Ontological Hypergraph of Intelligent Associations\n(Ohia Hates Inbox Architecture)")
                    .font(OhiaTypography.caption.weight(.bold))
                    .foregroundStyle(OhiaColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 6)

                // Copyright
                Text("© 2026 Jason G. Karlin")
                    .font(OhiaTypography.caption)
                    .foregroundStyle(OhiaColors.textSecondary)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 64)
            .opacity(contentOpacity)
        }
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($skipInputFocused)
        .onTapGesture {
            forceDismiss()
        }
        .accessibilityAction(named: Text("Skip Splash")) {
            forceDismiss()
        }
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.intersection([.command, .option, .control]).isEmpty else {
                return .ignored
            }
            forceDismiss()
            return .handled
        }
        .onAppear {
            animationStart = Date()
            skipInputFocused = true
            withAnimation(.easeIn(duration: fadeInDuration)) {
                skyOpacity = 1
                contentOpacity = 1
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + fadeInDuration + minimumVisibleHold
            ) {
                minimumHoldElapsed = true
                attemptDismiss()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + maximumVisibleDuration) {
                forceDismiss()
            }
        }
        .onChange(of: canDismiss) { _, _ in
            attemptDismiss()
        }
    }

    private func attemptDismiss() {
        guard canDismiss else { return }
        dismissIfAllowed()
    }

    private func forceDismiss() {
        minimumHoldElapsed = true
        dismissIfAllowed()
    }

    private func dismissIfAllowed() {
        guard minimumHoldElapsed, !didStartFadeOut else { return }
        didStartFadeOut = true
        // Hand off immediately. The shell cross-dissolves the *entire* splash
        // (ʻōhiʻa mark, text, and its starfield) into the lens over a long,
        // gradual fade, with the lens rendering underneath at its own pace — so
        // there is no separate foreground pre-fade here. The starfield is the
        // same deterministic field the lens draws, so only the mark + text read
        // as fading; the night sky stays continuous across the hand-off.
        onFinished()
    }
}

// MARK: - Eclipse stage

/// Composes the ʻōhiʻa mark with a luminous moon arcing behind it.
/// Runs a single 0→1 phase over `duration`, never loops.
private struct EclipseSplashStage: View {
    let animationStart: Date
    let duration: Double
    let tint: MoonTint
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            GeometryReader { proxy in
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                EclipseSplashScene(phase: 0.4, center: center, tint: tint)
            }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let elapsed = timeline.date.timeIntervalSince(animationStart)
                let phase = max(0, min(1, elapsed / max(duration, 0.0001)))

                GeometryReader { proxy in
                    let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    EclipseSplashScene(phase: phase, center: center, tint: tint)
                }
            }
        }
    }
}

private struct EclipseSplashScene: View {
    let phase: Double
    let center: CGPoint
    let tint: MoonTint

    var body: some View {
        ZStack {
            EclipseSplashBackLayer(phase: phase, center: center, tint: tint)

            // The ʻōhiʻa — opaque silhouette occludes the moon at apex,
            // alpha gaps in the foliage let light peek through.
            Image("ohia")
                .resizable()
                .scaledToFit()
                .frame(width: 125, height: 125)
                .position(center)

            EclipseSplashFrontLayer(phase: phase, center: center, tint: tint)
        }
    }
}

private struct EclipseSplashBackLayer: View {
    let phase: Double
    let center: CGPoint
    let tint: MoonTint

    var body: some View {
        let path = EclipsePath(cx: center.x, cy: center.y, reach: 140, drop: 70, lift: 15)
        let pos = path.position(at: phase)
        let alpha = eclipseAlpha(phase: phase)
        // Smooth U-curve: 1 when clear of the silhouette, dipping to 0 at
        // apex so the moon fully hides behind the ohia rather than leaking
        // through the petal gaps in the asset's alpha channel.
        let unblocked = smoothstep01(abs(phase - 0.5) / 0.20)
        let visible = alpha * unblocked

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            tint.haloInner,
                            tint.haloMid,
                            .clear
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: 60
                    )
                )
                .frame(width: 120, height: 120)
                .blur(radius: 7)
                .position(pos)
                .opacity(visible * 0.85)

            EclipseMetalMoonOrb(tint: tint, phase: phase)
                .frame(width: 30, height: 30)
                .position(pos)
                .opacity(visible)
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}

private struct EclipseSplashFrontLayer: View {
    let phase: Double
    let center: CGPoint
    let tint: MoonTint

    /// Base size of the ohia mark the glow layers are keyed to — matches
    /// `EclipseSplashScene`'s `Image("ohia")` frame.
    private static let markSize: CGFloat = 125

    /// One glow pass's scale + blur radius, plus the canvas footprint it
    /// needs. `glowCanvasSize` below is computed as the MAX footprint across
    /// all three specs — not a hand-picked "widest layer" constant — so a
    /// future tuning edit to any layer's scale/blur can't silently drift out
    /// of sync with the canvas and reintroduce the clip bug this exists to
    /// prevent.
    private struct GlowSpec {
        let scale: CGFloat
        let blurRadius: CGFloat
        /// Scaled diameter plus blur falloff on every side. The falloff
        /// budget (4× the blur radius per side) is a generous multiple of
        /// the ~3× a Gaussian blur's visible reach is commonly reckoned at —
        /// SwiftUI/Core Image don't publish the exact radius↔falloff
        /// relationship, so this errs wide rather than trusting a tight
        /// bound. The extra offscreen canvas this costs is cheap (a single
        /// flat-color rectangle+mask+blur composite, bounded to the ≤12s
        /// splash window), so there's no reason to cut the margin close.
        var footprint: CGFloat { markSize * scale + blurRadius * 8 }
    }

    private static let wideGlow = GlowSpec(scale: 1.65, blurRadius: 22)
    private static let midGlow = GlowSpec(scale: 1.3, blurRadius: 10)
    private static let rimGlow = GlowSpec(scale: 1.12, blurRadius: 4)

    /// `.drawingGroup()` below rasterizes into an offscreen buffer sized to
    /// this view's own LAYOUT frame — `scaleEffect` and `blur` are render-time
    /// effects that don't change that reported size. Without an explicit
    /// frame here the buffer defaults to `markSize` (125×125) and hard-clips
    /// every glow layer's scale+blur overflow the instant it rasterizes,
    /// square edge and all — the exact bug that made the bloom read as a box
    /// instead of fading out past the mark's silhouette.
    private static let glowCanvasSize: CGFloat = max(
        wideGlow.footprint, midGlow.footprint, rimGlow.footprint
    )

    var body: some View {
        let occlusion = eclipseBell(phase, peak: 0.50, width: 0.18)

        ZStack {
            // Wide bloom — a heavily blurred, enlarged pass of the ʻōhiʻa's
            // own silhouette. Reads as a soft ambient bleed of light, but
            // (unlike a radial-gradient circle) it still traces the mark's
            // real contour: rounder across the leaf lobes, broken into rays
            // where the stamens fan out.
            OhiaSilhouetteGlow(tint: tint.outerFlare, blurRadius: Self.wideGlow.blurRadius, scale: Self.wideGlow.scale)
                .opacity(occlusion)

            // Transition pass — narrows the gap between the wide bloom and
            // the tight rim below so the falloff reads as continuous.
            OhiaSilhouetteGlow(tint: tint.coronaMid, blurRadius: Self.midGlow.blurRadius, scale: Self.midGlow.scale)
                .opacity(occlusion * 0.8)

            // Rim light — a tight, brighter pass hugging the silhouette's
            // immediate edge, the shape-conforming analogue of the eclipse's
            // annular corona.
            OhiaSilhouetteGlow(tint: tint.coronaTop, blurRadius: Self.rimGlow.blurRadius, scale: Self.rimGlow.scale)
                .opacity(occlusion * 0.9)
        }
        // Reserve enough canvas that the widest scale+blur layer never
        // touches this frame's edge, THEN flatten — so `.drawingGroup()`
        // rasterizes the fully bloomed result instead of clipping it. The
        // three mask+blur passes are still collapsed into a single
        // Metal-backed rasterization per frame instead of compositing each
        // independently — this runs inside a 60fps TimelineView loop, so
        // collapsing three offscreen mask groups down to one keeps the
        // per-frame cost close to the original two-circle version it
        // replaced, even at this larger canvas size.
        .frame(width: Self.glowCanvasSize, height: Self.glowCanvasSize)
        .drawingGroup()
        .position(center)
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}

/// A solid-tint copy of the ʻōhiʻa mark, alpha-masked to the artwork's own
/// silhouette rather than a circle, then enlarged and blurred. Stacking
/// several of these at different blur radii / scales produces a backlight
/// bloom that follows the flower's actual outline — including the gaps
/// between stamens and the scalloped leaf edge — instead of a generic ring.
private struct OhiaSilhouetteGlow: View {
    let tint: Color
    let blurRadius: CGFloat
    let scale: CGFloat

    var body: some View {
        Rectangle()
            .fill(tint)
            .frame(width: 125, height: 125)
            .mask(
                Image("ohia")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 125, height: 125)
            )
            .scaleEffect(scale)
            .blur(radius: blurRadius)
    }
}

// MARK: - 3D moon body

private struct EclipseMetalMoonOrb: NSViewRepresentable {
    let tint: MoonTint
    let phase: Double

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearDepth = 1
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.sampleCount = 4
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor

        view.delegate = context.coordinator
        context.coordinator.configure(view: view)
        context.coordinator.update(tint: tint, phase: phase)
        view.draw()
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(tint: tint, phase: phase)
        view.draw()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private var resources: EclipseMoonMetalResourceSet?
        private var tint = MoonTint.cream
        private var phase: Float = 0

        func configure(view: MTKView) {
            resources = EclipseMoonMetalResources.shared.resources(for: view)
        }

        func update(tint: MoonTint, phase: Double) {
            self.tint = tint
            self.phase = Float(phase)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard
                let drawable = view.currentDrawable,
                let descriptor = view.currentRenderPassDescriptor,
                let resources,
                let commandBuffer = resources.commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return }

            var uniforms = EclipseOrbUniforms(
                color: tint.orbColor,
                light: SIMD4<Float>(0.42, 0.72, 0.55, 0),
                rimColor: tint.rimColor,
                phaseTime: SIMD4<Float>(phase, 0, 0, 0)
            )

            encoder.setRenderPipelineState(resources.pipelineState)
            encoder.setDepthStencilState(resources.depthState)
            encoder.setVertexBuffer(resources.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<EclipseOrbUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EclipseOrbUniforms>.stride, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: resources.indexCount,
                indexType: .uint16,
                indexBuffer: resources.indexBuffer,
                indexBufferOffset: 0
            )
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

@MainActor
private final class EclipseMoonMetalResources {
    static let shared = EclipseMoonMetalResources()

    private var cached: EclipseMoonMetalResourceSet?

    func resources(for view: MTKView) -> EclipseMoonMetalResourceSet? {
        if let cached {
            return cached
        }

        guard
            let device = view.device,
            let commandQueue = device.makeCommandQueue(),
            let library = device.makeDefaultLibrary(),
            let vertexFunction = library.makeFunction(name: "splashMoonVertex"),
            let fragmentFunction = library.makeFunction(name: "splashMoonFragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = view.sampleCount
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true

        let sphere = Self.makeSphere(segments: 48, rings: 24)
        guard
            let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor),
            let depthState = device.makeDepthStencilState(descriptor: depthDescriptor),
            let vertexBuffer = device.makeBuffer(
                bytes: sphere.vertices,
                length: sphere.vertices.count * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared
            ),
            let indexBuffer = device.makeBuffer(
                bytes: sphere.indices,
                length: sphere.indices.count * MemoryLayout<UInt16>.stride,
                options: .storageModeShared
            )
        else { return nil }

        let resources = EclipseMoonMetalResourceSet(
            commandQueue: commandQueue,
            pipelineState: pipelineState,
            depthState: depthState,
            vertexBuffer: vertexBuffer,
            indexBuffer: indexBuffer,
            indexCount: sphere.indices.count
        )
        cached = resources
        return resources
    }

    private static func makeSphere(
        segments: Int,
        rings: Int
    ) -> (vertices: [SIMD3<Float>], indices: [UInt16]) {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt16] = []
        vertices.reserveCapacity((segments + 1) * (rings + 1))
        indices.reserveCapacity(segments * rings * 6)

        for ring in 0...rings {
            let v = Float(ring) / Float(rings)
            let theta = Float.pi * v
            let y = cos(theta)
            let radius = sin(theta)

            for segment in 0...segments {
                let u = Float(segment) / Float(segments)
                let phi = u * Float.pi * 2
                vertices.append(
                    SIMD3<Float>(
                        cos(phi) * radius,
                        y,
                        sin(phi) * radius
                    )
                )
            }
        }

        for ring in 0..<rings {
            for segment in 0..<segments {
                let a = UInt16(ring * (segments + 1) + segment)
                let b = UInt16((ring + 1) * (segments + 1) + segment)
                let c = UInt16(ring * (segments + 1) + segment + 1)
                let d = UInt16((ring + 1) * (segments + 1) + segment + 1)
                indices.append(contentsOf: [a, b, c, c, b, d])
            }
        }

        return (vertices, indices)
    }
}

private struct EclipseMoonMetalResourceSet {
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
}

private struct EclipseOrbUniforms {
    var color: SIMD4<Float>
    var light: SIMD4<Float>
    var rimColor: SIMD4<Float>
    var phaseTime: SIMD4<Float>
}

/// The moon's per-layer color palette. Each entry maps to the splash halo,
/// flare, corona, and Metal sphere material so the account hue can drive every
/// photon the moon emits without flattening the 3D body.
private struct MoonTint {
    let haloInner: Color
    let haloMid: Color
    let outerFlare: Color
    let coronaTop: Color
    let coronaMid: Color
    let orbColor: SIMD4<Float>
    let rimColor: SIMD4<Float>

    static let cream = MoonTint(
        haloInner:  Color(.sRGB, red: 1.00, green: 0.97, blue: 0.88, opacity: 0.55),
        haloMid:    Color(.sRGB, red: 0.92, green: 0.88, blue: 0.74, opacity: 0.20),
        outerFlare: Color(.sRGB, red: 1.00, green: 0.94, blue: 0.78, opacity: 0.12),
        coronaTop:  Color(.sRGB, red: 1.00, green: 0.94, blue: 0.78, opacity: 0.65),
        coronaMid:  Color(.sRGB, red: 0.96, green: 0.86, blue: 0.62, opacity: 0.40),
        orbColor:   SIMD4<Float>(0.94, 0.92, 0.84, 1.0),
        rimColor:   SIMD4<Float>(1.00, 0.94, 0.78, 1.0)
    )

    /// Build the moon palette around an account's hue + saturation. The disk
    /// is desaturated relative to the halo/corona so the moon body still
    /// reads as a luminous object rather than a flat colored disc; the
    /// emitted-light layers (halo, flare, corona) carry the full account
    /// saturation so the spilled light is unambiguously the account color.
    static func tinted(hue: Double, saturation s: Double) -> MoonTint {
        let diskSat = s * 0.45
        return MoonTint(
            haloInner:  hsvColor(hue: hue, sat: s,       val: 1.00, opacity: 0.55),
            haloMid:    hsvColor(hue: hue, sat: s,       val: 0.92, opacity: 0.22),
            outerFlare: hsvColor(hue: hue, sat: s,       val: 1.00, opacity: 0.16),
            coronaTop:  hsvColor(hue: hue, sat: s,       val: 1.00, opacity: 0.70),
            coronaMid:  hsvColor(hue: hue, sat: s,       val: 0.93, opacity: 0.44),
            orbColor:   hsvRGBA(hue: hue, sat: diskSat,  val: 0.93, opacity: 1.0),
            rimColor:   hsvRGBA(hue: hue, sat: s,        val: 1.00, opacity: 1.0)
        )
    }
}

private func hsvColor(hue: Double, sat: Double, val: Double, opacity: Double) -> Color {
    let rgba = hsvRGBA(hue: hue, sat: sat, val: val, opacity: opacity)
    return Color(
        .sRGB,
        red: Double(rgba.x),
        green: Double(rgba.y),
        blue: Double(rgba.z),
        opacity: Double(rgba.w)
    )
}

private func hsvRGBA(hue: Double, sat: Double, val: Double, opacity: Double) -> SIMD4<Float> {
    let h = (hue.truncatingRemainder(dividingBy: 1.0) + 1.0)
        .truncatingRemainder(dividingBy: 1.0)
    let s = max(0.0, min(1.0, sat))
    let v = max(0.0, min(1.0, val))
    let c = v * s
    let x = c * (1.0 - abs((h * 6.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
    let m = v - c
    let rgb: (Double, Double, Double)
    switch h * 6.0 {
    case 0..<1: rgb = (c, x, 0)
    case 1..<2: rgb = (x, c, 0)
    case 2..<3: rgb = (0, c, x)
    case 3..<4: rgb = (0, x, c)
    case 4..<5: rgb = (x, 0, c)
    default:    rgb = (c, 0, x)
    }
    return SIMD4<Float>(
        Float(rgb.0 + m),
        Float(rgb.1 + m),
        Float(rgb.2 + m),
        Float(max(0.0, min(1.0, opacity)))
    )
}

private struct EclipsePath {
    let cx: CGFloat
    let cy: CGFloat
    let reach: CGFloat   // horizontal distance from centre to horizon
    let drop: CGFloat    // start/end vertical offset below ohia centre
    let lift: CGFloat    // apex offset above ohia centre

    /// Phase 0 → far-left horizon. Phase 0.5 → apex (behind ohia).
    /// Phase 1 → far-right horizon. The path is an elliptical arc.
    func position(at phase: Double) -> CGPoint {
        let t = .pi * (1 - phase)
        let x = cx + reach * CGFloat(cos(t))
        let horizonY = cy + drop
        let apexY = cy - lift
        let y = horizonY - (horizonY - apexY) * CGFloat(sin(t))
        return CGPoint(x: x, y: y)
    }
}

/// Fade-in / fade-out envelope for one full pass.
private func eclipseAlpha(phase: Double) -> Double {
    let fadeIn = smoothstep01(phase / 0.10)
    let fadeOut = 1 - smoothstep01((phase - 0.90) / 0.10)
    return fadeIn * fadeOut
}

/// Bell pulse around `peak` with falloff distance `width`.
private func eclipseBell(_ phase: Double, peak: Double, width: Double) -> Double {
    let d = abs(phase - peak)
    return max(0, 1 - d / max(width, 0.0001))
}

private func smoothstep01(_ x: Double) -> Double {
    let v = max(0, min(1, x))
    return v * v * v * (v * (v * 6 - 15) + 10)
}
