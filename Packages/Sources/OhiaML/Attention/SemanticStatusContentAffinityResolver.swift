import Foundation

// Internal semantic-status content expansion retained for Front Page and Timeline.
// Semantic labels seed this graph but cannot create a manual project.

/// Expands extractor-provided project memberships with structural and textual
/// evidence. The extractor remains the source of project seeds; this resolver
/// lets an established project collect related messages whose own project label
/// is absent or drifted across a separate conversation.
enum SemanticStatusContentAffinityResolver {
    static func expandingMemberships(
        messages: [ProjectMessageInput],
        membershipByMessageID: [UUID: [SemanticAffinityMembership]],
        affinityEvidenceIndex: SemanticStatusAffinityEvidenceIndex
    ) -> [UUID: [SemanticAffinityMembership]] {
        guard messages.isEmpty == false else { return membershipByMessageID }

        let conversationIDByMessageID = SemanticStatusIdentityResolver.conversationComponentIDs(messages)
        var expanded = inheritingSoleConversationMemberships(
            messages: messages,
            membershipByMessageID: membershipByMessageID,
            conversationIDByMessageID: conversationIDByMessageID
        )
        let contentTokensByMessageID = Dictionary(uniqueKeysWithValues: messages.map { message in
            (message.id, affinityEvidenceIndex.evidence(for: message.id)?.contentTokens ?? [])
        })
        let profiles = semanticProfiles(
            messages: messages,
            membershipByMessageID: expanded,
            contentTokensByMessageID: contentTokensByMessageID,
            conversationIDByMessageID: conversationIDByMessageID
        ).filter { $0.messageIDs.count >= 2 }
        guard profiles.isEmpty == false else { return expanded }
        let explicitSemanticPairs = Set(expanded.values.flatMap { memberships in
            semanticPairs(memberships.map(\.semanticKey))
        })

        var semanticKeysByAnchor: [String: Set<String>] = [:]
        let semanticProfileByKey = Dictionary(uniqueKeysWithValues: profiles.map { ($0.key, $0) })
        for profile in profiles {
            for anchor in profile.labelAnchors {
                semanticKeysByAnchor[anchor, default: []].insert(profile.key)
            }
        }

        for message in messages {
            let contentTokens = contentTokensByMessageID[message.id] ?? []
            let existingKeys = Set((expanded[message.id] ?? []).map(\.semanticKey))
            let candidateKeys = contentTokens.reduce(into: Set<String>()) { keys, token in
                keys.formUnion(semanticKeysByAnchor[token] ?? [])
            }.subtracting(existingKeys).filter { candidateKey in
                existingKeys.allSatisfy { existingKey in
                    explicitSemanticPairs.contains(SemanticStatusPair(existingKey, candidateKey)) == false
                }
            }
            let contentPhrases: Set<String> = candidateKeys.isEmpty
                ? []
                : affinityEvidenceIndex.evidence(for: message.id)?.contentPhrases ?? []

            let matches = candidateKeys.compactMap { key -> SemanticStatusAffinityMatch? in
                guard let profile = semanticProfileByKey[key] else { return nil }
                return match(
                    message: message,
                    contentTokens: contentTokens,
                    contentPhrases: contentPhrases,
                    profile: profile
                )
            }.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.profile.key < rhs.profile.key
            }

            guard let best = matches.first,
                  best.score >= 6 else {
                continue
            }
            if let runnerUp = matches.dropFirst().first,
               best.score - runnerUp.score < 1 {
                continue
            }

            let confidence = min(0.92, 0.72 + ((best.score - 6) * 0.04))
            let derived = SemanticAffinityMembership(
                semanticKey: best.profile.key,
                displayLabel: best.profile.displayLabel,
                score: confidence,
                confidence: confidence,
                strength: .secondary,
                sourceCentrality: .secondary
            )
            expanded[message.id] = sortedPreferredMemberships(
                (expanded[message.id] ?? []) + [derived]
            )
        }
        return expanded
    }

    /// A message with no project label still belongs to a sole-project reply
    /// chain. Multi-project conversations stay unresolved here; their content
    /// must select a unique project below rather than inheriting every label.
    private static func inheritingSoleConversationMemberships(
        messages: [ProjectMessageInput],
        membershipByMessageID: [UUID: [SemanticAffinityMembership]],
        conversationIDByMessageID: [UUID: UUID]
    ) -> [UUID: [SemanticAffinityMembership]] {
        let messagesByConversation = Dictionary(grouping: messages) { message in
            conversationIDByMessageID[message.id] ?? message.id
        }
        var expanded = membershipByMessageID

        for conversationMessages in messagesByConversation.values {
            let memberships = sortedPreferredMemberships(
                conversationMessages.flatMap { membershipByMessageID[$0.id] ?? [] }
            )
            guard memberships.count == 1,
                  let source = memberships.first else {
                continue
            }
            let inherited = SemanticAffinityMembership(
                semanticKey: source.semanticKey,
                displayLabel: source.displayLabel,
                score: min(source.score, 0.82),
                confidence: min(source.confidence, 0.82),
                strength: .secondary,
                sourceCentrality: .secondary
            )
            for message in conversationMessages where (expanded[message.id] ?? []).isEmpty {
                expanded[message.id] = [inherited]
            }
        }
        return expanded
    }

    private static func semanticProfiles(
        messages: [ProjectMessageInput],
        membershipByMessageID: [UUID: [SemanticAffinityMembership]],
        contentTokensByMessageID: [UUID: Set<String>],
        conversationIDByMessageID: [UUID: UUID]
    ) -> [SemanticStatusAffinityProfile] {
        var profilesByKey: [String: SemanticStatusAffinityProfile] = [:]
        for message in messages {
            for membership in membershipByMessageID[message.id] ?? [] {
                profilesByKey[membership.semanticKey, default: SemanticStatusAffinityProfile(key: membership.semanticKey)]
                    .add(
                        message: message,
                        membership: membership,
                        contentTokens: contentTokensByMessageID[message.id] ?? [],
                        conversationID: conversationIDByMessageID[message.id] ?? message.id
                    )
            }
        }
        return Array(profilesByKey.values)
    }

    private static func match(
        message: ProjectMessageInput,
        contentTokens: Set<String>,
        contentPhrases: Set<String>,
        profile: SemanticStatusAffinityProfile
    ) -> SemanticStatusAffinityMatch? {
        let sharedIdentityPhrases = profile.identityPhrases.intersection(contentPhrases)
        let sharedDistinctiveIdentifiers = profile.distinctiveIdentifiers.intersection(contentTokens)
        let sharedAnchors = profile.labelAnchors.intersection(contentTokens)
        guard sharedAnchors.isEmpty == false else { return nil }
        let sharedNonIdentifierAnchors = sharedAnchors.subtracting(sharedDistinctiveIdentifiers)
        guard sharedIdentityPhrases.isEmpty == false
            || (sharedDistinctiveIdentifiers.isEmpty == false
                && sharedNonIdentifierAnchors.isEmpty == false) else {
            return nil
        }
        let sharedEvidence = profile.signatureTokens
            .intersection(contentTokens)
            .subtracting(sharedAnchors)
        guard sharedEvidence.count >= 2,
              profile.days(from: message.date) <= 120 else {
            return nil
        }

        var score = Double(sharedAnchors.count * 3)
            + (Double(min(5, sharedEvidence.count)) * 0.8)
        let dayGap = profile.days(from: message.date)
        if dayGap <= 30 {
            score += 1
        } else if dayGap <= 60 {
            score += 0.5
        }
        if let threadID = message.threadID,
           profile.threadIDs.contains(threadID) {
            score += 2
        }
        return SemanticStatusAffinityMatch(profile: profile, score: score)
    }

    private static func sortedPreferredMemberships(
        _ memberships: [SemanticAffinityMembership]
    ) -> [SemanticAffinityMembership] {
        var membershipBySemanticKey: [String: SemanticAffinityMembership] = [:]
        for membership in memberships {
            if let existing = membershipBySemanticKey[membership.semanticKey] {
                membershipBySemanticKey[membership.semanticKey] = SemanticStatusIdentityResolution.preferredMembership(
                    existing,
                    membership
                )
            } else {
                membershipBySemanticKey[membership.semanticKey] = membership
            }
        }
        return membershipBySemanticKey.values.sorted { lhs, rhs in
            if lhs.strength != rhs.strength { return lhs.strength > rhs.strength }
            let leftScore = lhs.score + lhs.confidence
            let rightScore = rhs.score + rhs.confidence
            if leftScore != rightScore { return leftScore > rightScore }
            return lhs.semanticKey < rhs.semanticKey
        }
    }

    private static func semanticPairs(_ rawKeys: [String]) -> [SemanticStatusPair] {
        let keys = Array(Set(rawKeys.map(ProjectKeyNormalizer.canonicalKey))).sorted()
        guard keys.count > 1 else { return [] }
        var pairs: [SemanticStatusPair] = []
        for leftIndex in keys.indices {
            for rightIndex in keys.indices where rightIndex > leftIndex {
                pairs.append(SemanticStatusPair(keys[leftIndex], keys[rightIndex]))
            }
        }
        return pairs
    }
}

private struct SemanticStatusAffinityMatch {
    let profile: SemanticStatusAffinityProfile
    let score: Double
}

private struct SemanticStatusAffinityProfile {
    let key: String
    var displayVotes: [String: Double] = [:]
    var messageIDs: Set<UUID> = []
    var threadIDs: Set<UUID> = []
    var conversationIDs: Set<UUID> = []
    var labelAnchors: Set<String> = []
    var identityPhrases: Set<String> = []
    var distinctiveIdentifiers: Set<String> = []
    var conversationIDsByContentToken: [String: Set<UUID>] = [:]
    var firstDate: Date?
    var lastDate: Date?

    var displayLabel: String {
        displayVotes.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }?.key ?? ProjectKeyNormalizer.displayLabel(key)
    }

    var signatureTokens: Set<String> {
        let minimumSupport = conversationIDs.count >= 2 ? 2 : 1
        return Set(conversationIDsByContentToken.compactMap { token, supportingConversations in
            supportingConversations.count >= minimumSupport ? token : nil
        })
    }

    mutating func add(
        message: ProjectMessageInput,
        membership: SemanticAffinityMembership,
        contentTokens: Set<String>,
        conversationID: UUID
    ) {
        guard messageIDs.insert(message.id).inserted else { return }
        conversationIDs.insert(conversationID)
        displayVotes[membership.displayLabel, default: 0] += membership.score + membership.confidence
        if let threadID = message.threadID {
            threadIDs.insert(threadID)
        }
        labelAnchors.formUnion(
            SemanticStatusIdentityEvidence.affinityLabelAnchorTokens(in: membership.displayLabel)
        )
        identityPhrases.formUnion(
            SemanticStatusIdentityEvidence.affinityLabelIdentityPhrases(in: membership.displayLabel)
        )
        distinctiveIdentifiers.formUnion(
            SemanticStatusIdentityEvidence.affinityDistinctiveIdentifierTokens(in: membership.displayLabel)
        )
        for token in contentTokens {
            conversationIDsByContentToken[token, default: []].insert(conversationID)
        }
        firstDate = min(firstDate ?? message.date, message.date)
        lastDate = max(lastDate ?? message.date, message.date)
    }

    func days(from date: Date) -> Double {
        guard let firstDate, let lastDate else { return .infinity }
        if date < firstDate {
            return firstDate.timeIntervalSince(date) / 86_400
        }
        if date > lastDate {
            return date.timeIntervalSince(lastDate) / 86_400
        }
        return 0
    }
}
