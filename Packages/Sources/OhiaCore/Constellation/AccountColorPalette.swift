import Foundation
import simd

extension Notification.Name {
    /// Posted when an account's `colorIndex` changes. Constellation views
    /// listen for this to invalidate their snapshot cache so the renderer
    /// rebuilds per-message colors with the new account hue.
    public static let ohiaAccountColorChanged = Notification.Name("ohia.account.color-changed")
}

/// Per-account stellar/nebular color identity for the Constellation view.
/// Accounts pick one entry from the fixed palette below; the constellation
/// renderer uses the entry's hue and saturation for that account's nodes
/// and modulates brightness by message age (`ConstellationSnapshotLoader`).
public struct AccountColor: Identifiable, Sendable, Hashable {
    /// Stable ordinal in `AccountColorPalette.all`. Persisted on `Account.colorIndex`.
    public let id: Int
    public let name: String
    public let hue: Double
    public let saturation: Double

    public init(id: Int, name: String, hue: Double, saturation: Double) {
        self.id = id
        self.name = name
        self.hue = hue
        self.saturation = saturation
    }
}

public enum AccountColorPalette {
    /// 12 distinct hues drawn from real stellar spectral classes and emission
    /// nebulae so the palette stays inside the constellation's visual schema.
    /// Order matters: index 0 (Cygnus Cyan) is the default for the first
    /// account and matches the legacy single-color rendering. Subsequent
    /// indices are cycled through for additional accounts.
    public static let all: [AccountColor] = [
        AccountColor(id: 0,  name: "Cygnus Cyan",       hue: 0.55, saturation: 0.55),
        AccountColor(id: 1,  name: "Vega Blue",         hue: 0.62, saturation: 0.45),
        AccountColor(id: 2,  name: "Pleiades Indigo",   hue: 0.70, saturation: 0.55),
        AccountColor(id: 3,  name: "Trapezium Violet",  hue: 0.76, saturation: 0.55),
        AccountColor(id: 4,  name: "Rosette Magenta",   hue: 0.88, saturation: 0.55),
        AccountColor(id: 5,  name: "Eagle Pink",        hue: 0.95, saturation: 0.40),
        AccountColor(id: 6,  name: "Betelgeuse Red",    hue: 0.99, saturation: 0.65),
        AccountColor(id: 7,  name: "Arcturus Orange",   hue: 0.07, saturation: 0.70),
        AccountColor(id: 8,  name: "Capella Gold",      hue: 0.13, saturation: 0.65),
        AccountColor(id: 9,  name: "Procyon Pale",      hue: 0.15, saturation: 0.30),
        AccountColor(id: 10, name: "Ohia Green",        hue: 0.24166666666666667, saturation: 0.8695652173913043),
        AccountColor(id: 11, name: "Sirius White",      hue: 0.55, saturation: 0.10),
    ]

    public static var defaultIndex: Int { 0 }
    public static var correspondentAccentOffset: Int { 3 }
    /// Resolve a stored `colorIndex` to a palette entry. Out-of-range or nil
    /// values fall back to the default (Cygnus Cyan) so no node ever renders
    /// without a color.
    public static func color(forIndex index: Int?) -> AccountColor {
        guard let index, all.indices.contains(index) else { return all[defaultIndex] }
        return all[index]
    }

    /// Pick the single People-frame correspondent hub accent from the account
    /// palette. Start three palette slots after the source account color; if
    /// that slot is already in use by any account, walk forward circularly
    /// until the first unused color. If every palette slot is occupied, fall
    /// back to the preferred +3 slot so the choice remains deterministic.
    public static func correspondentAccentIndex(
        forAccountColorIndex accountColorIndex: Int? = nil,
        usedAccountColorIndices: Set<Int> = []
    ) -> Int {
        let count = all.count
        guard count > 0 else { return defaultIndex }
        let base = color(forIndex: accountColorIndex).id
        let preferred = (base + correspondentAccentOffset) % count
        let used = Set(usedAccountColorIndices.filter { all.indices.contains($0) })
        guard used.contains(preferred) else { return preferred }

        for offset in 1..<count {
            let candidate = (preferred + offset) % count
            if !used.contains(candidate) {
                return candidate
            }
        }
        return preferred
    }

    public static func correspondentAccentColor(
        forAccountColorIndex accountColorIndex: Int? = nil,
        usedAccountColorIndices: Set<Int> = []
    ) -> AccountColor {
        color(
            forIndex: correspondentAccentIndex(
                forAccountColorIndex: accountColorIndex,
                usedAccountColorIndices: usedAccountColorIndices
            )
        )
    }

    public static func correspondentAccentRGB(
        forAccountColorIndex accountColorIndex: Int? = nil,
        usedAccountColorIndices: Set<Int> = [],
        brightness: Double = 1.0
    ) -> SIMD3<Float> {
        let rgba = rgb(
            for: correspondentAccentColor(
                forAccountColorIndex: accountColorIndex,
                usedAccountColorIndices: usedAccountColorIndices
            ),
            brightness: brightness
        )
        return SIMD3<Float>(rgba.x, rgba.y, rgba.z)
    }

    /// Ring-band accent for the People-lens Saturn rings. Derived from the
    /// same alternate-AccountColor mechanism that produces the hub planet
    /// color (`correspondentAccentRGB`, `+3` from the base) but at a much
    /// lower saturation so the ring reads as the hub's ethereal companion
    /// — same identity, distinct material. The hub stays vivid, the band
    /// stays translucent, the email-node rocks keep their AccountColor.
    public static func ringAccentRGB(
        forAccountColorIndex accountColorIndex: Int? = nil,
        usedAccountColorIndices: Set<Int> = [],
        brightness: Double = 1.0
    ) -> SIMD3<Float> {
        let base = correspondentAccentColor(
            forAccountColorIndex: accountColorIndex,
            usedAccountColorIndices: usedAccountColorIndices
        )
        let pale = AccountColor(
            id: base.id,
            name: base.name,
            hue: base.hue,
            saturation: max(0.18, base.saturation * 0.32)
        )
        let rgba = rgb(for: pale, brightness: brightness)
        return SIMD3<Float>(rgba.x, rgba.y, rgba.z)
    }

    /// Per-tier ring-band colors for the People-lens Saturn rings. Picks
    /// `tierCount` palette slots that are NOT assigned to any user account
    /// (and never the hub's own AccountColor), spreading the picks across
    /// the hue wheel so the four bands carry four perceptually distinct
    /// identities. Each slot's hue is desaturated so the rings stay muted
    /// against the vivid central planet — the spread gives the hues room
    /// to read even after the mute.
    ///
    /// Picking strategy: start at the `+3` correspondent-accent offset, then
    /// step by `count / tierCount` so the picks land roughly at the four
    /// quadrants of the hue wheel. If a quadrant slot is excluded (hub's
    /// own color or another active account), walk forward circularly until
    /// the first unused unvisited slot. This preserves the "anchor at +3"
    /// behaviour while ensuring the four picks span the wheel instead of
    /// crowding into a single adjacent run (which made every ring read as
    /// the same dusty pink at default mute levels).
    ///
    /// Falls back gracefully when the palette is saturated: after the stride
    /// pass exhausts unused slots, fills any remaining tiers with in-use
    /// slots (still excluding the hub's own color); after exhausting those
    /// too, cycles the already-picked indices. With a 12-slot palette and
    /// `tierCount = 4`, the first fallback only triggers when the user has
    /// ≥ 9 accounts simultaneously.
    public static func tierBandColorsRGB(
        forAccountColorIndex accountColorIndex: Int? = nil,
        usedAccountColorIndices: Set<Int> = [],
        tierCount: Int = 4,
        brightness: Double = 1.0,
        saturationFactor: Double = 0.45,
        saturationFloor: Double = 0.22
    ) -> [SIMD3<Float>] {
        let count = all.count
        guard count > 0, tierCount > 0 else { return [] }
        let baseIndex = color(forIndex: accountColorIndex).id
        let start = (baseIndex + correspondentAccentOffset) % count
        let sanitizedUsed = Set(usedAccountColorIndices.filter { all.indices.contains($0) })
        let preferredExcluded = sanitizedUsed.union([baseIndex])
        let stride = max(1, count / tierCount)

        var picked: [Int] = []
        var visited: Set<Int> = []

        // Stride pass — anchor each tier at a quadrant slot, then walk
        // forward circularly to skip excluded / already-claimed indices.
        // Quadrant anchoring is what gives the rings their hue spread; the
        // forward walk is just collision handling, so it stays correct
        // even when the user has multiple accounts occupying quadrant
        // slots.
        for tierIdx in 0..<tierCount {
            let anchor = (start + tierIdx * stride) % count
            for offset in 0..<count {
                let candidate = (anchor + offset) % count
                if visited.contains(candidate) { continue }
                if preferredExcluded.contains(candidate) { continue }
                picked.append(candidate)
                visited.insert(candidate)
                break
            }
        }

        if picked.count < tierCount {
            for offset in 0..<count {
                let candidate = (start + offset) % count
                if visited.contains(candidate) { continue }
                if candidate == baseIndex { continue }
                picked.append(candidate)
                visited.insert(candidate)
                if picked.count == tierCount { break }
            }
        }

        if !picked.isEmpty {
            var cycleIndex = 0
            while picked.count < tierCount {
                picked.append(picked[cycleIndex % picked.count])
                cycleIndex += 1
            }
        }

        return picked.map { index in
            let source = all[index]
            let muted = AccountColor(
                id: source.id,
                name: source.name,
                hue: source.hue,
                saturation: max(saturationFloor, source.saturation * saturationFactor)
            )
            let rgba = rgb(for: muted, brightness: brightness)
            return SIMD3<Float>(rgba.x, rgba.y, rgba.z)
        }
    }

    /// First palette index not present in `usedIndices`. Returns nil when the
    /// palette is exhausted; callers cycle (`% palette.count`) in that case.
    public static func firstUnusedIndex(in usedIndices: Set<Int>) -> Int? {
        all.indices.first(where: { !usedIndices.contains($0) })
    }

    /// Applies the Meaning-lens material transform to a palette colour.
    /// Rendered cluster bodies take their hue from `MeaningClusterLensPalette`
    /// (the fixed spectral ramp); this per-account variant remains for
    /// Meaning-lens node treatments that echo an account identity.
    ///
    /// To stay visually distinct from raw account-coloured nodes, the source
    /// hue is shifted lighter or darker depending on system appearance:
    ///
    /// - **Dark appearance**: hue stays at full saturation, brightness 1.0,
    ///   then mixed ~30% toward white. Reads as a brighter, paler shade of
    ///   the account hue against the dark constellation backdrop.
    /// - **Light appearance**: brightness drops to 0.55, saturation lifted
    ///   ~+0.10. Reads as a deeper, more saturated shade of the same hue
    ///   against a lighter backdrop.
    ///
    /// Stability contract: the result is a pure function of the source
    /// account-colour index and the appearance bit. Camera, lens, frame,
    /// hover, selection, and animation do not change it.
    public static func meaningLensRGB(
        forAccountColorIndex accountColorIndex: Int?,
        isDarkAppearance: Bool
    ) -> SIMD3<Float> {
        meaningLensRGB(for: color(forIndex: accountColorIndex), isDarkAppearance: isDarkAppearance)
    }

    fileprivate static func meaningLensRGB(
        for source: AccountColor,
        isDarkAppearance: Bool
    ) -> SIMD3<Float> {
        if isDarkAppearance {
            // Brighter, paler shade of the account hue.
            let rgba = rgb(for: source, brightness: 1.0)
            let lifted = SIMD3<Float>(
                rgba.x * 0.70 + 0.30,
                rgba.y * 0.70 + 0.30,
                rgba.z * 0.70 + 0.30
            )
            return lifted
        } else {
            // Deeper, more saturated shade of the same hue.
            let deeper = AccountColor(
                id: source.id,
                name: source.name,
                hue: source.hue,
                saturation: min(1.0, source.saturation + 0.10)
            )
            let rgba = rgb(for: deeper, brightness: 0.55)
            return SIMD3<Float>(rgba.x, rgba.y, rgba.z)
        }
    }

    /// Stamen-register fallback body color for the People solar system's
    /// sun: token-faithful stamen yellow on dark, a deeper amber on light
    /// so the body holds against the near-white field. Production suns use
    /// `personSunAccentRGB` (an unused palette slot via the `+3` system);
    /// this register remains the off-menu fallback when every candidate
    /// slot is claimed by an account or a hub accent (reachable with as
    /// few as 6 accounts whose accents cover the complement), so an
    /// exhausted walk can never make the sun impersonate an account.
    /// Petal red stays reserved for urgency.
    public static func personSunRGB(isDarkAppearance: Bool) -> SIMD3<Float> {
        isDarkAppearance
            ? SIMD3<Float>(0.976, 0.952, 0.360)
            : SIMD3<Float>(0.860, 0.620, 0.120)
    }

    /// Preferred palette slot for the People solar system's sun — Capella
    /// Gold, the palette's G-type golden star, so the sun defaults to the
    /// solar archetype (2026-07-04 decision).
    private static var personSunPreferredIndex: Int { 8 }

    /// Palette index for the People solar system's sun. Same mechanism as
    /// `correspondentAccentIndex` (the `+3` unused-slot system): prefer a
    /// fixed slot, then walk forward circularly until a slot no account
    /// owns. Account colors are excluded because the hub planet BODIES
    /// ride the raw AccountColor of their dominant account; the exclusion
    /// set additionally folds in every account's correspondent accent
    /// (`correspondentAccentIndex`) because that hue seeds the ring-band
    /// and tier-band materials around those planets (desaturated, but the
    /// same identity). Between the two, the sun can never share a hue with
    /// the planets orbiting it or their rings — differentiating the user's
    /// body from the correspondent orbs is the whole point. Returns `nil`
    /// when every candidate slot is claimed; RGB callers then fall back to
    /// the stamen register (`personSunRGB`).
    public static func personSunAccentIndex(
        usedAccountColorIndices: Set<Int>
    ) -> Int? {
        let count = all.count
        guard count > 0 else { return nil }
        let used = Set(usedAccountColorIndices.filter { all.indices.contains($0) })
        var excluded = used
        if used.isEmpty {
            // No accounts yet: hubs ride the default accent chain.
            excluded.insert(correspondentAccentIndex())
        } else {
            for accountIndex in used {
                excluded.insert(
                    correspondentAccentIndex(
                        forAccountColorIndex: accountIndex,
                        usedAccountColorIndices: used
                    )
                )
            }
        }
        let preferred = personSunPreferredIndex % count
        guard excluded.contains(preferred) else { return preferred }
        for offset in 1..<count {
            let candidate = (preferred + offset) % count
            if !excluded.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Body color for the People solar system's sun, drawn from the account
    /// palette via `personSunAccentIndex` and rendered in the sun's emissive
    /// register. The appearance transform generalizes the stamen fallback's
    /// effective HSV to any source hue: dark lifts the full-brightness hue
    /// ~22% toward white (a hot, whitened body against the void); light
    /// deepens it (saturation +0.20, brightness 0.82) so the body holds
    /// against the near-white field — the same relationship the fallback
    /// amber has to the fallback stamen.
    public static func personSunAccentRGB(
        usedAccountColorIndices: Set<Int>,
        isDarkAppearance: Bool
    ) -> SIMD3<Float> {
        guard let index = personSunAccentIndex(
            usedAccountColorIndices: usedAccountColorIndices
        ) else {
            return personSunRGB(isDarkAppearance: isDarkAppearance)
        }
        let source = all[index]
        if isDarkAppearance {
            let rgba = rgb(for: source, brightness: 1.0)
            return SIMD3<Float>(
                rgba.x * 0.78 + 0.22,
                rgba.y * 0.78 + 0.22,
                rgba.z * 0.78 + 0.22
            )
        }
        let deeper = AccountColor(
            id: source.id,
            name: source.name,
            hue: source.hue,
            saturation: min(1.0, source.saturation + 0.20)
        )
        let rgba = rgb(for: deeper, brightness: 0.82)
        return SIMD3<Float>(rgba.x, rgba.y, rgba.z)
    }

    /// Whisper line color for the engraved orbit paths and recency band
    /// guides — faint starlight on dark, faint ink on light. The whisper
    /// register itself (≈6–8% alpha) is applied shader-side.
    public static func personOrbitPathRGB(isDarkAppearance: Bool) -> SIMD3<Float> {
        isDarkAppearance
            ? SIMD3<Float>(0.62, 0.66, 0.74)
            : SIMD3<Float>(0.24, 0.26, 0.30)
    }

    /// Petal-red ember for the open-obligation rim on People planets —
    /// the design system's sanctioned state-of-message urgency accent
    /// (`OhiaColors.ohiaRed`), identical in both appearances.
    public static let personEmberRGB = SIMD3<Float>(0.910, 0.220, 0.220)

    /// Assignment helper: pick the next index for a brand-new account given
    /// the indices already in use. Falls back to wrap-around when all 12
    /// entries are taken (rare — Settings UI signals this case to the user
    /// so they can resolve duplicates manually).
    public static func nextIndex(after usedIndices: Set<Int>) -> Int {
        firstUnusedIndex(in: usedIndices) ?? (usedIndices.count % all.count)
    }

    /// Convert an `AccountColor` (hue+saturation) plus a brightness in `[0, 1]`
    /// into an RGBA SIMD4 with alpha = 1. Used by the constellation snapshot
    /// loader to produce per-message colors from the per-account hue.
    public static func rgb(for color: AccountColor, brightness: Double) -> SIMD4<Float> {
        hsvToRGB(hue: color.hue, saturation: color.saturation, brightness: brightness)
    }

    private static func hsvToRGB(
        hue: Double,
        saturation: Double,
        brightness: Double
    ) -> SIMD4<Float> {
        let h = (hue.truncatingRemainder(dividingBy: 1.0) + 1.0)
            .truncatingRemainder(dividingBy: 1.0)
        let s = max(0.0, min(1.0, saturation))
        let v = max(0.0, min(1.0, brightness))
        let c = v * s
        let x = c * (1.0 - abs((h * 6.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = v - c

        let rgb: SIMD3<Double>
        switch h * 6.0 {
        case 0..<1: rgb = SIMD3(c, x, 0)
        case 1..<2: rgb = SIMD3(x, c, 0)
        case 2..<3: rgb = SIMD3(0, c, x)
        case 3..<4: rgb = SIMD3(0, x, c)
        case 4..<5: rgb = SIMD3(x, 0, c)
        default:    rgb = SIMD3(c, 0, x)
        }
        return SIMD4<Float>(
            Float(rgb.x + m),
            Float(rgb.y + m),
            Float(rgb.z + m),
            1
        )
    }
}

/// Fixed Meaning-lens cluster ramp — "one spectrum, many temperatures"
/// (2026-07-21 decision). Five perceptually separated stops inside a single
/// blue → violet → rose spectral family, sampled from emission-nebula
/// photography. The top-ranked clusters take distinct stops; every other
/// cluster renders the anchor base, so distinct color stays a privilege of
/// the clusters that matter (mirroring the hub density-privilege curve).
///
/// Unlike the retired shared accent, the ramp is deliberately NOT drawn
/// from unassigned account-palette slots: the spectral family must hold
/// regardless of which hues accounts claim. The gas material (translucent,
/// noise-carved) plus the constrained family keep cluster bodies from
/// reading as account-owned even when an account hue lands nearby.
public struct MeaningClusterLensPalette: Sendable, Equatable {
    /// Anchor violet — identical to `stops[anchorStopIndex]`. Ambient
    /// clusters beyond the distinct-hue privilege render this, keeping the
    /// lens's historical violet identity.
    public let base: SIMD3<Float>
    /// The five resolved ramp stops in spectral order, blue → rose.
    public let stops: [SIMD3<Float>]

    /// How many clusters may hold distinct ramp hues at once. Beyond five,
    /// adjacent stops inside one spectral family stop being distinguishable
    /// and the field drifts toward the mishmash the design rules out.
    public static let distinctLimit = 5
    /// Ramp position of the anchor violet (the lens's historical hue).
    public static let anchorStopIndex = 2

    /// Hue/saturation stops in the `AccountColor` model so both appearances
    /// resolve through the same Meaning-lens material transform as the
    /// retired shared accent (dark: whitened full-brightness hue; light:
    /// deeper, more saturated shade).
    private static let rampStops: [AccountColor] = [
        AccountColor(id: -2, name: "Channel Blue", hue: 0.629, saturation: 0.60),
        AccountColor(id: -3, name: "Deep Indigo", hue: 0.685, saturation: 0.55),
        AccountColor(id: -4, name: "Anchor Violet", hue: 0.729, saturation: 0.56),
        AccountColor(id: -5, name: "Orchid", hue: 0.796, saturation: 0.55),
        AccountColor(id: -6, name: "Nebula Rose", hue: 0.909, saturation: 0.59),
    ]

    public init(base: SIMD3<Float>, stops: [SIMD3<Float>]) {
        self.base = base
        self.stops = stops
    }

    /// Resolve the ramp for the active system appearance. Pure function of
    /// the appearance bit — camera, lens, hover, selection, and animation
    /// never change it (same stability contract as `meaningLensRGB`).
    public static func resolve(isDarkAppearance: Bool) -> MeaningClusterLensPalette {
        let resolved = rampStops.map {
            AccountColorPalette.meaningLensRGB(for: $0, isDarkAppearance: isDarkAppearance)
        }
        return MeaningClusterLensPalette(base: resolved[anchorStopIndex], stops: resolved)
    }

    /// Ramp color for an assigned stop; the anchor base for `nil`
    /// (ambient clusters beyond the distinct-hue privilege).
    public func rgb(forStop stop: Int?) -> SIMD3<Float> {
        guard let stop, stops.indices.contains(stop) else { return base }
        return stops[stop]
    }

    /// Assign ramp stops to the top-ranked clusters.
    ///
    /// The first `distinctLimit` ids in `rankedClusterIds` (planner rank
    /// order, duplicates ignored) receive distinct stops; everyone else is
    /// absent from the result and renders `base`. Which stop each privileged
    /// cluster gets is keyed on stable cluster identity — the chosen ids are
    /// sorted and zipped against spectral-spread stop indices — so hue
    /// assignment is a pure function of the privileged *set*, and rank churn
    /// inside that set can never flicker a cluster's hue between frames.
    ///
    /// Fewer than five privileged clusters spread across the whole ramp
    /// (1 → anchor violet; 2 → blue + rose; 3 → blue + violet + rose;
    /// 4 → all but the anchor) so small fields get maximum separation.
    public static func stopAssignments(rankedClusterIds: [Int64]) -> [Int64: Int] {
        var seen = Set<Int64>()
        var chosen: [Int64] = []
        chosen.reserveCapacity(distinctLimit)
        for id in rankedClusterIds where seen.insert(id).inserted {
            chosen.append(id)
            if chosen.count == distinctLimit { break }
        }
        let sortedIds = chosen.sorted()
        let spread = spreadStopIndices(count: sortedIds.count)
        var assignments: [Int64: Int] = [:]
        assignments.reserveCapacity(sortedIds.count)
        for (id, stop) in zip(sortedIds, spread) {
            assignments[id] = stop
        }
        return assignments
    }

    /// Evenly spread stop indices for `count` privileged clusters, in
    /// ascending ramp order.
    private static func spreadStopIndices(count: Int) -> [Int] {
        switch count {
        case ..<1: return []
        case 1: return [anchorStopIndex]
        case 2: return [0, 4]
        case 3: return [0, anchorStopIndex, 4]
        case 4: return [0, 1, 3, 4]
        default: return [0, 1, 2, 3, 4]
        }
    }
}
