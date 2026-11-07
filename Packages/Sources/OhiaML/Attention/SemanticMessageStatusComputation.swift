import Foundation
import OhiaCore

/// The persisted-ingestion boundary used by non-Projects status surfaces.
/// This is semantic-status scope only; it cannot create or mutate a manual
/// project.
public struct SemanticStatusActiveWindow: Sendable, Equatable {
    public let cutoffByAccountID: [UUID: Date]
    public let fallbackCutoff: Date?

    public init(cutoffByAccountID: [UUID: Date] = [:], fallbackCutoff: Date? = nil) {
        self.cutoffByAccountID = cutoffByAccountID
        self.fallbackCutoff = fallbackCutoff
    }

    public var isEnabled: Bool {
        cutoffByAccountID.isEmpty == false || fallbackCutoff != nil
    }

    public var fingerprint: String {
        let scoped = cutoffByAccountID
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { "\($0.key.uuidString)=\(Int($0.value.timeIntervalSince1970))" }
            .joined(separator: "|")
        let fallback = fallbackCutoff.map { String(Int($0.timeIntervalSince1970)) } ?? "nil"
        return "freshStart:\(scoped):fallback=\(fallback)"
    }

    public func contains(date: Date, accountID: UUID?) -> Bool {
        guard let cutoff = accountID.flatMap({ cutoffByAccountID[$0] }) ?? fallbackCutoff else {
            return false
        }
        return date >= cutoff
    }
}

public struct SemanticMessageStatusConfiguration: Sendable, Equatable {
    public let now: Date
    public let revivalQuietGap: TimeInterval
    public let revivalRecentWindow: TimeInterval
    public let includeWeakSharedCorrespondentLinks: Bool
    public let activeWindow: SemanticStatusActiveWindow?
    /// The user's own send-as addresses (e.g. every `Identity.address` across
    /// accounts), lowercased. Used to tell an actual correspondence
    /// continuing from the user simply appearing in both messages — every
    /// message the user sends or receives names them, so without this a
    /// batch containing no self-sent mail (a freshly connected account, a
    /// narrow filter scope) would infer no self addresses at all and treat
    /// the user's own recurring presence as correspondent overlap. Callers
    /// should source this from `Identity` rather than leave it empty.
    public let selfAddresses: Set<String>

    public init(
        now: Date = .now,
        revivalQuietGap: TimeInterval = 45 * 86_400,
        revivalRecentWindow: TimeInterval = 21 * 86_400,
        includeWeakSharedCorrespondentLinks: Bool = false,
        activeWindow: SemanticStatusActiveWindow? = nil,
        selfAddresses: Set<String> = []
    ) {
        self.now = now
        self.revivalQuietGap = revivalQuietGap
        self.revivalRecentWindow = revivalRecentWindow
        self.includeWeakSharedCorrespondentLinks = includeWeakSharedCorrespondentLinks
        self.activeWindow = activeWindow
        self.selfAddresses = Set(selfAddresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }
}

/// The semantic status enrichment retained for Front Page and Timeline after
/// Projects became explicitly configured. It intentionally exposes no project
/// rows, names, membership model, or persistence API.
public struct SemanticMessageStatusSnapshot: Sendable, Equatable {
    public let builtAt: Date
    public let statusSignals: MessageStatusSignalIndex
    public let scopedMessageIDs: Set<UUID>
    public let semanticGroupCount: Int

    private let semanticMemberMessageIDs: Set<UUID>
    private let visibleAttentionKindsByMessageID: [UUID: Set<MessageAttentionKind>]

    fileprivate init(
        builtAt: Date,
        statusSignals: MessageStatusSignalIndex,
        scopedMessageIDs: Set<UUID>,
        semanticGroupCount: Int,
        semanticMemberMessageIDs: Set<UUID>,
        visibleAttentionKindsByMessageID: [UUID: Set<MessageAttentionKind>]
    ) {
        self.builtAt = builtAt
        self.statusSignals = statusSignals
        self.scopedMessageIDs = scopedMessageIDs
        self.semanticGroupCount = semanticGroupCount
        self.semanticMemberMessageIDs = semanticMemberMessageIDs
        self.visibleAttentionKindsByMessageID = visibleAttentionKindsByMessageID
    }

    public func applyingAttentionGate(
        to states: [UUID: MessageAttentionState]
    ) -> [UUID: MessageAttentionState] {
        guard states.isEmpty == false, semanticMemberMessageIDs.isEmpty == false else {
            return states
        }

        var gated = states
        for messageID in semanticMemberMessageIDs {
            guard let state = gated[messageID] else { continue }
            let visibleKinds = visibleAttentionKindsByMessageID[messageID] ?? []
            let openKinds = state.openKinds.intersection(visibleKinds)
            guard openKinds != state.openKinds else { continue }
            gated[messageID] = MessageAttentionState(
                messageID: state.messageID,
                openKinds: openKinds,
                clearsByMessageID: state.clearsByMessageID
            )
        }
        return gated
    }

    public func projected(matchingMessageIDs: Set<UUID>) -> SemanticMessageStatusSnapshot {
        let projectedEvidence = statusSignals.sharedEvidenceKindsByMessageID.filter { messageID, _ in
            matchingMessageIDs.contains(messageID)
        }
        return SemanticMessageStatusSnapshot(
            builtAt: builtAt,
            statusSignals: MessageStatusSignalIndex(
                revivedMessageIDs: statusSignals.revivedMessageIDs.intersection(matchingMessageIDs),
                sharedEvidenceKindsByMessageID: projectedEvidence
            ),
            scopedMessageIDs: scopedMessageIDs.intersection(matchingMessageIDs),
            semanticGroupCount: semanticGroupCount,
            semanticMemberMessageIDs: semanticMemberMessageIDs,
            visibleAttentionKindsByMessageID: visibleAttentionKindsByMessageID
        )
    }
}

public enum SemanticMessageStatusComputation {
    private static let weakOrphanConfidenceThreshold = 0.90
    private static let weakOrphanMaximumMessageCount = 2

    public static func snapshot(
        messages rawMessages: [ProjectMessageInput],
        sharedMessageActions: ProjectLensSharedMessageActionState = .empty,
        configuration: SemanticMessageStatusConfiguration = SemanticMessageStatusConfiguration()
    ) -> SemanticMessageStatusSnapshot {
        let messages = rawMessages.sorted(by: semanticMessageSort)
        let rawMemberships = Dictionary(uniqueKeysWithValues: messages.map { message in
            (message.id, SemanticAffinityMembershipResolver.memberships(for: message))
        })
        let affinityEvidenceIndex = SemanticStatusAffinityEvidenceIndex(messages: messages)
        let identityResolution = SemanticStatusIdentityResolver.resolve(
            messages: messages,
            membershipByMessageID: rawMemberships,
            affinityEvidenceIndex: affinityEvidenceIndex
        )
        let resolvedMemberships = identityResolution.resolvedMembershipsByMessageID(rawMemberships)
        let membershipsByMessageID = SemanticStatusContentAffinityResolver.expandingMemberships(
            messages: messages,
            membershipByMessageID: resolvedMemberships,
            affinityEvidenceIndex: affinityEvidenceIndex
        )
        let semanticMemberMessageIDs = Set(membershipsByMessageID.compactMap { messageID, memberships in
            memberships.isEmpty ? nil : messageID
        })
        let liveSemanticKeys = Set(messages.flatMap { message -> [String] in
            guard message.isLiveInbound else { return [] }
            return membershipsByMessageID[message.id]?.map(\.semanticKey) ?? []
        })
        let rawAttention = MessageAttentionResolver.states(
            messages: messages.map(MessageAttentionInput.init(projectMessage:)),
            userActions: MessageAttentionUserActionState(
                resolvedMessageIDs: sharedMessageActions.resolvedMessageIDs,
                replyNeededMessageIDs: sharedMessageActions.replyNeededMessageIDs,
                repliedMessageIDs: sharedMessageActions.repliedMessageIDs,
                confirmationNeededMessageIDs: sharedMessageActions.confirmationNeededMessageIDs,
                confirmedMessageIDs: sharedMessageActions.confirmedMessageIDs
            )
        )

        let preliminaryGroups = semanticGroups(
            messages: messages,
            membershipsByMessageID: membershipsByMessageID,
            allowedKeys: liveSemanticKeys,
            rawAttention: rawAttention,
            sharedMessageActions: sharedMessageActions
        )
        let preliminaryKeys = Set(preliminaryGroups.keys)
        let linkedKeys = strongLinkedSemanticKeys(
            messages: messages,
            membershipsByMessageID: membershipsByMessageID,
            allowedKeys: preliminaryKeys
        )
        let visibleGroups = preliminaryGroups.filter { _, group in
            isWeakOrphan(group, linkedKeys: linkedKeys) == false
        }
        let visibleKeys = Set(visibleGroups.keys)
        let activeKeys = activeSemanticKeys(
            groups: visibleGroups,
            messages: messages,
            membershipsByMessageID: membershipsByMessageID,
            activeWindow: configuration.activeWindow
        )
        let visibleAttention = visibleAttentionKinds(
            groups: visibleGroups,
            activeKeys: activeKeys
        )
        let statusSignals = statusSignals(
            messages: messages,
            groups: visibleGroups,
            membershipsByMessageID: membershipsByMessageID,
            visibleKeys: visibleKeys,
            configuration: configuration
        )

        return SemanticMessageStatusSnapshot(
            builtAt: configuration.now,
            statusSignals: statusSignals,
            scopedMessageIDs: Set(messages.map(\.id)),
            semanticGroupCount: visibleGroups.count,
            semanticMemberMessageIDs: semanticMemberMessageIDs,
            visibleAttentionKindsByMessageID: visibleAttention
        )
    }

    private static func semanticGroups(
        messages: [ProjectMessageInput],
        membershipsByMessageID: [UUID: [SemanticAffinityMembership]],
        allowedKeys: Set<String>,
        rawAttention: [UUID: MessageAttentionState],
        sharedMessageActions: ProjectLensSharedMessageActionState
    ) -> [String: SemanticStatusGroup] {
        var groups: [String: SemanticStatusGroup] = [:]
        for message in messages {
            for membership in membershipsByMessageID[message.id] ?? []
            where allowedKeys.contains(membership.semanticKey) {
                groups[membership.semanticKey, default: SemanticStatusGroup(key: membership.semanticKey)]
                    .add(
                        message: message,
                        membership: membership,
                        attention: rawAttention[message.id]
                    )
            }
        }
        for key in groups.keys {
            guard var group = groups[key] else { continue }
            group.isResolvedByMessageClosures = messageClosureResolutionApplies(
                messages: group.messages,
                openAttentionCount: group.openAttentionCount,
                sharedMessageActions: sharedMessageActions
            )
            groups[key] = group
        }
        return groups
    }

    private static func activeSemanticKeys(
        groups: [String: SemanticStatusGroup],
        messages: [ProjectMessageInput],
        membershipsByMessageID: [UUID: [SemanticAffinityMembership]],
        activeWindow: SemanticStatusActiveWindow?
    ) -> Set<String> {
        let keys = Set(groups.keys)
        guard let activeWindow, activeWindow.isEnabled else {
            return keys
        }

        let recentKeys = Set(groups.compactMap { key, group in
            group.messages.contains {
                activeWindow.contains(date: $0.date, accountID: $0.accountID)
            } ? key : nil
        })
        let directLinks = strongSemanticLinks(
            messages: messages,
            membershipsByMessageID: membershipsByMessageID,
            allowedKeys: keys
        )
        var activeKeys = recentKeys
        for link in directLinks {
            if recentKeys.contains(link.left) {
                activeKeys.insert(link.right)
            }
            if recentKeys.contains(link.right) {
                activeKeys.insert(link.left)
            }
        }
        for (key, group) in groups where group.isResolvedByMessageClosures {
            activeKeys.insert(key)
        }
        return activeKeys
    }

    private static func visibleAttentionKinds(
        groups: [String: SemanticStatusGroup],
        activeKeys: Set<String>
    ) -> [UUID: Set<MessageAttentionKind>] {
        var visible: [UUID: Set<MessageAttentionKind>] = [:]
        for key in activeKeys.sorted() {
            guard let group = groups[key] else { continue }
            for (messageID, kinds) in group.openAttentionKindsByMessageID {
                visible[messageID, default: []].formUnion(kinds)
            }
        }
        return visible
    }

    private static func isWeakOrphan(
        _ group: SemanticStatusGroup,
        linkedKeys: Set<String>
    ) -> Bool {
        guard group.confidence < weakOrphanConfidenceThreshold,
              group.messages.count <= weakOrphanMaximumMessageCount,
              group.isResolvedByMessageClosures == false,
              group.openAttentionCount == 0,
              group.hasDeadline == false,
              linkedKeys.contains(group.key) == false,
              group.hasSharedThreadEvidence == false,
              group.hasReplyReferenceEvidence == false,
              group.hasSharedIdentifierEvidence == false else {
            return false
        }
        return true
    }

    private static func messageClosureResolutionApplies(
        messages: [ProjectMessageInput],
        openAttentionCount: Int,
        sharedMessageActions: ProjectLensSharedMessageActionState
    ) -> Bool {
        guard openAttentionCount == 0 else { return false }
        return messages.contains { message in
            sharedMessageActions.resolvedMessageIDs.contains(message.id)
                || sharedMessageActions.confirmedMessageIDs.contains(message.id)
        }
    }

    private static func statusSignals(
        messages: [ProjectMessageInput],
        groups: [String: SemanticStatusGroup],
        membershipsByMessageID: [UUID: [SemanticAffinityMembership]],
        visibleKeys: Set<String>,
        configuration: SemanticMessageStatusConfiguration
    ) -> MessageStatusSignalIndex {
        // Batch-inferred self addresses supplement (never replace) the
        // configuration's identity-sourced set: a scope with no self-sent
        // mail must still resolve correctly via `configuration.selfAddresses`.
        let selfAddresses = configuration.selfAddresses
            .union(messages.filter(\.isSentByUser).map(\.fromAddress))
        var revivedMessageIDs = Set<UUID>()
        for key in groups.keys.sorted() {
            let groupedMessages = groups[key]?.messages ?? []
            for (earlier, later) in zip(groupedMessages, groupedMessages.dropFirst()) {
                let gap = later.date.timeIntervalSince(earlier.date)
                guard gap >= configuration.revivalQuietGap,
                      configuration.now.timeIntervalSince(later.date) <= configuration.revivalRecentWindow,
                      isSameCorrespondence(earlier, later, selfAddresses: selfAddresses) else {
                    continue
                }
                revivedMessageIDs.insert(later.id)
            }
        }

        let linkEvidence = semanticLinkEvidence(
            messages: messages,
            membershipsByMessageID: membershipsByMessageID,
            allowedKeys: visibleKeys,
            includeWeakSharedCorrespondentLinks: configuration.includeWeakSharedCorrespondentLinks
        )
        var sharedEvidence: [UUID: Set<MessageSharedEvidenceKind>] = [:]
        for evidence in linkEvidence.values.flatMap({ $0 }) {
            for messageID in evidence.messageIDs {
                sharedEvidence[messageID, default: []].insert(evidence.kind)
            }
        }
        for message in messages where hasDirectSharedRecipientEvidence(message) {
            sharedEvidence[message.id, default: []].insert(.ccOrBcc)
        }

        return MessageStatusSignalIndex(
            revivedMessageIDs: revivedMessageIDs,
            sharedEvidenceKindsByMessageID: sharedEvidence
        )
    }

    /// Semantic groups link messages by shared topic, which can pull in
    /// messages about the same subject that never involved the same people
    /// (e.g. two unrelated conversations about the same property). A gap
    /// between such messages is not a correspondence going quiet and coming
    /// back — it is just the topic recurring — so "Revived" must additionally
    /// require actual continuity: the same thread, an explicit reply
    /// reference, or an overlapping non-self participant between the two
    /// messages.
    private static func isSameCorrespondence(
        _ earlier: ProjectMessageInput,
        _ later: ProjectMessageInput,
        selfAddresses: Set<String>
    ) -> Bool {
        if let earlierThread = earlier.threadID, let laterThread = later.threadID,
           earlierThread == laterThread {
            return true
        }
        if let earlierHeader = earlier.messageIDHeader, later.referencesHeaders.contains(earlierHeader) {
            return true
        }
        if let laterHeader = later.messageIDHeader, earlier.referencesHeaders.contains(laterHeader) {
            return true
        }
        let earlierExternal = earlier.normalizedParticipantEmails.subtracting(selfAddresses)
        let laterExternal = later.normalizedParticipantEmails.subtracting(selfAddresses)
        return earlierExternal.isDisjoint(with: laterExternal) == false
    }

    private static func strongLinkedSemanticKeys(
        messages: [ProjectMessageInput],
        membershipsByMessageID: [UUID: [SemanticAffinityMembership]],
        allowedKeys: Set<String>
    ) -> Set<String> {
        Set(strongSemanticLinks(
            messages: messages,
            membershipsByMessageID: membershipsByMessageID,
            allowedKeys: allowedKeys
        ).flatMap { [$0.left, $0.right] })
    }

    private static func strongSemanticLinks(
        messages: [ProjectMessageInput],
        membershipsByMessageID: [UUID: [SemanticAffinityMembership]],
        allowedKeys: Set<String>
    ) -> Set<SemanticStatusPair> {
        Set(semanticLinkEvidence(
            messages: messages,
            membershipsByMessageID: membershipsByMessageID,
            allowedKeys: allowedKeys,
            includeWeakSharedCorrespondentLinks: false
        ).keys)
    }

    private static func semanticLinkEvidence(
        messages: [ProjectMessageInput],
        membershipsByMessageID: [UUID: [SemanticAffinityMembership]],
        allowedKeys: Set<String>,
        includeWeakSharedCorrespondentLinks: Bool
    ) -> [SemanticStatusPair: [SemanticStatusLinkEvidence]] {
        var evidenceByPair: [SemanticStatusPair: [SemanticStatusLinkEvidence]] = [:]
        addSameMessageEvidence(
            membershipsByMessageID: membershipsByMessageID,
            allowedKeys: allowedKeys,
            evidenceByPair: &evidenceByPair
        )
        addSameThreadEvidence(
            messages: messages,
            membershipsByMessageID: membershipsByMessageID,
            allowedKeys: allowedKeys,
            evidenceByPair: &evidenceByPair
        )
        addReplyReferenceEvidence(
            messages: messages,
            membershipsByMessageID: membershipsByMessageID,
            allowedKeys: allowedKeys,
            evidenceByPair: &evidenceByPair
        )
        addResponseChainEvidence(
            messages: messages,
            membershipsByMessageID: membershipsByMessageID,
            allowedKeys: allowedKeys,
            evidenceByPair: &evidenceByPair
        )
        if includeWeakSharedCorrespondentLinks {
            addSharedCorrespondentEvidence(
                messages: messages,
                membershipsByMessageID: membershipsByMessageID,
                allowedKeys: allowedKeys,
                evidenceByPair: &evidenceByPair
            )
        }
        return evidenceByPair
    }

    private static func addSameMessageEvidence(
        membershipsByMessageID: [UUID: [SemanticAffinityMembership]],
        allowedKeys: Set<String>,
        evidenceByPair: inout [SemanticStatusPair: [SemanticStatusLinkEvidence]]
    ) {
        for (messageID, memberships) in membershipsByMessageID {
            let keys = Set(memberships.map(\.semanticKey)).intersection(allowedKeys)
            for pair in semanticPairs(keys) {
                evidenceByPair[pair, default: []].append(
                    SemanticStatusLinkEvidence(kind: .sameMessage, messageIDs: [messageID])
                )
            }
        }
    }

    private static func addSameThreadEvidence(
        messages: [ProjectMessageInput],
        membershipsByMessageID: [UUID: [SemanticAffinityMembership]],
        allowedKeys: Set<String>,
        evidenceByPair: inout [SemanticStatusPair: [SemanticStatusLinkEvidence]]
    ) {
        let messagesByThread = Dictionary(grouping: messages.filter { $0.threadID != nil }) { $0.threadID! }
        for threadMessages in messagesByThread.values {
            let keys = Set(threadMessages.flatMap {
                membershipsByMessageID[$0.id]?.map(\.semanticKey) ?? []
            }).intersection(allowedKeys)
            let messageIDs = threadMessages.map(\.id)
            for pair in semanticPairs(keys) {
                evidenceByPair[pair, default: []].append(
                    SemanticStatusLinkEvidence(kind: .sameThread, messageIDs: messageIDs)
                )
            }
        }
    }

    private static func addReplyReferenceEvidence(
        messages: [ProjectMessageInput],
        membershipsByMessageID: [UUID: [SemanticAffinityMembership]],
        allowedKeys: Set<String>,
        evidenceByPair: inout [SemanticStatusPair: [SemanticStatusLinkEvidence]]
    ) {
        let messageByHeader = messages.reduce(into: [String: ProjectMessageInput]()) { result, message in
            guard let header = message.messageIDHeader else { return }
            result[header] = message
        }
        for message in messages {
            let messageKeys = membershipsByMessageID[message.id]?.map(\.semanticKey) ?? []
            guard messageKeys.isEmpty == false else { continue }
            for reference in message.referencesHeaders {
                guard let referenced = messageByHeader[reference] else { continue }
                let referencedKeys = membershipsByMessageID[referenced.id]?.map(\.semanticKey) ?? []
                let keys = Set(messageKeys + referencedKeys).intersection(allowedKeys)
                for pair in semanticPairs(keys) {
                    evidenceByPair[pair, default: []].append(
                        SemanticStatusLinkEvidence(
                            kind: .replyReference,
                            messageIDs: [message.id, referenced.id]
                        )
                    )
                }
            }
        }
    }

    private static func addResponseChainEvidence(
        messages: [ProjectMessageInput],
        membershipsByMessageID: [UUID: [SemanticAffinityMembership]],
        allowedKeys: Set<String>,
        evidenceByPair: inout [SemanticStatusPair: [SemanticStatusLinkEvidence]]
    ) {
        let messagesByThread = Dictionary(grouping: messages.filter { $0.threadID != nil }) { $0.threadID! }
        for threadMessages in messagesByThread.values {
            let sorted = threadMessages.sorted(by: semanticMessageSort)
            for inbound in sorted where inbound.isSentByUser == false
                && inbound.triageVerdict?.isActionable == true {
                guard let sentReply = sorted.first(where: {
                    $0.isSentByUser && $0.date > inbound.date
                }) else {
                    continue
                }
                let inboundKeys = membershipsByMessageID[inbound.id]?.map(\.semanticKey) ?? []
                let replyKeys = membershipsByMessageID[sentReply.id]?.map(\.semanticKey) ?? []
                let keys = Set(inboundKeys + replyKeys).intersection(allowedKeys)
                for pair in semanticPairs(keys) {
                    evidenceByPair[pair, default: []].append(
                        SemanticStatusLinkEvidence(
                            kind: .responseChain,
                            messageIDs: [inbound.id, sentReply.id]
                        )
                    )
                }
            }
        }
    }

    private static func addSharedCorrespondentEvidence(
        messages: [ProjectMessageInput],
        membershipsByMessageID: [UUID: [SemanticAffinityMembership]],
        allowedKeys: Set<String>,
        evidenceByPair: inout [SemanticStatusPair: [SemanticStatusLinkEvidence]]
    ) {
        var correspondentsByKey: [String: Set<String>] = [:]
        var exampleMessageByKeyAndEmail: [String: UUID] = [:]
        for message in messages {
            let keys = membershipsByMessageID[message.id]?.map(\.semanticKey) ?? []
            for key in keys where allowedKeys.contains(key) {
                correspondentsByKey[key, default: []].formUnion(message.normalizedParticipantEmails)
                for email in message.normalizedParticipantEmails {
                    exampleMessageByKeyAndEmail["\(key)|\(email)"] = message.id
                }
            }
        }
        for pair in semanticPairs(Set(correspondentsByKey.keys)) {
            let shared = (correspondentsByKey[pair.left] ?? [])
                .intersection(correspondentsByKey[pair.right] ?? [])
            guard let email = shared.sorted().first else { continue }
            let messageIDs = [
                exampleMessageByKeyAndEmail["\(pair.left)|\(email)"],
                exampleMessageByKeyAndEmail["\(pair.right)|\(email)"],
            ].compactMap { $0 }
            evidenceByPair[pair, default: []].append(
                SemanticStatusLinkEvidence(kind: .sharedCorrespondent, messageIDs: messageIDs)
            )
        }
    }

    private static func semanticPairs(_ keys: Set<String>) -> [SemanticStatusPair] {
        let sorted = keys.sorted()
        guard sorted.count > 1 else { return [] }
        var pairs: [SemanticStatusPair] = []
        for leftIndex in sorted.indices {
            for rightIndex in sorted.indices where rightIndex > leftIndex {
                pairs.append(SemanticStatusPair(sorted[leftIndex], sorted[rightIndex]))
            }
        }
        return pairs
    }

    private static func hasDirectSharedRecipientEvidence(_ message: ProjectMessageInput) -> Bool {
        message.participants.contains { participant in
            participant.email.isEmpty == false
                && (participant.role == .cc || participant.role == .bcc)
        }
    }

    private static func semanticMessageSort(
        _ lhs: ProjectMessageInput,
        _ rhs: ProjectMessageInput
    ) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct SemanticStatusLinkEvidence: Sendable, Equatable {
    let kind: MessageSharedEvidenceKind
    let messageIDs: [UUID]
}

private struct SemanticStatusGroup {
    let key: String
    var messages: [ProjectMessageInput] = []
    var confidenceTotal = 0.0
    var threadCounts: [UUID: Int] = [:]
    var identifierCounts: [String: Int] = [:]
    var messageIDHeaders: Set<String> = []
    var referencedHeaders: Set<String> = []
    var openAttentionKindsByMessageID: [UUID: Set<MessageAttentionKind>] = [:]
    var isResolvedByMessageClosures = false

    var confidence: Double {
        messages.isEmpty ? 0 : confidenceTotal / Double(messages.count)
    }

    var openAttentionCount: Int {
        openAttentionKindsByMessageID.values.reduce(0) { $0 + $1.count }
    }

    var hasSharedThreadEvidence: Bool {
        threadCounts.values.contains { $0 >= 2 }
    }

    var hasSharedIdentifierEvidence: Bool {
        identifierCounts.values.contains { $0 >= 2 }
    }

    var hasReplyReferenceEvidence: Bool {
        messageIDHeaders.isDisjoint(with: referencedHeaders) == false
    }

    var hasDeadline: Bool {
        messages.contains { message in
            message.deadlines.contains { candidate in
                candidate.confidence >= 0.70
                    && DeadlineDateResolver.resolve(
                        candidate.dateString,
                        referenceDate: message.date
                    ) != nil
            }
        }
    }

    mutating func add(
        message: ProjectMessageInput,
        membership: SemanticAffinityMembership,
        attention: MessageAttentionState?
    ) {
        messages.append(message)
        confidenceTotal += membership.confidence
        if let threadID = message.threadID {
            threadCounts[threadID, default: 0] += 1
        }
        for identifier in SemanticStatusIdentityEvidence.identifiers(in: message) {
            identifierCounts[identifier, default: 0] += 1
        }
        if let messageIDHeader = message.messageIDHeader {
            messageIDHeaders.insert(messageIDHeader)
        }
        referencedHeaders.formUnion(message.referencesHeaders)
        if let attention, attention.openKinds.isEmpty == false {
            openAttentionKindsByMessageID[message.id] = attention.openKinds
        }
    }
}
