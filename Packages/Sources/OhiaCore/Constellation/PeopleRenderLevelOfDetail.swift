import Foundation

public struct PeopleRenderLevelOfDetail: Sendable, Equatable {
    public let maxHubs: Int
    public let maxStars: Int
    public let maxSatellites: Int
    public let maxNebulae: Int
    public let renderHubsAsPlanets: Bool
    public let degradationTier: RenderDegradationTier

    public init(
        maxHubs: Int,
        maxStars: Int,
        maxSatellites: Int,
        maxNebulae: Int,
        renderHubsAsPlanets: Bool = true,
        degradationTier: RenderDegradationTier = .reducedRefinement
    ) {
        self.maxHubs = max(0, maxHubs)
        self.maxStars = max(0, maxStars)
        self.maxSatellites = max(0, maxSatellites)
        self.maxNebulae = max(0, maxNebulae)
        self.renderHubsAsPlanets = renderHubsAsPlanets
        self.degradationTier = degradationTier
    }

    /// Backdrop-only budget for People focus exit. The focused scene remains
    /// full fidelity; this caps the returning constellation that moves behind it.
    public static let focusExitTransition = PeopleRenderLevelOfDetail(
        maxHubs: 128,
        maxStars: 360,
        maxSatellites: 56,
        maxNebulae: 32,
        renderHubsAsPlanets: false,
        degradationTier: .aggregateHeavy
    )

    /// First unlocked explorer packet after People focus closes. This keeps
    /// the constellation responsive while the full field is staged back in.
    public static let focusExitSettle = PeopleRenderLevelOfDetail(
        maxHubs: 180,
        maxStars: 520,
        maxSatellites: 72,
        maxNebulae: 40,
        renderHubsAsPlanets: true,
        degradationTier: .aggregateHeavy
    )

    /// Settled People-lens pressure relief after a heavy zoom/replan. Hubs keep
    /// their planet rendering because this packet may remain visible after motion.
    ///
    /// The hub cap is intentionally set far above any real mailbox's
    /// correspondent count so that widening the timeframe reveals *every*
    /// correspondent rather than clamping to a fixed subset — the earlier 220
    /// cap made Quarter/Year/All render an identical, truncated field. This is
    /// affordable because the expensive per-hub work is bounded elsewhere,
    /// independent of this number: `personPlanetLODTiers` caps the labeled,
    /// high-poly meshes at 24 high + 96 medium (everything beyond is a cheap
    /// instanced low-tier sphere) and the glyph atlas is capped at that same
    /// 120. Relief here therefore comes from the reduced-refinement tier, the
    /// nebula bound, and the star/satellite bounds (kept at least at the base
    /// budget so message density is not clamped below what the budget allows),
    /// not from dropping correspondents.
    public static let zoomedOutPressure = PeopleRenderLevelOfDetail(
        maxHubs: 4_000,
        maxStars: 2_000,
        maxSatellites: 200,
        maxNebulae: 64,
        renderHubsAsPlanets: true,
        degradationTier: .reducedRefinement
    )
}

public extension ConstellationRenderPacket {
    func applyingPeopleLevelOfDetail(
        _ levelOfDetail: PeopleRenderLevelOfDetail,
        focalEmail: String? = nil,
        focalMessageId: String? = nil,
        focalVectorId: Int64? = nil,
        generatedAt overrideGeneratedAt: TimeInterval? = nil
    ) -> ConstellationRenderPacket {
        guard !personHubs.isEmpty else { return self }

        let focalEmail = Self.normalizedPeopleEmail(focalEmail)
        let hubLimit = focalEmail == nil
            ? levelOfDetail.maxHubs
            : max(1, levelOfDetail.maxHubs)
        let selectedHubs = Self.selectedPeopleHubs(
            personHubs,
            maxCount: hubLimit,
            focalEmail: focalEmail
        )
        let keptEmails = Set(selectedHubs.compactMap { Self.normalizedPeopleEmail($0.email) })
        let hubMessageIds = selectedHubs.reduce(into: Set<String>()) { result, hub in
            result.formUnion(hub.messageIds)
        }

        let selectedStars = Self.selectedPeopleStars(
            stars,
            maxCount: levelOfDetail.maxStars,
            allowedMessageIds: hubMessageIds,
            focalMessageId: focalMessageId,
            focalVectorId: focalVectorId
        )
        var keptMessageIds = Set(selectedStars.map(\.messageId))
        if let focalMessageId {
            keptMessageIds.insert(focalMessageId)
        }

        let selectedSatellites = Self.selectedPeopleSatellites(
            satellites,
            maxCount: levelOfDetail.maxSatellites,
            allowedMessageIds: keptMessageIds,
            focalVectorId: focalVectorId
        )
        keptMessageIds.formUnion(selectedSatellites.map(\.parentMessageId))

        let selectedNebulae = Self.selectedPeopleNebulae(
            nebulae,
            maxCount: levelOfDetail.maxNebulae
        )
        let selectedRings = personRings.filter {
            guard let email = Self.normalizedPeopleEmail($0.email) else { return false }
            return keptEmails.contains(email)
        }
        let selectedRelations = personRelations.filter {
            guard let source = Self.normalizedPeopleEmail($0.sourceEmail),
                  let target = Self.normalizedPeopleEmail($0.targetEmail) else { return false }
            return keptEmails.contains(source) && keptEmails.contains(target)
        }
        let selectedPersonHitProxies = personHitProxies.filter {
            guard let email = Self.normalizedPeopleEmail($0.email) else { return false }
            return keptEmails.contains(email)
        }
        let selectedPersonAtoms = personAtoms.filter {
            guard let email = Self.normalizedPeopleEmail($0.hubEmail) else { return false }
            return keptEmails.contains(email) && keptMessageIds.contains($0.parentMessageId)
        }
        let selectedHitProxies = hitProxies.filter { proxy in
            // The sun (the "You" body) carries no email and no backing message,
            // so it matches none of the branches below and would be dropped by
            // the reduction. The reduced packet still re-emits the sun body
            // unconditionally (see the `personSun` argument passed to the packet
            // initializer below), so dropping only its hit proxy would leave a
            // visible orb that silently ignores the cursor. It is the scene's
            // anchor, not a capped correspondent, so its hit proxy survives at
            // every scope. (Proxy id is the bare literal "personSun" — there is
            // no "personSun:" prefix scheme.)
            if proxy.messageId == PersonSunInstance.hitProxyMessageId {
                return true
            }
            if proxy.vectorId == focalVectorId {
                return true
            }
            if let email = Self.peopleEmail(fromSyntheticMessageId: proxy.messageId) {
                return keptEmails.contains(email)
            }
            return keptMessageIds.contains(proxy.messageId)
        }

        let cappedBudget = RenderBudget(
            maxStars: min(budget.maxStars, levelOfDetail.maxStars),
            maxNebulae: min(budget.maxNebulae, levelOfDetail.maxNebulae),
            maxFibers: budget.maxFibers,
            maxSatellites: min(budget.maxSatellites, levelOfDetail.maxSatellites),
            degradationTier: max(budget.degradationTier, levelOfDetail.degradationTier)
        )

        if overrideGeneratedAt == nil,
           selectedHubs.count == personHubs.count,
           selectedStars.count == stars.count,
           selectedSatellites.count == satellites.count,
           selectedNebulae.count == nebulae.count,
           selectedRings.count == personRings.count,
           selectedHitProxies.count == hitProxies.count,
           levelOfDetail.renderHubsAsPlanets == renderHubsAsPlanets,
           cappedBudget == budget {
            return self
        }

        return ConstellationRenderPacket(
            stars: selectedStars,
            satellites: selectedSatellites,
            nebulae: selectedNebulae,
            semanticDensityFields: semanticDensityFields,
            fibers: fibers,
            hitProxies: selectedHitProxies,
            budget: cappedBudget,
            totalMessageCount: totalMessageCount,
            totalVectorCount: totalVectorCount,
            fieldDimFactor: fieldDimFactor,
            generatedAt: overrideGeneratedAt ?? generatedAt,
            visualLanguage: visualLanguage,
            arcLabels: arcLabels,
            personHubs: selectedHubs,
            personRelations: selectedRelations,
            personHitProxies: selectedPersonHitProxies,
            meaningClusterHubs: meaningClusterHubs,
            meaningClusterVisibility: meaningClusterVisibility,
            personRings: selectedRings,
            personAtoms: selectedPersonAtoms,
            renderHubsAsPlanets: levelOfDetail.renderHubsAsPlanets,
            personSun: personSun,
            personOrbitPathColor: personOrbitPathColor
        )
    }

    private static func selectedPeopleHubs(
        _ hubs: [PersonHubInstance],
        maxCount: Int,
        focalEmail: String?
    ) -> [PersonHubInstance] {
        guard maxCount > 0, hubs.count > maxCount else { return hubs }
        return hubs.sorted { left, right in
            let leftEmail = normalizedPeopleEmail(left.email) ?? ""
            let rightEmail = normalizedPeopleEmail(right.email) ?? ""
            let leftFocal = focalEmail != nil && leftEmail == focalEmail
            let rightFocal = focalEmail != nil && rightEmail == focalEmail
            if leftFocal != rightFocal { return leftFocal }
            if left.focusGlow != right.focusGlow { return left.focusGlow > right.focusGlow }
            let leftFootprint = left.sentCount + left.receivedCount + left.appearanceCount
            let rightFootprint = right.sentCount + right.receivedCount + right.appearanceCount
            if leftFootprint != rightFootprint { return leftFootprint > rightFootprint }
            if left.radius != right.radius { return left.radius > right.radius }
            if left.recencyScore != right.recencyScore { return left.recencyScore > right.recencyScore }
            if left.reciprocalScore != right.reciprocalScore { return left.reciprocalScore > right.reciprocalScore }
            return leftEmail < rightEmail
        }
        .prefix(maxCount)
        .map { $0 }
    }

    private static func selectedPeopleStars(
        _ stars: [MessageStarInstance],
        maxCount: Int,
        allowedMessageIds: Set<String>,
        focalMessageId: String?,
        focalVectorId: Int64?
    ) -> [MessageStarInstance] {
        guard maxCount > 0 else { return [] }
        let candidates = stars.filter { star in
            allowedMessageIds.contains(star.messageId)
                || star.messageId == focalMessageId
                || star.representativeVectorId == focalVectorId
                || star.signal.lockFocus > 0
                || star.signal.intensity > 0
        }
        guard candidates.count > maxCount else { return candidates }
        return candidates.sorted { left, right in
            let leftFocal = left.messageId == focalMessageId
                || left.representativeVectorId == focalVectorId
                || left.signal.lockFocus > 0
            let rightFocal = right.messageId == focalMessageId
                || right.representativeVectorId == focalVectorId
                || right.signal.lockFocus > 0
            if leftFocal != rightFocal { return leftFocal }
            if left.signal.intensity != right.signal.intensity {
                return left.signal.intensity > right.signal.intensity
            }
            if left.vectorCount != right.vectorCount { return left.vectorCount > right.vectorCount }
            if left.arrivalTime != right.arrivalTime { return left.arrivalTime > right.arrivalTime }
            return left.representativeVectorId < right.representativeVectorId
        }
        .prefix(maxCount)
        .map { $0 }
    }

    private static func selectedPeopleSatellites(
        _ satellites: [MessageSatelliteInstance],
        maxCount: Int,
        allowedMessageIds: Set<String>,
        focalVectorId: Int64?
    ) -> [MessageSatelliteInstance] {
        guard maxCount > 0 else { return [] }
        let candidates = satellites.filter {
            allowedMessageIds.contains($0.parentMessageId)
                || $0.vectorId == focalVectorId
                || $0.signal.lockFocus > 0
        }
        guard candidates.count > maxCount else { return candidates }
        return candidates.sorted { left, right in
            let leftFocal = left.vectorId == focalVectorId || left.signal.lockFocus > 0
            let rightFocal = right.vectorId == focalVectorId || right.signal.lockFocus > 0
            if leftFocal != rightFocal { return leftFocal }
            if left.signal.intensity != right.signal.intensity {
                return left.signal.intensity > right.signal.intensity
            }
            return left.vectorId < right.vectorId
        }
        .prefix(maxCount)
        .map { $0 }
    }

    private static func selectedPeopleNebulae(
        _ nebulae: [SemanticNebulaInstance],
        maxCount: Int
    ) -> [SemanticNebulaInstance] {
        guard maxCount > 0 else { return [] }
        guard nebulae.count > maxCount else { return nebulae }
        return nebulae.sorted {
            if $0.isTopCluster != $1.isTopCluster { return $0.isTopCluster }
            if $0.memberCount != $1.memberCount { return $0.memberCount > $1.memberCount }
            if $0.density != $1.density { return $0.density > $1.density }
            return $0.id < $1.id
        }
        .prefix(maxCount)
        .map { $0 }
    }

    private static func peopleEmail(fromSyntheticMessageId messageId: String) -> String? {
        guard messageId.hasPrefix("person:") else { return nil }
        return normalizedPeopleEmail(String(messageId.dropFirst("person:".count)))
    }

    private static func normalizedPeopleEmail(_ email: String?) -> String? {
        guard let email else { return nil }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
