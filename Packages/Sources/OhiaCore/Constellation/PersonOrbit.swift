import Foundation
import simd

/// Keplerian orbit parameters for one correspondent planet in the People
/// lens's solar-system layout. The sun (the user) sits at the orbit's
/// focus; the three relationship axes map to the three orbital elements:
///
///   * **perihelion** (closest approach)  ← recency: absolute log-age bands
///     anchored at the scope's "now" — fresher correspondents come closer.
///   * **eccentricity** (orbit shape)     ← reciprocity: balanced
///     relationships ride near-circles, one-sided ones elongate, and the
///     broadcast class (institutional senders the user never answers)
///     rides near-parabolic comet arcs.
///   * **meanMotion** (angular speed)     ← urgency: age-weighted open
///     obligations. A planet that owes the user nothing drifts; one with
///     week-old unanswered asks sweeps visibly.
///
/// Orbits are strictly periodic (e < 1): the comet class is *near*-
/// parabolic by design so every correspondent is always somewhere on its
/// arc — present, hoverable, clickable. Open conics would exit the chart.
public struct PersonOrbit: Sendable, Equatable {
    /// Perihelion distance from the sun in world units (> 0).
    public let perihelion: Float
    /// Eccentricity in [0, `PersonOrbitMath.maxEccentricity`]. Already
    /// clamped so the aphelion stays inside the chart's outer cap.
    public let eccentricity: Float
    /// Angle of the perihelion direction within the ecliptic plane,
    /// radians from the plane's +U axis. Communities cluster here so
    /// related correspondents' orbits align like a comet family.
    public let argumentOfPerihelion: Float
    /// Small rotation of the orbital plane around the perihelion axis
    /// (radians). Keeps co-orbital planets from z-fighting and gives the
    /// disc parallax life without breaking the coherent-plane reading.
    public let inclination: Float
    /// Mean anomaly at orbital-clock zero (radians).
    public let phaseAtEpoch: Float
    /// Mean motion in radians per second of orbital clock at full speed.
    public let meanMotion: Float
    /// Age-weighted open-obligation urgency in [0, 1]. Drives both the
    /// orbital period (via `meanMotion`, computed upstream) and the
    /// petal-red ember rim that keeps urgency readable while the system
    /// is stopped.
    public let urgency: Float
    /// Broadcast/transient class flag (institutional or automated sender
    /// the user has never written to). Comets take the near-parabolic
    /// eccentricity band and dashed path styling.
    public let isComet: Bool

    public init(
        perihelion: Float,
        eccentricity: Float,
        argumentOfPerihelion: Float,
        inclination: Float,
        phaseAtEpoch: Float,
        meanMotion: Float,
        urgency: Float,
        isComet: Bool
    ) {
        self.perihelion = max(0.0001, perihelion)
        self.eccentricity = max(0, min(PersonOrbitMath.maxEccentricity, eccentricity))
        self.argumentOfPerihelion = argumentOfPerihelion
        self.inclination = inclination
        self.phaseAtEpoch = phaseAtEpoch
        self.meanMotion = max(0, meanMotion)
        self.urgency = max(0, min(1, urgency))
        self.isComet = isComet
    }

    /// Semi-major axis derived from perihelion + eccentricity.
    public var semiMajorAxis: Float {
        perihelion / max(0.0001, 1 - eccentricity)
    }

    /// Aphelion (farthest distance from the sun).
    public var aphelion: Float {
        semiMajorAxis * (1 + eccentricity)
    }
}

/// Shared orthonormal basis of the solar system's ecliptic plane. All
/// orbits live in (small inclinations off) this plane; the renderer's
/// orbit-path pass and the builder's placement math derive positions
/// through the same basis so CPU layout, GPU displacement, and path
/// geometry can never disagree.
public struct PersonEclipticBasis: Sendable, Equatable {
    /// In-plane +U axis (unit).
    public let axisU: SIMD3<Float>
    /// In-plane +V axis (unit).
    public let axisV: SIMD3<Float>
    /// Plane normal (unit).
    public let normal: SIMD3<Float>

    public init(axisU: SIMD3<Float>, axisV: SIMD3<Float>, normal: SIMD3<Float>) {
        self.axisU = axisU
        self.axisV = axisV
        self.normal = normal
    }

    /// Canonical basis for a given plane normal, in-plane axes biased
    /// toward world-X the same way the ring quads' bases are, so every
    /// People-lens plane construction shares one orientation convention.
    public init(normal: SIMD3<Float>) {
        let n = simd_length(normal) > 0.0001 ? simd_normalize(normal) : SIMD3<Float>(0, 0, 1)
        let reference: SIMD3<Float> = abs(n.x) < 0.9
            ? SIMD3<Float>(1, 0, 0)
            : SIMD3<Float>(0, 1, 0)
        let u = simd_normalize(simd_cross(reference, n))
        let v = simd_normalize(simd_cross(n, u))
        self.init(axisU: u, axisV: v, normal: n)
    }
}

/// Pure Keplerian + chart-mapping math for the People solar system.
/// Deterministic and side-effect free: the same inputs always produce the
/// same geometry, which is what keeps packet rebuilds pop-free and lets
/// the renderer compute per-frame displacements CPU-side as
/// `position(at: now) - position(at: packetClock)`.
public enum PersonOrbitMath {
    // MARK: - Chart scale

    /// Sun body radius in world units.
    public static let sunRadius: Float = 0.085
    /// Hard ceiling on eccentricity — near-parabolic but strictly periodic.
    public static let maxEccentricity: Float = 0.97
    /// Aphelion cap: no orbit reaches past this distance from the sun, so
    /// the whole system (paths included) stays inside a framable chart.
    public static let aphelionCap: Float = 3.10

    /// Recency control points: (age in days, perihelion world radius).
    /// Log-interpolated between points; ages beyond the last point clamp
    /// to the outer rim. Bands start close to the sun so *fresh* comets
    /// have room to be properly near-parabolic under the aphelion cap
    /// (e_max = (cap - q) / (cap + q) — small q ⇒ large e_max).
    public static let recencyControlPoints: [(days: Float, radius: Float)] = [
        (0, 0.18),
        (1, 0.24),
        (7, 0.46),
        (30, 0.85),
        (90, 1.35),
        (365, 2.00),
        (730, 2.60)
    ]

    /// Radii of the faint concentric band-guide rings (the chart's grid),
    /// drawn at the day-boundary control points.
    public static var bandGuideRadii: [Float] {
        recencyControlPoints.dropFirst().map(\.radius)
    }

    /// Outer rim — the last recency control radius.
    public static var outerRimRadius: Float {
        recencyControlPoints.last?.radius ?? 2.60
    }

    // MARK: - Recency → perihelion

    /// Map an absolute age (seconds between the recency anchor and the
    /// correspondent's latest interaction) to a perihelion radius via
    /// piecewise log-age interpolation over `recencyControlPoints`.
    /// Negative ages (clock skew, future-dated mail) clamp to the
    /// innermost radius. Ages beyond the last control point clamp to the
    /// outer rim: distance is a calendar statement and the rim is its
    /// "a year or more" register.
    public static func perihelionRadius(forAgeSeconds ageSeconds: Double) -> Float {
        let days = Float(max(0, ageSeconds) / 86_400)
        let points = recencyControlPoints
        guard let first = points.first else { return 0.5 }
        if days <= first.days { return first.radius }
        for index in 1..<points.count {
            let lower = points[index - 1]
            let upper = points[index]
            if days <= upper.days {
                let logLower = log1p(lower.days)
                let logUpper = log1p(upper.days)
                let span = logUpper - logLower
                let t = span > 0 ? (log1p(days) - logLower) / span : 1
                return lower.radius + (upper.radius - lower.radius) * max(0, min(1, t))
            }
        }
        return points[points.count - 1].radius
    }

    // MARK: - Reciprocity → eccentricity

    /// Nominal (pre-cap) eccentricity for a human correspondent from the
    /// reciprocal score in [0, 1]. Fully reciprocal ⇒ near-circular 0.05;
    /// fully one-sided ⇒ elongated 0.85. The 1.35 exponent keeps mid
    /// reciprocity visibly elliptical without crowding the comet band.
    public static func humanEccentricity(reciprocalScore: Float) -> Float {
        let oneSidedness = max(0, min(1, 1 - reciprocalScore))
        return 0.05 + pow(oneSidedness, 1.35) * 0.80
    }

    /// Nominal (pre-cap) eccentricity for the broadcast/comet class.
    /// `jitter` in [0, 1] spreads comets across 0.93–0.97 so their arcs
    /// don't stack into one visual groove.
    public static func cometEccentricity(jitter: Float) -> Float {
        0.93 + max(0, min(1, jitter)) * 0.04
    }

    /// Clamp a nominal eccentricity so the orbit's aphelion stays within
    /// `aphelionCap` for the given perihelion. Q = q(1+e)/(1−e) ≤ C
    /// ⇒ e ≤ (C − q) / (C + q). Detail concentrates where recency does:
    /// fresh orbits keep their full shape range while stale orbits relax
    /// toward calm rim circles.
    public static func cappedEccentricity(nominal: Float, perihelion: Float) -> Float {
        let q = max(0.0001, perihelion)
        let cap = (aphelionCap - q) / (aphelionCap + q)
        return max(0, min(min(nominal, maxEccentricity), max(0, cap)))
    }

    // MARK: - Urgency → mean motion

    /// Full-speed orbital period in seconds for a given urgency and
    /// perihelion. Urgency compresses the period from the contemplative
    /// ~90 s baseline toward ~15 s at maximum; a mild Kepler-third-law
    /// flavor (`a^0.35`) keeps outer orbits statelier than inner ones so
    /// the system reads physically coherent at a glance.
    public static func orbitalPeriodSeconds(urgency: Float, perihelion: Float, eccentricity: Float) -> Float {
        let clampedUrgency = max(0, min(1, urgency))
        // Ease so a single fresh obligation already reads as "moving".
        let eased = pow(clampedUrgency, 0.75)
        let basePeriod = 90 - (90 - 15) * eased
        let a = max(0.05, perihelion / max(0.0001, 1 - min(maxEccentricity, eccentricity)))
        let keplerFlavor = pow(a, 0.35)
        return max(6, basePeriod * keplerFlavor)
    }

    /// Age-weighted open-obligation urgency in [0, 1].
    ///
    /// Each unresolved inbound obligation (needs-reply or needs-
    /// confirmation, already normalized upstream so resolved/self-sent
    /// rows never count) contributes `1 + min(2, waitingDays / 3.5)` —
    /// a week-old unanswered ask weighs 3× a fresh one, capped so one
    /// ancient thread can't saturate alone. The sum maps through
    /// `1 − exp(−Σ/2.5)`: one fresh ask ≈ 0.33, one week-old ask ≈ 0.70,
    /// a pile → 1. Zero obligations ⇒ 0 (baseline drift).
    public static func urgencyScore(obligationAgesDays: [Double]) -> Float {
        guard !obligationAgesDays.isEmpty else { return 0 }
        var total: Double = 0
        for age in obligationAgesDays {
            let days = max(0, age)
            total += 1 + min(2, days / 3.5)
        }
        return Float(1 - exp(-total / 2.5))
    }

    // MARK: - Kepler solve

    /// Solve Kepler's equation M = E − e·sin E for the eccentric anomaly
    /// via Newton iteration. Converges in ≤ `iterations` steps for
    /// e ≤ 0.97 with the E₀ = M (low e) / E₀ = π (high e) seed.
    public static func eccentricAnomaly(meanAnomaly: Float, eccentricity: Float, iterations: Int = 8) -> Float {
        let e = max(0, min(maxEccentricity, eccentricity))
        // Wrap M into (-π, π] for a stable seed.
        var m = meanAnomaly.truncatingRemainder(dividingBy: 2 * .pi)
        if m > .pi { m -= 2 * .pi }
        if m < -.pi { m += 2 * .pi }
        var eAnomaly: Float = e < 0.8 ? m : (m >= 0 ? .pi : -.pi)
        for _ in 0..<max(1, iterations) {
            let f = eAnomaly - e * sin(eAnomaly) - m
            let fPrime = 1 - e * cos(eAnomaly)
            let step = f / max(0.0001, fPrime)
            eAnomaly -= step
            if abs(step) < 1e-6 { break }
        }
        return eAnomaly
    }

    /// Position on the orbit at orbital-clock time `t`, in the world frame
    /// defined by `basis`, around `sunPosition`. This is the single source
    /// of truth shared by layout (packet base positions), the renderer's
    /// per-frame displacement pass, and any CPU consumer that needs a
    /// planet's live position — they only ever differ in the `t` they ask
    /// about.
    public static func position(
        orbit: PersonOrbit,
        at t: TimeInterval,
        sunPosition: SIMD3<Float>,
        basis: PersonEclipticBasis
    ) -> SIMD3<Float> {
        let meanAnomaly = orbit.phaseAtEpoch + orbit.meanMotion * Float(t)
        let e = orbit.eccentricity
        let eAnomaly = eccentricAnomaly(meanAnomaly: meanAnomaly, eccentricity: e)
        let a = orbit.semiMajorAxis
        // True anomaly from eccentric anomaly.
        let halfE = eAnomaly / 2
        let trueAnomaly = 2 * atan2(
            sqrt(max(0, 1 + e)) * sin(halfE),
            sqrt(max(0.0001, 1 - e)) * cos(halfE)
        )
        let r = a * (1 - e * cos(eAnomaly))
        return orbitPoint(
            orbit: orbit,
            trueAnomaly: trueAnomaly,
            radius: r,
            sunPosition: sunPosition,
            basis: basis
        )
    }

    /// Point on the orbit's *path* at a given true anomaly — used by the
    /// orbit-path line pass, which samples ν uniformly around the ellipse.
    public static func pathPoint(
        orbit: PersonOrbit,
        trueAnomaly: Float,
        sunPosition: SIMD3<Float>,
        basis: PersonEclipticBasis
    ) -> SIMD3<Float> {
        let e = orbit.eccentricity
        let p = orbit.perihelion * (1 + e) // semi-latus rectum
        let r = p / max(0.05, 1 + e * cos(trueAnomaly))
        return orbitPoint(
            orbit: orbit,
            trueAnomaly: trueAnomaly,
            radius: r,
            sunPosition: sunPosition,
            basis: basis
        )
    }

    private static func orbitPoint(
        orbit: PersonOrbit,
        trueAnomaly: Float,
        radius: Float,
        sunPosition: SIMD3<Float>,
        basis: PersonEclipticBasis
    ) -> SIMD3<Float> {
        let omega = orbit.argumentOfPerihelion
        // Perifocal axes: P̂ toward perihelion, Q̂ 90° ahead in the flight
        // direction, tilted by the small inclination around P̂.
        let pAxis = basis.axisU * cos(omega) + basis.axisV * sin(omega)
        let qFlat = basis.axisU * -sin(omega) + basis.axisV * cos(omega)
        let qAxis = qFlat * cos(orbit.inclination) + basis.normal * sin(orbit.inclination)
        return sunPosition
            + pAxis * (cos(trueAnomaly) * radius)
            + qAxis * (sin(trueAnomaly) * radius)
    }
}

/// The sun at the center of the People solar system — the user across
/// every account in scope. Aggregate stats ride along for the hover
/// readout; colors are resolved at the SwiftUI boundary (appearance-aware)
/// and baked here like every other packet color.
public struct PersonSunInstance: Sendable, Equatable {
    /// Synthetic hit-proxy messageId for the sun — hover shows the
    /// aggregate readout; click reframes the whole system.
    public static let hitProxyMessageId = "personSun"
    /// Synthetic vectorId for the sun's hit proxy. Outside every real
    /// vector id and distinct from the meaning-cluster negative range
    /// (`-clusterId - 1`).
    public static let hitProxyVectorId: Int64 = -900_001

    public let position: SIMD3<Float>
    public let radius: Float
    /// Body color — the sun accent from `AccountColorPalette.personSunAccentRGB`
    /// (an unused palette slot via the `+3` system, preferring Capella Gold;
    /// stamen register only as the exhausted-palette fallback).
    public let color: SIMD3<Float>
    public let correspondentCount: Int
    public let sentCount: Int
    public let receivedCount: Int
    /// Total unresolved inbound obligations across the scope.
    public let openObligationCount: Int
    /// Reference clock (seconds since 1970) at which every hub's packet
    /// base position was evaluated — `position(orbit, at: packetClock)`.
    /// The renderer's displacement pass reuses it so live positions are
    /// `position(orbit, at: now) − position(orbit, at: packetClock)`
    /// away from the packet geometry, and a frozen clock at packet time
    /// means zero displacement everywhere.
    public let orbitalEpoch: TimeInterval
    /// Shared ecliptic basis for every orbit in this packet.
    public let eclipticNormal: SIMD3<Float>

    public init(
        position: SIMD3<Float>,
        radius: Float = PersonOrbitMath.sunRadius,
        color: SIMD3<Float>,
        correspondentCount: Int,
        sentCount: Int,
        receivedCount: Int,
        openObligationCount: Int,
        orbitalEpoch: TimeInterval,
        eclipticNormal: SIMD3<Float>
    ) {
        self.position = position
        self.radius = max(0.01, radius)
        self.color = color
        self.correspondentCount = max(0, correspondentCount)
        self.sentCount = max(0, sentCount)
        self.receivedCount = max(0, receivedCount)
        self.openObligationCount = max(0, openObligationCount)
        self.orbitalEpoch = orbitalEpoch
        let n = simd_length(eclipticNormal)
        self.eclipticNormal = n > 0.0001 ? eclipticNormal / n : SIMD3<Float>(0, 0, 1)
    }

    public var eclipticBasis: PersonEclipticBasis {
        PersonEclipticBasis(normal: eclipticNormal)
    }
}
