import Foundation

// Internal semantic-status identity graph retained for Front Page and Timeline.
// These values cannot create, name, persist, or mutate a manual project.

struct SemanticStatusIdentityResolution: Sendable, Equatable {
    let parentKeyBySemanticKey: [String: String]
    let displayLabelBySemanticKey: [String: String]
    let parentKeyByMessageIDAndSemanticKey: [UUID: [String: String]]

    init(
        parentKeyBySemanticKey: [String: String] = [:],
        displayLabelBySemanticKey: [String: String] = [:],
        parentKeyByMessageIDAndSemanticKey: [UUID: [String: String]] = [:]
    ) {
        self.parentKeyBySemanticKey = parentKeyBySemanticKey
        self.displayLabelBySemanticKey = displayLabelBySemanticKey
        self.parentKeyByMessageIDAndSemanticKey = parentKeyByMessageIDAndSemanticKey
    }

    static let empty = SemanticStatusIdentityResolution()

    func resolvedKey(for raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen: Set<String> = []
        while let parent = parentKeyBySemanticKey[key], seen.insert(key).inserted {
            key = parent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return key
    }

    func resolvedMembershipsByMessageID(
        _ memberships: [UUID: [SemanticAffinityMembership]]
    ) -> [UUID: [SemanticAffinityMembership]] {
        guard parentKeyBySemanticKey.isEmpty == false
            || parentKeyByMessageIDAndSemanticKey.isEmpty == false else {
            return memberships
        }

        var resolvedByMessageID: [UUID: [SemanticAffinityMembership]] = [:]
        for (messageID, messageMemberships) in memberships {
            var byKey: [String: SemanticAffinityMembership] = [:]
            for membership in messageMemberships {
                let key = resolvedKey(for: membership.semanticKey, messageID: messageID)
                let resolved = membership.resolvingSemanticKey(
                    key,
                    displayLabel: displayLabelBySemanticKey[key]
                )
                if let existing = byKey[key] {
                    byKey[key] = Self.preferredMembership(existing, resolved)
                } else {
                    byKey[key] = resolved
                }
            }
            let sorted = byKey.values.sorted { lhs, rhs in
                if lhs.strength != rhs.strength { return lhs.strength > rhs.strength }
                let leftScore = lhs.score + lhs.confidence
                let rightScore = rhs.score + rhs.confidence
                if leftScore != rightScore { return leftScore > rightScore }
                return lhs.displayLabel.localizedStandardCompare(rhs.displayLabel) == .orderedAscending
            }
            resolvedByMessageID[messageID] = sorted
        }
        return resolvedByMessageID
    }

    private func resolvedKey(for raw: String, messageID: UUID) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen: Set<String> = []
        while seen.insert(key).inserted {
            if let scopedParent = parentKeyByMessageIDAndSemanticKey[messageID]?[key] {
                key = scopedParent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                continue
            }
            if let globalParent = parentKeyBySemanticKey[key] {
                key = globalParent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                continue
            }
            break
        }
        return key
    }

    static func preferredMembership(
        _ lhs: SemanticAffinityMembership,
        _ rhs: SemanticAffinityMembership
    ) -> SemanticAffinityMembership {
        if lhs.strength != rhs.strength { return lhs.strength > rhs.strength ? lhs : rhs }
        let leftScore = lhs.score + lhs.confidence
        let rightScore = rhs.score + rhs.confidence
        if leftScore != rightScore { return leftScore > rightScore ? lhs : rhs }
        return lhs.displayLabel.localizedStandardCompare(rhs.displayLabel) == .orderedAscending ? lhs : rhs
    }
}

struct SemanticStatusAffinityEvidence: Sendable, Equatable {
    let contentTokens: Set<String>
    let contentPhrases: Set<String>

    static let empty = SemanticStatusAffinityEvidence(contentTokens: [], contentPhrases: [])
}

/// One normalization pass per message, shared by identity reconciliation and
/// content-affinity expansion. Both stages consume the same token and phrase
/// evidence, so rebuilding it independently makes project computation scale
/// with the number of memberships and resolver passes instead of messages.
struct SemanticStatusAffinityEvidenceIndex: Sendable {
    private let evidenceByMessageID: [UUID: SemanticStatusAffinityEvidence]

    init(
        messages: [ProjectMessageInput],
        buildEvidence: (ProjectMessageInput) -> SemanticStatusAffinityEvidence = {
            SemanticStatusIdentityEvidence.affinityEvidence(in: $0)
        }
    ) {
        var indexed: [UUID: SemanticStatusAffinityEvidence] = [:]
        indexed.reserveCapacity(messages.count)
        for message in messages where indexed[message.id] == nil {
            indexed[message.id] = buildEvidence(message)
        }
        evidenceByMessageID = indexed
    }

    var count: Int { evidenceByMessageID.count }

    func evidence(for messageID: UUID) -> SemanticStatusAffinityEvidence? {
        evidenceByMessageID[messageID]
    }
}

enum SemanticStatusIdentityResolver {
    static func resolve(
        messages: [ProjectMessageInput],
        membershipByMessageID: [UUID: [SemanticAffinityMembership]]
    ) -> SemanticStatusIdentityResolution {
        resolve(
            messages: messages,
            membershipByMessageID: membershipByMessageID,
            affinityEvidenceIndex: SemanticStatusAffinityEvidenceIndex(messages: messages)
        )
    }

    static func resolve(
        messages: [ProjectMessageInput],
        membershipByMessageID: [UUID: [SemanticAffinityMembership]],
        affinityEvidenceIndex: SemanticStatusAffinityEvidenceIndex
    ) -> SemanticStatusIdentityResolution {
        // Canonical tag UUIDs are authoritative. Downstream content and
        // conversation proximity may expand status evidence, but must never
        // merge or rename distinct tag identities.
        return .empty
        /*
        var aggregateByKey: [String: SemanticStatusIdentityAggregate] = [:]
        let messageByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let conversationIDByMessageID = conversationComponentIDs(messages)

        for (messageID, memberships) in membershipByMessageID {
            guard let message = messageByID[messageID] else { continue }
            for membership in memberships {
                aggregateByKey[membership.semanticKey, default: SemanticStatusIdentityAggregate(key: membership.semanticKey)]
                    .add(
                        message: message,
                        membership: membership,
                        conversationID: conversationIDByMessageID[messageID] ?? messageID,
                        affinityEvidence: affinityEvidenceIndex.evidence(for: messageID) ?? .empty
                    )
            }
        }

        guard aggregateByKey.count > 1 else { return .empty }

        let aggregates = Array(aggregateByKey.values)
        let conversationResolution = conversationAliases(
            messages: messages,
            membershipByMessageID: membershipByMessageID,
            conversationIDByMessageID: conversationIDByMessageID
        )
        let explicitSemanticPairs = Set(
            membershipByMessageID.values.flatMap { memberships in
                semanticPairs(memberships.map(\.semanticKey))
            }
        )
        let affinityCandidatesByChildKey = contentAffinityCandidatesByChildKey(aggregates)
        var aliases: [String: String] = [:]
        for child in aggregates {
            if let parent = bestContentAffinityParent(
                for: child,
                in: affinityCandidatesByChildKey[child.key] ?? [],
                explicitSemanticPairs: explicitSemanticPairs
            ) {
                aliases[child.key] = parent.key
                continue
            }
            if child.isLifecycleAliasCandidate,
               let parent = bestLifecycleParent(for: child, in: aggregates) {
                aliases[child.key] = parent.key
            }
        }
        aliases = aliasesPreservingExplicitSemanticPairs(
            aliasesByDroppingCycles(aliases),
            explicitSemanticPairs: explicitSemanticPairs
        )

        guard aliases.isEmpty == false
            || conversationResolution.parentKeyByMessageIDAndSemanticKey.isEmpty == false else {
            return .empty
        }

        var displayLabels = conversationResolution.displayLabelBySemanticKey
        for aggregate in aggregates {
            let key = resolve(key: aggregate.key, aliases: aliases)
            if let parent = aggregateByKey[key] {
                displayLabels[key] = parent.displayLabel
            }
        }

        return SemanticStatusIdentityResolution(
            parentKeyBySemanticKey: aliases,
            displayLabelBySemanticKey: displayLabels,
            parentKeyByMessageIDAndSemanticKey: conversationResolution.parentKeyByMessageIDAndSemanticKey
        )
        */
    }

    /// Collapses extractor drift inside a single conversation without treating
    /// explicit multi-project messages as aliases. If one message carries two
    /// project labels, that remains cross-project evidence for the Links view.
    private static func conversationAliases(
        messages: [ProjectMessageInput],
        membershipByMessageID: [UUID: [SemanticAffinityMembership]],
        conversationIDByMessageID: [UUID: UUID]
    ) -> SemanticStatusConversationAliasResolution {
        let messageIDsByConversation = Dictionary(grouping: messages.map(\.id)) { messageID in
            conversationIDByMessageID[messageID] ?? messageID
        }
        var evidenceByConversation: [UUID: [String: SemanticStatusThreadGroupEvidence]] = [:]
        var explicitPairsByConversation: [UUID: Set<SemanticStatusPair>] = [:]

        for message in messages {
            let conversationID = conversationIDByMessageID[message.id] ?? message.id
            let memberships = membershipByMessageID[message.id] ?? []
            guard memberships.isEmpty == false else { continue }

            let uniqueMemberships = preferredMembershipsBySemanticKey(memberships)
            let isSoleProjectMessage = uniqueMemberships.count == 1
            if uniqueMemberships.count > 1 {
                for pair in semanticPairs(uniqueMemberships.map(\.semanticKey)) {
                    explicitPairsByConversation[conversationID, default: []].insert(pair)
                }
            }

            for membership in uniqueMemberships {
                var evidence = evidenceByConversation[conversationID]?[membership.semanticKey]
                    ?? SemanticStatusThreadGroupEvidence(key: membership.semanticKey)
                evidence.add(
                    message: message,
                    membership: membership,
                    isSoleProjectMessage: isSoleProjectMessage
                )
                evidenceByConversation[conversationID, default: [:]][membership.semanticKey] = evidence
            }
        }

        var parentKeyByMessageIDAndSemanticKey: [UUID: [String: String]] = [:]
        var displayLabelBySemanticKey: [String: String] = [:]
        for (conversationID, projectEvidenceByKey) in evidenceByConversation {
            let projectEvidence = Array(projectEvidenceByKey.values)
            guard projectEvidence.count > 1 else { continue }

            let explicitPairs = explicitPairsByConversation[conversationID] ?? []
            let components = connectedThreadSemanticComponents(
                projectEvidence,
                explicitPairs: explicitPairs
            )
            for component in components where component.count > 1 {
                guard let parent = component.max(by: threadParentSort) else { continue }
                for child in component where child.key != parent.key {
                    guard let messageIDs = messageIDsByConversation[conversationID] else { continue }
                    for messageID in messageIDs where membershipByMessageID[messageID]?.contains(where: { $0.semanticKey == child.key }) == true {
                        parentKeyByMessageIDAndSemanticKey[messageID, default: [:]][child.key] = parent.key
                    }
                }
                displayLabelBySemanticKey[parent.key] = parent.displayLabel
            }
        }

        return SemanticStatusConversationAliasResolution(
            parentKeyByMessageIDAndSemanticKey: parentKeyByMessageIDAndSemanticKey.mapValues(aliasesByDroppingCycles),
            displayLabelBySemanticKey: displayLabelBySemanticKey
        )
    }

    static func conversationComponentIDs(_ messages: [ProjectMessageInput]) -> [UUID: UUID] {
        guard messages.isEmpty == false else { return [:] }
        var union = SemanticStatusConversationUnionFind(messageIDs: messages.map(\.id))

        let byThread = Dictionary(grouping: messages.filter { $0.threadID != nil }) { $0.threadID! }
        for threadMessages in byThread.values {
            union.unionAll(threadMessages.map(\.id))
        }

        let messageIDByHeader = messages.reduce(into: [String: UUID]()) { dict, message in
            guard let header = message.messageIDHeader else { return }
            dict[header] = message.id
        }
        for message in messages {
            for referencedHeader in message.referencesHeaders {
                guard let referencedID = messageIDByHeader[referencedHeader] else { continue }
                union.union(message.id, referencedID)
            }
        }

        var componentMembers: [UUID: [UUID]] = [:]
        for message in messages {
            componentMembers[union.find(message.id), default: []].append(message.id)
        }

        var componentIDByMessageID: [UUID: UUID] = [:]
        for members in componentMembers.values {
            guard let componentID = members.min(by: { $0.uuidString < $1.uuidString }) else { continue }
            for member in members {
                componentIDByMessageID[member] = componentID
            }
        }
        return componentIDByMessageID
    }

    private static func preferredMembershipsBySemanticKey(
        _ memberships: [SemanticAffinityMembership]
    ) -> [SemanticAffinityMembership] {
        var byKey: [String: SemanticAffinityMembership] = [:]
        for membership in memberships {
            if let existing = byKey[membership.semanticKey] {
                byKey[membership.semanticKey] = SemanticStatusIdentityResolution.preferredMembership(existing, membership)
            } else {
                byKey[membership.semanticKey] = membership
            }
        }
        return byKey.values.sorted { lhs, rhs in
            if lhs.strength != rhs.strength { return lhs.strength > rhs.strength }
            let leftScore = lhs.score + lhs.confidence
            let rightScore = rhs.score + rhs.confidence
            if leftScore != rightScore { return leftScore > rightScore }
            return lhs.displayLabel.localizedStandardCompare(rhs.displayLabel) == .orderedAscending
        }
    }

    private static func semanticPairs(_ rawKeys: [String]) -> [SemanticStatusPair] {
        let keys = Array(Set(rawKeys.map(ProjectKeyNormalizer.canonicalKey))).sorted()
        guard keys.count > 1 else { return [] }
        var result: [SemanticStatusPair] = []
        for i in keys.indices {
            for j in keys.indices where j > i {
                result.append(SemanticStatusPair(keys[i], keys[j]))
            }
        }
        return result
    }

    private static func connectedThreadSemanticComponents(
        _ evidence: [SemanticStatusThreadGroupEvidence],
        explicitPairs: Set<SemanticStatusPair>
    ) -> [[SemanticStatusThreadGroupEvidence]] {
        var remaining = Set(evidence.map(\.key))
        let byKey = Dictionary(uniqueKeysWithValues: evidence.map { ($0.key, $0) })
        var components: [[SemanticStatusThreadGroupEvidence]] = []

        while let seed = remaining.first {
            var stack = [seed]
            var componentKeys = Set<String>()
            remaining.remove(seed)

            while let key = stack.popLast() {
                componentKeys.insert(key)
                guard let current = byKey[key] else { continue }
                for candidateKey in Array(remaining) {
                    guard let candidate = byKey[candidateKey],
                          componentKeys.allSatisfy({
                            explicitPairs.contains(SemanticStatusPair($0, candidate.key)) == false
                          }),
                          threadGroupsShouldAlias(
                            current,
                            candidate,
                            explicitPairs: explicitPairs
                          ) else {
                        continue
                    }
                    remaining.remove(candidateKey)
                    stack.append(candidateKey)
                }
            }

            components.append(componentKeys.compactMap { byKey[$0] })
        }

        return components
    }

    private static func threadGroupsShouldAlias(
        _ lhs: SemanticStatusThreadGroupEvidence,
        _ rhs: SemanticStatusThreadGroupEvidence,
        explicitPairs: Set<SemanticStatusPair>
    ) -> Bool {
        let pair = SemanticStatusPair(lhs.key, rhs.key)
        guard explicitPairs.contains(pair) == false else { return false }
        if explicitPairs.isEmpty,
           lhs.hasSoleProjectEvidence,
           rhs.hasSoleProjectEvidence {
            return true
        }
        return threadGroupsLookLikeSameWork(lhs, rhs)
    }

    private static func threadGroupsLookLikeSameWork(
        _ lhs: SemanticStatusThreadGroupEvidence,
        _ rhs: SemanticStatusThreadGroupEvidence
    ) -> Bool {
        lhs.mergeTokens.isDisjoint(with: rhs.mergeTokens) == false
    }

    private static func threadParentSort(
        _ lhs: SemanticStatusThreadGroupEvidence,
        _ rhs: SemanticStatusThreadGroupEvidence
    ) -> Bool {
        if lhs.averageConfidence != rhs.averageConfidence {
            return lhs.averageConfidence < rhs.averageConfidence
        }
        if lhs.messageCount != rhs.messageCount {
            return lhs.messageCount < rhs.messageCount
        }
        if lhs.mergeTokens.count != rhs.mergeTokens.count {
            return lhs.mergeTokens.count < rhs.mergeTokens.count
        }
        if lhs.firstDate != rhs.firstDate {
            let leftDate = lhs.firstDate ?? .distantFuture
            let rightDate = rhs.firstDate ?? .distantFuture
            return leftDate > rightDate
        }
        if lhs.displayLabel != rhs.displayLabel {
            return lhs.displayLabel > rhs.displayLabel
        }
        return lhs.key > rhs.key
    }

    private static func aliasesByDroppingCycles(_ aliases: [String: String]) -> [String: String] {
        var result = aliases
        for child in aliases.keys.sorted() {
            var key = child
            var seen: Set<String> = []
            while let parent = result[key] {
                if parent == child || !seen.insert(parent).inserted {
                    result[child] = nil
                    break
                }
                key = parent
            }
        }
        return result
    }

    /// An extractor can intentionally place two projects on the same message.
    /// Global aliases may rename either side, but must never make that explicit
    /// pair resolve to one key and erase the cross-project relationship.
    private static func aliasesPreservingExplicitSemanticPairs(
        _ aliases: [String: String],
        explicitSemanticPairs: Set<SemanticStatusPair>
    ) -> [String: String] {
        var result = aliases
        while true {
            var collapsedEndpoints = Set<String>()
            for pair in explicitSemanticPairs
            where resolve(key: pair.left, aliases: result) == resolve(key: pair.right, aliases: result) {
                if result[pair.left] != nil {
                    collapsedEndpoints.insert(pair.left)
                }
                if result[pair.right] != nil {
                    collapsedEndpoints.insert(pair.right)
                }
            }
            guard collapsedEndpoints.isEmpty == false else { return result }
            for key in collapsedEndpoints.sorted() {
                result.removeValue(forKey: key)
            }
        }
    }

    private static func bestLifecycleParent(
        for child: SemanticStatusIdentityAggregate,
        in aggregates: [SemanticStatusIdentityAggregate]
    ) -> SemanticStatusIdentityAggregate? {
        var best: (aggregate: SemanticStatusIdentityAggregate, score: Double)?
        for parent in aggregates where parent.key != child.key {
            guard parent.isPlausibleParent(for: child) else { continue }
            let score = mergeScore(child: child, parent: parent)
            guard score >= 6.5 else { continue }
            if let current = best {
                if score > current.score {
                    best = (parent, score)
                } else if score == current.score,
                          parent.parentTieBreakScore > current.aggregate.parentTieBreakScore {
                    best = (parent, score)
                }
            } else {
                best = (parent, score)
            }
        }
        return best?.aggregate
    }

    /// Reconciles extractor labels across separate conversations only when the
    /// smaller label cluster looks like a naming variant of an established
    /// project. A distinctive label anchor must match, subject/body evidence
    /// must independently corroborate it, and labels explicitly emitted on the
    /// same message remain separate projects.
    private static func bestContentAffinityParent(
        for child: SemanticStatusIdentityAggregate,
        in aggregates: [SemanticStatusIdentityAggregate],
        explicitSemanticPairs: Set<SemanticStatusPair>
    ) -> SemanticStatusIdentityAggregate? {
        var matches: [(aggregate: SemanticStatusIdentityAggregate, score: Double)] = []
        for parent in aggregates where parent.key != child.key {
            guard parent.messageCount >= 2,
                  parent.messageCount > child.messageCount,
                  explicitSemanticPairs.contains(SemanticStatusPair(child.key, parent.key)) == false,
                  child.daysFrom(parent) <= 120,
                  groupsShareHardIdentity(child, parent) else {
                continue
            }

            let sharedAnchors = child.affinityLabelAnchors
                .intersection(parent.affinitySignatureTokens)
                .union(parent.affinityLabelAnchors.intersection(child.affinitySignatureTokens))
            guard sharedAnchors.count >= 2 else { continue }
            let sharedEvidence = child.affinitySignatureTokens
                .intersection(parent.affinitySignatureTokens)
                .subtracting(sharedAnchors)
                .subtracting(SemanticStatusIdentityEvidence.affinityGenericEvidenceTokens)
            let hasSharedIdentityPhrase = groupsShareIdentityPhrase(
                child,
                parent
            )
            let minimumEvidenceCount = hasSharedIdentityPhrase ? 1 : 2
            guard sharedEvidence.count >= minimumEvidenceCount else { continue }

            var score = Double(sharedAnchors.count * 3)
                + (Double(min(5, sharedEvidence.count)) * 0.8)
            let dayGap = child.daysFrom(parent)
            if dayGap <= 30 {
                score += 1
            } else if dayGap <= 60 {
                score += 0.5
            }
            if parent.messageCount >= child.messageCount + 2 {
                score += 0.5
            }
            guard score >= 6 else { continue }
            matches.append((parent, score))
        }

        let sorted = matches.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.aggregate.parentTieBreakScore != rhs.aggregate.parentTieBreakScore {
                return lhs.aggregate.parentTieBreakScore > rhs.aggregate.parentTieBreakScore
            }
            return lhs.aggregate.key < rhs.aggregate.key
        }
        guard let best = sorted.first else { return nil }
        if let runnerUp = sorted.dropFirst().first,
           best.score - runnerUp.score < 1 {
            return nil
        }
        return best.aggregate
    }

    /// Separate conversations may use different labels for the same project,
    /// but broad topical vocabulary is not identity. Require either an ordered
    /// project-name phrase or a distinctive identifier (acronym, mixed
    /// letter/digit reference, or non-Latin name) before score-based aliasing.
    private static func groupsShareHardIdentity(
        _ child: SemanticStatusIdentityAggregate,
        _ parent: SemanticStatusIdentityAggregate
    ) -> Bool {
        if groupsShareIdentityPhrase(child, parent) {
            return true
        }
        return child.affinityDistinctiveIdentifiers.isDisjoint(with: parent.affinityContentTokens) == false
            || parent.affinityDistinctiveIdentifiers.isDisjoint(with: child.affinityContentTokens) == false
    }

    private static func groupsShareIdentityPhrase(
        _ child: SemanticStatusIdentityAggregate,
        _ parent: SemanticStatusIdentityAggregate
    ) -> Bool {
        child.affinityIdentityPhrases.isDisjoint(with: parent.affinityContentPhrases) == false
            || parent.affinityIdentityPhrases.isDisjoint(with: child.affinityContentPhrases) == false
    }

    /// Builds an inverted token index so cross-thread identity resolution is
    /// proportional to the evidence on each project rather than comparing
    /// every project row with every other row.
    private static func contentAffinityCandidatesByChildKey(
        _ aggregates: [SemanticStatusIdentityAggregate]
    ) -> [String: [SemanticStatusIdentityAggregate]] {
        var keysByLabelAnchor: [String: Set<String>] = [:]
        var keysBySignatureToken: [String: Set<String>] = [:]
        let aggregateByKey = Dictionary(uniqueKeysWithValues: aggregates.map { ($0.key, $0) })

        for aggregate in aggregates {
            for anchor in aggregate.affinityLabelAnchors {
                keysByLabelAnchor[anchor, default: []].insert(aggregate.key)
            }
            for token in aggregate.affinitySignatureTokens {
                keysBySignatureToken[token, default: []].insert(aggregate.key)
            }
        }

        var result: [String: [SemanticStatusIdentityAggregate]] = [:]
        for child in aggregates {
            var candidateKeys = Set<String>()
            for anchor in child.affinityLabelAnchors {
                candidateKeys.formUnion(keysBySignatureToken[anchor] ?? [])
            }
            for token in child.affinitySignatureTokens {
                candidateKeys.formUnion(keysByLabelAnchor[token] ?? [])
            }
            candidateKeys.remove(child.key)
            result[child.key] = candidateKeys.compactMap { aggregateByKey[$0] }
        }
        return result
    }

    private static func mergeScore(
        child: SemanticStatusIdentityAggregate,
        parent: SemanticStatusIdentityAggregate
    ) -> Double {
        var score = 0.0

        if child.identifiers.isDisjoint(with: parent.identifiers) == false {
            score += 4
        }
        if child.threadIDs.isDisjoint(with: parent.threadIDs) == false {
            score += 3
        }
        if parent.labelTokens.isSuperset(of: child.labelTokens), parent.labelTokens != child.labelTokens {
            score += 2.5
        }

        let sharedDurableTokens = child.durableTokens.intersection(parent.durableTokens)
        if sharedDurableTokens.isEmpty == false {
            score += sharedDurableTokens.count >= 2 ? 2 : 1
            if parent.durableTokens.count > child.durableTokens.count {
                score += 1.5
            }
        }

        let sharedParticipants = child.participantEmails.intersection(parent.participantEmails).count
        if sharedParticipants >= 2 {
            score += 1
        } else if sharedParticipants == 1 {
            score += 0.5
        }

        if child.daysFrom(parent) <= 14 {
            score += 1
        } else if child.daysFrom(parent) <= 45 {
            score += 0.5
        }

        if child.averageConfidence + 0.05 <= parent.averageConfidence {
            score += 1
        }

        return score
    }

    private static func resolve(key raw: String, aliases: [String: String]) -> String {
        var key = ProjectKeyNormalizer.canonicalKey(raw)
        var seen: Set<String> = []
        while let parent = aliases[key], seen.insert(key).inserted {
            key = ProjectKeyNormalizer.canonicalKey(parent)
        }
        return key
    }
}

private struct SemanticStatusConversationAliasResolution: Sendable, Equatable {
    let parentKeyByMessageIDAndSemanticKey: [UUID: [String: String]]
    let displayLabelBySemanticKey: [String: String]
}

private struct SemanticStatusConversationUnionFind {
    private var parentByMessageID: [UUID: UUID]

    init(messageIDs: [UUID]) {
        parentByMessageID = Dictionary(uniqueKeysWithValues: messageIDs.map { ($0, $0) })
    }

    mutating func find(_ messageID: UUID) -> UUID {
        let parent = parentByMessageID[messageID] ?? messageID
        guard parent != messageID else {
            parentByMessageID[messageID] = messageID
            return messageID
        }
        let root = find(parent)
        parentByMessageID[messageID] = root
        return root
    }

    mutating func union(_ lhs: UUID, _ rhs: UUID) {
        let leftRoot = find(lhs)
        let rightRoot = find(rhs)
        guard leftRoot != rightRoot else { return }
        if leftRoot.uuidString < rightRoot.uuidString {
            parentByMessageID[rightRoot] = leftRoot
        } else {
            parentByMessageID[leftRoot] = rightRoot
        }
    }

    mutating func unionAll(_ messageIDs: [UUID]) {
        guard let first = messageIDs.first else { return }
        for messageID in messageIDs.dropFirst() {
            union(first, messageID)
        }
    }
}

private struct SemanticStatusThreadGroupEvidence: Sendable {
    let key: String
    var displayVotes: [String: Double] = [:]
    var messageCount = 0
    var soleProjectMessageCount = 0
    var confidenceTotal = 0.0
    var semanticTokens: Set<String> = []
    var firstDate: Date?

    var averageConfidence: Double {
        messageCount == 0 ? 0 : confidenceTotal / Double(messageCount)
    }

    var hasSoleProjectEvidence: Bool {
        soleProjectMessageCount > 0
    }

    var displayLabel: String {
        displayVotes.max {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.key > $1.key
        }?.key ?? ProjectKeyNormalizer.displayLabel(key)
    }

    var mergeTokens: Set<String> {
        semanticTokens
            .subtracting(SemanticStatusIdentityEvidence.lifecycleTokens)
            .subtracting(SemanticStatusIdentityEvidence.threadGenericTokens)
    }

    var parentScore: Double {
        averageConfidence
            + (Double(messageCount) * 0.08)
            + (Double(mergeTokens.count) * 0.02)
    }

    mutating func add(
        message: ProjectMessageInput,
        membership: SemanticAffinityMembership,
        isSoleProjectMessage: Bool
    ) {
        messageCount += 1
        if isSoleProjectMessage {
            soleProjectMessageCount += 1
        }
        displayVotes[membership.displayLabel, default: 0] += membership.confidence + membership.score
        confidenceTotal += membership.confidence
        firstDate = min(firstDate ?? message.date, message.date)
        semanticTokens.formUnion(SemanticStatusIdentityEvidence.labelTokens(in: membership.displayLabel))
        for tag in message.semanticTags
            where ProjectKeyNormalizer.canonicalKey(tag.tagID.uuidString) == membership.semanticKey {
            semanticTokens.formUnion(SemanticStatusIdentityEvidence.labelTokens(in: tag.displayName))
        }
    }
}

private struct SemanticStatusIdentityAggregate: Sendable {
    let key: String
    var displayVotes: [String: Double] = [:]
    var messageIDs: Set<UUID> = []
    var threadIDs: Set<UUID> = []
    var participantEmails: Set<String> = []
    var identifiers: Set<String> = []
    var labelTokens: Set<String> = []
    var affinityLabelAnchors: Set<String> = []
    var affinityIdentityPhrases: Set<String> = []
    var affinityDistinctiveIdentifiers: Set<String> = []
    var affinityContentPhrases: Set<String> = []
    var conversationSupport: SemanticStatusEvidenceConversationSupport?
    var affinityTokenSupport: [String: SemanticStatusEvidenceConversationSupport] = [:]
    var confidenceTotal = 0.0
    var firstDate: Date?
    var lastDate: Date?

    var messageCount: Int { messageIDs.count }

    var averageConfidence: Double {
        messageCount == 0 ? 0 : confidenceTotal / Double(messageCount)
    }

    var displayLabel: String {
        displayVotes.max {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.key > $1.key
        }?.key ?? ProjectKeyNormalizer.displayLabel(key)
    }

    var durableTokens: Set<String> {
        labelTokens
            .subtracting(SemanticStatusIdentityEvidence.lifecycleTokens)
            .subtracting(SemanticStatusIdentityEvidence.genericTokens)
    }

    var affinitySignatureTokens: Set<String> {
        let needsMultipleConversations = conversationSupport?.hasMultipleConversations == true
        return Set(affinityTokenSupport.compactMap { token, support in
            needsMultipleConversations == false || support.hasMultipleConversations ? token : nil
        })
    }

    var affinityContentTokens: Set<String> {
        Set(affinityTokenSupport.keys)
    }

    var isLifecycleAliasCandidate: Bool {
        guard averageConfidence < 0.90,
              messageCount <= 8,
              labelTokens.isDisjoint(with: SemanticStatusIdentityEvidence.lifecycleTokens) == false else {
            return false
        }
        return durableTokens.count <= 2
    }

    var parentTieBreakScore: Double {
        averageConfidence
            + (Double(messageCount) * 0.05)
            + (Double(durableTokens.count) * 0.02)
    }

    mutating func add(
        message: ProjectMessageInput,
        membership: SemanticAffinityMembership,
        conversationID: UUID,
        affinityEvidence: SemanticStatusAffinityEvidence
    ) {
        messageIDs.insert(message.id)
        conversationSupport.observe(conversationID)
        if let threadID = message.threadID {
            threadIDs.insert(threadID)
        }
        participantEmails.formUnion(message.normalizedParticipantEmails)
        identifiers.formUnion(SemanticStatusIdentityEvidence.identifiers(in: message))
        labelTokens.formUnion(SemanticStatusIdentityEvidence.labelTokens(in: membership.displayLabel))
        affinityLabelAnchors.formUnion(
            SemanticStatusIdentityEvidence.affinityLabelAnchorTokens(in: membership.displayLabel)
        )
        affinityIdentityPhrases.formUnion(
            SemanticStatusIdentityEvidence.affinityLabelIdentityPhrases(in: membership.displayLabel)
        )
        affinityDistinctiveIdentifiers.formUnion(
            SemanticStatusIdentityEvidence.affinityDistinctiveIdentifierTokens(in: membership.displayLabel)
        )
        affinityContentPhrases.formUnion(affinityEvidence.contentPhrases)
        for token in affinityEvidence.contentTokens {
            affinityTokenSupport.observe(conversationID, for: token)
        }
        displayVotes[membership.displayLabel, default: 0] += membership.confidence + membership.score
        confidenceTotal += membership.confidence

        firstDate = min(firstDate ?? message.date, message.date)
        lastDate = max(lastDate ?? message.date, message.date)
    }

    func isPlausibleParent(for child: SemanticStatusIdentityAggregate) -> Bool {
        guard averageConfidence >= 0.90,
              averageConfidence >= child.averageConfidence + 0.03 else {
            return false
        }

        let sharesIdentityEvidence = identifiers.isDisjoint(with: child.identifiers) == false
            || threadIDs.isDisjoint(with: child.threadIDs) == false
        let sharedDurableTokens = durableTokens.intersection(child.durableTokens)
        guard sharesIdentityEvidence || sharedDurableTokens.isEmpty == false else {
            return false
        }

        return durableTokens.count > child.durableTokens.count
            || labelTokens.isSuperset(of: child.labelTokens)
            || sharesIdentityEvidence
    }

    func daysFrom(_ other: SemanticStatusIdentityAggregate) -> Double {
        guard let firstDate,
              let lastDate,
              let otherFirst = other.firstDate,
              let otherLast = other.lastDate else {
            return .infinity
        }
        if lastDate < otherFirst {
            return otherFirst.timeIntervalSince(lastDate) / 86_400
        }
        if otherLast < firstDate {
            return firstDate.timeIntervalSince(otherLast) / 86_400
        }
        return 0
    }

}

/// Records only whether evidence appeared in one or at least two distinct
/// conversations. Affinity gates never need an exact count, so capping here
/// prevents per-token UUID sets from growing with mailbox size.
private struct SemanticStatusEvidenceConversationSupport: Sendable {
    private(set) var firstConversationID: UUID
    private(set) var hasMultipleConversations = false

    init(firstConversationID: UUID) {
        self.firstConversationID = firstConversationID
    }

    mutating func observe(_ conversationID: UUID) {
        if conversationID != firstConversationID {
            hasMultipleConversations = true
        }
    }
}

private extension Optional where Wrapped == SemanticStatusEvidenceConversationSupport {
    mutating func observe(_ conversationID: UUID) {
        if self == nil {
            self = SemanticStatusEvidenceConversationSupport(firstConversationID: conversationID)
        } else {
            self?.observe(conversationID)
        }
    }
}

private extension Dictionary where Key == String, Value == SemanticStatusEvidenceConversationSupport {
    mutating func observe(_ conversationID: UUID, for token: String) {
        if self[token] == nil {
            self[token] = SemanticStatusEvidenceConversationSupport(firstConversationID: conversationID)
        } else {
            self[token]?.observe(conversationID)
        }
    }
}

enum SemanticStatusIdentityEvidence {
    static let lifecycleTokens: Set<String> = [
        "approval", "approved", "complete", "completed", "correction", "corrections",
        "identified", "incomplete", "intake", "issue", "issues", "process", "received",
        "required", "resubmission", "review", "revision", "status", "submission",
        "submitted", "submittal", "update"
    ]

    static let genericTokens: Set<String> = [
        "item", "project", "task", "work"
    ]

    static let threadGenericTokens = genericTokens.union([
        "design", "detail", "details"
    ])

    private static let affinityStopWords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "because", "been", "before",
        "being", "between", "but", "can", "could", "dear", "does", "each", "email", "for",
        "from", "had", "has", "have", "her", "here", "him", "his", "how", "into", "its",
        "may", "more", "must", "not", "now", "our", "please", "regarding", "reply", "said",
        "says", "she", "should", "that", "the", "their", "them", "then", "there", "they",
        "this", "through", "was", "were", "what", "when", "where", "which", "who", "will",
        "with", "would", "you", "your"
    ]

    private static let affinityGenericLabelTokens: Set<String> = [
        "application", "applications", "document", "documents", "form", "forms", "item",
        "letter", "letters", "process", "program", "project", "projects", "recommendation",
        "request", "requests", "task", "tasks", "update", "updates", "work"
    ]

    static let affinityGenericEvidenceTokens = affinityStopWords
        .union(affinityGenericLabelTokens)
        .union(lifecycleTokens)

    static func identifiers(in message: ProjectMessageInput) -> Set<String> {
        var values = Set<String>()
        for text in semanticTextFragments(in: message) {
            values.formUnion(identifierTokens(in: text))
        }
        return values
    }

    static func labelTokens(in label: String) -> Set<String> {
        Set(normalizedWords(in: ProjectKeyNormalizer.displayLabel(label).lowercased()))
    }

    static func affinityLabelAnchorTokens(in label: String) -> Set<String> {
        Set(affinityNormalizedWords(in: ProjectKeyNormalizer.displayLabel(label)))
            .subtracting(affinityStopWords)
            .subtracting(affinityGenericLabelTokens)
            .subtracting(lifecycleTokens)
            .filteringForSemanticAffinity()
    }

    /// Ordered phrases carry project identity in a way individual topical
    /// words cannot. Labels with three or more words contribute trigrams and
    /// four-grams; exact two-word labels remain eligible, and identifier-led
    /// bigrams such as "KDDI scholarship" are retained.
    static func affinityLabelIdentityPhrases(in label: String) -> Set<String> {
        let display = ProjectKeyNormalizer.displayLabel(label)
        let words = affinityNormalizedWords(in: display)
        guard words.count >= 2 else { return [] }

        let identifiers = affinityDistinctiveIdentifierTokens(in: display)
        var phrases: Set<String> = []
        if words.count == 2 {
            phrases.insert(words.joined(separator: " "))
        } else {
            phrases.formUnion(contiguousPhrases(words: words, lengths: 3...4))
        }
        for pair in contiguousPhrases(words: words, lengths: 2...2) {
            let pairTokens = Set(pair.split(separator: " ").map(String.init))
            if pairTokens.isDisjoint(with: identifiers) == false {
                phrases.insert(pair)
            }
        }
        return phrases
    }

    static func affinityDistinctiveIdentifierTokens(in label: String) -> Set<String> {
        let display = ProjectKeyNormalizer.displayLabel(label)
        return Set(affinityNormalizedWords(in: display).filter { token in
            let scalars = token.unicodeScalars
            let hasLetter = scalars.contains { CharacterSet.letters.contains($0) }
            let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
            if hasLetter && hasDigit && token.count >= 5 {
                return true
            }

            let isASCIIWord = scalars.allSatisfy {
                $0.value < 128 && CharacterSet.letters.contains($0)
            }
            if isASCIIWord,
               token.count >= 3,
               display.contains(token.uppercased()) {
                return true
            }

            let hasNonLatinLetter = scalars.contains {
                $0.value >= 128 && CharacterSet.letters.contains($0)
            }
            return hasNonLatinLetter && token.count >= 2
        })
    }

    static func affinityContentTokens(in message: ProjectMessageInput) -> Set<String> {
        affinityEvidence(in: message).contentTokens
    }

    static func affinityContentPhrases(in message: ProjectMessageInput) -> Set<String> {
        affinityEvidence(in: message).contentPhrases
    }

    static func affinityEvidence(in message: ProjectMessageInput) -> SemanticStatusAffinityEvidence {
        var tokens: Set<String> = []
        var phrases: Set<String> = []
        for fragment in semanticTextFragments(in: message) {
            let words = affinityNormalizedWords(in: fragment)
            tokens.formUnion(words)
            phrases.formUnion(contiguousPhrases(words: words, lengths: 2...4))
        }
        return SemanticStatusAffinityEvidence(
            contentTokens: tokens
                .subtracting(affinityStopWords)
                .filteringForSemanticAffinity(),
            contentPhrases: phrases
        )
    }

    static func affinityContent(
        in message: ProjectMessageInput,
        matchesAnyIdentityPhrase identityPhrases: Set<String>
    ) -> Bool {
        identityPhrases.isDisjoint(with: affinityContentPhrases(in: message)) == false
    }

    private static func semanticTextFragments(in message: ProjectMessageInput) -> [String] {
        var fragments = [message.subject]
        if let summary = message.bodySummary {
            fragments.append(summary)
        }
        fragments.append(contentsOf: message.semanticTags.map(\.displayName))
        return fragments
    }

    private static func identifierTokens(in text: String) -> Set<String> {
        let tokens = normalizedWords(in: text.uppercased())

        var identifiers = Set<String>()
        for token in tokens where isDistinctiveIdentifier(token) {
            identifiers.insert(token.lowercased())
        }

        for pair in zip(tokens, tokens.dropFirst()) {
            let combined = pair.0 + pair.1
            if isDistinctiveIdentifier(combined) {
                identifiers.insert(combined.lowercased())
            }
        }

        return identifiers
    }

    private static func isDistinctiveIdentifier(_ token: String) -> Bool {
        let scalars = token.unicodeScalars
        let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        guard hasDigit else { return false }
        let hasLetter = scalars.contains { CharacterSet.letters.contains($0) }
        return (hasLetter && token.count >= 5) || token.count >= 6
    }

    private static func normalizedWords(in text: String) -> [String] {
        var normalized = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
            } else {
                normalized.append(" ")
            }
        }
        return normalized
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    /// Tokenizes mixed-script labels such as `KDDI財団...` at the Latin/non-Latin
    /// boundary. The ordinary project-key tokenizer intentionally preserves its
    /// historical behavior; affinity matching needs this additional boundary so
    /// a durable acronym can bridge translated project names.
    private static func affinityNormalizedWords(in text: String) -> [String] {
        enum ScriptClass: Equatable {
            case latin
            case nonLatinLetter
            case digit
        }

        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var words: [String] = []
        var current = ""
        var currentClass: ScriptClass?

        func scriptClass(for scalar: UnicodeScalar) -> ScriptClass? {
            if CharacterSet.decimalDigits.contains(scalar) {
                return .digit
            }
            guard CharacterSet.letters.contains(scalar) else { return nil }
            return scalar.value < 128 ? .latin : .nonLatinLetter
        }

        func flush() {
            guard current.isEmpty == false else { return }
            words.append(current.lowercased())
            current = ""
            currentClass = nil
        }

        for scalar in folded.unicodeScalars {
            guard let nextClass = scriptClass(for: scalar) else {
                flush()
                continue
            }
            if let currentClass,
               currentClass != nextClass,
               (currentClass == .nonLatinLetter || nextClass == .nonLatinLetter) {
                flush()
            }
            current.unicodeScalars.append(scalar)
            currentClass = nextClass
        }
        flush()
        return words
    }

    private static func contiguousPhrases(
        words: [String],
        lengths: ClosedRange<Int>
    ) -> Set<String> {
        guard words.count >= lengths.lowerBound else { return [] }
        var phrases: Set<String> = []
        let upperLength = min(lengths.upperBound, words.count)
        guard lengths.lowerBound <= upperLength else { return [] }
        for length in lengths.lowerBound...upperLength {
            for start in 0...(words.count - length) {
                phrases.insert(words[start..<(start + length)].joined(separator: " "))
            }
        }
        return phrases
    }
}

private extension Set where Element == String {
    func filteringForSemanticAffinity() -> Set<String> {
        Set(filter { token in
            token.count >= 3 && token.allSatisfy { $0.isNumber } == false
        })
    }
}


struct SemanticStatusPair: Hashable, Sendable {
    let left: String
    let right: String

    init(_ lhs: String, _ rhs: String) {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if left <= right {
            self.left = left
            self.right = right
        } else {
            self.left = right
            self.right = left
        }
    }
}
