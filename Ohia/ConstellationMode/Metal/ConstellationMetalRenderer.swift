import AppKit
import Foundation
import Metal
import MetalKit
import QuartzCore
import simd
import OhiaCore
#if DEBUG
import OSLog
#endif

public struct ConstellationMetalFrameStats: Sendable, Equatable {
    /// Identity of the packet whose buffers produced this frame.
    public let packetGeneratedAt: TimeInterval
    public let starCount: Int
    public let satelliteCount: Int
    public let nebulaCount: Int
    public let fiberCount: Int
    public let hitProxyCount: Int
    /// CPU time spent translating a newly planned packet into Metal buffers
    /// and textures. This is packet-install cost, not GPU upload duration.
    public let packetPreparationMilliseconds: Double
    /// CPU time spent updating dynamic state and encoding the latest frame.
    /// It intentionally stops after commit and does not pretend to include
    /// asynchronous GPU execution.
    public let cpuEncodingMilliseconds: Double
    /// Completed GPU interval reported by Metal for the latest command buffer.
    /// Zero means no completed timing sample is available yet.
    public let gpuFrameMilliseconds: Double
    public let degradationTier: RenderDegradationTier
}

/// Metal completion handlers may run on an implementation-owned queue. Keep
/// their timing sample in a tiny lock-protected cell instead of racing the
/// main-thread renderer state read by `frameStats()`.
private final class MetalFrameTimingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latestMilliseconds: Double = 0
#if DEBUG
    private let presentationStream = UUID().uuidString
    private var presentationEpoch: UInt64 = 0
    private var presentationSequence: UInt64 = 0
    private var presentationActive = false
    private var presentationFramesPerSecond = 0

    /// Opt-in diagnosis only: no callbacks, per-frame logs or additional
    /// observations in an ordinary Debug run. Presentation callbacks can
    /// arrive after a surface pauses or remounts, hence the locked epoch.
    nonisolated private static let tracesPresentations = ProcessInfo.processInfo
        .environment["OHIA_TRACE_METAL_PRESENTATIONS"] == "1"
    nonisolated private static let presentationLogger = Logger(
        subsystem: "com.ohia.app", category: "MetalPresentation"
    )

    func setPresentationSampling(active: Bool, framesPerSecond: Int) {
        guard Self.tracesPresentations else { return }
        lock.lock()
        guard active != presentationActive
            || (active && framesPerSecond != presentationFramesPerSecond) else {
            lock.unlock()
            return
        }
        let endedEpoch = presentationActive ? presentationEpoch : nil
        let endedFramesPerSecond = presentationFramesPerSecond
        presentationActive = active
        if active {
            presentationEpoch &+= 1
            presentationSequence = 0
            presentationFramesPerSecond = framesPerSecond
        }
        let startedEpoch = active ? presentationEpoch : nil
        lock.unlock()

        let hostNanoseconds = Int64(CACurrentMediaTime() * 1_000_000_000)
        if let endedEpoch {
            Self.presentationLogger.info(
                "metal_epoch stream=\(self.presentationStream, privacy: .public) epoch=\(endedEpoch, privacy: .public) state=end target_fps=\(endedFramesPerSecond, privacy: .public) host_ns=\(hostNanoseconds, privacy: .public)"
            )
        }
        if let startedEpoch {
            Self.presentationLogger.info(
                "metal_epoch stream=\(self.presentationStream, privacy: .public) epoch=\(startedEpoch, privacy: .public) state=start target_fps=\(framesPerSecond, privacy: .public) host_ns=\(hostNanoseconds, privacy: .public)"
            )
        }
    }

    func presentationSample() -> (epoch: UInt64, sequence: UInt64, framesPerSecond: Int)? {
        guard Self.tracesPresentations else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard presentationActive else { return nil }
        presentationSequence &+= 1
        return (presentationEpoch, presentationSequence, presentationFramesPerSecond)
    }

    func recordPresentation(
        time: TimeInterval,
        epoch: UInt64,
        sequence: UInt64,
        framesPerSecond: Int
    ) {
        guard time.isFinite, time >= 0 else { return }
        lock.lock()
        let acceptsSample = presentationActive && presentationEpoch == epoch
        lock.unlock()
        guard acceptsSample else { return }
        // Zero is retained as an unavailable presentation timestamp. It is
        // never an interval endpoint or independently proof of a dropped
        // frame. Sort positive timestamps within each epoch when analysing:
        // callback scheduling time is not the drawable's presentation time.
        let presentedNanoseconds = Int64(time * 1_000_000_000)
        Self.presentationLogger.info(
            "metal_present stream=\(self.presentationStream, privacy: .public) epoch=\(epoch, privacy: .public) sequence=\(sequence, privacy: .public) target_fps=\(framesPerSecond, privacy: .public) presented_ns=\(presentedNanoseconds, privacy: .public)"
        )
    }
#endif

    func record(startTime: TimeInterval, endTime: TimeInterval) {
        guard startTime > 0, endTime >= startTime else { return }
        lock.lock()
        latestMilliseconds = (endTime - startTime) * 1_000
        lock.unlock()
    }

    func latest() -> Double {
        lock.lock()
        let value = latestMilliseconds
        lock.unlock()
        return value
    }
}

private struct MetalCameraUniforms {
    var viewProjection: simd_float4x4
    var viewportTimeScale: SIMD4<Float>
    var cameraPositionAndTier: SIMD4<Float>
    /// World-space camera basis vectors. Person-hub glyphs use these to
    /// keep their printed face oriented toward the current/reset camera.
    var cameraRight: SIMD4<Float>
    var cameraUp: SIMD4<Float>
    /// `x`: global lock field-dim factor.
    /// `y`: Meaning-cluster visibility, where 1 renders the cluster orbs
    /// (metaball bodies + defined nuclei) fully and 0 hides them. Ramped
    /// by the lock transition's source warp so clusters fade with the
    /// field dim instead of popping at a packet boundary.
    /// `z`: People portrait context-dim phase, where 0 keeps background
    /// hubs bright and 1 applies their baked context dim target.
    var lockControls: SIMD4<Float>
    /// Frame-visual-language flags packed for the shaders:
    /// - `x` = density nebula kind (0 = off, 1 = atmospheric).
    /// - `y` = action motion kind (0 = off, 1 = currentOnly, 2 = allActionable).
    /// - `z` = pulse rest damp: 1 while redraw is sustained (pulses animate
    ///   at full amplitude), ramped to 0 at rest so every pure time-driven
    ///   brightness pulse holds its canonical midpoint in a frozen frame.
    ///   (Slot previously reserved for the retired temporal accent.)
    /// - `w` = arc halo prominence (0 = off, 1 = ambient, 2 = prominent).
    var frameVisualLanguage: SIMD4<Float>
}

/// The live → locked transition: a pure field-dim ramp ("field collapse").
/// The renderer's `fieldDimFactor` sweeps from 1 toward the lock policy's
/// dim target with phase; every star/fiber/halo dims via the existing
/// `lock_dim_multiplier`, except those carrying a `lock.x` focus grade,
/// which interpolate toward full brightness. Pure visibility mechanism —
/// no motion. Historically this carried five candidate mechanisms (camera
/// dolly, dim sweep, fiber wavefront, vertex gravity, plunge-implode
/// hybrid) plus a GPU uniform lane exporting style and focal point/world,
/// all evaluated for the retired dual-Metal-view FocusedScene; the unified
/// in-scene lock path settled on the CPU-side dim sweep, so only the ramp
/// inputs remain.
public struct ConstellationSourceWarp: Equatable {
    public let intensity: Float
    public let phase: Float
    /// Optional dim target. This lets a transition dim toward the lock
    /// policy immediately, before the next packet upload publishes the
    /// same target as `fieldDimFactor`.
    public let fieldDimTarget: Float?
    /// Optional Meaning-cluster visibility endpoint, mirroring
    /// `fieldDimTarget` for the same reason: the locked packet that
    /// carries `meaningClusterVisibility = 0` installs asynchronously
    /// (planner latency scales with the scene), and the fade must ramp
    /// from the first warp frame — not step down whenever that refresh
    /// happens to land.
    public let meaningClusterVisibilityTarget: Float?

    public init(
        intensity: Float,
        phase: Float = 0,
        fieldDimTarget: Float? = nil,
        meaningClusterVisibilityTarget: Float? = nil
    ) {
        self.intensity = intensity
        self.phase = phase
        self.fieldDimTarget = fieldDimTarget
        self.meaningClusterVisibilityTarget = meaningClusterVisibilityTarget
    }
}

private struct MetalStarInstance {
    var positionRadius: SIMD4<Float>
    var color: SIMD4<Float>
    var signal: SIMD4<Float>
    var effects: SIMD4<Float>
    var lock: SIMD4<Float>
    /// `xyz` = `MessageStarInstance.defaultCorrespondentTint` — the colour
    /// the node *would* have under `.accountColorMajorOnly` modulation,
    /// baked CPU-side regardless of the active frame's coloration. The
    /// fragment shader switches `in.color.rgb` to this tint when the node
    /// is triggered (hovered / locked / search-matched) AND the
    /// `EmergeOnInteract.correspondentTint` bit is set on `lock.z`.
    /// `w` is currently reserved (zero) — it previously carried an action
    /// ring code for the retired state-ringed decoration; the lane stays
    /// in the layout to avoid reshuffling the GPU buffer schema.
    var emerge: SIMD4<Float>
}

private struct MetalNebulaInstance {
    var positionRadius: SIMD4<Float>
    var colorDensity: SIMD4<Float>
    var meta: SIMD4<Float>
}

private struct MetalHaloInstance {
    var positionRadius: SIMD4<Float>
    var colorIntensity: SIMD4<Float>
    var meta: SIMD4<Float>
    var lock: SIMD4<Float>
}

private struct MetalFiberVertex {
    var from: SIMD3<Float>
    var strength: Float
    var to: SIMD3<Float>
    var strokeWidthPixels: Float
    var color: SIMD4<Float>
    var lock: SIMD4<Float>
}

/// Saturn-style ring band for a correspondent hub in the `.people` galaxy.
/// Layout mirrors `PersonRingInstance` in the Metal shader source. The
/// alpha channel of `accountColor` carries the optional arc start fraction,
/// and `tier.w` carries the optional arc end fraction for segmented ring
/// variants. Account color is conveyed by the correspondent orb, not by
/// extra People ring geometry.
private struct MetalPersonRingInstance {
    /// `xyz` = ring center in world space. `w` = mid-line radius.
    var centerRadius: SIMD4<Float>
    /// `xyz` = unit-length normal to the ring plane. `w` = band half-width.
    var normalThickness: SIMD4<Float>
    /// `rgb` = base color, `a` = base alpha (inner rings dim via this alpha
    /// proportional to sent/received ratio).
    var colorAlpha: SIMD4<Float>
    /// `rgb` = hub's AccountColor; focused ring fragments use this as a
    /// low inner-edge radiance while keeping the tier tone as the base band.
    /// `a` reserved.
    var accountColor: SIMD4<Float>
    /// `x` = tier code (0..3 inner→outer in the 4-ring system).
    /// `y` = shimmer flag (0 off, 1 on) — fragment uses this to add a
    /// clockwise traveling bright sweep on the band's center line,
    /// engaged for the focused-correspondent's rings in the People
    /// lens's locked-node overlay. `z` = radial glow material. `w` = arc end.
    var tier: SIMD4<Float>
    /// `x` = fade with People context dim phase. Used by transition-only
    /// background rings in the locked People portrait. `y` = deletion progress
    /// for final-hub ring collapse.
    var transition: SIMD4<Float>
}

/// Per-instance data for the 3D person-hub planet pipeline. The vertex
/// shader scales the shared unit-icosphere by `radius` and translates by
/// `center`; the fragment shader uses `color` as the planet's diffuse
/// albedo. Layout mirrors `PersonPlanetInstance` in the Metal shader source.
private struct MetalPersonPlanetInstance {
    /// `xyz` = world center, `w` = world-space radius of the planet body.
    var centerRadius: SIMD4<Float>
    /// `rgb` = albedo, `a` = reserved.
    var color: SIMD4<Float>
    /// `xy` = glyph-atlas origin, `zw` = glyph-atlas size. Zeroed when no
    /// glyph texture is available.
    var glyphUV: SIMD4<Float>
    /// People material: `x` = recency in [0, 1], `y` = focus glow [0, 1],
    /// `z` = wide glyph decal (1 = two-line full name, 0 = initials/icon),
    /// `w` = negative deletion progress for a collapsing correspondent hub.
    /// Meaning material:
    /// `x` = density in [0, 1], `y` = visible-member count (raw), `z` =
    /// per-cluster static brightness phase in radians, `w` = material
    /// selector (1 = transparent field, 2 = defined centre nucleus / hover
    /// target, 3 = the People solar system's emissive sun body).
    var signal: SIMD4<Float>
    /// Solar-system lane: `x` = hub displacement index + 1 (0 = the
    /// zero-displacement sentinel — sun, pinned/locked hubs, non-solar
    /// packets), `y` = petal-red ember intensity from age-weighted open
    /// obligations, `z`/`w` reserved.
    var orbital: SIMD4<Float>
}

/// One engraved orbit path (or recency band guide) in the People solar
/// system. The vertex shader traces the conic r(ν) = q(1+e)/(1+e·cos ν)
/// as an instanced line strip in the orbit's own (P̂, Q̂) frame — the path
/// is time-invariant (only the body moves along it), so this pass never
/// reads the displacement buffer. Layout mirrors `PersonOrbitPathInstance`
/// in the Metal shader source.
private struct MetalPersonOrbitPathInstance {
    /// `xyz` = sun (focus) position, `w` = perihelion distance q.
    var centerPeri: SIMD4<Float>
    /// `xyz` = unit vector toward perihelion (P̂), `w` = eccentricity.
    var axisPE: SIMD4<Float>
    /// `xyz` = in-plane 90°-ahead axis (Q̂, inclination-tilted), `w` =
    /// hub displacement index + 1 (for the transient hover highlight
    /// match against `lockControls.w`; 0 = band guide).
    var axisQH: SIMD4<Float>
    /// `rgb` = whisper line color, `a` = base alpha.
    var colorAlpha: SIMD4<Float>
    /// `x` = style (0 = orbit, 1 = band guide, 2 = comet/dashed),
    /// `y` = baked focus highlight (locked correspondent's path),
    /// `z`/`w` reserved.
    var style: SIMD4<Float>
}

private struct PlanetSphereMesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
}

enum PersonPlanetLOD {
    case low
    case medium
    case high
}

private struct PersonPlanetLODBuckets {
    var low: [MetalPersonPlanetInstance] = []
    var medium: [MetalPersonPlanetInstance] = []
    var high: [MetalPersonPlanetInstance] = []

    nonisolated init(
        low: [MetalPersonPlanetInstance] = [],
        medium: [MetalPersonPlanetInstance] = [],
        high: [MetalPersonPlanetInstance] = []
    ) {
        self.low = low
        self.medium = medium
        self.high = high
    }
}

/// Per-cluster instance for the Meaning-lens metaball body. The vertex
/// shader scales the shared unit-icosphere by `centerRadius.w` (bounding
/// radius covering every aggregated blob's influence) and translates by
/// `centerRadius.xyz` (the cluster's persisted medoid). The fragment shader
/// raymarches through the bounding sphere accumulating blob contributions
/// from `memberRange.x ..< memberRange.x + memberRange.y` in the shared
/// member buffer. Layout mirrors `MeaningMetaballInstance` in the Metal
/// shader source. Internal (not fileprivate) so `MeaningMetaballFramePolicy`
/// and its tests can operate on the packet's CPU-side instance array.
struct MetalMeaningMetaballInstance {
    /// `xyz` = world anchor (cluster medoid), `w` = bounding sphere radius
    /// (>= every blob's distance from the anchor + that blob's influence
    /// radius).
    var centerRadius: SIMD4<Float>
    /// `rgb` = lens colour (see `AccountColorPalette.meaningLensRGB`), `a`
    /// = cluster density in [0, 1] (scales alpha output).
    var color: SIMD4<Float>
    /// `x` = first index into the shared member buffer, `y` = blob count,
    /// `z` = per-cluster static phase, `w` = raymarch step count stamped
    /// per frame by `MeaningMetaballFramePolicy.drawList` (0 in the packet;
    /// the fragment shader treats `<= 0` as the full 24 steps).
    var memberRange: SIMD4<Float>
}

/// One aggregated blob contribution in the shared metaball member buffer.
/// Multiple metaball instances index into this buffer using their
/// `memberRange`.
struct MetalMeaningMetaballMember {
    /// `xyz` = world position, `w` = influence radius (scales with the
    /// blob's affinity plus its constituent spread).
    var positionRadius: SIMD4<Float>
}

/// One representative blob produced by aggregating a cluster's member
/// halos. The metaball fragment shader can afford at most 24 field
/// contributors per cluster, so clusters with more visible members are
/// summarized into blobs that keep the silhouette instead of truncating
/// peripheral members away.
struct MeaningMetaballBlob: Equatable {
    /// Weighted centroid of the constituent halos.
    var position: SIMD3<Float>
    /// Max-normalized aggregate weight: sum of constituent affinities,
    /// scaled so the heaviest blob of the cluster is exactly 1.0.
    var affinity: Float
    /// Weighted RMS distance of constituents from `position`. Zero for
    /// the ≤24-halo passthrough (every halo is its own blob).
    var spread: Float
    /// Farthest constituent assigned to this blob. The influence radius uses
    /// this hard extent so low-affinity peripheral members cannot disappear
    /// outside the visible gas while RMS spread remains small.
    var maximumConstituentDistance: Float
}

enum MeaningMetaballMemberPolicy {
    nonisolated static let maxMemberCount = 24
    /// One representative slot is reserved for the connected envelope field.
    nonisolated static let detailedMemberCount = maxMemberCount - 1
    nonisolated static let guaranteedCoverageFraction: Float = 0.80
    /// Fixed Lloyd refinement passes — a constant iteration count keeps the
    /// aggregation deterministic (identical input → identical output).
    nonisolated static let lloydIterations = 4
    /// Floor applied to per-halo weights inside the centroid math so a
    /// zero-affinity halo cannot zero a blob's denominator.
    nonisolated private static let weightFloor: Float = 1e-4

    /// Influence radius for one blob. The density radius preserves the
    /// calibrated visual body; the coverage radius guarantees that the
    /// farthest absorbed member lies within 80% of the field radius, safely
    /// inside the shader's visible-gas threshold.
    nonisolated static func influenceRadius(of blob: MeaningMetaballBlob) -> Float {
        let densityRadius = 0.05 + blob.affinity * 0.04 + min(blob.spread, 0.03)
        let coverageRadius = blob.maximumConstituentDistance / guaranteedCoverageFraction + 0.002
        return max(densityRadius, coverageRadius)
    }

    /// Central low-density field that makes the planner's complete envelope
    /// one connected visible body. At the envelope edge the quadratic kernel
    /// remains above the shader's 0.08 gas threshold.
    nonisolated static func envelopeInfluenceRadius(_ envelopeRadius: Float) -> Float {
        max(0.05, max(0, envelopeRadius) / guaranteedCoverageFraction + 0.002)
    }

    /// Aggregate a cluster's member halos into at most `maxMemberCount`
    /// representative blobs.
    ///
    /// - `haloCount <= maxMemberCount`: passthrough — every halo becomes
    ///   its own blob with its original affinity and zero spread, so small
    ///   clusters render exactly as before.
    /// - Larger clusters: weighted k-means (k = `maxMemberCount`) over halo
    ///   positions with affinity weights. Deterministic farthest-point seeds
    ///   preserve the spatial extremes before exactly `lloydIterations`
    ///   assign/update rounds; ties resolve to the lowest blob index.
    ///   Blob affinity is the constituent affinity sum normalized so the
    ///   heaviest blob is 1.0; blob spread is the weighted RMS constituent
    ///   distance feeding `influenceRadius(of:)`.
    ///
    /// Deterministic, empty-safe, and guaranteed ≤ `maxMemberCount`.
    nonisolated static func aggregatedHalos(
        _ halos: [MeaningClusterMemberHalo],
        maximumCount: Int = maxMemberCount
    ) -> [MeaningMetaballBlob] {
        aggregate(halos, maximumCount: maximumCount).blobs
    }

    /// Full aggregation result: the deterministically sorted constituents,
    /// their final blob assignment (index into `blobs`), and the blobs.
    /// Internal seam so tests can verify affinity conservation and that
    /// every constituent sits inside its blob's influence radius; the
    /// render path consumes only `blobs` via `aggregatedHalos(_:)`.
    nonisolated static func aggregate(
        _ halos: [MeaningClusterMemberHalo],
        maximumCount: Int = maxMemberCount
    ) -> (constituents: [MeaningClusterMemberHalo], assignment: [Int], blobs: [MeaningMetaballBlob]) {
        guard !halos.isEmpty else { return ([], [], []) }
        let maximumCount = max(1, min(maxMemberCount, maximumCount))
        if halos.count <= maximumCount {
            let blobs = halos.map {
                MeaningMetaballBlob(
                    position: $0.position,
                    affinity: $0.affinity,
                    spread: 0,
                    maximumConstituentDistance: 0
                )
            }
            return (halos, Array(halos.indices), blobs)
        }

        // Deterministic constituent order: position lexicographic, then
        // affinity. Exact duplicates (same position AND affinity) are
        // interchangeable, so the output is value-deterministic even
        // though `sorted` is not stable.
        let sorted = halos.sorted { lhs, rhs in
            if lhs.position.x != rhs.position.x { return lhs.position.x < rhs.position.x }
            if lhs.position.y != rhs.position.y { return lhs.position.y < rhs.position.y }
            if lhs.position.z != rhs.position.z { return lhs.position.z < rhs.position.z }
            return lhs.affinity < rhs.affinity
        }
        let k = min(maximumCount, sorted.count)
        var centers: [SIMD3<Float>] = [sorted[0].position]
        centers.reserveCapacity(k)
        while centers.count < k {
            var selectedIndex = 0
            var selectedDistance = -Float.greatestFiniteMagnitude
            for (index, halo) in sorted.enumerated() {
                var nearest = Float.greatestFiniteMagnitude
                for center in centers {
                    nearest = min(
                        nearest,
                        simd_length_squared(halo.position - center)
                    )
                }
                if nearest > selectedDistance {
                    selectedDistance = nearest
                    selectedIndex = index
                }
            }
            centers.append(sorted[selectedIndex].position)
        }
        var assignment = [Int](repeating: 0, count: sorted.count)

        for _ in 0..<lloydIterations {
            // Assign: nearest center, ties to the lowest center index.
            for (index, halo) in sorted.enumerated() {
                var best = 0
                var bestDistance = Float.greatestFiniteMagnitude
                for (centerIndex, center) in centers.enumerated() {
                    let distance = simd_length_squared(halo.position - center)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = centerIndex
                    }
                }
                assignment[index] = best
            }
            // Update: weighted centroid per center; empty centers keep
            // their previous position (deterministic, and they simply
            // produce no blob below).
            var sums = [SIMD3<Float>](repeating: .zero, count: k)
            var weights = [Float](repeating: 0, count: k)
            for (index, halo) in sorted.enumerated() {
                let weight = max(halo.affinity, weightFloor)
                sums[assignment[index]] += halo.position * weight
                weights[assignment[index]] += weight
            }
            for centerIndex in 0..<k where weights[centerIndex] > 0 {
                centers[centerIndex] = sums[centerIndex] / weights[centerIndex]
            }
        }

        // After the final update each center is exactly the weighted
        // centroid of the constituents the last assignment gave it, so
        // blob position and constituent statistics stay consistent.
        var affinitySums = [Float](repeating: 0, count: k)
        var spreadNumerators = [Float](repeating: 0, count: k)
        var spreadDenominators = [Float](repeating: 0, count: k)
        var maximumDistances = [Float](repeating: 0, count: k)
        var counts = [Int](repeating: 0, count: k)
        for (index, halo) in sorted.enumerated() {
            let centerIndex = assignment[index]
            counts[centerIndex] += 1
            affinitySums[centerIndex] += halo.affinity
            let weight = max(halo.affinity, weightFloor)
            let distanceSquared = simd_length_squared(halo.position - centers[centerIndex])
            spreadNumerators[centerIndex] += weight * distanceSquared
            spreadDenominators[centerIndex] += weight
            maximumDistances[centerIndex] = max(
                maximumDistances[centerIndex],
                sqrt(distanceSquared)
            )
        }
        let maxAffinitySum = affinitySums.max() ?? 0

        // Compact empty centers away, remapping the assignment onto the
        // surviving blob indices.
        var blobIndexByCenter = [Int](repeating: -1, count: k)
        var blobs: [MeaningMetaballBlob] = []
        blobs.reserveCapacity(k)
        for centerIndex in 0..<k where counts[centerIndex] > 0 {
            blobIndexByCenter[centerIndex] = blobs.count
            blobs.append(MeaningMetaballBlob(
                position: centers[centerIndex],
                affinity: maxAffinitySum > 0 ? affinitySums[centerIndex] / maxAffinitySum : 0,
                spread: spreadDenominators[centerIndex] > 0
                    ? sqrt(spreadNumerators[centerIndex] / spreadDenominators[centerIndex])
                    : 0,
                maximumConstituentDistance: maximumDistances[centerIndex]
            ))
        }
        let remapped = assignment.map { blobIndexByCenter[$0] }
        return (sorted, remapped, blobs)
    }
}

/// Per-frame encode policy for the Meaning metaball pass: back-to-front
/// view-depth sorting, sub-pixel culling, and tier/size-scaled raymarch
/// step counts stamped into `memberRange.w`. Pure functions so the frame
/// math is testable without a Metal device.
enum MeaningMetaballFramePolicy {
    /// Bodies whose projected bounding-sphere radius falls below this many
    /// drawable pixels are culled for the frame.
    nonisolated static let cullPixelRadius: Float = 3
    /// Below this projected radius the tier's step count is halved — a
    /// small-on-screen body cannot show 24 steps' worth of detail.
    nonisolated static let smallBodyPixelRadius: Float = 40
    nonisolated static let minSteps = 6
    nonisolated static let maxSteps = 24
    /// `P[1][1]` of the renderer's projection matrix — `1 / tan(fovY / 2)`
    /// at the fixed `π/3` vertical field of view `projectionMatrix(aspect:)`
    /// always uses. Must change with it.
    nonisolated static let projectionYScale: Float = 1 / tan(Float.pi / 6)

    /// Raymarch step budget by degradation tier. `aggregateHeavy` returns 0
    /// — the encode path skips the whole pass there, mirroring the
    /// orbit-path engraving gate.
    nonisolated static func baseSteps(for tier: RenderDegradationTier) -> Int {
        switch tier {
        case .full, .reducedEffects:
            return 24
        case .reducedFibers:
            return 16
        case .reducedRefinement:
            return 12
        case .aggregateHeavy:
            return 0
        }
    }

    /// Final per-instance step count: the tier base, halved for
    /// small-on-screen bodies, clamped to `[minSteps, maxSteps]`.
    nonisolated static func marchSteps(baseSteps: Int, projectedPixelRadius: Float) -> Int {
        guard baseSteps > 0 else { return 0 }
        let scaled = projectedPixelRadius < smallBodyPixelRadius ? baseSteps / 2 : baseSteps
        return min(maxSteps, max(minSteps, scaled))
    }

    /// Projected bounding-sphere radius in drawable pixels. `clipW` is the
    /// instance center's clip-space `w` — the camera-forward view depth
    /// under the renderer's projection. Non-positive depth (center on or
    /// behind the camera plane) reports `.infinity`: such a sphere, if it
    /// survives the behind-camera cull, covers a large screen region.
    nonisolated static func projectedPixelRadius(
        boundingRadius: Float,
        clipW: Float,
        drawableHeight: Float
    ) -> Float {
        guard clipW > 0 else { return .infinity }
        return boundingRadius * projectionYScale * drawableHeight * 0.5 / clipW
    }

    /// Build the frame's draw list: cull invisible bodies, stamp each
    /// survivor's raymarch step count into `memberRange.w`, and sort
    /// back-to-front by view depth (deterministic tie-break by per-cluster
    /// phase, then packet order) so overlapping translucent bodies blend
    /// in a stable order.
    nonisolated static func drawList(
        instances: [MetalMeaningMetaballInstance],
        viewProjection: simd_float4x4,
        cameraPosition: SIMD3<Float>,
        drawableHeight: Float,
        tier: RenderDegradationTier
    ) -> [MetalMeaningMetaballInstance] {
        guard tier < .aggregateHeavy, !instances.isEmpty else { return [] }
        let base = baseSteps(for: tier)

        struct Entry {
            var instance: MetalMeaningMetaballInstance
            var depth: Float
            var index: Int
        }
        var entries: [Entry] = []
        entries.reserveCapacity(instances.count)
        for (index, instance) in instances.enumerated() {
            let center = SIMD3<Float>(
                instance.centerRadius.x, instance.centerRadius.y, instance.centerRadius.z
            )
            let radius = max(instance.centerRadius.w, 0.0001)
            let clip = viewProjection * SIMD4<Float>(center.x, center.y, center.z, 1)
            let cameraInside = simd_length(cameraPosition - center) <= radius
            // Sphere entirely behind the camera plane (and the camera is
            // outside it): nothing of it can reach the frustum.
            if !cameraInside, clip.w + radius <= 0 { continue }
            let projected = projectedPixelRadius(
                boundingRadius: radius,
                clipW: clip.w,
                drawableHeight: drawableHeight
            )
            if !cameraInside, projected < cullPixelRadius { continue }
            var stamped = instance
            stamped.memberRange.w = Float(marchSteps(
                baseSteps: base,
                projectedPixelRadius: cameraInside ? .infinity : projected
            ))
            entries.append(Entry(instance: stamped, depth: clip.w, index: index))
        }
        entries.sort { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
            if lhs.instance.memberRange.z != rhs.instance.memberRange.z {
                return lhs.instance.memberRange.z < rhs.instance.memberRange.z
            }
            return lhs.index < rhs.index
        }
        return entries.map(\.instance)
    }
}


/// CPU-side pick target — one per hit proxy, in `hitProxies` order,
/// mirroring exactly what the retired GPU picking pass encoded per
/// instance. `ConstellationMetalRenderer.resolvePick` walks these with the
/// same math the pick vertex/fragment shaders used (displacement lane,
/// signal-boosted pixel radius, Saturn-detail collapse, frustum clip,
/// nearest-depth winner), so hit-testing stays faithful to the rendered
/// geometry without a render pass and a blocking `waitUntilCompleted`
/// readback on every hover resolution and click.
struct ConstellationPickTarget {
    /// Base world position (pre-displacement) and world-space radius.
    var worldPosition: SIMD3<Float>
    var worldRadius: Float
    /// Floor in drawable pixels (`HitProxy.radiusPixels`).
    var minPixelRadius: Float
    /// max(hover, selected, search, citation) — triggered nodes render
    /// larger, and their pick circles grow by the same 55%.
    var signalBoost: Float
    /// People displacement lane: index + 1 into the displacement table,
    /// 0 = identity (non-solar packets, pinned hubs, the sun).
    var lane: Int
    /// Ring satellites become untargetable while their hub's Saturn
    /// detail is faded out; planet bodies never carry the flag.
    var collapsesWithDetailFade: Bool
    /// Meaning-cluster hub targets. Option-held picking restricts the
    /// candidate set to these so cluster hover/click never loses to the
    /// message nodes layered through the cluster body.
    var isMeaningCluster: Bool = false
}

/// Byte layout of one per-instance struct hand-mirrored between Swift and
/// Metal. Compared by `MetalInstanceLayoutTests`.
struct MetalInstanceLayoutFingerprint: Equatable {
    let name: String
    let stride: Int
    let size: Int
    let alignment: Int
}

/// Drift guard for the per-instance struct layouts hand-mirrored between
/// this file and `ConstellationMetalShaders.metal`. The GPU reads exactly
/// the bytes the CPU writes — field for field — so any change to a Swift
/// mirror's shape must be matched on the `.metal` side. `MetalInstanceLayoutTests`
/// pins these fingerprints; a failure means a mirror changed shape and the
/// shader struct (plus the expected values in that test) must be reconciled
/// in the same edit. `name` is the Metal-side struct name so a diff points
/// straight at the counterpart to fix.
enum MetalInstanceLayout {
    static var fingerprints: [MetalInstanceLayoutFingerprint] {
        [
            fingerprint("CameraUniforms", MetalCameraUniforms.self),
            fingerprint("StarInstance", MetalStarInstance.self),
            fingerprint("NebulaInstance", MetalNebulaInstance.self),
            fingerprint("HaloInstance", MetalHaloInstance.self),
            fingerprint("FiberVertex", MetalFiberVertex.self),
            fingerprint("PersonRingInstance", MetalPersonRingInstance.self),
            fingerprint("PersonPlanetInstance", MetalPersonPlanetInstance.self),
            fingerprint("PersonOrbitPathInstance", MetalPersonOrbitPathInstance.self),
            fingerprint("MeaningMetaballInstance", MetalMeaningMetaballInstance.self),
            fingerprint("MeaningMetaballMember", MetalMeaningMetaballMember.self),
        ]
    }

    private static func fingerprint<T>(_ name: String, _ type: T.Type) -> MetalInstanceLayoutFingerprint {
        MetalInstanceLayoutFingerprint(
            name: name,
            stride: MemoryLayout<T>.stride,
            size: MemoryLayout<T>.size,
            alignment: MemoryLayout<T>.alignment
        )
    }
}

public final class ConstellationMetalRenderer {
    private enum BlendMode {
        case opaque
        case alpha
        case additive
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let backgroundPipeline: MTLRenderPipelineState
    private let haloPipeline: MTLRenderPipelineState
    private let starPipeline: MTLRenderPipelineState
    private let nebulaPipeline: MTLRenderPipelineState
    private let fiberPipeline: MTLRenderPipelineState
    private let personRingPipeline: MTLRenderPipelineState
    private let personPlanetPipeline: MTLRenderPipelineState
    /// Engraved orbit paths + recency band guides for the People solar
    /// system — instanced line strips tracing each hub's conic.
    private let personOrbitPathPipeline: MTLRenderPipelineState
    private let meaningClusterPlanetPipeline: MTLRenderPipelineState
    /// Metaball-isosurface pipeline for the Meaning-lens cluster body. One
    /// instance per cluster; the fragment shader raymarches the bounding
    /// sphere summing member contributions from the shared member buffer.
    private let meaningClusterMetaballPipeline: MTLRenderPipelineState
    private let personGlyphSampler: MTLSamplerState
    private let transparentPersonGlyphTexture: MTLTexture
    /// Default depth state for sprite passes — always pass, no write. Pass
    /// participates in depth (the attachment exists) but neither tests nor
    /// writes, so all sprite layers continue to render in draw order.
    private let passThroughDepthState: MTLDepthStencilState
    /// Planet body — `less` test + depth write. Establishes the planet's
    /// silhouette in the depth buffer so the ring pipeline (and any other
    /// sprite layer that opts into depth-test) is correctly occluded.
    private let planetDepthState: MTLDepthStencilState
    /// Translucent layers that should be hidden where a closer planet body
    /// exists — `less-equal` test, no write. Used by the ring pipeline so
    /// rings going behind a planet vanish on the far side and stay visible
    /// where they pass in front, without rings occluding each other.
    private let occludedSpriteDepthState: MTLDepthStencilState
    /// Shared procedural icosphere meshes, generated once at init and
    /// instanced per planet. People hubs choose an LOD bucket by rendered
    /// body size; Meaning clusters use the cheap low mesh because their
    /// body edge is fragment-feathered.
    private let planetSphereLowMesh: PlanetSphereMesh
    private let planetSphereMediumMesh: PlanetSphereMesh
    private let planetSphereHighMesh: PlanetSphereMesh

    private var starBuffer: MTLBuffer?
    private var haloBuffer: MTLBuffer?
    private var nebulaBuffer: MTLBuffer?
    private var fiberBuffer: MTLBuffer?
    private var personPlanetLowBuffer: MTLBuffer?
    private var personPlanetMediumBuffer: MTLBuffer?
    private var personPlanetHighBuffer: MTLBuffer?
    private var meaningClusterPlanetBuffer: MTLBuffer?
    /// CPU-side metaball instances for the current packet — one per
    /// cluster. Each frame `MeaningMetaballFramePolicy.drawList` culls,
    /// step-stamps, and depth-sorts these, and the survivors upload via
    /// `setVertexBytes` (≤32 instances × 48 B, well under the 4 KB
    /// inline-constant limit), so this pass keeps no persistent instance
    /// `MTLBuffer`.
    private var meaningClusterMetaballInstances: [MetalMeaningMetaballInstance] = []
    /// Concatenated `MetalMeaningMetaballMember` entries across all
    /// clusters in this packet. Each instance's `memberRange` field slices
    /// into this buffer.
    private var meaningClusterMetaballMemberBuffer: MTLBuffer?
    private var personGlyphTexture: MTLTexture?
    /// Test-only identity view of the installed People glyph atlas —
    /// the memoization contract tests assert cache reuse vs rebuild by
    /// comparing texture object identity across packet installs.
    var personGlyphTextureForTesting: MTLTexture? { personGlyphTexture }
    var pickTargetsForTesting: [ConstellationPickTarget] { pickTargets }
    /// Atlas requests are keyed before AppKit label measurement, so a cached
    /// signature is cheap and a miss never rasterizes during packet install.
    private var personGlyphAtlasCache: [String: (atlas: PersonGlyphAtlas, stamp: UInt64)] = [:]
    private var personGlyphAtlasStamp: UInt64 = 0
    private static let personGlyphAtlasCacheCapacity = 4
    private var resolvedLabelKindCache: [String: PersonOrbLabelKind] = [:]
    private static let resolvedLabelKindCacheCapacity = 4_096
    private let glyphAtlasBuilder = PersonGlyphAtlasBuilder()
    private(set) var glyphAtlasPreparationTask: Task<Void, Never>?
    private var glyphAtlasRequestGeneration: UInt64 = 0
    private var glyphAtlasRequestedSignature: String?
    private var glyphAtlasHubs: [PersonHubInstance] = []
    private var glyphAtlasTiers: [PersonPlanetLOD] = []
    var onGlyphAtlasReady: (@MainActor () -> Void)?
    /// Fallback sprite-hub buffer for packets with `renderHubsAsPlanets =
    /// false` (today: the locked-overlay Focus scene). Mutually exclusive
    /// with the person-planet LOD buffers — at most one representation is
    /// non-nil per packet.
    private var personHubSpriteBuffer: MTLBuffer?
    private var personRingBuffer: MTLBuffer?
    private var personAtomBuffer: MTLBuffer?
    // MARK: People solar system
    /// The sun instance for the current packet (nil outside the People
    /// solar system). Carries the orbital epoch and ecliptic basis.
    private var personSun: PersonSunInstance?
    /// Per-hub orbits aligned with `packet.personHubs` order. Nil entries
    /// are pinned hubs (zero displacement by construction).
    private var personHubOrbits: [PersonOrbit?] = []
    /// Packet base positions + solar planet radii aligned with hub order.
    private var personHubBasePositions: [SIMD3<Float>] = []
    private var personHubPlanetRadii: [Float] = []
    /// Email / primary-message → hub index maps for displacement lookup.
    private var personHubIndexByEmail: [String: Int] = [:]
    private var personHubIndexByMessageId: [String: Int] = [:]
    /// Per-placement lanes for message stars riding hubs: a multi-
    /// recipient message has one ring placement per hub, and live-position
    /// translation must pick the placement the caller actually holds
    /// (matched by packet base position), not the primary hub's.
    private var peopleStarPlacementLanes: [String: [(position: SIMD3<Float>, lane: Int)]] = [:]
    /// GPU displacement + detail-fade table: entry 0 is the identity
    /// sentinel (zero displacement, fade 1); entry i+1 belongs to hub i.
    /// Rewritten every animating frame while the GPU may still be reading
    /// a prior frame's copy from an in-flight command buffer, so instead of
    /// one buffer overwritten in place, we keep a ring of `displacementRingDepth`
    /// buffers and rotate to a fresh slot on each write. MTKView's drawable
    /// pool (≤3 frames in flight) caps how far the CPU runs ahead, so a
    /// ring this deep guarantees the slot being written is never the slot a
    /// still-in-flight frame is reading — no tearing, and no main-thread
    /// semaphore wait that could leak on `draw`'s early-return guards.
    private var peopleDisplacementBuffers: [MTLBuffer] = []
    private var peopleDisplacementBufferIndex = 0
    /// Ring depth — matches the MTKView drawable pool so a written slot is
    /// always at least `depth` writes (≥ `depth` frames) removed from any
    /// slot still referenced by an in-flight command buffer.
    private static let displacementRingDepth = 3
    /// The slot the current frame's passes bind — the most recently written
    /// buffer. Nil for non-solar packets (callers fall back to
    /// `zeroDisplacementBuffer`).
    private var currentPeopleDisplacementBuffer: MTLBuffer? {
        guard peopleDisplacementBuffers.indices.contains(peopleDisplacementBufferIndex) else { return nil }
        return peopleDisplacementBuffers[peopleDisplacementBufferIndex]
    }
    /// CPU mirror of the displacement table for hover/lock translation.
    private var peopleDisplacements: [SIMD4<Float>] = []
    /// Identity table bound whenever a pass's shader expects the
    /// displacement buffer but the packet has no solar system.
    private let zeroDisplacementBuffer: MTLBuffer
    private var personOrbitPathBuffer: MTLBuffer?
    private var personOrbitPathCount = 0
    private var personSunBuffer: MTLBuffer?
    /// Orbital clock the displacement table currently reflects.
    private var displacedOrbitalTime: TimeInterval = .nan
    /// Camera position the detail fades were last evaluated against.
    private var detailFadeCameraPosition: SIMD3<Float>?
    private var detailFadeViewportHeight: Float = 0
    /// Transient hover highlight for orbit paths — hub index + 1, or 0.
    /// Set by the host view's hover routing; consumed as a uniform.
    private var hoveredOrbitPathHubIndexPlusOne: Float = 0
    /// Transient Meaning-cluster hover flare: the hovered cluster's
    /// deterministic phase + 1, or 0. Shares the `lockControls.w` uniform
    /// lane with the People orbit-path hover — safe because each lane is
    /// nonzero only while its own lens's hubs exist in the packet.
    private var hoveredMeaningClusterPhasePlusOne: Float = 0
    private var hoveredMeaningClusterId: Int64?
    /// The hovered correspondent's email backing that highlight. Retained
    /// so the lane can be re-resolved when a packet rebuild reorders hubs
    /// (they arrive reciprocity-sorted) — a bare index would then brighten
    /// whichever hub inherited the stale lane, not the hovered one.
    private var hoveredOrbitPathEmail: String?
    /// One entry per `hitProxies` element, rebuilt with each packet.
    /// Consumed by the CPU `hitTest` in place of the retired GPU pick pass.
    private var pickTargets: [ConstellationPickTarget] = []
    private var starCount = 0
    private var satelliteCount = 0
    private var haloCount = 0
    private var nebulaCount = 0
    private var fiberVertexCount = 0
    private var personPlanetCount = 0
    private var personPlanetLowCount = 0
    private var personPlanetMediumCount = 0
    private var personPlanetHighCount = 0
    private var meaningClusterPlanetCount = 0
    private var personHubSpriteCount = 0
    private var personRingCount = 0
    private var personAtomCount = 0
    private var hitProxies: [HitProxy] = []
    private var packetGeneratedAt: TimeInterval = 0
    private var budget: RenderBudget = .conservative
    private var fieldDimFactor: Float = 1.0
    private var meaningClusterVisibilityTarget: Float = 1.0
    private var peopleContextDimPhase: Float = 1.0
    /// People-portrait context-ring visibility (rides `cameraUp.w` in the
    /// uniforms). Defaults to the dim ramp's mirror; exits pin it to 0 —
    /// see `setPeopleContextDimPhase(_:ringVisibility:)`.
    private var peopleContextRingVisibility: Float = 0.0
    /// Active visual language, refreshed each `update(packet:)`. Drives the
    /// `frameVisualLanguage` uniform consumed by the nebula / star
    /// fragment shaders so per-frame channels (atmospheric breathing,
    /// action motion) light up without per-instance flags.
    private var currentVisualLanguage: FrameVisualLanguage = .forFrame(.defaultFrame)
    /// Small, renderer-relative seconds for shader animation. Do not feed
    /// Unix epoch seconds to Metal as Float32; epoch-scale values lose enough
    /// precision to make shimmer-style phase math unstable.
    private let animationStartTime = CACurrentMediaTime()
    /// Floating cluster labels emitted by legacy arc annotation. Read by
    /// `ConstellationModeView`'s SwiftUI overlay so labels can be projected
    /// with `ScreenProjection.project(...)`. Current live lenses leave this
    /// empty.
    public private(set) var arcLabels: [ArcLabelOverlay] = []
    private var lastPacketPreparationMilliseconds: Double = 0
    private var lastCPUEncodingMilliseconds: Double = 0
    private let frameTimingStore = MetalFrameTimingStore()
    /// True when the installed packet contains stars or satellites whose
    /// search / citation / selected signal channels are lit. Those three
    /// channels render as time-driven sine pulses in the star fragment
    /// shader, so the scene needs continuous redraw while any are visible
    /// — the draw loop reads this as its highlight keep-alive latch.
    /// Practical/action-motion pulses are deliberately excluded: they
    /// mark broad populations in action-motion frames, and latching on
    /// them would defeat the event-driven pause architecture.
    public private(set) var scenePulsesSignals = false

    /// Amplitude damp for the pure time-driven brightness pulses (signal
    /// pulses, halo breathing, nebula atmospherics). Held at 1 while the
    /// draw loop sustains redraw; ramped to 0 over a short settle tail
    /// once sustained redraw ends, so a frozen frame holds every pulse
    /// at its canonical midpoint instead of an arbitrary sine phase —
    /// and ramped back from 0 on wake, so the wall-clock phase jump
    /// after a long rest never lands on screen at visible amplitude.
    /// Spatially textured time effects (ring shimmer, dust drift) are
    /// deliberately NOT damped: their frozen frames stay structured, and
    /// flattening them at rest would erase the texture itself.
    private var pulseRestDamp: Float = 1
    private var pulseRestDampTarget: Float = 1
    private var lastPulseDampTickTime: CFTimeInterval?

    static let pulseRestDampRampSeconds: Double = 0.25
    /// A single tick may advance the ramp by at most this much wall time,
    /// so an hour-long pause between draws resumes as a visible ramp
    /// instead of a snap.
    static let pulseRestDampTickCapSeconds: Double = 0.1

    /// The draw loop reports whether it intends to keep sustaining
    /// redraw; the damp integrates toward that target on each frame.
    public func setPulseAnimationActive(_ active: Bool) {
        pulseRestDampTarget = active ? 1 : 0
    }

    /// True while the damp is still ramping toward its target. The draw
    /// loop keeps requesting frames for this settle tail so pulses ease
    /// to rest (or back in) instead of stepping.
    public var pulseRestSettling: Bool {
        pulseRestDamp != pulseRestDampTarget
    }

    /// Pure damp integration step — linear ramp over
    /// `pulseRestDampRampSeconds`, with the frame delta gap-capped so a
    /// long pause between draws advances the ramp by at most one capped
    /// step instead of snapping.
    nonisolated static func pulseRestDampStepped(
        current: Float,
        target: Float,
        deltaSeconds: Double
    ) -> Float {
        let dt = max(0, min(deltaSeconds, pulseRestDampTickCapSeconds))
        let step = Float(dt / pulseRestDampRampSeconds)
        if target > current {
            return min(target, current + step)
        }
        return max(target, current - step)
    }

    func tickPulseRestDamp(now: CFTimeInterval) -> Float {
        let dt = now - (lastPulseDampTickTime ?? now)
        lastPulseDampTickTime = now
        pulseRestDamp = Self.pulseRestDampStepped(
            current: pulseRestDamp,
            target: pulseRestDampTarget,
            deltaSeconds: dt
        )
        return pulseRestDamp
    }

    public init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            preconditionFailure("Constellation requires Metal support.")
        }
        self.device = device
        self.commandQueue = queue
        self.personGlyphSampler = Self.makePersonGlyphSampler(device: device)
        self.transparentPersonGlyphTexture = Self.makeTransparentGlyphTexture(device: device)
        var identityEntry = SIMD4<Float>(0, 0, 0, 1)
        guard let zeroBuffer = device.makeBuffer(
            bytes: &identityEntry,
            length: MemoryLayout<SIMD4<Float>>.stride,
            options: [.storageModeShared]
        ) else {
            preconditionFailure("Constellation Metal zero-displacement buffer creation failed.")
        }
        self.zeroDisplacementBuffer = zeroBuffer

        guard let library = device.makeDefaultLibrary() else {
            preconditionFailure("Constellation Metal shaders were not compiled into the app bundle.")
        }
        do {
            backgroundPipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "constellation_background_vertex",
                fragment: "constellation_background_fragment",
                blendMode: .opaque
            )
            haloPipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "constellation_halo_vertex",
                fragment: "constellation_halo_fragment",
                blendMode: .additive
            )
            starPipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "constellation_star_vertex",
                fragment: "constellation_star_fragment",
                blendMode: .alpha
            )
            nebulaPipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "constellation_nebula_vertex",
                fragment: "constellation_nebula_fragment",
                blendMode: .alpha
            )
            fiberPipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "constellation_fiber_vertex",
                fragment: "constellation_fiber_fragment",
                blendMode: .alpha
            )
            personRingPipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "constellation_person_ring_vertex",
                fragment: "constellation_person_ring_fragment",
                blendMode: .alpha
            )
            personPlanetPipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "constellation_person_planet_vertex",
                fragment: "constellation_person_planet_fragment",
                blendMode: .opaque
            )
            personOrbitPathPipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "constellation_person_orbit_vertex",
                fragment: "constellation_person_orbit_fragment",
                blendMode: .alpha
            )
            meaningClusterPlanetPipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "constellation_person_planet_vertex",
                fragment: "constellation_person_planet_fragment",
                blendMode: .alpha
            )
            meaningClusterMetaballPipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "meaning_metaball_vertex",
                fragment: "meaning_metaball_fragment",
                blendMode: .alpha
            )
        } catch {
            preconditionFailure("Constellation Metal pipeline creation failed: \(String(reflecting: type(of: error)))")
        }
        let passThroughDescriptor = MTLDepthStencilDescriptor()
        passThroughDescriptor.depthCompareFunction = .always
        passThroughDescriptor.isDepthWriteEnabled = false
        guard let passThrough = device.makeDepthStencilState(descriptor: passThroughDescriptor) else {
            preconditionFailure("Constellation Metal pass-through depth-state creation failed.")
        }
        passThroughDepthState = passThrough

        let planetDescriptor = MTLDepthStencilDescriptor()
        planetDescriptor.depthCompareFunction = .less
        planetDescriptor.isDepthWriteEnabled = true
        guard let planetDepth = device.makeDepthStencilState(descriptor: planetDescriptor) else {
            preconditionFailure("Constellation Metal planet depth-state creation failed.")
        }
        planetDepthState = planetDepth

        let occludedDescriptor = MTLDepthStencilDescriptor()
        occludedDescriptor.depthCompareFunction = .lessEqual
        occludedDescriptor.isDepthWriteEnabled = false
        guard let occluded = device.makeDepthStencilState(descriptor: occludedDescriptor) else {
            preconditionFailure("Constellation Metal occluded-sprite depth-state creation failed.")
        }
        occludedSpriteDepthState = occluded

        // LOD meshes:
        // - low    = level 2, 162 verts / 320 tris: original cheap People view
        // - medium = level 3, 642 verts / 1,280 tris: larger background hubs
        // - high   = level 4, 2,562 verts / 5,120 tris: selected/close hubs
        //
        // The locked overlay can bring a correspondent body close enough to
        // fill hundreds of pixels, where low/medium silhouettes become
        // visibly faceted. Global People views can contain hundreds of hubs,
        // so only a capped large-hub bucket gets the high mesh.
        planetSphereLowMesh = Self.makeIcosphereMesh(device: device, subdivisions: 2)
        planetSphereMediumMesh = Self.makeIcosphereMesh(device: device, subdivisions: 3)
        planetSphereHighMesh = Self.makeIcosphereMesh(device: device, subdivisions: 4)
    }

    deinit {
        glyphAtlasPreparationTask?.cancel()
    }

    public var metalDevice: MTLDevice { device }

    /// `ringVisibility` is the People-portrait context ring-BAND channel
    /// (background hubs' Saturn bands; the flagged ring satellites stay
    /// on the dim phase — they exist in the unlocked galaxy too). By
    /// default it mirrors the dim ramp (`1 − phase`: bands visible at
    /// open context, hidden at full recede). Lock exits and releases pass
    /// an explicit 0 so the reversing dim brightens the background
    /// planets WITHOUT fading their bands back in — bands exist only in
    /// portrait packets, so a mid-exit or post-release bloom would only
    /// snap away when the unlocked packet lands.
    public func setPeopleContextDimPhase(_ phase: Float, ringVisibility: Float? = nil) {
        peopleContextDimPhase = max(0, min(1, phase))
        peopleContextRingVisibility = max(0, min(1, ringVisibility ?? (1 - phase)))
    }

    /// Last phase written by `setPeopleContextDimPhase`. Lock exits read
    /// this so a release that lands mid-entry-ramp reverses from wherever
    /// the recede actually got to, instead of snapping to fully receded
    /// before fading back in.
    public func currentPeopleContextDimPhase() -> Float {
        peopleContextDimPhase
    }

    public func update(packet: ConstellationRenderPacket) {
        let start = CACurrentMediaTime()
        if !packet.renderHubsAsPlanets || packet.personHubs.isEmpty {
            cancelGlyphAtlasPreparation()
        }
        packetGeneratedAt = packet.generatedAt
        budget = packet.budget
        fieldDimFactor = max(0, min(1, packet.fieldDimFactor))
        meaningClusterVisibilityTarget = max(0, min(1, packet.meaningClusterVisibility))
        hitProxies = packet.hitProxies
        currentVisualLanguage = packet.visualLanguage
        arcLabels = packet.arcLabels
        scenePulsesSignals = Self.packetPulsesSignals(packet)

        // People solar system caches must exist before star/pick packing —
        // ring satellites and hit proxies resolve their hub displacement
        // lane through these maps.
        rebuildPeopleSolarCaches(packet: packet)

        let stars = packet.stars.map { star in
            Self.starInstance(star, hubLane: hubDisplacementLane(forEmail: star.peopleHubEmail))
        }
        let satellites = packet.satellites.map(Self.satelliteInstance)
        let combinedStars = stars + satellites
        starCount = packet.stars.count
        satelliteCount = packet.satellites.count
        starBuffer = Self.makeBuffer(device: device, values: combinedStars)
        // The planner's hit-proxy list starts with the NON-fading stars
        // (People-portrait context satellites are render-only), then the
        // satellites — so index-pairing pick entries against the raw
        // instance array desynchronizes as soon as any star carries the
        // context-fade flag. Align explicitly: one entry per proxy, nil
        // where the proxy has no star instance (person hubs, sun,
        // meaning clusters).
        //
        // Dying ghosts are the other alignment hazard: `combinePacket`
        // appends them to `stars`/`satellites` while filtering their
        // proxies out, so they must be excluded here too or every proxy
        // after the first ghost pairs one slot early (satellite proxies
        // inherit ghost-star radii and lanes for the 1–2s death window).
        // Ghosts are marked by `signal.deletion > 0` — combinePacket
        // floors in-flight deletion to 0.0001 so the marker is present
        // from the very first death frame.
        var pickAlignedStars: [MetalStarInstance?] = []
        pickAlignedStars.reserveCapacity(packet.hitProxies.count)
        for (index, star) in packet.stars.enumerated()
        where !star.fadesWithPeopleContext && star.signal.deletion == 0 {
            pickAlignedStars.append(stars[index])
        }
        for (index, satellite) in packet.satellites.enumerated()
        where satellite.signal.deletion == 0 {
            pickAlignedStars.append(satellites[index])
        }
        pickTargets = makePickTargets(
            alignedStars: pickAlignedStars,
            proxies: packet.hitProxies
        )

        let nebulae = packet.nebulae.map(Self.nebulaInstance)
        nebulaCount = nebulae.count
        nebulaBuffer = Self.makeBuffer(device: device, values: nebulae)

        let halos = Self.makeHaloInstances(
            stars: packet.stars,
            satellites: packet.satellites,
            nebulae: packet.nebulae,
            meaningClusterHubs: packet.meaningClusterHubs
        ) + Self.sunCoronaHalos(sun: packet.personSun)
        haloCount = halos.count
        haloBuffer = Self.makeBuffer(device: device, values: halos)

        let fiberVertices = packet.fibers.flatMap(Self.fiberVertices)
        fiberVertexCount = fiberVertices.count
        fiberBuffer = Self.makeBuffer(device: device, values: fiberVertices)

        if packet.renderHubsAsPlanets {
            if packet.personHubs.isEmpty {
                personGlyphTexture = nil
                personPlanetLowCount = 0
                personPlanetMediumCount = 0
                personPlanetHighCount = 0
                personPlanetLowBuffer = nil
                personPlanetMediumBuffer = nil
                personPlanetHighBuffer = nil
            } else {
                let tiers = Self.personPlanetLODTiers(hubs: packet.personHubs)
                let glyphAtlas = personGlyphAtlas(
                    hubs: packet.personHubs,
                    tiers: tiers
                )
                installPersonPlanetBuffers(hubs: packet.personHubs, tiers: tiers, atlas: glyphAtlas)
            }
            personPlanetCount = personPlanetLowCount + personPlanetMediumCount + personPlanetHighCount
            personHubSpriteCount = 0
            personHubSpriteBuffer = nil
        } else {
            personGlyphTexture = nil
            let personHubSprites = packet.personHubs.map(Self.personHubSpriteInstance)
            personHubSpriteCount = personHubSprites.count
            personHubSpriteBuffer = personHubSprites.isEmpty
                ? nil
                : Self.makeBuffer(device: device, values: personHubSprites)
            personPlanetCount = 0
            personPlanetLowCount = 0
            personPlanetMediumCount = 0
            personPlanetHighCount = 0
            personPlanetLowBuffer = nil
            personPlanetMediumBuffer = nil
            personPlanetHighBuffer = nil
        }
        let meaningClusterPlanets = packet.meaningClusterHubs.flatMap(Self.meaningClusterPlanetInstances)
        meaningClusterPlanetCount = meaningClusterPlanets.count
        meaningClusterPlanetBuffer = meaningClusterPlanets.isEmpty
            ? nil
            : Self.makeBuffer(device: device, values: meaningClusterPlanets)

        let metaball = Self.meaningClusterMetaballBuffers(hubs: packet.meaningClusterHubs)
        meaningClusterMetaballInstances = metaball.instances
        meaningClusterMetaballMemberBuffer = metaball.members.isEmpty
            ? nil
            : Self.makeBuffer(device: device, values: metaball.members)
        // Re-resolve the transient Meaning-cluster hover flare against the
        // fresh packet: a rebuild can drop the hovered cluster (lens change,
        // filter contraction, lock transition), and a stale nonzero lane
        // would leak into the People orbit-path highlight channel.
        if let clusterId = hoveredMeaningClusterId,
           packet.meaningClusterHubs.contains(where: { $0.clusterId == clusterId }) {
            hoveredMeaningClusterPhasePlusOne = Self.meaningClusterPhase(clusterId) + 1
        } else {
            hoveredMeaningClusterPhasePlusOne = 0
        }


        let personRings = packet.personRings.map { ring in
            Self.personRingInstance(ring, hubLane: hubDisplacementLane(forEmail: ring.email))
        }
        personRingCount = personRings.count
        personRingBuffer = personRings.isEmpty
            ? nil
            : Self.makeBuffer(device: device, values: personRings)

        let personAtoms = packet.personAtoms.map(Self.personAtomInstance)
        personAtomCount = personAtoms.count
        personAtomBuffer = personAtoms.isEmpty
            ? nil
            : Self.makeBuffer(device: device, values: personAtoms)

        lastPacketPreparationMilliseconds = (CACurrentMediaTime() - start) * 1_000
    }

    /// A packet drives shader-side signal pulses when any star or satellite
    /// lights a time-animated signal channel. Search scores and citations
    /// are bounded user-workspace sets, and `selected` marks the single
    /// locked node, so this predicate stays false for scenes at rest.
    nonisolated static func packetPulsesSignals(_ packet: ConstellationRenderPacket) -> Bool {
        let pulses: (VisualSignalState) -> Bool = { signal in
            signal.search > 0 || signal.citation > 0 || signal.selected > 0
        }
        return packet.stars.contains { pulses($0.signal) }
            || packet.satellites.contains { pulses($0.signal) }
    }

    // MARK: - People solar system

    /// Rebuild the per-packet solar caches: hub order-aligned orbits, base
    /// positions, index maps, the displacement table, the sun body, and
    /// the engraved orbit-path instances. Cleared for non-solar packets.
    private func rebuildPeopleSolarCaches(packet: ConstellationRenderPacket) {
        personSun = packet.personSun
        displacedOrbitalTime = .nan
        detailFadeCameraPosition = nil
        guard let sun = packet.personSun else {
            personHubOrbits = []
            personHubBasePositions = []
            personHubPlanetRadii = []
            personHubIndexByEmail = [:]
            personHubIndexByMessageId = [:]
            peopleStarPlacementLanes = [:]
            peopleDisplacementBuffers = []
            peopleDisplacementBufferIndex = 0
            peopleDisplacements = []
            personOrbitPathBuffer = nil
            personOrbitPathCount = 0
            personSunBuffer = nil
            hoveredOrbitPathEmail = nil
            hoveredOrbitPathHubIndexPlusOne = 0
            return
        }

        let hubs = packet.personHubs
        personHubOrbits = hubs.map(\.orbit)
        personHubBasePositions = hubs.map(\.position)
        personHubPlanetRadii = hubs.map { Self.personPlanetRadius($0) }
        var indexByEmail: [String: Int] = [:]
        indexByEmail.reserveCapacity(hubs.count)
        var indexByMessage: [String: Int] = [:]
        for (index, hub) in hubs.enumerated() {
            indexByEmail[hub.email] = index
            // Hubs arrive reciprocity-sorted, so the first hub claiming a
            // message is its primary placement — the same rule
            // `messagePositions` uses for the canonical row position.
            for messageId in hub.messageIds where indexByMessage[messageId] == nil {
                indexByMessage[messageId] = index
            }
        }
        personHubIndexByEmail = indexByEmail
        personHubIndexByMessageId = indexByMessage
        var placementLanes: [String: [(position: SIMD3<Float>, lane: Int)]] = [:]
        for star in packet.stars {
            guard let email = star.peopleHubEmail,
                  let index = indexByEmail[email],
                  personHubOrbits.indices.contains(index),
                  personHubOrbits[index] != nil else { continue }
            placementLanes[star.messageId, default: []].append((star.position, index + 1))
        }
        peopleStarPlacementLanes = placementLanes

        let table = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 1), count: hubs.count + 1)
        peopleDisplacements = table
        peopleDisplacementBufferIndex = 0
        peopleDisplacementBuffers = (0..<Self.displacementRingDepth).compactMap { _ in
            table.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: [.storageModeShared])
            }
        }

        personSunBuffer = makeSunBuffer(sun)
        let paths = Self.orbitPathInstances(
            hubs: hubs,
            sun: sun,
            pathColor: packet.personOrbitPathColor
        )
        personOrbitPathCount = paths.count
        personOrbitPathBuffer = paths.isEmpty ? nil : Self.makeBuffer(device: device, values: paths)
        // Re-resolve the transient orbit-path hover highlight against the
        // freshly built index. Hubs arrive reciprocity-sorted, so a rebuild
        // can move the hovered correspondent to a different lane (or drop it
        // from the scene); re-mapping by the retained email keeps the
        // highlight on the correct orbit instead of whatever hub now occupies
        // the stale lane.
        if let email = hoveredOrbitPathEmail, let index = personHubIndexByEmail[email] {
            hoveredOrbitPathHubIndexPlusOne = Float(index + 1)
        } else {
            hoveredOrbitPathHubIndexPlusOne = 0
        }
    }

    private func makeSunBuffer(_ sun: PersonSunInstance) -> MTLBuffer? {
        let instance = MetalPersonPlanetInstance(
            centerRadius: SIMD4<Float>(sun.position.x, sun.position.y, sun.position.z, sun.radius),
            color: SIMD4<Float>(sun.color.x, sun.color.y, sun.color.z, 1),
            glyphUV: SIMD4<Float>(0, 0, 0, 0),
            signal: SIMD4<Float>(0, 0, 0, 3),
            orbital: SIMD4<Float>(0, 0, 0, 0)
        )
        return Self.makeBuffer(device: device, values: [instance])
    }

    /// Displacement lane for a hub email: index + 1 into the displacement
    /// table, or 0 (the identity sentinel) when the email is absent or the
    /// packet isn't solar.
    private func hubDisplacementLane(forEmail email: String?) -> Float {
        guard let email, let index = personHubIndexByEmail[email] else { return 0 }
        // Pinned hubs (nil orbit) resolve to the sentinel so their pick
        // and satellite geometry can never displace off the pin.
        guard personHubOrbits.indices.contains(index), personHubOrbits[index] != nil else { return 0 }
        return Float(index + 1)
    }

    private func hubDisplacementLane(forProxy proxy: HitProxy) -> Float {
        if proxy.messageId == ConstellationMetalRenderer.personSunProxyMessageId {
            return 0
        }
        if proxy.messageId.hasPrefix("person:") {
            return hubDisplacementLane(forEmail: String(proxy.messageId.dropFirst("person:".count)))
        }
        guard let index = personHubIndexByMessageId[proxy.messageId],
              personHubOrbits.indices.contains(index),
              personHubOrbits[index] != nil else { return 0 }
        return Float(index + 1)
    }

    /// Synthetic hit-proxy messageId for the sun (hover readout + click →
    /// reframe). Canonical value lives on `PersonSunInstance`; aliased here
    /// for the renderer's own routing.
    public static let personSunProxyMessageId = PersonSunInstance.hitProxyMessageId

    /// Whether the current packet renders the People solar system.
    public var peopleSolarSystemActive: Bool { personSun != nil }

    /// Live (displaced) world position of a correspondent hub body.
    /// Identity for pinned/locked hubs and for zero-displacement scenes.
    public func peopleLiveHubPosition(email: String, basePosition: SIMD3<Float>) -> SIMD3<Float> {
        let lane = Int(hubDisplacementLane(forEmail: email))
        guard lane > 0, lane < peopleDisplacements.count else { return basePosition }
        let entry = peopleDisplacements[lane]
        return basePosition + SIMD3<Float>(entry.x, entry.y, entry.z)
    }

    /// Live (displaced) world position for a hit proxy in the People solar
    /// system — where the proxy's body is actually rendered right now.
    /// Zero-displacement scenes (packet epoch == current clock) return
    /// `proxy.worldPosition` unchanged. Message proxies resolve their OWN
    /// placement (matched by base position) so a multi-recipient message
    /// translates by the hub it was actually clicked on.
    public func peopleLiveWorldPosition(for proxy: HitProxy) -> SIMD3<Float> {
        peopleLiveWorldPosition(messageId: proxy.messageId, basePosition: proxy.worldPosition)
    }

    /// Live (displaced) world position for a People node addressed by its render
    /// id + base position — the `HitProxy` variant's guts, reusable by callers
    /// that only hold a message id and a base world (e.g. the send-to-Composer
    /// dispatch comet, which launches from where the satellite is actually drawn).
    public func peopleLiveWorldPosition(messageId: String, basePosition: SIMD3<Float>) -> SIMD3<Float> {
        guard personSun != nil else { return basePosition }
        var lane = 0
        if messageId == Self.personSunProxyMessageId {
            return basePosition
        } else if messageId.hasPrefix("person:") {
            lane = Int(hubDisplacementLane(forEmail: String(messageId.dropFirst("person:".count))))
        } else if let placements = peopleStarPlacementLanes[messageId] {
            var best: (distanceSquared: Float, lane: Int)?
            for placement in placements {
                let distanceSquared = simd_length_squared(placement.position - basePosition)
                if best == nil || distanceSquared < best!.distanceSquared {
                    best = (distanceSquared, placement.lane)
                }
            }
            if let best, best.distanceSquared < 1e-6 {
                lane = best.lane
            }
        }
        guard lane > 0, lane < peopleDisplacements.count else { return basePosition }
        let entry = peopleDisplacements[lane]
        return basePosition + SIMD3<Float>(entry.x, entry.y, entry.z)
    }

    /// Transient Meaning-cluster hover flare (brightens that cluster's
    /// nucleus, spike halo, and gas body while easing siblings back).
    /// Pass nil to clear.
    public func setHoveredMeaningCluster(clusterId: Int64?) {
        hoveredMeaningClusterId = clusterId
        guard let clusterId else {
            hoveredMeaningClusterPhasePlusOne = 0
            return
        }
        hoveredMeaningClusterPhasePlusOne = Self.meaningClusterPhase(clusterId) + 1
    }

    /// Transient orbit-path hover highlight (brightens that hub's engraved
    /// path). Pass nil to clear.
    public func setHoveredOrbitPathHub(email: String?) {
        hoveredOrbitPathEmail = email
        guard let email, let index = personHubIndexByEmail[email] else {
            hoveredOrbitPathHubIndexPlusOne = 0
            return
        }
        hoveredOrbitPathHubIndexPlusOne = Float(index + 1)
    }

    /// Advance the displacement + detail-fade table to the given orbital
    /// clock and camera. Cheap (a few hundred Kepler solves) and skipped
    /// entirely when neither the clock nor the camera moved.
    private func refreshPeopleDisplacements(
        orbitalTime: TimeInterval,
        camera: CameraState,
        viewportHeight: Float
    ) {
        guard let sun = personSun,
              !peopleDisplacementBuffers.isEmpty,
              !personHubOrbits.isEmpty else { return }
        let cameraMoved: Bool
        if let last = detailFadeCameraPosition {
            cameraMoved = simd_length_squared(last - camera.position) > 1e-8
                || abs(detailFadeViewportHeight - viewportHeight) > 0.5
        } else {
            cameraMoved = true
        }
        let timeMoved = displacedOrbitalTime.isNaN || abs(orbitalTime - displacedOrbitalTime) > 1e-9
        guard timeMoved || cameraMoved else { return }

        let basis = sun.eclipticBasis
        let epoch = sun.orbitalEpoch
        var table = peopleDisplacements
        if table.count != personHubOrbits.count + 1 {
            table = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 1), count: personHubOrbits.count + 1)
        }
        table[0] = SIMD4<Float>(0, 0, 0, 1)
        for index in personHubOrbits.indices {
            var displacement = SIMD3<Float>.zero
            if let orbit = personHubOrbits[index], abs(orbitalTime - epoch) > 1e-9 {
                let livePosition = PersonOrbitMath.position(
                    orbit: orbit,
                    at: orbitalTime,
                    sunPosition: sun.position,
                    basis: basis
                )
                displacement = livePosition - personHubBasePositions[index]
            }
            let fade = Self.peopleDetailFade(
                planetRadius: personHubPlanetRadii[index],
                worldPosition: personHubBasePositions[index] + displacement,
                cameraPosition: camera.position,
                viewportHeight: viewportHeight
            )
            table[index + 1] = SIMD4<Float>(displacement.x, displacement.y, displacement.z, fade)
        }
        peopleDisplacements = table
        // Rotate to a fresh ring slot before writing, so this frame never
        // overwrites the buffer a still-in-flight prior frame is reading.
        // `min(..., buffer.length)` is defensive: the table is sized to the
        // buffers in `rebuildPeopleSolarCaches`, but if `personHubOrbits`
        // were ever to change without a rebuild the copy stays in bounds.
        peopleDisplacementBufferIndex =
            (peopleDisplacementBufferIndex + 1) % peopleDisplacementBuffers.count
        let buffer = peopleDisplacementBuffers[peopleDisplacementBufferIndex]
        table.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(
                from: bytes.baseAddress!,
                byteCount: min(bytes.count, buffer.length)
            )
        }
        // No pick invalidation needed here: the CPU `hitTest` reads
        // `peopleDisplacements` live, so moving bodies are always tested
        // against their current displaced positions.
        displacedOrbitalTime = orbitalTime
        detailFadeCameraPosition = camera.position
        detailFadeViewportHeight = viewportHeight
    }

    /// Ring + satellite detail fade by the planet's apparent size: below
    /// ~8 px of projected planet radius the Saturn detail is sub-pixel
    /// noise and fades out; by ~24 px it is fully resolved. The planets
    /// themselves never fade — the orbs and their engraved paths carry
    /// the wide view.
    nonisolated private static func peopleDetailFade(
        planetRadius: Float,
        worldPosition: SIMD3<Float>,
        cameraPosition: SIMD3<Float>,
        viewportHeight: Float
    ) -> Float {
        let distance = max(0.01, simd_length(worldPosition - cameraPosition))
        // tan(FOV/2) for the shared π/3 vertical FOV.
        let tanHalfFOV: Float = 0.57735026
        let apparentPixels = planetRadius / (distance * tanHalfFOV) * (viewportHeight * 0.5)
        let t = max(0, min(1, (apparentPixels - 8) / 16))
        return t * t * (3 - 2 * t)
    }

    /// Corona halos for the sun — two soft additive layers routed through
    /// the halo pass's mist branch (`lock.z = 1`), so the sun reads as a
    /// radiant body with slow internal currents rather than a hard disc.
    nonisolated private static func sunCoronaHalos(sun: PersonSunInstance?) -> [MetalHaloInstance] {
        guard let sun else { return [] }
        let position = sun.position
        func halo(radiusScale: Float, intensity: Float, density: Float, phase: Float) -> MetalHaloInstance {
            MetalHaloInstance(
                positionRadius: SIMD4<Float>(position.x, position.y, position.z, sun.radius * radiusScale),
                colorIntensity: SIMD4<Float>(sun.color.x, sun.color.y, sun.color.z, intensity),
                meta: SIMD4<Float>(1, density, phase, 0),
                lock: SIMD4<Float>(0, 0, 1, 0)
            )
        }
        return [
            halo(radiusScale: 7.0, intensity: 0.085, density: 0.35, phase: 0.8),
            halo(radiusScale: 3.2, intensity: 0.165, density: 0.62, phase: 3.9)
        ]
    }

    /// Engraved orbit paths for every orbit-carrying hub + the concentric
    /// recency band guides. Paths are time-invariant (the ellipse doesn't
    /// move; the body does), so these instances survive the whole packet.
    nonisolated private static func orbitPathInstances(
        hubs: [PersonHubInstance],
        sun: PersonSunInstance,
        pathColor: SIMD3<Float>
    ) -> [MetalPersonOrbitPathInstance] {
        var instances: [MetalPersonOrbitPathInstance] = []
        instances.reserveCapacity(hubs.count + PersonOrbitMath.bandGuideRadii.count)
        let basis = sun.eclipticBasis

        // Recency band guides — the chart's faint concentric grid.
        for radius in PersonOrbitMath.bandGuideRadii {
            instances.append(MetalPersonOrbitPathInstance(
                centerPeri: SIMD4<Float>(sun.position.x, sun.position.y, sun.position.z, radius),
                axisPE: SIMD4<Float>(basis.axisU.x, basis.axisU.y, basis.axisU.z, 0),
                axisQH: SIMD4<Float>(basis.axisV.x, basis.axisV.y, basis.axisV.z, 0),
                colorAlpha: SIMD4<Float>(pathColor.x, pathColor.y, pathColor.z, 0.045),
                style: SIMD4<Float>(1, 0, 0, 0)
            ))
        }

        for (index, hub) in hubs.enumerated() {
            guard let orbit = hub.orbit else { continue }
            let omega = orbit.argumentOfPerihelion
            let pAxis = basis.axisU * cos(omega) + basis.axisV * sin(omega)
            let qFlat = basis.axisU * -sin(omega) + basis.axisV * cos(omega)
            let qAxis = qFlat * cos(orbit.inclination) + basis.normal * sin(orbit.inclination)
            let baseAlpha: Float = orbit.isComet ? 0.060 : 0.075
            instances.append(MetalPersonOrbitPathInstance(
                centerPeri: SIMD4<Float>(sun.position.x, sun.position.y, sun.position.z, orbit.perihelion),
                axisPE: SIMD4<Float>(pAxis.x, pAxis.y, pAxis.z, orbit.eccentricity),
                axisQH: SIMD4<Float>(qAxis.x, qAxis.y, qAxis.z, Float(index + 1)),
                colorAlpha: SIMD4<Float>(pathColor.x, pathColor.y, pathColor.z, baseAlpha),
                style: SIMD4<Float>(orbit.isComet ? 2 : 0, hub.focusGlow > 0.5 ? 1 : 0, 0, 0)
            ))
        }
        return instances
    }

    public func draw(
        in view: MTKView,
        camera: CameraState,
        sourceWarp: ConstellationSourceWarp? = nil,
        peopleOrbitalTime: TimeInterval? = nil,
        showsPeopleOrbitPaths: Bool = true,
        drawMeaningClusterMetaballBodies: Bool = true
    ) {
        let start = CACurrentMediaTime()
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let size = view.drawableSize
        // Advance the People solar system's displacement table to the
        // motion controller's orbital clock (frozen clock ⇒ zero
        // displacement everywhere ⇒ settled geometry). Also re-evaluates
        // the per-hub Saturn-detail fades against the current camera.
        let effectiveOrbitalTime = peopleOrbitalTime ?? personSun?.orbitalEpoch ?? 0
        refreshPeopleDisplacements(
            orbitalTime: effectiveOrbitalTime,
            camera: camera,
            viewportHeight: Float(size.height)
        )
        var uniforms = cameraUniforms(
            size: size,
            camera: camera,
            sourceWarp: sourceWarp,
            pulseRestDamp: tickPulseRestDamp(now: CACurrentMediaTime())
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        // Default depth state — always pass, no write — so the pre-planet
        // sprite layers continue to draw strictly in submission order. The
        // planet pass swaps to a write-enabled state, and the subsequent
        // ring / star / atom layers swap to a test-only state so they get
        // occluded by the planet silhouettes the planet pass wrote.
        encoder.setDepthStencilState(passThroughDepthState)

        // The fullscreen background quad is opaque (`float4(base, 1.0)`), so it
        // would paint over any SwiftUI view sitting behind a transparent Metal
        // view. Skip it when the view requests a transparent backdrop (the
        // People / Meanings `NightSkyView`) — the transparent clear already
        // fills the empty space and the night sky behind shows through; the
        // additive halo / nebula / fibre passes still composite over a
        // near-identical dark base. Every other lens keeps the opaque quad.
        let drawsOpaqueBackground = (view as? InputMetalView)?.rendersTransparentBackground != true
        if drawsOpaqueBackground {
            encoder.setRenderPipelineState(backgroundPipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        if let haloBuffer, haloCount > 0 {
            encoder.setRenderPipelineState(haloPipeline)
            encoder.setVertexBuffer(haloBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: haloCount)
        }

        if let fiberBuffer, fiberVertexCount > 0 {
            encoder.setRenderPipelineState(fiberPipeline)
            encoder.setVertexBuffer(fiberBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fiberVertexCount)
        }

        if let nebulaBuffer, nebulaCount > 0 {
            encoder.setRenderPipelineState(nebulaPipeline)
            encoder.setVertexBuffer(nebulaBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: nebulaCount)
        }

        // Hub planet pass — 3D icospheres for correspondent hubs in People,
        // plus the solar system's sun body. Drawn BEFORE rings / paths /
        // stars / atoms so the bodies write their silhouettes into depth;
        // everything that follows tests against that depth and is hidden
        // where a body covers it.
        if personPlanetCount > 0 || personSunBuffer != nil {
            encoder.setRenderPipelineState(personPlanetPipeline)
            encoder.setDepthStencilState(planetDepthState)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.setVertexBuffer(currentPeopleDisplacementBuffer ?? zeroDisplacementBuffer, offset: 0, index: 3)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.setFragmentTexture(personGlyphTexture ?? transparentPersonGlyphTexture, index: 0)
            encoder.setFragmentSamplerState(personGlyphSampler, index: 0)
            drawPersonPlanetBucket(
                encoder: encoder,
                mesh: planetSphereLowMesh,
                buffer: personPlanetLowBuffer,
                count: personPlanetLowCount
            )
            drawPersonPlanetBucket(
                encoder: encoder,
                mesh: planetSphereMediumMesh,
                buffer: personPlanetMediumBuffer,
                count: personPlanetMediumCount
            )
            drawPersonPlanetBucket(
                encoder: encoder,
                mesh: planetSphereHighMesh,
                buffer: personPlanetHighBuffer,
                count: personPlanetHighCount
            )
            if let personSunBuffer {
                // The sun always takes the high mesh — it is the single
                // largest body on screen and its silhouette must stay round.
                encoder.setVertexBuffer(planetSphereHighMesh.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(personSunBuffer, offset: 0, index: 2)
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: planetSphereHighMesh.indexCount,
                    indexType: .uint16,
                    indexBuffer: planetSphereHighMesh.indexBuffer,
                    indexBufferOffset: 0,
                    instanceCount: 1
                )
            }
            // From here through the end of the People-lens drawing every
            // translucent layer should be occluded by the planet bodies it
            // sits behind. Switch to a test-only state — write nothing so
            // the layers don't occlude each other, just the planets do.
            encoder.setDepthStencilState(occludedSpriteDepthState)
        }

        // Engraved orbit paths + recency band guides — the chart layer of
        // the People solar system. Drawn after the bodies (depth-tested, so
        // paths vanish behind planets and the sun) and before the rings.
        // Under heavy budget pressure the whisper engraving is the first
        // People layer to go.
        if let personOrbitPathBuffer,
           ConstellationMetalRedrawPolicy.drawsPeopleOrbitPaths(
               showsOrbitPaths: showsPeopleOrbitPaths,
               pathCount: personOrbitPathCount,
               degradationTier: budget.degradationTier
           ) {
            encoder.setRenderPipelineState(personOrbitPathPipeline)
            encoder.setDepthStencilState(occludedSpriteDepthState)
            encoder.setVertexBuffer(personOrbitPathBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.drawPrimitives(
                type: .lineStrip,
                vertexStart: 0,
                vertexCount: Self.orbitPathVertexCount,
                instanceCount: personOrbitPathCount
            )
        }

        // Person ring pass — Saturn-style ring bands per correspondent hub.
        // Drawn AFTER the planet pass so rings going behind the planet body
        // are hidden by the depth test, and rings in front draw on top.
        // Empty in every non-People lens.
        if let personRingBuffer, personRingCount > 0 {
            encoder.setRenderPipelineState(personRingPipeline)
            encoder.setVertexBuffer(personRingBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(currentPeopleDisplacementBuffer ?? zeroDisplacementBuffer, offset: 0, index: 2)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: personRingCount)
        }

        // Meaning-lens metaball body. One instance per cluster; the fragment
        // shader raymarches the bounding sphere accumulating blob
        // contributions from the shared member buffer. Drawn before the
        // centroid core dot so the hover anchor sits on top of the body.
        // Cull back faces so each pixel evaluates the metaball SDF exactly
        // once (default no-culling double-blends and brightens the body).
        //
        // Per frame, `MeaningMetaballFramePolicy.drawList` skips bodies
        // whose projected bounding sphere is sub-pixel, stamps each
        // survivor's tier/size-scaled raymarch step count into
        // `memberRange.w`, and orders them back-to-front so overlapping
        // translucent bodies blend stably. Under `aggregateHeavy` budget
        // pressure the whole pass is skipped, mirroring the orbit-path
        // engraving gate above. Survivors upload via `setVertexBytes`
        // (≤32 instances × 48 B — far under the 4 KB inline limit).
        if drawMeaningClusterMetaballBodies,
           uniforms.lockControls.y > 0.001,
           budget.degradationTier < .aggregateHeavy,
           let metaballMemberBuffer = meaningClusterMetaballMemberBuffer,
           !meaningClusterMetaballInstances.isEmpty {
            let metaballDrawList = MeaningMetaballFramePolicy.drawList(
                instances: meaningClusterMetaballInstances,
                viewProjection: uniforms.viewProjection,
                cameraPosition: camera.position,
                drawableHeight: Float(size.height),
                tier: budget.degradationTier
            )
            if !metaballDrawList.isEmpty {
                encoder.setRenderPipelineState(meaningClusterMetaballPipeline)
                encoder.setDepthStencilState(passThroughDepthState)
                encoder.setCullMode(.back)
                encoder.setVertexBuffer(planetSphereLowMesh.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
                metaballDrawList.withUnsafeBufferPointer { pointer in
                    let byteLength = MemoryLayout<MetalMeaningMetaballInstance>.stride * pointer.count
                    // `setVertexBytes` caps at 4 KB of inline constant data. The
                    // draw list is bounded to `meaningClusterHubMaxCount` (32) in
                    // ConstellationRenderPlanner, which at 48 B/instance is 1.5 KB.
                    // If that cap is ever raised past ~85, this pass must move to a
                    // persistent MTLBuffer; fail loudly here rather than letting
                    // Metal silently drop the write.
                    precondition(
                        byteLength <= 4096,
                        "meaning metaball instance upload (\(byteLength) B) exceeds the 4 KB setVertexBytes limit — raise came from meaningClusterHubMaxCount; switch this pass to an MTLBuffer"
                    )
                    encoder.setVertexBytes(
                        pointer.baseAddress!,
                        length: byteLength,
                        index: 2
                    )
                }
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
                encoder.setFragmentBuffer(metaballMemberBuffer, offset: 0, index: 2)
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: planetSphereLowMesh.indexCount,
                    indexType: .uint16,
                    indexBuffer: planetSphereLowMesh.indexBuffer,
                    indexBufferOffset: 0,
                    instanceCount: metaballDrawList.count
                )
                // Restore the encoder's default cull mode for following passes.
                encoder.setCullMode(.none)
            }
        }

        // Meaning-cluster centroid hover anchor — small bright dot at the
        // cluster's centre, drawn after the metaball body so it sits on
        // top of (and inside) the soft volumetric body. The cluster's
        // field branch in the shader is now dormant; only the core
        // material draws here.
        if let meaningClusterPlanetBuffer, meaningClusterPlanetCount > 0 {
            encoder.setRenderPipelineState(meaningClusterPlanetPipeline)
            encoder.setDepthStencilState(passThroughDepthState)
            encoder.setVertexBuffer(planetSphereLowMesh.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.setVertexBuffer(meaningClusterPlanetBuffer, offset: 0, index: 2)
            // Shares the person-planet vertex shader, which now reads the
            // displacement table; meaning clusters ride the identity lane.
            encoder.setVertexBuffer(zeroDisplacementBuffer, offset: 0, index: 3)
            encoder.setFragmentTexture(transparentPersonGlyphTexture, index: 0)
            encoder.setFragmentSamplerState(personGlyphSampler, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: planetSphereLowMesh.indexCount,
                indexType: .uint16,
                indexBuffer: planetSphereLowMesh.indexBuffer,
                indexBufferOffset: 0,
                instanceCount: meaningClusterPlanetCount
            )
        }

        let combinedStarCount = starCount + satelliteCount
        if let starBuffer, combinedStarCount > 0 {
            encoder.setRenderPipelineState(starPipeline)
            encoder.setVertexBuffer(starBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(currentPeopleDisplacementBuffer ?? zeroDisplacementBuffer, offset: 0, index: 2)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: combinedStarCount)
        }

        // Sprite-hub fallback — only populated when the packet sets
        // `renderHubsAsPlanets = false` (today: the locked-overlay Focus
        // scene). Mutually exclusive with the planet pass above. Runs
        // after stars so the hub sprite sits on top of its message moons
        // in the Focus scene, matching the pre-3D draw order.
        if let personHubSpriteBuffer, personHubSpriteCount > 0 {
            encoder.setRenderPipelineState(starPipeline)
            encoder.setVertexBuffer(personHubSpriteBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(currentPeopleDisplacementBuffer ?? zeroDisplacementBuffer, offset: 0, index: 2)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: personHubSpriteCount)
        }

        // Atom satellites — multi-recipient cue dots. Re-uses the star
        // pipeline so the dots render with the same gaussian falloff as the
        // primary stars; lives in its own buffer so the pick buffer doesn't
        // see them (atoms are cosmetic, not clickable).
        if let personAtomBuffer, personAtomCount > 0 {
            encoder.setRenderPipelineState(starPipeline)
            encoder.setVertexBuffer(personAtomBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(currentPeopleDisplacementBuffer ?? zeroDisplacementBuffer, offset: 0, index: 2)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalCameraUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: personAtomCount)
        }

        encoder.endEncoding()
        let timingStore = frameTimingStore
        commandBuffer.addCompletedHandler { completedBuffer in
            timingStore.record(
                startTime: completedBuffer.gpuStartTime,
                endTime: completedBuffer.gpuEndTime
            )
        }
#if DEBUG
        if let sample = timingStore.presentationSample() {
            drawable.addPresentedHandler { presentedDrawable in
                timingStore.recordPresentation(
                    time: presentedDrawable.presentedTime,
                    epoch: sample.epoch,
                    sequence: sample.sequence,
                    framesPerSecond: sample.framesPerSecond
                )
            }
        }
#endif
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastCPUEncodingMilliseconds = (CACurrentMediaTime() - start) * 1_000
    }

    private func drawPersonPlanetBucket(
        encoder: MTLRenderCommandEncoder,
        mesh: PlanetSphereMesh,
        buffer: MTLBuffer?,
        count: Int
    ) {
        guard let buffer, count > 0 else { return }
        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(buffer, offset: 0, index: 2)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: mesh.indexCount,
            indexType: .uint16,
            indexBuffer: mesh.indexBuffer,
            indexBufferOffset: 0,
            instanceCount: count
        )
    }

    public func hitTest(
        at point: CGPoint,
        viewSize: CGSize,
        drawableSize: CGSize,
        camera: CameraState,
        onlyMeaningClusters: Bool = false
    ) -> HitProxy? {
        guard viewSize.width > 0, viewSize.height > 0,
              drawableSize.width >= 1, drawableSize.height >= 1,
              point.x >= 0,
              point.y >= 0,
              point.x < viewSize.width,
              point.y < viewSize.height,
              pickTargets.isEmpty == false else {
            return nil
        }
        // Same projection inputs the render pass uses — `viewProjection`
        // built from this camera at the drawable's aspect, and the fixed
        // 900 px-per-world-unit scale carried in `viewportTimeScale.w` —
        // so the CPU circles land exactly on the rendered bodies.
        let uniforms = cameraUniforms(
            size: drawableSize,
            camera: camera,
            pulseRestDamp: pulseRestDamp
        )
        let index: Int?
        if onlyMeaningClusters {
            index = Self.resolveMeaningClusterPick(
                point: point,
                viewSize: viewSize,
                drawableSize: drawableSize,
                viewProjection: uniforms.viewProjection,
                pixelsPerWorldUnit: uniforms.viewportTimeScale.w,
                targets: pickTargets
            )
        } else {
            index = Self.resolvePick(
                point: point,
                viewSize: viewSize,
                drawableSize: drawableSize,
                viewProjection: uniforms.viewProjection,
                pixelsPerWorldUnit: uniforms.viewportTimeScale.w,
                targets: pickTargets,
                displacements: peopleDisplacements
            )
        }
        guard let index, index < hitProxies.count else {
            return nil
        }
        return hitProxies[index]
    }

    /// Option-held cluster picking: every non-cluster target is ignored and
    /// the Meaning-cluster nucleus nearest the cursor on screen wins. The
    /// reach floor is generous — the gesture's intent is explicit (the user
    /// is pointing at a cluster body, not threading a nucleus-sized needle
    /// past the message nodes layered through it), so proximity, not the
    /// nucleus footprint, decides.
    nonisolated static let meaningClusterOptionPickReachPixels: Float = 220

    nonisolated static func resolveMeaningClusterPick(
        point: CGPoint,
        viewSize: CGSize,
        drawableSize: CGSize,
        viewProjection: simd_float4x4,
        pixelsPerWorldUnit: Float,
        targets: [ConstellationPickTarget]
    ) -> Int? {
        guard viewSize.width > 0, viewSize.height > 0,
              drawableSize.width >= 1, drawableSize.height >= 1,
              targets.isEmpty == false else {
            return nil
        }
        let scaleX = drawableSize.width / viewSize.width
        let scaleY = drawableSize.height / viewSize.height
        let cursor = SIMD2<Float>(
            Float((point.x * scaleX).rounded(.down)) + 0.5,
            Float((point.y * scaleY).rounded(.down)) + 0.5
        )
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)

        var best: (distance: Float, index: Int)?
        for (index, target) in targets.enumerated() where target.isMeaningCluster {
            let world = target.worldPosition
            let clip = viewProjection * SIMD4<Float>(world.x, world.y, world.z, 1)
            guard clip.w > 0, clip.z >= 0, clip.z <= clip.w else { continue }
            let center = SIMD2<Float>(
                (clip.x / clip.w + 1) * 0.5 * width,
                (1 - clip.y / clip.w) * 0.5 * height
            )
            let visualPixelRadius = max(target.worldRadius, 0.001) * pixelsPerWorldUnit
            let reach = max(
                max(target.minPixelRadius, visualPixelRadius),
                meaningClusterOptionPickReachPixels
            )
            let distance = simd_length(cursor - center)
            guard distance <= reach else { continue }
            if best == nil || distance < best!.distance {
                best = (distance, index)
            }
        }
        return best?.index
    }

    /// Pure CPU replacement for the retired GPU picking pass. Reproduces the
    /// pick vertex/fragment shader semantics term for term:
    ///   - each target projects through the same view-projection matrix,
    ///     displaced by its People hub lane;
    ///   - its screen radius is `max(minPixelRadius, worldRadius · scale ·
    ///     (1 + signalBoost · 0.55), 1)` in drawable pixels — identical to
    ///     the shader's `max(pick.y, visualPixelRadius, 1.0)`;
    ///   - ring satellites collapse while their hub's Saturn-detail fade is
    ///     below 0.12 (planet bodies never do);
    ///   - targets outside the depth range clip away exactly like the
    ///     shared-z pick quad did (`w ≤ 0` or `z` outside `[0, w]`);
    ///   - among overlapping hits the nearest projected depth wins, first
    ///     target on ties — matching the pick pass's `.less` depth test
    ///     with write over submission order.
    /// The reference point is the center of the drawable texel under the
    /// cursor, mirroring the old single-texel readback.
    nonisolated static func resolvePick(
        point: CGPoint,
        viewSize: CGSize,
        drawableSize: CGSize,
        viewProjection: simd_float4x4,
        pixelsPerWorldUnit: Float,
        targets: [ConstellationPickTarget],
        displacements: [SIMD4<Float>]
    ) -> Int? {
        guard viewSize.width > 0, viewSize.height > 0,
              drawableSize.width >= 1, drawableSize.height >= 1,
              targets.isEmpty == false else {
            return nil
        }
        let scaleX = drawableSize.width / viewSize.width
        let scaleY = drawableSize.height / viewSize.height
        let cursor = SIMD2<Float>(
            Float((point.x * scaleX).rounded(.down)) + 0.5,
            Float((point.y * scaleY).rounded(.down)) + 0.5
        )
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        let meaningClusterLayerPresent = targets.contains(where: \.isMeaningCluster)

        var bestForeground: (ndcZ: Float, index: Int)?
        var bestMeaningCluster: (ndcZ: Float, index: Int)?
        for (index, target) in targets.enumerated() {
            var world = target.worldPosition
            var detailFade: Float = 1
            if target.lane > 0, target.lane < displacements.count {
                let entry = displacements[target.lane]
                world += SIMD3<Float>(entry.x, entry.y, entry.z)
                detailFade = entry.w
            }
            if target.collapsesWithDetailFade, target.lane > 0, detailFade < 0.12 {
                continue
            }
            let clip = viewProjection * SIMD4<Float>(world.x, world.y, world.z, 1)
            guard clip.w > 0, clip.z >= 0, clip.z <= clip.w else { continue }
            let center = SIMD2<Float>(
                (clip.x / clip.w + 1) * 0.5 * width,
                (1 - clip.y / clip.w) * 0.5 * height
            )
            let visualPixelRadius = max(target.worldRadius, 0.001)
                * pixelsPerWorldUnit
                * (1 + target.signalBoost * 0.55)
            // Meaning clouds own their complete visible area. A concrete
            // message intercepts that cloud only where its rendered body is
            // actually under the pointer; the normal padded proxy would make
            // dense groups nearly impossible to hover as clusters.
            let interactionFloor = meaningClusterLayerPresent && !target.isMeaningCluster
                ? Float(0)
                : target.minPixelRadius
            let pixelRadius = max(max(interactionFloor, visualPixelRadius), 1)
            guard simd_length(cursor - center) <= pixelRadius else { continue }
            let ndcZ = clip.z / clip.w
            if target.isMeaningCluster {
                if bestMeaningCluster == nil || ndcZ < bestMeaningCluster!.ndcZ {
                    bestMeaningCluster = (ndcZ, index)
                }
            } else if bestForeground == nil || ndcZ < bestForeground!.ndcZ {
                bestForeground = (ndcZ, index)
            }
        }
        // Message dots and other concrete bodies remain directly clickable
        // when drawn through a Meaning cloud. The cloud envelope catches the
        // remaining visible gas instead of stealing those foreground hits.
        return bestForeground?.index ?? bestMeaningCluster?.index
    }

    public func frameStats() -> ConstellationMetalFrameStats {
        ConstellationMetalFrameStats(
            packetGeneratedAt: packetGeneratedAt,
            starCount: starCount,
            satelliteCount: satelliteCount,
            nebulaCount: nebulaCount,
            fiberCount: fiberVertexCount / 6,
            hitProxyCount: hitProxies.count,
            packetPreparationMilliseconds: lastPacketPreparationMilliseconds,
            cpuEncodingMilliseconds: lastCPUEncodingMilliseconds,
            gpuFrameMilliseconds: frameTimingStore.latest(),
            degradationTier: budget.degradationTier
        )
    }

#if DEBUG
    func setPresentationSamplingActive(_ active: Bool, framesPerSecond: Int) {
        frameTimingStore.setPresentationSampling(active: active, framesPerSecond: framesPerSecond)
    }
#endif

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String,
        blendMode: BlendMode
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Every pipeline shares the main render pass, which now carries a
        // depth attachment so the 3D person-hub planets can z-test against
        // the rings (and so the rings can be occluded by the planet body
        // on the near side). Pipelines that don't want to participate in
        // depth simply leave the depth-stencil state at "always pass, no
        // write" at draw time.
        descriptor.depthAttachmentPixelFormat = .depth32Float
        if blendMode != .opaque {
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            switch blendMode {
            case .opaque:
                break
            case .alpha:
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .additive:
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makePersonGlyphSampler(device: MTLDevice) -> MTLSamplerState {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        // The atlas carries a real mip chain (see `PersonGlyphAtlasBuilder`)
        // built specifically because an SDF stays smooth under box-filter
        // downsampling, unlike the raw alpha mask this replaced — trilinear
        // filtering is what makes distant/minified orbs stop aliasing.
        descriptor.mipFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            preconditionFailure("Constellation Metal person-glyph sampler creation failed.")
        }
        return sampler
    }

    private static func makeTransparentGlyphTexture(device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            preconditionFailure("Constellation Metal transparent glyph texture creation failed.")
        }
        var pixel: UInt32 = 0
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: 4
        )
        return texture
    }

    private static func makeBuffer<T>(device: MTLDevice, values: [T]) -> MTLBuffer? {
        guard values.isEmpty == false else { return nil }
        return values.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: [.storageModeShared])
        }
    }

    private static func makeIcosphereMesh(device: MTLDevice, subdivisions: Int) -> PlanetSphereMesh {
        let sphere = Self.makeIcosphere(subdivisions: subdivisions)
        guard let vertexBuffer = makeBuffer(device: device, values: sphere.positions),
              let indexBuffer = makeBuffer(device: device, values: sphere.indices) else {
            preconditionFailure("Constellation Metal icosphere buffer creation failed.")
        }
        return PlanetSphereMesh(
            vertexBuffer: vertexBuffer,
            indexBuffer: indexBuffer,
            indexCount: sphere.indices.count
        )
    }

    /// Stable cache key for a resolved label — same text at the same bake
    /// resolution always produces the same SDF bytes, so this is all
    /// the preparation worker needs to dedupe the expensive
    /// distance-transform step across hubs and across packet updates.
    /// `PersonOrbLabelKind` isn't `Hashable` (only `Equatable`, for its
    /// existing test coverage), so this is a deliberately narrow string
    /// projection rather than adding dictionary-key conformance to a
    /// public rendering type.
    nonisolated private static func glyphCacheKey(for kind: PersonOrbLabelKind, tileSize: Int) -> String {
        switch kind {
        case .name(let text): return "\(tileSize)n:\(text)"
        case .initials(let text): return "\(tileSize)i:\(text)"
        case .icon: return "\(tileSize)icon"
        }
    }

    /// Content signature for a composited atlas: hub count, labeled tile
    /// positions, and per-tile label cache keys. Cache keys embed raw
    /// display-name text, so each key segment is length-prefixed — a plain
    /// join would let a label containing the separator shift segment
    /// boundaries and collide two different label sequences into one
    /// signature, serving the wrong atlas.
    nonisolated static func personGlyphAtlasSignature(
        hubCount: Int,
        labeledIndices: [Int],
        cacheKeys: [String]
    ) -> String {
        var signature = "\(hubCount)"
        for index in labeledIndices {
            signature += ",\(index)"
        }
        for key in cacheKeys {
            signature += "|\(key.utf8.count):"
            signature += key
        }
        return signature
    }

    private func cancelGlyphAtlasPreparation() {
        glyphAtlasRequestGeneration &+= 1
        glyphAtlasPreparationTask?.cancel()
        glyphAtlasPreparationTask = nil
        glyphAtlasRequestedSignature = nil
        glyphAtlasHubs = []
        glyphAtlasTiers = []
    }

    private func personGlyphAtlas(
        hubs: [PersonHubInstance],
        tiers: [PersonPlanetLOD]
    ) -> PersonGlyphAtlas {
        let labeledIndices = hubs.indices.filter { tiers[$0] != .low }
        let signature = Self.personGlyphAtlasSignature(
            hubCount: hubs.count,
            labeledIndices: labeledIndices,
            cacheKeys: labeledIndices.map { hubs[$0].displayName }
        )
        glyphAtlasHubs = hubs
        glyphAtlasTiers = tiers
        if glyphAtlasRequestedSignature != signature {
            glyphAtlasRequestGeneration &+= 1
            glyphAtlasPreparationTask?.cancel()
            glyphAtlasPreparationTask = nil
            glyphAtlasRequestedSignature = signature
        }
        if let hit = personGlyphAtlasCache[signature] {
            personGlyphAtlasStamp &+= 1
            personGlyphAtlasCache[signature] = (hit.atlas, personGlyphAtlasStamp)
            return hit.atlas
        }
        guard !labeledIndices.isEmpty else { return .empty(hubCount: hubs.count) }
        if glyphAtlasPreparationTask == nil {
            let generation = glyphAtlasRequestGeneration
            let builder = glyphAtlasBuilder
            let device = device
            glyphAtlasPreparationTask = Task(priority: .utility) { [weak self] in
                do {
                    // Do not measure/rasterize even the first label inside a
                    // synchronous packet install. MainActor keeps AppKit's
                    // thread-local graphics context; at most one label runs
                    // between suspensions, leaving room for input/layout.
                    let cachedTiles = await builder.cachedTiles()
                    var tiles: [PersonGlyphTile] = []
                    var wideDecalFlags = Array(repeating: false, count: hubs.count)
                    let tileSize = Int(PersonOrbLabel.productionTilePixels)
                    for hubIndex in labeledIndices {
                        try await Task.sleep(for: .milliseconds(1))
                        try Task.checkCancellation()
                        guard let kind = self?.resolvedGlyphKind(for: hubs[hubIndex].displayName) else { return }
                        let key = Self.glyphCacheKey(for: kind, tileSize: tileSize)
                        let source: PersonGlyphTile.Source
                        if let tile = cachedTiles[key] {
                            source = .distanceField(tile)
                        } else {
                            let mask = PersonOrbLabel.coverageMask(for: kind, tileSize: CGFloat(tileSize))
                            source = .coverage(bytes: mask.bytes, size: mask.size)
                        }
                        tiles.append(PersonGlyphTile(key: key, source: source))
                        wideDecalFlags[hubIndex] = kind.usesWideDecalPatch
                    }
                    let atlas = try await builder.build(
                        tiles: tiles,
                        tileSize: tileSize,
                        hubCount: hubs.count,
                        labeledIndices: labeledIndices,
                        wideDecalFlags: wideDecalFlags,
                        supersample: PersonOrbLabel.sdfSupersample,
                        spread: PersonOrbLabel.sdfSpreadPixels,
                        device: device
                    )
                    try Task.checkCancellation()
                    guard let self,
                          self.glyphAtlasRequestGeneration == generation,
                          self.glyphAtlasRequestedSignature == signature else { return }
                    self.personGlyphAtlasStamp &+= 1
                    self.personGlyphAtlasCache[signature] = (atlas, self.personGlyphAtlasStamp)
                    if self.personGlyphAtlasCache.count > Self.personGlyphAtlasCacheCapacity,
                       let oldest = self.personGlyphAtlasCache.min(by: { $0.value.stamp < $1.value.stamp }) {
                        self.personGlyphAtlasCache.removeValue(forKey: oldest.key)
                    }
                    // A same-signature packet may have moved the hubs while
                    // the bake ran. Use that packet's current geometry and
                    // install its UVs and immutable texture in one actor turn.
                    self.installPersonPlanetBuffers(
                        hubs: self.glyphAtlasHubs, tiers: self.glyphAtlasTiers, atlas: atlas
                    )
                    self.glyphAtlasPreparationTask = nil
                    self.onGlyphAtlasReady?()
                } catch {
                    guard let self, self.glyphAtlasRequestGeneration == generation else { return }
                    self.glyphAtlasPreparationTask = nil
                    if !(error is CancellationError) {
                        // Valid, clickable geometry remains present without
                        // decals; a later packet install may retry allocation.
                        print("[GlyphAtlas] preparation failed: \(String(reflecting: type(of: error)))")
                    }
                }
            }
        }
        // A previous texture's UVs cannot label a newly reordered/name-changed
        // packet. Render its geometry immediately with decals disabled until
        // the matching atlas becomes ready.
        return .empty(hubCount: hubs.count)
    }

    private func resolvedGlyphKind(for name: String) -> PersonOrbLabelKind {
        if let cached = resolvedLabelKindCache[name] { return cached }
        let kind = PersonOrbLabel.resolveKind(for: name)
        if resolvedLabelKindCache.count >= Self.resolvedLabelKindCacheCapacity {
            resolvedLabelKindCache.removeAll(keepingCapacity: true)
        }
        resolvedLabelKindCache[name] = kind
        return kind
    }

    private func installPersonPlanetBuffers(
        hubs: [PersonHubInstance], tiers: [PersonPlanetLOD], atlas: PersonGlyphAtlas
    ) {
        let buckets = Self.personPlanetLODBuckets(
            hubs: hubs, tiers: tiers, glyphUVs: atlas.uvs,
            glyphWideDecalFlags: atlas.wideDecalFlags
        )
        personGlyphTexture = atlas.texture
        personPlanetLowCount = buckets.low.count
        personPlanetMediumCount = buckets.medium.count
        personPlanetHighCount = buckets.high.count
        personPlanetLowBuffer = Self.makeBuffer(device: device, values: buckets.low)
        personPlanetMediumBuffer = Self.makeBuffer(device: device, values: buckets.medium)
        personPlanetHighBuffer = Self.makeBuffer(device: device, values: buckets.high)
        personPlanetCount = personPlanetLowCount + personPlanetMediumCount + personPlanetHighCount
    }

    /// Procedural unit-radius icosphere — golden-ratio icosahedron seed,
    /// triangle-subdivided `subdivisions` times. Output positions live on
    /// the unit sphere so the shader can treat each vertex's position as
    /// its surface normal.
    ///
    /// The renderer keeps level 2/3/4 meshes and chooses the People-hub LOD
    /// at upload time. Generated once at renderer init; the buffers are
    /// immutable.
    nonisolated private static func makeIcosphere(
        subdivisions: Int
    ) -> (positions: [SIMD3<Float>], indices: [UInt16]) {
        let phi = Float((1.0 + sqrt(5.0)) / 2.0)
        var positions: [SIMD3<Float>] = [
            SIMD3<Float>(-1,  phi,  0),
            SIMD3<Float>( 1,  phi,  0),
            SIMD3<Float>(-1, -phi,  0),
            SIMD3<Float>( 1, -phi,  0),
            SIMD3<Float>( 0, -1,  phi),
            SIMD3<Float>( 0,  1,  phi),
            SIMD3<Float>( 0, -1, -phi),
            SIMD3<Float>( 0,  1, -phi),
            SIMD3<Float>( phi,  0, -1),
            SIMD3<Float>( phi,  0,  1),
            SIMD3<Float>(-phi,  0, -1),
            SIMD3<Float>(-phi,  0,  1)
        ].map { simd_normalize($0) }

        var indices: [UInt16] = [
            0, 11,  5,   0,  5,  1,   0,  1,  7,   0,  7, 10,   0, 10, 11,
            1,  5,  9,   5, 11,  4,  11, 10,  2,  10,  7,  6,   7,  1,  8,
            3,  9,  4,   3,  4,  2,   3,  2,  6,   3,  6,  8,   3,  8,  9,
            4,  9,  5,   2,  4, 11,   6,  2, 10,   8,  6,  7,   9,  8,  1
        ]

        for _ in 0..<max(0, subdivisions) {
            var midpointCache: [UInt32: UInt16] = [:]
            func midpoint(_ a: UInt16, _ b: UInt16) -> UInt16 {
                let lo = min(a, b)
                let hi = max(a, b)
                let key = (UInt32(lo) << 16) | UInt32(hi)
                if let cached = midpointCache[key] { return cached }
                let mid = simd_normalize((positions[Int(a)] + positions[Int(b)]) * 0.5)
                let new = UInt16(positions.count)
                positions.append(mid)
                midpointCache[key] = new
                return new
            }
            var nextIndices: [UInt16] = []
            nextIndices.reserveCapacity(indices.count * 4)
            var i = 0
            while i < indices.count {
                let a = indices[i]
                let b = indices[i + 1]
                let c = indices[i + 2]
                let ab = midpoint(a, b)
                let bc = midpoint(b, c)
                let ca = midpoint(c, a)
                nextIndices.append(contentsOf: [a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca])
                i += 3
            }
            indices = nextIndices
        }
        return (positions, indices)
    }

    /// Pure with respect to renderer state: the pulse damp is passed in
    /// rather than ticked here, so `hitTest`'s pick math can build
    /// uniforms without advancing animation state.
    private func cameraUniforms(
        size: CGSize,
        camera: CameraState,
        sourceWarp: ConstellationSourceWarp? = nil,
        pulseRestDamp: Float
    ) -> MetalCameraUniforms {
        let aspect = Float(size.width / max(size.height, 1))
        var effectiveDim = fieldDimFactor

        if let sourceWarp {
            let phase = max(0, min(1, sourceWarp.phase))
            let intensity = max(0, min(1, sourceWarp.intensity))
            // Field Collapse: drive `fieldDimFactor` from phase. The
            // clicked node's per-vertex `lock.x = 1` keeps it at full
            // brightness via the existing `lock_dim_multiplier`; every
            // other vertex (with `lock.x = 0`) fades toward the packet's
            // dim factor or the transition's explicit target. The mechanism
            // is monotonic in phase, so exit's `phase = E(1 − progress)`
            // reverses the dim back to 1.
            if intensity > 0.001 {
                let targetDim = sourceWarp.fieldDimTarget ?? fieldDimFactor
                let clampedTarget = max(0.04, min(1, targetDim))
                effectiveDim = 1 - Float(phase) * (1 - clampedTarget)
            }
        }
        let effectiveClusterVisibility = Self.effectiveMeaningClusterVisibility(
            target: meaningClusterVisibilityTarget,
            sourceWarp: sourceWarp
        )
        let basis = Self.cameraBasis(for: camera)
        return MetalCameraUniforms(
            viewProjection: projectionMatrix(aspect: aspect) * viewMatrix(for: camera),
            viewportTimeScale: SIMD4<Float>(
                Float(size.width),
                Float(size.height),
                Float(CACurrentMediaTime() - animationStartTime),
                900
            ),
            cameraPositionAndTier: SIMD4<Float>(
                camera.position.x,
                camera.position.y,
                camera.position.z,
                Float(budget.degradationTier.rawValue)
            ),
            cameraRight: SIMD4<Float>(
                basis.right.x,
                basis.right.y,
                basis.right.z,
                0
            ),
            cameraUp: SIMD4<Float>(
                basis.up.x,
                basis.up.y,
                basis.up.z,
                // Spare channel carries the People context-ring visibility
                // (background portrait ring bands + flagged satellites) —
                // deliberately separate from lockControls.z so exits can
                // brighten planets while keeping rings hidden.
                peopleContextRingVisibility
            ),
            lockControls: SIMD4<Float>(
                effectiveDim,
                effectiveClusterVisibility,
                peopleContextDimPhase,
                // Transient hover-highlight lane, shared by two
                // lens-exclusive consumers: hub index + 1 of the hovered
                // People planet (orbit-path brighten), or the hovered
                // Meaning cluster's phase + 1 (nucleus/gas flare). Each is
                // nonzero only while its own lens's hubs are in the packet.
                hoveredOrbitPathHubIndexPlusOne > 0
                    ? hoveredOrbitPathHubIndexPlusOne
                    : hoveredMeaningClusterPhasePlusOne
            ),
            frameVisualLanguage: Self.frameVisualLanguageUniform(
                currentVisualLanguage,
                pulseRestDamp: pulseRestDamp
            )
        )
    }

    /// Meaning-cluster visibility for the current frame. Mirrors the
    /// field-dim ramp above: while a lock transition's source warp runs,
    /// the orbs sweep monotonically from fully visible toward the warp's
    /// own visibility endpoint (entry) — and back, since exit feeds the
    /// same reversed phase it feeds the dim. The warp's endpoint takes
    /// precedence over the packet's settled `meaningClusterVisibility`
    /// so the ramp is correct from the first frame after a click, before
    /// the async lock-flagged refresh installs the visibility-0 packet.
    /// With no warp active the packet's settled value applies directly
    /// (1 unlocked, 0 locked).
    nonisolated static func effectiveMeaningClusterVisibility(
        target: Float,
        sourceWarp: ConstellationSourceWarp?
    ) -> Float {
        let clampedTarget = max(0, min(1, target))
        guard let sourceWarp, max(0, min(1, sourceWarp.intensity)) > 0.001 else {
            return clampedTarget
        }
        let rampTarget = max(0, min(1, sourceWarp.meaningClusterVisibilityTarget ?? clampedTarget))
        let phase = max(0, min(1, sourceWarp.phase))
        return 1 - phase * (1 - rampTarget)
    }

    private static func cameraBasis(for camera: CameraState) -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        let qYaw = simd_quatf(angle: camera.yaw, axis: SIMD3(0, 1, 0))
        let qPitch = simd_quatf(angle: camera.pitch, axis: SIMD3(1, 0, 0))
        let qRoll = simd_quatf(angle: camera.roll, axis: SIMD3(0, 0, -1))
        let orientation = qYaw * qPitch * qRoll
        return (
            simd_normalize(orientation.act(SIMD3<Float>(1, 0, 0))),
            simd_normalize(orientation.act(SIMD3<Float>(0, 1, 0)))
        )
    }

    /// Pack `FrameVisualLanguage` flags into the shader's SIMD4 uniform
    /// channel. Stable wire format consumed by both star and nebula
    /// fragment shaders; see `MetalCameraUniforms.frameVisualLanguage` and
    /// the Metal `CameraUniforms` struct for the layout.
    nonisolated static func frameVisualLanguageUniform(
        _ language: FrameVisualLanguage,
        pulseRestDamp: Float
    ) -> SIMD4<Float> {
        let nebula: Float
        switch language.densityNebula {
        case .off:         nebula = 0
        case .atmospheric: nebula = 1
        }
        let motion: Float
        switch language.actionMotion {
        case .off:           motion = 0
        case .currentOnly:   motion = 1
        case .allActionable: motion = 2
        }
        // The z slot carries the pulse rest damp (the retired temporal
        // accent's lane — the Timeline lens owns its own SwiftUI/Canvas
        // workspace now).
        _ = language.temporalAccent
        let halos: Float
        switch language.arcHalos {
        case .off:                  halos = 0
        case .ambient:              halos = 1
        case .prominent:            halos = 2
        }
        return SIMD4<Float>(nebula, motion, max(0, min(1, pulseRestDamp)), halos)
    }

    private func makePickTargets(
        alignedStars: [MetalStarInstance?],
        proxies: [HitProxy]
    ) -> [ConstellationPickTarget] {
        proxies.enumerated().map { index, proxy -> ConstellationPickTarget in
            let star = index < alignedStars.count ? alignedStars[index] : nil
            let radius = Self.pickWorldRadius(
                proxyMessageId: proxy.messageId,
                proxyRadiusPixels: proxy.radiusPixels,
                starRadius: star?.positionRadius.w
            )
            let signal = star?.signal ?? SIMD4<Float>.zero
            // Hub displacement lane so pick geometry rides its planet
            // exactly like the visible pass does. Star-paired proxies take
            // THEIR instance's lane (`emerge.w`) — a multi-recipient
            // message has one placement per hub, and each pick circle must
            // ride its own hub, not the primary one. Unpaired proxies
            // (person hubs, the sun) resolve through the proxy id.
            // `collapsesWithDetailFade` marks hub-attached MESSAGE targets
            // (ring satellites), which become untargetable while the hub's
            // Saturn detail is faded out — planet bodies themselves stay
            // clickable at every distance.
            let lane = star.map(\.emerge.w) ?? hubDisplacementLane(forProxy: proxy)
            return ConstellationPickTarget(
                worldPosition: proxy.worldPosition,
                worldRadius: radius,
                minPixelRadius: proxy.radiusPixels,
                signalBoost: max(max(signal.x, signal.y), max(signal.z, signal.w)),
                lane: Int(lane.rounded()),
                collapsesWithDetailFade: lane > 0 && !proxy.messageId.hasPrefix("person"),
                isMeaningCluster: proxy.messageId.hasPrefix(
                    MeaningClusterHubInstance.hitProxyMessageIdPrefix
                )
            )
        }
    }

    nonisolated static func pickWorldRadius(
        proxyMessageId: String,
        proxyRadiusPixels: Float,
        starRadius: Float?
    ) -> Float {
        let proxyRadius = max(0.001, proxyRadiusPixels / 900)
        if proxyMessageId == PersonSunInstance.hitProxyMessageId {
            // The rendered sun has a wide radiant body and separate corona
            // halos. Hover/click should target only the compact "You"
            // node circle so nearby correspondent planets remain reachable.
            return proxyRadius
        }
        return starRadius ?? proxyRadius
    }

    /// Vertex count per instanced orbit-path line strip — dense enough
    /// that a near-parabolic comet arc stays smooth through perihelion.
    static let orbitPathVertexCount = 192

    nonisolated private static func starInstance(
        _ star: MessageStarInstance,
        hubLane: Float = 0
    ) -> MetalStarInstance {
        // effects.y carries `signal.birth` (0 = settled, 0..1 = supernova in
        // flight) — the previous packing of `arrivalTime` was lost to Float
        // precision once epoch hit ~1.7e9, and the 20s ignition shimmer it
        // drove is now redundant with the prominent supernova shockwave.
        //
        // lock.y carries the frame-driven glyph code from
        // `FrameVisualLanguage.Glyph.encode(isSentByUser:)`:
        //   0 = filled dot       (baseline; `.directional` received-direct)
        //   1 = hollow ring      (`.directional` sent-direct)
        //   2 = filled dashed    (`.directional` received-included; set by
        //                         `PeopleGraphBuilder` per-placement)
        //   3 = hollow dashed    (`.directional` sent-included; same)
        // lock.z carries `emergeMask` so the fragment shader can re-acquire
        // suppressed channels on hovered / locked / search-matched nodes.
        // lock.w flags People-portrait background ring satellites that fade
        // with `peopleContextDimPhase` (uniforms.lockControls.z).
        // emerge.xyz carries the People-frame tint baked regardless of
        // active frame; emerge.w is reserved (zero) — previously the
        // state-ring code for the retired triage decoration.
        MetalStarInstance(
            positionRadius: SIMD4<Float>(star.position.x, star.position.y, star.position.z, star.radius),
            color: star.color,
            signal: SIMD4<Float>(star.signal.hover, star.signal.selected, star.signal.search, star.signal.citation),
            effects: SIMD4<Float>(star.signal.practical, star.signal.birth, star.lastMoveMagnitude, star.signal.deletion),
            lock: SIMD4<Float>(
                star.signal.lockFocus,
                Float(star.glyphCode),
                Float(star.emergeMask),
                star.fadesWithPeopleContext ? 1 : 0
            ),
            // `emerge.w` carries the People solar-system hub displacement
            // lane (hub index + 1; 0 = identity) so ring satellites ride
            // their planet as it orbits. Every non-People star keeps 0 —
            // the same value the lane held while reserved.
            emerge: SIMD4<Float>(
                star.defaultCorrespondentTint.x,
                star.defaultCorrespondentTint.y,
                star.defaultCorrespondentTint.z,
                hubLane
            )
        )
    }

    nonisolated private static func satelliteInstance(_ satellite: MessageSatelliteInstance) -> MetalStarInstance {
        MetalStarInstance(
            positionRadius: SIMD4<Float>(satellite.position.x, satellite.position.y, satellite.position.z, satellite.radius),
            color: satellite.color,
            signal: SIMD4<Float>(satellite.signal.hover, satellite.signal.selected, satellite.signal.search, satellite.signal.citation),
            effects: SIMD4<Float>(satellite.signal.practical, satellite.signal.birth, 0, satellite.signal.deletion),
            lock: SIMD4<Float>(satellite.signal.lockFocus, 0, 0, 0),
            emerge: SIMD4<Float>(0, 0, 0, 0)
        )
    }

    /// Fallback sprite-hub representation for packets that opt out of the
    /// 3D planet rendering (today: the locked-overlay Focus scene). Uses
    /// the standard star pipeline with flat alpha — matches the visual
    /// register the Focus scene uses for the moons orbiting its central
    /// node, so the hub doesn't visually outrank its own messages.
    nonisolated private static func personHubSpriteInstance(_ hub: PersonHubInstance) -> MetalStarInstance {
        let demotion: Float = hub.isInstitutional ? 0.78 : 1.0
        let radius = max(0.038, min(0.115, hub.radius * demotion))
        return MetalStarInstance(
            positionRadius: SIMD4<Float>(hub.position.x, hub.position.y, hub.position.z, radius),
            color: SIMD4<Float>(hub.color.x, hub.color.y, hub.color.z, 0.96),
            signal: SIMD4<Float>(0, 0, 0, 0),
            effects: SIMD4<Float>(0, 0, 0, 0),
            lock: SIMD4<Float>(0, 0, 0, 0),
            emerge: SIMD4<Float>(0, 0, 0, 0)
        )
    }

    // `hub.radius` already encodes volume + reciprocity + institutional
    // damp (computed once in PeopleGraphBuilder.buildHubGeometry) AND is
    // the anchor the ring geometry walks outward from (every band's inner
    // edge is at `hub.radius + planetSurfaceGap`). The 3D sphere therefore
    // renders at full `hub.radius` so the planet rim and the first ring's
    // inner edge meet across exactly the `planetSurfaceGap` dark strip —
    // no scale mismatch leaving a wide black void between the orb and
    // ring 1. A legacy 0.45 scale factor sized the sphere to match the
    // old sprite's perceptually-solid core, but it left a gap of
    // `hub.radius * 0.55` between the planet rim and the ring anchor; the
    // ring geometry is the source of truth so the planet matches it, not
    // the other way around. Shared by `personPlanetInstance` (the
    // rendered radius) and `personPlanetLODTiers` (the ranking radius) so
    // LOD/text-tier assignment can never disagree with what's drawn.
    nonisolated private static func personPlanetRadius(_ hub: PersonHubInstance) -> Float {
        // Solar-scale floor (pre-solar bodies were clamped ≥ 0.042; the
        // system now runs at `PeopleGraphBuilder.solarScale` ≈ 0.30 of
        // that). The ceiling is unchanged so legacy fixtures stay valid.
        let minimumRadius: Float = hub.deletionProgress > 0 ? 0.001 : 0.010
        return max(minimumRadius, min(0.110, hub.radius))
    }

    nonisolated private static func personPlanetInstance(
        _ hub: PersonHubInstance,
        glyphUV: SIMD4<Float>,
        usesWideDecalPatch: Bool,
        hubLane: Float
    ) -> MetalPersonPlanetInstance {
        let radius = personPlanetRadius(hub)
        // `color.a` carries the context-dim multiplier (1.0 = full bright).
        // The planet fragment multiplies the composited body by it so the
        // People focus portrait can recede the unfocused background hubs
        // while the focused Saturn stays at full brightness.
        return MetalPersonPlanetInstance(
            centerRadius: SIMD4<Float>(hub.position.x, hub.position.y, hub.position.z, radius),
            color: SIMD4<Float>(hub.color.x, hub.color.y, hub.color.z, hub.contextDim),
            glyphUV: glyphUV,
            signal: SIMD4<Float>(
                hub.recencyScore,
                hub.focusGlow,
                usesWideDecalPatch ? 1 : 0,
                -hub.deletionProgress
            ),
            orbital: SIMD4<Float>(hubLane, hub.obligationUrgency, 0, 0)
        )
    }

    /// Ranks hubs into low/medium/high LOD tiers by rendered radius, same
    /// caps as before (24 high, 96 medium) so hundreds of background hubs
    /// never all pay the 5,120-triangle mesh path. Split out from
    /// `personPlanetLODBuckets` so the atlas builder can gate *which hubs
    /// get a glyph tile at all* on this same ranking, before any per-hub
    /// instance data exists — low-tier hubs (small/background/distant)
    /// never get a name decal, which both caps atlas size and removes the
    /// clutter of illegible labels on orbs too small to read one.
    nonisolated static func personPlanetLODTiers(hubs: [PersonHubInstance]) -> [PersonPlanetLOD] {
        guard hubs.count > 32 else {
            // Small/focused People packets can use the closeup mesh (and
            // full text) everywhere without meaningful cost, which keeps
            // locked-overlay focus views smooth for low-volume
            // correspondents.
            return Array(repeating: .high, count: hubs.count)
        }

        let ranked = hubs.enumerated().sorted { lhs, rhs in
            let lhsRadius = personPlanetRadius(lhs.element)
            let rhsRadius = personPlanetRadius(rhs.element)
            if lhsRadius != rhsRadius { return lhsRadius > rhsRadius }
            return lhs.offset < rhs.offset
        }
        var tiers = Array(repeating: PersonPlanetLOD.low, count: hubs.count)
        var highRemaining = 24
        var mediumRemaining = 96

        for (rank, entry) in ranked.enumerated() {
            let radius = personPlanetRadius(entry.element)
            // Radius thresholds are the pre-solar values scaled by
            // `PeopleGraphBuilder.solarScale` (0.085 → 0.0255,
            // 0.060 → 0.018) so the same relative population earns the
            // high/medium meshes and name decals as before the shrink.
            if highRemaining > 0 && (rank == 0 || radius >= 0.0255) {
                tiers[entry.offset] = .high
                highRemaining -= 1
            } else if mediumRemaining > 0 && (rank < 24 || radius >= 0.018) {
                tiers[entry.offset] = .medium
                mediumRemaining -= 1
            }
        }
        // The focus-glow hub is the correspondent the user is actually
        // inspecting (the builder sets `focusGlow` on the focal hub for
        // both lock kinds): it fills the focused viewport regardless of
        // how small its planet ranks against the full galaxy backdrop, so
        // it must always carry the closeup mesh and its name decal — a
        // 1-email correspondent otherwise ranks `.low` and renders as an
        // unlabeled dot in its own portrait. Deliberately NOT keyed on
        // `orbit == nil`: the builder strips orbits from the whole locked
        // ring scope (every host hub of a locked email node, the one-hop
        // co-recipient expansion — potentially hundreds of hubs), and
        // promoting all of them would bake an unbounded glyph atlas and
        // blow the capped mesh budget at lock entry. Dying ghosts
        // (deletionProgress > 0) stay un-promoted so a name decal never
        // pops onto a collapsing hub mid-death.
        for (index, hub) in hubs.enumerated()
        where hub.focusGlow > 0 && hub.deletionProgress == 0 {
            tiers[index] = .high
        }
        return tiers
    }

    nonisolated private static func personPlanetLODBuckets(
        hubs: [PersonHubInstance],
        tiers: [PersonPlanetLOD],
        glyphUVs: [SIMD4<Float>],
        glyphWideDecalFlags: [Bool]
    ) -> PersonPlanetLODBuckets {
        let planets = zip(hubs, glyphUVs).enumerated().map { index, pair in
            let (hub, glyphUV) = pair
            let usesWideDecalPatch = glyphWideDecalFlags.indices.contains(index)
                ? glyphWideDecalFlags[index]
                : false
            return personPlanetInstance(
                hub,
                glyphUV: glyphUV,
                usesWideDecalPatch: usesWideDecalPatch,
                // Displacement lane: index + 1 for orbit-carrying hubs,
                // the identity sentinel for pinned/locked ones.
                hubLane: hub.orbit == nil ? 0 : Float(index + 1)
            )
        }
        guard !planets.isEmpty else { return PersonPlanetLODBuckets() }

        var buckets = PersonPlanetLODBuckets()
        for (index, planet) in planets.enumerated() {
            switch tiers[index] {
            case .low:
                buckets.low.append(planet)
            case .medium:
                buckets.medium.append(planet)
            case .high:
                buckets.high.append(planet)
            }
        }
        return buckets
    }

    /// Pack each meaning cluster into a single planet instance — the dense
    /// hover-anchor centre at the cluster's centroid. The cluster's *body*
    /// (its visible silhouette) is rendered by the separate metaball body
    /// pass from the cluster's high-affinity member positions. The centroid
    /// core remains so every cluster has one unambiguous, hoverable point.
    ///
    /// `signal.w = 2` keeps selecting the nucleus material in the shared
    /// person-planet fragment shader (the field branch is now dormant).
    /// Deterministic per-cluster brightness phase in ≈ [0, 2π). The
    /// multiplicative hash keeps adjacent cluster ids from flattening to
    /// identical values. Shared by the nucleus material, the metaball body,
    /// the spike halo, and the hover-flare lane (`setHoveredMeaningCluster`)
    /// so a hovered cluster's phase always matches its rendered geometry.
    ///
    /// Quantized to 1e-4 steps across 62,831 buckets: the shader's
    /// hover-flare match window is ±5e-5, so distinct buckets can never
    /// cross-match (float32 round-trip error through the `phase + 1`
    /// uniform lane is ≤ ~3e-7), and an exact bucket collision between two
    /// displayed clusters is ≲1% even at the 32-hub display cap.
    nonisolated static func meaningClusterPhase(_ clusterId: Int64) -> Float {
        let mixed = UInt64(bitPattern: clusterId) &* 2_654_435_761
        return Float(mixed % 62_831) / 10_000.0
    }

    nonisolated private static func meaningClusterPlanetInstances(
        _ hub: MeaningClusterHubInstance
    ) -> [MetalPersonPlanetInstance] {
        let density = max(0, min(1, hub.density))
        let coreRadius = max(0.012, min(0.045, hub.coreRadius))
        let color = SIMD4<Float>(hub.color.x, hub.color.y, hub.color.z, 1.0)
        let phase = meaningClusterPhase(hub.clusterId)
        return [
            MetalPersonPlanetInstance(
                centerRadius: SIMD4<Float>(hub.position.x, hub.position.y, hub.position.z, coreRadius),
                color: color,
                glyphUV: SIMD4<Float>(0, 0, 0, 0),
                signal: SIMD4<Float>(density, Float(hub.memberCount), phase, 2),
                orbital: SIMD4<Float>(0, 0, 0, 0)
            )
        ]
    }

    /// Build the metaball pipeline's instance + shared member buffers
    /// from the planner's cluster hubs. The instance's bounding-sphere
    /// radius is computed here so the planner doesn't need to know about
    /// the renderer's influence-radius mapping.
    ///
    /// Member halos aggregate into ≤24 representative blobs per cluster
    /// (`MeaningMetaballMemberPolicy.aggregatedHalos`), so large clusters
    /// keep their full silhouette instead of dropping peripheral members.
    ///
    /// Affinity and constituent spread establish the density radius. A hard
    /// coverage radius then expands each representative just enough to keep
    /// every constituent inside the shader's visible-gas threshold.
    nonisolated static func meaningClusterMetaballBuffers(
        hubs: [MeaningClusterHubInstance]
    ) -> (instances: [MetalMeaningMetaballInstance], members: [MetalMeaningMetaballMember]) {
        var instances: [MetalMeaningMetaballInstance] = []
        var members: [MetalMeaningMetaballMember] = []
        instances.reserveCapacity(hubs.count)
        members.reserveCapacity(hubs.reduce(0) {
            $0 + min(
                $1.memberHalos.count,
                MeaningMetaballMemberPolicy.detailedMemberCount
            ) + 1
        })

        for hub in hubs where !hub.memberHalos.isEmpty {
            let firstIndex = members.count
            let blobs = MeaningMetaballMemberPolicy.aggregatedHalos(
                hub.memberHalos,
                maximumCount: MeaningMetaballMemberPolicy.detailedMemberCount
            )
            var maxReach: Float = 0
            for blob in blobs {
                let influenceRadius = MeaningMetaballMemberPolicy.influenceRadius(of: blob)
                let delta = blob.position - hub.position
                let reach = simd_length(delta) + influenceRadius
                if reach > maxReach { maxReach = reach }
                members.append(MetalMeaningMetaballMember(
                    positionRadius: SIMD4<Float>(
                        blob.position.x, blob.position.y, blob.position.z,
                        influenceRadius
                    )
                ))
            }
            // The detailed fields preserve local density and texture. This
            // final central field makes the planner's entire membership
            // envelope one connected, selectable cloud instead of detached
            // lobes that merely share a cluster id.
            let envelopeInfluence = MeaningMetaballMemberPolicy
                .envelopeInfluenceRadius(hub.radius)
            maxReach = max(maxReach, envelopeInfluence)
            members.append(MetalMeaningMetaballMember(
                positionRadius: SIMD4<Float>(
                    hub.position.x,
                    hub.position.y,
                    hub.position.z,
                    envelopeInfluence
                )
            ))
            // Tiny padding so fragments right at the bounding-sphere shell
            // still have a positive march distance to integrate over.
            let boundingRadius = max(0.05, maxReach + 0.020)
            let phase = meaningClusterPhase(hub.clusterId)
            instances.append(MetalMeaningMetaballInstance(
                centerRadius: SIMD4<Float>(
                    hub.position.x, hub.position.y, hub.position.z,
                    boundingRadius
                ),
                color: SIMD4<Float>(
                    hub.color.x, hub.color.y, hub.color.z,
                    -max(0.001, min(1, hub.density))
                ),
                memberRange: SIMD4<Float>(
                    Float(firstIndex), Float(blobs.count + 1), phase, 0
                )
            ))
        }
        return (instances, members)
    }

    nonisolated private static func personRingInstance(
        _ ring: PersonRingInstance,
        hubLane: Float = 0
    ) -> MetalPersonRingInstance {
        MetalPersonRingInstance(
            centerRadius: SIMD4<Float>(ring.center.x, ring.center.y, ring.center.z, ring.radius),
            normalThickness: SIMD4<Float>(ring.normal.x, ring.normal.y, ring.normal.z, ring.thickness),
            colorAlpha: SIMD4<Float>(ring.color.x, ring.color.y, ring.color.z, ring.alpha),
            accountColor: SIMD4<Float>(
                ring.accountColor.x,
                ring.accountColor.y,
                ring.accountColor.z,
                ring.arcStartFraction
            ),
            tier: SIMD4<Float>(
                Float(ring.tier.rawValue),
                ring.shimmer ? 1.0 : 0.0,
                ring.radialGlow ? 1.0 : 0.0,
                ring.arcEndFraction
            ),
            transition: SIMD4<Float>(
                ring.fadesWithPeopleContext ? 1.0 : 0.0,
                ring.deletionProgress,
                // Hub displacement lane so the band rides its planet.
                hubLane,
                0
            )
        )
    }

    nonisolated private static func personAtomInstance(_ atom: PersonAtomInstance) -> MetalStarInstance {
        // Re-uses the star pipeline; signal/effects/lock zero so the dot
        // never reacts to hover or lock — it's purely a multi-recipient cue.
        MetalStarInstance(
            positionRadius: SIMD4<Float>(atom.position.x, atom.position.y, atom.position.z, atom.radius),
            color: atom.color,
            signal: SIMD4<Float>(0, 0, 0, 0),
            effects: SIMD4<Float>(0, 0, 0, 0),
            lock: SIMD4<Float>(0, 0, 0, 0),
            emerge: SIMD4<Float>(0, 0, 0, 0)
        )
    }

    nonisolated private static func nebulaInstance(_ nebula: SemanticNebulaInstance) -> MetalNebulaInstance {
        MetalNebulaInstance(
            positionRadius: SIMD4<Float>(nebula.position.x, nebula.position.y, nebula.position.z, nebula.radius),
            colorDensity: SIMD4<Float>(nebula.color.x, nebula.color.y, nebula.color.z, nebula.density),
            meta: SIMD4<Float>(Float(nebula.memberCount), nebula.color.w, 0, 0)
        )
    }

    nonisolated private static func makeHaloInstances(
        stars: [MessageStarInstance],
        satellites: [MessageSatelliteInstance],
        nebulae: [SemanticNebulaInstance],
        meaningClusterHubs: [MeaningClusterHubInstance]
    ) -> [MetalHaloInstance] {
        var halos: [MetalHaloInstance] = []
        halos.reserveCapacity(
            nebulae.count + stars.count + satellites.count + meaningClusterHubs.count
        )

        // Ring moons in the locked People portrait are deliberately larger
        // than global People satellites so the user can read and tab through
        // them. Skip the regular broad halo for those focus beads; otherwise
        // the fixed 0.13-radius bloom turns the size increase into a blur.
        // Global satellite-sized People nodes still skip by the older radius
        // threshold, while ordinary message stars keep their halo.
        for star in stars where star.radius >= 0.022 && !isLockedPeopleRingMoon(star) {
            halos.append(starHaloInstance(star))
        }
        for satellite in satellites {
            halos.append(satelliteHaloInstance(satellite))
        }

        for nebula in nebulae {
            halos.append(nebulaHaloInstance(nebula))
        }

        // Meaning-lens nuclei get a stellar diffraction-spike sprite over
        // the small planet-pipeline core body — the "brightest object in
        // the cluster" signature that makes the hover anchor findable at
        // any zoom.
        for hub in meaningClusterHubs {
            halos.append(meaningNucleusSpikeHalo(hub))
        }

        return halos
    }

    /// One additive diffraction-spike sprite per Meaning-cluster nucleus.
    /// `lock.w = 1` selects the halo fragment's spike material; `meta.z`
    /// carries the cluster's deterministic phase so the material can match
    /// the hover-flare lane in `lockControls.w`. The sprite radius scales
    /// off the nucleus core so the cross reads as the core's own optics,
    /// not a second body.
    nonisolated private static func meaningNucleusSpikeHalo(
        _ hub: MeaningClusterHubInstance
    ) -> MetalHaloInstance {
        let radius = min(0.30, max(0.12, hub.coreRadius * 5.0))
        let intensity = 0.55 + hub.density * 0.30
        return MetalHaloInstance(
            positionRadius: SIMD4<Float>(hub.position.x, hub.position.y, hub.position.z, radius),
            colorIntensity: colorIntensity(tint: hub.color, intensity: intensity),
            meta: SIMD4<Float>(
                Float(hub.memberCount),
                hub.density,
                meaningClusterPhase(hub.clusterId),
                0
            ),
            lock: SIMD4<Float>(0, 0, 0, 1)
        )
    }

    nonisolated private static func isLockedPeopleRingMoon(_ star: MessageStarInstance) -> Bool {
        let tint = star.defaultCorrespondentTint
        let hasPeopleTint = tint.x + tint.y + tint.z > 0.01
        let hasFocusSignal = star.signal.lockFocus >= 0.70 && star.signal.search >= 0.34
        return (hasPeopleTint || hasFocusSignal) && star.radius <= 0.043
    }

    nonisolated private static func starHaloInstance(_ star: MessageStarInstance) -> MetalHaloInstance {
        let count = Float(max(star.vectorCount, 1))
        let concentration = min(1, log2(count + 1) / 7)
        let signal = max(star.signal.intensity, star.signal.practical * 0.75)
        let radius = 0.13 + concentration * 0.10 + min(0.06, star.radius * 2.0)
        // Dying nodes fade their halo alongside the body so the black-hole
        // collapse reads cleanly — without this, the surrounding halo would
        // outshine the shrinking body and the disc.
        let deathFade = max(0, 1 - star.signal.deletion)
        let intensity = min(0.115, 0.018 + concentration * 0.018 + signal * 0.050) * deathFade
        return MetalHaloInstance(
            positionRadius: SIMD4<Float>(star.position.x, star.position.y, star.position.z, radius),
            colorIntensity: colorIntensity(tint: haloTint(from: star.color), intensity: intensity),
            meta: SIMD4<Float>(count, concentration, stablePhase(for: star.representativeVectorId), 0),
            lock: SIMD4<Float>(star.signal.lockFocus, 0, 0, 0)
        )
    }

    nonisolated private static func satelliteHaloInstance(_ satellite: MessageSatelliteInstance) -> MetalHaloInstance {
        let signal = satellite.signal.intensity
        let radius: Float = 0.095
        let deathFade = max(0, 1 - satellite.signal.deletion)
        let intensity = min(0.070, 0.012 + signal * 0.040) * deathFade
        return MetalHaloInstance(
            positionRadius: SIMD4<Float>(satellite.position.x, satellite.position.y, satellite.position.z, radius),
            colorIntensity: colorIntensity(tint: haloTint(from: satellite.color), intensity: intensity),
            meta: SIMD4<Float>(1, 0.10, stablePhase(for: satellite.vectorId), 0),
            lock: SIMD4<Float>(satellite.signal.lockFocus, 0, 0, 0)
        )
    }

    nonisolated private static func nebulaHaloInstance(_ nebula: SemanticNebulaInstance) -> MetalHaloInstance {
        let count = Float(max(nebula.memberCount, 1))
        let concentration = min(1, log2(count + 1) / 10)
        let radius = min(1.20, max(nebula.radius * 1.95, 0.18 + concentration * 0.50))
        let intensity = min(0.24, 0.030 + concentration * 0.100 + nebula.density * 0.080)
        // Nested-aspect ring decoration: when the cluster has a secondary
        // arc label (different from the primary), the halo fragment draws
        // a thin inner ring tinted toward the secondary. `lock.y` is
        // unused by today's halo path and is reused as a "nested aspect
        // present" flag (0 = none, ~0.65 = nested ring active). The
        // existing `meta.w` is `proximity` and must not be repurposed —
        // we leave it at the long-standing 0 baseline.
        let nestedFlag: Float = nebula.nestedSubclusterHash != 0 ? 0.65 : 0.0
        return MetalHaloInstance(
            positionRadius: SIMD4<Float>(nebula.position.x, nebula.position.y, nebula.position.z, radius),
            colorIntensity: colorIntensity(tint: haloTint(from: nebula.color), intensity: intensity),
            meta: SIMD4<Float>(count, max(nebula.density, concentration), stablePhase(for: nebula.representativeVectorId), 0),
            lock: SIMD4<Float>(0, nestedFlag, 0, 0)
        )
    }

    nonisolated private static func colorIntensity(tint: SIMD3<Float>, intensity: Float) -> SIMD4<Float> {
        SIMD4<Float>(tint.x, tint.y, tint.z, intensity)
    }

    nonisolated private static func haloTint(from color: SIMD4<Float>) -> SIMD3<Float> {
        // Halo expresses the per-account hue. A small neutral lift keeps very
        // dark palette entries (deep indigo, near-black) from rendering as
        // invisible halos — without it those accounts would lose their bloom.
        let lift = SIMD3<Float>(0.18, 0.20, 0.22)
        let semantic = SIMD3<Float>(color.x, color.y, color.z)
        return lift * 0.18 + semantic * 0.82
    }

    nonisolated private static func stablePhase(for id: Int64) -> Float {
        let mixed = UInt64(bitPattern: id) &* 1_099_511_628_211 &+ 14_695_981_039_346_656_037
        return Float(mixed % 6_283) / 1_000
    }

    nonisolated private static func fiberVertices(_ fiber: AffinityFiberInstance) -> [MetalFiberVertex] {
        let active = max(fiber.signal.search, fiber.signal.citation)
        let warmth = max(0, min(1, fiber.strength))
        let isPeopleRelation = fiber.sourceMessageId.hasPrefix("person:")
            && fiber.targetMessageId.hasPrefix("person:")
        let alphaBase: Float = isPeopleRelation ? 0.24 : 0.12
        let alphaScale: Float = isPeopleRelation ? 0.74 : 0.55
        let alphaCap: Float = isPeopleRelation ? 0.96 : 0.86
        let alpha = min(alphaCap, alphaBase + fiber.strength * alphaScale + active * 0.22)
        let color: SIMD4<Float>
        if let presentationColor = fiber.presentationColor {
            color = SIMD4<Float>(
                presentationColor.x,
                presentationColor.y,
                presentationColor.z,
                min(0.96, presentationColor.w + active * 0.28)
            )
        } else {
            color = SIMD4<Float>(
                isPeopleRelation ? 0.48 + warmth * 0.28 : 0.38 + warmth * 0.62,
                isPeopleRelation ? 0.76 + warmth * 0.18 : 0.62 + warmth * 0.25,
                isPeopleRelation ? 0.70 + warmth * 0.12 : 0.95,
                alpha
            )
        }
        // Per-kind code packed into `lock.y` so the fragment shader can
        // tint thread strands amber, correspondent green, temporal blue,
        // etc. — distinct from cosine fibres without changing the geometry
        // path. `0` (kind-less) keeps today's blue cosine rendering.
        let kindCode = Float(fiber.edgeKind?.rendererCode ?? 0)
        let width = max(1.0, min(6.0, fiber.strokeWidthPixels))
        func vertex(endpoint: Float, side: Float) -> MetalFiberVertex {
            MetalFiberVertex(
                from: fiber.from,
                strength: fiber.strength,
                to: fiber.to,
                strokeWidthPixels: width,
                color: color,
                lock: SIMD4<Float>(fiber.signal.lockFocus, kindCode, endpoint, side)
            )
        }
        return [
            vertex(endpoint: 0, side: -1),
            vertex(endpoint: 1, side: -1),
            vertex(endpoint: 0, side: 1),
            vertex(endpoint: 0, side: 1),
            vertex(endpoint: 1, side: -1),
            vertex(endpoint: 1, side: 1)
        ]
    }
}

private func viewMatrix(for cam: CameraState) -> matrix_float4x4 {
    let qYaw = simd_quatf(angle: cam.yaw, axis: SIMD3(0, 1, 0))
    let qPitch = simd_quatf(angle: cam.pitch, axis: SIMD3(1, 0, 0))
    let qRoll = simd_quatf(angle: cam.roll, axis: SIMD3(0, 0, -1))
    let rotWorld = matrix_float4x4(qYaw * qPitch * qRoll)
    var rotView = rotWorld.transpose
    rotView.columns.3 = SIMD4<Float>(0, 0, 0, 1)
    var trans = matrix_identity_float4x4
    trans.columns.3 = SIMD4<Float>(-cam.position.x, -cam.position.y, -cam.position.z, 1)
    return rotView * trans
}

private func projectionMatrix(aspect: Float, fovY: Float = .pi / 3, near: Float = 0.01, far: Float = 100) -> matrix_float4x4 {
    let y = 1 / tan(fovY * 0.5)
    let x = y / max(aspect, 0.001)
    let z = far / (near - far)
    let w = (near * far) / (near - far)
    return matrix_float4x4(columns: (
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, z, -1),
        SIMD4<Float>(0, 0, w, 0)
    ))
}
