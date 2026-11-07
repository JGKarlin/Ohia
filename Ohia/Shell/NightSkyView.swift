import SwiftUI

/// A deep night sky: a deterministic field of varied stars over a faint
/// horizontal Milky Way band, with a subtle slow twinkle and the occasional
/// shooting star during a loading sequence.
///
/// The sky is intentionally dark in *both* the light and dark appearance — a
/// deliberate §18 exception scoped to the immersive splash + constellation-load
/// moment, where the eclipse moon and the incoming Constellation point cloud
/// both read as a night scene regardless of system appearance.
///
/// The starfield is generated once from a fixed seed and cached (`shared`), so
/// any two `NightSkyView` instances render the *same* stars in the *same*
/// normalized positions. That is what lets the splash hand off to the
/// Constellation-loading backdrop with no visible jump: both surfaces draw the
/// identical sky, full-bleed, so the only thing that changes across the
/// boundary is the foreground (the ʻōhiʻa mark and text) fading away.
struct NightSkyView: View {
    /// When true, the faint horizontal Milky Way band is drawn. Off for
    /// surfaces that want a plain starfield (e.g. the Front Page lens backdrop).
    var showsMilkyWay: Bool = true

    /// When true, a single shooting star streaks across the sky once, a few
    /// seconds into the loading sequence. Enabled on the splash; off on the
    /// Front Page backdrop and the constellation-load bridge. Suppressed under
    /// Reduce Motion.
    var showsShootingStars: Bool = false

    /// Whether star twinkle should run through a SwiftUI `TimelineView`.
    /// Immersive splash/loading surfaces keep it; Metal scene backdrops opt
    /// out so the camera renderer owns frame cadence.
    var twinkles: Bool = true

    /// How lively the star field's shimmer reads. `.standard` (the default)
    /// is the original, restrained twinkle used everywhere `NightSkyView`
    /// appears — unchanged by this property's existence. `.vivid` is opt-in:
    /// wider, more common per-star brightness swings plus a subtle,
    /// decorrelated hue drift, reserved for surfaces that want the sky to
    /// read as more alive (currently only the welcome "Get Started" screen).
    var starIntensity: NightSkyStarIntensity = .standard

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            NightSkyBase()
            if showsMilkyWay {
                MilkyWayBand()
            }
            NightSkyStarsLayer(reduceMotion: reduceMotion || !twinkles, style: starIntensity)
            if showsShootingStars && !reduceMotion {
                ShootingStarLayer()
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: - Deep-space base

/// Always-dark deep-space base, independent of the system color scheme so the
/// stars always read against true black. Three layers of darkening give the
/// field its contrast: a near-black vertical gradient, a corner vignette, and a
/// vertical band-vignette that crushes the sky above and below the central
/// Milky Way to black so the band stands out.
private struct NightSkyBase: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(.sRGB, red: 0.010, green: 0.012, blue: 0.030, opacity: 1), // #03040b
                    Color(.sRGB, red: 0.000, green: 0.000, blue: 0.004, opacity: 1)  // near-pure black
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Corner vignette.
            RadialGradient(
                colors: [Color.clear, Color.black.opacity(0.65)],
                center: .center,
                startRadius: 80,
                endRadius: 820
            )

            // Vertical band-vignette: dark at top and bottom, clear through the
            // central horizontal strip where the Milky Way sits. Boosts the
            // band's contrast against a darkened surrounding sky.
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.62), location: 0.00),
                    .init(color: Color.clear, location: 0.34),
                    .init(color: Color.clear, location: 0.66),
                    .init(color: Color.black.opacity(0.62), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Milky Way

/// A faint luminous band running horizontally across the vertical centre of the
/// view. Built from a few heavily-blurred capsules + soft colour patches under
/// `.screen` so it adds light over the dark base rather than painting a hard
/// shape. Static — it never redraws per frame.
private struct MilkyWayBand: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Broad diffuse haze.
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color(.sRGB, red: 0.52, green: 0.58, blue: 0.78, opacity: 0.20),
                                Color(.sRGB, red: 0.76, green: 0.80, blue: 0.94, opacity: 0.13),
                                Color(.sRGB, red: 0.52, green: 0.58, blue: 0.78, opacity: 0.20),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: w * 1.3, height: h * 0.46)
                    .blur(radius: 64)

                // Brighter, narrower spine of the band.
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color(.sRGB, red: 0.84, green: 0.87, blue: 0.98, opacity: 0.18),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: w * 1.2, height: h * 0.15)
                    .blur(radius: 30)

                // A faint warm patch and a cool patch for galactic texture.
                Ellipse()
                    .fill(Color(.sRGB, red: 0.95, green: 0.82, blue: 0.60, opacity: 0.08))
                    .frame(width: w * 0.34, height: h * 0.20)
                    .blur(radius: 54)
                    .offset(x: -w * 0.20)

                Ellipse()
                    .fill(Color(.sRGB, red: 0.55, green: 0.68, blue: 0.95, opacity: 0.08))
                    .frame(width: w * 0.30, height: h * 0.18)
                    .blur(radius: 54)
                    .offset(x: w * 0.22)
            }
            .frame(width: w, height: h)
            .position(x: w / 2, y: h / 2)
            .blendMode(.screen)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Stars

/// How lively the star field's shimmer reads. `.standard` is the original,
/// restrained twinkle used everywhere `NightSkyView` appears. `.vivid` is
/// opt-in — wider, more common brightness swings at a faster baked cadence,
/// plus a decorrelated hue drift — reserved for surfaces that want the sky
/// to read as more alive (currently only the welcome "Get Started" screen).
enum NightSkyStarIntensity {
    case standard
    case vivid
}

/// One star in the field, stored in normalized [0,1] coordinates so the same
/// field renders identically at any size / aspect.
private struct NightSkyStar {
    let position: CGPoint     // normalized 0...1
    let radius: CGFloat       // core radius in points at draw scale
    let brightness: Double    // 0...1 base opacity
    let color: Color
    let colorRGB: SIMD3<Double>  // same color as `color`, decomposed for hue-drift blending
    let hasHalo: Bool
    let twinkleAmplitude: Double  // 0 = steady; >0 = dims toward base*(1-amp). .standard style only.
    let twinkleSpeed: Double      // radians / second. .standard style only.
    let twinklePhase: Double

    // `.vivid` style only — baked independently of the fields above so the
    // `.standard` style (used by every other `NightSkyView` consumer) is
    // untouched by this variant's tuning.
    let vividAmplitude: Double         // always > 0: every star participates
    let vividSpeed1Multiplier: Double  // speeds up `twinkleSpeed`/`twinklePhase` for a livelier primary pulse
    let vividSpeed2: Double            // secondary harmonic, decorrelated from the primary
    let vividPhase2: Double
    let hueDrift: Double               // 0...1 per-star strength of chromatic flicker; skewed toward small
    let hueSpeed: Double
    let huePhase: Double
}

private struct NightSkyStarsLayer: View {
    let reduceMotion: Bool
    let style: NightSkyStarIntensity
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        if reduceMotion {
            Canvas(rendersAsynchronously: false) { context, size in
                NightSkyStarField.draw(in: &context, size: size, time: 0, style: style)
            }
            .ignoresSafeArea()
        } else {
            // 30 fps is ample for a slow shimmer and easy on the battery while
            // the eclipse moon's own Metal loop is also running. The twinkle
            // pauses while the window is inactive so a persistent backdrop
            // (e.g. the Front Page lens) doesn't keep redrawing off-screen.
            TimelineView(
                .animation(minimumInterval: 1.0 / 30.0,
                           paused: controlActiveState == .inactive)
            ) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                Canvas(rendersAsynchronously: false) { context, size in
                    NightSkyStarField.draw(in: &context, size: size, time: time, style: style)
                }
            }
            .ignoresSafeArea()
        }
    }
}

/// Deterministic shared starfield + the per-frame draw routine.
private enum NightSkyStarField {
    static let stars: [NightSkyStar] = generate()

    /// Core stars are kept small so the brightest never rival the splash moon
    /// (a 30pt disc). Halos are modest and reserved for the few largest.
    static func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        style: NightSkyStarIntensity = .standard
    ) {
        for star in stars {
            let center = CGPoint(x: star.position.x * size.width,
                                 y: star.position.y * size.height)
            let (brightness, color) = appearance(of: star, time: time, style: style)

            if star.hasHalo {
                let haloRadius = star.radius * 3.4
                let haloRect = CGRect(
                    x: center.x - haloRadius,
                    y: center.y - haloRadius,
                    width: haloRadius * 2,
                    height: haloRadius * 2
                )
                context.fill(
                    Path(ellipseIn: haloRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            color.opacity(0.38 * brightness),
                            .clear
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: haloRadius
                    )
                )
            }

            let coreRect = CGRect(
                x: center.x - star.radius,
                y: center.y - star.radius,
                width: star.radius * 2,
                height: star.radius * 2
            )
            context.fill(
                Path(ellipseIn: coreRect),
                with: .color(color.opacity(min(1.0, brightness)))
            )
        }
    }

    /// Resolves one star's current brightness + color for `time`, per
    /// `style`. `.standard` reproduces the field's original restrained
    /// shimmer exactly — byte-for-byte the same output as before this
    /// variant existed. `.vivid` layers a second, faster-baked harmonic onto
    /// the brightness pulse (every star participates, not just the baked
    /// ~30% subset) and adds a slow, decorrelated hue drift toward a warm or
    /// cool cast. Both styles only ever dim from the star's base brightness
    /// — never brighter — so the field still reads as a twinkle, not a
    /// strobe.
    private static func appearance(
        of star: NightSkyStar,
        time: TimeInterval,
        style: NightSkyStarIntensity
    ) -> (brightness: Double, color: Color) {
        switch style {
        case .standard:
            guard star.twinkleAmplitude > 0 else { return (star.brightness, star.color) }
            let shimmer = 0.5 + 0.5 * sin(time * star.twinkleSpeed + star.twinklePhase)
            let brightness = star.brightness * (1 - star.twinkleAmplitude * (1 - shimmer))
            return (brightness, star.color)

        case .vivid:
            let h1 = 0.5 + 0.5 * sin(time * star.twinkleSpeed * star.vividSpeed1Multiplier + star.twinklePhase)
            let h2 = 0.5 + 0.5 * sin(time * star.vividSpeed2 + star.vividPhase2)
            let shimmer = h1 * 0.65 + h2 * 0.35
            let brightness = star.brightness * (1 - star.vividAmplitude * (1 - shimmer))

            let driftPhase = sin(time * star.hueSpeed + star.huePhase)
            let color = driftedColor(base: star.colorRGB, baseColor: star.color, factor: driftPhase * star.hueDrift)
            return (brightness, color)
        }
    }

    /// Anchors the `.vivid` hue drift blends toward — a warm amber cast and a
    /// cool blue-white cast. Universal anchors (rather than color-specific
    /// ones) keep the drift readable against all three base star colors
    /// while staying subtle at `hueDriftMaxShift`.
    private static let hueDriftWarm = SIMD3<Double>(1.00, 0.90, 0.72)
    private static let hueDriftCool = SIMD3<Double>(0.80, 0.88, 1.00)
    private static let hueDriftMaxShift: Double = 0.20

    private static func driftedColor(base: SIMD3<Double>, baseColor: Color, factor: Double) -> Color {
        // Most stars carry a near-zero `hueDrift` strength (see generation),
        // so this early-out skips constructing a new Color for the common
        // case and just reuses the star's own precomputed color.
        guard abs(factor) > 0.0008 else { return baseColor }
        let t = max(-1, min(1, factor)) * hueDriftMaxShift
        let anchor = t >= 0 ? hueDriftWarm : hueDriftCool
        let blend = abs(t)
        let mixed = base + (anchor - base) * blend
        return Color(.sRGB, red: mixed.x, green: mixed.y, blue: mixed.z, opacity: 1)
    }

    // MARK: Generation

    private static func generate() -> [NightSkyStar] {
        // Fixed seed → identical field on every launch and across instances.
        var rng = SeededGenerator(seed: 0x01A5_EEDC_0DE1_2345)
        // A second, independent stream for the `.vivid`-only fields below.
        // Drawing them from `rng` would shift every subsequent star's
        // position/size/brightness/color/.standard-twinkle values by however
        // many extra draws each star consumes — breaking `.standard`'s
        // byte-for-byte reproduction of the original field for every other
        // `NightSkyView` consumer (splash, Front Page backdrop,
        // constellation-load bridge, etc.), none of which opt into `.vivid`.
        var vividRng = SeededGenerator(seed: 0x7B1A_C0DE_51DE_9E11)
        let total = 520
        let bandFraction = 0.40

        var result: [NightSkyStar] = []
        result.reserveCapacity(total)

        for _ in 0..<total {
            let isBandStar = Double.random(in: 0...1, using: &rng) < bandFraction

            // Position. The Milky Way runs horizontally through the vertical
            // centre, so band stars cluster in x freely and tightly in y.
            var x: Double
            var y: Double
            if isBandStar {
                var placed = (x: 0.5, y: 0.5)
                for _ in 0..<6 {
                    let px = Double.random(in: 0...1, using: &rng)
                    let py = 0.5 + gaussian(using: &rng) * 0.085
                    placed = (px, py)
                    if py >= 0, py <= 1 { break }
                }
                x = min(max(placed.x, 0), 1)
                y = min(max(placed.y, 0), 1)
            } else {
                x = Double.random(in: 0...1, using: &rng)
                y = Double.random(in: 0...1, using: &rng)
            }

            // Size — heavy skew toward tiny stars, a few slightly larger. Kept
            // small overall; band stars run a touch smaller (more distant).
            let sizeRoll = Double.random(in: 0...1, using: &rng)
            var radius = 0.35 + 1.15 * pow(sizeRoll, 3.2)
            if isBandStar { radius *= 0.80 }

            // Brightness — correlated with size, with its own jitter. Field
            // stars sit a little dimmer than band stars for added contrast.
            let brightRoll = Double.random(in: 0...1, using: &rng)
            let sizeNorm = min(1.0, (radius - 0.35) / 1.15)
            var brightness = 0.34 + 0.46 * brightRoll + 0.22 * sizeNorm
            brightness = min(1.0, brightness)
            if !isBandStar { brightness *= 0.88 }

            // Colour — realistic white-spectrum: mostly white, a cool-blue
            // scatter, a smaller warm-gold scatter.
            let colorRoll = Double.random(in: 0...1, using: &rng)
            let colorRGB: SIMD3<Double>
            if colorRoll < 0.70 {
                colorRGB = SIMD3(1.00, 0.98, 0.94)
            } else if colorRoll < 0.88 {
                colorRGB = SIMD3(0.74, 0.83, 1.00)
            } else {
                colorRGB = SIMD3(1.00, 0.88, 0.70)
            }
            let color = Color(.sRGB, red: colorRGB.x, green: colorRGB.y, blue: colorRGB.z, opacity: 1)

            // Twinkle (.standard style) — only ~30% shimmer, slowly; the rest
            // stay steady.
            let twinkles = Double.random(in: 0...1, using: &rng) < 0.30
            let amplitude = twinkles ? (0.18 + 0.32 * Double.random(in: 0...1, using: &rng)) : 0
            let speed = 0.25 + 0.65 * Double.random(in: 0...1, using: &rng)
            let phase = Double.random(in: 0...(2 * .pi), using: &rng)

            // Twinkle (.vivid style) — every star participates (no on/off
            // roll), at a faster baked cadence than .standard's, so the
            // effect reads clearly rather than as an echo of the restrained
            // default. Amplitude is skewed toward its lower-middle range
            // (most stars dip modestly, a handful swing hard) for "different
            // levels of brightness" rather than one uniform pulse.
            let vividAmplitudeRoll = Double.random(in: 0...1, using: &vividRng)
            let vividAmplitude = 0.15 + 0.55 * pow(vividAmplitudeRoll, 1.4)
            let vividSpeed1Multiplier = 1.6 + 1.4 * Double.random(in: 0...1, using: &vividRng)
            let vividSpeed2 = 1.0 + 2.0 * Double.random(in: 0...1, using: &vividRng)
            let vividPhase2 = Double.random(in: 0...(2 * .pi), using: &vividRng)

            // Hue drift (.vivid style only) — a slow, decorrelated
            // color-temperature wobble. Skewed hard toward near-zero so most
            // stars show only a whisper of chromatic flicker while a few
            // show a clearly visible warm/cool shimmer, matching how real
            // atmospheric scintillation is uneven across the sky.
            let hueDriftRoll = Double.random(in: 0...1, using: &vividRng)
            let hueDrift = pow(hueDriftRoll, 2.2)
            let hueSpeed = 0.3 + 0.7 * Double.random(in: 0...1, using: &vividRng)
            let huePhase = Double.random(in: 0...(2 * .pi), using: &vividRng)

            result.append(
                NightSkyStar(
                    position: CGPoint(x: x, y: y),
                    radius: radius,
                    brightness: brightness,
                    color: color,
                    colorRGB: colorRGB,
                    hasHalo: radius > 1.10,
                    twinkleAmplitude: amplitude,
                    twinkleSpeed: speed,
                    twinklePhase: phase,
                    vividAmplitude: vividAmplitude,
                    vividSpeed1Multiplier: vividSpeed1Multiplier,
                    vividSpeed2: vividSpeed2,
                    vividPhase2: vividPhase2,
                    hueDrift: hueDrift,
                    hueSpeed: hueSpeed,
                    huePhase: huePhase
                )
            )
        }
        return result
    }

    /// Standard-normal sample via Box–Muller, drawn from the seeded generator.
    private static func gaussian(using rng: inout SeededGenerator) -> Double {
        let u1 = max(Double.random(in: 0...1, using: &rng), 1e-9)
        let u2 = Double.random(in: 0...1, using: &rng)
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * .pi * u2)
    }
}

// MARK: - Shooting stars

/// A scheduled meteor: a bright head with a tapered trail that streaks across
/// the sky once, at `startTime` seconds after the layer appears.
private struct ShootingStar {
    let startTime: Double   // seconds after the layer appears
    let duration: Double    // seconds of travel
    let start: CGPoint      // normalized origin
    let end: CGPoint        // normalized destination
    let thickness: CGFloat
}

/// Draws meteors on a 60 fps `Canvas`. The layer captures its own appearance
/// time, so the first meteor is guaranteed early in any loading sequence and
/// further meteors follow across a full-length (≈12 s) load.
private struct ShootingStarLayer: View {
    @State private var start = Date()
    /// Randomized once per appearance, so each loading sequence gets a meteor
    /// with its own time, origin, and angle.
    @State private var meteor = ShootingStars.randomMeteor()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Canvas(rendersAsynchronously: false) { context, size in
                ShootingStars.draw(meteor, in: &context, size: size, elapsed: elapsed)
            }
        }
        .ignoresSafeArea()
        .blendMode(.screen)
    }
}

private enum ShootingStars {
    /// Trail length as a fraction of the full travel path.
    private static let trailFraction: Double = 0.16

    /// One streak per loading sequence, with randomized time, origin, angle,
    /// length, and duration. Confined to the upper sky so it stays clear of the
    /// centred emblem and title, and timed a couple of seconds in so it is seen
    /// while the moon arcs through a model-loading sequence. On an instant
    /// warm-cache launch the splash can dismiss before it fires — there is no
    /// loading to narrate then — so it is not strictly guaranteed.
    static func randomMeteor() -> ShootingStar {
        let startX = Double.random(in: 0.12...0.88)
        let startY = Double.random(in: 0.07...0.20)
        let angle = Double.random(in: (20.0 * .pi / 180)...(55.0 * .pi / 180)) // below horizontal
        let horizontalSign: Double = Bool.random() ? 1 : -1
        let length = Double.random(in: 0.34...0.52)

        let rawEndX = startX + cos(angle) * length * horizontalSign
        let rawEndY = startY + sin(angle) * length
        let endX = min(max(rawEndX, 0.05), 0.95)
        let endY = min(rawEndY, 0.36)

        return ShootingStar(
            startTime: Double.random(in: 2.0...5.0),
            duration: Double.random(in: 0.95...1.30),
            start: CGPoint(x: startX, y: startY),
            end: CGPoint(x: endX, y: endY),
            thickness: CGFloat.random(in: 1.3...1.8)
        )
    }

    static func draw(_ meteor: ShootingStar, in context: inout GraphicsContext, size: CGSize, elapsed: TimeInterval) {
        let local = elapsed - meteor.startTime
        guard local >= 0, local <= meteor.duration else { return }
        let progress = local / meteor.duration

        let dx = meteor.end.x - meteor.start.x
        let dy = meteor.end.y - meteor.start.y

        let head = CGPoint(
            x: (meteor.start.x + dx * progress) * size.width,
            y: (meteor.start.y + dy * progress) * size.height
        )
        let tailProgress = max(0, progress - trailFraction)
        let tail = CGPoint(
            x: (meteor.start.x + dx * tailProgress) * size.width,
            y: (meteor.start.y + dy * tailProgress) * size.height
        )

        // Fade in over the first 15%, hold, then fade out over the last 30%.
        let fadeIn = min(1.0, progress / 0.15)
        let fadeOut = 1.0 - max(0.0, (progress - 0.70) / 0.30)
        let alpha = max(0.0, min(1.0, fadeIn * fadeOut))
        guard alpha > 0 else { return }

        // Tapered trail: clear at the tail, bright at the head.
        var trail = Path()
        trail.move(to: tail)
        trail.addLine(to: head)
        context.stroke(
            trail,
            with: .linearGradient(
                Gradient(colors: [
                    Color.white.opacity(0),
                    Color(.sRGB, red: 0.86, green: 0.90, blue: 1.0, opacity: 0.85 * alpha)
                ]),
                startPoint: tail,
                endPoint: head
            ),
            style: StrokeStyle(lineWidth: meteor.thickness, lineCap: .round)
        )

        // Glowing head.
        let glowRadius = meteor.thickness * 3.4
        let glowRect = CGRect(
            x: head.x - glowRadius,
            y: head.y - glowRadius,
            width: glowRadius * 2,
            height: glowRadius * 2
        )
        context.fill(
            Path(ellipseIn: glowRect),
            with: .radialGradient(
                Gradient(colors: [
                    Color.white.opacity(0.9 * alpha),
                    .clear
                ]),
                center: head,
                startRadius: 0,
                endRadius: glowRadius
            )
        )
    }
}

/// Deterministic SplitMix64 generator so the shared starfield is identical on
/// every launch and across instances (no `Date`/`Math.random` dependence).
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
