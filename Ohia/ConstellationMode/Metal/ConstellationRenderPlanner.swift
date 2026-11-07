import Foundation
import os
import simd
import OhiaCore
import OhiaML

public struct ConstellationRenderRequest: Sendable {
    public let filter: VectorFilter
    public let lens: ConstellationLens
    public let frameLayoutStore: VectorFrameLayoutStore
    public let frameEdgeProvider: (any FrameEdgeProvider)?
    public let messageIndex: [String: MessageFilterRow]
    public let clusters: [ClusterRecord]
    public let colorByMessageId: [String: SIMD4<Float>]
    public let activeVectorIds: Set<Int64>
    public let citationVectorIds: Set<Int64>
    public let searchScores: [Int64: Float]
    public let hoveredVectorId: Int64?
    public let lockedVectorId: Int64?
    public let fieldDimFactor: Float
    public let budget: RenderBudget
    public let rowLimit: Int
    /// Per-frame visual reading vocabulary. Drives the renderer's
    /// coloration / glyph / halo / strand / motion / density channels
    /// independently of `lens.frame` itself, so legacy frames
    /// pre-`spatialLens` resolution still render coherently.
    public let frameVisualLanguage: FrameVisualLanguage
    /// Lowercased email addresses the user has pinned as "always major".
    /// Pinned addresses are union'd into the major-correspondent set
    /// regardless of recency-weighted volume so a user-flagged
    /// relationship stays salient in `.people` (and any other frame whose
    /// coloration is `.accountColorMajorOnly`) even when recent volume
    /// would otherwise demote it.
    public let pinnedCorrespondents: Set<String>
    /// People-frame visual focus derived from the Voices control. The
    /// renderer receives a filter with the hard correspondent query stripped;
    /// this value reinterprets the query as an ego-network focus.
    public let peopleFocus: PeopleFrameFocus?
    /// Lowercased email of the correspondent the locked-node overlay
    /// is currently inspecting in the People lens. Set whenever the
    /// inspector is open (whether opened by clicking an email node or
    /// by click-to-focus on a correspondent orb); nil otherwise. Drives
    /// the ring-shimmer effect — only the rings of this hub get the
    /// clockwise sweep so the inspected correspondent reads as "live"
    /// against the otherwise static galaxy.
    public let lockedCorrespondentEmail: String?
    /// Full message scope captured when the user enters a locked People
    /// correspondent portrait. The CORRESPONDENT pane uses this same set
    /// for telemetry, so the planner treats it as authoritative for the
    /// focused Saturn's ring stars instead of recomputing a second,
    /// slightly different scope from vector rows.
    public let lockedCorrespondentMessageIds: Set<String>
    /// Account UUID -> `AccountColorPalette` index for the current live
    /// accounts. Message-node colors are already resolved in the snapshot;
    /// People correspondent hubs need this map to resolve an orb color from
    /// their scoped message IDs without reaching back into SwiftData.
    public let accountColorIndexByAccountId: [UUID: Int]
    /// Scene-level color for People-frame correspondent hubs. Derived from
    /// the account palette by the SwiftUI boundary, then baked onto each hub
    /// so the Metal layer does not need account/color-index context.
    public let correspondentHubColor: SIMD3<Float>
    /// Scene-level color for the Saturn ring bands around each correspondent
    /// hub. Shares the hub's hue but at a lower saturation so the ring reads
    /// as an ethereal companion to the solid planet — same identity, distinct
    /// material. Computed alongside `correspondentHubColor` at the SwiftUI
    /// boundary via `AccountColorPalette.ringAccentRGB(...)`. Retained as a
    /// scalar accent for legacy callers and the satellite-tint path; the
    /// per-tier band colors are carried by `correspondentRingTierColors`.
    public let correspondentRingColor: SIMD3<Float>
    /// Per-tier ring-band colors (inside-out: sentDirect, sentIncluded,
    /// receivedDirect, included). Each entry is a heavily muted account-hue
    /// picked from palette slots not assigned to any active account, so the
    /// four rings carry distinct identities without overshadowing the
    /// central planet. Computed at the SwiftUI boundary via
    /// `AccountColorPalette.tierBandColorsRGB(...)`.
    public let correspondentRingTierColors: [SIMD3<Float>]
    /// Lowercased addresses that belong to the local user. People topology
    /// excludes them so the user is implicit rather than rendered as a hub.
    public let userAddresses: Set<String>
    /// Meaning-lens cluster ramp, appearance-resolved at the SwiftUI
    /// boundary (`MeaningClusterLensPalette.resolve`). The top-ranked
    /// clusters take distinct stops from one blue → violet → rose spectral
    /// family; every other cluster renders the anchor base — hue is the
    /// cluster-identity channel on this lens (2026-07-21 decision,
    /// superseding the shared single-accent material).
    public let meaningClusterPalette: MeaningClusterLensPalette
    /// Meaning-lens display aperture: stable persisted clusters are ranked
    /// within the current rendered view, then capped to this count. Other
    /// lenses ignore it.
    public let meaningClusterDisplayLimit: Int
    /// Message UUID strings whose live arrival has been detected but not yet
    /// announced (`NewMailArrivalLedger`). Their vectors are removed from the
    /// packet unconditionally — including forced rows and locked-neighborhood
    /// selections — so a freshly-arrived node can never render before its
    /// arrival moment (starburst badge, dock badge, sound, notification).
    public let embargoedMessageIds: Set<String>
    /// Body color for the People solar system's sun, resolved for the
    /// current appearance at the SwiftUI boundary — the dynamic sun accent
    /// (`AccountColorPalette.personSunAccentRGB`: an unused palette slot,
    /// preferring Capella Gold; stamen register only when the palette walk
    /// exhausts).
    public let personSunColor: SIMD3<Float>
    /// Whisper color for the engraved orbit paths + recency band guides,
    /// appearance-resolved at the SwiftUI boundary.
    public let personOrbitPathColor: SIMD3<Float>
    /// The People orbital clock at request time (the motion controller's
    /// accumulated orbital seconds). Hub base positions bake at this epoch,
    /// so a frozen clock yields zero renderer displacement and settled
    /// geometry that every downstream consumer can trust.
    public let peopleOrbitalClock: TimeInterval

    public init(
        filter: VectorFilter,
        lens: ConstellationLens,
        frameLayoutStore: VectorFrameLayoutStore,
        frameEdgeProvider: (any FrameEdgeProvider)?,
        messageIndex: [String: MessageFilterRow],
        clusters: [ClusterRecord] = [],
        colorByMessageId: [String: SIMD4<Float>],
        activeVectorIds: Set<Int64>,
        citationVectorIds: Set<Int64>,
        searchScores: [Int64: Float],
        hoveredVectorId: Int64?,
        lockedVectorId: Int64?,
        fieldDimFactor: Float = 1.0,
        budget: RenderBudget = .conservative,
        rowLimit: Int = 250_000,
        frameVisualLanguage: FrameVisualLanguage? = nil,
        pinnedCorrespondents: Set<String> = [],
        peopleFocus: PeopleFrameFocus? = nil,
        lockedCorrespondentEmail: String? = nil,
        lockedCorrespondentMessageIds: Set<String> = [],
        accountColorIndexByAccountId: [UUID: Int] = [:],
        correspondentHubColor: SIMD3<Float> = AccountColorPalette.correspondentAccentRGB(),
        correspondentRingColor: SIMD3<Float> = AccountColorPalette.ringAccentRGB(),
        correspondentRingTierColors: [SIMD3<Float>] = AccountColorPalette.tierBandColorsRGB(),
        userAddresses: Set<String> = [],
        meaningClusterPalette: MeaningClusterLensPalette = .resolve(isDarkAppearance: true),
        meaningClusterDisplayLimit: Int = Int.max,
        embargoedMessageIds: Set<String> = [],
        personSunColor: SIMD3<Float> = AccountColorPalette.personSunAccentRGB(
            usedAccountColorIndices: [],
            isDarkAppearance: true
        ),
        personOrbitPathColor: SIMD3<Float> = AccountColorPalette.personOrbitPathRGB(isDarkAppearance: true),
        peopleOrbitalClock: TimeInterval = 0
    ) {
        self.filter = filter
        self.lens = lens
        self.frameLayoutStore = frameLayoutStore
        self.frameEdgeProvider = frameEdgeProvider
        self.messageIndex = messageIndex
        self.clusters = clusters
        self.colorByMessageId = colorByMessageId
        self.activeVectorIds = activeVectorIds
        self.citationVectorIds = citationVectorIds
        self.searchScores = searchScores
        self.hoveredVectorId = hoveredVectorId
        self.lockedVectorId = lockedVectorId
        self.fieldDimFactor = fieldDimFactor
        self.budget = budget
        self.rowLimit = rowLimit
        // Default to the active frame's canonical visual language so
        // existing call sites (tests, snapshot fixtures) keep working
        // without having to know about the new parameter.
        self.frameVisualLanguage = frameVisualLanguage ?? FrameVisualLanguage.forFrame(lens.frame)
        // Lowercase defensively so a caller passing mixed-case addresses
        // still lines up against the planner's lowercased message-index
        // lookups in `majorCorrespondentAddresses`.
        self.pinnedCorrespondents = Set(pinnedCorrespondents.map { $0.lowercased() })
        self.peopleFocus = peopleFocus
        self.lockedCorrespondentEmail = lockedCorrespondentEmail.flatMap { email in
            let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? nil : trimmed
        }
        self.lockedCorrespondentMessageIds = lockedCorrespondentMessageIds
        self.accountColorIndexByAccountId = accountColorIndexByAccountId
        self.correspondentHubColor = correspondentHubColor
        self.correspondentRingColor = correspondentRingColor
        self.correspondentRingTierColors = correspondentRingTierColors
        self.userAddresses = Set(userAddresses.map { $0.lowercased() })
        self.meaningClusterPalette = meaningClusterPalette
        self.meaningClusterDisplayLimit = max(0, meaningClusterDisplayLimit)
        self.embargoedMessageIds = embargoedMessageIds
        self.personSunColor = personSunColor
        self.personOrbitPathColor = personOrbitPathColor
        self.peopleOrbitalClock = peopleOrbitalClock
    }
}

public actor ConstellationRenderPlanner {
    private let vectorStore: VectorStore
    private let neighborsStore: VectorNeighborsStore
    private let logger = Logger(subsystem: "com.ohia.app", category: "ConstellationRenderPlanner")

    public init(vectorStore: VectorStore, neighborsStore: VectorNeighborsStore) {
        self.vectorStore = vectorStore
        self.neighborsStore = neighborsStore
    }

    public func makePacket(_ request: ConstellationRenderRequest) async -> ConstellationRenderPacket {
        do {
            let forcedVectorIds = Self.forcedVectorIds(request)
            var rows = try vectorStore.renderRowsWithLayout(filter: request.filter, limit: request.rowLimit)
            if !forcedVectorIds.isEmpty {
                let existingIds = Set(rows.map(\.vectorId))
                let missingForcedIds = Array(forcedVectorIds.subtracting(existingIds))
                if !missingForcedIds.isEmpty {
                    let forcedRows = try vectorStore.hydrate(vectorIds: missingForcedIds)
                        .compactMap(Self.renderSourceRow)
                        .filter { Self.passesGlobalFilter($0, request: request) }
                    rows.append(contentsOf: forcedRows)
                }
            }
            // The People sun summarizes the whole Moments scope, independent
            // of the Sent/Received chip that narrows the rendered stars and
            // correspondent hubs below. Capture that pre-direction-filter
            // scope while the vector query's collection and time predicates
            // are still intact.
            let peopleSunCandidateMessageIds = request.lens.frame.spatialLens == .people
                ? Set(rows.map(\.messageId))
                : []
            try Task.checkCancellation()
            let lockedSelection = try await lockedNeighborhoodSelection(seedRows: rows, request: request)
            // Locking never contracts the rendered rows. The locked scene keeps
            // the same constellation slice the user was just exploring —
            // isolation comes from the field dim plus the graded `lockFocus`
            // signals derived from `lockedSelection` below, so every lock
            // entry/exit is a continuous camera move through unchanged
            // geometry rather than a swap to a hidden subset mid-flight.
            rows = rows.filter { row in
                guard let messageRow = request.messageIndex[row.messageId] else { return false }
                return ConstellationMessageFilter.matches(messageRow, filter: request.filter)
            }
            // The locked anchor is exempt from the scene filter. A mid-lock
            // filter change that excludes the anchor's message must not erase
            // the node the overlay is tethered to: the lock stays a visible,
            // spatially-anchored act until the user releases it, and the
            // post-release refresh applies the filter for real. Only the
            // anchor message is exempt — filtered neighbours drop like any
            // other node; their grades in `focusGradeByMessageId` are inert
            // for absent rows.
            if let lockedSelection,
               !rows.contains(where: { $0.messageId == lockedSelection.anchorMessageId }) {
                rows.append(contentsOf: lockedSelection.rows.filter { row in
                    row.messageId == lockedSelection.anchorMessageId
                        && (request.filter.collections.contains(row.collection)
                            || row.vectorId == request.lockedVectorId)
                })
            }
            // Arrival embargo: applied after BOTH branches above so the
            // locked-neighborhood selection and forced rows cannot smuggle a
            // not-yet-announced live arrival into the packet.
            if request.embargoedMessageIds.isEmpty == false {
                rows.removeAll { request.embargoedMessageIds.contains($0.messageId) }
            }
            if request.lens.frame != .defaultFrame {
                let framePositions = try request.frameLayoutStore.positionsForFrame(
                    request.lens.frame,
                    vectorIds: rows.map(\.vectorId)
                )
                rows = rows.map { row in
                    guard let position = framePositions[row.vectorId] else { return row }
                    return row.withLayout(position)
                }
            }
            try Task.checkCancellation()

            var vectorIdsByMessage = Dictionary(grouping: rows, by: \.messageId)
                .mapValues { Set($0.map(\.vectorId)) }
            let lockFocusGradeByMessageId = lockedSelection?.focusGradeByMessageId ?? [:]
            let signalForMessage: @Sendable (String, Set<Int64>) -> VisualSignalState = { [request] messageId, ids in
                Self.signalState(
                    messageId: messageId,
                    vectorIds: ids,
                    request: request,
                    lockFocusGradeByMessageId: lockFocusGradeByMessageId
                )
            }
            // Per-frame coloration is a modulation of the account-derived
            // color, never a hue replacement. Major-correspondent set is
            // computed once per packet whenever either the active coloration
            // consumes it OR the frame's emerge mask wants the correspondent
            // tint to re-acquire on hover / lock / search — so the same
            // tint is available for both the resting cluster colour and the
            // emerge override.
            let activeVisualLanguage = request.frameVisualLanguage
            let needsMajorCorrespondents =
                activeVisualLanguage.coloration == .accountColorMajorOnly
                || activeVisualLanguage.emergeOnInteract.contains(.correspondentTint)
            let majorCorrespondents = needsMajorCorrespondents
                ? Self.majorCorrespondentAddresses(request: request, coloration: .accountColorMajorOnly)
                : Set<String>()
            let referenceNow = Date.now
            let colorForMessage: @Sendable (String) -> SIMD4<Float> = { [request] messageId in
                let base = request.colorByMessageId[messageId]
                    ?? ConstellationRenderBuilder.stableSemanticColor(for: messageId)
                return Self.modulateAccountColor(
                    base: base,
                    messageId: messageId,
                    coloration: activeVisualLanguage.coloration,
                    messageIndex: request.messageIndex,
                    majorCorrespondents: majorCorrespondents,
                    referenceNow: referenceNow
                )
            }

            // Per-frame glyph variant. Frames that don't decorate (e.g.,
            // `.meaning`, `.timeline`, `.projects`) leave
            // `.dot` and the encode call returns 0 — same as today's render.
            // `.directional` encodes filled (0) for received and hollow ring
            // (1) for sent; the dashed-included variants (codes 2 and 3) are
            // applied downstream by `PeopleGraphBuilder` per-placement.
            let glyph = activeVisualLanguage.glyph
            let glyphForMessage: @Sendable (String) -> UInt8 = { [request] messageId in
                guard let row = request.messageIndex[messageId] else { return 0 }
                return glyph.encode(isSentByUser: row.isSentByUser)
            }

            // Emerge mask is constant per packet (same for every node
            // under the active frame's visual language). Stamping it
            // per-instance keeps the shader-side decode trivial and
            // matches how the renderer already packs `glyphCode`.
            let emergeRawValue = activeVisualLanguage.emergeOnInteract.rawValue
            let emergeMaskForMessage: @Sendable (String) -> UInt8 = { _ in emergeRawValue }

            // `defaultCorrespondentTint` carries the colour the node *would*
            // have in `.people` frame, regardless of the active frame. When
            // a hovered / locked / search-matched node's emerge mask
            // includes `.correspondentTint`, the shader overrides its body
            // colour with this tint so the relationship cluster identity
            // re-acquires transiently.
            let defaultTintForMessage: @Sendable (String) -> SIMD3<Float> = { [request] messageId in
                guard activeVisualLanguage.emergeOnInteract.contains(.correspondentTint) else {
                    return .zero
                }
                let base = request.colorByMessageId[messageId]
                    ?? ConstellationRenderBuilder.stableSemanticColor(for: messageId)
                let modulated = Self.modulateAccountColor(
                    base: base,
                    messageId: messageId,
                    coloration: .accountColorMajorOnly,
                    messageIndex: request.messageIndex,
                    majorCorrespondents: majorCorrespondents,
                    referenceNow: referenceNow
                )
                return SIMD3<Float>(modulated.x, modulated.y, modulated.z)
            }

            let isMeaningLens = request.lens.frame.spatialLens == .meaning
            let baseStars = ConstellationRenderBuilder.messageStars(
                from: rows,
                colorForMessage: colorForMessage,
                signalForMessage: signalForMessage,
                glyphForMessage: glyphForMessage,
                emergeMaskForMessage: emergeMaskForMessage,
                defaultTintForMessage: defaultTintForMessage,
                positionMode: isMeaningLens ? .contextSummary : .evidenceWeighted
            )
            let rawStars: [MessageStarInstance]
            var meaningClusterCenterOverrideById: [Int64: SIMD3<Float>] = [:]
            var meaningSourcePositionByMessageId: [String: SIMD3<Float>] = [:]
            if isMeaningLens {
                let clusterIdByMessageId = request.messageIndex.compactMapValues(\.clusterId)
                let clusterCenterById = Dictionary(
                    uniqueKeysWithValues: request.clusters.map { ($0.id, $0.centroid) }
                )
                let clusterMemberCountById = Dictionary(
                    uniqueKeysWithValues: request.clusters.map { ($0.id, $0.memberCount) }
                )
                let sourceRadiusById = try vectorStore.clusteredContextSourceRadii(
                    frame: .meaning,
                    anchorByClusterId: clusterCenterById
                )
                meaningClusterCenterOverrideById = ConstellationRenderBuilder
                    .meaningFidelityPackedCenters(
                        clusterCenterById: clusterCenterById,
                        clusterMemberCountById: clusterMemberCountById
                    )
                rawStars = ConstellationRenderBuilder.meaningFidelityArrangedStars(
                    baseStars,
                    clusterIdByMessageId: clusterIdByMessageId,
                    clusterCenterById: clusterCenterById,
                    clusterMemberCountById: clusterMemberCountById,
                    clusterSourceRadiusById: sourceRadiusById,
                    packedCenterById: meaningClusterCenterOverrideById
                )

                // Focus satellites and any row-derived geometry must follow
                // the message dot by the same delta. That preserves each
                // message's local evidence shape after the exact-tag cluster
                // contracts around its unchanged semantic anchor.
                let basePositionByMessageId = Dictionary(
                    uniqueKeysWithValues: baseStars.map { ($0.messageId, $0.position) }
                )
                meaningSourcePositionByMessageId = basePositionByMessageId
                let arrangedPositionByMessageId = Dictionary(
                    uniqueKeysWithValues: rawStars.map { ($0.messageId, $0.position) }
                )
                rows = rows.map { row in
                    guard let basePosition = basePositionByMessageId[row.messageId],
                          let arrangedPosition = arrangedPositionByMessageId[row.messageId] else {
                        return row
                    }
                    return row.withLayout(row.layout + arrangedPosition - basePosition)
                }
            } else {
                rawStars = baseStars
            }
            let peopleInputStars = request.lens.frame.spatialLens == .people
                ? Self.expandedPeopleFocusStars(
                    rawStars,
                    messageIndex: request.messageIndex,
                    filter: request.filter,
                    userAddresses: request.userAddresses,
                    lockedCorrespondentEmail: request.lockedCorrespondentEmail,
                    lockedCorrespondentMessageIds: request.lockedCorrespondentMessageIds,
                    peopleFocus: request.peopleFocus,
                    vectorIdsByMessage: vectorIdsByMessage,
                    colorForMessage: colorForMessage,
                    signalForMessage: { messageId, ids in
                        signalForMessage(messageId, ids)
                    },
                    glyphForMessage: glyphForMessage,
                    emergeMaskForMessage: emergeMaskForMessage,
                    defaultTintForMessage: defaultTintForMessage
                )
                : rawStars
            let peopleLayout: PeopleGraphLayout?
            let allStars: [MessageStarInstance]
            if request.lens.frame.spatialLens == .people {
                // People email-node lock (a live lock on a message, not a
                // correspondent): the builder renders a portrait-style scene
                // anchored on the locked message's own correspondent
                // system(s) — those hubs keep active rings while every other
                // hub recedes to the context dim with fade-flagged bands and
                // ring satellites, exactly like a correspondent portrait.
                let lockedEmailAnchorMessageId: String? = {
                    guard request.lockedVectorId != nil,
                          request.lockedCorrespondentEmail == nil,
                          !(request.peopleFocus?.isActive ?? false) else {
                        return nil
                    }
                    return lockedSelection?.anchorMessageId
                }()
                // Recency anchor: "now" for live scopes; the window's end
                // for a past date filter, so distance stays a meaningful
                // calendar statement inside any timeframe preset. Reuses
                // the packet's single `referenceNow` so color modulation
                // and orbital ages agree on the same moment.
                let recencyAnchor: Date = {
                    guard let window = request.filter.timeRange else { return referenceNow }
                    return min(referenceNow, window.upperBound)
                }()
                var layout = PeopleGraphBuilder.build(
                    stars: peopleInputStars,
                    messageIndex: request.messageIndex,
                    userAddresses: request.userAddresses,
                    focus: request.peopleFocus,
                    lockedCorrespondentEmail: request.lockedCorrespondentEmail,
                    lockedEmailAnchorMessageId: lockedEmailAnchorMessageId,
                    accountColorIndexByAccountId: request.accountColorIndexByAccountId,
                    hubColor: request.correspondentHubColor,
                    ringColor: request.correspondentRingColor,
                    ringTierColors: request.correspondentRingTierColors,
                    sunColor: request.personSunColor,
                    now: referenceNow,
                    recencyAnchor: recencyAnchor,
                    orbitalClock: request.peopleOrbitalClock
                )
                if let sun = layout.sun {
                    let stats = Self.peopleSunStats(
                        candidateMessageIds: peopleSunCandidateMessageIds,
                        messageIndex: request.messageIndex,
                        filter: request.filter,
                        userAddresses: request.userAddresses,
                        embargoedMessageIds: request.embargoedMessageIds
                    )
                    layout.sun = PersonSunInstance(
                        position: sun.position,
                        radius: sun.radius,
                        color: sun.color,
                        correspondentCount: stats.correspondentCount,
                        sentCount: stats.sentCount,
                        receivedCount: stats.receivedCount,
                        openObligationCount: stats.openObligationCount,
                        orbitalEpoch: sun.orbitalEpoch,
                        eclipticNormal: sun.eclipticNormal
                    )
                }
                // Only a genuine People email-node lock exposes its graded
                // semantic neighbours. A correspondent lock also carries a
                // representative vector, but its visible stars must remain
                // scoped to the focused rings.
                if lockedEmailAnchorMessageId != nil,
                   !lockFocusGradeByMessageId.isEmpty {
                    layout.stars = layout.stars.map { star in
                        guard star.fadesWithPeopleContext,
                              lockFocusGradeByMessageId[star.messageId] != nil else {
                            return star
                        }
                        return star.withPeopleContextFade(false)
                    }
                }
                // Focus-portrait background ring satellites (`fadesWithPeopleContext`)
                // render for transition continuity but are not interactive —
                // keeping their rows would mint hover/click hit proxies on
                // stars the settled portrait has faded to nothing. A message
                // that also has an unflagged placement (e.g. it sits on the
                // focused hub's rings too) stays interactive through that
                // placement.
                let visiblePeopleMessageIds = Set(
                    layout.stars
                        .filter { !$0.fadesWithPeopleContext }
                        .map(\.messageId)
                )
                rows = rows
                    .filter { visiblePeopleMessageIds.contains($0.messageId) }
                    .map { row in
                        guard let newPosition = layout.messagePositions[row.messageId] else {
                            return row
                        }
                        // In the galaxy layout, every star sits exactly on a
                        // ring slot — no semantic "personality offset" — so
                        // the row carries the primary ring position verbatim.
                        // This also keeps per-row nebula aggregation aligned
                        // with the visible billboard positions.
                        return row.withLayout(newPosition)
                    }
                vectorIdsByMessage = Dictionary(grouping: rows, by: \.messageId)
                    .mapValues { Set($0.map(\.vectorId)) }
                for star in layout.stars {
                    vectorIdsByMessage[star.messageId, default: []].insert(star.representativeVectorId)
                }
                peopleLayout = layout
                allStars = layout.stars
            } else {
                peopleLayout = nil
                allStars = rawStars
            }
            let selectedStars = Self.visibleStarsForLens(
                allStars,
                request: request,
                vectorIdsByMessage: vectorIdsByMessage
            )
            let visibleMessageIds = Set(selectedStars.map(\.messageId))
            // People-portrait context satellites are transition continuity
            // geometry — when budget-trimmed they must simply not render,
            // not re-aggregate into nebula fog that would sit undimmed
            // around the receded background hubs.
            let hiddenStars = allStars.filter {
                visibleMessageIds.contains($0.messageId) == false
                    && !$0.fadesWithPeopleContext
            }
            // `nebulaeWithMembership` returns the cell-grouped membership
            // map alongside the nebula instances. The current Metal lenses
            // use the nebulae as density fields; legacy arc annotation can
            // still read this membership without re-deriving it via an
            // O(nebulae × hiddenStars) radial check.
            let nebulaResult = ConstellationRenderBuilder.nebulaeWithMembership(
                from: hiddenStars,
                camera: request.lens.camera,
                aperture: request.lens.aperture,
                maxCount: request.budget.maxNebulae
            )
            let (nebulae, arcLabels): ([SemanticNebulaInstance], [ArcLabelOverlay])
            if request.lens.frame.spatialLens == .meaning {
                // Meaning owns its semantic-cluster reading through the 3D
                // membership contours below. The older hidden-star nebula pass reads
                // as a broad fog layer in this lens and obscures the cluster
                // markers, so keep it out of Meaning.
                nebulae = []
                arcLabels = []
            } else {
                (nebulae, arcLabels) = Self.applyArcAnnotations(
                    rawNebulae: nebulaResult.nebulae,
                    membersById: nebulaResult.membersById,
                    request: request
                )
            }
            let selectedMessageIds = Set(selectedStars.filter { $0.signal.selected > 0 }.map(\.messageId))
            let focusMessageIds = lockedSelection?.messageIds ?? selectedMessageIds
            let satellites: [MessageSatelliteInstance]
            if request.lens.frame.spatialLens == .people {
                // Sub-vector cue-dots (body chunks / entities / attachments of
                // the focused message) are a Meanings/Focus-mode device. In the
                // People portrait every row of a message snaps to that message's
                // single ring slot, so the seed message's beads stack into one
                // glowing orb that reads as an artifact rather than relationship
                // signal — and the tier rings, dated ring satellites, and
                // telemetry strip already carry the correspondent's history.
                // Suppress them here, mirroring the `fibers = []` gate below.
                satellites = []
            } else {
                satellites = ConstellationRenderBuilder.satellites(
                    from: rows,
                    visibleMessageIds: visibleMessageIds,
                    focusedMessageIds: focusMessageIds,
                    colorForMessage: colorForMessage,
                    signalForMessage: signalForMessage,
                    maxCount: request.budget.maxSatellites
                )
            }
            let meaningClusterHubs: [MeaningClusterHubInstance]
            if request.lens.frame.spatialLens == .meaning {
                meaningClusterHubs = Self.meaningClusterHubs(
                    clusters: request.clusters,
                    visibleStars: selectedStars,
                    messageIndex: request.messageIndex,
                    palette: request.meaningClusterPalette,
                    displayLimit: request.meaningClusterDisplayLimit,
                    centerOverrideByClusterId: meaningClusterCenterOverrideById,
                    sourcePositionByMessageId: meaningSourcePositionByMessageId
                )
            } else {
                meaningClusterHubs = []
            }
            let meaningClusterColorById = Dictionary(
                uniqueKeysWithValues: meaningClusterHubs.map { ($0.clusterId, $0.color) }
            )
            let fibers: [AffinityFiberInstance]
            if request.lens.frame.spatialLens == .people {
                // Galaxy layout — no hub-hub correspondent lines. Connections
                // read off the rings, planets, and proximity instead.
                fibers = []
            } else {
                fibers = try await makeMessageFibers(
                    rows: rows,
                    visibleStars: selectedStars,
                    request: request,
                    vectorIdsByMessage: vectorIdsByMessage,
                    lockFocusGradeByMessageId: lockFocusGradeByMessageId,
                    meaningClusterColorById: meaningClusterColorById
                )
            }
            // People-portrait context satellites render for transition
            // continuity only — the settled portrait fades them to nothing,
            // so they must not be hover/click targets.
            let hitProxies = selectedStars
                .filter { !$0.fadesWithPeopleContext }
                .map {
                HitProxy(
                    messageId: $0.messageId,
                    vectorId: $0.representativeVectorId,
                    worldPosition: $0.position,
                    radiusPixels: max(16, $0.radius * 950)
                )
            } + satellites.map {
                HitProxy(
                    messageId: $0.parentMessageId,
                    vectorId: $0.vectorId,
                    worldPosition: $0.position,
                    radiusPixels: 12
                )
            } + (peopleLayout?.hitProxies.compactMap { proxy -> HitProxy? in
                guard let vectorId = proxy.representativeVectorId else { return nil }
                return HitProxy(
                    messageId: "person:\(proxy.email)",
                    vectorId: vectorId,
                    worldPosition: proxy.worldPosition,
                    radiusPixels: proxy.radiusPixels
                )
            } ?? [])
            // The sun (the user) is hoverable — aggregate readout — and
            // clickable — reframe to the whole system. Suppressed while a
            // lock is open so the portrait's click grammar (ring select /
            // hub switch / deselect) keeps the whole surface.
            + ((peopleLayout?.sun != nil && request.lockedVectorId == nil && request.lockedCorrespondentEmail == nil)
                ? [HitProxy(
                    messageId: PersonSunInstance.hitProxyMessageId,
                    vectorId: PersonSunInstance.hitProxyVectorId,
                    worldPosition: peopleLayout!.sun!.position,
                    // Compact node-circle target only. The rendered sun has
                    // a wide radiant body/corona, but hover and click must
                    // stay on the "You" circle so nearby planets remain
                    // reachable inside the glow.
                    radiusPixels: 28
                )]
                : [])
            // Meaning-cluster contours in a LOCKED packet render for transition
            // continuity only — they fade to invisible with the lock's
            // source-warp ramp — so, like the People-portrait context
            // satellites above, they must not be hover/click targets.
            + (request.lockedVectorId == nil ? meaningClusterHubs.compactMap { hub in
                return HitProxy(
                    messageId: MeaningClusterHubInstance.hitProxyMessageId(clusterId: hub.clusterId),
                    vectorId: -hub.clusterId - 1,
                    worldPosition: hub.position,
                    // The whole visible contour is selectable. Normal picking
                    // still gives message dots priority over this envelope.
                    radiusPixels: max(18, hub.radius * 900)
                )
            } : [])

            return ConstellationRenderPacket(
                stars: selectedStars,
                satellites: satellites,
                nebulae: nebulae,
                fibers: fibers,
                hitProxies: hitProxies,
                budget: request.budget,
                totalMessageCount: allStars.count,
                totalVectorCount: rows.count,
                fieldDimFactor: request.fieldDimFactor,
                visualLanguage: request.frameVisualLanguage,
                arcLabels: arcLabels,
                personHubs: peopleLayout?.hubs ?? [],
                personRelations: peopleLayout?.relations ?? [],
                personHitProxies: peopleLayout?.hitProxies ?? [],
                meaningClusterHubs: meaningClusterHubs,
                meaningClusterVisibility: request.lockedVectorId == nil ? 1 : 0,
                personRings: peopleLayout?.rings ?? [],
                personAtoms: [],
                personSun: peopleLayout?.sun,
                personOrbitPathColor: request.personOrbitPathColor
            )
        } catch is CancellationError {
            return .empty
        } catch {
            logger.error("render packet failed: \(String(reflecting: type(of: error)), privacy: .public)")
            return .empty
        }
    }

    private struct LockedNeighborhoodSelection: Sendable {
        let rows: [VectorRenderSourceRow]
        let vectorIds: Set<Int64>
        let messageIds: Set<String>
        /// Message id of the locked node itself (focus grade 1.0).
        let anchorMessageId: String
        let neighbours: [LockedNeighborhoodResolver.NeighbourMessage]
        /// Semantic-distance focus grade per member message: the anchor is
        /// 1.0 and gated neighbours descend with resolver rank. The shader's
        /// `lock_dim_multiplier` interpolates brightness between the field
        /// dim and full emission with this value, so closer neighbours stay
        /// brighter than farther ones instead of the whole neighbourhood
        /// snapping to a single binary level.
        let focusGradeByMessageId: [String: Float]

        /// Anchor grade — full emission.
        static let anchorFocusGrade: Float = 1.0
        /// Grade of the top-ranked neighbour.
        static let nearestNeighbourFocusGrade: Float = 0.90
        /// Grade of the last-ranked neighbour when the list is full.
        /// The star fragment shader strips the magenta signal halo for
        /// `lock.x ≥ 0.45` (`constellation_star_fragment` in
        /// ConstellationMetalShaders.metal); keep this floor above that
        /// threshold so the whole graded neighbourhood is stripped
        /// uniformly inside a lock.
        static let farthestNeighbourFocusGrade: Float = 0.50

        /// Grades are proportional to each neighbour's actual best cosine
        /// similarity, normalized across the gated list — not to its rank.
        /// Two neighbours whose similarities differ by a hair render at
        /// near-identical brightness instead of being forced a full rank
        /// step apart; a genuine similarity gap reads as a brightness gap.
        /// The top-similarity neighbour always sits at the nearest grade,
        /// the lowest at the farthest; a single neighbour (or a degenerate
        /// all-equal list) holds the nearest grade.
        static func neighbourGrades(
            anchorMessageId: String,
            neighbours: [LockedNeighborhoodResolver.NeighbourMessage]
        ) -> [String: Float] {
            var grades: [String: Float] = [anchorMessageId: anchorFocusGrade]
            guard !neighbours.isEmpty else { return grades }
            let span = nearestNeighbourFocusGrade - farthestNeighbourFocusGrade
            // Non-finite similarities (a NaN cosine from a degenerate vector)
            // must not poison the normalization — a NaN grade reaches the
            // shader as `lock.x` and corrupts the whole neighbourhood's
            // brightness. Non-finite entries grade at the farthest level.
            let similarities = neighbours.map(\.bestSimilarity).filter(\.isFinite)
            let maxSimilarity = similarities.max() ?? 0
            let minSimilarity = similarities.min() ?? 0
            let similaritySpan = maxSimilarity - minSimilarity
            for neighbour in neighbours {
                guard neighbour.bestSimilarity.isFinite else {
                    grades[neighbour.messageId] = farthestNeighbourFocusGrade
                    continue
                }
                let normalized: Float = similaritySpan > 0.0001
                    ? (maxSimilarity - neighbour.bestSimilarity) / similaritySpan
                    : 0
                grades[neighbour.messageId] = nearestNeighbourFocusGrade - span * normalized
            }
            return grades
        }
    }

    private func lockedNeighborhoodSelection(
        seedRows: [VectorRenderSourceRow],
        request: ConstellationRenderRequest
    ) async throws -> LockedNeighborhoodSelection? {
        guard let lockedVectorId = request.lockedVectorId else { return nil }
        let hydratedSelectedMessageId: String?
        if seedRows.contains(where: { $0.vectorId == lockedVectorId }) {
            hydratedSelectedMessageId = nil
        } else {
            hydratedSelectedMessageId = try vectorStore.hydrate(vectorIds: [lockedVectorId]).first?.messageId
        }
        let selectedMessageId = seedRows.first { $0.vectorId == lockedVectorId }?.messageId
            ?? hydratedSelectedMessageId
        guard let selectedMessageId,
              request.messageIndex[selectedMessageId] != nil else {
            return nil
        }

        let selectedRows = try vectorStore.vectorsForMessage(messageId: selectedMessageId)
            .compactMap(Self.renderSourceRow)
        guard selectedRows.isEmpty == false else { return nil }

        let selectedVectorIds = selectedRows.map(\.vectorId)
        let neighbors = try await vectorEdges(for: selectedVectorIds, request: request)
        let targetIds = Array(Set(neighbors.map(\.targetId)))
        let targetRecords = try vectorStore.hydrate(vectorIds: targetIds)

        var messageByVectorId = Dictionary(uniqueKeysWithValues: seedRows.map { ($0.vectorId, $0.messageId) })
        for row in selectedRows {
            messageByVectorId[row.vectorId] = row.messageId
        }
        for record in targetRecords {
            messageByVectorId[record.vectorId] = record.messageId
        }

        let neighbours = LockedNeighborhoodResolver().resolve(
            anchorMessageId: selectedMessageId,
            anchorVectorIds: Set(selectedVectorIds),
            neighborsBySource: Dictionary(grouping: neighbors, by: \.sourceId),
            messageByVectorId: messageByVectorId,
            eligibleMessageIds: Set(request.messageIndex.keys),
            limit: Self.selectedNeighborMessageLimit
        )
        let relatedMessageIds = neighbours.map(\.messageId)

        var rowsByVectorId: [Int64: VectorRenderSourceRow] = [:]
        for row in selectedRows {
            rowsByVectorId[row.vectorId] = row
        }
        for messageId in relatedMessageIds {
            let relatedRows = try vectorStore.vectorsForMessage(messageId: messageId)
                .compactMap(Self.renderSourceRow)
            for row in relatedRows {
                rowsByVectorId[row.vectorId] = row
            }
        }

        let rows = rowsByVectorId.values.sorted {
            if $0.messageId != $1.messageId {
                if $0.messageId == selectedMessageId { return true }
                if $1.messageId == selectedMessageId { return false }
                return $0.messageId < $1.messageId
            }
            if $0.collection != $1.collection {
                return Self.collectionRank($0.collection) < Self.collectionRank($1.collection)
            }
            if $0.chunkIndex != $1.chunkIndex { return $0.chunkIndex < $1.chunkIndex }
            return $0.vectorId < $1.vectorId
        }
        guard !rows.isEmpty else { return nil }
        return LockedNeighborhoodSelection(
            rows: rows,
            vectorIds: Set(rows.map(\.vectorId)),
            messageIds: Set([selectedMessageId] + relatedMessageIds),
            anchorMessageId: selectedMessageId,
            neighbours: neighbours,
            focusGradeByMessageId: LockedNeighborhoodSelection.neighbourGrades(
                anchorMessageId: selectedMessageId,
                neighbours: neighbours
            )
        )
    }

    private nonisolated static let selectedNeighborMessageLimit = 12

    private nonisolated static func collectionRank(_ collection: VectorCollection) -> Int {
        switch collection {
        case .context: return 0
        case .attachment: return 1
        case .entity: return 2
        case .style: return 3
        }
    }

    private static func forcedVectorIds(_ request: ConstellationRenderRequest) -> Set<Int64> {
        var ids = request.activeVectorIds
        ids.formUnion(request.citationVectorIds)
        ids.formUnion(request.searchScores.keys)
        if let hovered = request.hoveredVectorId { ids.insert(hovered) }
        if let locked = request.lockedVectorId { ids.insert(locked) }
        return ids
    }

    // MARK: - Legacy arc annotations

    /// Minimum cluster size for emitting a floating arc label overlay.
    /// Below this the label is too small to be legible in the scene.
    private static let arcLabelMinMembers: Int = 30
    /// Minimum dominant-label vote share (0–1) before emitting an
    /// overlay. Prevents labels on clusters where the dominant label
    /// barely beats the runner-up.
    private static let arcLabelMinConfidence: Float = 0.5
    /// Secondary-label threshold for the nested-ring decoration. A
    /// cluster gets a nested aspect only when a runner-up label
    /// covers at least this share of the remainder.
    private static let arcNestedAspectThreshold: Float = 0.30
    /// Cluster must have at least this many total members in the DB before
    /// it qualifies as a meaning node — a guard against single-thread
    /// "clusters" that survived detection with tiny support.
    private static let meaningClusterHubMinMembers: Int = 4
    /// Floor on visible (in-scope) members. Mirrors the detector's default
    /// minimum support so every rendered hub has enough stars to read as a
    /// semantic group without suppressing legitimate small clusters.
    private static let meaningClusterHubMinVisibleMembers: Int = 4
    /// Hard ceiling so a wide-open filter scope can't flood the scene
    /// with thirty-plus contours that obscure the email nodes.
    private static let meaningClusterHubMaxCount: Int = 32
    /// Meaning uses the same light, compact message dots as the rest of
    /// Constellation, but its NightSky backdrop can visually compete with a
    /// tiny filtered set. A modest lens-only bump keeps email nodes larger
    /// than background stars without turning them into cluster bodies.
    private static let meaningLensMessageStarRadiusScale: Float = 1.35

    private struct MeaningClusterVisualStats {
        let center: SIMD3<Float>
        let visibleMemberCount: Int
        let internalWeight: Float
        let density: Float
        let compactness: Float
        /// Single composite score in `[0, 1]` blending visible-member
        /// density, local compactness, and within-cluster fibre weight.
        /// Used both to rank clusters and to scale contour radius / opacity
        /// — never as a hard gate, because the gate is "enough visible
        /// support," not "tight enough to look impressive."
        let intensity: Float
    }

    /// Legacy support for annotating top nebula clusters with their majority
    /// project / team / topic label. The current Projects correspondence
    /// lens bypasses Metal entirely, so this explicitly refuses `.projects`
    /// packets even if an old frame-burst job reaches the planner.
    ///
    /// Membership comes from the cell-grouping pass inside
    /// `nebulaeWithMembership(...)` — exact, with no cell-boundary
    /// cross-contamination — so this function does no spatial work.
    /// The cost is O(nebulae × averageMembersPerNebula) rather than
    /// O(nebulae × allHiddenStars), bounded by the budget's
    /// `maxNebulae` and the cell grouping's intrinsic membership sizes.
    private static func applyArcAnnotations(
        rawNebulae: [SemanticNebulaInstance],
        membersById: [Int64: [String]],
        request: ConstellationRenderRequest
    ) -> (nebulae: [SemanticNebulaInstance], labels: [ArcLabelOverlay]) {
        guard request.lens.frame.spatialLens != .projects else {
            return (rawNebulae, [])
        }
        guard case .prominent(_, let labelTopClusters) = request.frameVisualLanguage.arcHalos else {
            // Non-prominent arc halo treatments (off / ambient) don't
            // need any annotation; the renderer's existing halo path
            // already handles the visual.
            return (rawNebulae, [])
        }

        var annotated: [SemanticNebulaInstance] = []
        annotated.reserveCapacity(rawNebulae.count)
        var labels: [ArcLabelOverlay] = []
        var ranking = 0
        for nebula in rawNebulae {
            let memberIds = membersById[nebula.id] ?? []
            let vote = majorityArcLabel(
                memberIds: memberIds,
                messageIndex: request.messageIndex
            )
            guard let primary = vote.primary else {
                // No labelled messages → keep the existing rendering.
                annotated.append(nebula)
                ranking += 1
                continue
            }
            let labelHash = FrameColorationPalettes.fnv1a(primary.label.lowercased())
            let tint = FrameColorationPalettes.arcLabelTint(label: primary.label)
            let nested = vote.secondary
            let nestedHash: UInt32 = nested.map {
                FrameColorationPalettes.fnv1a($0.label.lowercased())
            } ?? 0

            let isTopCluster = ranking < labelTopClusters
                && nebula.memberCount >= arcLabelMinMembers
                && primary.confidence >= arcLabelMinConfidence

            // Override the nebula's averaged colour with the arc tint so
            // the halo + cloud share one identity.
            let colorOverlay = SIMD4<Float>(tint.x, tint.y, tint.z, nebula.color.w)
            annotated.append(SemanticNebulaInstance(
                id: nebula.id,
                position: nebula.position,
                color: colorOverlay,
                radius: nebula.radius,
                density: nebula.density,
                memberCount: nebula.memberCount,
                representativeVectorId: nebula.representativeVectorId,
                labelHash: labelHash,
                nestedSubclusterHash: nestedHash,
                isTopCluster: isTopCluster
            ))

            if isTopCluster {
                labels.append(ArcLabelOverlay(
                    clusterId: nebula.id,
                    position: nebula.position,
                    text: primary.label,
                    tint: SIMD3<Float>(tint.x, tint.y, tint.z),
                    memberCount: nebula.memberCount
                ))
            }
            ranking += 1
        }
        return (annotated, labels)
    }

    /// Build one contour landmark per semantic cluster. Each hub is anchored at the
    /// cluster's persisted semantic anchor and gets two radii:
    ///   - `radius`: transparent field reaching toward the visible cluster edge.
    ///   - `coreRadius`: dense hoverable centre point.
    ///
    /// Meaning members are packed around this same anchor, so the contour and
    /// its dots share one center while anchor-to-anchor embedding distances
    /// remain unchanged.
    /// This intentionally does not search for local density peaks: Meaning
    /// clusters are semantic groups first, and the visual marks the whole
    /// group rather than only its densest lobe.
    ///
    /// Ranking and brightness read visible support and how tight each
    /// community is in the stored semantic layout
    /// (`sourcePositionByMessageId`). The displayed footprint is
    /// population-sized by design, so its density cannot tell a tight
    /// community from a loose one; without source positions the displayed
    /// geometry is used. Position and extent always follow the display.
    ///
    /// Internal (not private) so planner tests can drive the hub pipeline
    /// directly with fixture clusters.
    static func meaningClusterHubs(
        clusters: [ClusterRecord],
        visibleStars: [MessageStarInstance],
        messageIndex: [String: MessageFilterRow],
        palette: MeaningClusterLensPalette,
        displayLimit: Int,
        centerOverrideByClusterId: [Int64: SIMD3<Float>] = [:],
        sourcePositionByMessageId: [String: SIMD3<Float>] = [:]
    ) -> [MeaningClusterHubInstance] {
        guard !clusters.isEmpty else { return [] }
        let displayLimit = min(meaningClusterHubMaxCount, max(0, displayLimit))
        guard displayLimit > 0 else { return [] }
        guard visibleStars.count >= meaningClusterHubMinVisibleMembers else { return [] }

        let positionsByCluster = meaningClusterPositionsByCluster(
            visibleStars: visibleStars,
            messageIndex: messageIndex
        )

        // Track members with their per-row cluster-attachment weight
        // (positionsByCluster strips identity for the anchor / spread math).
        // The weight is the Leiden attachment strength persisted by the
        // cluster worker — 1.0 for legacy rows — and it
        // becomes the member halo's affinity below.
        var membersByCluster: [Int64: [(position: SIMD3<Float>, weight: Float)]] = [:]
        membersByCluster.reserveCapacity(positionsByCluster.count)
        // The same pass records each cluster's visible received-date span
        // for the hover card, so presentation never rescans the index.
        var receivedDateRangeByCluster: [Int64: ClosedRange<Date>] = [:]
        receivedDateRangeByCluster.reserveCapacity(positionsByCluster.count)
        for star in visibleStars {
            guard let row = messageIndex[star.messageId], let clusterId = row.clusterId else { continue }
            membersByCluster[clusterId, default: []].append((star.position, row.clusterWeight ?? 1.0))
            if let receivedAt = row.receivedAt {
                if let range = receivedDateRangeByCluster[clusterId] {
                    receivedDateRangeByCluster[clusterId] =
                        min(range.lowerBound, receivedAt)...max(range.upperBound, receivedAt)
                } else {
                    receivedDateRangeByCluster[clusterId] = receivedAt...receivedAt
                }
            }
        }

        let clusterById = Dictionary(uniqueKeysWithValues: clusters.map { ($0.id, $0) })

        let dynamicFloor = max(
            meaningClusterHubMinVisibleMembers,
            min(12, Int(ceil(Double(visibleStars.count) * 0.0025)))
        )

        let cloudSpread = meaningCloudSpread(visibleStars.map(\.position))
        let usesSourceLayout = !sourcePositionByMessageId.isEmpty
        var sourcePositionsByCluster: [Int64: [SIMD3<Float>]] = [:]
        if usesSourceLayout {
            for star in visibleStars {
                guard let clusterId = messageIndex[star.messageId]?.clusterId else { continue }
                sourcePositionsByCluster[clusterId, default: []].append(
                    sourcePositionByMessageId[star.messageId] ?? star.position
                )
            }
        }
        let sourceCloudSpread = usesSourceLayout
            ? meaningCloudSpread(visibleStars.map {
                sourcePositionByMessageId[$0.messageId] ?? $0.position
            })
            : cloudSpread

        struct Candidate {
            let clusterId: Int64
            let center: SIMD3<Float>
            let visibleCount: Int
            /// Tightness in the stored semantic layout.
            let rawDensity: Float
            let compactness: Float
            let envelopeRadius: Float
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(positionsByCluster.count)

        for (clusterId, positions) in positionsByCluster {
            guard let cluster = clusterById[clusterId],
                  cluster.memberCount >= meaningClusterHubMinMembers,
                  positions.count >= dynamicFloor else {
                continue
            }

            // Persisted full-community anchor keeps node placement stable as
            // Moments and other filters reveal different member subsets.
            let center = centerOverrideByClusterId[clusterId] ?? cluster.centroid
            let displayed = meaningClusterTightness(
                positions: positions,
                center: center,
                cloudSpread: cloudSpread
            )
            // The stored layout's anchor is the persisted centroid.
            let tightness = usesSourceLayout
                ? meaningClusterTightness(
                    positions: sourcePositionsByCluster[clusterId] ?? positions,
                    center: cluster.centroid,
                    cloudSpread: sourceCloudSpread
                )
                : displayed
            let envelopeRadius = meaningClusterEnvelopeRadius(
                sortedDistances: displayed.sortedDistances,
                spread: displayed.spread,
                cloudSpread: cloudSpread,
                clusterCount: positionsByCluster.count
            )

            candidates.append(Candidate(
                clusterId: cluster.id,
                center: center,
                visibleCount: positions.count,
                rawDensity: tightness.rawDensity,
                compactness: tightness.compactness,
                envelopeRadius: envelopeRadius
            ))
        }
        guard !candidates.isEmpty else { return [] }

        let maxVisible = Float(max(1, candidates.map(\.visibleCount).max() ?? 1))
        let maxDensity = max(candidates.map(\.rawDensity).max() ?? 1, 0.0001)

        func rankingScore(_ candidate: Candidate) -> Float {
            let support = Float(candidate.visibleCount) / maxVisible
            let relativeDensity = sqrt(max(0, min(1, candidate.rawDensity / maxDensity)))
            return support * 0.55 + relativeDensity * 0.30 + candidate.compactness * 0.15
        }

        let ranked = candidates
            .sorted { lhs, rhs in
                let lhsScore = rankingScore(lhs)
                let rhsScore = rankingScore(rhs)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                if lhs.visibleCount != rhs.visibleCount {
                    return lhs.visibleCount > rhs.visibleCount
                }
                if lhs.rawDensity != rhs.rawDensity {
                    return lhs.rawDensity > rhs.rawDensity
                }
                return lhs.clusterId < rhs.clusterId
            }
            .prefix(displayLimit)

        // Distinct ramp hues are a privilege of the top-ranked clusters;
        // everyone else renders the palette's anchor base. Stop choice is
        // keyed on stable cluster identity inside that privileged set, so
        // rank churn between frames never flickers a cluster's hue.
        let rampStops = MeaningClusterLensPalette.stopAssignments(
            rankedClusterIds: ranked.map(\.clusterId)
        )

        var hubs: [MeaningClusterHubInstance] = []
        hubs.reserveCapacity(ranked.count)
        for candidate in ranked {
            let members = membersByCluster[candidate.clusterId] ?? []
            let support = Float(max(candidate.visibleCount, 1)) / maxVisible
            let relativeDensity = sqrt(max(0, min(1, candidate.rawDensity / maxDensity)))
            // Tightened curve: the blended score is gamma-shaped through
            // pow(_, 1.35) so the perceptual gap between an ambient contour
            // and a dense one widens. Floor at 0.10 keeps low-support contours
            // genuinely dim rather than crowding the mid-range.
            let blend = support * 0.45 + relativeDensity * 0.35 + candidate.compactness * 0.20
            let density = max(0.10, min(1, pow(blend, 1.35)))
            let coreRadius = meaningClusterCoreRadius(
                memberCount: candidate.visibleCount,
                density: density,
                clusterCount: ranked.count
            )
            // One selectable semantic identity has one visible contour. Every
            // in-scope member contributes to that contour, including peripheral
            // members; density changes brightness, never membership extent.
            let memberHalos = Self.meaningClusterMemberHalos(clusterMembers: members)
            hubs.append(MeaningClusterHubInstance(
                clusterId: candidate.clusterId,
                position: candidate.center,
                radius: candidate.envelopeRadius,
                coreRadius: coreRadius,
                memberCount: candidate.visibleCount,
                color: palette.rgb(forStop: rampStops[candidate.clusterId]),
                density: density,
                memberHalos: memberHalos,
                receivedDateRange: receivedDateRangeByCluster[candidate.clusterId]
            ))
        }
        return hubs
    }

    private static func meaningCloudSpread(_ positions: [SIMD3<Float>]) -> Float {
        let center = averagePosition(positions)
        return max(0.05, positions.map { simd_length($0 - center) }.max() ?? 0.05)
    }

    /// Spread, density and compactness of one cluster's positions around its
    /// anchor, relative to the spread of the whole visible field.
    private static func meaningClusterTightness(
        positions: [SIMD3<Float>],
        center: SIMD3<Float>,
        cloudSpread: Float
    ) -> (sortedDistances: [Float], spread: Float, rawDensity: Float, compactness: Float) {
        let distances = positions.map { simd_length($0 - center) }.sorted()
        let meanSquareDistance = distances.reduce(Float(0)) { partial, distance in
            partial + distance * distance
        } / Float(max(1, distances.count))
        let spread = max(0.002, sqrt(meanSquareDistance))
        let rawDensity = Float(positions.count) / max(spread * spread, 0.0004)
        let compactness = max(0, min(1, 1 - min(1, spread / max(cloudSpread, 0.0001))))
        return (distances, spread, rawDensity, compactness)
    }

    private static func meaningClusterEnvelopeRadius(
        sortedDistances: [Float],
        spread: Float,
        cloudSpread: Float,
        clusterCount: Int
    ) -> Float {
        _ = spread
        _ = cloudSpread
        _ = clusterCount
        // The contour is the spatial statement of membership. Its interaction
        // envelope therefore reaches beyond the farthest member dot; density
        // controls visual intensity, not which members the cloud encloses.
        guard sortedDistances.isEmpty == false else { return 0.020 }
        return max(0.020, (sortedDistances.last ?? 0) + 0.012)
    }

    /// Dense centre-point world radius derived from visible support and
    /// local density. This remains small even when the transparent field is
    /// large, which preserves the hoverable "semantic nucleus" the sandbox
    /// mockup established.
    private static func meaningClusterCoreRadius(
        memberCount: Int,
        density: Float,
        clusterCount: Int
    ) -> Float {
        let countTerm = min(1, log2(Float(max(1, memberCount)) + 1) / 9)
        let densityTerm = sqrt(max(0, min(1, density)))
        // Many simultaneous contours shrink each one so the constellation
        // doesn't become a wall of contours. Floor at 0.78× keeps every core
        // legible even when the scope surfaces the full cap.
        let crowdedScale = clusterCount > 10
            ? max(0.78, sqrt(10 / Float(clusterCount)))
            : 1
        let radius = (0.014 + densityTerm * 0.012 + countTerm * 0.010) * crowdedScale
        return max(0.014, min(0.036, radius))
    }

    /// Member halos for the metaball body: every visible cluster member
    /// contributes, weighted by its persisted cluster-attachment strength
    /// (`MessageFilterRow.clusterWeight`; 1.0 for rows without one). The
    /// renderer aggregates these into representative blobs, so peripheral
    /// members still pull the silhouette toward them instead of being
    /// median-filtered away.
    ///
    /// Internal (not private) so planner tests can pin complete membership
    /// and the weight passthrough directly.
    static func meaningClusterMemberHalos(
        clusterMembers: [(position: SIMD3<Float>, weight: Float)]
    ) -> [MeaningClusterMemberHalo] {
        guard !clusterMembers.isEmpty else { return [] }
        return clusterMembers.map {
            MeaningClusterMemberHalo(position: $0.position, affinity: $0.weight)
        }
    }

    private static func meaningClusterPositionsByCluster(
        visibleStars: [MessageStarInstance],
        messageIndex: [String: MessageFilterRow]
    ) -> [Int64: [SIMD3<Float>]] {
        var positionsByCluster: [Int64: [SIMD3<Float>]] = [:]
        for star in visibleStars {
            guard let clusterId = messageIndex[star.messageId]?.clusterId else { continue }
            positionsByCluster[clusterId, default: []].append(star.position)
        }
        return positionsByCluster
    }

    /// Compute per-cluster visual stats used to size and shade the contour.
    /// All values are relative to the candidate set — `density` and
    /// `compactness` express each cluster's standing **among the
    /// candidates**, not against an absolute world-space yardstick.
    /// That sidesteps the failure mode where the entire visible field
    /// is tightly packed and an absolute compactness threshold filters
    /// every real cluster out.
    private static func meaningClusterVisualStats(
        clusters: [ClusterRecord],
        positionsByCluster: [Int64: [SIMD3<Float>]],
        internalWeights: [Int64: Float]
    ) -> [Int64: MeaningClusterVisualStats] {
        guard !clusters.isEmpty else { return [:] }

        var centerByCluster: [Int64: SIMD3<Float>] = [:]
        var visibleCountByCluster: [Int64: Int] = [:]
        var localSpreadByCluster: [Int64: Float] = [:]
        var rawDensityByCluster: [Int64: Float] = [:]
        centerByCluster.reserveCapacity(clusters.count)
        visibleCountByCluster.reserveCapacity(clusters.count)
        localSpreadByCluster.reserveCapacity(clusters.count)
        rawDensityByCluster.reserveCapacity(clusters.count)

        for cluster in clusters {
            let positions = positionsByCluster[cluster.id] ?? []
            let center = averagePosition(positions)
            centerByCluster[cluster.id] = center
            visibleCountByCluster[cluster.id] = positions.count
            let localSpread: Float
            if positions.count > 1 {
                let meanSquareDistance = positions.reduce(Float(0)) { partial, position in
                    let delta = position - center
                    return partial + simd_dot(delta, delta)
                } / Float(positions.count)
                localSpread = max(0.002, sqrt(meanSquareDistance))
            } else {
                localSpread = 0.002
            }
            localSpreadByCluster[cluster.id] = localSpread
            rawDensityByCluster[cluster.id] = Float(positions.count) / max(localSpread * localSpread, 0.0004)
        }

        // Normalize spreads and densities across the candidate set so
        // every score lands in [0, 1] regardless of the absolute scale
        // of the active layout (cosine-only vs. force-directed frames
        // produce different world spans).
        let maxSpread = max(localSpreadByCluster.values.max() ?? 1, 0.0001)
        let maxDensity = max(rawDensityByCluster.values.max() ?? 1, 0.0001)

        return Dictionary(uniqueKeysWithValues: clusters.map { cluster in
            let spread = localSpreadByCluster[cluster.id] ?? maxSpread
            let raw = rawDensityByCluster[cluster.id] ?? 0
            let relativeDensity = sqrt(max(0, min(1, raw / maxDensity)))
            // Compactness: 1 when this cluster is the tightest in scope,
            // 0 when it's the loosest. Always defined regardless of the
            // absolute world-space spread.
            let compactness = 1 - min(1, spread / maxSpread)
            let density = max(0.10, min(1, relativeDensity * 0.65 + compactness * 0.35))
            let internalWeight = internalWeights[cluster.id] ?? 0
            let intensity = max(0.10, min(1, density * 0.50 + compactness * 0.25 + internalWeight * 0.25))
            return (
                cluster.id,
                MeaningClusterVisualStats(
                    center: centerByCluster[cluster.id] ?? cluster.centroid,
                    visibleMemberCount: visibleCountByCluster[cluster.id] ?? 0,
                    internalWeight: internalWeight,
                    density: density,
                    compactness: compactness,
                    intensity: intensity
                )
            )
        })
    }

    private static func meaningClusterInternalWeights(
        fibers: [AffinityFiberInstance],
        messageIndex: [String: MessageFilterRow]
    ) -> [Int64: Float] {
        var totals: [Int64: Float] = [:]
        var counts: [Int64: Float] = [:]
        for fiber in fibers {
            guard let clusterId = messageIndex[fiber.sourceMessageId]?.clusterId,
                  clusterId == messageIndex[fiber.targetMessageId]?.clusterId else {
                continue
            }
            let weight = max(0, min(1, fiber.strength)) * (0.70 + max(0, min(1, fiber.confidence)) * 0.30)
            totals[clusterId, default: 0] += weight
            counts[clusterId, default: 0] += 1
        }
        return Dictionary(uniqueKeysWithValues: totals.map { clusterId, total in
            let count = max(1, counts[clusterId] ?? 1)
            return (clusterId, max(0, min(1, total / count)))
        })
    }

    private static func averagePosition(_ positions: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !positions.isEmpty else { return .zero }
        let total = positions.reduce(SIMD3<Float>.zero, +)
        return total / Float(positions.count)
    }

    private struct ArcLabelVote: Sendable {
        let label: String
        let confidence: Float   // dominant share over labelled members
    }

    private struct ArcLabelVoteResult: Sendable {
        let primary: ArcLabelVote?
        let secondary: ArcLabelVote?
    }

    /// Majority canonical tag across the cluster's tagged members, with the
    /// runner-up as the secondary (nested aspect) candidate.
    ///
    /// Each member contributes one vote weighted by its tag score so
    /// confident tags dominate weak ones; alphabetical tie-break keeps
    /// the output stable across packets.
    private static func majorityArcLabel(
        memberIds: [String],
        messageIndex: [String: MessageFilterRow]
    ) -> ArcLabelVoteResult {
        guard !memberIds.isEmpty else { return ArcLabelVoteResult(primary: nil, secondary: nil) }
        var weights: [UUID: (display: String, weight: Float)] = [:]
        var labelledCount: Int = 0
        for id in memberIds {
            guard let row = messageIndex[id],
                  let dimensions = row.dimensions else { continue }
            guard let chosen = SemanticTagProjectionPresentation.canonical(dimensions.semanticTags).first,
                  chosen.score >= 0.10 else { continue }
            let trimmed = chosen.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var entry = weights[chosen.tagID] ?? (display: trimmed, weight: 0)
            entry.weight += Float(chosen.weightedScore)
            weights[chosen.tagID] = entry
            labelledCount += 1
        }
        guard labelledCount > 0 else { return ArcLabelVoteResult(primary: nil, secondary: nil) }
        let ranked = weights.values
            .sorted { lhs, rhs in
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                return lhs.display < rhs.display
            }
        guard let top = ranked.first else { return ArcLabelVoteResult(primary: nil, secondary: nil) }
        let totalWeight = ranked.reduce(Float(0)) { $0 + $1.weight }
        let primary = ArcLabelVote(
            label: top.display,
            confidence: totalWeight > 0 ? top.weight / totalWeight : 0
        )

        let secondary: ArcLabelVote?
        if ranked.count >= 2 {
            let runnerUp = ranked[1]
            let remainder = totalWeight - top.weight
            let share = remainder > 0 ? runnerUp.weight / remainder : 0
            if share >= arcNestedAspectThreshold {
                secondary = ArcLabelVote(label: runnerUp.display, confidence: share)
            } else {
                secondary = nil
            }
        } else {
            secondary = nil
        }
        return ArcLabelVoteResult(primary: primary, secondary: secondary)
    }

    // MARK: - Frame-aware account-color modulation

    /// Modulate the account-derived base color per the active frame's
    /// `Coloration`. The base hue is always preserved — only saturation
    /// (and never opacity) varies.
    ///
    /// Exposed at `internal` (rather than `private`) so the address-
    /// direction logic in `.accountColorMajorOnly` can be exercised in
    /// unit tests without standing up a full packet fixture. Call sites
    /// outside this type are strictly tests.
    static func modulateAccountColor(
        base: SIMD4<Float>,
        messageId: String,
        coloration: FrameVisualLanguage.Coloration,
        messageIndex: [String: MessageFilterRow],
        majorCorrespondents: Set<String>,
        referenceNow: Date
    ) -> SIMD4<Float> {
        switch coloration {
        case .accountColor:
            return base
        case .accountColorMajorOnly:
            guard let row = messageIndex[messageId] else { return base }
            // Mirror `MessageGraphEdgeProvider.correspondentSignals`: the
            // "correspondent" is the other party, not the From: address.
            // For sent mail, `fromAddress` is the user's own identity and
            // is never in `majorCorrespondents` (the set is built from
            // inbound mail only), which would otherwise desaturate every
            // message sent to a major correspondent — making the user's
            // outbound side of the exchange look like long-tail noise
            // even though the layout force has clustered it next to the
            // inbound side.
            //
            // Sent mail consults `recipientAddresses` (To + Cc + Bcc) so
            // a sent message that CC'd a major correspondent without
            // putting them on the To line still reads as vivid — that's
            // the role-set the layout force uses too, so colour and
            // layout agree on what counts as "the same correspondent."
            // Received mail consults the sender.
            let candidates: [String]
            if row.isSentByUser {
                // Pre-lowercased by `MessageFilterRow`; superset of
                // `toAddresses` for messages with Cc/Bcc participants.
                candidates = row.recipientAddresses
            } else {
                candidates = [row.fromAddress.lowercased()]
            }
            let isMajor = candidates.contains { majorCorrespondents.contains($0) }
            return isMajor
                ? base
                : FrameColorationPalettes.neutralCorrespondent(base: base)
        }
    }

    /// Top-N senders by *recency-weighted* message count. Restricted to
    /// frames that consume the set. Top-N target follows
    /// `N = max(20, min(80, ⌈M / 200⌉))` so small mailboxes get ~20 majors
    /// and large mailboxes cap at ~80.
    ///
    /// Recency weighting keeps the ranking from being tyrannized by
    /// long-dormant high-volume senders (years of newsletter clutter would
    /// otherwise crowd out a meaningful but recent correspondent). Each
    /// message contributes weight ≈ 1.0 if received in the last week,
    /// decaying smoothly to a 0.3 floor at ~1 year+. Messages without a
    /// `receivedAt` fall to the floor.
    /// Exposed at `internal` rather than `private` so the planner-level
    /// pinning union behaviour can be unit-tested without standing up a
    /// full `ConstellationRenderPacket` fixture. The function remains a
    /// planner implementation detail — call sites outside this type are
    /// strictly tests.
    static func majorCorrespondentAddresses(
        request: ConstellationRenderRequest,
        coloration: FrameVisualLanguage.Coloration
    ) -> Set<String> {
        guard coloration == .accountColorMajorOnly else { return [] }
        var weights: [String: Double] = [:]
        weights.reserveCapacity(min(request.messageIndex.count, 4_096))
        let reference = Date.now
        for row in request.messageIndex.values {
            // Only inbound mail counts toward "major correspondent" weight —
            // self-sent mail would distort the ranking toward the user's own
            // identities.
            guard row.isSentByUser == false else { continue }
            let address = row.fromAddress.lowercased()
            guard !address.isEmpty else { continue }
            let weight = recencyWeight(receivedAt: row.receivedAt, reference: reference)
            weights[address, default: 0] += weight
        }
        let m = weights.count
        let n = max(20, min(80, Int((Double(m) / 200.0).rounded(.up))))
        let recencyMajors: Set<String>
        if weights.count <= n {
            recencyMajors = Set(weights.keys)
        } else {
            recencyMajors = Set(
                weights
                    .sorted { lhs, rhs in
                        if lhs.value != rhs.value { return lhs.value > rhs.value }
                        return lhs.key < rhs.key
                    }
                    .prefix(n)
                    .map(\.key)
            )
        }
        // Pinned addresses always count as major regardless of recency
        // volume. The user has explicitly said "this matters" — we don't
        // re-litigate that against the recency algorithm.
        return recencyMajors.union(request.pinnedCorrespondents)
    }

    /// Per-message recency weight in `[0.3, 1.0]`. Recent stays at 1.0
    /// through ~7 days, then decays smoothly toward the 0.3 floor at
    /// 1 year+. Mirrors `FrameColorationPalettes.recencySaturationMultiplier`
    /// so the same notion of "recent" drives both the saturation gradient
    /// and the major-correspondent ranking.
    private static func recencyWeight(receivedAt: Date?, reference: Date) -> Double {
        guard let receivedAt else { return 0.3 }
        let ageDays = max(0, reference.timeIntervalSince(receivedAt)) / 86_400
        return FrameColorationPalettes.recencySaturationMultiplier(ageDays: ageDays)
    }

    nonisolated static func expandedPeopleFocusStars(
        _ rawStars: [MessageStarInstance],
        messageIndex: [String: MessageFilterRow],
        filter: VectorFilter,
        userAddresses: Set<String>,
        lockedCorrespondentEmail: String?,
        lockedCorrespondentMessageIds: Set<String> = [],
        peopleFocus: PeopleFrameFocus?,
        vectorIdsByMessage: [String: Set<Int64>],
        colorForMessage: (String) -> SIMD4<Float>,
        signalForMessage: (String, Set<Int64>) -> VisualSignalState,
        glyphForMessage: (String) -> UInt8,
        emergeMaskForMessage: (String) -> UInt8,
        defaultTintForMessage: (String) -> SIMD3<Float>
    ) -> [MessageStarInstance] {
        guard let focusedEmail = lockedPeopleFocusEmail(
            lockedCorrespondentEmail: lockedCorrespondentEmail,
            peopleFocus: peopleFocus
        ) else {
            return rawStars
        }

        var seenMessageIds = Set(rawStars.map(\.messageId))
        let userAddressSet = Set(userAddresses.map(normalizedEmail).filter { !$0.isEmpty })
        let anchorPosition = peopleFocus?.pinnedHubWorldPosition
            ?? rawStars.first?.position
            ?? .zero
        var expanded = rawStars
        let hasLockedCorrespondentScope = !normalizedEmail(lockedCorrespondentEmail ?? "").isEmpty

        let scopedRows: [(key: String, value: MessageFilterRow)]
        if hasLockedCorrespondentScope {
            scopedRows = lockedCorrespondentMessageIds
                .compactMap { messageId -> (key: String, value: MessageFilterRow)? in
                    guard seenMessageIds.contains(messageId) == false,
                          let row = messageIndex[messageId],
                          messageRowPassesCurrentFilter(row, filter: filter) else { return nil }
                    return (messageId, row)
                }
                .sorted { lhs, rhs in
                    let leftDate = lhs.value.receivedAt ?? lhs.value.ingestedAt
                    let rightDate = rhs.value.receivedAt ?? rhs.value.ingestedAt
                    if leftDate != rightDate { return leftDate < rightDate }
                    return lhs.key < rhs.key
                }
        } else {
            scopedRows = messageIndex
                .filter { messageId, row in
                    seenMessageIds.contains(messageId) == false
                        && messageRowPassesCurrentFilter(row, filter: filter)
                        && peopleParticipantSet(row: row, userAddresses: userAddressSet).contains(focusedEmail)
                }
                .sorted { lhs, rhs in
                    let leftDate = lhs.value.receivedAt ?? lhs.value.ingestedAt
                    let rightDate = rhs.value.receivedAt ?? rhs.value.ingestedAt
                    if leftDate != rightDate { return leftDate < rightDate }
                    return lhs.key < rhs.key
                }
            }

        for (messageId, row) in scopedRows {
            let vectorIds = vectorIdsByMessage[messageId] ?? []
            let representativeVectorId = vectorIds.min()
                ?? syntheticPeopleFocusVectorId(messageId: messageId)
            let signalIds = vectorIds.isEmpty ? [representativeVectorId] : vectorIds
            expanded.append(
                MessageStarInstance(
                    messageId: messageId,
                    representativeVectorId: representativeVectorId,
                    position: anchorPosition,
                    color: colorForMessage(messageId),
                    radius: 0.012,
                    vectorCount: max(vectorIds.count, 1),
                    evidenceWeight: 1,
                    arrivalTime: (row.receivedAt ?? row.ingestedAt).timeIntervalSince1970,
                    lastMoveMagnitude: 0,
                    signal: signalForMessage(messageId, signalIds),
                    glyphCode: glyphForMessage(messageId),
                    emergeMask: emergeMaskForMessage(messageId),
                    defaultCorrespondentTint: defaultTintForMessage(messageId)
                )
            )
            seenMessageIds.insert(messageId)
        }

        return expanded
    }

    private nonisolated static func lockedPeopleFocusEmail(
        lockedCorrespondentEmail: String?,
        peopleFocus: PeopleFrameFocus?
    ) -> String? {
        let locked = normalizedEmail(lockedCorrespondentEmail ?? "")
        if !locked.isEmpty { return locked }
        guard let peopleFocus, peopleFocus.matchesAnyRole else { return nil }
        let focused = normalizedEmail(peopleFocus.query)
        return focused.isEmpty ? nil : focused
    }

    private nonisolated static func peopleParticipantSet(
        row: MessageFilterRow,
        userAddresses: Set<String>
    ) -> Set<String> {
        let rawAddresses = row.isSentByUser
            ? row.recipientAddresses
            : [row.fromAddress] + row.recipientAddresses
        var participants: Set<String> = []
        for rawAddress in rawAddresses {
            let address = normalizedEmail(rawAddress)
            if !address.isEmpty, userAddresses.contains(address) == false {
                participants.insert(address)
            }
        }
        return participants
    }

    private nonisolated static func peopleSunStats(
        candidateMessageIds: Set<String>,
        messageIndex: [String: MessageFilterRow],
        filter: VectorFilter,
        userAddresses: Set<String>,
        embargoedMessageIds: Set<String>
    ) -> (
        correspondentCount: Int,
        sentCount: Int,
        receivedCount: Int,
        openObligationCount: Int
    ) {
        var directionIndependentFilter = filter
        directionIndependentFilter.sentStates = nil
        let normalizedUserAddresses = Set(
            userAddresses
                .map(normalizedEmail)
                .filter { !$0.isEmpty }
        )
        var correspondents: Set<String> = []
        var sentCount = 0
        var receivedCount = 0
        var openObligationCount = 0

        for messageId in candidateMessageIds {
            guard !embargoedMessageIds.contains(messageId),
                  let row = messageIndex[messageId],
                  messageRowPassesCurrentFilter(row, filter: directionIndependentFilter) else {
                continue
            }
            let participants = peopleParticipantSet(
                row: row,
                userAddresses: normalizedUserAddresses
            )
            guard !participants.isEmpty else { continue }
            correspondents.formUnion(participants)
            if row.isSentByUser {
                sentCount += 1
            } else {
                receivedCount += 1
                if row.isActionable == true || row.requiresConfirmation == true {
                    openObligationCount += 1
                }
            }
        }

        return (
            correspondentCount: correspondents.count,
            sentCount: sentCount,
            receivedCount: receivedCount,
            openObligationCount: openObligationCount
        )
    }

    private nonisolated static func normalizedEmail(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private nonisolated static func messageRowPassesCurrentFilter(
        _ row: MessageFilterRow,
        filter: VectorFilter
    ) -> Bool {
        guard ConstellationMessageFilter.matches(row, filter: filter) else { return false }
        guard let timeRange = filter.timeRange else { return true }
        guard let receivedAt = row.receivedAt else { return false }
        return timeRange.contains(receivedAt)
    }

    private nonisolated static func syntheticPeopleFocusVectorId(messageId: String) -> Int64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in messageId.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let positive = Int64(hash & 0x3fff_ffff_ffff_ffff)
        return -max(positive, 1)
    }

    private static func passesGlobalFilter(
        _ row: VectorRenderSourceRow,
        request: ConstellationRenderRequest
    ) -> Bool {
        if request.filter.collections.isEmpty {
            return false
        }
        if !request.filter.collections.contains(row.collection) {
            return false
        }
        if let timeRange = request.filter.timeRange {
            guard let messageReceivedAt = row.messageReceivedAt else {
                return false
            }
            let messageDate = Date(timeIntervalSince1970: messageReceivedAt)
            guard timeRange.contains(messageDate) else {
                return false
            }
        }
        guard let messageRow = request.messageIndex[row.messageId] else {
            return false
        }
        return ConstellationMessageFilter.matches(messageRow, filter: request.filter)
    }

    private static func renderSourceRow(from record: VectorRecord) -> VectorRenderSourceRow? {
        guard let x = record.layoutX,
              let y = record.layoutY,
              let z = record.layoutZ else {
            return nil
        }
        return VectorRenderSourceRow(
            vectorId: record.vectorId,
            messageId: record.messageId,
            collection: record.collection,
            chunkIndex: record.chunkIndex,
            layout: SIMD3<Float>(x, y, z),
            arrivalTime: record.arrivalTime,
            lastMoveMagnitude: record.lastMoveMagnitude ?? 0,
            messageReceivedAt: record.messageReceivedAt,
            entityKind: record.entityKind,
            entityScore: record.entityScore
        )
    }

    private func makeMessageFibers(
        rows: [VectorRenderSourceRow],
        visibleStars: [MessageStarInstance],
        request: ConstellationRenderRequest,
        vectorIdsByMessage: [String: Set<Int64>],
        lockFocusGradeByMessageId: [String: Float],
        meaningClusterColorById: [Int64: SIMD3<Float>] = [:]
    ) async throws -> [AffinityFiberInstance] {
        guard visibleStars.count > 1, request.budget.maxFibers > 0 else { return [] }
        let visibleByMessage = Dictionary(uniqueKeysWithValues: visibleStars.map { ($0.messageId, $0) })
        let visibleMessageIds = Set(visibleByMessage.keys)
        let sourceVectorIds = visibleMessageIds.flatMap { messageId in
            Array(vectorIdsByMessage[messageId] ?? [])
        }
        let vectorToMessage = Dictionary(uniqueKeysWithValues: rows.map { ($0.vectorId, $0.messageId) })
        let edges = try await vectorEdges(for: sourceVectorIds, request: request)

        struct Pair: Hashable {
            let a: String
            let b: String
            init(_ left: String, _ right: String) {
                if left < right {
                    a = left; b = right
                } else {
                    a = right; b = left
                }
            }
        }
        struct Accumulator {
            var strength: Float
            var confidence: Float
            var sourceVectorId: Int64
            var targetVectorId: Int64
            /// Strongest contributing edge kind. Used by the renderer to
            /// pick a per-kind tint in the fiber fragment shader, and by
            /// selective-strand frames to keep only their chosen edge kind.
            var dominantKind: VectorEdgeKind?
            /// Maximum strength observed for `dominantKind`. Used as the
            /// tie-break when later edges of a different kind arrive.
            var dominantStrength: Float
        }

        var accumulators: [Pair: Accumulator] = [:]
        for edge in edges {
            guard let sourceMessage = vectorToMessage[edge.sourceId],
                  let targetMessage = vectorToMessage[edge.targetId],
                  sourceMessage != targetMessage,
                  visibleMessageIds.contains(sourceMessage),
                  visibleMessageIds.contains(targetMessage) else { continue }
            let pair = Pair(sourceMessage, targetMessage)
            let strength = max(0, min(1, edge.similarity))
            if var existing = accumulators[pair] {
                // Snapshot the pre-update values so the representative-pair
                // and dominant-kind comparisons aren't reading the just-
                // mutated `strength`.
                let previousStrength = existing.strength
                let previousDominantStrength = existing.dominantStrength
                existing.strength = max(existing.strength, strength)
                existing.confidence += 1
                if strength >= previousStrength {
                    existing.sourceVectorId = edge.sourceId
                    existing.targetVectorId = edge.targetId
                }
                // Dominant-kind selection: strictly greater strength wins
                // outright; on an exact tie, a structural kind (thread /
                // correspondent / temporal / action / category / arc)
                // beats cosine or an unannotated edge — otherwise the
                // first cosine fibre would silently outvote a tied thread
                // fibre and a thread-only selective-strand filter would
                // drop the pair entirely.
                let existingIsBackground = existing.dominantKind == nil || existing.dominantKind == .cosine
                let incomingIsBackground = edge.kind == nil || edge.kind == .cosine
                if strength > previousDominantStrength {
                    existing.dominantKind = edge.kind
                    existing.dominantStrength = strength
                } else if strength == previousDominantStrength,
                          existingIsBackground,
                          !incomingIsBackground {
                    existing.dominantKind = edge.kind
                    existing.dominantStrength = strength
                }
                accumulators[pair] = existing
            } else {
                accumulators[pair] = Accumulator(
                    strength: strength,
                    confidence: 1,
                    sourceVectorId: edge.sourceId,
                    targetVectorId: edge.targetId,
                    dominantKind: edge.kind,
                    dominantStrength: strength
                )
            }
        }

        let strandPolicy = request.frameVisualLanguage.threadStrands
        let isMeaningLens = request.lens.frame.spatialLens == .meaning
        let fiberLimit = isMeaningLens
            ? min(request.budget.maxFibers, max(120, min(720, visibleStars.count)))
            : request.budget.maxFibers

        let candidates = accumulators.compactMap { pair, acc -> AffinityFiberInstance? in
            // A fiber inside the locked neighbourhood carries the dimmer of
            // its two endpoints' focus grades, so strand brightness matches
            // the graded stars it connects instead of snapping to binary 1.
            let lockFocus: Float = min(
                lockFocusGradeByMessageId[pair.a] ?? 0,
                lockFocusGradeByMessageId[pair.b] ?? 0
            )
            if isMeaningLens {
                let weightedStrength = acc.strength * (0.70 + min(1, acc.confidence / 4) * 0.30)
                if meaningClusterColorById.isEmpty || lockFocus > 0 {
                    // No contour is on screen (cluster display off, or
                    // detection not ready), or both endpoints lie in a locked
                    // node's graded neighbourhood, where the lock fades the
                    // contours out: strong semantic neighbours draw at the
                    // pre-contour bar. The rest of a locked field keeps the
                    // contour rules, so locking does not rewire it.
                    guard weightedStrength >= 0.64 else { return nil }
                } else {
                    let sourceClusterId = request.messageIndex[pair.a]?.clusterId
                    let targetClusterId = request.messageIndex[pair.b]?.clusterId
                    let sharesCluster = sourceClusterId != nil && sourceClusterId == targetClusterId
                    let sourceIsDisplayed = sourceClusterId.map {
                        meaningClusterColorById[$0] != nil
                    } ?? false
                    let targetIsDisplayed = targetClusterId.map {
                        meaningClusterColorById[$0] != nil
                    } ?? false
                    guard sourceIsDisplayed && targetIsDisplayed else { return nil }
                    // Very strong cross-boundary neighbours are the explicit
                    // secondary-membership disclosure. Keeping their bar high
                    // prevents the contour view from becoming a line mesh.
                    let threshold: Float = sharesCluster ? 0.62 : 0.84
                    guard weightedStrength >= threshold else {
                        return nil
                    }
                }
            }
            // Selective strands keep only edges of the frame's chosen
            // kind so the scene communicates one relationship at a time:
            // `.people` keeps correspondent.
            // Edges with no annotated kind drop out (they were cosine
            // fibres before the kind-tagging pass).
            if case .selective(let allowedKind) = strandPolicy,
               acc.dominantKind != allowedKind {
                return nil
            }
            guard let fromStar = visibleByMessage[pair.a],
                  let toStar = visibleByMessage[pair.b] else { return nil }
            let active = max(fromStar.signal.intensity, toStar.signal.intensity)
            let sourceClusterId = request.messageIndex[pair.a]?.clusterId
            let targetClusterId = request.messageIndex[pair.b]?.clusterId
            let sharedClusterId = sourceClusterId == targetClusterId ? sourceClusterId : nil
            let presentationColor: SIMD4<Float>?
            let strokeWidth: Float
            if isMeaningLens {
                let rgb = sharedClusterId.flatMap { meaningClusterColorById[$0] }
                    ?? SIMD3<Float>(0.64, 0.70, 0.82)
                let alpha: Float = 0.08 + acc.strength * 0.12
                presentationColor = SIMD4<Float>(rgb.x, rgb.y, rgb.z, alpha)
                strokeWidth = 1.0
            } else {
                presentationColor = nil
                strokeWidth = 1.0
            }
            return AffinityFiberInstance(
                sourceMessageId: pair.a,
                targetMessageId: pair.b,
                sourceVectorId: acc.sourceVectorId,
                targetVectorId: acc.targetVectorId,
                from: fromStar.position,
                to: toStar.position,
                strength: acc.strength,
                confidence: min(1, acc.confidence / 4),
                strokeWidthPixels: strokeWidth,
                signal: VisualSignalState(lockFocus: lockFocus, search: active, citation: active),
                edgeKind: acc.dominantKind,
                presentationColor: presentationColor
            )
        }
        .sorted {
            if $0.signal.intensity != $1.signal.intensity {
                return $0.signal.intensity > $1.signal.intensity
            }
            if $0.strength != $1.strength { return $0.strength > $1.strength }
            return $0.confidence > $1.confidence
        }
        return Array(candidates.prefix(fiberLimit))
    }

    private func vectorEdges(for vectorIds: [Int64], request: ConstellationRenderRequest) async throws -> [VectorNeighbor] {
        guard vectorIds.isEmpty == false else { return [] }
        let topK = 12
        let weights = FrameForceWeights.forFrame(request.lens.frame)
        var weighted: [VectorNeighbor] = []

        let cosine = try neighborsStore.neighborsOf(vectorIds: vectorIds, limit: topK)
        weighted.append(contentsOf: Self.flatten(cosine, weight: weights.cosine, kind: .cosine))

        if request.lens.frame != .defaultFrame, let provider = request.frameEdgeProvider {
            if weights.thread > 0 {
                let thread = try await provider.threadEdges(for: vectorIds, topK: topK)
                weighted.append(contentsOf: Self.flatten(thread, weight: weights.thread, kind: .thread))
            }
            if weights.correspondent > 0 {
                let correspondent = try await provider.correspondentEdges(for: vectorIds, topK: topK)
                weighted.append(contentsOf: Self.flatten(correspondent, weight: weights.correspondent, kind: .correspondent))
            }
            if weights.temporal > 0 {
                let temporal = try await provider.temporalEdges(for: vectorIds, topK: topK, windowDays: 21)
                weighted.append(contentsOf: Self.flatten(temporal, weight: weights.temporal, kind: .temporal))
            }
            if weights.action > 0 {
                let action = try await provider.actionEdges(for: vectorIds, topK: topK)
                weighted.append(contentsOf: Self.flatten(action, weight: weights.action, kind: .action))
            }
            if weights.classification > 0 {
                let classification = try await provider.classificationEdges(for: vectorIds, topK: topK)
                weighted.append(contentsOf: Self.flatten(
                    classification,
                    weight: weights.classification,
                    kind: .classification
                ))
            }
            if weights.arc > 0 {
                let arc = try await provider.arcEdges(for: vectorIds, topK: topK)
                weighted.append(contentsOf: Self.flatten(arc, weight: weights.arc, kind: .arc))
            }
        }
        return weighted
    }

    private static func peopleRelationFibers(
        _ relations: [PersonRelationInstance],
        maxCount: Int
    ) -> [AffinityFiberInstance] {
        guard maxCount > 0, !relations.isEmpty else { return [] }
        let maxStrength = max(relations.map(\.dilutedStrength).max() ?? 1, 0.0001)
        return relations
            .sorted {
                if $0.dilutedStrength != $1.dilutedStrength {
                    return $0.dilutedStrength > $1.dilutedStrength
                }
                return $0.id < $1.id
            }
            .prefix(maxCount)
            .map { relation in
                let normalized = max(0.12, min(1, relation.dilutedStrength / maxStrength))
                return AffinityFiberInstance(
                    sourceMessageId: "person:\(relation.sourceEmail)",
                    targetMessageId: "person:\(relation.targetEmail)",
                    sourceVectorId: 0,
                    targetVectorId: 0,
                    from: relation.sourcePosition,
                    to: relation.targetPosition,
                    strength: normalized,
                    confidence: min(1, Float(relation.sharedMessageCount) / 4),
                    strokeWidthPixels: PeopleVisualMetrics.sharedStrokeWidthPixels(
                        isShared: true,
                        sharedParticipantCount: relation.sharedMessageCount,
                        sharedStrength: normalized
                    ),
                    signal: .none,
                    edgeKind: .correspondent
                )
            }
    }

    private static func flatten(
        _ grouped: [Int64: [VectorNeighbor]],
        weight: Float,
        kind: VectorEdgeKind
    ) -> [VectorNeighbor] {
        guard weight > 0 else { return [] }
        let clamped = max(0, min(2, weight))
        return grouped.values.flatMap { rows in
            rows.map {
                VectorNeighbor(
                    sourceId: $0.sourceId,
                    targetId: $0.targetId,
                    similarity: min(1, $0.similarity * clamped),
                    rank: $0.rank,
                    kind: kind
                )
            }
        }
    }

    private static func visibleStarsForLens(
        _ stars: [MessageStarInstance],
        request: ConstellationRenderRequest,
        vectorIdsByMessage: [String: Set<Int64>]
    ) -> [MessageStarInstance] {
        let selected = selectVisibleStars(
            stars,
            request: request,
            vectorIdsByMessage: vectorIdsByMessage
        )
        guard request.lens.frame.spatialLens == .meaning else { return selected }
        return selected.map { $0.scalingRadius(by: meaningLensMessageStarRadiusScale) }
    }

    private static func selectVisibleStars(
        _ stars: [MessageStarInstance],
        request: ConstellationRenderRequest,
        vectorIdsByMessage: [String: Set<Int64>]
    ) -> [MessageStarInstance] {
        guard stars.count > request.budget.maxStars else { return stars }
        let camera = request.lens.camera
        let viewSize = request.lens.viewSize
        let apertureRadius = ApertureSelector.radius(forAperture: request.lens.aperture)
        let apertureRadius2 = apertureRadius * apertureRadius
        let hasView = viewSize.width > 1 && viewSize.height > 1
        let padding: CGFloat = 180

        struct Scored {
            let star: MessageStarInstance
            let score: Float
        }

        var scored: [Scored] = []
        scored.reserveCapacity(stars.count)
        for star in stars {
            let ids = vectorIdsByMessage[star.messageId] ?? []
            let active = ids.contains { request.activeVectorIds.contains($0) }
                || ids.contains { request.citationVectorIds.contains($0) }
                || ids.contains { request.searchScores[$0] != nil }
                || (request.hoveredVectorId.map(ids.contains) ?? false)
                || (request.lockedVectorId.map(ids.contains) ?? false)
                || star.signal.lockFocus > 0

            let delta = star.position - camera.position
            let distance2 = simd_dot(delta, delta)
            let insideAperture = request.lens.aperture >= 0.999 || distance2 <= apertureRadius2
            let projected: Bool
            if hasView, let screen = ScreenProjection.project(
                world: star.position,
                camera: camera,
                viewSize: viewSize,
                fovYRadians: .pi / 3
            ) {
                projected = screen.x >= -padding
                    && screen.y >= -padding
                    && screen.x <= viewSize.width + padding
                    && screen.y <= viewSize.height + padding
            } else {
                projected = false
            }

            let activeBonus: Float = active ? -1_000_000 : 0
            let aperturePenalty: Float = insideAperture ? 0 : 50_000
            let projectionPenalty: Float = projected || active ? 0 : 25_000
            let signalBonus = -star.signal.intensity * 10_000
            let score = activeBonus + aperturePenalty + projectionPenalty + distance2 + signalBonus
            scored.append(Scored(star: star, score: score))
        }
        return scored.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.star.representativeVectorId < $1.star.representativeVectorId
        }
        .prefix(request.budget.maxStars)
        .map(\.star)
    }

    private static func signalState(
        messageId: String,
        vectorIds: Set<Int64>,
        request: ConstellationRenderRequest,
        lockFocusGradeByMessageId: [String: Float]
    ) -> VisualSignalState {
        let search = vectorIds.compactMap { request.searchScores[$0] }.max() ?? 0
        let citation: Float = vectorIds.isDisjoint(with: request.citationVectorIds) ? 0 : 1
        let hover = request.hoveredVectorId.map { vectorIds.contains($0) ? Float(1) : 0 } ?? 0
        let selected = request.lockedVectorId.map { vectorIds.contains($0) ? Float(1) : 0 } ?? 0
        // Semantic-distance grade: 1.0 on the anchor, descending with
        // resolver rank across the gated neighbours, 0 outside the
        // neighbourhood. The shader's `lock_dim_multiplier` interpolates
        // between the field dim and full emission with this value, so
        // closer neighbours read brighter than farther ones during and
        // after the lock transition.
        let lockFocus = lockFocusGradeByMessageId[messageId] ?? 0
        let practical: Float
        // `practical` feeds a time-driven shader pulse, so frames that opt
        // out of action motion must not stamp it onto every email node.
        if request.frameVisualLanguage.actionMotion == .off {
            practical = 0
        } else if let row = request.messageIndex[messageId] {
            var value: Float = 0
            if row.isReplied == false && row.isSentByUser == false { value += 0.30 }
            if row.flagged { value += 0.45 }
            if row.hasAttachments { value += 0.18 }
            // When the active frame requests `.currentOnly` action motion,
            // saturate `practical` for messages that are *actually*
            // unresolved-and-recent — the shader's existing `practicalPulse`
            // path then renders the pulse. Older actionables and resolved
            // ones keep their default practical value, so the motion stays
            // on what's "current" rather than every actionable ever ingested.
            if request.frameVisualLanguage.actionMotion == .currentOnly,
               row.isActionable == true,
               row.isReplied == false,
               row.isSentByUser == false,
               let receivedAt = row.receivedAt,
               receivedAt.timeIntervalSinceNow >= -14 * 86_400 {
                value = 1.0
            }
            practical = min(1, value)
        } else {
            practical = 0
        }
        return VisualSignalState(
            hover: hover,
            selected: selected,
            lockFocus: lockFocus,
            search: max(0, min(1, search)),
            citation: citation,
            practical: practical
        )
    }

}
