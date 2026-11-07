import Foundation
import OhiaCore
import SwiftData
import Synchronization

public enum ManualProjectMembershipRepositoryError: Error, Sendable, Equatable {
    case dirtyContext
    case projectNotFound(UUID)
    case staleRevision(expected: Int, actual: Int)
    case staleMessageSource(Set<UUID>)
    case duplicateEvaluatedMessage(UUID)
    case malformedProvenance
}

public enum MailProjectReconciliationScope: Sendable, Equatable {
    case full
    case messages(Set<UUID>)
}

enum ManualProjectWriteAuthority {
    private static let mutex = Mutex<Void>(())

    static func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        try mutex.withLock { _ in try body() }
    }
}

public struct MailProjectMembershipSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let messageID: UUID
    public let configurationRevision: Int
    public let source: MailProjectMembershipSource
    public let matchingGroupID: UUID?
    public let matchingConditionIDs: [UUID]
    public let provenance: MailProjectMembershipProvenance
    public let sourceFingerprint: String
    public let evaluatedAt: Date

    public init(
        id: UUID,
        projectID: UUID,
        messageID: UUID,
        configurationRevision: Int,
        source: MailProjectMembershipSource,
        matchingGroupID: UUID?,
        matchingConditionIDs: [UUID],
        provenance: MailProjectMembershipProvenance,
        sourceFingerprint: String,
        evaluatedAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.messageID = messageID
        self.configurationRevision = configurationRevision
        self.source = source
        self.matchingGroupID = matchingGroupID
        self.matchingConditionIDs = matchingConditionIDs
        self.provenance = provenance
        self.sourceFingerprint = sourceFingerprint
        self.evaluatedAt = evaluatedAt
    }
}

public struct MailProjectEvaluatedMessage: Codable, Sendable, Equatable {
    public let messageID: UUID
    public let finalDecision: MailProjectFinalMembershipDecision
    public let sourceFingerprint: String
    public let evaluatedAt: Date

    public init(
        messageID: UUID,
        finalDecision: MailProjectFinalMembershipDecision,
        sourceFingerprint: String,
        evaluatedAt: Date
    ) {
        self.messageID = messageID
        self.finalDecision = finalDecision
        self.sourceFingerprint = sourceFingerprint
        self.evaluatedAt = evaluatedAt
    }
}

public struct MailProjectDeletionSnapshot: Codable, Sendable, Equatable {
    public let project: MailProjectScalarSnapshot
    public let ruleGroups: [MailProjectOwnedRuleGroupSnapshot]
    public let decisions: [MailProjectOwnedDecisionSnapshot]
    public let memberships: [MailProjectMembershipSnapshot]
    public let configurationDraft: MailProjectConfigurationDraftSnapshot?
    public let projectCacheKeys: [String]
    public let projectGuideState: MailProjectGuideStateSnapshot?

    public init(
        project: MailProjectScalarSnapshot,
        ruleGroups: [MailProjectOwnedRuleGroupSnapshot],
        decisions: [MailProjectOwnedDecisionSnapshot],
        memberships: [MailProjectMembershipSnapshot],
        configurationDraft: MailProjectConfigurationDraftSnapshot?,
        projectCacheKeys: [String],
        projectGuideState: MailProjectGuideStateSnapshot? = nil
    ) {
        self.project = project
        self.ruleGroups = ruleGroups
        self.decisions = decisions
        self.memberships = memberships
        self.configurationDraft = configurationDraft
        self.projectCacheKeys = projectCacheKeys
        self.projectGuideState = projectGuideState
    }
}

public struct MailProjectGuideStateSnapshot: Codable, Sendable, Equatable {
    public let entryID: String
    public let completedStepIDsJSON: String?
    public let guideLastReadAt: Date?
    public let guideLastReadReason: String?
    public let updatedAt: Date

    public init(
        entryID: String,
        completedStepIDsJSON: String?,
        guideLastReadAt: Date?,
        guideLastReadReason: String?,
        updatedAt: Date
    ) {
        self.entryID = entryID
        self.completedStepIDsJSON = completedStepIDsJSON
        self.guideLastReadAt = guideLastReadAt
        self.guideLastReadReason = guideLastReadReason
        self.updatedAt = updatedAt
    }
}

public struct MailProjectScalarSnapshot: Codable, Sendable, Equatable {
    public let id: UUID
    public let normalizedName: String
    public let displayName: String
    public let accountIDs: Set<UUID>
    public let automaticIntakeStartAt: Date?
    public let configurationRevision: Int
    public let isPinned: Bool
    public let pinSortIndex: Int?
    public let lastMembershipUsedAt: Date?
    public let resolvedAt: Date?
    public let health: MailProjectHealth
    public let lastMembershipError: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        normalizedName: String,
        displayName: String,
        accountIDs: Set<UUID>,
        automaticIntakeStartAt: Date?,
        configurationRevision: Int,
        isPinned: Bool,
        pinSortIndex: Int?,
        lastMembershipUsedAt: Date?,
        resolvedAt: Date?,
        health: MailProjectHealth,
        lastMembershipError: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.normalizedName = normalizedName
        self.displayName = displayName
        self.accountIDs = accountIDs
        self.automaticIntakeStartAt = automaticIntakeStartAt
        self.configurationRevision = configurationRevision
        self.isPinned = isPinned
        self.pinSortIndex = pinSortIndex
        self.lastMembershipUsedAt = lastMembershipUsedAt
        self.resolvedAt = resolvedAt
        self.health = health
        self.lastMembershipError = lastMembershipError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MailProjectOwnedRuleGroupSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: MailProjectRuleGroupKind
    public let sortIndex: Int
    public let conditions: [MailProjectOwnedRuleConditionSnapshot]

    public init(
        id: UUID,
        kind: MailProjectRuleGroupKind,
        sortIndex: Int,
        conditions: [MailProjectOwnedRuleConditionSnapshot]
    ) {
        self.id = id
        self.kind = kind
        self.sortIndex = sortIndex
        self.conditions = conditions
    }
}

public struct MailProjectOwnedRuleConditionSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let facet: MailProjectRuleFacet
    public let polarity: MailProjectConditionPolarity
    public let quantifier: MailProjectValueQuantifier
    public let values: [String]
    public let correspondentRole: MailProjectCorrespondentRole?
    public let keywordScopes: [MailProjectKeywordScope]
    public let keywordOperator: MailProjectKeywordOperator?
    public let sortIndex: Int

    public init(
        id: UUID,
        facet: MailProjectRuleFacet,
        polarity: MailProjectConditionPolarity,
        quantifier: MailProjectValueQuantifier,
        values: [String],
        correspondentRole: MailProjectCorrespondentRole?,
        keywordScopes: [MailProjectKeywordScope],
        keywordOperator: MailProjectKeywordOperator?,
        sortIndex: Int
    ) {
        self.id = id
        self.facet = facet
        self.polarity = polarity
        self.quantifier = quantifier
        self.values = values
        self.correspondentRole = correspondentRole
        self.keywordScopes = keywordScopes
        self.keywordOperator = keywordOperator
        self.sortIndex = sortIndex
    }
}

public struct MailProjectOwnedDecisionSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let targetKind: MailProjectDecisionTargetKind
    public let targetID: UUID
    public let decision: MailProjectDecisionValue
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        projectID: UUID,
        targetKind: MailProjectDecisionTargetKind,
        targetID: UUID,
        decision: MailProjectDecisionValue,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.targetKind = targetKind
        self.targetID = targetID
        self.decision = decision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MailProjectConfigurationDraftSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let targetProjectID: UUID?
    public let baseRevision: Int
    public let payloadVersion: Int
    public let payloadJSON: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        targetProjectID: UUID?,
        baseRevision: Int,
        payloadVersion: Int,
        payloadJSON: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.targetProjectID = targetProjectID
        self.baseRevision = baseRevision
        self.payloadVersion = payloadVersion
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension MailProjectFinalMembershipDecision: Codable {
    private enum Kind: String, Codable {
        case included
        case excluded
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case membershipSource
        case provenance
        case exclusionSource
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .included:
            guard container.contains(.exclusionSource) == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .exclusionSource,
                    in: container,
                    debugDescription: "Included membership cannot carry an exclusion source."
                )
            }
            self = .included(
                source: try container.decode(
                    MailProjectMembershipSource.self,
                    forKey: .membershipSource
                ),
                provenance: try container.decode(
                    MailProjectMembershipProvenance.self,
                    forKey: .provenance
                )
            )
        case .excluded:
            guard container.contains(.membershipSource) == false,
                  container.contains(.provenance) == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "Excluded membership cannot carry inclusion payloads."
                )
            }
            guard container.contains(.exclusionSource) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.exclusionSource,
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Excluded membership requires an explicit exclusionSource key."
                    )
                )
            }
            self = .excluded(
                source: try container.decodeIfPresent(
                    MailProjectDecisionTargetKind.self,
                    forKey: .exclusionSource
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .included(source, provenance):
            try container.encode(Kind.included, forKey: .kind)
            try container.encode(source, forKey: .membershipSource)
            try container.encode(provenance, forKey: .provenance)
        case let .excluded(source):
            try container.encode(Kind.excluded, forKey: .kind)
            if let source {
                try container.encode(source, forKey: .exclusionSource)
            } else {
                try container.encodeNil(forKey: .exclusionSource)
            }
        }
    }
}

@MainActor
public struct ManualProjectMembershipRepository {
    private let modelContext: ModelContext
    private let notificationCenter: NotificationCenter
    private let now: @MainActor () -> Date
    private let beforeSave: @MainActor () throws -> Void

    public init(
        modelContext: ModelContext,
        notificationCenter: NotificationCenter = .default,
        now: @escaping @MainActor () -> Date = { .now },
        beforeSave: @escaping @MainActor () throws -> Void = {}
    ) {
        self.modelContext = modelContext
        self.notificationCenter = notificationCenter
        self.now = now
        self.beforeSave = beforeSave
    }

    public func memberships(messageID: UUID) throws -> [MailProjectMembershipSnapshot] {
        let targetMessageID = messageID
        return try modelContext.fetch(FetchDescriptor<MailProjectMembership>(
            predicate: #Predicate { $0.messageID == targetMessageID }
        ))
            .map(snapshot)
            .sorted { lhs, rhs in
                if lhs.projectID != rhs.projectID {
                    return lhs.projectID.uuidString < rhs.projectID.uuidString
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func memberMessageIDs(projectID: UUID) throws -> Set<UUID> {
        Set(try projectMemberships(projectID: projectID).map(\.messageID))
    }

    public func setMessageDecision(projectID: UUID, messageID: UUID, included: Bool) throws {
        let receipt = try ManualProjectWriteAuthority.withLock {
            try setMessageDecisionWithoutLock(
                projectID: projectID,
                messageID: messageID,
                included: included
            )
        }
        if let receipt {
            postMembership(
                projectID: projectID,
                messageIDs: receipt.messageIDs,
                revision: receipt.revision
            )
        }
    }

    private func setMessageDecisionWithoutLock(
        projectID: UUID,
        messageID: UUID,
        included: Bool
    ) throws -> MembershipMutationReceipt? {
        try requireCleanContext()
        var committed = false
        defer {
            if committed == false { modelContext.rollback() }
        }
        let project = try requireProject(projectID)
        let decisionRows = try targetDecisions(projectID: projectID, kind: .message, targetID: messageID)
        let winner = preferredDecision(in: decisionRows)
        let currentMembership = try membershipRow(projectID: projectID, messageID: messageID)
        let threadDecision = try threadDecisionForMessage(projectID: projectID, messageID: messageID)
        let timestamp = now()

        if included == false,
           winner == nil,
           currentMembership == nil,
           threadDecision?.decision != .include {
            committed = true
            return nil
        }
        project.configurationRevision += 1
        project.updatedAt = timestamp

        if included {
            let decision = winner ?? MailProjectDecision(
                projectID: projectID,
                targetKind: .message,
                targetID: messageID,
                decision: .include,
                createdAt: timestamp
            )
            if winner == nil { modelContext.insert(decision) }
            decision.decision = .include
            decision.updatedAt = timestamp
            deleteDuplicateDecisions(decisionRows, keeping: decision)

            let rule = try currentMembership.flatMap { try decodedProvenance($0.provenanceJSON).rule }
            let provenance = MailProjectMembershipProvenance(
                rule: rule,
                decisionID: decision.id,
                decisionTargetKind: .message,
                isExceptionToAutomaticRules: rule == nil
            )
            let row: MailProjectMembership
            if let currentMembership {
                row = currentMembership
            } else {
                row = try MailProjectMembership(
                    projectID: projectID,
                    messageID: messageID,
                    configurationRevision: project.configurationRevision,
                    source: .messageOverride,
                    matchingConditionIDs: []
                )
                modelContext.insert(row)
            }
            try install(
                provenance: provenance,
                source: .messageOverride,
                sourceFingerprint: manualFingerprint(
                    projectID: projectID, messageID: messageID, decision: decision
                ),
                evaluatedAt: timestamp,
                revision: project.configurationRevision,
                on: row
            )
        } else {
            let rule = try currentMembership.flatMap { try decodedProvenance($0.provenanceJSON).rule }
            let lowerThreadInclude = threadDecision?.decision == .include
            let priorExclusion = winner?.decision == .exclude
            let needsExclusion = rule != nil || lowerThreadInclude || priorExclusion
            if needsExclusion {
                let decision = winner ?? MailProjectDecision(
                    projectID: projectID,
                    targetKind: .message,
                    targetID: messageID,
                    decision: .exclude,
                    createdAt: timestamp
                )
                if winner == nil { modelContext.insert(decision) }
                decision.decision = .exclude
                decision.updatedAt = timestamp
                deleteDuplicateDecisions(decisionRows, keeping: decision)
            } else {
                for decision in decisionRows { modelContext.delete(decision) }
            }
            if let currentMembership { modelContext.delete(currentMembership) }
        }

        try save()
        committed = true
        return MembershipMutationReceipt(
            messageIDs: [messageID],
            revision: project.configurationRevision
        )
    }

    public func addThread(projectID: UUID, threadID: UUID) throws {
        let receipt = try ManualProjectWriteAuthority.withLock {
            try addThreadWithoutLock(projectID: projectID, threadID: threadID)
        }
        postMembership(
            projectID: projectID,
            messageIDs: receipt.messageIDs,
            revision: receipt.revision
        )
    }

    private func addThreadWithoutLock(
        projectID: UUID,
        threadID: UUID
    ) throws -> MembershipMutationReceipt {
        try requireCleanContext()
        var committed = false
        defer {
            if committed == false { modelContext.rollback() }
        }
        let project = try requireProject(projectID)
        let timestamp = now()
        project.configurationRevision += 1
        project.updatedAt = timestamp
        let threadRows = try targetDecisions(projectID: projectID, kind: .thread, targetID: threadID)
        let threadDecision = preferredDecision(in: threadRows) ?? MailProjectDecision(
            projectID: projectID,
            targetKind: .thread,
            targetID: threadID,
            decision: .include,
            createdAt: timestamp
        )
        if threadRows.isEmpty { modelContext.insert(threadDecision) }
        threadDecision.decision = .include
        threadDecision.updatedAt = timestamp
        deleteDuplicateDecisions(threadRows, keeping: threadDecision)

        let messages = try messages(threadID: threadID)
        for message in messages {
            let messageRows = try targetDecisions(projectID: projectID, kind: .message, targetID: message.id)
            let messageDecision = preferredDecision(in: messageRows)
            if messageDecision?.decision == .exclude {
                for decision in messageRows { modelContext.delete(decision) }
            } else if let messageDecision {
                deleteDuplicateDecisions(messageRows, keeping: messageDecision)
            }

            let existing = try membershipRow(projectID: projectID, messageID: message.id)
            let rule = try existing.flatMap { try decodedProvenance($0.provenanceJSON).rule }
            let includeDecision: MailProjectDecision
            let source: MailProjectMembershipSource
            if let messageDecision, messageDecision.decision == .include {
                includeDecision = messageDecision
                source = .messageOverride
            } else {
                includeDecision = threadDecision
                source = .threadOverride
            }
            let targetKind: MailProjectDecisionTargetKind = source == .messageOverride ? .message : .thread
            let provenance = MailProjectMembershipProvenance(
                rule: rule,
                decisionID: includeDecision.id,
                decisionTargetKind: targetKind,
                isExceptionToAutomaticRules: rule == nil
            )
            let row: MailProjectMembership
            if let existing {
                row = existing
            } else {
                row = try MailProjectMembership(
                    projectID: projectID,
                    messageID: message.id,
                    configurationRevision: project.configurationRevision,
                    source: source,
                    matchingConditionIDs: []
                )
                modelContext.insert(row)
            }
            try install(
                provenance: provenance,
                source: source,
                sourceFingerprint: manualFingerprint(
                    projectID: projectID, messageID: message.id, decision: includeDecision
                ),
                evaluatedAt: timestamp,
                revision: project.configurationRevision,
                on: row
            )
        }

        try save()
        committed = true
        return MembershipMutationReceipt(
            messageIDs: Set(messages.map(\.id)),
            revision: project.configurationRevision
        )
    }

    public func removeThread(projectID: UUID, threadID: UUID) throws {
        let receipt = try ManualProjectWriteAuthority.withLock {
            try removeThreadWithoutLock(projectID: projectID, threadID: threadID)
        }
        postMembership(
            projectID: projectID,
            messageIDs: receipt.messageIDs,
            revision: receipt.revision
        )
    }

    private func removeThreadWithoutLock(
        projectID: UUID,
        threadID: UUID
    ) throws -> MembershipMutationReceipt {
        try requireCleanContext()
        var committed = false
        defer {
            if committed == false { modelContext.rollback() }
        }
        let project = try requireProject(projectID)
        let timestamp = now()
        project.configurationRevision += 1
        project.updatedAt = timestamp
        let threadRows = try targetDecisions(projectID: projectID, kind: .thread, targetID: threadID)
        let threadDecision = preferredDecision(in: threadRows) ?? MailProjectDecision(
            projectID: projectID,
            targetKind: .thread,
            targetID: threadID,
            decision: .exclude,
            createdAt: timestamp
        )
        if threadRows.isEmpty { modelContext.insert(threadDecision) }
        threadDecision.decision = .exclude
        threadDecision.updatedAt = timestamp
        deleteDuplicateDecisions(threadRows, keeping: threadDecision)

        let messages = try messages(threadID: threadID)
        for message in messages {
            let messageRows = try targetDecisions(projectID: projectID, kind: .message, targetID: message.id)
            for decision in messageRows where decision.decision == .include {
                modelContext.delete(decision)
            }
            let exclusions = messageRows.filter { $0.decision == .exclude }
            if let exclusion = preferredDecision(in: exclusions) {
                deleteDuplicateDecisions(exclusions, keeping: exclusion)
            }
            if let row = try membershipRow(projectID: projectID, messageID: message.id) {
                modelContext.delete(row)
            }
        }

        try save()
        committed = true
        return MembershipMutationReceipt(
            messageIDs: Set(messages.map(\.id)),
            revision: project.configurationRevision
        )
    }

    public func rebuild(
        projectID: UUID,
        evaluated: [MailProjectEvaluatedMessage],
        revision: Int
    ) throws {
        let changedMessageIDs = try ManualProjectWriteAuthority.withLock {
            try rebuildWithoutLock(
                projectID: projectID,
                evaluated: evaluated,
                revision: revision
            )
        }
        if changedMessageIDs.isEmpty == false {
            postMembership(projectID: projectID, messageIDs: changedMessageIDs, revision: revision)
        }
    }

    private func rebuildWithoutLock(
        projectID: UUID,
        evaluated: [MailProjectEvaluatedMessage],
        revision: Int
    ) throws -> Set<UUID> {
        try requireCleanContext()
        var committed = false
        defer {
            if committed == false { modelContext.rollback() }
        }
        let project = try requireProject(projectID)
        guard project.configurationRevision == revision else {
            throw ManualProjectMembershipRepositoryError.staleRevision(
                expected: project.configurationRevision,
                actual: revision
            )
        }
        var seen: Set<UUID> = []
        for item in evaluated where seen.insert(item.messageID).inserted == false {
            throw ManualProjectMembershipRepositoryError.duplicateEvaluatedMessage(item.messageID)
        }

        var desired: [UUID: DesiredProjection] = [:]
        for item in evaluated {
            guard case let .included(source, provenance) = item.finalDecision else { continue }
            desired[item.messageID] = DesiredProjection(
                source: source,
                provenance: provenance,
                provenanceJSON: try encodedProvenance(provenance),
                sourceFingerprint: item.sourceFingerprint,
                evaluatedAt: item.evaluatedAt
            )
        }

        let oldRows = try projectMemberships(projectID: projectID)
        for row in oldRows {
            _ = try decodedProvenance(row.provenanceJSON)
        }
        let oldByMessageID = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.messageID, $0) })
        var changedMessageIDs: Set<UUID> = []

        for old in oldRows where desired[old.messageID] == nil {
            modelContext.delete(old)
            changedMessageIDs.insert(old.messageID)
        }
        for (messageID, projection) in desired {
            if let existing = oldByMessageID[messageID] {
                if try projectionDiffers(projection, revision: revision, from: existing) {
                    try install(
                        provenance: projection.provenance,
                        provenanceJSON: projection.provenanceJSON,
                        source: projection.source,
                        sourceFingerprint: projection.sourceFingerprint,
                        evaluatedAt: projection.evaluatedAt,
                        revision: revision,
                        on: existing
                    )
                    changedMessageIDs.insert(messageID)
                }
            } else {
                let row = try MailProjectMembership(
                    projectID: projectID,
                    messageID: messageID,
                    configurationRevision: revision,
                    source: projection.source,
                    matchingGroupID: projection.provenance.rule?.matchingGroupID,
                    matchingConditionIDs: Array(projection.provenance.rule?.matchingConditionIDs ?? []),
                    provenanceJSON: projection.provenanceJSON,
                    sourceFingerprint: projection.sourceFingerprint,
                    evaluatedAt: projection.evaluatedAt
                )
                modelContext.insert(row)
                changedMessageIDs.insert(messageID)
            }
        }

        try save()
        committed = true
        return changedMessageIDs
    }

    public func reconcileAtomically(
        projectID: UUID,
        evaluated: [MailProjectEvaluatedMessage],
        sourceStateFingerprints: [UUID: String],
        revision: Int,
        scope: MailProjectReconciliationScope,
        health: MailProjectHealth,
        lastMembershipError: String?,
        cancellationCheck: @MainActor @Sendable () throws -> Void = {}
    ) throws {
        var seen: Set<UUID> = []
        for item in evaluated where seen.insert(item.messageID).inserted == false {
            throw ManualProjectMembershipRepositoryError.duplicateEvaluatedMessage(item.messageID)
        }

        let scopedEvaluated: [MailProjectEvaluatedMessage]
        switch scope {
        case .full:
            scopedEvaluated = evaluated
        case let .messages(messageIDs):
            scopedEvaluated = evaluated.filter { messageIDs.contains($0.messageID) }
        }
        var desired: [UUID: DesiredProjection] = [:]
        for item in scopedEvaluated {
            guard case let .included(source, provenance) = item.finalDecision else { continue }
            desired[item.messageID] = DesiredProjection(
                source: source,
                provenance: provenance,
                provenanceJSON: try encodedProvenance(provenance),
                sourceFingerprint: item.sourceFingerprint,
                evaluatedAt: item.evaluatedAt
            )
        }

        let changedMessageIDs = try ManualProjectWriteAuthority.withLock {
            try requireCleanContext()
            var changedMessageIDs: Set<UUID> = []
            try modelContext.transaction {
                try cancellationCheck()
                let project = try requireProject(projectID)
                guard project.configurationRevision == revision else {
                    throw ManualProjectMembershipRepositoryError.staleRevision(
                        expected: project.configurationRevision,
                        actual: revision
                    )
                }
                let requiredMessageIDs: Set<UUID>
                var currentMessagesByID: [UUID: Message] = [:]
                var staleMessageIDs: Set<UUID> = []
                switch scope {
                case .full:
                    let currentMessages = try modelContext.fetch(FetchDescriptor<Message>())
                    currentMessagesByID = Dictionary(
                        uniqueKeysWithValues: currentMessages.map { ($0.id, $0) }
                    )
                    requiredMessageIDs = Set(sourceStateFingerprints.keys)
                    staleMessageIDs.formUnion(
                        Set(currentMessagesByID.keys).subtracting(requiredMessageIDs)
                    )
                case let .messages(messageIDs):
                    requiredMessageIDs = messageIDs
                }
                for messageID in requiredMessageIDs {
                    guard let expected = sourceStateFingerprints[messageID] else {
                        staleMessageIDs.insert(messageID)
                        continue
                    }
                    let message: Message?
                    if case .full = scope {
                        message = currentMessagesByID[messageID]
                    } else {
                        let id = messageID
                        message = try modelContext.fetch(FetchDescriptor<Message>(
                            predicate: #Predicate { $0.id == id }
                        )).first
                    }
                    if ManualProjectFingerprint.messageSourceStateFingerprint(message) != expected {
                        staleMessageIDs.insert(messageID)
                    }
                }
                guard staleMessageIDs.isEmpty else {
                    throw ManualProjectMembershipRepositoryError.staleMessageSource(
                        staleMessageIDs
                    )
                }

                let affectedRows: [MailProjectMembership]
                switch scope {
                case .full:
                    affectedRows = try projectMemberships(projectID: projectID)
                case let .messages(messageIDs):
                    affectedRows = try messageIDs.sorted(by: uuidOrder).compactMap {
                        try membershipRow(projectID: projectID, messageID: $0)
                    }
                }
                let oldByMessageID = Dictionary(
                    uniqueKeysWithValues: affectedRows.map { ($0.messageID, $0) }
                )

                for old in affectedRows where desired[old.messageID] == nil {
                    modelContext.delete(old)
                    changedMessageIDs.insert(old.messageID)
                }
                for (messageID, projection) in desired {
                    if let existing = oldByMessageID[messageID] {
                        if projectionDiffersRepairingMalformed(
                            projection,
                            revision: revision,
                            from: existing
                        ) {
                            try install(
                                provenance: projection.provenance,
                                provenanceJSON: projection.provenanceJSON,
                                source: projection.source,
                                sourceFingerprint: projection.sourceFingerprint,
                                evaluatedAt: projection.evaluatedAt,
                                revision: revision,
                                on: existing
                            )
                            changedMessageIDs.insert(messageID)
                        }
                    } else {
                        let row = try MailProjectMembership(
                            projectID: projectID,
                            messageID: messageID,
                            configurationRevision: revision,
                            source: projection.source,
                            matchingGroupID: projection.provenance.rule?.matchingGroupID,
                            matchingConditionIDs: Array(
                                projection.provenance.rule?.matchingConditionIDs ?? []
                            ),
                            provenanceJSON: projection.provenanceJSON,
                            sourceFingerprint: projection.sourceFingerprint,
                            evaluatedAt: projection.evaluatedAt
                        )
                        modelContext.insert(row)
                        changedMessageIDs.insert(messageID)
                    }
                }

                let healthDiffers = project.health != health
                    || project.lastMembershipError != lastMembershipError
                if healthDiffers {
                    project.health = health
                    project.lastMembershipError = lastMembershipError
                }
                if changedMessageIDs.isEmpty == false || healthDiffers {
                    try cancellationCheck()
                    try beforeSave()
                }
            }
            return changedMessageIDs
        }

        if changedMessageIDs.isEmpty == false {
            postMembership(
                projectID: projectID,
                messageIDs: changedMessageIDs,
                revision: revision
            )
        }
    }

    public func updateMembershipHealthAtomically(
        projectID: UUID,
        revision: Int,
        health: MailProjectHealth,
        lastMembershipError: String?,
        cancellationCheck: @MainActor @Sendable () throws -> Void = {}
    ) throws {
        try ManualProjectWriteAuthority.withLock {
            try requireCleanContext()
            try modelContext.transaction {
                try cancellationCheck()
                let project = try requireProject(projectID)
                guard project.configurationRevision == revision else {
                    throw ManualProjectMembershipRepositoryError.staleRevision(
                        expected: project.configurationRevision,
                        actual: revision
                    )
                }
                guard project.health != health
                        || project.lastMembershipError != lastMembershipError else {
                    return
                }
                project.health = health
                project.lastMembershipError = lastMembershipError
                try cancellationCheck()
                try beforeSave()
            }
        }
    }

    public func removeSourceMessageProjections(messageIDs: Set<UUID>) throws {
        let receipts = try ManualProjectWriteAuthority.withLock {
            try removeSourceMessageProjectionsWithoutLock(messageIDs: messageIDs)
        }
        for receipt in receipts {
            postMembership(
                projectID: receipt.projectID,
                messageIDs: receipt.messageIDs,
                revision: receipt.revision
            )
        }
    }

    private func removeSourceMessageProjectionsWithoutLock(
        messageIDs: Set<UUID>
    ) throws -> [ProjectMembershipMutationReceipt] {
        try requireCleanContext()
        var committed = false
        defer {
            if committed == false { modelContext.rollback() }
        }
        guard messageIDs.isEmpty == false else {
            committed = true
            return []
        }
        let rows = try allMemberships().filter { messageIDs.contains($0.messageID) }
        guard rows.isEmpty == false else {
            committed = true
            return []
        }
        for row in rows {
            _ = try decodedProvenance(row.provenanceJSON)
        }

        let byProject = Dictionary(grouping: rows, by: \.projectID)
        let revisions = try Dictionary(uniqueKeysWithValues: byProject.keys.map { projectID in
            let project = try requireProject(projectID)
            return (projectID, project.configurationRevision)
        })
        for row in rows { modelContext.delete(row) }

        try save()
        committed = true
        return byProject.keys.sorted(by: uuidOrder).compactMap { projectID in
            guard let revision = revisions[projectID] else { return nil }
            return ProjectMembershipMutationReceipt(
                projectID: projectID,
                messageIDs: Set(byProject[projectID, default: []].map(\.messageID)),
                revision: revision
            )
        }
    }

    public func deleteProjectOwnedState(projectID: UUID) throws -> MailProjectDeletionSnapshot {
        let receipt = try ManualProjectWriteAuthority.withLock {
            try deleteProjectOwnedStateWithoutLock(projectID: projectID)
        }
        postMembership(
            projectID: projectID,
            messageIDs: receipt.messageIDs,
            revision: receipt.revision
        )
        return receipt.snapshot
    }

    private func deleteProjectOwnedStateWithoutLock(
        projectID: UUID
    ) throws -> ProjectDeletionReceipt {
        try requireCleanContext()
        var committed = false
        defer {
            if committed == false { modelContext.rollback() }
        }
        let project = try requireProject(projectID)
        let groups = project.ruleGroups.sorted(by: groupOrder)
        let projectDecisions = try allDecisions().filter { $0.projectID == projectID }.sorted(by: decisionOrder)
        let projectMemberships = try projectMemberships(projectID: projectID).sorted(by: membershipOrder)
        let drafts = try modelContext.fetch(FetchDescriptor<MailProjectConfigurationDraft>())
            .filter { $0.targetProjectID == projectID }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let draft = drafts.first
        let guideEntryID = "project-\(projectID.uuidString.lowercased())"
        let guideStates = try modelContext.fetch(FetchDescriptor<DeadlineGuideState>(
            predicate: #Predicate { $0.entryID == guideEntryID }
        ))
        let guideState = guideStates.first

        let snapshot = try MailProjectDeletionSnapshot(
            project: MailProjectScalarSnapshot(
                id: project.id,
                normalizedName: project.normalizedName,
                displayName: project.displayName,
                accountIDs: Set(project.accountIDs()),
                automaticIntakeStartAt: project.automaticIntakeStartAt,
                configurationRevision: project.configurationRevision,
                isPinned: project.isPinned,
                pinSortIndex: project.pinSortIndex,
                lastMembershipUsedAt: project.lastMembershipUsedAt,
                resolvedAt: project.resolvedAt,
                health: project.health,
                lastMembershipError: project.lastMembershipError,
                createdAt: project.createdAt,
                updatedAt: project.updatedAt
            ),
            ruleGroups: groups.map { group in
                MailProjectOwnedRuleGroupSnapshot(
                    id: group.id,
                    kind: group.kind,
                    sortIndex: group.sortIndex,
                    conditions: try group.conditions.sorted(by: conditionOrder).map { condition in
                        MailProjectOwnedRuleConditionSnapshot(
                            id: condition.id,
                            facet: condition.facet,
                            polarity: condition.polarity,
                            quantifier: condition.quantifier,
                            values: try condition.values(),
                            correspondentRole: condition.correspondentRole,
                            keywordScopes: try condition.keywordScopes(),
                            keywordOperator: condition.keywordOperator,
                            sortIndex: condition.sortIndex
                        )
                    }
                )
            },
            decisions: projectDecisions.map { decision in
                MailProjectOwnedDecisionSnapshot(
                    id: decision.id,
                    projectID: decision.projectID,
                    targetKind: decision.targetKind,
                    targetID: decision.targetID,
                    decision: decision.decision,
                    createdAt: decision.createdAt,
                    updatedAt: decision.updatedAt
                )
            },
            memberships: try projectMemberships.map(self.snapshot),
            configurationDraft: draft.map { draft in
                MailProjectConfigurationDraftSnapshot(
                    id: draft.id,
                    targetProjectID: draft.targetProjectID,
                    baseRevision: draft.baseRevision,
                    payloadVersion: draft.payloadVersion,
                    payloadJSON: draft.payloadJSON,
                    createdAt: draft.createdAt,
                    updatedAt: draft.updatedAt
                )
            },
            projectCacheKeys: [],
            projectGuideState: guideState.map { state in
                MailProjectGuideStateSnapshot(
                    entryID: state.entryID,
                    completedStepIDsJSON: state.completedStepIDsJSON,
                    guideLastReadAt: state.guideLastReadAt,
                    guideLastReadReason: state.guideLastReadReason,
                    updatedAt: state.updatedAt
                )
            }
        )
        let revision = project.configurationRevision
        let messageIDs = Set(projectMemberships.map(\.messageID))

        for decision in projectDecisions { modelContext.delete(decision) }
        for membership in projectMemberships { modelContext.delete(membership) }
        for draft in drafts { modelContext.delete(draft) }
        for state in guideStates { modelContext.delete(state) }
        modelContext.delete(project)

        try save()
        committed = true
        return ProjectDeletionReceipt(
            snapshot: snapshot,
            messageIDs: messageIDs,
            revision: revision
        )
    }

    private func requireCleanContext() throws {
        guard modelContext.hasChanges == false else {
            throw ManualProjectMembershipRepositoryError.dirtyContext
        }
    }

    private func save() throws {
        try beforeSave()
        try modelContext.save()
    }

    private func requireProject(_ projectID: UUID) throws -> MailProject {
        let id = projectID
        guard let project = try modelContext.fetch(FetchDescriptor<MailProject>(
            predicate: #Predicate { $0.id == id }
        )).first else {
            throw ManualProjectMembershipRepositoryError.projectNotFound(projectID)
        }
        return project
    }

    private func allMemberships() throws -> [MailProjectMembership] {
        try modelContext.fetch(FetchDescriptor<MailProjectMembership>())
    }

    private func projectMemberships(projectID: UUID) throws -> [MailProjectMembership] {
        let id = projectID
        return try modelContext.fetch(FetchDescriptor<MailProjectMembership>(
            predicate: #Predicate { $0.projectID == id }
        ))
    }

    private func membershipRow(projectID: UUID, messageID: UUID) throws -> MailProjectMembership? {
        let key = MailProjectMembership.key(projectID: projectID, messageID: messageID)
        return try modelContext.fetch(FetchDescriptor<MailProjectMembership>(
            predicate: #Predicate { $0.membershipKey == key }
        )).first
    }

    private func allDecisions() throws -> [MailProjectDecision] {
        try modelContext.fetch(FetchDescriptor<MailProjectDecision>())
    }

    private func targetDecisions(
        projectID: UUID,
        kind: MailProjectDecisionTargetKind,
        targetID: UUID
    ) throws -> [MailProjectDecision] {
        let key = MailProjectDecision.key(
            projectID: projectID,
            targetKind: kind,
            targetID: targetID
        )
        return try modelContext.fetch(FetchDescriptor<MailProjectDecision>(
            predicate: #Predicate { $0.decisionKey == key }
        ))
    }

    private func preferredDecision(in rows: [MailProjectDecision]) -> MailProjectDecision? {
        rows.sorted(by: decisionPreference).first
    }

    private func deleteDuplicateDecisions(
        _ rows: [MailProjectDecision],
        keeping winner: MailProjectDecision
    ) {
        for row in rows where row !== winner { modelContext.delete(row) }
    }

    private func threadDecisionForMessage(
        projectID: UUID,
        messageID: UUID
    ) throws -> MailProjectDecision? {
        let id = messageID
        guard let message = try modelContext.fetch(FetchDescriptor<Message>(
            predicate: #Predicate { $0.id == id }
        )).first,
              let threadID = message.thread?.id else {
            return nil
        }
        return preferredDecision(in: try targetDecisions(
            projectID: projectID,
            kind: .thread,
            targetID: threadID
        ))
    }

    private func messages(threadID: UUID) throws -> [Message] {
        try modelContext.fetch(FetchDescriptor<Message>())
            .filter { $0.thread?.id == threadID }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func snapshot(_ row: MailProjectMembership) throws -> MailProjectMembershipSnapshot {
        MailProjectMembershipSnapshot(
            id: row.id,
            projectID: row.projectID,
            messageID: row.messageID,
            configurationRevision: row.configurationRevision,
            source: row.source,
            matchingGroupID: row.matchingGroupID,
            matchingConditionIDs: try row.matchingConditionIDs(),
            provenance: try decodedProvenance(row.provenanceJSON),
            sourceFingerprint: row.sourceFingerprint,
            evaluatedAt: row.evaluatedAt
        )
    }

    private func encodedProvenance(_ provenance: MailProjectMembershipProvenance) throws -> String {
        do {
            let canonical = CanonicalMembershipProvenance(
                rule: provenance.rule.map { rule in
                    CanonicalRuleProvenance(
                        matchingGroupID: rule.matchingGroupID,
                        matchingConditionIDs: rule.matchingConditionIDs.sorted(by: uuidOrder)
                    )
                },
                decisionID: provenance.decisionID,
                decisionTargetKind: provenance.decisionTargetKind,
                isExceptionToAutomaticRules: provenance.isExceptionToAutomaticRules
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(canonical), as: UTF8.self)
        } catch {
            throw ManualProjectMembershipRepositoryError.malformedProvenance
        }
    }

    private func decodedProvenance(_ json: String) throws -> MailProjectMembershipProvenance {
        do {
            return try JSONDecoder().decode(
                MailProjectMembershipProvenance.self,
                from: Data(json.utf8)
            )
        } catch {
            throw ManualProjectMembershipRepositoryError.malformedProvenance
        }
    }

    private func install(
        provenance: MailProjectMembershipProvenance,
        provenanceJSON: String? = nil,
        source: MailProjectMembershipSource,
        sourceFingerprint: String,
        evaluatedAt: Date,
        revision: Int,
        on row: MailProjectMembership
    ) throws {
        row.configurationRevision = revision
        row.source = source
        row.matchingGroupID = provenance.rule?.matchingGroupID
        try row.replaceMatchingConditionIDs(Array(provenance.rule?.matchingConditionIDs ?? []))
        if let provenanceJSON {
            row.provenanceJSON = provenanceJSON
        } else {
            row.provenanceJSON = try encodedProvenance(provenance)
        }
        row.sourceFingerprint = sourceFingerprint
        row.evaluatedAt = evaluatedAt
    }

    private func projectionDiffers(
        _ desired: DesiredProjection,
        revision: Int,
        from row: MailProjectMembership
    ) throws -> Bool {
        try row.configurationRevision != revision
            || row.source != desired.source
            || row.matchingGroupID != desired.provenance.rule?.matchingGroupID
            || Set(row.matchingConditionIDs()) != (desired.provenance.rule?.matchingConditionIDs ?? [])
            || row.provenanceJSON != desired.provenanceJSON
            || row.sourceFingerprint != desired.sourceFingerprint
            || row.evaluatedAt != desired.evaluatedAt
    }

    private func projectionDiffersRepairingMalformed(
        _ desired: DesiredProjection,
        revision: Int,
        from row: MailProjectMembership
    ) -> Bool {
        guard let conditionIDs = try? row.matchingConditionIDs() else { return true }
        return row.configurationRevision != revision
            || row.source != desired.source
            || row.matchingGroupID != desired.provenance.rule?.matchingGroupID
            || Set(conditionIDs) != (desired.provenance.rule?.matchingConditionIDs ?? [])
            || row.provenanceJSON != desired.provenanceJSON
            || row.sourceFingerprint != desired.sourceFingerprint
            || row.evaluatedAt != desired.evaluatedAt
    }

    private func manualFingerprint(
        projectID: UUID,
        messageID: UUID,
        decision: MailProjectDecision
    ) -> String {
        let bits = decision.updatedAt.timeIntervalSinceReferenceDate.bitPattern
        return [projectID.uuidString, decision.id.uuidString, String(bits), messageID.uuidString]
            .joined(separator: "|")
    }

    private func postMembership(projectID: UUID, messageIDs: Set<UUID>, revision: Int) {
        notificationCenter.post(
            name: .ohiaManualProjectMembershipDidChange,
            object: nil,
            userInfo: ManualProjectMembershipNotificationCoding.userInfo(
                projectIDs: [projectID],
                messageIDs: messageIDs,
                configurationRevision: revision
            )
        )
    }

    private func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    private func decisionPreference(_ lhs: MailProjectDecision, _ rhs: MailProjectDecision) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func decisionOrder(_ lhs: MailProjectDecision, _ rhs: MailProjectDecision) -> Bool {
        if lhs.targetKindRawValue != rhs.targetKindRawValue {
            return lhs.targetKindRawValue < rhs.targetKindRawValue
        }
        if lhs.targetID != rhs.targetID { return lhs.targetID.uuidString < rhs.targetID.uuidString }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func groupOrder(_ lhs: MailProjectRuleGroup, _ rhs: MailProjectRuleGroup) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func conditionOrder(_ lhs: MailProjectRuleCondition, _ rhs: MailProjectRuleCondition) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func membershipOrder(_ lhs: MailProjectMembership, _ rhs: MailProjectMembership) -> Bool {
        if lhs.messageID != rhs.messageID { return lhs.messageID.uuidString < rhs.messageID.uuidString }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct DesiredProjection {
    let source: MailProjectMembershipSource
    let provenance: MailProjectMembershipProvenance
    let provenanceJSON: String
    let sourceFingerprint: String
    let evaluatedAt: Date
}

private struct MembershipMutationReceipt {
    let messageIDs: Set<UUID>
    let revision: Int
}

private struct ProjectMembershipMutationReceipt {
    let projectID: UUID
    let messageIDs: Set<UUID>
    let revision: Int
}

private struct ProjectDeletionReceipt {
    let snapshot: MailProjectDeletionSnapshot
    let messageIDs: Set<UUID>
    let revision: Int
}

private struct CanonicalMembershipProvenance: Codable {
    let rule: CanonicalRuleProvenance?
    let decisionID: UUID?
    let decisionTargetKind: MailProjectDecisionTargetKind?
    let isExceptionToAutomaticRules: Bool
}

private struct CanonicalRuleProvenance: Codable {
    let matchingGroupID: UUID
    let matchingConditionIDs: [UUID]
}
