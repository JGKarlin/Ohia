import Foundation
import simd
import OhiaCore
import OhiaML

nonisolated public struct PeopleFrameFocus: Sendable, Equatable {
    public let query: String
    public let scopes: Set<CorrespondentScope>
    /// Display name for a locked People-focus correspondent. Normal
    /// toolbar-driven focuses omit this and let visible messages supply
    /// names; the locked empty-ring fallback uses it so the preserved
    /// center hub keeps the same identity glyph as the clicked Saturn.
    public let displayName: String?
    /// When `true` the People-lens shows the matched correspondent PLUS
    /// every co-recipient who appears alongside them on a shared message
    /// (the original "ego network" behaviour). When `false` (the default)
    /// the lens shows ONLY the matched correspondent — the strict reading
    /// of "filter to Sam means show me Sam." Co-correspondent context is
    /// still discoverable via the included ring, hover, and the locked-overlay
    /// participant list.
    public let expandsToOneHop: Bool
    /// When `true` the renderer matches the query against participants of
    /// any role (sender OR recipient), ignoring `scopes`. Used by the
    /// People-lens locked-Saturn portrait so the rings show every email
    /// the user has exchanged with the focused correspondent — both
    /// messages they sent (correspondent = recipient) and messages they
    /// received from the correspondent (correspondent = sender). The
    /// filter-search path keeps the default `false` so the existing
    /// selected From/To/Cc/Bcc semantics for typed queries are preserved.
    public let matchesAnyRole: Bool
    /// Optional world-space anchor that pins the focused hub to a fixed
    /// position regardless of what the layout solver would otherwise
    /// pick. Used by the click-to-focus Saturn portrait so the hub
    /// stays at the same point on screen during the camera transition
    /// — without it, the solver collapses the single-hub layout to its
    /// own centroid and the orb appears to jump sideways the moment
    /// the narrowing kicks in. Only honored when `matchesAnyRole` is
    /// true; the filter-search path leaves it nil and accepts the
    /// solver's natural placement.
    public let pinnedHubWorldPosition: SIMD3<Float>?

    public init(
        query: String,
        scopes: Set<CorrespondentScope>,
        displayName: String? = nil,
        expandsToOneHop: Bool = false,
        matchesAnyRole: Bool = false,
        pinnedHubWorldPosition: SIMD3<Float>? = nil
    ) {
        self.query = query
        self.scopes = scopes
        self.displayName = displayName
        self.expandsToOneHop = expandsToOneHop
        self.matchesAnyRole = matchesAnyRole
        self.pinnedHubWorldPosition = pinnedHubWorldPosition
    }

    /// Convenience for role-specific renderer fixtures and locked-focus call
    /// sites. Toolbar-driven focus uses the multi-role initializer above.
    public init(
        query: String,
        scope: CorrespondentScope,
        displayName: String? = nil,
        expandsToOneHop: Bool = false,
        matchesAnyRole: Bool = false,
        pinnedHubWorldPosition: SIMD3<Float>? = nil
    ) {
        self.init(
            query: query,
            scopes: [scope],
            displayName: displayName,
            expandsToOneHop: expandsToOneHop,
            matchesAnyRole: matchesAnyRole,
            pinnedHubWorldPosition: pinnedHubWorldPosition
        )
    }

    public var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var isActive: Bool {
        !normalizedQuery.isEmpty
    }
}

nonisolated struct PeopleGraphLayout: Sendable, Equatable {
    /// Per-placement star instances. A multi-recipient message produces one
    /// instance per correspondent hub it touches, so this array may contain
    /// repeated `messageId`s. Renderer treats each as a distinct billboard.
    var stars: [MessageStarInstance]
    /// Primary placement per `messageId` — the hub with the highest reciprocal
    /// score among the message's correspondents. Drives the per-row layout
    /// override in the planner so that downstream consumers that key by
    /// `messageId` (nebula aggregation, satellite ribbons, the row-level
    /// vector index) see a single canonical position.
    var messagePositions: [String: SIMD3<Float>]
    var hubs: [PersonHubInstance]
    /// Per-hub-pair correspondent relations. Retained for the locked-overlay
    /// hover stats and Focused Scene; **not** rendered as edges in `.people`.
    var relations: [PersonRelationInstance]
    var hitProxies: [PersonHitProxy]
    var personEmailsByMessageId: [String: Set<String>]
    /// Saturn-style ring bands — up to four semantic relationship tiers per hub.
    var rings: [PersonRingInstance]
    /// Legacy atom satellite cue dots for multi-recipient stars. Kept on the
    /// layout shape for renderer compatibility, but the People lens no longer
    /// emits them now that included mail has its own ring.
    var atoms: [PersonAtomInstance]
    /// The sun (the user) at the solar system's focus, carrying the orbital
    /// epoch and ecliptic basis every hub orbit is expressed against. Nil
    /// only for degenerate empty layouts.
    var sun: PersonSunInstance?

    static let empty = PeopleGraphLayout(
        stars: [],
        messagePositions: [:],
        hubs: [],
        relations: [],
        hitProxies: [],
        personEmailsByMessageId: [:],
        rings: [],
        atoms: [],
        sun: nil
    )
}

nonisolated enum PeopleGraphBuilder {
    // MARK: - Tunables
    /// Brightness multiplier the unfocused background correspondent hubs
    /// recede to in a People focus portrait (the focused Saturn and any
    /// ring-bearing hub stay at 1.0). Deep enough that the focused portrait
    /// dominates, but not so dark the surrounding galaxy disappears — the
    /// People analogue of the Meanings lens's `meaningsLock` field dim.
    private static let backgroundHubContextDim: Float = 0.25
    /// Extra brightness the portrait's *affinity neighbours* keep above the
    /// unrelated background: contextDim = base + affinity × this, capped at
    /// `affinityContextDimCeiling`. Orbital motion means angular position no
    /// longer encodes community, so the locked portrait names its neighbours
    /// through graded brightness instead — the focused correspondent's real
    /// co-participants stay legible against the receded field.
    private static let affinityContextDimGain: Float = 0.30
    private static let affinityContextDimCeiling: Float = 0.55
    /// Relation strength needed before correspondents share the same angular
    /// island. Weak broadcast/list co-presence may still leave a faint spring,
    /// but it should not create a tight community by itself.
    private static let componentAffinityThreshold: Float = 0.24
    /// Global scale applied to planet bodies and ring satellites for the
    /// solar-system layout. The correspondent Saturn systems shrink to
    /// ~30% of their pre-solar size so the chart reads as a large sun with
    /// many small planets in vast space; the locked portrait recovers full
    /// visual size through camera framing (footprint-fit), not geometry.
    static let solarScale: Float = 0.30
    /// Hard ceiling on a single hub's outermost ring radius — a runaway
    /// correspondent with thousands of messages can't swallow the system.
    /// (Pre-solar value 0.46, scaled by `solarScale`.)
    private static let maxOuterRingRadius: Float = 0.138
    /// Fraction of a hub's inbound mail that must be mailing-list traffic
    /// before a never-replied-to correspondent classifies as broadcast
    /// (comet class) alongside token-detected automated senders.
    private static let cometListShareThreshold: Float = 0.6
    /// Inclination jitter half-range (radians) — keeps co-orbital planets
    /// out of z-fighting and gives the disc parallax life while preserving
    /// the coherent-plane reading.
    private static let inclinationJitterHalfRange: Float = 0.09
    /// Perihelion jitter fraction so same-day correspondents don't share
    /// one exact orbit radius.
    private static let perihelionJitterFraction: Float = 0.04
    /// Ring band half-width expressed as a fraction of `planetRadius`.
    /// All 4 rings on a hub share this same value, so the rings are
    /// categorical bands of equal width on each hub; the value scales
    /// with the planet so the overall planet : ring-system proportion
    /// stays consistent across small and large correspondents alike
    /// (the Saturn-reference target is ~25–30% planet diameter ÷
    /// total system diameter).
    private static let ringBandHalfRatio: Float = 0.25
    /// Visible Cassini-style dark zone between two adjacent rings'
    /// band-edges, expressed as a fraction of `planetRadius`. Scales
    /// with the planet so the inter-ring gaps stay proportionally
    /// consistent across hub sizes.
    private static let cassiniGapRatio: Float = 0.10
    /// Visible dark strip between the planet rim and the innermost
    /// ring's band-inner-edge, expressed as a fraction of `planetRadius`.
    /// About 2-3x the inter-ring Cassini gap so the planet-to-ring
    /// separation reads as a distinct black annulus without becoming
    /// an oversized moat around the correspondent orb.
    private static let planetSurfaceGapRatio: Float = 0.26
    /// Locked People focus uses the same planet-to-ring gap as the
    /// baseline People layout; the black annulus should be clearer
    /// than the inter-ring gaps, not much larger than them.
    private static let lockedFocusSurfaceGapRatio: Float = 0.26
    /// World-unit radius reference for the message-satellite nodes that
    /// sit IN the ring band. Sized so several satellites fit within the
    /// band's width without crowding — moonlets embedded in the ring,
    /// like Pan or Daphnis in Saturn's rings. With band half-width
    /// scaling proportionally to planet radius (smallest hub bandHalf
    /// ≈ 0.0105), a fixed 0.006 satellite radius always fits inside
    /// the band edge — no overhang case anymore.
    private static let ringSatelliteRadius: Float = 0.006
    /// Tilt of the galaxy plane normal (radians). The whole galaxy reads as a
    /// disc when tilted a touch off the camera-forward axis.
    private static let galaxyTiltX: Float = -0.22
    private static let galaxyTiltY: Float = 0.08
    /// World-fixed "virtual sun" direction. **MUST mirror the planet
    /// fragment shader's `L` constant** in `ConstellationMetalShaders.metal`
    /// (`normalize(float3(0.42, 0.72, 0.55))`) so each ring satellite is
    /// lit by the same sun as its parent planet — that shared lighting is
    /// what makes the ring read as part of the planet's body rather than
    /// a separately-stamped overlay.
    private static let virtualSunDirection: SIMD3<Float> = simd_normalize(SIMD3<Float>(0.42, 0.72, 0.55))

    // MARK: - Public entry point

    static func build(
        stars inputStars: [MessageStarInstance],
        messageIndex: [String: MessageFilterRow],
        userAddresses: Set<String>,
        focus: PeopleFrameFocus?,
        lockedCorrespondentEmail: String? = nil,
        lockedEmailAnchorMessageId: String? = nil,
        accountColorIndexByAccountId: [UUID: Int] = [:],
        hubColor: SIMD3<Float> = AccountColorPalette.correspondentAccentRGB(),
        ringColor: SIMD3<Float> = AccountColorPalette.ringAccentRGB(),
        ringTierColors: [SIMD3<Float>] = AccountColorPalette.tierBandColorsRGB(),
        sunColor: SIMD3<Float> = AccountColorPalette.personSunAccentRGB(
            usedAccountColorIndices: [],
            isDarkAppearance: true
        ),
        now: Date = Date(),
        recencyAnchor: Date? = nil,
        orbitalClock: TimeInterval = 0
    ) -> PeopleGraphLayout {
        guard !inputStars.isEmpty else {
            return emptyLockedFocusLayout(
                focus: focus,
                hubColor: hubColor
            ) ?? .empty
        }

        // 1. Per-message participants (non-user only) with role tagged.
        let inferredUserAddresses = Set(
            inputStars.compactMap { star -> String? in
                guard let row = messageIndex[star.messageId],
                      row.isSentByUser else { return nil }
                return normalizeEmail(row.fromAddress)
            }
        )
        let userAddressSet = Set(userAddresses.compactMap(normalizeEmail)).union(inferredUserAddresses)
        var allParticipantsByMessage: [String: [PersonParticipant]] = [:]
        allParticipantsByMessage.reserveCapacity(inputStars.count)
        for star in inputStars {
            guard let row = messageIndex[star.messageId] else { continue }
            let participants = participants(for: row, userAddresses: userAddressSet)
            if !participants.isEmpty {
                allParticipantsByMessage[star.messageId] = participants
            }
        }

        // 2. Focus filter — restrict to focused correspondents + one hop.
        let focusEmails = focusedEmails(
            participantsByMessage: allParticipantsByMessage,
            messageIndex: messageIndex,
            focus: focus
        )
        // Click-to-focus Saturn portrait (`matchesAnyRole` + an active query).
        // Unlike a typed toolbar filter — which narrows the whole galaxy down
        // to the matched correspondents — the portrait keeps every OTHER
        // correspondent on screen as a dimmed background planet, the People
        // analogue of the Meanings field dim. So in portrait mode the hub
        // pipeline runs unfiltered (all hubs build) and only ring/satellite
        // placement is scoped to the focused correspondent.
        let isPortraitFocus = (focus?.matchesAnyRole ?? false) && (focus?.isActive ?? false)
        // `allowedPeople` gates which correspondents become hubs at all.
        // `ringScopeEmails` gates which of those hubs render a ring system +
        // satellites: `nil` = every hub (baseline galaxy view); non-nil =
        // only these hubs get rings, the rest render as bare dimmed bodies.
        let allowedPeople: Set<String>?
        let ringScopeEmails: Set<String>?
        if focus?.isActive == true {
            guard !focusEmails.isEmpty else {
                return emptyLockedFocusLayout(
                    focus: focus,
                    hubColor: hubColor
                ) ?? .empty
            }
            let scoped: Set<String>
            if focus?.expandsToOneHop == true {
                // Ego-network mode: include co-recipients on shared messages.
                var oneHop = focusEmails
                for participants in allParticipantsByMessage.values where !participantEmails(participants).isDisjoint(with: focusEmails) {
                    oneHop.formUnion(participantEmails(participants))
                }
                scoped = oneHop
            } else {
                // Strict mode (default): only the matched correspondent.
                scoped = focusEmails
            }
            if isPortraitFocus {
                // Build the full galaxy of hub bodies. The focused
                // correspondent keeps fully active rings; surrounding hubs emit
                // transition-only context rings that fade out with the same
                // phase as their dimmed bodies, avoiding a packet-boundary pop
                // while leaving the settled portrait visually quiet.
                allowedPeople = nil
                ringScopeEmails = scoped
            } else {
                // Toolbar filter: narrow everything to the matched set.
                allowedPeople = scoped
                ringScopeEmails = nil
            }
        } else if let lockedEmailAnchorMessageId {
            // Live email-node lock (no correspondent focus): a portrait
            // anchored on the locked message's own correspondent system(s).
            // The hubs that host the locked message keep active rings and
            // full brightness; every other hub recedes exactly like a
            // correspondent portrait's background — dimmed body, fade-flagged
            // context bands, fade-flagged ring satellites. A message with no
            // correspondent hub (user-only participants) yields an empty
            // scope: the whole galaxy recedes around the bare locked node.
            allowedPeople = nil
            ringScopeEmails = participantEmails(
                allParticipantsByMessage[lockedEmailAnchorMessageId] ?? []
            )
        } else {
            allowedPeople = nil
            ringScopeEmails = nil
        }

        var participantsByMessage: [String: [PersonParticipant]] = [:]
        participantsByMessage.reserveCapacity(allParticipantsByMessage.count)
        for (messageId, participants) in allParticipantsByMessage {
            let filtered: [PersonParticipant]
            if let allowedPeople {
                filtered = participants.filter { allowedPeople.contains($0.email) }
            } else {
                filtered = participants
            }
            guard !filtered.isEmpty else { continue }
            participantsByMessage[messageId] = filtered
        }

        // 3. Restrict to messages with at least one allowed participant.
        let visibleMessageIds = Set(participantsByMessage.keys)
        let visibleStars = inputStars.filter { visibleMessageIds.contains($0.messageId) }
        guard !visibleStars.isEmpty else {
            return emptyLockedFocusLayout(
                focus: focus,
                hubColor: hubColor
            ) ?? .empty
        }

        // 4. Per-hub stats (sentCount, receivedCount, latestDate, etc).
        let starByMessageId = Dictionary(uniqueKeysWithValues: visibleStars.map { ($0.messageId, $0) })
        let stats = buildStats(
            stars: visibleStars,
            participantsByMessage: participantsByMessage,
            messageIndex: messageIndex
        )
        guard !stats.isEmpty else {
            // No correspondents in scope (e.g. all-self mail): an honest,
            // planetless system — the sun still anchors the view.
            let center = centroid(of: visibleStars.map(\.position))
            return PeopleGraphLayout(
                stars: visibleStars,
                messagePositions: Dictionary(uniqueKeysWithValues: visibleStars.map { ($0.messageId, $0.position) }),
                hubs: [],
                relations: [],
                hitProxies: [],
                personEmailsByMessageId: personEmailsByMessageId(participantsByMessage),
                rings: [],
                atoms: [],
                sun: makeSun(
                    position: center,
                    color: sunColor,
                    correspondentCount: 0,
                    visibleStars: visibleStars,
                    messageIndex: messageIndex,
                    orbitalEpoch: orbitalClock,
                    eclipticNormal: galaxyPlaneNormal()
                )
            )
        }

        // 5. Per-hub message classification (outer = received-side, inner = user-sent).
        let placements = classifyPlacements(
            participantsByMessage: participantsByMessage,
            messageIndex: messageIndex
        )

        // 6. Per-hub specific Purpose + Domain vector for
        // affinity-driven clustering.
        let semanticAffinityVectorByEmail = buildSemanticAffinityVectors(
            placements: placements,
            messageIndex: messageIndex
        )

        // 7. Hub planet radii + ring radii.
        let hubGeometryByEmail = buildHubGeometry(
            stats: stats,
            placements: placements
        )

        // 8. Hub→hub cross-message relations (existing diluted strength).
        let relationStats = buildRelations(participantsByMessage: participantsByMessage)

        // 9. Evidence affinity. Shared-message relations create the spring;
        // classification-facet overlap can only refine an existing relation,
        // never invent a neighbor claim on its own.
        let combinedAffinity = buildCombinedAffinity(
            relationStats: relationStats,
            semanticAffinityVectorByEmail: semanticAffinityVectorByEmail
        )

        // 10. Centrality (reciprocity + recency) still orders communities
        // and the members within them: angular family sectors and phase
        // seeding need a stable, meaningful ranking even though radial
        // placement is now orbital (recency → perihelion), not radial
        // centrality.
        let eventDateRange = PeopleVisualMetrics.dateRange(
            rows: visibleStars.compactMap { messageIndex[$0.messageId] }
        )
        let centralityByEmail = centralityScores(
            stats: stats,
            dateRange: eventDateRange
        )

        // 11. Solar-system placement: the sun (the user) sits at the scene
        // centroid; every correspondent gets a deterministic Keplerian
        // orbit — perihelion from absolute log-age recency, eccentricity
        // from reciprocity (near-parabolic for the broadcast class),
        // mean motion from age-weighted open obligations — and the packet
        // bakes each hub's position at `orbitalClock` (the orbital epoch).
        // The renderer displaces per frame by `pos(now) − pos(epoch)`, so
        // a frozen clock at packet time means zero displacement and every
        // downstream consumer reads settled geometry exactly as before.
        let center = centroid(of: visibleStars.map(\.position))
        let eclipticBasis = PersonEclipticBasis(normal: galaxyPlaneNormal())
        let anchor = recencyAnchor ?? now
        var orbitByEmail = assignOrbits(
            stats: stats,
            affinity: combinedAffinity,
            centralityByEmail: centralityByEmail,
            messageIndex: messageIndex,
            recencyAnchor: anchor,
            now: now
        )
        // Urgency captured pre-pinning: pinned/locked hubs drop their
        // orbit below, but the ember rim must survive on them.
        let urgencyByEmail = orbitByEmail.mapValues(\.urgency)
        var hubPositions: [String: SIMD3<Float>] = [:]
        hubPositions.reserveCapacity(orbitByEmail.count)
        for (email, orbit) in orbitByEmail {
            hubPositions[email] = PersonOrbitMath.position(
                orbit: orbit,
                at: orbitalClock,
                sunPosition: center,
                basis: eclipticBasis
            )
        }
        // Honor the click-to-focus pinned anchor so the focused hub
        // stays at its original galaxy-view world position. Without this
        // override the focused hub drifts off its pre-focus world position
        // and the orb visibly jumps sideways the instant focus kicks in —
        // breaking the entry transition's "tight zoom → pull back, both
        // centered on the same point" hand-off. Matched by exact email:
        // the portrait now builds the FULL galaxy of background hubs, so a
        // loose substring match could snap several of them onto the single
        // pinned anchor. The focus query is always the focal correspondent's
        // full normalized email, so equality is the precise intent.
        // The pinned hub also loses its orbit: nil orbit = the renderer's
        // zero-displacement sentinel, so the pin is exact under any clock.
        if let focus, focus.matchesAnyRole,
           let pinned = focus.pinnedHubWorldPosition {
            let normalized = focus.normalizedQuery
            for (email, _) in hubPositions where email.lowercased() == normalized {
                hubPositions[email] = pinned
                orbitByEmail[email] = nil
            }
        }
        // Locked-scope hubs (the correspondent portrait's focal Saturn, or
        // the hubs hosting a locked email node) pin to their epoch pose:
        // the locked packet is built with the motion controller's frozen
        // clock, so `position(epoch)` IS the visual pose, and removing the
        // orbit guarantees the overlay's live anchor projection can never
        // drift off the rendered geometry while the lock is open.
        if let ringScopeEmails {
            for email in ringScopeEmails {
                orbitByEmail[email] = nil
            }
        }

        // `shimmerHubEmail` is the focused-correspondent's email when
        // the People lens's locked-node overlay is open. The caller
        // supplies it explicitly (`lockedCorrespondentEmail`) — set
        // for any path that opens the inspector, whether by clicking
        // an email node or by click-to-focusing a correspondent orb.
        // Fall back to the `focus.matchesAnyRole` derivation for
        // legacy call sites that haven't been migrated yet.
        let shimmerHubEmail: String? = {
            if let lockedCorrespondentEmail {
                let normalized = lockedCorrespondentEmail
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if !normalized.isEmpty { return normalized }
            }
            guard let focus, focus.matchesAnyRole else { return nil }
            let normalized = focus.normalizedQuery
            return normalized.isEmpty ? nil : normalized
        }()
        // The inspected correspondent is always pinned to its epoch pose,
        // even on legacy call paths that set `lockedCorrespondentEmail`
        // without a portrait focus — the overlay tether must never chase a
        // displaced body.
        if let shimmerHubEmail {
            orbitByEmail[shimmerHubEmail] = nil
        }

        // 12. Build PersonHubInstances (with ring radii filled). In a focus
        // portrait, hubs outside `ringScopeEmails` are the dimmed background
        // field — the focused correspondent's true co-participants keep an
        // affinity-graded lift above `backgroundHubContextDim` so the
        // portrait still names its neighbourhood now that angular position
        // no longer encodes community.
        let contextDimByEmail = contextDims(
            emails: Array(stats.keys),
            ringScopeEmails: ringScopeEmails,
            affinity: combinedAffinity
        )
        let hubs = makeHubs(
            stats: stats,
            positions: hubPositions,
            geometry: hubGeometryByEmail,
            color: hubColor,
            messageIndex: messageIndex,
            accountColorIndexByAccountId: accountColorIndexByAccountId,
            focusGlowEmail: shimmerHubEmail,
            contextDimByEmail: contextDimByEmail,
            orbitByEmail: orbitByEmail,
            urgencyByEmail: urgencyByEmail,
            now: now
        )
        let hubByEmail = Dictionary(uniqueKeysWithValues: hubs.map { ($0.email, $0) })

        // 13. Build PersonRelationInstances (kept for hover stats; not rendered as edges).
        let relations = makeRelations(
            relationStats: relationStats,
            hubByEmail: hubByEmail
        )

        // 14. Place stars on rings, with reply-to-parent angular alignment.
        // In a focus portrait only the in-scope correspondent(s) keep active
        // ring systems. The surrounding context hubs keep their ring-satellite
        // stars too — at the exact positions the galaxy view rendered them —
        // but flagged `fadesWithPeopleContext` so the star shader recedes
        // them with the same `peopleContextDimPhase` ramp that dims the hub
        // bodies and context ring bands. That keeps the focus-packet install
        // free of node popping on entry, and lets exit progressively restore
        // them as the camera pulls back. Their band geometry comes from
        // `contextRingBands` below (transition-only, fade-flagged), so
        // `placeMessagesOnRings` skips emitting rings for out-of-scope hubs.
        let placementResult = placeMessagesOnRings(
            hubs: hubs,
            placements: placements,
            starByMessageId: starByMessageId,
            ringColor: ringColor,
            ringTierColors: ringTierColors,
            shimmerHubEmail: shimmerHubEmail,
            ringScopeEmails: ringScopeEmails
        )
        let contextRings = ringScopeEmails.map {
            contextRingBands(
                hubs: hubs,
                ringScopeEmails: $0,
                ringTierColors: ringTierColors
            )
        } ?? []
        let rings = contextRings + placementResult.rings
        let perPlacementStars = placementResult.stars
        let atoms = placementResult.atoms
        let primaryPositionByMessage = placementResult.primaryPositionByMessage

        // 15. Hub click proxies (unchanged).
        let hitProxies = hubs.map {
            PersonHitProxy(
                email: $0.email,
                displayName: $0.displayName,
                worldPosition: $0.position,
                radiusPixels: max(20, $0.radius * 1_200),
                representativeMessageId: $0.representativeMessageId,
                representativeVectorId: $0.representativeVectorId
            )
        }

        let sun = makeSun(
            position: center,
            color: sunColor,
            correspondentCount: hubs.count,
            visibleStars: visibleStars,
            messageIndex: messageIndex,
            orbitalEpoch: orbitalClock,
            eclipticNormal: eclipticBasis.normal
        )

        return PeopleGraphLayout(
            stars: perPlacementStars,
            messagePositions: primaryPositionByMessage,
            hubs: hubs,
            relations: relations,
            hitProxies: hitProxies,
            personEmailsByMessageId: personEmailsByMessageId(participantsByMessage),
            rings: rings,
            atoms: atoms,
            sun: sun
        )
    }

    private static func emptyLockedFocusLayout(
        focus: PeopleFrameFocus?,
        hubColor: SIMD3<Float>
    ) -> PeopleGraphLayout? {
        guard let focus,
              focus.matchesAnyRole,
              let position = focus.pinnedHubWorldPosition,
              let email = normalizeEmail(focus.query) else {
            return nil
        }
        let displayName = focusDisplayName(focus, fallbackEmail: email)
        let galaxyNormal = galaxyPlaneNormal()
        let hub = PersonHubInstance(
            email: email,
            displayName: displayName,
            position: position,
            // Solar-scale placeholder body (pre-solar stub was 0.052).
            radius: 0.016,
            sentCount: 0,
            receivedCount: 0,
            reciprocalScore: 0,
            recencyScore: 0,
            isInstitutional: isInstitutional(PersonStats(email: email, displayName: displayName)),
            color: hubColor,
            representativeMessageId: nil,
            representativeVectorId: nil,
            messageIds: [],
            // Empty correspondent slot — no messages yet, so no rings to
            // render. The Saturn portrait shows just the planet body until
            // the host re-supplies the ring scope. No orbit: the pinned
            // placeholder must hold its anchor exactly.
            rings: [],
            ringNormal: galaxyNormal
        )
        return PeopleGraphLayout(
            stars: [],
            messagePositions: [:],
            hubs: [hub],
            relations: [],
            hitProxies: [],
            personEmailsByMessageId: [:],
            rings: [],
            atoms: [],
            sun: nil
        )
    }

    private static func focusDisplayName(_ focus: PeopleFrameFocus, fallbackEmail: String) -> String {
        let trimmed = focus.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallbackEmail : trimmed
    }

    // MARK: - Types

    fileprivate struct PersonParticipant: Sendable, Hashable {
        enum Role: Sendable, Hashable {
            case sender
            case to
            case cc
            case bcc
            case unknown
        }

        let email: String
        let displayName: String
        let role: Role
    }

    fileprivate struct PersonStats: Sendable {
        var email: String
        var displayName: String
        var sentCount: Int = 0
        var receivedCount: Int = 0
        var appearanceCount: Int = 0
        var messageIds: Set<String> = []
        var latestDate: Date?
        var representativeMessageId: String?
        var representativeVectorId: Int64?
        /// Received-at dates of this correspondent's UNRESOLVED inbound
        /// obligations (needs-reply / needs-confirmation, already
        /// normalized upstream against replied/self-sent). Ages against
        /// wall-clock now feed the urgency → orbital-velocity mapping and
        /// the petal-red ember rim.
        var obligationDates: [Date] = []
        /// Inbound rows from this correspondent carrying an RFC 2919 list
        /// id. A never-replied-to correspondent whose inbound mail is
        /// predominantly list traffic classifies as broadcast (comet).
        var listMessageCount: Int = 0

        var totalCount: Int { sentCount + receivedCount + appearanceCount }
        var reciprocalScore: Float {
            let directional = sentCount + receivedCount
            guard directional > 0 else { return 0 }
            let reciprocal = min(sentCount, receivedCount)
            guard reciprocal > 0 else { return 0 }
            return min(1, Float(reciprocal * 2) / Float(directional))
        }
    }

    private struct RelationPair: Hashable {
        let a: String
        let b: String

        init(_ left: String, _ right: String) {
            if left <= right {
                a = left
                b = right
            } else {
                a = right
                b = left
            }
        }
    }

    private struct RelationStats: Sendable {
        var sharedMessageCount: Int = 0
        var dilutedStrength: Float = 0
    }

    private struct HubComponentMember {
        let componentIndex: Int
        let memberIndex: Int
        let memberCount: Int
        let anchorEmail: String
    }

    /// One placement of a message on a hub's ring. A multi-recipient message
    /// produces multiple placements (one per non-user correspondent it
    /// touches). Placements are the unit of work for ring-satellite emission.
    fileprivate struct Placement: Sendable {
        let hubEmail: String
        let messageId: String
        let tier: PersonRingInstance.Tier
        let date: Date
        /// Stable conversation identity. Uses the persistent `MessageThread.id`
        /// when available (post-backfill); falls back to the message's own id
        /// so unthreaded rows count as singleton threads (depth 1). Drives
        /// the within-band radial position: thread sizes are counted globally
        /// (distinct messages per thread, not placements per thread) so a
        /// 50-message conversation reads as depth 50 at every hub it touches,
        /// even hubs the conversation only brushed via a single Cc.
        let threadKey: String
    }

    fileprivate struct HubGeometry: Sendable {
        let email: String
        let planetRadius: Float
        /// Per-tier ring entries already sized by share of hub total.
        /// Sorted innermost → outermost (matches `PersonRingInstance.Tier`
        /// raw value order). Tiers with zero messages on this hub are
        /// omitted entirely.
        let rings: [HubRingGeometry]

        /// Outermost ring radius — drives planet-collision clearance in
        /// the force solver and the camera framing path. Zero when this
        /// hub has no ring messages.
        var maxRingRadius: Float {
            rings.map(\.radius).max() ?? 0
        }
    }

    fileprivate struct HubRingGeometry: Sendable {
        let tier: PersonRingInstance.Tier
        /// Mid-line radius in world units.
        let radius: Float
        /// Half-width band thickness scaled from this tier's share of the
        /// hub's total message footprint.
        let thickness: Float
        /// Count of placements landing on this ring — kept for diagnostics
        /// and so the renderer's instance count can match the placement
        /// loop's expectations without re-counting.
        let count: Int
    }

    // MARK: - Participants

    private static func participants(
        for row: MessageFilterRow,
        userAddresses: Set<String>
    ) -> [PersonParticipant] {
        var result: [PersonParticipant] = []
        var seen: Set<String> = []

        func append(email rawEmail: String, displayName rawName: String?, role: PersonParticipant.Role) {
            guard let email = normalizeEmail(rawEmail),
                  !userAddresses.contains(email),
                  !seen.contains(email) else { return }
            seen.insert(email)
            let name = normalizedDisplayName(rawName, fallbackEmail: email)
            result.append(PersonParticipant(email: email, displayName: name, role: role))
        }

        if !row.isSentByUser {
            append(email: row.fromAddress, displayName: row.fromName, role: .sender)
        }
        appendRecipients(
            addresses: row.toAddresses,
            displayNames: row.toDisplayNames,
            role: .to,
            append: append(email:displayName:role:)
        )
        appendRecipients(
            addresses: row.ccAddresses,
            displayNames: row.ccDisplayNames,
            role: .cc,
            append: append(email:displayName:role:)
        )
        appendRecipients(
            addresses: row.bccAddresses,
            displayNames: row.bccDisplayNames,
            role: .bcc,
            append: append(email:displayName:role:)
        )
        // Preserve graph participants supplied only through the legacy broad
        // recipient union. Their exact header role is unknowable, so keep them
        // in the layout without letting any exact-role checkbox claim them.
        for address in row.recipientAddresses {
            append(email: address, displayName: nil, role: .unknown)
        }
        return result
    }

    private static func appendRecipients(
        addresses: [String],
        displayNames: [String],
        role: PersonParticipant.Role,
        append: (String, String?, PersonParticipant.Role) -> Void
    ) {
        for (index, address) in addresses.enumerated() {
            let displayName = displayNames.indices.contains(index) ? displayNames[index] : nil
            append(address, displayName, role)
        }
    }

    private static func focusedEmails(
        participantsByMessage: [String: [PersonParticipant]],
        messageIndex: [String: MessageFilterRow],
        focus: PeopleFrameFocus?
    ) -> Set<String> {
        guard let focus, focus.isActive else { return [] }
        let query = focus.normalizedQuery
        var result: Set<String> = []
        for (messageId, participants) in participantsByMessage {
            guard messageIndex[messageId] != nil else { continue }
            for participant in participants where matches(participant, focus: focus, query: query) {
                result.insert(participant.email)
            }
        }
        return result
    }

    private static func matches(
        _ participant: PersonParticipant,
        focus: PeopleFrameFocus,
        query: String
    ) -> Bool {
        if focus.matchesAnyRole {
            return participant.email.contains(query) || participant.displayName.lowercased().contains(query)
        }
        let roleMatches = switch participant.role {
        case .sender: focus.scopes.contains(.from)
        case .to:     focus.scopes.contains(.to)
        case .cc:     focus.scopes.contains(.cc)
        case .bcc:    focus.scopes.contains(.bcc)
        case .unknown: false
        }
        guard roleMatches else { return false }
        return participant.email.contains(query) || participant.displayName.lowercased().contains(query)
    }

    // MARK: - Stats

    /// `stars` MUST contain at most one `MessageStarInstance` per `messageId` —
    /// the `Dictionary(uniqueKeysWithValues:)` below traps on duplicate keys.
    /// This is fine in the current call site (the builder receives the
    /// pre-duplication, per-message list `rawStars`) but the
    /// post-duplication `layout.stars` MUST NOT be passed back through here.
    private static func buildStats(
        stars: [MessageStarInstance],
        participantsByMessage: [String: [PersonParticipant]],
        messageIndex: [String: MessageFilterRow]
    ) -> [String: PersonStats] {
        let starByMessageId = Dictionary(uniqueKeysWithValues: stars.map { ($0.messageId, $0) })
        var stats: [String: PersonStats] = [:]
        for star in stars {
            guard let row = messageIndex[star.messageId],
                  let participants = participantsByMessage[star.messageId] else { continue }
            for participant in participants {
                var item = stats[participant.email] ?? PersonStats(
                    email: participant.email,
                    displayName: participant.displayName
                )
                item.displayName = betterDisplayName(existing: item.displayName, candidate: participant.displayName, email: participant.email)
                item.messageIds.insert(star.messageId)
                if row.isSentByUser {
                    item.sentCount += 1
                } else if participant.role == .sender {
                    item.receivedCount += 1
                    // Open obligation on an inbound row from this
                    // correspondent: `isActionable` / `requiresConfirmation`
                    // arrive pre-normalized (raw triage AND not replied AND
                    // not self-sent), so true here means "still owed".
                    if row.isActionable == true || row.requiresConfirmation == true,
                       let obligationDate = row.receivedAt {
                        item.obligationDates.append(obligationDate)
                    }
                    if row.listId != nil {
                        item.listMessageCount += 1
                    }
                } else {
                    item.appearanceCount += 1
                }
                let date = row.receivedAt ?? Date(timeIntervalSince1970: star.arrivalTime)
                if item.latestDate.map({ date > $0 }) ?? true {
                    item.latestDate = date
                    item.representativeMessageId = star.messageId
                    item.representativeVectorId = starByMessageId[star.messageId]?.representativeVectorId
                }
                stats[participant.email] = item
            }
        }
        return stats
    }

    // MARK: - Placements

    private static func classifyPlacements(
        participantsByMessage: [String: [PersonParticipant]],
        messageIndex: [String: MessageFilterRow]
    ) -> [Placement] {
        var placements: [Placement] = []
        placements.reserveCapacity(participantsByMessage.count * 2)
        for (messageId, participants) in participantsByMessage {
            guard let row = messageIndex[messageId] else { continue }
            let date = row.receivedAt ?? Date.distantPast
            // Prefer the persistent thread id; fall back to the message id so
            // an unthreaded row is treated as its own singleton conversation
            // (radial depth = 1) instead of collapsing all unthreaded rows
            // into one giant pseudo-thread. The `"msg:"` prefix can't collide
            // with a real UUID string.
            let threadKey = row.threadId?.uuidString ?? "msg:\(messageId)"
            // Primary-To: set for this message — drives the split between
            // sent·direct (user wrote to this person on the To: line) and
            // sent·included (user wrote to someone else, this person is on
            // Cc:/Bcc:). When `toAddresses` is empty (rare; defensive), we
            // treat every recipient as primary so we don't silently demote
            // an entire conversation to the included tier.
            let primaryRecipients = Set(row.toAddresses.compactMap { normalizeEmail($0) })
            for participant in participants {
                let tier = classifyTier(
                    isSentByUser: row.isSentByUser,
                    participant: participant,
                    primaryRecipients: primaryRecipients
                )
                placements.append(
                    Placement(
                        hubEmail: participant.email,
                        messageId: messageId,
                        tier: tier,
                        date: date,
                        threadKey: threadKey
                    )
                )
            }
        }
        return placements
    }

    /// Map a participant on a message onto one of the 4 People-lens ring
    /// tiers. The two axes are direction (user→world vs world→user) and
    /// directness (this hub is the primary counterpart vs a CC'd
    /// co-recipient). The same rule fires on both sides:
    ///   * sent + primary To:           → `.sentDirect`
    ///   * sent + on Cc:/Bcc: only      → `.sentIncluded`
    ///   * received + this hub is sender → `.receivedDirect`
    ///   * received + this hub is co-recipient → `.included`
    private static func classifyTier(
        isSentByUser: Bool,
        participant: PersonParticipant,
        primaryRecipients: Set<String>
    ) -> PersonRingInstance.Tier {
        if isSentByUser {
            // Sent messages: every participant carries a recipient role (the
            // `participants(for:)` helper drops the sender for sent rows).
            // Split by whether this person was on the To: line vs only
            // Cc:/Bcc:. An empty primary set is treated as "everyone is
            // primary" by the caller's defensive fallback above.
            if primaryRecipients.isEmpty || primaryRecipients.contains(participant.email) {
                return .sentDirect
            }
            return .sentIncluded
        }
        // Received messages: the participants list includes the sender
        // with role `.sender` and every co-recipient with its header role.
        if participant.role == .sender {
            return .receivedDirect
        }
        return .included
    }

    // MARK: - Geometry

    private static func buildHubGeometry(
        stats: [String: PersonStats],
        placements: [Placement]
    ) -> [String: HubGeometry] {
        // Bucket placement counts per (hub, tier). The per-tier shares
        // drive both band thickness and ring ordering — a hub with no
        // sent·direct messages skips that band entirely (no zero-radius
        // placeholder ring instance).
        var countsByHub: [String: [PersonRingInstance.Tier: Int]] = [:]
        for placement in placements {
            countsByHub[placement.hubEmail, default: [:]][placement.tier, default: 0] += 1
        }

        var result: [String: HubGeometry] = [:]
        result.reserveCapacity(stats.count)
        for (email, stat) in stats {
            let counts = countsByHub[email] ?? [:]
            let total = max(1, stat.sentCount + stat.receivedCount + stat.appearanceCount)
            let volume = min(Float(0.090), Float(log1p(Double(total))) * 0.016)
            let reciprocityLift: Float = stat.reciprocalScore * 0.030
            let institutionalDamp: Float = isInstitutional(stat) ? 0.72 : 1.0
            // Pre-solar body range [0.042, 0.110], then shrunk by
            // `solarScale` so the whole Saturn system reads as a small
            // planet against the sun and the orbital span — the locked
            // portrait recovers apparent size through camera framing.
            let planetRadius = max(0.042, min(0.110, (0.040 + volume + reciprocityLift) * institutionalDamp)) * solarScale

            // Per-hub ring dimensions, all proportional to the planet
            // radius so the overall planet : ring-system ratio stays
            // consistent across hubs of every size (Saturn-reference
            // target is ~25–30% planet diameter ÷ total system
            // diameter). With these ratios the outermost ring sits at
            // roughly `planetRadius + planetRadius` for a fully-
            // populated 4-tier hub, giving planet:total ≈ 1:2 on a
            // radial axis (= 1:4 on a diameter axis once both sides
            // are counted), which lands inside the reference band.
            let bandHalf = planetRadius * ringBandHalfRatio
            let surfaceGap = planetRadius * planetSurfaceGapRatio
            let interRingGap = planetRadius * cassiniGapRatio

            // Uniform band thickness for every non-empty tier on this
            // hub — the rings are categorical bands of equal weight,
            // with the per-tier message volume read from the density
            // of satellites inside the band rather than the band's
            // width. Tiers with 0 placements are omitted from `rings`
            // (no zero-thickness instance leaks into the renderer).
            var ringBands: [(tier: PersonRingInstance.Tier, thickness: Float, count: Int)] = []
            ringBands.reserveCapacity(PersonRingInstance.Tier.allCases.count)
            for tier in PersonRingInstance.Tier.insideOutOrder {
                let count = counts[tier] ?? 0
                guard count > 0 else { continue }
                ringBands.append((tier, bandHalf, count))
            }

            // Walk inward → outward, anchoring the innermost ring to the
            // planet surface and spacing each subsequent ring by the
            // Cassini gap + the previous and current band's half-widths.
            // This guarantees every ring sits beyond the planet rim AND
            // every Cassini gap is the same visible dark strip.
            var rings: [HubRingGeometry] = []
            rings.reserveCapacity(ringBands.count)
            var previousOuterEdge = planetRadius + surfaceGap
            for entry in ringBands {
                let radius = previousOuterEdge + entry.thickness
                let clampedRadius = min(maxOuterRingRadius, radius)
                rings.append(HubRingGeometry(
                    tier: entry.tier,
                    radius: clampedRadius,
                    thickness: entry.thickness,
                    count: entry.count
                ))
                previousOuterEdge = clampedRadius + entry.thickness + interRingGap
            }

            result[email] = HubGeometry(
                email: email,
                planetRadius: planetRadius,
                rings: rings
            )
        }
        return result
    }

    // MARK: - Semantic affinity

    /// Sparse specific-Purpose + Domain vector per hub. Built once and
    /// Jaccard-compared pairwise during the force solve.
    private static func buildSemanticAffinityVectors(
        placements: [Placement],
        messageIndex: [String: MessageFilterRow]
    ) -> [String: Set<String>] {
        var byEmail: [String: Set<String>] = [:]
        for placement in placements {
            guard let row = messageIndex[placement.messageId] else { continue }
            let facets = semanticAffinityFacets(for: row)
            guard !facets.isEmpty else { continue }
            byEmail[placement.hubEmail, default: []].formUnion(facets)
        }
        return byEmail
    }

    static func semanticAffinityFacets(for row: MessageFilterRow) -> Set<String> {
        Set(draftingMemoryFacets(
            classification: row.mailClassification,
            customCategoryKeys: []
        ).semanticAffinityKeys)
    }

    private static func facetOverlap(
        _ a: Set<String>,
        _ b: Set<String>
    ) -> Float {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        guard intersection > 0 else { return 0 }
        let union = a.union(b).count
        return Float(intersection) / Float(union)
    }

    static func refinedRelationshipAffinity(
        relationship: Float,
        facetOverlap: Float
    ) -> Float {
        let relationship = max(0, min(1, relationship))
        guard relationship > 0 else { return 0 }
        let overlap = max(0, min(1, facetOverlap))
        return min(1, relationship * (1 + overlap * 0.15))
    }

    // MARK: - Relations

    private static func buildRelations(
        participantsByMessage: [String: [PersonParticipant]]
    ) -> [RelationPair: RelationStats] {
        var relations: [RelationPair: RelationStats] = [:]
        for participants in participantsByMessage.values {
            let emails = Array(Set(participants.map(\.email))).sorted()
            guard emails.count > 1 else { continue }
            let pairCount = max(1, emails.count * (emails.count - 1) / 2)
            let contribution = Float(1) / Float(pairCount)
            for i in 0..<(emails.count - 1) {
                for j in (i + 1)..<emails.count {
                    let pair = RelationPair(emails[i], emails[j])
                    var item = relations[pair] ?? RelationStats()
                    item.sharedMessageCount += 1
                    item.dilutedStrength += contribution
                    relations[pair] = item
                }
            }
        }
        return relations
    }

    private static func buildCombinedAffinity(
        relationStats: [RelationPair: RelationStats],
        semanticAffinityVectorByEmail: [String: Set<String>]
    ) -> [RelationPair: Float] {
        var byPair: [RelationPair: Float] = [:]
        byPair.reserveCapacity(relationStats.count)

        for (pair, stats) in relationStats {
            // Use absolute diluted evidence, not "strongest in this slice".
            // Otherwise one broad list/broadcast message can normalize every
            // tiny co-recipient pair into a strong proximity claim.
            let relation = max(0, min(1, sqrt(max(0, stats.dilutedStrength))))
            let facetSimilarity = facetOverlap(
                semanticAffinityVectorByEmail[pair.a] ?? [],
                semanticAffinityVectorByEmail[pair.b] ?? []
            )
            // Facet similarity is a refinement, not an edge source. The
            // People lens has no drawn lines, so physical adjacency must be
            // reserved for correspondents with explicit shared-message evidence.
            byPair[pair] = refinedRelationshipAffinity(
                relationship: relation,
                facetOverlap: facetSimilarity
            )
        }
        return byPair
    }

    // MARK: - Centrality

    private static func centralityScores(
        stats: [String: PersonStats],
        dateRange: ClosedRange<Date>?
    ) -> [String: Float] {
        var result: [String: Float] = [:]
        result.reserveCapacity(stats.count)
        for (email, stat) in stats {
            let reciprocity = stat.reciprocalScore
            let recency = recencyScore(for: stat.latestDate, range: dateRange)
            let raw = reciprocity * 0.55 + recency * 0.45
            // Volume gives a small nudge so a brand-new highly-reciprocal
            // correspondent doesn't outrank a long-running one.
            let volumeNudge = min(Float(0.10), Float(log1p(Double(max(1, stat.sentCount + stat.receivedCount)))) * 0.018)
            let institutionalMultiplier: Float = isAutomatedSender(stat) && stat.sentCount == 0 ? 0.72 : 1.0
            result[email] = min(1, (raw + volumeNudge) * institutionalMultiplier)
        }
        return result
    }

    private static func recencyScore(
        for date: Date?,
        range: ClosedRange<Date>?
    ) -> Float {
        guard let date, let range else { return 0 }
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard span > 0 else { return 1 }
        let offset = date.timeIntervalSince(range.lowerBound)
        return Float(max(0, min(1, offset / span)))
    }

    /// Calendar-absolute recency for planet brightness. Exponential decay
    /// against `now`, half-life calibrated to track the hover card's
    /// freshness tiers:
    ///
    ///   0d → 1.00    (today)
    ///   7d → 0.86    ("active")
    ///  30d → 0.51    ("recent")
    ///  90d → 0.13    ("fading")
    /// 365d → ~0      ("quiet" / "dormant")
    ///
    /// Returns 0 when a hub has no dated activity, so a stat-only hub
    /// reads as dormant rather than freshly-active.
    private static func recencyGlowScore(latestDate: Date?, now: Date) -> Float {
        guard let latestDate else { return 0 }
        let seconds = now.timeIntervalSince(latestDate)
        guard seconds > 0 else { return 1 }
        let days = seconds / 86_400
        let halfLife: Double = 45
        return Float(exp(-days / halfLife))
    }

    private static func hubComponentMembership(
        emails: [String],
        affinity: [RelationPair: Float],
        centralityByEmail: [String: Float]
    ) -> [String: HubComponentMember] {
        let emailSet = Set(emails)
        var adjacency = Dictionary(uniqueKeysWithValues: emails.map { ($0, Set<String>()) })
        for (pair, strength) in affinity where strength >= componentAffinityThreshold {
            guard emailSet.contains(pair.a), emailSet.contains(pair.b) else { continue }
            adjacency[pair.a, default: []].insert(pair.b)
            adjacency[pair.b, default: []].insert(pair.a)
        }

        var seen: Set<String> = []
        var components: [[String]] = []
        for email in emails.sorted() where !seen.contains(email) {
            var stack = [email]
            var component: [String] = []
            seen.insert(email)
            while let current = stack.popLast() {
                component.append(current)
                let neighbors = (adjacency[current] ?? []).sorted {
                    let left = centralityByEmail[$0] ?? 0
                    let right = centralityByEmail[$1] ?? 0
                    if left != right { return left > right }
                    return $0 < $1
                }
                for neighbor in neighbors where !seen.contains(neighbor) {
                    seen.insert(neighbor)
                    stack.append(neighbor)
                }
            }
            component.sort {
                let left = centralityByEmail[$0] ?? 0
                let right = centralityByEmail[$1] ?? 0
                if left != right { return left > right }
                return $0 < $1
            }
            components.append(component)
        }

        components.sort { lhs, rhs in
            let leftCentrality = lhs.map { centralityByEmail[$0] ?? 0 }.max() ?? 0
            let rightCentrality = rhs.map { centralityByEmail[$0] ?? 0 }.max() ?? 0
            if leftCentrality != rightCentrality { return leftCentrality > rightCentrality }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return (lhs.first ?? "") < (rhs.first ?? "")
        }

        var result: [String: HubComponentMember] = [:]
        result.reserveCapacity(emails.count)
        for (componentIndex, component) in components.enumerated() {
            guard let anchorEmail = component.first else { continue }
            for (memberIndex, email) in component.enumerated() {
                result[email] = HubComponentMember(
                    componentIndex: componentIndex,
                    memberIndex: memberIndex,
                    memberCount: component.count,
                    anchorEmail: anchorEmail
                )
            }
        }
        return result
    }

    private static func initialHubAngle(
        email: String,
        membership: HubComponentMember?,
        goldenAngle: Float
    ) -> Float {
        guard let membership else {
            return stableSignedUnit(email) * Float.pi
        }
        let componentAngle = Float(membership.componentIndex) * goldenAngle
            + stableSignedUnit("component:\(membership.anchorEmail)") * 0.28
        guard membership.memberCount > 1 else {
            return componentAngle + stableSignedUnit(email) * 0.18
        }
        let denominator = max(1, membership.memberCount - 1)
        let progress = Float(membership.memberIndex) / Float(denominator)
        let spread = min(Float(0.74), Float(0.18) + Float(membership.memberCount - 1) * 0.07)
        return componentAngle
            + (progress - 0.5) * spread
            + stableSignedUnit("member:\(email)") * 0.035
    }

    // MARK: - Hub orbits (solar system)

    /// Shared ecliptic-plane normal — the world-fixed tilt the whole disc
    /// reads through (same values the ring normals have always used).
    fileprivate static func galaxyPlaneNormal() -> SIMD3<Float> {
        simd_normalize(SIMD3<Float>(
            sin(galaxyTiltY),
            sin(galaxyTiltX),
            cos(galaxyTiltX) * cos(galaxyTiltY)
        ))
    }

    /// Assign every correspondent a deterministic Keplerian orbit:
    ///
    ///   * perihelion ← absolute log-age recency vs `recencyAnchor`
    ///     (+ a small stable jitter so same-day contacts don't stack on
    ///     one exact radius),
    ///   * eccentricity ← reciprocity, with the broadcast class riding the
    ///     near-parabolic comet band, both clamped by the aphelion cap,
    ///   * argument of perihelion ← community family sectors (the same
    ///     angular-island machinery the force layout used, re-aimed at
    ///     orbit orientation so related correspondents' ellipses align
    ///     like a comet family),
    ///   * phase ← community-adjacent seeding with per-member spread,
    ///   * mean motion ← age-weighted open obligations (urgency).
    ///
    /// Everything is hash-seeded by email, so packet rebuilds produce
    /// identical orbits for unchanged data — no pop at packet swaps.
    private static func assignOrbits(
        stats: [String: PersonStats],
        affinity: [RelationPair: Float],
        centralityByEmail: [String: Float],
        messageIndex: [String: MessageFilterRow],
        recencyAnchor: Date,
        now: Date
    ) -> [String: PersonOrbit] {
        let ranked = stats.values.sorted { lhs, rhs in
            let cl = centralityByEmail[lhs.email] ?? 0
            let cr = centralityByEmail[rhs.email] ?? 0
            if cl != cr { return cl > cr }
            return lhs.email < rhs.email
        }
        guard !ranked.isEmpty else { return [:] }

        let goldenAngle: Float = 2.3999632
        let componentMembership = hubComponentMembership(
            emails: ranked.map(\.email),
            affinity: affinity,
            centralityByEmail: centralityByEmail
        )

        var orbits: [String: PersonOrbit] = [:]
        orbits.reserveCapacity(ranked.count)
        for person in ranked {
            let email = person.email

            // Recency → perihelion. Undated hubs read as dormant (rim).
            let ageSeconds: Double
            if let latest = person.latestDate {
                ageSeconds = max(0, recencyAnchor.timeIntervalSince(latest))
            } else {
                ageSeconds = Double.greatestFiniteMagnitude
            }
            let baseQ = PersonOrbitMath.perihelionRadius(forAgeSeconds: ageSeconds)
            let q = baseQ * (1 + stableSignedUnit("q:\(email)") * perihelionJitterFraction)

            // Reciprocity → eccentricity; broadcast class → comet band.
            let comet = isBroadcastComet(person)
            let nominalE = comet
                ? PersonOrbitMath.cometEccentricity(jitter: stableUnit("e:\(email)"))
                : PersonOrbitMath.humanEccentricity(reciprocalScore: person.reciprocalScore)
            let e = PersonOrbitMath.cappedEccentricity(nominal: nominalE, perihelion: q)

            // Community family sector → orbit orientation.
            let membership = componentMembership[email]
            let omega = initialHubAngle(
                email: email,
                membership: membership,
                goldenAngle: goldenAngle
            )
            let inclination = stableSignedUnit("i:\(email)") * inclinationJitterHalfRange

            // Phase: members of a family start phase-adjacent so the
            // at-rest view still shows loose processions; they drift as
            // the system animates, which the affinity-graded lock dim
            // compensates for.
            let phase = initialHubPhase(email: email, membership: membership)

            // Urgency → mean motion.
            let obligationAges = person.obligationDates.map {
                max(0, now.timeIntervalSince($0)) / 86_400
            }
            let urgency = PersonOrbitMath.urgencyScore(obligationAgesDays: obligationAges)
            let period = PersonOrbitMath.orbitalPeriodSeconds(
                urgency: urgency,
                perihelion: q,
                eccentricity: e
            )

            orbits[email] = PersonOrbit(
                perihelion: q,
                eccentricity: e,
                argumentOfPerihelion: omega,
                inclination: inclination,
                phaseAtEpoch: phase,
                meanMotion: 2 * .pi / max(1, period),
                urgency: urgency,
                isComet: comet
            )
        }
        return orbits
    }

    /// Broadcast/transient classification for the comet band: the user has
    /// never written to this correspondent AND the inbound traffic is
    /// recognizably automated — token-detected sender (noreply/newsletter/…)
    /// or predominantly mailing-list mail. Silent *humans* stay on the
    /// elongated-ellipse end of the human eccentricity ramp instead.
    private static func isBroadcastComet(_ stats: PersonStats) -> Bool {
        guard stats.sentCount == 0 else { return false }
        if isAutomatedSender(stats) { return true }
        guard stats.receivedCount > 0 else { return false }
        let listShare = Float(stats.listMessageCount) / Float(stats.receivedCount)
        return listShare >= cometListShareThreshold
    }

    /// Mean anomaly at epoch. Families seed phase-adjacent (offset from a
    /// per-family anchor phase), singles land on a stable hash phase, so
    /// the settled view reads loose processions without co-orbital stacks.
    private static func initialHubPhase(
        email: String,
        membership: HubComponentMember?
    ) -> Float {
        guard let membership, membership.memberCount > 1 else {
            return stableUnit("phase:\(email)") * 2 * .pi
        }
        let familyPhase = stableUnit("familyPhase:\(membership.anchorEmail)") * 2 * .pi
        let denominator = max(1, membership.memberCount - 1)
        let progress = Float(membership.memberIndex) / Float(denominator)
        let spread = min(Float(1.0), Float(0.30) + Float(membership.memberCount - 1) * 0.09)
        return familyPhase
            + (progress - 0.5) * spread
            + stableSignedUnit("phaseJitter:\(email)") * 0.06
    }

    /// Per-hub brightness for the locked portrait's background field:
    /// in-scope (focused/anchor) hubs stay at 1; everything else recedes
    /// to the context dim, lifted by its strongest affinity to the scope
    /// so the focused correspondent's true co-participants remain legible
    /// wherever their orbits carried them.
    private static func contextDims(
        emails: [String],
        ringScopeEmails: Set<String>?,
        affinity: [RelationPair: Float]
    ) -> [String: Float] {
        var dims: [String: Float] = [:]
        dims.reserveCapacity(emails.count)
        guard let ringScopeEmails else {
            for email in emails { dims[email] = 1 }
            return dims
        }
        for email in emails {
            if ringScopeEmails.contains(email) {
                dims[email] = 1
                continue
            }
            var bestAffinity: Float = 0
            for scopeEmail in ringScopeEmails {
                let strength = affinity[RelationPair(email, scopeEmail)] ?? 0
                if strength > bestAffinity { bestAffinity = strength }
            }
            dims[email] = min(
                affinityContextDimCeiling,
                backgroundHubContextDim + bestAffinity * affinityContextDimGain
            )
        }
        return dims
    }

    /// Aggregate sun readout across the visible scope — row-level counts
    /// so multi-recipient sends aren't double-counted the way per-hub
    /// tallies would.
    private static func makeSun(
        position: SIMD3<Float>,
        color: SIMD3<Float>,
        correspondentCount: Int,
        visibleStars: [MessageStarInstance],
        messageIndex: [String: MessageFilterRow],
        orbitalEpoch: TimeInterval,
        eclipticNormal: SIMD3<Float>
    ) -> PersonSunInstance {
        var sent = 0
        var received = 0
        var openObligations = 0
        for star in visibleStars {
            guard let row = messageIndex[star.messageId] else { continue }
            if row.isSentByUser {
                sent += 1
            } else {
                received += 1
                if row.isActionable == true || row.requiresConfirmation == true {
                    openObligations += 1
                }
            }
        }
        return PersonSunInstance(
            position: position,
            color: color,
            correspondentCount: correspondentCount,
            sentCount: sent,
            receivedCount: received,
            openObligationCount: openObligations,
            orbitalEpoch: orbitalEpoch,
            eclipticNormal: eclipticNormal
        )
    }

    // MARK: - Hubs

    private static func makeHubs(
        stats: [String: PersonStats],
        positions: [String: SIMD3<Float>],
        geometry: [String: HubGeometry],
        color: SIMD3<Float>,
        messageIndex: [String: MessageFilterRow],
        accountColorIndexByAccountId: [UUID: Int],
        focusGlowEmail: String?,
        contextDimByEmail: [String: Float],
        orbitByEmail: [String: PersonOrbit],
        urgencyByEmail: [String: Float],
        now: Date
    ) -> [PersonHubInstance] {
        let galaxyNormal = galaxyPlaneNormal()
        return stats.values.compactMap { item in
            guard let position = positions[item.email],
                  let geo = geometry[item.email] else { return nil }
            let isFocusGlowHub = focusGlowEmail.map { $0 == item.email } ?? false
            // Locked-portrait background hubs recede with an affinity-graded
            // dim (see `contextDims`); scope hubs and the baseline view stay 1.
            let contextDim = contextDimByEmail[item.email] ?? 1
            let focusGapBoost = isFocusGlowHub
                ? geo.planetRadius * max(0, lockedFocusSurfaceGapRatio - planetSurfaceGapRatio)
                : 0
            let hubRings = geo.rings.map { entry in
                PersonHubInstance.RingGeometry(
                    tier: entry.tier,
                    radius: entry.radius + focusGapBoost,
                    thickness: entry.thickness
                )
            }
            let resolvedColor = PeopleAccountColorResolver.dominantColorRGB(
                messageIds: item.messageIds,
                messageIndex: messageIndex,
                accountColorIndexByAccountId: accountColorIndexByAccountId
            ) ?? color
            return PersonHubInstance(
                email: item.email,
                displayName: item.displayName,
                position: position,
                radius: geo.planetRadius,
                sentCount: item.sentCount,
                receivedCount: item.receivedCount,
                appearanceCount: item.appearanceCount,
                reciprocalScore: item.reciprocalScore,
                recencyScore: isFocusGlowHub ? 1 : recencyGlowScore(latestDate: item.latestDate, now: now),
                isInstitutional: isInstitutional(item),
                color: resolvedColor,
                representativeMessageId: item.representativeMessageId,
                representativeVectorId: item.representativeVectorId,
                messageIds: item.messageIds,
                focusGlow: isFocusGlowHub ? 1 : 0,
                contextDim: contextDim,
                rings: hubRings,
                ringNormal: galaxyNormal,
                orbit: orbitByEmail[item.email],
                obligationUrgency: urgencyByEmail[item.email] ?? 0
            )
        }
        .sorted {
            if $0.reciprocalScore != $1.reciprocalScore { return $0.reciprocalScore > $1.reciprocalScore }
            let leftTotal = $0.sentCount + $0.receivedCount
            let rightTotal = $1.sentCount + $1.receivedCount
            if leftTotal != rightTotal { return leftTotal > rightTotal }
            return $0.email < $1.email
        }
    }

    private static func makeRelations(
        relationStats: [RelationPair: RelationStats],
        hubByEmail: [String: PersonHubInstance]
    ) -> [PersonRelationInstance] {
        relationStats.compactMap { pair, stats -> PersonRelationInstance? in
            guard let source = hubByEmail[pair.a],
                  let target = hubByEmail[pair.b] else { return nil }
            return PersonRelationInstance(
                sourceEmail: source.email,
                targetEmail: target.email,
                sourcePosition: source.position,
                targetPosition: target.position,
                sharedMessageCount: stats.sharedMessageCount,
                dilutedStrength: stats.dilutedStrength
            )
        }
        .sorted {
            if $0.dilutedStrength != $1.dilutedStrength { return $0.dilutedStrength > $1.dilutedStrength }
            return $0.id < $1.id
        }
    }

    // MARK: - Ring placement

    /// Places each placement on its hub's appropriate ring, with reply→parent
    /// angular alignment for inner-ring messages whose subject matches a
    /// received-from-the-same-hub message. Returns (rings, stars,
    /// primaryPositionByMessage). Atom cues are intentionally suppressed:
    /// included mail is now represented by discrete People rings.
    private static func placeMessagesOnRings(
        hubs: [PersonHubInstance],
        placements: [Placement],
        starByMessageId: [String: MessageStarInstance],
        ringColor: SIMD3<Float>,
        ringTierColors: [SIMD3<Float>],
        shimmerHubEmail: String?,
        ringScopeEmails: Set<String>? = nil
    ) -> (
        rings: [PersonRingInstance],
        stars: [MessageStarInstance],
        atoms: [PersonAtomInstance],
        primaryPositionByMessage: [String: SIMD3<Float>]
    ) {
        var rings: [PersonRingInstance] = []
        var stars: [MessageStarInstance] = []
        let atoms: [PersonAtomInstance] = []
        var primaryPositionByMessage: [String: SIMD3<Float>] = [:]
        var primaryReciprocityByMessage: [String: Float] = [:]

        // Group placements by hub.
        let placementsByHub = Dictionary(grouping: placements, by: \.hubEmail)

        for hub in hubs {
            guard let bucket = placementsByHub[hub.email] else { continue }

            let normal = hub.ringNormal
            let (axisU, axisV) = orthogonalBasis(for: normal)
            let isShimmerHub = shimmerHubEmail.map { $0 == hub.email } ?? false
            // Focus-portrait background hub: its ring satellites stay at
            // their galaxy positions but fade with `peopleContextDimPhase`,
            // and its band geometry is emitted by `contextRingBands` as
            // transition-only fading rings — not here.
            let isContextHub = ringScopeEmails.map { !$0.contains(hub.email) } ?? false

            // Chronological sweep envelope: every placement on this hub's
            // semantic rings shares one oldest→newest timeline so a sent
            // reply and the received message it answers can be read off the
            // same radial direction at the same date.
            // When the hub has a single placement or every placement shares
            // the same timestamp, `chronologicalRingAngle` falls into the
            // degenerate-span branch and pins every message at the newest
            // (1°) angle; the tier band still communicates the message's
            // relationship to the focused correspondent.
            let earliest = bucket.map(\.date).min() ?? Date.distantPast
            let latest = bucket.map(\.date).max() ?? earliest

            // Iterate per-tier rings on this hub. `hub.rings` is sorted
            // innermost → outermost; each entry already carries the
            // per-hub band thickness computed from this tier's share of
            // total messages, so the loop is purely a routing step.
            for ringEntry in hub.rings {
                let tier = ringEntry.tier
                let tierPlacements = bucket.filter { $0.tier == tier }
                guard !tierPlacements.isEmpty else { continue }

                // Ring band carries the per-hub muted account-hue picked
                // from palette slots not assigned to any active account
                // (see `AccountColorPalette.tierBandColorsRGB`). The hub's
                // own AccountColor stays vivid on the central planet, so
                // the rings sit visually beneath it. Satellite tint and
                // SurveyTelemetryStrip chip continue to source the static
                // Twilight `tier.tierColor` — those are scoped-by-tier
                // identity vocabulary independent of the focused hub.
                let tierRingColor = ringBandColor(
                    for: tier,
                    ringTierColors: ringTierColors
                )
                let tierAlpha = tier.ringAlpha
                let jitterPrefix = "ring\(tier.rawValue)"

                for placement in tierPlacements {
                    let angle = chronologicalRingAngle(
                        date: placement.date,
                        earliest: earliest,
                        latest: latest
                    )
                    // Satellites sit exactly on the band's mid-line —
                    // no thread-depth radial offset, no normal-axis
                    // jitter. Every node in a ring shares the same
                    // distance from the hub center, so the rings read
                    // as clean concentric tracks of dots like a real
                    // planetary ring rather than a scatter band.
                    let world = ringPoint(
                        center: hub.position,
                        nominalRadius: ringEntry.radius,
                        angle: angle,
                        radialOffset: 0,
                        u: axisU,
                        v: axisV,
                        normal: normal,
                        bandThickness: 0,
                        jitterKey: "\(jitterPrefix):\(hub.email):\(placement.messageId)"
                    )
                    if let base = starByMessageId[placement.messageId] {
                        let radial = simd_normalize(world - hub.position)
                        let lambert = simd_dot(radial, virtualSunDirection)
                        // `withRingSatelliteAppearance` reads the tier's
                        // fixed Twilight tone internally; the raw
                        // `ringColor` argument is retained on the call
                        // for signature stability but no longer affects
                        // the satellite hue. Satellite and band match
                        // because both source `tier.tierColor`.
                        // Satellite radii stay UNSCALED by `solarScale`:
                        // star sprites render at a fixed screen size (the
                        // sprite math cancels camera distance), so world-
                        // scaling them would shrink the portrait's moons
                        // permanently. The wide view hides them through the
                        // per-hub LOD fade instead.
                        let satellite = base.withPosition(world).withRingSatelliteAppearance(
                            ringColor: ringColor,
                            tier: tier,
                            lambert: lambert
                        ).withPeopleHub(hub.email)
                        let visibleSatellite = isShimmerHub
                            ? lockedFocusMoon(satellite, tier: tier)
                            : satellite
                        stars.append(
                            isContextHub
                                ? visibleSatellite.withPeopleContextFade(true)
                                : visibleSatellite
                        )
                        // Context-hub placements never register a primary
                        // position: a message shared between the focused hub
                        // and a higher-reciprocity background hub must keep
                        // its canonical `messagePositions` entry on the
                        // focused hub (matching the pre-portrait behavior,
                        // where context placements were filtered out before
                        // this loop). Context-only messages fall through to
                        // the semantic-position fallback below.
                        if !isContextHub {
                            registerPrimary(
                                messageId: placement.messageId,
                                position: world,
                                reciprocity: hub.reciprocalScore,
                                primaryPositionByMessage: &primaryPositionByMessage,
                                primaryReciprocityByMessage: &primaryReciprocityByMessage
                            )
                        }
                    }
                }

                // Context hubs' band geometry is emitted by
                // `contextRingBands` (fade-flagged); emitting a second,
                // non-fading band here would leave a bright ring floating
                // around a dimmed background hub in the settled portrait.
                guard !isContextHub else { continue }

                // Emit one PersonRingInstance per non-empty tier so the
                // renderer draws one band per ring. The `accountColor`
                // field is populated for future ring variants but the
                // current fragment renders each tier as a uniform
                // Twilight fill — no inner-edge hue bleed — so the
                // Cassini gaps between bands stay genuinely dark.
                // `shimmer` is true only for the focused-correspondent's
                // rings (locked-node overlay state) — the fragment
                // shader uses it to sweep a clockwise bright spot
                // around the band's center line.
                rings.append(
                    PersonRingInstance(
                        email: hub.email,
                        center: hub.position,
                        radius: ringEntry.radius,
                        thickness: ringEntry.thickness,
                        normal: normal,
                        color: tierRingColor,
                        accountColor: hub.color,
                        alpha: tierAlpha,
                        tier: tier,
                        shimmer: isShimmerHub
                    )
                )
            }
        }

        // Any message that never matched a hub (e.g. a message-only star with
        // all user-only participants) keeps its semantic position as a
        // fallback so the row's `withLayout(...)` step doesn't snap it to the
        // origin.
        for (messageId, star) in starByMessageId where primaryPositionByMessage[messageId] == nil {
            primaryPositionByMessage[messageId] = star.position
        }

        return (rings, stars, atoms, primaryPositionByMessage)
    }

    private static func contextRingBands(
        hubs: [PersonHubInstance],
        ringScopeEmails: Set<String>,
        ringTierColors: [SIMD3<Float>]
    ) -> [PersonRingInstance] {
        var rings: [PersonRingInstance] = []
        for hub in hubs where !ringScopeEmails.contains(hub.email) {
            for ringEntry in hub.rings {
                rings.append(
                    PersonRingInstance(
                        email: hub.email,
                        center: hub.position,
                        radius: ringEntry.radius,
                        thickness: ringEntry.thickness,
                        normal: hub.ringNormal,
                        color: ringBandColor(
                            for: ringEntry.tier,
                            ringTierColors: ringTierColors
                        ),
                        accountColor: hub.color,
                        alpha: ringEntry.tier.ringAlpha,
                        tier: ringEntry.tier,
                        fadesWithPeopleContext: true
                    )
                )
            }
        }
        return rings
    }

    private static func ringBandColor(
        for tier: PersonRingInstance.Tier,
        ringTierColors: [SIMD3<Float>]
    ) -> SIMD3<Float> {
        let tierIndex = tier.insideOutIndex
        return ringTierColors.indices.contains(tierIndex)
            ? ringTierColors[tierIndex]
            : tier.tierColor
    }

    private static func lockedFocusMoon(
        _ satellite: MessageStarInstance,
        tier: PersonRingInstance.Tier
    ) -> MessageStarInstance {
        let targetRadius = lockedFocusMoonRadius(for: tier)
        let resized = satellite.scalingRadius(by: targetRadius / max(satellite.radius, 0.0001))
        let signal = resized.signal
        // Focused-correspondent satellites carry a steady ~5.5 Hz
        // breathing pulse through the `search` channel — the same pulse
        // every ring tier shares, so received dots and sent open rings
        // breathe in sync. The fragment shader strips the magenta
        // signalTint at `lockFocus ≥ 0.7`, so the pulse rides only on
        // the body's own color rather than producing a purple halo.
        // `selected` is forced to 0 to silence the locked-message lock
        // halo: the SwiftUI reticle already marks the active node.
        return resized.withSignal(VisualSignalState(
            hover: signal.hover,
            selected: 0,
            lockFocus: max(signal.lockFocus, 0.72),
            search: max(signal.search, 0.34),
            citation: signal.citation,
            practical: signal.practical,
            deletion: signal.deletion,
            birth: signal.birth
        ))
    }

    private static func lockedFocusMoonRadius(for tier: PersonRingInstance.Tier) -> Float {
        // All four tiers render at the same 2.5× the baseline
        // `ringSatelliteRadius` (0.006) so received and sent satellites
        // read as the same "moon" size when a hub is locked — the ring
        // band carries the tier signal, not the marker size. Deliberately
        // NOT scaled by `solarScale`: star sprites are fixed screen-size,
        // so the locked portrait's moons keep today's exact on-screen
        // register.
        _ = tier
        return ringSatelliteRadius * 2.5
    }

    private static func registerPrimary(
        messageId: String,
        position: SIMD3<Float>,
        reciprocity: Float,
        primaryPositionByMessage: inout [String: SIMD3<Float>],
        primaryReciprocityByMessage: inout [String: Float]
    ) {
        let existing = primaryReciprocityByMessage[messageId] ?? -1
        if reciprocity > existing {
            primaryPositionByMessage[messageId] = position
            primaryReciprocityByMessage[messageId] = reciprocity
        }
    }

    /// Chronological ring angle in the world coordinate convention used by
    /// `cos(angle) * u + sin(angle) * v`. With `orthogonalBasis`'s typical
    /// output, world angle `π` lands near the top of the ring as the user
    /// sees it (offset by the small galaxy tilt — same drift for every hub
    /// since they share `galaxyNormal`, so the "newest at top" anchor
    /// stays visually coherent across the scene). We anchor the newest
    /// message at clock-clockwise 1° (just past 12 o'clock) and sweep
    /// clockwise to 359° for the oldest, so the eye can read a hub's
    /// history by following the ring clockwise from the top. A 2° gap at
    /// the top keeps newest and oldest from collapsing into the same
    /// pixel.
    ///
    /// Degenerate span (`earliest >= latest` — single placement or all
    /// placements share a timestamp) pins every message at the newest
    /// position rather than at the oldest, matching the contract the
    /// comment promises.
    private static func chronologicalRingAngle(
        date: Date,
        earliest: Date,
        latest: Date
    ) -> Float {
        let span = latest.timeIntervalSince(earliest)
        let t: Float
        if span > 0 {
            let raw = Float(date.timeIntervalSince(earliest) / span)
            t = max(0, min(1, raw))
        } else {
            t = 1
        }
        let clockDegrees: Float = 1 + (1 - t) * 358
        let clockRadians = clockDegrees * .pi / 180
        // World angle so the chronological start sits at the top of the
        // ring and angles sweep clockwise on screen as time runs backward
        // through the hub's history.
        return .pi - clockRadians
    }

    /// Place a satellite on a ring exactly on the band's mid-line.
    /// `radialOffset` and `bandThickness` are retained on the signature
    /// so callers that need to lift a node off the mid-line (e.g. a
    /// future hover-pluck affordance) can pass non-zero values; the
    /// current placement path always passes zero, so every satellite
    /// in a ring shares the same distance from the hub center.
    private static func ringPoint(
        center: SIMD3<Float>,
        nominalRadius: Float,
        angle: Float,
        radialOffset: Float,
        u: SIMD3<Float>,
        v: SIMD3<Float>,
        normal: SIMD3<Float>,
        bandThickness: Float,
        jitterKey: String
    ) -> SIMD3<Float> {
        let normalJitter = stableSignedUnit("n:\(jitterKey)") * bandThickness * 0.20
        let effectiveRadius = max(0.0001, nominalRadius + radialOffset)
        return center
            + u * (cos(angle) * effectiveRadius)
            + v * (sin(angle) * effectiveRadius)
            + normal * normalJitter
    }

    /// Two orthonormal in-plane axes for a given ring normal. The first axis
    /// is biased toward world-X so all rings share a roughly consistent
    /// orientation (so the user reads the galaxy as a coherent disc).
    private static func orthogonalBasis(for normal: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let n = simd_length(normal) > 0.0001 ? normal : SIMD3<Float>(0, 0, 1)
        let reference: SIMD3<Float> = abs(n.x) < 0.9
            ? SIMD3<Float>(1, 0, 0)
            : SIMD3<Float>(0, 1, 0)
        let u = simd_normalize(simd_cross(reference, n))
        let v = simd_normalize(simd_cross(n, u))
        return (u, v)
    }

    // MARK: - Helpers

    private static func participantEmails(_ participants: [PersonParticipant]) -> Set<String> {
        Set(participants.map { $0.email })
    }

    private static func personEmailsByMessageId(
        _ participantsByMessage: [String: [PersonParticipant]]
    ) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        result.reserveCapacity(participantsByMessage.count)
        for (messageId, participants) in participantsByMessage {
            result[messageId] = participantEmails(participants)
        }
        return result
    }

    private static func isInstitutional(_ stats: PersonStats) -> Bool {
        if isAutomatedSender(stats) {
            return true
        }
        return stats.sentCount == 0 && stats.receivedCount > 0
    }

    private static func isAutomatedSender(_ stats: PersonStats) -> Bool {
        let localPart = stats.email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? stats.email
        let institutionalTokens = [
            "noreply", "no-reply", "do-not-reply", "donotreply",
            "notification", "notifications", "mailer", "newsletter",
            "alerts", "updates", "receipts", "receipt", "billing"
        ]
        return institutionalTokens.contains { localPart.contains($0) }
    }

    private static func normalizeEmail(_ value: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("mailto:") {
            trimmed.removeFirst("mailto:".count)
        }
        guard !trimmed.isEmpty, trimmed.contains("@") else { return nil }
        return trimmed
    }

    private static func normalizedDisplayName(_ value: String?, fallbackEmail: String) -> String {
        guard let value else { return fallbackEmail }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.lowercased() != fallbackEmail else { return fallbackEmail }
        return trimmed
    }

    private static func betterDisplayName(existing: String, candidate: String, email: String) -> String {
        if existing == email, candidate != email { return candidate }
        if candidate.count > existing.count, !candidate.contains("@") { return candidate }
        return existing
    }

    private static func centroid(of positions: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !positions.isEmpty else { return .zero }
        return positions.reduce(SIMD3<Float>.zero, +) / Float(positions.count)
    }

    private static func stableUnit(_ key: String) -> Float {
        let value = stableHash(key) & 0x00FF_FFFF
        return Float(value) / Float(0x00FF_FFFF)
    }

    private static func stableSignedUnit(_ key: String) -> Float {
        stableUnit(key) * 2 - 1
    }

    private static func stableHash(_ key: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
