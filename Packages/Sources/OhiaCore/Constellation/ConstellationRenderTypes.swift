import Foundation
import CoreGraphics
import simd

public struct VectorRenderSourceRow: Sendable, Equatable {
    public let vectorId: Int64
    public let messageId: String
    public let collection: VectorCollection
    public let chunkIndex: Int
    public let layout: SIMD3<Float>
    public let arrivalTime: TimeInterval?
    public let lastMoveMagnitude: Float
    public let messageReceivedAt: TimeInterval?
    public let entityKind: EntityKind?
    public let entityScore: Float?

    public init(
        vectorId: Int64,
        messageId: String,
        collection: VectorCollection,
        chunkIndex: Int,
        layout: SIMD3<Float>,
        arrivalTime: TimeInterval? = nil,
        lastMoveMagnitude: Float = 0,
        messageReceivedAt: TimeInterval? = nil,
        entityKind: EntityKind? = nil,
        entityScore: Float? = nil
    ) {
        self.vectorId = vectorId
        self.messageId = messageId
        self.collection = collection
        self.chunkIndex = chunkIndex
        self.layout = layout
        self.arrivalTime = arrivalTime
        self.lastMoveMagnitude = lastMoveMagnitude
        self.messageReceivedAt = messageReceivedAt
        self.entityKind = entityKind
        self.entityScore = entityScore
    }

    public func withLayout(_ layout: SIMD3<Float>) -> VectorRenderSourceRow {
        VectorRenderSourceRow(
            vectorId: vectorId,
            messageId: messageId,
            collection: collection,
            chunkIndex: chunkIndex,
            layout: layout,
            arrivalTime: arrivalTime,
            lastMoveMagnitude: lastMoveMagnitude,
            messageReceivedAt: messageReceivedAt,
            entityKind: entityKind,
            entityScore: entityScore
        )
    }
}

public struct VisualSignalState: Sendable, Equatable {
    public var hover: Float
    public var selected: Float
    public var lockFocus: Float
    public var search: Float
    public var citation: Float
    public var practical: Float
    public var deletion: Float
    public var birth: Float

    public init(
        hover: Float = 0,
        selected: Float = 0,
        lockFocus: Float = 0,
        search: Float = 0,
        citation: Float = 0,
        practical: Float = 0,
        deletion: Float = 0,
        birth: Float = 0
    ) {
        self.hover = hover
        self.selected = selected
        self.lockFocus = lockFocus
        self.search = search
        self.citation = citation
        self.practical = practical
        self.deletion = deletion
        self.birth = birth
    }

    public static let none = VisualSignalState()

    public var intensity: Float {
        max(hover, selected, lockFocus, search, citation, practical, deletion, birth)
    }
}

public struct MessageStarInstance: Identifiable, Sendable, Equatable {
    public var id: String { messageId }
    public let messageId: String
    public let representativeVectorId: Int64
    public let position: SIMD3<Float>
    public let color: SIMD4<Float>
    public let radius: Float
    public let vectorCount: Int
    public let evidenceWeight: Float
    public let arrivalTime: TimeInterval
    public let lastMoveMagnitude: Float
    public let signal: VisualSignalState
    /// Glyph variant code consumed by the star fragment shader. `0` = filled
    /// dot (today's baseline); other values encode directional / state-ringed
    /// variants set by `FrameVisualLanguage.Glyph` in the planner.
    public let glyphCode: UInt8
    /// `FrameVisualLanguage.EmergeOnInteract.rawValue` baked per node so the
    /// shader can re-acquire suppressed channels when the node is hovered,
    /// locked, or search-matched.
    public let emergeMask: UInt8
    /// Pre-baked correspondent-major tint used by the renderer when the
    /// node emerges (`emergeMask` contains `.correspondentTint` AND a
    /// trigger bit is set). `SIMD3<Float>.zero` means "no tint" — renderer
    /// falls back to the base color in that case.
    public let defaultCorrespondentTint: SIMD3<Float>
    /// People-portrait background continuity flag. In a People focus
    /// portrait, background correspondents' ring satellites stay in the
    /// packet (so they never pop at the packet swap) but are tagged with
    /// this flag so the star shader fades them with the same
    /// `peopleContextDimPhase` uniform that recedes the background hub
    /// bodies and context ring bands — out during focus entry, back in
    /// during exit. `false` everywhere outside a People portrait.
    public let fadesWithPeopleContext: Bool
    /// Owning correspondent hub for a People-lens ring satellite. Nil for
    /// every star outside the People solar system. The renderer maps this
    /// to the hub's orbital displacement so ring satellites ride their
    /// planet as it orbits; satellites of the pinned (locked) hub map to
    /// the zero-displacement sentinel via the hub's nil orbit.
    public let peopleHubEmail: String?

    public init(
        messageId: String,
        representativeVectorId: Int64,
        position: SIMD3<Float>,
        color: SIMD4<Float>,
        radius: Float,
        vectorCount: Int,
        evidenceWeight: Float,
        arrivalTime: TimeInterval,
        lastMoveMagnitude: Float,
        signal: VisualSignalState,
        glyphCode: UInt8 = 0,
        emergeMask: UInt8 = 0,
        defaultCorrespondentTint: SIMD3<Float> = .zero,
        fadesWithPeopleContext: Bool = false,
        peopleHubEmail: String? = nil
    ) {
        self.messageId = messageId
        self.representativeVectorId = representativeVectorId
        self.position = position
        self.color = color
        self.radius = radius
        self.vectorCount = vectorCount
        self.evidenceWeight = evidenceWeight
        self.arrivalTime = arrivalTime
        self.lastMoveMagnitude = lastMoveMagnitude
        self.signal = signal
        self.glyphCode = glyphCode
        self.emergeMask = emergeMask
        self.defaultCorrespondentTint = defaultCorrespondentTint
        self.fadesWithPeopleContext = fadesWithPeopleContext
        self.peopleHubEmail = peopleHubEmail
    }

    /// Returns a copy of this instance with the radius scaled by
    /// `multiplier`, clamped to a safe rendering range. Used by the
    /// planner to apply frame-specific visual weight without disturbing
    /// any of the other instance fields (signal state, lock focus,
    /// glyph code, emerge channels). The clamp protects against
    /// pathological inputs collapsing nodes to invisibility or
    /// expanding them into the cluster halo zone.
    public func scalingRadius(by multiplier: Float) -> MessageStarInstance {
        // Floor low enough for the solar-scaled People ring moons
        // (0.0045 world units) — the locked portrait's footprint-fit
        // camera keeps them comfortably visible and clickable on screen.
        let scaled = max(0.002, min(0.040, radius * multiplier))
        return MessageStarInstance(
            messageId: messageId,
            representativeVectorId: representativeVectorId,
            position: position,
            color: color,
            radius: scaled,
            vectorCount: vectorCount,
            evidenceWeight: evidenceWeight,
            arrivalTime: arrivalTime,
            lastMoveMagnitude: lastMoveMagnitude,
            signal: signal,
            glyphCode: glyphCode,
            emergeMask: emergeMask,
            defaultCorrespondentTint: defaultCorrespondentTint,
            fadesWithPeopleContext: fadesWithPeopleContext,
            peopleHubEmail: peopleHubEmail
        )
    }

    public func withPosition(_ position: SIMD3<Float>) -> MessageStarInstance {
        MessageStarInstance(
            messageId: messageId,
            representativeVectorId: representativeVectorId,
            position: position,
            color: color,
            radius: radius,
            vectorCount: vectorCount,
            evidenceWeight: evidenceWeight,
            arrivalTime: arrivalTime,
            lastMoveMagnitude: lastMoveMagnitude,
            signal: signal,
            glyphCode: glyphCode,
            emergeMask: emergeMask,
            defaultCorrespondentTint: defaultCorrespondentTint,
            fadesWithPeopleContext: fadesWithPeopleContext,
            peopleHubEmail: peopleHubEmail
        )
    }

    public func withSignal(_ signal: VisualSignalState) -> MessageStarInstance {
        MessageStarInstance(
            messageId: messageId,
            representativeVectorId: representativeVectorId,
            position: position,
            color: color,
            radius: radius,
            vectorCount: vectorCount,
            evidenceWeight: evidenceWeight,
            arrivalTime: arrivalTime,
            lastMoveMagnitude: lastMoveMagnitude,
            signal: signal,
            glyphCode: glyphCode,
            emergeMask: emergeMask,
            defaultCorrespondentTint: defaultCorrespondentTint,
            fadesWithPeopleContext: fadesWithPeopleContext,
            peopleHubEmail: peopleHubEmail
        )
    }

    /// Marks this star as People-portrait background continuity geometry
    /// (see `fadesWithPeopleContext`). Used by `PeopleGraphBuilder` for the
    /// background correspondents' ring satellites in a focus portrait.
    public func withPeopleContextFade(_ fades: Bool) -> MessageStarInstance {
        MessageStarInstance(
            messageId: messageId,
            representativeVectorId: representativeVectorId,
            position: position,
            color: color,
            radius: radius,
            vectorCount: vectorCount,
            evidenceWeight: evidenceWeight,
            arrivalTime: arrivalTime,
            lastMoveMagnitude: lastMoveMagnitude,
            signal: signal,
            glyphCode: glyphCode,
            emergeMask: emergeMask,
            defaultCorrespondentTint: defaultCorrespondentTint,
            fadesWithPeopleContext: fades,
            peopleHubEmail: peopleHubEmail
        )
    }

    /// Attach (or clear) the owning People-lens hub for this satellite —
    /// see `peopleHubEmail`. Emitted by `PeopleGraphBuilder` when placing
    /// a message on a hub's ring in the solar-system layout.
    public func withPeopleHub(_ email: String?) -> MessageStarInstance {
        MessageStarInstance(
            messageId: messageId,
            representativeVectorId: representativeVectorId,
            position: position,
            color: color,
            radius: radius,
            vectorCount: vectorCount,
            evidenceWeight: evidenceWeight,
            arrivalTime: arrivalTime,
            lastMoveMagnitude: lastMoveMagnitude,
            signal: signal,
            glyphCode: glyphCode,
            emergeMask: emergeMask,
            defaultCorrespondentTint: defaultCorrespondentTint,
            fadesWithPeopleContext: fadesWithPeopleContext,
            peopleHubEmail: email
        )
    }

    /// Tier-aware ring-satellite appearance used by `PeopleGraphBuilder`
    /// after assigning a message to its People ring band. The
    /// returned star reads as a small satellite orbiting within the ring,
    /// not a luminous glyph stamped on top:
    ///   - Color is the account color heavily desaturated and mixed
    ///     toward `ringColor` so each satellite carries a faint hue of
    ///     its account against the surrounding band.
    ///   - `tier` controls size + base brightness from the per-tier shade
    ///     table on `PersonRingInstance.Tier`. The 4 People-lens tiers use
    ///     `PersonRingInstance.Tier.insideOutOrder` for geometry while
    ///     direct-correspondence satellites read as solid and CC'd ones as
    ///     dashed (`glyphCode` 2 or 3) for a per-node membership cue that
    ///     mirrors Projects' dashed-for-mention pattern.
    ///   - `lambert` is the cosine of the angle between the satellite's
    ///     radial direction (from hub center) and the planet shader's
    ///     virtual sun. The builder computes this once per satellite so
    ///     satellites on the lit side of the ring catch a small
    ///     brightening and those on the dark side stay muted — same
    ///     world-fixed light as the planet body, so ring + planet read
    ///     as one Saturn system.
    public func withRingSatelliteAppearance(
        ringColor: SIMD3<Float>,
        tier: PersonRingInstance.Tier,
        lambert: Float,
        radiusScale: Float = 1
    ) -> MessageStarInstance {
        // `ringColor` is the per-account ring accent — retained on the
        // signature for callers, but no longer used for the satellite
        // base tone under the Twilight schema. Each tier's color is
        // fixed in `Tier.tierColor`, so chip + ring band + satellite
        // all match regardless of which account the planet belongs to.
        // The message's own desaturated tint is still mixed in so each
        // satellite carries a faint cue of its individual color while
        // the dominant signal is the ring family.
        _ = ringColor
        let rgb = SIMD3<Float>(color.x, color.y, color.z)
        let gray = (rgb.x + rgb.y + rgb.z) / 3
        let desaturated = simd_mix(SIMD3<Float>(repeating: gray), rgb, SIMD3<Float>(repeating: 0.25))
        let ringTinted = simd_mix(tier.tierColor, desaturated, SIMD3<Float>(repeating: 0.40))

        let baseTierRadius: Float
        switch tier {
        case .sentDirect:
            baseTierRadius = 0.0090
        case .sentIncluded:
            baseTierRadius = 0.0078
        case .receivedDirect:
            baseTierRadius = 0.0200
        case .included:
            baseTierRadius = 0.0170
        }
        // Solar-system layouts shrink the whole Saturn system (planet,
        // bands, satellites) by one shared scale so the proportions the
        // tier sizes encode survive the reduction.
        let tierRadius = baseTierRadius * max(0.05, radiusScale)

        // Half-Lambert wrap (0.55..1.0) keeps the dark side legible while
        // still varying — point-satellites can't sustain a hard terminator
        // without disappearing into the ring.
        let lambertClamped = max(0, min(1, lambert * 0.5 + 0.5))
        let lightFactor: Float = 0.55 + 0.45 * lambertClamped
        let lit = ringTinted * lightFactor
        let tierAlpha = tier.satelliteAlpha

        // Included tiers overlay the dashed glyph variant on top of the
        // direction-only code the planner already baked. Direct tiers
        // pass `glyphCode` through unchanged so they still read as filled
        // (received) or hollow ring (sent).
        let tierGlyph: UInt8
        switch tier {
        case .sentDirect, .receivedDirect:
            tierGlyph = glyphCode
        case .sentIncluded:
            tierGlyph = 3 // hollow dashed
        case .included:
            tierGlyph = 2 // filled dashed
        }

        return MessageStarInstance(
            messageId: messageId,
            representativeVectorId: representativeVectorId,
            position: position,
            color: SIMD4<Float>(lit.x, lit.y, lit.z, tierAlpha),
            radius: tierRadius,
            vectorCount: vectorCount,
            evidenceWeight: evidenceWeight,
            arrivalTime: arrivalTime,
            lastMoveMagnitude: lastMoveMagnitude,
            signal: signal,
            glyphCode: tierGlyph,
            emergeMask: emergeMask,
            defaultCorrespondentTint: defaultCorrespondentTint,
            fadesWithPeopleContext: fadesWithPeopleContext,
            peopleHubEmail: peopleHubEmail
        )
    }
}

public enum MessageStarPositionMode: Sendable {
    /// Place the message at the evidence-weighted centroid of its summary,
    /// body chunks, and attachments. This remains the default presentation
    /// for lenses that benefit from the whole message evidence footprint.
    case evidenceWeighted
    /// Place the message at its context-summary vector. Meaning clustering
    /// uses that same vector, so this mode keeps the rendered dot and its
    /// semantic-cluster membership in one coordinate system.
    case contextSummary
}

public struct MessageSatelliteInstance: Identifiable, Sendable, Equatable {
    public var id: Int64 { vectorId }
    public let vectorId: Int64
    public let parentMessageId: String
    public let position: SIMD3<Float>
    public let color: SIMD4<Float>
    public let radius: Float
    public let signal: VisualSignalState

    public init(
        vectorId: Int64,
        parentMessageId: String,
        position: SIMD3<Float>,
        color: SIMD4<Float>,
        radius: Float,
        signal: VisualSignalState
    ) {
        self.vectorId = vectorId
        self.parentMessageId = parentMessageId
        self.position = position
        self.color = color
        self.radius = radius
        self.signal = signal
    }
}

public struct SemanticNebulaInstance: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let position: SIMD3<Float>
    public let color: SIMD4<Float>
    public let radius: Float
    public let density: Float
    public let memberCount: Int
    public let representativeVectorId: Int64
    /// FNV-1a hash of an optional dominant semantic label across cluster
    /// members. `0` means no label assigned. This is retained for legacy
    /// arc-halo annotation; the current Projects workspace does not consume
    /// Metal nebula labels.
    public let labelHash: UInt32
    /// Secondary majority label hash for nested-aspect rendering. `0` means
    /// no sub-cluster of the threshold size. Renders as a thin inner ring
    /// in the halo fragment when non-zero.
    public let nestedSubclusterHash: UInt32
    /// True for the top-N largest clusters in legacy arc-label packets.
    /// `ConstellationRenderPacket.arcLabels` is keyed by these clusters.
    public let isTopCluster: Bool

    public init(
        id: Int64,
        position: SIMD3<Float>,
        color: SIMD4<Float>,
        radius: Float,
        density: Float,
        memberCount: Int,
        representativeVectorId: Int64,
        labelHash: UInt32 = 0,
        nestedSubclusterHash: UInt32 = 0,
        isTopCluster: Bool = false
    ) {
        self.id = id
        self.position = position
        self.color = color
        self.radius = radius
        self.density = density
        self.memberCount = memberCount
        self.representativeVectorId = representativeVectorId
        self.labelHash = labelHash
        self.nestedSubclusterHash = nestedSubclusterHash
        self.isTopCluster = isTopCluster
    }
}

/// Meaning-lens terrain field derived from canonical project/team/topic labels,
/// with canonical classification facets allowed as weak fallback fields.
/// Unlike `SemanticNebulaInstance`, which aggregates hidden visual density by
/// grid cell, these fields describe semantic density among visible messages.
public struct SemanticDensityFieldInstance: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let canonicalKey: String
    public let label: String
    public let kind: SemanticEdgeReasonKind
    public let position: SIMD3<Float>
    public let color: SIMD4<Float>
    public let radius: Float
    public let density: Float
    public let strength: Float
    public let memberCount: Int
    public let labelHash: UInt32

    public init(
        id: Int64,
        canonicalKey: String,
        label: String,
        kind: SemanticEdgeReasonKind,
        position: SIMD3<Float>,
        color: SIMD4<Float>,
        radius: Float,
        density: Float,
        strength: Float,
        memberCount: Int,
        labelHash: UInt32
    ) {
        self.id = id
        self.canonicalKey = canonicalKey
        self.label = label
        self.kind = kind
        self.position = position
        self.color = color
        self.radius = radius
        self.density = max(0, min(1, density))
        self.strength = max(0, min(1, strength))
        self.memberCount = memberCount
        self.labelHash = labelHash
    }
}

public struct AffinityFiberInstance: Identifiable, Sendable, Equatable {
    public var id: String { "\(sourceMessageId):\(targetMessageId)" }
    public let sourceMessageId: String
    public let targetMessageId: String
    public let sourceVectorId: Int64
    public let targetVectorId: Int64
    public let from: SIMD3<Float>
    public let to: SIMD3<Float>
    public let strength: Float
    public let confidence: Float
    public let strokeWidthPixels: Float
    public let signal: VisualSignalState
    /// Meaning-lens explanation for why this fiber exists. Nil keeps legacy
    /// behaviour for cosine, thread, people, timeline, attention, and project
    /// fibers.
    public let semanticReason: SemanticEdgeReason?
    /// Which edge builder produced this fibre. Drives the per-kind tint
    /// table in the fiber fragment shader and the `.conversations` frame's
    /// selective filtering (keep only `.thread`). `nil` falls through to
    /// today's cosine-blue rendering.
    public let edgeKind: VectorEdgeKind?
    /// Optional Meaning-lens tint for a semantic relationship.
    /// Nil preserves the established per-kind fibre palette exactly.
    public let presentationColor: SIMD4<Float>?

    public init(
        sourceMessageId: String,
        targetMessageId: String,
        sourceVectorId: Int64,
        targetVectorId: Int64,
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        strength: Float,
        confidence: Float,
        strokeWidthPixels: Float = 1.0,
        signal: VisualSignalState = .none,
        semanticReason: SemanticEdgeReason? = nil,
        edgeKind: VectorEdgeKind? = nil,
        presentationColor: SIMD4<Float>? = nil
    ) {
        self.sourceMessageId = sourceMessageId
        self.targetMessageId = targetMessageId
        self.sourceVectorId = sourceVectorId
        self.targetVectorId = targetVectorId
        self.from = from
        self.to = to
        self.strength = strength
        self.confidence = confidence
        self.strokeWidthPixels = strokeWidthPixels
        self.signal = signal
        self.semanticReason = semanticReason
        self.edgeKind = edgeKind
        self.presentationColor = presentationColor
    }
}

/// One floating cluster label for legacy Metal arc annotations. Emitted by
/// the planner only when the cluster crosses size + confidence thresholds and
/// the frame's `ArcHaloPresence` requests labels. Rendered by SwiftUI on top
/// of the Metal scene via `ScreenProjection.project(...)` - no Metal text
/// rendering. Capped at a small number of records per packet. The current
/// Projects correspondence workspace does not render from this packet field.
///
/// Conforms to `Identifiable` so SwiftUI's `ForEach` can track labels by
/// their cluster rather than by array index. When the planner emits the
/// same cluster label in a different position across consecutive packets,
/// SwiftUI treats it as the same view and animates the move; when two
/// clusters happen to share the same label, their ids remain distinct.
public struct ArcLabelOverlay: Sendable, Equatable, Identifiable {
    /// Stable cluster identity from the nebula cell that produced this label.
    /// Multiple top clusters can share the same human label, so SwiftUI
    /// identity must include the cluster, not just the text.
    public let clusterId: Int64
    /// World-space centroid of the cluster.
    public let position: SIMD3<Float>
    /// Human-readable label string (project / team / topic name).
    public let text: String
    /// Pre-baked tint matching the cluster's halo so the floating pill and
    /// the underlying nebula read as one identity. RGB only; alpha
    /// controlled by the SwiftUI overlay style.
    public let tint: SIMD3<Float>
    /// Cluster member count, used by SwiftUI overlay layout for label
    /// priority and to skip labels on shrinking clusters.
    public let memberCount: Int

    /// Stable identity for SwiftUI ForEach. Includes the cluster id because
    /// the same project/team/topic label can appear in two visible top
    /// clusters at once.
    public var id: String { "\(clusterId):\(text.lowercased())" }

    public init(
        clusterId: Int64 = 0,
        position: SIMD3<Float>,
        text: String,
        tint: SIMD3<Float>,
        memberCount: Int
    ) {
        self.clusterId = clusterId
        self.position = position
        self.text = text
        self.tint = tint
        self.memberCount = memberCount
    }
}

public struct HitProxy: Sendable, Equatable {
    public let messageId: String
    public let vectorId: Int64
    public let worldPosition: SIMD3<Float>
    public let radiusPixels: Float

    public init(messageId: String, vectorId: Int64, worldPosition: SIMD3<Float>, radiusPixels: Float) {
        self.messageId = messageId
        self.vectorId = vectorId
        self.worldPosition = worldPosition
        self.radiusPixels = radiusPixels
    }
}

public struct PersonHubInstance: Identifiable, Sendable, Equatable {
    /// Per-tier ring geometry for the People-lens Saturn portrait. Each
    /// entry carries the world-space mid-line radius and band thickness
    /// for one tier. Empty tiers (no messages in that bucket on this hub)
    /// are filtered upstream so this array never holds zero-radius
    /// placeholders — its `count` is the number of rendered rings.
    public struct RingGeometry: Sendable, Equatable {
        public let tier: PersonRingInstance.Tier
        /// Mid-line radius of the ring band in world units.
        public let radius: Float
        /// Half-width band thickness. Scaled per-hub from this tier's
        /// share of the hub's total message footprint (linear, capped
        /// 0.004–0.034 in world units).
        public let thickness: Float

        public init(tier: PersonRingInstance.Tier, radius: Float, thickness: Float) {
            self.tier = tier
            self.radius = max(0, radius)
            self.thickness = max(0, thickness)
        }
    }

    public var id: String { email }
    public let email: String
    public let displayName: String
    public let position: SIMD3<Float>
    public let radius: Float
    public let sentCount: Int
    public let receivedCount: Int
    /// Count of messages where this correspondent appears as a non-sender
    /// recipient on a third-party email (someone else sent the row; both the
    /// user and this correspondent are on the To/Cc line). Together,
    /// `sentCount + receivedCount + appearanceCount` is the hub's total
    /// message footprint in scope.
    public let appearanceCount: Int
    public let reciprocalScore: Float
    /// Calendar recency in [0, 1] — 1.0 = interaction within the last day,
    /// decays exponentially toward 0 as the latest interaction recedes.
    /// Calibrated against the hover card's freshness tiers (active ≤ 7d,
    /// recent ≤ 30d, fading ≤ 90d, quiet ≤ 365d, dormant 365+). Renderer
    /// uses this to dim the planet body so big-but-dormant relationships
    /// read as exactly that — large in history, quiet in the present —
    /// while small-but-active ones read as small-but-bright.
    public let recencyScore: Float
    public let isInstitutional: Bool
    public let color: SIMD3<Float>
    public let representativeMessageId: String?
    public let representativeVectorId: Int64?
    public let messageIds: Set<String>
    /// Extra planet radiance for isolated focus portraits. Default zero so
    /// ordinary People-lens hubs keep their quieter recency-driven material.
    public let focusGlow: Float
    /// Brightness multiplier in [0, 1] applied to the planet body. Default
    /// 1.0 (full). The People-lens focus portrait drops the *unfocused*
    /// correspondent hubs to a fraction of this so the surrounding galaxy
    /// reads as a dimmed backdrop behind the focused Saturn — the People
    /// analogue of the Meanings lens's field dim. The focused hub (and any
    /// hubs that still carry rings) stay at 1.0.
    public let contextDim: Float
    /// Event-horizon deletion progress in [0, 1]. Normal hubs stay at 0;
    /// People-lens delete ghosts advance toward 1 while their final
    /// correspondent planet collapses out of the render packet.
    public let deletionProgress: Float
    /// Per-tier ring geometry. Sorted by `Tier.insideOutOrder` so
    /// iteration matches inner → outer ring order. Empty when the hub has no
    /// ring messages (e.g. a one-message stat-only hub with no
    /// non-user participants in scope).
    public let rings: [RingGeometry]
    /// Unit-length normal of the ring plane in world space. Drives Saturn-
    /// style tilt; the renderer derives two orthogonal in-plane vectors from
    /// it to build the ring's billboard quad.
    public let ringNormal: SIMD3<Float>
    /// Keplerian orbit this hub rides in the People solar-system layout.
    /// `position` is the orbit evaluated at the packet's orbital epoch
    /// (see `PersonSunInstance.orbitalEpoch`); the renderer displaces the
    /// hub per frame by `position(orbit, now) − position(orbit, epoch)`.
    /// Nil for hubs that must stay exactly where the packet placed them —
    /// the locked/pinned focus hub, and every hub in legacy non-solar
    /// packets — which is what keeps overlays, telemetry, and pick
    /// geometry correct without displacement translation.
    public let orbit: PersonOrbit?
    /// Age-weighted open-obligation urgency in [0, 1] — carried on the hub
    /// (not only on the orbit) so the petal-red ember rim survives on
    /// pinned/locked hubs whose orbit is nil.
    public let obligationUrgency: Float

    /// Outermost ring radius — drives camera framing, planet-collision
    /// clearance in the force solver, and the locked-hub footprint. Zero
    /// when `rings` is empty.
    public var maxRingRadius: Float {
        rings.map(\.radius).max() ?? 0
    }

    /// World-space radius for a specific tier, or 0 when the hub has no
    /// ring messages in that tier. Convenience for renderer paths that
    /// need to reach for a known tier by name (e.g. the empty-locked-
    /// focus stub).
    public func ringRadius(for tier: PersonRingInstance.Tier) -> Float {
        rings.first { $0.tier == tier }?.radius ?? 0
    }

    public init(
        email: String,
        displayName: String,
        position: SIMD3<Float>,
        radius: Float,
        sentCount: Int,
        receivedCount: Int,
        appearanceCount: Int = 0,
        reciprocalScore: Float,
        recencyScore: Float = 0,
        isInstitutional: Bool,
        color: SIMD3<Float> = AccountColorPalette.correspondentAccentRGB(),
        representativeMessageId: String? = nil,
        representativeVectorId: Int64? = nil,
        messageIds: Set<String> = [],
        focusGlow: Float = 0,
        contextDim: Float = 1,
        deletionProgress: Float = 0,
        rings: [RingGeometry] = [],
        ringNormal: SIMD3<Float> = SIMD3<Float>(0, 0, 1),
        orbit: PersonOrbit? = nil,
        obligationUrgency: Float = 0
    ) {
        self.email = email
        self.displayName = displayName
        self.position = position
        self.radius = radius
        self.sentCount = sentCount
        self.receivedCount = receivedCount
        self.appearanceCount = appearanceCount
        self.reciprocalScore = reciprocalScore
        self.recencyScore = max(0, min(1, recencyScore))
        self.isInstitutional = isInstitutional
        self.color = color
        self.representativeMessageId = representativeMessageId
        self.representativeVectorId = representativeVectorId
        self.messageIds = messageIds
        self.focusGlow = max(0, min(1, focusGlow))
        self.contextDim = max(0, min(1, contextDim))
        self.deletionProgress = max(0, min(1, deletionProgress))
        self.orbit = orbit
        self.obligationUrgency = max(0, min(1, obligationUrgency))
        self.rings = rings
            .filter { $0.radius > 0 }
            .sorted { $0.tier.insideOutIndex < $1.tier.insideOutIndex }
        let n = simd_length(ringNormal)
        self.ringNormal = n > 0.0001 ? ringNormal / n : SIMD3<Float>(0, 0, 1)
    }
}

/// One semantic-cluster landmark for the Meaning lens. Unlike the message
/// stars, this is not an email node; it is a hoverable handle for a cluster's
/// meaning metadata and should render only when the active spatial lens is
/// `.meaning`.
public struct MeaningClusterHubInstance: Identifiable, Sendable, Equatable {
    /// Hit-proxy message-id namespace for Meaning-cluster hubs. Shared by
    /// the planner (which mints the proxies), the renderer (Option-held
    /// cluster-only picking), and the mode view (click/hover routing) so
    /// the three can never drift.
    public static let hitProxyMessageIdPrefix = "meaningCluster:"

    public static func hitProxyMessageId(clusterId: Int64) -> String {
        hitProxyMessageIdPrefix + String(clusterId)
    }

    public var id: Int64 { clusterId }
    public let clusterId: Int64
    public let position: SIMD3<Float>
    /// Transparent cluster envelope radius. This should cover the visible
    /// member stars for the semantic cluster rather than merely marking a
    /// local density peak.
    public let radius: Float
    /// Distinct hoverable centre marker radius. Kept separate from `radius`
    /// so broad semantic fields can have a large translucent reach without
    /// turning the centre point into a giant opaque body.
    public let coreRadius: Float
    public let memberCount: Int
    public let color: SIMD3<Float>
    public let density: Float
    /// Weighted member positions for the metaball cluster body. Every
    /// visible cluster member contributes, with `affinity` carrying its
    /// persisted cluster-attachment weight (Leiden attachment for Meaning
    /// clusters; 1.0 for legacy rows). The Metal renderer
    /// aggregates these into detailed blobs plus one connected envelope field,
    /// so the visible body contains every member without dropping periphery.
    /// The hover anchor is the hub's persisted full-cluster medoid.
    public let memberHalos: [MeaningClusterMemberHalo]
    /// Earliest and latest received date among the visible members that
    /// carry one; `nil` when none does. Presentation only — the renderer
    /// never reads it.
    public let receivedDateRange: ClosedRange<Date>?

    public init(
        clusterId: Int64,
        position: SIMD3<Float>,
        radius: Float,
        coreRadius: Float? = nil,
        memberCount: Int,
        color: SIMD3<Float>,
        density: Float = 0,
        memberHalos: [MeaningClusterMemberHalo] = [],
        receivedDateRange: ClosedRange<Date>? = nil
    ) {
        self.clusterId = clusterId
        self.position = position
        self.radius = max(0.001, radius)
        self.coreRadius = max(0.001, coreRadius ?? min(max(0.012, radius * 0.32), 0.032))
        self.memberCount = max(0, memberCount)
        self.color = color
        self.density = max(0, min(1, density))
        self.memberHalos = memberHalos
        self.receivedDateRange = receivedDateRange
    }
}

/// One halo around a visible member of a Meaning-lens cluster.
/// `affinity` is the member's persisted cluster-attachment weight in
/// (0, 1] — the Leiden attachment strength for Meaning clusters, 1.0 for
/// rows written before weights existed. The renderer
/// scales each member's field contribution by this value so
/// strongly-attached members carry more of the cluster's visible mass.
public struct MeaningClusterMemberHalo: Sendable, Equatable {
    public let position: SIMD3<Float>
    public let affinity: Float

    public init(position: SIMD3<Float>, affinity: Float) {
        self.position = position
        self.affinity = max(0, min(1, affinity))
    }
}

/// One Saturn-style ring band for a correspondent hub. The renderer expands
/// each instance into a world-oriented quad in the ring's plane and discards
/// pixels outside the annulus, so the ring reads as a tilted elliptical band
/// when the camera is off-axis. Emitted only in the `.people` lens; empty in
/// every other frame.
public struct PersonRingInstance: Identifiable, Sendable, Equatable {
    /// The 4 People-lens ring tiers. `insideOutOrder` encodes the visual
    /// ring layering; raw values remain stable renderer/material ids. Each
    /// tier carries a shade pair (brightness + alpha) that the builder
    /// applies to the per-account hub color so the rings read as 4 shades
    /// of one AccountColor — direct correspondence solid and bright,
    /// included correspondence dimmer and translucent.
    public enum Tier: UInt8, Sendable, Equatable, CaseIterable {
        /// Messages the user sent and where the hub is on the To: line
        /// (the user wrote *to* this person directly). Raw value is a
        /// stable renderer/material id — visual ring layering is set by
        /// `insideOutOrder`, not by the raw value.
        case sentDirect = 0
        /// Messages the user sent and where the hub is on the Cc: / Bcc:
        /// line alongside someone else (the user included this person on
        /// outbound thread, but the primary recipient was elsewhere).
        case sentIncluded = 1
        /// Messages the user received where the hub is the sender
        /// (the hub wrote to the user directly).
        case receivedDirect = 2
        /// Messages the user received where the hub is just a
        /// co-recipient alongside the user (someone else wrote to both;
        /// the hub was included on inbound thread without being the
        /// originator).
        case included = 3

        /// Visual ring layering, innermost → outermost. Received tiers
        /// sit closest to the hub planet (inbound mail at the body),
        /// sent tiers sit further out (outbound mail radiating away).
        /// Within each pair the "direct" tier sits inside the "included"
        /// tier — direct correspondence is closer to the planet than
        /// peripheral inclusion. Same array drives the SurveyTelemetry
        /// chip order, the annotation Tab order, and the dial-wedge
        /// stacking, so the user reads the chip strip left-to-right as a
        /// legend for the rings inside-to-outside.
        public static let insideOutOrder: [Tier] = [
            .receivedDirect,
            .included,
            .sentDirect,
            .sentIncluded
        ]

        public var insideOutIndex: Int {
            Self.insideOutOrder.firstIndex(of: self) ?? Self.insideOutOrder.count
        }

        /// Fixed sRGB triple for this tier's ring band — Twilight
        /// schema: peach, dusty rose, slate-blue, and midnight slate
        /// assigned by semantic tier. The arc keeps the muted-sunset
        /// progression (warm → cool → dark) without the purple plum tone
        /// the received band previously carried. The colors are independent
        /// of the per-account ring color (the central planet body still
        /// carries the AccountColor); the rings carry a consistent
        /// planetary-ring vocabulary regardless of account. The same triple
        /// is reused by the chip in the SurveyTelemetryStrip and the
        /// satellite base tone so chip + ring + satellite all match.
        public var tierColor: SIMD3<Float> {
            switch self {
            case .sentDirect:
                return SIMD3<Float>(0.788, 0.596, 0.518)
            case .sentIncluded:
                return SIMD3<Float>(0.655, 0.482, 0.522)
            case .receivedDirect:
                return SIMD3<Float>(0.420, 0.500, 0.555)
            case .included:
                return SIMD3<Float>(0.239, 0.263, 0.376)
            }
        }

        /// Base alpha for the ring band — combined with the fragment
        /// shader's gaussian envelope inside `PersonRingInstance.init`.
        /// Direct tiers stay opaque so the band reads solid; included
        /// tiers run translucent so they read as peripheral dust at
        /// galaxy zoom.
        public var ringAlpha: Float {
            switch self {
            case .sentDirect:     return 1.00
            case .receivedDirect: return 1.00
            case .sentIncluded:   return 0.85
            case .included:       return 0.75
            }
        }

        /// Alpha for individual ring satellites. Slightly lifted
        /// relative to the ring band's alpha so the satellite dot
        /// itself reads through the band's gaussian envelope.
        public var satelliteAlpha: Float {
            switch self {
            case .sentDirect: return 0.98
            case .receivedDirect: return 0.96
            case .sentIncluded: return 0.85
            case .included: return 0.78
            }
        }

        /// Map a message to the People-lens ring tier it would land on
        /// for the supplied hub email. Returns `nil` when the hub isn't
        /// a participant on the row (so callers can skip rendering a
        /// tier label for emails that aren't actually on this hub's
        /// rings). This is the canonical classifier — `PeopleGraphBuilder`
        /// and the locked-overlay hover both route through it so the
        /// rendered ring and the hover label can never disagree. The
        /// signature uses primitive fields (rather than a single
        /// `MessageFilterRow`) because that type lives in the app
        /// target; OhiaCore stays decoupled from the row schema.
        nonisolated public static func classify(
            isSentByUser: Bool,
            fromAddress: String,
            toAddresses: [String],
            recipientAddresses: [String],
            hubEmail: String
        ) -> Tier? {
            let normalizedHub = Self.normalizeEmail(hubEmail)
            guard !normalizedHub.isEmpty else { return nil }
            if isSentByUser {
                let allRecipients = Set(recipientAddresses.map(Self.normalizeEmail))
                guard allRecipients.contains(normalizedHub) else { return nil }
                let primaryTo = Set(toAddresses.map(Self.normalizeEmail))
                if primaryTo.isEmpty || primaryTo.contains(normalizedHub) {
                    return .sentDirect
                }
                return .sentIncluded
            }
            if Self.normalizeEmail(fromAddress) == normalizedHub {
                return .receivedDirect
            }
            let allRecipients = Set(recipientAddresses.map(Self.normalizeEmail))
            guard allRecipients.contains(normalizedHub) else { return nil }
            return .included
        }

        /// Terse two-word label rendered as the People-lens hover popup's
        /// top line. Direction word + qualifier — "direct" for primary
        /// To:/From: counterparts, "cc'd" for peripheral Cc:/Bcc:
        /// involvement. Fits the popup's first-line slot at any
        /// reasonable width and reads as a tag rather than a sentence.
        public var hoverDirectionLabel: String {
            switch self {
            case .sentDirect: return "sent direct"
            case .sentIncluded: return "sent cc'd"
            case .receivedDirect: return "received direct"
            case .included: return "received cc'd"
            }
        }

        /// SF Symbol matching the tier's role in the People system.
        /// Outline paperplane for the sent·included variant disambiguates
        /// it from the filled sent·direct paperplane.
        public var directionSymbolName: String {
            switch self {
            case .sentDirect: return "paperplane.fill"
            case .sentIncluded: return "paperplane"
            case .receivedDirect: return "tray.and.arrow.down"
            case .included: return "person.2.fill"
            }
        }

        nonisolated private static func normalizeEmail(_ value: String) -> String {
            var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.hasPrefix("mailto:") {
                trimmed.removeFirst("mailto:".count)
            }
            return trimmed
        }

        /// Short human-readable label used in debug overlays / accessibility.
        /// Cc/Bcc tiers read as "cc'd" to match the hover popup's
        /// `hoverDirectionLabel` and the People annotation chips.
        public var label: String {
            switch self {
            case .sentDirect: return "sent"
            case .sentIncluded: return "sent · cc'd"
            case .receivedDirect: return "received"
            case .included: return "cc'd"
            }
        }
    }

    public var id: String {
        let arcKey: String
        if arcEndFraction > 0 {
            arcKey = "#arc\(Int(arcStartFraction * 10_000))-\(Int(arcEndFraction * 10_000))"
        } else {
            arcKey = ""
        }
        return "\(email)#\(tier.rawValue)\(radialGlow ? "#glow" : "")\(fadesWithPeopleContext ? "#context" : "")\(arcKey)"
    }
    public let email: String
    public let center: SIMD3<Float>
    /// Mid-line radius of the ring band in world units.
    public let radius: Float
    /// Half-width of the ring band in world units. The fragment shader fades
    /// alpha at the inner and outer edges of `radius ± thickness`.
    public let thickness: Float
    /// Unit-length normal of the ring plane.
    public let normal: SIMD3<Float>
    public let color: SIMD3<Float>
    /// Hub's AccountColor. The Twilight tier tone stays the band base;
    /// focused People overlays use this hue as an inner radiance so the
    /// central orb's light reaches into the rings without filling the
    /// Cassini gaps.
    public let accountColor: SIMD3<Float>
    public let alpha: Float
    public let tier: Tier
    /// When `true`, the fragment shader overlays a clockwise-traveling
    /// bright sweep on the band's center line — used in the People
    /// lens's locked-node overlay so the focused correspondent's
    /// rings read as "live" against the dimmed galaxy underneath.
    /// Default `false` so the galaxy view's rings stay still.
    public let shimmer: Bool
    /// Broad AccountColor light field emitted by a locked correspondent
    /// planet before the first ring band. Rendered with a separate shader
    /// branch so it has no center spine and does not count as a semantic tier.
    public let radialGlow: Bool
    /// Optional normalized angular slice for this ring. `arcEndFraction == 0`
    /// means a full annulus; otherwise the fragment shader discards pixels
    /// outside `[arcStartFraction, arcEndFraction]` around the ring. People
    /// account color must remain on the correspondent orb; semantic People
    /// rings are reserved for relationship tiers.
    public let arcStartFraction: Float
    public let arcEndFraction: Float
    /// Transition-only context rings in the People locked-correspondent
    /// portrait fade with the same phase as the surrounding dimmed hubs. This
    /// keeps entry/exit continuous while allowing the settled focused portrait
    /// to remain visually quiet.
    public let fadesWithPeopleContext: Bool
    /// Event-horizon deletion progress in [0, 1] for a final correspondent
    /// hub's dying ring bands. Settled rings keep this at 0.
    public let deletionProgress: Float

    public init(
        email: String,
        center: SIMD3<Float>,
        radius: Float,
        thickness: Float,
        normal: SIMD3<Float>,
        color: SIMD3<Float>,
        accountColor: SIMD3<Float>? = nil,
        alpha: Float,
        tier: Tier,
        shimmer: Bool = false,
        radialGlow: Bool = false,
        arcStartFraction: Float = 0,
        arcEndFraction: Float = 0,
        fadesWithPeopleContext: Bool = false,
        deletionProgress: Float = 0
    ) {
        self.email = email
        self.center = center
        self.radius = max(0.0001, radius)
        self.thickness = max(0.0001, thickness)
        let n = simd_length(normal)
        self.normal = n > 0.0001 ? normal / n : SIMD3<Float>(0, 0, 1)
        self.color = color
        self.accountColor = accountColor ?? color
        self.alpha = max(0, min(1, alpha))
        self.tier = tier
        self.shimmer = shimmer
        self.radialGlow = radialGlow
        self.arcStartFraction = max(0, min(1, arcStartFraction))
        self.arcEndFraction = max(0, min(1, arcEndFraction))
        self.fadesWithPeopleContext = fadesWithPeopleContext
        self.deletionProgress = max(0, min(1, deletionProgress))
    }
}

/// Legacy satellite dot orbiting a multi-recipient message star. The main
/// People lens no longer emits these now that included correspondence has a
/// discrete ring; the type remains so older packets/tests can still model the
/// renderer's optional atom buffer.
public struct PersonAtomInstance: Identifiable, Sendable, Equatable {
    public var id: String { "\(parentMessageId)@\(hubEmail)#\(seed)" }
    public let parentMessageId: String
    public let hubEmail: String
    public let position: SIMD3<Float>
    public let color: SIMD4<Float>
    public let radius: Float
    /// Stable per-satellite seed so the renderer can vary phase between
    /// satellites within the same atom without collision.
    public let seed: UInt8

    public init(
        parentMessageId: String,
        hubEmail: String,
        position: SIMD3<Float>,
        color: SIMD4<Float>,
        radius: Float,
        seed: UInt8
    ) {
        self.parentMessageId = parentMessageId
        self.hubEmail = hubEmail
        self.position = position
        self.color = color
        self.radius = radius
        self.seed = seed
    }
}

public struct PersonRelationInstance: Identifiable, Sendable, Equatable {
    public var id: String { "\(sourceEmail)|\(targetEmail)" }
    public let sourceEmail: String
    public let targetEmail: String
    public let sourcePosition: SIMD3<Float>
    public let targetPosition: SIMD3<Float>
    public let sharedMessageCount: Int
    public let dilutedStrength: Float

    public init(
        sourceEmail: String,
        targetEmail: String,
        sourcePosition: SIMD3<Float>,
        targetPosition: SIMD3<Float>,
        sharedMessageCount: Int,
        dilutedStrength: Float
    ) {
        if sourceEmail <= targetEmail {
            self.sourceEmail = sourceEmail
            self.targetEmail = targetEmail
            self.sourcePosition = sourcePosition
            self.targetPosition = targetPosition
        } else {
            self.sourceEmail = targetEmail
            self.targetEmail = sourceEmail
            self.sourcePosition = targetPosition
            self.targetPosition = sourcePosition
        }
        self.sharedMessageCount = sharedMessageCount
        self.dilutedStrength = dilutedStrength
    }
}

public struct PersonHitProxy: Sendable, Equatable {
    public let email: String
    public let displayName: String
    public let worldPosition: SIMD3<Float>
    public let radiusPixels: Float
    public let representativeMessageId: String?
    public let representativeVectorId: Int64?

    public init(
        email: String,
        displayName: String,
        worldPosition: SIMD3<Float>,
        radiusPixels: Float,
        representativeMessageId: String? = nil,
        representativeVectorId: Int64? = nil
    ) {
        self.email = email
        self.displayName = displayName
        self.worldPosition = worldPosition
        self.radiusPixels = radiusPixels
        self.representativeMessageId = representativeMessageId
        self.representativeVectorId = representativeVectorId
    }
}

public enum RenderDegradationTier: Int, Sendable, Equatable, Comparable {
    case full = 0
    case reducedEffects = 1
    case reducedFibers = 2
    case reducedRefinement = 3
    case aggregateHeavy = 4

    public static func < (lhs: RenderDegradationTier, rhs: RenderDegradationTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RenderBudget: Sendable, Equatable {
    public let maxStars: Int
    public let maxNebulae: Int
    public let maxFibers: Int
    public let maxSatellites: Int
    public let degradationTier: RenderDegradationTier

    public init(
        maxStars: Int,
        maxNebulae: Int,
        maxFibers: Int,
        maxSatellites: Int,
        degradationTier: RenderDegradationTier = .full
    ) {
        self.maxStars = maxStars
        self.maxNebulae = maxNebulae
        self.maxFibers = maxFibers
        self.maxSatellites = maxSatellites
        self.degradationTier = degradationTier
    }

    public static let conservative = RenderBudget(
        maxStars: 1_600,
        maxNebulae: 512,
        maxFibers: 2_400,
        maxSatellites: 160,
        degradationTier: .full
    )

    public func reducingForPressure() -> RenderBudget {
        switch degradationTier {
        case .full:
            return RenderBudget(maxStars: maxStars, maxNebulae: maxNebulae, maxFibers: maxFibers / 2, maxSatellites: maxSatellites, degradationTier: .reducedEffects)
        case .reducedEffects:
            return RenderBudget(maxStars: maxStars, maxNebulae: maxNebulae, maxFibers: maxFibers / 2, maxSatellites: maxSatellites / 2, degradationTier: .reducedFibers)
        case .reducedFibers:
            return RenderBudget(maxStars: maxStars * 3 / 4, maxNebulae: maxNebulae, maxFibers: maxFibers / 2, maxSatellites: maxSatellites / 2, degradationTier: .reducedRefinement)
        case .reducedRefinement:
            return RenderBudget(maxStars: maxStars / 2, maxNebulae: maxNebulae, maxFibers: maxFibers / 2, maxSatellites: maxSatellites / 3, degradationTier: .aggregateHeavy)
        case .aggregateHeavy:
            return self
        }
    }
}

public struct ConstellationLens: Sendable {
    public let frame: FrameKey
    public let aperture: Double
    public let viewSize: CGSize
    public let camera: CameraState

    public init(frame: FrameKey, aperture: Double, viewSize: CGSize, camera: CameraState) {
        self.frame = frame
        self.aperture = aperture
        self.viewSize = viewSize
        self.camera = camera
    }
}

public struct ConstellationRenderPacket: Sendable, Equatable {
    public let stars: [MessageStarInstance]
    public let satellites: [MessageSatelliteInstance]
    public let nebulae: [SemanticNebulaInstance]
    public let semanticDensityFields: [SemanticDensityFieldInstance]
    public let fibers: [AffinityFiberInstance]
    public let hitProxies: [HitProxy]
    public let budget: RenderBudget
    public let totalMessageCount: Int
    public let totalVectorCount: Int
    public let fieldDimFactor: Float
    public let generatedAt: TimeInterval
    /// Active visual language for this packet. Drives the renderer's per-channel
    /// branching (coloration, glyph, halos, strands, motion, density).
    /// Defaults to the neutral `.defaultFrame` reading so legacy callers and
    /// snapshot fixtures continue to render exactly as today.
    public let visualLanguage: FrameVisualLanguage
    /// Up to `labelTopClusters` floating cluster labels for legacy arc
    /// annotations. Empty for current live lenses, including Projects.
    /// SwiftUI renders these on top of the Metal scene when present; no Metal
    /// text rendering.
    public let arcLabels: [ArcLabelOverlay]
    /// People-frame topology primitives. Empty outside `.people`.
    public let personHubs: [PersonHubInstance]
    public let personRelations: [PersonRelationInstance]
    public let personHitProxies: [PersonHitProxy]
    /// Semantic-cluster landmarks for the `.meaning` lens. Empty in every
    /// other lens; rendered as soft hoverable density orbs separate from the
    /// underlying email nodes.
    public let meaningClusterHubs: [MeaningClusterHubInstance]
    /// Settled visibility for `meaningClusterHubs`: 1 = fully visible
    /// (unlocked scene), 0 = fully faded (a node lock is open). Locked
    /// packets still CARRY the cluster hubs so the renderer can fade them
    /// continuously along the lock transition's source-warp ramp instead
    /// of adding/removing them at a packet boundary; this value is the
    /// endpoint the ramp animates toward, and the static value applied
    /// when no transition is running.
    public let meaningClusterVisibility: Float
    /// Saturn-style ring bands. Empty outside `.people`. Drawn between the
    /// halo and star passes so message stars sit on top of their orbital
    /// bands.
    public let personRings: [PersonRingInstance]
    /// Optional legacy atom satellites for multi-recipient message stars.
    /// The main People lens now keeps this empty because included mail has
    /// its own ring.
    public let personAtoms: [PersonAtomInstance]
    /// When `true` (default), the renderer draws each `PersonHubInstance`
    /// as a 3D icosphere with directional shading + depth-tested rings
    /// (Saturn-style). When `false`, the renderer falls back to flat
    /// sprite hubs — used by the locked-overlay Focus scene where the
    /// galaxy metaphor isn't in play and a planet body would compete
    /// with the email-thread reading of the moons around the focal node.
    public let renderHubsAsPlanets: Bool
    /// The sun at the center of the People solar system — present exactly
    /// when this packet carries the solar-system layout (`.people` lens).
    /// Carries the orbital epoch and ecliptic basis every hub orbit in
    /// this packet is expressed against. Nil in every other lens.
    public let personSun: PersonSunInstance?
    /// Whisper-alpha color for the engraved orbit paths + recency band
    /// guides. Appearance-resolved at the SwiftUI boundary (dark: faint
    /// starlight grey; light: faint ink) and baked here like every other
    /// packet color.
    public let personOrbitPathColor: SIMD3<Float>

    public init(
        stars: [MessageStarInstance],
        satellites: [MessageSatelliteInstance],
        nebulae: [SemanticNebulaInstance],
        semanticDensityFields: [SemanticDensityFieldInstance] = [],
        fibers: [AffinityFiberInstance],
        hitProxies: [HitProxy],
        budget: RenderBudget,
        totalMessageCount: Int,
        totalVectorCount: Int,
        fieldDimFactor: Float = 1.0,
        generatedAt: TimeInterval = Date().timeIntervalSince1970,
        visualLanguage: FrameVisualLanguage = .forFrame(.defaultFrame),
        arcLabels: [ArcLabelOverlay] = [],
        personHubs: [PersonHubInstance] = [],
        personRelations: [PersonRelationInstance] = [],
        personHitProxies: [PersonHitProxy] = [],
        meaningClusterHubs: [MeaningClusterHubInstance] = [],
        meaningClusterVisibility: Float = 1.0,
        personRings: [PersonRingInstance] = [],
        personAtoms: [PersonAtomInstance] = [],
        renderHubsAsPlanets: Bool = true,
        personSun: PersonSunInstance? = nil,
        personOrbitPathColor: SIMD3<Float> = SIMD3<Float>(0.62, 0.66, 0.74)
    ) {
        self.stars = stars
        self.satellites = satellites
        self.nebulae = nebulae
        self.semanticDensityFields = semanticDensityFields
        self.fibers = fibers
        self.hitProxies = hitProxies
        self.budget = budget
        self.totalMessageCount = totalMessageCount
        self.totalVectorCount = totalVectorCount
        self.fieldDimFactor = fieldDimFactor
        self.generatedAt = generatedAt
        self.visualLanguage = visualLanguage
        self.arcLabels = arcLabels
        self.personHubs = personHubs
        self.personRelations = personRelations
        self.personHitProxies = personHitProxies
        self.meaningClusterHubs = meaningClusterHubs
        self.meaningClusterVisibility = max(0, min(1, meaningClusterVisibility))
        self.personRings = personRings
        self.personAtoms = personAtoms
        self.renderHubsAsPlanets = renderHubsAsPlanets
        self.personSun = personSun
        self.personOrbitPathColor = personOrbitPathColor
    }

    public static let empty = ConstellationRenderPacket(
        stars: [],
        satellites: [],
        nebulae: [],
        semanticDensityFields: [],
        fibers: [],
        hitProxies: [],
        budget: .conservative,
        totalMessageCount: 0,
        totalVectorCount: 0
    )
}

public enum ConstellationRenderBuilder {
    public static func messageStars(
        from rows: [VectorRenderSourceRow],
        colorForMessage: (String) -> SIMD4<Float>,
        signalForMessage: (String, Set<Int64>) -> VisualSignalState,
        glyphForMessage: ((String) -> UInt8)? = nil,
        emergeMaskForMessage: ((String) -> UInt8)? = nil,
        defaultTintForMessage: ((String) -> SIMD3<Float>)? = nil,
        positionMode: MessageStarPositionMode = .evidenceWeighted
    ) -> [MessageStarInstance] {
        let messageRows = Dictionary(grouping: rows.filter { $0.collection != .entity }, by: \.messageId)
        return messageRows.map { messageId, group -> MessageStarInstance in
            var weighted = SIMD3<Float>.zero
            var totalWeight: Float = 0
            var mostRepresentative = group[0]
            var strongestRepresentativeScore: Float = -.greatestFiniteMagnitude
            var maxMove: Float = 0
            var latestArrival: TimeInterval = 0
            var vectorIds = Set<Int64>()

            for row in group {
                let weight = weight(for: row)
                weighted += row.layout * weight
                totalWeight += weight
                vectorIds.insert(row.vectorId)
                maxMove = max(maxMove, row.lastMoveMagnitude)
                latestArrival = max(latestArrival, row.arrivalTime ?? 0)

                let representativeScore = weight + Float(row.chunkIndex == 0 ? 1 : 0)
                if representativeScore > strongestRepresentativeScore {
                    strongestRepresentativeScore = representativeScore
                    mostRepresentative = row
                }
            }

            let evidenceWeightedPosition = totalWeight > 0
                ? weighted / totalWeight
                : mostRepresentative.layout
            let position: SIMD3<Float>
            switch positionMode {
            case .evidenceWeighted:
                position = evidenceWeightedPosition
            case .contextSummary:
                position = group
                    .filter { $0.collection == .context && $0.chunkIndex == 0 }
                    .min { $0.vectorId < $1.vectorId }?
                    .layout ?? evidenceWeightedPosition
            }
            let count = max(group.count, 1)
            let radius = min(0.024, 0.009 + log2(Float(count) + 1) * 0.0025)
            return MessageStarInstance(
                messageId: messageId,
                representativeVectorId: mostRepresentative.vectorId,
                position: position,
                color: colorForMessage(messageId),
                radius: radius,
                vectorCount: count,
                evidenceWeight: totalWeight,
                arrivalTime: latestArrival,
                lastMoveMagnitude: maxMove,
                signal: signalForMessage(messageId, vectorIds),
                glyphCode: glyphForMessage?(messageId) ?? 0,
                emergeMask: emergeMaskForMessage?(messageId) ?? 0,
                defaultCorrespondentTint: defaultTintForMessage?(messageId) ?? .zero
            )
        }
        .sorted {
            if $0.signal.intensity != $1.signal.intensity {
                return $0.signal.intensity > $1.signal.intensity
            }
            return $0.representativeVectorId < $1.representativeVectorId
        }
    }

    /// Tightens each persisted Meaning cluster around its embedding-derived
    /// medoid without moving that anchor. This creates legible concentrations
    /// of exact-tag members while preserving the semantic distances between
    /// cluster anchors. Unclustered messages and groups below the detector's
    /// four-member support floor remain at their original embedding position.
    public static func meaningArrangedStars(
        _ stars: [MessageStarInstance],
        clusterIdByMessageId: [String: Int64],
        clusterCenterById: [Int64: SIMD3<Float>] = [:]
    ) -> [MessageStarInstance] {
        let minimumClusterSize = 4
        let contraction: Float = 0.30
        let grouped = Dictionary(
            grouping: stars.compactMap { star -> (Int64, MessageStarInstance)? in
                guard let clusterId = clusterIdByMessageId[star.messageId] else { return nil }
                return (clusterId, star)
            },
            by: { $0.0 }
        )

        var arrangedPositionByMessageId: [String: SIMD3<Float>] = [:]
        arrangedPositionByMessageId.reserveCapacity(stars.count)
        for (clusterId, members) in grouped {
            let center: SIMD3<Float>
            if let persistedCenter = clusterCenterById[clusterId] {
                center = persistedCenter
            } else {
                guard members.count >= minimumClusterSize else { continue }
                center = members.reduce(SIMD3<Float>.zero) { partial, member in
                    partial + member.1.position
                } / Float(members.count)
            }
            for (_, star) in members {
                arrangedPositionByMessageId[star.messageId] = center
                    + (star.position - center) * contraction
            }
        }

        return stars.map { star in
            guard let position = arrangedPositionByMessageId[star.messageId] else { return star }
            return star.withPosition(position)
        }
    }

    /// Screen-projected footprint radius for one Meaning community. Radius is
    /// proportional to the square root of full support, so visible area is
    /// population-proportional rather than inherited from the stored layout's
    /// uneven cluster spread.
    public static func meaningFidelityTargetRadius(memberCount: Int) -> Float {
        guard memberCount >= 4 else { return 0 }
        return max(0.012, min(0.075, sqrt(Float(memberCount)) * 0.006))
    }

    /// Minimally separates population-sized Meaning footprints while
    /// retaining the stored medoid arrangement wherever communities do not
    /// collide. Pair corrections follow the current inter-medoid direction,
    /// so the packing removes ambiguous overlap without re-sorting meanings.
    public static func meaningFidelityPackedCenters(
        clusterCenterById: [Int64: SIMD3<Float>],
        clusterMemberCountById: [Int64: Int]
    ) -> [Int64: SIMD3<Float>] {
        let clusterIds = clusterCenterById.keys
            .filter { (clusterMemberCountById[$0] ?? 0) >= 4 }
            .sorted()
        guard clusterIds.count > 1 else { return clusterCenterById }

        var centers = clusterCenterById
        let envelopePadding: Float = 0.012
        let separationGap: Float = 0.004
        for _ in 0..<32 {
            var largestOverlap: Float = 0
            for leftIndex in 0..<(clusterIds.count - 1) {
                let leftId = clusterIds[leftIndex]
                guard var left = centers[leftId] else { continue }
                let leftRadius = meaningFidelityTargetRadius(
                    memberCount: clusterMemberCountById[leftId] ?? 0
                ) + envelopePadding
                for rightIndex in (leftIndex + 1)..<clusterIds.count {
                    let rightId = clusterIds[rightIndex]
                    guard var right = centers[rightId] else { continue }
                    let rightRadius = meaningFidelityTargetRadius(
                        memberCount: clusterMemberCountById[rightId] ?? 0
                    ) + envelopePadding
                    let requiredDistance = leftRadius + rightRadius + separationGap
                    let delta = right - left
                    let distance = simd_length(delta)
                    let overlap = requiredDistance - distance
                    guard overlap > 0 else { continue }
                    largestOverlap = max(largestOverlap, overlap)
                    let direction: SIMD3<Float>
                    if distance > 0.000_001 {
                        direction = delta / distance
                    } else {
                        let axis = (leftIndex + rightIndex) % 3
                        direction = axis == 0
                            ? SIMD3<Float>(1, 0, 0)
                            : axis == 1
                                ? SIMD3<Float>(0, 1, 0)
                                : SIMD3<Float>(0, 0, 1)
                    }
                    let correction = direction * (overlap * 0.5)
                    left -= correction
                    right += correction
                    centers[leftId] = left
                    centers[rightId] = right
                }
            }
            if largestOverlap < 0.000_05 { break }
        }
        return centers
    }

    /// Packs each Meaning cluster into a population-sized area while
    /// preserving every within-cluster pairwise distance ratio and nearest
    /// neighbour. The source radius comes from the complete persisted cluster,
    /// and packed centers come from the complete cluster roster, so filters do
    /// not alter the transform of surviving messages.
    public static func meaningFidelityArrangedStars(
        _ stars: [MessageStarInstance],
        clusterIdByMessageId: [String: Int64],
        clusterCenterById: [Int64: SIMD3<Float>] = [:],
        clusterMemberCountById: [Int64: Int] = [:],
        clusterSourceRadiusById: [Int64: Float] = [:],
        packedCenterById: [Int64: SIMD3<Float>] = [:]
    ) -> [MessageStarInstance] {
        let minimumClusterSize = 4
        let grouped = Dictionary(
            grouping: stars.compactMap { star -> (Int64, MessageStarInstance)? in
                guard let clusterId = clusterIdByMessageId[star.messageId] else { return nil }
                return (clusterId, star)
            },
            by: { $0.0 }
        )

        var arrangedPositionByMessageId: [String: SIMD3<Float>] = [:]
        arrangedPositionByMessageId.reserveCapacity(stars.count)

        for (clusterId, members) in grouped {
            let support = clusterMemberCountById[clusterId] ?? members.count
            guard support >= minimumClusterSize else { continue }
            let center = clusterCenterById[clusterId] ?? members.reduce(SIMD3<Float>.zero) {
                $0 + $1.1.position
            } / Float(members.count)
            let packedCenter = packedCenterById[clusterId] ?? center
            let fallbackSourceRadius = members.map {
                simd_length($0.1.position - center)
            }.max() ?? 0
            let sourceRadius = max(
                0.000_001,
                clusterSourceRadiusById[clusterId] ?? fallbackSourceRadius
            )
            let scale = meaningFidelityTargetRadius(memberCount: support) / sourceRadius

            for (_, star) in members {
                arrangedPositionByMessageId[star.messageId] = packedCenter
                    + (star.position - center) * scale
            }
        }

        return stars.map { star in
            guard let position = arrangedPositionByMessageId[star.messageId] else { return star }
            return star.withPosition(position)
        }
    }

    public static func satellites(
        from rows: [VectorRenderSourceRow],
        visibleMessageIds: Set<String>,
        focusedMessageIds: Set<String>,
        colorForMessage: (String) -> SIMD4<Float>,
        signalForMessage: (String, Set<Int64>) -> VisualSignalState,
        maxCount: Int
    ) -> [MessageSatelliteInstance] {
        guard maxCount > 0, !focusedMessageIds.isEmpty else { return [] }
        let eligible = rows
            .filter { visibleMessageIds.contains($0.messageId) && focusedMessageIds.contains($0.messageId) }
            .filter { $0.collection == .entity || $0.collection == .attachment || $0.chunkIndex > 0 }
            .prefix(maxCount)

        return eligible.map { row in
            var color = colorForMessage(row.messageId)
            if row.collection == .entity {
                color = SIMD4<Float>(1.0, 0.72, 0.30, 1.0)
            } else if row.collection == .attachment {
                color = SIMD4<Float>(0.50, 0.78, 1.0, 1.0)
            }
            return MessageSatelliteInstance(
                vectorId: row.vectorId,
                parentMessageId: row.messageId,
                position: row.layout,
                color: color,
                radius: row.collection == .entity ? 0.006 : 0.007,
                signal: signalForMessage(row.messageId, [row.vectorId])
            )
        }
    }

    public static func nebulae(
        from hiddenStars: [MessageStarInstance],
        camera: CameraState,
        aperture: Double,
        maxCount: Int
    ) -> [SemanticNebulaInstance] {
        nebulaeWithMembership(
            from: hiddenStars,
            camera: camera,
            aperture: aperture,
            maxCount: maxCount
        ).nebulae
    }

    /// Same nebula computation as `nebulae(...)`, but also returns the
    /// exact set of member message IDs per nebula keyed by the nebula's
    /// stable cell id. Legacy arc-label annotation uses this so it does not
    /// have to re-derive membership via an O(nebulae × hiddenStars) radial
    /// check. Membership comes straight from the cell grouping the function
    /// already performs, so the result is exact (no cell-boundary
    /// cross-contamination).
    public static func nebulaeWithMembership(
        from hiddenStars: [MessageStarInstance],
        camera: CameraState,
        aperture: Double,
        maxCount: Int
    ) -> (nebulae: [SemanticNebulaInstance], membersById: [Int64: [String]]) {
        guard maxCount > 0, !hiddenStars.isEmpty else { return ([], [:]) }
        let radius = ApertureSelector.radius(forAperture: aperture)
        let cellSize = max(0.10, min(0.55, radius * 0.35))
        struct Cell: Hashable { let x: Int; let y: Int; let z: Int }
        func cell(for p: SIMD3<Float>) -> Cell {
            Cell(
                x: Int(floor(p.x / cellSize)),
                y: Int(floor(p.y / cellSize)),
                z: Int(floor(p.z / cellSize))
            )
        }

        let grouped = Dictionary(grouping: hiddenStars, by: { cell(for: $0.position) })
        // Per-nebula member message IDs, indexed by stable cell ID so the
        // caller can look up by `SemanticNebulaInstance.id` without
        // tracking the cell key separately. Built in the same pass that
        // produces the nebula instances.
        var membersById: [Int64: [String]] = [:]
        membersById.reserveCapacity(grouped.count)
        var unsortedNebulae: [SemanticNebulaInstance] = []
        unsortedNebulae.reserveCapacity(grouped.count)
        for (key, stars) in grouped {
            var centroid = SIMD3<Float>.zero
            var color = SIMD4<Float>.zero
            var representative = stars[0]
            var nearest = Float.greatestFiniteMagnitude
            for star in stars {
                centroid += star.position
                color += star.color
                let d = simd_distance_squared(star.position, camera.position)
                if d < nearest {
                    nearest = d
                    representative = star
                }
            }
            centroid /= Float(stars.count)
            color /= Float(stars.count)
            var maxDistance: Float = 0
            for star in stars {
                maxDistance = max(maxDistance, simd_distance(star.position, centroid))
            }
            let id = stableCellId(x: key.x, y: key.y, z: key.z)
            let density = min(1, log2(Float(stars.count) + 1) / 9)
            unsortedNebulae.append(SemanticNebulaInstance(
                id: id,
                position: centroid,
                color: SIMD4<Float>(color.x, color.y, color.z, min(0.88, 0.30 + density * 0.55)),
                radius: max(0.035, maxDistance + 0.025),
                density: density,
                memberCount: stars.count,
                representativeVectorId: representative.representativeVectorId
            ))
            membersById[id] = stars.map(\.messageId)
        }
        let sorted = unsortedNebulae
            .sorted {
                if $0.memberCount != $1.memberCount { return $0.memberCount > $1.memberCount }
                return $0.id < $1.id
            }
            .prefix(maxCount)
            .map { $0 }
        // Trim the membership map to the surviving (top-maxCount) nebulae
        // so callers don't carry membership for clusters that won't render.
        let surviving = Set(sorted.map(\.id))
        membersById = membersById.filter { surviving.contains($0.key) }
        return (sorted, membersById)
    }

    public static func stableSemanticColor(for key: String) -> SIMD4<Float> {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let hue = Float(hash % 360) / 360.0
        let saturation: Float = 0.58 + Float((hash >> 9) % 20) / 100.0
        let value: Float = 0.72 + Float((hash >> 17) % 16) / 100.0
        let rgb = hsvToRGB(hue: hue, saturation: saturation, value: value)
        return SIMD4<Float>(rgb.x, rgb.y, rgb.z, 1)
    }

    private static func weight(for row: VectorRenderSourceRow) -> Float {
        switch row.collection {
        case .context:
            return row.chunkIndex == 0 ? 1.25 : 0.95
        case .attachment:
            return 0.80 + min(0.25, row.entityScore ?? 0)
        case .style:
            return 0.65
        case .entity:
            return 0.35 + min(0.25, row.entityScore ?? 0)
        }
    }

    private static func stableCellId(x: Int, y: Int, z: Int) -> Int64 {
        var h: Int64 = 1_125_899_906_842_597
        h = h &* 31 &+ Int64(x)
        h = h &* 31 &+ Int64(y)
        h = h &* 31 &+ Int64(z)
        return h
    }

    private static func hsvToRGB(hue h: Float, saturation s: Float, value v: Float) -> SIMD3<Float> {
        let i = floor(h * 6)
        let f = h * 6 - i
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: return SIMD3<Float>(v, t, p)
        case 1: return SIMD3<Float>(q, v, p)
        case 2: return SIMD3<Float>(p, v, t)
        case 3: return SIMD3<Float>(p, q, v)
        case 4: return SIMD3<Float>(t, p, v)
        default: return SIMD3<Float>(v, p, q)
        }
    }
}
